import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';
import test from 'node:test';
import { createAuthState } from '../src/authState.js';

async function pairNext(auth: Awaited<ReturnType<typeof createAuthState>>, deviceName?: string) {
  const payload = auth.createPairingPayload('https://cc.example.com', 'Test PC');
  const result = await auth.pair(payload.nonce, deviceName);
  assert.ok('token' in result, `pairing failed: ${JSON.stringify(result)}`);
  return result;
}

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

    const first = await pairNext(auth, 'Pixel 9');
    assert.equal(auth.verifyToken(first.token), first.deviceId);
    assert.equal(auth.verifyBearerToken(`Bearer ${first.token}`), first.deviceId);
    const generation = auth.getAuthGeneration();
    assert.deepEqual(await auth.pair(payload.nonce), { error: 'invalid_pairing_code' });

    await auth.logout();
    assert.equal(auth.verifyToken(first.token), null);
    assert.equal(auth.getAuthGeneration(), generation + 1);

    const next = await pairNext(auth);
    assert.notEqual(next.deviceId, first.deviceId);
    assert.equal(auth.verifyToken(next.token), next.deviceId);

    await auth.setClaudeSessionId('session-1');
    const reloaded = await createAuthState(statePath);
    assert.deepEqual(reloaded.status(), { paired: true, deviceCount: 1, hasClaudeSessionId: true });
    assert.equal(reloaded.getClaudeSessionId(), 'session-1');

    await reloaded.setClaudeSessionId(undefined);
    assert.deepEqual(reloaded.status(), { paired: true, deviceCount: 1, hasClaudeSessionId: false });
    assert.equal(reloaded.getClaudeSessionId(), undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('multiple devices pair independently and revoke individually', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-'));
  try {
    const statePath = join(dir, 'state.json');
    const auth = await createAuthState(statePath);

    const phone = await pairNext(auth, '  Pixel\t9  ');
    const tablet = await pairNext(auth, 'Pixel Tablet');

    assert.deepEqual(
      auth.listDevices().map(device => device.name),
      ['Pixel 9', 'Pixel Tablet'],
    );
    assert.equal(auth.verifyToken(phone.token), phone.deviceId);
    assert.equal(auth.verifyToken(tablet.token), tablet.deviceId);
    assert.equal(auth.isDeviceActive(phone.deviceId), true);
    assert.equal(auth.isDeviceActive(tablet.deviceId), true);

    const listed = auth.listDevices();
    assert.equal(listed.length, 2);
    assert.equal(listed[0].id, phone.deviceId);
    assert.equal(listed[0].name, 'Pixel 9');
    assert.equal(typeof listed[0].pairedAt, 'number');

    const revoked = await auth.logout(tablet.deviceId);
    assert.equal(revoked, 1);
    assert.equal(auth.verifyToken(tablet.token), null);
    assert.equal(auth.isDeviceActive(tablet.deviceId), false);
    assert.equal(auth.verifyToken(phone.token), phone.deviceId);

    assert.equal(await auth.logout(tablet.deviceId), 0);
    assert.deepEqual(auth.status(), { paired: true, deviceCount: 1, hasClaudeSessionId: false });

    const persisted = JSON.parse(await readFile(statePath, 'utf8')) as {
      devices?: { id: string; name: string }[];
      tokenHash?: string;
    };
    assert.equal(persisted.devices?.length, 1);
    assert.equal(persisted.devices?.[0].id, phone.deviceId);
    assert.equal(typeof persisted.tokenHash, 'string');

    await auth.logout();
    assert.deepEqual(auth.status(), { paired: false, deviceCount: 0, hasClaudeSessionId: false });
    assert.equal(auth.verifyToken(phone.token), null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('device limit rejects additional pairing without consuming the nonce', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-'));
  try {
    const auth = await createAuthState(join(dir, 'state.json'), 1);
    const first = await pairNext(auth, 'Pixel 9');
    assert.equal(auth.listDevices().length, 1);

    const payload = auth.createPairingPayload('https://cc.example.com', 'Test PC');
    assert.deepEqual(await auth.pair(payload.nonce, 'Pixel Tablet'), { error: 'device_limit' });

    await auth.logout(first.deviceId);
    const retry = await auth.pair(payload.nonce, 'Pixel Tablet');
    assert.ok('token' in retry);
    assert.equal(auth.listDevices()[0].name, 'Pixel Tablet');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('legacy single-token state migrates to a device record', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-'));
  try {
    const statePath = join(dir, 'state.json');
    const { createHash } = await import('node:crypto');
    const legacyToken = 'legacy-token';
    const legacy = {
      stateSecret: 'secret-1',
      tokenHash: createHash('sha256').update(legacyToken).digest('base64url'),
      claudeSessionId: 'session-9',
      authGeneration: 3,
    };
    await (await import('node:fs/promises')).writeFile(statePath, JSON.stringify(legacy), 'utf8');

    const auth = await createAuthState(statePath);
    const deviceId = auth.verifyToken(legacyToken);
    assert.ok(deviceId);
    assert.deepEqual(auth.status(), { paired: true, deviceCount: 1, hasClaudeSessionId: true });
    assert.equal(auth.listDevices()[0].name, '已配对手机');
    assert.equal(auth.getAuthGeneration(), 3);

    const next = await pairNext(auth, 'Pixel 9');
    assert.equal(auth.verifyToken(legacyToken), deviceId);
    assert.equal(auth.verifyToken(next.token), next.deviceId);
    assert.equal(auth.listDevices().length, 2);

    const persisted = JSON.parse(await readFile(statePath, 'utf8')) as { devices?: unknown[] };
    assert.equal(persisted.devices?.length, 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('device name is sanitized and defaulted', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-'));
  try {
    const auth = await createAuthState(join(dir, 'state.json'), 3);
    await pairNext(auth, '');
    await pairNext(auth, '  \u0007控制\u001f字符\n\n换行  ');
    await pairNext(auth, `${'x'.repeat(80)} trailing`);

    const names = auth.listDevices().map(device => device.name);
    assert.equal(names[0], 'Android 设备');
    assert.equal(names[1], '控制 字符 换行');
    assert.equal(names[2].length, 64);
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
