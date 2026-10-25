import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:cc_remote/workspace_paths.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/signal_console_theme.dart';

TranscriptMessage thought(
  ActivityState state, {
  String detail = '先检查代码。再运行测试。',
}) => TranscriptMessage.activity(
  '思考',
  id: 'thinking',
  kind: ActivityKind.thinking,
  state: state,
  detail: detail,
  durationMs: 3200,
);

TranscriptMessage tool(
  ActivityState state, {
  String id = 'tool',
  String name = 'Bash',
  String detail = 'flutter test',
  int? durationMs,
}) => TranscriptMessage.activity(
  '调用 $name',
  id: id,
  kind: ActivityKind.tool,
  state: state,
  tool: name,
  detail: detail,
  durationMs: durationMs,
);

Widget host(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool reduceMotion = false,
}) => MaterialApp(
  theme: buildSignalConsoleTheme(brightness),
  builder: (context, navigator) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      size: const Size(320, 568),
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduceMotion,
    ),
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 320, height: 568, child: navigator),
    ),
  ),
  home: Scaffold(body: child),
);

Widget transcript(
  List<TranscriptMessage> messages, {
  bool running = false,
  String? activeSessionId,
}) => TranscriptView(
  messages: messages,
  session: null,
  activeSessionId: activeSessionId,
  runStartedAt: null,
  running: running,
  connected: true,
  offline: false,
  pendingPermissions: const [],
  respondingPermissionIds: const {},
  onFillPrompt: (_) {},
  onPermissionAllow: (_) {},
  onPermissionDeny: (_) {},
  onReconnect: () {},
);

void main() {
  test(
    'summary duration cannot overwrite the individual thinking duration',
    () {
      final messages = [
        TranscriptMessage.user('检查'),
        thought(ActivityState.done),
      ];
      mergeRemoteActivity(
        messages,
        const RemoteActivity(
          id: 'summary',
          kind: ActivityKind.summary,
          state: ActivityState.done,
          durationMs: 60000,
        ),
      );
      expect(messages.last.activityDurationMs, 3200);
      final restored = TranscriptMessage.fromJson(messages.last.toJson());
      expect(restored.activityDetail, messages.last.activityDetail);
      expect(restored.activityDurationMs, 3200);
    },
  );

  test('completion retains prior process history', () {
    final previous = thought(ActivityState.done);
    final messages = [
      TranscriptMessage.user('第一轮'),
      previous,
      TranscriptMessage.user('第二轮'),
      thought(ActivityState.running),
    ];
    removeCurrentTurnActivities(messages);
    expect(messages[1], same(previous));
    expect(messages.last.activityState, ActivityState.done);
    expect(
      transcriptRowKey(messages[1], 1),
      isNot(transcriptRowKey(messages.last, 3)),
    );
  });

  testWidgets('reasoning is inline and retains manual state on completion', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ThinkingHistoryBlock(message: thought(ActivityState.running))),
    );
    expect(find.text('思考中'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsNothing,
    );
    await tester.pumpWidget(
      host(ThinkingHistoryBlock(message: thought(ActivityState.done))),
    );
    await tester.pumpAndSettle();
    expect(find.text('已深度思考'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsOneWidget,
    );
    expect(find.byType(AnimatedSize), findsNothing);
  });

  testWidgets('empty reasoning shows only its live indicator', (tester) async {
    await tester.pumpWidget(
      host(
        ThinkingHistoryBlock(
          message: thought(ActivityState.running, detail: ''),
        ),
      ),
    );
    expect(find.text('思考中'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsNothing,
    );
    await tester.pumpWidget(
      host(
        ThinkingHistoryBlock(message: thought(ActivityState.done, detail: '')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('thinking-history-toggle')), findsNothing);
  });

  testWidgets('reasoning remains smaller than body with enlarged text', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: ThinkingHistoryBlock(
              message: thought(
                ActivityState.done,
                detail: '# 检查\n\n- 先检查代码\n\n`flutter test`',
              ),
            ),
          ),
          brightness: brightness,
          scale: 2,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('thinking-history-content')),
        findsOneWidget,
      );
      final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(
        markdown.styleSheet!.p!.fontSize,
        lessThan(AppTypography.assistantBodySize),
      );
      expect(markdown.styleSheet!.h1!.fontSize, AppTypography.activityBodySize);
      expect(
        markdown.styleSheet!.listBullet!.fontSize,
        AppTypography.activityBodySize,
      );
      expect(
        markdown.styleSheet!.code!.fontSize,
        AppTypography.activityBodySize,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('tool details are visible inline and collapse independently', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        ActivityTimelineCard(
          activities: [
            tool(
              ActivityState.done,
              id: 'read',
              name: 'Read',
              detail: 'README.md',
            ),
            tool(ActivityState.done, id: 'test'),
          ],
        ),
      ),
    );
    final readDetail = find.byKey(const ValueKey('activity-detail-read'));
    expect(readDetail, findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    expect(readDetail, findsOneWidget);
    expect(
      find.descendant(of: readDetail, matching: find.byType(SelectableText)),
      findsOneWidget,
    );
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
    final row = find.byKey(const ValueKey('activity-step-toggle-read'));
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    final before = tester.getSize(find.byType(ActivityTimelineCard)).height;
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(readDetail, findsNothing);
    expect(find.text('flutter test'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ActivityTimelineCard)).height,
      lessThan(before),
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(readDetail, findsOneWidget);
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
  });

  testWidgets('completed process keeps tools and reasoning in message order', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        transcript([
          TranscriptMessage.user('检查项目'),
          tool(
            ActivityState.done,
            id: 'read',
            name: 'Read',
            detail: 'README.md',
          ),
          TranscriptMessage.assistant('文件已读取，接着检查测试。'),
          thought(ActivityState.done),
          tool(ActivityState.done, id: 'test'),
          TranscriptMessage.assistant('检查完成，测试通过。'),
        ]),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('process-history-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('process-history-surface')), findsNothing);
    expect(
      find.byKey(const ValueKey('activity-timeline-surface')),
      findsNothing,
    );
    expect(find.byType(ActivityTimelineCard), findsOneWidget);
    expect(find.text('检查完成，测试通过。'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinking-history-toggle')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    final read = find.byKey(const ValueKey('activity-step-toggle-read'));
    final narration = find.text('文件已读取，接着检查测试。');
    final reasoning = find.byKey(const ValueKey('thinking-history-toggle'));
    final command = find.byKey(const ValueKey('activity-step-toggle-test'));
    expect(
      tester.getTopLeft(read).dy,
      lessThan(tester.getTopLeft(narration).dy),
    );
    expect(
      tester.getTopLeft(narration).dy,
      lessThan(tester.getTopLeft(reasoning).dy),
    );
    expect(
      tester.getTopLeft(reasoning).dy,
      lessThan(tester.getTopLeft(command).dy),
    );
  });

  testWidgets('manual tool folding survives completion and later calls', (
    tester,
  ) async {
    Widget buildTurn(bool running, {bool anotherTool = false}) => host(
      transcript([
        TranscriptMessage.user('运行检查'),
        tool(running ? ActivityState.running : ActivityState.done),
        if (anotherTool)
          tool(ActivityState.done, id: 'next', detail: 'dart analyze'),
        if (!running) TranscriptMessage.assistant('检查完成。'),
      ], running: running),
      reduceMotion: true,
    );
    await tester.pumpWidget(buildTurn(true));
    await tester.pumpAndSettle();
    expect(find.text('flutter test'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildTurn(false, anotherTool: true));
    await tester.pumpAndSettle();
    expect(find.text('flutter test'), findsNothing);
    expect(find.text('dart analyze'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('dart analyze'), findsOneWidget);
    expect(find.text('检查完成。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
    await tester.pumpAndSettle();
    expect(find.text('flutter test'), findsOneWidget);
  });

  for (final target in ['reasoning', 'tool detail', 'tool group']) {
    testWidgets('manual $target folding survives scrolling off screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          transcript([
            for (var turn = 0; turn < 16; turn++) ...[
              TranscriptMessage.user('检查 $turn'),
              thought(ActivityState.done),
              tool(ActivityState.done, id: 'tool-$turn'),
              TranscriptMessage.assistant('第 $turn 轮完成。'),
            ],
          ]),
          reduceMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('transcript-list')),
      );
      final scroll = list.controller!;
      scroll.jumpTo(scroll.position.minScrollExtent);
      await tester.pumpAndSettle();

      final process = find.byType(ActivityTimelineCard).first;
      await tester.tap(
        find.descendant(
          of: process,
          matching: find.byKey(const ValueKey('activity-process-toggle')),
        ),
      );
      await tester.pumpAndSettle();
      if (target == 'reasoning') {
        await tester.tap(
          find.descendant(
            of: process,
            matching: find.byKey(const ValueKey('thinking-history-toggle')),
          ),
        );
        await tester.pumpAndSettle();
      }
      final originalElement = tester.element(process);
      final toggle = find.descendant(
        of: process,
        matching: find.byKey(
          ValueKey(switch (target) {
            'reasoning' => 'thinking-history-toggle',
            'tool detail' => 'activity-step-toggle-tool-0',
            _ => 'activity-process-toggle',
          }),
        ),
      );
      final content = find.descendant(
        of: process,
        matching: find.byKey(
          ValueKey(
            target == 'reasoning'
                ? 'thinking-history-content'
                : 'activity-detail-tool-0',
          ),
        ),
      );
      expect(content, findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(content, findsNothing);

      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(originalElement.mounted, isFalse);
      scroll.jumpTo(scroll.position.minScrollExtent);
      await tester.pumpAndSettle();
      expect(content, findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(content, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('group folding preserves individual reasoning and tool choices', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        transcript([
          TranscriptMessage.user('检查项目'),
          thought(ActivityState.done),
          tool(ActivityState.done),
          TranscriptMessage.assistant('检查完成。'),
        ]),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
    await tester.pumpAndSettle();
    final group = find.byKey(const ValueKey('activity-process-toggle'));
    await tester.tap(group);
    await tester.pumpAndSettle();
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('activity-detail-tool')), findsNothing);
    expect(
      find.byKey(const ValueKey('thinking-history-toggle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activity-step-toggle-tool')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'live reasoning keeps its fold when moved into completed history',
    (tester) async {
      Widget buildTurn(bool running) => host(
        transcript([
          TranscriptMessage.user('检查项目'),
          tool(ActivityState.done),
          thought(running ? ActivityState.running : ActivityState.done),
          if (!running) TranscriptMessage.assistant('检查完成。'),
        ], running: running),
        reduceMotion: true,
      );
      await tester.pumpWidget(buildTurn(true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(buildTurn(false));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('thinking-history-toggle')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('已深度思考'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('thinking-history-content')),
        findsNothing,
      );
      expect(find.text('flutter test'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fold choices do not leak into another session with reused IDs', (
    tester,
  ) async {
    Widget buildSession(String sessionId) => host(
      transcript([
        TranscriptMessage.user('检查项目'),
        thought(ActivityState.done),
        tool(ActivityState.done),
        TranscriptMessage.assistant('检查完成。'),
      ], activeSessionId: sessionId),
      reduceMotion: true,
    );
    await tester.pumpWidget(buildSession('first'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(buildSession('second'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('thinking-history-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('activity-detail-tool')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('activity-detail-tool')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline command and duration update on completion', (
    tester,
  ) async {
    Widget buildTurn(bool running) => host(
      transcript([
        TranscriptMessage.user('运行检查'),
        tool(
          running ? ActivityState.running : ActivityState.done,
          detail: running ? 'flutter test' : 'flutter test --no-pub',
          durationMs: running ? null : 4200,
        ),
        if (!running) TranscriptMessage.assistant('检查完成。'),
      ], running: running),
      reduceMotion: true,
    );
    await tester.pumpWidget(buildTurn(true));
    await tester.pumpAndSettle();
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('flutter test'), findsOneWidget);
    await tester.pumpWidget(buildTurn(false));
    await tester.pumpAndSettle();
    expect(find.text('flutter test --no-pub'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('已完成 · 4 秒'), findsOneWidget);
    expect(find.text('flutter test --no-pub'), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool completion between calls does not settle the active turn', (
    tester,
  ) async {
    Widget buildTurn(ActivityState state) => host(
      transcript([TranscriptMessage.user('运行检查'), tool(state)], running: true),
      reduceMotion: true,
    );
    await tester.pumpWidget(buildTurn(ActivityState.running));
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildTurn(ActivityState.done));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byKey(const ValueKey('process-history-toggle')), findsNothing);
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.text('正在使用工具'), findsOneWidget);
  });

  testWidgets('process grouping preserves user turn boundaries', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        transcript([
          TranscriptMessage.user('第一轮'),
          tool(ActivityState.done, id: 'first'),
          TranscriptMessage.assistant('第一轮完成。'),
          TranscriptMessage.user('第二轮'),
          tool(ActivityState.done, id: 'second'),
          TranscriptMessage.assistant('第二轮完成。'),
        ]),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    final groups = tester.widgetList<ActivityTimelineCard>(
      find.byType(ActivityTimelineCard),
    );
    expect(groups.map((group) => group.activities.single.activityId), [
      'first',
      'second',
    ]);
    expect(find.text('第一轮完成。'), findsOneWidget);
    expect(find.text('第二轮完成。'), findsOneWidget);
  });

  testWidgets('fast tool updates coalesce summary titles', (tester) async {
    await tester.pumpWidget(
      host(
        ActivityTimelineCard(
          activities: [tool(ActivityState.running, id: 'read', name: 'Read')],
        ),
      ),
    );
    await tester.pumpWidget(
      host(
        ActivityTimelineCard(
          activities: [
            tool(ActivityState.done, id: 'read', name: 'Read'),
            tool(ActivityState.running, id: 'search', name: 'Grep'),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('读取文件'), findsOneWidget);
    expect(find.text('搜索代码'), findsNothing);
    await tester.pumpWidget(
      host(
        ActivityTimelineCard(
          activities: [
            tool(ActivityState.done, id: 'read', name: 'Read'),
            tool(ActivityState.done, id: 'search', name: 'Grep'),
            tool(ActivityState.running),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('运行命令'), findsOneWidget);
    expect(find.text('搜索代码'), findsNothing);
  });

  testWidgets('tool errors and stops expose state in text and semantics', (
    tester,
  ) async {
    for (final state in [ActivityState.error, ActivityState.stopped]) {
      final status = state == ActivityState.error ? '1 个失败' : '1 个已停止';
      await tester.pumpWidget(
        host(ActivityTimelineCard(activities: [tool(state)])),
      );
      expect(find.text(status), findsOneWidget);
      expect(find.text('flutter test'), findsNothing);
      final semantics = tester
          .getSemantics(find.byKey(const ValueKey('activity-process-toggle')))
          .getSemanticsData();
      expect(semantics.label, '运行命令，1 次操作，$status');
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(semantics.flagsCollection.isExpanded, Tristate.isFalse);
      await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('flutter test'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('reduced motion disables shimmer and inline transitions', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        ActivityTimelineCard(activities: [tool(ActivityState.running)]),
        reduceMotion: true,
      ),
    );
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
    await tester.pumpAndSettle();
    expect(find.text('flutter test'), findsNothing);
    for (final rotation in tester.widgetList<AnimatedRotation>(
      find.byType(AnimatedRotation),
    )) {
      expect(rotation.duration, Duration.zero);
    }
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long commands wrap inline with large text in both palettes', (
    tester,
  ) async {
    final detail = List.filled(
      30,
      'long-command --check connection',
    ).join('\n');
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: ActivityTimelineCard(
              activities: [tool(ActivityState.done, detail: detail)],
            ),
          ),
          brightness: brightness,
          scale: 2,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
      await tester.pumpAndSettle();
      expect(find.text(detail), findsOneWidget);
      final text = tester.widget<WorkspacePathText>(
        find.byKey(const ValueKey('activity-detail-tool')),
      );
      expect(text.selectable, isTrue);
      expect(text.style!.fontSize, lessThan(AppTypography.assistantBodySize));
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -280),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('reasoning disclosure preserves its header in a reversed list', (
    tester,
  ) async {
    final scroll = ScrollController(initialScrollOffset: 50);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      host(
        ListView(
          controller: scroll,
          reverse: true,
          children: [
            const SizedBox(height: 100),
            ThinkingHistoryBlock(message: thought(ActivityState.done)),
            const SizedBox(height: 600),
          ],
        ),
      ),
    );
    final header = find.byKey(const ValueKey('thinking-history-toggle'));
    final before = tester.getTopLeft(header).dy;
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, closeTo(before, 1));
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, closeTo(before, 1));
  });
}
