import { open, realpath } from 'node:fs/promises';
import { basename, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AttachmentStore, attachmentDescriptor, MAX_ATTACHMENT_BYTES, type AttachmentDescriptor } from './attachmentStore.js';

export function replyImageSources(text: string): string[] {
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
    .filter(source => /\.(png|jpe?g|gif|webp)(?:[?#].*)?$/i.test(source)
      && !/^(https?:|data:|\/\/|\\\\)/i.test(source)))];
}

export async function collectReplyImages(options: {
  store: AttachmentStore;
  projectId: string;
  sessionId: string;
  workspaceDir: string;
  text: string;
  existing?: AttachmentDescriptor[];
}): Promise<AttachmentDescriptor[]> {
  const images: AttachmentDescriptor[] = (options.existing ?? []).filter(image => !image.source);
  for (const source of replyImageSources(options.text)) {
    const existing = options.existing?.find(image => image.source === source);
    if (existing) {
      images.push(existing);
      continue;
    }
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
      const mimeType = imageMimeType(header);
      if (!mimeType) continue;
      const saved = await options.store.save({
        projectId: options.projectId,
        sessionId: options.sessionId,
        name: basename(path),
        mimeType,
        input: file.createReadStream({ start: 0, autoClose: false }),
      });
      images.push({ ...attachmentDescriptor(saved), source });
    } finally {
      await file.close();
    }
  }
  return images;
}

function imageMimeType(header: Buffer): string | undefined {
  if (header.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return 'image/png';
  if (header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff) return 'image/jpeg';
  if (/^GIF8[79]a$/.test(header.toString('ascii', 0, 6))) return 'image/gif';
  if (header.toString('ascii', 0, 4) === 'RIFF' && header.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  return undefined;
}
