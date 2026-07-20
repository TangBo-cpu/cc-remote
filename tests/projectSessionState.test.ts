import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createProjectSessionState } from '../src/projectSessionState.js';

test('registers projects and keeps independent sessions', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-projects-'));
  const first = join(dir, 'first');
  const second = join(dir, 'second');
  await mkdir(first);
  await mkdir(second);
  try {
    const state = await createProjectSessionState({ dataDir: join(dir, 'data'), initialWorkspace: first });
    const initial = state.active();
    initial.transcript.beginPrompt('first prompt', 'manual');
    await initial.transcript.finishDone();

    await state.registerProject(second);
    const secondContext = state.active();
    assert.equal(secondContext.project.path, second);
    assert.notEqual(secondContext.session.id, initial.session.id);
    assert.deepEqual(secondContext.transcript.snapshot().messages, []);

    const another = await state.createSession(secondContext.project.id);
    assert.notEqual(another.session.id, secondContext.session.id);
    await state.setSessionTitleFromPrompt(another.session.id, 'implement project switching with tests');
    assert.equal(state.catalog().projects.length, 2);
    assert.equal(state.catalog().sessions.length, 3);
    assert.equal(
      state.catalog().sessions.find(item => item.id === another.session.id)?.title,
      'implement project switching with tests',
    );

    await state.setSessionTitle(another.session.id, '  切换项目  ');
    assert.equal(
      state.catalog().sessions.find(item => item.id === another.session.id)?.title,
      '切换项目',
    );

    const third = await state.createSession(secondContext.project.id, 'to-archive');
    await state.archiveSession(third.session.id);
    assert.equal(
      state.catalog().sessions.find(item => item.id === third.session.id)?.archived,
      true,
    );

    const deleted = await state.deleteSession(another.session.id);
    assert.equal(deleted.deletedSessionId, another.session.id);
    assert.equal(
      deleted.catalog.sessions.some(item => item.id === another.session.id),
      false,
    );

    await state.selectSession(initial.session.id);
    assert.equal(state.active().transcript.snapshot().messages[0].text, 'first prompt');
    await state.flush();

    const reloaded = await createProjectSessionState({
      dataDir: join(dir, 'data'),
      initialWorkspace: first,
    });
    assert.equal(reloaded.active().session.id, initial.session.id);
    assert.equal(reloaded.catalog().projects.length, 2);
    // archived third + remaining sessions after delete of "another"
    assert.equal(reloaded.catalog().sessions.length, 3);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('registering the launch workspace reactivates it after reload', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-boot-workspace-'));
  const first = join(dir, 'first');
  const second = join(dir, 'second');
  await mkdir(first);
  await mkdir(second);
  try {
    const state = await createProjectSessionState({ dataDir: join(dir, 'data'), initialWorkspace: first });
    await state.registerProject(second);
    assert.equal(state.active().project.path, second);
    await state.flush();

    // Cold start reloads last active project; daemon must register launch cwd again.
    const reloaded = await createProjectSessionState({
      dataDir: join(dir, 'data'),
      initialWorkspace: first,
    });
    assert.equal(reloaded.active().project.path, second);
    await reloaded.registerProject(first);
    assert.equal(reloaded.active().project.path, first);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('registerProject skips archived sessions when reactivating a project', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-skip-archived-'));
  const first = join(dir, 'first');
  const second = join(dir, 'second');
  await mkdir(first);
  await mkdir(second);
  try {
    const state = await createProjectSessionState({ dataDir: join(dir, 'data'), initialWorkspace: first });
    const live = state.active();
    const archived = await state.createSession(live.project.id, 'old');
    await state.archiveSession(archived.session.id);
    assert.equal(state.active().session.id, live.session.id);

    await state.registerProject(second);
    await state.registerProject(first);
    assert.equal(state.active().session.id, live.session.id);
    assert.equal(state.active().session.archivedAt, undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('migrates the legacy transcript into the initial session', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-project-migration-'));
  const dataDir = join(dir, 'data');
  await mkdir(dataDir);
  await writeFile(join(dataDir, 'transcript.json'), JSON.stringify({
    version: 1,
    revision: 4,
    running: false,
    updatedAt: Date.now(),
    claudeSessionId: 'claude-session-1',
    permissionMode: 'manual',
    pendingPermissions: [],
    sessionInfo: { model: 'claude-opus-4-8' },
    messages: [{ role: 'user', text: 'legacy prompt' }],
  }));
  try {
    const state = await createProjectSessionState({ dataDir, initialWorkspace: dir });
    const snapshot = state.active().transcript.snapshot();
    assert.equal(snapshot.claudeSessionId, 'claude-session-1');
    assert.equal(snapshot.messages[0].text, 'legacy prompt');
    assert.equal(state.catalog().sessions.length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
