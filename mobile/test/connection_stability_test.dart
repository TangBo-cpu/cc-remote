import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/data/websocket_client.dart';
import 'package:cc_remote/main.dart';

import 'websocket_client_test.dart' show FakeWebSocketChannel;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('authentication stays online when the active session is stale', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.start(tester);
    harness.requests.single.completeError(TimeoutException('HTTP unavailable'));
    await tester.pump();
    await tester.pump();
    final dynamic state = harness.state(tester);
    state.activeSessionId = 'previous-session';
    await harness.authenticate(tester);
    expect(state.activeSessionId, 'previous-session');
    expect(state.wsReady, isTrue);
    expect(state.remoteOffline, isFalse);
    harness.channels.single.incoming.add(
      jsonEncode({
        'type': 'catalog',
        'activeProjectId': 'project',
        'activeSessionId': 'test-session',
        'projects': [],
        'sessions': [],
      }),
    );
    await tester.pump();
    expect(harness.state(tester).activeSessionId, 'test-session');
    expect(harness.state(tester).wsReady, isTrue);
    expect(harness.state(tester).remoteOffline, isFalse);
    expect((await TokenStore().load())?.token, 'saved-token');
    await harness.dispose(tester);
  });

  testWidgets('bootstrap opens WebSocket while HTTP status is pending', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.start(tester);

    expect(harness.requests.single.isCompleted, isFalse);
    expect(harness.channels, hasLength(1));
    expect(harness.state(tester).route, ShellRoute.chat);
    await harness.authenticate(tester, running: true);
    harness.channels.single.incoming.add(
      jsonEncode({
        'type': 'catalog',
        'activeProjectId': 'project',
        'activeSessionId': 'test-session',
        'projects': [],
        'sessions': [],
      }),
    );
    await tester.pump();

    expect(harness.state(tester).activeSessionId, 'test-session');
    expect(harness.state(tester).wsReady, isTrue);
    expect(harness.requests.single.isCompleted, isFalse);
    expect(harness.state(tester).running, isTrue);
    expect(harness.state(tester).activeRunId, 'active-run');
    harness.requests.single.complete(statusResponse());
    await tester.pump();
    expect(harness.state(tester).running, isTrue);
    expect(harness.state(tester).activeRunId, 'active-run');
    expect(harness.channels, hasLength(1));
    await harness.dispose(tester);
  });
  testWidgets('a cached transcript does not overwrite a host snapshot', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.start(tester);
    final dynamic state = harness.state(tester);
    // The host snapshot lands before the cached read resolves.
    harness.channels.single.incoming.add(
      jsonEncode({
        'type': 'transcript_snapshot',
        'version': 1,
        'revision': 4,
        'sessionId': 'test-session',
        'running': false,
        'messages': [TranscriptMessage.assistant('host reply').toJson()],
      }),
    );
    await tester.pump();
    await tester.pump();
    expect(state.messages.single.text, 'host reply');
    // The in-flight cached read resolves with the older snapshot afterwards.
    await TranscriptStore().storage.write(
      key: TranscriptStore.key,
      value: jsonEncode({
        'version': 1,
        'sessionId': 'test-session',
        'running': false,
        'messages': [TranscriptMessage.assistant('cached reply').toJson()],
      }),
    );
    await state.restoreTranscriptSnapshot();
    await tester.pump();

    expect(state.messages.single.text, 'host reply');
    expect(state.remoteTranscriptRevision, 4);
    harness.requests.single.complete(statusResponse());
    await tester.pump();
    await harness.dispose(tester);
  });

  testWidgets('bootstrap starts automatic recovery after a network failure', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.start(tester);
    harness.requests.single.completeError(
      TimeoutException('network unavailable'),
    );
    await tester.pump();
    await tester.pump();

    expect(harness.state(tester).route, ShellRoute.chat);
    expect(harness.channels, hasLength(1));
    harness.channels.single.incoming.addError(StateError('still offline'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(harness.channels, hasLength(2));
    await harness.authenticate(tester);
    expect(harness.state(tester).wsReady, isTrue);
    expect((await TokenStore().load())?.token, 'saved-token');
    await harness.dispose(tester);
  });

  testWidgets('invalid credentials still return to pairing without retrying', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.start(tester);
    expect(harness.channels, hasLength(1));
    harness.requests.single.complete(http.Response('{}', 401));
    harness.channels.single.incoming.add(
      jsonEncode({'type': 'status', 'authenticated': false}),
    );
    await tester.pump();
    await tester.pump();

    expect(harness.state(tester).route, ShellRoute.pair);
    expect(harness.client.channel, isNull);
    expect(await TokenStore().load(), isNull);
    await harness.dispose(tester);
  });

  testWidgets(
    'a delayed HTTP refresh cannot replace a recovered socket or its run state',
    (tester) async {
      final harness = ConnectionHarness();
      await harness.startConnected(tester);
      final Future<void> refreshing = harness
          .state(tester)
          .refreshConnection(forceReconnect: true);
      await tester.pump();
      unawaited(harness.channels.first.incoming.close());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(harness.channels, hasLength(2));
      await harness.authenticate(tester, running: true);

      harness.requests.last.complete(statusResponse());
      await tester.pump();
      await refreshing;

      expect(harness.channels, hasLength(2));
      expect(harness.state(tester).wsReady, isTrue);
      expect(harness.state(tester).running, isTrue);
      expect(harness.state(tester).activeRunId, 'active-run');
      await harness.dispose(tester);
    },
  );

  testWidgets('HTTP failure does not close a healthy socket', (tester) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final Future<void> refreshing = harness
        .state(tester)
        .refreshConnection(forceReconnect: true);
    await tester.pump();
    harness.channels.single.replyToProbe();
    harness.requests.last.completeError(TimeoutException('HTTP unavailable'));
    await tester.pump();
    await refreshing;

    expect(harness.channels, hasLength(1));
    expect(harness.state(tester).wsReady, isTrue);
    expect(harness.state(tester).remoteOffline, isFalse);
    await harness.dispose(tester);
  });

  testWidgets(
    'returning from a long background stay keeps a responsive socket',
    (tester) async {
      final harness = ConnectionHarness();
      await harness.startConnected(tester);
      final dynamic state = harness.state(tester);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      state.appBackgroundedAt = DateTime.now().subtract(
        const Duration(minutes: 2),
      );
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();

      expect(harness.channels, hasLength(1));
      expect(state.wsReady, isTrue);
      expect(harness.requests, hasLength(1));
      harness.channels.single.replyToProbe();
      await tester.pump();

      expect(harness.channels, hasLength(1));
      expect(harness.requests, hasLength(1));
      expect(state.wsReady, isTrue);
      expect(state.remoteOffline, isFalse);
      await harness.dispose(tester);
    },
  );

  testWidgets('a short background stay probes and keeps a live socket', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.appBackgroundedAt = DateTime.now().subtract(
      const Duration(seconds: 2),
    );
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();

    expect(harness.channels, hasLength(1));
    expect(
      jsonDecode(harness.channels.single.sent.last as String)['type'],
      'ping',
    );
    expect(harness.requests, hasLength(1));
    harness.channels.single.replyToProbe();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));

    expect(harness.channels, hasLength(1));
    expect(harness.requests, hasLength(1));
    expect(state.wsReady, isTrue);
    await harness.dispose(tester);
  });

  testWidgets('a short background stay reconnects after the probe expires', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.appBackgroundedAt = DateTime.now().subtract(
      const Duration(seconds: 2),
    );
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(harness.requests, hasLength(1));
    await tester.pump(const Duration(milliseconds: 60));
    expect(harness.channels, hasLength(1));
    await tester.pump(
      RemoteWebSocketClient.resumeProbeTimeout +
          const Duration(milliseconds: 50),
    );

    expect(harness.channels, hasLength(2));
    expect(harness.requests, hasLength(2));
    harness.requests.last.complete(statusResponse());
    await harness.authenticate(tester);
    expect(state.wsReady, isTrue);
    await harness.dispose(tester);
  });

  testWidgets('resume keeps a socket with a delayed tunnel pong', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    expect(harness.channels, hasLength(1));
    expect(state.wsReady, isTrue);
    expect(harness.requests, hasLength(1));
    harness.channels.single.replyToProbe();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));

    expect(harness.channels, hasLength(1));
    expect(harness.requests, hasLength(1));
    expect(state.wsReady, isTrue);
    await harness.dispose(tester);
  });

  testWidgets('repeated resumes share a probe without HTTP refreshes', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    for (var i = 0; i < 3; i += 1) {
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
    }

    expect(
      harness.channels.single.sent.where(
        (message) => jsonDecode(message as String)['type'] == 'ping',
      ),
      hasLength(1),
    );
    expect(harness.requests, hasLength(1));
    harness.channels.single.replyToProbe();
    await tester.pump();
    expect(harness.requests, hasLength(1));
    expect(state.wsReady, isTrue);
    await harness.dispose(tester);
  });

  testWidgets('disposing during a resume probe does not start HTTP fallback', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await harness.dispose(tester);

    expect(harness.requests, hasLength(1));
    expect(harness.channels, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('resume keeps an automatic reconnect already awaiting auth', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    harness.channels.single.incoming.addError(StateError('network lost'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final connecting = harness.channels.last;
    expect(harness.channels, hasLength(2));
    state.appBackgroundedAt = DateTime.now().subtract(
      const Duration(seconds: 5),
    );
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(harness.requests, hasLength(2));
    harness.requests.last.complete(statusResponse());
    await tester.pump();

    expect(harness.channels, hasLength(2));
    expect(harness.client.channel, same(connecting));
    await harness.authenticate(tester);
    expect(state.wsReady, isTrue);
    await harness.dispose(tester);
  });

  testWidgets('resume retries a closed probe while HTTP refresh is pending', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    final Future<void> refreshing = state.refreshConnection(
      forceReconnect: false,
    );
    await tester.pump();
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    harness.channels.single.incoming.addError(StateError('network lost'));
    await tester.pump();

    expect(harness.channels, hasLength(2));
    expect(harness.requests, hasLength(2));
    expect(harness.requests.last.isCompleted, isFalse);
    await harness.authenticate(tester);
    harness.requests.last.complete(statusResponse());
    await tester.pump();
    await refreshing;
    expect(state.wsReady, isTrue);
    await harness.dispose(tester);
  });

  testWidgets('resume retries immediately during reconnect backoff', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    harness.channels.single.incoming.addError(StateError('network lost'));
    await tester.pump();
    expect(harness.client.channel, isNull);

    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.appBackgroundedAt = DateTime.now().subtract(
      const Duration(seconds: 5),
    );
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();

    expect(harness.channels, hasLength(2));
    expect(harness.requests, hasLength(2));
    harness.requests.last.complete(statusResponse());
    await tester.pump();
    await harness.authenticate(tester);
    harness.channels.last.incoming.addError(StateError('still offline'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 99));
    expect(harness.channels, hasLength(2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.channels, hasLength(3));
    await harness.dispose(tester);
  });
  testWidgets('a manual reconnect invalidates an older HTTP refresh', (
    tester,
  ) async {
    final harness = ConnectionHarness();
    await harness.startConnected(tester);
    final dynamic state = harness.state(tester);
    final Future<void> refreshing = state.refreshConnection(
      forceReconnect: true,
    );
    await tester.pump();
    state.reconnectNow();
    await tester.pump();
    await harness.authenticate(tester, running: true);
    harness.requests.last.complete(statusResponse());
    await tester.pump();
    await refreshing;

    expect(harness.channels, hasLength(2));
    expect(state.running, isTrue);
    expect(state.wsReady, isTrue);
    await harness.dispose(tester);
  });

  testWidgets(
    'disposing during refresh does not reconnect or update a dead widget',
    (tester) async {
      final harness = ConnectionHarness();
      await harness.startConnected(tester);
      final Future<void> refreshing = harness
          .state(tester)
          .refreshConnection(forceReconnect: true);
      await tester.pump();
      await harness.dispose(tester);
      harness.requests.last.complete(statusResponse());
      await tester.pump();
      await refreshing;
      await tester.pump(const Duration(milliseconds: 200));

      expect(harness.channels, hasLength(1));
      expect(harness.client.isActive, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

http.Response statusResponse() => http.Response(
  jsonEncode({
    'deviceName': 'Test host',
    'workspaceDir': '/workspace/project',
    'running': false,
  }),
  200,
);

class ConnectionHarness {
  final channels = <FakeWebSocketChannel>[];
  final requests = <Completer<http.Response>>[];
  late final client = RemoteWebSocketClient(
    connect: (_) {
      final channel = FakeWebSocketChannel();
      channels.add(channel);
      return channel;
    },
    livenessTimeout: const Duration(milliseconds: 50),
    reconnectDelays: const [Duration(milliseconds: 100)],
  );
  late final api = RemoteApiClient(
    client: MockClient((request) {
      expectSync(request.url.path, '/api/status');
      expectSync(request.headers['Authorization'], 'Bearer saved-token');
      final response = Completer<http.Response>();
      requests.add(response);
      return response.future;
    }),
  );

  dynamic state(WidgetTester tester) => tester.state(find.byType(DemoShell));

  Future<void> start(WidgetTester tester) async {
    addTearDown(client.close);
    await TokenStore().save(
      SavedSession(
        origin: Uri.parse('https://example.test'),
        token: 'saved-token',
        deviceName: 'Test host',
        workspaceDir: '/workspace/project',
      ),
    );
    await tester.pumpWidget(
      CcRemoteApp(enableCamera: false, wsClient: client, apiClient: api),
    );
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(1));
  }

  Future<void> startConnected(WidgetTester tester) async {
    await start(tester);
    requests.single.complete(statusResponse());
    await tester.pump();
    await tester.pump();
    expect(channels, hasLength(1));
    await authenticate(tester);
  }

  Future<void> authenticate(WidgetTester tester, {bool running = false}) async {
    channels.last.incoming.add(
      jsonEncode({
        'type': 'status',
        'authenticated': true,
        'connectionProbe': true,
        'running': running,
        'sessionId': 'test-session',
        if (running) 'runId': 'active-run',
      }),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }
}
