import { appendFileSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const options = Object.fromEntries(process.argv.slice(2)
  .filter(arg => arg.startsWith('--fake-'))
  .map(arg => {
    const [key, ...value] = arg.slice('--fake-'.length).split('=');
    return [key, value.join('=')];
  }));

if (options.log) appendFileSync(options.log, JSON.stringify(process.argv.slice(2)) + '\n');

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
