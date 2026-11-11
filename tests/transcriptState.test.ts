import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';
import { createTranscriptState } from '../src/transcriptState.js';

test('pages ten messages without truncating stored history and rejects stale cursors', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-pages-'));
  try {
    const state = await createTranscriptState(join(dir, 'transcript.json'));
    for (let i = 0; i < 13; i++) {
      state.beginPrompt('question ' + i, 'manual');
      state.appendText('answer ' + i);
      await state.finishDone();
    }
    const full = state.snapshot();
    const tail = state.snapshot({});
    assert.equal(tail.messages.length, 10);
    assert.equal(tail.history?.start, 16);
    assert.equal(tail.history?.total, 26);
    assert.deepEqual(tail.messages, full.messages.slice(-10));
    const middle = state.snapshot({ before: tail.history!.before! });
    const first = state.snapshot({ before: middle.history!.before! });
    assert.deepEqual([...first.messages, ...middle.messages, ...tail.messages], full.messages);
    assert.equal(first.history?.before, null);
    tail.messages[0].text = 'client mutation';
    assert.deepEqual(state.snapshot(), full);
    state.beginPrompt('new question', 'manual');
    assert.deepEqual(state.snapshot({ before: middle.history!.before! }).messages, first.messages);
    assert.throws(() => state.snapshot({ before: 'not-a-cursor' }), /invalid_transcript_cursor/);
    await state.clear();
    assert.throws(() => state.snapshot({ before: middle.history!.before! }), /transcript_history_changed/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

for (const typed of [false, true]) {
  test(`pages ten body messages without counting process records (typed: ${typed})`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-body-pages-'));
    try {
      const state = await createTranscriptState(join(dir, 'transcript.json'));
      for (let turn = 0; turn < 7; turn++) {
        state.beginPrompt('question ' + turn, 'manual');
        state.appendText('checking ' + turn, typed ? { phase: 'commentary' } : undefined);
        for (let tool = 0; tool < 6; tool++) {
          state.mergeActivity({
            id: `tool-${turn}-${tool}`, kind: 'tool', state: 'done', toolName: 'Read',
          });
        }
        state.appendText('answer ' + turn, typed ? { phase: 'final_answer' } : undefined);
        await state.finishDone();
      }
      const full = state.snapshot();
      const tail = state.snapshot({});
      const body = tail.messages.filter(message => /^(question|answer) /.test(message.text));
      assert.equal(body.length, 10);
      assert.equal(tail.messages[0].text, 'question 2');
      assert.equal(tail.messages.filter(message => message.role === 'activity').length, 30);
      const first = state.snapshot({ before: tail.history!.before! });
      assert.equal(first.history?.before, null);
      assert.deepEqual([...first.messages, ...tail.messages], full.messages);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}

test('very long process history stays bounded and pages without losing records', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-long-pages-'));
  try {
    const state = await createTranscriptState(join(dir, 'transcript.json'));
    state.beginPrompt('question', 'manual');
    for (let tool = 0; tool < 450; tool++) {
      state.mergeActivity({ id: `tool-${tool}`, kind: 'tool', state: 'done', toolName: 'Read' });
    }
    state.appendText('answer');
    await state.finishDone();
    const full = state.snapshot();
    let page = state.snapshot({});
    assert.equal(page.messages.length, 200);
    const combined = [...page.messages];
    while (page.history!.before !== null) {
      assert.ok(page.messages.length > 0 && page.messages.length <= 200);
      page = state.snapshot({ before: page.history!.before });
      combined.unshift(...page.messages);
    }
    assert.deepEqual(combined, full.messages);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('background save failure stays recoverable and flush retries unsaved history', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-save-failure-'));
  const blocked = join(dir, 'blocked');
  const path = join(blocked, 'transcript.json');
  try {
    const { stderr } = await promisify(execFile)(process.execPath, [
      '--import', import.meta.resolve('tsx'), '--input-type=module', '-e', `
        import assert from 'node:assert/strict';
        import { rm, writeFile } from 'node:fs/promises';
        import { createTranscriptState } from ${JSON.stringify(new URL('../src/transcriptState.ts', import.meta.url).href)};
        const state = await createTranscriptState(process.argv[1]);
        await writeFile(process.argv[2], 'not a directory');
        const failed = new Promise(resolve => {
          const warn = console.warn;
          console.warn = (...args) => { warn(...args); resolve(); };
        });
        const timeout = setTimeout(() => { throw new Error('save_failure_timeout'); }, 3000);
        state.beginPrompt('keep this question', 'manual');
        state.appendText('keep this answer');
        await failed;
        await assert.rejects(state.flush());
        assert.equal(state.snapshot().messages.at(-1).text, 'keep this answer');
        await rm(process.argv[2]);
        await state.flush();
        await state.finishDone();
        clearTimeout(timeout);
      `, path, blocked,
    ], { windowsHide: true, timeout: 10_000 });
    assert.match(stderr, /Could not save session history/);
    const restored = await createTranscriptState(path);
    assert.equal(restored.snapshot().running, false);
    assert.deepEqual(restored.snapshot().messages.map(message => message.text), [
      'keep this question', 'keep this answer',
    ]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('persists the authoritative transcript and restores it after restart', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-'));
  const path = join(dir, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    assert.equal(state.snapshot().permissionMode, 'auto');
    state.beginPrompt('检查项目', 'manual');
    state.appendText('已经检查完成');
    state.setSessionInfo({ model: 'claude-opus-4-8', contextWindow: 200000, remainingTokens: 175000 });
    state.setEngineSessionId('session-1');
    await state.finishDone();

    const restored = await createTranscriptState(path);
    assert.deepEqual(restored.snapshot(), {
      version: 1,
      revision: 5,
      running: false,
      updatedAt: restored.snapshot().updatedAt,
      engineSessionId: 'session-1',
      sandboxMode: undefined,
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

test('keeps leading whitespace stream fragments until visible text arrives', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-'));
  const path = join(dir, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.beginPrompt('写代码', 'manual');
    state.appendText('    ');
    assert.equal(
      state.snapshot().messages.some((message) => message.role === 'assistant'),
      false,
      'whitespace-only prefix must not open a blank assistant bubble',
    );

    state.appendText('const x = 1;');
    assert.deepEqual(state.snapshot().messages.at(-1), {
      role: 'assistant',
      text: '    const x = 1;',
    });

    await state.finishDone();
    assert.deepEqual(state.snapshot().messages.at(-1), {
      role: 'assistant',
      text: '    const x = 1;',
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('discards whitespace-only prefix when the turn ends without visible text', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-'));
  const path = join(dir, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.beginPrompt('空回复', 'manual');
    state.appendText('  \n');
    await state.finishDone();
    assert.equal(state.snapshot().messages.length, 2);
    assert.equal(state.snapshot().messages[0].role, 'user');
    assert.equal(state.snapshot().messages[0].text, '空回复');
    assert.deepEqual(state.snapshot().messages[1], {
      role: 'system',
      text: '本轮没有返回文本，请重试',
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
      { role: 'activity', text: '思考已停止', activityId: 'thinking',
        activityKind: 'thinking', activityState: 'stopped' },
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
      durationMs: 3200,
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
      activityDurationMs: 3200,
    });

    await state.clear();
    assert.equal(state.snapshot().running, false);
    assert.deepEqual(state.snapshot().messages, []);
    assert.deepEqual(state.snapshot().sessionInfo, {});
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('persists bypass mode for the whole conversation', async () => {
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
    assert.equal(state.snapshot().permissionMode, 'bypassPermissions');
    assert.deepEqual(state.snapshot().pendingPermissions, []);

    const restored = await createTranscriptState(path);
    assert.equal(restored.snapshot().permissionMode, 'bypassPermissions');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('persists attachment metadata without exposing local file paths', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-transcript-attachments-'));
  const path = join(dir, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.beginPrompt('分析截图', 'manual', [{
      id: 'attachment-1',
      name: 'screen.png',
      mimeType: 'image/png',
      size: 2048,
    }]);
    await state.flush();

    const message = state.snapshot().messages[0];
    assert.deepEqual(message.attachments, [{
      id: 'attachment-1',
      name: 'screen.png',
      mimeType: 'image/png',
      size: 2048,
    }]);
    assert.equal(JSON.stringify(message).includes('uploads'), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('process history survives completion, repeated IDs and restart', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-process-'));
  const path = join(dir, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.beginPrompt('first', 'auto');
    state.mergeActivity({ id: 'thinking', kind: 'thinking', state: 'running', detail: 'First thought.' });
    state.mergeActivity({ id: 'thinking', kind: 'thinking', state: 'done', durationMs: 3200 });
    state.mergeActivity({ id: 'summary', kind: 'summary', state: 'done', durationMs: 90000 });
    state.appendText('First answer.');
    await state.finishDone();
    state.beginPrompt('second', 'auto');
    state.mergeActivity({ id: 'thinking', kind: 'thinking', state: 'running', detail: 'Second thought.' });
    await state.finishStopped();
    const restored = await createTranscriptState(path);
    const thoughts = restored.snapshot().messages.filter(message => message.activityKind === 'thinking');
    assert.equal(thoughts.length, 2);
    assert.equal(thoughts[0].activityState, 'done');
    assert.equal(thoughts[0].activityDetail, 'First thought.');
    assert.equal(thoughts[0].activityDurationMs, 3200);
    assert.equal(thoughts[1].activityState, 'stopped');
    assert.equal(thoughts[1].activityDetail, 'Second thought.');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('tool progress and text close thinking, error preserves tool evidence', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-process-'));
  try {
    const state = await createTranscriptState(join(dir, 'transcript.json'));
    state.beginPrompt('check', 'auto');
    state.mergeActivity({ id: 'thinking', kind: 'thinking', state: 'running', detail: 'Check files.' });
    state.mergeActivity({ id: 'read', kind: 'tool', state: 'running', toolName: 'Read', detail: 'README.md' });
    assert.equal(state.snapshot().messages[1].activityState, 'done');
    await state.finishError('failed');
    assert.equal(state.snapshot().messages[2].activityState, 'error');
    assert.equal(state.snapshot().messages[2].activityDetail, 'README.md');
    state.beginPrompt('reply', 'auto');
    state.mergeActivity({ id: 'thinking', kind: 'thinking', state: 'running' });
    state.appendText('answer');
    assert.equal(state.snapshot().messages.at(-2)?.activityState, 'done');
    await state.finishDone();
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
