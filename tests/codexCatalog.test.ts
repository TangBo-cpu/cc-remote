import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { CodexBridge } from '../src/codexBridge.js';

const fixture = join(process.cwd(), 'tests', 'fixtures', 'fakeCodex.mjs');

for (const catalogError of [false, true]) {
  test(`Codex catalog shares initialization with turns, catalogError=${catalogError}`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'cc-remote-codex-catalog-'));
    const logPath = join(dir, 'requests.jsonl');
    const bridge = new CodexBridge({
      codexBin: process.execPath,
      codexArgs: [fixture, `--fake-log=${logPath}`, '--fake-initializeDelay=30',
        ...(catalogError ? ['--fake-mode=catalog-error'] : [])],
      workspaceDir: dir,
    });
    try {
      const catalogs = Promise.all([bridge.listModels(), bridge.listSkills()]);
      const run = bridge.run({
        prompt: 'hello', permissionMode: 'manual', model: 'gpt-test-codex',
        onEvent: () => {}, onText: () => {}, onSessionId: () => {},
      });
      if (catalogError) {
        await assert.rejects(catalogs, /catalog_unavailable/);
      } else {
        const [models, skills] = await catalogs;
        assert.deepEqual(models.map(item => item.model), ['gpt-test-codex', 'gpt-test-fast']);
        assert.equal(models[0].displayName, 'Codex Test');
        assert.equal(models[0].isDefault, true);
        assert.deepEqual(skills, [{
          name: 'inspect', description: 'Inspect code', path: dir + '/skills/inspect/SKILL.md',
        }]);
      }
      assert.equal((await run).exitCode, 0);
      const records = (await readFile(logPath, 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
      assert.equal(records.filter(item => item.kind === 'process').length, 1);
      assert.equal(records.filter(item => item.method === 'initialize').length, 1);
      assert.equal(records.find(item => item.method === 'turn/start').params.model, 'gpt-test-codex');
      if (!catalogError) {
        assert.deepEqual(records.filter(item => item.method === 'model/list').map(item => item.params), [
          { limit: 100 }, { limit: 100, cursor: 'second-page' },
        ]);
        assert.deepEqual(records.find(item => item.method === 'skills/list').params, {
          cwds: [dir], forceReload: true,
        });
      }
    } finally {
      bridge.close();
      await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}

test('Codex catalog preserves provider-qualified model IDs through selection', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-codex-catalog-'));
  const logPath = join(dir, 'requests.jsonl');
  const bridge = new CodexBridge({
    codexBin: process.execPath,
    codexArgs: [fixture, `--fake-log=${logPath}`, '--fake-mode=catalog-namespaced'],
    workspaceDir: dir,
  });
  try {
    const models = await bridge.listModels();
    assert.deepEqual(models.map(item => item.model), [
      'gpt-test-codex', 'gpt-test-fast',
      'workbuddy-ai/deepseek-v4.1-flash', 'workbuddy/deepseek-v4.1-flash',
    ]);
    const model = models.at(-1)!.model;
    const result = await bridge.run({
      prompt: 'hello', permissionMode: 'manual', model,
      onEvent: () => {}, onText: () => {}, onSessionId: () => {},
    });
    assert.equal(result.exitCode, 0);
    const records = (await readFile(logPath, 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
    assert.equal(records.find(item => item.method === 'thread/start').params.model, model);
    assert.equal(records.find(item => item.method === 'turn/start').params.model, model);
  } finally {
    bridge.close();
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('Codex slash skill uses native skill input and preserves its arguments', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-codex-skill-'));
  const logPath = join(dir, 'requests.jsonl');
  const bridge = new CodexBridge({
    codexBin: process.execPath,
    codexArgs: [fixture, `--fake-log=${logPath}`],
    workspaceDir: dir,
  });
  try {
    const callbacks = { permissionMode: 'manual' as const, onEvent: () => {}, onText: () => {}, onSessionId: () => {} };
    const result = await bridge.run({ prompt: '/inspect src/main.ts\ncheck tests', ...callbacks });
    assert.equal(result.exitCode, 0);
    const unknown = await bridge.run({ prompt: '/disabled do work', ...callbacks });
    assert.equal(unknown.stderr, 'codex_command_not_found');
    const records = (await readFile(logPath, 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
    const turns = records.filter(item => item.method === 'turn/start');
    assert.equal(turns.length, 1);
    assert.deepEqual(turns[0].params.input, [
      { type: 'text', text: '$inspect src/main.ts\ncheck tests' },
      { type: 'skill', name: 'inspect', path: dir + '/skills/inspect/SKILL.md' },
    ]);
  } finally {
    bridge.close();
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

for (const mode of ['normal', 'compact-failed', 'compact-rpc-error', 'compact-hang']) {
  test(`Codex native compact waits for completion and handles ${mode}`, { timeout: 10_000 }, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'cc-remote-codex-compact-'));
    const logPath = join(dir, 'requests.jsonl');
    const bridge = new CodexBridge({
      codexBin: process.execPath,
      codexArgs: [fixture, `--fake-log=${logPath}`, `--fake-mode=${mode}`],
      workspaceDir: dir,
    });
    const text: string[] = [];
    const events: any[] = [];
    const callbacks = { permissionMode: 'manual' as const, onEvent: (event: unknown) => events.push(event),
      onText: (value: string) => text.push(value), onSessionId: () => {} };
    let releaseStarted!: () => void;
    const started = new Promise<void>(resolve => { releaseStarted = resolve; });
    try {
      const resultPromise = bridge.run({
        prompt: '/compact ', sessionId: 'fake-thread-id', model: 'gpt-test-codex', sandboxMode: 'workspace-write',
        ...callbacks,
        onEvent: (event: any) => {
          events.push(event);
          if (event.type === 'turn.started') releaseStarted();
        },
      });
      if (mode !== 'compact-rpc-error') {
        await started;
        assert.equal(bridge.isRunning(), true);
        assert.deepEqual(text, []);
        await assert.rejects(bridge.run({ prompt: 'another turn', ...callbacks }), /already running/);
        if (mode === 'compact-hang') assert.equal(bridge.stop(), true);
      }
      const result = await resultPromise;
      assert.equal(bridge.isRunning(), false);
      assert.equal(result.sessionId, 'fake-thread-id');
      if (mode === 'normal') {
        assert.equal(result.exitCode, 0);
        assert.deepEqual(text, ['上下文压缩完成。']);
        assert.equal(events.filter(event => event.type === 'turn.completed').length, 1);
      } else {
        assert.deepEqual(text, []);
        if (mode === 'compact-hang') assert.equal(result.stopped, true);
        else assert.match(result.stderr, mode === 'compact-failed' ? /compaction_failed/ : /compaction_unavailable/);
      }
      const records = (await readFile(logPath, 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
      assert.equal(records.filter(item => item.method === 'turn/start' || item.method === 'skills/list').length, 0);
      assert.deepEqual(records.find(item => item.method === 'thread/compact/start').params, { threadId: 'fake-thread-id' });
      const resume = records.find(item => item.method === 'thread/resume').params;
      assert.equal(resume.model, 'gpt-test-codex');
      assert.equal(resume.sandbox, 'workspace-write');
      if (mode === 'compact-hang') {
        assert.deepEqual(records.find(item => item.method === 'turn/interrupt').params,
          { threadId: 'fake-thread-id', turnId: 'compact-1' });
      }
    } finally {
      bridge.close();
      await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}

test('Codex command catalog includes native commands and native review targets', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-codex-native-'));
  const logPath = join(dir, 'requests.jsonl');
  const bridge = new CodexBridge({
    codexBin: process.execPath, codexArgs: [fixture, `--fake-log=${logPath}`], workspaceDir: dir,
  });
  const callbacks = { permissionMode: 'manual' as const, onEvent: () => {}, onText: () => {}, onSessionId: () => {} };
  try {
    assert.deepEqual(await bridge.listCommands(), ['compact', 'review', 'inspect']);
    assert.match((await bridge.run({ prompt: '/compact', ...callbacks })).stderr, /还没有 Codex 上下文/);
    assert.match((await bridge.run({ prompt: '/compact extra', ...callbacks })).stderr, /不接受参数/);
    assert.match((await bridge.run({ prompt: '/review', imagePaths: ['image.png'], ...callbacks })).stderr, /不接受图片附件/);
    for (const prompt of ['/review ', '/review check security\ninclude tests']) {
      assert.equal((await bridge.run({ prompt, ...callbacks })).exitCode, 0);
    }
    assert.equal((await bridge.run({ prompt: '/compact', ...callbacks })).exitCode, 0);
    assert.equal((await bridge.run({ prompt: 'continue', ...callbacks })).exitCode, 0);
    const records = (await readFile(logPath, 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
    const reviews = records.filter(item => item.method === 'review/start');
    assert.deepEqual(reviews.map(item => item.params.target), [
      { type: 'uncommittedChanges' }, { type: 'custom', instructions: 'check security\ninclude tests' },
    ]);
    assert.ok(reviews.every(item => item.params.delivery === 'inline'));
    assert.equal(records.filter(item => item.method === 'thread/start').length, 1);
    assert.equal(records.filter(item => item.method === 'skills/list').length, 1);
    assert.equal(records.filter(item => item.method === 'turn/start').length, 1);
  } finally {
    bridge.close();
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});
