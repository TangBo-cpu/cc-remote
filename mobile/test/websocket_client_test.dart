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

    expect(first.sent, [jsonEncode({'type': 'auth', 'token': 'secret'})]);
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
    expect(client.send({'type': 'current'}, expectedConnection: second), isTrue);
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
  late final WebSocketSink _sink = FakeWebSocketSink(sent, incoming);

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

  @override
  void add(dynamic event) => sent.add(event);

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
