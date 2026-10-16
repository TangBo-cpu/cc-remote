import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:phosphor_icons/phosphor_icons.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cc_remote/main.dart';
import 'package:cc_remote/app_icon.dart';
import 'package:cc_remote/attachments.dart';
import 'package:cc_remote/camera_permission.dart';
import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/data/websocket_client.dart';
import 'package:cc_remote/effort_preference.dart';
import 'package:cc_remote/notification_service.dart';
import 'package:cc_remote/model_preference.dart';
import 'package:cc_remote/noto_icon.dart';
import 'package:cc_remote/reading_font_size.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/workspace_drawer.dart';
import 'package:cc_remote/workspace_paths.dart';
import 'package:cc_remote/session_interaction.dart';

bool containsWidgetSpan(InlineSpan span) {
  if (span is WidgetSpan) return true;
  if (span is TextSpan) {
    return span.children?.any(containsWidgetSpan) ?? false;
  }
  return false;
}

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
  test('console theme uses platform fonts and a restrained accent', () {
    expect(AppTypography.fontFamily, isNull);
    expect(AppTypography.assistantFontFamily, isNull);
    final theme = buildSignalConsoleTheme();
    expect(theme.textTheme.bodyLarge?.fontFamily, isNot('NotoSerifSC'));
    expect(theme.textTheme.labelLarge?.fontFamily, isNot('NotoSerifSC'));
    expect(theme.colorScheme.primary, AppColors.accentStrong);
  });

  testWidgets('compact press feedback targets 0.96 and can stay static', (
    tester,
  ) async {
    Future<void> pumpEffect({required bool scaleOnPress}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SignalPressEffect(
              scaleOnPress: scaleOnPress,
              builder: (context, pressed, child) => DecoratedBox(
                key: const ValueKey('press-surface'),
                decoration: AppLiquidGlass.thin(pressed: pressed),
                child: child,
              ),
              child: const SizedBox.square(
                key: ValueKey('press-target'),
                dimension: 44,
              ),
            ),
          ),
        ),
      );
    }

    await pumpEffect(scaleOnPress: true);
    final press = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('press-target'))),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      0.96,
    );
    expect(
      (tester
                  .widget<DecoratedBox>(
                    find.byKey(const ValueKey('press-surface')),
                  )
                  .decoration
              as BoxDecoration)
          .gradient,
      isNull,
    );
    await press.up();
    await tester.pump();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    expect(
      (tester
                  .widget<DecoratedBox>(
                    find.byKey(const ValueKey('press-surface')),
                  )
                  .decoration
              as BoxDecoration)
          .gradient,
      isNull,
    );

    await pumpEffect(scaleOnPress: false);
    final staticPress = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('press-target'))),
    );
    await tester.pump();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await staticPress.up();
  });

  testWidgets('custom app glyphs render on the product icon grid', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: Directionality(
            textDirection: TextDirection.rtl,
            child: IconTheme(
              data: const IconThemeData(color: AppColors.ink),
              child: Wrap(
                children: [
                  for (final glyph in AppGlyph.values)
                    for (final size in const [16.0, 20.0, 24.0])
                      AppIcon(glyph, size: size),
                  const AppIcon(
                    AppGlyph.back,
                    key: ValueKey('semantic-app-icon'),
                    size: 16,
                    semanticLabel: '返回',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AppIcon), findsNWidgets(AppGlyph.values.length * 3 + 1));
    expect(
      tester.getSize(find.byKey(const ValueKey('semantic-app-icon'))),
      const Size.square(16),
    );
    expect(find.bySemanticsLabel('返回'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  test(
    'effort preference persists regular levels but not session-only max',
    () async {
      final store = ClaudeEffortPreferenceStore();

      await store.save(ClaudeEffortPreference.xhigh);
      expect(await store.load(), ClaudeEffortPreference.xhigh);

      await store.save(ClaudeEffortPreference.max);
      expect(await store.load(), ClaudeEffortPreference.automatic);
    },
  );

  test(
    'prompt messages include Claude Code effort and explicit model only',
    () {
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
        effort: ClaudeEffortPreference.xhigh,
      );
      final codex = buildPromptMessage(
        promptId: 'prompt-3',
        text: 'inspect',
        attachmentIds: const ['image-1'],
        permissionMode: PermissionMode.manual,
        sessionId: 'session-2',
        model: ClaudeModelPreference.opus,
        effort: ClaudeEffortPreference.high,
        engine: SessionEngine.codex,
        codexSandboxMode: CodexSandboxMode.readOnly,
      );

      expect(following, isNot(contains('model')));
      expect(following['effort'], 'auto');
      expect(following['promptId'], 'prompt-1');
      expect(opus['model'], 'opus');
      expect(opus['effort'], 'xhigh');
      expect(opus['promptId'], 'prompt-2');
      expect(opus['attachmentIds'], ['attachment-1']);
      expect(codex['engine'], 'codex');
      expect(codex['sandboxMode'], 'read-only');
      expect(codex['effort'], 'high');
      expect(codex, isNot(contains('permissionMode')));
      expect(codex, isNot(contains('model')));
    },
  );

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
    expect(catalog.sessions.single.engine, SessionEngine.claude);
    expect(catalog.sessions.single.summary, contains('运行中'));
    expect(catalog.sessions.single.summary, contains('Opus 4.8'));
    expect(catalog.sessions.single.summary, isNot(contains('CC')));
  });

  test('session engine defaults missing and unknown values to Claude', () {
    expect(SessionEngine.fromWire(null), SessionEngine.claude);
    expect(SessionEngine.fromWire('codex'), SessionEngine.codex);
    expect(SessionEngine.fromWire('future-engine'), SessionEngine.claude);

    final unknown = RemoteSessionSummary.tryParse({
      'id': 'session-unknown',
      'projectId': 'project-1',
      'title': '未知引擎会话',
      'engine': 'future-engine',
    });

    expect(unknown, isNotNull);
    expect(unknown!.engine, SessionEngine.claude);
  });

  test('Codex sandbox capabilities keep only supported wire modes', () {
    expect(CodexSandboxMode.listFromWire(null), isNull);
    expect(
      CodexSandboxMode.listFromWire([
        'workspace-write',
        'unknown-mode',
        'read-only',
        'workspace-write',
      ]),
      [CodexSandboxMode.workspaceWrite, CodexSandboxMode.readOnly],
    );
    expect(CodexSandboxMode.listFromWire([]), [CodexSandboxMode.readOnly]);
    expect(CodexSandboxMode.listFromWire(['danger-full-access']), [
      CodexSandboxMode.dangerFullAccess,
    ]);
  });

  test('session search result parses snippet highlight metadata', () {
    final result = RemoteSessionSearchResult.tryParse({
      'sessionId': 'session-2',
      'projectId': 'project-1',
      'title': '恢复连接',
      'updatedAt': 12,
      'archived': false,
      'role': 'assistant',
      'messageIndex': 3,
      'snippet': '自动重连已经恢复',
      'matchStart': 2,
      'matchEnd': 4,
      'matchCount': 2,
      'engine': 'codex',
    });

    expect(result, isNotNull);
    expect(result!.engine, SessionEngine.codex);
    expect(result.roleLabel, 'Codex 回复');
    expect(result.snippet.substring(result.matchStart, result.matchEnd), '重连');
    expect(result.matchCount, 2);
  });

  testWidgets('session navigator switches projects and creates a session', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? createdProjectId;
    SessionEngine? createdEngine;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionNavigatorPage(
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
              engine: SessionEngine.claude,
              updatedAt: 1,
              running: false,
              messageCount: 2,
            ),
            RemoteSessionSummary(
              id: 'session-2',
              projectId: 'project-2',
              title: 'second task',
              engine: SessionEngine.codex,
              updatedAt: 2,
              running: false,
              messageCount: 3,
            ),
          ],
          activeProjectId: 'project-1',
          activeSessionId: 'session-1',
          running: false,
          onSelect: (_) {},
          onSearchResult: (_) {},
          onCreate: (projectId, engine) {
            createdProjectId = projectId;
            createdEngine = engine;
          },
          onRename: (_, _) async {},
          onArchive: (_) async {},
          onDelete: (_) async {},
          onSearch: (_) async => const [],
        ),
      ),
    );

    expect(find.text('first task'), findsOneWidget);
    expect(find.text('当前 · CC · 2 条消息'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-context-icon-home')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('project-icon-project-1'))),
      const Size.square(16),
    );
    expect(
      tester
          .widget<PhosphorIcon>(
            find.byKey(const ValueKey('project-icon-project-1')),
          )
          .icon,
      PhosphorIconsFill.cube,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('create-session'))),
      const Size.square(48),
    );
    expect(
      tester.getSize(
        find.descendant(
          of: find.byKey(const ValueKey('create-session')),
          matching: find.byType(Icon),
        ),
      ),
      const Size.square(20),
    );
    await tester.tap(find.byKey(const ValueKey('open-project-browser')));
    await tester.pump();
    expect(find.text('选择项目'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-context-icon-projects')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('session-project-view')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-home-view')), findsNothing);
    expect(find.text(r'E:\first'), findsOneWidget);
    expect(find.text(r'E:\second'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project-project-2')));
    await tester.pumpAndSettle();
    expect(find.text('second task'), findsOneWidget);
    expect(find.text('Codex · 3 条消息'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('create-session')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('session-engine-icon-claude')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('session-engine-icon-codex')),
      findsOneWidget,
    );
    expect(find.text('Claude Code'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-engine-codex')));
    await tester.pumpAndSettle();
    expect(createdProjectId, 'project-2');
    expect(createdEngine, SessionEngine.codex);
  });

  testWidgets(
    'session navigator filters sessions locally and resets per project',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: SessionNavigatorPage(
            projects: const [
              RemoteProjectSummary(
                id: 'project-1',
                name: 'first',
                path: r'E:\first',
                sessionCount: 4,
                running: true,
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
                id: 'session-running',
                projectId: 'project-1',
                title: '运行中的会话',
                engine: SessionEngine.claude,
                updatedAt: 1,
                running: true,
                messageCount: 4,
              ),
              RemoteSessionSummary(
                id: 'session-archived',
                projectId: 'project-1',
                title: '已归档的会话',
                engine: SessionEngine.codex,
                updatedAt: 2,
                running: false,
                messageCount: 5,
                archived: true,
              ),
              RemoteSessionSummary(
                id: 'session-codex',
                projectId: 'project-1',
                title: 'Codex 会话',
                engine: SessionEngine.codex,
                updatedAt: 3,
                running: false,
                messageCount: 6,
              ),
              RemoteSessionSummary(
                id: 'session-claude',
                projectId: 'project-1',
                title: 'Claude 会话',
                engine: SessionEngine.claude,
                updatedAt: 4,
                running: false,
                messageCount: 7,
              ),
              RemoteSessionSummary(
                id: 'session-other-project',
                projectId: 'project-2',
                title: '另一个项目的会话',
                engine: SessionEngine.claude,
                updatedAt: 5,
                running: false,
                messageCount: 8,
              ),
            ],
            activeProjectId: 'project-1',
            activeSessionId: 'session-claude',
            running: false,
            onSelect: (_) {},
            onSearchResult: (_) {},
            onCreate: (_, _) {},
            onRename: (_, _) async {},
            onArchive: (_) async {},
            onDelete: (_) async {},
            onSearch: (_) async => const [],
          ),
        ),
      );

      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('session-filter-all')),
            )
            .selected,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('session-session-running')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-session-archived')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-session-codex')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-session-claude')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('session-filter-running')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('session-session-running')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-session-claude')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('session-session-archived')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-session-running')),
        findsNothing,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('session-filter-codex')),
      );
      await tester.tap(find.byKey(const ValueKey('session-filter-codex')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('session-session-codex')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-session-archived')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-session-claude')),
        findsNothing,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('session-filter-claude')),
      );
      await tester.tap(find.byKey(const ValueKey('session-filter-claude')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('session-session-claude')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-session-running')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('session-session-codex')), findsNothing);
      expect(
        find.byKey(const ValueKey('session-session-archived')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('open-project-browser')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-project-2')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('session-filter-all')),
            )
            .selected,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('session-session-other-project')),
        findsOneWidget,
      );
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'session filter clears empty results on a narrow phone in ${brightness.name}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSignalConsoleTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: SessionNavigatorPage(
              projects: const [
                RemoteProjectSummary(
                  id: 'project-1',
                  name: 'first',
                  path: r'E:\first',
                  sessionCount: 1,
                  running: false,
                ),
              ],
              sessions: const [
                RemoteSessionSummary(
                  id: 'session-claude',
                  projectId: 'project-1',
                  title: 'Claude 会话',
                  engine: SessionEngine.claude,
                  updatedAt: 1,
                  running: false,
                  messageCount: 2,
                ),
              ],
              activeProjectId: 'project-1',
              activeSessionId: 'session-claude',
              running: false,
              onSelect: (_) {},
              onSearchResult: (_) {},
              onCreate: (_, _) {},
              onRename: (_, _) async {},
              onArchive: (_) async {},
              onDelete: (_) async {},
              onSearch: (_) async => const [],
            ),
          ),
        );

        await tester.ensureVisible(
          find.byKey(const ValueKey('session-filter-codex')),
        );
        await tester.tap(find.byKey(const ValueKey('session-filter-codex')));
        await tester.pump();
        expect(find.text('没有符合条件的会话'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('session-filter-clear')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('session-session-claude')),
          findsNothing,
        );

        expect(
          find.byKey(const ValueKey('session-empty-create')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('session-filter-clear')),
        );
        await tester.tap(find.byKey(const ValueKey('session-filter-clear')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('session-session-claude')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ChoiceChip>(
                find.byKey(const ValueKey('session-filter-all')),
              )
              .selected,
          isTrue,
        );
        expect(tester.takeException(), isNull);
        final animation = tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('session-filter-all')),
            )
            .chipAnimationStyle!;
        expect(animation.selectAnimation!.duration, Duration.zero);
        expect(animation.avatarDrawerAnimation!.duration, Duration.zero);
      },
    );
  }

  testWidgets('session search debounces, highlights and opens a result', (
    tester,
  ) async {
    final queries = <String>[];
    String? selectedSessionId;
    RemoteSessionSearchResult? selectedSearchResult;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: SessionNavigatorPage(
          projects: const [
            RemoteProjectSummary(
              id: 'project-1',
              name: 'cc-remote',
              path: r'E:\cc-remote',
              sessionCount: 2,
              running: false,
            ),
          ],
          sessions: const [
            RemoteSessionSummary(
              id: 'session-1',
              projectId: 'project-1',
              title: '当前会话',
              updatedAt: 1,
              running: false,
              messageCount: 2,
            ),
            RemoteSessionSummary(
              id: 'session-2',
              projectId: 'project-1',
              title: '恢复连接',
              updatedAt: 2,
              running: false,
              messageCount: 4,
            ),
          ],
          activeProjectId: 'project-1',
          activeSessionId: 'session-1',
          running: false,
          onSelect: (sessionId) => selectedSessionId = sessionId,
          onSearchResult: (result) {
            selectedSearchResult = result;
            selectedSessionId = result.sessionId;
          },
          onCreate: (_, _) {},
          onRename: (_, _) async {},
          onArchive: (_) async {},
          onDelete: (_) async {},
          onSearch: (query) async {
            queries.add(query);
            if (query != 'reconnect') return const [];
            return const [
              RemoteSessionSearchResult(
                sessionId: 'session-2',
                projectId: 'project-1',
                title: '恢复连接',
                updatedAt: 2,
                archived: false,
                role: RemoteSessionSearchRole.assistant,
                messageIndex: 3,
                snippet: 'The reconnect panel is ready.',
                matchStart: 4,
                matchEnd: 13,
                matchCount: 2,
              ),
            ];
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-session-search')));
    await tester.pump();
    final searchField = tester.widget<TextField>(
      find.byKey(const ValueKey('session-search-field')),
    );
    expect(searchField.focusNode?.hasFocus, isFalse);
    await tester.pump(AppMotion.standard - const Duration(milliseconds: 1));
    expect(searchField.focusNode?.hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(searchField.focusNode?.hasFocus, isTrue);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('session-search-field')),
      'reconnect',
    );
    await tester.pump(const Duration(milliseconds: 299));
    expect(queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(queries, ['reconnect']);
    expect(find.text('恢复连接'), findsOneWidget);
    expect(
      find.textContaining('The reconnect panel is ready.'),
      findsOneWidget,
    );
    expect(find.textContaining('2 条匹配内容'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-session-session-2')));
    expect(selectedSessionId, 'session-2');
    expect(selectedSearchResult?.messageIndex, 3);
    expect(selectedSearchResult?.snippet, 'The reconnect panel is ready.');

    await tester.enterText(
      find.byKey(const ValueKey('session-search-field')),
      'missing',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('没有找到匹配内容'), findsOneWidget);
  });

  testWidgets('running session navigator disables navigation mutations', (
    tester,
  ) async {
    var selected = false;
    var created = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SessionNavigatorPage(
          projects: const [
            RemoteProjectSummary(
              id: 'project-1',
              name: 'first',
              path: r'E:\first',
              sessionCount: 2,
              running: true,
            ),
          ],
          sessions: const [
            RemoteSessionSummary(
              id: 'session-1',
              projectId: 'project-1',
              title: 'active',
              engine: SessionEngine.claude,
              updatedAt: 2,
              running: true,
              messageCount: 1,
            ),
            RemoteSessionSummary(
              id: 'session-2',
              projectId: 'project-1',
              title: 'other',
              engine: SessionEngine.claude,
              updatedAt: 1,
              running: false,
              messageCount: 1,
            ),
          ],
          activeProjectId: 'project-1',
          activeSessionId: 'session-1',
          running: true,
          onSelect: (_) => selected = true,
          onSearchResult: (_) {},
          onCreate: (_, _) => created = true,
          onRename: (_, _) async {},
          onArchive: (_) async {},
          onDelete: (_) async {},
          onSearch: (_) async => const [],
        ),
      ),
    );

    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('create-session')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('session-session-2')))
          .onTap,
      isNotNull,
    );
    expect(find.byKey(const ValueKey('session-menu-session-2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('session-session-2')));
    expect(selected, isTrue);
    expect(created, isFalse);
  });

  testWidgets('session navigator fits a small phone with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showSessionNavigator(
                context,
                projects: const [
                  RemoteProjectSummary(
                    id: 'project-1',
                    name: 'cc-remote',
                    path: r'E:\cc-remote',
                    sessionCount: 1,
                    running: false,
                  ),
                ],
                sessions: const [
                  RemoteSessionSummary(
                    id: 'session-1',
                    projectId: 'project-1',
                    title: '当前会话',
                    engine: SessionEngine.claude,
                    updatedAt: 1,
                    running: false,
                    messageCount: 2,
                  ),
                ],
                activeProjectId: 'project-1',
                activeSessionId: 'session-1',
                running: false,
                onSelect: (_) {},
                onSearchResult: (_) {},
                onCreate: (_, _) {},
                onRename: (_, _) async {},
                onArchive: (_) async {},
                onDelete: (_) async {},
                onSearch: (_) async => const [],
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('session-navigator-page')),
      findsOneWidget,
    );
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byType(BottomSheet), findsNothing);
    final switcher = tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('session-view-switcher')),
    );
    expect(switcher.duration, Duration.zero);
    expect(switcher.reverseDuration, Duration.zero);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('open-session-search')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('session-search-field')))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('session-back-search')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('open-project-browser')));
    await tester.pump();
    expect(find.byKey(const ValueKey('session-project-view')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('session-back-projects')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('session-page-back')));
    await tester.pump();
    expect(find.byKey(const ValueKey('session-navigator-page')), findsNothing);
    expect(find.text('打开'), findsOneWidget);
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

  testWidgets('demo startup does not delay pairing', (tester) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );

    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
    expect(find.text('连接这台电脑'), findsOneWidget);
    expect(find.byKey(const ValueKey('boot')), findsNothing);
    final shellOverlay = tester
        .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        )
        .last;
    expect(shellOverlay.value.systemNavigationBarColor, AppColors.paper);
  });

  testWidgets('new Claude conversations reset to automatic permissions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('访问权限：自动判断'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('permission-mode-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('permission-mode-manual')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('访问权限：询问权限'), findsOneWidget);

    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('访问权限：自动判断'), findsOneWidget);
  });

  testWidgets('startup and pairing use plain neutral surfaces', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const Scaffold(body: BootstrapScreen()),
      ),
    );

    expect(find.byKey(const ValueKey('boot')), findsOneWidget);
    expect(find.text('CC Remote'), findsOneWidget);
    expect(find.text('正在读取连接信息'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(LucideIcons.terminal), findsNothing);
    final bootstrap = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('boot')),
    );
    expect(bootstrap.color, AppColors.paper);

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

  testWidgets('startup reports real bootstrap phases', (tester) async {
    for (final phase in BootstrapPhase.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: BootstrapScreen(key: ValueKey(phase), phase: phase),
          ),
        ),
      );

      expect(find.text(phase.label), findsOneWidget);
    }
  });

  testWidgets('startup remains static with reduced motion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const Scaffold(body: BootstrapScreen()),
      ),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: BootstrapScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byKey(const ValueKey('boot')), findsOneWidget);
  });

  testWidgets('modal surfaces honor reduced motion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) => Scaffold(
              body: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    showAttachmentSourceSheet(context, imagesOnly: true),
                child: const Text('打开附件来源'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开附件来源'));
    await tester.pump();

    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('选择图片'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup composition survives a small phone with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.6),
            disableAnimations: true,
          ),
          child: BootstrapScreen(phase: BootstrapPhase.contactingHost),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('正在检查桌面主机'), findsOneWidget);
    expect(find.text('CC Remote'), findsOneWidget);
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
    expect(find.text('接着处理 cc-remote'), findsOneWidget);
    expect(find.text('从下方输入指令，或先点一个快捷任务'), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.byTooltip('新对话'), findsOneWidget);

    await tester.showKeyboard(find.byType(TextField).last);
    expect(tester.testTextInput.isVisible, isTrue);

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
    final settingsSurface = find.byKey(const ValueKey('settings-surface'));
    expect(settingsSurface, findsOneWidget);
    expect(
      tester
          .widget<BottomSheet>(find.byType(BottomSheet))
          .animationController
          ?.duration,
      AppMotion.standard,
    );
    final settingsDecoration =
        tester.widget<Container>(settingsSurface).decoration! as BoxDecoration;
    expect(settingsDecoration.gradient, isNull);
    expect(
      find.descendant(
        of: settingsSurface,
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    expect(tester.testTextInput.isVisible, isFalse);
    expect(
      find.byKey(const ValueKey('settings-preference-preview')),
      findsNothing,
    );
    expect(find.text('后台通知'), findsOneWidget);
    expect(find.text('开启新对话'), findsNothing);
    expect(find.text('扫描电脑终端里的二维码'), findsNothing);
    expect(find.text('字体大小'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);

    await openSettingsFromHeader(tester);

    await tester.ensureVisible(
      find.byKey(const ValueKey('background-notifications-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('background-notifications-toggle')),
    );
    await tester.pumpAndSettle();
    expect(await NotificationPreferenceStore().load(), isFalse);

    await tester.scrollUntilVisible(
      find.text('退出配对'),
      300,
      scrollable: find.descendant(
        of: settingsSurface,
        matching: find.byType(Scrollable),
      ),
    );
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

    final modelButton = find.byKey(const ValueKey('composer-model-button'));
    expect(
      tester.getSize(modelButton),
      const Size.square(AppSizes.touchTarget),
    );
    expect(
      find.descendant(of: modelButton, matching: find.byType(Text)),
      findsNothing,
    );
    final modelIcon = tester.widget<NotoIcon>(
      find.descendant(of: modelButton, matching: find.byType(NotoIcon)),
    );
    expect(modelIcon.glyph, NotoGlyph.brain);
    final modelSurface = tester.widget<SignalAnimatedSurface>(
      find.byKey(const ValueKey('composer-model-visual')),
    );
    expect((modelSurface.decoration as BoxDecoration).shape, BoxShape.circle);

    await tester.tap(find.byKey(const ValueKey('composer-model-button')));
    await tester.pumpAndSettle();
    expect(find.text('选择模型'), findsOneWidget);
    expect(find.text('设置'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('model-option-sonnet')));
    await tester.pumpAndSettle();

    expect(find.byTooltip('选择模型：Sonnet'), findsOneWidget);
    expect(
      await ClaudeModelPreferenceStore().load(),
      ClaudeModelPreference.sonnet,
    );
  });

  testWidgets('model picker fits a narrow phone width', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showClaudeModelPicker(
                  context,
                  selected: ClaudeModelPreference.opus,
                ),
                child: const Text('打开模型选择器'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开模型选择器'));
    await tester.pumpAndSettle();

    expect(find.text('选择模型'), findsOneWidget);
    expect(find.byType(AppSheetSurface), findsOneWidget);
    expect(find.byType(SheetScrim), findsOneWidget);
    expect(
      tester.widget<SheetScrim>(find.byType(SheetScrim)).color,
      AppColors.scrim,
    );
    expect(find.byKey(const ValueKey('model-option-follow')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-option-fable')), findsOneWidget);

    final selectedOption = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('model-option-opus')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(selectedOption.color, AppPalette.light.accentSoft);

    final unselectedOption = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('model-option-follow')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(unselectedOption.color, Colors.transparent);
    // The Cherry Studio recipe drops the 40pt icon seat for a bare 32pt avatar,
    // so the row no longer paints a control-filled container behind the icon.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('model-option-follow')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SizedBox && widget.width == 32 && widget.height == 32,
        ),
      ),
      findsOneWidget,
    );

    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('选择模型'), findsNothing);
  });

  testWidgets('demo connect can open the session list', (tester) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('项目与会话'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-home-view')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('project-icon-demo-cc-remote')),
      findsOneWidget,
    );
  });

  testWidgets('creating a session applies the HTTP catalog without a WS push', (
    tester,
  ) async {
    var createRequests = 0;
    final client = MockClient((request) async {
      createRequests += 1;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/projects/demo-mobile/sessions');
      expect(jsonDecode(request.body), {'engine': 'codex'});
      return http.Response(
        jsonEncode({
          'ok': true,
          'projectId': 'demo-mobile',
          'sessionId': 'created-session',
          'catalog': {
            'activeProjectId': 'demo-mobile',
            'activeSessionId': 'created-session',
            'projects': [
              {
                'id': 'demo-mobile',
                'name': 'mobile',
                'path': '/workspace/cc-remote/mobile',
                'sessionCount': 1,
              },
            ],
            'sessions': [
              {
                'id': 'created-session',
                'projectId': 'demo-mobile',
                'title': '新会话',
                'engine': 'codex',
                'messageCount': 0,
              },
            ],
          },
        }),
        201,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(
        const CcRemoteApp(enableCamera: false, demoMode: true),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('连接这台电脑'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('项目与会话'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('session-demo-session-glass')),
      );
      await tester.pumpAndSettle();
      expect(find.text('玻璃控制面已经落地。'), findsOneWidget);

      await tester.tap(find.byTooltip('项目与会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-project-browser')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-demo-mobile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('create-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-engine-codex')));
      await tester.pumpAndSettle();

      expect(createRequests, 1);
      expect(find.text('新建会话失败，请重试'), findsNothing);
      expect(find.text('玻璃控制面已经落地。'), findsNothing);
      expect(
        tester.widget<ChatScreen>(find.byType(ChatScreen)).engine,
        SessionEngine.codex,
      );
      final savedSession = await TokenStore().load();
      expect(savedSession?.workspaceDir, '/workspace/cc-remote/mobile');
      expect(savedSession?.token, 'demo');
      expect((await TranscriptStore().load())?.messages, isEmpty);
      await tester.tap(find.byTooltip('项目与会话'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session-created-session')),
        findsOneWidget,
      );
      expect(find.text('当前 · Codex · 0 条消息'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-page-back')));
      await tester.pumpAndSettle();
      expect(find.byType(PromptBar), findsOneWidget);
    }, () => client);
  });

  testWidgets('demo session list can switch to another session locally', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('项目与会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-demo-session-glass')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-peek-dock')), findsNothing);
    expect(find.byType(PromptBar), findsOneWidget);
    expect(find.text('玻璃控制面已经落地。'), findsOneWidget);
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
            currentModel: 'claude-opus-4-8',
            selectedModel: ClaudeModelPreference.followComputer,
            readingFontScale: kReadingFontScaleDefault,
            onReconnect: () {},
            onNotificationsChanged: (value) async => value,
            onModelChanged: (_) async {},
            onReadingFontScaleChanged: (scale, {bool persist = true}) async {},
            onLogout: () {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('settings-surface'))).height,
      greaterThan(320),
    );
    expect(
      find.byKey(const ValueKey('settings-preference-preview')),
      findsNothing,
    );
    final settingsSurface = find.byKey(const ValueKey('settings-surface'));
    expect(
      find.descendant(of: settingsSurface, matching: find.byType(ListView)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: settingsSurface,
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.text('退出配对'),
      300,
      scrollable: find.descendant(
        of: settingsSurface,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出配对').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings notification toggle rolls back after a save error', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: SettingsSheet(
            session: null,
            notificationsEnabled: true,
            currentModel: null,
            selectedModel: ClaudeModelPreference.followComputer,
            readingFontScale: kReadingFontScaleDefault,
            onReconnect: () {},
            onNotificationsChanged: (_) async => throw StateError('save'),
            onModelChanged: (_) async {},
            onReadingFontScaleChanged: (scale, {bool persist = true}) async {},
            onLogout: () {},
          ),
        ),
      ),
    );

    final toggle = find.byKey(
      const ValueKey('background-notifications-toggle'),
    );
    await tester.scrollUntilVisible(
      toggle,
      240,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-surface')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(find.text('通知设置保存失败，请重试'), findsOneWidget);
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

    final shell = find.byKey(const ValueKey('shell-route-switcher'));
    final shellBefore = tester.widget<AnimatedSwitcher>(shell);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final composer = find.byKey(const ValueKey('composer'));
    final composerBefore = tester.widget<SignalLiquidGlass>(composer);

    for (final text in const ['p', 'pi', 'ping']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      expect(tester.widget<SignalLiquidGlass>(composer), same(composerBefore));
    }

    expect(tester.widget<AnimatedSwitcher>(shell), same(shellBefore));
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

    tester.view.viewInsets = const FakeViewPadding(bottom: 120);
    await tester.pump();
    final assistantDuringKeyboardAnimation = tester.widget(
      find.byKey(const ValueKey('assistant-message')),
    );
    final promptDuringKeyboardAnimation = tester.widget<PromptBar>(
      find.byType(PromptBar),
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    expect(
      tester.widget(find.byKey(const ValueKey('assistant-message'))),
      same(assistantDuringKeyboardAnimation),
    );
    expect(
      tester.widget<PromptBar>(find.byType(PromptBar)),
      same(promptDuringKeyboardAnimation),
    );
    final composer = tester.widget<SignalLiquidGlass>(
      find.byKey(const ValueKey('composer')),
    );
    final composerDecoration = composer.decoration;
    expect(
      composerDecoration.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(AppRadii.composerFloat)),
    );
    expect(composerDecoration.boxShadow, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard resize keeps the plain background stationary', (
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
    final backgroundBefore = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('chat-background-layer')),
    );
    final contentHeightBefore = tester
        .getSize(find.byKey(const ValueKey('keyboard-content')))
        .height;

    await tester.pumpWidget(buildScreen(300));

    final beforeDecoration = backgroundBefore.decoration as BoxDecoration;
    final backgroundAfter = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('chat-background-layer')),
    );
    final afterDecoration = backgroundAfter.decoration as BoxDecoration;
    expect(beforeDecoration.color, afterDecoration.color);
    expect(afterDecoration.gradient, isNull);
    expect(afterDecoration.color, AppColors.paper);
    expect(
      tester.getSize(find.byKey(const ValueKey('keyboard-content'))).height,
      contentHeightBefore - 300,
    );
  });

  testWidgets('app sheet surfaces use opaque neutral fills', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppSheetSurface(child: Text('content'))),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    final surface = tester.widget<Container>(find.byType(Container).first);
    final decoration = surface.decoration! as BoxDecoration;
    expect(decoration.gradient, isNull);
    expect(decoration.color, AppColors.surface);
    expect(decoration.boxShadow, isNotEmpty);
  });

  testWidgets('chat routes do not restore the composer keyboard', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Builder(
          builder: (context) => AppBackground(
            child: ChatScreen(
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
              onNewConversation: () =>
                  unawaited(showSessionEnginePicker(context)),
              onOpenSessions: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (pageContext) => Scaffold(
                      body: Center(
                        child: TextButton(
                          key: const ValueKey('test-session-back'),
                          onPressed: () => Navigator.pop(pageContext),
                          child: const Text('返回'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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

    await tester.showKeyboard(find.byType(TextField));
    await tester.tap(find.byTooltip('项目与会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-session-back')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.showKeyboard(find.byType(TextField));
    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();
    expect(find.text('选择会话引擎'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('选择会话引擎'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
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

    expect(
      find.byKey(const ValueKey('workspace-browser-page')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('workspace-files')), findsOneWidget);
    expect(find.textContaining('codex/workspace-sidebar'), findsOneWidget);

    await tester.tap(find.text('修改 2'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedAlign>(
            find.byKey(const ValueKey('workspace-tab-indicator')),
          )
          .alignment,
      Alignment.centerRight,
    );
    expect(find.byKey(const ValueKey('workspace-changes')), findsOneWidget);

    await tester.tap(find.text('daemon.ts'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workspace-document-page')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('workspace-browser-page')), findsNothing);
    expect(find.byKey(const ValueKey('workspace-diff')), findsOneWidget);
    expect(find.textContaining("workspace_drawer.dart"), findsOneWidget);
  });

  testWidgets('demo send shows a local workspace change echo', (tester) async {
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

    expect(find.byKey(const ValueKey('workspace-change-echo')), findsOneWidget);
    expect(find.text('改了 2 个文件'), findsOneWidget);
    expect(find.text('看 diff · 仅桌面工作区'), findsOneWidget);

    final snapshot = await TranscriptStore().load();
    expect(snapshot, isNotNull);
    expect(snapshot!.messages.map((message) => message.text), [
      'ping',
      '演示模式：真实对话需要连接 daemon WebSocket。',
    ]);

    await tester.ensureVisible(find.text('改了 2 个文件'));
    await tester.tap(find.text('改了 2 个文件'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-changes')), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-change-echo')), findsNothing);
  });

  testWidgets('workspace drawer opens initialPath as a change diff', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: WorkspaceDrawer(
          origin: Uri.parse('https://example.test'),
          token: 'test',
          workspaceName: 'cc-remote',
          demoMode: true,
          initialTab: 1,
          initialPath: 'src/daemon.ts',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('workspace-document-page')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('workspace-diff')), findsOneWidget);
    expect(find.textContaining('daemon.ts'), findsWidgets);
  });

  testWidgets('tapping an activity path opens the workspace portal', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: WorkspacePortal(
            workspaceDir: 'cc-remote',
            onOpenPath: (path) => opened = path,
            child: TranscriptView(
              messages: [
                TranscriptMessage.user('看文件'),
                TranscriptMessage.activity(
                  '读取文件',
                  id: 'read-1',
                  kind: ActivityKind.tool,
                  state: ActivityState.done,
                  tool: 'Read',
                  detail: 'src/daemon.ts',
                ),
              ],
              pendingPermissions: const [],
              respondingPermissionIds: const {},
              connected: true,
              onFillPrompt: (_) {},
              onReconnect: () {},
              onPermissionAllow: (_) {},
              onPermissionDeny: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('src/daemon.ts'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src/daemon.ts').last);
    expect(opened, 'src/daemon.ts');
  });

  Future<void> pumpAssistantMessage(
    WidgetTester tester, {
    required String text,
    ValueChanged<String>? onOpenPath,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: WorkspacePortal(
            onOpenPath: onOpenPath ?? (_) {},
            child: MessageBlock(message: TranscriptMessage.assistant(text)),
          ),
        ),
      ),
    );
  }

  testWidgets('unlabeled fenced code is a single code card', (tester) async {
    await pumpAssistantMessage(tester, text: '```\nsrc/daemon.ts\n```');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('code-block-card')), findsOneWidget);
    expect(find.byType(WorkspacePathText), findsNothing);
  });

  testWidgets('markdown inline code path opens the workspace portal', (
    tester,
  ) async {
    String? opened;
    await pumpAssistantMessage(
      tester,
      text: 'see `src/daemon.ts` now',
      onOpenPath: (path) => opened = path,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('src/daemon.ts'));
    expect(opened, 'src/daemon.ts');
  });

  testWidgets('markdown bold path opens the workspace portal', (tester) async {
    String? opened;
    await pumpAssistantMessage(
      tester,
      text: 'updated **src/daemon.ts**',
      onOpenPath: (path) => opened = path,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('src/daemon.ts'));
    expect(opened, 'src/daemon.ts');
  });

  testWidgets('permission summary path opens the workspace portal', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: WorkspacePortal(
            onOpenPath: (path) => opened = path,
            child: PermissionRequestCard(
              request: const RemotePermissionRequest(
                requestId: 'permission-path',
                toolName: 'Read',
                detail: 'src/daemon.ts',
              ),
              responding: false,
              connected: true,
              onAllow: () {},
              onDeny: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('src/daemon.ts'));
    expect(opened, 'src/daemon.ts');
  });

  testWidgets('workspace drawer opens initialPath as a file when unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: WorkspaceDrawer(
          origin: Uri.parse('https://example.test'),
          token: 'test',
          workspaceName: 'cc-remote',
          demoMode: true,
          initialPath: 'README.md',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workspace-document-page')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('workspace-document-file')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('workspace-diff')), findsNothing);
  });

  testWidgets('workspace drawer still opens initialPath if snapshot fails', (
    tester,
  ) async {
    final api = FailingSnapshotWorkspaceApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: WorkspaceDrawer(
          origin: Uri.parse('https://example.test'),
          token: 'test',
          workspaceName: 'review',
          api: api,
          initialPath: 'README.md',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workspace-document-file')),
      findsOneWidget,
    );
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

  testWidgets('permission mode picker confirms bypass for the conversation', (
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
            contextWindow: 200000,
            remainingContext: 174919,
            onPermissionModeSelected: (mode) => selected = mode,
            onCommandSelected: (_) {},
            onReconnect: () {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.byTooltip('访问权限：询问权限'), findsOneWidget);
    expect(find.bySemanticsLabel('上下文剩余 175K / 200K，87%'), findsOneWidget);
    expect(find.text('87%'), findsOneWidget);
    final contextRing = tester.widget<CircularProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-context-indicator')),
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    expect(contextRing.value, closeTo(0.125405, 0.000001));
    expect(contextRing.color, AppColors.inactive);
    expect(
      tester.getSize(find.byKey(const ValueKey('permission-mode-chip'))),
      const Size.square(AppSizes.touchTarget),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('permission-mode-visual'))),
      const Size.square(AppSizes.iconControl),
    );
    await tester.tap(find.byKey(const ValueKey('permission-mode-chip')));
    await tester.pumpAndSettle();
    expect(find.byType(AppSheetSurface), findsOneWidget);
    expect(find.byType(SheetScrim), findsOneWidget);
    expect(
      tester.widget<SheetScrim>(find.byType(SheetScrim)).color,
      AppColors.scrim,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('permission-mode-bypassPermissions')),
    );
    await tester.tap(
      find.byKey(const ValueKey('permission-mode-bypassPermissions')),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前对话跳过权限检查'), findsOneWidget);

    await tester.tap(find.text('对当前对话开启'));
    await tester.pumpAndSettle();
    expect(selected, PermissionMode.bypassPermissions);
  });

  testWidgets('context ring warns only when remaining context is low', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    Widget buildBar(int remaining) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 320,
            child: PromptBar(
              controller: controller,
              commands: const [],
              running: false,
              connected: true,
              offline: false,
              permissionMode: PermissionMode.manual,
              allowBypassPermissions: false,
              contextWindow: 200000,
              remainingContext: remaining,
              onPermissionModeSelected: (_) {},
              onCommandSelected: (_) {},
              onReconnect: () {},
              onSend: () {},
              onStop: () {},
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildBar(29900));
    await tester.pump();
    expect(find.bySemanticsLabel('上下文剩余 30K / 200K，15%'), findsOneWidget);
    expect(find.text('15%'), findsOneWidget);
    final warningRing = tester.widget<CircularProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-context-indicator')),
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    expect(warningRing.color, AppColors.warning);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(buildBar(30001));
    await tester.pump();
    final quietRing = tester.widget<CircularProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-context-indicator')),
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    expect(quietRing.color, AppColors.inactive);
    expect(tester.takeException(), isNull);
  });

  testWidgets('composer effort gauge supports drag, auto, and semantics', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    ClaudeEffortPreference? selected;

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
            allowBypassPermissions: false,
            selectedEffort: ClaudeEffortPreference.high,
            onEffortSelected: (effort) => selected = effort,
            onPermissionModeSelected: (_) {},
            onCommandSelected: (_) {},
            onReconnect: () {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.byTooltip('思考强度：高'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('composer-effort-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('effort-gauge-overlay')), findsOneWidget);
    expect(find.byKey(const ValueKey('effort-gauge-blur')), findsOneWidget);
    expect(find.text('高'), findsOneWidget);

    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byKey(const ValueKey('effort-gauge-control'))),
      matchesSemantics(
        label: '思考强度',
        value: '高',
        increasedValue: '超高',
        decreasedValue: '中',
        hint: '左右滑动或点击档位；双击跟随模型',
        isSlider: true,
        isFocused: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    semantics.dispose();

    final control = find.byKey(const ValueKey('effort-gauge-control'));
    final rect = tester.getRect(control);
    await tester.timedDragFrom(
      Offset(rect.left + 12, rect.top + 36),
      Offset(rect.width - 24, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(selected, ClaudeEffortPreference.max);
    expect(find.text('最大'), findsOneWidget);

    await tester.tapAt(Offset(rect.center.dx, rect.top + rect.height * 0.53));
    await tester.pumpAndSettle();
    expect(selected, ClaudeEffortPreference.automatic);
    expect(find.text('自动'), findsOneWidget);
  });

  testWidgets('Codex composer exposes advertised sandbox modes', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    CodexSandboxMode? selected;
    const advertisedModes = [
      CodexSandboxMode.readOnly,
      CodexSandboxMode.workspaceWrite,
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptBar(
            controller: controller,
            commands: const [],
            running: false,
            connected: true,
            offline: false,
            engine: SessionEngine.codex,
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            codexSandboxMode: CodexSandboxMode.readOnly,
            codexSandboxModes: advertisedModes,
            onPermissionModeSelected: (_) {},
            onCodexSandboxModeSelected: (mode) => selected = mode,
            onCommandSelected: (_) {},
            onReconnect: () {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('permission-mode-chip')));
    await tester.pumpAndSettle();

    for (final mode in advertisedModes) {
      expect(
        find.byKey(ValueKey('codex-sandbox-${mode.wireName}')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey('codex-sandbox-danger-full-access')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('permission-mode-manual')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('codex-sandbox-read-only')));
    await tester.pumpAndSettle();
    expect(selected, CodexSandboxMode.readOnly);
  });

  testWidgets('composer effort control fits a narrow phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: PromptBar(
              controller: controller,
              commands: const [],
              running: false,
              connected: true,
              offline: false,
              permissionMode: PermissionMode.manual,
              allowBypassPermissions: false,
              contextWindow: 200000,
              remainingContext: 174919,
              selectedModel: ClaudeModelPreference.sonnet,
              selectedEffort: ClaudeEffortPreference.xhigh,
              onEffortSelected: (_) {},
              onPermissionModeSelected: (_) {},
              onCommandSelected: (_) {},
              onReconnect: () {},
              onSend: () {},
              onStop: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('composer-effort-button')),
      findsOneWidget,
    );
    final contextRect = tester.getRect(
      find.byKey(const ValueKey('composer-context-indicator')),
    );
    expect(contextRect.left, greaterThanOrEqualTo(0));
    expect(contextRect.right, lessThanOrEqualTo(320));
    await tester.tap(find.byKey(const ValueKey('composer-effort-button')));
    await tester.pumpAndSettle();
    final gaugeRect = tester.getRect(
      find.byKey(const ValueKey('effort-gauge-control')),
    );
    expect(gaugeRect.left, greaterThanOrEqualTo(0));
    expect(gaugeRect.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
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
    expect(find.byTooltip('添加附件'), findsOneWidget);
    expect(find.byKey(const ValueKey('permission-mode-chip')), findsOneWidget);
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
    expect(find.text('仅本次请求'), findsNothing);
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

  test('completed replies keep thinking and tool process history', () {
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
      '思考完成',
      '已读取文件',
      '当前答案',
    ]);
  });

  test('sending a prompt immediately adds a thinking activity', () {
    final messages = <TranscriptMessage>[];

    beginPrompt(messages, '检查项目');

    expect(messages, hasLength(2));
    expect(messages.first.role, MessageRole.user);
    expect(messages.first.text, '检查项目');
    expect(messages.last.activityKind, ActivityKind.thinking);
    expect(messages.last.activityState, ActivityState.running);
  });

  test('console inputHint adapts to session engine', () {
    final claudePresentation = ConsolePresentation.resolve(
      connected: true,
      offline: false,
      running: false,
      stopping: false,
      uploading: false,
      engine: SessionEngine.claude,
    );
    expect(claudePresentation.inputHint, '输入要发给 Claude Code 的内容');

    final codexPresentation = ConsolePresentation.resolve(
      connected: true,
      offline: false,
      running: false,
      stopping: false,
      uploading: false,
      engine: SessionEngine.codex,
    );
    expect(codexPresentation.inputHint, '输入要发给 Codex 的内容');
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
    expect(presentation.canDraft, isFalse);
    expect(presentation.canQueue, isFalse);
  });

  test('running console keeps stop but allows drafting the next prompt', () {
    final presentation = ConsolePresentation.resolve(
      connected: true,
      offline: false,
      running: true,
      stopping: false,
      uploading: false,
    );

    expect(presentation.canCompose, isFalse);
    expect(presentation.canDraft, isTrue);
    expect(presentation.canQueue, isTrue);
    expect(presentation.showsStop, isTrue);
    expect(presentation.inputHint, '下一句可以先写着，点排队发送');
  });

  test('status strip defers recovery states to the shared panel', () {
    final running = ConsolePresentation.resolve(
      connected: true,
      offline: false,
      running: true,
      stopping: false,
      uploading: false,
    );
    final uploading = ConsolePresentation.resolve(
      connected: true,
      offline: false,
      running: false,
      stopping: false,
      uploading: true,
    );
    final stopping = ConsolePresentation.resolve(
      connected: true,
      offline: false,
      running: true,
      stopping: true,
      uploading: false,
    );
    final awaitingPermission = ConsolePresentation.resolve(
      connected: true,
      offline: false,
      running: true,
      stopping: false,
      uploading: false,
      awaitingPermission: true,
    );

    expect(ConsoleStatusStrip.shouldShow(running), isFalse);
    expect(ConsoleStatusStrip.shouldShow(uploading), isFalse);
    expect(ConsoleStatusStrip.shouldShow(stopping), isFalse);
    expect(ConsoleStatusStrip.shouldShow(awaitingPermission), isTrue);
    expect(RecoveryStatePanel.shouldShow(stopping), isTrue);
    expect(
      ConsoleStatusStrip.shouldShow(
        const ConsolePresentation(ConsolePhase.connected),
      ),
      isFalse,
    );
  });

  test('blank assistant text does not count as a real reply', () {
    expect(
      hasAssistantReplyAfterLastUser([
        TranscriptMessage.user('问题'),
        TranscriptMessage.assistant('  \n'),
      ]),
      isFalse,
    );
    expect(
      hasAssistantReplyAfterLastUser([
        TranscriptMessage.user('问题'),
        TranscriptMessage.assistant('答案'),
      ]),
      isTrue,
    );
  });

  test('isBlankAssistantMessage only matches empty assistant text', () {
    expect(isBlankAssistantMessage(TranscriptMessage.assistant('   ')), isTrue);
    expect(isBlankAssistantMessage(TranscriptMessage.assistant('hi')), isFalse);
    expect(isBlankAssistantMessage(TranscriptMessage.user('   ')), isFalse);
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
    expect(currentFailureDetail(messages), '命令失败');
    expect(lastUserPromptText(messages), '第二轮');
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
    expect(
      find.byKey(const ValueKey('recovery-state-stopTimedOut')),
      findsOneWidget,
    );
    expect(find.text('停止尚未确认'), findsOneWidget);
    expect(find.text('任务已停止'), findsNothing);
    expect(find.byTooltip('再次停止'), findsOneWidget);

    await tester.tap(find.text('再次停止'));
    expect(stopCount, 1);

    await tester.tap(find.byKey(const ValueKey('composer-primary-action')));
    expect(stopCount, 2);
  });

  testWidgets(
    'failed recovery panel restores the previous prompt for editing',
    (tester) async {
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
              connected: true,
              offline: false,
              modelName: 'claude-opus-4-8',
              contextWindow: 200000,
              remainingContext: 174919,
              messages: [
                TranscriptMessage.user('运行测试'),
                TranscriptMessage.system('错误：命令退出码为 1'),
              ],
              commands: const [],
              permissionMode: PermissionMode.manual,
              allowBypassPermissions: false,
              pendingPermissions: const [],
              respondingPermissionIds: const {},
              promptController: controller,
              onFillPrompt: (text) => controller.text = text,
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

      expect(
        find.byKey(const ValueKey('recovery-state-failed')),
        findsOneWidget,
      );
      expect(find.text('命令退出码为 1'), findsOneWidget);
      await tester.tap(find.text('重新编辑上条指令'));
      expect(controller.text, '运行测试');
    },
  );

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
    expect(find.byType(BackdropGroup), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
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
    expect(find.byKey(const ValueKey('session-activity-pill')), findsNothing);
  });

  testWidgets('header renders dynamic activity pill when active', (
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
            running: true,
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

    expect(find.byKey(const ValueKey('session-activity-pill')), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
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
    final stopVisual = tester.widget<Container>(
      find.byKey(const ValueKey('composer-primary-visual')),
    );
    expect(
      (stopVisual.decoration! as BoxDecoration).color,
      AppColors.composerDisabledFill,
    );
    expect(AppColors.composerDisabledFill.a, 0);

    await tester.tap(find.byKey(const ValueKey('composer-primary-action')));
    expect(stopCount, 0);
  });

  testWidgets('composer primary action morphs without replacing its button', (
    tester,
  ) async {
    final controller = TextEditingController(text: '继续');
    addTearDown(controller.dispose);
    var running = false;
    var stopping = false;
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return PromptBar(
                controller: controller,
                commands: const [],
                running: running,
                stopping: stopping,
                connected: true,
                offline: false,
                permissionMode: PermissionMode.manual,
                allowBypassPermissions: false,
                onPermissionModeSelected: (_) {},
                onCommandSelected: (_) {},
                onReconnect: () {},
                onSend: () {},
                onStop: () {},
              );
            },
          ),
        ),
      ),
    );

    final action = find.byKey(const ValueKey('composer-primary-action'));
    final actionElement = tester.element(action);
    expect(find.byKey(const ValueKey('composer-primary-send')), findsOneWidget);

    rebuild(() => running = true);
    await tester.pump(AppMotion.fast);
    expect(identical(actionElement, tester.element(action)), isTrue);
    expect(find.byKey(const ValueKey('composer-primary-stop')), findsOneWidget);
    final stopVisual = tester.widget<Container>(
      find.byKey(const ValueKey('composer-primary-visual')),
    );
    final stopDecoration = stopVisual.decoration! as BoxDecoration;
    expect(stopDecoration.color, AppColors.stopGlass);
    expect(stopDecoration.border, isNotNull);
    expect(stopDecoration.boxShadow, isNotEmpty);
    final stopIcon = tester.widget<Icon>(
      find.byKey(const ValueKey('composer-primary-stop')),
    );
    expect(stopIcon.icon, PhosphorIconsFill.square);
    expect(stopIcon.size, 14);

    rebuild(() => stopping = true);
    await tester.pump(AppMotion.fast);
    expect(identical(actionElement, tester.element(action)), isTrue);
    expect(
      find.byKey(const ValueKey('composer-primary-waiting')),
      findsOneWidget,
    );
    expect(tester.widget<IconButton>(action).onPressed, isNull);

    rebuild(() {
      running = false;
      stopping = false;
    });
    await tester.pump(AppMotion.fast);
    expect(find.byKey(const ValueKey('composer-primary-send')), findsOneWidget);
  });

  testWidgets('composer waiting cue is static with reduced motion', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: PromptBar(
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
              onStop: () {},
            ),
          ),
        ),
      ),
    );

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('composer-primary-icon-switcher')),
    );
    expect(switcher.duration, Duration.zero);
    expect(switcher.reverseDuration, Duration.zero);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('composer-primary-waiting')),
        matching: find.byIcon(LucideIcons.loader),
      ),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
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

  testWidgets('streaming Markdown is parsed only after the turn completes', (
    tester,
  ) async {
    var isStreaming = true;

    Widget buildReply() => MaterialApp(
      home: Scaffold(
        body: MessageBlock(
          message: TranscriptMessage.assistant('```dart\nvoid main() {}\n```'),
          isStreaming: isStreaming,
        ),
      ),
    );

    await tester.pumpWidget(buildReply());
    expect(find.byKey(const ValueKey('code-block-card')), findsNothing);

    isStreaming = false;
    await tester.pumpWidget(buildReply());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('code-block-card')), findsOneWidget);
  });

  testWidgets('stream text refreshes only the transcript subtree', (
    tester,
  ) async {
    final messages = <TranscriptMessage>[
      TranscriptMessage.user('上一条任务'),
      TranscriptMessage.assistant('**prior**'),
      TranscriptMessage.user('检查项目'),
    ];
    final transcriptRevision = ValueNotifier(0);
    final promptController = TextEditingController();
    addTearDown(transcriptRevision.dispose);
    addTearDown(promptController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: ChatScreen(
            session: SavedSession(
              origin: Uri.parse('https://cc-remote.example.com'),
              token: 'demo',
              deviceName: 'My PC',
            ),
            running: true,
            connected: true,
            offline: false,
            modelName: null,
            contextWindow: null,
            remainingContext: null,
            messages: messages,
            transcriptRevisionListenable: transcriptRevision,
            commands: const [],
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            promptController: promptController,
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

    expect(find.bySubtype<MarkdownBody>(), findsOneWidget);
    final header = tester.widget(find.byType(ConnectionHeader));
    messages.add(TranscriptMessage.assistant('**streaming**'));
    transcriptRevision.value++;
    await tester.pump();

    expect(find.text('**streaming**'), findsOneWidget);
    expect(find.bySubtype<MarkdownBody>(), findsOneWidget);
    expect(tester.widget(find.byType(ConnectionHeader)), same(header));
  });

  testWidgets('conversation bubbles stay distinct on light backgrounds', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageBlock(
                message: TranscriptMessage(MessageRole.assistant, 'reply'),
              ),
              MessageBlock(
                message: TranscriptMessage(
                  MessageRole.assistant,
                  '**bold** and `code`',
                ),
              ),
              MessageBlock(
                message: TranscriptMessage(MessageRole.user, '继续检查这个问题'),
              ),
            ],
          ),
        ),
      ),
    );

    final assistant = find.byKey(const ValueKey('assistant-message'));
    expect(assistant, findsNWidgets(2));
    // Plain text skips MarkdownBody; markup still uses it.
    expect(find.bySubtype<MarkdownBody>(), findsOneWidget);
    final markdown = tester.widget<MarkdownBody>(find.bySubtype<MarkdownBody>());
    expect(markdown.styleSheet!.tableColumnWidth, isA<IntrinsicColumnWidth>());
    expect(
      markdown.styleSheet!.tableCellsPadding,
      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    );
    expect(markdown.styleSheet!.p!.fontFamily, isNot('NotoSerifSC'));
    expect(markdown.styleSheet!.p!.fontSize, AppTypography.assistantBodySize);
    expect(
      markdown.styleSheet!.code!.fontSize,
      lessThan(AppTypography.assistantBodySize),
    );
    expect(
      markdown.styleSheet!.blockquote!.fontSize,
      AppTypography.assistantBodySize,
    );
    expect(
      markdown.styleSheet!.listBullet!.fontSize,
      AppTypography.assistantBodySize,
    );
    expect(
      markdown.styleSheet!.tableBody!.fontSize,
      AppTypography.assistantBodySize,
    );
    expect(
      markdown.styleSheet!.checkbox!.fontSize,
      AppTypography.assistantBodySize,
    );
    expect(markdown.styleSheet!.h1!.fontFamily, isNot('NotoSerifSC'));
    expect(markdown.styleSheet!.blockSpacing, 12);
    expect(markdown.styleSheet!.listIndent, 24);
    expect(markdown.styleSheet!.h1Padding, EdgeInsets.zero);
    expect(markdown.builders.containsKey('pre'), isTrue);
    final bubble = tester.widget<DecoratedBox>(assistant.first);
    final decoration = bubble.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(decoration.borderRadius, BorderRadius.circular(AppRadii.compact));
    expect(decoration.border, isNull);
    expect(
      decoration.boxShadow == null || decoration.boxShadow!.isEmpty,
      isTrue,
    );
    expect(find.byType(Image), findsNothing);
    final user = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('user-message')),
    );
    final userDecoration = user.decoration as BoxDecoration;
    expect(userDecoration.color, AppColors.userBubble);
    expect(userDecoration.border, isNull);
    expect(userDecoration.borderRadius, BorderRadius.circular(AppRadii.bubble));
    expect(AppColors.assistantBubble.a, 1.0);
    expect(AppColors.userBubble.a, 1.0);
  });

  testWidgets('reply layout keeps balanced gutters across message states', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final markdownText =
        '## 检查结果\n\n'
        '这是一条需要换行的回复，正文、列表和代码块应该使用同一条阅读边界。\n\n'
        '- 保持两侧留白\n- 长内容可以横向滚动\n\n'
        '> 引用内容保留内距。\n\n'
        '```dart\nfinal value = "${'long value ' * 12}";\n```\n\n'
        '| 项目 | 结果 |\n| --- | --- |\n'
        '| ${'wide table cell ' * 8} | 通过 |';

    for (final width in [320.0, 390.0, 1024.0]) {
      tester.view.physicalSize = Size(width, 844);
      final contentWidth = (width > 760 ? 760.0 : width) - 40;
      final gutter = (width - contentWidth) / 2;
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          for (final reply in [
            (text: '好', streaming: false),
            (text: markdownText, streaming: true),
            (text: markdownText, streaming: false),
          ]) {
            await tester.pumpWidget(
              MaterialApp(
                key: ValueKey((width, brightness, scale, reply)),
                theme: buildSignalConsoleTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: ChatScreen(
                    session: null,
                    activeSessionId: 'layout',
                    running: reply.streaming,
                    connected: true,
                    offline: false,
                    modelName: null,
                    contextWindow: null,
                    remainingContext: null,
                    messages: [TranscriptMessage.assistant(reply.text)],
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
            await tester.pumpAndSettle();

            final frame = tester.getRect(
              find.byKey(const ValueKey('assistant-message')),
            );
            expect(frame.left, closeTo(gutter, 0.01));
            expect(width - frame.right, closeTo(gutter, 0.01));
            expect(frame.width, closeTo(contentWidth, 0.01));
            if (!reply.streaming && reply.text == markdownText) {
              final code = tester.getRect(
                find.byKey(const ValueKey('code-block-card')),
              );
              expect(code.left, closeTo(frame.left, 0.01));
              expect(code.right, closeTo(frame.right, 0.01));
              final tableViewport = tester.getRect(
                find
                    .ancestor(
                      of: find.byType(Table),
                      matching: find.byType(SingleChildScrollView),
                    )
                    .first,
              );
              expect(tableViewport.left, greaterThanOrEqualTo(frame.left));
              expect(tableViewport.right, lessThanOrEqualTo(frame.right));
            }
            expect(tester.takeException(), isNull);
          }
        }
      }
    }
  });

  test('search source links accept only absolute web URLs', () {
    expect(
      searchSourceUri('https://example.com/report?q=source'),
      Uri.parse('https://example.com/report?q=source'),
    );
    expect(searchSourceUri('http://example.com/source'), isNotNull);
    expect(searchSourceUri('javascript:alert(1)'), isNull);
    expect(searchSourceUri('/relative/source'), isNull);
    expect(searchSourceUri('https://'), isNull);
  });

  testWidgets('assistant search source links are actionable', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    MethodCall? launchCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          launchCall = call;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBlock(
            message: TranscriptMessage(
              MessageRole.assistant,
              '[搜索来源](https://example.com/report)',
            ),
          ),
        ),
      ),
    );

    final markdown = tester.widget<MarkdownBody>(find.bySubtype<MarkdownBody>());
    expect(markdown.onTapLink, isNotNull);
    expect(find.text('搜索来源'), findsOneWidget);

    await tester.tap(find.text('搜索来源'));
    await tester.pump();

    expect(launchCall?.method, 'launch');
    final arguments = launchCall!.arguments as Map<Object?, Object?>;
    expect(arguments['url'], 'https://example.com/report');
    expect(arguments['useWebView'], isFalse);
  });

  testWidgets('composer controls keep 48 point targets and emphasize send', (
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
      const Size.square(40),
    );
    final sendVisual = tester.widget<Container>(
      find.byKey(const ValueKey('composer-primary-visual')),
    );
    final sendDecoration = sendVisual.decoration! as BoxDecoration;
    expect(sendDecoration.color, AppColors.cta);
    expect(sendDecoration.boxShadow, isNotEmpty);
    final sendIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-primary-visual')),
        matching: find.byType(Icon),
      ),
    );
    expect(sendIcon.size, 20);

    controller.clear();
    await tester.pump();
    expect(
      (tester
                  .widget<Container>(
                    find.byKey(const ValueKey('composer-primary-visual')),
                  )
                  .decoration!
              as BoxDecoration)
          .color,
      AppColors.glassControl,
    );
    controller.text = '继续';
    await tester.pump();
    final rail = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('composer-control-rail')),
    );
    final railDecoration = rail.decoration as BoxDecoration;
    expect(railDecoration.color, AppColors.composerControlRest);
    expect(railDecoration.boxShadow, isNull);

    final expandSurface = tester.widget<SignalAnimatedSurface>(
      find.byKey(const ValueKey('composer-expand-visual')),
    );
    final expandDecoration = expandSurface.decoration as BoxDecoration;
    expect(expandDecoration.color, Colors.transparent);
    expect(expandDecoration.boxShadow, isNull);

    final modelSurface = tester.widget<SignalAnimatedSurface>(
      find.byKey(const ValueKey('composer-model-visual')),
    );
    final modelDecoration = modelSurface.decoration as BoxDecoration;
    expect(modelDecoration.color, Colors.transparent);
    expect(modelDecoration.boxShadow, isNull);

    final press = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('permission-mode-chip'))),
    );
    await tester.pump();
    expect(
      (tester
                  .widget<SignalAnimatedSurface>(
                    find.byKey(const ValueKey('permission-mode-visual')),
                  )
                  .decoration
              as BoxDecoration)
          .color,
      AppColors.composerControlPressed,
    );
    await press.up();
    await tester.pump();
    final composer = tester.widget<SignalLiquidGlass>(
      find.byKey(const ValueKey('composer')),
    );
    final decoration = composer.decoration;
    expect(decoration.gradient, isNull);
    expect(decoration.border, isNotNull);
    expect(
      decoration.borderRadius,
      BorderRadius.circular(AppRadii.composerFloat),
    );
    expect(decoration.boxShadow, isNotEmpty);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('composer')),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );

    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    final focusedDecoration = tester
        .widget<SignalLiquidGlass>(find.byKey(const ValueKey('composer')))
        .decoration;
    final focusedBorder = focusedDecoration.border! as Border;
    expect(focusedBorder.top.color, AppPalette.light.liquidFocus);
    expect(focusedBorder.top.width, 2);
  });

  test('transcript spacing groups supporting rows within each turn', () {
    final user = TranscriptMessage.user('问题');
    final assistant = TranscriptMessage.assistant('回答');
    final activity = TranscriptMessage.activity(
      '正在检查',
      id: 'spacing-activity',
      kind: ActivityKind.tool,
      state: ActivityState.running,
    );

    expect(transcriptGapBetween(user, assistant), 12);
    expect(transcriptGapBetween(user, activity), 12);
    expect(transcriptGapBetween(activity, assistant), 4);
    expect(transcriptGapBetween(assistant, activity), 12);
    expect(transcriptGapBetween(assistant, user), 20);
    expect(transcriptGapBetween(assistant, assistant), 6);
  });

  testWidgets('thinking activity shows a shimmering text disclosure', (
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
              detail: '先检查状态。',
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('thinking-bubble')), findsOneWidget);
    expect(find.text('思考中'), findsOneWidget);
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.text('先检查状态。', findRichText: true), findsOneWidget);
    final liveStatus = tester.getSemantics(
      find.bySemanticsLabel('思考中，本轮已运行 12 秒'),
    );
    expect(liveStatus.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('先检查状态。', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thinking shimmer stays still when animations are disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ThinkingHistoryBlock(
              message: TranscriptMessage.activity(
                '正在思考',
                id: 'thinking',
                kind: ActivityKind.thinking,
                state: ActivityState.running,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('思考中'), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expanded reasoning receives streamed Markdown without a preview',
    (tester) async {
      Widget buildReasoning(String detail) => MaterialApp(
        home: Scaffold(
          body: ThinkingHistoryBlock(
            message: TranscriptMessage.activity(
              '正在思考',
              id: 'thinking',
              kind: ActivityKind.thinking,
              state: ActivityState.running,
              detail: detail,
            ),
          ),
        ),
      );

      await tester.pumpWidget(buildReasoning('第一句。'));
      expect(find.text('第一句。', findRichText: true), findsOneWidget);
      await tester.pumpWidget(buildReasoning('第一句。第二句。'));
      expect(find.text('第一句。第二句。', findRichText: true), findsOneWidget);
      expect(
        find.byKey(const ValueKey('thinking-history-content')),
        findsOneWidget,
      );
    },
  );

  testWidgets('completed thinking activity stays as collapsible history', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: MessageBlock(
            message: TranscriptMessage.activity(
              '思考完成',
              id: 'thinking-done',
              kind: ActivityKind.thinking,
              state: ActivityState.done,
              detail: '先检查状态。再整理结果。',
              durationMs: 4200,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('thinking-bubble')), findsOneWidget);
    expect(find.text('已深度思考'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsNothing,
    );
    expect(find.text('先检查状态。再整理结果。', findRichText: true), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsNothing,
    );
  });

  testWidgets('consecutive tool activities render an inline sequence', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: TranscriptView(
            messages: [
              TranscriptMessage.user('跑一下检查'),
              TranscriptMessage.activity(
                '读取文件',
                id: 't1',
                kind: ActivityKind.tool,
                state: ActivityState.done,
                tool: 'Read',
                detail: 'README.md',
              ),
              TranscriptMessage.activity(
                '搜索代码',
                id: 't2',
                kind: ActivityKind.tool,
                state: ActivityState.done,
                tool: 'Grep',
                detail: 'needle pattern',
              ),
              TranscriptMessage.activity(
                '运行测试',
                id: 't3',
                kind: ActivityKind.tool,
                state: ActivityState.running,
                tool: 'Bash',
              ),
              TranscriptMessage.assistant('完成'),
            ],
            session: null,
            activeSessionId: null,
            runStartedAt: null,
            running: true,
            connected: true,
            offline: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            onFillPrompt: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onReconnect: () {},
          ),
        ),
      ),
    );

    expect(find.byType(ActivityTimelineCard), findsOneWidget);
    expect(find.text('运行命令'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('activity-step-toggle-t1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activity-step-toggle-t2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activity-step-toggle-t3')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('activity-step-toggle-t1')), findsNothing);
    expect(
      find.byKey(const ValueKey('activity-step-toggle-t2')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('needle pattern'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-t2')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('activity-detail-t2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-t2')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('needle pattern'), findsOneWidget);
  });

  testWidgets('skill activity shows its name and inline detail', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: TranscriptView(
            messages: [
              TranscriptMessage.user('搜索绍兴市中心美食'),
              TranscriptMessage.activity(
                '已调用技能',
                id: 'skill-1',
                kind: ActivityKind.tool,
                state: ActivityState.done,
                tool: 'Skill',
                detail: 'agent-reach',
              ),
              TranscriptMessage.assistant('找到以下推荐'),
            ],
            session: null,
            activeSessionId: null,
            runStartedAt: null,
            running: false,
            connected: true,
            offline: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            onFillPrompt: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onReconnect: () {},
          ),
        ),
      ),
    );

    expect(find.byType(ActivityTimelineCard), findsOneWidget);
    expect(find.text('使用技能 · agent-reach'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-step-toggle-skill-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('已调用技能'), findsOneWidget);
    expect(find.text('agent-reach'), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activity-step-toggle-skill-1')),
        matching: find.byType(SmartIcon),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('activity-step-toggle-skill-1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('activity-detail-skill-1')), findsNothing);
    expect(find.text('agent-reach'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('activity-step-toggle-skill-1')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity-detail-skill-1')),
      findsOneWidget,
    );
  });

  testWidgets('code blocks render language header with working copy button', (
    tester,
  ) async {
    String? copiedText;
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBlock(
            message: TranscriptMessage.assistant(
              '看这段：\n\n```dart\nvoid main() {}\n```\n',
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('code-block-card')), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    final card = tester.widget<Container>(
      find.byKey(const ValueKey('code-block-card')),
    );
    final cardDecoration = card.decoration as BoxDecoration;
    expect(
      cardDecoration.border,
      Border.all(color: AppPalette.light.line, width: 0.8),
    );
    expect(cardDecoration.color, AppColors.control);

    await tester.tap(find.byKey(const ValueKey('code-copy-button')));
    await tester.pump();
    expect(copiedText, 'void main() {}');
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('assistant replies can be selected and copied in full', (
    tester,
  ) async {
    String? copiedText;
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );

    await pumpAssistantMessage(tester, text: '先改 daemon 启动参数');
    expect(find.byType(AssistantSelectionArea), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);

    await tester.longPress(find.text('先改 daemon 启动参数'));
    await tester.pumpAndSettle();
    expect(find.text('复制全部'), findsOneWidget);

    await tester.tap(find.text('复制全部'));
    await tester.pumpAndSettle();
    expect(copiedText, '先改 daemon 启动参数');
  });

  testWidgets('markdown assistant replies stay inside a selection area', (
    tester,
  ) async {
    await pumpAssistantMessage(tester, text: '- 先跑测试\n- 再看 `src/daemon.ts`');
    await tester.pumpAndSettle();
    expect(find.bySubtype<MarkdownBody>(), findsOneWidget);
    expect(find.byType(AssistantSelectionArea), findsOneWidget);
    expect(find.textContaining('先跑测试'), findsOneWidget);
  });

  testWidgets('blank assistant messages are not rendered', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: TranscriptView(
            messages: [
              TranscriptMessage.user('问题'),
              TranscriptMessage.assistant('   \n'),
              TranscriptMessage.assistant('有内容的回复'),
            ],
            session: null,
            activeSessionId: null,
            runStartedAt: null,
            running: false,
            connected: true,
            offline: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            onFillPrompt: (_) {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onReconnect: () {},
          ),
        ),
      ),
    );

    expect(find.text('问题'), findsOneWidget);
    expect(find.text('有内容的回复'), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-message')), findsOneWidget);
  });

  testWidgets('transcript search jump scrolls to and highlights the message', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messages = <TranscriptMessage>[
      TranscriptMessage.system('本地连接提示'),
      for (var index = 0; index < 140; index++)
        if (index == 125)
          TranscriptMessage.user('target needle appears here')
        else if (index % 11 == 0)
          TranscriptMessage.assistant(
            List.generate(
              18,
              (line) => 'long message $index line $line',
            ).join('\n'),
          )
        else
          TranscriptMessage.user('message $index'),
    ];
    TranscriptJumpRequest? handledRequest;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: TranscriptView(
            messages: messages,
            jumpRequest: const TranscriptJumpRequest(
              generation: 1,
              sessionId: 'session-1',
              // The local system row shifts the daemon index by one. The
              // snippet fallback must still resolve the authoritative hit.
              messageIndex: 125,
              role: RemoteSessionSearchRole.user,
              snippet: 'target needle appears here',
            ),
            activeSessionId: 'session-1',
            connected: true,
            offline: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            onFillPrompt: (_) {},
            onReconnect: () {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
            onJumpHandled: (request) => handledRequest = request,
          ),
        ),
      ),
    );

    for (var attempt = 0; attempt < 60 && handledRequest == null; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(handledRequest?.generation, 1);
    expect(
      find.byKey(const ValueKey('transcript-search-hit-126')),
      findsOneWidget,
    );
    final target = find.text('target needle appears here');
    expect(target, findsOneWidget);
    final targetRect = tester.getRect(target);
    expect(targetRect.top, greaterThanOrEqualTo(0));
    expect(targetRect.bottom, lessThanOrEqualTo(720));

    await tester.pump(const Duration(milliseconds: 1601));
    expect(
      find.byKey(const ValueKey('transcript-search-hit-126')),
      findsNothing,
    );
  });

  testWidgets('transcript opens at the latest message', (tester) async {
    tester.view.physicalSize = const Size(393, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: TranscriptView(
            messages: [
              for (var index = 0; index < 80; index++)
                TranscriptMessage.user('restored message $index'),
            ],
            activeSessionId: 'session-1',
            connected: true,
            offline: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            onFillPrompt: (_) {},
            onReconnect: () {},
            onPermissionAllow: (_) {},
            onPermissionDeny: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('transcript-list')),
    );
    final position = list.controller!.position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.extentAfter, lessThan(1));
    expect(find.text('restored message 79'), findsOneWidget);
  });

  testWidgets('new output stays visible while reading and returns to latest', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messages = <TranscriptMessage>[
      for (var index = 0; index < 80; index++)
        TranscriptMessage.user('message $index'),
    ];
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return TranscriptView(
                messages: messages,
                activeSessionId: 'session-1',
                running: true,
                connected: true,
                offline: false,
                pendingPermissions: const [],
                respondingPermissionIds: const {},
                onFillPrompt: (_) {},
                onReconnect: () {},
                onPermissionAllow: (_) {},
                onPermissionDeny: (_) {},
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final controller = tester
        .widget<ListView>(find.byKey(const ValueKey('transcript-list')))
        .controller!;
    controller.jumpTo(0);
    await tester.pump();

    rebuild(() => messages.add(TranscriptMessage.assistant('新的输出')));
    await tester.pump();
    expect(find.byKey(const ValueKey('transcript-new-output')), findsOneWidget);
    expect(find.text('1 条新输出 · 仍在运行'), findsOneWidget);

    rebuild(
      () => messages[messages.length - 1] = TranscriptMessage.assistant(
        '新的输出，继续流式追加',
      ),
    );
    await tester.pump();
    expect(find.text('1 条新输出 · 仍在运行'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('transcript-new-output')));
    await tester.pumpAndSettle();
    expect(controller.position.extentAfter, lessThan(1));
    expect(find.byKey(const ValueKey('transcript-new-output')), findsNothing);
  });

  testWidgets('tool activity shows its target inline and folds in place', (
    tester,
  ) async {
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

    expect(find.text('读取文件'), findsOneWidget);
    expect(find.text('mobile/lib/main.dart'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool-1')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
    expect(find.text('mobile/lib/main.dart'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool-1')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('mobile/lib/main.dart'), findsOneWidget);
  });

  testWidgets('offline recovery panel keeps one reconnect action', (
    tester,
  ) async {
    var reconnectCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: RecoveryStatePanel(
            presentation: const ConsolePresentation(ConsolePhase.offline),
            hostLabel: 'My PC',
            reconnectSnapshot: RemoteConnectionSnapshot(
              phase: RemoteConnectionPhase.retrying,
              attempt: 3,
              nextRetryAt: DateTime.now().add(const Duration(seconds: 30)),
              lastError: StateError('connection refused'),
            ),
            hasTranscript: true,
            hasDraft: true,
            onReconnect: () => reconnectCount += 1,
            onStop: () {},
            onOpenWorkspace: () {},
          ),
        ),
      ),
    );

    expect(find.text('正在自动重连'), findsOneWidget);
    expect(find.textContaining('自动重连第 3 次'), findsOneWidget);
    expect(find.textContaining('约 30 秒后再次尝试'), findsOneWidget);
    expect(find.textContaining('电脑端拒绝连接'), findsOneWidget);
    expect(find.text('对话记录已保留，当前输入仍在编辑框中'), findsOneWidget);
    expect(find.text('立即重连'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('约 29 秒后再次尝试'), findsOneWidget);

    await tester.tap(find.text('立即重连'));
    expect(reconnectCount, 1);
  });

  testWidgets('connecting uses the shared panel without reconnect action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: RecoveryStatePanel(
            presentation: const ConsolePresentation(ConsolePhase.connecting),
            onReconnect: () {},
            onStop: () {},
            onOpenWorkspace: () {},
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('recovery-state-connecting')),
      findsOneWidget,
    );
    expect(find.text('正在连接电脑端'), findsOneWidget);
    expect(find.text('立即重连'), findsNothing);
  });

  testWidgets('recovery states morph in place and briefly confirm completion', (
    tester,
  ) async {
    var presentation = const ConsolePresentation(ConsolePhase.connecting);
    var reconnectSnapshot = const RemoteConnectionSnapshot.idle();
    Object? completionEvent;
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return RecoveryStatePanel(
                presentation: presentation,
                completionEvent: completionEvent,
                reconnectSnapshot: reconnectSnapshot,
                onReconnect: () {},
                onStop: () {},
                onOpenWorkspace: () {},
              );
            },
          ),
        ),
      ),
    );

    final panel = find.byKey(const ValueKey('recovery-state-panel'));
    final panelElement = tester.element(panel);
    rebuild(() {
      presentation = const ConsolePresentation(ConsolePhase.offline);
      reconnectSnapshot = RemoteConnectionSnapshot(
        phase: RemoteConnectionPhase.retrying,
        attempt: 1,
        nextRetryAt: DateTime.now().add(const Duration(seconds: 5)),
      );
    });
    await tester.pump(AppMotion.fast);
    expect(identical(panelElement, tester.element(panel)), isTrue);
    expect(
      find.byKey(const ValueKey('recovery-state-offline')),
      findsOneWidget,
    );

    rebuild(() {
      presentation = const ConsolePresentation(ConsolePhase.running);
      reconnectSnapshot = const RemoteConnectionSnapshot.idle();
    });
    await tester.pump(AppMotion.standard);
    rebuild(() {
      presentation = const ConsolePresentation(ConsolePhase.connected);
      completionEvent = Object();
    });
    await tester.pump();
    expect(
      find.byKey(const ValueKey('recovery-state-completed')),
      findsOneWidget,
    );
    expect(find.text('任务已完成'), findsOneWidget);

    await tester.pump(AppMotion.signal);
    await tester.pump(AppMotion.standard);
    expect(
      find.byKey(const ValueKey('recovery-state-completed')),
      findsNothing,
    );
  });

  testWidgets('connecting ChatScreen shows one shared state panel', (
    tester,
  ) async {
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

    expect(find.byKey(const ValueKey('console-status-strip')), findsNothing);
    expect(
      find.byKey(const ValueKey('recovery-state-connecting')),
      findsOneWidget,
    );
    expect(find.text('正在连接电脑端'), findsOneWidget);
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

  testWidgets('long workspace paths do not overlap following assistant text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const path = r'D:\Workspace\project\项目笔记\学习路线.md';
    const following = '按你库里的习惯把 YAML、callout 和清单格式写一页可勾选的路线。';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: WorkspacePortal(
            workspaceDir: r'D:\Workspace\project',
            onOpenPath: (_) {},
            child: MessageBlock(
              message: TranscriptMessage.assistant(
                '已写入当前目录：\n**$path**\n$following',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final element in tester.allElements) {
      final widget = element.widget;
      if (widget is Text && widget.textSpan != null) {
        expect(
          containsWidgetSpan(widget.textSpan!),
          isFalse,
          reason: 'workspace paths must stay in the parent text layout',
        );
      }
      if (widget is RichText) {
        expect(
          containsWidgetSpan(widget.text),
          isFalse,
          reason: 'workspace paths must stay in the parent text layout',
        );
      }
    }
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

    expect(find.text('接着处理 cc-remote'), findsOneWidget);
    expect(find.text('从下方输入指令，或先点一个快捷任务'), findsOneWidget);
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

  testWidgets('running composer stays editable and queues the next prompt', (
    tester,
  ) async {
    final controller = TextEditingController(text: '下一轮跑测试');
    addTearDown(controller.dispose);
    var sendCount = 0;
    var stopCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: PromptBar(
            controller: controller,
            commands: const [],
            running: true,
            connected: true,
            offline: false,
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            onPermissionModeSelected: (_) {},
            onCommandSelected: (_) {},
            onReconnect: () {},
            onSend: () => sendCount += 1,
            onStop: () => stopCount += 1,
          ),
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(find.byKey(const ValueKey('composer-primary-stop')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-queue-action')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('composer-queue-action')));
    expect(sendCount, 1);
    expect(stopCount, 0);

    await tester.tap(find.byKey(const ValueKey('composer-primary-action')));
    expect(stopCount, 1);
  });

  testWidgets('queued prompt chip can be cancelled', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: PromptBar(
            controller: controller,
            commands: const [],
            running: true,
            connected: true,
            offline: false,
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            queuedPreview: '排队发送：下一轮跑测试',
            onCancelQueue: () => cancelled = true,
            onPermissionModeSelected: (_) {},
            onCommandSelected: (_) {},
            onReconnect: () {},
            onSend: () {},
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('composer-queued-chip')), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.byKey(const ValueKey('composer-queue-action')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('composer-queued-cancel')));
    expect(cancelled, isTrue);
  });

  testWidgets('peeking another session is read-only and can return', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var returned = false;
    var stopped = false;

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
            activeSessionId: 'session-1',
            running: true,
            connected: true,
            offline: false,
            modelName: 'claude-opus-4-8',
            contextWindow: 200000,
            remainingContext: 174919,
            messages: [TranscriptMessage.user('正在跑当前任务')],
            commands: const [],
            permissionMode: PermissionMode.manual,
            allowBypassPermissions: false,
            pendingPermissions: const [],
            respondingPermissionIds: const {},
            promptController: controller,
            peek: const SessionPeekView(
              sessionId: 'session-2',
              title: '玻璃控制面',
              messages: [
                TranscriptMessage(MessageRole.user, '把控制面改成玻璃'),
                TranscriptMessage(MessageRole.assistant, '玻璃控制面已经落地。'),
              ],
              liveRunning: true,
            ),
            onExitPeek: () => returned = true,
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
            onStop: () => stopped = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('session-peek-dock')), findsOneWidget);
    expect(find.byType(PromptBar), findsNothing);
    expect(find.text('玻璃控制面已经落地。'), findsOneWidget);
    expect(find.text('正在跑当前任务'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('session-peek-stop')));
    expect(stopped, isTrue);
    await tester.tap(find.byKey(const ValueKey('session-peek-return')));
    expect(returned, isTrue);
  });

  testWidgets(
    'peek loading shows a placeholder instead of the live transcript',
    (tester) async {
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
              activeSessionId: 'session-1',
              running: true,
              connected: true,
              offline: false,
              modelName: 'claude-opus-4-8',
              contextWindow: 200000,
              remainingContext: 174919,
              messages: [TranscriptMessage.user('正在跑当前任务')],
              commands: const [],
              permissionMode: PermissionMode.manual,
              allowBypassPermissions: false,
              pendingPermissions: const [],
              respondingPermissionIds: const {},
              promptController: controller,
              peek: const SessionPeekView(
                sessionId: 'session-2',
                title: '玻璃控制面',
                messages: [TranscriptMessage(MessageRole.system, '正在读取会话…')],
                loading: true,
                liveRunning: true,
              ),
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

      expect(find.byKey(const ValueKey('session-peek-dock')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session-peek-loading')),
        findsOneWidget,
      );
      expect(find.text('正在读取会话…'), findsOneWidget);
      expect(find.text('正在跑当前任务'), findsNothing);
      expect(find.byType(PromptBar), findsNothing);
    },
  );
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

class FailingSnapshotWorkspaceApi extends WorkspaceApi {
  FailingSnapshotWorkspaceApi()
    : super(origin: Uri.parse('https://example.test'), token: 'test');

  @override
  Future<WorkspaceSnapshot> snapshot() async {
    throw StateError('workspace_failed');
  }

  @override
  Future<WorkspaceDocument> file(String path) async {
    return WorkspaceDocument.file(path, 'hello\n', truncated: false);
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

class DelayedClaudeModelPreferenceStore extends ClaudeModelPreferenceStore {
  final Completer<ClaudeModelPreference> loadCompleter = Completer();

  @override
  Future<ClaudeModelPreference> load() => loadCompleter.future;

  void completeLoad(ClaudeModelPreference preference) {
    loadCompleter.complete(preference);
  }
}
