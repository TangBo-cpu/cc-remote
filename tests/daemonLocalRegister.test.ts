import assert from 'node:assert/strict';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { createServer, request as httpRequest } from 'node:http';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test, { after, before } from 'node:test';

type RunningDaemon = {
  baseUrl: string;
  child: ChildProcessWithoutNullStreams;
  root: string;
  publicHost: string;
};

let daemon: RunningDaemon;

before(async () => {
  daemon = await startRegisterDaemon();
});

after(async () => {
  daemon.child.kill();
  await Promise.race([
    once(daemon.child, 'exit'),
    new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
  ]);
  await rm(daemon.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

test('local register accepts loopback Host with a valid control token', async () => {
  const token = await localControlToken();
  const workspace = join(daemon.root, 'other-project');
  await mkdir(workspace, { recursive: true });
  await writeFile(join(workspace, 'README.md'), '# other\n', 'utf8');

  const response = await fetch(`${daemon.baseUrl}/api/local/projects/register`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-cc-remote-local-token': token,
    },
    body: JSON.stringify({ path: workspace, name: 'other' }),
  });

  assert.equal(response.status, 200);
  const body = await response.json() as { ok?: boolean; activeProjectId?: string };
  assert.equal(body.ok, true);
});

test('local register returns 400 when the workspace path does not exist', async () => {
  const token = await localControlToken();
  const missing = join(daemon.root, 'missing-project');
  const response = await fetch(`${daemon.baseUrl}/api/local/projects/register`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-cc-remote-local-token': token,
    },
    body: JSON.stringify({ path: missing }),
  });

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: 'workspace_not_found' });
});

test('local register rejects public Host even with a valid control token', async () => {
  const token = await localControlToken();
  const url = new URL(daemon.baseUrl);
  const response = await rawJsonRequest({
    hostname: url.hostname,
    port: Number(url.port),
    path: '/api/local/projects/register',
    headers: {
      Host: daemon.publicHost,
      'Content-Type': 'application/json',
      'x-cc-remote-local-token': token,
      'Content-Length': String(Buffer.byteLength('{"path":"C:\\\\nowhere"}')),
    },
    body: '{"path":"C:\\\\nowhere"}',
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(JSON.parse(response.body), { error: 'local_only' });
});

test('desktop control routes reject missing tokens, public hosts, and foreign origins', async () => {
  for (const [method, path] of [
    ['GET', '/api/local/status'],
    ['POST', '/api/local/pairing'],
    ['POST', '/api/local/shutdown'],
  ]) {
    const missingToken = await fetch(daemon.baseUrl + path, { method });
    assert.equal(missingToken.status, 401);
    const token = await localControlToken();
    const url = new URL(daemon.baseUrl);
    const publicRequest = await rawJsonRequest({
      hostname: url.hostname,
      port: Number(url.port),
      method,
      path,
      headers: { Host: daemon.publicHost, 'x-cc-remote-local-token': token },
    });
    assert.equal(publicRequest.statusCode, 403);
    const foreignOrigin = await fetch(daemon.baseUrl + path, {
      method,
      headers: { Origin: 'https://attacker.example', 'x-cc-remote-local-token': token },
    });
    assert.equal(foreignOrigin.status, 403);
  }
});

test('desktop keeps a fresh QR available for additional devices without replacing paired tokens', async () => {
  const headers = { 'x-cc-remote-local-token': await localControlToken() };
  const initial = await fetch(`${daemon.baseUrl}/api/local/status`, { headers });
  const initialStatus = await initial.json() as { paired: boolean; pairing: { payload: { nonce: string }; modules: boolean[][] } };
  assert.equal(initialStatus.paired, false);
  assert.ok(initialStatus.pairing.payload.nonce);
  assert.ok(initialStatus.pairing.modules.length >= 21);
  assert.ok(initialStatus.pairing.modules.every(row => row.length === initialStatus.pairing.modules.length));

  const refreshed = await fetch(`${daemon.baseUrl}/api/local/pairing`, { method: 'POST', headers });
  const { payload } = await refreshed.json() as { payload: { nonce: string; expiresAt: number } };
  assert.notEqual(payload.nonce, initialStatus.pairing.payload.nonce);
  const obsolete = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST',
    body: JSON.stringify({ nonce: initialStatus.pairing.payload.nonce }),
  });
  assert.equal(obsolete.status, 401);

  const paired = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST', body: JSON.stringify({ nonce: payload.nonce, deviceName: 'Pixel 9' }),
  });
  const { token, deviceId } = await paired.json() as { token: string; deviceId: string };
  assert.ok(token);
  const status = await fetch(`${daemon.baseUrl}/api/local/status`, { headers });
  const nextStatus = await status.json() as typeof initialStatus;
  assert.equal(nextStatus.paired, true);
  assert.ok(nextStatus.pairing, 'A new QR must remain available after pairing');
  assert.notEqual(nextStatus.pairing.payload.nonce, payload.nonce);
  assert.ok(nextStatus.pairing.modules.length >= 21);
  const polled = await fetch(`${daemon.baseUrl}/api/local/status`, { headers });
  assert.deepEqual((await polled.json() as typeof initialStatus).pairing, nextStatus.pairing);
  const replayed = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST', body: JSON.stringify({ nonce: payload.nonce }),
  });
  assert.equal(replayed.status, 401);

  const stillAuthorized = await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(stillAuthorized.status, 200);

  const secondPaired = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST', body: JSON.stringify({ nonce: nextStatus.pairing.payload.nonce, deviceName: 'Pixel Tablet' }),
  });
  assert.equal(secondPaired.status, 200);
  const second = await secondPaired.json() as { token: string; deviceId: string };
  assert.notEqual(second.deviceId, deviceId);

  const secondStatus = await (await fetch(`${daemon.baseUrl}/api/local/status`, { headers })).json() as typeof initialStatus;
  assert.notEqual(secondStatus.pairing.payload.nonce, nextStatus.pairing.payload.nonce);
  const manualRefresh = await fetch(`${daemon.baseUrl}/api/local/pairing`, { method: 'POST', headers });
  const manualPairing = await manualRefresh.json() as typeof initialStatus.pairing;
  assert.notEqual(manualPairing.payload.nonce, secondStatus.pairing.payload.nonce);
  const refreshedStatus = await fetch(`${daemon.baseUrl}/api/local/status`, { headers });
  assert.deepEqual((await refreshedStatus.json() as typeof initialStatus).pairing, manualPairing);

  const firstStillAuthorized = await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(firstStillAuthorized.status, 200);

  const devices = await (await fetch(`${daemon.baseUrl}/api/devices`, {
    headers: { Authorization: `Bearer ${second.token}` },
  })).json() as { devices: Array<{ id: string; name: string; current: boolean }> };
  assert.deepEqual(
    devices.devices.map(device => [device.name, device.current]),
    [['Pixel 9', false], ['Pixel Tablet', true]],
  );

  const revocation = await fetch(
    `${daemon.baseUrl}/api/devices/${encodeURIComponent(second.deviceId)}/revoke`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
    },
  );
  assert.equal(revocation.status, 200);
  assert.equal((await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${second.token}` },
  })).status, 401);
  assert.equal((await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${token}` },
  })).status, 200);
});

test('paired phone browses directories and opens a new engine session without local-control access', async () => {
  const localHeaders = { 'x-cc-remote-local-token': await localControlToken() };
  const pairing = await fetch(`${daemon.baseUrl}/api/local/pairing`, { method: 'POST', headers: localHeaders });
  const { payload } = await pairing.json() as { payload: { nonce: string } };
  const paired = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST', body: JSON.stringify({ nonce: payload.nonce }),
  });
  const { token } = await paired.json() as { token: string };
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  assert.equal((await fetch(`${daemon.baseUrl}/api/directories`)).status, 401);
  assert.equal((await fetch(`${daemon.baseUrl}/api/directories`, { headers: localHeaders })).status, 401);
  const target = join(daemon.root, 'phone 中文 app');
  await mkdir(target);
  await writeFile(join(target, 'hello.txt'), 'workspace content');
  const listing = await fetch(`${daemon.baseUrl}/api/directories?${new URLSearchParams({ path: target })}`, { headers });
  assert.equal(listing.status, 200);
  assert.equal((await listing.json() as { path: string }).path, target);
  const before = await (await fetch(`${daemon.baseUrl}/api/projects`, { headers })).json() as { activeSessionId: string; sessions: unknown[] };
  const rejected = await fetch(`${daemon.baseUrl}/api/projects/open-directory`, {
    method: 'POST', headers, body: JSON.stringify({ path: target, engine: 'unknown' }),
  });
  assert.equal(rejected.status, 400);
  const opened = await fetch(`${daemon.baseUrl}/api/projects/open-directory`, {
    method: 'POST', headers, body: JSON.stringify({ path: target, engine: 'codex' }),
  });
  assert.equal(opened.status, 201);
  const body = await opened.json() as { sessionId: string; catalog: { sessions: Array<{ id: string; engine: string }> } };
  assert.equal(body.catalog.sessions.length, before.sessions.length + 1);
  assert.equal(body.catalog.sessions.find(item => item.id === body.sessionId)?.engine, 'codex');
  const status = await (await fetch(`${daemon.baseUrl}/api/status`, { headers })).json() as { workspaceDir: string; activeSessionId: string };
  assert.equal(status.workspaceDir, target);
  assert.equal(status.activeSessionId, body.sessionId);
  const workspace = await (await fetch(`${daemon.baseUrl}/api/workspace`, { headers })).json() as { files: string[] };
  assert.ok(workspace.files.includes('hello.txt'));
  const missing = await fetch(`${daemon.baseUrl}/api/projects/open-directory`, {
    method: 'POST', headers, body: JSON.stringify({ path: join(target, 'missing'), engine: 'claude' }),
  });
  assert.equal(missing.status, 404);
  const unchanged = await (await fetch(`${daemon.baseUrl}/api/projects`, { headers })).json() as { activeSessionId: string };
  assert.equal(unchanged.activeSessionId, body.sessionId);
  assert.equal((await fetch(`${daemon.baseUrl}/api/local/projects/register`, {
    method: 'POST', headers, body: JSON.stringify({ path: target }),
  })).status, 401);
});

test('desktop shutdown exits without deleting pairing state', async () => {
  const statePath = join(daemon.root, '.data', 'state.json');
  const stateBefore = JSON.parse(await readFile(statePath, 'utf8')) as { tokenHash: string };
  const exited = once(daemon.child, 'exit');
  const response = await fetch(`${daemon.baseUrl}/api/local/shutdown`, {
    method: 'POST',
    headers: { 'x-cc-remote-local-token': await localControlToken() },
  });
  assert.equal(response.status, 200);
  await exited;
  const stateAfter = JSON.parse(await readFile(statePath, 'utf8')) as { tokenHash: string };
  assert.equal(stateAfter.tokenHash, stateBefore.tokenHash);
});

async function localControlToken(): Promise<string> {
  const raw = await readFile(join(daemon.root, '.data', 'local-control.json'), 'utf8');
  const parsed = JSON.parse(raw) as { token: string };
  assert.ok(parsed.token);
  return parsed.token;
}

async function startRegisterDaemon(): Promise<RunningDaemon> {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-daemon-local-register-'));
  await writeFile(join(root, 'README.md'), '# fixture\n', 'utf8');
  const port = await findFreePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const publicHost = 'public-cc-remote.test';
  const daemonPath = resolve('src/daemon.ts');
  const tsxImport = import.meta.resolve('tsx');
  const child = spawn(process.execPath, ['--import', tsxImport, daemonPath], {
    cwd: root,
    env: {
      ...process.env,
      HOST: '127.0.0.1',
      PORT: String(port),
      PUBLIC_ORIGIN: `https://${publicHost}`,
      WORKSPACE_DIR: root,
      CLAUDE_BIN: join(root, 'missing-claude-executable'),
      DEVICE_NAME: 'local-register-host',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
    windowsHide: true,
  });

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', chunk => {
    stdout += chunk.toString('utf8');
  });
  child.stderr.on('data', chunk => {
    stderr += chunk.toString('utf8');
  });

  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const payloadLine = stdout
      .split(/\r?\n/)
      .find(line => line.startsWith('{"type":"cc-remote-pair"'));
    if (payloadLine) {
      return { baseUrl, child, root, publicHost };
    }
    if (child.exitCode !== null) {
      throw new Error(`daemon exited early (${child.exitCode}): ${stderr || stdout}`);
    }
    await new Promise(resolveTimeout => setTimeout(resolveTimeout, 25));
  }

  child.kill();
  throw new Error(`daemon did not start in time: ${stderr || stdout}`);
}

async function findFreePort(): Promise<number> {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('free_port_not_found');
  const port = address.port;
  server.close();
  await once(server, 'close');
  return port;
}

function rawJsonRequest(options: {
  method?: string;
  hostname: string;
  port: number;
  path: string;
  headers?: Record<string, string>;
  body?: string;
}): Promise<{ statusCode: number; body: string }> {
  return new Promise((resolveRequest, rejectRequest) => {
    const req = httpRequest({
      hostname: options.hostname,
      port: options.port,
      path: options.path,
      method: options.method || 'POST',
      headers: options.headers,
      agent: false,
    }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => {
        body += chunk;
      });
      response.on('end', () => {
        resolveRequest({ statusCode: response.statusCode || 0, body });
      });
    });
    req.on('error', rejectRequest);
    if (options.body) req.write(options.body);
    req.end();
  });
}
