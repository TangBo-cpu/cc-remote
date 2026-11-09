import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import 'remote_origin.dart';

const _chunkBytes = 16 * 1024;
const _maxBodyBytes = 128 * 1024 * 1024;
const _maxMessageBytes = 32 * 1024 * 1024;
final _activePeers = <String, RemotePeerTransport>{};

class RemotePeerTransport {
  RemotePeerTransport({
    required this.origin,
    required this.token,
    required this.signal,
    required this.onMessage,
    required this.onReady,
    required this.onFailed,
  });

  final Uri origin;
  final String token;
  final bool Function(Map<String, dynamic>) signal;
  final void Function(String) onMessage;
  final void Function() onReady;
  final void Function(bool wasReady) onFailed;
  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  bool _closed = false;
  bool _ready = false;
  bool _channelReady = false;
  final _earlyMessages = <String>[];
  int _earlyMessageBytes = 0;
  bool _offerSent = false;
  Future<void>? _answer;
  final _earlyCandidates = <RTCIceCandidate>[];
  final _remoteCandidates = <RTCIceCandidate>[];
  Timer? _setupTimer;
  int _messageId = 0x80000000;
  int _requestId = 0;
  int _pendingBytes = 0;
  Future<void> _sending = Future.value();
  final _messages = <int, _PeerMessage>{};
  final _requests = <int, _PeerRequest>{};
  String path = 'webrtc';

  bool get isReady => _ready && !_closed;

  Future<void> start() async {
    _setupTimer = Timer(const Duration(seconds: 20), _fail);
    final client = http.Client();
    try {
      final response = await client
          .get(
            resolveRemotePath(origin, '/api/peer/ice'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (_closed) return;
      if (response.statusCode != 200 || response.bodyBytes.length > 16 * 1024) {
        throw StateError('peer_unavailable');
      }
      final config = jsonDecode(response.body) as Map<String, dynamic>;
      if (config['iceServers'] is! List) {
        throw StateError('invalid_peer_configuration');
      }
      final peer = await createPeerConnection({
        'iceServers': config['iceServers'],
        'iceTransportPolicy': 'all',
      });
      if (_closed) {
        await peer.dispose();
        return;
      }
      _peer = peer;
      peer.onIceCandidate = (candidate) {
        if (_closed || candidate.candidate?.isNotEmpty != true) return;
        if (!_offerSent) {
          _earlyCandidates.add(candidate);
        } else {
          _signalCandidate(candidate);
        }
      };
      peer.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _fail();
        }
      };
      final channel = await peer.createDataChannel(
        'cc-remote-v1',
        RTCDataChannelInit(),
      );
      if (_closed) {
        await channel.close();
        return;
      }
      _channel = channel;
      channel.onMessage = (message) {
        try {
          if (_closed) return;
          if (message.isBinary) {
            _receiveBinary(message.binary);
          } else {
            if (message.text.length > 32 * 1024) {
              throw StateError('peer_frame_too_large');
            }
            _receiveControl(jsonDecode(message.text) as Map<String, dynamic>);
          }
        } catch (_) {
          _fail();
        }
      };
      channel.onDataChannelState = (state) {
        if (_closed) return;
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          unawaited(_control({'type': 'ready'}).catchError((_) => _fail()));
        } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
          _fail();
        }
      };
      final offer = await peer.createOffer();
      if (_closed) return;
      await peer.setLocalDescription(offer);
      if (_closed) return;
      if (!signal({'type': 'peer_offer', 'sdp': offer.sdp})) {
        throw StateError('peer_signal_failed');
      }
      _offerSent = true;
      for (final candidate in _earlyCandidates) {
        _signalCandidate(candidate);
      }
      _earlyCandidates.clear();
    } catch (_) {
      _fail();
    } finally {
      client.close();
    }
  }

  Future<void> handleSignal(Map<String, dynamic> value) async {
    if (_closed) return;
    try {
      if (value['type'] == 'peer_unavailable') {
        _fail();
      } else if (value['type'] == 'peer_switched') {
        if (!_channelReady || _ready) throw StateError('invalid_peer_switch');
        _ready = true;
        _activePeers[origin.origin] = this;
        _setupTimer?.cancel();
        for (final raw in _earlyMessages) {
          onMessage(raw);
        }
        _earlyMessages.clear();
        _earlyMessageBytes = 0;
        onReady();
        unawaited(_inspectPath());
      } else if (value['type'] == 'peer_answer') {
        final peer = _peer;
        final sdp = value['sdp'];
        if (peer == null ||
            _answer != null ||
            sdp is! String ||
            sdp.length > 32 * 1024) {
          return;
        }
        _answer = peer.setRemoteDescription(
          RTCSessionDescription(sdp, 'answer'),
        );
        await _answer;
        if (_closed) return;
        for (final candidate in _remoteCandidates) {
          await peer.addCandidate(candidate);
        }
        _remoteCandidates.clear();
      } else if (value['type'] == 'peer_ice') {
        final candidate = value['candidate'];
        if (candidate is! Map || jsonEncode(candidate).length > 4096) return;
        final parsed = RTCIceCandidate(
          candidate['candidate'] as String?,
          candidate['sdpMid'] as String?,
          candidate['sdpMLineIndex'] as int?,
        );
        if (_answer == null) {
          if (_remoteCandidates.length >= 64) {
            throw StateError('too_many_peer_candidates');
          }
          _remoteCandidates.add(parsed);
        } else {
          await _answer;
          if (!_closed) await _peer?.addCandidate(parsed);
        }
      }
    } catch (_) {
      _fail();
    }
  }

  bool sendMessage(String raw) {
    if (!isReady) return false;
    final bytes = utf8.encode(raw);
    if (bytes.length > 64 * 1024 ||
        _pendingBytes + bytes.length > 8 * 1024 * 1024) {
      _fail();
      return true;
    }
    _pendingBytes += bytes.length;
    _sending = _sending
        .then<void>((_) async {
          final id = _messageId++;
          if (_messageId > 0xffffffff) _messageId = 0x80000000;
          await _control({'type': 'message', 'id': id, 'length': bytes.length});
          await _binary(id, bytes);
          await _control({'type': 'end', 'id': id});
        })
        .catchError((_) => _fail())
        .whenComplete(() {
          _pendingBytes -= bytes.length;
        });
    return true;
  }

  bool canSend(http.BaseRequest request) =>
      isReady &&
      request.url.origin == origin.origin &&
      request.url.path.startsWith('/api/') &&
      !request.url.path.startsWith('/api/local') &&
      const ['GET', 'POST', 'DELETE'].contains(request.method) &&
      request.headers.entries.any(
        (entry) =>
            entry.key.toLowerCase() == 'authorization' &&
            entry.value == 'Bearer $token',
      );

  Future<http.StreamedResponse> sendRequest(
    http.BaseRequest request, {
    void Function()? onFinished,
  }) {
    if (!canSend(request) || _requests.length >= 8) {
      return Future.error(
        http.ClientException('peer_unavailable', request.url),
      );
    }
    final length = request.contentLength;
    if (length != null && (length < 0 || length > _maxBodyBytes)) {
      return Future.error(
        http.ClientException('peer_body_too_large', request.url),
      );
    }
    if (++_requestId >= 0x80000000) _requestId = 1;
    final id = _requestId;
    final pending = _PeerRequest(request, onFinished);
    pending.body.onCancel = () => _cancelRequest(id);
    _requests[id] = pending;
    _armTimeout(id, pending);
    unawaited(() async {
      try {
        final body = request.finalize();
        final headers = {
          for (final entry in request.headers.entries)
            if (entry.key.toLowerCase() == 'content-type')
              'content-type': entry.value,
          if (length != null) 'content-length': '$length',
        };
        await _control({
          'type': 'request',
          'id': id,
          'method': request.method,
          'path': request.url.toString().substring(request.url.origin.length),
          'headers': headers,
        });
        var sent = 0;
        await for (final chunk in body) {
          if (!_requests.containsKey(id)) return;
          sent += chunk.length;
          if (sent > _maxBodyBytes) throw StateError('peer_body_too_large');
          await _binary(id, chunk);
          _armTimeout(id, pending);
        }
        if (_requests.containsKey(id)) {
          await _control({'type': 'end', 'id': id});
        }
      } catch (error) {
        _failRequest(id, error);
        _sendCancel(id);
      }
    }());
    return pending.response.future;
  }

  void cancelRequest(http.BaseRequest request) {
    for (final entry in _requests.entries.toList()) {
      if (identical(entry.value.request, request)) {
        _failRequest(
          entry.key,
          http.ClientException('client_closed', request.url),
        );
        _sendCancel(entry.key);
        return;
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (identical(_activePeers[origin.origin], this)) {
      _activePeers.remove(origin.origin);
    }
    _ready = false;
    _setupTimer?.cancel();
    for (final message in _messages.values) {
      message.timer.cancel();
    }
    _messages.clear();
    for (final id in _requests.keys.toList()) {
      _failRequest(id, http.ClientException('peer_disconnected'));
    }
    final channel = _channel;
    final peer = _peer;
    _channel = null;
    _peer = null;
    if (channel != null) unawaited(channel.close().catchError((_) {}));
    if (peer != null) unawaited(peer.dispose().catchError((_) {}));
  }

  void _fail() {
    if (_closed) return;
    final wasReady = _ready;
    close();
    onFailed(wasReady);
  }

  void _signalCandidate(RTCIceCandidate candidate) {
    if (!_closed &&
        !signal({'type': 'peer_ice', 'candidate': candidate.toMap()})) {
      _fail();
    }
  }

  void _receiveControl(Map<String, dynamic> value) {
    if (value['type'] == 'ready') {
      if (_channelReady) throw StateError('peer_already_ready');
      _channelReady = true;
      if (!signal({'type': 'peer_switch'})) _fail();
      return;
    }
    if (!_channelReady) throw StateError('peer_not_ready');
    final id = value['id'];
    if (id is! int || id < 1 || id > 0xffffffff) {
      throw StateError('invalid_peer_id');
    }
    if (value['type'] == 'message') {
      final length = value['length'];
      if (id < 0x80000000 ||
          _messages.isNotEmpty ||
          length is! int ||
          length < 0 ||
          length > _maxMessageBytes) {
        throw StateError('invalid_peer_message');
      }
      _messages[id] = _PeerMessage(
        length,
        Timer(const Duration(seconds: 30), _fail),
      );
      return;
    }
    if (id >= 0x80000000) {
      final message = _messages.remove(id);
      if (value['type'] != 'end' ||
          message == null ||
          message.bytes.length != message.expected) {
        throw StateError('peer_message_truncated');
      }
      message.timer.cancel();
      final bytes = message.bytes.takeBytes();
      final raw = utf8.decode(bytes);
      if (_ready) {
        onMessage(raw);
      } else {
        _earlyMessageBytes += bytes.length;
        if (_earlyMessageBytes > _maxMessageBytes) {
          throw StateError('peer_queue_full');
        }
        _earlyMessages.add(raw);
      }
      return;
    }
    final pending = _requests[id];
    if (pending == null) return;
    _armTimeout(id, pending);
    if (value['type'] == 'response') {
      final status = value['status'];
      final rawHeaders = value['headers'];
      if (pending.response.isCompleted ||
          status is! int ||
          status < 100 ||
          status > 599 ||
          rawHeaders is! Map) {
        throw StateError('invalid_peer_response');
      }
      final headers = Map<String, String>.from(rawHeaders);
      final length = headers['content-length'] == null
          ? null
          : int.tryParse(headers['content-length']!);
      if (length != null && (length < 0 || length > _maxBodyBytes)) {
        throw StateError('peer_body_too_large');
      }
      pending.expected = length;
      pending.response.complete(
        http.StreamedResponse(
          pending.body.stream,
          status,
          headers: headers,
          contentLength: length,
          request: pending.request,
        ),
      );
    } else if (value['type'] == 'end') {
      if (!pending.response.isCompleted ||
          (pending.expected != null && pending.expected != pending.received)) {
        throw StateError('peer_body_truncated');
      }
      _requests.remove(id);
      pending.timer?.cancel();
      pending.onFinished?.call();
      unawaited(pending.body.close());
    } else if (value['type'] == 'error') {
      _failRequest(
        id,
        http.ClientException('peer_request_failed', pending.request.url),
      );
    } else {
      throw StateError('invalid_peer_frame');
    }
  }

  void _receiveBinary(Uint8List frame) {
    if (!_channelReady || frame.length < 5 || frame.length > _chunkBytes + 4) {
      throw StateError('invalid_peer_chunk');
    }
    final id = ByteData.sublistView(frame).getUint32(0);
    final bytes = Uint8List.sublistView(frame, 4);
    final message = _messages[id];
    if (message != null) {
      if (message.bytes.length + bytes.length > message.expected) {
        throw StateError('peer_message_too_large');
      }
      message.bytes.add(bytes);
      return;
    }
    final pending = _requests[id];
    if (pending == null) return;
    if (!pending.response.isCompleted) {
      throw StateError('peer_response_headers_missing');
    }
    pending.received += bytes.length;
    if (pending.received > _maxBodyBytes ||
        (pending.expected != null && pending.received > pending.expected!)) {
      throw StateError('peer_body_too_large');
    }
    _armTimeout(id, pending);
    pending.body.add(bytes);
  }

  void _armTimeout(int id, _PeerRequest pending) {
    pending.timer?.cancel();
    pending.timer = Timer(const Duration(seconds: 30), () {
      _failRequest(id, TimeoutException('peer_request_timeout'));
      _sendCancel(id);
    });
  }

  void _cancelRequest(int id) {
    final pending = _requests.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    pending.onFinished?.call();
    _sendCancel(id);
  }

  void _failRequest(int id, Object error) {
    final pending = _requests.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    pending.onFinished?.call();
    if (pending.response.isCompleted) {
      pending.body.addError(error);
    } else {
      pending.response.completeError(error);
    }
    unawaited(pending.body.close());
  }

  void _sendCancel(int id) {
    if (isReady) {
      unawaited(
        _control({'type': 'cancel', 'id': id}).catchError((_) => _fail()),
      );
    }
  }

  Future<void> _control(Map<String, dynamic> value) async {
    await _writable();
    await _channel!.send(RTCDataChannelMessage(jsonEncode(value)));
  }

  Future<void> _binary(int id, List<int> bytes) async {
    for (var offset = 0; offset < bytes.length; offset += _chunkBytes) {
      await _writable();
      final end = (offset + _chunkBytes).clamp(0, bytes.length);
      final frame = Uint8List(4 + end - offset);
      ByteData.sublistView(frame).setUint32(0, id);
      frame.setRange(4, frame.length, bytes, offset);
      await _channel!.send(RTCDataChannelMessage.fromBinary(frame));
    }
  }

  Future<void> _writable() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!_closed &&
        _channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      if (await _channel!.getBufferedAmount() < 512 * 1024) return;
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('peer_channel_unavailable');
  }

  Future<void> _inspectPath() async {
    try {
      final stats = await _peer!.getStats().timeout(const Duration(seconds: 2));
      if (!isReady) return;
      final byId = {for (final stat in stats) stat.id: stat};
      for (final stat in stats) {
        if (stat.type != 'candidate-pair' ||
            stat.values['state'] != 'succeeded' ||
            (stat.values['nominated'] != true &&
                stat.values['selected'] != true)) {
          continue;
        }
        final local = byId[stat.values['localCandidateId']];
        final remote = byId[stat.values['remoteCandidateId']];
        path =
            local?.values['candidateType'] == 'relay' ||
                remote?.values['candidateType'] == 'relay'
            ? 'turn'
            : 'p2p';
        onReady();
        return;
      }
    } catch (_) {
      /* Diagnostics must not interrupt an established channel. */
    }
  }
}

class PeerHttpClient extends http.BaseClient {
  PeerHttpClient([this.peer]) : _fallback = http.Client();
  final RemotePeerTransport? Function()? peer;
  final http.Client _fallback;
  final _requests = <http.BaseRequest, RemotePeerTransport>{};
  bool _closed = false;

  static bool hasPeer(Uri origin, String token) {
    final peer = _activePeers[origin.origin];
    return peer?.isReady == true && peer!.token == token;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_closed) {
      return Future.error(http.ClientException('client_closed', request.url));
    }
    final transport = peer == null ? _activePeers[request.url.origin] : peer!();
    // Once sent, a failed HTTP mutation is not automatically replayed elsewhere.
    if (transport?.canSend(request) != true) return _fallback.send(request);
    _requests[request] = transport!;
    return transport
        .sendRequest(request, onFinished: () => _requests.remove(request))
        .catchError((Object error) {
          _requests.remove(request);
          throw error;
        });
  }

  @override
  void close() {
    _closed = true;
    for (final entry in _requests.entries.toList()) {
      entry.value.cancelRequest(entry.key);
    }
    _requests.clear();
    _fallback.close();
  }
}

class _PeerMessage {
  _PeerMessage(this.expected, this.timer);
  final int expected;
  final Timer timer;
  final BytesBuilder bytes = BytesBuilder(copy: false);
}

class _PeerRequest {
  _PeerRequest(this.request, this.onFinished);
  final http.BaseRequest request;
  final void Function()? onFinished;
  final Completer<http.StreamedResponse> response = Completer();
  final StreamController<List<int>> body = StreamController();
  Timer? timer;
  int received = 0;
  int? expected;
}
