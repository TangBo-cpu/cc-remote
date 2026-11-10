import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('long errors stay compact and keep the complete log in details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final log = List.generate(
      1000,
      (index) => '\u001b[33mWARN\u001b[0m plugin diagnostic $index',
    ).join('\n');
    final message = TranscriptMessage.system('错误：$log');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MessageBlock(message: message),
              const Text('后续回复'),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(MessageBlock)).height, lessThan(250));
    expect(find.text('后续回复').hitTestable(), findsOneWidget);
    expect(find.textContaining('diagnostic'), findsNothing);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    final details = tester.widget<SelectableText>(
      find.byKey(const ValueKey('failure-log-text')),
    );
    expect(details.data, contains('WARN plugin diagnostic 999'));
    expect(details.data, isNot(contains('\u001b')));
    expect(
      tester.getSize(find.byKey(const ValueKey('failure-log-scroll'))).height,
      lessThan(350),
    );
    expect(message.text, '错误：$log');
    expect(tester.takeException(), isNull);
  });

  testWidgets('error cards and sheets fit small screens and enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    try {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          for (final detail in ['连接超时，请检查电脑端网络。', 'path/' * 100, '']) {
            await tester.pumpWidget(
              MaterialApp(
                key: ValueKey((brightness, scale, detail)),
                theme: buildSignalConsoleTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      MessageBlock(
                        message: TranscriptMessage.system('错误：$detail'),
                      ),
                      const Text('后续回复'),
                    ],
                  ),
                ),
              ),
            );
            final card = find.byKey(const ValueKey('transcript-error-card'));
            expect(tester.getSize(card).width, 288);
            expect(tester.getSize(card).height, lessThan(300));
            expect(find.text('后续回复').hitTestable(), findsOneWidget);
            final open = find.widgetWithText(TextButton, '查看详情');
            expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
            expect(tester.getSemantics(open).label, '查看详情');
            await tester.tap(open);
            await tester.pumpAndSettle();
            final copy = find.byKey(const ValueKey('failure-log-copy'));
            expect(tester.getSize(copy).height, greaterThanOrEqualTo(48));
            expect(tester.getSemantics(copy).label, contains('复制日志'));
            expect(tester.takeException(), isNull);
            await tester.tap(find.byTooltip('关闭状态详情'));
            await tester.pumpAndSettle();
          }
        }
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('log copy masks credentials and reports clipboard failures', (
    tester,
  ) async {
    String? copied;
    var failCopy = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          if (failCopy) throw PlatformException(code: 'clipboard-unavailable');
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    const raw =
        '\u001b[31mERROR\u001b[0m engine failed\n'
        'API_KEY=fake-sensitive-key\nfinal diagnostic';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: MessageBlock(message: TranscriptMessage.system('错误：$raw')),
        ),
      ),
    );
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    final log = tester.widget<SelectableText>(
      find.byKey(const ValueKey('failure-log-text')),
    );
    expect(log.data, isNot(contains('fake-sensitive-key')));
    await tester.tap(find.byKey(const ValueKey('failure-log-copy')));
    await tester.pump();
    expect(copied, log.data);
    expect(copied, contains('final diagnostic'));
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('复制日志'), findsOneWidget);
    failCopy = true;
    await tester.tap(find.byKey(const ValueKey('failure-log-copy')));
    await tester.pumpAndSettle();
    expect(find.text('复制失败，请重试'), findsOneWidget);
    expect(find.text('已复制'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary system notices keep their existing presentation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBlock(message: TranscriptMessage.system('已停止')),
        ),
      ),
    );
    expect(find.widgetWithText(SelectableText, '已停止'), findsOneWidget);
    expect(find.byKey(const ValueKey('transcript-error-card')), findsNothing);
  });

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
    final failureStatus = find.byKey(const ValueKey('recovery-state-failed'));
    expect(failureStatus, findsOneWidget);
    expect(find.byKey(const ValueKey('transcript-error-card')), findsOneWidget);
    expect(find.text('命令退出码为 1'), findsOneWidget);
    expect(find.text('任务已完成'), findsNothing);
    expect(find.text('部分输出'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery-state-failed')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, '命令退出码为 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '收起失败提示'));
    await tester.pumpAndSettle();
    expect(failureStatus, findsNothing);
    expect(find.byKey(const ValueKey('transcript-error-card')), findsOneWidget);
    expect(hasCurrentFailureEvidence(state.messages), isTrue);

    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(failureStatus, findsNothing);

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
    expect(failureStatus, findsNothing);

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
    expect(failureStatus, findsOneWidget);
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
                      failureDetail: List.generate(
                        100,
                        (index) => '\u001b[33mWARN\u001b[0m diagnostic $index',
                      ).join('\n'),
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
          expect(
            tester
                .widget<SelectableText>(
                  find.byKey(const ValueKey('failure-log-text')),
                )
                .data,
            endsWith('WARN diagnostic 99'),
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('failure-log-scroll')))
                .height,
            lessThanOrEqualTo(280),
          );
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
