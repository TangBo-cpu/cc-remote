import { randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

export type LocalControlState = {
  token: string;
  verify(value: string | undefined): boolean;
};

export async function createLocalControlState(
  statePath = join(process.cwd(), '.data', 'local-control.json'),
): Promise<LocalControlState> {
  let token: string | undefined;
  try {
    const parsed = JSON.parse(await readFile(statePath, 'utf8')) as { token?: unknown };
    if (typeof parsed.token === 'string' && parsed.token.length >= 32) token = parsed.token;
  } catch {
    // Create the local-only control token below.
  }
  if (!token) {
    token = randomBytes(32).toString('base64url');
    await mkdir(dirname(statePath), { recursive: true });
    await writeFile(statePath, JSON.stringify({ token }, null, 2) + '\n', 'utf8');
  }
  const current = token;
  return {
    token: current,
    verify(value: string | undefined): boolean {
      if (!value) return false;
      const a = Buffer.from(value);
      const b = Buffer.from(current);
      return a.length === b.length && timingSafeEqual(a, b);
    },
  };
}
