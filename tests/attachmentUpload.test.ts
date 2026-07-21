import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { AttachmentStore, MAX_ATTACHMENT_BYTES } from '../src/attachmentStore.js';
import { readAttachments } from '../src/attachmentUpload.js';

test('oversized multipart upload returns an error without leaving sibling files', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-attachment-upload-'));
  const store = new AttachmentStore(dir);
  const server = createServer(async (req, res) => {
    try {
      await readAttachments(req, { projectId: 'project-1', sessionId: 'session-1' }, store);
      res.writeHead(201).end();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      res.writeHead(message === 'attachment_too_large' ? 413 : 400).end(message);
    }
  });

  try {
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const address = server.address();
    assert(address && typeof address === 'object');
    const form = new FormData();
    form.append('files', new Blob(['ok']), 'ok.txt');
    form.append(
      'files',
      new Blob([new Uint8Array(MAX_ATTACHMENT_BYTES + 1)]),
      'too-big.bin',
    );

    const response = await fetch(
      `http://127.0.0.1:${address.port}/attachments`,
      { method: 'POST', body: form },
    );

    assert.equal(response.status, 413);
    assert.equal(await response.text(), 'attachment_too_large');
    assert.deepEqual(await readdir(join(dir, 'project-1', 'session-1')), []);
  } finally {
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});
