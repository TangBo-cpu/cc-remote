import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'remote_origin.dart';

typedef WebSocketMessageHandler = void Function(dynamic data);
typedef WebSocketErrorHandler = void Function(Object error);
typedef WebSocketStateHandler =
    void Function(RemoteConnectionSnapshot snapshot);

enum RemoteConnectionPhase { idle, connecting, retrying, connected }

class RemoteConnectionSnapshot {
  const RemoteConnectionSnapshot({
    required this.phase,
    this.attempt = 0,
    this.nextRetryAt,
    this.lastError,
  });

  const RemoteConnectionSnapshot.idle()
    : phase = RemoteConnectionPhase.idle,
      attempt = 0,
      nextRetryAt = null,
      lastError = null;

  final RemoteConnectionPhase phase;
  final int attempt;
  final DateTime? nextRetryAt;
  final Object? lastError;
}

class RemoteWebSocketClient {
  RemoteWebSocketClient({
    WebSocketChannel Function(Uri)? connect,
    List<Duration>? reconnectDelays,
    DateTime Function()? now,
    Duration authTimeout = _defaultAuthTimeout,
    Duration livenessTimeout = _defaultLivenessTimeout,
  }) : _connect =
           connect ??
           ((Uri uri) => IOWebSocketChannel.connect(
             uri,
             connectTimeout: _defaultConnectTimeout,
             pingInterval: _defaultPingInterval,
           )),
       _reconnectDelays = reconnectDelays ?? _defaultReconnectDelays,
       _now = now ?? DateTime.now,
       _authTimeout = authTimeout,
       _livenessTimeout = livenessTimeout;

  static const _defaultConnectTimeout = Duration(seconds: 12);
  static const _defaultPingInterval = Duration(seconds: 20);
  static const _defaultAuthTimeout = Duration(seconds: 12);
  static const _defaultLivenessTimeout = Duration(seconds: 8);
  // Tunnel latency can exceed two seconds without the connection being dead.
  static const resumeProbeTimeout = _defaultLivenessTimeout;

  static const _defaultReconnectDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  final WebSocketChannel Function(Uri) _connect;
  final List<Duration> _reconnectDelays;
  final DateTime Function() _now;
  final Duration _authTimeout;
  final Duration _livenessTimeout;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _authTimer;
  bool _transportReady = false;
  bool _authenticated = false;
  bool _supportsConnectionProbe = false;
  bool _supportsMultiDevice = false;
  Timer? _probeTimer;
  Completer<void>? _probe;
  String? _probeId;
  bool _reconnectNowOnProbeFailure = false;
  int _probeSequence = 0;
  int _generation = 0;
  int _reconnectAttempt = 0;
  bool _explicitlyClosed = true;
  Uri? _origin;
  String? _token;
  WebSocketMessageHandler? _onMessage;
  WebSocketErrorHandler? _onError;
  void Function()? _onDone;
  WebSocketStateHandler? _onState;
  Map<String, dynamic>? _pendingPrompt;
  Object? _lastError;

  WebSocketChannel? get channel => _channel;
  bool get isActive => !_explicitlyClosed && _origin != null && _token != null;
  bool get isAuthenticated => _authenticated;
  bool get supportsMultiDevice => _supportsMultiDevice;

  Future<void> ensureConnected({
    bool retryNow = false,
    Duration? probeTimeout,
    bool reconnectNowOnProbeFailure = false,
  }) {
    if (!isActive) return Future<void>.value();
    final channel = _channel;
    if (channel == null) {
      if (_reconnectTimer == null || retryNow) {
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _openConnection();
      }
      return Future<void>.value();
    }
    // The existing connect/auth timers own an unfinished handshake.
    if (!_authenticated || !_supportsConnectionProbe) {
      return Future<void>.value();
    }
    // A resume request also upgrades a probe started by a soft refresh.
    _reconnectNowOnProbeFailure |= reconnectNowOnProbeFailure;
    final pending = _probe;
    if (pending != null) return pending.future;

    final generation = _generation;
    final probe = Completer<void>();
    _probe = probe;
    final probeId = '$generation-${++_probeSequence}';
    _probeId = probeId;
    final timeout = probeTimeout ?? _livenessTimeout;
    _probeTimer = Timer(timeout, () {
      if (!_isCurrent(channel, generation)) return;
      _reportError(TimeoutException('websocket_liveness_timeout', timeout));
      _handleDisconnect(
        channel,
        generation,
        immediate: reconnectNowOnProbeFailure,
      );
    });
    send({'type': 'ping', 'probeId': probeId}, expectedConnection: channel);
    return probe.future;
  }

  void connect({
    required Uri origin,
    required String token,
    required WebSocketMessageHandler onMessage,
    required WebSocketErrorHandler onError,
    required void Function() onDone,
    WebSocketStateHandler? onState,
  }) {
    final sameCredentials = _origin == origin && _token == token;
    if (!sameCredentials) _pendingPrompt = null;
    _origin = origin;
    _token = token;
    _onMessage = onMessage;
    _onError = onError;
    _onDone = onDone;
    _onState = onState;
    _explicitlyClosed = false;
    _reconnectAttempt = 0;
    _lastError = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _openConnection();
  }

  void _openConnection() {
    final origin = _origin;
    final token = _token;
    if (_explicitlyClosed || origin == null || token == null) return;

    _closeCurrentConnection();
    final openingGeneration = _generation;
    _publishState(RemoteConnectionPhase.connecting);
    if (_explicitlyClosed || openingGeneration != _generation) return;
    late final WebSocketChannel channel;
    try {
      channel = _connect(webSocketUri(origin));
    } catch (error) {
      _reportError(error);
      _scheduleReconnect();
      return;
    }
    final generation = ++_generation;
    _channel = channel;
    _transportReady = false;
    _subscription = channel.stream.listen(
      (data) {
        if (!_isCurrent(channel, generation)) return;
        final authenticated = _handlePromptProtocolMessage(data);
        _onMessage?.call(data);
        if (authenticated && !_isCurrent(channel, generation)) return;
        if (authenticated) {
          final wasAuthenticated = _authenticated;
          _authenticated = true;
          _authTimer?.cancel();
          _authTimer = null;
          _reconnectAttempt = 0;
          _lastError = null;
          _publishState(RemoteConnectionPhase.connected);
          if (!wasAuthenticated) _retryPendingPrompt(channel, generation);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_isCurrent(channel, generation)) return;
        _reportError(error);
        _handleDisconnect(channel, generation);
      },
      onDone: () {
        if (!_isCurrent(channel, generation)) return;
        _onDone?.call();
        _handleDisconnect(channel, generation);
      },
    );
    unawaited(
      channel.ready.then<void>(
        (_) {
          if (!_isCurrent(channel, generation)) return;
          _authTimer = Timer(_authTimeout, () {
            if (!_isCurrent(channel, generation)) return;
            _reportError(
              TimeoutException('websocket_auth_timeout', _authTimeout),
            );
            _handleDisconnect(channel, generation);
          });
          try {
            channel.sink.add(jsonEncode({'type': 'auth', 'token': token}));
            _transportReady = true;
          } catch (error) {
            if (_isCurrent(channel, generation)) {
              _reportError(error);
              _handleDisconnect(channel, generation);
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!_isCurrent(channel, generation)) return;
          _reportError(error);
          _handleDisconnect(channel, generation);
        },
      ),
    );
  }

  bool send(Map<String, dynamic> message, {Object? expectedConnection}) {
    final channel = _channel;
    if (!_transportReady ||
        channel == null ||
        (expectedConnection != null && channel != expectedConnection)) {
      return false;
    }
    final generation = _generation;
    try {
      channel.sink.add(jsonEncode(message));
      return true;
    } catch (error) {
      if (_isCurrent(channel, generation)) {
        _reportError(error);
        _handleDisconnect(channel, generation);
      }
      return false;
    }
  }

  bool sendPrompt(Map<String, dynamic> message, {Object? expectedConnection}) {
    final channel = _channel;
    if (!_transportReady ||
        channel == null ||
        (expectedConnection != null && channel != expectedConnection)) {
      return false;
    }
    final promptId = message['promptId'];
    if (message['type'] != 'prompt' ||
        promptId is! String ||
        promptId.isEmpty) {
      return false;
    }
    final pending = _pendingPrompt;
    if (pending != null && pending['promptId'] != promptId) return false;
    _pendingPrompt = Map<String, dynamic>.from(message);
    final generation = _generation;
    try {
      channel.sink.add(jsonEncode(message));
    } catch (error) {
      if (_isCurrent(channel, generation)) {
        _reportError(error);
        _handleDisconnect(channel, generation);
      }
      return false;
    }
    return true;
  }

  bool reconnect() {
    if (_explicitlyClosed || _origin == null || _token == null) return false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _lastError = null;
    _openConnection();
    return true;
  }

  void close() {
    _explicitlyClosed = true;
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _origin = null;
    _token = null;
    _onMessage = null;
    _onError = null;
    _onDone = null;
    _onState = null;
    _pendingPrompt = null;
    _lastError = null;
    _closeCurrentConnection();
  }

  bool _handlePromptProtocolMessage(dynamic data) {
    try {
      final decoded = jsonDecode(data.toString());
      if (decoded is! Map<String, dynamic>) return false;
      if (decoded['type'] == 'pong' &&
          _probeId != null &&
          decoded['probeId'] == _probeId) {
        _finishProbe();
      }
      if (decoded['type'] == 'status' &&
          decoded['authenticated'] == true &&
          decoded.containsKey('connectionProbe')) {
        _supportsConnectionProbe = decoded['connectionProbe'] == true;
      }
      if (decoded['type'] == 'status' &&
          decoded['authenticated'] == true &&
          decoded.containsKey('multiDevice')) {
        _supportsMultiDevice = decoded['multiDevice'] == true;
      }
      final pendingPromptId = _pendingPrompt?['promptId'];
      final messagePromptId = decoded['promptId'];
      if (pendingPromptId is String && messagePromptId == pendingPromptId) {
        if (decoded['type'] == 'prompt_accepted' ||
            decoded['type'] == 'error') {
          _pendingPrompt = null;
        }
      }
      return decoded['type'] == 'status' && decoded['authenticated'] == true;
    } catch (_) {
      return false;
    }
  }

  void _retryPendingPrompt(WebSocketChannel channel, int generation) {
    final pending = _pendingPrompt;
    if (pending == null || !_isCurrent(channel, generation)) return;
    try {
      channel.sink.add(jsonEncode(pending));
    } catch (error) {
      if (_isCurrent(channel, generation)) {
        _reportError(error);
        _handleDisconnect(channel, generation);
      }
    }
  }

  void _handleDisconnect(
    WebSocketChannel channel,
    int generation, {
    bool immediate = false,
  }) {
    if (!_isCurrent(channel, generation)) return;
    immediate |= _probe != null && _reconnectNowOnProbeFailure;
    _closeCurrentConnection();
    _scheduleReconnect(immediate: immediate);
  }

  void _scheduleReconnect({bool immediate = false}) {
    if (_explicitlyClosed ||
        _reconnectDelays.isEmpty ||
        _origin == null ||
        _token == null) {
      return;
    }
    if (immediate) {
      // A failed resume probe already proved this socket unusable; waiting out
      // the backoff would only stretch the visible reconnect.
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempt += 1;
      _openConnection();
      return;
    }
    if (_reconnectTimer != null) return;
    final index = _reconnectAttempt < _reconnectDelays.length
        ? _reconnectAttempt
        : _reconnectDelays.length - 1;
    final delay = _reconnectDelays[index];
    _reconnectAttempt += 1;
    final nextRetryAt = _now().add(delay);
    final scheduleGeneration = _generation;
    _publishState(RemoteConnectionPhase.retrying, nextRetryAt: nextRetryAt);
    if (_explicitlyClosed || scheduleGeneration != _generation) return;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _openConnection();
    });
  }

  void _closeCurrentConnection() {
    _generation += 1;
    _authTimer?.cancel();
    _authTimer = null;
    _transportReady = false;
    _authenticated = false;
    _supportsConnectionProbe = false;
    _supportsMultiDevice = false;
    _finishProbe();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close().catchError((_) {}));
    }
  }

  void _finishProbe() {
    _probeTimer?.cancel();
    _probeTimer = null;
    _probeId = null;
    _reconnectNowOnProbeFailure = false;
    final probe = _probe;
    _probe = null;
    probe?.complete();
  }

  void _reportError(Object error) {
    _lastError = error;
    _onError?.call(error);
  }

  void _publishState(RemoteConnectionPhase phase, {DateTime? nextRetryAt}) {
    _onState?.call(
      RemoteConnectionSnapshot(
        phase: phase,
        attempt: _reconnectAttempt,
        nextRetryAt: nextRetryAt,
        lastError: _lastError,
      ),
    );
  }

  static Uri webSocketUri(Uri origin) {
    return remoteWebSocketUri(origin);
  }

  bool _isCurrent(WebSocketChannel channel, int generation) {
    return generation == _generation && identical(channel, _channel);
  }
}
