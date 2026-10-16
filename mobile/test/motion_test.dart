import 'dart:convert';

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/transcript_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {bool reduced = false, double scale = 1}) =>
    MaterialApp(
      theme: buildSignalConsoleTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: reduced,
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(body: child),
      ),
    );

Widget transcript(
  TranscriptMotion motion,
  List<TranscriptMessage> messages, {
  List<RemotePermissionRequest> permissions = const [],
  String sessionId = 'session',
  VoidCallback? allow,
}) => TranscriptView(
  motion: motion,
  messages: messages,
  activeSessionId: sessionId,
  pendingPermissions: permissions,
  respondingPermissionIds: const {},
  connected: true,
  onFillPrompt: (_) {},
  onReconnect: () {},
  onPermissionAllow: (_) => allow?.call(),
  onPermissionDeny: (_) {},
);

double opacityOf(WidgetTester tester, Finder entrance) => tester
    .widget<FadeTransition>(
      find
          .descendant(of: entrance, matching: find.byType(FadeTransition))
          .first,
    )
    .opacity
    .value;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('cues follow message identity through streaming, then consume once', () {
    final motion = TranscriptMotion();
    final first = TranscriptMessage.assistant('first');
    final next = TranscriptMessage.assistant('first delta');
    motion.recordMessage(first);
    motion.replaceMessage(first, next);
    expect(motion.takeMessage(first), isFalse);
    expect(motion.takeMessage(next), isTrue);
    expect(motion.takeMessage(next), isFalse);
    motion.replaceMessage(next, first);
    expect(motion.takeMessage(first), isFalse);
    expect(motion.takeMessage(TranscriptMessage.assistant('first')), isFalse);
  });

  test('reset discards restored entrances and successful completion cues', () {
    final motion = TranscriptMotion();
    final message = TranscriptMessage.user('hello');
    motion.recordMessage(message);
    motion.recordPermission('permission');
    motion.completeRun('run');
    final completion = motion.completionEvent;
    motion.completeRun('run');
    expect(motion.completionEvent, same(completion));
    motion.reset();
    expect(motion.completionEvent, isNull);
    expect(motion.takeMessage(message), isFalse);
    expect(motion.takePermission('permission'), isFalse);
  });

  testWidgets('live message enters once; streaming and remount do not replay', (
    tester,
  ) async {
    final motion = TranscriptMotion();
    final messages = [TranscriptMessage.user('hello')];
    await tester.pumpWidget(host(transcript(motion, messages)));
    await tester.pumpAndSettle();
    final reply = TranscriptMessage.assistant('reply');
    motion.recordMessage(reply);
    messages.add(reply);
    await tester.pumpWidget(host(transcript(motion, messages)));
    final entrance = find.byKey(const ValueKey('message-entrance-1'));
    expect(opacityOf(tester, entrance), 0);
    await tester.pump(const Duration(milliseconds: 80));
    expect(opacityOf(tester, entrance), inExclusiveRange(0, 1));
    final merged = TranscriptMessage.assistant('reply continued');
    motion.replaceMessage(reply, merged);
    messages[1] = merged;
    final midway = opacityOf(tester, entrance);
    await tester.pumpWidget(host(transcript(motion, messages)));
    expect(opacityOf(tester, entrance), greaterThanOrEqualTo(midway));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, entrance), 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host(transcript(motion, messages)));
    expect(opacityOf(tester, entrance), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first paint, snapshots and session changes never enter', (
    tester,
  ) async {
    final motion = TranscriptMotion();
    var message = TranscriptMessage.user('cached');
    motion.recordMessage(message);
    await tester.pumpWidget(host(transcript(motion, [message])));
    final entrance = find.byKey(const ValueKey('message-entrance-0'));
    expect(opacityOf(tester, entrance), 1);
    message = TranscriptMessage.user('snapshot');
    motion.recordMessage(message);
    motion.reset();
    await tester.pumpWidget(host(transcript(motion, [message])));
    expect(opacityOf(tester, entrance), 1);
    message = TranscriptMessage.user('other session');
    motion.recordMessage(message);
    await tester.pumpWidget(
      host(transcript(motion, [message], sessionId: 'other')),
    );
    expect(opacityOf(tester, entrance), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fresh permission enters once and its buttons remain usable', (
    tester,
  ) async {
    final motion = TranscriptMotion();
    var allowed = false;
    final messages = [TranscriptMessage.user('run')];
    const request = RemotePermissionRequest(
      requestId: 'request',
      toolName: 'Bash',
      detail: 'flutter test',
    );
    await tester.pumpWidget(host(transcript(motion, messages)));
    await tester.pumpAndSettle();
    motion.recordPermission(request.requestId);
    await tester.pumpWidget(
      host(
        transcript(
          motion,
          messages,
          permissions: [request],
          allow: () => allowed = true,
        ),
      ),
    );
    final entrance = find.byKey(const ValueKey('permission-entrance-request'));
    expect(opacityOf(tester, entrance), 0);
    await tester.pump(const Duration(milliseconds: 30));
    expect(opacityOf(tester, entrance), inExclusiveRange(0, 1));
    final button = find.widgetWithText(FilledButton, '仅本次允许');
    await tester.tap(button);
    expect(allowed, isTrue);
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      host(transcript(motion, messages, permissions: [request])),
    );
    expect(opacityOf(tester, entrance), 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      host(transcript(motion, messages, permissions: [request])),
    );
    expect(opacityOf(tester, entrance), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reduced motion finishes entrances immediately, including mid-flight',
    (tester) async {
      Widget entrance({bool reduced = false}) => host(
        const SignalEntrance(
          animate: true,
          distance: 6,
          child: Text('content'),
        ),
        reduced: reduced,
      );
      await tester.pumpWidget(entrance());
      expect(opacityOf(tester, find.byType(SignalEntrance)), 0);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(entrance(reduced: true));
      expect(opacityOf(tester, find.byType(SignalEntrance)), 1);
      await tester.pumpWidget(entrance());
      expect(opacityOf(tester, find.byType(SignalEntrance)), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing an entrance mid-flight releases its ticker', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const SignalEntrance(
          animate: true,
          distance: 4,
          child: Text('request'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('completion requires a new explicit cue, not a phase change', (
    tester,
  ) async {
    Widget panel(ConsolePhase phase, [Object? cue]) => host(
      RecoveryStatePanel(
        presentation: ConsolePresentation(phase),
        completionEvent: cue,
        onReconnect: () {},
        onStop: () {},
        onOpenWorkspace: () {},
      ),
    );
    await tester.pumpWidget(panel(ConsolePhase.running));
    await tester.pumpWidget(panel(ConsolePhase.connected));
    expect(find.text('任务已完成'), findsNothing);
    final cue = Object();
    await tester.pumpWidget(panel(ConsolePhase.connected, cue));
    expect(find.text('任务已完成'), findsOneWidget);
    expect(find.byType(SignalCompletionIcon), findsOneWidget);
    await tester.pump(AppMotion.signal);
    await tester.pumpAndSettle();
    await tester.pumpWidget(panel(ConsolePhase.connected, cue));
    expect(find.text('任务已完成'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(panel(ConsolePhase.connected, cue));
    expect(find.text('任务已完成'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'shell emits cues only for live updates and explicit successful done',
    (tester) async {
      await tester.pumpWidget(
        const CcRemoteApp(enableCamera: false, demoMode: true),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(DemoShell));
      await state.connectDemoDevice();
      await tester.pumpAndSettle();
      final motion = state.transcriptMotion as TranscriptMotion;
      void emit(Map<String, Object?> event) => state.handleWsMessage(
        jsonEncode({
          'sessionId': 'demo-session-polish',
          'runId': 'run',
          ...event,
        }),
      );
      beginPrompt(state.messages as List<TranscriptMessage>, 'run');
      emit({'type': 'status', 'authenticated': true, 'running': true});
      state.appendAssistantText('first');
      state.appendAssistantText(' delta');
      expect(
        motion.takeMessage((state.messages as List<TranscriptMessage>).last),
        isTrue,
      );
      state.appendAssistantText(' more');
      expect(
        motion.takeMessage((state.messages as List<TranscriptMessage>).last),
        isFalse,
      );
      emit({
        'type': 'permission_request',
        'requestId': 'p',
        'toolName': 'Bash',
      });
      expect(motion.takePermission('p'), isTrue);
      emit({
        'type': 'permission_request',
        'requestId': 'p',
        'toolName': 'Bash',
      });
      expect(motion.takePermission('p'), isFalse);
      emit({'type': 'status', 'authenticated': true, 'running': false});
      expect(motion.completionEvent, isNull);
      emit({'type': 'done', 'exitCode': 0});
      final completion = motion.completionEvent;
      expect(completion, isNotNull);
      emit({'type': 'done', 'exitCode': 0});
      expect(motion.completionEvent, same(completion));
      emit({
        'type': 'transcript_snapshot',
        'version': 1,
        'revision': 1,
        'running': false,
        'messages': (state.messages as List<TranscriptMessage>)
            .map((m) => m.toJson())
            .toList(),
        'pendingPermissions': [
          {'requestId': 'restored', 'toolName': 'Bash'},
        ],
      });
      expect(motion.completionEvent, isNull);
      expect(motion.takePermission('restored'), isFalse);
      emit({'type': 'done', 'exitCode': 0});
      expect(motion.completionEvent, isNull);
      emit({'type': 'done', 'exitCode': 1});
      expect(motion.completionEvent, isNull);
      emit({'type': 'done'});
      expect(motion.completionEvent, isNull);
      await state.lastTranscriptWrite;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'reading history neither moves the anchor nor queues late entrances',
    (tester) async {
      final motion = TranscriptMotion();
      final messages = List.generate(
        30,
        (index) => TranscriptMessage.user('history $index'),
      );
      await tester.pumpWidget(host(transcript(motion, messages)));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<ListView>(find.byKey(const ValueKey('transcript-list')))
          .controller!;
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      final message = TranscriptMessage.assistant('live output');
      motion.recordMessage(message);
      messages.add(message);
      await tester.pumpWidget(host(transcript(motion, messages)));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(motion.takeMessage(message), isFalse);
      expect(
        find.byKey(const ValueKey('transcript-new-output')),
        findsOneWidget,
      );
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        opacityOf(tester, find.byKey(const ValueKey('message-entrance-30'))),
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('background events do not queue visual feedback for resume', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(DemoShell));
    await state.connectDemoDevice();
    await tester.pumpAndSettle();
    final motion = state.transcriptMotion as TranscriptMotion;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    state.appendAssistantText('background reply');
    expect(
      motion.takeMessage((state.messages as List<TranscriptMessage>).last),
      isFalse,
    );
    for (final event in [
      {
        'type': 'permission_request',
        'requestId': 'background',
        'toolName': 'Bash',
      },
      {'type': 'done', 'exitCode': 0},
    ]) {
      state.handleWsMessage(
        jsonEncode({
          'sessionId': 'demo-session-polish',
          'runId': 'background-run',
          ...event,
        }),
      );
    }
    expect(motion.takePermission('background'), isFalse);
    expect(motion.completionEvent, isNull);
    await state.lastTranscriptWrite;
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'completion paints the final check without motion in ${brightness.name}',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSignalConsoleTheme(brightness),
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Builder(
                builder: (context) => SignalCompletionIcon(
                  color: AppPalette.of(context).success,
                  size: 24,
                ),
              ),
            ),
          ),
        );
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(SignalCompletionIcon),
            matching: find.byType(CustomPaint),
          ),
        );
        final dynamic painter = paint.painter;
        expect(painter.progress, 1);
        expect(
          painter.color,
          brightness == Brightness.dark
              ? AppPalette.dark.success
              : AppPalette.light.success,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }

  for (final reduced in [false, true]) {
    testWidgets(
      'copy confirms only after success; stable controls; reduced=$reduced',
      (tester) async {
        var fail = false;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData' && fail) {
              throw PlatformException(code: 'clipboard_unavailable');
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          host(
            MessageBlock(
              message: TranscriptMessage.assistant('```dart\nhello();\n```'),
            ),
            reduced: reduced,
            scale: 2,
          ),
        );
        final button = find.byKey(const ValueKey('code-copy-button'));
        final rect = tester.getRect(button);
        await tester.tap(button);
        await tester.pump();
        expect(find.byTooltip('已复制'), findsOneWidget);
        expect(tester.getRect(button), rect);
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1200));
        expect(find.byTooltip('已复制'), findsOneWidget);
        expect(tester.getRect(button), rect);
        fail = true;
        await tester.tap(button);
        await tester.pump();
        expect(find.byTooltip('已复制'), findsNothing);
        expect(find.text('复制失败，请重试'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 3));
      },
    );
  }
}
