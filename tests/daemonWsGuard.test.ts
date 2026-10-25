import assert from 'node:assert/strict';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { createServer, request } from 'node:http';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
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

test('malformed upgrade URLs and Hosts are rejected without terminating daemon', async () => {
  const instance = await startGuardDaemon();
  try {
    const endpoint = new URL(instance.baseUrl);
    for (const [path, host, status] of [
      ['//[', endpoint.host, 400],
      ['/ws', '[', 401],
    ] as const) {
      const socket = net.createConnection({ host: endpoint.hostname, port: Number(endpoint.port) });
      socket.setTimeout(2000, () => socket.destroy(new Error('upgrade_response_timeout')));
      let response = '';
      socket.on('data', chunk => { response += chunk.toString('latin1'); });
      const closed = once(socket, 'close');
      try {
        await once(socket, 'connect');
        socket.write(`GET ${path} HTTP/1.1\r\nHost: ${host}\r\nConnection: Upgrade\r\n`
          + 'Upgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
          + 'Sec-WebSocket-Version: 13\r\n\r\n');
        await closed;
        assert.match(response, new RegExp(`^HTTP/1.1 ${status} `));
        assert.equal((await fetch(instance.baseUrl + '/api/health')).status, 200);
      } finally {
        socket.destroy();
      }
    }
  } finally {
    instance.child.kill();
    if (instance.child.exitCode === null) await once(instance.child, 'exit');
    await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('HTTP JSON preserves UTF-8 across chunks and limits bytes', async () => {
  const instance = await startGuardDaemon();
  try {
    const paired = await fetch(instance.baseUrl + '/api/pair', {
      method: 'POST', headers: { Origin: instance.baseUrl },
      body: JSON.stringify({ nonce: instance.nonce }),
    });
    const { token } = await paired.json() as { token: string };
    const headers = { Authorization: `Bearer ${token}`, Origin: instance.baseUrl };
    const status = await (await fetch(instance.baseUrl + '/api/status', { headers })).json() as { activeSessionId: string };
    const body = Buffer.from(JSON.stringify({ title: '中文标题' }));
    const split = body.indexOf(Buffer.from('中')) + 1;
    const response = await new Promise<{ status: number; body: string }>((resolveResponse, rejectResponse) => {
      const req = request(`${instance.baseUrl}/api/sessions/${status.activeSessionId}/title`, {
        method: 'POST', headers: { ...headers, 'Content-Length': body.length },
      }, res => {
        const chunks: Buffer[] = [];
        res.on('data', chunk => chunks.push(chunk));
        res.on('error', rejectResponse);
        res.on('end', () => resolveResponse({ status: res.statusCode!, body: Buffer.concat(chunks).toString('utf8') }));
      });
      req.on('error', rejectResponse);
      req.write(body.subarray(0, split));
      setTimeout(() => req.end(body.subarray(split)), 50);
    });
    assert.equal(response.status, 200);
    const catalog = JSON.parse(response.body) as { sessions: Array<{ id: string; title: string }> };
    assert.equal(catalog.sessions.find(session => session.id === status.activeSessionId)?.title, '中文标题');
    const oversized = await fetch(instance.baseUrl + '/api/pair', {
      method: 'POST', headers: { Origin: instance.baseUrl },
      body: JSON.stringify({ nonce: '中'.repeat(24_000) }),
    });
    assert.deepEqual(await oversized.json(), { error: 'body_too_large' });
    assert.equal((await fetch(instance.baseUrl + '/api/health')).status, 200);
  } finally {
    instance.child.kill();
    if (instance.child.exitCode === null) await once(instance.child, 'exit');
    await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

for (const sizeMiB of [1, 12]) {
  test(`large snapshots sync, slow readers disconnect, and history survives reconnect (${sizeMiB} MiB)`, async () => {
    const text = 'x'.repeat(sizeMiB * 1024 * 1024);
    const instance = await startGuardDaemon({ WS_AUTH_TIMEOUT_MS: '10000' }, text);
    let socket: WebSocket | undefined;
    try {
      const paired = await fetch(instance.baseUrl + '/api/pair', {
        method: 'POST', headers: { Origin: instance.baseUrl },
        body: JSON.stringify({ nonce: instance.nonce }),
      });
      const { token } = await paired.json() as { token: string };
      const headers = { Authorization: `Bearer ${token}`, Origin: instance.baseUrl };
      const connect = async () => {
        const peer = new WebSocket(instance.baseUrl.replace('http:', 'ws:') + '/ws', { headers: { Origin: instance.baseUrl } });
        peer.on('error', () => {});
        socket = peer;
        await once(peer, 'open');
        const snapshot = nextMessage(peer, 'transcript_snapshot');
        peer.send(JSON.stringify({ type: 'auth', token }));
        assert.equal(((await snapshot).messages as Array<{ text: string }>)[0].text, text);
        const pong = nextMessage(peer, 'pong');
        peer.send(JSON.stringify({ type: 'ping', probeId: 'after-snapshot' }));
        await pong;
        return peer;
      };
      const slow = await connect();
      const closed = once(slow, 'close');
      slow.pause();
      for (let i = 0; i < Math.ceil(48 / sizeMiB); i += 1) {
        const selected = await fetch(instance.baseUrl + '/api/sessions/seed-session/select', { method: 'POST', headers });
        assert.equal(selected.status, 200);
        await selected.arrayBuffer();
      }
      slow.resume();
      let timer: NodeJS.Timeout | undefined;
      try {
        await Promise.race([closed, new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('slow_reader_not_disconnected')), 3000);
        })]);
      } finally {
        clearTimeout(timer);
      }
      assert.equal(instance.child.exitCode, null);
      await connect();
    } finally {
      socket?.terminate();
      instance.child.kill();
      if (instance.child.exitCode === null) await once(instance.child, 'exit');
      await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}

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

test('device revocation close fallback releases the final connection slot', async () => {
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
      body: JSON.stringify({ nonce: limitDaemon.nonce, deviceName: 'Raw client' }),
    });
    assert.equal(pairResponse.status, 200);
    const { token, deviceId } = await pairResponse.json() as { token: string; deviceId: string };

    // Authenticate the raw socket so the daemon tracks it as the device socket.
    // The raw client never answers close frames, so revocation must fall back
    // to terminate() to release the single connection slot.
    const authFrame = Buffer.from(JSON.stringify({ type: 'auth', token }), 'utf8');
    const mask = randomBytes(4);
    const maskedAuth = Buffer.from(authFrame.map((value, index) => value ^ mask[index % 4]));
    raw.socket.write(Buffer.concat([
      Buffer.from([0x81, 0x80 | maskedAuth.length]),
      mask,
      maskedAuth,
    ]));
    await new Promise(resolveTimeout => setTimeout(resolveTimeout, 250));

    const revokeResponse = await fetch(
      `${limitDaemon.baseUrl}/api/devices/${encodeURIComponent(deviceId)}/revoke`,
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, Origin: limitDaemon.baseUrl },
      },
    );
    assert.equal(revokeResponse.status, 200);
    await Promise.race([
      raw.closed,
      new Promise<never>((_, rejectTimeout) => {
        setTimeout(() => rejectTimeout(new Error('revoked_raw_socket_not_terminated')), 2_000);
      }),
    ]);

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
    assert.equal(status.multiDevice, true);

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
  transcriptText?: string,
): Promise<RunningDaemon> {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-daemon-ws-guard-'));
  await writeFile(join(root, 'README.md'), '# fixture\n', 'utf8');
  if (transcriptText) {
    await mkdir(join(root, '.data', 'sessions'), { recursive: true });
    const now = Date.now();
    await writeFile(join(root, '.data', 'projects.json'), JSON.stringify({
      version: 1, activeProjectId: 'seed-project', activeSessionId: 'seed-session',
      projects: [{ id: 'seed-project', name: 'fixture', path: root, createdAt: now, updatedAt: now }],
      sessions: [{ id: 'seed-session', projectId: 'seed-project', title: 'fixture', engine: 'claude', createdAt: now, updatedAt: now }],
    }));
    await writeFile(join(root, '.data', 'sessions', 'seed-session.json'), JSON.stringify({
      version: 1, revision: 1, running: false, updatedAt: now, permissionMode: 'auto',
      sessionInfo: {}, messages: [{ role: 'assistant', text: transcriptText }],
    }));
  }
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
