import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createLocalControlState } from '../src/localControlState.js';

test('persists and verifies a private local control token', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-local-control-'));
  const path = join(dir, 'local-control.json');
  try {
    const first = await createLocalControlState(path);
    const second = await createLocalControlState(path);
    assert.equal(second.token, first.token);
    assert.equal(second.verify(first.token), true);
    assert.equal(second.verify('wrong'), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
