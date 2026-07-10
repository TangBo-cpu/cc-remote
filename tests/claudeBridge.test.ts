import assert from 'node:assert/strict';
import test from 'node:test';
import { ClaudeBridge, extractClaudeActivities, isMissingConversationError } from '../src/claudeBridge.js';

test('ClaudeBridge reports a missing CLI as a run result instead of throwing', async () => {
  const bridge = new ClaudeBridge({ claudeBin: 'cc-remote-missing-claude-bin', workspaceDir: process.cwd() });
  const result = await bridge.run({
    prompt: 'test',
    onEvent: () => {},
    onText: () => {},
    onSessionId: () => {},
  });

  assert.equal(result.exitCode, null);
  assert.equal(result.stopped, false);
  assert.match(result.stderr, /ENOENT|not found|spawn/i);
  assert.equal(bridge.isRunning(), false);
});

test('detects stale Claude Code session errors', () => {
  assert.equal(
    isMissingConversationError('Error: No conversation found with session ID: cc8a61d2-6548-4527-b29f-7bc3d2b8aa6b'),
    true,
  );
  assert.equal(isMissingConversationError('Some other Claude error'), false);
});

test('normalizes safe activity events without exposing thinking text or tool results', () => {
  assert.deepEqual(extractClaudeActivities({
    type: 'stream_event',
    event: {
      type: 'content_block_start',
      content_block: { type: 'thinking', thinking: 'private reasoning' },
    },
  }), [{ id: 'thinking', kind: 'thinking', state: 'running' }]);

  assert.deepEqual(extractClaudeActivities({
    type: 'assistant',
    message: {
      content: [{
        type: 'tool_use',
        id: 'tool-1',
        name: 'Read',
        input: { file_path: 'mobile/lib/main.dart' },
      }],
    },
  }), [{
    id: 'tool-1',
    kind: 'tool',
    state: 'running',
    toolName: 'Read',
    detail: 'mobile/lib/main.dart',
  }]);

  assert.deepEqual(extractClaudeActivities({
    type: 'user',
    message: {
      content: [{
        type: 'tool_result',
        tool_use_id: 'tool-1',
        content: 'secret file contents',
      }],
    },
  }), [{ id: 'tool-1', kind: 'tool', state: 'done' }]);

  assert.deepEqual(extractClaudeActivities({
    type: 'result',
    is_error: false,
    duration_ms: 8100,
    num_turns: 2,
    permission_denials: [],
  }), [{
    id: 'summary',
    kind: 'summary',
    state: 'done',
    durationMs: 8100,
    numTurns: 2,
    permissionDenials: 0,
  }]);
});
