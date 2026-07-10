import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/main.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('transcript snapshot round-trip preserves messages and running', () {
    final snapshot = TranscriptSnapshot(
      running: true,
      messages: [
        TranscriptMessage.user('user text'),
        TranscriptMessage.assistant('assistant text'),
        TranscriptMessage.system('system text'),
        TranscriptMessage.activity(
          '正在读取文件',
          id: 'tool-1',
          kind: ActivityKind.tool,
          state: ActivityState.running,
          tool: 'Read',
          detail: 'mobile/lib/main.dart',
        ),
      ],
    );

    final restored = TranscriptSnapshot.fromJson(snapshot.toJson());

    expect(restored.running, isTrue);
    expect(restored.messages, hasLength(4));
    expect(restored.messages[0].role, MessageRole.user);
    expect(restored.messages[0].text, 'user text');
    expect(restored.messages[1].role, MessageRole.assistant);
    expect(restored.messages[1].text, 'assistant text');
    expect(restored.messages[2].role, MessageRole.system);
    expect(restored.messages[2].text, 'system text');
    expect(restored.messages[3].role, MessageRole.activity);
    expect(restored.messages[3].activityTool, 'Read');
    expect(restored.messages[3].activityDetail, 'mobile/lib/main.dart');
  });

  test('transcript store round-trip and clear', () async {
    final store = TranscriptStore();
    final snapshot = TranscriptSnapshot(
      running: true,
      messages: [
        TranscriptMessage.user('user text'),
        TranscriptMessage.assistant('assistant text'),
        TranscriptMessage.system('system text'),
      ],
    );

    await store.save(snapshot);
    final restored = await store.load();

    expect(restored, isNotNull);
    expect(restored!.running, isTrue);
    expect(restored.messages.map((message) => message.text), [
      'user text',
      'assistant text',
      'system text',
    ]);

    await store.clear();

    expect(await store.load(), isNull);
  });

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
    expect(find.text('有什么需要处理？'), findsOneWidget);
    expect(find.byTooltip('新对话'), findsOneWidget);

    await TranscriptStore().save(
      TranscriptSnapshot(
        running: false,
        messages: [TranscriptMessage.user('persisted')],
      ),
    );

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('退出配对'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    expect(find.text('开启新对话'), findsNothing);
    expect(find.text('扫描电脑终端里的二维码'), findsNothing);

    await tester.tap(find.text('退出配对'));
    await tester.pumpAndSettle();
    expect(find.text('退出后这台手机需要重新扫码。'), findsOneWidget);

    await tester.tap(find.text('退出').last);
    await tester.pumpAndSettle();
    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
    expect(await TranscriptStore().load(), isNull);
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

    final snapshot = await TranscriptStore().load();
    expect(snapshot, isNotNull);
    expect(snapshot!.messages.map((message) => message.text), [
      'ping',
      '演示模式：真实对话需要连接 daemon WebSocket。',
    ]);
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

    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();

    expect(find.text('ping'), findsNothing);
    expect(find.text('已开启新对话'), findsOneWidget);

    final snapshot = await TranscriptStore().load();
    expect(snapshot, isNotNull);
    expect(snapshot!.running, isFalse);
    expect(snapshot.messages.map((message) => message.text), ['已开启新对话']);
  });

  testWidgets('command picker searches and fills a synced command', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('指令'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code 指令'), findsOneWidget);
    expect(find.text('caveman:caveman-help'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'caveman');
    await tester.pump();
    expect(find.text('frontend-design'), findsNothing);

    await tester.tap(find.text('caveman:caveman-help'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '/caveman:caveman-help ',
    );
  });

  test('detects missing assistant reply after the latest user message', () {
    expect(hasAssistantReplyAfterLastUser([]), isTrue);
    expect(
      hasAssistantReplyAfterLastUser([TranscriptMessage.user('hello')]),
      isFalse,
    );
    expect(
      hasAssistantReplyAfterLastUser([
        TranscriptMessage.user('hello'),
        TranscriptMessage.system('本轮没有返回文本，请重试'),
      ]),
      isFalse,
    );
    expect(
      hasAssistantReplyAfterLastUser([
        TranscriptMessage.user('hello'),
        TranscriptMessage.assistant('hi'),
      ]),
      isTrue,
    );
  });

  test('merges thinking, tool progress, and completion summary', () {
    final messages = [TranscriptMessage.user('check project')];

    mergeRemoteActivity(
      messages,
      const RemoteActivity(
        id: 'thinking',
        kind: ActivityKind.thinking,
        state: ActivityState.running,
      ),
    );
    mergeRemoteActivity(
      messages,
      const RemoteActivity(
        id: 'tool-1',
        kind: ActivityKind.tool,
        state: ActivityState.running,
        toolName: 'Read',
        detail: 'mobile/lib/main.dart',
      ),
    );
    mergeRemoteActivity(
      messages,
      const RemoteActivity(
        id: 'tool-1',
        kind: ActivityKind.tool,
        state: ActivityState.done,
      ),
    );
    mergeRemoteActivity(
      messages,
      const RemoteActivity(
        id: 'summary',
        kind: ActivityKind.summary,
        state: ActivityState.done,
        durationMs: 8100,
        numTurns: 2,
      ),
    );

    expect(messages[1].text, '已完成分析');
    expect(messages[2].text, '已读取文件');
    expect(messages[2].activityState, ActivityState.done);
    expect(messages[3].text, '任务完成');
    expect(messages[3].activityDetail, '8.1 秒 · 1 次工具调用 · 2 轮');
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
            commands: const ['review'],
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

  testWidgets('assistant replies are unframed selectable markdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBlock(
            message: TranscriptMessage(MessageRole.assistant, 'reply'),
          ),
        ),
      ),
    );

    final assistant = find.byKey(const ValueKey('assistant-message'));
    expect(assistant, findsOneWidget);
    expect(
      find.descendant(of: assistant, matching: find.byType(MarkdownBody)),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('user-message')), findsNothing);
  });

  testWidgets('tool activity expands to show its target', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBlock(
            message: TranscriptMessage.activity(
              '正在读取文件',
              id: 'tool-1',
              kind: ActivityKind.tool,
              state: ActivityState.running,
              tool: 'Read',
              detail: 'mobile/lib/main.dart',
            ),
          ),
        ),
      ),
    );

    expect(find.text('正在读取文件'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);

    await tester.tap(find.text('正在读取文件'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SelectableText), findsOneWidget);
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

    expect(find.text('有什么需要处理？'), findsOneWidget);
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
