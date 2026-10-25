import 'dart:convert';

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SavedSession round-trips the optional device id', () {
    final withDevice = SavedSession(
      origin: Uri.parse('https://cc.example.com'),
      token: 'token-1',
      deviceName: 'Test PC',
      deviceId: 'dev-1',
    );
    final encoded = jsonDecode(jsonEncode(withDevice.toJson()))
        as Map<String, dynamic>;
    final restored = SavedSession.fromJson(encoded);
    expect(restored.deviceId, 'dev-1');

    final withoutDevice = SavedSession(
      origin: Uri.parse('https://cc.example.com'),
      token: 'token-1',
      deviceName: 'Test PC',
    );
    final legacy = jsonDecode(
      jsonEncode(withoutDevice.toJson()),
    ) as Map<String, dynamic>;
    expect(legacy.containsKey('deviceId'), isFalse);
    expect(SavedSession.fromJson(legacy).deviceId, isNull);
    expect(withDevice.copyWith(deviceName: 'Renamed').deviceId, 'dev-1');
  });

  test('RemoteDevice parses the daemon payload', () {
    final device = RemoteDevice.tryParse({
      'id': 'dev-2',
      'name': 'Pixel Tablet',
      'pairedAt': 1792846423349,
      'lastSeen': 1792846523349,
      'current': true,
    });
    expect(device?.id, 'dev-2');
    expect(device?.name, 'Pixel Tablet');
    expect(device?.current, isTrue);
    expect(device?.lastSeen, 1792846523349);

    expect(RemoteDevice.tryParse({'id': '', 'name': 'x'}), isNull);
    expect(RemoteDevice.tryParse({'id': 'dev', 'name': 3}), isNull);
  });

  testWidgets('device manager lists devices with a local badge', (
    tester,
  ) async {
    final devices = <RemoteDevice>[
      const RemoteDevice(
        id: 'dev-1',
        name: 'Pixel 9',
        pairedAt: 1792846423349,
        lastSeen: 1792846523349,
        current: true,
      ),
      const RemoteDevice(id: 'dev-2', name: 'Pixel Tablet', pairedAt: 0, current: false),
    ];
    var fetchCount = 0;
    await _pumpManager(
      tester,
      fetchDevices: () async {
        fetchCount += 1;
        return devices;
      },
      revokeDevice: (_) async => true,
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-row-dev-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-row-dev-2')), findsOneWidget);
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('本机'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-revoke-dev-2')), findsOneWidget);
    expect(fetchCount, 1);
  });

  testWidgets('revoking another device confirms then refreshes the list', (
    tester,
  ) async {
    String? revokedId;
    final devices = <RemoteDevice>[
      const RemoteDevice(
        id: 'dev-1',
        name: 'Pixel 9',
        pairedAt: 1,
        current: true,
      ),
      const RemoteDevice(id: 'dev-2', name: 'Pixel Tablet', pairedAt: 1, current: false),
    ];
    await _pumpManager(
      tester,
      fetchDevices: () async => devices,
      revokeDevice: (id) async {
        revokedId = id;
        devices.removeWhere((device) => device.id == id);
        return true;
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('device-revoke-dev-2')));
    await tester.pumpAndSettle();
    expect(find.text('撤销「Pixel Tablet」？'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-revoke-confirm')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('device-revoke-confirm')));
    await tester.pumpAndSettle();

    expect(revokedId, 'dev-2');
    expect(find.byKey(const ValueKey('device-row-dev-2')), findsNothing);
    expect(find.byKey(const ValueKey('device-row-dev-1')), findsOneWidget);
  });

  testWidgets('cancelling the revoke dialog keeps the device', (tester) async {
    var revocations = 0;
    await _pumpManager(
      tester,
      fetchDevices: () async => const [
        RemoteDevice(id: 'dev-1', name: 'Pixel 9', pairedAt: 1, current: true),
        RemoteDevice(id: 'dev-2', name: 'Pixel Tablet', pairedAt: 1, current: false),
      ],
      revokeDevice: (_) async {
        revocations += 1;
        return true;
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('device-revoke-dev-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(revocations, 0);
    expect(find.byKey(const ValueKey('device-row-dev-2')), findsOneWidget);
  });

  testWidgets('revoking this device closes the sheet and reports back', (
    tester,
  ) async {
    var selfRevoked = false;
    String? revokedId;
    await _pumpManager(
      tester,
      fetchDevices: () async => const [
        RemoteDevice(id: 'dev-1', name: 'Pixel 9', pairedAt: 1, current: true),
      ],
      revokeDevice: (id) async {
        revokedId = id;
        return true;
      },
      onSelfRevoked: () => selfRevoked = true,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('device-revoke-dev-1')));
    await tester.pumpAndSettle();
    expect(find.text('撤销本机？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('device-revoke-confirm')));
    await tester.pumpAndSettle();

    expect(revokedId, 'dev-1');
    expect(selfRevoked, isTrue);
    expect(find.byKey(const ValueKey('devices-page')), findsNothing);
  });

  testWidgets('a devices push refreshes the list', (tester) async {
    final revision = ValueNotifier<int>(0);
    var fetchCount = 0;
    final devices = <RemoteDevice>[
      const RemoteDevice(id: 'dev-1', name: 'Pixel 9', pairedAt: 1, current: false),
    ];
    await _pumpManager(
      tester,
      fetchDevices: () async {
        fetchCount += 1;
        return devices;
      },
      revokeDevice: (_) async => true,
      revisionListenable: revision,
    );
    await tester.pumpAndSettle();
    expect(fetchCount, 1);

    devices.add(
        const RemoteDevice(id: 'dev-2', name: 'Pixel Tablet', pairedAt: 1, current: false),
      );
    revision.value += 1;
    await tester.pumpAndSettle();

    expect(fetchCount, 2);
    expect(find.byKey(const ValueKey('device-row-dev-2')), findsOneWidget);
  });
}

Future<void> _pumpManager(
  WidgetTester tester, {
  required Future<List<RemoteDevice>> Function() fetchDevices,
  required Future<bool> Function(String) revokeDevice,
  ValueListenable<int>? revisionListenable,
  VoidCallback? onSelfRevoked,
}) async {
  final revision = revisionListenable ?? ValueNotifier<int>(0);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildSignalConsoleTheme(),
      home: Scaffold(
        body: DeviceManagerPage(
          revisionListenable: revision,
          fetchDevices: fetchDevices,
          revokeDevice: revokeDevice,
          onSelfRevoked: onSelfRevoked ?? () {},
        ),
      ),
    ),
  );
}
