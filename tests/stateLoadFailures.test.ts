import assert from 'node:assert/strict';
import fs, { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createProjectSessionState } from '../src/projectSessionState.js';
import { createTranscriptState } from '../src/transcriptState.js';

for (const kind of ['transcript', 'catalog'] as const) {
  test(`${kind} read errors preserve existing data and allow reload`, async t => {
    const dir = await mkdtemp(join(tmpdir(), 'cc-remote-load-failure-'));
    const path = join(dir, kind === 'transcript' ? 'transcript.json' : 'projects.json');
    const load = () => kind === 'transcript'
      ? createTranscriptState(path)
      : createProjectSessionState({ dataDir: dir, initialWorkspace: dir });
    try {
      if (kind === 'transcript') {
        const state = await createTranscriptState(path);
        state.beginPrompt('existing question', 'manual');
        state.appendText('existing answer');
        await state.finishDone();
      } else {
        await load();
      }
      const original = await readFile(path, 'utf8');
      const read = t.mock.method(fs, 'readFile', () =>
        Promise.reject(Object.assign(new Error('read blocked'), { code: 'EACCES' })));
      syncBuiltinESMExports();
      try {
        await assert.rejects(load(), { code: 'EACCES' });
      } finally {
        read.mock.restore();
        syncBuiltinESMExports();
      }
      assert.equal(await readFile(path, 'utf8'), original);
      await load();
      assert.equal(await readFile(path, 'utf8'), original);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test(`${kind} malformed files are rejected without rewriting them`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'cc-remote-invalid-state-'));
    const path = join(dir, kind === 'transcript' ? 'transcript.json' : 'projects.json');
    const load = () => kind === 'transcript'
      ? createTranscriptState(path)
      : createProjectSessionState({ dataDir: dir, initialWorkspace: dir });
    const invalid = kind === 'transcript'
      ? { version: 1, messages: [{ role: 'user', text: 'keep' }, { role: 'user', text: 42 }] }
      : { version: 1, projects: [{ id: 'keep' }], sessions: [] };
    try {
      for (const content of ['{', 'null', '{"version":2}', JSON.stringify(invalid)]) {
        await writeFile(path, content);
        await assert.rejects(load());
        assert.equal(await readFile(path, 'utf8'), content);
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}
