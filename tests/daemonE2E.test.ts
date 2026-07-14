import assert from 'node:assert/strict';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { createServer, request } from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test, { after, before } from 'node:test';
import WebSocket from 'ws';

type RunningDaemon = {
  baseUrl: string;
  child: ChildProcessWithoutNullStreams;
  nonce: string;
  root: string;
};

let daemon: RunningDaemon;

before(async () => {
  daemon = await startDaemon();
});

after(async () => {
  daemon.child.kill();
  await Promise.race([
    once(daemon.child, 'exit'),
    new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
  ]);
  await rm(daemon.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

test('daemon rejects an untrusted Host before routing the request', async () => {
  const url = new URL(daemon.baseUrl);
  const response = await rawRequest({
    hostname: url.hostname,
    port: Number(url.port),
    path: '/api/health',
    headers: { Host: 'attacker.example' },
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(JSON.parse(response.body), { error: 'bad_host' });
});

test('daemon rejects a state-changing request from an untrusted Origin', async () => {
  const response = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Origin: 'https://attacker.example',
    },
    body: JSON.stringify({ nonce: daemon.nonce }),
  });

  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { error: 'bad_origin' });
});

test('daemon never serves private state through the static file handler', async () => {
  const response = await fetch(`${daemon.baseUrl}/.data/state.json`);

  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: 'not_found' });
});

test('daemon rejects a WebSocket upgrade from an untrusted Origin', async () => {
  const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: 'https://attacker.example' },
  });
  socket.on('error', () => {});
  const statusCode = await new Promise<number>((resolveStatus, rejectStatus) => {
    socket.once('unexpected-response', (_request, response) => {
      response.resume();
      resolveStatus(response.statusCode || 0);
    });
    socket.once('open', () => rejectStatus(new Error('untrusted_websocket_opened')));
    setTimeout(() => rejectStatus(new Error('websocket_upgrade_timeout')), 5_000).unref();
  });

  assert.equal(statusCode, 401);
});

test('logout revokes the old Bearer token and closes its WebSocket', async () => {
  const pairResponse = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Origin: daemon.baseUrl,
    },
    body: JSON.stringify({ nonce: daemon.nonce }),
  });
  assert.equal(pairResponse.status, 200);
  const pairBody = await pairResponse.json() as { token: string };
  const token = pairBody.token;

  const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  await once(socket, 'open');
  socket.send(JSON.stringify({ type: 'auth', token }));
  const status = await waitForWsMessage(socket, message => message.type === 'status');
  assert.equal(status.authenticated, true);
  const closed = once(socket, 'close');

  const logoutResponse = await fetch(`${daemon.baseUrl}/api/logout`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Origin: daemon.baseUrl,
    },
  });
  assert.equal(logoutResponse.status, 200);
  await closed;

  const statusResponse = await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(statusResponse.status, 401);
});

async function startDaemon(): Promise<RunningDaemon> {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-daemon-e2e-'));
  await writeFile(join(root, 'README.md'), '# fixture\n', 'utf8');
  const port = await findFreePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const daemonPath = resolve('src/daemon.ts');
  const tsxImport = import.meta.resolve('tsx');
  const child = spawn(process.execPath, ['--import', tsxImport, daemonPath], {
    cwd: root,
    env: {
      ...process.env,
      HOST: '127.0.0.1',
      PORT: String(port),
      PUBLIC_ORIGIN: baseUrl,
      WORKSPACE_DIR: root,
      CLAUDE_BIN: join(root, 'missing-claude-executable'),
      DEVICE_NAME: 'e2e-host',
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
      const payload = JSON.parse(payloadLine) as { nonce: string };
      return { baseUrl, child, nonce: payload.nonce, root };
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

function rawRequest(options: {
  hostname: string;
  port: number;
  path: string;
  headers?: Record<string, string>;
}): Promise<{ statusCode: number; body: string }> {
  return new Promise((resolveRequest, rejectRequest) => {
    const req = request(options, response => {
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
    req.end();
  });
}

function waitForWsMessage(
  socket: WebSocket,
  predicate: (message: Record<string, unknown>) => boolean,
): Promise<Record<string, unknown>> {
  return new Promise((resolveMessage, rejectMessage) => {
    const timeout = setTimeout(() => {
      cleanup();
      rejectMessage(new Error('websocket_message_timeout'));
    }, 5_000);
    const onMessage = (data: WebSocket.RawData) => {
      const message = JSON.parse(data.toString()) as Record<string, unknown>;
      if (!predicate(message)) return;
      cleanup();
      resolveMessage(message);
    };
    const onClose = () => {
      cleanup();
      rejectMessage(new Error('websocket_closed_before_message'));
    };
    const cleanup = () => {
      clearTimeout(timeout);
      socket.off('message', onMessage);
      socket.off('close', onClose);
    };
    socket.on('message', onMessage);
    socket.on('close', onClose);
  });
}
