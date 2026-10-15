import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, parse } from 'node:path';
import test from 'node:test';
import { browseDirectories, canonicalDirectory, DirectoryError } from '../src/directoryService.js';
import { createProjectSessionState } from '../src/projectSessionState.js';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'cc-remote-directory-'));
  return { root, clean: () => rm(root, { recursive: true, force: true, maxRetries: 3 }) };
}

test('directory browser lists immediate folders with natural sorting and canonical parents', async () => {
  const { root, clean } = await fixture();
  try {
    await Promise.all(['folder10', 'folder2', '中文 app'].map(name => mkdir(join(root, name))));
    await writeFile(join(root, 'file.txt'), 'not a directory');
    await mkdir(join(root, 'folder2', 'nested'));
    const listing = await browseDirectories(root);
    assert.equal(listing.path, await realpath(root));
    assert.equal(listing.parentPath, dirname(await realpath(root)));
    const names = listing.directories.map(entry => entry.name);
    assert.equal(names.length, 3);
    assert.ok(names.includes('中文 app'));
    assert.ok(names.indexOf('folder2') < names.indexOf('folder10'));
    assert.equal(listing.truncated, false);
    assert.equal((await browseDirectories(parse(root).root)).parentPath, null);
  } finally { await clean(); }
});

test('directory browser exposes roots and rejects invalid, missing and file paths', async () => {
  const { root, clean } = await fixture();
  try {
    const roots = await browseDirectories();
    assert.equal(roots.path, null);
    assert.ok(roots.roots.length > 0);
    await writeFile(join(root, 'file.txt'), 'file');
    for (const [path, code] of [
      ['', 'directory_path_invalid'], ['relative/path', 'directory_path_invalid'],
      [null, 'directory_path_invalid'], [root + '\0', 'directory_path_invalid'],
      [join(root, 'missing'), 'directory_not_found'], [join(root, 'file.txt'), 'directory_not_directory'],
    ]) {
      await assert.rejects(canonicalDirectory(path), error => error instanceof DirectoryError && error.code === code);
    }
  } finally { await clean(); }
});

test('large directories bound their listing without recursive traversal', async () => {
  const { root, clean } = await fixture();
  try {
    await Promise.all(Array.from({ length: 502 }, (_, index) => mkdir(join(root, `folder${index}`))));
    const listing = await browseDirectories(root);
    assert.equal(listing.directories.length, 500);
    assert.equal(listing.truncated, true);
  } finally { await clean(); }
});

test('opening host directories creates one session per request and retains old history after restart', async () => {
  const { root, clean } = await fixture();
  try {
    const first = join(root, 'first');
    const second = join(root, '中文 app');
    await mkdir(first);
    await mkdir(second);
    const options = { dataDir: join(root, 'data'), initialWorkspace: first };
    const state = await createProjectSessionState(options);
    const original = state.active();
    original.transcript.beginPrompt('keep original history', 'manual');
    await original.transcript.finishDone();
    const codex = await state.createSessionAtDirectory(second, 'codex');
    assert.equal(codex.project.path, await realpath(second));
    assert.equal(codex.session.engine, 'codex');
    assert.equal(state.catalog().sessions.length, 2);
    assert.equal(state.catalog().projects.length, 2);
    const claude = await state.createSessionAtDirectory(second, 'claude');
    assert.equal(claude.project.id, codex.project.id);
    assert.equal(claude.session.engine, 'claude');
    assert.equal(state.catalog().sessions.length, 3);
    await state.flush();
    const restored = await createProjectSessionState(options);
    assert.equal(restored.active().session.id, claude.session.id);
    await restored.selectSession(original.session.id);
    assert.equal(restored.active().project.path, first);
    assert.equal(restored.active().transcript.snapshot().messages[0].text, 'keep original history');
  } finally { await clean(); }
});

test('directory aliases reuse a project without changing the existing conversation', async () => {
  const { root, clean } = await fixture();
  try {
    const target = join(root, 'target');
    const alias = join(root, 'alias');
    await mkdir(target);
    await symlink(target, alias, process.platform === 'win32' ? 'junction' : 'dir');
    const state = await createProjectSessionState({ dataDir: join(root, 'data'), initialWorkspace: alias });
    const old = state.active();
    const next = await state.createSessionAtDirectory(target, 'codex');
    assert.equal(next.project.id, old.project.id);
    assert.equal(state.catalog().projects.length, 1);
    assert.notEqual(next.session.id, old.session.id);
  } finally { await clean(); }
});

test('invalid directories and catalog write failures preserve the active session', async () => {
  const { root, clean } = await fixture();
  try {
    const dataDir = join(root, 'data');
    const target = join(root, 'target');
    await mkdir(target);
    const state = await createProjectSessionState({ dataDir, initialWorkspace: root });
    const before = state.catalog();
    await assert.rejects(state.createSessionAtDirectory(join(root, 'missing'), 'codex'));
    assert.deepEqual(state.catalog(), before);
    const catalogPath = join(dataDir, 'projects.json');
    const saved = await readFile(catalogPath, 'utf8');
    await rename(catalogPath, catalogPath + '.saved');
    await mkdir(catalogPath);
    await assert.rejects(state.createSessionAtDirectory(target, 'codex'));
    assert.deepEqual(state.catalog(), before);
    await rm(catalogPath, { recursive: true });
    await rename(catalogPath + '.saved', catalogPath);
    assert.equal(await readFile(catalogPath, 'utf8'), saved);
    await state.flush();
  } finally { await clean(); }
});
