import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/main.dart';

void main() {
  test('resume keeps a live socket unless reconnect is forced', () {
    expect(
      shouldPreserveLiveWebSocket(
        forceReconnect: false,
        wsReady: true,
        remoteOffline: false,
        hasChannel: true,
      ),
      isTrue,
    );
    expect(
      shouldPreserveLiveWebSocket(
        forceReconnect: true,
        wsReady: true,
        remoteOffline: false,
        hasChannel: true,
      ),
      isFalse,
    );
    expect(
      shouldPreserveLiveWebSocket(
        forceReconnect: false,
        wsReady: false,
        remoteOffline: false,
        hasChannel: true,
      ),
      isFalse,
    );
    expect(
      shouldPreserveLiveWebSocket(
        forceReconnect: false,
        wsReady: true,
        remoteOffline: true,
        hasChannel: true,
      ),
      isFalse,
    );
    expect(
      shouldPreserveLiveWebSocket(
        forceReconnect: false,
        wsReady: true,
        remoteOffline: false,
        hasChannel: false,
      ),
      isFalse,
    );
  });

  test('forces reconnect after a full liveness window in background', () {
    const livenessWindow = Duration(seconds: 60);

    expect(
      shouldForceReconnectAfterBackground(
        backgroundDuration: const Duration(seconds: 59),
        livenessThreshold: livenessWindow,
      ),
      isFalse,
    );
    expect(
      shouldForceReconnectAfterBackground(
        backgroundDuration: livenessWindow,
        livenessThreshold: livenessWindow,
      ),
      isTrue,
    );

    final forceReconnect = shouldForceReconnectAfterBackground(
      backgroundDuration: livenessWindow,
      livenessThreshold: livenessWindow,
    );
    expect(
      shouldPreserveLiveWebSocket(
        forceReconnect: forceReconnect,
        wsReady: true,
        remoteOffline: false,
        hasChannel: true,
      ),
      isFalse,
    );
  });
}
