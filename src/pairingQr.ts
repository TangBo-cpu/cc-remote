import { createRequire } from 'node:module';
import type { PairingPayload } from './authState.js';

// shortcut: use qrcode-terminal's bundled encoder; review this path when upgrading it.
const QrCode = createRequire(import.meta.url)('qrcode-terminal/vendor/QRCode') as new (
  version: number, level: number,
) => {
  addData(text: string): void;
  make(): void;
  getModuleCount(): number;
  isDark(row: number, column: number): boolean;
};

export function createPairingQr(payload: PairingPayload): { payload: PairingPayload; modules: boolean[][] } {
  const qr = new QrCode(-1, 1);
  const text = JSON.stringify(payload).replace(/[^\x00-\x7f]/g,
    character => `\\u${character.charCodeAt(0).toString(16).padStart(4, '0')}`);
  qr.addData(text);
  qr.make();
  const size = qr.getModuleCount();
  return { payload, modules: Array.from({ length: size }, (_, row) =>
    Array.from({ length: size }, (_, column) => qr.isDark(row, column))) };
}
