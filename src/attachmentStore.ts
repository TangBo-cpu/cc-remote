import { randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, type ReadStream } from 'node:fs';
import { access, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, extname, join, resolve, sep } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Transform, type Readable } from 'node:stream';

export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;
export const MAX_ATTACHMENTS_PER_PROMPT = 5;

export type AttachmentDescriptor = {
  id: string;
  name: string;
  mimeType: string;
  size: number;
};

export type StoredAttachment = AttachmentDescriptor & {
  projectId: string;
  sessionId: string;
  path: string;
  createdAt: number;
};

type StoredAttachmentMetadata = AttachmentDescriptor & {
  version: 1;
  projectId: string;
  sessionId: string;
  storedName: string;
  createdAt: number;
};

export class AttachmentStore {
  constructor(private readonly rootDir = join(process.cwd(), '.data', 'uploads')) {}

  async save(options: {
    projectId: string;
    sessionId: string;
    name: string;
    mimeType?: string;
    input: Readable;
  }): Promise<StoredAttachment> {
    const projectId = safeId(options.projectId);
    const sessionId = safeId(options.sessionId);
    const name = sanitizeFileName(options.name);
    const mimeType = sanitizeMimeType(options.mimeType);
    const id = randomUUID();
    const directory = this.sessionDirectory(projectId, sessionId);
    const storedName = `${id}${extname(name).toLowerCase()}`;
    const targetPath = join(directory, storedName);
    const tempPath = `${targetPath}.${process.pid}.tmp`;
    let size = 0;
    const limiter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        size += chunk.length;
        if (size > MAX_ATTACHMENT_BYTES) {
          callback(new Error('attachment_too_large'));
          return;
        }
        callback(null, chunk);
      },
    });

    await mkdir(directory, { recursive: true });
    try {
      await pipeline(options.input, limiter, createWriteStream(tempPath, { flags: 'wx' }));
      if (size === 0) throw new Error('attachment_empty');
      await rename(tempPath, targetPath);
      const metadata: StoredAttachmentMetadata = {
        version: 1,
        id,
        projectId,
        sessionId,
        name,
        mimeType,
        size,
        storedName,
        createdAt: Date.now(),
      };
      await writeMetadata(this.metadataPath(projectId, sessionId, id), metadata);
      return materialize(directory, metadata);
    } catch (error) {
      await rm(tempPath, { force: true }).catch(() => undefined);
      await rm(targetPath, { force: true }).catch(() => undefined);
      throw error;
    }
  }

  async resolve(
    projectId: string,
    sessionId: string,
    attachmentId: string,
  ): Promise<StoredAttachment | undefined> {
    const safeProjectId = safeId(projectId);
    const safeSessionId = safeId(sessionId);
    const safeAttachmentId = safeId(attachmentId);
    const directory = this.sessionDirectory(safeProjectId, safeSessionId);
    try {
      const parsed = JSON.parse(
        await readFile(this.metadataPath(safeProjectId, safeSessionId, safeAttachmentId), 'utf8'),
      ) as unknown;
      if (!isMetadata(parsed)
        || parsed.projectId !== safeProjectId
        || parsed.sessionId !== safeSessionId
        || parsed.id !== safeAttachmentId) {
        return undefined;
      }
      const attachment = materialize(directory, parsed);
      await access(attachment.path);
      return attachment;
    } catch {
      return undefined;
    }
  }

  async resolveMany(
    projectId: string,
    sessionId: string,
    attachmentIds: string[],
  ): Promise<StoredAttachment[]> {
    const uniqueIds = [...new Set(attachmentIds)];
    if (uniqueIds.length > MAX_ATTACHMENTS_PER_PROMPT) throw new Error('too_many_attachments');
    const attachments = await Promise.all(
      uniqueIds.map(id => this.resolve(projectId, sessionId, id)),
    );
    if (attachments.some(attachment => !attachment)) throw new Error('attachment_not_found');
    return attachments as StoredAttachment[];
  }

  open(attachment: StoredAttachment): ReadStream {
    return createReadStream(attachment.path);
  }

  async remove(attachment: StoredAttachment): Promise<void> {
    const projectId = safeId(attachment.projectId);
    const sessionId = safeId(attachment.sessionId);
    const attachmentId = safeId(attachment.id);
    const directory = this.sessionDirectory(projectId, sessionId);
    const storedPath = resolve(attachment.path);
    if (!storedPath.startsWith(directory + sep)) throw new Error('invalid_attachment_path');
    await Promise.all([
      rm(storedPath, { force: true }),
      rm(this.metadataPath(projectId, sessionId, attachmentId), { force: true }),
    ]);
  }

  async removeMany(storedAttachments: StoredAttachment[]): Promise<void> {
    await Promise.all(
      storedAttachments.map(attachment => this.remove(attachment).catch(() => undefined)),
    );
  }

  sessionDirectory(projectId: string, sessionId: string): string {
    const directory = resolve(this.rootDir, safeId(projectId), safeId(sessionId));
    const root = resolve(this.rootDir);
    if (directory !== root && !directory.startsWith(root + sep)) throw new Error('invalid_attachment_path');
    return directory;
  }

  async ensureSessionDirectory(projectId: string, sessionId: string): Promise<string> {
    const directory = this.sessionDirectory(projectId, sessionId);
    await mkdir(directory, { recursive: true });
    return directory;
  }

  async removeSessionDirectory(projectId: string, sessionId: string): Promise<void> {
    const directory = this.sessionDirectory(projectId, sessionId);
    await rm(directory, { recursive: true, force: true }).catch(() => undefined);
  }

  private metadataPath(projectId: string, sessionId: string, attachmentId: string): string {
    return join(this.sessionDirectory(projectId, sessionId), `${safeId(attachmentId)}.json`);
  }
}

export function attachmentDescriptor(attachment: StoredAttachment): AttachmentDescriptor {
  return {
    id: attachment.id,
    name: attachment.name,
    mimeType: attachment.mimeType,
    size: attachment.size,
  };
}

export function promptWithAttachments(prompt: string, attachments: StoredAttachment[]): string {
  if (attachments.length === 0) return prompt;
  const request = prompt.trim() || '请查看附件并根据内容处理。';
  const files = attachments
    .map(attachment => `- ${attachment.name}: ${attachment.path}`)
    .join('\n');
  return `${request}\n\n以下附件由用户通过 CC Remote 上传。请先读取需要的文件。\n${files}`;
}

function sanitizeFileName(value: string): string {
  const name = basename(value.replace(/\\/g, '/'))
    .replace(/[\u0000-\u001f<>:"/\\|?*]+/g, '_')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 120);
  return name && name !== '.' && name !== '..' ? name : 'attachment.bin';
}

function sanitizeMimeType(value: string | undefined): string {
  const mimeType = value?.split(';')[0].trim().toLowerCase() || '';
  return /^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/.test(mimeType)
    ? mimeType
    : 'application/octet-stream';
}

function safeId(value: string): string {
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(value)) throw new Error('invalid_attachment_id');
  return value;
}

function materialize(directory: string, metadata: StoredAttachmentMetadata): StoredAttachment {
  return {
    id: metadata.id,
    projectId: metadata.projectId,
    sessionId: metadata.sessionId,
    name: metadata.name,
    mimeType: metadata.mimeType,
    size: metadata.size,
    path: join(directory, metadata.storedName),
    createdAt: metadata.createdAt,
  };
}

async function writeMetadata(path: string, metadata: StoredAttachmentMetadata): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temp = `${path}.${process.pid}.tmp`;
  try {
    await writeFile(temp, JSON.stringify(metadata, null, 2) + '\n', 'utf8');
    await rename(temp, path);
  } catch (error) {
    await rm(temp, { force: true }).catch(() => undefined);
    throw error;
  }
}

function isMetadata(value: unknown): value is StoredAttachmentMetadata {
  if (!isRecord(value)) return false;
  return value.version === 1
    && typeof value.id === 'string'
    && typeof value.projectId === 'string'
    && typeof value.sessionId === 'string'
    && typeof value.name === 'string'
    && typeof value.mimeType === 'string'
    && typeof value.size === 'number'
    && typeof value.storedName === 'string'
    && typeof value.createdAt === 'number';
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
