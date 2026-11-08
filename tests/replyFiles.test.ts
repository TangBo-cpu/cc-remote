import assert from 'node:assert/strict';
import { mkdtemp, mkdir, open, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { AttachmentStore, MAX_ATTACHMENT_BYTES } from '../src/attachmentStore.js';
import { collectReplyFiles, replyFileSources } from '../src/replyFiles.js';
import { createTranscriptState } from '../src/transcriptState.js';

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jvGQAAAAASUVORK5CYII=', 'base64');

test('finds local deliveries while ignoring examples, web links, and code files', () => {
  assert.deepEqual(replyFileSources([
    '![图](./output.png)',
    '[截图](</E:/project/截图 1.png>)',
    '![same](./output.png)',
    '![括号](output(1).jpg "title")',
    '![文件](file:///E:/project/test.gif)',
    '![remote](https://example.test/image.png)',
    '![network](//host/image.png)',
    '[doc](report.pdf)',
    '[sheet](report.xlsx)',
    '[code](src/main.ts)',
    '`![inline example](example.png)`',
    '```markdown\n![example](hidden.webp)\n```',
    '~~~markdown\n![example](also-hidden.png)\n~~~~',
    '```markdown\n![unfinished example](unfinished.png)',
  ].join('\n')), [
    './output.png', '/E:/project/截图 1.png', 'output(1).jpg', 'file:///E:/project/test.gif',
    'report.pdf', 'report.xlsx',
  ]);
});

test('copies a referenced image into its session, keeps its original text, and reuses persisted metadata', async () => {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-reply-image-'));
  try {
    const workspaceDir = join(root, 'workspace');
    await mkdir(workspaceDir);
    const source = join(workspaceDir, '截图 (1).png');
    await writeFile(source, png);
    const store = new AttachmentStore(join(root, 'uploads'));
    const text = `结果如下：\n\n![截图](<${pathToFileURL(source)}>)`;
    const options = { store, workspaceDir, projectId: 'project', sessionId: 'session', text };
    const images = await collectReplyFiles(options);
    assert.equal(images.length, 1);
    assert.equal(images[0].mimeType, 'image/png');
    assert.equal(images[0].name, '截图 (1).png');
    const saved = await store.resolve('project', 'session', images[0].id);
    assert.ok(saved);
    assert.deepEqual(await readFile(saved.path), png);
    assert.equal(await store.resolve('project', 'other', images[0].id), undefined);
    await rm(source);

    const statePath = join(root, 'transcript.json');
    const transcript = await createTranscriptState(statePath);
    transcript.beginPrompt('生成图片', 'manual');
    transcript.appendText(text);
    assert.equal(transcript.setAssistantAttachments(1, images), true);
    assert.equal(transcript.setAssistantAttachments(1, images), false);
    await transcript.finishDone();
    const restored = await createTranscriptState(statePath);
    assert.equal(restored.snapshot().messages[1].text, text);
    assert.deepEqual(restored.snapshot().messages[1].attachments, images);
    assert.deepEqual(await collectReplyFiles({ ...options, existing: images }), images);
    assert.equal((await readdir(store.sessionDirectory('project', 'session'))).length, 2);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('rejects files outside the workspace, escaped symlinks, fake images, and oversized images', async () => {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-reply-image-boundary-'));
  try {
    const workspaceDir = join(root, 'workspace');
    const outside = join(root, 'outside');
    await mkdir(workspaceDir);
    await mkdir(outside);
    await writeFile(join(outside, 'private.png'), png);
    await symlink(outside, join(workspaceDir, 'escape'), process.platform === 'win32' ? 'junction' : 'dir');
    await writeFile(join(workspaceDir, 'fake.png'), 'secret text is not an image');
    const large = await open(join(workspaceDir, 'large.png'), 'w');
    await large.truncate(MAX_ATTACHMENT_BYTES + 1);
    await large.close();
    const store = new AttachmentStore(join(workspaceDir, '.uploads'));
    const otherDirectory = await store.ensureSessionDirectory('project', 'other-session');
    await writeFile(join(otherDirectory, 'private.png'), png);
    const images = await collectReplyFiles({
      store, workspaceDir, projectId: 'project', sessionId: 'session',
      text: [
        '![outside](../outside/private.png)',
        '![symlink](escape/private.png)',
        '![fake](fake.png)',
        '![large](large.png)',
        '![missing](missing.png)',
        '![encoded network](%5C%5Cinvalid.example%5Cprivate.png)',
        `![other session](<${join(otherDirectory, 'private.png')}>)`,
      ].join('\n'),
    });
    assert.deepEqual(images, []);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('imports Windows local links and URL-encoded paths without fetching remote images', async () => {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-reply-image-path-'));
  try {
    const workspaceDir = join(root, 'workspace');
    await mkdir(workspaceDir);
    const file = join(workspaceDir, 'image 1.png');
    await writeFile(file, png);
    const source = process.platform === 'win32' ? '/' + file.replaceAll('\\', '/') : file;
    const images = await collectReplyFiles({
      store: new AttachmentStore(join(root, 'uploads')),
      workspaceDir, projectId: 'project', sessionId: 'session',
      text: `[截图](${source.replaceAll(' ', '%20')})\n![remote](https://example.test/remote.png)`,
    });
    assert.equal(images.length, 1);
    assert.equal(images[0].size, png.length);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('delivers documents with session isolation, deduplicates aliases and preserves snapshots', async () => {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-delivery-'));
  try {
    const workspaceDir = join(root, 'workspace');
    await mkdir(workspaceDir);
    const store = new AttachmentStore(join(workspaceDir, '.uploads'));
    const types = {
      'report.pdf': 'application/pdf',
      'report.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'report.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'report.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'report.md': 'text/markdown',
      'data.csv': 'text/csv',
    };
    for (const name of Object.keys(types)) await writeFile(join(workspaceDir, name), `content of ${name}`);
    await writeFile(join(root, 'private.pdf'), 'private');
    const other = await store.ensureSessionDirectory('project', 'other');
    await writeFile(join(other, 'private.pdf'), 'private');
    const large = await open(join(workspaceDir, 'large.pdf'), 'w');
    await large.truncate(MAX_ATTACHMENT_BYTES + 1);
    await large.close();
    const options = {
      store, workspaceDir, projectId: 'project', sessionId: 'session',
      text: [
        ...Object.keys(types).map(name => `[file](${name})`),
        '[duplicate](./report.pdf)',
        '[outside](../private.pdf)',
        '[other](.uploads/project/other/private.pdf)',
        '[large](large.pdf)',
        '[remote](https://example.test/report.pdf)',
      ].join('\n'),
    };
    const files = await collectReplyFiles(options);
    assert.equal(files.length, Object.keys(types).length);
    for (const file of files) {
      assert.equal(file.mimeType, types[file.name as keyof typeof types]);
      const saved = await store.resolve('project', 'session', file.id);
      assert.ok(saved);
      assert.equal(await readFile(saved.path, 'utf8'), `content of ${file.name}`);
      assert.equal(await store.resolve('project', 'other', file.id), undefined);
    }
    assert.deepEqual(await collectReplyFiles({ ...options, existing: files }), files);
    await rm(join(workspaceDir, 'report.pdf'));
    assert.deepEqual(await collectReplyFiles({ ...options, existing: files }), files);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
