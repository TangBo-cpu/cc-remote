import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

Widget transcript(List<TranscriptMessage> messages, {bool running = false}) =>
    TranscriptView(
      messages: messages,
      session: null,
      activeSessionId: null,
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

  testWidgets('reasoning keeps manual disclosure state when it finishes', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ThinkingHistoryBlock(message: thought(ActivityState.running))),
    );
    expect(find.text('思考中'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('thinking-history-content')),
      findsOneWidget,
    );
    expect(find.byType(AnimatedSize), findsNothing);
    await tester.pumpWidget(
      host(ThinkingHistoryBlock(message: thought(ActivityState.done))),
    );
    await tester.pumpAndSettle();
    expect(find.text('已深度思考'), findsOneWidget);
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

  testWidgets(
    'empty streaming reasoning remains visible and empty history is hidden',
    (tester) async {
      await tester.pumpWidget(
        host(
          ThinkingHistoryBlock(
            message: thought(ActivityState.running, detail: ''),
          ),
        ),
      );
      expect(find.text('思考中'), findsOneWidget);
      await tester.pumpWidget(
        host(
          ThinkingHistoryBlock(
            message: thought(ActivityState.done, detail: ''),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('thinking-history-toggle')),
        findsNothing,
      );
    },
  );

  testWidgets('reasoning survives enlarged text in both palettes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: ThinkingHistoryBlock(message: thought(ActivityState.done)),
          ),
          brightness: brightness,
          scale: 2,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('thinking-history-toggle')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('先检查代码。再运行测试。', findRichText: true), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets(
    'tool groups default to a folded summary and open an independent detail sheet',
    (tester) async {
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
      expect(find.text('读取文件与运行命令'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('activity-step-toggle-read')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
      await tester.pumpAndSettle();
      final before = tester.getSize(find.byType(ActivityTimelineCard));
      final row = find.byKey(const ValueKey('activity-step-toggle-read'));
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tool-activity-sheet')), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(tester.getSize(find.byType(ActivityTimelineCard)), before);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
      expect(
        find.byKey(const ValueKey('activity-step-toggle-read')),
        findsOneWidget,
      );
    },
  );

  testWidgets('completed turn folds interleaved tools into one process', (
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
    expect(
      find.byKey(const ValueKey('process-history-toggle')),
      findsOneWidget,
    );
    expect(find.byType(ActivityTimelineCard), findsNothing);
    expect(find.text('文件已读取，接着检查测试。'), findsNothing);
    expect(find.text('检查完成，测试通过。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('process-history-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityTimelineCard), findsOneWidget);
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

  testWidgets(
    'finishing a turn wraps the process and preserves manually opened tools',
    (tester) async {
      Widget buildTurn(ActivityState state, bool running) => host(
        transcript([
          TranscriptMessage.user('运行检查'),
          tool(state),
          if (!running) TranscriptMessage.assistant('检查完成。'),
        ], running: running),
        reduceMotion: true,
      );
      await tester.pumpWidget(buildTurn(ActivityState.running, true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('activity-step-toggle-tool')),
        findsOneWidget,
      );
      await tester.pumpWidget(buildTurn(ActivityState.done, false));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('process-history-toggle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('activity-step-toggle-tool')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('process-history-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('activity-step-toggle-tool')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('process-history-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('activity-step-toggle-tool')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'an open tool sheet stays live when its turn becomes a completed process',
    (tester) async {
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
      await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
      await tester.pumpAndSettle();
      expect(find.text('运行中'), findsOneWidget);
      await tester.pumpWidget(buildTurn(false));
      await tester.pumpAndSettle();
      expect(find.text('已完成 · 4 秒'), findsOneWidget);
      expect(find.text('flutter test --no-pub'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('process-history-toggle')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tool completion between calls does not settle the active turn', (
    tester,
  ) async {
    Widget buildTurn(ActivityState state) => host(
      transcript([TranscriptMessage.user('运行检查'), tool(state)], running: true),
      reduceMotion: true,
    );
    await tester.pumpWidget(buildTurn(ActivityState.running));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildTurn(ActivityState.done));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byKey(const ValueKey('process-history-toggle')), findsNothing);
    expect(
      find.byKey(const ValueKey('activity-step-toggle-tool')),
      findsOneWidget,
    );
    expect(find.text('正在使用工具'), findsOneWidget);
  });

  testWidgets('completed process grouping preserves user turn boundaries', (
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
    expect(
      find.byKey(const ValueKey('process-history-toggle')),
      findsNWidgets(2),
    );
    await tester.tap(find.byKey(const ValueKey('process-history-toggle')).last);
    await tester.pumpAndSettle();
    final group = tester.widget<ActivityTimelineCard>(
      find.byType(ActivityTimelineCard),
    );
    expect(group.activities.single.activityId, 'second');
    expect(find.text('第一轮完成。'), findsOneWidget);
    expect(find.text('第二轮完成。'), findsOneWidget);
  });

  testWidgets('open tool details update after host completion', (tester) async {
    await tester.pumpWidget(
      host(ActivityTimelineCard(activities: [tool(ActivityState.running)])),
    );
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('运行中'), findsOneWidget);
    await tester.pumpWidget(
      host(
        ActivityTimelineCard(
          activities: [
            tool(
              ActivityState.done,
              detail: 'flutter test --no-pub',
              durationMs: 4200,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('已完成 · 4 秒'), findsOneWidget);
    expect(find.text('flutter test --no-pub'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity-step-toggle-tool')),
      findsOneWidget,
    );
  });

  testWidgets(
    'fast tool updates keep the current title and coalesce superseded titles',
    (tester) async {
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
    },
  );

  testWidgets(
    'tool errors and stops retain visible state and accessible summaries',
    (tester) async {
      for (final state in [ActivityState.error, ActivityState.stopped]) {
        final status = state == ActivityState.error ? '1 个失败' : '1 个已停止';
        await tester.pumpWidget(
          host(ActivityTimelineCard(activities: [tool(state)])),
        );
        expect(find.text(status), findsOneWidget);
        final semantics = tester
            .getSemantics(find.byKey(const ValueKey('activity-process-toggle')))
            .getSemanticsData();
        expect(semantics.label, '运行命令，1 次操作，$status');
        expect(semantics.flagsCollection.isButton, isTrue);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('reduced motion disables shimmer and disclosure transitions', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        ActivityTimelineCard(activities: [tool(ActivityState.running)]),
        reduceMotion: true,
      ),
    );
    expect(find.byType(ShaderMask), findsNothing);
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedSize), findsNothing);
    for (final rotation in tester.widgetList<AnimatedRotation>(
      find.byType(AnimatedRotation),
    )) {
      expect(rotation.duration, Duration.zero);
    }
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detail sheets resize and scroll long content with large text in both palettes',
    (tester) async {
      final detail = List.filled(
        30,
        'long-command --check connection',
      ).join('\n');
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          host(
            ActivityTimelineCard(
              activities: [tool(ActivityState.done, detail: detail)],
            ),
            brightness: brightness,
            scale: 2,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('activity-step-toggle-tool')),
        );
        await tester.pumpAndSettle();
        final sheet = find.byKey(const ValueKey('tool-activity-sheet'));
        final compactHeight = tester.getSize(sheet).height;
        await tester.drag(
          find.byType(CustomScrollView).last,
          const Offset(0, -280),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(sheet).height, greaterThan(compactHeight + 100));
        expect(find.text(detail), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('detail sheets can close after the source row is removed', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ActivityTimelineCard(activities: [tool(ActivityState.done)])),
    );
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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
