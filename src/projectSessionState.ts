import { randomUUID } from 'node:crypto';
import { access, copyFile, mkdir, readFile, realpath, rename, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { createTranscriptState, type TranscriptSnapshot, type TranscriptState } from './transcriptState.js';
import { isAgentEngine, type AgentEngine } from './engineBridge.js';
import { canonicalDirectory } from './directoryService.js';

const SCHEMA_VERSION = 1;

type StoredProject = {
  id: string;
  name: string;
  path: string;
  createdAt: number;
  updatedAt: number;
};

type StoredSession = {
  id: string;
  projectId: string;
  title: string;
  engine: AgentEngine;
  createdAt: number;
  updatedAt: number;
  archivedAt?: number;
  pinned?: boolean;
};

type StoredCatalog = {
  version: typeof SCHEMA_VERSION;
  activeProjectId?: string;
  activeSessionId?: string;
  projects: StoredProject[];
  sessions: StoredSession[];
};

export type ProjectSummary = StoredProject & {
  sessionCount: number;
  running: boolean;
};

export type SessionSummary = StoredSession & {
  running: boolean;
  messageCount: number;
  model?: string;
  remainingTokens?: number;
  archived: boolean;
  preview?: string;
  needsAttention: boolean;
};

export type ProjectSessionCatalog = {
  version: typeof SCHEMA_VERSION;
  activeProjectId: string;
  activeSessionId: string;
  projects: ProjectSummary[];
  sessions: SessionSummary[];
};

export type SessionSearchResult = {
  sessionId: string;
  projectId: string;
  title: string;
  engine: AgentEngine;
  updatedAt: number;
  archived: boolean;
  role: 'title' | 'user' | 'assistant';
  messageIndex: number;
  snippet: string;
  matchStart: number;
  matchEnd: number;
  matchCount: number;
};

export type SessionContext = {
  project: StoredProject;
  session: StoredSession;
  transcript: TranscriptState;
};

export type ProjectSessionState = {
  catalog(): ProjectSessionCatalog;
  active(): SessionContext;
  getSession(sessionId: string): SessionContext | undefined;
  searchSessions(query: string, limit?: number, filters?: { projectId?: string; engine?: AgentEngine; archived?: boolean }): SessionSearchResult[];
  registerProject(path: string, name?: string): Promise<ProjectSessionCatalog>;
  createSession(projectId: string, title?: string, engine?: AgentEngine): Promise<SessionContext>;
  createSessionAtDirectory(path: unknown, engine: AgentEngine): Promise<SessionContext>;
  selectSession(sessionId: string): Promise<SessionContext>;
  setSessionTitleFromPrompt(sessionId: string, prompt: string): Promise<void>;
  setSessionTitle(sessionId: string, title: string): Promise<SessionContext>;
  archiveSession(sessionId: string): Promise<SessionContext>;
  restoreSession(sessionId: string): Promise<void>;
  setSessionPinned(sessionId: string, pinned: boolean): Promise<void>;
  deleteSession(sessionId: string): Promise<{ catalog: ProjectSessionCatalog; deletedSessionId: string }>;
  flush(): Promise<void>;
};

export function titleFromPrompt(prompt: string, maxLength = 48): string {
  const firstLine = prompt
    .split(/\r?\n/)
    .map(line => line.replace(/\s+/g, ' ').trim())
    .find(line => line.length > 0) || '';
  return firstLine.slice(0, maxLength) || '新会话';
}

function isDefaultTitle(title: string): boolean {
  return title === '新会话' || title === '当前会话' || title.trim().length === 0;
}

export async function createProjectSessionState(options: {
  dataDir?: string;
  initialWorkspace: string;
}): Promise<ProjectSessionState> {
  const dataDir = options.dataDir ?? join(process.cwd(), '.data');
  const catalogPath = join(dataDir, 'projects.json');
  const sessionsDir = join(dataDir, 'sessions');
  const legacyTranscriptPath = join(dataDir, 'transcript.json');
  let catalog = await loadCatalog(catalogPath);
  let saveQueue = Promise.resolve();
  let tmpCounter = 0;
  const transcripts = new Map<string, TranscriptState>();

  async function saveCatalog(value: StoredCatalog = catalog): Promise<void> {
    const snapshot = structuredClone(value);
    const write = saveQueue.catch(() => undefined).then(async () => {
      await mkdir(dirname(catalogPath), { recursive: true });
      const tmp = `${catalogPath}.${process.pid}.${tmpCounter += 1}.tmp`;
      try {
        await writeFile(tmp, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
        await rename(tmp, catalogPath);
      } finally {
        await rm(tmp, { force: true }).catch(() => undefined);
      }
    });
    saveQueue = write;
    await write;
  }

  async function loadTranscript(sessionId: string): Promise<TranscriptState> {
    const existing = transcripts.get(sessionId);
    if (existing) return existing;
    const state = await createTranscriptState(join(sessionsDir, `${sessionId}.json`));
    transcripts.set(sessionId, state);
    return state;
  }

  async function createSessionRecord(
    projectId: string,
    title = '新会话',
    engine: AgentEngine = 'claude',
  ): Promise<SessionContext> {
    const next = structuredClone(catalog);
    const project = next.projects.find(item => item.id === projectId);
    if (!project) throw new Error('project_not_found');
    const now = Date.now();
    const session: StoredSession = {
      id: randomUUID(),
      projectId,
      title,
      engine,
      createdAt: now,
      updatedAt: now,
    };
    next.sessions.push(session);
    next.activeProjectId = projectId;
    next.activeSessionId = session.id;
    project.updatedAt = now;
    const transcript = await createTranscriptState(join(sessionsDir, `${session.id}.json`));
    try {
      await saveCatalog(next);
    } catch (error) {
      saveQueue = saveQueue.catch(() => undefined);
      throw error;
    }
    transcripts.set(session.id, transcript);
    catalog = next;
    return { project, session, transcript };
  }

  if (catalog.projects.length === 0) {
    const project = newProject(options.initialWorkspace);
    catalog.projects.push(project);
    const now = Date.now();
    const session: StoredSession = {
      id: randomUUID(),
      projectId: project.id,
      title: '当前会话',
      engine: 'claude',
      createdAt: now,
      updatedAt: now,
    };
    catalog.sessions.push(session);
    catalog.activeProjectId = project.id;
    catalog.activeSessionId = session.id;
    await mkdir(sessionsDir, { recursive: true });
    if (await exists(legacyTranscriptPath)) {
      await copyFile(legacyTranscriptPath, join(sessionsDir, `${session.id}.json`));
    }
    await saveCatalog();
  }

  if (!catalog.activeProjectId || !catalog.projects.some(item => item.id === catalog.activeProjectId)) {
    catalog.activeProjectId = catalog.projects[0].id;
  }
  if (!catalog.activeSessionId || !catalog.sessions.some(item => item.id === catalog.activeSessionId)) {
    const first = catalog.sessions.find(item => item.projectId === catalog.activeProjectId);
    if (first) catalog.activeSessionId = first.id;
    else catalog.activeSessionId = (await createSessionRecord(catalog.activeProjectId)).session.id;
  }

  for (const session of catalog.sessions) await loadTranscript(session.id);

  function getSessionContext(sessionId: string): SessionContext | undefined {
    const session = catalog.sessions.find(item => item.id === sessionId);
    if (!session) return undefined;
    const project = catalog.projects.find(item => item.id === session.projectId);
    const transcript = transcripts.get(session.id);
    if (!project || !transcript) return undefined;
    return { project, session, transcript };
  }

  function current(): SessionContext {
    const context = getSessionContext(catalog.activeSessionId || '');
    if (!context) throw new Error('active_session_not_found');
    return context;
  }

  function snapshotCatalog(): ProjectSessionCatalog {
    const sessions = catalog.sessions
      .map(session => sessionSummary(session, transcripts.get(session.id)?.snapshot()))
      .sort((a, b) => {
        if (a.archived !== b.archived) return a.archived ? 1 : -1;
        return b.updatedAt - a.updatedAt;
      });
    const projects = catalog.projects
      .map(project => ({
        ...project,
        sessionCount: sessions.filter(session =>
          session.projectId === project.id && !session.archived).length,
        running: sessions.some(session =>
          session.projectId === project.id && session.running && !session.archived),
      }))
      .sort((a, b) => b.updatedAt - a.updatedAt);
    return {
      version: SCHEMA_VERSION,
      activeProjectId: catalog.activeProjectId!,
      activeSessionId: catalog.activeSessionId!,
      projects,
      sessions,
    };
  }

  return {
    catalog: snapshotCatalog,
    active: current,
    getSession: getSessionContext,

    searchSessions(query: string, limit = 50, filters: { projectId?: string; engine?: AgentEngine; archived?: boolean } = {}): SessionSearchResult[] {
      const needle = query.trim();
      if (!needle) return [];
      const maxResults = Math.max(1, Math.min(Math.trunc(limit), 50));
      return catalog.sessions
        .filter(session => (!filters.projectId || session.projectId === filters.projectId)
          && (!filters.engine || session.engine === filters.engine)
          && (filters.archived === undefined || Boolean(session.archivedAt) === filters.archived))
        .map(session => {
          const snapshot = transcripts.get(session.id)?.snapshot();
          if (!snapshot) return undefined;
          let matchCount = 0;
          let bestMatch: ReturnType<typeof createSearchSnippet> | undefined;
          let bestRole: SessionSearchResult['role'] = 'title';
          let bestMessageIndex = -1;
          for (let index = snapshot.messages.length - 1; index >= 0; index -= 1) {
            const message = snapshot.messages[index];
            if (message.role !== 'user' && message.role !== 'assistant') continue;
            const match = createSearchSnippet(message.text, needle);
            if (!match) continue;
            matchCount += 1;
            if (!bestMatch) {
              bestMatch = match;
              bestRole = message.role;
              bestMessageIndex = index;
            }
          }
          const titleMatch = createSearchSnippet(session.title, needle);
          if (titleMatch) matchCount += 1;
          const chosen = bestMatch ?? titleMatch;
          if (!chosen) return undefined;
          return {
            sessionId: session.id,
            projectId: session.projectId,
            title: session.title,
            engine: session.engine,
            updatedAt: Math.max(session.updatedAt, snapshot.updatedAt),
            archived: typeof session.archivedAt === 'number',
            role: bestMatch ? bestRole : 'title',
            messageIndex: bestMatch ? bestMessageIndex : -1,
            ...chosen,
            matchCount,
          } satisfies SessionSearchResult;
        })
        .filter((result): result is SessionSearchResult => result !== undefined)
        .sort((a, b) => b.updatedAt - a.updatedAt)
        .slice(0, maxResults);
    },

    async registerProject(path: string, name?: string): Promise<ProjectSessionCatalog> {
      const canonicalPath = resolve(path);
      if (!(await stat(canonicalPath)).isDirectory()) throw new Error('workspace_not_directory');
      let project = catalog.projects.find(item => samePath(item.path, canonicalPath));
      if (!project) {
        project = newProject(canonicalPath, name);
        catalog.projects.push(project);
        await createSessionRecord(project.id);
      } else {
        project.name = cleanName(name) || project.name;
        project.updatedAt = Date.now();
        catalog.activeProjectId = project.id;
        const latest = catalog.sessions
          .filter(item => item.projectId === project!.id && !item.archivedAt)
          .sort((a, b) => b.updatedAt - a.updatedAt)[0];
        if (latest) catalog.activeSessionId = latest.id;
        else await createSessionRecord(project.id);
        await saveCatalog();
      }
      return snapshotCatalog();
    },

    createSession: createSessionRecord,

    async createSessionAtDirectory(path: unknown, engine: AgentEngine): Promise<SessionContext> {
      if (!isAgentEngine(engine)) throw new Error('invalid_engine');
      if (current().transcript.snapshot().running) throw new Error('claude_is_busy');
      const canonicalPath = await canonicalDirectory(path);
      let existing = catalog.projects.find(item => samePath(item.path, canonicalPath));
      if (!existing) {
        for (const project of catalog.projects) {
          const actual = await realpath(project.path).catch(() => undefined);
          if (actual && samePath(actual, canonicalPath)) { existing = project; break; }
        }
      }
      const next = structuredClone(catalog);
      const project = existing
        ? next.projects.find(item => item.id === existing.id)!
        : newProject(canonicalPath);
      if (!existing) next.projects.push(project);
      const now = Date.now();
      const session: StoredSession = {
        id: randomUUID(), projectId: project.id, title: '新会话', engine,
        createdAt: now, updatedAt: now,
      };
      next.sessions.push(session);
      next.activeProjectId = project.id;
      next.activeSessionId = session.id;
      project.updatedAt = now;
      const transcriptPath = join(sessionsDir, `${session.id}.json`);
      try {
        const transcript = await createTranscriptState(transcriptPath);
        await transcript.flush();
        await saveCatalog(next);
        transcripts.set(session.id, transcript);
        catalog = next;
        return { project, session, transcript };
      } catch (error) {
        saveQueue = saveQueue.catch(() => undefined);
        await rm(transcriptPath, { force: true }).catch(() => undefined);
        throw error;
      }
    },

    async selectSession(sessionId: string): Promise<SessionContext> {
      const context = getSessionContext(sessionId);
      if (!context) throw new Error('session_not_found');
      if (context.session.archivedAt) throw new Error('session_archived');
      catalog.activeProjectId = context.project.id;
      catalog.activeSessionId = context.session.id;
      context.project.updatedAt = Date.now();
      await saveCatalog();
      return context;
    },

    async setSessionTitleFromPrompt(sessionId: string, prompt: string): Promise<void> {
      const context = getSessionContext(sessionId);
      if (!context) return;
      const now = Date.now();
      if (isDefaultTitle(context.session.title)) {
        context.session.title = titleFromPrompt(prompt);
      }
      context.session.updatedAt = now;
      context.project.updatedAt = now;
      await saveCatalog();
    },

    async setSessionTitle(sessionId: string, title: string): Promise<SessionContext> {
      const context = getSessionContext(sessionId);
      if (!context) throw new Error('session_not_found');
      const cleaned = cleanName(title).slice(0, 48);
      if (!cleaned) throw new Error('title_required');
      const now = Date.now();
      context.session.title = cleaned;
      context.session.updatedAt = now;
      context.project.updatedAt = now;
      await saveCatalog();
      return context;
    },

    async archiveSession(sessionId: string): Promise<SessionContext> {
      const context = getSessionContext(sessionId);
      if (!context) throw new Error('session_not_found');
      if (context.transcript.snapshot().running) throw new Error('claude_is_busy');
      if (context.session.archivedAt) return current();
      const projectSessions = catalog.sessions.filter(item =>
        item.projectId === context.project.id && !item.archivedAt);
      if (projectSessions.length <= 1) throw new Error('last_session');
      const now = Date.now();
      const nextCatalog = structuredClone(catalog);
      const archived = nextCatalog.sessions.find(item => item.id === sessionId)!;
      archived.archivedAt = now;
      archived.updatedAt = now;
      nextCatalog.projects.find(item => item.id === context.project.id)!.updatedAt = now;
      if (catalog.activeSessionId === sessionId) {
        const next = catalog.sessions
          .filter(item => item.projectId === context.project.id && !item.archivedAt && item.id !== sessionId)
          .sort((a, b) => b.updatedAt - a.updatedAt)[0];
        if (!next) throw new Error('last_session');
        nextCatalog.activeSessionId = next.id;
      }
      await saveCatalog(nextCatalog);
      catalog = nextCatalog;
      return getSessionContext(catalog.activeSessionId!)!;
    },

    async restoreSession(sessionId: string): Promise<void> {
      if (!getSessionContext(sessionId)) throw new Error('session_not_found');
      const next = structuredClone(catalog);
      delete next.sessions.find(item => item.id === sessionId)!.archivedAt;
      await saveCatalog(next);
      catalog = next;
    },

    async setSessionPinned(sessionId: string, pinned: boolean): Promise<void> {
      if (!getSessionContext(sessionId)) throw new Error('session_not_found');
      const next = structuredClone(catalog);
      next.sessions.find(item => item.id === sessionId)!.pinned = pinned;
      await saveCatalog(next);
      catalog = next;
    },

    async deleteSession(sessionId: string): Promise<{ catalog: ProjectSessionCatalog; deletedSessionId: string }> {
      const context = getSessionContext(sessionId);
      if (!context) throw new Error('session_not_found');
      if (context.transcript.snapshot().running) throw new Error('claude_is_busy');
      const projectId = context.project.id;
      const now = Date.now();
      const next: StoredCatalog = {
        ...catalog,
        projects: catalog.projects.map(item => item.id === projectId ? { ...item, updatedAt: now } : item),
        sessions: catalog.sessions.filter(item => item.id !== sessionId),
      };
      const remainingInProject = next.sessions.filter(item => item.projectId === projectId && !item.archivedAt);
      let replacement: StoredSession | undefined;
      let replacementTranscript: TranscriptState | undefined;
      if (remainingInProject.length === 0) {
        replacement = {
          id: randomUUID(), projectId, title: '新会话', engine: context.session.engine,
          createdAt: now, updatedAt: now,
        };
        replacementTranscript = await createTranscriptState(join(sessionsDir, `${replacement.id}.json`));
        next.sessions.push(replacement);
        remainingInProject.push(replacement);
      }
      if (next.activeSessionId === sessionId) {
        next.activeProjectId = projectId;
        next.activeSessionId = remainingInProject.sort((a, b) => b.updatedAt - a.updatedAt)[0].id;
      }
      await context.transcript.flush();
      try {
        await saveCatalog(next);
      } catch (error) {
        saveQueue = saveQueue.catch(() => undefined);
        throw error;
      }
      if (replacement && replacementTranscript) transcripts.set(replacement.id, replacementTranscript);
      catalog = next;
      transcripts.delete(sessionId);
      await rm(join(sessionsDir, `${sessionId}.json`), { force: true }).catch(() => undefined);
      return { catalog: snapshotCatalog(), deletedSessionId: sessionId };
    },

    async flush(): Promise<void> {
      await Promise.all([...transcripts.values()].map(item => item.flush()));
      await saveQueue;
    },
  };
}

function newProject(path: string, name?: string): StoredProject {
  const canonicalPath = resolve(path);
  const now = Date.now();
  return {
    id: randomUUID(),
    name: cleanName(name) || basename(canonicalPath) || canonicalPath,
    path: canonicalPath,
    createdAt: now,
    updatedAt: now,
  };
}

function sessionSummary(session: StoredSession, snapshot?: TranscriptSnapshot): SessionSummary {
  let preview: string | undefined;
  const messages = snapshot?.messages ?? [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if ((message.role === 'user' || message.role === 'assistant') && message.text.trim()) {
      preview = message.text.replace(/\s+/g, ' ').trim().slice(0, 160);
      break;
    }
  }
  return {
    ...session,
    updatedAt: Math.max(session.updatedAt, snapshot?.updatedAt ?? 0),
    running: snapshot?.running === true,
    messageCount: snapshot?.messages.length ?? 0,
    model: snapshot?.sessionInfo.model,
    remainingTokens: snapshot?.sessionInfo.remainingTokens,
    archived: typeof session.archivedAt === 'number',
    pinned: session.pinned === true,
    preview,
    needsAttention: (snapshot?.pendingPermissions.length ?? 0) > 0,
  };
}

function createSearchSnippet(
  text: string,
  needle: string,
): Pick<SessionSearchResult, 'snippet' | 'matchStart' | 'matchEnd'> | undefined {
  const normalized = text.replace(/\s+/g, ' ').trim();
  const match = new RegExp(escapeSearchPattern(needle), 'iu').exec(normalized);
  if (!match) return undefined;
  const matchIndex = match.index;
  const matchLength = match[0].length;
  const contextBefore = 44;
  const contextAfter = 72;
  const sliceStart = Math.max(0, matchIndex - contextBefore);
  const sliceEnd = Math.min(normalized.length, matchIndex + matchLength + contextAfter);
  const hasPrefix = sliceStart > 0;
  const hasSuffix = sliceEnd < normalized.length;
  const snippet = `${hasPrefix ? '…' : ''}${normalized.slice(sliceStart, sliceEnd)}${hasSuffix ? '…' : ''}`;
  const matchStart = (hasPrefix ? 1 : 0) + matchIndex - sliceStart;
  return {
    snippet,
    matchStart,
    matchEnd: matchStart + matchLength,
  };
}

function escapeSearchPattern(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function loadCatalog(path: string): Promise<StoredCatalog> {
  try {
    const parsed = JSON.parse(await readFile(path, 'utf8')) as Partial<StoredCatalog>;
    if (parsed.version !== SCHEMA_VERSION || !Array.isArray(parsed.projects) || !Array.isArray(parsed.sessions)) {
      return emptyCatalog();
    }
    return {
      version: SCHEMA_VERSION,
      activeProjectId: typeof parsed.activeProjectId === 'string' ? parsed.activeProjectId : undefined,
      activeSessionId: typeof parsed.activeSessionId === 'string' ? parsed.activeSessionId : undefined,
      projects: parsed.projects.filter(isProject),
      sessions: parsed.sessions
        .filter(isSession)
        .map(session => ({
          ...session,
          engine: isAgentEngine(session.engine) ? session.engine : 'claude',
          pinned: session.pinned === true,
        })),
    };
  } catch {
    return emptyCatalog();
  }
}

function emptyCatalog(): StoredCatalog {
  return { version: SCHEMA_VERSION, projects: [], sessions: [] };
}

function isProject(value: unknown): value is StoredProject {
  return isRecord(value)
    && typeof value.id === 'string'
    && typeof value.name === 'string'
    && typeof value.path === 'string'
    && typeof value.createdAt === 'number'
    && typeof value.updatedAt === 'number';
}

function isSession(
  value: unknown,
): value is Omit<StoredSession, 'engine'> & { engine?: unknown } {
  if (!(isRecord(value)
    && typeof value.id === 'string'
    && typeof value.projectId === 'string'
    && typeof value.title === 'string'
    && typeof value.createdAt === 'number'
    && typeof value.updatedAt === 'number')) {
    return false;
  }
  if (value.archivedAt !== undefined && typeof value.archivedAt !== 'number') return false;
  return true;
}

function cleanName(value: string | undefined): string {
  return value?.replace(/\s+/g, ' ').trim().slice(0, 64) || '';
}

function samePath(a: string, b: string): boolean {
  return process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
}

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
