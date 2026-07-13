import { randomUUID } from 'node:crypto';
import { access, copyFile, mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { createTranscriptState, type TranscriptSnapshot, type TranscriptState } from './transcriptState.js';

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
  createdAt: number;
  updatedAt: number;
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
};

export type ProjectSessionCatalog = {
  version: typeof SCHEMA_VERSION;
  activeProjectId: string;
  activeSessionId: string;
  projects: ProjectSummary[];
  sessions: SessionSummary[];
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
  registerProject(path: string, name?: string): Promise<ProjectSessionCatalog>;
  createSession(projectId: string, title?: string): Promise<SessionContext>;
  selectSession(sessionId: string): Promise<SessionContext>;
  setSessionTitleFromPrompt(sessionId: string, prompt: string): Promise<void>;
  flush(): Promise<void>;
};

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

  async function saveCatalog(): Promise<void> {
    const snapshot = structuredClone(catalog);
    const write = saveQueue.catch(() => undefined).then(async () => {
      await mkdir(dirname(catalogPath), { recursive: true });
      const tmp = `${catalogPath}.${process.pid}.${tmpCounter += 1}.tmp`;
      await writeFile(tmp, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
      await rename(tmp, catalogPath);
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

  async function createSessionRecord(projectId: string, title = '新会话'): Promise<SessionContext> {
    const project = catalog.projects.find(item => item.id === projectId);
    if (!project) throw new Error('project_not_found');
    const now = Date.now();
    const session: StoredSession = {
      id: randomUUID(),
      projectId,
      title,
      createdAt: now,
      updatedAt: now,
    };
    catalog.sessions.push(session);
    catalog.activeProjectId = projectId;
    catalog.activeSessionId = session.id;
    project.updatedAt = now;
    await saveCatalog();
    return { project, session, transcript: await loadTranscript(session.id) };
  }

  if (catalog.projects.length === 0) {
    const project = newProject(options.initialWorkspace);
    catalog.projects.push(project);
    const now = Date.now();
    const session: StoredSession = {
      id: randomUUID(),
      projectId: project.id,
      title: '当前会话',
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
      .sort((a, b) => b.updatedAt - a.updatedAt);
    const projects = catalog.projects
      .map(project => ({
        ...project,
        sessionCount: sessions.filter(session => session.projectId === project.id).length,
        running: sessions.some(session => session.projectId === project.id && session.running),
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
          .filter(item => item.projectId === project!.id)
          .sort((a, b) => b.updatedAt - a.updatedAt)[0];
        if (latest) catalog.activeSessionId = latest.id;
        else await createSessionRecord(project.id);
        await saveCatalog();
      }
      return snapshotCatalog();
    },

    createSession: createSessionRecord,

    async selectSession(sessionId: string): Promise<SessionContext> {
      const context = getSessionContext(sessionId);
      if (!context) throw new Error('session_not_found');
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
      if (context.session.title === '新会话' || context.session.title === '当前会话') {
        context.session.title = prompt.replace(/\s+/g, ' ').trim().slice(0, 36) || '新会话';
      }
      context.session.updatedAt = now;
      context.project.updatedAt = now;
      await saveCatalog();
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
  return {
    ...session,
    updatedAt: Math.max(session.updatedAt, snapshot?.updatedAt ?? 0),
    running: snapshot?.running === true,
    messageCount: snapshot?.messages.length ?? 0,
    model: snapshot?.sessionInfo.model,
    remainingTokens: snapshot?.sessionInfo.remainingTokens,
  };
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
      sessions: parsed.sessions.filter(isSession),
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

function isSession(value: unknown): value is StoredSession {
  return isRecord(value)
    && typeof value.id === 'string'
    && typeof value.projectId === 'string'
    && typeof value.title === 'string'
    && typeof value.createdAt === 'number'
    && typeof value.updatedAt === 'number';
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
