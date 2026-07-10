import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { StringDecoder } from 'node:string_decoder';

export type ClaudeBridgeOptions = {
  claudeBin: string;
  workspaceDir: string;
};

export type ClaudeRunOptions = {
  prompt: string;
  sessionId?: string;
  onEvent: (event: unknown) => void;
  onText: (text: string) => void;
  onSessionId: (sessionId: string) => void;
};

export type ClaudeRunResult = {
  exitCode: number | null;
  stopped: boolean;
  sessionId?: string;
  stderr: string;
};

export type ClaudeActivity = {
  id: string;
  kind: 'thinking' | 'tool' | 'summary';
  state: 'running' | 'done' | 'error';
  toolName?: string;
  detail?: string;
  durationMs?: number;
  numTurns?: number;
  permissionDenials?: number;
};

type CurrentRun = {
  child: ChildProcessWithoutNullStreams;
  stopped: boolean;
  settled: boolean;
};

export class ClaudeBridge {
  private current: CurrentRun | null = null;

  constructor(private readonly options: ClaudeBridgeOptions) {}

  isRunning(): boolean {
    return this.current !== null;
  }

  async run(options: ClaudeRunOptions): Promise<ClaudeRunResult> {
    if (this.current) throw new Error('Claude is already running');

    const args = [
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
    ];
    if (options.sessionId) args.push('--resume', options.sessionId);

    const child = spawn(this.options.claudeBin, args, {
      cwd: this.options.workspaceDir,
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env },
    });
    const exitOrError = Promise.race([
      once(child, 'exit') as Promise<[number | null, NodeJS.Signals | null]>,
      once(child, 'error').then(([err]) => err instanceof Error ? err : new Error(String(err))),
      once(child.stdin, 'error').then(([err]) => err instanceof Error ? err : new Error(String(err))),
    ]);

    const run: CurrentRun = { child, stopped: false, settled: false };
    this.current = run;

    let stderr = '';
    let stdoutBuffer = '';
    let sessionId = options.sessionId;
    let sawDelta = false;
    const decoder = new StringDecoder('utf8');

    const handleLine = (line: string) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      let event: unknown;
      try {
        event = JSON.parse(trimmed);
      } catch {
        options.onEvent({ type: 'parse_error', line: trimmed });
        return;
      }

      options.onEvent(event);

      const foundSessionId = findSessionId(event);
      if (foundSessionId && foundSessionId !== sessionId) {
        sessionId = foundSessionId;
        options.onSessionId(foundSessionId);
      }

      const delta = extractTextDelta(event);
      if (delta) {
        sawDelta = true;
        options.onText(delta);
        return;
      }

      const assistantText = extractAssistantText(event);
      if (assistantText && !sawDelta) {
        options.onText(assistantText);
        return;
      }

      const resultText = extractResultText(event);
      if (resultText && !sawDelta) {
        options.onText(resultText);
      }
    };

    child.stdout.on('data', (chunk: Buffer) => {
      stdoutBuffer += decoder.write(chunk);
      let idx: number;
      while ((idx = stdoutBuffer.indexOf('\n')) >= 0) {
        const line = stdoutBuffer.slice(0, idx);
        stdoutBuffer = stdoutBuffer.slice(idx + 1);
        handleLine(line);
      }
    });

    child.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8');
      if (stderr.length > 16_000) stderr = stderr.slice(-16_000);
    });

    try {
      child.stdin.write(JSON.stringify({
        type: 'user',
        message: {
          role: 'user',
          content: [{ type: 'text', text: options.prompt }],
        },
      }) + '\n');
      child.stdin.end();
      const result = await exitOrError;
      if (result instanceof Error) throw result;
      const [exitCode] = result;
      run.settled = true;
      const rest = decoder.end();
      if (rest) stdoutBuffer += rest;
      if (stdoutBuffer.trim()) handleLine(stdoutBuffer);
      return { exitCode, stopped: run.stopped, sessionId, stderr };
    } catch (err) {
      return { exitCode: null, stopped: run.stopped, sessionId, stderr: err instanceof Error ? err.message : String(err) };
    } finally {
      if (this.current === run) this.current = null;
    }
  }

  stop(): boolean {
    const run = this.current;
    if (!run) return false;
    run.stopped = true;
    run.child.kill();

    if (process.platform === 'win32' && run.child.pid) {
      const pid = run.child.pid;
      setTimeout(() => {
        if (this.current !== run || run.settled) return;
        spawn('taskkill', ['/pid', String(pid), '/t', '/f'], { stdio: 'ignore', shell: false });
      }, 1_500).unref();
    }
    return true;
  }
}

export function isMissingConversationError(stderr: string): boolean {
  return /No conversation found with session ID/i.test(stderr);
}

export function extractClaudeActivities(event: unknown): ClaudeActivity[] {
  if (!isRecord(event)) return [];

  if (event.type === 'stream_event') {
    const inner = isRecord(event.event) ? event.event : undefined;
    const block = isRecord(inner?.content_block) ? inner.content_block : undefined;
    if (inner?.type === 'content_block_start' && block?.type === 'thinking') {
      return [{ id: 'thinking', kind: 'thinking', state: 'running' }];
    }
    return [];
  }

  if (event.type === 'assistant') {
    const message = isRecord(event.message) ? event.message : undefined;
    const content = Array.isArray(message?.content) ? message.content : [];
    return content.flatMap(block => {
      if (!isRecord(block) || block.type !== 'tool_use') return [];
      if (typeof block.id !== 'string' || typeof block.name !== 'string') return [];
      return [{
        id: block.id,
        kind: 'tool' as const,
        state: 'running' as const,
        toolName: block.name,
        detail: summarizeToolInput(block.input),
      }];
    });
  }

  if (event.type === 'user') {
    const message = isRecord(event.message) ? event.message : undefined;
    const content = Array.isArray(message?.content) ? message.content : [];
    return content.flatMap(block => {
      if (!isRecord(block) || block.type !== 'tool_result') return [];
      if (typeof block.tool_use_id !== 'string') return [];
      return [{
        id: block.tool_use_id,
        kind: 'tool' as const,
        state: block.is_error === true ? 'error' as const : 'done' as const,
      }];
    });
  }

  if (event.type === 'result') {
    return [{
      id: 'summary',
      kind: 'summary',
      state: event.is_error === true ? 'error' : 'done',
      durationMs: typeof event.duration_ms === 'number' ? event.duration_ms : undefined,
      numTurns: typeof event.num_turns === 'number' ? event.num_turns : undefined,
      permissionDenials: Array.isArray(event.permission_denials) ? event.permission_denials.length : undefined,
    }];
  }

  return [];
}

export function extractClaudeCommands(event: unknown): string[] {
  if (!isRecord(event) || event.type !== 'system' || event.subtype !== 'init') return [];
  if (!Array.isArray(event.skills)) return [];
  return [...new Set(event.skills
    .filter((command): command is string => typeof command === 'string')
    .map(command => command.trim().replace(/^\/+/, ''))
    .filter(Boolean))]
    .sort((a, b) => a.localeCompare(b));
}

export async function discoverClaudeCommands(options: ClaudeBridgeOptions): Promise<string[]> {
  const child = spawn(options.claudeBin, [
    '-p',
    '/help',
    '--output-format', 'stream-json',
    '--verbose',
  ], {
    cwd: options.workspaceDir,
    shell: false,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env },
  });
  const decoder = new StringDecoder('utf8');
  let buffer = '';
  let commands: string[] = [];

  const handleLine = (line: string) => {
    try {
      const found = extractClaudeCommands(JSON.parse(line));
      if (found.length) commands = found;
    } catch {}
  };
  child.stdout.on('data', (chunk: Buffer) => {
    buffer += decoder.write(chunk);
    let index: number;
    while ((index = buffer.indexOf('\n')) >= 0) {
      handleLine(buffer.slice(0, index));
      buffer = buffer.slice(index + 1);
    }
  });
  child.stderr.resume();

  const timeout = setTimeout(() => child.kill(), 20_000);
  timeout.unref();
  await Promise.race([once(child, 'exit'), once(child, 'error')]).catch(() => {});
  clearTimeout(timeout);
  buffer += decoder.end();
  if (buffer.trim()) handleLine(buffer);
  return commands;
}

function extractTextDelta(event: unknown): string {
  if (!isRecord(event)) return '';
  if (event.type !== 'stream_event') return '';
  const inner = isRecord(event.event) ? event.event : undefined;
  if (inner?.type !== 'content_block_delta') return '';
  const delta = isRecord(inner.delta) ? inner.delta : undefined;
  return delta?.type === 'text_delta' && typeof delta.text === 'string' ? delta.text : '';
}

function extractAssistantText(event: unknown): string {
  if (!isRecord(event) || event.type !== 'assistant') return '';
  const message = isRecord(event.message) ? event.message : undefined;
  const content = Array.isArray(message?.content) ? message.content : [];
  return content
    .filter((block): block is Record<string, unknown> => isRecord(block) && block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text as string)
    .join('');
}

function extractResultText(event: unknown): string {
  if (!isRecord(event) || event.type !== 'result') return '';
  return typeof event.result === 'string' ? event.result : '';
}

function findSessionId(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined;
  if (typeof value.session_id === 'string') return value.session_id;
  for (const item of Object.values(value)) {
    if (isRecord(item)) {
      const found = findSessionId(item);
      if (found) return found;
    } else if (Array.isArray(item)) {
      for (const nested of item) {
        const found = findSessionId(nested);
        if (found) return found;
      }
    }
  }
  return undefined;
}

function summarizeToolInput(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined;
  for (const key of ['file_path', 'path', 'command', 'pattern', 'query', 'description', 'url']) {
    const item = value[key];
    if (typeof item === 'string' && item.trim()) return truncate(item.trim(), 240);
  }
  return undefined;
}

function truncate(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 1)}…`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
