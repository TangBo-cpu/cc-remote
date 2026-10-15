import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { normalizeCodexSandboxMode, type CodexSandboxMode } from '../src/engineBridge.js';
import { createTranscriptState } from '../src/transcriptState.js';

test('Codex defaults to full access and respects explicit sandbox choices', () => {
  for (const value of [undefined, null, '']) {
    assert.equal(normalizeCodexSandboxMode(value), 'danger-full-access');
  }
  for (const value of ['read-only', 'workspace-write', 'danger-full-access'] as const) {
    assert.equal(normalizeCodexSandboxMode(value), value);
  }
  assert.equal(normalizeCodexSandboxMode('manual'), 'read-only');
  assert.throws(() => normalizeCodexSandboxMode('unknown'), /invalid_permission_mode/);
});

for (const mode of ['read-only', 'workspace-write', 'danger-full-access'] as CodexSandboxMode[]) {
  for (const ending of ['done', 'stopped', 'error', 'restart'] as const) {
    test(`Codex retains ${mode} after ${ending} and restores it from disk`, async () => {
      const dir = await mkdtemp(join(tmpdir(), 'cc-remote-sandbox-'));
      const path = join(dir, 'transcript.json');
      try {
        const state = await createTranscriptState(path);
        state.beginPrompt('inspect project', 'manual', [], mode);
        state.appendText('inspected');
        if (ending === 'done') await state.finishDone();
        if (ending === 'stopped') await state.finishStopped();
        if (ending === 'error') await state.finishError('test failure');
        if (ending === 'restart') await state.flush();

        const restored = await createTranscriptState(path);
        assert.equal(restored.snapshot().running, false);
        assert.equal(restored.snapshot().sandboxMode, mode);
        await restored.flush();
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    });
  }
}
