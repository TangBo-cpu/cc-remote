import 'dart:async';
import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/websocket_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'session_mutation_test.dart' show boot, catalog, response;
import 'websocket_client_test.dart' show FakeWebSocketChannel;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final changeSession in [false, true]) {
    testWidgets('workspace read bounds retries with session change $changeSession', (
      tester,
    ) async {
      var reads = 0;
      await http.runWithClient(
        () async {
          final dynamic state = await boot(
            tester,
            RemoteApiClient(client: MockClient((_) async => response({}))),
          );
          final Future<dynamic> reading = state.readWorkspaceSnapshot(state.session);
          await tester.pump();
          expect(reads, 1);
          if (changeSession) {
            state.handleWsMessage({'type': 'catalog', ...catalog('b')});
          }
          await tester.pump(const Duration(seconds: 1));
          expect(await reading, isNull);
          expect(reads, changeSession ? 1 : 2);
          await tester.pump(const Duration(seconds: 1));
          expect(reads, changeSession ? 1 : 2);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          expectSync(request.url.path, '/api/workspace');
          reads++;
          return response({'error': 'workspace_failed'}, 503);
        }),
      );
    });
  }

  for (final (completion, failedRead) in [
    ('done', 0),
    ('status', 0),
    ('transcript_snapshot', 0),
    ('http_status', 0),
    ('done', 1),
    ('done', 2),
  ]) {
    testWidgets('workspace echo after $completion with failed read $failedRead', (
      tester,
    ) async {
      var version = 0;
      var snapshots = 0;
      await http.runWithClient(
        () async {
          late FakeWebSocketChannel channel;
          final ws = RemoteWebSocketClient(
            connect: (_) => channel = FakeWebSocketChannel(),
            reconnectDelays: const [Duration(milliseconds: 100)],
          );
          final api = RemoteApiClient(
            client: MockClient((request) async {
              expectSync(request.url.path, '/api/status');
              return response({
                'running': false,
                'workspaceDir': '/workspace/project',
                'catalog': catalog('a'),
              });
            }),
          );
          final dynamic state = await boot(tester, api, wsClient: ws);
          state.connectWs(state.session);
          await tester.pump();
          channel.incoming.add(
            jsonEncode({
              'type': 'status',
              'sessionId': 'a',
              'authenticated': true,
              'running': false,
            }),
          );
          await tester.pumpAndSettle();
          expect(ws.isAuthenticated, isTrue);

          for (var turn = 0; turn < 3; turn++) {
            await tester.enterText(find.byType(TextField), 'turn $turn');
            await tester.pump();
            await tester.tap(find.byTooltip('发送'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            if (failedRead == 1) {
              await tester.pump(const Duration(seconds: 1));
            }
            expect(state.running, isTrue, reason: 'turn $turn');
            expect(
              state.workspaceChangeBaseline,
              isNotNull,
              reason: 'baseline turn $turn; snapshots $snapshots',
            );
            final prompt = channel.sent
                .map((item) => jsonDecode(item as String) as Map)
                .lastWhere((item) => item['type'] == 'prompt');
            channel.incoming.add(
              jsonEncode({
                'type': 'prompt_accepted',
                'sessionId': 'a',
                'promptId': prompt['promptId'],
              }),
            );
            expect(
              find.byKey(const ValueKey('workspace-change-echo')),
              findsNothing,
            );

            if (turn != 1) version++;
            if (completion == 'done') {
              channel.incoming.add(
                jsonEncode({'type': 'done', 'sessionId': 'a', 'exitCode': 0}),
              );
            } else {
              unawaited(channel.incoming.close());
              await tester.pump();
              expect(state.remoteOffline, isTrue);
              expect(state.running, isTrue);
              await tester.pump(const Duration(milliseconds: 110));
              if (completion == 'http_status') {
                await state.refreshConnection();
              } else {
                channel.incoming.add(
                  jsonEncode({
                    'type': 'status',
                    'sessionId': 'a',
                    'authenticated': true,
                    'running': completion == 'transcript_snapshot',
                  }),
                );
                await tester.pump();
                if (completion == 'transcript_snapshot') {
                  channel.incoming.add(
                    jsonEncode({
                      'type': 'transcript_snapshot',
                      'sessionId': 'a',
                      'version': 1,
                      'revision': turn + 1,
                      'running': false,
                      'messages': [
                        {'role': 'user', 'text': 'turn $turn'},
                        {'role': 'assistant', 'text': '已完成修改'},
                      ],
                      'pendingPermissions': [],
                    }),
                  );
                }
              }
            }
            await tester.pumpAndSettle();
            if (failedRead == 2) {
              await tester.pump(const Duration(seconds: 1));
              await tester.pumpAndSettle();
            }
            expect(state.running, isFalse);
            final expectedReads = (turn + 1) * 2 + (failedRead > 0 ? 1 : 0);
            expect(snapshots, expectedReads, reason: 'turn $turn');
            expect(state.workspaceChangeBaseline, isNotNull);
            expect(
              state.workspaceChangeEcho?.paths,
              turn == 1 ? isNull : ['app.dart'],
            );
            expect(
              find.byKey(const ValueKey('workspace-change-echo')),
              turn == 1 ? findsNothing : findsOneWidget,
            );
            if (turn != 1) {
              expect(find.text('改了 app.dart'), findsOneWidget);
              expect(find.text('改了 2 个文件'), findsNothing);
            }
            channel.incoming.add(
              jsonEncode({
                'type': 'status',
                'sessionId': 'a',
                'authenticated': true,
                'running': false,
              }),
            );
            channel.incoming.add(
              jsonEncode({
                'type': 'transcript_snapshot',
                'sessionId': 'a',
                'version': 1,
                'revision': turn + 1,
                'running': false,
                'messages': [
                  {'role': 'user', 'text': 'turn $turn'},
                  {'role': 'assistant', 'text': '已完成修改'},
                ],
                'pendingPermissions': [],
              }),
            );
            await tester.pumpAndSettle();
            expect(snapshots, expectedReads, reason: 'duplicate completion');
          }

          expect(snapshots, failedRead > 0 ? 7 : 6);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          expectSync(request.url.path, '/api/workspace');
          snapshots++;
          if (snapshots == failedRead) {
            return response({'error': 'temporary_workspace_failure'}, 503);
          }
          return response({
            'rootName': 'project',
            'gitAvailable': true,
            'files': ['old.txt', 'app.dart'],
            'changes': [
              {'path': 'old.txt', 'unstaged': 'M', 'fingerprint': 'unchanged'},
              {
                'path': 'app.dart',
                'unstaged': 'M',
                'fingerprint': 'version-$version',
              },
            ],
          });
        }),
      );
    });
  }
}
