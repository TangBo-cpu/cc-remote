import assert from 'node:assert/strict';
import test from 'node:test';
import { ClaudeBridge, isMissingConversationError } from '../src/claudeBridge.js';

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
