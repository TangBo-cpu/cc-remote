import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:cc_remote/data/websocket_client.dart';

void main() {
  test('authenticates and guards sends to the active connection', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    final client = RemoteWebSocketClient(connect: (_) => channels.removeAt(0));

    client.connect(
      origin: Uri.parse('https://example.test/base'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(first.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
    ]);
    expect(client.send({'type': 'ping'}, expectedConnection: first), isTrue);
    expect(first.sent.last, jsonEncode({'type': 'ping'}));

    client.connect(
      origin: Uri.parse('https://example.test/base'),
      token: 'next',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(client.send({'type': 'stale'}, expectedConnection: first), isFalse);
    expect(
      client.send({'type': 'current'}, expectedConnection: second),
      isTrue,
    );
    expect(second.sent.last, jsonEncode({'type': 'current'}));
    client.close();
  });

  test('does not forward completion from a superseded connection', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    var doneCount = 0;
    final client = RemoteWebSocketClient(connect: (_) => channels.removeAt(0));

    void connect() {
      client.connect(
        origin: Uri.parse('https://example.test'),
        token: 'secret',
        onMessage: (_) {},
        onError: (_) {},
        onDone: () => doneCount += 1,
      );
    }

    connect();
    connect();
    await Future<void>.delayed(Duration.zero);

    expect(doneCount, 0);
    await second.incoming.close();
    await Future<void>.delayed(Duration.zero);
    expect(doneCount, 1);
    client.close();
  });

  test('automatically reconnects after the active connection closes', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    var doneCount = 0;
    final client = RemoteWebSocketClient(
      connect: (_) => channels.removeAt(0),
      reconnectDelays: const [Duration.zero],
    );
    addTearDown(client.close);

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () => doneCount += 1,
    );
    await first.incoming.close();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(doneCount, 1);
    expect(second.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
    ]);
    expect(client.channel, same(second));
    client.close();
  });

  test('explicit close cancels a pending automatic reconnect', () async {
    final first = FakeWebSocketChannel();
    var connectCount = 0;
    final snapshots = <RemoteConnectionSnapshot>[];
    final client = RemoteWebSocketClient(
      connect: (_) {
        connectCount += 1;
        return first;
      },
      reconnectDelays: const [Duration(milliseconds: 20)],
    );

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
      onState: snapshots.add,
    );
    await first.incoming.close();
    await Future<void>.delayed(Duration.zero);
    final snapshotCountBeforeClose = snapshots.length;
    client.close();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(connectCount, 1);
    expect(snapshots, hasLength(snapshotCountBeforeClose));
  });

  test('send failure reports false and reconnects', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    var errorCount = 0;
    final client = RemoteWebSocketClient(
      connect: (_) => channels.removeAt(0),
      reconnectDelays: const [Duration.zero],
    );

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) => errorCount += 1,
      onDone: () {},
    );
    await Future<void>.delayed(Duration.zero);
    first.failNextSend();

    expect(client.send({'type': 'prompt'}), isFalse);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(errorCount, 1);
    expect(second.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
    ]);
    expect(client.channel, same(second));
    client.close();
  });

  test('sendPrompt reports false and reconnects when send fails', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    var errorCount = 0;
    final client = RemoteWebSocketClient(
      connect: (_) => channels.removeAt(0),
      reconnectDelays: const [Duration.zero],
    );
    addTearDown(client.close);

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) => errorCount += 1,
      onDone: () {},
    );
    await Future<void>.delayed(Duration.zero);
    first.failNextSend();

    final sent = client.sendPrompt({
      'type': 'prompt',
      'promptId': 'prompt-1',
      'sessionId': 'session-1',
      'text': 'hello',
    }, expectedConnection: first);

    expect(sent, isFalse);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(errorCount, 1);
    expect(client.channel, same(second));
    expect(second.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
    ]);
  });

  test('reconnects when authentication times out', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    var connectCount = 0;
    Object? lastError;
    final reconnected = Completer<void>();

    final client = RemoteWebSocketClient(
      connect: (_) {
        connectCount += 1;
        final channel = channels.removeAt(0);
        if (connectCount == 2 && !reconnected.isCompleted) {
          reconnected.complete();
        }
        return channel;
      },
      authTimeout: const Duration(milliseconds: 20),
      reconnectDelays: const [Duration.zero],
    );
    addTearDown(client.close);

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (error) => lastError = error,
      onDone: () {},
    );

    await reconnected.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);

    expect(connectCount, 2);
    expect(lastError, isA<TimeoutException>());
    expect(second.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
    ]);
  });

  test(
    'retrying state reentry does not leave a stale reconnect timer',
    () async {
      final first = FakeWebSocketChannel();
      final replacement = FakeWebSocketChannel();
      final unexpected = FakeWebSocketChannel();
      final channels = <FakeWebSocketChannel>[first, replacement, unexpected];
      var connectCount = 0;
      bool? replacementResult;
      var reentered = false;
      final retryStateHandled = Completer<void>();

      final client = RemoteWebSocketClient(
        connect: (_) {
          connectCount += 1;
          return channels.removeAt(0);
        },
        authTimeout: const Duration(seconds: 1),
        reconnectDelays: const [Duration(milliseconds: 20)],
      );
      addTearDown(client.close);

      client.connect(
        origin: Uri.parse('https://example.test'),
        token: 'secret',
        onMessage: (_) {},
        onError: (_) {},
        onDone: () {},
        onState: (snapshot) {
          if (snapshot.phase == RemoteConnectionPhase.retrying && !reentered) {
            reentered = true;
            replacementResult = client.reconnect();
            retryStateHandled.complete();
          }
        },
      );

      await first.incoming.close();
      await retryStateHandled.future.timeout(const Duration(seconds: 1));

      expect(replacementResult, isTrue);
      expect(connectCount, 2);
      expect(client.channel, same(replacement));

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(connectCount, 2);
      expect(client.channel, same(replacement));
    },
  );

  test(
    'replacement connect keeps its auth timeout after old authenticated callback',
    () async {
      final first = FakeWebSocketChannel();
      final second = FakeWebSocketChannel();
      final third = FakeWebSocketChannel();
      final channels = <FakeWebSocketChannel>[first, second, third];
      var connectCount = 0;
      bool? replacementResult;
      final thirdConnected = Completer<void>();

      final client = RemoteWebSocketClient(
        connect: (_) {
          connectCount += 1;
          final channel = channels.removeAt(0);
          if (connectCount == 3 && !thirdConnected.isCompleted) {
            thirdConnected.complete();
          }
          return channel;
        },
        authTimeout: const Duration(milliseconds: 20),
        reconnectDelays: const [Duration.zero],
      );
      addTearDown(client.close);

      client.connect(
        origin: Uri.parse('https://example.test'),
        token: 'secret',
        onMessage: (_) {
          if (replacementResult != null) return;
          replacementResult = client.reconnect();
        },
        onError: (_) {},
        onDone: () {},
      );

      first.incoming.add(jsonEncode({'type': 'status', 'authenticated': true}));

      await thirdConnected.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(replacementResult, isTrue);
      expect(connectCount, 3);
      expect(second.sent, [
        jsonEncode({'type': 'auth', 'token': 'secret'}),
      ]);
      expect(third.sent, [
        jsonEncode({'type': 'auth', 'token': 'secret'}),
      ]);
    },
  );

  test('aborts outer open when onState replaces the connection', () {
    final replacement = FakeWebSocketChannel();
    final unexpected = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[replacement, unexpected];
    var connectCount = 0;
    var replacing = false;
    bool? replacementResult;

    final client = RemoteWebSocketClient(
      connect: (_) {
        connectCount += 1;
        return channels.removeAt(0);
      },
      authTimeout: const Duration(milliseconds: 20),
      reconnectDelays: const [Duration.zero],
    );
    addTearDown(client.close);

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
      onState: (snapshot) {
        if (snapshot.phase == RemoteConnectionPhase.connecting && !replacing) {
          replacing = true;
          replacementResult = client.reconnect();
        }
      },
    );

    expect(replacementResult, isTrue);
    expect(connectCount, 1);
    expect(client.channel, same(replacement));
    expect(unexpected.sent, isEmpty);
  });

  test('waits for channel.ready before auth and business sends', () async {
    final channel = FakeWebSocketChannel();
    final client = RemoteWebSocketClient(
      connect: (_) => channel,
      authTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(client.close);

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
    );

    expect(channel.sent, isEmpty);
    expect(client.send({'type': 'before_auth'}), isFalse);

    await Future<void>.delayed(Duration.zero);

    expect(channel.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
    ]);
    expect(client.send({'type': 'after_auth'}), isTrue);
    expect(channel.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
      jsonEncode({'type': 'after_auth'}),
    ]);
  });

  test('resends an unacknowledged prompt after reconnect only', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final third = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second, third];
    final client = RemoteWebSocketClient(
      connect: (_) => channels.removeAt(0),
      reconnectDelays: const [Duration.zero],
    );
    final prompt = <String, dynamic>{
      'type': 'prompt',
      'promptId': 'prompt-1',
      'sessionId': 'session-1',
      'text': 'keep this prompt',
      'permissionMode': 'manual',
    };

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.sendPrompt(prompt, expectedConnection: first), isTrue);

    await first.incoming.close();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    second.incoming.add(jsonEncode({'type': 'status', 'authenticated': true}));
    await Future<void>.delayed(Duration.zero);

    expect(second.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
      jsonEncode(prompt),
    ]);

    second.incoming.add(
      jsonEncode({'type': 'prompt_accepted', 'promptId': 'prompt-1'}),
    );
    await Future<void>.delayed(Duration.zero);
    await second.incoming.close();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    third.incoming.add(jsonEncode({'type': 'status', 'authenticated': true}));
    await Future<void>.delayed(Duration.zero);

    expect(third.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
    ]);
    client.close();
  });

  test('retries when opening a connection throws synchronously', () async {
    final channel = FakeWebSocketChannel();
    var connectCount = 0;
    var errorCount = 0;
    final client = RemoteWebSocketClient(
      connect: (_) {
        connectCount += 1;
        if (connectCount == 1) throw StateError('connect_failed');
        return channel;
      },
      reconnectDelays: const [Duration.zero],
    );

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) => errorCount += 1,
      onDone: () {},
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(connectCount, 2);
    expect(errorCount, 1);
    expect(channel.sent, [
      jsonEncode({'type': 'auth', 'token': 'secret'}),
    ]);
    client.close();
  });

  test('publishes retry timing from the transport retry schedule', () async {
    final channel = FakeWebSocketChannel();
    final snapshots = <RemoteConnectionSnapshot>[];
    final now = DateTime.utc(2026, 8, 17, 12);
    final client = RemoteWebSocketClient(
      connect: (_) => channel,
      reconnectDelays: const [Duration(seconds: 5)],
      now: () => now,
    );

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
      onState: snapshots.add,
    );
    await channel.incoming.close();
    await Future<void>.delayed(Duration.zero);

    expect(snapshots.map((snapshot) => snapshot.phase), [
      RemoteConnectionPhase.connecting,
      RemoteConnectionPhase.retrying,
    ]);
    expect(snapshots.last.attempt, 1);
    expect(snapshots.last.nextRetryAt, now.add(const Duration(seconds: 5)));
    client.close();
  });

  test('only authenticated status resets the reconnect attempt', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    final snapshots = <RemoteConnectionSnapshot>[];
    final client = RemoteWebSocketClient(
      connect: (_) => channels.removeAt(0),
      reconnectDelays: const [Duration.zero],
    );

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
      onState: snapshots.add,
    );
    await first.incoming.close();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    second.incoming.add(jsonEncode({'type': 'text', 'text': 'not ready'}));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.phase, RemoteConnectionPhase.connecting);
    expect(snapshots.last.attempt, 1);

    second.incoming.add(jsonEncode({'type': 'status', 'authenticated': true}));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.phase, RemoteConnectionPhase.connected);
    expect(snapshots.last.attempt, 0);
    client.close();
  });

  test('manual reconnect cancels the pending automatic retry', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    var connectCount = 0;
    final client = RemoteWebSocketClient(
      connect: (_) {
        connectCount += 1;
        return channels.removeAt(0);
      },
      reconnectDelays: const [Duration(milliseconds: 20)],
    );

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
    );
    await first.incoming.close();
    await Future<void>.delayed(Duration.zero);

    expect(client.reconnect(), isTrue);
    expect(client.channel, same(second));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(connectCount, 2);
    client.close();
  });

  test('manual reconnect ignores completion from the old connection', () async {
    final first = FakeWebSocketChannel();
    final second = FakeWebSocketChannel();
    final channels = <FakeWebSocketChannel>[first, second];
    var doneCount = 0;
    final client = RemoteWebSocketClient(
      connect: (_) => channels.removeAt(0),
      reconnectDelays: const [Duration.zero],
    );

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () => doneCount += 1,
    );
    expect(client.reconnect(), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(doneCount, 0);
    expect(client.channel, same(second));
    client.close();
  });

  test('retry snapshot retains the latest transport error', () async {
    final error = StateError('connect_failed');
    final snapshots = <RemoteConnectionSnapshot>[];
    final client = RemoteWebSocketClient(
      connect: (_) => throw error,
      reconnectDelays: const [Duration(seconds: 30)],
    );

    client.connect(
      origin: Uri.parse('https://example.test'),
      token: 'secret',
      onMessage: (_) {},
      onError: (_) {},
      onDone: () {},
      onState: snapshots.add,
    );

    expect(snapshots.last.phase, RemoteConnectionPhase.retrying);
    expect(snapshots.last.lastError, same(error));
    client.close();
  });

  test('maps an origin base path to the daemon websocket endpoint', () {
    expect(
      RemoteWebSocketClient.webSocketUri(
        Uri.parse('https://example.test/tunnel'),
      ).toString(),
      'wss://example.test/tunnel/ws',
    );
  });
}

class FakeWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final sent = <dynamic>[];
  late final FakeWebSocketSink _sink = FakeWebSocketSink(sent, incoming);

  void failNextSend() => _sink.nextError = StateError('send_failed');

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;
}

class FakeWebSocketSink implements WebSocketSink {
  FakeWebSocketSink(this.sent, this.incoming);

  final List<dynamic> sent;
  final StreamController<dynamic> incoming;
  final Completer<void> _done = Completer<void>();
  Object? nextError;

  @override
  void add(dynamic event) {
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
    sent.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) _done.complete();
    await incoming.close();
  }

  @override
  Future<void> get done => _done.future;
}
