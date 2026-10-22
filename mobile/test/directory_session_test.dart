import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/directory_picker.dart';
import 'package:cc_remote/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> catalog({bool newSession = false}) => {
  'version': 1,
  'activeProjectId': newSession ? 'new-project' : 'old-project',
  'activeSessionId': newSession ? 'new-session' : 'old-session',
  'projects': [
    {'id': 'old-project', 'name': 'old', 'path': '/projects/old'},
    if (newSession)
      {'id': 'new-project', 'name': 'new', 'path': '/projects/new'},
  ],
  'sessions': [
    {
      'id': 'old-session',
      'projectId': 'old-project',
      'title': '旧对话',
      'engine': 'claude',
    },
    if (newSession)
      {
        'id': 'new-session',
        'projectId': 'new-project',
        'title': '新对话',
        'engine': 'codex',
      },
  ],
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
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
    workspaceDir: '/projects/old',
  );
  state.route = ShellRoute.chat;
  state.applyCatalog(RemoteProjectCatalog.tryParse(catalog()));
  state.messages.add(TranscriptMessage.assistant('旧对话内容'));
  state.promptController.text = '保留这段草稿';
  state.handleWsMessage(
    jsonEncode({
      'type': 'status',
      'sessionId': 'old-session',
      'authenticated': true,
      'running': false,
    }),
  );
  await tester.pumpAndSettle();
  state.openSessions();
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('create-session')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('open-computer-directory')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('directory-path-input')),
    '/projects/new',
  );
  await tester.tap(find.byKey(const ValueKey('directory-path-open')));
  await tester.pumpAndSettle();
  return state;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final wsFirst in [false, true]) {
    testWidgets(
      'directory switch retains draft and handles WS-first=$wsFirst',
      (tester) async {
        dynamic state;
        var requests = 0;
        final api = RemoteApiClient(
          client: MockClient((request) async {
            if (request.url.path == '/api/directories') {
              return jsonResponse({
                'path': request.url.queryParameters['path'],
                'parentPath': null,
                'roots': [],
                'directories': [],
                'truncated': false,
              });
            }
            if (request.url.path == '/api/projects/open-directory') {
              requests++;
              expect(jsonDecode(request.body), {
                'path': '/projects/new',
                'engine': 'codex',
              });
              if (wsFirst) {
                state.handleWsMessage(
                  jsonEncode({'type': 'catalog', ...catalog(newSession: true)}),
                );
                state.handleWsMessage(
                  jsonEncode({
                    'type': 'transcript_snapshot',
                    'sessionId': 'new-session',
                    'engine': 'codex',
                    'version': 1,
                    'revision': 1,
                    'running': false,
                    'messages': [TranscriptMessage.system('新会话快照已同步').toJson()],
                    'pendingPermissions': [],
                  }),
                );
              }
              return jsonResponse({
                'ok': true,
                'catalog': catalog(newSession: true),
              }, 201);
            }
            return jsonResponse({});
          }),
        );
        state = await boot(tester, api);
        await tester.tap(find.byKey(const ValueKey('directory-engine-codex')));
        await tester.tap(
          find.byKey(const ValueKey('directory-create-session')),
        );
        await tester.pumpAndSettle();
        expect(requests, 1);
        expect(find.byType(DirectoryPickerPage), findsNothing);
        expect(state.activeSessionId, 'new-session');
        expect(state.session.workspaceDir, '/projects/new');
        expect(state.activeSessionEngine, SessionEngine.codex);
        expect(state.promptController.text, isEmpty);
        expect(
          state.sessionMemoryStore.forSession('old-session').draft.text,
          '保留这段草稿',
        );
        expect(state.remoteSessions.length, 2);
        expect(
          (state.messages as List).any((message) => message.text == '旧对话内容'),
          isFalse,
        );
        if (wsFirst) expect(find.text('新会话快照已同步'), findsOneWidget);
        await state.lastTranscriptWrite;
        expect((await TokenStore().load())!.workspaceDir, '/projects/new');
        expect((await TranscriptStore().load())!.sessionId, 'new-session');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'failed directory creation leaves the original chat and draft intact',
    (tester) async {
      final api = RemoteApiClient(
        client: MockClient((request) async {
          if (request.url.path == '/api/projects/open-directory') {
            return jsonResponse({'error': 'directory_access_denied'}, 403);
          }
          return jsonResponse({
            'path': request.url.queryParameters['path'],
            'parentPath': null,
            'roots': [],
            'directories': [],
            'truncated': false,
          });
        }),
      );
      final dynamic state = await boot(tester, api);
      await tester.tap(find.byKey(const ValueKey('directory-create-session')));
      await tester.pumpAndSettle();
      expect(find.byType(DirectoryPickerPage), findsOneWidget);
      expect(state.activeSessionId, 'old-session');
      expect(state.session.workspaceDir, '/projects/old');
      expect(state.promptController.text, '保留这段草稿');
      expect(state.messages.single.text, '旧对话内容');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('live app task state updates directory creation availability', (
    tester,
  ) async {
    final api = RemoteApiClient(
      client: MockClient(
        (request) async => jsonResponse({
          'path': request.url.queryParameters['path'],
          'parentPath': null,
          'roots': [],
          'directories': [],
          'truncated': false,
        }),
      ),
    );
    final dynamic state = await boot(tester, api);
    final button = find.byKey(const ValueKey('directory-create-session'));
    state.handleWsMessage(
      jsonEncode({
        'type': 'status',
        'sessionId': 'old-session',
        'authenticated': true,
        'running': true,
      }),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    state.handleWsMessage(
      jsonEncode({
        'type': 'status',
        'sessionId': 'old-session',
        'authenticated': true,
        'running': false,
      }),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await state.lastTranscriptWrite;
    await tester.pumpWidget(const SizedBox());
  });
}
