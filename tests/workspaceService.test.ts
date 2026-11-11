import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';
import { normalizeRelative, parseGitStatus, WorkspaceService } from '../src/workspaceService.js';

const execFileAsync = promisify(execFile);

test('parses staged, unstaged, untracked, and renamed git entries', () => {
  const changes = parseGitStatus([
    ' M src/app.ts',
    'A  src/new.ts',
    '?? notes.txt',
    'R  src/after.ts',
    'src/before.ts',
    '',
  ].join('\0'));

  assert.deepEqual(changes, [
    { path: 'notes.txt', unstaged: '?' },
    { path: 'src/after.ts', previousPath: 'src/before.ts', staged: 'R' },
    { path: 'src/app.ts', unstaged: 'M' },
    { path: 'src/new.ts', staged: 'A' },
  ]);
});

test('workspace paths reject traversal and absolute paths', () => {
  assert.equal(normalizeRelative('src\\app.ts'), 'src/app.ts');
  assert.throws(() => normalizeRelative('../secret.txt'), /invalid_path/);
  assert.throws(() => normalizeRelative('src/../../secret.txt'), /invalid_path/);
  assert.throws(() => normalizeRelative('C:\\secret.txt'), /invalid_path/);
  assert.throws(() => normalizeRelative(''), /invalid_path/);
});

test('change fingerprints stay stable until file contents change', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-workspace-'));
  try {
    await execFileAsync('git', ['-C', dir, 'init', '-q']);
    await mkdir(join(dir, 'notes'));
    await writeFile(join(dir, 'notes', 'draft.txt'), 'first');
    const workspace = new WorkspaceService(dir);
    const first = (await workspace.snapshot()).changes;
    assert.equal(first[0]?.path, 'notes/draft.txt');
    assert.ok(first[0]?.fingerprint);
    assert.deepEqual((await workspace.snapshot()).changes, first);

    await writeFile(join(dir, 'notes', 'draft.txt'), 'other');
    const next = (await workspace.snapshot()).changes;
    assert.equal(next[0]?.unstaged, first[0]?.unstaged);
    assert.notEqual(next[0]?.fingerprint, first[0]?.fingerprint);

    await writeFile(join(dir, 'notes', 'draft.txt'), 'other');
    assert.deepEqual((await workspace.snapshot()).changes, next);

    await execFileAsync('git', ['-C', dir, 'add', '--', 'notes/draft.txt']);
    assert.equal((await workspace.snapshot()).changes[0]?.fingerprint, next[0]?.fingerprint);
    await rm(join(dir, 'notes', 'draft.txt'));
    assert.equal((await workspace.snapshot()).changes[0]?.fingerprint, 'deleted');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('reads text files inside the workspace and blocks traversal', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-workspace-'));
  try {
    await writeFile(join(dir, 'hello.txt'), 'hello\nworld', 'utf8');
    const workspace = new WorkspaceService(dir);

    assert.deepEqual(await workspace.readFile('hello.txt'), {
      path: 'hello.txt',
      content: 'hello\nworld',
      size: 11,
      truncated: false,
    });
    await assert.rejects(() => workspace.readFile('../secret.txt'), /invalid_path/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('does not read git-ignored or git-internal files by guessed path', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-workspace-'));
  try {
    await writeFile(join(dir, '.gitignore'), '.data/\n.env\n', 'utf8');
    await writeFile(join(dir, '.env'), 'SECRET=value', 'utf8');
    await writeFile(join(dir, 'visible.txt'), 'visible', 'utf8');
    await mkdir(join(dir, '.data'));
    await writeFile(join(dir, '.data', 'state.json'), '{}', 'utf8');
    await execFileAsync('git', ['-C', dir, 'init', '-q']);
    const workspace = new WorkspaceService(dir);

    assert.equal((await workspace.readFile('visible.txt')).content, 'visible');

    await assert.rejects(() => workspace.readFile('.env'), /file_not_browsable/);
    await assert.rejects(
      () => workspace.readFile('.data/state.json'),
      /file_not_browsable/,
    );
    await assert.rejects(() => workspace.readFile('.git/config'), /file_not_browsable/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
