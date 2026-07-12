import assert from 'node:assert/strict';
import test from 'node:test';
import {
  ClaudeBridge,
  extractClaudeActivities,
  extractClaudeCommands,
  extractClaudePermissionRequest,
  extractClaudeSessionInfo,
  isMissingConversationError,
  permissionControlResponse,
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

test('detects stale Claude Code session errors', () => {
  assert.equal(
    isMissingConversationError('Error: No conversation found with session ID: cc8a61d2-6548-4527-b29f-7bc3d2b8aa6b'),
    true,
  );
  assert.equal(isMissingConversationError('Some other Claude error'), false);
});

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
  }), ['frontend-design', 'review']);

  assert.deepEqual(extractClaudeCommands({
    type: 'system',
    subtype: 'status',
    skills: ['review'],
  }), []);
});

test('extracts the active model and exact remaining context', () => {
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
    usedTokens: 25081,
    remainingTokens: 174919,
  });
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
