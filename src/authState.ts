import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { dirname, join } from 'node:path';

const TOKEN_BYTES = 32;
const SECRET_BYTES = 32;
const PAIRING_TTL_MS = 5 * 60 * 1000;
const DEVICE_ID_BYTES = 8;
const DEVICE_NAME_MAX_CHARS = 64;
const LAST_SEEN_THROTTLE_MS = 60 * 1000;

export const DEFAULT_MAX_PAIRED_DEVICES = 8;

const PAIRING_TYPE = 'cc-remote-pair' as const;
const PAIRING_VERSION = 1 as const;

export type StoredDevice = {
  id: string;
  name: string;
  tokenHash: string;
  pairedAt: number;
  lastSeen?: number;
};

export type PublicDevice = {
  id: string;
  name: string;
  pairedAt: number;
  lastSeen?: number;
};

type StoredState = {
  stateSecret: string;
  devices: StoredDevice[];
  // Legacy mirror of devices[0].tokenHash: a daemon downgraded to the
  // single-token build still accepts the first paired device.
  tokenHash?: string;
  claudeSessionId?: string;
  authGeneration: number;
};

type PairingCode = {
  nonceHash: string;
  expiresAt: number;
  used: boolean;
};

export type PairingPayload = {
  type: typeof PAIRING_TYPE;
  version: typeof PAIRING_VERSION;
  origin: string;
  nonce: string;
  deviceName: string;
  expiresAt: number;
};

export type PairSuccess = { token: string; deviceId: string };
export type PairFailure = { error: 'invalid_pairing_code' | 'device_limit' };

export type AuthStatus = {
  paired: boolean;
  deviceCount: number;
  hasClaudeSessionId: boolean;
};

export type AuthState = {
  createPairingPayload(publicOrigin: string, deviceName: string): PairingPayload;
  pair(nonce: string, deviceName?: string): Promise<PairSuccess | PairFailure>;
  verifyBearerToken(authHeader: string | undefined): string | null;
  verifyToken(token: string | undefined): string | null;
  /** Revokes one device, or every device when deviceId is omitted. Returns how many were revoked. */
  logout(deviceId?: string): Promise<number>;
  listDevices(): PublicDevice[];
  touchDevice(deviceId: string | null): void;
  isDeviceActive(deviceId: string | null): boolean;
  status(): AuthStatus;
  getAuthGeneration(): number;
  getClaudeSessionId(): string | undefined;
  setClaudeSessionId(sessionId: string | undefined): Promise<void>;
};

export async function createAuthState(
  statePath = join(process.cwd(), '.data', 'state.json'),
  maxDevices = DEFAULT_MAX_PAIRED_DEVICES,
): Promise<AuthState> {
  let state = await loadOrCreateState(statePath);
  let pairing: PairingCode | undefined;
  let saveQueue: Promise<void> = Promise.resolve();
  let tmpCounter = 0;

  async function save(next = state): Promise<void> {
    state = next;
    const snapshot: StoredState = {
      ...state,
      tokenHash: state.devices[0]?.tokenHash,
    };
    const write = saveQueue.catch(() => undefined).then(async () => {
      await mkdir(dirname(statePath), { recursive: true });
      const tmp = `${statePath}.${process.pid}.${tmpCounter += 1}.tmp`;
      await writeFile(tmp, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
      await rename(tmp, statePath);
    });
    saveQueue = write;
    await write;
  }

  function verifyToken(token: string | undefined): string | null {
    if (!token) return null;
    const hash = sha256(token.trim());
    for (const device of state.devices) {
      if (safeEqual(hash, device.tokenHash)) return device.id;
    }
    return null;
  }

  return {
    createPairingPayload(publicOrigin: string, deviceName: string): PairingPayload {
      const nonce = randomToken(TOKEN_BYTES);
      const expiresAt = Date.now() + PAIRING_TTL_MS;
      pairing = {
        nonceHash: sha256(nonce),
        expiresAt,
        used: false,
      };
      return {
        type: PAIRING_TYPE,
        version: PAIRING_VERSION,
        origin: publicOrigin.replace(/\/+$/, ''),
        nonce,
        deviceName,
        expiresAt,
      };
    },

    async pair(nonce: string, deviceName?: string): Promise<PairSuccess | PairFailure> {
      const clean = nonce.trim();
      if (!clean || !pairing || pairing.used || Date.now() > pairing.expiresAt) {
        return { error: 'invalid_pairing_code' };
      }
      if (!safeEqual(sha256(clean), pairing.nonceHash)) return { error: 'invalid_pairing_code' };
      if (state.devices.length >= maxDevices) return { error: 'device_limit' };

      pairing.used = true;
      const token = randomToken(TOKEN_BYTES);
      const device: StoredDevice = {
        id: freshDeviceId(state.devices),
        name: sanitizeDeviceName(deviceName),
        tokenHash: sha256(token),
        pairedAt: Date.now(),
      };
      state.devices = [...state.devices, device];
      state.authGeneration += 1;
      await save();
      return { token, deviceId: device.id };
    },

    verifyBearerToken(authHeader: string | undefined): string | null {
      if (!authHeader?.startsWith('Bearer ')) return null;
      return verifyToken(authHeader.slice('Bearer '.length));
    },

    verifyToken,

    async logout(deviceId?: string): Promise<number> {
      const before = state.devices.length;
      state.devices = deviceId
        ? state.devices.filter(device => device.id !== deviceId)
        : [];
      if (state.devices.length === before) return 0;
      state.authGeneration += 1;
      await save();
      return before - state.devices.length;
    },

    listDevices(): PublicDevice[] {
      return state.devices.map(({ id, name, pairedAt, lastSeen }) => ({ id, name, pairedAt, lastSeen }));
    },

    touchDevice(deviceId: string | null): void {
      if (!deviceId) return;
      const device = state.devices.find(entry => entry.id === deviceId);
      if (!device) return;
      const now = Date.now();
      if (device.lastSeen && now - device.lastSeen < LAST_SEEN_THROTTLE_MS) return;
      device.lastSeen = now;
      void save().catch(() => undefined);
    },

    isDeviceActive(deviceId: string | null): boolean {
      if (!deviceId) return false;
      return state.devices.some(device => device.id === deviceId);
    },

    status(): AuthStatus {
      return {
        paired: state.devices.length > 0,
        deviceCount: state.devices.length,
        hasClaudeSessionId: Boolean(state.claudeSessionId),
      };
    },

    getAuthGeneration(): number {
      return state.authGeneration;
    },

    getClaudeSessionId(): string | undefined {
      return state.claudeSessionId;
    },

    async setClaudeSessionId(sessionId: string | undefined): Promise<void> {
      state.claudeSessionId = sessionId || undefined;
      await save();
    },
  };
}

async function loadOrCreateState(statePath: string): Promise<StoredState> {
  try {
    const parsed = JSON.parse(await readFile(statePath, 'utf8')) as Partial<StoredState> & { cookieSecret?: string };
    const stateSecret = typeof parsed.stateSecret === 'string' && parsed.stateSecret.length > 0
      ? parsed.stateSecret
      : typeof parsed.cookieSecret === 'string' && parsed.cookieSecret.length > 0
        ? parsed.cookieSecret
        : undefined;
    if (stateSecret) {
      return {
        stateSecret,
        devices: parsed.devices !== undefined
          ? parsed.devices.filter(isStoredDevice)
          : migrateLegacyToken(parsed.tokenHash),
        tokenHash: typeof parsed.tokenHash === 'string' ? parsed.tokenHash : undefined,
        claudeSessionId: typeof parsed.claudeSessionId === 'string' ? parsed.claudeSessionId : undefined,
        authGeneration: typeof parsed.authGeneration === 'number' ? parsed.authGeneration : 0,
      };
    }
  } catch {
    // create a new state below
  }
  const state: StoredState = { stateSecret: randomToken(SECRET_BYTES), devices: [], authGeneration: 0 };
  await mkdir(dirname(statePath), { recursive: true });
  await writeFile(statePath, JSON.stringify(state, null, 2) + '\n', 'utf8');
  return state;
}

function migrateLegacyToken(tokenHash: unknown): StoredDevice[] {
  if (typeof tokenHash !== 'string' || tokenHash.length === 0) return [];
  return [{
    id: randomToken(DEVICE_ID_BYTES),
    name: '已配对手机',
    tokenHash,
    pairedAt: 0,
  }];
}

function isStoredDevice(value: unknown): value is StoredDevice {
  if (typeof value !== 'object' || value === null) return false;
  const device = value as StoredDevice;
  return typeof device.id === 'string' && device.id.length > 0
    && typeof device.name === 'string'
    && typeof device.tokenHash === 'string' && device.tokenHash.length > 0
    && typeof device.pairedAt === 'number';
}

function freshDeviceId(existing: StoredDevice[]): string {
  let id = randomToken(DEVICE_ID_BYTES);
  while (existing.some(device => device.id === id)) {
    id = randomToken(DEVICE_ID_BYTES);
  }
  return id;
}

function sanitizeDeviceName(name: string | undefined): string {
  const clean = (name || '')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, DEVICE_NAME_MAX_CHARS)
    .trim();
  return clean || 'Android 设备';
}

function randomToken(bytes: number): string {
  return randomBytes(bytes).toString('base64url');
}

function sha256(input: string): string {
  return createHash('sha256').update(input).digest('base64url');
}

function safeEqual(a: string, b: string): boolean {
  const aa = Buffer.from(a);
  const bb = Buffer.from(b);
  return aa.length === bb.length && timingSafeEqual(aa, bb);
}
