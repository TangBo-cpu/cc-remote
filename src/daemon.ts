import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { hostname } from 'node:os';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { delimiter, extname, join } from 'node:path';
import qrcode from 'qrcode-terminal';
import WebSocket, { WebSocketServer } from 'ws';
import { createAuthState, DEFAULT_MAX_PAIRED_DEVICES, type PairingPayload } from './authState.js';
import { createLocalControlState } from './localControlState.js';
import { createPairingQr } from './pairingQr.js';
import {
  createProjectSessionState,
  type SessionContext,
} from './projectSessionState.js';
import { WorkspaceService } from './workspaceService.js';
import { browseDirectories, DirectoryError } from './directoryService.js';
import {
  AttachmentStore,
  attachmentDescriptor,
  promptWithAttachments,
  type StoredAttachment,
} from './attachmentStore.js';
import { readAttachments } from './attachmentUpload.js';
import { collectReplyImages } from './replyImages.js';
import {
  ClaudeBridge,
  discoverClaudeCommands,
  extractClaudeActivities,
  extractClaudeCommands,
  extractClaudeSessionInfo,
  isMissingConversationError,
  mergeClaudeSessionInfo,
  restoreClaudeSessionInfo,
  type ClaudeActivity,
  type ClaudePermissionMode,
  type ClaudePermissionRequest,
  type ClaudeSessionInfo,
} from './claudeBridge.js';
import {
  CodexBridge,
  extractCodexActivities,
  extractCodexSessionInfo,
} from './codexBridge.js';
import {
  isAgentEngine,
  normalizeAgentEngine,
  normalizeCodexSandboxMode,
  normalizeEngineEffort,
  normalizeEngineModel,
  type AgentEngine,
  type CodexSandboxMode,
  type EngineBridge,
} from './engineBridge.js';
import { createRunFlight } from './runFlight.js';
import { ClaudeHistoryReader, syncClaudeSessionHistory } from './claudeSessionHistory.js';

const HOST = process.env.HOST || '127.0.0.1';
const PORT = Number(process.env.PORT || 8787);
const PUBLIC_ORIGIN = (process.env.PUBLIC_ORIGIN || `http://${HOST}:${PORT}`).replace(/\/+$/, '');
const WORKSPACE_DIR = process.env.WORKSPACE_DIR || process.cwd();
const CLAUDE_BIN = process.env.CLAUDE_BIN || 'claude';
// ponytail: test/fixture only — pipe-separated argv before Claude flags
const CLAUDE_ARGS = process.env.CLAUDE_ARGS
  ? process.env.CLAUDE_ARGS.split('|').filter(Boolean)
  : undefined;
const DEFAULT_CODEX = defaultCodexCommand();
const CODEX_BIN = process.env.CODEX_BIN || DEFAULT_CODEX.bin;
const CODEX_ARGS = [
  ...(process.env.CODEX_BIN ? [] : DEFAULT_CODEX.args),
  ...(process.env.CODEX_ARGS
    ? process.env.CODEX_ARGS.split('|').filter(Boolean)
    : []),
];
const DEVICE_NAME = process.env.DEVICE_NAME || hostname();
const ALLOW_BYPASS_PERMISSIONS = process.env.ALLOW_BYPASS_PERMISSIONS !== '0';

function readBoundedIntEnv(
  name: string,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    console.warn(
      `[config] ${name} must be an integer in [${minimum}, ${maximum}]; using ${fallback}`,
    );
    return fallback;
  }
  return value;
}

const MAX_BODY_BYTES = 64 * 1024;
const MAX_WS_BUFFERED_BYTES = 8 * 1024 * 1024;
const MAX_WS_CONNECTIONS = readBoundedIntEnv(
  'MAX_WS_CONNECTIONS',
  16,
  1,
  64,
);
const MAX_PAIRED_DEVICES = readBoundedIntEnv(
  'MAX_PAIRED_DEVICES',
  DEFAULT_MAX_PAIRED_DEVICES,
  1,
  16,
);
const WS_AUTH_TIMEOUT_MS = readBoundedIntEnv(
  'WS_AUTH_TIMEOUT_MS',
  10_000,
  1_000,
  60_000,
);
const WS_HEARTBEAT_INTERVAL_MS = readBoundedIntEnv(
  'WS_HEARTBEAT_INTERVAL_MS',
  30_000,
  1_000,
  120_000,
);
const WS_CLOSE_TIMEOUT_MS = readBoundedIntEnv(
  'WS_CLOSE_TIMEOUT_MS',
  1_000,
  100,
  10_000,
);

function defaultCodexCommand(): { bin: string; args: string[] } {
  if (process.platform !== 'win32') return { bin: 'codex', args: [] };
  for (const entry of (process.env.PATH || '').split(delimiter)) {
    const directory = entry.replace(/^"|"$/g, '');
    if (!directory) continue;
    const launcher = join(
      directory,
      'node_modules',
      '@openai',
      'codex',
      'bin',
      'codex.js',
    );
    if (existsSync(launcher)) return { bin: process.execPath, args: [launcher] };
  }
  return { bin: 'codex', args: [] };
}

const publicUrl = new URL(PUBLIC_ORIGIN);
const auth = await createAuthState(undefined, MAX_PAIRED_DEVICES);
const localControl = await createLocalControlState();
const projectSessions = await createProjectSessionState({ initialWorkspace: WORKSPACE_DIR });
// Align cold start with "cc-remote already running" register path: activate WORKSPACE_DIR.
await projectSessions.registerProject(WORKSPACE_DIR);
for (const session of projectSessions.catalog().sessions) {
  const context = projectSessions.getSession(session.id);
  if (context) await syncNativeClaudeHistory(context);
}
const attachments = new AttachmentStore();
let activeContext = projectSessions.active();
let workspace = new WorkspaceService(activeContext.project.path);
let bridge = createBridge(activeContext.project.path, activeContext.session.engine);
const claudeHistoryReader = new ClaudeHistoryReader();
let historyBridge: CodexBridge | undefined;
const historyErrors = new Map<string, string>();
const replyImageRevisions = new WeakMap<SessionContext['transcript'], number>();
let nativeHistoryRefresh: Promise<void> | undefined;
// Serializes prompt/select/register across awaits; bridge.isRunning alone races.
const runFlight = createRunFlight(() => bridge.isRunning());
const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_BODY_BYTES });
const openSockets = new Set<WebSocket>();
const authedSockets = new Map<WebSocket, string>();
const wsAlive = new WeakMap<WebSocket, boolean>();
const wsCloseTimers = new WeakMap<WebSocket, NodeJS.Timeout>();
const wsLargePayloadBytes = new WeakMap<WebSocket, number>();
const wsHeartbeatTimer = setInterval(() => {
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.CLOSING) {
      client.terminate();
      continue;
    }
    if (client.readyState !== WebSocket.OPEN) continue;
    if (wsAlive.get(client) === false) {
      client.terminate();
      continue;
    }
    wsAlive.set(client, false);
    try {
      client.ping();
    } catch {
      client.terminate();
    }
  }
}, WS_HEARTBEAT_INTERVAL_MS);
wsHeartbeatTimer.unref?.();
const commandCaches = new Map<string, string[]>();
const commandDiscoveries = new Map<string, Promise<string[]>>();
const promptReceipts = new Map<string, PromptReceipt>();
const MAX_PROMPT_RECEIPTS = 256;
let nextRunId = 0;
let activeRunId: string | undefined;
let activeRunStartedAt: number | undefined;
let sessionInfo: ClaudeSessionInfo = activeContext.transcript.snapshot().sessionInfo;
await applyRestoredClaudeSessionInfo(
  activeContext,
  activeContext.transcript.snapshot().engineSessionId,
);

const server = createServer(async (req, res) => {
  try {
    if (shuttingDown) return sendJson(res, 503, { error: 'shutting_down' });
    if (!isAllowedHost(req)) return sendJson(res, 403, { error: 'bad_host' });

    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    if (url.pathname.startsWith('/api/')) {
      await handleApi(req, res, url);
      return;
    }

    if (req.method !== 'GET') return sendJson(res, 405, { error: 'method_not_allowed' });
    await serveStatic(res, url.pathname);
  } catch (err) {
    sendJson(res, 500, { error: err instanceof Error ? err.message : String(err) });
  }
});

server.on('upgrade', (req, socket, head) => {
  socket.on('error', () => socket.destroy());
  if (!isAllowedHost(req) || !isAllowedOrigin(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  let url: URL;
  try {
    url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  } catch {
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
    socket.destroy();
    return;
  }
  if (url.pathname !== '/ws') {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  if (openSockets.size >= MAX_WS_CONNECTIONS) {
    socket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n');
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, ws => {
    wss.emit('connection', ws, req);
  });
});

wss.on('connection', ws => {
  let authenticated = false;
  let authedDeviceId: string | null = null;
  openSockets.add(ws);
  wsAlive.set(ws, true);
  const authTimer = setTimeout(() => {
    if (!authenticated && ws.readyState === WebSocket.OPEN) {
      ws.close(1008, 'auth_timeout');
    }
  }, WS_AUTH_TIMEOUT_MS);
  authTimer.unref?.();

  const clearAuthTimer = () => {
    clearTimeout(authTimer);
  };

  ws.on('pong', () => {
    wsAlive.set(ws, true);
  });

  ws.on('error', () => {
    clearAuthTimer();
    if (ws.readyState !== WebSocket.CLOSED) ws.terminate();
  });

  ws.on('close', () => {
    clearAuthTimer();
    const closeTimer = wsCloseTimers.get(ws);
    if (closeTimer) clearTimeout(closeTimer);
    wsCloseTimers.delete(ws);
    wsAlive.delete(ws);
    openSockets.delete(ws);
    authedSockets.delete(ws);
  });

  ws.on('message', data => {
    if (shuttingDown) {
      ws.close(1001, 'shutting_down');
      return;
    }
    if (authenticated && !auth.isDeviceActive(authedDeviceId)) {
      ws.close(1008, 'authorization_expired');
      return;
    }
    void handleWsMessage(ws, data.toString('utf8'), {
      isAuthenticated: () => authenticated,
      authenticate: async token => {
        const deviceId = auth.verifyToken(token);
        if (!deviceId) return false;
        authenticated = true;
        authedDeviceId = deviceId;
        clearAuthTimer();
        auth.touchDevice(deviceId);
        await refreshNativeHistory(activeContext);
        if (!auth.isDeviceActive(deviceId) || ws.readyState !== WebSocket.OPEN) return false;
        authedSockets.set(ws, deviceId);
        sendStatus(ws, true);
        send(ws, { type: 'catalog', ...projectSessions.catalog() });
        const commands = commandCaches.get(commandCacheKey(activeContext)) || [];
        send(ws, sessionMessage({ type: 'commands', commands, loaded: commandCaches.has(commandCacheKey(activeContext)) }));
        if (activeContext.session.engine === 'claude') void refreshCommands().catch(() => {});
        if (Object.keys(sessionInfo).length) {
          send(ws, sessionMessage({ type: 'session_info', ...sessionInfo }));
        }
        send(ws, sessionMessage({
          type: 'transcript_snapshot',
          ...activeContext.transcript.snapshot(),
          ...taskStatus(activeContext),
        }, activeContext, activeRunId));
        send(ws, sessionMessage(permissionCapabilities(activeContext)));
        return true;
      },
    }).catch(err => {
      const message = err instanceof Error ? err.message : String(err);
      let envelope: Record<string, unknown> = {};
      try {
        const parsed = JSON.parse(data.toString('utf8')) as unknown;
        if (typeof parsed === 'object' && parsed !== null) {
          envelope = parsed as Record<string, unknown>;
        }
      } catch {}
      const requestedSessionId = envelope.sessionId;
      const context = typeof requestedSessionId === 'string'
        ? projectSessions.getSession(requestedSessionId)
        : activeContext;
      const promptId = typeof envelope.promptId === 'string'
        ? envelope.promptId
        : undefined;
      const receipt = promptId ? promptReceipts.get(promptId) : undefined;
      const errorData = {
        type: 'error',
        message,
        ...(promptId ? { promptId } : {}),
      };
      if (!authenticated) {
        send(ws, errorData);
      } else if (context) {
        send(ws, sessionMessage(errorData, context, receipt?.runId));
      } else {
        send(ws, {
          ...errorData,
          ...(typeof requestedSessionId === 'string'
            ? { sessionId: requestedSessionId }
            : {}),
        });
      }
      // Unauthenticated peers must not keep the socket after a bad first frame.
      if (!authenticated) {
        clearAuthTimer();
        ws.close(1008, message.slice(0, 64));
      }
    });
  });
});

let pairingPayload: PairingPayload;
let pairingQr: ReturnType<typeof createPairingQr> | undefined;
let shuttingDown = false;
const nativeHistoryTimer = setInterval(() => {
  if (!shuttingDown && authedSockets.size > 0) void refreshNativeHistory(activeContext);
}, 30_000);
nativeHistoryTimer.unref();

server.listen(PORT, HOST, () => {
  pairingPayload = auth.createPairingPayload(PUBLIC_ORIGIN, DEVICE_NAME);
  const pairQr = JSON.stringify(pairingPayload);
  console.log(`CC Remote listening on http://${HOST}:${PORT}`);
  console.log(`Workspace: ${activeContext.project.path}`);
  console.log(`Public origin: ${PUBLIC_ORIGIN}`);
  console.log(`Device name: ${DEVICE_NAME}`);
  if (process.env.CC_REMOTE_DESKTOP !== '1') {
    console.log('Scan this QR with the CC Remote mobile app:');
    console.log(pairQr);
    qrcode.generate(pairQr, { small: true });
  }
  if (activeContext.session.engine === 'claude') void refreshCommands().catch(() => {});
});

async function handleApi(req: IncomingMessage, res: ServerResponse, url: URL): Promise<void> {
  if (req.method !== 'GET' && nativeHistoryRefresh) await nativeHistoryRefresh;
  res.setHeader('Cache-Control', 'no-store');

  if (req.method === 'GET' && url.pathname === '/api/health') {
    sendJson(res, 200, { ok: true, service: 'cc-remote' });
    return;
  }

  if (url.pathname.startsWith('/api/local/')) {
    // Token alone is not enough: tunnel traffic also arrives from 127.0.0.1.
    if (!isLocalControlRequest(req)) {
      sendJson(res, 403, { error: 'local_only' });
      return;
    }
    if (!localControl.verify(headerValue(req, 'x-cc-remote-local-token'))) {
      sendJson(res, 401, { error: 'invalid_local_control_token' });
      return;
    }
    if (!isAllowedOrigin(req)) {
      sendJson(res, 403, { error: 'bad_origin' });
      return;
    }
  }

  if (req.method === 'GET' && url.pathname === '/api/local/status') {
    sendJson(res, 200, {
      ...auth.status(),
      ...taskStatus(activeContext),
      deviceName: DEVICE_NAME,
      workspaceDir: activeContext.project.path,
      publicOrigin: PUBLIC_ORIGIN,
      authGeneration: auth.getAuthGeneration(),
      processId: process.pid,
      connectedClients: authedSockets.size,
      pairing: !auth.status().paired && Date.now() < pairingPayload.expiresAt
        ? pairingQr ||= createPairingQr(pairingPayload) : null,
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/local/pairing') {
    pairingPayload = auth.createPairingPayload(PUBLIC_ORIGIN, DEVICE_NAME);
    pairingQr = createPairingQr(pairingPayload);
    sendJson(res, 200, pairingQr);
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/local/shutdown') {
    const body = await readJson<{ force?: boolean }>(req);
    if (runFlight.isBusy() && body.force !== true) {
      sendJson(res, 409, { error: 'claude_is_busy' });
      return;
    }
    shuttingDown = true;
    try {
      await projectSessions.flush();
    } catch (err) {
      shuttingDown = false;
      throw err;
    }
    sendJson(res, 200, { ok: true });
    bridge.close();
    historyBridge?.close();
    clearInterval(nativeHistoryTimer);
    clearInterval(wsHeartbeatTimer);
    closeAllSockets();
    server.close();
    setTimeout(() => {
      void projectSessions.flush().then(() => process.exit(0), () => process.exit(1));
    }, 2_000).unref();
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/local/projects/register') {
    if (!runFlight.tryBegin('mutate')) {
      sendJson(res, 409, { error: 'claude_is_busy' });
      return;
    }
    try {
      const body = await readJson<{ path?: string; name?: string }>(req);
      if (!body.path) return sendJson(res, 400, { error: 'workspace_required' });
      await projectSessions.registerProject(body.path, body.name);
      await selectActiveSession(projectSessions.active());
      broadcastCatalog();
      sendJson(res, 200, { ok: true, ...projectSessions.catalog() });
    } catch (err) {
      const code = err && typeof err === 'object' && 'code' in err ? String((err as { code?: unknown }).code) : '';
      const message = err instanceof Error ? err.message : String(err);
      if (code === 'ENOENT' || message === 'workspace_not_directory') {
        sendJson(res, 400, { error: 'workspace_not_found' });
        return;
      }
      throw err;
    } finally {
      runFlight.end();
    }
    return;
  }

  if (req.method === 'POST' && !isAllowedOrigin(req)) {
    sendJson(res, 403, { error: 'bad_origin' });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/pair') {
    const body = await readJson<{ nonce?: string; deviceName?: string }>(req);
    const result = await auth.pair(
      body.nonce || '',
      typeof body.deviceName === 'string' ? body.deviceName : undefined,
    );
    if ('error' in result) {
      const status = result.error === 'device_limit' ? 409 : 401;
      return sendJson(res, status, { ok: false, error: result.error });
    }
    sendJson(res, 200, {
      ok: true,
      token: result.token,
      deviceId: result.deviceId,
      deviceName: DEVICE_NAME,
    });
    return;
  }

  const callerDeviceId = auth.verifyBearerToken(req.headers.authorization);
  if (!callerDeviceId) {
    sendJson(res, 401, { authorized: false, ...auth.status() });
    return;
  }
  auth.touchDevice(callerDeviceId);

  if (req.method === 'GET' && url.pathname === '/api/status') {
    sendJson(res, 200, {
      authorized: true,
      ...taskStatus(activeContext),
      deviceName: DEVICE_NAME,
      workspaceDir: activeContext.project.path,
      activeProjectId: activeContext.project.id,
      activeSessionId: activeContext.session.id,
      engine: activeContext.session.engine,
      sessionInfo,
      catalog: projectSessions.catalog(),
      ...auth.status(),
      ...engineSessionStatus(activeContext),
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/directories') {
    try {
      sendJson(res, 200, await browseDirectories(url.searchParams.has('path') ? url.searchParams.get('path') : undefined));
    } catch (error) {
      if (error instanceof DirectoryError) sendJson(res, error.status, { error: error.code });
      else sendJson(res, 500, { error: 'directory_read_failed' });
    }
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/projects/open-directory') {
    if (!runFlight.tryBegin('mutate')) return sendJson(res, 409, { error: 'claude_is_busy' });
    try {
      const body = await readJson<{ path?: unknown; engine?: unknown }>(req);
      if (!body || !isAgentEngine(body.engine)) return sendJson(res, 400, { error: 'invalid_engine' });
      const context = await projectSessions.createSessionAtDirectory(body.path, body.engine);
      await selectActiveSession(context);
      broadcastActiveSession();
      sendJson(res, 201, {
        ok: true, projectId: context.project.id, sessionId: context.session.id,
        catalog: projectSessions.catalog(),
      });
    } catch (error) {
      if (error instanceof DirectoryError) sendJson(res, error.status, { error: error.code });
      else sendJson(res, 500, { error: 'directory_open_failed' });
    } finally {
      runFlight.end();
    }
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/projects') {
    sendJson(res, 200, projectSessions.catalog());
    return;
  }

  if (req.method === 'GET' && (url.pathname === '/api/models' || url.pathname === '/api/commands')) {
    const context = activeContext;
    const requestedSessionId = url.searchParams.get('sessionId');
    if (requestedSessionId !== context.session.id) {
      sendJson(res, 409, { error: 'session_changed' });
      return;
    }
    const currentBridge = bridge;
    try {
      if (url.pathname === '/api/models') {
        if (!(currentBridge instanceof CodexBridge)) {
          sendJson(res, 400, { error: 'model_catalog_not_supported' });
          return;
        }
        const models = await currentBridge.listModels();
        sendJson(res, 200, sessionMessage({ models }, context));
      } else {
        const commands = await refreshCommands();
        sendJson(res, 200, sessionMessage({ commands }, context));
      }
    } catch (error) {
      // ponytail: the client only sees a generic 502, so log the real cause once
      console.warn(`[catalog] ${url.pathname} failed:`, error);
      sendJson(res, 502, { error: 'engine_catalog_unavailable' });
    }
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/search/sessions') {
    const query = (url.searchParams.get('q') || '').trim();
    const requestedLimit = Number(url.searchParams.get('limit') || 50);
    if (!query || query.length > 200) {
      sendJson(res, 400, { error: 'search_query_invalid' });
      return;
    }
    if (!Number.isInteger(requestedLimit) || requestedLimit < 1) {
      sendJson(res, 400, { error: 'search_limit_invalid' });
      return;
    }
    const projectId = url.searchParams.get('projectId') || undefined;
    const engine = url.searchParams.get('engine') || undefined;
    const archived = url.searchParams.get('archived');
    if ((engine !== undefined && !isAgentEngine(engine))
      || (archived !== null && archived !== 'true' && archived !== 'false')) {
      sendJson(res, 400, { error: 'search_filter_invalid' });
      return;
    }
    sendJson(res, 200, {
      query,
      results: projectSessions.searchSessions(query, Math.min(requestedLimit, 50), {
        projectId, engine,
        archived: archived === null ? undefined : archived === 'true',
      }),
    });
    return;
  }

  const createSessionMatch = req.method === 'POST'
    ? url.pathname.match(/^\/api\/projects\/([^/]+)\/sessions$/)
    : null;
  if (createSessionMatch) {
    if (!runFlight.tryBegin('mutate')) return sendJson(res, 409, { error: 'claude_is_busy' });
    try {
      const body = await readJson<{ engine?: unknown }>(req);
      const context = await projectSessions.createSession(
        decodeURIComponent(createSessionMatch[1]),
        undefined,
        normalizeAgentEngine(body.engine),
      );
      await selectActiveSession(context);
      broadcastActiveSession();
      sendJson(res, 201, {
        ok: true,
        projectId: context.project.id,
        sessionId: context.session.id,
        catalog: projectSessions.catalog(),
      });
    } finally {
      runFlight.end();
    }
    return;
  }

  const selectSessionMatch = req.method === 'POST'
    ? url.pathname.match(/^\/api\/sessions\/([^/]+)\/select$/)
    : null;
  if (selectSessionMatch) {
    if (!runFlight.tryBegin('mutate')) return sendJson(res, 409, { error: 'claude_is_busy' });
    try {
      const context = await projectSessions.selectSession(decodeURIComponent(selectSessionMatch[1]));
      await selectActiveSession(context);
      broadcastActiveSession();
      sendJson(res, 200, { ok: true, ...projectSessions.catalog() });
    } finally {
      runFlight.end();
    }
    return;
  }

  const renameSessionMatch = req.method === 'POST'
    ? url.pathname.match(/^\/api\/sessions\/([^/]+)\/title$/)
    : null;
  if (renameSessionMatch) {
    if (!runFlight.tryBegin('mutate')) return sendJson(res, 409, { error: 'claude_is_busy' });
    try {
      const body = await readJson<{ title?: string }>(req);
      const context = await projectSessions.setSessionTitle(
        decodeURIComponent(renameSessionMatch[1]),
        body.title || '',
      );
      await syncNativeClaudeHistory(context);
      broadcastCatalog();
      sendJson(res, 200, { ok: true, ...projectSessions.catalog() });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = message === 'session_not_found' ? 404
        : message === 'title_required' ? 400
        : 400;
      sendJson(res, status, { error: message });
    } finally {
      runFlight.end();
    }
    return;
  }

  const sessionMetadataMatch = req.method === 'POST'
    ? url.pathname.match(/^\/api\/sessions\/([^/]+)\/(pin|restore)$/)
    : null;
  if (sessionMetadataMatch) {
    if (!runFlight.tryBegin('mutate')) return sendJson(res, 409, { error: 'claude_is_busy' });
    try {
      const sessionId = decodeURIComponent(sessionMetadataMatch[1]);
      if (sessionMetadataMatch[2] === 'restore') {
        await projectSessions.restoreSession(sessionId);
      } else {
        const body = await readJson<{ pinned?: unknown }>(req);
        if (typeof body.pinned !== 'boolean') return sendJson(res, 400, { error: 'pinned_invalid' });
        await projectSessions.setSessionPinned(sessionId, body.pinned);
      }
      activeContext = projectSessions.active();
      broadcastCatalog();
      sendJson(res, 200, { ok: true, ...projectSessions.catalog() });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      sendJson(res, message === 'session_not_found' ? 404 : 400, { error: message });
    } finally {
      runFlight.end();
    }
    return;
  }

  const archiveSessionMatch = req.method === 'POST'
    ? url.pathname.match(/^\/api\/sessions\/([^/]+)\/archive$/)
    : null;
  if (archiveSessionMatch) {
    if (!runFlight.tryBegin('mutate')) return sendJson(res, 409, { error: 'claude_is_busy' });
    try {
      const next = await projectSessions.archiveSession(decodeURIComponent(archiveSessionMatch[1]));
      if (next.session.id !== activeContext.session.id) {
        await selectActiveSession(next);
        broadcastActiveSession();
      } else {
        activeContext = next;
        broadcastCatalog();
      }
      sendJson(res, 200, { ok: true, ...projectSessions.catalog() });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = message === 'session_not_found' ? 404
        : message === 'claude_is_busy' ? 409
        : message === 'last_session' ? 400
        : 400;
      sendJson(res, status, { error: message });
    } finally {
      runFlight.end();
    }
    return;
  }

  const deleteSessionMatch = req.method === 'DELETE'
    ? url.pathname.match(/^\/api\/sessions\/([^/]+)$/)
    : null;
  if (deleteSessionMatch) {
    if (!runFlight.tryBegin('mutate')) return sendJson(res, 409, { error: 'claude_is_busy' });
    try {
      const sessionId = decodeURIComponent(deleteSessionMatch[1]);
      const existing = projectSessions.getSession(sessionId);
      if (!existing) return sendJson(res, 404, { error: 'session_not_found' });
      const result = await projectSessions.deleteSession(sessionId);
      claudeHistoryReader.forget(existing.transcript.snapshot().engineSessionId || '');
      historyErrors.delete(sessionId);
      await attachments.removeSessionDirectory(existing.project.id, sessionId);
      const next = projectSessions.active();
      if (next.session.id !== activeContext.session.id
        || next.project.id !== activeContext.project.id) {
        await selectActiveSession(next);
        broadcastActiveSession();
      } else {
        broadcastCatalog();
      }
      sendJson(res, 200, { ok: true, deletedSessionId: result.deletedSessionId, ...result.catalog });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = message === 'session_not_found' ? 404
        : message === 'claude_is_busy' ? 409
        : 400;
      sendJson(res, status, { error: message });
    } finally {
      runFlight.end();
    }
    return;
  }

  const sessionMatch = req.method === 'GET'
    ? url.pathname.match(/^\/api\/sessions\/([^/]+)$/)
    : null;
  if (sessionMatch) {
    const context = projectSessions.getSession(decodeURIComponent(sessionMatch[1]));
    if (!context) return sendJson(res, 404, { error: 'session_not_found' });
    await refreshNativeHistory(context);
    sendJson(res, 200, {
      projectId: context.project.id,
      sessionId: context.session.id,
      title: context.session.title,
      archived: Boolean(context.session.archivedAt),
      transcript: context.transcript.snapshot(),
    });
    return;
  }

  const uploadAttachmentsMatch = req.method === 'POST'
    ? url.pathname.match(/^\/api\/sessions\/([^/]+)\/attachments$/)
    : null;
  if (uploadAttachmentsMatch) {
    const context = projectSessions.getSession(decodeURIComponent(uploadAttachmentsMatch[1]));
    if (!context) return sendJson(res, 404, { error: 'session_not_found' });
    try {
      const saved = await readAttachments(req, {
        projectId: context.project.id,
        sessionId: context.session.id,
      }, attachments);
      sendJson(res, 201, { attachments: saved.map(attachmentDescriptor) });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = message === 'attachment_too_large' ? 413 : 400;
      sendJson(res, status, { error: message });
    }
    return;
  }

  const attachmentContentMatch = req.method === 'GET'
    ? url.pathname.match(/^\/api\/sessions\/([^/]+)\/attachments\/([^/]+)\/content$/)
    : null;
  if (attachmentContentMatch) {
    const context = projectSessions.getSession(decodeURIComponent(attachmentContentMatch[1]));
    if (!context) return sendJson(res, 404, { error: 'session_not_found' });
    const attachment = await attachments.resolve(
      context.project.id,
      context.session.id,
      decodeURIComponent(attachmentContentMatch[2]),
    );
    if (!attachment) return sendJson(res, 404, { error: 'attachment_not_found' });
    sendAttachment(res, attachment);
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/workspace') {
    sendJson(res, 200, await workspace.snapshot());
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/workspace/file') {
    const path = url.searchParams.get('path') || '';
    sendJson(res, 200, await workspace.readFile(path));
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/workspace/diff') {
    const path = url.searchParams.get('path') || '';
    const staged = url.searchParams.get('staged') === '1';
    sendJson(res, 200, { path, staged, diff: await workspace.diff(path, staged) });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/logout') {
    await auth.logout(callerDeviceId);
    closeSocketsForDevice(callerDeviceId);
    broadcastDevices();
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/devices') {
    const devices = auth.listDevices();
    sendJson(res, 200, {
      devices: devices.map(device => ({ ...device, current: device.id === callerDeviceId })),
    });
    return;
  }

  const revokeMatch = url.pathname.match(/^\/api\/devices\/([^/]+)\/revoke$/);
  if (req.method === 'POST' && revokeMatch) {
    let deviceId: string;
    try {
      deviceId = decodeURIComponent(revokeMatch[1]);
    } catch {
      return sendJson(res, 400, { ok: false, error: 'bad_device_id' });
    }
    const revoked = await auth.logout(deviceId);
    if (!revoked) return sendJson(res, 404, { ok: false, error: 'device_not_found' });
    closeSocketsForDevice(deviceId);
    broadcastDevices();
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/new-conversation') {
    if (!runFlight.tryBegin('mutate')) return sendJson(res, 409, { error: 'claude_is_busy' });
    try {
      const body = await readJson<{ engine?: unknown }>(req);
      const context = await projectSessions.createSession(
        activeContext.project.id,
        undefined,
        normalizeAgentEngine(body.engine),
      );
      await auth.setClaudeSessionId(undefined);
      await selectActiveSession(context);
      broadcastActiveSession();
      sendJson(res, 200, { ok: true, sessionId: context.session.id });
    } finally {
      runFlight.end();
    }
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/stop') {
    runFlight.requestStop();
    const stopped = bridge.stop();
    broadcast(sessionMessage({
      type: 'status',
      authenticated: true,
      ...taskStatus(activeContext),
      ...engineSessionStatus(activeContext),
    }, activeContext, activeRunId));
    sendJson(res, 200, { stopped });
    return;
  }

  sendJson(res, 404, { error: 'not_found' });
}

type WsSession = {
  isAuthenticated(): boolean;
  authenticate(token: string | undefined): Promise<boolean>;
};

async function handleWsMessage(ws: WebSocket, raw: string, session: WsSession): Promise<void> {
  if (raw.length > MAX_BODY_BYTES) throw new Error('message_too_large');
  const msg = JSON.parse(raw) as {
    type?: string;
    text?: string;
    token?: string;
    permissionMode?: string;
    sandboxMode?: unknown;
    requestId?: string;
    decision?: string;
    sessionId?: string;
    promptId?: unknown;
    probeId?: unknown;
    model?: unknown;
    effort?: unknown;
    engine?: unknown;
    attachmentIds?: unknown;
  };

  if (!session.isAuthenticated()) {
    if (msg.type !== 'auth') throw new Error('auth_required');
    if (!await session.authenticate(msg.token)) {
      ws.close(1008, 'auth_failed');
      return;
    }
    return;
  }

  if (msg.type === 'ping') {
    if (typeof msg.probeId !== 'string' || !msg.probeId || msg.probeId.length > 128) {
      throw new Error('invalid_probe_id');
    }
    send(ws, { type: 'pong', probeId: msg.probeId });
    return;
  }

  if (msg.type === 'stop') {
    runFlight.requestStop();
    bridge.stop();
    broadcast(sessionMessage({
      type: 'status',
      authenticated: true,
      ...taskStatus(activeContext),
      ...engineSessionStatus(activeContext),
    }, activeContext, activeRunId));
    return;
  }

  if (msg.type === 'select_session') {
    if (!msg.sessionId) throw new Error('session_required');
    if (!runFlight.tryBegin('mutate')) throw new Error('claude_is_busy');
    try {
      const context = await projectSessions.selectSession(msg.sessionId);
      await selectActiveSession(context);
      broadcastActiveSession();
    } finally {
      runFlight.end();
    }
    return;
  }

  if (msg.type === 'permission_response') {
    if (typeof msg.requestId !== 'string' || (msg.decision !== 'allow' && msg.decision !== 'deny')) {
      throw new Error('invalid_permission_response');
    }
    if (!bridge.respondToPermission(msg.requestId, msg.decision)) {
      send(ws, { type: 'permission_expired', requestId: msg.requestId });
    }
    return;
  }

  if (msg.type !== 'prompt') throw new Error('unknown_message_type');
  const prompt = (msg.text || '').trim();
  if (msg.attachmentIds !== undefined
    && (!Array.isArray(msg.attachmentIds)
      || !msg.attachmentIds.every(id => typeof id === 'string'))) {
    throw new Error('invalid_attachments');
  }
  const attachmentIds = (msg.attachmentIds ?? []) as string[];
  if (!prompt && attachmentIds.length === 0) return;
  if (prompt.length > MAX_BODY_BYTES) throw new Error('prompt_too_large');
  const promptId = parsePromptId(msg.promptId);
  const promptContext = msg.sessionId
    ? projectSessions.getSession(msg.sessionId)
    : activeContext;
  if (!promptContext) throw new Error('session_not_found');
  const engine = normalizeAgentEngine(msg.engine, promptContext.session.engine);
  if (engine !== promptContext.session.engine) throw new Error('engine_mismatch');
  const sandboxMode = engine === 'codex'
    ? normalizeCodexSandboxMode(msg.sandboxMode)
    : undefined;
  const signature = promptSignature(
    msg,
    prompt,
    attachmentIds,
    engine,
    sandboxMode,
  );
  if (promptId) {
    const receipt = promptReceipts.get(promptId);
    if (receipt) {
      if (receipt.signature !== signature) {
        send(ws, {
          type: 'error',
          message: 'prompt_id_conflict',
          promptId,
          projectId: receipt.projectId,
          sessionId: receipt.sessionId,
          engine: receipt.engine,
          runId: receipt.runId,
        });
      } else {
        sendPromptAccepted(ws, promptId, receipt);
      }
      return;
    }
  }
  if (nativeHistoryRefresh) await nativeHistoryRefresh;
  if (!runFlight.tryBegin('prompt')) {
    if (promptId) {
      send(ws, sessionMessage({
        type: 'error',
        message: 'claude_is_busy',
        promptId,
      }, promptContext));
      return;
    }
    throw new Error('claude_is_busy');
  }
  const runId = `run-${++nextRunId}`;
  activeRunId = runId;
  if (promptId) {
    const receipt = {
      signature,
      projectId: promptContext.project.id,
      sessionId: promptContext.session.id,
      engine,
      runId,
    };
    rememberPromptReceipt(promptId, receipt);
    sendPromptAccepted(ws, promptId, receipt);
  }
  try {
    await runPromptFlight(
      msg,
      prompt,
      attachmentIds,
      runId,
      engine,
      sandboxMode,
    );
  } catch (error) {
    if (activeRunStartedAt !== undefined) {
      flushTextDeltaBatch();
      const message = error instanceof Error ? error.message : String(error);
      await promptContext.transcript.finishError(message).catch(saveError => {
        console.warn('[transcript] Could not save failed run:', saveError);
      });
      broadcastNativeTranscript(promptContext, runId);
      broadcast(sessionMessage({
        type: 'status',
        authenticated: true,
        ...taskStatus(promptContext),
        ...engineSessionStatus(promptContext),
      }, promptContext, runId));
    }
    if (promptId && !promptContext.transcript.snapshot().running) {
      promptReceipts.delete(promptId);
    }
    throw error;
  } finally {
    if (activeRunId === runId) {
      activeRunId = undefined;
      activeRunStartedAt = undefined;
    }
    runFlight.end();
  }
}

async function runPromptFlight(
  msg: {
    sessionId?: string;
    permissionMode?: string;
    model?: unknown;
    effort?: unknown;
    engine?: unknown;
    sandboxMode?: unknown;
  },
  prompt: string,
  attachmentIds: string[],
  runId: string,
  engine: AgentEngine,
  sandboxMode: CodexSandboxMode | undefined,
): Promise<void> {
  const permissionMode = parsePermissionMode(msg.permissionMode);
  const model = engine === 'codex' && msg.engine === undefined
    ? undefined
    : normalizeEngineModel(msg.model);
  const effort = normalizeEngineEffort(msg.effort);
  if (engine === 'claude'
    && permissionMode === 'bypassPermissions'
    && !ALLOW_BYPASS_PERMISSIONS) {
    throw new Error('bypass_permissions_disabled');
  }
  if (msg.sessionId && msg.sessionId !== activeContext.session.id) {
    const context = await projectSessions.selectSession(msg.sessionId);
    // Abort if stop arrived while we were switching sessions.
    if (runFlight.isStopRequested()) return;
    await selectActiveSession(context);
    broadcastActiveSession();
  }

  const runContext = activeContext;
  if (runContext.session.engine !== engine) throw new Error('engine_mismatch');
  if (runFlight.isStopRequested()) return;
  const promptAttachments = await attachments.resolveMany(
    runContext.project.id,
    runContext.session.id,
    attachmentIds,
  );
  if (engine === 'codex'
    && promptAttachments.some(attachment => !attachment.mimeType.startsWith('image/'))) {
    throw new Error('codex_only_supports_image_attachments');
  }
  const uploadDirectory = engine === 'claude'
    ? await attachments.ensureSessionDirectory(
        runContext.project.id,
        runContext.session.id,
      )
    : undefined;
  if (runFlight.isStopRequested()) return;

  const displayPrompt = prompt;
  const enginePrompt = engine === 'claude'
    ? promptWithAttachments(prompt, promptAttachments)
    : prompt || '请查看附件并根据内容处理。';
  let historyChanged: boolean;
  try {
    historyChanged = await syncNativeMessages(runContext, true);
  } catch (error) {
    const message = error instanceof Error && error.message === 'native_session_is_busy'
      ? '电脑端仍在处理这个会话，请等它完成后再发送'
      : '会话历史同步失败，已有记录已保留，请重试';
    await runContext.transcript.recordRejectedPrompt(
      displayPrompt, message, promptAttachments.map(attachmentDescriptor),
    ).catch(() => undefined);
    throw error;
  }
  if (runFlight.isStopRequested()) return;

  activeRunStartedAt = Date.now();
  runContext.transcript.beginPrompt(
    displayPrompt,
    permissionMode,
    promptAttachments.map(attachmentDescriptor),
    sandboxMode,
    enginePrompt,
    /^\/compact(?:\s|$)/.test(prompt) || engine === 'codex' && /^\/review(?:\s|$)/.test(prompt),
  );
  if (historyChanged) broadcastNativeTranscript(runContext, runId);
  await projectSessions.setSessionTitleFromPrompt(
    runContext.session.id,
    prompt || promptAttachments[0]?.name || '附件会话',
  );
  if (runFlight.isStopRequested()) {
    await runContext.transcript.finishStopped();
    broadcast(sessionMessage({ type: 'stopped' }, runContext, runId));
    broadcast(sessionMessage({
      type: 'status',
      authenticated: true,
      ...taskStatus(runContext),
      ...engineSessionStatus(runContext),
    }, runContext, runId));
    broadcastCatalog();
    return;
  }
  broadcastCatalog();
  broadcast(sessionMessage({
    type: 'status',
    authenticated: true,
    ...taskStatus(runContext),
    ...engineSessionStatus(runContext),
  }, runContext, runId));

  const runEngine = (sessionId: string | undefined) => bridge.run({
    prompt: enginePrompt,
    sessionId,
    onPrompt: prompt => runContext.transcript.setNativePrompt(prompt),
    additionalDirectories: uploadDirectory ? [uploadDirectory] : undefined,
    imagePaths: engine === 'codex'
      ? promptAttachments.map(attachment => attachment.path)
      : undefined,
    permissionMode,
    sandboxMode,
    model,
    effort,
    onEvent: event => {
      const commands = engine === 'claude' ? extractClaudeCommands(event) : [];
      const cacheKey = commandCacheKey(runContext);
      const cachedCommands = commandCaches.get(cacheKey) || [];
      if (commands.length && commands.join('\n') !== cachedCommands.join('\n')) {
        commandCaches.set(cacheKey, commands);
        broadcast(sessionMessage({ type: 'commands', commands }, runContext, runId));
      }
      const nextSessionInfo = engine === 'claude'
        ? extractClaudeSessionInfo(event)
        : extractCodexSessionInfo(event);
      if (nextSessionInfo) {
        sessionInfo = { ...sessionInfo, ...nextSessionInfo };
        runContext.transcript.setSessionInfo(nextSessionInfo);
        broadcast(sessionMessage({ type: 'session_info', ...sessionInfo }, runContext, runId));
      }
      const activities = engine === 'claude'
        ? extractClaudeActivities(event)
        : extractCodexActivities(event);
      for (const activity of activities) {
        const publicActivity = redactAttachmentPaths(
          activity,
          promptAttachments,
          uploadDirectory,
        );
        runContext.transcript.mergeActivity(publicActivity);
        broadcast(sessionMessage({ type: 'activity', ...publicActivity }, runContext, runId));
      }
    },
    onText: text => {
      enqueueTextDelta(runContext, text, runId);
    },
    onSessionId: sessionId => {
      runContext.transcript.setEngineSessionId(sessionId);
      if (engine === 'claude') {
        void auth.setClaudeSessionId(sessionId).catch(error => {
          console.warn('[auth] Could not save Claude session:', error);
        });
      }
    },
    onPermissionRequest: request => {
      runContext.transcript.addPermission(request);
      broadcastCatalog();
      broadcast(sessionMessage(permissionRequestMessage(request), runContext, runId));
    },
    onPermissionClosed: requestId => {
      runContext.transcript.removePermission(requestId);
      broadcastCatalog();
      broadcast(sessionMessage({ type: 'permission_resolved', requestId }, runContext, runId));
    },
  });

  const previousSessionId = runContext.transcript.snapshot().engineSessionId;
  let result = await runEngine(previousSessionId);
  if (engine === 'claude'
    && previousSessionId
    && result.exitCode !== 0
    && isMissingConversationError(result.stderr)) {
    await auth.setClaudeSessionId(undefined);
    runContext.transcript.setEngineSessionId(undefined);
    result = runFlight.isStopRequested()
      ? { ...result, stopped: true }
      : await runEngine(undefined);
  }

  // Flush coalesced stream text before terminal events so clients never miss a tail.
  flushTextDeltaBatch();

  if (result.sessionId) {
    runContext.transcript.setEngineSessionId(result.sessionId);
    if (engine === 'claude') await auth.setClaudeSessionId(result.sessionId);
  }
  if (engine === 'claude') {
    await syncNativeClaudeHistory(runContext);
    const restored = await applyRestoredClaudeSessionInfo(
      runContext,
      result.sessionId || runContext.transcript.snapshot().engineSessionId,
    );
    if (restored) {
      broadcast(sessionMessage({ type: 'session_info', ...sessionInfo }, runContext, runId));
    }
  }
  const replyImagesChanged = await syncReplyImages(runContext);
  if (result.stopped) {
    await runContext.transcript.finishStopped();
    broadcast(sessionMessage({ type: 'stopped' }, runContext, runId));
  } else {
    if (result.exitCode !== 0 && result.stderr) {
      await runContext.transcript.finishError(result.stderr);
      broadcast(sessionMessage({ type: 'error', message: result.stderr }, runContext, runId));
    } else {
      await runContext.transcript.finishDone();
    }
    broadcast(sessionMessage({
      type: 'done',
      exitCode: result.exitCode,
      engineSessionId: result.sessionId,
      ...(engine === 'claude' ? { claudeSessionId: result.sessionId } : {}),
    }, runContext, runId));
  }
  if (replyImagesChanged) broadcastNativeTranscript(runContext, runId);
  broadcast(sessionMessage({
    type: 'status',
    authenticated: true,
    ...taskStatus(runContext),
    ...engineSessionStatus(runContext),
  }, runContext, runId));
  broadcastCatalog();
}

function redactAttachmentPaths(
  activity: ClaudeActivity,
  promptAttachments: StoredAttachment[],
  uploadDirectory: string | undefined,
): ClaudeActivity {
  if (!activity.detail) return activity;
  let detail = activity.detail;
  for (const attachment of promptAttachments) {
    detail = detail.split(attachment.path).join(`附件/${attachment.name}`);
  }
  if (uploadDirectory) detail = detail.split(uploadDirectory).join('附件');
  return detail === activity.detail ? activity : { ...activity, detail };
}

function sendAttachment(res: ServerResponse, attachment: StoredAttachment): void {
  const dispositionName = encodeURIComponent(attachment.name).replace(/'/g, '%27');
  res.writeHead(200, {
    'Content-Type': attachment.mimeType,
    'Content-Length': attachment.size,
    'Content-Disposition': `inline; filename*=UTF-8''${dispositionName}`,
    'Cache-Control': 'private, max-age=3600',
    'X-Content-Type-Options': 'nosniff',
  });
  const stream = attachments.open(attachment);
  stream.on('error', () => res.destroy());
  stream.pipe(res);
}

async function serveStatic(res: ServerResponse, pathname: string): Promise<void> {
  const file = staticFile(pathname);
  if (!file) return sendJson(res, 404, { error: 'not_found' });
  const data = await readFile(file.path);
  res.writeHead(200, {
    'Content-Type': file.type,
    'Cache-Control': file.cache,
  });
  res.end(data);
}

function staticFile(pathname: string): { path: string; type: string; cache: string } | null {
  if (pathname === '/' || pathname === '/pair') {
    return { path: join(process.cwd(), 'web', 'index.html'), type: 'text/html; charset=utf-8', cache: 'no-cache' };
  }
  if (pathname === '/manifest.webmanifest') {
    return { path: join(process.cwd(), 'web', 'manifest.webmanifest'), type: 'application/manifest+json', cache: 'no-cache' };
  }
  if (pathname === '/app.js' || pathname === '/app.js.map' || pathname === '/sw.js') {
    return { path: join(process.cwd(), 'dist', 'web', pathname.slice(1)), type: contentType(pathname), cache: 'no-cache' };
  }
  return null;
}

function contentType(pathname: string): string {
  const ext = extname(pathname);
  if (ext === '.js') return 'text/javascript; charset=utf-8';
  if (ext === '.map') return 'application/json; charset=utf-8';
  return 'application/octet-stream';
}

async function readJson<T>(req: IncomingMessage): Promise<T> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new Error('body_too_large');
    chunks.push(chunk);
  }
  const body = Buffer.concat(chunks, size).toString('utf8');
  return body ? JSON.parse(body) as T : {} as T;
}

function sendJson(res: ServerResponse, status: number, data: unknown): void {
  if (res.headersSent) return;
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function sendStatus(ws: WebSocket, authenticated: boolean): void {
  send(ws, sessionMessage({
    type: 'status',
    authenticated,
    connectionProbe: true,
    multiDevice: true,
    ...taskStatus(activeContext),
    ...engineSessionStatus(activeContext),
    workspaceDir: activeContext.project.path,
  }, activeContext, activeRunId));
}

function refreshCommands(): Promise<string[]> {
  const project = activeContext.project;
  const context = activeContext;
  const cacheKey = commandCacheKey(context);
  const existing = commandDiscoveries.get(cacheKey);
  if (existing) return existing;
  const currentBridge = bridge;
  const discovery = (currentBridge instanceof CodexBridge
    ? currentBridge.listCommands()
    : discoverClaudeCommands({ claudeBin: CLAUDE_BIN, workspaceDir: project.path }))
  .then(commands => {
    if (bridge === currentBridge) {
      commandCaches.set(cacheKey, commands);
      broadcast(sessionMessage({ type: 'commands', commands, loading: false }));
    }
    return commands;
  }).catch(error => {
    if (bridge === currentBridge) {
      broadcast(sessionMessage({
        type: 'commands', commands: commandCaches.get(cacheKey) || [],
        loading: false, error: 'engine_catalog_unavailable',
      }));
    }
    throw error;
  }).finally(() => {
    if (commandDiscoveries.get(cacheKey) === discovery) commandDiscoveries.delete(cacheKey);
  });
  commandDiscoveries.set(cacheKey, discovery);
  return discovery;
}

function createBridge(workspaceDir: string, engine: AgentEngine): EngineBridge {
  if (engine === 'codex') {
    return new CodexBridge({
      codexBin: CODEX_BIN,
      codexArgs: CODEX_ARGS,
      workspaceDir,
    });
  }
  return new ClaudeBridge({
    claudeBin: CLAUDE_BIN,
    claudeArgs: CLAUDE_ARGS,
    workspaceDir,
    allowBypassPermissions: ALLOW_BYPASS_PERMISSIONS,
  });
}

async function syncNativeClaudeHistory(context: SessionContext): Promise<void> {
  const sessionId = context.transcript.snapshot().engineSessionId;
  if (context.session.engine !== 'claude' || !sessionId) return;
  try {
    const title = projectSessions.getSession(context.session.id)?.session.title ?? context.session.title;
    await syncClaudeSessionHistory({ sessionId, title });
  } catch (error) {
    console.warn('[claude-history] Could not sync the desktop session list:', error);
  }
}

async function syncNativeMessages(context: SessionContext, required = false): Promise<boolean> {
  const snapshot = context.transcript.snapshot();
  if (snapshot.running) return false;
  if (!snapshot.engineSessionId) return syncReplyImages(context);
  try {
    let history;
    if (context.session.engine === 'claude') {
      history = await claudeHistoryReader.read(snapshot.engineSessionId);
    } else {
      // History is addressed by thread ID, independent of the active folder.
      historyBridge ??= new CodexBridge({
        codexBin: CODEX_BIN, codexArgs: CODEX_ARGS, workspaceDir: WORKSPACE_DIR,
      });
      history = await historyBridge.readHistory(snapshot.engineSessionId);
    }
    if (!history) return syncReplyImages(context);
    const result = await context.transcript.importNativeHistory(history);
    const imagesChanged = await syncReplyImages(context);
    if (result.external && context.session.id === activeContext.session.id) bridge.close();
    historyErrors.delete(context.session.id);
    if (required && history.running) {
      throw new Error('native_session_is_busy');
    }
    return result.changed || imagesChanged;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (required) {
      if (message === 'native_session_is_busy') throw error;
      throw new Error('native_history_sync_failed', { cause: error });
    }
    if (historyErrors.get(context.session.id) !== message) {
      historyErrors.set(context.session.id, message);
      console.warn('[native-history] Could not refresh session history:', error);
    }
    return syncReplyImages(context);
  }
}

async function syncReplyImages(context: SessionContext): Promise<boolean> {
  const snapshot = context.transcript.snapshot();
  if (replyImageRevisions.get(context.transcript) === snapshot.revision) return false;
  let changed = false;
  for (const [index, message] of snapshot.messages.entries()) {
    if (message.role !== 'assistant') continue;
    try {
      const images = await collectReplyImages({
        store: attachments,
        projectId: context.project.id,
        sessionId: context.session.id,
        workspaceDir: context.project.path,
        text: message.text,
        existing: message.attachments,
      });
      changed = context.transcript.setAssistantAttachments(index, images) || changed;
    } catch (error) {
      console.warn('[reply-images] Could not attach a reply image:', error);
    }
  }
  if (changed) await context.transcript.flush();
  replyImageRevisions.set(context.transcript, context.transcript.snapshot().revision);
  return changed;
}

function broadcastNativeTranscript(context: SessionContext, runId?: string): void {
  broadcastCatalog();
  broadcast(sessionMessage({
    type: 'transcript_snapshot',
    ...context.transcript.snapshot(),
    ...taskStatus(context),
  }, context, runId));
}

async function refreshNativeHistory(context: SessionContext): Promise<void> {
  if (nativeHistoryRefresh) await nativeHistoryRefresh;
  if (!runFlight.tryBegin('mutate')) return;
  if (!projectSessions.getSession(context.session.id)) {
    runFlight.end();
    return;
  }
  nativeHistoryRefresh = (async () => {
    try {
      if (await syncNativeMessages(context)) broadcastNativeTranscript(context);
    } finally {
      runFlight.end();
      nativeHistoryRefresh = undefined;
    }
  })();
  await nativeHistoryRefresh;
}

async function selectActiveSession(context: SessionContext): Promise<void> {
  bridge.close();
  commandDiscoveries.clear();
  activeContext = context;
  workspace = new WorkspaceService(context.project.path);
  bridge = createBridge(context.project.path, context.session.engine);
  sessionInfo = context.transcript.snapshot().sessionInfo;
  await applyRestoredClaudeSessionInfo(
    context,
    context.transcript.snapshot().engineSessionId,
  );
  await syncNativeMessages(context);
  if (context.session.engine === 'claude') void refreshCommands().catch(() => {});
}

async function applyRestoredClaudeSessionInfo(
  context: SessionContext,
  sessionId: string | undefined,
): Promise<boolean> {
  if (context.session.engine !== 'claude' || !sessionId) return false;
  const restored = await restoreClaudeSessionInfo({ sessionId });
  if (!restored) return false;
  sessionInfo = mergeClaudeSessionInfo(sessionInfo, restored);
  context.transcript.setSessionInfo(sessionInfo);
  await context.transcript.flush();
  return true;
}

function broadcastCatalog(): void {
  broadcast({ type: 'catalog', ...projectSessions.catalog() });
}

function broadcastActiveSession(): void {
  broadcastCatalog();
  broadcast(sessionMessage({
    type: 'status',
    authenticated: true,
    ...taskStatus(activeContext),
    ...engineSessionStatus(activeContext),
    workspaceDir: activeContext.project.path,
  }, activeContext, activeRunId));
  broadcast(sessionMessage({ type: 'session_info', ...sessionInfo }, activeContext, activeRunId));
  broadcast(sessionMessage({
    type: 'transcript_snapshot',
    ...activeContext.transcript.snapshot(),
    ...taskStatus(activeContext),
  }, activeContext, activeRunId));
  broadcast(sessionMessage(permissionCapabilities(activeContext)));
  const commands = commandCaches.get(commandCacheKey(activeContext)) || [];
  broadcast(sessionMessage({ type: 'commands', commands, loaded: commandCaches.has(commandCacheKey(activeContext)) }));
}

function sessionMessage(
  data: Record<string, unknown>,
  context: SessionContext = activeContext,
  runId: string | undefined = undefined,
): Record<string, unknown> {
  return {
    ...data,
    projectId: context.project.id,
    sessionId: context.session.id,
    engine: context.session.engine,
    ...(runId ? { runId } : {}),
  };
}

type PromptReceipt = {
  signature: string;
  projectId: string;
  sessionId: string;
  engine: AgentEngine;
  runId: string;
};

function parsePromptId(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || value.length < 1 || value.length > 128) {
    throw new Error('invalid_prompt_id');
  }
  return value;
}

function promptSignature(
  msg: {
    sessionId?: string;
    permissionMode?: string;
    model?: unknown;
    effort?: unknown;
    engine?: unknown;
    sandboxMode?: unknown;
  },
  prompt: string,
  attachmentIds: string[],
  engine: AgentEngine,
  sandboxMode: CodexSandboxMode | undefined,
): string {
  return JSON.stringify({
    sessionId: msg.sessionId ?? activeContext.session.id,
    prompt,
    attachmentIds,
    permissionMode: msg.permissionMode ?? 'auto',
    model: msg.model ?? null,
    effort: msg.effort ?? null,
    engine,
    sandboxMode: sandboxMode ?? null,
  });
}

function rememberPromptReceipt(promptId: string, receipt: PromptReceipt): void {
  promptReceipts.set(promptId, receipt);
  while (promptReceipts.size > MAX_PROMPT_RECEIPTS) {
    const oldest = promptReceipts.keys().next().value as string | undefined;
    if (!oldest) break;
    promptReceipts.delete(oldest);
  }
}

function sendPromptAccepted(ws: WebSocket, promptId: string, receipt: PromptReceipt): void {
  send(ws, {
    type: 'prompt_accepted',
    promptId,
    projectId: receipt.projectId,
    sessionId: receipt.sessionId,
    engine: receipt.engine,
    runId: receipt.runId,
  });
}

function taskStatus(context: SessionContext): Record<string, unknown> {
  const running = context.transcript.snapshot().running;
  return {
    running,
    stopping: running && runFlight.isStopRequested(),
    ...(running && activeRunStartedAt ? { startedAt: activeRunStartedAt } : {}),
  };
}

function engineSessionStatus(context: SessionContext): Record<string, unknown> {
  const hasEngineSessionId = Boolean(context.transcript.snapshot().engineSessionId);
  return {
    hasEngineSessionId,
    hasClaudeSessionId: context.session.engine === 'claude' && hasEngineSessionId,
  };
}

function commandCacheKey(context: SessionContext): string {
  return `${context.session.engine}:${context.project.id}`;
}

function permissionCapabilities(context: SessionContext): Record<string, unknown> {
  return {
    type: 'permission_capabilities',
    allowBypassPermissions:
      context.session.engine === 'claude' && ALLOW_BYPASS_PERMISSIONS,
    codexSandboxModes: context.session.engine === 'codex'
      ? ['read-only', 'workspace-write', 'danger-full-access']
      : [],
  };
}

// ponytail: 30ms text coalesce is enough for mobile/tunnel; drop if first-byte latency matters more
const TEXT_BATCH_MS = 30;
let textBatch = '';
let textBatchContext: SessionContext | undefined;
let textBatchRunId: string | undefined;
let textBatchTimer: NodeJS.Timeout | undefined;

function enqueueTextDelta(context: SessionContext, text: string, runId: string): void {
  if (!text) return;
  context.transcript.appendText(text);
  if (textBatchContext && textBatchContext.session.id !== context.session.id) {
    flushTextDeltaBatch();
  }
  textBatchContext = context;
  textBatchRunId = runId;
  textBatch += text;
  if (!textBatchTimer) {
    textBatchTimer = setTimeout(() => {
      textBatchTimer = undefined;
      flushTextDeltaBatch();
    }, TEXT_BATCH_MS);
    textBatchTimer.unref();
  }
}

function flushTextDeltaBatch(): void {
  if (textBatchTimer) {
    clearTimeout(textBatchTimer);
    textBatchTimer = undefined;
  }
  if (!textBatch || !textBatchContext) {
    textBatch = '';
    textBatchContext = undefined;
    textBatchRunId = undefined;
    return;
  }
  const text = textBatch;
  const context = textBatchContext;
  const runId = textBatchRunId;
  textBatch = '';
  textBatchContext = undefined;
  textBatchRunId = undefined;
  broadcast(sessionMessage({ type: 'text', text }, context, runId));
}

function broadcast(data: unknown): void {
  for (const client of [...authedSockets.keys()]) {
    try {
      send(client, data);
    } catch {
      if (client.readyState !== WebSocket.CLOSED) client.terminate();
    }
  }
}

function broadcastDevices(): void {
  const devices = auth.listDevices();
  for (const [client, deviceId] of authedSockets) {
    send(client, {
      type: 'devices',
      devices: devices.map(device => ({ ...device, current: device.id === deviceId })),
    });
  }
}

function closeSocketsForDevice(deviceId: string): void {
  for (const [client, socketDeviceId] of [...authedSockets]) {
    if (socketDeviceId !== deviceId) continue;
    authedSockets.delete(client);
    if (client.readyState === WebSocket.CLOSED) continue;
    const previousTimer = wsCloseTimers.get(client);
    if (previousTimer) clearTimeout(previousTimer);
    client.close(1008, 'authorization_changed');
    const closeTimer = setTimeout(() => {
      if (client.readyState !== WebSocket.CLOSED) client.terminate();
      wsCloseTimers.delete(client);
    }, WS_CLOSE_TIMEOUT_MS);
    closeTimer.unref?.();
    wsCloseTimers.set(client, closeTimer);
  }
}

function closeAllSockets(): void {
  for (const client of [...wss.clients]) {
    if (client.readyState === WebSocket.CLOSED) continue;
    const previousTimer = wsCloseTimers.get(client);
    if (previousTimer) clearTimeout(previousTimer);
    client.close(1008, 'authorization_changed');
    const closeTimer = setTimeout(() => {
      if (client.readyState !== WebSocket.CLOSED) client.terminate();
      wsCloseTimers.delete(client);
    }, WS_CLOSE_TIMEOUT_MS);
    closeTimer.unref?.();
    wsCloseTimers.set(client, closeTimer);
  }
}

function send(ws: WebSocket, data: unknown): void {
  if (ws.readyState !== WebSocket.OPEN) return;

  let payload: string | undefined;
  try {
    payload = JSON.stringify(data);
  } catch (error) {
    console.error(
      'WebSocket payload serialization failed:',
      error instanceof Error ? error.message : String(error),
    );
    return;
  }
  if (payload === undefined) return;

  const payloadBytes = Buffer.byteLength(payload);
  const oversized = payloadBytes > MAX_WS_BUFFERED_BYTES;
  const largePayloadBytes = wsLargePayloadBytes.get(ws) ?? 0;
  if ((oversized && largePayloadBytes > 0)
    || ws.bufferedAmount + (oversized ? 0 : payloadBytes) > MAX_WS_BUFFERED_BYTES + largePayloadBytes) {
    ws.terminate();
    return;
  }
  // Allow one large snapshot while limiting the messages queued behind it.
  if (oversized) wsLargePayloadBytes.set(ws, payloadBytes);
  try {
    ws.send(payload, error => {
      if (oversized) wsLargePayloadBytes.delete(ws);
      if (error) {
        console.error('WebSocket send failed:', error.message);
        ws.terminate();
      }
    });
  } catch (error) {
    if (oversized) wsLargePayloadBytes.delete(ws);
    console.error(
      'WebSocket send failed:',
      error instanceof Error ? error.message : String(error),
    );
    ws.terminate();
  }
}

function headerValue(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function parsePermissionMode(value: string | undefined): ClaudePermissionMode {
  if (value === 'acceptEdits'
    || value === 'auto'
    || value === 'dontAsk'
    || value === 'plan'
    || value === 'bypassPermissions') {
    return value;
  }
  return 'auto';
}

function permissionRequestMessage(request: ClaudePermissionRequest): Record<string, unknown> {
  return {
    type: 'permission_request',
    requestId: request.requestId,
    toolName: request.toolName,
    detail: request.detail,
    title: request.title,
    displayName: request.displayName,
    description: request.description,
    decisionReason: request.decisionReason,
  };
}

function isAllowedHost(req: IncomingMessage): boolean {
  const host = (req.headers.host || '').toLowerCase();
  return host === publicUrl.host.toLowerCase() || isLoopbackHost(host);
}

function isAllowedOrigin(req: IncomingMessage): boolean {
  const origin = req.headers.origin;
  if (!origin) return true;
  if (origin === PUBLIC_ORIGIN) return true;
  try {
    const url = new URL(origin);
    return isLoopbackHost(url.host) && isLoopbackHost(req.headers.host || '');
  } catch {
    return false;
  }
}

function isLoopbackHost(host: string): boolean {
  const lower = host.toLowerCase();
  if (lower === '[::1]' || lower.startsWith('[::1]:')) return true;
  const name = lower.split(':')[0];
  return name === '127.0.0.1' || name === 'localhost';
}

function isLoopbackAddress(address: string | undefined): boolean {
  if (!address) return false;
  const value = address.toLowerCase();
  return value === '127.0.0.1'
    || value === '::1'
    || value === '::ffff:127.0.0.1';
}

/** Local control APIs require both loopback peer and loopback Host (not public tunnel Host). */
function isLocalControlRequest(req: IncomingMessage): boolean {
  const remote = req.socket.remoteAddress;
  return isLoopbackAddress(remote) && isLoopbackHost(req.headers.host || '');
}
