import assert from 'node:assert/strict';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
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
  daemon = await startGuardDaemon();
});

after(async () => {
  daemon.child.kill();
  await Promise.race([
    once(daemon.child, 'exit'),
    new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
  ]);
  await rm(daemon.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

test('unauthenticated WebSocket is closed after auth timeout', async () => {
  const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  socket.on('error', () => {});
  await once(socket, 'open');
  const [code, reason] = await once(socket, 'close') as [number, Buffer];
  assert.equal(code, 1008);
  assert.match(reason.toString(), /auth_timeout/);
});

test('invalid first WebSocket frame closes the unauthenticated socket', async () => {
  const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  socket.on('error', () => {});
  await once(socket, 'open');
  const closed = once(socket, 'close');
  socket.send(JSON.stringify({ type: 'prompt', text: 'nope' }));
  const [code] = await closed as [number, Buffer];
  assert.equal(code, 1008);
});

test('WebSocket upgrade is rejected when connection limit is reached', async () => {
  const holders: WebSocket[] = [];
  try {
    // MAX_WS_CONNECTIONS=2 in this daemon; hold both slots without auth.
    for (let i = 0; i < 2; i += 1) {
      const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
        headers: { Origin: daemon.baseUrl },
      });
      socket.on('error', () => {});
      await once(socket, 'open');
      holders.push(socket);
    }

    const blocked = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
      headers: { Origin: daemon.baseUrl },
    });
    blocked.on('error', () => {});
    const statusCode = await new Promise<number>((resolveStatus, rejectStatus) => {
      blocked.once('unexpected-response', (_request, response) => {
        response.resume();
        resolveStatus(response.statusCode || 0);
      });
      blocked.once('open', () => rejectStatus(new Error('over_limit_websocket_opened')));
      setTimeout(() => rejectStatus(new Error('websocket_upgrade_timeout')), 5_000).unref();
    });
    assert.equal(statusCode, 503);
  } finally {
    for (const socket of holders) socket.close();
  }
});

async function startGuardDaemon(): Promise<RunningDaemon> {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-daemon-ws-guard-'));
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
      DEVICE_NAME: 'ws-guard-host',
      MAX_WS_CONNECTIONS: '2',
      WS_AUTH_TIMEOUT_MS: '800',
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
