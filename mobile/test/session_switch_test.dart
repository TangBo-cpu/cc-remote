import 'dart:async';
import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/websocket_client.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/session_interaction.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'session_mutation_test.dart' show boot, catalog, response;
import 'websocket_client_test.dart' show FakeWebSocketChannel;

Map<String, Object?> transcript(String id) => {
  'type': 'transcript_snapshot',
  'sessionId': id,
  'version': 1,
  'revision': 1,
  'running': false,
  'messages': [
    {'role': 'assistant', 'text': 'reply $id'},
  ],
  'pendingPermissions': [],
};

Map<String, Object?> selection(String id) => {
  ...catalog(id),
  'transcript': transcript(id),
};

Map<String, Object?> view(String id, {int revision = 1}) => {
  'sessionId': id,
  'projectId': 'project',
  'title': 'session $id',
  'transcript': {...transcript(id), 'revision': revision},
};

MockClient selectionClient(
  Future<http.Response> Function(http.Request) select,
) => MockClient((request) {
  if (request.method == 'GET' && request.url.queryParameters['cached'] == '1') {
    return Future.value(response(view(request.url.pathSegments.last)));
  }
  return select(request);
});

Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'switch feedback fits a narrow phone with large text in both themes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController(text: 'keep draft');
      addTearDown(controller.dispose);
      for (final brightness in Brightness.values) {
        for (final failed in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildSignalConsoleTheme(brightness),
              home: MediaQuery(
                data: const MediaQueryData(
                  textScaler: TextScaler.linear(1.8),
                  disableAnimations: true,
                ),
                child: AppBackground(
                  child: ChatScreen(
                    session: null,
                    activeSessionId: 'a',
                    running: false,
                    connected: true,
                    offline: false,
                    modelName: null,
                    contextWindow: null,
                    remainingContext: null,
                    messages: const [],
                    commands: const [],
                    permissionMode: PermissionMode.manual,
                    allowBypassPermissions: false,
                    pendingPermissions: const [],
                    respondingPermissionIds: const {},
                    promptController: controller,
                    peek: SessionPeekView(
                      sessionId: 'b',
                      title: 'A long session title',
                      messages: const [],
                      switching: true,
                      loading: !failed,
                      failed: failed,
                    ),
                    onExitPeek: () {},
                    onRetryPeek: () {},
                    onFillPrompt: (_) {},
                    onReconnect: () {},
                    onOpenSettings: () {},
                    onOpenModelPicker: (_) {},
                    onNewConversation: () {},
                    onOpenSessions: () {},
                    onOpenWorkspace: () {},
                    onPermissionModeSelected: (_) {},
                    onPermissionAllow: (_) {},
                    onPermissionDeny: (_) {},
                    onSend: () {},
                    onStop: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const ValueKey('session-peek-dock')), findsNothing);
          expect(find.byType(PromptBar), findsOneWidget);
          expect(find.byType(PromptChip), findsNothing);
          expect(
            find.byKey(const ValueKey('session-switch-return')),
            findsOneWidget,
          );
          expect(find.byType(LinearProgressIndicator), findsNothing);
          if (failed) {
            expect(find.text('重试'), findsOneWidget);
          }
        }
      }
      await disposeApp(tester);
    },
  );

  for (final connected in [true, false]) {
    testWidgets('switch completes over HTTP when WS ready is $connected', (
      tester,
    ) async {
      final pending = Completer<http.Response>();
      final requests = <http.Request>[];
      final api = RemoteApiClient(
        client: selectionClient((request) {
          requests.add(request);
          return pending.future;
        }),
      );
      final channel = FakeWebSocketChannel();
      final client = RemoteWebSocketClient(connect: (_) => channel);
      final dynamic state = await boot(tester, api, wsClient: client);
      if (connected) {
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
        await tester.pump();
        expect(client.isAuthenticated, isTrue);
      }
      state.wsReady = connected;
      state.handleWsMessage(jsonEncode(transcript('a')));
      state.promptController.text = 'draft a';

      expect(state.selectRemoteSessionWithJump('b'), isTrue);
      await tester.pump();
      expect(state.viewingSessionId, 'b');
      expect(find.byKey(const ValueKey('session-peek-dock')), findsNothing);
      expect(
        find.byKey(const ValueKey('session-switch-progress')),
        findsNothing,
      );
      if (connected) {
        expect(requests, isEmpty);
        await tester.pump(const Duration(seconds: 2));
      }
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/api/sessions/b/select');
      pending.complete(response(selection('b')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(state.activeSessionId, 'b');
      expect(state.viewingSessionId, isNull);
      expect(
        find.byKey(const ValueKey('session-switch-progress')),
        findsNothing,
      );
      expect(state.messages.single.text, 'reply b');
      expect(state.sessionMemoryStore.forSession('a').draft.text, 'draft a');
      await disposeApp(tester);
    });
  }

  testWidgets('a responsive websocket switches without waiting for HTTP', (
    tester,
  ) async {
    var requests = 0;
    final channel = FakeWebSocketChannel();
    final client = RemoteWebSocketClient(connect: (_) => channel);
    final dynamic state = await boot(
      tester,
      RemoteApiClient(
        client: selectionClient((_) async {
          requests++;
          return response(selection('b'));
        }),
      ),
      wsClient: client,
    );
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
    await tester.pump();
    state.selectRemoteSessionWithJump('b');
    await tester.pump();
    expect(jsonDecode(channel.sent.last as String)['type'], 'select_session');
    channel.incoming.add(jsonEncode({'type': 'catalog', ...catalog('b')}));
    channel.incoming.add(jsonEncode(transcript('b')));
    await tester.pumpAndSettle();
    expect(state.activeSessionId, 'b');
    expect(state.messages.single.text, 'reply b');
    expect(state.viewingSessionId, isNull);
    expect(requests, 0);
    await disposeApp(tester);
  });

  testWidgets('reconnection resends the pending selection once', (
    tester,
  ) async {
    final channels = [FakeWebSocketChannel(), FakeWebSocketChannel()];
    var connection = 0;
    final client = RemoteWebSocketClient(
      connect: (_) => channels[connection++],
    );
    final dynamic state = await boot(
      tester,
      RemoteApiClient(
        client: selectionClient((_) async => response(selection('b'))),
      ),
      wsClient: client,
    );
    state.connectWs(state.session);
    await tester.pump();
    final status = jsonEncode({
      'type': 'status',
      'sessionId': 'a',
      'authenticated': true,
      'running': false,
    });
    channels.first.incoming.add(status);
    await tester.pump();
    state.selectRemoteSessionWithJump('b');
    await tester.pump();
    client.reconnect();
    await tester.pump();
    channels.last.incoming.add(status);
    await tester.pump();
    channels.last.incoming.add(status);
    await tester.pump();
    expect(
      channels.last.sent
          .map((message) => jsonDecode(message as String))
          .where((message) => message['type'] == 'select_session'),
      hasLength(1),
    );
    channels.last.incoming.add(
      jsonEncode({'type': 'catalog', ...catalog('b')}),
    );
    channels.last.incoming.add(jsonEncode(transcript('b')));
    await tester.pumpAndSettle();
    expect(state.activeSessionId, 'b');
    expect(state.viewingSessionId, isNull);
    await disposeApp(tester);
  });

  testWidgets(
    'rapid selections keep the newest target and ignore older replies',
    (tester) async {
      final requests = <http.Request>[];
      final responses = <Completer<http.Response>>[];
      final dynamic state = await boot(
        tester,
        RemoteApiClient(
          client: selectionClient((request) {
            requests.add(request);
            final pending = Completer<http.Response>();
            responses.add(pending);
            return pending.future;
          }),
        ),
      );
      expect(state.selectRemoteSessionWithJump('b'), isTrue);
      await tester.pump();
      expect(state.selectRemoteSessionWithJump('c'), isTrue);
      await tester.pump();
      expect(state.viewingSessionId, 'c');
      expect(state.currentSessionPeek().messages.single.text, 'reply c');
      expect(state.peekLoading, isFalse);
      expect(state.activeSessionId, 'a');
      expect(
        requests,
        hasLength(1),
        reason: 'viewing C must not wait for activation B',
      );
      state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('b')}));
      state.handleWsMessage(jsonEncode(transcript('b')));
      expect(state.viewingSessionId, 'c');
      responses.first.complete(response(selection('b')));
      await tester.pump();
      await tester.pump();
      expect(requests.last.url.path, '/api/sessions/c/select');
      responses.last.complete(response(selection('c')));
      await tester.pumpAndSettle();
      expect(state.activeSessionId, 'c');
      expect(state.messages.single.text, 'reply c');
      await disposeApp(tester);
    },
  );

  testWidgets('late reads cannot replace a newer view or its live snapshot', (
    tester,
  ) async {
    final reads = <String, Completer<http.Response>>{};
    final paths = <String>[];
    final activations = <String, Completer<http.Response>>{};
    final dynamic state = await boot(
      tester,
      RemoteApiClient(
        client: MockClient((request) {
          paths.add('${request.method} ${request.url}');
          if (request.method == 'GET') {
            final result = Completer<http.Response>();
            reads[request.url.pathSegments.last] = result;
            return result.future;
          }
          final result = Completer<http.Response>();
          activations[request.url.pathSegments[2]] = result;
          return result.future;
        }),
      ),
    );
    state.promptController.text = 'draft a';
    expect(state.selectRemoteSessionWithJump('b'), isTrue);
    await tester.pump();
    expect(state.selectRemoteSessionWithJump('c'), isTrue);
    await tester.pump();
    expect(reads.keys, containsAll(['b', 'c']), reason: paths.toString());
    expect(
      paths.where((path) => path.startsWith('GET')),
      everyElement(endsWith('?cached=1')),
    );
    state.handleWsMessage({
      ...transcript('c'),
      'revision': 3,
      'messages': [
        {'role': 'assistant', 'text': 'latest c'},
      ],
    });
    await tester.pump();
    expect(state.currentSessionPeek().messages.single.text, 'latest c');
    reads['b']!.complete(response(view('b')));
    reads['c']!.complete(response(view('c')));
    await tester.pump();
    expect(state.currentSessionPeek().messages.single.text, 'latest c');
    expect(state.activeSessionId, 'a');
    state.openSessions();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      tester
          .widget<SessionNavigatorPage>(find.byType(SessionNavigatorPage))
          .activeSessionId,
      'c',
    );
    Navigator.of(tester.element(find.byType(SessionNavigatorPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await state.sendPrompt();
    expect(state.promptController.text, 'draft a');
    state.handleWsMessage({'type': 'catalog', ...catalog('c')});
    state.handleWsMessage({'type': 'transcript_snapshot', 'sessionId': 'c'});
    expect(
      state.selectingSessionId,
      'c',
      reason: 'a malformed snapshot cannot confirm activation',
    );
    activations['b']!.complete(response(selection('b')));
    await tester.pump();
    activations['c']!.complete(response(selection('c')));
    await tester.pump();
    expect(state.viewingSessionId, isNull);
    expect(state.messages.single.text, 'latest c');
    expect(state.remoteTranscriptRevision, 3);
    await disposeApp(tester);
  });

  testWidgets('revisiting a session shows saved messages before the response', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final dynamic state = await boot(
      tester,
      RemoteApiClient(client: selectionClient((_) => pending.future)),
    );
    state.handleWsMessage(jsonEncode(transcript('a')));
    state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('b')}));
    state.handleWsMessage(jsonEncode(transcript('b')));
    expect(state.selectRemoteSessionWithJump('a'), isTrue);
    await tester.pump();
    expect(state.currentSessionPeek().messages.single.text, 'reply a');
    pending.complete(response(selection('a')));
    await tester.pumpAndSettle();
    expect(state.messages.single.text, 'reply a');
    await disposeApp(tester);
  });

  testWidgets('a timed out switch offers retry and preserves the old draft', (
    tester,
  ) async {
    final first = Completer<http.Response>();
    var attempts = 0;
    final dynamic state = await boot(
      tester,
      RemoteApiClient(
        client: selectionClient((_) {
          attempts++;
          return attempts == 1
              ? first.future
              : Future.value(response(selection('b')));
        }),
      ),
    );
    state.promptController.text = 'keep draft';
    state.selectRemoteSessionWithJump('b');
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));
    await tester.pump();
    expect(state.peekFailed, isTrue);
    expect(state.peekLoading, isFalse);
    expect(state.activeSessionId, 'a');
    expect(state.promptController.text, 'keep draft');
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(state.activeSessionId, 'b');
    expect(state.messages.single.text, 'reply b');
    first.complete(response(selection('a')));
    await tester.pump();
    expect(state.activeSessionId, 'b');
    await disposeApp(tester);
  });

  testWidgets(
    'WS confirmation finishes a switch before a delayed HTTP response',
    (tester) async {
      final responses = <Completer<http.Response>>[];
      final dynamic state = await boot(
        tester,
        RemoteApiClient(
          client: selectionClient((_) {
            final pending = Completer<http.Response>();
            responses.add(pending);
            return pending.future;
          }),
        ),
      );
      state.selectRemoteSessionWithJump('b');
      await tester.pump();
      state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('b')}));
      state.handleWsMessage(jsonEncode(transcript('b')));
      expect(state.viewingSessionId, isNull);
      state.selectRemoteSessionWithJump('c');
      await tester.pump();
      expect(responses, hasLength(2));
      responses.last.complete(response(selection('c')));
      await tester.pumpAndSettle();
      responses.first.complete(response(selection('b')));
      state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('b')}));
      state.handleWsMessage(jsonEncode(transcript('b')));
      await tester.pump();
      expect(state.activeSessionId, 'c');
      expect(state.messages.single.text, 'reply c');
      state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('c')}));
      state.handleWsMessage(jsonEncode(transcript('c')));
      expect(state.messages.single.text, 'reply c');
      await disposeApp(tester);
    },
  );

  testWidgets('switch ignores a response from the previous connection', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final dynamic state = await boot(
      tester,
      RemoteApiClient(client: selectionClient((_) => pending.future)),
    );
    state.selectRemoteSessionWithJump('b');
    await tester.pump();
    state.closeWs();
    state.clearSessionPeek();
    state.session = state.session.copyWith(workspaceDir: '/different');
    state.handleWsMessage(jsonEncode({'type': 'catalog', ...catalog('c')}));
    state.handleWsMessage(jsonEncode(transcript('c')));
    pending.complete(response(selection('b'), 401));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.activeSessionId, 'c');
    expect(state.session, isNotNull);
    expect(state.messages.single.text, 'reply c');
    await disposeApp(tester);
  });

  testWidgets(
    'returning during a switch restores the original selection after the pending request',
    (tester) async {
      final first = Completer<http.Response>();
      final requests = <http.Request>[];
      final dynamic state = await boot(
        tester,
        RemoteApiClient(
          client: selectionClient((request) {
            requests.add(request);
            return requests.length == 1
                ? first.future
                : Future.value(response(selection('a')));
          }),
        ),
      );
      state.handleWsMessage(jsonEncode(transcript('a')));
      state.selectRemoteSessionWithJump('b');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('session-switch-return')));
      await tester.pump();
      expect(state.viewingSessionId, 'a');
      first.complete(response(selection('b')));
      await tester.pumpAndSettle();
      expect(requests.last.url.path, '/api/sessions/a/select');
      expect(state.activeSessionId, 'a');
      expect(state.messages.single.text, 'reply a');
      await disposeApp(tester);
    },
  );
}
