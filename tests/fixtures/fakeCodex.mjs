import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
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
let initialized = false;

log({ kind: 'process', args, ...(fakeOptions['record-cwd'] === '1' ? { cwd: process.cwd() } : {}) });

const input = createInterface({ input: process.stdin });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.method === 'initialized') { initialized = true; return; }
  if (message.id !== undefined) log({ kind: 'request', method: message.method, params: message.params });

  if (message.method === 'initialize') {
    setTimeout(() => respond(message.id, {
      userAgent: 'fake-codex',
      platformFamily: 'windows',
      platformOs: 'windows',
      codexHome: process.cwd(),
    }), Number(fakeOptions.initializeDelay || 0));
    return;
  }
  if (!initialized) {
    process.stdout.write(JSON.stringify({ id: message.id, error: { message: 'not_initialized' } }) + '\n');
    return;
  }
  if (message.method === 'thread/read') {
    const history = readHistory();
    respond(message.id, { thread: {
      id: fakeOptions.mode === 'history-wrong-thread' ? 'different-thread' : message.params.threadId,
      status: { type: history.running ? 'active' : 'notLoaded' },
      turns: message.params.includeTurns ? history.turns : [],
    } });
    return;
  }
  if (message.method === 'thread/turns/list' || message.method === 'thread/items/list') {
    if (fakeOptions.mode === 'history-legacy' || fakeOptions.mode === 'history-error') {
      process.stdout.write(JSON.stringify({ id: message.id, error: {
        code: fakeOptions.mode === 'history-legacy' ? -32601 : -32000,
        message: fakeOptions.mode === 'history-legacy' ? 'method not found' : 'history_unavailable',
      } }) + '\n');
      return;
    }
    const history = readHistory();
    const data = message.method === 'thread/turns/list' ? history.turns.map(turn => ({
      ...turn,
      itemsView: fakeOptions.mode === 'history-summary' ? 'summary' : 'full',
      ...(fakeOptions.mode === 'history-summary' ? { items: [] } : {}),
    })) : history.turns.filter(turn => turn.id === message.params.turnId)
      .flatMap(turn => turn.items.map(item => ({ turnId: turn.id, item })));
    const index = Number(message.params.cursor || 0);
    const page = {
      data: data.slice(index, index + 1),
      nextCursor: fakeOptions.mode === 'history-loop' ? '0'
        : index + 1 < data.length ? String(index + 1) : null,
    };
    if (history.delayMs) setTimeout(() => respond(message.id, page), history.delayMs);
    else respond(message.id, page);
    return;
  }
  if (message.method === 'model/list' || message.method === 'skills/list') {
    if (fakeOptions.mode === 'catalog-error') {
      process.stdout.write(JSON.stringify({ id: message.id, error: { message: 'catalog_unavailable' } }) + '\n');
      return;
    }
    if (message.method === 'model/list') {
      respond(message.id, message.params.cursor ? {
        data: [{ model: 'gpt-test-fast', displayName: 'Fast', description: 'Fast model', isDefault: false }],
        nextCursor: null,
      } : {
        data: [
          { model: 'gpt-test-codex', displayName: 'Codex Test', description: 'Coding model', isDefault: true },
          { model: 'gpt-hidden', hidden: true },
        ],
        nextCursor: 'second-page',
      });
    } else {
      respond(message.id, { data: [{
        cwd: process.cwd(),
        skills: [
          { name: 'inspect', description: 'Inspect code', path: process.cwd() + '/skills/inspect/SKILL.md', enabled: true },
          { name: 'disabled', path: '/disabled/SKILL.md', enabled: false },
        ],
        errors: [],
      }] });
    }
    return;
  }

  if (message.method === 'thread/start' || message.method === 'thread/resume') {
    respond(message.id, { thread: { id: threadId, turns: [], model: 'gpt-6-sol' }, model: 'gpt-6-sol' });
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
  if (message.method === 'thread/compact/start') {
    if (fakeOptions.mode === 'compact-rpc-error') {
      process.stdout.write(JSON.stringify({ id: message.id, error: { message: 'compaction_unavailable' } }) + '\n');
      return;
    }
    respond(message.id, {});
    const compactTurnId = `compact-${++turnNumber}`;
    notify('turn/started', { threadId, turn: { id: compactTurnId, items: [], status: 'inProgress' } });
    notify('item/started', { threadId, turnId: compactTurnId, item: { id: compactTurnId, type: 'contextCompaction' } });
    notify('turn/completed', { threadId: 'unrelated-thread', turn: { id: compactTurnId, items: [], status: 'completed' } });
    notify('turn/completed', { threadId, turn: { id: 'stale-turn', items: [], status: 'completed' } });
    if (fakeOptions.mode === 'compact-hang') return;
    setTimeout(() => {
      if (fakeOptions.mode !== 'compact-failed') {
        notify('item/completed', { threadId, turnId: compactTurnId, item: { id: compactTurnId, type: 'contextCompaction' } });
      }
      notify('turn/completed', {
        threadId,
        turn: { id: compactTurnId, items: [], status: fakeOptions.mode === 'compact-failed' ? 'failed' : 'completed',
          ...(fakeOptions.mode === 'compact-failed' ? { error: { message: 'compaction_failed' } } : {}) },
      });
    }, 40);
    return;
  }
  if (message.method === 'review/start') {
    const reviewTurnId = `review-${++turnNumber}`;
    respond(message.id, { turn: { id: reviewTurnId, items: [], status: 'inProgress' }, reviewThreadId: threadId });
    notify('turn/started', { threadId, turn: { id: reviewTurnId, items: [], status: 'inProgress' } });
    notify('item/completed', { threadId, turnId: reviewTurnId,
      item: { id: reviewTurnId, type: 'exitedReviewMode', review: 'native review result' } });
    notify('turn/completed', { threadId, turn: { id: reviewTurnId, items: [], status: 'completed' } });
    return;
  }
  if (message.method !== 'turn/start') return;
  if (fakeOptions.history) turnNumber = Math.max(turnNumber, readHistory().turns.length);

  const turnId = `fake-turn-${++turnNumber}`;
  respond(message.id, { turn: { id: turnId, items: [], status: 'inProgress' } });
  notify('turn/started', {
    threadId,
    turn: { id: turnId, items: [], status: 'inProgress' },
  });
  if (fakeOptions.mode === 'hang') return;
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
  if (fakeOptions.history) {
    const history = readHistory();
    history.turns.push({
      id: turnId, status: 'completed', itemsView: 'full',
      items: [
        { id: turnId + '-user', type: 'userMessage', content: message.params.input },
        { id: 'message-' + turnNumber, type: 'agentMessage', text: 'fake codex reply' },
      ],
    });
    writeFileSync(fakeOptions.history, JSON.stringify(history));
  }
  notify('turn/completed', {
    threadId,
    turn: { id: turnId, items: [], status: 'completed' },
  });
});

function readHistory() {
  return fakeOptions.history && existsSync(fakeOptions.history)
    ? JSON.parse(readFileSync(fakeOptions.history, 'utf8')) : { turns: [] };
}

function respond(id, result) {
  process.stdout.write(JSON.stringify({ id, result }) + '\n');
}

function notify(method, params) {
  process.stdout.write(JSON.stringify({ method, params }) + '\n');
}

function log(record) {
  if (fakeOptions.log) appendFileSync(fakeOptions.log, JSON.stringify(record) + '\n');
}
