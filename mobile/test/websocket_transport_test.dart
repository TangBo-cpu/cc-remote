import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/data/websocket_client.dart';

void main() {
  test(
    'native WebSocket preserves a responsive peer and recovers a silent peer',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <WebSocket>[];
      final errors = <Object>[];
      final firstConnected = Completer<void>();
      final reconnected = Completer<void>();
      var connectedCount = 0;
      var answerProbes = true;
      final client = RemoteWebSocketClient(
        livenessTimeout: const Duration(milliseconds: 100),
        reconnectDelays: const [Duration(milliseconds: 10)],
      );
      addTearDown(() async {
        client.close();
        for (final peer in peers) {
          await peer.close();
        }
        await server.close(force: true);
      });

      server.listen((request) async {
        final peer = await WebSocketTransformer.upgrade(request);
        peers.add(peer);
        peer.listen((data) {
          final message = jsonDecode(data as String) as Map<String, dynamic>;
          if (message['type'] == 'auth') {
            peer.add(
              jsonEncode({
                'type': 'status',
                'authenticated': true,
                'connectionProbe': true,
                'sessionId': 'session-1',
                'running': false,
              }),
            );
          } else if (message['type'] == 'ping' && answerProbes) {
            peer.add(
              jsonEncode({'type': 'pong', 'probeId': message['probeId']}),
            );
          }
        });
      });

      client.connect(
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'test-token',
        onMessage: (_) {},
        onError: errors.add,
        onDone: () {},
        onState: (snapshot) {
          if (snapshot.phase != RemoteConnectionPhase.connected) return;
          connectedCount += 1;
          if (connectedCount == 1) firstConnected.complete();
          if (connectedCount == 2) reconnected.complete();
        },
      );
      await firstConnected.future.timeout(const Duration(seconds: 3));
      final originalChannel = client.channel;
      await client.ensureConnected(retryNow: true);

      expect(client.channel, same(originalChannel));
      expect(peers, hasLength(1));
      expect(errors, isEmpty);

      answerProbes = false;
      await client.ensureConnected();
      await reconnected.future.timeout(const Duration(seconds: 3));

      expect(client.channel, isNot(same(originalChannel)));
      expect(peers, hasLength(2));
      expect(client.isAuthenticated, isTrue);
      expect(errors.single, isA<TimeoutException>());
    },
  );
}
