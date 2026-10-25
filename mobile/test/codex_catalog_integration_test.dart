import 'dart:async';
import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/data/websocket_client.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/model_preference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'websocket_client_test.dart' show FakeWebSocketChannel;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'App loads Codex catalogs, sends its model, and discards stale commands',
    (tester) async {
      final channel = FakeWebSocketChannel();
      final ws = RemoteWebSocketClient(connect: (_) => channel);
      addTearDown(ws.close);
      final commandResponses = <Completer<http.Response>>[];
      final requestedSessions = <String>[];
      final api = RemoteApiClient(
        client: MockClient((request) async {
          expectSync(request.headers['Authorization'], 'Bearer test-token');
          switch (request.url.path) {
            case '/api/status':
              return response({
                'deviceName': 'Test host',
                'workspaceDir': '/workspace/project',
                'running': false,
              });
            case '/api/models':
              expectSync(
                request.url.queryParameters['sessionId'],
                'codex-session',
              );
              return response({
                'sessionId': 'codex-session',
                'engine': 'codex',
                'models': [
                  {'model': 'gpt-test-codex', 'displayName': 'Test model'},
                ],
              });
            case '/api/commands':
              requestedSessions.add(request.url.queryParameters['sessionId']!);
              final pending = Completer<http.Response>();
              commandResponses.add(pending);
              return pending.future;
            default:
              return response({});
          }
        }),
      );
      await TokenStore().save(
        SavedSession(
          origin: Uri.parse('https://example.test'),
          token: 'test-token',
          deviceName: 'Test host',
          workspaceDir: '/workspace/project',
        ),
      );
      await tester.pumpWidget(
        CcRemoteApp(enableCamera: false, wsClient: ws, apiClient: api),
      );
      await tester.pump();
      await tester.pump();
      channel.incoming.add(
        jsonEncode({
          'type': 'status',
          'authenticated': true,
          'running': false,
          'sessionId': 'codex-session',
          'engine': 'codex',
        }),
      );
      channel.incoming.add(jsonEncode(catalog('codex-session')));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(DemoShell));
      expect(state.activeSessionEngine, SessionEngine.codex);
      await tester.tap(find.byKey(const ValueKey('composer-model-button')));
      await tester.pumpAndSettle();
      expect(find.text('选择 Codex 模型'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('codex-model-option-gpt-test-codex')),
      );
      await tester.pumpAndSettle();
      expect(await CodexModelPreferenceStore().load(), 'gpt-test-codex');
      expect(state.commandsSessionId, isNull);
      expect(state.activeSessionId, 'codex-session');

      await tester.enterText(find.byType(TextField).first, '/');
      await tester.pump();
      expect(state.promptController.text, '/');
      expect(state.commandsSessionId, 'codex-session');
      expect(state.commandsFailed, isFalse);
      expect(state.commandsLoading, isTrue);
      expect(requestedSessions, ['codex-session']);
      expect(find.text('正在获取指令'), findsOneWidget);
      channel.incoming.add(jsonEncode(catalog('codex-session')));
      await tester.pump();
      commandResponses[0].complete(
        response({
          'sessionId': 'codex-session',
          'engine': 'codex',
          'commands': ['inspect'],
        }),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('inspect'));
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.pump();
      final sent = channel.sent
          .map((item) => jsonDecode(item as String))
          .where((item) => item['type'] == 'prompt')
          .last;
      expect(sent['text'], '/inspect');
      expect(sent['model'], 'gpt-test-codex');
      expect(sent['sandboxMode'], 'danger-full-access');

      channel.incoming.add(
        jsonEncode({'type': 'done', 'sessionId': 'codex-session'}),
      );
      await tester.pump();
      state.promptController.text = '/';
      final Future<void> oldRefresh = state.refreshCommandCatalog();
      await tester.pump();
      await tester.pump();
      channel.incoming.add(jsonEncode(catalog('other-session')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(state.activeSessionId, 'other-session');
      expect(state.promptController.text, isEmpty);
      expect(requestedSessions, ['codex-session', 'codex-session']);
      await tester.enterText(find.byType(TextField).first, '/');
      await tester.pump();
      expect(requestedSessions, [
        'codex-session',
        'codex-session',
        'other-session',
      ]);
      commandResponses[2].complete(
        response({
          'sessionId': 'other-session',
          'engine': 'codex',
          'commands': ['new-skill'],
        }),
      );
      await tester.pump();
      commandResponses[1].complete(
        response({
          'sessionId': 'codex-session',
          'engine': 'codex',
          'commands': ['stale-skill'],
        }),
      );
      await tester.pump();
      await oldRefresh;
      expect(state.commands, ['new-skill']);
      expect(state.commandsLoading, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

http.Response response(Map<String, Object> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object> catalog(String sessionId) => {
  'type': 'catalog',
  'activeProjectId': 'project',
  'activeSessionId': sessionId,
  'projects': [
    {
      'id': 'project',
      'name': 'Project',
      'path': '/workspace/project',
      'sessionCount': 2,
      'running': false,
    },
  ],
  'sessions': [
    for (final id in ['codex-session', 'other-session'])
      {
        'id': id,
        'projectId': 'project',
        'title': id,
        'engine': 'codex',
        'updatedAt': 1,
        'messageCount': 0,
        'running': false,
      },
  ],
};
