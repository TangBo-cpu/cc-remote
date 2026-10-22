import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  ClaudeBridge,
  extractClaudeActivities,
  extractClaudeCommands,
  extractClaudePermissionRequest,
  extractClaudeSessionInfo,
  isMissingConversationError,
  mergeClaudeSessionInfo,
  normalizeClaudeEffort,
  normalizeClaudeModel,
  permissionControlResponse,
  restoreClaudeSessionInfo,
} from '../src/claudeBridge.js';

test('ClaudeBridge reports a missing CLI as a run result instead of throwing', async () => {
  const bridge = new ClaudeBridge({ claudeBin: 'cc-remote-missing-claude-bin', workspaceDir: process.cwd() });
  const result = await bridge.run({
    prompt: 'test',
    permissionMode: 'manual',
    onEvent: () => {},
    onText: () => {},
    onSessionId: () => {},
    onPermissionRequest: () => {},
    onPermissionClosed: () => {},
  });

  assert.equal(result.exitCode, null);
  assert.equal(result.stopped, false);
  assert.match(result.stderr, /ENOENT|not found|spawn/i);
  assert.equal(bridge.isRunning(), false);
});

test('ClaudeBridge reuses one streaming process across turns', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-bridge-resume-'));
  const logPath = join(dir, 'args.jsonl');
  const fixture = join(process.cwd(), 'tests', 'fixtures', 'fakeClaude.mjs');
  let bridge: ClaudeBridge | undefined;
  try {
    bridge = new ClaudeBridge({
      claudeBin: process.execPath,
      claudeArgs: [fixture, `--fake-log=${logPath}`],
      workspaceDir: dir,
    });
    const callbacks = {
      prompt: 'test',
      permissionMode: 'manual' as const,
      onEvent: () => {},
      onText: () => {},
      onSessionId: () => {},
      onPermissionRequest: () => {},
      onPermissionClosed: () => {},
    };

    const first = await bridge.run(callbacks);
    assert.equal(first.sessionId, 'fake-session-id');
    const second = await bridge.run({
      ...callbacks,
      sessionId: first.sessionId,
    });
    assert.equal(second.exitCode, 0);

    const invocations = (await readFile(logPath, 'utf8'))
      .trim()
      .split(/\r?\n/)
      .map(line => JSON.parse(line) as string[]);
    assert.equal(invocations.length, 1);
    assert.equal(invocations[0].includes('--resume'), false);
  } finally {
    bridge?.close();
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('ClaudeBridge preserves stale-session stderr emitted before initialization', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-bridge-stale-session-'));
  const fixture = join(process.cwd(), 'tests', 'fixtures', 'fakeClaude.mjs');
  try {
    const bridge = new ClaudeBridge({
      claudeBin: process.execPath,
      claudeArgs: [fixture, '--fake-mode=stale-resume'],
      workspaceDir: dir,
    });
    const result = await bridge.run({
      prompt: 'test',
      sessionId: 'stale-session-id',
      permissionMode: 'manual',
      onEvent: () => {},
      onText: () => {},
      onSessionId: () => {},
      onPermissionRequest: () => {},
      onPermissionClosed: () => {},
    });

    assert.equal(result.exitCode, 1);
    assert.match(result.stderr, /No conversation found with session ID: stale-session-id/i);
  } finally {
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

for (const mode of ['compact-success', 'compact-failed', 'compact-empty']) {
  test('ClaudeBridge reports native compact outcomes once (' + mode + ')', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'cc-remote-claude-compact-'));
    const bridge = new ClaudeBridge({
      claudeBin: process.execPath,
      claudeArgs: [join(process.cwd(), 'tests', 'fixtures', 'fakeClaude.mjs'), '--fake-mode=' + mode],
      workspaceDir: dir,
    });
    const text: string[] = [];
    const callbacks = { permissionMode: 'manual' as const,
      onEvent: () => {}, onText: (value: string) => text.push(value), onSessionId: () => {} };
    try {
      const result = await bridge.run({ prompt: '/compact Keep the test code.', ...callbacks });
      if (mode === 'compact-success') {
        assert.equal(result.exitCode, 0);
        assert.deepEqual(text, ['上下文压缩完成。']);
      } else {
        assert.equal(result.exitCode, 1);
        assert.match(result.stderr, mode === 'compact-empty' ? /No messages to compact/ : /compaction_failed/);
        assert.deepEqual(text, []);
      }
      text.length = 0;
      assert.equal((await bridge.run({ prompt: 'continue', ...callbacks })).exitCode, 0);
      assert.deepEqual(text, ['fake reply']);
      assert.equal(bridge.isRunning(), false);
    } finally {
      bridge.close();
      await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
    }
  });
}

test('Claude model overrides reject unsafe CLI values', () => {
  assert.equal(normalizeClaudeModel(' claude-opus-4-8 '), 'claude-opus-4-8');
  assert.equal(normalizeClaudeModel(undefined), undefined);
  assert.throws(() => normalizeClaudeModel('--dangerously-skip-permissions'));
  assert.throws(() => normalizeClaudeModel('opus sonnet'));
});

test('Claude effort accepts only Claude Code effort levels', () => {
  assert.equal(normalizeClaudeEffort('auto'), 'auto');
  assert.equal(normalizeClaudeEffort('xhigh'), 'xhigh');
  assert.equal(normalizeClaudeEffort(undefined), undefined);
  assert.throws(() => normalizeClaudeEffort('ultracode'));
  assert.throws(() => normalizeClaudeEffort('--model'));
});

test('ClaudeBridge resets automatic effort through the Claude Code environment', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-bridge-effort-'));
  const envLogPath = join(dir, 'env.jsonl');
  const fixture = join(process.cwd(), 'tests', 'fixtures', 'fakeClaude.mjs');
  let bridge: ClaudeBridge | undefined;
  try {
    bridge = new ClaudeBridge({
      claudeBin: process.execPath,
      claudeArgs: [fixture, `--fake-envlog=${envLogPath}`],
      workspaceDir: dir,
    });
    await bridge.run({
      prompt: 'test',
      effort: 'auto',
      permissionMode: 'manual',
      onEvent: () => {},
      onText: () => {},
      onSessionId: () => {},
      onPermissionRequest: () => {},
      onPermissionClosed: () => {},
    });

    const environment = JSON.parse((await readFile(envLogPath, 'utf8')).trim()) as {
      effort: string | null;
      entrypoint: string | null;
    };
    assert.equal(environment.effort, 'auto');
    assert.equal(environment.entrypoint, 'cc-app');
  } finally {
    bridge?.close();
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('ClaudeBridge stop removes the full Claude process tree on Windows', {
  skip: process.platform !== 'win32',
}, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-bridge-stop-'));
  const pidPath = join(dir, 'descendant.pid');
  const fixture = join(process.cwd(), 'tests', 'fixtures', 'fakeClaude.mjs');
  let descendantPid = 0;
  try {
    const bridge = new ClaudeBridge({
      claudeBin: process.execPath,
      claudeArgs: [fixture, '--fake-mode=hang-tree', `--fake-pid=${pidPath}`],
      workspaceDir: dir,
    });
    const running = bridge.run({
      prompt: 'test',
      permissionMode: 'manual',
      onEvent: () => {},
      onText: () => {},
      onSessionId: () => {},
      onPermissionRequest: () => {},
      onPermissionClosed: () => {},
    });
    descendantPid = Number(await waitForFile(pidPath));
    assert.equal(isProcessAlive(descendantPid), true);

    assert.equal(bridge.stop(), true);
    const result = await running;
    assert.equal(result.stopped, true);
    await waitFor(() => !isProcessAlive(descendantPid), 3_000);
    assert.equal(isProcessAlive(descendantPid), false);
  } finally {
    if (descendantPid && isProcessAlive(descendantPid)) {
      try { process.kill(descendantPid); } catch {}
    }
    await rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

test('detects stale Claude Code session errors', () => {
  assert.equal(
    isMissingConversationError('Error: No conversation found with session ID: cc8a61d2-6548-4527-b29f-7bc3d2b8aa6b'),
    true,
  );
  assert.equal(isMissingConversationError('Some other Claude error'), false);
});

async function waitForFile(path: string): Promise<string> {
  let lastError: unknown;
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      return await readFile(path, 'utf8');
    } catch (error) {
      lastError = error;
      await new Promise(resolveTimeout => setTimeout(resolveTimeout, 25));
    }
  }
  throw lastError instanceof Error ? lastError : new Error('file_wait_timeout');
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolveTimeout => setTimeout(resolveTimeout, 25));
  }
  throw new Error('condition_wait_timeout');
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test('normalizes safe activity events without exposing thinking text or tool results', () => {
  assert.deepEqual(extractClaudeActivities({
    type: 'stream_event',
    event: {
      type: 'content_block_start',
      content_block: { type: 'thinking', thinking: 'private reasoning' },
    },
  }), [{ id: 'thinking', kind: 'thinking', state: 'running' }]);

  assert.deepEqual(extractClaudeActivities({
    type: 'assistant',
    message: {
      content: [{
        type: 'tool_use',
        id: 'tool-1',
        name: 'Read',
        input: { file_path: 'mobile/lib/main.dart' },
      }],
    },
  }), [{
    id: 'tool-1',
    kind: 'tool',
    state: 'running',
    toolName: 'Read',
    detail: 'mobile/lib/main.dart',
  }]);

  assert.deepEqual(extractClaudeActivities({
    type: 'assistant',
    message: {
      content: [{
        type: 'tool_use',
        id: 'tool-skill',
        name: 'Skill',
        input: { skill: 'full-output-enforcement', args: 'count to 100000' },
      }],
    },
  }), [{
    id: 'tool-skill',
    kind: 'tool',
    state: 'running',
    toolName: 'Skill',
    detail: 'full-output-enforcement',
  }]);

  assert.deepEqual(extractClaudeActivities({
    type: 'user',
    message: {
      content: [{
        type: 'tool_result',
        tool_use_id: 'tool-1',
        content: 'secret file contents',
      }],
    },
  }), [{ id: 'tool-1', kind: 'tool', state: 'done' }]);

  assert.deepEqual(extractClaudeActivities({
    type: 'result',
    is_error: false,
    duration_ms: 8100,
    num_turns: 2,
    permission_denials: [],
  }), [{
    id: 'summary',
    kind: 'summary',
    state: 'done',
    durationMs: 8100,
    numTurns: 2,
    permissionDenials: 0,
  }]);
});

test('extracts sorted invokable commands from Claude init events', () => {
  assert.deepEqual(extractClaudeCommands({
    type: 'system',
    subtype: 'init',
    slash_commands: ['help', 'compact', 'review'],
    skills: ['review', '/frontend-design', 'review'],
  }), ['compact', 'frontend-design', 'help', 'review']);

  assert.deepEqual(extractClaudeCommands({
    type: 'system',
    subtype: 'init',
    slash_commands: ['/compact'],
  }), ['compact']);

  assert.deepEqual(extractClaudeCommands({
    type: 'system',
    subtype: 'status',
    skills: ['review'],
  }), []);
});

test('extracts the active model without treating billed totals as context fill', () => {
  assert.deepEqual(extractClaudeSessionInfo({
    type: 'system',
    subtype: 'init',
    model: 'claude-opus-4-8',
  }), { model: 'claude-opus-4-8' });

  assert.deepEqual(extractClaudeSessionInfo({
    type: 'result',
    modelUsage: {
      'claude-opus-4-8': {
        inputTokens: 505,
        cacheReadInputTokens: 24576,
        cacheCreationInputTokens: 0,
        outputTokens: 5,
        contextWindow: 200000,
      },
    },
  }), {
    model: 'claude-opus-4-8',
    contextWindow: 200000,
  });
});

test('result usage is ignored because it sums every API turn of the run', () => {
  assert.deepEqual(extractClaudeSessionInfo({
    type: 'result',
    model: 'grok-4.6',
    usage: {
      input_tokens: 51388,
      cache_read_input_tokens: 256,
      cache_creation_input_tokens: 0,
      output_tokens: 113,
    },
    modelUsage: {
      'grok-4.6[1m]': {
        inputTokens: 51388,
        cacheReadInputTokens: 256,
        cacheCreationInputTokens: 0,
        outputTokens: 113,
        contextWindow: 1000000,
      },
    },
  }), {
    model: 'grok-4.6[1m]',
    contextWindow: 1000000,
  });
});

test('zeroed stream-json assistant usage is not treated as remaining context', () => {
  assert.equal(extractClaudeSessionInfo({
    type: 'assistant',
    message: {
      model: 'grok-4.6',
      usage: {
        input_tokens: 0,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0,
        output_tokens: 0,
        context_details: { input_tokens: 0, output_tokens: 0 },
      },
    },
  }), null);
});

test('assistant usage streams live remaining context for the 1M window', () => {
  assert.deepEqual(extractClaudeSessionInfo({
    type: 'assistant',
    message: {
      model: 'claude-sonnet-4-5[1m]',
      usage: {
        input_tokens: 12000,
        cache_read_input_tokens: 640000,
        cache_creation_input_tokens: 2000,
        output_tokens: 900,
      },
    },
  }), {
    model: 'claude-sonnet-4-5[1m]',
    contextWindow: 1000000,
    usedTokens: 654000,
    remainingTokens: 346000,
  });
});

test('merge keeps the 1M window and last-request used tokens', () => {
  assert.deepEqual(mergeClaudeSessionInfo({
    model: 'grok-4.6[1m]',
    contextWindow: 1000000,
  }, {
    model: 'grok-4.6',
    contextWindow: 200000,
    usedTokens: 72737,
    remainingTokens: 127263,
  }), {
    model: 'grok-4.6[1m]',
    contextWindow: 1000000,
    usedTokens: 72737,
    remainingTokens: 927263,
  });
});

test('restores remaining context from the last transcript request', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-session-info-'));
  const projectsDir = join(dir, 'projects');
  const sessionDir = join(projectsDir, 'old-worktree');
  const settingsPath = join(dir, 'settings.json');
  const sessionId = '2c732c81-e207-4de5-856e-2ec4f7f14199';
  try {
    await mkdir(sessionDir, { recursive: true });
    await writeFile(settingsPath, JSON.stringify({
      env: { ANTHROPIC_MODEL: 'claude-opus-4-8' },
    }), 'utf8');
    await writeFile(join(sessionDir, `${sessionId}.jsonl`), [
      JSON.stringify({ type: 'user', sessionId }),
      JSON.stringify({
        type: 'assistant',
        sessionId,
        message: {
          model: 'gpt-5.6-terra',
          usage: {
            input_tokens: 13688,
            cache_read_input_tokens: 11264,
            cache_creation_input_tokens: 0,
          },
        },
      }),
    ].join('\n'), 'utf8');

    assert.deepEqual(await restoreClaudeSessionInfo({
      sessionId,
      projectsDir,
      settingsPath,
      environment: {},
    }), {
      model: 'gpt-5.6-terra',
      contextWindow: 200000,
      usedTokens: 24952,
      remainingTokens: 175048,
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('restores 1M window from cost-state even when message.model omits [1m]', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cc-remote-session-1m-'));
  const projectsDir = join(dir, 'projects');
  const sessionDir = join(projectsDir, 'worktree');
  const settingsPath = join(dir, 'settings.json');
  const sessionId = '13868263-fcb5-46f5-98ba-31084a7c2ed8';
  try {
    await mkdir(sessionDir, { recursive: true });
    await writeFile(settingsPath, '{}', 'utf8');
    await writeFile(join(sessionDir, `${sessionId}.jsonl`), [
      JSON.stringify({
        type: 'assistant',
        isSidechain: false,
        message: {
          model: 'grok-4.6',
          usage: { input_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
        },
      }),
      JSON.stringify({
        type: 'assistant',
        isSidechain: false,
        message: {
          model: 'grok-4.6',
          usage: {
            input_tokens: 59553,
            cache_read_input_tokens: 13184,
            cache_creation_input_tokens: 0,
          },
        },
      }),
      JSON.stringify({
        type: 'cost-state',
        modelUsage: {
          'grok-4.6[1M]': {
            inputTokens: 423201,
            cacheReadInputTokens: 52992,
            cacheCreationInputTokens: 0,
          },
        },
      }),
    ].join('\n'), 'utf8');

    assert.deepEqual(await restoreClaudeSessionInfo({
      sessionId,
      projectsDir,
      settingsPath,
      environment: {},
    }), {
      model: 'grok-4.6[1M]',
      contextWindow: 1000000,
      usedTokens: 72737,
      remainingTokens: 927263,
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('normalizes permission control requests and builds one-time decisions', () => {
  const request = extractClaudePermissionRequest({
    type: 'control_request',
    request_id: 'permission-1',
    request: {
      subtype: 'can_use_tool',
      tool_name: 'Bash',
      input: { command: 'npm test', description: 'Run tests' },
      title: 'Run command',
      display_name: 'Bash',
      description: 'Run the project tests',
    },
  });

  assert.deepEqual(request, {
    requestId: 'permission-1',
    toolName: 'Bash',
    input: { command: 'npm test', description: 'Run tests' },
    detail: 'npm test',
    title: 'Run command',
    displayName: 'Bash',
    description: 'Run the project tests',
    decisionReason: undefined,
  });
  assert.deepEqual(permissionControlResponse(request!, 'allow'), {
    type: 'control_response',
    response: {
      subtype: 'success',
      request_id: 'permission-1',
      response: {
        behavior: 'allow',
        updatedInput: { command: 'npm test', description: 'Run tests' },
      },
    },
  });
  assert.deepEqual(permissionControlResponse(request!, 'deny'), {
    type: 'control_response',
    response: {
      subtype: 'success',
      request_id: 'permission-1',
      response: {
        behavior: 'deny',
        message: '用户在手机端拒绝了这个操作',
        interrupt: false,
      },
    },
  });
});
