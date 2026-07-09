import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/main.dart';

void main() {
  testWidgets('shows the app shell and advances to pairing', (tester) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );

    expect(find.text('CC Remote'), findsOneWidget);
    expect(find.text('正在检查本地配对信息'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));

    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
    expect(find.text('连接这台电脑'), findsOneWidget);
  });

  testWidgets('settings uses a confirmation before leaving pairing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();
    expect(find.text('本机已连接'), findsOneWidget);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('退出配对'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    expect(find.text('开启新对话'), findsOneWidget);
    expect(find.text('扫描电脑终端里的二维码'), findsNothing);

    await tester.tap(find.text('退出配对'));
    await tester.pumpAndSettle();
    expect(find.text('退出后这台手机需要重新扫码。'), findsOneWidget);

    await tester.tap(find.text('退出').last);
    await tester.pumpAndSettle();
    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
  });

  testWidgets('demo chat no longer uses the old fake project scan reply', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ping');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(find.text('ping'), findsOneWidget);
    expect(find.textContaining('真实对话需要连接 daemon WebSocket'), findsOneWidget);
    expect(find.textContaining('正在检查 `cc-remote` 的当前结构'), findsNothing);
  });

  testWidgets('new conversation clears the current transcript', (tester) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ping');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('ping'), findsOneWidget);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启新对话'));
    await tester.pumpAndSettle();

    expect(find.text('ping'), findsNothing);
    expect(find.text('已开启新对话'), findsOneWidget);
  });

  testWidgets('running state does not show a chat progress bar', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppBackground(
          child: ChatScreen(
            session: SavedSession(
              origin: Uri.parse('https://tbhaoshuai.ccwu.cc'),
              token: 'demo',
              deviceName: 'tb',
              workspaceDir: 'cc-remote',
            ),
            running: true,
            connected: true,
            offline: false,
            messages: [TranscriptMessage.user('你好')],
            promptController: controller,
            onChanged: () {},
            onFillPrompt: (_) {},
            onReconnect: () {},
            onNewConversation: () {},
            onSend: () {},
            onStop: () {},
            onLogout: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('运行中'), findsOneWidget);
    expect(find.text('新会话'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('empty transcript does not overflow when keyboard is open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    expect(find.text('本机已连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pair screen can resume after holding a scanned QR', (
    tester,
  ) async {
    var resetCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: PairScreen(
          enableCamera: false,
          pairing: false,
          canResetScan: true,
          onQr: (_) {},
          onClearError: () => resetCount += 1,
        ),
      ),
    );

    expect(find.text('已暂停扫描，点刷新可重新确认'), findsOneWidget);

    await tester.tap(find.byTooltip('重新扫描'));
    await tester.pump();

    expect(resetCount, 1);
  });

  test('parses daemon QR pairing payload', () {
    final payload = PairingPayload.parse(
      jsonEncode({
        'type': 'cc-remote-pair',
        'version': 1,
        'origin': 'https://tbhaoshuai.ccwu.cc',
        'nonce': 'abc123',
        'deviceName': 'Jayson PC',
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      }),
    );

    expect(payload.origin.toString(), 'https://tbhaoshuai.ccwu.cc');
    expect(payload.nonce, 'abc123');
    expect(payload.deviceName, 'Jayson PC');
  });

  test('network timeout gets a useful pairing error', () {
    expect(errorText(TimeoutException('slow')), '连接超时，请检查电脑端和隧道');
  });
}
