import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';

test('web client replaces completed items without duplicating other reply parts', async () => {
  const bubbles: Array<{ className?: string; textContent?: string }> = [];
  const element = { addEventListener() {}, append: (bubble: typeof bubbles[number]) => bubbles.push(bubble) };
  const source = await readFile(new URL('../src/web/app.ts', import.meta.url), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
  const receive = runInNewContext(compiled + '\nhandleServerMessage', {
    document: { getElementById: () => element, createElement: () => ({}) },
    navigator: {}, location: { pathname: '/' },
    localStorage: { getItem: () => null, removeItem() {} },
    fetch: async () => ({ status: 401 }),
  }) as (event: unknown) => void;
  receive({ type: 'text', messageId: 'progress', text: '检查' });
  receive({ type: 'text', messageId: 'answer', text: '第一段。' });
  receive({ type: 'text', messageId: 'progress', text: '检查完成。', replace: true });
  receive({ type: 'text', messageId: 'answer', text: '\n\n第二段。' });
  receive({ type: 'text', messageId: 'extra', text: '补充。', replace: true });
  assert.deepEqual(bubbles.map(bubble => bubble.textContent), ['检查完成。', '第一段。\n\n第二段。', '补充。']);
  receive({ type: 'done', exitCode: 0 });
  receive({ type: 'text', messageId: 'answer', text: '新一轮。' });
  assert.equal(bubbles.at(-1)?.textContent, '新一轮。');
});
