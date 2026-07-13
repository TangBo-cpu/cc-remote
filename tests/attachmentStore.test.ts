import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import test from 'node:test';
import {
  AttachmentStore,
  MAX_ATTACHMENT_BYTES,
  attachmentDescriptor,
  promptWithAttachments,
} from '../src/attachmentStore.js';

test('stores attachments outside the project and resolves them by session ownership', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-attachments-'));
  try {
    const store = new AttachmentStore(dir);
    const saved = await store.save({
      projectId: 'project-1',
      sessionId: 'session-1',
      name: '../screen shot.png',
      mimeType: 'image/png',
      input: Readable.from(Buffer.from('png-data')),
    });

    assert.equal(saved.name, 'screen shot.png');
    assert.equal(saved.size, 8);
    assert.equal(await readFile(saved.path, 'utf8'), 'png-data');
    assert.deepEqual(attachmentDescriptor(saved), {
      id: saved.id,
      name: 'screen shot.png',
      mimeType: 'image/png',
      size: 8,
    });
    assert.equal((await store.resolve('project-1', 'session-1', saved.id))?.path, saved.path);
    assert.equal(await store.resolve('project-1', 'session-2', saved.id), undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('rejects oversized attachments and removes partial files', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-attachments-limit-'));
  try {
    const store = new AttachmentStore(dir);
    await assert.rejects(() => store.save({
      projectId: 'project-1',
      sessionId: 'session-1',
      name: 'large.bin',
      input: Readable.from(Buffer.alloc(MAX_ATTACHMENT_BYTES + 1)),
    }), /attachment_too_large/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('builds a Claude prompt from trusted stored attachment paths', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-attachments-prompt-'));
  try {
    const store = new AttachmentStore(dir);
    const saved = await store.save({
      projectId: 'project-1',
      sessionId: 'session-1',
      name: 'error.log',
      mimeType: 'text/plain',
      input: Readable.from('failure'),
    });
    const prompt = promptWithAttachments('分析这个错误', [saved]);

    assert.match(prompt, /分析这个错误/);
    assert.match(prompt, /error\.log/);
    assert.match(prompt, new RegExp(saved.path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
