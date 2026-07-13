import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/main.dart';
import 'package:cc_remote/attachments.dart';
import 'package:cc_remote/notification_service.dart';
import 'package:cc_remote/workspace_drawer.dart';

void main() {
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
      'deviceName': 'tb',
      'workspaceDir': 'cc-remote',
      'running': false,
      'sessionInfo': {
        'model': 'claude-opus-4-8',
        'contextWindow': 200000,
        'remainingTokens': 175000,
      },
    });

    expect(status.modelName, 'claude-opus-4-8');
    expect(status.contextWindow, 200000);
    expect(status.remainingContext, 175000);
  });

  test('project catalog parses projects and independent sessions', () {
    final catalog = RemoteProjectCatalog.tryParse({
      'activeProjectId': 'project-1',
      'activeSessionId': 'session-2',
      'projects': [
        {
          'id': 'project-1',
          'name': 'cc-remote',
          'path': r'E:\Code-All\cc-remote',
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
          ),
        ),
      ),
    );

    expect(find.text('first task'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project-project-2')));
    await tester.pump();
    expect(find.text('second task'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('create-session')));
    expect(createdProjectId, 'project-2');
  });

  test('remote transcript snapshot restores messages and session context', () {
    final snapshot = RemoteTranscriptSnapshot.tryParse({
      'version': 1,
      'revision': 8,
      'running': true,
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

  testWidgets('settings uses a confirmation before leaving pairing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();
    expect(find.text('本机已连接，可以发送任务给 Claude Code'), findsOneWidget);
    expect(find.byTooltip('工作区'), findsOneWidget);
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
    expect(find.text('后台通知'), findsOneWidget);
    expect(find.text('开启新对话'), findsNothing);
    expect(find.text('扫描电脑终端里的二维码'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('background-notifications-toggle')),
    );
    await tester.pumpAndSettle();
    expect(await NotificationPreferenceStore().load(), isFalse);

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

  testWidgets('glass panels avoid realtime backdrop blur', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: GlassPanel(child: Text('content'))),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
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

    await tester.tap(find.byTooltip('工作区'));
    await tester.pumpAndSettle();

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
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

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
            onSend: () => sent = true,
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.text('error.log'), findsOneWidget);
    expect(find.byTooltip('添加附件'), findsOneWidget);
    await tester.tap(find.byTooltip('发送'));
    expect(sent, isTrue);
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
            onAllow: () => allowed = true,
            onDeny: () {},
          ),
        ),
      ),
    );

    expect(find.text('等待权限确认'), findsOneWidget);
    expect(find.text('npm test'), findsOneWidget);
    await tester.tap(find.text('允许一次'));
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
            modelName: 'claude-opus-4-8',
            contextWindow: 200000,
            remainingContext: 174919,
            messages: [TranscriptMessage.user('你好')],
            commands: const ['review'],
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            notificationsEnabled: true,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            promptController: controller,
            onFillPrompt: (_) {},
            onReconnect: () {},
            onNotificationsChanged: (value) async => value,
            onNewConversation: () {},
            onOpenSessions: () {},
            onOpenWorkspace: () {},
            onPermissionModeSelected: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onSend: () {},
            onStop: () {},
            onLogout: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('运行中'), findsOneWidget);
    expect(find.text('Opus 4.8'), findsOneWidget);
    expect(find.text('剩余 175K / 200K'), findsOneWidget);
    expect(find.text('新会话'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
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
              origin: Uri.parse('https://tbhaoshuai.ccwu.cc'),
              token: 'demo',
              deviceName: 'tb',
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
            notificationsEnabled: true,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            promptController: controller,
            onFillPrompt: (_) {},
            onReconnect: () {},
            onNotificationsChanged: (value) async => value,
            onNewConversation: () => createdConversation = true,
            onOpenSessions: () => openedSessions = true,
            onOpenWorkspace: () {},
            onPermissionModeSelected: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onSend: () {},
            onStop: () {},
            onLogout: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('项目与会话'));
    await tester.tap(find.byTooltip('新对话'));

    expect(openedSessions, isFalse);
    expect(createdConversation, isFalse);
  });

  testWidgets('assistant replies use a left aligned markdown bubble', (
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
    expect(find.byKey(const ValueKey('assistant-avatar')), findsOneWidget);
    expect(find.byKey(const ValueKey('user-message')), findsNothing);
  });

  testWidgets('thinking activity shows animated status and elapsed time', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBlock(
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
    expect(find.text('0 秒'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1 秒'), findsOneWidget);
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

    expect(find.text('本机已连接，可以发送任务给 Claude Code'), findsOneWidget);
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

  @override
  Future<void> initialize({required ValueChanged<String?> onTap}) async {
    this.onTap = onTap;
  }

  @override
  Future<bool> requestPermission() async => permissionGranted;

  @override
  Future<void> show(AppNotification notification) async {
    notifications.add(notification);
  }

  @override
  Future<void> cancelAll() async {
    cancelCount += 1;
  }
}
