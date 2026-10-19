import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rename, rm, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { ClaudeHistoryReader, parseClaudeHistory } from '../src/claudeSessionHistory.js';
import { mergeNativeMessages, type NativeHistory, type NativeMessage } from '../src/nativeHistory.js';
import { createTranscriptState, type TranscriptMessage } from '../src/transcriptState.js';

const sessionId = randomUUID();
function nativeTurn(id: string, prompt: string, reply: string): NativeMessage[] {
  return [
    { id: id + '-user', role: 'user', text: prompt },
    { id: id + '-reply', role: 'assistant', text: reply },
  ];
}
const phone = nativeTurn('phone', '手机问题', '手机回复');
const desktop = nativeTurn('desktop', '电脑问题', '电脑回复');
const local: TranscriptMessage[] = phone.map(({ role, text }) => ({ role, text }));
const history = (messages = [...phone, ...desktop]): NativeHistory => ({
  sessionId, messages, running: false,
});

test('native merge binds legacy messages, preserves local detail, and imports desktop history once', () => {
  const annotated: TranscriptMessage[] = [
    local[0],
    { role: 'activity', text: '已调用工具', activityId: 'tool-1' },
    local[1],
    { role: 'system', text: '已停止' },
  ];
  const merged = mergeNativeMessages(annotated, history().messages);
  assert.equal(merged.external, true);
  assert.equal(merged.messages.length, 6);
  assert.equal(merged.messages[1].activityId, 'tool-1');
  assert.equal(merged.messages[3].text, '已停止');
  assert.deepEqual(merged.messages.slice(4).map(message => message.text), ['电脑问题', '电脑回复']);
  assert.deepEqual(merged.messages[0].native?.ids, ['phone-user', 'phone-reply']);
  const again = mergeNativeMessages(merged.messages, history().messages);
  assert.equal(again.external, false);
  assert.deepEqual(again.messages, merged.messages);
});

test('identical messages in different native turns remain distinct', () => {
  const first = mergeNativeMessages(local, phone).messages;
  const repeated = mergeNativeMessages(first, [...phone, ...nativeTurn('repeat', '手机问题', '手机回复')]);
  assert.equal(repeated.messages.length, 4);
  assert.notDeepEqual(repeated.messages[0].native?.ids, repeated.messages[2].native?.ids);
  assert.throws(() => mergeNativeMessages(local,
    [...phone, ...nativeTurn('repeat', '手机问题', '手机回复')]), /native_history_conflict/);
});

test('legacy repeated turns match only when their complete ordered alignment is unique', () => {
  const twice = [...phone, ...nativeTurn('repeat', '手机问题', '手机回复')];
  const result = mergeNativeMessages([...local, ...local], twice);
  assert.deepEqual(result.messages.filter(message => message.role === 'user')
    .map(message => message.native?.ids[0]), ['phone-user', 'repeat-user']);
});

test('native updates replace the existing reply and preserve local activities and diagnostics', () => {
  const first = mergeNativeMessages([
    local[0], { role: 'activity', text: '工具结果' }, local[1],
    { role: 'system', text: '诊断' },
  ], phone).messages;
  const result = mergeNativeMessages(first, nativeTurn('phone', '手机问题', '手机回复，补充内容'));
  assert.deepEqual(result.messages.map(message => message.text),
    ['手机问题', '工具结果', '手机回复，补充内容', '诊断']);
  assert.equal(result.external, true);
  assert.throws(() => mergeNativeMessages(result.messages,
    nativeTurn('phone', '手机问题', '分叉回复').map(message =>
      message.role === 'assistant' ? { ...message, id: 'different-reply' } : message)),
  /native_history_conflict/);
});

test('native merge retains upload metadata and matches the exact engine prompt', () => {
  const prompt = '问题\n\n附件说明';
  const original: TranscriptMessage[] = [{
    role: 'user', text: '问题', nativePrompt: prompt,
    attachments: [{ id: 'file', name: 'image.png', mimeType: 'image/png', size: 20 }],
  }, { role: 'assistant', text: '回复' }];
  const result = mergeNativeMessages(original, nativeTurn('upload', prompt, '回复'));
  assert.equal(result.messages[0].text, '问题');
  assert.deepEqual(result.messages[0].attachments, original[0].attachments);
});

test('native merge aligns assistant fragments around tools without removing the tools', () => {
  const original: TranscriptMessage[] = [
    local[0], { role: 'assistant', text: '手机' },
    { role: 'activity', text: '工具' }, { role: 'assistant', text: '回复' },
  ];
  assert.equal(mergeNativeMessages(original, phone).messages.length, 4);
});

test('failed local-only requests survive subsequent native imports', () => {
  const failed: TranscriptMessage[] = [
    { role: 'user', text: '未送达' }, { role: 'system', text: '错误：进程退出' },
  ];
  const first = mergeNativeMessages([...local, ...failed], phone).messages;
  const next = mergeNativeMessages(first, history().messages);
  assert.deepEqual(next.messages.map(message => message.text),
    ['手机问题', '手机回复', '未送达', '错误：进程退出', '电脑问题', '电脑回复']);
});

test('conflicting or truncated history never replaces the saved conversation', () => {
  const first = mergeNativeMessages(local, phone).messages;
  for (const incoming of [desktop, [], [phone[0]], [...phone, phone[1]]]) {
    assert.throws(() => mergeNativeMessages(first, incoming), /native_history_(conflict|invalid)/);
    assert.equal(first[1].text, '手机回复');
  }
});

test('local control commands remain in order without blocking later history imports', () => {
  const command: TranscriptMessage[] = [
    { role: 'user', text: '/compact', nativeLocalOnly: true },
    { role: 'assistant', text: '上下文压缩完成。' },
  ];
  const bound = mergeNativeMessages([...local, ...command], phone).messages;
  const result = mergeNativeMessages(bound, history().messages);
  assert.deepEqual(result.messages.map(message => message.text),
    ['手机问题', '手机回复', '/compact', '上下文压缩完成。', '电脑问题', '电脑回复']);
});

function entry(id: string, parent: string | null, type: string, content: unknown, extra = {}) {
  return {
    sessionId, uuid: id, parentUuid: parent, type,
    message: { role: type, content }, ...extra,
  };
}
const jsonl = (entries: unknown[]) => entries.map(value => JSON.stringify(value)).join('\n') + '\n';

test('Claude reader follows the main parent chain and filters sidechains, tool results and metadata', () => {
  const source = jsonl([
    entry('u1', null, 'user', '手机问题'),
    entry('a1', 'u1', 'assistant', [{ type: 'text', text: '手机回复' }, { type: 'thinking', thinking: 'hidden' }]),
    entry('old', 'a1', 'assistant', '已分叉回复'),
    entry('tool', 'a1', 'user', [{ type: 'tool_result', content: '秘密工具输出' }]),
    entry('meta', 'tool', 'user', '内部说明', { isMeta: true }),
    entry('other', 'meta', 'user', '其他会话', { sessionId: randomUUID() }),
    entry('side', 'a1', 'assistant', '子代理', { isSidechain: true }),
    entry('u2', 'meta', 'user', '电脑问题'),
    entry('a2', 'u2', 'assistant', '电脑回复'),
  ]);
  const result = parseClaudeHistory(sessionId, source);
  assert.deepEqual(result.messages.map(message => message.id), ['u1', 'a1', 'u2', 'a2']);
  assert.equal(result.running, false);
});

test('Claude reader defers incomplete JSON and detects pending native work', () => {
  const source = jsonl([entry('u1', null, 'user', '中文🙂')]);
  const pending = parseClaudeHistory(sessionId, source + '{"type":"assistant"');
  assert.equal(pending.messages.length, 1);
  assert.equal(pending.running, true);
  const done = parseClaudeHistory(sessionId, source + jsonl([entry('a1', 'u1', 'assistant', '完成')]));
  assert.equal(done.running, false);
  assert.equal(done.messages[0].text, '中文🙂');
  assert.throws(() => parseClaudeHistory(sessionId, source + 'invalid\n'));
});

test('Claude compaction links to the previous conversation without importing its summary', () => {
  const result = parseClaudeHistory(sessionId, jsonl([
    entry('u1', null, 'user', '手机问题'),
    entry('a1', 'u1', 'assistant', '手机回复'),
    { sessionId, uuid: 'boundary', parentUuid: null, type: 'system',
      subtype: 'compact_boundary', logicalParentUuid: 'a1' },
    entry('summary', 'boundary', 'user', '内部压缩摘要', { isCompactSummary: true }),
    entry('u2', 'summary', 'user', '电脑问题'),
    entry('a2', 'u2', 'assistant', '电脑回复'),
  ]));
  assert.deepEqual(result.messages.map(message => message.id), ['u1', 'a1', 'u2', 'a2']);
});

test('Claude text blocks match the live bridge without adding whitespace', () => {
  const parsed = parseClaudeHistory(sessionId, jsonl([
    entry('u1', null, 'user', [{ type: 'text', text: '手机' }, { type: 'text', text: '问题' }]),
    entry('a1', 'u1', 'assistant', [{ type: 'text', text: '手机' }, { type: 'text', text: '回复' }]),
  ]));
  assert.equal(mergeNativeMessages(local, parsed.messages).messages.length, 2);
});

test('Claude history cache notices file replacement and never exposes image payloads', async () => {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-native-reader-'));
  try {
    const path = join(root, sessionId + '.jsonl');
    await writeFile(path, jsonl([
      entry('image', null, 'user', [{ type: 'image', source: { data: 'PRIVATE_BASE64' } }]),
      entry('reply', 'image', 'assistant', '图片回复'),
    ]));
    const reader = new ClaudeHistoryReader(root);
    const first = await reader.read(sessionId);
    assert.deepEqual(first?.messages.map(message => message.text), ['[图片]', '图片回复']);
    assert.deepEqual(await reader.read(sessionId), first);
    await rename(path, path + '.old');
    await writeFile(path, jsonl([entry('new', null, 'user', '替换记录')]));
    assert.equal((await reader.read(sessionId))?.messages[0].text, '替换记录');
    const old = new Date(Date.now() - 60_000);
    await utimes(path, old, old);
    assert.equal((await reader.read(sessionId))?.running, false);
    assert.equal(await reader.read('../bad'), null);
  } finally {
    await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('rejected requests and their attachments survive native updates and restart without being resent', async () => {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-native-rejected-'));
  const path = join(root, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.setEngineSessionId(sessionId);
    await state.importNativeHistory(history(phone));
    const attachments = [{ id: 'image', name: 'image.png', mimeType: 'image/png', size: 20 }];
    await state.recordRejectedPrompt('稍后再发', '电脑端仍在处理', attachments);
    await state.importNativeHistory(history());
    const reloaded = await createTranscriptState(path);
    const rejected = reloaded.snapshot().messages.find(message => message.text === '稍后再发');
    assert.equal(rejected?.nativeLocalOnly, true);
    assert.deepEqual(rejected?.attachments, attachments);
    assert.equal(reloaded.snapshot().messages.some(message => message.text === '电脑回复'), true);
    const before = reloaded.snapshot();
    await rename(path, path + '.saved');
    await mkdir(path);
    await assert.rejects(reloaded.recordRejectedPrompt('保存失败', '重试'));
    assert.deepEqual(reloaded.snapshot(), before);
    await rm(path, { recursive: true });
    await rename(path + '.saved', path);
  } finally {
    await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('native import commits messages and identities together and can retry a failed save', async () => {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-native-save-'));
  const path = join(root, 'transcript.json');
  try {
    const state = await createTranscriptState(path);
    state.beginPrompt('手机问题', 'manual');
    state.appendText('手机回复');
    state.setEngineSessionId(sessionId);
    await state.finishDone();
    const before = state.snapshot();
    await rename(path, path + '.saved');
    await mkdir(path);
    await assert.rejects(state.importNativeHistory(history()));
    assert.deepEqual(state.snapshot(), before);
    await rm(path, { recursive: true });
    await rename(path + '.saved', path);
    const result = await state.importNativeHistory(history());
    assert.equal(result.changed, true);
    assert.equal(result.external, true);
    const reloaded = await createTranscriptState(path);
    assert.deepEqual(JSON.parse(JSON.stringify(reloaded.snapshot())),
      JSON.parse(JSON.stringify(state.snapshot())));
    const revision = state.snapshot().revision;
    assert.equal((await state.importNativeHistory(history())).changed, false);
    assert.equal(state.snapshot().revision, revision);
    assert.equal(JSON.parse(await readFile(path, 'utf8')).messages.length, 4);
  } finally {
    await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('native import ignores running and unrelated sessions and respects engine session resets', async () => {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-native-reset-'));
  try {
    const state = await createTranscriptState(join(root, 'transcript.json'));
    state.setEngineSessionId(sessionId);
    state.beginPrompt('手机问题', 'manual');
    assert.equal((await state.importNativeHistory(history())).changed, false);
    state.appendText('手机回复');
    await state.finishDone();
    assert.equal((await state.importNativeHistory({ ...history(), sessionId: 'unrelated' })).changed, false);
    await state.importNativeHistory(history(phone));
    state.beginPrompt('重新开始', 'manual');
    state.setEngineSessionId(undefined);
    state.setEngineSessionId('replacement');
    state.appendText('新回复');
    await state.finishDone();
    await state.importNativeHistory({
      sessionId: 'replacement', running: false,
      messages: [...nativeTurn('replacement', '重新开始', '新回复'), ...desktop],
    });
    assert.deepEqual(state.snapshot().messages.filter(message => message.role === 'user')
      .map(message => message.text), ['手机问题', '重新开始', '电脑问题']);
    await state.clear();
    assert.equal(state.snapshot().nativeHistoryStart, undefined);
  } finally {
    await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});
