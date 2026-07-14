import assert from 'node:assert/strict';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import WebSocket, { type RawData } from 'ws';

const LIVE = process.env.CC_REMOTE_LIVE_E2E === '1';

test('live daemon resumes a Claude session and stops a long response', {
  skip: !LIVE,
  timeout: 180_000,
}, async () => {
  const daemon = await startLiveDaemon();
  let socket: WebSocket | undefined;
  try {
    const pairResponse = await fetch(`${daemon.baseUrl}/api/pair`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Origin: daemon.baseUrl },
      body: JSON.stringify({ nonce: daemon.nonce }),
    });
    assert.equal(pairResponse.status, 200);
    const { token } = await pairResponse.json() as { token: string };

    const statusResponse = await fetch(`${daemon.baseUrl}/api/status`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const status = await statusResponse.json() as { activeSessionId: string };

    socket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
      headers: { Origin: daemon.baseUrl },
    });
    const inbox = new WsInbox(socket);
    await once(socket, 'open');
    socket.send(JSON.stringify({ type: 'auth', token }));
    await inbox.next(message => message.type === 'status' && message.authenticated === true);

    const verificationWord = `ORBIT-${Date.now()}`;
    const first = await runPrompt(socket, inbox, status.activeSessionId,
      `Remember the verification word ${verificationWord}. Reply with only FIRST_OK.`);
    assert.match(first, /FIRST_OK/i);

    const second = await runPrompt(socket, inbox, status.activeSessionId,
      'Reply with only the verification word from my previous message.');
    assert.match(second, new RegExp(verificationWord, 'i'));

    inbox.discard(message => message.type === 'status');
    socket.send(JSON.stringify({
      type: 'prompt',
      sessionId: status.activeSessionId,
      text: 'Count upward from 1 to 100000, writing one number per line. Do not stop early.',
      permissionMode: 'manual',
    }));
    await inbox.next(message => message.type === 'status' && message.running === true);
    const stoppedEvent = inbox.next(message => message.type === 'stopped');
    const stopResponse = await fetch(`${daemon.baseUrl}/api/stop`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, Origin: daemon.baseUrl },
    });
    assert.equal(stopResponse.status, 200);
    assert.equal((await stopResponse.json() as { stopped: boolean }).stopped, true);
    await stoppedEvent;

    const finalStatusResponse = await fetch(`${daemon.baseUrl}/api/status`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    assert.equal((await finalStatusResponse.json() as { running: boolean }).running, false);
  } finally {
    socket?.close();
    await stopProcessTree(daemon.child);
    try {
      await rm(daemon.root, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    } catch (error) {
      if (!(error instanceof Error && 'code' in error && error.code === 'EBUSY')) throw error;
    }
  }
});

async function runPrompt(
  socket: WebSocket,
  inbox: WsInbox,
  sessionId: string,
  text: string,
): Promise<string> {
  inbox.discard(message => message.type === 'status');
  socket.send(JSON.stringify({ type: 'prompt', sessionId, text, permissionMode: 'manual' }));
  let output = '';
  while (true) {
    const message = await inbox.next(candidate =>
      candidate.sessionId === sessionId
      && (candidate.type === 'text' || candidate.type === 'done' || candidate.type === 'error'));
    if (message.type === 'text') output += String(message.text || '');
    if (message.type === 'error') throw new Error(String(message.message || 'live_prompt_failed'));
    if (message.type === 'done') {
      await inbox.next(candidate =>
        candidate.type === 'status'
        && candidate.sessionId === sessionId
        && candidate.running === false);
      return output;
    }
  }
}

class WsInbox {
  private readonly messages: Record<string, unknown>[] = [];
  private readonly waiters: Array<{
    predicate: (message: Record<string, unknown>) => boolean;
    resolve: (message: Record<string, unknown>) => void;
    reject: (error: Error) => void;
    timer: NodeJS.Timeout;
  }> = [];

  constructor(socket: WebSocket) {
    socket.on('message', (data: RawData) => this.push(JSON.parse(data.toString())));
    socket.on('close', () => this.fail(new Error('websocket_closed')));
    socket.on('error', error => this.fail(error));
  }

  next(
    predicate: (message: Record<string, unknown>) => boolean,
    timeoutMs = 90_000,
  ): Promise<Record<string, unknown>> {
    const index = this.messages.findIndex(predicate);
    if (index >= 0) return Promise.resolve(this.messages.splice(index, 1)[0]);
    return new Promise((resolveMessage, rejectMessage) => {
      const waiter = {
        predicate,
        resolve: resolveMessage,
        reject: rejectMessage,
        timer: setTimeout(() => {
          this.remove(waiter);
          rejectMessage(new Error('websocket_message_timeout'));
        }, timeoutMs),
      };
      this.waiters.push(waiter);
    });
  }

  discard(predicate: (message: Record<string, unknown>) => boolean): void {
    for (let index = this.messages.length - 1; index >= 0; index -= 1) {
      if (predicate(this.messages[index])) this.messages.splice(index, 1);
    }
  }

  private push(message: Record<string, unknown>): void {
    const index = this.waiters.findIndex(waiter => waiter.predicate(message));
    if (index < 0) {
      this.messages.push(message);
      return;
    }
    const [waiter] = this.waiters.splice(index, 1);
    clearTimeout(waiter.timer);
    waiter.resolve(message);
  }

  private fail(error: Error): void {
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
  }

  private remove(waiter: typeof this.waiters[number]): void {
    const index = this.waiters.indexOf(waiter);
    if (index >= 0) this.waiters.splice(index, 1);
  }
}

async function startLiveDaemon(): Promise<{
  baseUrl: string;
  child: ChildProcessWithoutNullStreams;
  nonce: string;
  root: string;
}> {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-live-e2e-'));
  await writeFile(join(root, 'README.md'), '# live reliability fixture\n', 'utf8');
  const port = await findFreePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const child = spawn(process.execPath, [
    '--import', import.meta.resolve('tsx'), resolve('src/daemon.ts'),
  ], {
    cwd: root,
    env: {
      ...process.env,
      HOST: '127.0.0.1',
      PORT: String(port),
      PUBLIC_ORIGIN: baseUrl,
      WORKSPACE_DIR: root,
      DEVICE_NAME: 'live-e2e-host',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
    windowsHide: true,
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', chunk => { stderr += chunk.toString('utf8'); });

  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const payloadLine = stdout.split(/\r?\n/)
      .find(line => line.startsWith('{"type":"cc-remote-pair"'));
    if (payloadLine) {
      return {
        baseUrl,
        child,
        nonce: (JSON.parse(payloadLine) as { nonce: string }).nonce,
        root,
      };
    }
    if (child.exitCode !== null) throw new Error(stderr || stdout || 'daemon_exited');
    await new Promise(resolveTimeout => setTimeout(resolveTimeout, 25));
  }
  child.kill();
  throw new Error(stderr || stdout || 'daemon_start_timeout');
}

async function findFreePort(): Promise<number> {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('free_port_not_found');
  server.close();
  await once(server, 'close');
  return address.port;
}

async function stopProcessTree(child: ChildProcessWithoutNullStreams): Promise<void> {
  if (child.exitCode !== null) return;
  const exited = once(child, 'exit');
  if (process.platform === 'win32' && child.pid) {
    const killer = spawn('taskkill', ['/pid', String(child.pid), '/t', '/f'], {
      stdio: 'ignore',
      windowsHide: true,
    });
    await Promise.race([
      once(killer, 'exit'),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 5_000)),
    ]);
  } else {
    child.kill('SIGTERM');
  }
  await Promise.race([
    exited,
    new Promise(resolveTimeout => setTimeout(resolveTimeout, 5_000)),
  ]);
}
