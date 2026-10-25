export type AgentEngine = 'claude' | 'codex';

export type ClaudePermissionMode =
  | 'manual'
  | 'acceptEdits'
  | 'auto'
  | 'dontAsk'
  | 'plan'
  | 'bypassPermissions';

export type CodexSandboxMode =
  | 'read-only'
  | 'workspace-write'
  | 'danger-full-access';

export type EngineEffortLevel =
  | 'auto'
  | 'low'
  | 'medium'
  | 'high'
  | 'xhigh'
  | 'max';

export type EnginePermissionRequest = {
  requestId: string;
  toolName: string;
  input: Record<string, unknown>;
  detail?: string;
  title?: string;
  displayName?: string;
  description?: string;
  decisionReason?: string;
};

export type EngineActivity = {
  id: string;
  kind: 'thinking' | 'tool' | 'summary';
  state: 'running' | 'done' | 'error';
  toolName?: string;
  detail?: string;
  durationMs?: number;
  numTurns?: number;
  permissionDenials?: number;
};

export type EngineSessionInfo = {
  model?: string;
  contextWindow?: number;
  usedTokens?: number;
  remainingTokens?: number;
};

export type EngineRunOptions = {
  prompt: string;
  sessionId?: string;
  model?: string;
  effort?: EngineEffortLevel;
  additionalDirectories?: string[];
  imagePaths?: string[];
  permissionMode: ClaudePermissionMode;
  sandboxMode?: CodexSandboxMode;
  onEvent: (event: unknown) => void;
  onText: (text: string) => void;
  onSessionId: (sessionId: string) => void;
  onPrompt?: (prompt: string) => void;
  onPermissionRequest?: (request: EnginePermissionRequest) => void;
  onPermissionClosed?: (requestId: string) => void;
};

export type EngineRunResult = {
  exitCode: number | null;
  stopped: boolean;
  sessionId?: string;
  stderr: string;
};

export interface EngineBridge {
  isRunning(): boolean;
  respondToPermission(requestId: string, decision: 'allow' | 'deny'): boolean;
  run(options: EngineRunOptions): Promise<EngineRunResult>;
  stop(): boolean;
  close(): void;
}

export function isAgentEngine(value: unknown): value is AgentEngine {
  return value === 'claude' || value === 'codex';
}

export function normalizeAgentEngine(
  value: unknown,
  fallback: AgentEngine = 'claude',
): AgentEngine {
  if (value === undefined || value === null || value === '') return fallback;
  if (!isAgentEngine(value)) throw new Error('invalid_engine');
  return value;
}

export function normalizeEngineModel(value: unknown): string | undefined {
  if (value === undefined || value === null || value === '') return undefined;
  if (typeof value !== 'string') throw new Error('invalid_model');
  const model = value.trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/.test(model)) {
    throw new Error('invalid_model');
  }
  return model;
}

export function normalizeEngineEffort(value: unknown): EngineEffortLevel | undefined {
  if (value === undefined || value === null || value === '') return undefined;
  if (typeof value !== 'string') throw new Error('invalid_effort');
  if (!['auto', 'low', 'medium', 'high', 'xhigh', 'max'].includes(value)) {
    throw new Error('invalid_effort');
  }
  return value as EngineEffortLevel;
}

export function isClaudePermissionMode(value: unknown): value is ClaudePermissionMode {
  return value === 'manual'
    || value === 'acceptEdits'
    || value === 'auto'
    || value === 'dontAsk'
    || value === 'plan'
    || value === 'bypassPermissions';
}

export function normalizeCodexSandboxMode(value: unknown): CodexSandboxMode {
  if (value === undefined || value === null || value === '') {
    return 'danger-full-access';
  }
  if (value === 'manual') return 'read-only';
  if (value === 'read-only'
    || value === 'workspace-write'
    || value === 'danger-full-access') {
    return value;
  }
  throw new Error('invalid_permission_mode');
}
