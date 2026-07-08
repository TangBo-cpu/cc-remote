import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { dirname, join } from 'node:path';

const TOKEN_BYTES = 32;
const SECRET_BYTES = 32;
const PAIRING_TTL_MS = 5 * 60 * 1000;

const PAIRING_TYPE = 'cc-remote-pair' as const;
const PAIRING_VERSION = 1 as const;

type StoredState = {
  stateSecret: string;
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

export type AuthStatus = {
  paired: boolean;
  hasClaudeSessionId: boolean;
};

export type AuthState = {
  createPairingPayload(publicOrigin: string, deviceName: string): PairingPayload;
  pair(nonce: string): Promise<string | null>;
  verifyBearerToken(authHeader: string | undefined): boolean;
  verifyToken(token: string | undefined): boolean;
  logout(): Promise<void>;
  status(): AuthStatus;
  getAuthGeneration(): number;
  getClaudeSessionId(): string | undefined;
  setClaudeSessionId(sessionId: string | undefined): Promise<void>;
};

export async function createAuthState(statePath = join(process.cwd(), '.data', 'state.json')): Promise<AuthState> {
  let state = await loadOrCreateState(statePath);
  let pairing: PairingCode | undefined;
  let saveQueue: Promise<void> = Promise.resolve();
  let tmpCounter = 0;

  async function save(next = state): Promise<void> {
    state = next;
    const snapshot = { ...state };
    const write = saveQueue.catch(() => undefined).then(async () => {
      await mkdir(dirname(statePath), { recursive: true });
      const tmp = `${statePath}.${process.pid}.${tmpCounter += 1}.tmp`;
      await writeFile(tmp, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
      await rename(tmp, statePath);
    });
    saveQueue = write;
    await write;
  }

  function verifyToken(token: string | undefined): boolean {
    if (!state.tokenHash || !token) return false;
    return safeEqual(sha256(token.trim()), state.tokenHash);
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

    async pair(nonce: string): Promise<string | null> {
      const clean = nonce.trim();
      if (!clean || !pairing || pairing.used || Date.now() > pairing.expiresAt) return null;
      if (!safeEqual(sha256(clean), pairing.nonceHash)) return null;

      pairing.used = true;
      const token = randomToken(TOKEN_BYTES);
      state.tokenHash = sha256(token);
      state.authGeneration += 1;
      await save();
      return token;
    },

    verifyBearerToken(authHeader: string | undefined): boolean {
      if (!authHeader?.startsWith('Bearer ')) return false;
      return verifyToken(authHeader.slice('Bearer '.length));
    },

    verifyToken,

    async logout(): Promise<void> {
      state.tokenHash = undefined;
      state.authGeneration += 1;
      await save();
    },

    status(): AuthStatus {
      return {
        paired: Boolean(state.tokenHash),
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
        tokenHash: typeof parsed.tokenHash === 'string' ? parsed.tokenHash : undefined,
        claudeSessionId: typeof parsed.claudeSessionId === 'string' ? parsed.claudeSessionId : undefined,
        authGeneration: typeof parsed.authGeneration === 'number' ? parsed.authGeneration : 0,
      };
    }
  } catch {
    // create a new state below
  }
  const state: StoredState = { stateSecret: randomToken(SECRET_BYTES), authGeneration: 0 };
  await mkdir(dirname(statePath), { recursive: true });
  await writeFile(statePath, JSON.stringify(state, null, 2) + '\n', 'utf8');
  return state;
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
