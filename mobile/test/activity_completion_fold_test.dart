import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TranscriptMessage thought(ActivityState state) => TranscriptMessage.activity(
  '思考',
  id: 'thinking',
  kind: ActivityKind.thinking,
  state: state,
  detail: '先检查代码，再运行测试。',
);

TranscriptMessage tool(ActivityState state) => TranscriptMessage.activity(
  '读取文件',
  id: 'read',
  kind: ActivityKind.tool,
  state: state,
  tool: 'Read',
  detail: 'README.md',
);

Widget host(Widget child) => MaterialApp(
  theme: buildSignalConsoleTheme(),
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

Widget turn() => TranscriptView(
  messages: [
    TranscriptMessage.user('检查项目'),
    thought(ActivityState.done),
    tool(ActivityState.done),
    TranscriptMessage.assistant('检查完成。'),
  ],
  activeSessionId: 'session',
  pendingPermissions: const [],
  respondingPermissionIds: const {},
  connected: true,
  onFillPrompt: (_) {},
  onReconnect: () {},
  onPermissionAllow: (_) {},
  onPermissionDeny: (_) {},
);

const thinkingToggle = ValueKey('thinking-history-toggle');
const thinkingContent = ValueKey('thinking-history-content');
const processToggle = ValueKey('activity-process-toggle');

void main() {
  testWidgets('completed reasoning defaults to collapsed on entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ThinkingHistoryBlock(message: thought(ActivityState.done))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(thinkingToggle), findsOneWidget);
    expect(find.byKey(thinkingContent), findsNothing);
    await tester.tap(find.byKey(thinkingToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(thinkingContent), findsOneWidget);
  });

  testWidgets('completed tool chain defaults to collapsed on entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ActivityTimelineCard(activities: [tool(ActivityState.done)])),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(processToggle), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-detail-read')), findsNothing);
    await tester.tap(find.byKey(processToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-detail-read')), findsOneWidget);
  });

  testWidgets('reasoning collapses when running activity completes', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ThinkingHistoryBlock(message: thought(ActivityState.running))),
    );
    expect(find.byKey(thinkingContent), findsOneWidget);
    await tester.pumpWidget(
      host(ThinkingHistoryBlock(message: thought(ActivityState.done))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(thinkingContent), findsNothing);
    await tester.tap(find.byKey(thinkingToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(thinkingContent), findsOneWidget);
  });

  testWidgets('tool chain collapses when the whole task completes', (
    tester,
  ) async {
    Widget chain(bool running) => host(
      ActivityTimelineCard(
        activities: [tool(ActivityState.done)],
        running: running,
      ),
    );
    await tester.pumpWidget(chain(true));
    expect(find.byKey(const ValueKey('activity-detail-read')), findsOneWidget);
    await tester.tap(find.byKey(processToggle));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(processToggle));
    await tester.pumpAndSettle();
    await tester.pumpWidget(chain(false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-detail-read')), findsNothing);
  });

  for (final reasoning in [true, false]) {
    testWidgets(
      '${reasoning ? 'reasoning' : 'tool chain'} does not restore running expansion into completed history',
      (tester) async {
        final bucket = PageStorageBucket();
        Widget activity(bool running) => host(
          PageStorage(
            bucket: bucket,
            child: reasoning
                ? ThinkingHistoryBlock(
                    message: thought(
                      running ? ActivityState.running : ActivityState.done,
                    ),
                  )
                : ActivityTimelineCard(
                    activities: [tool(ActivityState.done)],
                    running: running,
                  ),
          ),
        );
        final toggle = find.byKey(reasoning ? thinkingToggle : processToggle);
        final content = reasoning
            ? find.byKey(thinkingContent)
            : find.byKey(const ValueKey('activity-detail-read'));
        await tester.pumpWidget(activity(true));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(content, findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(activity(false));
        await tester.pumpAndSettle();
        expect(content, findsNothing);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.pumpWidget(activity(false));
        await tester.pumpAndSettle();
        expect(content, findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(activity(false));
        await tester.pumpAndSettle();
        expect(content, findsOneWidget);
      },
    );
  }

  testWidgets('reopening a completed conversation starts with folded history', (
    tester,
  ) async {
    await tester.pumpWidget(host(turn()));
    await tester.pumpAndSettle();
    expect(find.text('检查完成。'), findsOneWidget);
    expect(find.byKey(thinkingToggle), findsNothing);
    expect(find.byKey(const ValueKey('activity-detail-read')), findsNothing);
    await tester.tap(find.byKey(processToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(thinkingContent), findsNothing);
    await tester.tap(find.byKey(thinkingToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(thinkingContent), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-detail-read')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(turn()));
    await tester.pumpAndSettle();
    expect(find.text('检查完成。'), findsOneWidget);
    expect(find.byKey(thinkingToggle), findsNothing);
    expect(find.byKey(const ValueKey('activity-detail-read')), findsNothing);
  });
}
