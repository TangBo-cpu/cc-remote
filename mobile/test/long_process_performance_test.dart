import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/tool_activity_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<TranscriptMessage> processMessages() => [
  TranscriptMessage.user('Check the project'),
  for (var i = 0; i < 150; i++)
    TranscriptMessage.activity(
      'Read',
      id: 'tool-$i',
      kind: ActivityKind.tool,
      state: ActivityState.done,
      tool: 'Read',
      detail: 'lib/file_$i.dart',
    ),
];

Widget host({
  required List<TranscriptMessage> messages,
  bool running = true,
  int messageStart = 10,
  TranscriptJumpRequest? jump,
  ValueChanged<TranscriptJumpRequest>? onJumpHandled,
}) => MaterialApp(
  theme: buildSignalConsoleTheme(),
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(
      body: TranscriptView(
        activeSessionId: 'session',
        messages: messages,
        messageStart: messageStart,
        running: running,
        jumpRequest: jump,
        onJumpHandled: onJumpHandled,
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

ScrollController transcriptScroll(WidgetTester tester) => tester
    .widget<CustomScrollView>(find.byKey(const ValueKey('transcript-list')))
    .controller!;

void main() {
  testWidgets('long process builds visible rows and retains detail choices', (
    tester,
  ) async {
    final messages = processMessages();
    await tester.pumpWidget(host(messages: messages));
    await tester.pumpAndSettle();
    expect(find.byType(ToolActivityDetail).evaluate().length, lessThan(30));
    final scroll = transcriptScroll(tester);
    scroll.jumpTo(scroll.position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity-detail-tool-0')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('activity-step-toggle-tool-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-detail-tool-0')), findsNothing);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity-step-toggle-tool-149')),
      findsOneWidget,
    );
    scroll.jumpTo(scroll.position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-detail-tool-0')), findsNothing);

    final toggle = find.byKey(const ValueKey('activity-process-toggle'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(ToolActivityDetail), findsNWidgets(2));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(ToolActivityDetail).evaluate().length, lessThan(30));

    await tester.pumpWidget(host(messages: messages, running: false));
    await tester.pumpAndSettle();
    expect(find.byType(ToolActivityDetail), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.byType(ToolActivityDetail).evaluate().length,
      inExclusiveRange(0, 30),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'prepending history preserves a long process anchor and details',
    (tester) async {
      final messages = processMessages();
      await tester.pumpWidget(host(messages: messages));
      await tester.pumpAndSettle();
      final scroll = transcriptScroll(tester);
      scroll.jumpTo(scroll.position.minScrollExtent);
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('activity-step-toggle-tool-0'));
      await tester.tap(first);
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(first).dy;
      await tester.pumpWidget(
        host(
          messages: [
            for (var i = 0; i < 10; i++) TranscriptMessage.user('older $i'),
            ...messages,
          ],
          messageStart: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(first).dy, closeTo(top, 1));
      expect(
        find.byKey(const ValueKey('activity-detail-tool-0')),
        findsNothing,
      );
      expect(find.byType(ToolActivityDetail).evaluate().length, lessThan(30));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a growing process retains details when it starts lazy layout', (
    tester,
  ) async {
    final messages = processMessages();
    await tester.pumpWidget(host(messages: messages.take(21).toList()));
    await tester.pumpAndSettle();
    final scroll = transcriptScroll(tester);
    scroll.jumpTo(scroll.position.minScrollExtent);
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('activity-step-toggle-tool-0'));
    await tester.tap(first);
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(first).dy;

    await tester.pumpWidget(host(messages: messages));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-detail-tool-0')), findsNothing);
    expect(tester.getTopLeft(first).dy, closeTo(top, 4));
    expect(find.byType(ToolActivityDetail).evaluate().length, lessThan(30));

    final before = tester.state(find.byType(ToolActivityDetail).first);
    await tester.pumpWidget(
      host(
        messages: [
          ...messages,
          const TranscriptMessage(
            MessageRole.assistant,
            'Still working',
            phase: 'commentary',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ToolActivityDetail).first), same(before));
    expect(find.byKey(const ValueKey('activity-detail-tool-0')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search reveals a lazy process row outside the viewport', (
    tester,
  ) async {
    final messages = processMessages();
    messages.insert(
      75,
      const TranscriptMessage(
        MessageRole.assistant,
        'Needle in the middle of the process',
        phase: 'commentary',
      ),
    );
    await tester.pumpWidget(host(messages: messages, running: false));
    await tester.pumpAndSettle();
    var handled = false;
    await tester.pumpWidget(
      host(
        messages: messages,
        running: false,
        jump: const TranscriptJumpRequest(
          generation: 1,
          sessionId: 'session',
          messageIndex: 85,
          role: RemoteSessionSearchRole.assistant,
          snippet: 'Needle in the middle',
        ),
        onJumpHandled: (_) => handled = true,
      ),
    );
    for (var i = 0; i < 60 && !handled; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(handled, isTrue);
    await tester.pump();
    final hit = find.byKey(const ValueKey('transcript-search-hit-75'));
    expect(hit, findsOneWidget);
    expect(tester.getTopLeft(hit).dy, inInclusiveRange(0, 600));
    expect(find.byType(ToolActivityDetail).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
