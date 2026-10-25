import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { StringDecoder } from 'node:string_decoder';
import type { NativeHistory, NativeMessage } from './nativeHistory.js';
import {
  normalizeCodexSandboxMode,
  normalizeEngineEffort,
  normalizeEngineModel,
  type EngineActivity,
  type EngineBridge,
  type EngineRunOptions,
  type EngineRunResult,
  type EngineSessionInfo,
} from './engineBridge.js';

export type CodexBridgeOptions = {
  codexBin: string;
  codexArgs?: string[];
  workspaceDir: string;
};

export type CodexModelOption = {
  model: string;
  displayName: string;
  description: string;
  isDefault: boolean;
};

export type CodexSkillOption = {
  name: string;
  description: string;
  path: string;
};

const nativeCommands = ['compact', 'review'] as const;
type NativeCommand = typeof nativeCommands[number];

type CurrentRun = {
  process?: CodexProcess;
  stopped: boolean;
  settled: boolean;
  sessionId?: string;
  turnId?: string;
  nativeCommand?: NativeCommand;
  sawDelta: boolean;
  stderr: string;
  options: EngineRunOptions;
  resolve: (result: EngineRunResult) => void;
};

type PendingRequest = {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
};

type CodexProcess = {
  child: ChildProcessWithoutNullStreams;
  pending: Map<string, PendingRequest>;
  nextRequestId: number;
  stderr: string;
  stdoutBuffer: string;
  decoder: StringDecoder;
  exitCode: number | null;
  closed: boolean;
  threadId?: string;
  threadKey?: string;
};

export class CodexBridge implements EngineBridge {
  private current: CurrentRun | null = null;
  private process: CodexProcess | null = null;
  private initializing: Promise<CodexProcess> | null = null;

  constructor(private readonly options: CodexBridgeOptions) {}

  isRunning(): boolean {
    return this.current !== null;
  }

  respondToPermission(_requestId: string, _decision: 'allow' | 'deny'): boolean {
    return false;
  }

  async readHistory(sessionId: string): Promise<NativeHistory> {
    const state = await this.ensureProcess();
    const read = await this.request(state, 'thread/read', { threadId: sessionId }, 5_000);
    const thread = isRecord(read) && isRecord(read.thread) ? read.thread : undefined;
    if (!thread || thread.id !== sessionId) throw new Error('native_history_invalid');
    let turns: unknown[];
    try {
      turns = await this.readHistoryPages(state, 'thread/turns/list', {
        threadId: sessionId, itemsView: 'full',
      });
    } catch (error) {
      const cause = error instanceof Error ? error.cause : undefined;
      if (!(isRecord(cause) && cause.code === -32601)
          && !(error instanceof Error && /method not found|unknown method|unsupported method/i.test(error.message))) {
        throw error;
      }
      const legacy = await this.request(state, 'thread/read', {
        threadId: sessionId, includeTurns: true,
      }, 5_000);
      if (!isRecord(legacy) || !isRecord(legacy.thread)
          || legacy.thread.id !== sessionId || !Array.isArray(legacy.thread.turns)) {
        throw new Error('native_history_invalid');
      }
      turns = legacy.thread.turns;
    }
    const messages: NativeMessage[] = [];
    let running = isRecord(thread.status) && thread.status.type === 'active';
    for (const turn of turns) {
      if (!isRecord(turn) || typeof turn.id !== 'string' || !Array.isArray(turn.items)) {
        throw new Error('native_history_invalid');
      }
      running ||= turn.status === 'inProgress';
      let items = turn.items;
      if (turn.itemsView && turn.itemsView !== 'full') {
        const entries = await this.readHistoryPages(state, 'thread/items/list', {
          threadId: sessionId, turnId: turn.id,
        });
        items = entries.map(entry => {
          if (!isRecord(entry) || entry.turnId !== turn.id || !isRecord(entry.item)) {
            throw new Error('native_history_invalid');
          }
          return entry.item;
        });
      }
      for (const item of items) {
        if (!isRecord(item) || typeof item.id !== 'string' || !item.id) {
          throw new Error('native_history_invalid');
        }
        if (item.type === 'agentMessage' && typeof item.text === 'string' && item.text.trim()) {
          messages.push({ id: item.id, role: 'assistant', text: item.text });
        } else if (item.type === 'userMessage' && Array.isArray(item.content)) {
          const text = item.content.filter(input => isRecord(input)
            && input.type === 'text' && typeof input.text === 'string')
            .map(input => input.text).join('\n');
          const hasImage = item.content.some(input => isRecord(input)
            && (input.type === 'image' || input.type === 'localImage'));
          if (text.trim() || hasImage) messages.push({
            id: item.id, role: 'user', text: text || '[图片]',
          });
        }
      }
    }
    return { sessionId, messages, running };
  }

  private async readHistoryPages(
    state: CodexProcess,
    method: string,
    params: Record<string, unknown>,
  ): Promise<unknown[]> {
    const data: unknown[] = [];
    const cursors = new Set<string>();
    let cursor: string | undefined;
    do {
      const page = await this.request(state, method, {
        ...params, sortDirection: 'asc', limit: 100, ...(cursor ? { cursor } : {}),
      }, 5_000);
      if (!isRecord(page) || !Array.isArray(page.data)
          || (page.nextCursor != null && typeof page.nextCursor !== 'string')) {
        throw new Error('native_history_invalid');
      }
      data.push(...page.data);
      cursor = typeof page.nextCursor === 'string' && page.nextCursor ? page.nextCursor : undefined;
      if (cursor && cursors.has(cursor)) throw new Error('native_history_invalid');
      if (cursor) cursors.add(cursor);
    } while (cursor);
    return data;
  }

  async listModels(): Promise<CodexModelOption[]> {
    const state = await this.ensureProcess();
    const models = new Map<string, CodexModelOption>();
    const cursors = new Set<string>();
    let cursor: string | undefined;
    do {
      const result = await this.request(state, 'model/list', {
        limit: 100,
        ...(cursor ? { cursor } : {}),
      }, 15_000);
      if (!isRecord(result) || !Array.isArray(result.data)) {
        throw new Error('invalid_codex_model_catalog');
      }
      for (const item of result.data) {
        if (!isRecord(item) || item.hidden === true || typeof item.model !== 'string') continue;
        const model = normalizeEngineModel(item.model);
        if (!model) continue;
        models.set(model, {
          model,
          displayName: typeof item.displayName === 'string' ? item.displayName : model,
          description: typeof item.description === 'string' ? item.description : '',
          isDefault: item.isDefault === true,
        });
      }
      cursor = typeof result.nextCursor === 'string' && result.nextCursor ? result.nextCursor : undefined;
      if (cursor && cursors.has(cursor)) throw new Error('invalid_codex_model_cursor');
      if (cursor) cursors.add(cursor);
    } while (cursor);
    return [...models.values()];
  }

  async listSkills(): Promise<CodexSkillOption[]> {
    const state = await this.ensureProcess();
    const result = await this.request(state, 'skills/list', {
      cwds: [this.options.workspaceDir],
      forceReload: true,
    }, 15_000);
    if (!isRecord(result) || !Array.isArray(result.data)) {
      throw new Error('invalid_codex_skill_catalog');
    }
    const skills = new Map<string, CodexSkillOption>();
    for (const entry of result.data) {
      if (!isRecord(entry) || !Array.isArray(entry.skills)) continue;
      for (const item of entry.skills) {
        if (!isRecord(item) || item.enabled === false
          || typeof item.name !== 'string' || typeof item.path !== 'string') continue;
        if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(item.name)) continue;
        skills.set(item.name, {
          name: item.name,
          path: item.path,
          description: typeof item.description === 'string' ? item.description : '',
        });
      }
    }
    return [...skills.values()];
  }

  async listCommands(): Promise<string[]> {
    const skills = await this.listSkills();
    return [...new Set([...nativeCommands, ...skills.map(skill => skill.name)])];
  }

  async run(options: EngineRunOptions): Promise<EngineRunResult> {
    if (this.current) throw new Error('Codex is already running');
    const model = normalizeEngineModel(options.model);
    const effort = normalizeEngineEffort(options.effort);
    const sandbox = normalizeCodexSandboxMode(options.sandboxMode);
    let resolveRun: (result: EngineRunResult) => void = () => {};
    const completed = new Promise<EngineRunResult>(resolve => {
      resolveRun = resolve;
    });
    const run: CurrentRun = {
      stopped: false,
      settled: false,
      sessionId: options.sessionId,
      sawDelta: false,
      stderr: '',
      options,
      resolve: resolveRun,
    };
    this.current = run;
    try {
      const command = options.prompt.match(/^\/([A-Za-z0-9][A-Za-z0-9._-]{0,127})(?:\s|$)/);
      const nativeCommand = nativeCommands.find(name => name === command?.[1]);
      const argumentsText = command ? options.prompt.slice(command[1].length + 1).trim() : '';
      if (nativeCommand && options.imagePaths?.length) {
        throw new Error('Codex 原生命令不接受图片附件，请单独发送命令。');
      }
      if (nativeCommand === 'compact' && argumentsText) {
        throw new Error('/compact 不接受参数，请单独发送 /compact。');
      }
      const processState = await this.ensureProcess();
      run.process = processState;
      if (run.stopped || run.settled) return await completed;
      if (nativeCommand === 'compact' && !options.sessionId && !processState.threadId) {
        throw new Error('当前会话还没有 Codex 上下文，请先发送一条消息。');
      }
      const skill = command && !nativeCommand
        ? (await this.listSkills()).find(item => item.name === command[1])
        : undefined;
      if (command && !nativeCommand && !skill) throw new Error('codex_command_not_found');
      if (run.stopped || run.settled) return await completed;
      const thread = await this.ensureThread(processState, options, model, sandbox);
      if (run.stopped || run.settled) return await completed;
      if (thread.model) {
        options.onEvent({ type: 'thread.started', thread });
      }
      const threadId = thread.id;
      if (threadId !== run.sessionId) {
        run.sessionId = threadId;
        options.onSessionId(threadId);
      }
      run.nativeCommand = nativeCommand;
      if (nativeCommand === 'compact') {
        await this.request(processState, 'thread/compact/start', { threadId }, 15_000);
        return await completed;
      }
      if (nativeCommand === 'review') {
        const result = await this.request(processState, 'review/start', {
          threadId,
          target: argumentsText
            ? { type: 'custom', instructions: argumentsText }
            : { type: 'uncommittedChanges' },
          delivery: 'inline',
        }, 15_000);
        const turn = isRecord(result) && isRecord(result.turn) ? result.turn : undefined;
        if (!turn || typeof turn.id !== 'string') throw new Error('codex_review_start_failed');
        run.turnId = turn.id;
        return await completed;
      }
      const input: Array<Record<string, unknown>> = [{
        type: 'text',
        text: skill ? options.prompt.replace(/^\//, '$') : options.prompt,
      }];
      options.onPrompt?.(String(input[0].text));
      if (skill) input.push({ type: 'skill', name: skill.name, path: skill.path });
      for (const path of [...new Set(options.imagePaths ?? [])]) {
        if (path.trim()) input.push({ type: 'localImage', path });
      }
      const result = await this.request(processState, 'turn/start', {
        threadId,
        input,
        approvalPolicy: 'never',
        ...(model ? { model } : {}),
        ...(effort && effort !== 'auto' ? { effort } : {}),
      });
      const turn = isRecord(result) && isRecord(result.turn) ? result.turn : undefined;
      if (!turn || typeof turn.id !== 'string') throw new Error('codex_turn_start_failed');
      run.turnId = turn.id;
      return await completed;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
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
    const processState = run.process;
    if (processState && run.sessionId && run.turnId) {
      void this.request(processState, 'turn/interrupt', {
        threadId: run.sessionId,
        turnId: run.turnId,
      }).catch(() => this.terminateProcess(processState));
      const timer = setTimeout(() => {
        if (this.current === run && !run.settled) this.terminateProcess(processState);
      }, 2_000);
      timer.unref();
    } else {
      this.terminateProcess(processState ?? this.process);
    }
    return true;
  }

  close(): void {
    this.terminateProcess(this.process);
  }

  private async ensureProcess(): Promise<CodexProcess> {
    if (this.initializing) return this.initializing;
    const pending = this.startProcess();
    this.initializing = pending;
    try {
      return await pending;
    } finally {
      if (this.initializing === pending) this.initializing = null;
    }
  }

  private async startProcess(): Promise<CodexProcess> {
    const existing = this.process;
    if (existing && !existing.closed) return existing;

    const child = spawn(this.options.codexBin, [
      ...(this.options.codexArgs ?? []),
      'app-server',
    ], {
      cwd: this.options.workspaceDir,
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env },
    });
    const state: CodexProcess = {
      child,
      pending: new Map(),
      nextRequestId: 0,
      stderr: '',
      stdoutBuffer: '',
      decoder: new StringDecoder('utf8'),
      exitCode: null,
      closed: false,
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
      this.rejectPending(state, new Error('codex_app_server_exited'));
      const run = this.current;
      if (run?.process === state) {
        this.finishRun(run, code, run.stopped ? undefined : 'codex_app_server_exited');
      }
    });

    let timer: NodeJS.Timeout | undefined;
    try {
      await Promise.race([
        this.request(state, 'initialize', {
          clientInfo: { name: 'cc-remote', title: 'CC Remote', version: '0.1.0' },
        }),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('codex_initialize_timeout')), 15_000);
          timer.unref();
        }),
      ]);
      this.notify(state, 'initialized');
      return state;
    } catch (error) {
      this.terminateProcess(state);
      throw error;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  private async ensureThread(
    state: CodexProcess,
    options: EngineRunOptions,
    model: string | undefined,
    sandbox: ReturnType<typeof normalizeCodexSandboxMode>,
  ): Promise<{ id: string; model?: string }> {
    const additionalDirectories = [...new Set(options.additionalDirectories ?? [])]
      .filter(directory => directory.trim());
    const threadKey = JSON.stringify({ model, sandbox, additionalDirectories });
    const requestedThreadId = options.sessionId ?? state.threadId;
    if (state.threadId === requestedThreadId && state.threadKey === threadKey) {
      return { id: state.threadId! };
    }

    const params = {
      approvalPolicy: 'never',
      cwd: this.options.workspaceDir,
      sandbox,
      ...(model ? { model } : {}),
      ...(additionalDirectories.length
        ? { runtimeWorkspaceRoots: [this.options.workspaceDir, ...additionalDirectories] }
        : {}),
    };
    const result = requestedThreadId
      ? await this.request(state, 'thread/resume', { threadId: requestedThreadId, ...params })
      : await this.request(state, 'thread/start', params);
    const thread = isRecord(result) && isRecord(result.thread) ? result.thread : undefined;
    if (!thread || typeof thread.id !== 'string') throw new Error('codex_thread_start_failed');
    state.threadId = thread.id;
    state.threadKey = threadKey;
    const resultModel = isRecord(result) && typeof result.model === 'string'
      ? result.model
      : undefined;
    return {
      id: thread.id,
      ...(typeof thread.model === 'string'
        ? { model: thread.model }
        : resultModel ? { model: resultModel } : {}),
    };
  }

  private request(state: CodexProcess, method: string, params: unknown, timeoutMs?: number): Promise<unknown> {
    if (state.closed || state.child.stdin.destroyed) {
      return Promise.reject(new Error('codex_app_server_not_running'));
    }
    const id = String(++state.nextRequestId);
    return new Promise((resolve, reject) => {
      const timer = timeoutMs ? setTimeout(() => {
        state.pending.delete(id);
        reject(new Error(`codex_request_timeout: ${method}`));
      }, timeoutMs) : undefined;
      timer?.unref();
      state.pending.set(id, {
        resolve: result => { if (timer) clearTimeout(timer); resolve(result); },
        reject: error => { if (timer) clearTimeout(timer); reject(error); },
      });
      try {
        state.child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
      } catch (error) {
        state.pending.delete(id);
        if (timer) clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private notify(state: CodexProcess, method: string): void {
    if (!state.closed && !state.child.stdin.destroyed) {
      state.child.stdin.write(JSON.stringify({ method }) + '\n');
    }
  }

  private handleLine(state: CodexProcess, line: string): void {
    const trimmed = line.trim();
    if (!trimmed) return;
    let message: unknown;
    try {
      message = JSON.parse(trimmed);
    } catch {
      this.current?.options.onEvent({ type: 'parse_error', line: trimmed });
      return;
    }
    if (!isRecord(message)) return;

    if ((typeof message.id === 'string' || typeof message.id === 'number')
      && ('result' in message || 'error' in message)) {
      const pending = state.pending.get(String(message.id));
      if (!pending) return;
      state.pending.delete(String(message.id));
      if (message.error !== undefined) {
        const error = isRecord(message.error) && typeof message.error.message === 'string'
          ? message.error.message
          : String(message.error);
        pending.reject(new Error(error, { cause: message.error }));
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (typeof message.method !== 'string') return;

    const params = isRecord(message.params) ? message.params : {};
    const event: Record<string, unknown> = {
      type: message.method.replaceAll('/', '.'),
      ...params,
    };
    const run = this.current;
    if (!run || run.process !== state || run.settled) return;
    const foundSessionId = extractCodexThreadId(event);
    if (foundSessionId && run.sessionId && foundSessionId !== run.sessionId) return;
    if (run.nativeCommand && !run.turnId && event.type === 'turn.started' && isRecord(event.turn)
      && typeof event.turn.id === 'string') run.turnId = event.turn.id;
    if (run.turnId) {
      const eventTurnId = typeof event.turnId === 'string' ? event.turnId
        : isRecord(event.turn) && typeof event.turn.id === 'string' ? event.turn.id : undefined;
      if (eventTurnId && eventTurnId !== run.turnId) return;
    }
    run.options.onEvent(event);

    if (foundSessionId && foundSessionId !== run.sessionId) {
      run.sessionId = foundSessionId;
      state.threadId = foundSessionId;
      run.options.onSessionId(foundSessionId);
    }
    const text = extractCodexText(event);
    if (event.type === 'item.agentMessage.delta' && text) {
      run.sawDelta = true;
      run.options.onText(text);
    } else if (text && !run.sawDelta) {
      run.options.onText(text);
    }
    const eventError = extractCodexError(event);
    if (eventError) run.stderr = appendBounded(run.stderr, `${eventError}\n`);

    if (event.type === 'turn.completed' && isRecord(event.turn)) {
      const status = event.turn.status;
      if (status === 'interrupted') run.stopped = true;
      if (run.nativeCommand === 'compact' && status === 'completed' && !run.stopped) {
        run.options.onText('上下文压缩完成。');
      }
      this.finishRun(run, status === 'failed' ? 1 : 0, eventError);
    }
  }

  private handleProcessFailure(state: CodexProcess, error: Error): void {
    this.rejectPending(state, error);
    const run = this.current;
    if (run?.process === state) this.finishRun(run, state.exitCode, error.message);
  }

  private rejectPending(state: CodexProcess, error: Error): void {
    for (const pending of state.pending.values()) pending.reject(error);
    state.pending.clear();
  }

  private finishRun(run: CurrentRun, exitCode: number | null, error?: string): void {
    if (run.settled) return;
    run.settled = true;
    run.resolve({
      exitCode,
      stopped: run.stopped,
      sessionId: run.sessionId,
      stderr: run.stderr.trim() || error || '',
    });
  }

  private terminateProcess(state: CodexProcess | null | undefined): void {
    if (!state || state.closed) return;
    if (this.process === state) this.process = null;
    state.closed = true;
    if (!state.child.stdin.destroyed) state.child.stdin.end();
    if (process.platform === 'win32' && state.child.pid) {
      spawn('taskkill', ['/pid', String(state.child.pid), '/t', '/f'], {
        stdio: 'ignore',
        shell: false,
      });
      // Under heavy system load, spawning taskkill itself can stall for tens
      // of seconds. Fall back to terminating the child through its existing
      // handle (TerminateProcess, no new process) so a stop never hangs on
      // process creation; descendants are still left to the taskkill tree.
      const killFallback = setTimeout(() => {
        if (state.child.exitCode === null && !state.child.killed) state.child.kill();
      }, 1_500);
      killFallback.unref?.();
    } else {
      state.child.kill();
    }
  }
}

export function extractCodexActivities(event: unknown): EngineActivity[] {
  if (!isRecord(event)
    || (event.type !== 'item.started' && event.type !== 'item.completed')
    || !isRecord(event.item)) {
    return [];
  }
  const item = event.item;
  if (typeof item.id !== 'string' || typeof item.type !== 'string') return [];

  const toolName = codexToolName(item);
  if (!toolName) return [];
  const failed = item.status === 'failed' || item.status === 'error';
  return [{
    id: item.id,
    kind: 'tool',
    state: event.type === 'item.started' ? 'running' : failed ? 'error' : 'done',
    toolName,
    detail: codexItemDetail(item),
  }];
}

export function extractCodexSessionInfo(event: unknown): EngineSessionInfo | null {
  if (!isRecord(event)) return null;
  const model = isRecord(event.thread) && typeof event.thread.model === 'string'
    ? event.thread.model
    : typeof event.model === 'string' ? event.model : undefined;
  if (event.type === 'thread.tokenUsage.updated' && isRecord(event.tokenUsage)) {
    // total accumulates across the whole thread, so it races past the context
    // window within a few turns; last is the most recent model request, which
    // is what the context window actually holds.
    const usage = (isRecord(event.tokenUsage.last) ? event.tokenUsage.last : undefined)
      ?? (isRecord(event.tokenUsage.total) ? event.tokenUsage.total : undefined);
    if (!usage) return null;
    const usedTokens = tokenValue(usage.totalTokens)
      || tokenValue(usage.inputTokens) + tokenValue(usage.outputTokens);
    const contextWindow = optionalTokenValue(event.tokenUsage.modelContextWindow);
    return {
      ...(model ? { model } : {}),
      usedTokens,
      ...(contextWindow === undefined
        ? {}
        : {
            contextWindow,
            remainingTokens: Math.max(0, contextWindow - usedTokens),
          }),
    };
  }
  if (event.type !== 'turn.completed' || !isRecord(event.usage)) {
    return model ? { model } : null;
  }
  const usage = event.usage;
  const inputTokens = tokenValue(usage.input_tokens ?? usage.inputTokens);
  const outputTokens = tokenValue(usage.output_tokens ?? usage.outputTokens);
  const contextWindow = optionalTokenValue(
    usage.context_window ?? usage.contextWindow,
  );
  const usedTokens = inputTokens + outputTokens;
  return {
    ...(model ? { model } : {}),
    usedTokens,
    ...(contextWindow === undefined
      ? {}
      : {
          contextWindow,
          remainingTokens: Math.max(0, contextWindow - usedTokens),
      }),
  };
}

function extractCodexThreadId(event: unknown): string | undefined {
  if (!isRecord(event)) return undefined;
  if (typeof event.threadId === 'string') return event.threadId;
  if (event.type === 'thread.started' && typeof event.thread_id === 'string') {
    return event.thread_id;
  }
  if (event.type === 'thread.started' && isRecord(event.thread) && typeof event.thread.id === 'string') {
    return event.thread.id;
  }
  return undefined;
}

function extractCodexText(event: unknown): string {
  if (!isRecord(event)) return '';
  if (event.type === 'item.agentMessage.delta' && typeof event.delta === 'string') {
    return event.delta;
  }
  if (event.type !== 'item.completed' || !isRecord(event.item)) return '';
  if (event.item.type === 'exitedReviewMode' && typeof event.item.review === 'string') {
    return event.item.review;
  }
  return (event.item.type === 'agent_message' || event.item.type === 'agentMessage')
    && typeof event.item.text === 'string'
    ? event.item.text
    : '';
}

function extractCodexError(event: unknown): string | undefined {
  if (!isRecord(event)) return undefined;
  if (event.type === 'error' && typeof event.message === 'string') {
    return event.message;
  }
  if (event.type === 'error' && isRecord(event.error) && typeof event.error.message === 'string') {
    return event.error.message;
  }
  if (event.type === 'turn.completed'
    && isRecord(event.turn)
    && event.turn.status === 'failed'
    && isRecord(event.turn.error)
    && typeof event.turn.error.message === 'string') {
    return event.turn.error.message;
  }
  if (event.type === 'turn.failed') {
    if (typeof event.error === 'string') return event.error;
    if (isRecord(event.error) && typeof event.error.message === 'string') {
      return event.error.message;
    }
  }
  return undefined;
}

function codexToolName(item: Record<string, unknown>): string | undefined {
  if (item.type === 'command_execution' || item.type === 'commandExecution') return 'Shell';
  if (item.type === 'file_change' || item.type === 'fileChange') return 'FileChange';
  if (item.type === 'contextCompaction') return 'Compact';
  if (item.type === 'mcp_tool_call' || item.type === 'mcpToolCall') {
    const server = stringValue(item.server);
    const tool = stringValue(item.tool) ?? stringValue(item.name);
    return server && tool ? `${server}.${tool}` : tool ?? 'MCP';
  }
  if (item.type === 'dynamicToolCall') return stringValue(item.tool) ?? 'Tool';
  if (item.type === 'web_search' || item.type === 'webSearch') return 'WebSearch';
  return undefined;
}

function codexItemDetail(item: Record<string, unknown>): string | undefined {
  for (const key of ['command', 'path', 'query', 'name']) {
    const value = item[key];
    if (typeof value === 'string' && value.trim()) return truncate(value.trim(), 240);
    if (Array.isArray(value)) {
      const joined = value.filter((part): part is string => typeof part === 'string').join(' ');
      if (joined.trim()) return truncate(joined.trim(), 240);
    }
  }
  return undefined;
}

function truncate(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 1)}…`;
}

function optionalTokenValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function tokenValue(value: unknown): number {
  return optionalTokenValue(value) ?? 0;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function appendBounded(current: string, addition: string): string {
  const next = current + addition;
  return next.length > 16_000 ? next.slice(-16_000) : next;
}
