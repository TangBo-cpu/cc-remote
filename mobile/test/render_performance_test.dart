import 'dart:collection';
import 'dart:convert';

import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/message_code.dart';
import 'package:cc_remote/message_markdown.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/workspace_diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('activity and session info keep the shell and rail mounted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(DemoShell));
    await state.connectDemoDevice();
    await tester.pumpAndSettle();
    state.handleWsMessage(
      jsonEncode({
        'type': 'status',
        'sessionId': state.activeSessionId,
        'authenticated': true,
        'running': true,
      }),
    );
    await tester.pumpAndSettle();
    final rail = tester.widget(find.byType(SessionRail));
    final chat = tester.widget(find.byType(ChatScreen));
    var transcriptUpdates = 0;
    (state.transcriptRevision as ValueNotifier<int>).addListener(
      () => transcriptUpdates++,
    );
    for (var i = 0; i < 20; i++) {
      state.handleWsMessage(
        jsonEncode({
          'type': 'activity',
          'sessionId': state.activeSessionId,
          'id': 'tool-$i',
          'kind': 'tool',
          'state': 'running',
          'toolName': 'Read',
        }),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget(find.byType(SessionRail)), same(rail));
    expect(tester.widget(find.byType(ChatScreen)), same(chat));
    expect(transcriptUpdates, inInclusiveRange(1, 3));
    expect(
      tester
          .widgetList<ActivityTimelineCard>(find.byType(ActivityTimelineCard))
          .expand((card) => card.activities),
      hasLength(20),
    );
    state.handleWsMessage(
      jsonEncode({
        'type': 'session_info',
        'sessionId': state.activeSessionId,
        'model': 'updated-model',
        'contextWindow': 200000,
        'remainingTokens': 100000,
      }),
    );
    await tester.pump();
    expect(tester.widget(find.byType(ChatScreen)), same(chat));
    expect(
      tester.widget<ConnectionHeader>(find.byType(ConnectionHeader)).modelName,
      'updated-model',
    );
    expect(
      tester.widget<PromptBar>(find.byType(PromptBar)).remainingContext,
      100000,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('large code stays readable while highlighting runs off-thread', (
    tester,
  ) async {
    var code = List.generate(1000, (i) => 'final value$i = $i;').join('\n');
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SingleChildScrollView(
                child: MessageCodeText(
                  code: code,
                  language: 'dart',
                  style: const TextStyle(fontSize: 13),
                ),
              );
            },
          ),
        ),
      ),
    );
    final dynamic state = tester.state(find.byType(MessageCodeText));
    expect(state.nodes, isNull);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byType(MessageCodeText),
              matching: find.byType(Text),
            ),
          )
          .textSpan!
          .toPlainText(),
      code,
    );
    update(
      () => code = List.generate(
        1000,
        (i) => 'final newest$i = true;',
      ).join('\n'),
    );
    await tester.pump();
    for (var i = 0; i < 200 && state.parsing == true; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(state.nodes, isNotNull);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byType(MessageCodeText),
              matching: find.byType(Text),
            ),
          )
          .textSpan!
          .toPlainText(),
      code,
    );
    update(() => code = 'final pending = false;\n' * 1000);
    await tester.pump();
    update(() => code = 'final latest = true;');
    await tester.pump();
    for (var i = 0; i < 200 && state.parsing == true; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byType(MessageCodeText),
        matching: find.byType(Text),
      ),
    );
    expect(text.textSpan!.toPlainText(), code);
    expect((text.textSpan! as TextSpan).children, isNotEmpty);
    expect(state.parsing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large diff paints before measuring offscreen line widths', (
    tester,
  ) async {
    final diff =
        '@@ -1,0 +1,1000 @@\n'
        '${List.generate(999, (i) => '+line $i').join('\n')}\n'
        '+${'wide ' * 1000}';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(body: WorkspaceDiffView(diff: diff)),
      ),
    );
    final horizontal = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('workspace-diff-horizontal-scroll')),
        )
        .controller!;
    expect(horizontal.position.maxScrollExtent, 0);
    await tester.pumpAndSettle();
    expect(horizontal.position.maxScrollExtent, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('workspace-diff-wrap')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workspace-diff-horizontal-scroll')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('workspace-diff-wrap')));
    await tester.pumpAndSettle();
    expect(horizontal.position.maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('diff replacement discards pending width measurements', (
    tester,
  ) async {
    var diff =
        '@@ -1,0 +1,1000 @@\n'
        '${List.generate(999, (i) => '+line $i').join('\n')}\n'
        '+${'old wide ' * 1000}';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return WorkspaceDiffView(diff: diff);
            },
          ),
        ),
      ),
    );
    update(() => diff = '@@ -1 +1 @@\n-old\n+new');
    await tester.pumpAndSettle();
    final horizontal = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('workspace-diff-horizontal-scroll')),
        )
        .controller!;
    expect(horizontal.position.maxScrollExtent, 0);
    expect(find.text('+new'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('streaming Markdown batches parsing and finishes immediately', (
    tester,
  ) async {
    var text = '**first**';
    var streaming = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MessageBlock(
                message: TranscriptMessage.assistant(text),
                isStreaming: streaming,
              );
            },
          ),
        ),
      ),
    );
    final markdown = find.byType(MessageMarkdownBody);
    final first = tester.widget<MessageMarkdownBody>(markdown);
    for (var i = 0; i < 3; i++) {
      update(() => text = '**update $i**');
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.widget(markdown), same(first));
    }
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.widget<MessageMarkdownBody>(markdown).data, '**update 2**');

    update(() => text = '**final**');
    await tester.pump(const Duration(milliseconds: 20));
    update(() => streaming = false);
    await tester.pump();
    expect(tester.widget<MessageMarkdownBody>(markdown).data, '**final**');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('plain streaming text is displayed without the Markdown delay', (
    tester,
  ) async {
    var text = 'first';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MessageBlock(
                message: TranscriptMessage.assistant(text),
                isStreaming: true,
              );
            },
          ),
        ),
      ),
    );
    update(() => text = 'latest plain text');
    await tester.pump();
    expect(find.text('latest plain text'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('streaming a reply does not rescan unchanged history', (
    tester,
  ) async {
    final messages = CountingMessages([
      for (var i = 0; i < 400; i++) TranscriptMessage.user('history $i'),
      TranscriptMessage.assistant('first reply'),
    ]);
    final revision = ValueNotifier(0);
    final controller = TextEditingController();
    addTearDown(revision.dispose);
    addTearDown(controller.dispose);
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ChatScreen(
                session: null,
                running: true,
                connected: true,
                offline: false,
                modelName: null,
                contextWindow: null,
                remainingContext: null,
                messages: messages,
                transcriptRevisionListenable: revision,
                commands: const [],
                permissionMode: PermissionMode.auto,
                allowBypassPermissions: false,
                pendingPermissions: const [],
                respondingPermissionIds: const {},
                promptController: controller,
                onFillPrompt: (_) {},
                onReconnect: () {},
                onOpenSettings: () {},
                onOpenModelPicker: (_) {},
                onNewConversation: () {},
                onOpenSessions: () {},
                onOpenWorkspace: () {},
                onPermissionModeSelected: (_) {},
                onPermissionAllow: (_) {},
                onPermissionDeny: (_) {},
                onSend: () {},
                onStop: () {},
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    messages[400] = TranscriptMessage.assistant('latest reply');
    messages.reads = 0;
    revision.value++;
    await tester.pump();
    await tester.pump();
    expect(messages.reads, lessThan(10));
    expect(find.text('latest reply'), findsOneWidget);

    update(() => messages[399] = TranscriptMessage.user('changed history'));
    await tester.pump();
    expect(find.text('changed history'), findsOneWidget);

    messages.add(TranscriptMessage.assistant('new reply'));
    revision.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('new reply'), findsOneWidget);
    messages[401] = TranscriptMessage.assistant('');
    revision.value++;
    await tester.pump();
    expect(find.text('new reply'), findsNothing);
    messages.add(
      TranscriptMessage.activity(
        'running',
        id: 'current-tool',
        kind: ActivityKind.tool,
        state: ActivityState.running,
        tool: 'Read',
      ),
    );
    messages.reads = 0;
    revision.value++;
    await tester.pump();
    await tester.pump();
    expect(messages.reads, lessThan(30));
    messages[messages.length - 1] = TranscriptMessage.activity(
      'done',
      id: 'current-tool',
      kind: ActivityKind.tool,
      state: ActivityState.done,
      tool: 'Read',
    );
    messages.reads = 0;
    revision.value++;
    await tester.pump();
    expect(messages.reads, lessThan(30));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final terminal in ['done', 'stopped', 'error', 'background']) {
    testWidgets('activity saves are batched and flushed on $terminal', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        const CcRemoteApp(enableCamera: false, demoMode: true),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(DemoShell));
      await state.connectDemoDevice();
      await tester.pumpAndSettle();
      state.handleWsMessage(
        jsonEncode({
          'type': 'status',
          'sessionId': state.activeSessionId,
          'authenticated': true,
          'running': true,
        }),
      );
      await state.lastTranscriptWrite;
      final before = state.lastTranscriptWrite;
      state.lastStreamPersistAt = DateTime.now();
      for (var i = 0; i < 20; i++) {
        state.handleWsMessage(
          jsonEncode({
            'type': 'activity',
            'sessionId': state.activeSessionId,
            'id': 'tool-$i',
            'kind': 'tool',
            'state': 'running',
            'toolName': 'Read',
          }),
        );
      }
      expect(state.lastTranscriptWrite, same(before));
      if (terminal == 'background') {
        state.didChangeAppLifecycleState(AppLifecycleState.paused);
      } else {
        state.handleWsMessage(
          jsonEncode({
            'type': terminal,
            'sessionId': state.activeSessionId,
            'exitCode': 0,
            'message': 'test failure',
          }),
        );
      }
      await state.lastTranscriptWrite;
      final TranscriptSnapshot snapshot = (await state.transcriptStore.load())!;
      expect(
        snapshot.messages.where((message) => message.activityTool == 'Read'),
        hasLength(20),
      );
      expect(snapshot.running, terminal == 'background');
      expect(state.streamPersistTimer, isNull);
      expect(state.activityRefreshTimer, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}

class CountingMessages extends ListBase<TranscriptMessage> {
  CountingMessages(this.messages);

  final List<TranscriptMessage> messages;
  int reads = 0;

  @override
  int get length => messages.length;

  @override
  set length(int value) => messages.length = value;

  @override
  TranscriptMessage operator [](int index) {
    reads++;
    return messages[index];
  }

  @override
  void operator []=(int index, TranscriptMessage value) =>
      messages[index] = value;

  @override
  void add(TranscriptMessage value) => messages.add(value);
}
