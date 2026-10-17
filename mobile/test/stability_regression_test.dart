import 'dart:async';

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/model_preference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<dynamic> start(
    WidgetTester tester,
    _DelayedModelStore modelStore,
  ) async {
    await tester.pumpWidget(
      CcRemoteApp(
        enableCamera: false,
        demoMode: true,
        modelPreferenceStore: modelStore,
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(DemoShell));
    await state.connectDemoDevice();
    await tester.pumpAndSettle();
    state.messages.clear();
    return state;
  }

  Future<void> finish(WidgetTester tester, dynamic state) async {
    await state.lastTranscriptWrite;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('a pending send cannot follow a session switch', (tester) async {
    final modelStore = _DelayedModelStore();
    final dynamic state = await start(tester, modelStore);
    state.promptController.text = 'draft for the first session';
    final Future<void> sending = state.sendPrompt();
    state.changeActiveSession('second-session');
    state.promptController.text = 'keep the second draft';
    modelStore.loaded.complete(ClaudeModelPreference.followComputer);
    await tester.pump();
    await sending;

    expect(
      state.messages.where((message) => message.role == MessageRole.user),
      isEmpty,
    );
    expect(state.promptController.text, 'keep the second draft');
    await finish(tester, state);
  });

  testWidgets('repeated send taps wait for one preference initialization', (
    tester,
  ) async {
    final modelStore = _DelayedModelStore();
    final dynamic state = await start(tester, modelStore);
    state.promptController.text = 'send this once';
    final Future<void> first = state.sendPrompt();
    final Future<void> second = state.sendPrompt();
    modelStore.loaded.complete(ClaudeModelPreference.followComputer);
    await tester.pump();
    await Future.wait([first, second]);

    expect(
      state.messages.where((message) => message.role == MessageRole.user),
      hasLength(1),
    );
    await finish(tester, state);
  });

  testWidgets('editing during preference loading preserves the newer draft', (
    tester,
  ) async {
    final modelStore = _DelayedModelStore();
    final dynamic state = await start(tester, modelStore);
    state.promptController.text = 'original draft';
    final Future<void> sending = state.sendPrompt();
    state.promptController.text = 'edited draft';
    modelStore.loaded.complete(ClaudeModelPreference.followComputer);
    await tester.pump();
    await sending;

    expect(
      state.messages.where((message) => message.role == MessageRole.user),
      isEmpty,
    );
    expect(state.promptController.text, 'edited draft');
    await finish(tester, state);
  });

  testWidgets('leaving a search preview clears its unfinished jump', (
    tester,
  ) async {
    final modelStore = _DelayedModelStore()
      ..loaded.complete(ClaudeModelPreference.followComputer);
    final dynamic state = await start(tester, modelStore);
    final target = (state.remoteSessions as List<RemoteSessionSummary>)
        .firstWhere((item) => item.id != state.activeSessionId);
    await state.openSessionPeek(
      target,
      jump: TranscriptJumpRequest(
        generation: 1,
        sessionId: target.id,
        messageIndex: 0,
        role: RemoteSessionSearchRole.user,
        snippet: '',
      ),
    );
    state.clearSessionPeek();

    expect(state.transcriptJumpRequest, isNull);
    await finish(tester, state);
  });
}

class _DelayedModelStore extends ClaudeModelPreferenceStore {
  final loaded = Completer<ClaudeModelPreference>();

  @override
  Future<ClaudeModelPreference> load() => loaded.future;
}
