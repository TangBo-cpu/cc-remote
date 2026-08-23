import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const rawArgs = process.argv.slice(2);
const fakeOptions = Object.fromEntries(rawArgs
  .filter(arg => arg.startsWith('--fake-'))
  .map(arg => {
    const [key, ...value] = arg.slice('--fake-'.length).split('=');
    return [key, value.join('=')];
  }));
const args = rawArgs.filter(arg => !arg.startsWith('--fake-'));
const threadId = fakeOptions.session || 'fake-thread-id';
let turnNumber = 0;

log({ kind: 'process', args });

const input = createInterface({ input: process.stdin });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.method === 'initialized') return;
  if (message.id !== undefined) log({ kind: 'request', method: message.method, params: message.params });

  if (message.method === 'initialize') {
    respond(message.id, {
      userAgent: 'fake-codex',
      platformFamily: 'windows',
      platformOs: 'windows',
      codexHome: process.cwd(),
    });
    return;
  }
  if (message.method === 'thread/start' || message.method === 'thread/resume') {
    respond(message.id, { thread: { id: threadId, turns: [] } });
    return;
  }
  if (message.method === 'turn/interrupt') {
    respond(message.id, {});
    notify('turn/completed', {
      threadId,
      turn: { id: message.params.turnId, items: [], status: 'interrupted' },
    });
    return;
  }
  if (message.method !== 'turn/start') return;

  const turnId = `fake-turn-${++turnNumber}`;
  respond(message.id, { turn: { id: turnId, items: [], status: 'inProgress' } });
  notify('turn/started', {
    threadId,
    turn: { id: turnId, items: [], status: 'inProgress' },
  });
  notify('item/started', {
    threadId,
    turnId,
    startedAtMs: Date.now(),
    item: {
      id: `command-${turnNumber}`,
      type: 'commandExecution',
      command: 'npm test',
      commandActions: [],
      cwd: process.cwd(),
      status: 'inProgress',
    },
  });
  notify('item/completed', {
    threadId,
    turnId,
    completedAtMs: Date.now(),
    item: {
      id: `command-${turnNumber}`,
      type: 'commandExecution',
      command: 'npm test',
      commandActions: [],
      cwd: process.cwd(),
      status: 'completed',
      exitCode: 0,
    },
  });
  notify('item/agentMessage/delta', {
    threadId,
    turnId,
    itemId: `message-${turnNumber}`,
    delta: 'fake codex ',
  });
  notify('item/agentMessage/delta', {
    threadId,
    turnId,
    itemId: `message-${turnNumber}`,
    delta: 'reply',
  });
  notify('item/completed', {
    threadId,
    turnId,
    completedAtMs: Date.now(),
    item: {
      id: `message-${turnNumber}`,
      type: 'agentMessage',
      text: 'fake codex reply',
    },
  });
  notify('thread/tokenUsage/updated', {
    threadId,
    turnId,
    tokenUsage: {
      total: {
        cachedInputTokens: 2,
        inputTokens: 10,
        outputTokens: 3,
        reasoningOutputTokens: 0,
        totalTokens: 13,
      },
      last: {
        cachedInputTokens: 2,
        inputTokens: 10,
        outputTokens: 3,
        reasoningOutputTokens: 0,
        totalTokens: 13,
      },
      modelContextWindow: 200000,
    },
  });
  notify('turn/completed', {
    threadId,
    turn: { id: turnId, items: [], status: 'completed' },
  });
});

function respond(id, result) {
  process.stdout.write(JSON.stringify({ id, result }) + '\n');
}

function notify(method, params) {
  process.stdout.write(JSON.stringify({ method, params }) + '\n');
}

function log(record) {
  if (fakeOptions.log) appendFileSync(fakeOptions.log, JSON.stringify(record) + '\n');
}
