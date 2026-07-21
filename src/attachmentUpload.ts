import type { IncomingMessage } from 'node:http';
import type { Readable } from 'node:stream';
import Busboy from 'busboy';
import {
  AttachmentStore,
  MAX_ATTACHMENT_BYTES,
  MAX_ATTACHMENTS_PER_PROMPT,
  type StoredAttachment,
} from './attachmentStore.js';

export type AttachmentUploadContext = {
  projectId: string;
  sessionId: string;
};

type AttachmentWrite =
  | { attachment: StoredAttachment; error?: undefined }
  | { attachment?: undefined; error: Error };

export function readAttachments(
  req: IncomingMessage,
  context: AttachmentUploadContext,
  attachments: AttachmentStore,
): Promise<StoredAttachment[]> {
  return new Promise((resolve, reject) => {
    let parser: ReturnType<typeof Busboy>;
    try {
      parser = Busboy({
        headers: req.headers,
        limits: {
          files: MAX_ATTACHMENTS_PER_PROMPT,
          fileSize: MAX_ATTACHMENT_BYTES,
          fields: 0,
          parts: MAX_ATTACHMENTS_PER_PROMPT,
        },
      });
    } catch {
      reject(new Error('invalid_multipart'));
      return;
    }

    const writes: Promise<AttachmentWrite>[] = [];
    const openFiles = new Set<Readable>();
    let batchError: Error | undefined;
    let finalizing = false;
    const rememberError = (error: unknown) => {
      batchError ??= error instanceof Error ? error : new Error(String(error));
    };
    const finalize = async () => {
      if (finalizing) return;
      finalizing = true;
      const outcomes = await Promise.all(writes);
      const saved = outcomes
        .map(outcome => outcome.attachment)
        .filter((attachment): attachment is StoredAttachment => Boolean(attachment));
      const writeError = outcomes.find(outcome => outcome.error)?.error;
      const error = batchError ?? writeError;
      if (error || saved.length === 0) {
        await attachments.removeMany(saved);
        reject(error ?? new Error('attachment_required'));
        return;
      }
      resolve(saved);
    };

    parser.on('file', (fieldName, file, info) => {
      if (fieldName !== 'files') {
        file.resume();
        return;
      }
      openFiles.add(file);
      file.once('close', () => openFiles.delete(file));
      file.once('limit', () => rememberError(new Error('attachment_too_large')));
      writes.push(
        attachments.save({
          projectId: context.projectId,
          sessionId: context.sessionId,
          name: info.filename,
          mimeType: info.mimeType,
          input: file,
        }).then<AttachmentWrite, AttachmentWrite>(
          attachment => ({ attachment }),
          error => ({ error: error instanceof Error ? error : new Error(String(error)) }),
        ),
      );
    });
    parser.on('filesLimit', () => rememberError(new Error('too_many_attachments')));
    parser.on('partsLimit', () => rememberError(new Error('too_many_attachments')));
    parser.on('fieldsLimit', () => rememberError(new Error('invalid_multipart')));
    parser.on('error', error => {
      rememberError(error);
      for (const file of openFiles) file.destroy(batchError);
      void finalize();
    });
    parser.on('finish', () => void finalize());
    req.once('aborted', () => {
      const error = new Error('upload_aborted');
      rememberError(error);
      for (const file of openFiles) file.destroy(error);
      if (!parser.destroyed) parser.destroy(error);
      void finalize();
    });
    req.pipe(parser);
  });
}
