import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/noto_icon.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TranscriptMessage processMessage({required bool thinking}) =>
    TranscriptMessage.activity(
      thinking ? '思考' : '运行命令',
      id: thinking ? 'thinking' : 'command',
      kind: thinking ? ActivityKind.thinking : ActivityKind.tool,
      state: ActivityState.done,
      tool: thinking ? null : 'Bash',
      detail: thinking ? '先检查代码，再运行测试。' : 'flutter test',
    );

Widget host({
  required List<TranscriptMessage> messages,
  required Brightness brightness,
  required double scale,
  required double width,
}) => MaterialApp(
  theme: buildSignalConsoleTheme(brightness),
  builder: (context, navigator) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, height: 700, child: navigator),
    ),
  ),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TranscriptView(
        messages: messages,
        activeSessionId: 'layout-session',
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
);

void expectCompactProcess(WidgetTester tester, Finder toggle) {
  final reply = find.text('检查完成。');
  final leading = find
      .descendant(of: toggle, matching: find.byType(SmartIcon))
      .first;
  final targetRect = tester.getRect(toggle);
  final bodyRect = tester.getRect(reply);
  expect(tester.getRect(leading).left, closeTo(bodyRect.left, 0.1));
  expect(targetRect.height, greaterThanOrEqualTo(AppSizes.touchTarget));
  expect(bodyRect.top - targetRect.bottom, inInclusiveRange(0, 4));
  expect(tester.takeException(), isNull);
}

void main() {
  for (final thinking in [false, true]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        for (final width in [320.0, 412.0]) {
          testWidgets(
            '${thinking ? 'reasoning' : 'tool'} heading aligns with reply '
            'at $brightness, ${scale}x text, ${width}dp',
            (tester) async {
              await tester.pumpWidget(
                host(
                  messages: [
                    TranscriptMessage.user('检查项目'),
                    processMessage(thinking: thinking),
                    TranscriptMessage.assistant('检查完成。'),
                  ],
                  brightness: brightness,
                  scale: scale,
                  width: width,
                ),
              );
              await tester.pumpAndSettle();
              expectCompactProcess(
                tester,
                find.byKey(
                  ValueKey(
                    thinking
                        ? 'thinking-history-toggle'
                        : 'activity-process-toggle',
                  ),
                ),
              );
            },
          );
        }
      }
    }
  }

  testWidgets('expanded process keeps its reply attached without overlap', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        messages: [
          TranscriptMessage.user('检查项目'),
          TranscriptMessage.assistant('先检查项目。'),
          processMessage(thinking: false),
          TranscriptMessage.assistant('检查完成。'),
        ],
        brightness: Brightness.light,
        scale: 1,
        width: 320,
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('activity-process-toggle'));
    expectCompactProcess(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final detail = find.byKey(const ValueKey('activity-detail-command'));
    final reply = find.text('检查完成。');
    expect(detail, findsOneWidget);
    expect(
      tester.getTopLeft(reply).dy - tester.getBottomLeft(detail).dy,
      inInclusiveRange(0, 12),
    );
    expect(
      tester.getTopLeft(find.text('先检查项目。')).dx,
      closeTo(tester.getTopLeft(reply).dx, 0.1),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expectCompactProcess(tester, toggle);
  });
}
