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
      'implement project switching with tes',
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
