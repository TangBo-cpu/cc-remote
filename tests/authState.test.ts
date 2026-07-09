import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';
import test from 'node:test';
import { createAuthState } from '../src/authState.js';

test('pairing issues a bearer token and persists session id', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-'));
  try {
    const statePath = join(dir, 'state.json');
    const auth = await createAuthState(statePath);
    const payload = auth.createPairingPayload('https://cc.example.com', 'Test PC');

    assert.equal(payload.type, 'cc-remote-pair');
    assert.equal(payload.version, 1);
    assert.equal(payload.origin, 'https://cc.example.com');
    assert.equal(payload.deviceName, 'Test PC');
    assert.ok(payload.expiresAt > Date.now());

    const token = await auth.pair(payload.nonce);
    assert.ok(token);
    assert.equal(auth.verifyToken(token), true);
    assert.equal(auth.verifyBearerToken(`Bearer ${token}`), true);
    const generation = auth.getAuthGeneration();
    assert.equal(await auth.pair(payload.nonce), null);

    await auth.logout();
    assert.equal(auth.verifyToken(token), false);
    assert.equal(auth.getAuthGeneration(), generation + 1);

    const nextPayload = auth.createPairingPayload('https://cc.example.com', 'Test PC');
    const nextToken = await auth.pair(nextPayload.nonce);
    assert.ok(nextToken);
    assert.equal(auth.verifyToken(nextToken), true);

    await auth.setClaudeSessionId('session-1');
    const reloaded = await createAuthState(statePath);
    assert.deepEqual(reloaded.status(), { paired: true, hasClaudeSessionId: true });
    assert.equal(reloaded.getClaudeSessionId(), 'session-1');

    await reloaded.setClaudeSessionId(undefined);
    assert.deepEqual(reloaded.status(), { paired: true, hasClaudeSessionId: false });
    assert.equal(reloaded.getClaudeSessionId(), undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('concurrent session id saves do not reuse the same temp file', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-'));
  try {
    const statePath = join(dir, 'state.json');
    const auth = await createAuthState(statePath);

    await Promise.all([
      auth.setClaudeSessionId('session-1'),
      auth.setClaudeSessionId('session-2'),
    ]);

    const parsed = JSON.parse(await readFile(statePath, 'utf8')) as { claudeSessionId?: string };
    assert.equal(parsed.claudeSessionId, 'session-2');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
