import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/tool_activity_detail.dart';
import 'package:cc_remote/workspace_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final longDetail = List.generate(
  20,
  (index) => 'step $index --check',
).join('\n');

Widget toolDetail(
  String detail, {
  String id = 'tool',
  bool reveal = false,
  ActivityState state = ActivityState.running,
}) => ToolActivityDetail(
  activity: TranscriptMessage.activity(
    '运行命令',
    id: id,
    kind: ActivityKind.tool,
    state: state,
    tool: 'Bash',
    detail: detail,
    durationMs: 3200,
  ),
  title: '运行命令',
  titleWidget: const Text('运行命令'),
  leading: const SizedBox.square(dimension: 16),
  running: state == ActivityState.running,
  reveal: reveal,
);

Widget host(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  PageStorageBucket? bucket,
  bool reversed = false,
}) => MaterialApp(
  theme: buildSignalConsoleTheme(brightness),
  builder: (context, navigator) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: navigator!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 320,
        height: 500,
        child: PageStorage(
          bucket: bucket ?? PageStorageBucket(),
          child: reversed
              ? ListView(
                  reverse: true,
                  children: [
                    const SizedBox(height: 80),
                    child,
                    const SizedBox(height: 800),
                  ],
                )
              : SingleChildScrollView(child: child),
        ),
      ),
    ),
  ),
);

void main() {
  WorkspacePathText detailText(WidgetTester tester) =>
      tester.widget(find.byKey(const ValueKey('activity-detail-tool')));

  testWidgets('short details stay selectable without an extra action', (
    tester,
  ) async {
    await tester.pumpWidget(host(toolDetail('flutter test')));
    await tester.pumpAndSettle();
    expect(detailText(tester).selectable, isTrue);
    expect(detailText(tester).maxLines, isNull);
    expect(find.text('展开全部'), findsNothing);
    expect(find.text('运行中 · 3 秒'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'long wrapped input has a bounded preview $brightness $scale',
        (tester) async {
          final singleLine = List.filled(40, 'long-command --check').join(' ');
          await tester.pumpWidget(
            host(toolDetail(singleLine), brightness: brightness, scale: scale),
          );
          await tester.pumpAndSettle();
          expect(detailText(tester).text, singleLine);
          expect(detailText(tester).maxLines, 3);
          expect(detailText(tester).overflow, TextOverflow.ellipsis);
          expect(detailText(tester).selectable, isFalse);
          expect(
            tester
                .getSize(find.byKey(const ValueKey('activity-detail-tool')))
                .height,
            lessThanOrEqualTo(
              3 * (AppTypography.activityBodySize * 1.6 * scale).ceilToDouble(),
            ),
          );
          final more = find.byKey(const ValueKey('activity-detail-more-tool'));
          expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
          await tester.tap(more);
          await tester.pumpAndSettle();
          expect(detailText(tester).selectable, isTrue);
          expect(detailText(tester).maxLines, isNull);
          expect(detailText(tester).text, singleLine);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('manual expansion survives updates and can return to preview', (
    tester,
  ) async {
    await tester.pumpWidget(host(toolDetail(longDetail)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开全部'));
    await tester.pumpAndSettle();
    final updated = '$longDetail\nlast step';
    await tester.pumpWidget(
      host(toolDetail(updated, state: ActivityState.done)),
    );
    await tester.pumpAndSettle();
    expect(detailText(tester).selectable, isTrue);
    expect(detailText(tester).text, updated);
    await tester.ensureVisible(find.text('收起详情'));
    await tester.tap(find.text('收起详情'));
    await tester.pumpAndSettle();
    expect(detailText(tester).maxLines, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace links remain tappable inside a long preview', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      host(
        WorkspacePortal(
          workspaceDir: '/workspace/project',
          onOpenPath: (path) => opened = path,
          child: toolDetail('README.md\n$longDetail'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(detailText(tester).maxLines, 3);
    await tester.tap(find.text('README.md'));
    expect(opened, 'README.md');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search reveals the full detail without changing the manual state',
    (tester) async {
      await tester.pumpWidget(host(toolDetail(longDetail, reveal: true)));
      await tester.pumpAndSettle();
      expect(detailText(tester).selectable, isTrue);
      expect(detailText(tester).maxLines, isNull);
      expect(find.text('展开全部'), findsNothing);
      expect(find.text('收起详情'), findsNothing);
      await tester.pumpWidget(host(toolDetail(longDetail)));
      await tester.pumpAndSettle();
      expect(detailText(tester).maxLines, 3);
    },
  );

  testWidgets(
    'expansion is stored per activity and restored after remounting',
    (tester) async {
      final bucket = PageStorageBucket();
      await tester.pumpWidget(host(toolDetail(longDetail), bucket: bucket));
      await tester.pumpAndSettle();
      await tester.tap(find.text('展开全部'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(const SizedBox(), bucket: bucket));
      await tester.pumpWidget(host(toolDetail(longDetail), bucket: bucket));
      await tester.pumpAndSettle();
      expect(detailText(tester).maxLines, isNull);
      await tester.pumpWidget(
        host(toolDetail(longDetail, id: 'other'), bucket: bucket),
      );
      await tester.pumpAndSettle();
      final other = tester.widget<WorkspacePathText>(
        find.byKey(const ValueKey('activity-detail-other')),
      );
      expect(other.maxLines, 3);
    },
  );

  testWidgets('failures and stops stay visible above a long preview', (
    tester,
  ) async {
    for (final state in [ActivityState.error, ActivityState.stopped]) {
      await tester.pumpWidget(host(toolDetail(longDetail, state: state)));
      await tester.pumpAndSettle();
      expect(
        find.text('${toolActivityStateLabel(state)} · 3 秒'),
        findsOneWidget,
      );
      expect(detailText(tester).maxLines, 3);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'expanding a preview keeps its header anchored in a reversed list',
    (tester) async {
      await tester.pumpWidget(host(toolDetail(longDetail), reversed: true));
      await tester.pumpAndSettle();
      final header = find.byKey(const ValueKey('activity-step-toggle-tool'));
      final before = tester.getTopLeft(header).dy;
      await tester.tap(find.text('展开全部'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(header).dy, closeTo(before, 1));
      expect(tester.takeException(), isNull);
    },
  );
}
