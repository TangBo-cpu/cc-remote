import assert from 'node:assert/strict';
import test from 'node:test';
import { extractClaudeActivities } from '../src/claudeBridge.js';

test('only supplied reasoning text becomes a completed thinking activity', () => {
  assert.deepEqual(extractClaudeActivities({ type: 'assistant', message: {
    content: [
      { type: 'thinking', thinking: 'Read the file.' },
      { type: 'thinking', thinking: 'Check the result.' },
      { type: 'tool_use', id: 'read', name: 'Read', input: { file_path: 'README.md' } },
    ],
  } }), [
    { id: 'thinking', kind: 'thinking', state: 'done', detail: 'Read the file.\n\nCheck the result.' },
    { id: 'read', kind: 'tool', state: 'running', toolName: 'Read', detail: 'README.md' },
  ]);
  assert.deepEqual(extractClaudeActivities({ type: 'assistant', message: {
    content: [{ type: 'redacted_thinking', data: 'redacted' }, { type: 'text', text: 'answer' }],
  } }), []);
});
