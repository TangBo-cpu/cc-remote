import 'dart:async';
import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/data/websocket_client.dart';
import 'package:cc_remote/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> catalog(String active, {bool deleted = false}) => {
  'activeProjectId': 'project',
  'activeSessionId': active,
  'projects': [
    {'id': 'project', 'name': 'project', 'path': '/workspace/project'},
  ],
  'sessions': [
    for (final id in ['a', 'b', 'c'])
      if (!deleted || id != 'b')
        {'id': id, 'projectId': 'project', 'title': id, 'engine': 'codex'},
  ],
};

http.Response response(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<dynamic> boot(
  WidgetTester tester,
  RemoteApiClient api, {
  RemoteWebSocketClient? wsClient,
}) async {
  await tester.pumpWidget(
    CcRemoteApp(enableCamera: false, apiClient: api, wsClient: wsClient),
  );
  await tester.pumpAndSettle();
  final dynamic state = tester.state(find.byType(DemoShell));
  state.session = SavedSession(
    origin: Uri.parse('https://example.test'),
    token: 'test-token',
    deviceName: 'Test host',
  );
  state.route = ShellRoute.chat;
  state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('a')}));
  state.handleWsMessage(
    jsonEncode({
      'type': 'status',
      'sessionId': 'a',
      'authenticated': true,
      'running': false,
    }),
  );
  await tester.pumpAndSettle();
  return state;
}

Future<void> mutate(dynamic state, String operation) async {
  switch (operation) {
    case 'create':
      await state.createRemoteSession('project', SessionEngine.codex);
    case 'rename':
      await state.renameRemoteSession('b', 'renamed');
    case 'archive':
      await state.archiveRemoteSession('b');
    case 'delete':
      await state.deleteRemoteSession('b');
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'archived history opens read-only without changing the active draft',
    (tester) async {
      final api = RemoteApiClient(
        client: MockClient(
          (_) async => response({
            'projectId': 'project',
            'sessionId': 'archived',
            'title': 'Archive',
            'archived': true,
            'transcript': {
              'version': 1,
              'revision': 1,
              'running': false,
              'messages': [
                {'role': 'assistant', 'text': 'archived reply'},
              ],
              'pendingPermissions': [],
            },
          }),
        ),
      );
      final dynamic state = await boot(tester, api);
      state.remoteSessions.add(
        const RemoteSessionSummary(
          id: 'archived',
          projectId: 'project',
          title: 'Archive',
          updatedAt: 1,
          running: false,
          messageCount: 1,
          archived: true,
        ),
      );
      state.promptController.text = 'keep draft';
      expect(state.selectRemoteSessionWithJump('archived'), true);
      await tester.pumpAndSettle();
      expect(state.activeSessionId, 'a');
      expect(state.viewingSessionId, 'archived');
      expect(state.peekMessages.single.text, 'archived reply');
      expect(state.promptController.text, 'keep draft');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'session metadata ignores an old host response and preserves current state',
    (tester) async {
      final pending = Completer<http.Response>();
      final api = RemoteApiClient(client: MockClient((_) => pending.future));
      final dynamic state = await boot(tester, api);
      final Future<void> mutation = state.updateSessionMetadata(
        'b',
        'pin',
        pinned: true,
      );
      final expected = expectLater(mutation, throwsStateError);
      state.session = SavedSession(
        origin: Uri.parse('https://new-host.test'),
        token: 'new-token',
        deviceName: 'New host',
      );
      state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('c')}));
      pending.complete(response(catalog('a'), 401));
      await expected;
      await tester.pumpAndSettle();
      expect(state.activeSessionId, 'c');
      expect(state.session.token, 'new-token');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final (failedSelection, wsFirst) in [
    (true, false),
    (false, false),
    (true, true),
    (false, true),
  ]) {
    testWidgets(
      'create supersedes a previous selection, failed-selection=$failedSelection, WS-first=$wsFirst',
      (tester) async {
        dynamic state;
        final selection = Completer<http.Response>();
        final created = catalog('created');
        (created['sessions'] as List).add({
          'id': 'created',
          'projectId': 'project',
          'title': '新对话',
          'engine': 'codex',
        });
        final api = RemoteApiClient(
          client: MockClient((request) async {
            if (request.url.path == '/api/sessions/b/select') {
              return selection.future;
            }
            if (request.url.path == '/api/projects/project/sessions') {
              if (wsFirst) {
                state.handleWsMessage({'type': 'catalog', ...created});
                state.handleWsMessage({
                  'type': 'transcript_snapshot',
                  'sessionId': 'created',
                  'version': 1,
                  'revision': 1,
                  'running': false,
                  'messages': [
                    TranscriptMessage.assistant('新会话快照已同步').toJson(),
                  ],
                  'pendingPermissions': [],
                });
              }
              return response({'catalog': created}, 201);
            }
            return response({});
          }),
        );
        state = await boot(tester, api);
        state.messages.add(TranscriptMessage.assistant('原会话内容'));
        state.promptController.text = '保留草稿';
        expect(state.selectRemoteSessionWithJump('b'), isTrue);
        await tester.pump();
        if (failedSelection) {
          selection.complete(response({'error': 'select_failed'}, 500));
          await tester.pumpAndSettle();
          expect(state.peekFailed, isTrue);
        }
        expect(state.selectingSessionId, 'b');

        await state.createRemoteSession('project', SessionEngine.codex);
        await tester.pumpAndSettle();
        expect(state.activeSessionId, 'created');
        expect(state.selectingSessionId, isNull);
        expect(state.viewingSessionId, isNull);
        expect(state.promptController.text, isEmpty);
        expect(state.sessionMemoryStore.forSession('a').draft.text, '保留草稿');
        expect(
          state.messages.map((dynamic message) => message.text).toList(),
          wsFirst ? ['新会话快照已同步'] : isEmpty,
        );

        if (!failedSelection) {
          selection.complete(
            response({
              ...catalog('b'),
              'transcript': {
                'version': 1,
                'revision': 1,
                'running': false,
                'messages': [TranscriptMessage.assistant('旧请求的回复').toJson()],
                'pendingPermissions': [],
              },
            }),
          );
          await tester.pumpAndSettle();
          await state.sessionSelectionOperation;
          expect(state.activeSessionId, 'created');
          expect(
            state.messages.map((dynamic message) => message.text).toList(),
            wsFirst ? ['新会话快照已同步'] : isEmpty,
          );
        }
        await state.lastTranscriptWrite;
        expect((await TranscriptStore().load())!.sessionId, 'created');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  for (final operation in ['create', 'rename', 'archive', 'delete']) {
    testWidgets(
      '$operation ignores an HTTP catalog after a newer WS selection',
      (tester) async {
        final pending = Completer<http.Response>();
        final api = RemoteApiClient(client: MockClient((_) => pending.future));
        final dynamic state = await boot(tester, api);
        state.sessionMemoryStore.forSession('b').draft = const TextEditingValue(
          text: 'deleted draft',
        );
        final Future<void> mutation = mutate(state, operation);
        await tester.pump();
        state.handleWsMessage(
          jsonEncode({'type': 'catalog', ...catalog('c', deleted: true)}),
        );
        state.handleWsMessage(
          jsonEncode({
            'type': 'transcript_snapshot',
            'sessionId': 'c',
            'version': 1,
            'revision': 1,
            'running': false,
            'messages': [TranscriptMessage.assistant('current reply').toJson()],
            'pendingPermissions': [],
          }),
        );
        state.promptController.text = 'current draft';
        pending.complete(
          response(
            operation == 'create'
                ? {'catalog': catalog('b')}
                : catalog('a', deleted: operation == 'delete'),
            operation == 'create' ? 201 : 200,
          ),
        );
        await mutation;
        await tester.pumpAndSettle();

        expect(state.activeSessionId, 'c');
        expect(state.messages.single.text, 'current reply');
        expect(state.promptController.text, 'current draft');
        if (operation == 'delete') {
          expect(state.sessionMemoryStore.forSession('b').draft.text, isEmpty);
        }
        await state.lastTranscriptWrite;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('$operation ignores an old connection response', (
      tester,
    ) async {
      for (final status in [200, 401, 500]) {
        final pending = Completer<http.Response>();
        final api = RemoteApiClient(client: MockClient((_) => pending.future));
        final dynamic state = await boot(tester, api);
        final Future<void> mutation = mutate(state, operation);
        await tester.pump();
        state.session = SavedSession(
          origin: Uri.parse('https://new-host.test'),
          token: 'new-token',
          deviceName: 'New host',
        );
        state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('c')}));
        state.messages.add(TranscriptMessage.assistant('new host reply'));
        state.sessionMemoryStore.forSession('b').draft = const TextEditingValue(
          text: 'new host draft',
        );
        pending.complete(
          response(
            operation == 'create' ? {'catalog': catalog('b')} : catalog('a'),
            operation == 'create' && status == 200 ? 201 : status,
          ),
        );
        await mutation;
        await tester.pumpAndSettle();

        expect(state.session.origin.host, 'new-host.test');
        expect(state.activeSessionId, 'c');
        expect(state.messages.single.text, 'new host reply');
        expect(
          state.sessionMemoryStore.forSession('b').draft.text,
          'new host draft',
        );
        await state.lastTranscriptWrite;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('new conversation clears a failed selection from the header', (
    tester,
  ) async {
    final api = RemoteApiClient(
      client: MockClient(
        (request) async => request.url.path == '/api/new-conversation'
            ? response({'sessionId': 'c', 'engine': 'codex'})
            : response({'error': 'select_failed'}, 500),
      ),
    );
    final dynamic state = await boot(tester, api);
    state.promptController.text = '保留草稿';
    expect(state.selectRemoteSessionWithJump('b'), isTrue);
    await tester.pumpAndSettle();
    expect(state.peekFailed, isTrue);
    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-engine-codex')));
    await tester.pumpAndSettle();
    expect(state.activeSessionId, 'c');
    expect(state.selectingSessionId, isNull);
    expect(state.viewingSessionId, isNull);
    expect(state.sessionMemoryStore.forSession('a').draft.text, '保留草稿');
    await state.lastTranscriptWrite;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('create does not cancel a newer pending selection', (
    tester,
  ) async {
    final creation = Completer<http.Response>();
    final selection = Completer<http.Response>();
    final api = RemoteApiClient(
      client: MockClient((request) async {
        if (request.url.path == '/api/projects/project/sessions') {
          return creation.future;
        }
        if (request.url.path == '/api/sessions/c/select') {
          return selection.future;
        }
        return response({});
      }),
    );
    final dynamic state = await boot(tester, api);
    final Future<void> creating = state.createRemoteSession(
      'project',
      SessionEngine.codex,
    );
    await tester.pump();
    expect(state.selectRemoteSessionWithJump('c'), isTrue);
    await tester.pump();
    creation.complete(response({'catalog': catalog('b')}, 201));
    await creating;
    await tester.pump();
    expect(state.activeSessionId, 'a');
    expect(state.selectingSessionId, 'c');

    selection.complete(
      response({
        ...catalog('c'),
        'transcript': {
          'version': 1,
          'revision': 1,
          'running': false,
          'messages': [TranscriptMessage.assistant('新的选择').toJson()],
          'pendingPermissions': [],
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(state.activeSessionId, 'c');
    expect(state.messages.single.text, '新的选择');
    await state.lastTranscriptWrite;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('delete applies an HTTP-only catalog and clears deleted memory', (
    tester,
  ) async {
    final api = RemoteApiClient(
      client: MockClient((_) async => response(catalog('c', deleted: true))),
    );
    final dynamic state = await boot(tester, api);
    state.sessionMemoryStore.forSession('b').draft = const TextEditingValue(
      text: 'deleted draft',
    );
    await state.deleteRemoteSession('b');
    await tester.pumpAndSettle();

    expect(state.activeSessionId, 'c');
    expect(state.remoteSessions.any((item) => item.id == 'b'), isFalse);
    expect(state.sessionMemoryStore.forSession('b').draft.text, isEmpty);
    await state.lastTranscriptWrite;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
