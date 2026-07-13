import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { createReadStream } from 'node:fs';
import { readdir, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { StringDecoder } from 'node:string_decoder';

export type ClaudeBridgeOptions = {
  claudeBin: string;
  workspaceDir: string;
  allowBypassPermissions?: boolean;
};

export type ClaudePermissionMode =
  | 'manual'
  | 'acceptEdits'
  | 'auto'
  | 'dontAsk'
  | 'plan'
  | 'bypassPermissions';

export type ClaudePermissionRequest = {
  requestId: string;
  toolName: string;
  input: Record<string, unknown>;
  detail?: string;
  title?: string;
  displayName?: string;
  description?: string;
  decisionReason?: string;
};

export type ClaudeRunOptions = {
  prompt: string;
  sessionId?: string;
  additionalDirectories?: string[];
  permissionMode: ClaudePermissionMode;
  onEvent: (event: unknown) => void;
  onText: (text: string) => void;
  onSessionId: (sessionId: string) => void;
  onPermissionRequest: (request: ClaudePermissionRequest) => void;
  onPermissionClosed: (requestId: string) => void;
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

export type ClaudeSessionInfo = {
  model?: string;
  contextWindow?: number;
  usedTokens?: number;
  remainingTokens?: number;
};

export type ClaudeSessionInfoRestoreOptions = {
  sessionId: string;
  projectsDir?: string;
  settingsPath?: string;
  environment?: NodeJS.ProcessEnv;
};

type CurrentRun = {
  child: ChildProcessWithoutNullStreams;
  stopped: boolean;
  settled: boolean;
  pendingPermissions: Map<string, ClaudePermissionRequest>;
  onPermissionClosed: (requestId: string) => void;
};

export class ClaudeBridge {
  private current: CurrentRun | null = null;

  constructor(private readonly options: ClaudeBridgeOptions) {}

  isRunning(): boolean {
    return this.current !== null;
  }

  respondToPermission(requestId: string, decision: 'allow' | 'deny'): boolean {
    const run = this.current;
    const request = run?.pendingPermissions.get(requestId);
    if (!run || !request || run.child.stdin.destroyed) return false;
    run.pendingPermissions.delete(requestId);
    run.child.stdin.write(JSON.stringify(permissionControlResponse(request, decision)) + '\n');
    run.onPermissionClosed(requestId);
    return true;
  }

  async run(options: ClaudeRunOptions): Promise<ClaudeRunResult> {
    if (this.current) throw new Error('Claude is already running');

    const args = [
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-prompt-tool', 'stdio',
      '--permission-mode', options.permissionMode,
    ];
    if (options.permissionMode === 'bypassPermissions') {
      if (!this.options.allowBypassPermissions) throw new Error('bypass_permissions_disabled');
      args.push('--allow-dangerously-skip-permissions');
    }
    const additionalDirectories = [...new Set(options.additionalDirectories ?? [])]
      .filter(directory => directory.trim().length > 0);
    if (additionalDirectories.length) args.push('--add-dir', ...additionalDirectories);
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

    const run: CurrentRun = {
      child,
      stopped: false,
      settled: false,
      pendingPermissions: new Map(),
      onPermissionClosed: options.onPermissionClosed,
    };
    this.current = run;

    let stderr = '';
    let stdoutBuffer = '';
    let sessionId = options.sessionId;
    let sawDelta = false;
    const decoder = new StringDecoder('utf8');
    const initializeRequestId = `cc-remote-init-${Date.now()}`;
    let initializeResolve: (() => void) | undefined;
    let initializeReject: ((error: Error) => void) | undefined;
    const initialized = new Promise<void>((resolve, reject) => {
      initializeResolve = resolve;
      initializeReject = reject;
    });

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

      if (isRecord(event) && event.type === 'control_response') {
        const response = isRecord(event.response) ? event.response : undefined;
        if (response?.request_id === initializeRequestId) {
          if (response.subtype === 'error') {
            initializeReject?.(new Error(String(response.error || 'claude_initialize_failed')));
          } else {
            initializeResolve?.();
          }
          return;
        }
      }

      const permissionRequest = extractClaudePermissionRequest(event);
      if (permissionRequest) {
        run.pendingPermissions.set(permissionRequest.requestId, permissionRequest);
        options.onPermissionRequest(permissionRequest);
        return;
      }

      if (isRecord(event) && event.type === 'control_cancel_request' && typeof event.request_id === 'string') {
        if (run.pendingPermissions.delete(event.request_id)) options.onPermissionClosed(event.request_id);
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

      if (isRecord(event) && event.type === 'result' && !child.stdin.destroyed) {
        child.stdin.end();
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
        type: 'control_request',
        request_id: initializeRequestId,
        request: { subtype: 'initialize', hooks: null },
      }) + '\n');
      await Promise.race([
        initialized,
        exitOrError.then(result => {
          if (result instanceof Error) throw result;
          throw new Error('claude_exited_before_initialize');
        }),
        new Promise<never>((_, reject) => {
          const timer = setTimeout(() => reject(new Error('claude_initialize_timeout')), 15_000);
          timer.unref();
        }),
      ]);
      child.stdin.write(JSON.stringify({
        type: 'user',
        message: {
          role: 'user',
          content: [{ type: 'text', text: options.prompt }],
        },
      }) + '\n');
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
      for (const requestId of run.pendingPermissions.keys()) options.onPermissionClosed(requestId);
      run.pendingPermissions.clear();
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

export function extractClaudePermissionRequest(event: unknown): ClaudePermissionRequest | null {
  if (!isRecord(event) || event.type !== 'control_request' || typeof event.request_id !== 'string') return null;
  const request = isRecord(event.request) ? event.request : undefined;
  if (request?.subtype !== 'can_use_tool' || typeof request.tool_name !== 'string' || !isRecord(request.input)) {
    return null;
  }
  return {
    requestId: event.request_id,
    toolName: request.tool_name,
    input: request.input,
    detail: summarizeToolInput(request.input),
    title: stringValue(request.title),
    displayName: stringValue(request.display_name),
    description: stringValue(request.description),
    decisionReason: stringValue(request.decision_reason),
  };
}

export function permissionControlResponse(
  request: ClaudePermissionRequest,
  decision: 'allow' | 'deny',
): Record<string, unknown> {
  return {
    type: 'control_response',
    response: {
      subtype: 'success',
      request_id: request.requestId,
      response: decision === 'allow'
        ? { behavior: 'allow', updatedInput: request.input }
        : { behavior: 'deny', message: '用户在手机端拒绝了这个操作', interrupt: false },
    },
  };
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

export function extractClaudeSessionInfo(event: unknown): ClaudeSessionInfo | null {
  if (!isRecord(event)) return null;

  if (event.type === 'system' && event.subtype === 'init' && typeof event.model === 'string') {
    return { model: event.model };
  }

  if (event.type !== 'result' || !isRecord(event.modelUsage)) return null;
  let selected: ClaudeSessionInfo | null = null;
  for (const [model, value] of Object.entries(event.modelUsage)) {
    if (!isRecord(value) || typeof value.contextWindow !== 'number') continue;
    const usedTokens = tokenValue(value.inputTokens)
      + tokenValue(value.cacheReadInputTokens)
      + tokenValue(value.cacheCreationInputTokens);
    const candidate = {
      model,
      contextWindow: value.contextWindow,
      usedTokens,
      remainingTokens: Math.max(0, value.contextWindow - usedTokens),
    };
    if (!selected || usedTokens > (selected.usedTokens ?? 0)) selected = candidate;
  }
  return selected;
}

export async function restoreClaudeSessionInfo({
  sessionId,
  projectsDir = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects'),
  settingsPath = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'settings.json'),
  environment = process.env,
}: ClaudeSessionInfoRestoreOptions): Promise<ClaudeSessionInfo | null> {
  if (!sessionId) return null;
  const transcriptPath = await findSessionTranscript(projectsDir, `${sessionId}.jsonl`);
  if (!transcriptPath) return null;

  const configuredModel = await readConfiguredClaudeModel(settingsPath, environment);
  let latestModel: string | undefined;
  let latestUsedTokens: number | undefined;
  const lines = createInterface({
    input: createReadStream(transcriptPath, { encoding: 'utf8' }),
    crlfDelay: Infinity,
  });
  for await (const line of lines) {
    try {
      const entry = JSON.parse(line) as unknown;
      if (!isRecord(entry) || entry.type !== 'assistant' || !isRecord(entry.message)) continue;
      const message = entry.message;
      if (typeof message.model === 'string') latestModel = message.model;
      if (!isRecord(message.usage)) continue;
      latestUsedTokens = tokenValue(message.usage.input_tokens)
        + tokenValue(message.usage.cache_read_input_tokens)
        + tokenValue(message.usage.cache_creation_input_tokens);
    } catch {}
  }

  const model = configuredModel || latestModel;
  if (!model) return null;
  const contextWindow = contextWindowForModel(model);
  const usedTokens = latestUsedTokens ?? 0;
  return {
    model,
    contextWindow,
    usedTokens,
    remainingTokens: Math.max(0, contextWindow - usedTokens),
  };
}

async function findSessionTranscript(root: string, fileName: string): Promise<string | null> {
  const pending = [root];
  while (pending.length) {
    const directory = pending.shift()!;
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) pending.push(path);
      else if (entry.isFile() && entry.name === fileName) return path;
    }
  }
  return null;
}

async function readConfiguredClaudeModel(
  settingsPath: string,
  environment: NodeJS.ProcessEnv,
): Promise<string | undefined> {
  if (environment.ANTHROPIC_MODEL) return environment.ANTHROPIC_MODEL;
  try {
    const settings = JSON.parse(await readFile(settingsPath, 'utf8')) as unknown;
    if (!isRecord(settings)) return undefined;
    const settingsEnv = isRecord(settings.env) ? settings.env : {};
    if (typeof settingsEnv.ANTHROPIC_MODEL === 'string') return settingsEnv.ANTHROPIC_MODEL;
    if (typeof settings.model !== 'string') return undefined;
    const aliasKey = `ANTHROPIC_DEFAULT_${settings.model.toUpperCase()}_MODEL`;
    const aliasModel = settingsEnv[aliasKey];
    if (typeof aliasModel === 'string') return aliasModel;
    return settings.model.includes('-') ? settings.model : undefined;
  } catch {
    return undefined;
  }
}

function contextWindowForModel(model: string): number {
  return /(?:^|[-_])(1m|1000k)(?:$|[-_])/i.test(model) ? 1_000_000 : 200_000;
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

function tokenValue(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
