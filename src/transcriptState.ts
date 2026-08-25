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

const SCHEMA_VERSION = 1;
const SAVE_DELAY_MS = 200;
const INTERRUPTED_MESSAGE = '电脑端重启，任务已中断';

export type TranscriptMessage = {
  role: 'user' | 'assistant' | 'system' | 'activity';
  text: string;
  attachments?: AttachmentDescriptor[];
  activityId?: string;
  activityKind?: ClaudeActivity['kind'];
  activityState?: ClaudeActivity['state'] | 'stopped';
  activityTool?: string;
  activityDetail?: string;
};

export type TranscriptSnapshot = {
  version: typeof SCHEMA_VERSION;
  revision: number;
  running: boolean;
  updatedAt: number;
  engineSessionId?: string;
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
  ): void;
  appendText(text: string): void;
  mergeActivity(activity: ClaudeActivity): void;
  setSessionInfo(info: ClaudeSessionInfo): void;
  setEngineSessionId(sessionId: string | undefined): void;
  addPermission(request: ClaudePermissionRequest): void;
  removePermission(requestId: string): void;
  finishDone(): Promise<void>;
  finishStopped(): Promise<void>;
  finishError(message: string): Promise<void>;
  clear(): Promise<void>;
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

  async function saveNow(): Promise<void> {
    const snapshot = cloneSnapshot(state);
    const write = saveQueue.catch(() => undefined).then(async () => {
      await mkdir(dirname(statePath), { recursive: true });
      const tmp = `${statePath}.${process.pid}.${tmpCounter += 1}.tmp`;
      await writeFile(tmp, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
      await rename(tmp, statePath);
    });
    saveQueue = write;
    await write;
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
    if (state.sandboxMode === 'danger-full-access') state.sandboxMode = 'read-only';
    state.pendingPermissions = [];
    state.messages = state.messages.filter(message => message.role !== 'activity');
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
        state.messages.push({ role: 'assistant', text: nextText });
      });
    },

    mergeActivity(activity: ClaudeActivity): void {
      if (!state.running || activity.kind === 'summary') return;
      mutate(() => {
        if (activity.kind === 'thinking' && activity.state === 'running') {
          const existingThinking = state.messages.findIndex(message =>
            message.role === 'activity' && message.activityKind === 'thinking');
          if (existingThinking < 0) {
            state.messages.push(activityMessage(activity));
          }
          return;
        }
        const index = state.messages.findIndex(message =>
          message.role === 'activity' && message.activityId === activity.id);
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
        state.engineSessionId = sessionId;
      });
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
        if (state.sandboxMode === 'danger-full-access') state.sandboxMode = 'read-only';
        state.pendingPermissions = [];
        removeActivities(state.messages);
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
        if (state.sandboxMode === 'danger-full-access') state.sandboxMode = 'read-only';
        state.pendingPermissions = [];
        removeActivities(state.messages);
        state.messages.push({ role: 'system', text: '已停止' });
      });
      await flush();
    },

    async finishError(message: string): Promise<void> {
      if (!state.running) return flush();
      clearPendingAssistantPrefix(pending);
      mutate(() => {
        state.running = false;
        if (state.sandboxMode === 'danger-full-access') state.sandboxMode = 'read-only';
        state.pendingPermissions = [];
        removeActivities(state.messages);
        state.messages.push({ role: 'system', text: `错误：${message}` });
      });
      await flush();
    },

    async clear(): Promise<void> {
      clearPendingAssistantPrefix(pending);
      mutate(() => {
        state.running = false;
        state.engineSessionId = undefined;
        state.permissionMode = 'auto';
        state.sandboxMode = undefined;
        state.pendingPermissions = [];
        state.sessionInfo = {};
        state.messages = [];
      });
      await flush();
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
      sandboxMode: isCodexSandboxMode(parsed.sandboxMode)
        ? parsed.sandboxMode
        : undefined,
      permissionMode: isPermissionMode(parsed.permissionMode) ? parsed.permissionMode : 'auto',
      pendingPermissions: Array.isArray(parsed.pendingPermissions)
        ? parsed.pendingPermissions.filter(isTranscriptPermissionRequest)
        : [],
      sessionInfo: isRecord(parsed.sessionInfo) ? parsed.sessionInfo as ClaudeSessionInfo : {},
      messages: parsed.messages.filter(isTranscriptMessage),
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
  };
}

function activityLabel(activity: ClaudeActivity): string {
  if (activity.kind === 'thinking') return activity.state === 'running' ? '正在思考' : '思考完成';
  const action = activity.toolName ? `调用 ${activity.toolName}` : '调用工具';
  if (activity.state === 'running') return `正在${action}`;
  if (activity.state === 'error') return `${action}失败`;
  return `已${action}`;
}

function removeActivities(messages: TranscriptMessage[]): void {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index].role === 'activity') messages.splice(index, 1);
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
      .some(message => message.role === 'assistant' && message.text.trim().length > 0)
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
    && typeof value.size === 'number';
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
