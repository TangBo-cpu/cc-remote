import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { hostname } from 'node:os';
import { readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import qrcode from 'qrcode-terminal';
import WebSocket, { WebSocketServer } from 'ws';
import { createAuthState } from './authState.js';
import { createTranscriptState } from './transcriptState.js';
import {
  ClaudeBridge,
  discoverClaudeCommands,
  extractClaudeActivities,
  extractClaudeCommands,
  extractClaudeSessionInfo,
  isMissingConversationError,
  type ClaudePermissionMode,
  type ClaudePermissionRequest,
  type ClaudeSessionInfo,
} from './claudeBridge.js';

const HOST = process.env.HOST || '127.0.0.1';
const PORT = Number(process.env.PORT || 8787);
const PUBLIC_ORIGIN = (process.env.PUBLIC_ORIGIN || `http://${HOST}:${PORT}`).replace(/\/+$/, '');
const WORKSPACE_DIR = process.env.WORKSPACE_DIR || process.cwd();
const CLAUDE_BIN = process.env.CLAUDE_BIN || 'claude';
const DEVICE_NAME = process.env.DEVICE_NAME || hostname();
const ALLOW_BYPASS_PERMISSIONS = process.env.ALLOW_BYPASS_PERMISSIONS === '1';
const MAX_BODY_BYTES = 64 * 1024;

const publicUrl = new URL(PUBLIC_ORIGIN);
const auth = await createAuthState();
const transcript = await createTranscriptState();
const bridge = new ClaudeBridge({
  claudeBin: CLAUDE_BIN,
  workspaceDir: WORKSPACE_DIR,
  allowBypassPermissions: ALLOW_BYPASS_PERMISSIONS,
});
const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_BODY_BYTES });
const authedSockets = new Set<WebSocket>();
let commandCache: string[] = [];
let commandDiscovery: Promise<string[]> | undefined;
let sessionInfo: ClaudeSessionInfo = transcript.snapshot().sessionInfo;

const server = createServer(async (req, res) => {
  try {
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
  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  if (url.pathname !== '/ws' || !isAllowedHost(req) || !isAllowedOrigin(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, ws => {
    wss.emit('connection', ws, req);
  });
});

wss.on('connection', ws => {
  let authenticated = false;
  let authGeneration = -1;

  ws.on('close', () => {
    authedSockets.delete(ws);
  });

  ws.on('message', data => {
    if (authenticated && authGeneration !== auth.getAuthGeneration()) {
      ws.close(1008, 'authorization_expired');
      return;
    }
    void handleWsMessage(ws, data.toString('utf8'), {
      isAuthenticated: () => authenticated,
      authenticate: token => {
        if (!auth.verifyToken(token)) return false;
        authenticated = true;
        authGeneration = auth.getAuthGeneration();
        authedSockets.add(ws);
        sendStatus(ws, true);
        if (commandCache.length) {
          send(ws, { type: 'commands', commands: commandCache });
        } else {
          void refreshCommands();
        }
        if (Object.keys(sessionInfo).length) {
          send(ws, { type: 'session_info', ...sessionInfo });
        }
        send(ws, { type: 'transcript_snapshot', ...transcript.snapshot() });
        send(ws, { type: 'permission_capabilities', allowBypassPermissions: ALLOW_BYPASS_PERMISSIONS });
        return true;
      },
    }).catch(err => {
      send(ws, { type: 'error', message: err instanceof Error ? err.message : String(err) });
    });
  });
});

server.listen(PORT, HOST, () => {
  const pairPayload = auth.createPairingPayload(PUBLIC_ORIGIN, DEVICE_NAME);
  const pairQr = JSON.stringify(pairPayload);
  console.log(`CC Remote listening on http://${HOST}:${PORT}`);
  console.log(`Workspace: ${WORKSPACE_DIR}`);
  console.log(`Public origin: ${PUBLIC_ORIGIN}`);
  console.log(`Device name: ${DEVICE_NAME}`);
  console.log('Scan this QR with the CC Remote mobile app:');
  console.log(pairQr);
  qrcode.generate(pairQr, { small: true });
  void refreshCommands();
});

async function handleApi(req: IncomingMessage, res: ServerResponse, url: URL): Promise<void> {
  res.setHeader('Cache-Control', 'no-store');

  if (req.method === 'GET' && url.pathname === '/api/health') {
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'POST' && !isAllowedOrigin(req)) {
    sendJson(res, 403, { error: 'bad_origin' });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/pair') {
    const body = await readJson<{ nonce?: string }>(req);
    const token = await auth.pair(body.nonce || '');
    if (!token) return sendJson(res, 401, { ok: false, error: 'invalid_pairing_code' });
    closeAllSockets();
    sendJson(res, 200, { ok: true, token, deviceName: DEVICE_NAME });
    return;
  }

  const authorized = auth.verifyBearerToken(req.headers.authorization);
  if (!authorized) {
    sendJson(res, 401, { authorized: false, ...auth.status() });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/status') {
    sendJson(res, 200, {
      authorized: true,
      running: bridge.isRunning(),
      deviceName: DEVICE_NAME,
      workspaceDir: WORKSPACE_DIR,
      ...auth.status(),
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/logout') {
    await auth.logout();
    closeAllSockets();
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/new-conversation') {
    if (bridge.isRunning()) return sendJson(res, 409, { error: 'claude_is_busy' });
    await auth.setClaudeSessionId(undefined);
    await transcript.clear();
    sessionInfo = {};
    broadcast({ type: 'status', authenticated: true, running: false, hasClaudeSessionId: false });
    broadcast({ type: 'session_info', model: null, contextWindow: null, usedTokens: null, remainingTokens: null });
    broadcast({ type: 'transcript_snapshot', ...transcript.snapshot() });
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/stop') {
    const stopped = bridge.stop();
    if (stopped) await transcript.finishStopped();
    broadcast({ type: stopped ? 'stopped' : 'status', authenticated: true, running: false, hasClaudeSessionId: Boolean(auth.getClaudeSessionId()) });
    sendJson(res, 200, { stopped });
    return;
  }

  sendJson(res, 404, { error: 'not_found' });
}

type WsSession = {
  isAuthenticated(): boolean;
  authenticate(token: string | undefined): boolean;
};

async function handleWsMessage(ws: WebSocket, raw: string, session: WsSession): Promise<void> {
  if (raw.length > MAX_BODY_BYTES) throw new Error('message_too_large');
  const msg = JSON.parse(raw) as {
    type?: string;
    text?: string;
    token?: string;
    permissionMode?: string;
    requestId?: string;
    decision?: string;
  };

  if (!session.isAuthenticated()) {
    if (msg.type !== 'auth') throw new Error('auth_required');
    if (!session.authenticate(msg.token)) {
      ws.close(1008, 'auth_failed');
      return;
    }
    return;
  }

  if (msg.type === 'stop') {
    const stopped = bridge.stop();
    if (!stopped) sendStatus(ws, true);
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
  if (!prompt) return;
  if (prompt.length > MAX_BODY_BYTES) throw new Error('prompt_too_large');
  if (bridge.isRunning()) throw new Error('claude_is_busy');
  const permissionMode = parsePermissionMode(msg.permissionMode);
  if (permissionMode === 'bypassPermissions' && !ALLOW_BYPASS_PERMISSIONS) {
    throw new Error('bypass_permissions_disabled');
  }

  transcript.beginPrompt(prompt, permissionMode);
  broadcast({ type: 'status', authenticated: true, running: true, hasClaudeSessionId: Boolean(auth.getClaudeSessionId()) });

  const runClaude = (sessionId: string | undefined) => bridge.run({
    prompt,
    sessionId,
    permissionMode,
    onEvent: event => {
      const commands = extractClaudeCommands(event);
      if (commands.length && commands.join('\n') !== commandCache.join('\n')) {
        commandCache = commands;
        broadcast({ type: 'commands', commands });
      }
      const nextSessionInfo = extractClaudeSessionInfo(event);
      if (nextSessionInfo) {
        sessionInfo = { ...sessionInfo, ...nextSessionInfo };
        transcript.setSessionInfo(nextSessionInfo);
        broadcast({ type: 'session_info', ...sessionInfo });
      }
      for (const activity of extractClaudeActivities(event)) {
        transcript.mergeActivity(activity);
        broadcast({ type: 'activity', ...activity });
      }
    },
    onText: text => {
      transcript.appendText(text);
      broadcast({ type: 'text', text });
    },
    onSessionId: sessionId => {
      transcript.setClaudeSessionId(sessionId);
      void auth.setClaudeSessionId(sessionId);
    },
    onPermissionRequest: request => {
      transcript.addPermission(request);
      broadcast(permissionRequestMessage(request));
    },
    onPermissionClosed: requestId => {
      transcript.removePermission(requestId);
      broadcast({ type: 'permission_resolved', requestId });
    },
  });

  const previousSessionId = auth.getClaudeSessionId();
  let result = await runClaude(previousSessionId);
  if (previousSessionId && result.exitCode !== 0 && isMissingConversationError(result.stderr)) {
    await auth.setClaudeSessionId(undefined);
    transcript.setClaudeSessionId(undefined);
    result = await runClaude(undefined);
  }

  if (result.sessionId) {
    transcript.setClaudeSessionId(result.sessionId);
    await auth.setClaudeSessionId(result.sessionId);
  }
  if (result.stopped) {
    await transcript.finishStopped();
    broadcast({ type: 'stopped' });
  } else {
    if (result.exitCode !== 0 && result.stderr) {
      await transcript.finishError(result.stderr);
      broadcast({ type: 'error', message: result.stderr });
    } else {
      await transcript.finishDone();
    }
    broadcast({ type: 'done', exitCode: result.exitCode, claudeSessionId: result.sessionId });
  }
  broadcast({ type: 'status', authenticated: true, running: false, hasClaudeSessionId: Boolean(auth.getClaudeSessionId()) });
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
  let body = '';
  for await (const chunk of req) {
    body += chunk.toString('utf8');
    if (body.length > MAX_BODY_BYTES) throw new Error('body_too_large');
  }
  return body ? JSON.parse(body) as T : {} as T;
}

function sendJson(res: ServerResponse, status: number, data: unknown): void {
  if (res.headersSent) return;
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(data));
}

function sendStatus(ws: WebSocket, authenticated: boolean): void {
  send(ws, { type: 'status', authenticated, running: bridge.isRunning(), hasClaudeSessionId: Boolean(auth.getClaudeSessionId()) });
}

function refreshCommands(): Promise<string[]> {
  if (commandDiscovery) return commandDiscovery;
  commandDiscovery = discoverClaudeCommands({
    claudeBin: CLAUDE_BIN,
    workspaceDir: WORKSPACE_DIR,
  }).then(commands => {
    if (commands.length) {
      commandCache = commands;
      broadcast({ type: 'commands', commands });
    }
    return commands;
  }).finally(() => {
    commandDiscovery = undefined;
  });
  return commandDiscovery;
}

function broadcast(data: unknown): void {
  for (const client of authedSockets) send(client, data);
}

function closeAllSockets(): void {
  for (const client of wss.clients) client.close(1008, 'authorization_changed');
  authedSockets.clear();
}

function send(ws: WebSocket, data: unknown): void {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(data));
}

function parsePermissionMode(value: string | undefined): ClaudePermissionMode {
  if (value === 'acceptEdits'
    || value === 'auto'
    || value === 'dontAsk'
    || value === 'plan'
    || value === 'bypassPermissions') {
    return value;
  }
  return 'manual';
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
