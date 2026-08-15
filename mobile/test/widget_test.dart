import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/main.dart';
import 'package:cc_remote/attachments.dart';
import 'package:cc_remote/camera_permission.dart';
import 'package:cc_remote/chat_background.dart';
import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/notification_service.dart';
import 'package:cc_remote/model_preference.dart';
import 'package:cc_remote/reading_font_size.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/workspace_drawer.dart';

Future<void> openSessionMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
}

Future<void> openSettingsFromHeader(WidgetTester tester) async {
  await openSessionMenu(tester);
  await tester.tap(find.text('设置').last);
  await tester.pumpAndSettle();
}

Future<void> openWorkspaceFromHeader(WidgetTester tester) async {
  await openSessionMenu(tester);
  await tester.tap(find.text('工作区').last);
  await tester.pumpAndSettle();
}

void main() {
  test('Warm Console theme uses packaged serif for UI and assistant', () {
    expect(AppTypography.fontFamily, 'NotoSerifSC');
    expect(AppTypography.assistantFontFamily, 'NotoSerifSC');
    final theme = buildSignalConsoleTheme();
    expect(theme.textTheme.bodyLarge?.fontFamily, 'NotoSerifSC');
    expect(theme.textTheme.labelLarge?.fontFamily, 'NotoSerifSC');
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('transcript snapshot round-trip preserves messages and running', () {
    final snapshot = TranscriptSnapshot(
      running: true,
      messages: [
        TranscriptMessage.user(
          'user text',
          attachments: const [
            RemoteAttachment(
              id: 'attachment-1',
              name: 'screen.png',
              mimeType: 'image/png',
              size: 1024,
            ),
          ],
        ),
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
    expect(restored.messages[0].attachments.single.name, 'screen.png');
    expect(restored.messages[1].role, MessageRole.assistant);
    expect(restored.messages[1].text, 'assistant text');
    expect(restored.messages[2].role, MessageRole.system);
    expect(restored.messages[2].text, 'system text');
    expect(restored.messages[3].role, MessageRole.activity);
    expect(restored.messages[3].activityTool, 'Read');
    expect(restored.messages[3].activityDetail, 'mobile/lib/main.dart');
  });

  test('notification preference defaults on and persists changes', () async {
    final store = NotificationPreferenceStore();
    expect(await store.load(), isTrue);
    await store.save(false);
    expect(await store.load(), isFalse);
  });

  test('chat background preference persists presets', () async {
    final store = ChatBackgroundPreferenceStore();
    const preference = ChatBackgroundPreference.preset(
      ChatBackgroundPreset.mint,
    );

    await store.save(preference);

    expect(await store.load(), preference);
  });

  test('missing custom background image falls back to default', () async {
    final store = ChatBackgroundPreferenceStore(fileExists: (_) async => false);
    await store.save(
      const ChatBackgroundPreference.localImage('missing-background.jpg'),
    );

    expect(await store.load(), ChatBackgroundPreference.defaultValue);
    expect(
      await const FlutterSecureStorage().read(
        key: ChatBackgroundPreferenceStore.key,
      ),
      isNull,
    );
  });

  test('prompt messages only include an explicit model override', () {
    final following = buildPromptMessage(
      promptId: 'prompt-1',
      text: 'hello',
      attachmentIds: const [],
      permissionMode: PermissionMode.manual,
      sessionId: 'session-1',
      model: ClaudeModelPreference.followComputer,
    );
    final opus = buildPromptMessage(
      promptId: 'prompt-2',
      text: 'hello',
      attachmentIds: const ['attachment-1'],
      permissionMode: PermissionMode.plan,
      sessionId: 'session-1',
      model: ClaudeModelPreference.opus,
    );

    expect(following, isNot(contains('model')));
    expect(following['promptId'], 'prompt-1');
    expect(opus['model'], 'opus');
    expect(opus['promptId'], 'prompt-2');
    expect(opus['attachmentIds'], ['attachment-1']);
  });

  test(
    'background notification controller stays quiet in foreground',
    () async {
      final service = FakeBackgroundNotificationService();
      final controller = BackgroundNotificationController(service: service);
      const notification = AppNotification(
        key: 'done-session-1',
        title: '任务已完成',
        body: 'cc-remote',
        sessionId: 'session-1',
      );

      await controller.notify(notification);
      expect(service.notifications, isEmpty);

      controller.lifecycleState = AppLifecycleState.paused;
      await controller.notify(notification);
      expect(service.notifications, [notification]);

      controller.enabled = false;
      await controller.notify(notification);
      expect(service.notifications, hasLength(1));
    },
  );

  test('notification body includes project, session and compact detail', () {
    expect(
      notificationBody(
        projectName: 'cc-remote',
        sessionTitle: '后台通知',
        detail: '任务\n已经完成',
      ),
      'cc-remote · 后台通知\n任务 已经完成',
    );
  });

  test('transcript store round-trip and clear', () async {
    final store = TranscriptStore();
    final snapshot = TranscriptSnapshot(
      running: true,
      modelName: 'claude-opus-4-8',
      contextWindow: 200000,
      remainingContext: 175000,
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
    expect(restored.modelName, 'claude-opus-4-8');
    expect(restored.contextWindow, 200000);
    expect(restored.remainingContext, 175000);
    expect(restored.messages.map((message) => message.text), [
      'user text',
      'assistant text',
      'system text',
    ]);

    await store.clear();

    expect(await store.load(), isNull);
  });

  test('remote status carries the current model and context', () {
    final status = RemoteStatus.fromJson({
      'deviceName': 'My PC',
      'workspaceDir': 'cc-remote',
      'running': true,
      'stopping': true,
      'runId': 'run-12',
      'startedAt': 1780000000000,
      'sessionInfo': {
        'model': 'claude-opus-4-8',
        'contextWindow': 200000,
        'remainingTokens': 175000,
      },
    });

    expect(status.modelName, 'claude-opus-4-8');
    expect(status.contextWindow, 200000);
    expect(status.remainingContext, 175000);
    expect(status.stopping, isTrue);
    expect(status.runId, 'run-12');
    expect(
      status.startedAt,
      DateTime.fromMillisecondsSinceEpoch(1780000000000),
    );
  });

  test('project catalog parses projects and independent sessions', () {
    final catalog = RemoteProjectCatalog.tryParse({
      'activeProjectId': 'project-1',
      'activeSessionId': 'session-2',
      'projects': [
        {
          'id': 'project-1',
          'name': 'cc-remote',
          'path': r'C:\Projects\cc-remote',
          'sessionCount': 2,
          'running': false,
        },
      ],
      'sessions': [
        {
          'id': 'session-2',
          'projectId': 'project-1',
          'title': '实现多会话',
          'updatedAt': 10,
          'running': true,
          'messageCount': 4,
          'model': 'claude-opus-4-8',
        },
      ],
    });

    expect(catalog, isNotNull);
    expect(catalog!.activeProject?.name, 'cc-remote');
    expect(catalog.sessions.single.title, '实现多会话');
    expect(catalog.sessions.single.summary, contains('运行中'));
  });

  testWidgets('session navigator switches projects and creates a session', (
    tester,
  ) async {
    String? createdProjectId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionNavigatorSheet(
            projects: const [
              RemoteProjectSummary(
                id: 'project-1',
                name: 'first',
                path: r'E:\first',
                sessionCount: 1,
                running: false,
              ),
              RemoteProjectSummary(
                id: 'project-2',
                name: 'second',
                path: r'E:\second',
                sessionCount: 1,
                running: false,
              ),
            ],
            sessions: const [
              RemoteSessionSummary(
                id: 'session-1',
                projectId: 'project-1',
                title: 'first task',
                updatedAt: 1,
                running: false,
                messageCount: 2,
              ),
              RemoteSessionSummary(
                id: 'session-2',
                projectId: 'project-2',
                title: 'second task',
                updatedAt: 2,
                running: false,
                messageCount: 3,
              ),
            ],
            activeProjectId: 'project-1',
            activeSessionId: 'session-1',
            running: false,
            onSelect: (_) {},
            onCreate: (projectId) => createdProjectId = projectId,
            onRename: (_, _) async {},
            onArchive: (_) async {},
            onDelete: (_) async {},
          ),
        ),
      ),
    );

    expect(find.text('first task'), findsOneWidget);
    expect(find.byKey(const ValueKey('selected-project-path')), findsOneWidget);
    expect(find.text(r'E:\first'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project-project-2')));
    await tester.pump();
    expect(find.text('second task'), findsOneWidget);
    expect(find.text(r'E:\second'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('create-session')));
    expect(createdProjectId, 'project-2');
  });

  test('remote transcript snapshot restores messages and session context', () {
    final snapshot = RemoteTranscriptSnapshot.tryParse({
      'version': 1,
      'revision': 8,
      'running': true,
      'stopping': true,
      'runId': 'run-8',
      'startedAt': 1780000000000,
      'permissionMode': 'manual',
      'pendingPermissions': [
        {
          'requestId': 'permission-1',
          'toolName': 'Bash',
          'detail': 'npm test',
          'description': 'Run tests',
        },
      ],
      'sessionInfo': {
        'model': 'claude-opus-4-8',
        'contextWindow': 200000,
        'remainingTokens': 175000,
      },
      'messages': [
        {'role': 'user', 'text': '检查项目'},
        {'role': 'assistant', 'text': '正在处理'},
        {
          'role': 'activity',
          'text': '正在读取文件',
          'activityId': 'tool-1',
          'activityKind': 'tool',
          'activityState': 'running',
          'activityTool': 'Read',
          'activityDetail': 'README.md',
        },
      ],
    });

    expect(snapshot, isNotNull);
    expect(snapshot!.revision, 8);
    expect(snapshot.running, isTrue);
    expect(snapshot.stopping, isTrue);
    expect(snapshot.runId, 'run-8');
    expect(
      snapshot.startedAt,
      DateTime.fromMillisecondsSinceEpoch(1780000000000),
    );
    expect(snapshot.messages, hasLength(3));
    expect(snapshot.messages.last.activityTool, 'Read');
    expect(snapshot.modelName, 'claude-opus-4-8');
    expect(snapshot.remainingContext, 175000);
    expect(snapshot.permissionMode, PermissionMode.manual);
    expect(snapshot.pendingPermissions.single.detail, 'npm test');
  });

  test(
    'remote transcript migration keeps local history until daemon has data',
    () {
      const emptyRemote = RemoteTranscriptSnapshot(
        revision: 0,
        running: false,
        messages: [],
        permissionMode: PermissionMode.manual,
        pendingPermissions: [],
      );
      const persistedRemote = RemoteTranscriptSnapshot(
        revision: 3,
        running: false,
        messages: [],
        permissionMode: PermissionMode.manual,
        pendingPermissions: [],
      );

      expect(
        shouldApplyRemoteTranscriptSnapshot(
          snapshot: emptyRemote,
          currentRevision: 0,
          hasLocalMessages: true,
        ),
        isFalse,
      );
      expect(
        shouldApplyRemoteTranscriptSnapshot(
          snapshot: persistedRemote,
          currentRevision: 0,
          hasLocalMessages: true,
        ),
        isTrue,
      );
      expect(
        shouldApplyRemoteTranscriptSnapshot(
          snapshot: persistedRemote,
          currentRevision: 4,
          hasLocalMessages: false,
        ),
        isFalse,
      );
      expect(
        shouldApplyRemoteTranscriptSnapshot(
          snapshot: const RemoteTranscriptSnapshot(
            revision: 4,
            running: true,
            messages: [],
            permissionMode: PermissionMode.manual,
            pendingPermissions: [],
          ),
          currentRevision: 4,
          hasLocalMessages: false,
        ),
        isTrue,
      );
    },
  );

  testWidgets('shows the app shell and advances to pairing', (tester) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );

    expect(find.text('CC Remote'), findsOneWidget);
    expect(find.text('正在检查本机连接'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));

    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
    expect(find.text('连接这台电脑'), findsOneWidget);
  });

  testWidgets('startup and pairing surfaces use warm tonal depth', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const Scaffold(body: BootstrapScreen()),
      ),
    );

    final bootstrapMark = tester.widget<Container>(
      find.byKey(const ValueKey('bootstrap-mark')),
    );
    final bootstrapDecoration = bootstrapMark.decoration! as BoxDecoration;
    expect(bootstrapDecoration.color, AppColors.surface);
    expect(bootstrapDecoration.boxShadow, isNull);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: AppBackground(
          child: PairScreen(
            enableCamera: false,
            pairing: false,
            canResetScan: false,
            onQr: (_) {},
            onClearError: () {},
            onDemoConnect: () {},
          ),
        ),
      ),
    );

    final pairPanel = tester.widget<Container>(
      find.byKey(const ValueKey('pair-status-panel')),
    );
    final pairDecoration = pairPanel.decoration! as BoxDecoration;
    expect(pairDecoration.color, AppColors.surface);
    expect(pairDecoration.boxShadow, isNull);
    expect(find.byIcon(LucideIcons.monitor), findsOneWidget);
    expect(find.text('相机已就绪'), findsOneWidget);
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
    expect(find.text('下一件事'), findsOneWidget);
    expect(find.text('从下方输入，或先点一个快捷任务'), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.byTooltip('新对话'), findsOneWidget);

    await TranscriptStore().save(
      TranscriptSnapshot(
        running: false,
        messages: [TranscriptMessage.user('persisted')],
      ),
    );

    await openSessionMenu(tester);
    expect(find.bySemanticsLabel('当前模型 Opus 4.8'), findsOneWidget);
    expect(find.textContaining('上下文'), findsNothing);
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.text('退出配对'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    expect(find.text('后台通知'), findsOneWidget);
    expect(find.text('开启新对话'), findsNothing);
    expect(find.text('扫描电脑终端里的二维码'), findsNothing);
    expect(find.text('字体大小'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('background-notifications-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('background-notifications-toggle')),
    );
    await tester.pumpAndSettle();
    expect(await NotificationPreferenceStore().load(), isFalse);

    await tester.ensureVisible(find.text('退出配对'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出配对'));
    await tester.pumpAndSettle();
    expect(find.text('退出后这台手机需要重新扫码。'), findsOneWidget);

    await tester.tap(find.text('退出').last);
    await tester.pumpAndSettle();
    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
    expect(await TranscriptStore().load(), isNull);
  });

  testWidgets('model selection persists and applies to future messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('composer-model-button')));
    await tester.pumpAndSettle();
    expect(find.text('选择模型'), findsOneWidget);
    expect(find.text('设置'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('model-option-sonnet')));
    await tester.pumpAndSettle();

    expect(find.text('Sonnet'), findsOneWidget);
    expect(
      await ClaudeModelPreferenceStore().load(),
      ClaudeModelPreference.sonnet,
    );
  });

  testWidgets('the first prompt waits for the stored model preference', (
    tester,
  ) async {
    final store = DelayedClaudeModelPreferenceStore();
    await tester.pumpWidget(
      CcRemoteApp(
        enableCamera: false,
        demoMode: true,
        modelPreferenceStore: store,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ping');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(find.byKey(const ValueKey('user-message')), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'ping',
    );

    store.completeLoad(ClaudeModelPreference.sonnet);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('user-message')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );

    await tester.tap(find.byKey(const ValueKey('composer-model-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-option-sonnet')), findsOneWidget);
  });

  testWidgets('app requests camera permission during the first startup', (
    tester,
  ) async {
    final cameraPermission = FakeCameraPermissionService();

    await tester.pumpWidget(
      CcRemoteApp(
        cameraPermissionService: cameraPermission,
        notificationService: FakeBackgroundNotificationService(),
      ),
    );
    await tester.pump();

    expect(cameraPermission.requestCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('camera permission is requested before notification permission', (
    tester,
  ) async {
    final order = <String>[];
    final cameraPermission = FakeCameraPermissionService(
      onRequest: () {
        order.add('camera');
      },
    );
    final notificationService = FakeBackgroundNotificationService()
      ..onRequestPermission = () => order.add('notification');

    await tester.pumpWidget(
      CcRemoteApp(
        cameraPermissionService: cameraPermission,
        notificationService: notificationService,
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));

    expect(order, ['camera', 'notification']);
  });

  testWidgets('camera permission is not requested again after a prior denial', (
    tester,
  ) async {
    final cameraPermission = FakeCameraPermissionService(
      statusValue: CameraPermissionState.denied,
      requestValue: CameraPermissionState.denied,
      requestOnLaunch: false,
    );

    await tester.pumpWidget(
      CcRemoteApp(
        cameraPermissionService: cameraPermission,
        notificationService: FakeBackgroundNotificationService(),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));

    expect(cameraPermission.requestCount, 0);
  });

  testWidgets('pairing screen offers a retry when camera access is denied', (
    tester,
  ) async {
    final cameraPermission = FakeCameraPermissionService(
      statusValue: CameraPermissionState.denied,
      requestValue: CameraPermissionState.denied,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: PairScreen(
          enableCamera: true,
          cameraPermissionService: cameraPermission,
          pairing: false,
          canResetScan: false,
          onQr: (_) {},
          onClearError: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('需要相机权限'), findsOneWidget);
    expect(find.text('等待相机权限'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('camera-permission-action')));
    await tester.pumpAndSettle();
    expect(cameraPermission.requestCount, 1);
  });

  testWidgets('pairing screen opens settings for permanently denied camera', (
    tester,
  ) async {
    final cameraPermission = FakeCameraPermissionService(
      statusValue: CameraPermissionState.permanentlyDenied,
      requestValue: CameraPermissionState.permanentlyDenied,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: PairScreen(
          enableCamera: true,
          cameraPermissionService: cameraPermission,
          pairing: false,
          canResetScan: false,
          onQr: (_) {},
          onClearError: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('相机权限已关闭'), findsOneWidget);
    expect(find.text('打开设置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('camera-permission-action')));
    await tester.pumpAndSettle();
    expect(cameraPermission.openSettingsCount, 1);
    expect(cameraPermission.requestCount, 0);
  });

  testWidgets('chat background can use a preset, local image and reset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const imagePath = r'C:\app\chat_background\wall.png';
    final imageService = FakeChatBackgroundImageService(imagePath);
    final store = ChatBackgroundPreferenceStore(fileExists: (_) async => true);

    await tester.pumpWidget(
      CcRemoteApp(
        enableCamera: false,
        demoMode: true,
        chatBackgroundPreferenceStore: store,
        chatBackgroundImageService: imageService,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();
    await openSettingsFromHeader(tester);

    expect(find.text('聊天背景'), findsOneWidget);
    expect(find.text('默认纸感'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('chat-background-setting')),
    );
    await tester.tap(find.byKey(const ValueKey('chat-background-setting')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('亚麻'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppBackground>(find.byType(AppBackground)).chatBackground,
      const ChatBackgroundPreference.preset(ChatBackgroundPreset.mint),
    );
    expect((await store.load()).preset, ChatBackgroundPreset.mint);

    await tester.ensureVisible(
      find.byKey(const ValueKey('pick-chat-background-image')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-chat-background-image')));
    await tester.pumpAndSettle();
    expect(imageService.pickCount, 1);
    expect((await store.load()).imagePath, imagePath);
    expect(
      find.byKey(const ValueKey('custom-chat-background-image')),
      findsWidgets,
    );

    final opacityBefore = (await store.load()).overlayOpacity;
    await tester.ensureVisible(
      find.byKey(const ValueKey('chat-background-opacity-slider')),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('chat-background-opacity-slider')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect((await store.load()).overlayOpacity, isNot(opacityBefore));

    await tester.ensureVisible(
      find.byKey(const ValueKey('reset-chat-background')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-chat-background')));
    await tester.pumpAndSettle();
    expect(await store.load(), ChatBackgroundPreference.defaultValue);
    expect(imageService.deletedPaths, contains(imagePath));
    expect(
      tester.widget<AppBackground>(find.byType(AppBackground)).chatBackground,
      ChatBackgroundPreference.defaultValue,
    );
  });

  testWidgets('saved chat background is only applied to the chat route', (
    tester,
  ) async {
    final store = ChatBackgroundPreferenceStore();
    const preference = ChatBackgroundPreference.preset(
      ChatBackgroundPreset.sunrise,
    );
    await store.save(preference);

    await tester.pumpWidget(
      CcRemoteApp(
        enableCamera: false,
        demoMode: true,
        chatBackgroundPreferenceStore: store,
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
    expect(
      tester.widget<AppBackground>(find.byType(AppBackground)).chatBackground,
      ChatBackgroundPreference.defaultValue,
    );

    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<AppBackground>(find.byType(AppBackground)).chatBackground,
      preference,
    );
  });

  testWidgets('a late background load cannot overwrite a user selection', (
    tester,
  ) async {
    final store = DelayedChatBackgroundPreferenceStore();

    await tester.pumpWidget(
      CcRemoteApp(
        enableCamera: false,
        demoMode: true,
        chatBackgroundPreferenceStore: store,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();
    await openSettingsFromHeader(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('chat-background-setting')),
    );
    await tester.tap(find.byKey(const ValueKey('chat-background-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('亚麻'));
    await tester.pumpAndSettle();

    store.completeLoad(
      const ChatBackgroundPreference.preset(ChatBackgroundPreset.sunrise),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<AppBackground>(find.byType(AppBackground)).chatBackground,
      const ChatBackgroundPreference.preset(ChatBackgroundPreset.mint),
    );
    expect(
      store.savedPreference,
      const ChatBackgroundPreference.preset(ChatBackgroundPreset.mint),
    );
  });

  testWidgets('settings remain scrollable on a short screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: Scaffold(
          body: SettingsSheet(
            session: SavedSession(
              origin: Uri.parse('https://example.test'),
              token: 'demo',
              deviceName: 'My PC',
              workspaceDir: 'cc-remote',
            ),
            notificationsEnabled: true,
            chatBackground: ChatBackgroundPreference.defaultValue,
            currentModel: 'claude-opus-4-8',
            selectedModel: ClaudeModelPreference.followComputer,
            readingFontScale: kReadingFontScaleDefault,
            onReconnect: () {},
            onNotificationsChanged: (value) async => value,
            onModelChanged: (_) async {},
            onChatBackgroundChanged: (preference) async => preference,
            onPickChatBackgroundImage: (_) async => null,
            onReadingFontScaleChanged: (scale, {bool persist = true}) async {},
            onLogout: () {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('退出配对'));
    await tester.pumpAndSettle();
    expect(find.text('退出配对').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('typing only rebuilds the prompt controls', (tester) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    final shellBefore = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );

    await tester.enterText(find.byType(TextField), 'ping');
    await tester.pump();

    expect(
      tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)),
      same(shellBefore),
    );
    expect(find.byTooltip('发送').hitTestable(), findsOneWidget);
  });

  testWidgets('keyboard resize keeps rendered messages intact', (tester) async {
    tester.view.physicalSize = const Size(393, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

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

    final markdownBefore = tester.widget<MarkdownBody>(
      find.byType(MarkdownBody),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)),
      same(markdownBefore),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard resize keeps the warm paper background stationary', (
    tester,
  ) async {
    Widget buildScreen(double keyboardInset) {
      return MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: const Size(393, 800),
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: child!,
        ),
        home: const AppBackground(
          child: SizedBox.expand(key: ValueKey('keyboard-content')),
        ),
      );
    }

    await tester.pumpWidget(buildScreen(0));
    final backgroundBefore = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-background-layer')),
        matching: find.byType(ColoredBox),
      ),
    );
    final contentHeightBefore = tester
        .getSize(find.byKey(const ValueKey('keyboard-content')))
        .height;

    await tester.pumpWidget(buildScreen(300));

    expect(backgroundBefore.color, AppColors.paper);
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byKey(const ValueKey('chat-background-layer')),
              matching: find.byType(ColoredBox),
            ),
          )
          .color,
      AppColors.paper,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('keyboard-content'))).height,
      contentHeightBefore - 300,
    );
  });

  testWidgets('warm sheet surfaces use soft paper lift', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: WarmSheetSurface(child: Text('content'))),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    final surface = tester.widget<Container>(find.byType(Container).first);
    final decoration = surface.decoration! as BoxDecoration;
    expect(decoration.color, AppColors.surfaceElevated);
    expect(decoration.boxShadow, isNotNull);
    expect(decoration.boxShadow, isNotEmpty);
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

  testWidgets('workspace drawer shows files and git diff', (tester) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    await openWorkspaceFromHeader(tester);

    expect(find.byKey(const ValueKey('workspace-files')), findsOneWidget);
    expect(find.textContaining('codex/workspace-sidebar'), findsOneWidget);

    await tester.tap(find.text('修改 2'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-changes')), findsOneWidget);

    await tester.tap(find.text('daemon.ts'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-diff')), findsOneWidget);
    expect(find.textContaining("workspace_drawer.dart"), findsOneWidget);
  });

  testWidgets(
    'workspace file preview virtualizes long content and closes its api',
    (tester) async {
      final api = ReviewWorkspaceApi();
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspaceDrawer(
            origin: Uri.parse('https://example.test'),
            token: 'test',
            workspaceName: 'review',
            api: api,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('large.txt'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('workspace-file-lines')),
        findsOneWidget,
      );
      expect(find.textContaining('[本行过长，已截断]'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(api.closed, isTrue);
    },
  );

  testWidgets('typing slash shows and filters synced commands inline', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(find.byKey(const ValueKey('command-suggestions')), findsOneWidget);
    expect(find.text('caveman:caveman-help'), findsOneWidget);
    expect(find.text('frontend-design'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/caveman');
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

  testWidgets('slash command suggestions can scroll past the first six', (
    tester,
  ) async {
    final controller = TextEditingController(text: '/');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 400,
              child: PromptBar(
                controller: controller,
                commands: List.generate(10, (index) => 'command-${index + 1}'),
                running: false,
                connected: true,
                offline: false,
                permissionMode: PermissionMode.manual,
                allowBypassPermissions: false,
                onPermissionModeSelected: (_) {},
                onCommandSelected: (_) {},
                onReconnect: () {},
                onSend: () {},
                onStop: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('command-8').hitTestable(), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('command-suggestions')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();

    expect(find.text('command-8').hitTestable(), findsOneWidget);
  });

  testWidgets('permission mode picker confirms bypass for one task', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    PermissionMode? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptBar(
            controller: controller,
            commands: const [],
            running: false,
            connected: true,
            offline: false,
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: true,
            onPermissionModeSelected: (mode) => selected = mode,
            onCommandSelected: (_) {},
            onReconnect: () {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('composer-expand-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('permission-mode-chip')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('permission-mode-bypassPermissions')),
    );
    await tester.tap(
      find.byKey(const ValueKey('permission-mode-bypassPermissions')),
    );
    await tester.pumpAndSettle();
    expect(find.text('本次任务跳过权限检查'), findsOneWidget);

    await tester.tap(find.text('仅本次开启'));
    await tester.pumpAndSettle();
    expect(selected, PermissionMode.bypassPermissions);
  });

  testWidgets('an attachment can be sent without prompt text', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sent = false;
    const attachment = AttachmentDraft(
      path: 'missing-error.log',
      name: 'error.log',
      size: 2048,
      mimeType: 'text/plain',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptBar(
            controller: controller,
            attachments: const [attachment],
            commands: const [],
            running: false,
            connected: true,
            offline: false,
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            onPermissionModeSelected: (_) {},
            onCommandSelected: (_) {},
            onAddAttachment: () {},
            onRemoveAttachment: (_) {},
            onReconnect: () {},
            onSend: () => sent = true,
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.text('error.log'), findsOneWidget);
    expect(find.byTooltip('添加内容和设置权限'), findsOneWidget);
    await tester.tap(find.byTooltip('发送'));
    expect(sent, isTrue);
  });

  testWidgets('offline prompt bar collapses to a reconnect action', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var reconnectCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptBar(
            controller: controller,
            commands: const [],
            running: false,
            connected: false,
            offline: true,
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            onPermissionModeSelected: (_) {},
            onCommandSelected: (_) {},
            onReconnect: () => reconnectCount += 1,
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.text('重新连接'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('permission-mode-chip')), findsNothing);

    await tester.tap(find.text('重新连接'));
    expect(reconnectCount, 1);
  });

  testWidgets('permission request card submits one-time approval', (
    tester,
  ) async {
    var allowed = false;
    const request = RemotePermissionRequest(
      requestId: 'permission-1',
      toolName: 'Bash',
      detail: 'npm test',
      description: 'Run tests',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PermissionRequestCard(
            request: request,
            responding: false,
            connected: true,
            workspaceDir: r'E:\client\production',
            onAllow: () => allowed = true,
            onDeny: () {},
          ),
        ),
      ),
    );

    expect(find.text('允许 Claude 运行命令？'), findsOneWidget);
    expect(find.text('npm test'), findsOneWidget);
    expect(find.text(r'E:\client\production'), findsOneWidget);
    expect(find.text('仅本次请求'), findsOneWidget);
    await tester.tap(find.text('仅本次允许'));
    expect(allowed, isTrue);
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

  test('merges thinking and tool progress but ignores completion summary', () {
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

    expect(messages[1].text, '思考完成');
    expect(messages[2].text, '已读取文件');
    expect(messages[2].activityState, ActivityState.done);
    expect(messages, hasLength(3));
  });

  test('parses stopped remote activities', () {
    final activity = RemoteActivity.tryParse({
      'id': 'tool-1',
      'kind': 'tool',
      'state': 'stopped',
    });

    expect(activity, isNotNull);
    expect(activity!.state, ActivityState.stopped);
  });

  test(
    'completed replies remove current tool activity from the transcript',
    () {
      final messages = [
        TranscriptMessage.user('上一轮'),
        TranscriptMessage.assistant('上一轮答案'),
        TranscriptMessage.user('检查项目'),
        TranscriptMessage.activity(
          '思考完成',
          id: 'thinking',
          kind: ActivityKind.thinking,
          state: ActivityState.done,
        ),
        TranscriptMessage.activity(
          '已读取文件',
          id: 'tool-1',
          kind: ActivityKind.tool,
          state: ActivityState.done,
        ),
        TranscriptMessage.assistant('当前答案'),
      ];

      removeCurrentTurnActivities(messages);

      expect(messages.map((message) => message.text), [
        '上一轮',
        '上一轮答案',
        '检查项目',
        '当前答案',
      ]);
    },
  );

  test('sending a prompt immediately adds a thinking activity', () {
    final messages = <TranscriptMessage>[];

    beginPrompt(messages, '检查项目');

    expect(messages, hasLength(2));
    expect(messages.first.role, MessageRole.user);
    expect(messages.first.text, '检查项目');
    expect(messages.last.activityKind, ActivityKind.thinking);
    expect(messages.last.activityState, ActivityState.running);
  });

  test('console presentation prioritizes offline over stale run facts', () {
    final presentation = ConsolePresentation.resolve(
      connected: false,
      offline: true,
      running: true,
      stopping: false,
      uploading: false,
    );

    expect(presentation.phase, ConsolePhase.offline);
    expect(presentation.statusLabel, '连接已断开');
    expect(presentation.showsReconnect, isTrue);
    expect(presentation.showsStop, isFalse);
    expect(presentation.canCompose, isFalse);
  });

  test('terminal evidence only applies to the current turn', () {
    final messages = <TranscriptMessage>[
      TranscriptMessage.user('第一轮'),
      TranscriptMessage.system('已停止'),
      TranscriptMessage.user('第二轮'),
      TranscriptMessage.system('停止请求未确认，任务仍在运行'),
    ];

    expect(hasConfirmedStopEvidence(messages), isFalse);
    expect(hasStopTimeoutEvidence(messages), isTrue);
    expect(hasCurrentFailureEvidence(messages), isFalse);

    messages.add(TranscriptMessage.system('错误：命令失败'));
    expect(hasCurrentFailureEvidence(messages), isTrue);
  });

  testWidgets('stop timeout remains actionable with the minimal header', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var stopCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: AppBackground(
          child: ChatScreen(
            session: SavedSession(
              origin: Uri.parse('https://cc-remote.example.com'),
              token: 'demo',
              deviceName: 'My PC',
              workspaceDir: 'cc-remote',
            ),
            running: true,
            connected: true,
            offline: false,
            modelName: 'claude-opus-4-8',
            contextWindow: 200000,
            remainingContext: 174919,
            messages: [
              TranscriptMessage.user('停止当前任务'),
              TranscriptMessage.system('停止请求未确认，任务仍在运行'),
            ],
            commands: const [],
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            promptController: controller,
            onFillPrompt: (_) {},
            onReconnect: () {},
            onOpenSettings: () {},
            onOpenModelPicker: () {},
            onNewConversation: () {},
            onOpenSessions: () {},
            onOpenWorkspace: () {},
            onPermissionModeSelected: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onSend: () {},
            onStop: () => stopCount += 1,
          ),
        ),
      ),
    );

    expect(find.textContaining('My PC'), findsNothing);
    expect(find.text('主机未确认停止，可再次尝试'), findsOneWidget);
    expect(find.byTooltip('再次停止'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('composer-primary-action')));
    expect(stopCount, 1);
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
              origin: Uri.parse('https://cc-remote.example.com'),
              token: 'demo',
              deviceName: 'My PC',
              workspaceDir: 'cc-remote',
            ),
            running: true,
            connected: true,
            offline: false,
            modelName: 'claude-opus-4-8',
            contextWindow: 200000,
            remainingContext: 174919,
            messages: [TranscriptMessage.user('你好')],
            commands: const ['review'],
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            promptController: controller,
            onFillPrompt: (_) {},
            onReconnect: () {},
            onOpenSettings: () {},
            onOpenModelPicker: () {},
            onNewConversation: () {},
            onOpenSessions: () {},
            onOpenWorkspace: () {},
            onPermissionModeSelected: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.text('CC Remote'), findsNothing);
    expect(find.text('cc-remote'), findsNothing);
    expect(find.textContaining('My PC'), findsNothing);
    expect(find.byKey(const ValueKey('session-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-model-button')), findsOneWidget);
    final newConversation = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('session-new-button')),
        matching: find.byType(IconButton),
      ),
    );
    expect(newConversation.onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('minimal header omits redundant identity and status copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: ConnectionHeader(
            session: SavedSession(
              origin: Uri.parse('https://cc-remote.example.com'),
              token: 'demo',
              deviceName: 'My PC',
              workspaceDir: 'cc-remote',
            ),
            running: false,
            connected: true,
            offline: false,
            modelName: 'claude-opus-4-8',
            contextWindow: 200000,
            remainingContext: 174919,
            onReconnect: () {},
            onOpenSettings: () {},
            onNewConversation: () {},
            onOpenSessions: () {},
            onOpenWorkspace: () {},
            uploadingAttachments: false,
          ),
        ),
      ),
    );

    expect(find.text('CC Remote'), findsNothing);
    expect(find.text('cc-remote'), findsNothing);
    expect(find.textContaining('My PC'), findsNothing);
    expect(find.textContaining('已连接'), findsNothing);
    expect(find.textContaining('已停止'), findsNothing);
  });

  testWidgets('stopping state disables the stop action and shows progress', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var stopCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: PromptBar(
            controller: controller,
            commands: const [],
            running: true,
            stopping: true,
            connected: true,
            offline: false,
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            onPermissionModeSelected: (_) {},
            onCommandSelected: (_) {},
            onReconnect: () {},
            onSend: () {},
            onStop: () => stopCount += 1,
          ),
        ),
      ),
    );

    expect(find.text('等待主机确认停止'), findsOneWidget);
    final stopButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('composer-primary-action')),
    );
    expect(stopButton.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('composer-primary-action')));
    expect(stopCount, 0);
  });

  testWidgets('route motion turns off when reduced motion is requested', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: DemoShell(enableCamera: false, demoMode: true),
        ),
      ),
    );

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(switcher.duration, Duration.zero);
    expect(switcher.reverseDuration, Duration.zero);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('signal console stays usable with large text on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: AppBackground(
            child: ChatScreen(
              session: SavedSession(
                origin: Uri.parse('https://cc-remote.example.com'),
                token: 'demo',
                deviceName: 'My PC',
                workspaceDir: 'cc-remote',
              ),
              running: true,
              connected: true,
              offline: false,
              modelName: 'claude-opus-4-8',
              contextWindow: 200000,
              remainingContext: 174919,
              messages: [TranscriptMessage.user('检查项目状态')],
              commands: const ['review'],
              permissionMode: PermissionMode.manual,
              allowBypassPermissions: false,
              pendingPermissions: const [],
              respondingPermissionIds: const {},
              promptController: controller,
              onFillPrompt: (_) {},
              onReconnect: () {},
              onOpenSettings: () {},
              onOpenModelPicker: () {},
              onNewConversation: () {},
              onOpenSessions: () {},
              onOpenWorkspace: () {},
              onPermissionModeSelected: (_) {},
              onPermissionAllow: (_) {},
              onPermissionDeny: (_) {},
              onSend: () {},
              onStop: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('停止'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('composer-primary-action'))),
      const Size.square(AppSizes.touchTarget),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'minimal session controls keep Claude-style geometry with large text',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(393, 852),
              devicePixelRatio: 1,
              textScaler: TextScaler.linear(1.35),
            ),
            child: Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: ConnectionHeader(
                    session: SavedSession(
                      origin: Uri.parse('https://cc-remote.example.com'),
                      token: 'demo',
                      deviceName: 'My PC',
                      workspaceDir: 'cc-remote',
                    ),
                    running: false,
                    connected: false,
                    offline: true,
                    modelName: 'claude-opus-4-8',
                    contextWindow: 200000,
                    remainingContext: 174919,
                    onReconnect: () {},
                    onOpenSettings: () {},
                    onNewConversation: () {},
                    onOpenSessions: () {},
                    onOpenWorkspace: () {},
                    uploadingAttachments: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const ValueKey('session-header'))).height,
        AppSizes.sessionHeader,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('session-menu-surface'))),
        const Size.square(AppSizes.touchTarget),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('session-actions-surface'))),
        const Size(AppSizes.touchTarget * 2, AppSizes.touchTarget),
      );
      expect(find.byTooltip('项目与会话'), findsOneWidget);
      expect(find.byTooltip('新对话'), findsOneWidget);
      expect(find.byTooltip('更多'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pairing screen remains scrollable in landscape', (tester) async {
    tester.view.physicalSize = const Size(812, 375);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: AppBackground(
          child: PairScreen(
            enableCamera: false,
            pairing: false,
            canResetScan: false,
            onQr: (_) {},
            onClearError: () {},
            onDemoConnect: () {},
          ),
        ),
      ),
    );

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('连接这台电脑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment upload blocks conversation navigation', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var openedSessions = false;
    var createdConversation = false;

    await tester.pumpWidget(
      MaterialApp(
        home: AppBackground(
          child: ChatScreen(
            session: SavedSession(
              origin: Uri.parse('https://cc-remote.example.com'),
              token: 'demo',
              deviceName: 'My PC',
              workspaceDir: 'cc-remote',
            ),
            running: false,
            uploadingAttachments: true,
            connected: true,
            offline: false,
            modelName: null,
            contextWindow: null,
            remainingContext: null,
            messages: const [],
            commands: const [],
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            promptController: controller,
            onFillPrompt: (_) {},
            onReconnect: () {},
            onOpenSettings: () {},
            onOpenModelPicker: () {},
            onNewConversation: () => createdConversation = true,
            onOpenSessions: () => openedSessions = true,
            onOpenWorkspace: () {},
            onPermissionModeSelected: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('项目与会话'));
    await tester.tap(find.byTooltip('新对话'));

    expect(openedSessions, isFalse);
    expect(createdConversation, isFalse);
  });

  testWidgets('assistant replies use a left aligned bubble frame', (
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
    final markdown = tester.widget<MarkdownBody>(
      find.descendant(of: assistant, matching: find.byType(MarkdownBody)),
    );
    expect(markdown.styleSheet!.tableColumnWidth, isA<IntrinsicColumnWidth>());
    expect(
      markdown.styleSheet!.tableCellsPadding,
      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    );
    expect(markdown.styleSheet!.p!.fontFamily, 'NotoSerifSC');
    expect(
      markdown.styleSheet!.p!.fontSize,
      AppTypography.assistantBodySize,
    );
    expect(markdown.styleSheet!.h1!.fontFamily, 'NotoSerifSC');
    final bubble = tester.widget<Container>(assistant);
    final decoration = bubble.decoration! as BoxDecoration;
    expect(decoration.color, AppColors.surfaceElevated);
    expect(decoration.borderRadius, isNotNull);
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const ValueKey('user-message')), findsNothing);
  });

  testWidgets('composer controls use 44 point targets and 36 point visuals', (
    tester,
  ) async {
    final controller = TextEditingController(text: '继续');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: PromptBar(
            controller: controller,
            commands: const [],
            running: false,
            connected: true,
            offline: false,
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            onPermissionModeSelected: (_) {},
            onCommandSelected: (_) {},
            onReconnect: () {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('composer-expand-button'))),
      const Size.square(AppSizes.touchTarget),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('composer-expand-visual'))),
      const Size.square(AppSizes.iconControl),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('composer-primary-action'))),
      const Size.square(AppSizes.touchTarget),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('composer-primary-visual'))),
      const Size.square(AppSizes.iconControl),
    );
  });

  testWidgets('thinking activity shows animated status and elapsed time', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBlock(
            runStartedAt: DateTime.now().subtract(const Duration(seconds: 12)),
            message: TranscriptMessage.activity(
              '正在思考',
              id: 'thinking',
              kind: ActivityKind.thinking,
              state: ActivityState.running,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('thinking-bubble')), findsOneWidget);
    expect(find.byKey(const ValueKey('thinking-icon')), findsOneWidget);
    expect(find.text('正在思考'), findsOneWidget);
    expect(find.text('12 秒'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('13 秒'), findsOneWidget);
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

  testWidgets('offline empty state keeps reconnect action at the top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 565);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reconnectCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: TranscriptView(
            messages: const [],
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            connected: false,
            offline: true,
            onFillPrompt: (_) {},
            onReconnect: () => reconnectCount += 1,
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('下一件事'), findsNothing);
    expect(find.text('让电脑重新上线'), findsOneWidget);
    expect(find.text('立即重连'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('立即重连'));
    expect(reconnectCount, 1);
  });

  testWidgets('connecting empty state does not reuse offline reconnect card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: TranscriptView(
            messages: const [],
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            connected: false,
            offline: false,
            onFillPrompt: (_) {},
            onReconnect: () {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('connecting-status-card')), findsOneWidget);
    expect(find.text('正在重新连接'), findsOneWidget);
    expect(find.text('让电脑重新上线'), findsNothing);
    expect(find.text('立即重连'), findsNothing);
  });

  testWidgets('connecting ChatScreen shows status strip', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: AppBackground(
          child: ChatScreen(
            session: SavedSession(
              origin: Uri.parse('https://cc-remote.example.com'),
              token: 'demo',
              deviceName: 'My PC',
              workspaceDir: 'cc-remote',
            ),
            running: false,
            connected: false,
            offline: false,
            modelName: 'claude-opus-4-8',
            contextWindow: 200000,
            remainingContext: 174919,
            messages: const [],
            commands: const [],
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            promptController: controller,
            onFillPrompt: (_) {},
            onReconnect: () {},
            onOpenSettings: () {},
            onOpenModelPicker: () {},
            onNewConversation: () {},
            onOpenSessions: () {},
            onOpenWorkspace: () {},
            onPermissionModeSelected: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('console-status-strip')), findsOneWidget);
    expect(find.text('正在连接'), findsOneWidget);
    expect(find.byKey(const ValueKey('connecting-status-card')), findsOneWidget);
  });

  testWidgets('TranscriptView forwards workspace path into permission card', (
    tester,
  ) async {
    const request = RemotePermissionRequest(
      requestId: 'permission-path-1',
      toolName: 'Bash',
      detail: 'ls',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: TranscriptView(
            messages: const [],
            session: SavedSession(
              origin: Uri.parse('https://cc-remote.example.com'),
              token: 'demo',
              deviceName: 'My PC',
              workspaceDir: r'E:\work\cc-remote',
            ),
            pendingPermissions: const [request],
            respondingPermissionIds: const {},
            connected: true,
            offline: false,
            onFillPrompt: (_) {},
            onReconnect: () {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
          ),
        ),
      ),
    );

    expect(find.text(r'E:\work\cc-remote'), findsOneWidget);
  });

  testWidgets('permission card falls back when workspace path is missing', (
    tester,
  ) async {
    const request = RemotePermissionRequest(
      requestId: 'permission-path-2',
      toolName: 'Bash',
      detail: 'pwd',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: PermissionRequestCard(
            request: request,
            responding: false,
            connected: true,
            onAllow: () {},
            onDeny: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('路径暂不可用'), findsOneWidget);
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

    expect(find.text('下一件事'), findsOneWidget);
    expect(find.text('从下方输入，或先点一个快捷任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slash suggestions fit above an open keyboard', (tester) async {
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

    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();

    expect(find.byKey(const ValueKey('command-suggestions')), findsOneWidget);
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

    expect(find.text('已暂停扫描，点重新扫描可继续'), findsOneWidget);

    await tester.tap(find.text('重新扫描'));
    await tester.pump();

    expect(resetCount, 1);
  });

  test('parses daemon QR pairing payload', () {
    final payload = PairingPayload.parse(
      jsonEncode({
        'type': 'cc-remote-pair',
        'version': 1,
        'origin': 'https://cc-remote.example.com',
        'nonce': 'abc123',
        'deviceName': 'My PC',
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      }),
    );

    expect(payload.origin.toString(), 'https://cc-remote.example.com');
    expect(payload.nonce, 'abc123');
    expect(payload.deviceName, 'My PC');
  });

  test('rejects expired daemon QR pairing payloads', () {
    expect(
      () => PairingPayload.parse(
        jsonEncode({
          'type': 'cc-remote-pair',
          'version': 1,
          'origin': 'https://cc-remote.example.com',
          'nonce': 'abc123',
          'expiresAt': DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
        }),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'expired_pairing_payload',
        ),
      ),
    );
  });

  test('network timeout gets a useful pairing error', () {
    expect(errorText(TimeoutException('slow')), '连接超时，请检查电脑端和隧道');
  });
}

class ReviewWorkspaceApi extends WorkspaceApi {
  ReviewWorkspaceApi()
    : super(origin: Uri.parse('https://example.test'), token: 'test');

  bool closed = false;

  @override
  Future<WorkspaceSnapshot> snapshot() async {
    return const WorkspaceSnapshot(
      rootName: 'review',
      gitAvailable: true,
      files: ['large.txt'],
      changes: [],
    );
  }

  @override
  Future<WorkspaceDocument> file(String path) async {
    return WorkspaceDocument.file(
      path,
      List.filled(20000, 'x').join(),
      truncated: false,
    );
  }

  @override
  Future<String> diff(String path, {required bool staged}) async => '';

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class FakeBackgroundNotificationService
    implements BackgroundNotificationService {
  final List<AppNotification> notifications = [];
  ValueChanged<String?>? onTap;
  bool permissionGranted = true;
  int cancelCount = 0;
  VoidCallback? onRequestPermission;

  @override
  Future<void> initialize({required ValueChanged<String?> onTap}) async {
    this.onTap = onTap;
  }

  @override
  Future<bool> requestPermission() async {
    onRequestPermission?.call();
    return permissionGranted;
  }

  @override
  Future<void> show(AppNotification notification) async {
    notifications.add(notification);
  }

  @override
  Future<void> cancelAll() async {
    cancelCount += 1;
  }
}

class FakeCameraPermissionService implements CameraPermissionService {
  FakeCameraPermissionService({
    this.statusValue = CameraPermissionState.granted,
    this.requestValue = CameraPermissionState.granted,
    this.requestOnLaunch = true,
    this.onRequest,
  });

  CameraPermissionState statusValue;
  CameraPermissionState requestValue;
  bool requestOnLaunch;
  final VoidCallback? onRequest;
  int requestCount = 0;
  int openSettingsCount = 0;

  @override
  Future<bool> openSettings() async {
    openSettingsCount += 1;
    return true;
  }

  @override
  Future<CameraPermissionState> request() async {
    requestCount += 1;
    onRequest?.call();
    return requestValue;
  }

  @override
  Future<CameraPermissionState> status() async => statusValue;

  @override
  Future<bool> shouldRequestOnLaunch() async => requestOnLaunch;
}

class FakeChatBackgroundImageService implements ChatBackgroundImageService {
  FakeChatBackgroundImageService(this.path);

  final String path;
  final List<String?> deletedPaths = [];
  int pickCount = 0;

  @override
  Future<String?> pickAndStore() async {
    pickCount += 1;
    return path;
  }

  @override
  Future<void> deleteStoredImage(String? path) async {
    deletedPaths.add(path);
  }
}

class DelayedChatBackgroundPreferenceStore
    extends ChatBackgroundPreferenceStore {
  final Completer<ChatBackgroundPreference> loadCompleter = Completer();
  ChatBackgroundPreference? savedPreference;

  @override
  Future<ChatBackgroundPreference> load() => loadCompleter.future;

  @override
  Future<void> save(ChatBackgroundPreference preference) async {
    savedPreference = preference;
  }

  void completeLoad(ChatBackgroundPreference preference) {
    loadCompleter.complete(preference);
  }
}

class DelayedClaudeModelPreferenceStore extends ClaudeModelPreferenceStore {
  final Completer<ClaudeModelPreference> loadCompleter = Completer();

  @override
  Future<ClaudeModelPreference> load() => loadCompleter.future;

  void completeLoad(ClaudeModelPreference preference) {
    loadCompleter.complete(preference);
  }
}
