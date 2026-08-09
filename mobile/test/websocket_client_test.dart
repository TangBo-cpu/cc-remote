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
    );
    await first.incoming.close();
    await Future<void>.delayed(Duration.zero);
    client.close();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(connectCount, 1);
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
