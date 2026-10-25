import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { createServer, request } from 'node:http';
import { appendFile, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
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

test('session search requires bearer authentication', async () => {
  const response = await fetch(`${daemon.baseUrl}/api/search/sessions?q=history`);

  assert.equal(response.status, 401);
});

test('session center APIs persist pin and restore, broadcast catalogs and filter search', async () => {
  const instance = await startDaemon();
  let socket: WebSocket | undefined;
  try {
    assert.equal((await fetch(instance.baseUrl + '/api/sessions/missing/restore', {
      method: 'POST', headers: { Origin: instance.baseUrl },
    })).status, 401);
    const paired = await fetch(instance.baseUrl + '/api/pair', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Origin: instance.baseUrl },
      body: JSON.stringify({ nonce: instance.nonce }),
    });
    const { token } = await paired.json() as { token: string };
    const headers = { Authorization: 'Bearer ' + token, Origin: instance.baseUrl, 'Content-Type': 'application/json' };
    const status = await fetch(instance.baseUrl + '/api/status', { headers });
    const initial = await status.json() as { activeProjectId: string; activeSessionId: string };
    const created = await fetch(instance.baseUrl + '/api/projects/' + initial.activeProjectId + '/sessions', {
      method: 'POST', headers, body: JSON.stringify({ engine: 'codex' }),
    });
    assert.equal(created.status, 201);
    const { sessionId } = await created.json() as { sessionId: string };
    socket = new WebSocket(instance.baseUrl.replace('http:', 'ws:') + '/ws', { headers: { Origin: instance.baseUrl } });
    await once(socket, 'open');
    socket.send(JSON.stringify({ type: 'auth', token }));
    await waitForWsMessage(socket, message => message.type === 'status');
    const catalogUpdate = waitForWsMessage(socket, message => message.type === 'catalog'
      && Array.isArray(message.sessions) && message.sessions.some((item: any) => item.id === sessionId && item.pinned));
    const pinned = await fetch(instance.baseUrl + '/api/sessions/' + sessionId + '/pin', {
      method: 'POST', headers, body: JSON.stringify({ pinned: true }),
    });
    assert.equal(pinned.status, 200);
    await catalogUpdate;
    assert.equal((await fetch(instance.baseUrl + '/api/sessions/' + sessionId + '/pin', {
      method: 'POST', headers, body: JSON.stringify({ pinned: 'true' }),
    })).status, 400);
    assert.equal((await fetch(instance.baseUrl + '/api/sessions/' + sessionId + '/title', {
      method: 'POST', headers, body: JSON.stringify({ title: 'needle session' }),
    })).status, 200);
    assert.equal((await fetch(instance.baseUrl + '/api/sessions/' + sessionId + '/archive', {
      method: 'POST', headers,
    })).status, 200);
    const search = await fetch(instance.baseUrl + '/api/search/sessions?q=needle&engine=codex&archived=true&projectId='
      + initial.activeProjectId + '&limit=1', { headers });
    assert.equal(search.status, 200);
    const { results } = await search.json() as { results: Array<{ sessionId: string }> };
    assert.equal(results[0]?.sessionId, sessionId);
    assert.equal((await fetch(instance.baseUrl + '/api/search/sessions?q=needle&engine=invalid', { headers })).status, 400);
    assert.equal((await fetch(instance.baseUrl + '/api/search/sessions?q=needle&archived=invalid', { headers })).status, 400);
    const restored = await fetch(instance.baseUrl + '/api/sessions/' + sessionId + '/restore', { method: 'POST', headers });
    assert.equal(restored.status, 200);
    const catalog = await restored.json() as { activeSessionId: string; sessions: Array<{ id: string; pinned: boolean; archived: boolean }> };
    assert.equal(catalog.activeSessionId, initial.activeSessionId);
    assert.equal(catalog.sessions.find(item => item.id === sessionId)?.pinned, true);
    assert.equal(catalog.sessions.find(item => item.id === sessionId)?.archived, false);
  } finally {
    socket?.terminate();
    instance.child.kill();
    await Promise.race([
      instance.child.exitCode === null ? once(instance.child, 'exit') : Promise.resolve(),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
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

  const searchResponse = await fetch(`${daemon.baseUrl}/api/search/sessions?q=missing`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(searchResponse.status, 200);
  assert.deepEqual(await searchResponse.json(), { query: 'missing', results: [] });

  const invalidSearchResponse = await fetch(`${daemon.baseUrl}/api/search/sessions`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(invalidSearchResponse.status, 400);

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

test('revoking one device closes only its WebSocket and notifies the others', async () => {
  const localControl = JSON.parse(
    await readFile(join(daemon.root, '.data', 'local-control.json'), 'utf8'),
  ) as { token: string };
  const pairHeaders = {
    'Content-Type': 'application/json',
    Origin: daemon.baseUrl,
    'x-cc-remote-local-token': localControl.token,
  };

  const pairAs = async (deviceName: string, nonce: string) => {
    const response = await fetch(`${daemon.baseUrl}/api/pair`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Origin: daemon.baseUrl,
      },
      body: JSON.stringify({ nonce, deviceName }),
    });
    assert.equal(response.status, 200);
    return await response.json() as { token: string; deviceId: string };
  };

  const phonePairing = await fetch(`${daemon.baseUrl}/api/local/pairing`, {
    method: 'POST',
    headers: pairHeaders,
  });
  const { payload: phonePayload } = await phonePairing.json() as { payload: { nonce: string } };
  const phone = await pairAs('Pixel 9', phonePayload.nonce);
  const phoneSocket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  phoneSocket.on('error', () => {});
  await once(phoneSocket, 'open');
  phoneSocket.send(JSON.stringify({ type: 'auth', token: phone.token }));
  assert.equal((await waitForWsMessage(phoneSocket, message => message.type === 'status')).authenticated, true);
  const devicesBroadcast = waitForWsMessage(phoneSocket, message => message.type === 'devices');

  const refreshed = await fetch(`${daemon.baseUrl}/api/local/pairing`, {
    method: 'POST',
    headers: pairHeaders,
  });
  const { payload } = await refreshed.json() as { payload: { nonce: string } };
  const tablet = await pairAs('Pixel Tablet', payload.nonce);

  const tabletSocket = new WebSocket(daemon.baseUrl.replace('http:', 'ws:') + '/ws', {
    headers: { Origin: daemon.baseUrl },
  });
  tabletSocket.on('error', () => {});
  await once(tabletSocket, 'open');
  tabletSocket.send(JSON.stringify({ type: 'auth', token: tablet.token }));
  assert.equal((await waitForWsMessage(tabletSocket, message => message.type === 'status')).authenticated, true);
  const tabletClosed = once(tabletSocket, 'close');

  const revokeResponse = await fetch(
    `${daemon.baseUrl}/api/devices/${encodeURIComponent(tablet.deviceId)}/revoke`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${phone.token}`, Origin: daemon.baseUrl },
    },
  );
  assert.equal(revokeResponse.status, 200);
  await tabletClosed;

  const broadcast = await devicesBroadcast;
  assert.deepEqual(
    (broadcast.devices as Array<{ name: string; current: boolean }>).map(device => [device.name, device.current]),
    [['Pixel 9', true]],
  );
  assert.equal(phoneSocket.readyState, WebSocket.OPEN);

  assert.equal((await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${phone.token}` },
  })).status, 200);
  assert.equal((await fetch(`${daemon.baseUrl}/api/status`, {
    headers: { Authorization: `Bearer ${tablet.token}` },
  })).status, 401);

  phoneSocket.terminate();
  await once(phoneSocket, 'close');
});

test('daemon exposes existing Claude app sessions and syncs renamed desktop titles', async () => {
  const sessionId = randomUUID();
  const historyDaemon = await startDaemon({ staleSessionId: sessionId, nativeHistory: true });
  const nativePath = join(historyDaemon.root, '.claude', 'projects', 'fixture', `${sessionId}.jsonl`);
  try {
    const entries = (await readFile(nativePath, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
    assert.equal(entries[0].entrypoint, 'cc-app');
    assert.equal(entries[0].message.content, 'existing phone conversation');
    assert.equal(entries.at(-1).customTitle, '当前会话');
    const response = await fetch(`${historyDaemon.baseUrl}/api/pair`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Origin: historyDaemon.baseUrl },
      body: JSON.stringify({ nonce: historyDaemon.nonce }),
    });
    const { token } = await response.json() as { token: string };
    const catalog = JSON.parse(await readFile(join(historyDaemon.root, '.data', 'projects.json'), 'utf8'));
    const renameResponse = await fetch(`${historyDaemon.baseUrl}/api/sessions/${catalog.activeSessionId}/title`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json', Origin: historyDaemon.baseUrl,
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ title: '手机上的摄像头会话' }),
    });
    assert.equal(renameResponse.status, 200);
    const renamed = (await readFile(nativePath, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
    assert.equal(renamed.at(-1).customTitle, '手机上的摄像头会话');
  } finally {
    historyDaemon.child.kill();
    await Promise.race([once(historyDaemon.child, 'exit'), new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000))]);
    await rm(historyDaemon.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('daemon retries a prompt without a stale Claude session id', async () => {
  const staleSessionId = 'stale-session-id';
  const fixture = resolve('tests/fixtures/fakeClaude.mjs');
  const retryDaemon = await startDaemon({
    staleSessionId,
    claudeBin: process.execPath,
    claudeArgs: root => [
      fixture,
      '--fake-mode=stale-resume',
      `--fake-log=${join(root, 'claude-args.jsonl')}`,
    ],
  });
  let socket: WebSocket | undefined;
  try {
    const pairResponse = await fetch(`${retryDaemon.baseUrl}/api/pair`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Origin: retryDaemon.baseUrl },
      body: JSON.stringify({ nonce: retryDaemon.nonce }),
    });
    assert.equal(pairResponse.status, 200);
    const { token } = await pairResponse.json() as { token: string };
    const statusResponse = await fetch(`${retryDaemon.baseUrl}/api/status`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const { activeSessionId } = await statusResponse.json() as { activeSessionId: string };

    socket = new WebSocket(retryDaemon.baseUrl.replace('http:', 'ws:') + '/ws', {
      headers: { Origin: retryDaemon.baseUrl },
    });
    await once(socket, 'open');
    socket.send(JSON.stringify({ type: 'auth', token }));
    await waitForWsMessage(socket, message => message.type === 'status' && message.authenticated === true);

    const promptResult = waitForPromptResult(socket, activeSessionId);
    socket.send(JSON.stringify({
      type: 'prompt',
      sessionId: activeSessionId,
      text: 'retry stale session',
      permissionMode: 'manual',
      effort: 'xhigh',
    }));
    const result = await promptResult;

    assert.equal(result.text, 'fake reply');
    assert.equal(result.claudeSessionId, 'fake-session-id');
    const invocations = (await readFile(join(retryDaemon.root, 'claude-args.jsonl'), 'utf8'))
      .trim()
      .split(/\r?\n/)
      .map(line => JSON.parse(line) as string[]);
    assert.equal(invocations.length, 2);
    assert.deepEqual(invocations[0].slice(-2), ['--resume', staleSessionId]);
    const effortIndex = invocations[0].indexOf('--effort');
    assert.deepEqual(invocations[0].slice(effortIndex, effortIndex + 2), [
      '--effort',
      'xhigh',
    ]);
    assert.equal(invocations[1].includes('--resume'), false);
    assert.equal(invocations[1].includes('xhigh'), true);
  } finally {
    socket?.close();
    retryDaemon.child.kill();
    await Promise.race([
      retryDaemon.child.exitCode === null ? once(retryDaemon.child, 'exit') : Promise.resolve(),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(retryDaemon.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

for (const mode of ['compact-success', 'compact-failed', 'compact-empty']) {
  test('Claude compact reports its outcome and allows the next prompt (' + mode + ')', async () => {
    const nativeId = randomUUID();
    const instance = await startDaemon({
      claudeBin: process.execPath,
      claudeArgs: root => [resolve('tests/fixtures/fakeClaude.mjs'), '--fake-mode=' + mode,
        '--fake-session=' + nativeId,
        '--fake-history=' + join(root, '.claude', 'projects', 'fixture', nativeId + '.jsonl')],
    });
    let socket: WebSocket | undefined;
    try {
      const paired = await fetch(instance.baseUrl + '/api/pair', {
        method: 'POST', headers: { Origin: instance.baseUrl, 'Content-Type': 'application/json' },
        body: JSON.stringify({ nonce: instance.nonce }),
      });
      const { token } = await paired.json() as { token: string };
      const headers = { Origin: instance.baseUrl, Authorization: 'Bearer ' + token };
      const status = await fetch(instance.baseUrl + '/api/status', { headers });
      const { activeSessionId: sessionId } = await status.json() as { activeSessionId: string };
      socket = new WebSocket(instance.baseUrl.replace('http:', 'ws:') + '/ws', {
        headers: { Origin: instance.baseUrl },
      });
      await once(socket, 'open');
      const authenticated = waitForWsMessage(socket, message => message.type === 'status' && message.authenticated === true);
      socket.send(JSON.stringify({ type: 'auth', token }));
      await authenticated;
      const run = async (text: string) => {
        const result = waitForPromptResult(socket!, sessionId);
        socket!.send(JSON.stringify({ type: 'prompt', sessionId, text }));
        return result;
      };
      if (mode !== 'compact-empty') assert.equal((await run('before compact')).text, 'fake reply');
      const received: Array<Record<string, unknown>> = [];
      socket.on('message', data => received.push(JSON.parse(data.toString())));
      const completed = waitForWsMessage(socket, message => message.type === 'done' && message.sessionId === sessionId);
      socket.send(JSON.stringify({ type: 'prompt', sessionId, text: '/compact' }));
      const done = await completed;
      assert.equal(done.exitCode, mode === 'compact-success' ? 0 : 1);
      assert.equal(received.filter(message => message.type === 'error').length,
        mode === 'compact-success' ? 0 : 1);
      assert.equal(received.filter(message => message.type === 'text')
        .map(message => message.text).join(''), mode === 'compact-success' ? '上下文压缩完成。' : '');
      assert.equal((await run('after compact')).text, 'fake reply');
      const current = await fetch(instance.baseUrl + '/api/sessions/' + sessionId, { headers });
      const { transcript } = await current.json() as { transcript: {
        messages: Array<{ role: string; text: string; nativeLocalOnly?: boolean }>;
      } };
      assert.equal(transcript.messages.find(message => message.text === '/compact')?.nativeLocalOnly, true);
      assert.equal(transcript.messages.some(message => message.text.includes('本轮没有返回文本')), false);
      assert.equal(transcript.messages.filter(message => mode === 'compact-success'
        ? message.text === '上下文压缩完成。' : message.role === 'system' && message.text.startsWith('错误：')).length, 1);
    } finally {
      socket?.close();
      instance.child.kill();
      await Promise.race([
        instance.child.exitCode === null ? once(instance.child, 'exit') : Promise.resolve(),
        new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
      ]);
      await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}

test('daemon persists and resumes a Codex session without invoking the Claude bridge', async () => {
  const claudeFixture = resolve('tests/fixtures/fakeClaude.mjs');
  const codexFixture = resolve('tests/fixtures/fakeCodex.mjs');
  const codexDaemon = await startDaemon({
    claudeBin: process.execPath,
    claudeArgs: root => [
      claudeFixture,
      `--fake-log=${join(root, 'claude-args.jsonl')}`,
    ],
    codexBin: process.execPath,
    codexArgs: root => [
      codexFixture,
      `--fake-log=${join(root, 'codex-args.jsonl')}`,
      '--fake-record-cwd=1',
    ],
  });
  let socket: WebSocket | undefined;
  try {
    const pairResponse = await fetch(`${codexDaemon.baseUrl}/api/pair`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Origin: codexDaemon.baseUrl,
      },
      body: JSON.stringify({ nonce: codexDaemon.nonce }),
    });
    assert.equal(pairResponse.status, 200);
    const { token } = await pairResponse.json() as { token: string };

    const selectedDirectory = join(codexDaemon.root, 'selected project');
    await mkdir(selectedDirectory);
    const createResponse = await fetch(
      `${codexDaemon.baseUrl}/api/projects/open-directory`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
          Origin: codexDaemon.baseUrl,
        },
        body: JSON.stringify({ path: selectedDirectory, engine: 'codex' }),
      },
    );
    assert.equal(createResponse.status, 201);
    const created = await createResponse.json() as {
      sessionId: string;
      catalog: {
        sessions: Array<{ id: string; engine: string }>;
      };
    };
    const sessionId = created.sessionId;
    assert.equal(
      created.catalog.sessions.find(session => session.id === sessionId)?.engine,
      'codex',
    );

    socket = new WebSocket(codexDaemon.baseUrl.replace('http:', 'ws:') + '/ws', {
      headers: { Origin: codexDaemon.baseUrl },
    });
    await once(socket, 'open');
    const initialCatalogPromise = waitForWsMessage(socket, message =>
      message.type === 'catalog' && message.activeSessionId === sessionId);
    socket.send(JSON.stringify({ type: 'auth', token }));
    const initialCatalog = await initialCatalogPromise;
    assert.equal(
      (initialCatalog.sessions as Array<{ id: string; engine: string }>)
        .find(session => session.id === sessionId)?.engine,
      'codex',
    );

    const selectedCatalog = waitForWsMessage(socket, message =>
      message.type === 'catalog' && message.activeSessionId === sessionId);
    const selectedStatus = waitForWsMessage(socket, message =>
      message.type === 'status'
      && message.sessionId === sessionId
      && message.running === false);
    socket.send(JSON.stringify({ type: 'select_session', sessionId }));
    await Promise.all([selectedCatalog, selectedStatus]);
    await new Promise(resolve => setTimeout(resolve, 25));

    const firstResultPromise = waitForPromptResult(socket, sessionId);
    const firstIdlePromise = waitForWsMessage(socket, message =>
      message.type === 'status'
      && message.sessionId === sessionId
      && message.running === false
      && message.hasEngineSessionId === true);
    socket.send(JSON.stringify({
      type: 'prompt',
      promptId: 'codex-e2e-first',
      sessionId,
      engine: 'codex',
      sandboxMode: 'read-only',
      permissionMode: 'manual',
      text: 'first Codex prompt',
    }));
    const firstResult = await firstResultPromise;
    assert.equal(firstResult.text, 'fake codex reply');
    assert.equal(firstResult.engineSessionId, 'fake-thread-id');
    await firstIdlePromise;
    const directoryLog = (await readFile(join(codexDaemon.root, 'codex-args.jsonl'), 'utf8'))
      .trim().split('\n').map(line => JSON.parse(line));
    assert.equal(directoryLog.find(entry => entry.kind === 'process')?.cwd, selectedDirectory);
    assert.equal(directoryLog.find(entry => entry.method === 'thread/start')?.params.cwd, selectedDirectory);
    await new Promise(resolve => setTimeout(resolve, 25));

    socket.close();
    await once(socket, 'close');
    socket = new WebSocket(codexDaemon.baseUrl.replace('http:', 'ws:') + '/ws', {
      headers: { Origin: codexDaemon.baseUrl },
    });
    await once(socket, 'open');
    const restoredSnapshot = waitForWsMessage(socket, message =>
      message.type === 'transcript_snapshot' && message.sessionId === sessionId);
    socket.send(JSON.stringify({ type: 'auth', token }));
    const snapshot = await restoredSnapshot;
    assert.equal(snapshot.engineSessionId, 'fake-thread-id');
    assert.equal(snapshot.running, false);
    assert.equal(
      (snapshot.messages as Array<{ role: string; text: string }>).find(message =>
        message.role === 'assistant')?.text,
      'fake codex reply',
    );

    const secondResultPromise = waitForPromptResult(socket, sessionId);
    socket.send(JSON.stringify({
      type: 'prompt',
      promptId: 'codex-e2e-second',
      sessionId,
      engine: 'codex',
      sandboxMode: 'read-only',
      permissionMode: 'manual',
      text: 'second Codex prompt',
    }));
    const secondResult = await secondResultPromise;
    assert.equal(secondResult.text, 'fake codex reply');
    assert.equal(secondResult.engineSessionId, 'fake-thread-id');

    const form = new FormData();
    form.append('files', new Blob(['not an image'], { type: 'text/plain' }), 'notes.txt');
    const uploadResponse = await fetch(
      `${codexDaemon.baseUrl}/api/sessions/${encodeURIComponent(sessionId)}/attachments`,
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, Origin: codexDaemon.baseUrl },
        body: form,
      },
    );
    assert.equal(uploadResponse.status, 201);
    const uploadBody = await uploadResponse.json() as {
      attachments: Array<{ id: string }>;
    };
    const rejectedPrompt = waitForWsMessage(socket, message =>
      message.type === 'error' && message.promptId === 'codex-e2e-non-image');
    socket.send(JSON.stringify({
      type: 'prompt',
      promptId: 'codex-e2e-non-image',
      sessionId,
      engine: 'codex',
      sandboxMode: 'read-only',
      permissionMode: 'manual',
      attachmentIds: [uploadBody.attachments[0].id],
      text: 'reject this attachment',
    }));
    const rejection = await rejectedPrompt;
    assert.equal(rejection.message, 'codex_only_supports_image_attachments');

    const dangerResultPromise = waitForPromptResult(socket, sessionId);
    socket.send(JSON.stringify({
      type: 'prompt',
      promptId: 'codex-e2e-danger',
      sessionId,
      engine: 'codex',
      sandboxMode: 'danger-full-access',
      permissionMode: 'manual',
      text: 'danger mode prompt',
    }));
    const dangerResult = await dangerResultPromise;
    assert.equal(dangerResult.text, 'fake codex reply');
    const transcriptResponse = await fetch(
      `${codexDaemon.baseUrl}/api/sessions/${encodeURIComponent(sessionId)}`,
      { headers: { Authorization: `Bearer ${token}` } },
    );
    assert.equal(transcriptResponse.status, 200);
    const transcriptBody = await transcriptResponse.json() as {
      transcript: { sandboxMode?: string; sessionInfo?: { model?: string } };
    };
    assert.equal(transcriptBody.transcript.sandboxMode, 'danger-full-access');
    assert.equal(transcriptBody.transcript.sessionInfo?.model, 'gpt-6-sol');

    const records = (await readFile(
      join(codexDaemon.root, 'codex-args.jsonl'),
      'utf8',
    ))
      .trim()
      .split(/\r?\n/)
      .map(line => JSON.parse(line) as {
        kind: 'process' | 'request';
        args?: string[];
        method?: string;
        params?: {
          input?: Array<{ type: string; text?: string }>;
          sandbox?: string;
        };
      });
    assert.deepEqual(records.filter(record => record.kind === 'process'), [selectedDirectory, codexDaemon.root].map(cwd => ({
      kind: 'process',
      args: ['app-server'],
      cwd,
    })));
    const requests = records.filter(record => record.kind === 'request');
    assert.equal(requests.filter(record => record.method === 'initialize').length, 2);
    assert.deepEqual(requests.filter(record => ![
      'initialize', 'thread/read', 'thread/turns/list', 'thread/items/list',
    ].includes(record.method || '')).map(record => record.method), [
      'thread/start',
      'turn/start',
      'turn/start',
      'thread/resume',
      'turn/start',
    ]);
    assert.deepEqual(
      requests
        .filter(record => record.method === 'turn/start')
        .map(record => record.params?.input?.find(item => item.type === 'text')?.text),
      ['first Codex prompt', 'second Codex prompt', 'danger mode prompt'],
    );
    assert.equal(requests.find(record => record.method === 'thread/resume')?.params?.sandbox,
      'danger-full-access');

    await assert.rejects(
      () => readFile(join(codexDaemon.root, 'claude-args.jsonl'), 'utf8'),
      { code: 'ENOENT' },
    );
  } finally {
    socket?.close();
    codexDaemon.child.kill();
    await Promise.race([
      codexDaemon.child.exitCode === null
        ? once(codexDaemon.child, 'exit')
        : Promise.resolve(),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(codexDaemon.root, {
      recursive: true,
      force: true,
      maxRetries: 3,
      retryDelay: 50,
    });
  }
});

test('Codex catalogs are authenticated, scoped to the session, and usable by prompts', async () => {
  const catalogDaemon = await startDaemon({
    codexBin: process.execPath,
    codexArgs: root => [resolve('tests/fixtures/fakeCodex.mjs'),
      `--fake-log=${join(root, 'codex-catalog.jsonl')}`,
      `--fake-history=${join(root, 'codex-native.json')}`],
  });
  let socket: WebSocket | undefined;
  try {
    assert.equal((await fetch(`${catalogDaemon.baseUrl}/api/models?sessionId=missing`)).status, 401);
    assert.equal((await fetch(`${catalogDaemon.baseUrl}/api/commands?sessionId=missing`)).status, 401);
    const pair = await fetch(`${catalogDaemon.baseUrl}/api/pair`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Origin: catalogDaemon.baseUrl },
      body: JSON.stringify({ nonce: catalogDaemon.nonce }),
    });
    const { token } = await pair.json() as { token: string };
    const headers = { Authorization: `Bearer ${token}` };
    const status = await fetch(`${catalogDaemon.baseUrl}/api/status`, { headers });
    const { activeProjectId } = await status.json() as { activeProjectId: string };
    const create = await fetch(`${catalogDaemon.baseUrl}/api/projects/${activeProjectId}/sessions`, {
      method: 'POST', headers: { ...headers, 'Content-Type': 'application/json', Origin: catalogDaemon.baseUrl },
      body: JSON.stringify({ engine: 'codex' }),
    });
    assert.equal(create.status, 201);
    const { sessionId } = await create.json() as { sessionId: string };
    await assert.rejects(readFile(join(catalogDaemon.root, 'codex-catalog.jsonl'), 'utf8'), { code: 'ENOENT' });
    assert.equal((await fetch(`${catalogDaemon.baseUrl}/api/models?sessionId=old-session`, { headers })).status, 409);

    socket = new WebSocket(catalogDaemon.baseUrl.replace('http:', 'ws:') + '/ws', { headers: { Origin: catalogDaemon.baseUrl } });
    await once(socket, 'open');
    const authenticated = waitForWsMessage(socket, message => message.type === 'status' && message.authenticated === true);
    socket.send(JSON.stringify({ type: 'auth', token }));
    await authenticated;
    const commandsPushed = waitForWsMessage(socket, message => message.type === 'commands' && (message.commands as string[])?.includes('inspect'));
    const [modelsResponse, commandsResponse] = await Promise.all([
      fetch(`${catalogDaemon.baseUrl}/api/models?sessionId=${sessionId}`, { headers }),
      fetch(`${catalogDaemon.baseUrl}/api/commands?sessionId=${sessionId}`, { headers }),
    ]);
    assert.equal(modelsResponse.status, 200);
    assert.equal(commandsResponse.status, 200);
    const models = await modelsResponse.json() as { sessionId: string; engine: string; models: Array<{ model: string }> };
    assert.equal(models.sessionId, sessionId);
    assert.equal(models.engine, 'codex');
    assert.deepEqual(models.models.map(item => item.model), ['gpt-test-codex', 'gpt-test-fast']);
    const commands = await commandsResponse.json() as { commands: string[] };
    assert.deepEqual(commands.commands, ['compact', 'review', 'inspect']);
    await commandsPushed;
    const resultPromise = waitForPromptResult(socket, sessionId);
    socket.send(JSON.stringify({
      type: 'prompt', promptId: 'catalog-skill', sessionId, engine: 'codex',
      model: 'gpt-test-codex', text: '/inspect check tests',
    }));
    assert.equal((await resultPromise).text, 'fake codex reply');
    const historyPath = join(catalogDaemon.root, 'codex-native.json');
    const history = JSON.parse(await readFile(historyPath, 'utf8'));
    history.turns[0].items.splice(1, 0, {
      id: 'call-question', type: 'agentMessage', text: 'Which files should I inspect?',
    });
    await writeFile(historyPath, JSON.stringify(history));
    const compactPromise = waitForPromptResult(socket, sessionId);
    socket.send(JSON.stringify({
      type: 'prompt', promptId: 'catalog-compact', sessionId, engine: 'codex',
      model: 'gpt-test-codex', text: '/compact',
    }));
    assert.equal((await compactPromise).text, '上下文压缩完成。');
    const reviewPromise = waitForPromptResult(socket, sessionId);
    socket.send(JSON.stringify({
      type: 'prompt', promptId: 'catalog-review', sessionId, engine: 'codex',
      model: 'gpt-test-codex', text: '/review',
    }));
    assert.equal((await reviewPromise).text, 'native review result');
    const session = await fetch(`${catalogDaemon.baseUrl}/api/sessions/${sessionId}`, { headers });
    const { transcript } = await session.json() as { transcript: { messages: Array<{ text: string }> } };
    assert.equal(transcript.messages.filter(message => message.text === 'Which files should I inspect?').length, 1);
    assert.equal(transcript.messages.filter(message => message.text === '上下文压缩完成。').length, 1);
    const records = (await readFile(join(catalogDaemon.root, 'codex-catalog.jsonl'), 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
    assert.equal(records.filter(item => item.kind === 'process').length, 3);
    const turn = records.find(item => item.method === 'turn/start');
    assert.equal(turn.params.model, 'gpt-test-codex');
    assert.equal(turn.params.input[0].text, '$inspect check tests');
    assert.equal(turn.params.input[1].type, 'skill');
    assert.equal(records.filter(item => item.method === 'turn/start').length, 1);
    assert.equal(records.find(item => item.method === 'thread/compact/start').params.threadId, 'fake-thread-id');
    assert.deepEqual(records.find(item => item.method === 'review/start').params.target, { type: 'uncommittedChanges' });
  } finally {
    socket?.close();
    catalogDaemon.child.kill();
    await Promise.race([
      catalogDaemon.child.exitCode === null ? once(catalogDaemon.child, 'exit') : Promise.resolve(),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(catalogDaemon.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('Codex history stays warm when switching conversations across folders', async t => {
  const instance = await startDaemon({
    codexBin: process.execPath,
    codexArgs: root => [
      resolve('tests/fixtures/fakeCodex.mjs'),
      '--fake-log=' + join(root, 'codex-switch.jsonl'),
      '--fake-initializeDelay=500',
      '--fake-record-cwd=1',
    ],
  });
  let socket: WebSocket | undefined;
  try {
    const paired = await fetch(instance.baseUrl + '/api/pair', {
      method: 'POST',
      headers: { Origin: instance.baseUrl, 'Content-Type': 'application/json' },
      body: JSON.stringify({ nonce: instance.nonce }),
    });
    const { token } = await paired.json() as { token: string };
    const headers = {
      Origin: instance.baseUrl, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json',
    };
    const sessions: string[] = [];
    for (const name of ['first', 'second']) {
      const path = join(instance.root, name);
      await mkdir(path);
      const created = await fetch(instance.baseUrl + '/api/projects/open-directory', {
        method: 'POST', headers, body: JSON.stringify({ path, engine: 'codex' }),
      });
      assert.equal(created.status, 201);
      const { sessionId } = await created.json() as { sessionId: string };
      sessions.push(sessionId);
      if (!socket) {
        socket = new WebSocket(instance.baseUrl.replace('http:', 'ws:') + '/ws', {
          headers: { Origin: instance.baseUrl },
        });
        await once(socket, 'open');
        const authenticated = waitForWsMessage(socket, message => message.type === 'transcript_snapshot');
        socket.send(JSON.stringify({ type: 'auth', token }));
        await authenticated;
      }
      const result = waitForPromptResult(socket, sessionId);
      socket.send(JSON.stringify({ type: 'prompt', sessionId, engine: 'codex', text: name }));
      assert.equal((await result).text, 'fake codex reply');
    }

    const select = async (sessionId: string, http = false) => {
      const snapshot = waitForWsMessage(socket!, message =>
        message.type === 'transcript_snapshot' && message.sessionId === sessionId);
      const started = performance.now();
      if (http) {
        const response = await fetch(instance.baseUrl + '/api/sessions/' + sessionId + '/select', {
          method: 'POST', headers,
        });
        assert.equal(response.status, 200);
      } else {
        socket!.send(JSON.stringify({ type: 'select_session', sessionId }));
      }
      const selected = await snapshot;
      const expectedPrompt = sessionId === sessions[0] ? 'first' : 'second';
      assert.deepEqual(
        (selected.messages as Array<{ role: string; text: string }>)
          .filter(message => message.role === 'user').map(message => message.text),
        [expectedPrompt],
      );
      return performance.now() - started;
    };
    const processes = async () => (await readFile(join(instance.root, 'codex-switch.jsonl'), 'utf8'))
      .trim().split('\n').map(line => JSON.parse(line)).filter(entry => entry.kind === 'process');

    const cold = await select(sessions[0]);
    const before = (await processes()).length;
    const elapsed: number[] = [];
    for (let index = 0; index < 4; index++) {
      elapsed.push(await select(sessions[(index + 1) % 2], index % 2 === 1));
    }
    t.diagnostic('Cold history: ' + cold.toFixed(0) + ' ms; cross-folder switches: '
      + elapsed.map(value => value.toFixed(0)).join(', ') + ' ms');
    assert.equal((await processes()).length, before, 'switching folders must reuse the history reader');
  } finally {
    socket?.terminate();
    instance.child.kill();
    await Promise.race([
      instance.child.exitCode === null ? once(instance.child, 'exit') : Promise.resolve(),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

for (const engine of ['claude', 'codex'] as const) {
  test('native ' + engine + ' history syncs live, reconnects, resumes context and stays deleted', async () => {
    const nativeId = engine === 'claude' ? randomUUID() : 'fake-thread-id';
    const instance = await startDaemon({
      claudeBin: process.execPath,
      claudeArgs: root => [
        resolve('tests/fixtures/fakeClaude.mjs'),
        '--fake-session=' + nativeId,
        '--fake-log=' + join(root, 'claude-sync.jsonl'),
        '--fake-history=' + join(root, '.claude', 'projects', 'fixture', nativeId + '.jsonl'),
      ],
      codexBin: process.execPath,
      codexArgs: root => [
        resolve('tests/fixtures/fakeCodex.mjs'),
        '--fake-log=' + join(root, 'codex-sync.jsonl'),
        '--fake-history=' + join(root, 'codex-native.json'),
      ],
    });
    let socket: WebSocket | undefined;
    try {
      const paired = await fetch(instance.baseUrl + '/api/pair', {
        method: 'POST',
        headers: { Origin: instance.baseUrl, 'Content-Type': 'application/json' },
        body: JSON.stringify({ nonce: instance.nonce }),
      });
      const { token } = await paired.json() as { token: string };
      const headers = {
        Origin: instance.baseUrl, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json',
      };
      const create = await fetch(instance.baseUrl + '/api/projects/open-directory', {
        method: 'POST', headers, body: JSON.stringify({ path: instance.root, engine }),
      });
      assert.equal(create.status, 201);
      const { sessionId } = await create.json() as { sessionId: string };
      const connect = async () => {
        const connection = new WebSocket(instance.baseUrl.replace('http:', 'ws:') + '/ws', {
          headers: { Origin: instance.baseUrl },
        });
        await once(connection, 'open');
        const snapshot = waitForWsMessage(connection, message =>
          message.type === 'transcript_snapshot' && message.sessionId === sessionId);
        connection.send(JSON.stringify({ type: 'auth', token }));
        return { connection, snapshot };
      };
      const first = await connect();
      socket = first.connection;
      await first.snapshot;
      const run = async (text: string) => {
        const result = waitForPromptResult(socket!, sessionId);
        socket!.send(JSON.stringify({ type: 'prompt', sessionId, engine, text }));
        return result;
      };
      assert.equal((await run('phone first')).text, engine === 'claude' ? 'fake reply' : 'fake codex reply');
      const appendDesktop = async (prompt: string, reply: string, pending = false) => {
        if (engine === 'claude') {
          const path = join(instance.root, '.claude', 'projects', 'fixture', nativeId + '.jsonl');
          const entries = (await readFile(path, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
          const parent = entries.filter(entry => entry.uuid).at(-1)?.uuid ?? null;
          const userId = randomUUID();
          const user = { type: 'user', uuid: userId, parentUuid: parent,
            sessionId: nativeId, message: { role: 'user', content: prompt } };
          const assistant = { type: 'assistant', uuid: randomUUID(), parentUuid: userId,
            sessionId: nativeId, message: { role: 'assistant', content: reply } };
          await appendFile(path, (pending ? [user] : [user, assistant])
            .map(entry => JSON.stringify(entry)).join('\n') + '\n');
          return async () => { await appendFile(path, JSON.stringify(assistant) + '\n'); };
        } else {
          const path = join(instance.root, 'codex-native.json');
          const history = JSON.parse(await readFile(path, 'utf8'));
          const turnId = randomUUID();
          const turn = { id: turnId, status: pending ? 'inProgress' : 'completed', itemsView: 'full', items: [
            { id: turnId + '-user', type: 'userMessage', content: [{ type: 'text', text: prompt }] },
            ...(!pending ? [{ id: turnId + '-reply', type: 'agentMessage', text: reply }] : []),
          ] };
          history.turns.push(turn);
          await writeFile(path, JSON.stringify(history));
          return async () => {
            turn.status = 'completed';
            turn.items.push({ id: turnId + '-reply', type: 'agentMessage', text: reply });
            await writeFile(path, JSON.stringify(history));
          };
        }
      };
      const contains = (message: Record<string, unknown>, text: string) =>
        Array.isArray(message.messages) && message.messages.some(item => item.text === text);
      const update = waitForWsMessage(socket, message =>
        message.type === 'transcript_snapshot' && contains(message, 'desktop reply'), 40_000);
      await appendDesktop('desktop question', 'desktop reply');
      const synced = await update;
      assert.equal((synced.messages as Array<{ text: string }>).filter(item => item.text === 'phone first').length, 1);
      const beforeSend = waitForWsMessage(socket, message =>
        message.type === 'transcript_snapshot' && message.running === true
        && contains(message, 'before-send reply') && contains(message, 'phone continues'));
      await appendDesktop('just before send', 'before-send reply');
      assert.equal((await run('phone continues')).text, engine === 'claude' ? 'fake reply' : 'fake codex reply');
      await beforeSend;

      const records = (await readFile(join(instance.root, engine + '-sync.jsonl'), 'utf8'))
        .trim().split('\n').map(line => JSON.parse(line));
      if (engine === 'claude') {
        const runs = records.filter(args => args.includes('--input-format'));
        assert.equal(runs.length, 2);
        assert.equal(runs[1][runs[1].indexOf('--resume') + 1], nativeId);
      } else {
        assert.equal(records.filter(record => record.kind === 'process').length, 3);
        assert.equal(records.filter(record => record.method === 'thread/resume').length, 1);
      }

      const completeNative = await appendDesktop('native is working', 'native finished', true);
      const blocked = waitForWsMessage(socket, message =>
        message.type === 'error' && message.message === 'native_session_is_busy');
      socket.send(JSON.stringify({ type: 'prompt', sessionId, engine, text: 'must wait' }));
      await blocked;
      const retained = await fetch(instance.baseUrl + '/api/sessions/' + sessionId, { headers });
      const retainedBody = await retained.json() as { transcript: {
        messages: Array<{ text: string; nativeLocalOnly?: boolean }>;
      } };
      assert.equal(retainedBody.transcript.messages.find(message =>
        message.text === 'must wait')?.nativeLocalOnly, true);
      await completeNative();

      const closed = once(socket, 'close');
      socket.close();
      await closed;
      await appendDesktop('offline desktop', 'offline reply');
      const reconnected = await connect();
      socket = reconnected.connection;
      const restored = await reconnected.snapshot;
      assert.equal(contains(restored, 'offline reply'), true);
      assert.equal(contains(restored, 'phone continues'), true);
      assert.equal(contains(restored, 'must wait'), true);
      const current = await fetch(instance.baseUrl + '/api/sessions/' + sessionId, { headers });
      const snapshot = await current.json() as { transcript: { revision: number; messages: unknown[] } };
      const again = await fetch(instance.baseUrl + '/api/sessions/' + sessionId, { headers });
      assert.deepEqual((await again.json() as typeof snapshot).transcript, snapshot.transcript);

      const next = await fetch(instance.baseUrl + '/api/projects/open-directory', {
        method: 'POST', headers, body: JSON.stringify({ path: instance.root, engine }),
      });
      const nextSession = await next.json() as { sessionId: string };
      await appendDesktop('background desktop', 'background reply');
      if (engine === 'codex') {
        const path = join(instance.root, 'codex-native.json');
        const history = JSON.parse(await readFile(path, 'utf8'));
        await writeFile(path, JSON.stringify({ ...history, delayMs: 40 }));
      }
      const backgroundRequest = fetch(instance.baseUrl + '/api/sessions/' + sessionId, { headers });
      await new Promise(resolveTimeout => setTimeout(resolveTimeout, 20));
      const deleteRequest = fetch(instance.baseUrl + '/api/sessions/' + sessionId, { method: 'DELETE', headers });
      const background = await backgroundRequest;
      assert.equal(JSON.stringify(await background.json()).includes('background reply'), true);
      const catalog = JSON.parse(await readFile(join(instance.root, '.data', 'projects.json'), 'utf8'));
      assert.equal(catalog.activeSessionId, nextSession.sessionId);
      const deleted = await deleteRequest;
      assert.equal(deleted.status, 200, await deleted.text());
      await appendDesktop('after delete', 'must not resurrect');
      const missing = await fetch(instance.baseUrl + '/api/sessions/' + sessionId, { headers });
      assert.equal(missing.status, 404);
      await assert.rejects(readFile(join(instance.root, '.data', 'sessions', sessionId + '.json')), { code: 'ENOENT' });
    } finally {
      socket?.close();
      instance.child.kill();
      await Promise.race([
        instance.child.exitCode === null ? once(instance.child, 'exit') : Promise.resolve(),
        new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
      ]);
      await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}

test('reply images are pushed with their message, require session auth, and survive native refresh', async () => {
  const instance = await startDaemon({
    codexBin: process.execPath,
    codexArgs: root => [resolve('tests/fixtures/fakeCodex.mjs'),
      '--fake-reply-file=' + join(root, 'reply.md'),
      '--fake-history=' + join(root, 'native.json')],
  });
  let socket: WebSocket | undefined;
  try {
    const imageBytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jvGQAAAAASUVORK5CYII=', 'base64');
    const imagePath = join(instance.root, 'preview 1.png');
    const text = `截图如下：\n\n![预览](<${imagePath}>)`;
    await writeFile(imagePath, imageBytes);
    await writeFile(join(instance.root, 'reply.md'), text);
    const pair = await fetch(instance.baseUrl + '/api/pair', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Origin: instance.baseUrl },
      body: JSON.stringify({ nonce: instance.nonce }),
    });
    const { token } = await pair.json() as { token: string };
    const headers = { Authorization: 'Bearer ' + token, Origin: instance.baseUrl, 'Content-Type': 'application/json' };
    const status = await fetch(instance.baseUrl + '/api/status', { headers });
    const { activeProjectId, activeSessionId: otherSessionId } = await status.json() as {
      activeProjectId: string; activeSessionId: string;
    };
    const created = await fetch(instance.baseUrl + '/api/projects/' + activeProjectId + '/sessions', {
      method: 'POST', headers, body: JSON.stringify({ engine: 'codex' }),
    });
    const { sessionId } = await created.json() as { sessionId: string };
    socket = new WebSocket(instance.baseUrl.replace('http:', 'ws:') + '/ws', { headers: { Origin: instance.baseUrl } });
    await once(socket, 'open');
    const authenticated = waitForWsMessage(socket, message => message.type === 'status');
    socket.send(JSON.stringify({ type: 'auth', token }));
    await authenticated;
    const snapshotPromise = waitForWsMessage(socket, message => message.type === 'transcript_snapshot'
      && (message.messages as Array<any>)?.some(item => item.role === 'assistant' && item.attachments?.length));
    const promptResult = waitForPromptResult(socket, sessionId);
    socket.send(JSON.stringify({ type: 'prompt', promptId: 'reply-image', sessionId, engine: 'codex', text: '生成截图' }));
    assert.equal((await promptResult).text, text);
    const snapshot = await snapshotPromise;
    const reply = (snapshot.messages as Array<any>).find(item => item.role === 'assistant');
    assert.equal(reply.text, text);
    assert.equal(reply.attachments.length, 1);
    const imageId = reply.attachments[0].id;
    const contentUrl = instance.baseUrl + `/api/sessions/${sessionId}/attachments/${imageId}/content`;
    assert.equal((await fetch(contentUrl)).status, 401);
    const downloaded = await fetch(contentUrl, { headers });
    assert.equal(downloaded.status, 200);
    assert.equal(downloaded.headers.get('content-type'), 'image/png');
    assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), imageBytes);
    assert.equal((await fetch(instance.baseUrl + `/api/sessions/${otherSessionId}/attachments/${imageId}/content`, { headers })).status, 404);
    await rm(imagePath);
    assert.equal((await fetch(instance.baseUrl + `/api/sessions/${sessionId}/select`, { method: 'POST', headers })).status, 200);
    const refreshed = await fetch(instance.baseUrl + `/api/sessions/${sessionId}`, { headers });
    const saved = await refreshed.json() as { transcript: { messages: Array<any> } };
    assert.deepEqual(saved.transcript.messages.find(item => item.role === 'assistant')?.attachments, reply.attachments);
    assert.equal((await fetch(contentUrl, { headers })).status, 200);

    await writeFile(join(instance.root, 'desktop.png'), imageBytes);
    const native = JSON.parse(await readFile(join(instance.root, 'native.json'), 'utf8'));
    native.turns.push({ id: 'desktop-turn', status: 'completed', itemsView: 'full', items: [
      { id: 'desktop-user', type: 'userMessage', content: [{ type: 'text', text: '电脑端生成图片' }] },
      { id: 'desktop-reply', type: 'agentMessage', text: '[图片](desktop.png)' },
    ] });
    await writeFile(join(instance.root, 'native.json'), JSON.stringify(native));
    assert.equal((await fetch(instance.baseUrl + `/api/sessions/${sessionId}/select`, { method: 'POST', headers })).status, 200);
    const importedResponse = await fetch(instance.baseUrl + `/api/sessions/${sessionId}`, { headers });
    const imported = await importedResponse.json() as { transcript: { messages: Array<any> } };
    assert.equal(imported.transcript.messages.at(-1)?.attachments?.[0].name, 'desktop.png');
  } finally {
    socket?.terminate();
    instance.child.kill();
    await Promise.race([
      instance.child.exitCode === null ? once(instance.child, 'exit') : Promise.resolve(),
      new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
    ]);
    await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

for (const failure of ['catalog', 'auth', 'transcript'] as const) {
  test(`prompt persistence failure clears running state and allows retry (${failure})`, async () => {
    const nativeId = randomUUID();
    const instance = await startDaemon({
      claudeBin: process.execPath,
      claudeArgs: root => [resolve('tests/fixtures/fakeClaude.mjs'), '--fake-session=' + nativeId,
        '--fake-history=' + join(root, '.claude', 'projects', 'fixture', nativeId + '.jsonl')],
    });
    let socket: WebSocket | undefined;
    try {
      const paired = await fetch(instance.baseUrl + '/api/pair', {
        method: 'POST', headers: { 'Content-Type': 'application/json', Origin: instance.baseUrl },
        body: JSON.stringify({ nonce: instance.nonce }),
      });
      assert.equal(paired.status, 200);
      const { token } = await paired.json() as { token: string };
      const headers = { Authorization: 'Bearer ' + token, Origin: instance.baseUrl };
      const status = await fetch(instance.baseUrl + '/api/status', { headers });
      const { activeSessionId: sessionId } = await status.json() as { activeSessionId: string };
      socket = new WebSocket(instance.baseUrl.replace('http:', 'ws:') + '/ws', {
        headers: { Origin: instance.baseUrl },
      });
      await once(socket, 'open');
      const ready = waitForWsMessage(socket, message => message.type === 'transcript_snapshot');
      socket.send(JSON.stringify({ type: 'auth', token }));
      await ready;
      const path = join(instance.root, '.data', failure === 'catalog' ? 'projects.json'
        : failure === 'auth' ? 'state.json' : join('sessions', sessionId + '.json'));
      if (failure === 'transcript') await writeFile(path, '{}');
      await rename(path, path + '.saved');
      await mkdir(path);
      const prompt = { type: 'prompt', sessionId, promptId: 'retry-persistence', text: 'probe' };
      const failed = Promise.all([
        waitForWsMessage(socket, message => message.type === 'error' && message.promptId === prompt.promptId),
        waitForWsMessage(socket, message => message.type === 'status'
          && message.running === false && typeof message.runId === 'string'),
      ]);
      socket.send(JSON.stringify(prompt));
      await failed;
      assert.equal(instance.child.exitCode, null);
      const afterFailure = await fetch(instance.baseUrl + '/api/status', { headers });
      assert.equal((await afterFailure.json() as { running: boolean }).running, false);
      const stop = await fetch(instance.baseUrl + '/api/stop', { method: 'POST', headers });
      assert.deepEqual(await stop.json(), { stopped: false });
      await rm(path, { recursive: true });
      await rename(path + '.saved', path);
      const retry = Promise.all([
        waitForPromptResult(socket, sessionId),
        waitForWsMessage(socket, message => message.type === 'status'
          && message.running === false && typeof message.runId === 'string'),
      ]);
      socket.send(JSON.stringify(prompt));
      assert.equal((await retry)[0].text, 'fake reply');
      const saved = JSON.parse(await readFile(join(instance.root, '.data', 'sessions', sessionId + '.json'), 'utf8'));
      assert.equal(saved.running, false);
      assert.ok(saved.messages.some((message: { text: string }) => message.text === 'fake reply'));
      const native = (await readFile(join(instance.root, '.claude', 'projects', 'fixture', nativeId + '.jsonl'), 'utf8'))
        .trim().split('\n').map(line => JSON.parse(line));
      assert.equal(native.filter(entry => entry.type === 'custom-title').at(-1)?.customTitle, 'probe');
    } finally {
      socket?.terminate();
      instance.child.kill();
      await Promise.race([
        instance.child.exitCode === null ? once(instance.child, 'exit') : Promise.resolve(),
        new Promise(resolveTimeout => setTimeout(resolveTimeout, 2_000)),
      ]);
      await rm(instance.root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}

async function startDaemon(options: {
  claudeBin?: string;
  claudeArgs?: (root: string) => string[];
  codexBin?: string;
  codexArgs?: (root: string) => string[];
  staleSessionId?: string;
  nativeHistory?: boolean;
} = {}): Promise<RunningDaemon> {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-daemon-e2e-'));
  await writeFile(join(root, 'README.md'), '# fixture\n', 'utf8');
  if (options.staleSessionId) {
    await mkdir(join(root, '.data'), { recursive: true });
    await writeFile(join(root, '.data', 'transcript.json'), JSON.stringify({
      version: 1,
      revision: 0,
      running: false,
      updatedAt: Date.now(),
      claudeSessionId: options.staleSessionId,
      permissionMode: 'manual',
      pendingPermissions: [],
      sessionInfo: {},
      messages: [],
    }, null, 2) + '\n', 'utf8');
  }
  if (options.nativeHistory && options.staleSessionId) {
    const directory = join(root, '.claude', 'projects', 'fixture');
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, `${options.staleSessionId}.jsonl`), JSON.stringify({
      type: 'user', sessionId: options.staleSessionId, entrypoint: 'sdk-cli',
      message: { role: 'user', content: 'existing phone conversation' },
    }) + '\n');
  }
  const port = await findFreePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const daemonPath = resolve('src/daemon.ts');
  const tsxImport = import.meta.resolve('tsx');
  const child = spawn(process.execPath, ['--import', tsxImport, daemonPath], {
    cwd: root,
    env: {
      ...process.env,
      CC_REMOTE_DESKTOP: '0',
      HOST: '127.0.0.1',
      PORT: String(port),
      PUBLIC_ORIGIN: baseUrl,
      WORKSPACE_DIR: root,
      CLAUDE_BIN: options.claudeBin ?? join(root, 'missing-claude-executable'),
      CLAUDE_CONFIG_DIR: join(root, '.claude'),
      ...(options.claudeArgs ? { CLAUDE_ARGS: options.claudeArgs(root).join('|') } : {}),
      CODEX_BIN: options.codexBin ?? join(root, 'missing-codex-executable'),
      ...(options.codexArgs ? { CODEX_ARGS: options.codexArgs(root).join('|') } : {}),
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

function waitForPromptResult(
  socket: WebSocket,
  sessionId: string,
): Promise<{
  text: string;
  engineSessionId?: string;
  claudeSessionId?: string;
}> {
  return new Promise((resolvePrompt, rejectPrompt) => {
    let text = '';
    const timeout = setTimeout(() => {
      cleanup();
      rejectPrompt(new Error('websocket_prompt_timeout'));
    }, 5_000);
    const onMessage = (data: WebSocket.RawData) => {
      const message = JSON.parse(data.toString()) as Record<string, unknown>;
      if (message.sessionId !== sessionId) return;
      if (message.type === 'text') text += String(message.text || '');
      if (message.type === 'error') {
        cleanup();
        rejectPrompt(new Error(String(message.message || 'prompt_failed')));
      }
      if (message.type === 'done') {
        cleanup();
        resolvePrompt({
          text,
          engineSessionId: typeof message.engineSessionId === 'string'
            ? message.engineSessionId
            : undefined,
          claudeSessionId: typeof message.claudeSessionId === 'string' ? message.claudeSessionId : undefined,
        });
      }
    };
    const onClose = () => {
      cleanup();
      rejectPrompt(new Error('websocket_closed_before_prompt_finished'));
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
    const req = request({ ...options, agent: false }, response => {
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
  timeoutMs = 5_000,
): Promise<Record<string, unknown>> {
  return new Promise((resolveMessage, rejectMessage) => {
    const timeout = setTimeout(() => {
      cleanup();
      rejectMessage(new Error('websocket_message_timeout'));
    }, timeoutMs);
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
