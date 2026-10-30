import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/native_session_api.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/effort_preference.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/native_session_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> catalog({bool imported = false}) => {
  'version': 1,
  'activeProjectId': 'project',
  'activeSessionId': imported ? 'imported' : 'original',
  'projects': [
    {'id': 'project', 'name': 'project', 'path': '/project'},
  ],
  'sessions': [
    {
      'id': 'original',
      'projectId': 'project',
      'title': '手机会话',
      'engine': 'codex',
    },
    if (imported)
      {
        'id': 'imported',
        'projectId': 'project',
        'title': '电脑会话',
        'engine': 'codex',
      },
  ],
};

Map<String, Object?> transcript() => {
  'type': 'transcript_snapshot',
  'sessionId': 'imported',
  'engine': 'codex',
  'version': 1,
  'revision': 2,
  'running': false,
  'pendingPermissions': [],
  'messages': [
    {'role': 'user', 'text': '电脑问题'},
    {'role': 'assistant', 'text': '电脑回复'},
  ],
};

http.Response response(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'missing directory keeps its recovery message instead of an upgrade prompt',
    () {
      final api = NativeSessionApi(
        client: RemoteApiClient(client: MockClient((_) async => response({}))),
        origin: Uri.parse('https://example.test'),
        token: 'test',
      );
      addTearDown(api.client.close);
      expect(
        () => api.decode(
          http.Response(jsonEncode({'error': 'directory_not_found'}), 404),
        ),
        throwsA(
          isA<NativeSessionException>().having(
            (error) => error.code,
            'code',
            'directory_not_found',
          ),
        ),
      );
      expect(
        () =>
            api.decode(http.Response(jsonEncode({'error': 'not_found'}), 404)),
        throwsA(
          isA<NativeSessionException>().having(
            (error) => error.code,
            'code',
            'native_sessions_unavailable',
          ),
        ),
      );
    },
  );

  for (final wsFirst in [false, true]) {
    testWidgets(
      'syncs one desktop session and preserves drafts with WS-first=$wsFirst',
      (tester) async {
        dynamic state;
        var syncRequests = 0;
        final api = RemoteApiClient(
          client: MockClient((request) async {
            if (request.url.path == '/api/native-sessions') {
              expect(request.url.queryParameters['engine'], 'codex');
              return response({
                'sessions': [
                  for (final id in ['other-thread', 'desktop-thread'])
                    {
                      'sessionId': id,
                      'engine': 'codex',
                      'title': id == 'desktop-thread' ? '电脑会话' : '其他会话',
                      'workspaceDir': '/project',
                      'updatedAt': 1000,
                    },
                ],
                'nextCursor': null,
                'maxSessionBytes': 2 * 1024 * 1024,
              });
            }
            if (request.url.path == '/api/native-sessions/sync') {
              syncRequests++;
              expect(jsonDecode(request.body), {
                'engine': 'codex',
                'sessionId': 'desktop-thread',
              });
              if (wsFirst) {
                state.handleWsMessage(
                  jsonEncode({'type': 'catalog', ...catalog(imported: true)}),
                );
                state.handleWsMessage(jsonEncode(transcript()));
              }
              return response({
                'catalog': catalog(imported: true),
                'transcript': transcript(),
              });
            }
            return response({});
          }),
        );
        await tester.pumpWidget(
          CcRemoteApp(enableCamera: false, apiClient: api),
        );
        await tester.pumpAndSettle();
        state = tester.state(find.byType(DemoShell));
        state.session = SavedSession(
          origin: Uri.parse('https://example.test'),
          token: 'test',
          deviceName: 'host',
        );
        state.route = ShellRoute.chat;
        state.applyCatalog(RemoteProjectCatalog.tryParse(catalog()));
        state.messages.add(TranscriptMessage.assistant('原会话内容'));
        state.promptController.text = '保留草稿';
        state.selectedEffort = ClaudeEffortPreference.max;
        state.handleWsMessage(
          jsonEncode({
            'type': 'status',
            'sessionId': 'original',
            'authenticated': true,
            'running': false,
          }),
        );
        await tester.pumpAndSettle();
        state.openSessions();
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('open-native-session-picker')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NativeSessionPickerPage), findsOneWidget);
        expect(find.text('超过 2 MB 或无法读取的会话已过滤。'), findsOneWidget);
        final button = find.byKey(const ValueKey('sync-native-session'));
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        await tester.tap(
          find.byKey(const ValueKey('native-session-other-thread')),
        );
        await tester.tap(
          find.byKey(const ValueKey('native-session-desktop-thread')),
        );
        await tester.pump();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(syncRequests, 1);
        expect(find.byType(NativeSessionPickerPage), findsNothing);
        expect(state.activeSessionId, 'imported');
        expect(state.remoteSessions.length, 2);
        expect(state.messages.map((dynamic message) => message.text).toList(), [
          '电脑问题',
          '电脑回复',
        ]);
        expect(
          state.sessionMemoryStore.forSession('original').draft.text,
          '保留草稿',
        );
        expect(state.promptController.text, isEmpty);
        expect(state.selectedEffort, ClaudeEffortPreference.automatic);
        await state.lastTranscriptWrite;
        expect((await TranscriptStore().load())!.sessionId, 'imported');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
