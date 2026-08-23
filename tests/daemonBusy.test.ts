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

test('running task recovers across reconnect and stops after the process exits', async () => {
  const { token, sessionId, socket, inbox } = await pairAndConnect();
  const promptId = 'prompt-reconnect-1';
  let activeSocket = socket;
  try {
    activeSocket.send(JSON.stringify({
      type: 'prompt',
      promptId,
      sessionId,
      text: 'hang please',
      permissionMode: 'manual',
    }));
    const accepted = await inbox.next(message =>
      message.type === 'prompt_accepted' && message.promptId === promptId);
    assert.equal(typeof accepted.runId, 'string');
    const started = await inbox.next(message => message.type === 'status' && message.running === true);
    assert.equal(started.runId, accepted.runId);
    assert.equal(typeof started.startedAt, 'number');
    assert.equal(started.stopping, false);

    activeSocket.send(JSON.stringify({
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

    activeSocket.close();
    await once(activeSocket, 'close');

    const reconnected = await connectWithToken(token);
    activeSocket = reconnected.socket;
    const recoveredStatus = await reconnected.inbox.next(message =>
      message.type === 'status' && message.authenticated === true);
    assert.equal(recoveredStatus.running, true);
    assert.equal(recoveredStatus.stopping, false);
    assert.equal(recoveredStatus.runId, started.runId);
    assert.equal(recoveredStatus.startedAt, started.startedAt);

    const recoveredSnapshot = await reconnected.inbox.next(message =>
      message.type === 'transcript_snapshot');
    assert.equal(recoveredSnapshot.running, true);
    assert.equal(recoveredSnapshot.stopping, false);
    assert.equal(recoveredSnapshot.runId, started.runId);
    assert.equal(recoveredSnapshot.startedAt, started.startedAt);

    activeSocket.send(JSON.stringify({
      type: 'prompt',
      promptId,
      sessionId,
      text: 'hang please',
      permissionMode: 'manual',
    }));
    const duplicateAccepted = await reconnected.inbox.next(message =>
      message.type === 'prompt_accepted' && message.promptId === promptId);
    assert.equal(duplicateAccepted.runId, started.runId);

    const stopResponse = await fetch(`${daemon.baseUrl}/api/stop`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        Origin: daemon.baseUrl,
      },
    });
    assert.equal(stopResponse.status, 200);
    assert.deepEqual(await stopResponse.json(), { stopped: true });

    const stopping = await reconnected.inbox.next(message =>
      message.type === 'status' && message.stopping === true);
    assert.equal(stopping.running, true);
    assert.equal(stopping.runId, started.runId);
    assert.equal(stopping.startedAt, started.startedAt);

    const stopped = await reconnected.inbox.next(message => message.type === 'stopped');
    assert.equal(stopped.runId, started.runId);
    const finished = await reconnected.inbox.next(message =>
      message.type === 'status' && message.running === false);
    assert.equal(finished.stopping, false);
    assert.equal(finished.runId, started.runId);

    const finalStatus = await statusBody(token);
    assert.equal(finalStatus.running, false);
    assert.equal(finalStatus.stopping, false);
  } finally {
    activeSocket.close();
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
  const { socket, inbox } = await connectWithToken(token);
  return { token, sessionId: status.activeSessionId, socket, inbox };
}

async function connectWithToken(token: string): Promise<{
  socket: WebSocket;
  inbox: WsInbox;
}> {
  const socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  const inbox = new WsInbox(socket);
  await once(socket, 'open');
  socket.send(JSON.stringify({ type: 'auth', token }));
  return { socket, inbox };
}

async function statusBody(token: string): Promise<{
  activeSessionId: string;
  activeProjectId: string;
  running: boolean;
  stopping: boolean;
}> {
  const response = await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(response.status, 200);
  return await response.json() as {
    activeSessionId: string;
    activeProjectId: string;
    running: boolean;
    stopping: boolean;
  };
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
      }, 15_000);
      this.waiters.push({ predicate, resolve, reject, timer });
    });
  }
}
