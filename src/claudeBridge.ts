import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { createReadStream } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { StringDecoder } from 'node:string_decoder';
import { CLAUDE_APP_ENTRYPOINT, findSessionTranscript } from './claudeSessionHistory.js';
import {
  isClaudePermissionMode,
  normalizeEngineEffort,
  normalizeEngineModel,
  type ClaudePermissionMode as SharedClaudePermissionMode,
  type EngineActivity,
  type EngineBridge,
  type EngineEffortLevel,
  type EnginePermissionRequest,
  type EngineRunOptions,
  type EngineRunResult,
  type EngineSessionInfo,
} from './engineBridge.js';

export type ClaudeBridgeOptions = {
  claudeBin: string;
  claudeArgs?: string[];
  workspaceDir: string;
  allowBypassPermissions?: boolean;
};

export type ClaudePermissionMode = SharedClaudePermissionMode;
export type ClaudeEffortLevel = EngineEffortLevel;
export type ClaudePermissionRequest = EnginePermissionRequest;
export type ClaudeRunOptions = EngineRunOptions;

export function normalizeClaudeModel(value: unknown): string | undefined {
  return normalizeEngineModel(value);
}

export function normalizeClaudeEffort(value: unknown): ClaudeEffortLevel | undefined {
  return normalizeEngineEffort(value);
}

export type ClaudeRunResult = EngineRunResult;

export type ClaudeActivity = EngineActivity;

export type ClaudeSessionInfo = EngineSessionInfo;

export type ClaudeSessionInfoRestoreOptions = {
  sessionId: string;
  projectsDir?: string;
  settingsPath?: string;
  environment?: NodeJS.ProcessEnv;
};

type CurrentRun = {
  process?: ClaudeProcess;
  stopped: boolean;
  settled: boolean;
  pendingPermissions: Map<string, ClaudePermissionRequest>;
  onPermissionClosed: (requestId: string) => void;
  options: ClaudeRunOptions;
  sessionId?: string;
  sawDelta: boolean;
  stderr: string;
  resolve: (result: ClaudeRunResult) => void;
};

type ClaudeProcess = {
  child: ChildProcessWithoutNullStreams;
  key: string;
  sessionId?: string;
  stderr: string;
  stdoutBuffer: string;
  decoder: StringDecoder;
  exitCode: number | null;
  closed: boolean;
  initializeRequestId: string;
  resolveInitialize: () => void;
  rejectInitialize: (error: Error) => void;
  initialized: Promise<void>;
};

export class ClaudeBridge implements EngineBridge {
  private current: CurrentRun | null = null;
  private process: ClaudeProcess | null = null;

  constructor(private readonly options: ClaudeBridgeOptions) {}

  isRunning(): boolean {
    return this.current !== null;
  }

  respondToPermission(requestId: string, decision: 'allow' | 'deny'): boolean {
    const run = this.current;
    const request = run?.pendingPermissions.get(requestId);
    const child = run?.process?.child;
    if (!run || !request || !child || child.stdin.destroyed) return false;
    run.pendingPermissions.delete(requestId);
    child.stdin.write(JSON.stringify(permissionControlResponse(request, decision)) + '\n');
    run.onPermissionClosed(requestId);
    return true;
  }

  async run(options: ClaudeRunOptions): Promise<ClaudeRunResult> {
    if (this.current) throw new Error('Claude is already running');
    if (!isClaudePermissionMode(options.permissionMode)) {
      throw new Error('invalid_permission_mode');
    }
    const model = normalizeClaudeModel(options.model);
    const effort = normalizeClaudeEffort(options.effort);
    const permissionMode = options.permissionMode;

    const args = [
      ...(this.options.claudeArgs ?? []),
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-prompt-tool', 'stdio',
      '--permission-mode', permissionMode,
    ];
    if (permissionMode === 'bypassPermissions') {
      if (!this.options.allowBypassPermissions) throw new Error('bypass_permissions_disabled');
      args.push('--allow-dangerously-skip-permissions');
    }
    if (model) args.push('--model', model);
    if (effort && effort !== 'auto') args.push('--effort', effort);
    const additionalDirectories = [...new Set(options.additionalDirectories ?? [])]
      .filter(directory => directory.trim().length > 0);
    if (additionalDirectories.length) args.push('--add-dir', ...additionalDirectories);
    if (options.sessionId) args.push('--resume', options.sessionId);
    let resolveRun: (result: ClaudeRunResult) => void = () => {};
    const completed = new Promise<ClaudeRunResult>(resolve => {
      resolveRun = resolve;
    });
    const run: CurrentRun = {
      stopped: false,
      settled: false,
      pendingPermissions: new Map(),
      onPermissionClosed: options.onPermissionClosed ?? (() => {}),
      options,
      sessionId: options.sessionId,
      sawDelta: false,
      stderr: '',
      resolve: resolveRun,
    };
    this.current = run;

    const processKey = JSON.stringify({
      permissionMode,
      model,
      effort,
      additionalDirectories,
    });
    try {
      const processState = await this.ensureProcess(processKey, args, effort, options.sessionId);
      run.process = processState;
      processState.child.stdin.write(JSON.stringify({
        type: 'user',
        message: {
          role: 'user',
          content: [{ type: 'text', text: options.prompt }],
        },
      }) + '\n');
      return await completed;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.finishRun(run, run.process?.exitCode ?? null, message);
      return await completed;
    } finally {
      if (this.current === run) this.current = null;
    }
  }

  stop(): boolean {
    const run = this.current;
    if (!run) return false;
    run.stopped = true;
    this.terminateProcess(run.process ?? this.process);
    return true;
  }

  close(): void {
    this.terminateProcess(this.process);
  }

  private async ensureProcess(
    key: string,
    args: string[],
    effort: ClaudeEffortLevel | undefined,
    sessionId: string | undefined,
  ): Promise<ClaudeProcess> {
    const existing = this.process;
    if (existing
      && !existing.closed
      && existing.key === key
      && (!sessionId || !existing.sessionId || existing.sessionId === sessionId)) {
      return existing;
    }
    this.terminateProcess(existing);

    const child = spawn(this.options.claudeBin, args, {
      cwd: this.options.workspaceDir,
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env,
        CLAUDE_CODE_ENTRYPOINT: CLAUDE_APP_ENTRYPOINT,
        ...(effort === 'auto' ? { CLAUDE_CODE_EFFORT_LEVEL: 'auto' } : {}),
      },
    });
    let resolveInitialize: () => void = () => {};
    let rejectInitialize: (error: Error) => void = () => {};
    const initialized = new Promise<void>((resolve, reject) => {
      resolveInitialize = resolve;
      rejectInitialize = reject;
    });
    const state: ClaudeProcess = {
      child,
      key,
      sessionId,
      stderr: '',
      stdoutBuffer: '',
      decoder: new StringDecoder('utf8'),
      exitCode: null,
      closed: false,
      initializeRequestId: `cc-remote-init-${Date.now()}`,
      resolveInitialize,
      rejectInitialize,
      initialized,
    };
    this.process = state;
    if (this.current) this.current.process = state;

    child.stdout.on('data', (chunk: Buffer) => {
      state.stdoutBuffer += state.decoder.write(chunk);
      let index: number;
      while ((index = state.stdoutBuffer.indexOf('\n')) >= 0) {
        const line = state.stdoutBuffer.slice(0, index);
        state.stdoutBuffer = state.stdoutBuffer.slice(index + 1);
        this.handleLine(state, line);
      }
    });
    child.stderr.on('data', (chunk: Buffer) => {
      const text = chunk.toString('utf8');
      state.stderr = appendBounded(state.stderr, text);
      const run = this.current;
      if (run?.process === state) run.stderr = appendBounded(run.stderr, text);
    });
    child.once('error', error => this.handleProcessFailure(state, error));
    child.stdin.once('error', error => this.handleProcessFailure(state, error));
    child.once('close', code => {
      state.exitCode = code;
      state.closed = true;
      const rest = state.decoder.end();
      if (rest) state.stdoutBuffer += rest;
      if (state.stdoutBuffer.trim()) this.handleLine(state, state.stdoutBuffer);
      state.rejectInitialize(new Error('claude_exited_before_initialize'));
      const run = this.current;
      if (run?.process === state) {
        this.finishRun(run, code, run.stopped ? undefined : 'claude_process_exited');
      }
    });

    child.stdin.write(JSON.stringify({
      type: 'control_request',
      request_id: state.initializeRequestId,
      request: { subtype: 'initialize', hooks: null },
    }) + '\n');
    let timer: NodeJS.Timeout | undefined;
    try {
      await Promise.race([
        state.initialized,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('claude_initialize_timeout')), 15_000);
          timer.unref();
        }),
      ]);
      return state;
    } catch (error) {
      this.terminateProcess(state);
      throw error;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  private handleLine(state: ClaudeProcess, line: string): void {
    const trimmed = line.trim();
    if (!trimmed) return;
    let event: unknown;
    try {
      event = JSON.parse(trimmed);
    } catch {
      this.current?.options.onEvent({ type: 'parse_error', line: trimmed });
      return;
    }

    if (isRecord(event) && event.type === 'control_response') {
      const response = isRecord(event.response) ? event.response : undefined;
      if (response?.request_id === state.initializeRequestId) {
        if (response.subtype === 'error') {
          state.rejectInitialize(new Error(String(response.error || 'claude_initialize_failed')));
        } else {
          state.resolveInitialize();
        }
        return;
      }
    }

    const run = this.current;
    if (!run || run.process !== state || run.settled) return;
    const permissionRequest = extractClaudePermissionRequest(event);
    if (permissionRequest) {
      run.pendingPermissions.set(permissionRequest.requestId, permissionRequest);
      run.options.onPermissionRequest?.(permissionRequest);
      return;
    }
    if (isRecord(event) && event.type === 'control_cancel_request' && typeof event.request_id === 'string') {
      if (run.pendingPermissions.delete(event.request_id)) run.onPermissionClosed(event.request_id);
      return;
    }

    run.options.onEvent(event);
    const foundSessionId = findSessionId(event);
    if (foundSessionId && foundSessionId !== run.sessionId) {
      run.sessionId = foundSessionId;
      state.sessionId = foundSessionId;
      run.options.onSessionId(foundSessionId);
    }

    const delta = extractTextDelta(event);
    if (delta) {
      run.sawDelta = true;
      run.options.onText(delta);
    } else {
      const assistantText = extractAssistantText(event);
      const resultText = extractResultText(event);
      if (assistantText && !run.sawDelta) run.options.onText(assistantText);
      else if (resultText && !run.sawDelta) run.options.onText(resultText);
    }

    if (isRecord(event) && event.type === 'result') {
      this.finishRun(
        run,
        event.is_error === true ? 1 : 0,
        event.is_error === true ? extractResultText(event) || 'claude_run_failed' : undefined,
      );
    }
  }

  private handleProcessFailure(state: ClaudeProcess, error: Error): void {
    state.rejectInitialize(error);
    const run = this.current;
    if (run?.process === state) this.finishRun(run, state.exitCode, error.message);
  }

  private finishRun(run: CurrentRun, exitCode: number | null, error?: string): void {
    if (run.settled) return;
    run.settled = true;
    for (const requestId of run.pendingPermissions.keys()) run.onPermissionClosed(requestId);
    run.pendingPermissions.clear();
    run.resolve({
      exitCode,
      stopped: run.stopped,
      sessionId: run.sessionId,
      stderr: run.stderr.trim() || error || '',
    });
  }

  private terminateProcess(state: ClaudeProcess | null | undefined): void {
    if (!state || state.closed) return;
    if (this.process === state) this.process = null;
    state.closed = true;
    if (!state.child.stdin.destroyed) state.child.stdin.end();
    if (process.platform === 'win32' && state.child.pid) {
      spawn('taskkill', ['/pid', String(state.child.pid), '/t', '/f'], {
        stdio: 'ignore',
        shell: false,
      });
    } else {
      state.child.kill();
    }
  }
}

function appendBounded(current: string, addition: string): string {
  const next = current + addition;
  return next.length > 16_000 ? next.slice(-16_000) : next;
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
    const activities: ClaudeActivity[] = content.flatMap(block => {
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
    const thinking = content.flatMap(block =>
      isRecord(block) && block.type === 'thinking' && typeof block.thinking === 'string'
        && block.thinking.trim() ? [block.thinking] : []).join('\n\n');
    if (thinking) activities.unshift({
      id: 'thinking', kind: 'thinking', state: 'done', detail: thinking,
    });
    return activities;
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
  const commands = [
    ...(Array.isArray(event.slash_commands) ? event.slash_commands : []),
    ...(Array.isArray(event.skills) ? event.skills : []),
  ];
  return [...new Set(commands
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

  // Stream-json assistant events on Claude Code 2.1+ ship zeroed usage.
  // Only treat per-request usage as context fill when the counts are present.
  if (event.type === 'assistant' && isRecord(event.message)) {
    return claudeSessionInfoFromRequest(event.message.model, event.message.usage, event.modelUsage);
  }

  // result.usage and modelUsage token fields are billed totals for the whole
  // run (every tool-loop API call). Using them as context fill races past the
  // window. Keep only the model and the declared context window.
  if (event.type === 'result') {
    return claudeWindowFromResult(event.model, event.modelUsage);
  }
  return null;
}


export function mergeClaudeSessionInfo(
  current: ClaudeSessionInfo,
  next: ClaudeSessionInfo,
): ClaudeSessionInfo {
  const model = preferredClaudeModel(next.model, current.model);
  const contextWindow = Math.max(next.contextWindow ?? 0, current.contextWindow ?? 0) || undefined;
  const usedTokens = next.usedTokens ?? current.usedTokens;
  const merged: ClaudeSessionInfo = { ...current, ...next };
  if (model) merged.model = model;
  if (contextWindow) {
    merged.contextWindow = contextWindow;
    if (usedTokens !== undefined) {
      merged.usedTokens = usedTokens;
      merged.remainingTokens = Math.max(0, contextWindow - usedTokens);
    }
  }
  return merged;
}

function claudeSessionInfoFromRequest(
  model: unknown,
  usage: unknown,
  modelUsage: unknown,
): ClaudeSessionInfo | null {
  if (!isRecord(usage)) return null;
  const usedTokens = usedTokensFromUsage(usage);
  if (usedTokens <= 0) return null;
  if (model === '<synthetic>') return null;
  const contextWindow = claudeContextWindowForRequest(model, modelUsage, usedTokens);
  const info: ClaudeSessionInfo = {
    contextWindow,
    usedTokens,
    remainingTokens: Math.max(0, contextWindow - usedTokens),
  };
  if (typeof model === 'string' && model) info.model = model;
  return info;
}

function claudeWindowFromResult(model: unknown, modelUsage: unknown): ClaudeSessionInfo | null {
  let selectedName = typeof model === 'string' && model ? model : undefined;
  let selectedWindow = selectedName ? contextWindowForModel(selectedName) : 0;
  if (isRecord(modelUsage)) {
    const matched = selectedName ? modelUsage[selectedName] : undefined;
    if (isRecord(matched) && tokenValue(matched.contextWindow) > 0) {
      selectedWindow = tokenValue(matched.contextWindow);
    } else {
      for (const [name, value] of Object.entries(modelUsage)) {
        if (!isRecord(value)) continue;
        const window = tokenValue(value.contextWindow);
        if (window > selectedWindow) {
          selectedWindow = window;
          selectedName = name;
        } else if (!selectedName && name) {
          selectedName = name;
          if (!selectedWindow) selectedWindow = contextWindowForModel(name);
        }
      }
    }
  }
  if (!selectedName) return null;
  return {
    model: selectedName,
    contextWindow: selectedWindow || contextWindowForModel(selectedName),
  };
}

function pickRestoredClaudeModel(
  latest: string | undefined,
  configured: string | undefined,
  names: string[],
): string | undefined {
  if (latest) return oneMAlias(latest, names) || latest;
  if (configured) return oneMAlias(configured, names) || configured;
  return names.find(is1mModel) || names[0];
}

function preferredClaudeModel(next?: string, current?: string): string | undefined {
  if (!next) return current;
  if (!current) return next;
  if (is1mModel(next)) return next;
  if (is1mModel(current) && baseClaudeModel(current) === baseClaudeModel(next)) return current;
  return next;
}

function oneMAlias(model: string, names: string[]): string | undefined {
  const base = baseClaudeModel(model);
  return names.find(name => is1mModel(name) && baseClaudeModel(name) === base);
}

function baseClaudeModel(model: string): string {
  return model.replace(/\[1m\]/ig, '').replace(/-1m$/i, '').replace(/_1m$/i, '').trim().toLowerCase();
}

function is1mModel(model: string): boolean {
  return contextWindowForModel(model) === 1_000_000;
}

function usedTokensFromUsage(usage: unknown): number {
  if (!isRecord(usage)) return 0;
  return tokenValue(usage.input_tokens)
    + tokenValue(usage.cache_read_input_tokens)
    + tokenValue(usage.cache_creation_input_tokens);
}

function claudeContextWindowForRequest(
  model: unknown,
  modelUsage: unknown,
  _usedTokens: number,
): number {
  if (isRecord(modelUsage)) {
    if (typeof model === 'string' && isRecord(modelUsage[model])
      && typeof modelUsage[model].contextWindow === 'number') {
      return modelUsage[model].contextWindow;
    }
    let best: number | undefined;
    let bestUsed = -1;
    for (const value of Object.values(modelUsage)) {
      if (!isRecord(value) || typeof value.contextWindow !== 'number') continue;
      const candidateUsed = tokenValue(value.inputTokens)
        + tokenValue(value.cacheReadInputTokens)
        + tokenValue(value.cacheCreationInputTokens);
      if (candidateUsed > bestUsed) {
        bestUsed = candidateUsed;
        best = value.contextWindow;
      }
    }
    if (best !== undefined) return best;
  }
  return contextWindowForModel(typeof model === 'string' ? model : '');
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
  let bestWindow = 0;
  const modelNames: string[] = [];
  const considerModel = (name: unknown, window?: unknown) => {
    if (typeof name !== 'string' || !name || name === '<synthetic>') return;
    modelNames.push(name);
    const explicit = tokenValue(window);
    const nextWindow = explicit > 0 ? explicit : contextWindowForModel(name);
    if (nextWindow > bestWindow) bestWindow = nextWindow;
  };
  const lines = createInterface({
    input: createReadStream(transcriptPath, { encoding: 'utf8' }),
    crlfDelay: Infinity,
  });
  for await (const line of lines) {
    try {
      const entry = JSON.parse(line) as unknown;
      if (!isRecord(entry)) continue;
      if (isRecord(entry.modelUsage)) {
        for (const [name, value] of Object.entries(entry.modelUsage)) {
          considerModel(name, isRecord(value) ? value.contextWindow : undefined);
        }
      }
      if (entry.type !== 'assistant' || !isRecord(entry.message)) continue;
      // Sidechain entries belong to subagent contexts, not the main thread.
      if (entry.isSidechain === true) continue;
      const message = entry.message;
      if (typeof message.model === 'string' && message.model !== '<synthetic>') {
        latestModel = message.model;
        considerModel(message.model);
      }
      const usedTokens = usedTokensFromUsage(message.usage);
      if (usedTokens <= 0) continue;
      latestUsedTokens = usedTokens;
    } catch {}
  }

  const model = pickRestoredClaudeModel(latestModel, configuredModel, modelNames);
  if (!model) return null;
  const contextWindow = bestWindow || contextWindowForModel(model);
  const info: ClaudeSessionInfo = { model, contextWindow };
  if (latestUsedTokens !== undefined) {
    info.usedTokens = latestUsedTokens;
    info.remainingTokens = Math.max(0, contextWindow - latestUsedTokens);
  }
  return info;
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
  // "[1m]" is how Claude Code marks the 1M-context beta model variant.
  return /(?:^|[-_[])(?:1m|1000k)(?:$|[-_\].])/i.test(model) ? 1_000_000 : 200_000;
}

export async function discoverClaudeCommands(options: ClaudeBridgeOptions): Promise<string[]> {
  const child = spawn(options.claudeBin, [
    ...(options.claudeArgs ?? []),
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
  for (const key of ['file_path', 'path', 'command', 'skill', 'pattern', 'query', 'description', 'url']) {
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
