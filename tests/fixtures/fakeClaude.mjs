import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { dirname } from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const options = Object.fromEntries(process.argv.slice(2)
  .filter(arg => arg.startsWith('--fake-'))
  .map(arg => {
    const [key, ...value] = arg.slice('--fake-'.length).split('=');
    return [key, value.join('=')];
  }));

if (options.log) appendFileSync(options.log, JSON.stringify(process.argv.slice(2)) + '\n');
if (options.envlog) {
  appendFileSync(options.envlog, JSON.stringify({
    effort: process.env.CLAUDE_CODE_EFFORT_LEVEL ?? null,
    entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT ?? null,
  }) + '\n');
}

const resumeIndex = process.argv.indexOf('--resume');
if (options.mode === 'stale-resume' && resumeIndex >= 0) {
  process.stderr.write(`No conversation found with session ID: ${process.argv[resumeIndex + 1]}\n`);
  process.exitCode = 1;
} else {
  const input = createInterface({ input: process.stdin });
  input.on('line', line => {
    const message = JSON.parse(line);
    if (message.type === 'control_request' && message.request?.subtype === 'initialize') {
      process.stdout.write(JSON.stringify({
        type: 'control_response',
        response: { subtype: 'success', request_id: message.request_id },
      }) + '\n');
      return;
    }
    if (message.type !== 'user') return;
    if (options.history) {
      mkdirSync(dirname(options.history), { recursive: true });
      const previous = existsSync(options.history)
        ? readFileSync(options.history, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line))
        : [];
      const parent = previous.filter(entry => entry.uuid).at(-1)?.uuid ?? null;
      const userId = randomUUID();
      const entries = [
        { type: 'user', uuid: userId, parentUuid: parent, message: message.message },
        { type: 'assistant', uuid: randomUUID(), parentUuid: userId,
          message: { role: 'assistant', content: [{ type: 'text', text: 'fake reply' }] } },
      ].map(entry => ({ ...entry, sessionId: options.session, entrypoint: 'sdk-cli' }));
      appendFileSync(options.history, entries.map(entry => JSON.stringify(entry)).join('\n') + '\n');
    }

    process.stdout.write(JSON.stringify({
      type: 'system',
      subtype: 'init',
      session_id: options.session || 'fake-session-id',
    }) + '\n');

    if (options.mode === 'hang-tree') {
      const descendant = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
        detached: false,
        stdio: 'ignore',
        windowsHide: true,
      });
      if (options.pid) writeFileSync(options.pid, String(descendant.pid));
      setInterval(() => {}, 1000);
      return;
    }

    process.stdout.write(JSON.stringify({
      type: 'assistant',
      message: { content: [{ type: 'text', text: 'fake reply' }] },
    }) + '\n');
    process.stdout.write(JSON.stringify({ type: 'result', is_error: false }) + '\n');
  });
}
