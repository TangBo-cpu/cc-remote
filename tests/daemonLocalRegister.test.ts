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
      method: 'POST',
      headers: options.headers,
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
