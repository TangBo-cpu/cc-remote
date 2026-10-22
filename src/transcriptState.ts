import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type {
  ClaudeActivity,
  ClaudePermissionMode,
  ClaudePermissionRequest,
  ClaudeSessionInfo,
} from './claudeBridge.js';
import type { CodexSandboxMode } from './engineBridge.js';
import type { AttachmentDescriptor } from './attachmentStore.js';
import { mergeNativeMessages, type NativeBinding, type NativeHistory } from './nativeHistory.js';

const SCHEMA_VERSION = 1;
const SAVE_DELAY_MS = 200;
const INTERRUPTED_MESSAGE = '电脑端重启，任务已中断';

export type TranscriptMessage = {
  role: 'user' | 'assistant' | 'system' | 'activity';
  text: string;
  native?: NativeBinding;
  nativePrompt?: string;
  nativeLocalOnly?: boolean;
  attachments?: AttachmentDescriptor[];
  activityId?: string;
  activityKind?: ClaudeActivity['kind'];
  activityState?: ClaudeActivity['state'] | 'stopped';
  activityTool?: string;
  activityDetail?: string;
  activityDurationMs?: number;
};

export type TranscriptSnapshot = {
  version: typeof SCHEMA_VERSION;
  revision: number;
  running: boolean;
  updatedAt: number;
  engineSessionId?: string;
  nativeHistoryStart?: number;
  permissionMode: ClaudePermissionMode;
  sandboxMode?: CodexSandboxMode;
  pendingPermissions: TranscriptPermissionRequest[];
  sessionInfo: ClaudeSessionInfo;
  messages: TranscriptMessage[];
};

export type TranscriptPermissionRequest = Omit<ClaudePermissionRequest, 'input'>;

export type TranscriptState = {
  snapshot(): TranscriptSnapshot;
  beginPrompt(
    prompt: string,
    permissionMode: ClaudePermissionMode,
    attachments?: AttachmentDescriptor[],
    sandboxMode?: CodexSandboxMode,
    nativePrompt?: string,
    nativeLocalOnly?: boolean,
  ): void;
  appendText(text: string): void;
  setAssistantAttachments(index: number, attachments: AttachmentDescriptor[]): boolean;
  mergeActivity(activity: ClaudeActivity): void;
  setSessionInfo(info: ClaudeSessionInfo): void;
  setEngineSessionId(sessionId: string | undefined): void;
  setNativePrompt(prompt: string): void;
  addPermission(request: ClaudePermissionRequest): void;
  removePermission(requestId: string): void;
  finishDone(): Promise<void>;
  finishStopped(): Promise<void>;
  finishError(message: string): Promise<void>;
  clear(): Promise<void>;
  importNativeHistory(history: NativeHistory): Promise<{ changed: boolean; external: boolean }>;
  recordRejectedPrompt(prompt: string, error: string, attachments?: AttachmentDescriptor[]): Promise<void>;
  flush(): Promise<void>;
};

function clearPendingAssistantPrefix(holder: { pendingAssistantPrefix: string }): void {
  holder.pendingAssistantPrefix = '';
}

export async function createTranscriptState(
  statePath = join(process.cwd(), '.data', 'transcript.json'),
): Promise<TranscriptState> {
  let state = await loadState(statePath);
  let saveQueue: Promise<void> = Promise.resolve();
  let saveTimer: NodeJS.Timeout | undefined;
  let tmpCounter = 0;
  // Whitespace-only stream fragments may arrive before visible text; keep them
  // until a non-whitespace delta arrives so indent/code fences are not lost.
  const pending = { pendingAssistantPrefix: '' };

  async function saveSnapshot(snapshot: TranscriptSnapshot): Promise<void> {
    const write = saveQueue.catch(() => undefined).then(async () => {
      await mkdir(dirname(statePath), { recursive: true });
      const tmp = `${statePath}.${process.pid}.${tmpCounter += 1}.tmp`;
      await writeFile(tmp, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
      await rename(tmp, statePath);
    });
    saveQueue = write;
    await write;
  }

  async function saveNow(): Promise<void> {
    await saveSnapshot(cloneSnapshot(state));
  }

  async function commitSnapshot(next: TranscriptSnapshot): Promise<void> {
    try {
      await saveSnapshot(next);
    } catch (error) {
      saveQueue = saveQueue.catch(() => undefined);
      throw error;
    }
    state = next;
  }

  function scheduleSave(): void {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      saveTimer = undefined;
      void saveNow();
    }, SAVE_DELAY_MS);
    saveTimer.unref();
  }

  function mutate(update: () => void): void {
    update();
    state.revision += 1;
    state.updatedAt = Date.now();
    scheduleSave();
  }

  async function flush(): Promise<void> {
    if (saveTimer) {
      clearTimeout(saveTimer);
      saveTimer = undefined;
      await saveNow();
      return;
    }
    await saveQueue;
  }

  if (state.running) {
    state.running = false;
    state.pendingPermissions = [];
    finishActivities(state.messages, 'stopped');
    state.messages.push({ role: 'system', text: INTERRUPTED_MESSAGE });
    state.revision += 1;
    state.updatedAt = Date.now();
    clearPendingAssistantPrefix(pending);
    await saveNow();
  }

  return {
    snapshot(): TranscriptSnapshot {
      return cloneSnapshot(state);
    },

    beginPrompt(
      prompt: string,
      permissionMode: ClaudePermissionMode,
      attachments: AttachmentDescriptor[] = [],
      sandboxMode?: CodexSandboxMode,
      nativePrompt?: string,
      nativeLocalOnly?: boolean,
    ): void {
      clearPendingAssistantPrefix(pending);
      mutate(() => {
        state.running = true;
        state.permissionMode = permissionMode;
        state.sandboxMode = sandboxMode;
        state.pendingPermissions = [];
        state.messages.push({
          role: 'user',
          text: prompt,
          ...(nativePrompt !== undefined && nativePrompt !== prompt ? { nativePrompt } : {}),
          ...(nativeLocalOnly ? { nativeLocalOnly: true } : {}),
          attachments: attachments.length ? structuredClone(attachments) : undefined,
        });
      });
    },

    appendText(text: string): void {
      if (!text || !state.running) return;
      const last = state.messages.at(-1);
      if (last?.role === 'assistant') {
        mutate(() => {
          last.text += text;
        });
        return;
      }

      // Hold leading whitespace until visible text arrives; never paint blank bubbles.
      if (!text.trim()) {
        pending.pendingAssistantPrefix += text;
        return;
      }

      const nextText = pending.pendingAssistantPrefix + text;
      clearPendingAssistantPrefix(pending);
      mutate(() => {
        finishActivities(state.messages, 'done', 'thinking');
        state.messages.push({ role: 'assistant', text: nextText });
      });
    },

    setAssistantAttachments(index, attachments): boolean {
      const message = state.messages[index];
      if (message?.role !== 'assistant'
          || JSON.stringify(message.attachments ?? []) === JSON.stringify(attachments)) return false;
      mutate(() => {
        message.attachments = attachments.length ? structuredClone(attachments) : undefined;
      });
      return true;
    },

    mergeActivity(activity: ClaudeActivity): void {
      if (!state.running || activity.kind === 'summary') return;
      mutate(() => {
        if (activity.kind === 'tool' && activity.state === 'running') {
          finishActivities(state.messages, 'done', 'thinking');
        }
        const start = currentTurnStart(state.messages);
        let index = -1;
        for (let candidate = state.messages.length - 1; candidate >= start; candidate -= 1) {
          if (state.messages[candidate].role === 'activity'
              && state.messages[candidate].activityId === activity.id) {
            index = candidate;
            break;
          }
        }
        const next = activityMessage(activity, index >= 0 ? state.messages[index] : undefined);
        if (index >= 0) state.messages[index] = next;
        else state.messages.push(next);
      });
    },

    setSessionInfo(info: ClaudeSessionInfo): void {
      mutate(() => {
        state.sessionInfo = { ...state.sessionInfo, ...info };
      });
    },

    setEngineSessionId(sessionId: string | undefined): void {
      if (state.engineSessionId === sessionId) return;
      mutate(() => {
        if (state.engineSessionId) {
          const lastUser = state.messages.map(message => message.role).lastIndexOf('user');
          state.nativeHistoryStart = state.running && lastUser >= 0 ? lastUser : state.messages.length;
        }
        state.engineSessionId = sessionId;
      });
    },

    setNativePrompt(prompt: string): void {
      const user = [...state.messages].reverse().find(message => message.role === 'user');
      if (!state.running || !user || (user.nativePrompt ?? user.text) === prompt) return;
      mutate(() => { user.nativePrompt = prompt; });
    },

    addPermission(request: ClaudePermissionRequest): void {
      mutate(() => {
        const { input: _input, ...displayRequest } = request;
        const index = state.pendingPermissions.findIndex(item => item.requestId === request.requestId);
        if (index >= 0) state.pendingPermissions[index] = displayRequest;
        else state.pendingPermissions.push(displayRequest);
      });
    },

    removePermission(requestId: string): void {
      const index = state.pendingPermissions.findIndex(item => item.requestId === requestId);
      if (index < 0) return;
      mutate(() => {
        state.pendingPermissions.splice(index, 1);
      });
    },

    async finishDone(): Promise<void> {
      if (!state.running) return flush();
      clearPendingAssistantPrefix(pending);
      mutate(() => {
        state.running = false;
        state.pendingPermissions = [];
        finishActivities(state.messages, 'done');
        if (!hasAssistantReplyAfterLastUser(state.messages)) {
          state.messages.push({ role: 'system', text: '本轮没有返回文本，请重试' });
        }
      });
      await flush();
    },

    async finishStopped(): Promise<void> {
      if (!state.running) return flush();
      clearPendingAssistantPrefix(pending);
      mutate(() => {
        state.running = false;
        state.pendingPermissions = [];
        finishActivities(state.messages, 'stopped');
        state.messages.push({ role: 'system', text: '已停止' });
      });
      await flush();
    },

    async finishError(message: string): Promise<void> {
      if (!state.running) return flush();
      clearPendingAssistantPrefix(pending);
      mutate(() => {
        state.running = false;
        state.pendingPermissions = [];
        finishActivities(state.messages, 'error');
        state.messages.push({ role: 'system', text: `错误：${message}` });
      });
      await flush();
    },

    async clear(): Promise<void> {
      clearPendingAssistantPrefix(pending);
      mutate(() => {
        state.running = false;
        state.engineSessionId = undefined;
        state.nativeHistoryStart = undefined;
        state.permissionMode = 'auto';
        state.sandboxMode = undefined;
        state.pendingPermissions = [];
        state.sessionInfo = {};
        state.messages = [];
      });
      await flush();
    },

    async importNativeHistory(history): Promise<{ changed: boolean; external: boolean }> {
      if (state.running || state.engineSessionId !== history.sessionId) {
        return { changed: false, external: false };
      }
      await flush();
      if (state.running || state.engineSessionId !== history.sessionId) {
        return { changed: false, external: false };
      }
      const merged = mergeNativeMessages(state.messages, history.messages, state.nativeHistoryStart);
      if (JSON.stringify(merged.messages) === JSON.stringify(state.messages)) {
        return { changed: false, external: false };
      }
      const next = {
        ...cloneSnapshot(state),
        messages: merged.messages,
        revision: state.revision + 1,
        updatedAt: Date.now(),
      };
      await commitSnapshot(next);
      return { changed: true, external: merged.external };
    },

    async recordRejectedPrompt(prompt, error, attachments = []): Promise<void> {
      if (state.running) throw new Error('claude_is_busy');
      await flush();
      await commitSnapshot({
        ...cloneSnapshot(state),
        revision: state.revision + 1,
        updatedAt: Date.now(),
        messages: [...state.messages, {
          role: 'user', text: prompt, nativeLocalOnly: true,
          ...(attachments.length ? { attachments: structuredClone(attachments) } : {}),
        }, { role: 'system', text: '错误：' + error }],
      });
    },

    flush,
  };
}

function emptySnapshot(): TranscriptSnapshot {
  return {
    version: SCHEMA_VERSION,
    revision: 0,
    running: false,
    updatedAt: Date.now(),
    permissionMode: 'auto',
    pendingPermissions: [],
    sessionInfo: {},
    messages: [],
  };
}

async function loadState(statePath: string): Promise<TranscriptSnapshot> {
  try {
    const parsed = JSON.parse(await readFile(statePath, 'utf8')) as
      Partial<TranscriptSnapshot> & { claudeSessionId?: unknown };
    if (parsed.version !== SCHEMA_VERSION || !Array.isArray(parsed.messages)) return emptySnapshot();
    return {
      version: SCHEMA_VERSION,
      revision: typeof parsed.revision === 'number' ? parsed.revision : 0,
      running: parsed.running === true,
      updatedAt: typeof parsed.updatedAt === 'number' ? parsed.updatedAt : Date.now(),
      engineSessionId: typeof parsed.engineSessionId === 'string'
        ? parsed.engineSessionId
        : typeof parsed.claudeSessionId === 'string'
          ? parsed.claudeSessionId
          : undefined,
      ...(Number.isSafeInteger(parsed.nativeHistoryStart)
        && parsed.nativeHistoryStart! >= 0 && parsed.nativeHistoryStart! <= parsed.messages.length
        ? { nativeHistoryStart: parsed.nativeHistoryStart } : {}),
      sandboxMode: isCodexSandboxMode(parsed.sandboxMode)
        ? parsed.sandboxMode
        : undefined,
      permissionMode: isPermissionMode(parsed.permissionMode) ? parsed.permissionMode : 'auto',
      pendingPermissions: Array.isArray(parsed.pendingPermissions)
        ? parsed.pendingPermissions.filter(isTranscriptPermissionRequest)
        : [],
      sessionInfo: isRecord(parsed.sessionInfo) ? parsed.sessionInfo as ClaudeSessionInfo : {},
      messages: parsed.messages.filter(isTranscriptMessage).map(message => {
        const { native, nativePrompt, nativeLocalOnly, ...rest } = message;
        const validBinding = message.role === 'user' && isRecord(native)
          && Array.isArray(native.ids) && native.ids.length > 0
          && native.ids.every(id => typeof id === 'string' && id.length > 0)
          && typeof native.hash === 'string' && /^[a-f0-9]{64}$/.test(native.hash);
        return {
          ...rest,
          ...(validBinding ? { native: native as NativeBinding } : {}),
          ...(typeof nativePrompt === 'string' ? { nativePrompt } : {}),
          ...(nativeLocalOnly === true ? { nativeLocalOnly: true } : {}),
        };
      }),
    };
  } catch {
    return emptySnapshot();
  }
}

function activityMessage(activity: ClaudeActivity, previous?: TranscriptMessage): TranscriptMessage {
  return {
    role: 'activity',
    text: activityLabel(activity),
    activityId: activity.id,
    activityKind: activity.kind,
    activityState: activity.state,
    activityTool: activity.toolName ?? previous?.activityTool,
    activityDetail: activity.detail ?? previous?.activityDetail,
    activityDurationMs: activity.durationMs ?? previous?.activityDurationMs,
  };
}

function activityLabel(activity: ClaudeActivity): string {
  if (activity.kind === 'thinking') return activity.state === 'running' ? '正在思考' : '思考完成';
  const action = activity.toolName ? `调用 ${activity.toolName}` : '调用工具';
  if (activity.state === 'running') return `正在${action}`;
  if (activity.state === 'error') return `${action}失败`;
  return `已${action}`;
}

function currentTurnStart(messages: TranscriptMessage[]): number {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index].role === 'user') return index + 1;
  }
  return 0;
}

function finishActivities(
  messages: TranscriptMessage[],
  status: 'done' | 'error' | 'stopped',
  kind?: ClaudeActivity['kind'],
): void {
  for (let index = currentTurnStart(messages); index < messages.length; index += 1) {
    const message = messages[index];
    if (message.role !== 'activity' || message.activityState !== 'running'
        || (kind && message.activityKind !== kind)) continue;
    const label = message.activityKind === 'thinking' ? '思考' : '工具执行';
    messages[index] = {
      ...message,
      activityState: status,
      text: status === 'done' ? `${label}完成`
        : status === 'error' ? `${label}失败` : `${label}已停止`,
    };
  }
}

function hasAssistantReplyAfterLastUser(messages: TranscriptMessage[]): boolean {
  let lastUser = -1;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index].role === 'user') {
      lastUser = index;
      break;
    }
  }
  return (
    lastUser < 0 ||
    messages
      .slice(lastUser + 1)
      .some(message => message.role === 'assistant'
        && (message.text.trim().length > 0 || Boolean(message.attachments?.length)))
  );
}

function cloneSnapshot(snapshot: TranscriptSnapshot): TranscriptSnapshot {
  return structuredClone(snapshot);
}

function isTranscriptMessage(value: unknown): value is TranscriptMessage {
  if (!isRecord(value) || typeof value.text !== 'string') return false;
  if (value.attachments !== undefined
    && (!Array.isArray(value.attachments) || !value.attachments.every(isAttachmentDescriptor))) {
    return false;
  }
  return value.role === 'user' || value.role === 'assistant' || value.role === 'system' || value.role === 'activity';
}

function isAttachmentDescriptor(value: unknown): value is AttachmentDescriptor {
  return isRecord(value)
    && typeof value.id === 'string'
    && typeof value.name === 'string'
    && typeof value.mimeType === 'string'
    && typeof value.size === 'number'
    && (value.source === undefined || typeof value.source === 'string');
}

function isTranscriptPermissionRequest(value: unknown): value is TranscriptPermissionRequest {
  return isRecord(value) && typeof value.requestId === 'string' && typeof value.toolName === 'string';
}

function isPermissionMode(value: unknown): value is ClaudePermissionMode {
  return value === 'manual'
    || value === 'acceptEdits'
    || value === 'auto'
    || value === 'dontAsk'
    || value === 'plan'
    || value === 'bypassPermissions';
}

function isCodexSandboxMode(value: unknown): value is CodexSandboxMode {
  return value === 'read-only'
    || value === 'workspace-write'
    || value === 'danger-full-access';
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
