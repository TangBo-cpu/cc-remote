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
  daemon = await startBusyDaemon();
});

after(async () => {
  daemon.child.kill();
  await Promise.race([
    once(daemon.child, 'exit'),
    new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
  ]);
  await rm(daemon.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

test('second concurrent prompt is rejected as claude_is_busy', async () => {
  const { token, sessionId, socket, inbox } = await pairAndConnect();
  try {
    socket.send(JSON.stringify({
      type: 'prompt',
      sessionId,
      text: 'hang please',
      permissionMode: 'manual',
    }));
    await inbox.next(message => message.type === 'status' && message.running === true);

    socket.send(JSON.stringify({
      type: 'prompt',
      sessionId,
      text: 'should be busy',
      permissionMode: 'manual',
    }));
    const busy = await inbox.next(message =>
      message.type === 'error' && String(message.message || '').includes('claude_is_busy'));
    assert.equal(busy.type, 'error');

    const createResponse = await fetch(
      `${daemon.baseUrl}/api/projects/${encodeURIComponent((await statusBody(token)).activeProjectId)}/sessions`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          Origin: daemon.baseUrl,
        },
      },
    );
    assert.equal(createResponse.status, 409);
    assert.deepEqual(await createResponse.json(), { error: 'claude_is_busy' });

    socket.send(JSON.stringify({ type: 'stop' }));
    await inbox.next(message =>
      message.type === 'stopped'
      || (message.type === 'status' && message.running === false));
  } finally {
    socket.close();
  }
});

async function pairAndConnect(): Promise<{
  token: string;
  sessionId: string;
  socket: WebSocket;
  inbox: WsInbox;
}> {
  const pairResponse = await fetch(`${daemon.baseUrl}/api/pair`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Origin: daemon.baseUrl,
    },
    body: JSON.stringify({ nonce: daemon.nonce }),
  });
  assert.equal(pairResponse.status, 200);
  const { token } = await pairResponse.json() as { token: string };
  const status = await statusBody(token);

  const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  const inbox = new WsInbox(socket);
  await once(socket, 'open');
  socket.send(JSON.stringify({ type: 'auth', token }));
  await inbox.next(message => message.type === 'status' && message.authenticated === true);
  return { token, sessionId: status.activeSessionId, socket, inbox };
}

async function statusBody(token: string): Promise<{ activeSessionId: string; activeProjectId: string }> {
  const response = await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(response.status, 200);
  return await response.json() as { activeSessionId: string; activeProjectId: string };
}

async function startBusyDaemon(): Promise<RunningDaemon> {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-daemon-busy-'));
  await writeFile(join(root, 'README.md'), '# fixture\n', 'utf8');
  const port = await findFreePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const daemonPath = resolve('src/daemon.ts');
  const fixture = resolve('tests/fixtures/fakeClaude.mjs');
  const tsxImport = import.meta.resolve('tsx');
  const child = spawn(process.execPath, ['--import', tsxImport, daemonPath], {
    cwd: root,
    env: {
      ...process.env,
      HOST: '127.0.0.1',
      PORT: String(port),
      PUBLIC_ORIGIN: baseUrl,
      WORKSPACE_DIR: root,
      CLAUDE_BIN: process.execPath,
      CLAUDE_ARGS: `${fixture}|--fake-mode=hang-tree`,
      DEVICE_NAME: 'busy-host',
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

class WsInbox {
  private readonly queue: Record<string, unknown>[] = [];
  private readonly waiters: Array<{
    predicate: (message: Record<string, unknown>) => boolean;
    resolve: (message: Record<string, unknown>) => void;
    reject: (error: Error) => void;
    timer: NodeJS.Timeout;
  }> = [];

  constructor(private readonly socket: WebSocket) {
    socket.on('message', data => {
      const message = JSON.parse(data.toString()) as Record<string, unknown>;
      const index = this.waiters.findIndex(waiter => waiter.predicate(message));
      if (index >= 0) {
        const [waiter] = this.waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(message);
        return;
      }
      this.queue.push(message);
    });
    socket.on('close', () => {
      for (const waiter of this.waiters.splice(0)) {
        clearTimeout(waiter.timer);
        waiter.reject(new Error('websocket_closed_before_message'));
      }
    });
  }

  next(predicate: (message: Record<string, unknown>) => boolean): Promise<Record<string, unknown>> {
    const queuedIndex = this.queue.findIndex(predicate);
    if (queuedIndex >= 0) {
      const [message] = this.queue.splice(queuedIndex, 1);
      return Promise.resolve(message);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.waiters.findIndex(item => item.timer === timer);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(new Error('websocket_message_timeout'));
      }, 8_000);
      this.waiters.push({ predicate, resolve, reject, timer });
    });
  }
}
