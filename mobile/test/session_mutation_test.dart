import 'dart:async';
import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/remote_models.dart';
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

Future<dynamic> boot(WidgetTester tester, RemoteApiClient api) async {
  await tester.pumpWidget(CcRemoteApp(enableCamera: false, apiClient: api));
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
