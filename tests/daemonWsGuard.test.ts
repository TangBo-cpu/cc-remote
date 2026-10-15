import assert from 'node:assert/strict';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import net from 'node:net';
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

test('malformed WebSocket frame does not terminate daemon', async () => {
  const raw = await openRawWebSocket(daemon.baseUrl);

  try {
    const mask = Buffer.from([0x01, 0x02, 0x03, 0x04]);
    const invalidUtf8 = Buffer.from([0xc0, 0xaf]);
    const maskedPayload = Buffer.from(
      invalidUtf8.map((value, index) => value ^ mask[index]),
    );

    raw.socket.write(Buffer.concat([
      Buffer.from([0x81, 0x80 | maskedPayload.length]),
      mask,
      maskedPayload,
    ]));

    await new Promise(resolveTimeout => setTimeout(resolveTimeout, 500));

    assert.equal(daemon.child.exitCode, null);
  } finally {
    raw.socket.destroy();
  }
});

test('heartbeat terminates a peer that does not answer ping', async () => {
  const heartbeatDaemon = await startGuardDaemon({
    WS_HEARTBEAT_INTERVAL_MS: '1000',
    WS_AUTH_TIMEOUT_MS: '5000',
  });
  let raw: Awaited<ReturnType<typeof openRawWebSocket>> | undefined;
  let timeout: ReturnType<typeof setTimeout> | undefined;

  try {
    raw = await openRawWebSocket(heartbeatDaemon.baseUrl);
    await Promise.race([
      raw.closed,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error('heartbeat_timeout')), 3000);
      }),
    ]);

    assert.equal(heartbeatDaemon.child.exitCode, null);
  } finally {
    if (timeout != null) clearTimeout(timeout);
    raw?.socket.destroy();
    heartbeatDaemon.child.kill();
    await Promise.race([
      once(heartbeatDaemon.child, 'exit'),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(heartbeatDaemon.root, {
      recursive: true,
      force: true,
      maxRetries: 3,
      retryDelay: 50,
    });
  }
});

test('invalid heartbeat interval falls back instead of creating a busy loop', async () => {
  const invalidConfigDaemon = await startGuardDaemon({
    WS_HEARTBEAT_INTERVAL_MS: 'NaN',
    WS_AUTH_TIMEOUT_MS: '5000',
  });
  let raw: Awaited<ReturnType<typeof openRawWebSocket>> | undefined;
  let keepAliveTimer: ReturnType<typeof setTimeout> | undefined;

  try {
    raw = await openRawWebSocket(invalidConfigDaemon.baseUrl);
    const closedEarly = await Promise.race([
      raw.closed.then(() => true),
      new Promise<false>(resolveOpen => {
        keepAliveTimer = setTimeout(() => resolveOpen(false), 500);
      }),
    ]);

    assert.equal(closedEarly, false);
    assert.equal(invalidConfigDaemon.child.exitCode, null);
  } finally {
    if (keepAliveTimer != null) clearTimeout(keepAliveTimer);
    raw?.socket.destroy();
    invalidConfigDaemon.child.kill();
    await Promise.race([
      once(invalidConfigDaemon.child, 'exit'),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(invalidConfigDaemon.root, {
      recursive: true,
      force: true,
      maxRetries: 3,
      retryDelay: 50,
    });
  }
});

test('authorization close fallback releases the final connection slot', async () => {
  const limitDaemon = await startGuardDaemon({
    MAX_WS_CONNECTIONS: '1',
    WS_HEARTBEAT_INTERVAL_MS: '10000',
    WS_AUTH_TIMEOUT_MS: '60000',
    WS_CLOSE_TIMEOUT_MS: '100',
  });
  let raw: Awaited<ReturnType<typeof openRawWebSocket>> | undefined;

  try {
    raw = await openRawWebSocket(limitDaemon.baseUrl);

    const pairResponse = await fetch(`${limitDaemon.baseUrl}/api/pair`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Origin: limitDaemon.baseUrl,
      },
      body: JSON.stringify({ nonce: limitDaemon.nonce }),
    });
    assert.equal(pairResponse.status, 200);
    await pairResponse.text();

    await new Promise(resolveTimeout => setTimeout(resolveTimeout, 250));

    const socket = new WebSocket(
      limitDaemon.baseUrl.replace('http:', 'ws:') + '/ws',
      { headers: { Origin: limitDaemon.baseUrl } },
    );
    socket.on('error', () => {});

    const result = await new Promise<'open' | 'rejected'>(
      (resolveResult, rejectResult) => {
        const timer = setTimeout(() => {
          rejectResult(new Error('replacement_websocket_timeout'));
        }, 750);

        socket.once('open', () => {
          clearTimeout(timer);
          socket.close();
          resolveResult('open');
        });

        socket.once('unexpected-response', (_request, response) => {
          clearTimeout(timer);
          response.resume();
          resolveResult('rejected');
        });
      },
    );

    assert.equal(result, 'open');
  } finally {
    raw?.socket.destroy();
    limitDaemon.child.kill();
    await Promise.race([
      once(limitDaemon.child, 'exit'),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(limitDaemon.root, {
      recursive: true,
      force: true,
      maxRetries: 3,
      retryDelay: 50,
    });
  }
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
    await Promise.all(holders.map(async socket => {
      if (socket.readyState === WebSocket.CLOSED) return;
      const closed = once(socket, 'close');
      socket.close();
      await closed;
    }));
  }
});

test('application probe requires authentication', async () => {
  const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  socket.on('error', () => {});
  await once(socket, 'open');
  const closed = once(socket, 'close');
  socket.send(JSON.stringify({ type: 'ping', probeId: 'probe-1' }));
  const [code] = await closed as [number, Buffer];
  assert.equal(code, 1008);
});

test('authenticated application probe echoes its id without changing the session', async () => {
  const paired = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Origin: daemon.baseUrl },
    body: JSON.stringify({ nonce: daemon.nonce }),
  });
  assert.equal(paired.status, 200);
  const { token } = await paired.json() as { token: string };
  const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  socket.on('error', () => {});
  try {
    await once(socket, 'open');
    const statusReceived = nextMessage(socket, 'status');
    socket.send(JSON.stringify({ type: 'auth', token }));
    const status = await statusReceived;
    assert.equal(status.connectionProbe, true);

    const before = await (await fetch(`${daemon.baseUrl}/api/status`, {
      headers: { Authorization: `Bearer ${token}`, Origin: daemon.baseUrl },
    })).json();
    const pongReceived = nextMessage(socket, 'pong');
    socket.send(JSON.stringify({ type: 'ping', probeId: 'probe-1' }));
    assert.deepEqual(await pongReceived, { type: 'pong', probeId: 'probe-1' });
    const after = await (await fetch(`${daemon.baseUrl}/api/status`, {
      headers: { Authorization: `Bearer ${token}`, Origin: daemon.baseUrl },
    })).json();
    assert.deepEqual(after, before);

    const invalidReceived = nextMessage(socket, 'error');
    socket.send(JSON.stringify({ type: 'ping', probeId: 'x'.repeat(129) }));
    assert.equal((await invalidReceived).message, 'invalid_probe_id');
    assert.equal(socket.readyState, WebSocket.OPEN);
  } finally {
    const closed = once(socket, 'close');
    socket.terminate();
    await closed;
  }
});

function nextMessage(socket: WebSocket, type: string): Promise<Record<string, unknown>> {
  return new Promise((resolveMessage, rejectMessage) => {
    const timer = setTimeout(() => {
      socket.off('message', onMessage);
      rejectMessage(new Error(`message_timeout:${type}`));
    }, 2000);
    const onMessage = (raw: WebSocket.RawData) => {
      const message = JSON.parse(raw.toString()) as Record<string, unknown>;
      if (message.type !== type) return;
      clearTimeout(timer);
      socket.off('message', onMessage);
      resolveMessage(message);
    };
    socket.on('message', onMessage);
  });
}

async function startGuardDaemon(
  extraEnv: Record<string, string> = {},
): Promise<RunningDaemon> {
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
      WS_AUTH_TIMEOUT_MS: '1000',
      ...extraEnv,
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

async function openRawWebSocket(baseUrl: string): Promise<{
  socket: net.Socket;
  closed: Promise<void>;
}> {
  const endpoint = new URL(baseUrl);
  const socket = net.createConnection({
    host: endpoint.hostname,
    port: Number(endpoint.port),
  });

  socket.on('error', () => {});

  await once(socket, 'connect');

  const key = randomBytes(16).toString('base64');
  socket.write(
    `GET /ws HTTP/1.1\r\n`
    + `Host: ${endpoint.host}\r\n`
    + 'Upgrade: websocket\r\n'
    + 'Connection: Upgrade\r\n'
    + `Sec-WebSocket-Key: ${key}\r\n`
    + 'Sec-WebSocket-Version: 13\r\n'
    + `Origin: ${baseUrl}\r\n`
    + '\r\n',
  );

  let response = '';
  while (!response.includes('\r\n\r\n')) {
    const [chunk] = await once(socket, 'data') as [Buffer];
    response += chunk.toString('latin1');
  }

  assert.match(response, /^HTTP\/1\.1 101 Switching Protocols/m);

  return {
    socket,
    closed: new Promise<void>(resolveClosed => {
      socket.once('close', () => resolveClosed());
    }),
  };
}
