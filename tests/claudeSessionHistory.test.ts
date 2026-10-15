import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { CLAUDE_APP_ENTRYPOINT, syncClaudeSessionHistory } from '../src/claudeSessionHistory.js';

async function fixture(run: (root: string, path: string, sessionId: string) => Promise<void>) {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-native-history-'));
  const sessionId = randomUUID();
  const directory = join(root, 'project');
  await mkdir(directory);
  try {
    await run(root, join(directory, `${sessionId}.jsonl`), sessionId);
  } finally {
    await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
}

for (const entrypoint of ['sdk-cli', 'sdk-ts', 'sdk-py']) {
  test(`native history exposes ${entrypoint} app sessions without changing messages or offsets`, async () => {
    await fixture(async (projectsDir, path, sessionId) => {
      const entries = [
        {
          type: 'user', sessionId, uuid: randomUUID(), parentUuid: null,
          message: { role: 'user', content: [{ type: 'text', text: '中文消息，保留 "entrypoint":"sdk-cli" 与 {括号}' }], entrypoint: 'sdk-cli' },
          entrypoint, isSidechain: false,
        },
        { type: 'assistant', sessionId, uuid: randomUUID(), message: { role: 'assistant', content: '原始回复' }, entrypoint },
        { type: 'user', sessionId, message: { role: 'user', content: '子代理记录' }, entrypoint, isSidechain: true },
        { type: 'user', sessionId: randomUUID(), message: { role: 'user', content: '其他会话' }, entrypoint },
      ];
      const original = entries.map(entry => JSON.stringify(entry)).join('\r\n') + '\r\n';
      await writeFile(path, original);
      assert.equal(await syncClaudeSessionHistory({ projectsDir, sessionId, title: '摄像头学习' }), true);
      const updated = await readFile(path, 'utf8');
      const result = updated.trim().split('\n').map(line => JSON.parse(line));
      assert.deepEqual(result.slice(0, entries.length), entries.map((entry, index) =>
        index < 2 ? { ...entry, entrypoint: CLAUDE_APP_ENTRYPOINT } : entry));
      assert.deepEqual(result.at(-1), { type: 'custom-title', customTitle: '摄像头学习', sessionId });
      assert.equal(updated.split('\n')[0].length, original.split('\n')[0].length);
      assert.equal(await readFile(`${path}.cc-remote-history.bak`, 'utf8'), original);
      assert.equal(await syncClaudeSessionHistory({ projectsDir, sessionId, title: '摄像头学习' }), false);
      assert.equal(await readFile(path, 'utf8'), updated);

      await appendFile(path, JSON.stringify({ type: 'assistant', sessionId, message: { content: '后续回复' }, entrypoint }) + '\n');
      assert.equal(await syncClaudeSessionHistory({ projectsDir, sessionId, title: '新标题' }), true);
      const renamed = (await readFile(path, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
      assert.equal(renamed.at(-1).customTitle, '新标题');
      assert.equal(renamed.at(-2).message.content, '后续回复');
      assert.equal(await readFile(`${path}.cc-remote-history.bak`, 'utf8'), original);
    });
  });
}

test('native history leaves incomplete transcripts intact and ignores invalid or missing session ids', async () => {
  await fixture(async (projectsDir, path, sessionId) => {
    const incomplete = JSON.stringify({ type: 'user', sessionId, entrypoint: 'sdk-cli' }) + '\n{"type":"assistant"';
    await writeFile(path, incomplete);
    assert.equal(await syncClaudeSessionHistory({ projectsDir, sessionId, title: 'test' }), false);
    assert.equal(await readFile(path, 'utf8'), incomplete);
    assert.equal(await syncClaudeSessionHistory({ projectsDir, sessionId: '../session', title: 'test' }), false);
    assert.equal(await syncClaudeSessionHistory({ projectsDir, sessionId: randomUUID(), title: 'test' }), false);
  });
});

test('native history reads spaced top-level source fields without changing nested fields', async () => {
  await fixture(async (projectsDir, path, sessionId) => {
    const original = `{ "type": "user", "sessionId": "${sessionId}", "message": { "entrypoint": "sdk-cli", "content": "你好" }, "entrypoint": "sdk-cli" }\n`;
    await writeFile(path, original);
    assert.equal(await syncClaudeSessionHistory({ projectsDir, sessionId, title: '' }), true);
    const updated = await readFile(path, 'utf8');
    assert.equal(Buffer.byteLength(updated), Buffer.byteLength(original));
    assert.equal(JSON.parse(updated).message.entrypoint, 'sdk-cli');
    assert.equal(JSON.parse(updated).entrypoint, CLAUDE_APP_ENTRYPOINT);
  });
});
