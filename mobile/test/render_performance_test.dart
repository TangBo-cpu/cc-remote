import 'dart:collection';
import 'dart:convert';

import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/message_markdown.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
                onOpenModelPicker: () {},
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
