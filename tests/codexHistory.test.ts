import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { CodexBridge } from '../src/codexBridge.js';

const firstTurn = {
  id: 'first', status: 'completed', items: [
    { id: 'u1', type: 'userMessage', content: [{ type: 'text', text: '手机提问' }] },
    { id: 'reasoning', type: 'reasoning', content: ['PRIVATE_REASONING'] },
    { id: 'tool', type: 'commandExecution', aggregatedOutput: 'PRIVATE_TOOL_OUTPUT' },
    { id: 'a1', type: 'agentMessage', text: '手机回复' },
  ],
};
const secondTurn = {
  id: 'second', status: 'completed', items: [
    { id: 'u2', type: 'userMessage', content: [
      { type: 'text', text: '电脑提问' }, { type: 'localImage', path: 'PRIVATE_IMAGE_PATH' },
    ] },
    { id: 'a2', type: 'agentMessage', text: '电脑回复' },
  ],
};

for (const mode of ['normal', 'history-summary', 'history-legacy']) {
  test('Codex reads fresh history without resuming or running the thread (' + mode + ')', async () => {
    const root = await mkdtemp(join(tmpdir(), 'cc-remote-codex-history-'));
    const path = join(root, 'history.json');
    const log = join(root, 'requests.jsonl');
    const bridge = new CodexBridge({
      codexBin: process.execPath,
      codexArgs: [
        join(process.cwd(), 'tests', 'fixtures', 'fakeCodex.mjs'),
        '--fake-history=' + path, '--fake-log=' + log, '--fake-mode=' + mode,
      ],
      workspaceDir: root,
    });
    try {
      await writeFile(path, JSON.stringify({ turns: [firstTurn, secondTurn] }));
      const result = await bridge.readHistory('native-thread');
      assert.equal(result.sessionId, 'native-thread');
      assert.equal(result.running, false);
      assert.deepEqual(result.messages.map(message => message.text),
        ['手机提问', '手机回复', '电脑提问', '电脑回复']);
      assert.equal(JSON.stringify(result).includes('PRIVATE'), false);
      await writeFile(path, JSON.stringify({
        running: true, turns: [firstTurn, { ...secondTurn, status: 'inProgress' }],
      }));
      assert.equal((await bridge.readHistory('native-thread')).running, true);
      const records = (await readFile(log, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
      assert.equal(records.filter(record => record.kind === 'process').length, 1);
      assert.equal(records.some(record => record.method === 'thread/resume'
        || record.method === 'turn/start'), false);
      if (mode === 'history-summary') {
        assert.equal(records.some(record => record.method === 'thread/items/list'), true);
      }
    } finally {
      bridge.close();
      await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}

for (const mode of ['history-error', 'history-wrong-thread', 'history-loop']) {
  test('Codex rejects unsafe history without masking the error (' + mode + ')', async () => {
    const root = await mkdtemp(join(tmpdir(), 'cc-remote-codex-history-error-'));
    const log = join(root, 'requests.jsonl');
    const bridge = new CodexBridge({
      codexBin: process.execPath,
      codexArgs: [
        join(process.cwd(), 'tests', 'fixtures', 'fakeCodex.mjs'),
        '--fake-log=' + log, '--fake-mode=' + mode,
      ],
      workspaceDir: root,
    });
    try {
      await assert.rejects(bridge.readHistory('native-thread'), /history_unavailable|native_history_invalid/);
      const records = (await readFile(log, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
      assert.equal(records.some(record => record.params?.includeTurns === true), false);
    } finally {
      bridge.close();
      await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}
