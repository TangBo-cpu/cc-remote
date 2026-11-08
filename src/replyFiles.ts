import { open, realpath } from 'node:fs/promises';
import { basename, extname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AttachmentStore, attachmentDescriptor, MAX_ATTACHMENT_BYTES, type AttachmentDescriptor } from './attachmentStore.js';

const deliveryTypes: Record<string, string> = {
  '.pdf': 'application/pdf',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.csv': 'text/csv', '.tsv': 'text/tab-separated-values',
  '.md': 'text/markdown', '.markdown': 'text/markdown', '.txt': 'text/plain',
  '.html': 'text/html', '.htm': 'text/html', '.svg': 'image/svg+xml',
  '.zip': 'application/zip', '.7z': 'application/x-7z-compressed',
  '.tar': 'application/x-tar', '.gz': 'application/gzip',
  '.apk': 'application/vnd.android.package-archive',
  '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.m4a': 'audio/mp4',
  '.mp4': 'video/mp4', '.webm': 'video/webm',
};
const bitmapExtension = /\.(png|jpe?g|gif|webp)$/i;

export function replyFileSources(text: string): string[] {
  let fence = '';
  const prose = text.split(/\r?\n/).filter(line => {
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = '';
      return false;
    }
    if (marker) {
      fence = marker[1];
      return false;
    }
    return true;
  }).join('\n').replace(/(`+)[^\n]*?\1/g, '');
  // shortcut: inline Markdown links only; add reference-style links when replies use them.
  const links = /!?\[[^\]\r\n]*\]\(\s*(?:<([^>\r\n]+)>|((?:\\.|[^()\s\\]|\([^()\r\n]*\))+))(?:\s+(?:"[^"\r\n]*"|'[^'\r\n]*'))?\s*\)/g;
  return [...new Set([...prose.matchAll(links)].map(match => match[1] ?? match[2])
    .filter(source => {
      if (/^(https?:|data:|\/\/|\\\\)/i.test(source)) return false;
      try {
        const path = decodeURIComponent(source.split(/[?#]/)[0]);
        return bitmapExtension.test(path) || Object.hasOwn(deliveryTypes, extname(path).toLowerCase());
      } catch {
        return false;
      }
    }))];
}

export async function collectReplyFiles(options: {
  store: AttachmentStore;
  projectId: string;
  sessionId: string;
  workspaceDir: string;
  text: string;
  existing?: AttachmentDescriptor[];
}): Promise<AttachmentDescriptor[]> {
  const files: AttachmentDescriptor[] = (options.existing ?? []).filter(file => !file.source);
  const seenPaths = new Set<string>();
  for (const source of replyFileSources(options.text)) {
    const existing = options.existing?.find(file => file.source === source);
    let path: string;
    let roots: string[];
    try {
      let local = source.replace(/\\([()\\ ])/g, '$1').split(/[?#]/)[0];
      if (local.startsWith('file:')) {
        const url = new URL(local);
        if (url.hostname && url.hostname !== 'localhost') continue;
        local = fileURLToPath(url);
      } else {
        local = decodeURIComponent(local);
        if (process.platform === 'win32') local = local.replace(/^\/([a-z]:[\\/])/i, '$1');
        if (/^[a-z][a-z\d+.-]*:/i.test(local) && !/^[a-z]:[\\/]/i.test(local)) continue;
      }
      if (/^[\\/]{2}/.test(local)) continue;
      path = await realpath(resolve(options.workspaceDir, local));
      roots = await Promise.all([
        options.workspaceDir,
        options.store.sessionDirectory(options.projectId, options.sessionId),
      ].map(root => realpath(root).catch(() => resolve(root))));
    } catch {
      if (existing && !files.some(file => file.id === existing.id)) files.push(existing);
      continue;
    }
    const key = process.platform === 'win32' ? path.toLowerCase() : path;
    if (seenPaths.has(key)) continue;
    seenPaths.add(key);
    if (existing) {
      if (!files.some(file => file.id === existing.id)) files.push(existing);
      continue;
    }
    const inside = (root: string) => {
      const child = relative(root, path);
      return child !== '' && child !== '..' && !child.startsWith('..' + sep) && !isAbsolute(child);
    };
    const uploadRoot = await realpath(options.store.rootDir).catch(() => resolve(options.store.rootDir));
    if (!roots.some(inside) || (inside(uploadRoot) && !inside(roots[1]))) continue;

    const file = await open(path, 'r').catch(() => undefined);
    if (!file) continue;
    try {
      const stat = await file.stat();
      if (!stat.isFile() || stat.size === 0 || stat.size > MAX_ATTACHMENT_BYTES) continue;
      const header = Buffer.alloc(12);
      await file.read(header, 0, header.length, 0);
      const mimeType = bitmapExtension.test(path)
        ? imageMimeType(header)
        : deliveryTypes[extname(path).toLowerCase()];
      if (!mimeType) continue;
      const saved = await options.store.save({
        projectId: options.projectId,
        sessionId: options.sessionId,
        name: basename(path),
        mimeType,
        input: file.createReadStream({ start: 0, autoClose: false }),
      });
      files.push({ ...attachmentDescriptor(saved), source });
    } catch {
      // A file removed or changed during collection must not hide other deliveries.
      continue;
    } finally {
      await file.close();
    }
  }
  return files;
}

function imageMimeType(header: Buffer): string | undefined {
  if (header.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return 'image/png';
  if (header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff) return 'image/jpeg';
  if (/^GIF8[79]a$/.test(header.toString('ascii', 0, 6))) return 'image/gif';
  if (header.toString('ascii', 0, 4) === 'RIFF' && header.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  return undefined;
}
