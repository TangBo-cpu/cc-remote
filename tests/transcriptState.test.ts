import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createTranscriptState } from '../src/transcriptState.js';

test('persists the authoritative transcript and restores it after restart', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-'));
  const path = join(dir, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.beginPrompt('检查项目', 'manual');
    state.appendText('已经检查完成');
    state.setSessionInfo({ model: 'claude-opus-4-8', contextWindow: 200000, remainingTokens: 175000 });
    state.setClaudeSessionId('session-1');
    await state.finishDone();

    const restored = await createTranscriptState(path);
    assert.deepEqual(restored.snapshot(), {
      version: 1,
      revision: 5,
      running: false,
      updatedAt: restored.snapshot().updatedAt,
      claudeSessionId: 'session-1',
      permissionMode: 'manual',
      pendingPermissions: [],
      sessionInfo: {
        model: 'claude-opus-4-8',
        contextWindow: 200000,
        remainingTokens: 175000,
      },
      messages: [
        { role: 'user', text: '检查项目' },
        { role: 'assistant', text: '已经检查完成' },
      ],
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('normalizes a persisted running task to interrupted on daemon restart', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-'));
  const path = join(dir, 'transcript.json');
  try {
    await writeFile(path, JSON.stringify({
      version: 1,
      revision: 2,
      running: true,
      updatedAt: Date.now(),
      sessionInfo: {},
      messages: [
        { role: 'user', text: '长任务' },
        {
          role: 'activity',
          text: '正在思考',
          activityId: 'thinking',
          activityKind: 'thinking',
          activityState: 'running',
        },
      ],
    }), 'utf8');

    const state = await createTranscriptState(path);
    assert.equal(state.snapshot().running, false);
    assert.deepEqual(state.snapshot().messages, [
      { role: 'user', text: '长任务' },
      { role: 'system', text: '电脑端重启，任务已中断' },
    ]);
    const saved = JSON.parse(await readFile(path, 'utf8')) as { running: boolean };
    assert.equal(saved.running, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('keeps safe activity metadata and clears the conversation atomically', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-'));
  const path = join(dir, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.beginPrompt('读取文件', 'manual');
    state.mergeActivity({
      id: 'tool-1',
      kind: 'tool',
      state: 'running',
      toolName: 'Read',
      detail: 'README.md',
    });
    await state.flush();
    assert.deepEqual(state.snapshot().messages.at(-1), {
      role: 'activity',
      text: '正在调用 Read',
      activityId: 'tool-1',
      activityKind: 'tool',
      activityState: 'running',
      activityTool: 'Read',
      activityDetail: 'README.md',
    });

    await state.clear();
    assert.equal(state.snapshot().running, false);
    assert.deepEqual(state.snapshot().messages, []);
    assert.deepEqual(state.snapshot().sessionInfo, {});
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('persists pending approvals and resets bypass mode after the task', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-'));
  const path = join(dir, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.beginPrompt('执行命令', 'bypassPermissions');
    state.addPermission({
      requestId: 'permission-1',
      toolName: 'Bash',
      input: { command: 'npm test' },
      detail: 'npm test',
      description: 'Run tests',
    });
    await state.flush();

    assert.equal(state.snapshot().permissionMode, 'bypassPermissions');
    assert.deepEqual(state.snapshot().pendingPermissions, [{
      requestId: 'permission-1',
      toolName: 'Bash',
      detail: 'npm test',
      description: 'Run tests',
    }]);

    state.removePermission('permission-1');
    await state.finishStopped();
    assert.equal(state.snapshot().permissionMode, 'manual');
    assert.deepEqual(state.snapshot().pendingPermissions, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
