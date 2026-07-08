import assert from 'node:assert/strict';
import test from 'node:test';
import { ClaudeBridge } from '../src/claudeBridge.js';

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
