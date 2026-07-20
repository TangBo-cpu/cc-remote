import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

typedef WebSocketMessageHandler = void Function(dynamic data);
typedef WebSocketErrorHandler = void Function(Object error);

class RemoteWebSocketClient {
  RemoteWebSocketClient({WebSocketChannel Function(Uri)? connect})
    : _connect = connect ?? WebSocketChannel.connect;

  final WebSocketChannel Function(Uri) _connect;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  WebSocketChannel? get channel => _channel;

  void connect({
    required Uri origin,
    required String token,
    required WebSocketMessageHandler onMessage,
    required WebSocketErrorHandler onError,
    required void Function() onDone,
  }) {
    close();
    final channel = _connect(webSocketUri(origin));
    _channel = channel;
    _subscription = channel.stream.listen(
      onMessage,
      onError: onError,
      onDone: onDone,
    );
    channel.sink.add(jsonEncode({'type': 'auth', 'token': token}));
  }

  bool send(Map<String, dynamic> message, {Object? expectedConnection}) {
    final channel = _channel;
    if (channel == null ||
        (expectedConnection != null && channel != expectedConnection)) {
      return false;
    }
    channel.sink.add(jsonEncode(message));
    return true;
  }

  void close() {
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  static Uri webSocketUri(Uri origin) {
    final scheme = origin.scheme == 'https' ? 'wss' : 'ws';
    return Uri.parse('$scheme://${origin.authority}/ws');
  }
}
