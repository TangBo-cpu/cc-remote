import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createProjectSessionState } from '../src/projectSessionState.js';

test('failed session creation preserves the active session and can be retried', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-create-failure-'));
  const options = { dataDir: join(dir, 'data'), initialWorkspace: dir };
  const catalogPath = join(options.dataDir, 'projects.json');
  try {
    const state = await createProjectSessionState(options);
    const original = state.active();
    original.transcript.beginPrompt('keep this history', 'manual');
    await original.transcript.finishDone();
    const before = state.catalog();
    await rename(catalogPath, catalogPath + '.saved');
    await mkdir(catalogPath);

    await assert.rejects(state.createSession(original.project.id, undefined, 'codex'));
    assert.deepEqual(state.catalog(), before);
    assert.equal(state.active().session.id, original.session.id);
    assert.equal(state.active().transcript.snapshot().messages[0].text, 'keep this history');

    await rm(catalogPath, { recursive: true });
    await rename(catalogPath + '.saved', catalogPath);
    await state.flush();
    const restored = await createProjectSessionState(options);
    assert.equal(restored.active().session.id, original.session.id);
    const created = await state.createSession(original.project.id, undefined, 'codex');
    assert.equal(created.session.engine, 'codex');
    assert.equal(state.catalog().sessions.length, 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

for (const lastSession of [false, true]) {
  test(`failed deletion preserves history and supports retry (last=${lastSession})`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'cc-remote-delete-failure-'));
    const options = { dataDir: join(dir, 'data'), initialWorkspace: dir };
    const catalogPath = join(options.dataDir, 'projects.json');
    try {
      const state = await createProjectSessionState(options);
      const original = state.active();
      original.transcript.beginPrompt('keep this history', 'manual');
      original.transcript.appendText('saved answer');
      await original.transcript.finishDone();
      if (!lastSession) await state.createSession(original.project.id);
      const before = state.catalog();
      const transcriptPath = join(options.dataDir, 'sessions', `${original.session.id}.json`);
      const savedTranscript = await readFile(transcriptPath, 'utf8');
      await rename(catalogPath, catalogPath + '.saved');
      await mkdir(catalogPath);

      await assert.rejects(state.deleteSession(original.session.id));
      assert.deepEqual(state.catalog(), before);
      assert.equal(state.active().session.id, before.activeSessionId);
      assert.equal(await readFile(transcriptPath, 'utf8'), savedTranscript);
      assert.equal(state.getSession(original.session.id)?.transcript.snapshot().messages.length, 2);

      await rm(catalogPath, { recursive: true });
      await rename(catalogPath + '.saved', catalogPath);
      await state.flush();
      const restored = await createProjectSessionState(options);
      assert.equal(restored.getSession(original.session.id)?.transcript.snapshot().messages.length, 2);
      await state.deleteSession(original.session.id);
      assert.equal(state.getSession(original.session.id), undefined);
      assert.equal(state.catalog().sessions.length, 1);
      await assert.rejects(readFile(transcriptPath, 'utf8'), { code: 'ENOENT' });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}

for (const background of [false, true]) {
  test(`deleting the last Codex session preserves its engine and active selection (background=${background})`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'cc-remote-delete-selection-'));
    const options = { dataDir: join(dir, 'data'), initialWorkspace: dir };
    try {
      const state = await createProjectSessionState(options);
      const initial = state.active();
      const codex = await state.createSession(initial.project.id, undefined, 'codex');
      await state.deleteSession(initial.session.id);
      if (background) {
        const other = join(dir, 'other');
        await mkdir(other);
        await state.registerProject(other);
      }
      const activeBefore = state.active().session.id;
      await state.deleteSession(codex.session.id);
      const replacement = state.catalog().sessions.find(item => item.projectId === codex.project.id);
      assert.ok(replacement);
      assert.notEqual(replacement.id, codex.session.id);
      assert.equal(replacement.engine, 'codex');
      assert.equal(state.active().session.id, background ? activeBefore : replacement.id);
      await state.flush();
      const restored = await createProjectSessionState(options);
      assert.equal(restored.active().session.id, state.active().session.id);
      assert.equal(restored.getSession(replacement.id)?.session.engine, 'codex');
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}

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
    assert.equal(snapshot.engineSessionId, 'claude-session-1');
    assert.equal(snapshot.messages[0].text, 'legacy prompt');
    assert.equal(state.catalog().sessions.length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('searches session titles and user or assistant transcript text', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-session-search-'));
  try {
    const state = await createProjectSessionState({
      dataDir: join(dir, 'data'),
      initialWorkspace: dir,
    });
    const first = state.active();
    await state.setSessionTitle(first.session.id, 'Reconnect investigation');
    first.transcript.beginPrompt('检查网络恢复状态', 'manual');
    first.transcript.appendText('The reconnect panel is ready for review.');
    await first.transcript.finishDone();

    const second = await state.createSession(first.project.id, 'Other task');
    second.transcript.beginPrompt('Write the release notes', 'manual');
    second.transcript.appendText('Document the RECONNECT behavior.');
    await second.transcript.finishDone();

    const systemOnly = await state.createSession(first.project.id, 'Failure log');
    systemOnly.transcript.beginPrompt('Unrelated request', 'manual');
    await systemOnly.transcript.finishError('reconnect secret should stay system-only');
    await state.archiveSession(second.session.id);

    const titleOnly = await state.createSession(first.project.id, 'Unique title needle');

    const results = state.searchSessions('reconnect');
    assert.equal(results.length, 2);
    assert.deepEqual(
      new Set(results.map(result => result.sessionId)),
      new Set([first.session.id, second.session.id]),
    );
    for (const result of results) {
      assert.equal(
        result.snippet.slice(result.matchStart, result.matchEnd).toLowerCase(),
        'reconnect',
      );
      assert.ok(result.matchCount >= 1);
      assert.ok(result.role === 'title' || result.role === 'assistant');
    }
    assert.equal(
      results.find(result => result.sessionId === second.session.id)?.archived,
      true,
    );
    const chineseResults = state.searchSessions('网络恢复');
    assert.equal(chineseResults.length, 1);
    assert.equal(chineseResults[0]?.sessionId, first.session.id);
    assert.equal(state.searchSessions('reconnect', 1).length, 1);
    const titleResults = state.searchSessions('title needle');
    assert.equal(titleResults.length, 1);
    assert.equal(titleResults[0]?.sessionId, titleOnly.session.id);
    assert.equal(titleResults[0]?.role, 'title');

    const unicodeTitle = await state.createSession(first.project.id, 'İstanbul notes');
    const unicodeResults = state.searchSessions('İ');
    const unicodeResult = unicodeResults.find(
      result => result.sessionId === unicodeTitle.session.id,
    );
    assert.ok(unicodeResult);
    assert.equal(
      unicodeResult.snippet.slice(unicodeResult.matchStart, unicodeResult.matchEnd),
      'İ',
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('loads legacy catalog sessions without an engine as Claude sessions', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-engine-migration-'));
  const dataDir = join(dir, 'data');
  const catalogPath = join(dataDir, 'projects.json');
  try {
    const seeded = await createProjectSessionState({
      dataDir,
      initialWorkspace: dir,
    });
    const sessionId = seeded.active().session.id;
    await seeded.flush();

    const stored = JSON.parse(await readFile(catalogPath, 'utf8')) as {
      sessions: Array<{ id: string; engine?: string }>;
    };
    const legacySession = stored.sessions.find(session => session.id === sessionId);
    assert.ok(legacySession);
    delete legacySession.engine;
    await writeFile(catalogPath, `${JSON.stringify(stored, null, 2)}\n`, 'utf8');

    const restored = await createProjectSessionState({
      dataDir,
      initialWorkspace: dir,
    });
    assert.equal(restored.active().session.id, sessionId);
    assert.equal(restored.active().session.engine, 'claude');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('persists the selected engine independently for each session', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-session-engines-'));
  const dataDir = join(dir, 'data');
  try {
    const state = await createProjectSessionState({
      dataDir,
      initialWorkspace: dir,
    });
    const claudeSession = state.active();
    const codexSession = await state.createSession(
      claudeSession.project.id,
      'Codex task',
      'codex',
    );

    assert.equal(claudeSession.session.engine, 'claude');
    assert.equal(codexSession.session.engine, 'codex');
    await state.flush();

    const restored = await createProjectSessionState({
      dataDir,
      initialWorkspace: dir,
    });
    assert.equal(
      restored.getSession(claudeSession.session.id)?.session.engine,
      'claude',
    );
    assert.equal(
      restored.getSession(codexSession.session.id)?.session.engine,
      'codex',
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
