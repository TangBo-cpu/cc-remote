import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/noto_icon.dart';
import 'package:cc_remote/signal_console_theme.dart';

TranscriptMessage tool(ActivityState state) => TranscriptMessage.activity(
  '读取文件',
  id: 'read',
  kind: ActivityKind.tool,
  state: state,
  tool: 'Read',
  detail: 'README.md',
);

TranscriptMessage thinking() => TranscriptMessage.activity(
  '思考中',
  id: 'thinking',
  kind: ActivityKind.thinking,
  state: ActivityState.running,
);

Widget host(Widget child, {bool reduceMotion = false, double scale = 1}) =>
    MaterialApp(
      theme: buildSignalConsoleTheme(),
      builder: (context, navigator) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(scale),
        ),
        child: navigator!,
      ),
      home: Scaffold(body: SizedBox(width: 320, child: child)),
    );

Widget turn({required bool running}) => TranscriptView(
  messages: [
    TranscriptMessage.user('检查项目'),
    tool(ActivityState.done),
    if (running) thinking() else TranscriptMessage.assistant('检查完成'),
  ],
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
  testWidgets('running tools show their detail without a card or sheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ActivityTimelineCard(activities: [tool(ActivityState.running)])),
    );
    expect(
      find.byKey(const ValueKey('activity-timeline-surface')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('activity-step-toggle-read')),
      findsOneWidget,
    );
    expect(find.byType(SmartIcon), findsWidgets);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
    final materials = tester.widgetList<Material>(
      find.descendant(
        of: find.byType(ActivityTimelineCard),
        matching: find.byType(Material),
      ),
    );
    expect(
      materials.every((material) => material.color == Colors.transparent),
      isTrue,
    );
    expect(materials.every((material) => material.shape == null), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live thinking remains animated outside collapsed tool history', (
    tester,
  ) async {
    await tester.pumpWidget(host(turn(running: true)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('activity-process-toggle')));
    await tester.pump(const Duration(milliseconds: 220));
    final icon = find.byKey(const ValueKey('thinking-icon'));
    expect(icon, findsOneWidget);
    final before = tester.widget<CustomPaint>(icon).painter!;
    await tester.pump(const Duration(milliseconds: 250));
    final after = tester.widget<CustomPaint>(icon).painter!;
    expect(after.shouldRepaint(before), isTrue);
    expect(find.byKey(const ValueKey('thinking-elapsed')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('completed history keeps details inline beside the final reply', (
    tester,
  ) async {
    await tester.pumpWidget(host(turn(running: false), reduceMotion: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('process-history-surface')), findsNothing);
    expect(find.byType(SmartIcon), findsWidgets);
    expect(find.text('检查完成'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-activity-sheet')), findsNothing);
  });

  testWidgets(
    'reduced motion keeps a static thinking icon and readable elapsed time',
    (tester) async {
      await tester.pumpWidget(
        host(
          ThinkingHistoryBlock(message: thinking(), initialElapsedSeconds: 12),
          reduceMotion: true,
          scale: 2,
        ),
      );
      final icon = find.byKey(const ValueKey('thinking-icon'));
      expect(icon, findsOneWidget);
      final before = tester.widget<CustomPaint>(icon).painter!;
      await tester.pump(const Duration(seconds: 1));
      final after = tester.widget<CustomPaint>(icon).painter!;
      expect(after.shouldRepaint(before), isFalse);
      expect(find.byType(ShaderMask), findsNothing);
      expect(find.textContaining('本轮已运行 13 秒'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
