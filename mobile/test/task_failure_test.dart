import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'successful turn keeps tool errors without a task failure panel',
    (tester) async {
      await tester.pumpWidget(
        const CcRemoteApp(enableCamera: false, demoMode: true),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(DemoShell));
      await state.connectDemoDevice();
      beginPrompt(state.messages as List<TranscriptMessage>, '运行测试');

      void emit(Map<String, Object?> event) {
        state.handleWsMessage(
          jsonEncode({
            'sessionId': 'demo-session-polish',
            'runId': 'successful-run',
            ...event,
          }),
        );
      }

      emit({'type': 'status', 'authenticated': true, 'running': true});
      emit({
        'type': 'activity',
        'id': 'failed-tool',
        'kind': 'tool',
        'state': 'error',
        'toolName': 'Bash',
        'detail': '第一次测试失败',
      });
      emit({
        'type': 'activity',
        'id': 'retried-tool',
        'kind': 'tool',
        'state': 'done',
        'toolName': 'Bash',
        'detail': '重试测试通过',
      });
      emit({'type': 'text', 'text': '已修复问题，测试通过。'});
      emit({'type': 'done', 'exitCode': 0});
      await tester.pumpAndSettle();

      final messages = state.messages as List<TranscriptMessage>;
      expect(
        messages
            .singleWhere((m) => m.activityId == 'failed-tool')
            .activityState,
        ActivityState.error,
      );
      expect(find.text('已修复问题，测试通过。'), findsOneWidget);
      expect(find.text('任务执行失败'), findsNothing);
      expect(hasCurrentFailureEvidence(messages), isFalse);

      emit({
        'type': 'transcript_snapshot',
        'version': 1,
        'revision': 1,
        'running': false,
        'messages': messages.map((message) => message.toJson()).toList(),
        'pendingPermissions': [],
      });
      await tester.pumpAndSettle();
      expect(find.text('任务执行失败'), findsNothing);
      await state.lastTranscriptWrite;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('real task failure remains visible after a nonzero done event', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(DemoShell));
    await state.connectDemoDevice();
    beginPrompt(state.messages as List<TranscriptMessage>, '运行任务');
    for (final event in [
      {'type': 'status', 'authenticated': true, 'running': true},
      {'type': 'text', 'text': '部分输出'},
      {'type': 'error', 'message': '命令退出码为 1'},
      {'type': 'done', 'exitCode': 1},
    ]) {
      state.handleWsMessage(
        jsonEncode({
          'sessionId': 'demo-session-polish',
          'runId': 'failed-run',
          ...event,
        }),
      );
    }
    await tester.pumpAndSettle();
    expect(find.text('任务执行失败'), findsOneWidget);
    expect(find.text('命令退出码为 1'), findsNothing);
    expect(find.text('任务已完成'), findsNothing);
    expect(find.text('部分输出'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery-state-failed')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, '命令退出码为 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '收起失败提示'));
    await tester.pumpAndSettle();
    expect(find.text('任务执行失败'), findsNothing);
    expect(hasCurrentFailureEvidence(state.messages), isTrue);

    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.text('任务执行失败'), findsNothing);

    state.handleWsMessage(
      jsonEncode({
        'type': 'transcript_snapshot',
        'sessionId': 'demo-session-polish',
        'version': 1,
        'revision': 1,
        'running': false,
        'messages': (state.messages as List<TranscriptMessage>)
            .map((message) => message.toJson())
            .toList(),
        'pendingPermissions': [],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('任务执行失败'), findsNothing);

    beginPrompt(state.messages as List<TranscriptMessage>, '运行任务');
    state.handleWsMessage(
      jsonEncode({
        'type': 'error',
        'sessionId': 'demo-session-polish',
        'runId': 'next-failed-run',
        'message': '命令退出码为 1',
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('任务执行失败'), findsOneWidget);
    await state.lastTranscriptWrite;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('failure panel can be dismissed and shows a later failure', (
    tester,
  ) async {
    Future<void> pumpPanel({String detail = '本次任务失败'}) {
      return tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: RecoveryStatePanel(
              presentation: const ConsolePresentation(ConsolePhase.failed),
              failureDetail: detail,
              onReconnect: () {},
              onStop: () {},
              onOpenWorkspace: () {},
            ),
          ),
        ),
      );
    }

    await pumpPanel();
    expect(find.text('任务执行失败'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery-state-failed')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, '本次任务失败'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '收起失败提示'));
    await tester.pumpAndSettle();
    expect(find.text('任务执行失败'), findsNothing);

    await pumpPanel();
    await tester.pumpAndSettle();
    expect(find.text('任务执行失败'), findsNothing);

    await pumpPanel(detail: '下一次任务失败');
    await tester.pumpAndSettle();
    expect(find.text('任务执行失败'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery-state-failed')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, '下一次任务失败'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭状态详情'));
    await tester.pumpAndSettle();
  });

  testWidgets('failure dismiss control fits small screens and has a label', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    try {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          await tester.pumpWidget(
            MaterialApp(
              key: ValueKey((brightness, scale)),
              theme: buildSignalConsoleTheme(brightness),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(8),
                    child: RecoveryStatePanel(
                      presentation: const ConsolePresentation(
                        ConsolePhase.failed,
                      ),
                      failureDetail: '任务未完成，请检查错误后重新编辑上条指令再试一次。',
                      onReconnect: () {},
                      onStop: () {},
                      onOpenWorkspace: () {},
                      onEditPreviousPrompt: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          final status = find.byKey(const ValueKey('recovery-state-failed'));
          expect(tester.getSize(status).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(status).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(status).label, '任务执行失败');
          await tester.tap(status);
          await tester.pumpAndSettle();
          final dismiss = find.widgetWithText(TextButton, '收起失败提示');
          await tester.ensureVisible(dismiss);
          expect(tester.getSize(dismiss).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(dismiss).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(dismiss).label, '收起失败提示');
          expect(tester.takeException(), isNull);
          await tester.tap(dismiss);
          await tester.pumpAndSettle();
          expect(find.text('任务执行失败'), findsNothing);
        }
      }
    } finally {
      semantics.dispose();
    }
  });
}
