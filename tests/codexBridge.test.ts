import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { CodexBridge, extractCodexSessionInfo } from '../src/codexBridge.js';

test('codex token usage prefers the latest request over the thread total', () => {
  // tokenUsage.total accumulates across every turn; last is the most recent
  // model request, which is what fills the context window.
  assert.deepEqual(extractCodexSessionInfo({
    type: 'thread.started',
    thread: { model: 'gpt-6-sol' },
  }), { model: 'gpt-6-sol' });

  assert.deepEqual(extractCodexSessionInfo({
    type: 'thread.tokenUsage.updated',
    tokenUsage: {
      total: { totalTokens: 210000 },
      last: { totalTokens: 62000 },
      modelContextWindow: 272000,
    },
  }), {
    usedTokens: 62000,
    contextWindow: 272000,
    remainingTokens: 210000,
  });

  // Older app servers without `last` keep the total-based estimate.
  assert.deepEqual(extractCodexSessionInfo({
    type: 'thread.tokenUsage.updated',
    tokenUsage: {
      total: { inputTokens: 1500, outputTokens: 500 },
    },
  }), { usedTokens: 2000 });
});

test('CodexBridge reports a missing CLI as a run result instead of throwing', async () => {
  const bridge = new CodexBridge({
    codexBin: 'cc-remote-missing-codex-bin',
    workspaceDir: process.cwd(),
  });
  const result = await bridge.run({
    prompt: 'test',
    permissionMode: 'manual',
    sandboxMode: 'read-only',
    onEvent: () => {},
    onText: () => {},
    onSessionId: () => {},
  });

  assert.equal(result.exitCode, null);
  assert.equal(result.stopped, false);
  assert.match(result.stderr, /ENOENT|not found|spawn/i);
  assert.equal(bridge.isRunning(), false);
});

test('CodexBridge reuses one App Server and streams turns over JSON-RPC', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-codex-bridge-'));
  const logPath = join(dir, 'invocations.jsonl');
  const imagePath = join(dir, 'screen.png');
  const fixture = join(process.cwd(), 'tests', 'fixtures', 'fakeCodex.mjs');
  let bridge: CodexBridge | undefined;
  try {
    await writeFile(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    const events: unknown[] = [];
    const texts: string[] = [];
    const sessionIds: string[] = [];
    bridge = new CodexBridge({
      codexBin: process.execPath,
      codexArgs: [fixture, `--fake-log=${logPath}`],
      workspaceDir: dir,
    });
    const callbacks = {
      permissionMode: 'manual' as const,
      onEvent: (event: unknown) => events.push(event),
      onText: (text: string) => texts.push(text),
      onSessionId: (sessionId: string) => sessionIds.push(sessionId),
    };

    const first = await bridge.run({
      prompt: 'first prompt',
      sandboxMode: 'read-only',
      ...callbacks,
    });
    assert.equal(first.exitCode, 0);
    assert.equal(first.sessionId, 'fake-thread-id');

    const second = await bridge.run({
      prompt: 'continue prompt',
      sessionId: first.sessionId,
      sandboxMode: 'workspace-write',
      model: 'gpt-5.6-luna',
      effort: 'high',
      imagePaths: [imagePath],
      ...callbacks,
    });
    assert.equal(second.exitCode, 0);
    assert.equal(second.sessionId, 'fake-thread-id');

    const records = (await readFile(logPath, 'utf8'))
      .trim()
      .split(/\r?\n/)
      .map(line => JSON.parse(line) as {
        kind: 'process' | 'request';
        args?: string[];
        method?: string;
        params?: Record<string, unknown>;
      });
    assert.deepEqual(records.filter(record => record.kind === 'process'), [{
      kind: 'process',
      args: ['app-server'],
    }]);
    const requests = records.filter(record => record.kind === 'request');
    assert.deepEqual(requests.map(record => record.method), [
      'initialize',
      'thread/start',
      'turn/start',
      'thread/resume',
      'turn/start',
    ]);
    assert.deepEqual(requests[1].params, {
      approvalPolicy: 'never',
      cwd: dir,
      sandbox: 'read-only',
    });
    assert.deepEqual(requests[2].params?.input, [{ type: 'text', text: 'first prompt' }]);
    assert.deepEqual(requests[3].params, {
      threadId: 'fake-thread-id',
      approvalPolicy: 'never',
      cwd: dir,
      sandbox: 'workspace-write',
      model: 'gpt-5.6-luna',
    });
    assert.deepEqual(requests[4].params?.input, [
      { type: 'text', text: 'continue prompt' },
      { type: 'localImage', path: imagePath },
    ]);
    assert.equal(requests[4].params?.effort, 'high');
    assert.deepEqual(sessionIds, ['fake-thread-id']);
    assert.equal(texts.join(''), 'fake codex replyfake codex reply');
    assert.equal(events.length, 18);
  } finally {
    bridge?.close();
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('CodexBridge interrupts a running turn', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-codex-stop-'));
  const fixture = join(process.cwd(), 'tests', 'fixtures', 'fakeCodex.mjs');
  let bridge: CodexBridge | undefined;
  try {
    let turnStarted!: () => void;
    const started = new Promise<void>(resolve => {
      turnStarted = resolve;
    });
    bridge = new CodexBridge({
      codexBin: process.execPath,
      codexArgs: [fixture, '--fake-mode=hang'],
      workspaceDir: dir,
    });
    const run = bridge.run({
      prompt: 'long-running prompt',
      sandboxMode: 'read-only',
      permissionMode: 'manual',
      onEvent: event => {
        if ((event as { type?: string }).type === 'turn.started') turnStarted();
      },
      onText: () => {},
      onSessionId: () => {},
    });

    await started;
    assert.equal(bridge.stop(), true);
    const result = await run;
    assert.equal(result.exitCode, 0);
    assert.equal(result.stopped, true);
  } finally {
    bridge?.close();
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});
