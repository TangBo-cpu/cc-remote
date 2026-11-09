import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/session_memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> snapshot({
  int revision = 5,
  String sessionId = 'a',
  bool running = false,
}) => {
  'type': 'transcript_snapshot',
  'sessionId': sessionId,
  'version': 1,
  'revision': revision,
  'running': running,
  if (running) 'runId': 'next-run',
  'pendingPermissions': [],
  'messages': [
    {
      'role': 'user',
      'text': '手机问题',
      'native': {
        'ids': ['native-user'],
        'hash': 'internal',
      },
      'nativePrompt': 'internal engine prompt',
    },
    {'role': 'assistant', 'text': '手机回复'},
    {'role': 'user', 'text': '电脑问题'},
    {'role': 'assistant', 'text': '电脑回复'},
    if (running) {'role': 'user', 'text': '手机继续'},
  ],
};

Future<dynamic> boot(WidgetTester tester) async {
  await tester.pumpWidget(
    CcRemoteApp(
      enableCamera: false,
      apiClient: RemoteApiClient(
        client: MockClient((_) async => http.Response('{}', 200)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final dynamic state = tester.state(find.byType(DemoShell));
  state.session = SavedSession(
    origin: Uri.parse('https://example.test'),
    token: 'token',
    deviceName: 'host',
  );
  state.route = ShellRoute.chat;
  state.handleWsMessage(
    jsonEncode({
      'type': 'catalog',
      'activeProjectId': 'project',
      'activeSessionId': 'a',
      'projects': [
        {'id': 'project', 'name': 'project', 'path': '/workspace'},
      ],
      'sessions': [
        for (final id in ['a', 'b'])
          {'id': id, 'projectId': 'project', 'title': id, 'engine': 'codex'},
      ],
    }),
  );
  state.handleWsMessage(
    jsonEncode({
      'type': 'status',
      'sessionId': 'a',
      'authenticated': true,
      'running': false,
    }),
  );
  await tester.pumpAndSettle();
  return state;
}

Future<void> disposeApp(WidgetTester tester, dynamic state) async {
  await state.lastTranscriptWrite;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'stream batches preserve IDs, late phases and multiple final messages',
    (tester) async {
      final dynamic state = await boot(tester);
      state.handleWsMessage(jsonEncode(snapshot(running: true)));
      void text(
        String id,
        String value, {
        String? phase,
        bool replace = false,
      }) {
        state.handleWsMessage(
          jsonEncode({
            'type': 'text',
            'sessionId': 'a',
            'runId': 'next-run',
            'messageId': id,
            'text': value,
            'phase': phase,
            'replace': replace,
          }),
        );
      }

      text('progress', '检查');
      text('progress', '检查完成。', phase: 'commentary', replace: true);
      text('partial', '确认上限。', phase: 'partial_answer');
      text('final', '第一段。\n\n第二段。', phase: 'final_answer');
      text('final', '\n\n第三段。\n\n第四段。', phase: 'final_answer');
      text('extra', '补充。', phase: 'final_answer', replace: true);
      state.handleWsMessage(
        jsonEncode({
          'type': 'done',
          'sessionId': 'a',
          'runId': 'next-run',
          'exitCode': 0,
        }),
      );
      final replies = (state.messages as List<TranscriptMessage>)
          .skip(5)
          .toList();
      expect(replies.map((message) => message.text), [
        '检查完成。',
        '确认上限。',
        '第一段。\n\n第二段。\n\n第三段。\n\n第四段。',
        '补充。',
      ]);
      expect(replies.map((message) => message.phase), [
        'commentary',
        'partial_answer',
        'final_answer',
        'final_answer',
      ]);
      expect(
        replies.map(
          (message) => TranscriptMessage.fromJson(message.toJson()).messageId,
        ),
        ['progress', 'partial', 'final', 'extra'],
      );
      await disposeApp(tester, state);
    },
  );

  testWidgets(
    'native snapshots preserve the current session, draft and reading memory',
    (tester) async {
      final dynamic state = await boot(tester);
      state.promptController.value = const TextEditingValue(
        text: '尚未发送的草稿',
        selection: TextSelection.collapsed(offset: 3),
      );
      const reading = TranscriptReadingPosition(
        followingBottom: false,
        scrollOffset: 240,
        rawIndex: 0,
        role: 'user',
        textPrefix: '手机问题',
      );
      state.sessionMemoryStore.forSession('a').readingPosition = reading;
      state.handleWsMessage(jsonEncode(snapshot()));
      expect(state.activeSessionId, 'a');
      expect(state.promptController.text, '尚未发送的草稿');
      expect(state.promptController.selection.baseOffset, 3);
      expect(
        state.sessionMemoryStore.forSession('a').readingPosition,
        same(reading),
      );
      expect(state.messages.map((dynamic message) => message.text).toList(), [
        '手机问题',
        '手机回复',
        '电脑问题',
        '电脑回复',
      ]);
      state.handleWsMessage(jsonEncode(snapshot()));
      expect(state.messages.length, 4);
      state.handleWsMessage(jsonEncode(snapshot(revision: 4, running: true)));
      expect(state.messages.length, 4);
      expect(state.running, isFalse);
      await disposeApp(tester, state);
    },
  );

  testWidgets(
    'background native snapshots do not replace the current conversation',
    (tester) async {
      final dynamic state = await boot(tester);
      state.handleWsMessage(jsonEncode(snapshot()));
      state.promptController.text = '当前草稿';
      state.handleWsMessage(
        jsonEncode(snapshot(sessionId: 'b', revision: 10, running: true)),
      );
      expect(state.activeSessionId, 'a');
      expect(state.remoteTranscriptRevision, 5);
      expect(state.messages.length, 4);
      expect(state.promptController.text, '当前草稿');
      await disposeApp(tester, state);
    },
  );

  testWidgets(
    'pre-send history snapshot keeps the new question and subsequent live reply',
    (tester) async {
      final dynamic state = await boot(tester);
      state.handleWsMessage(jsonEncode(snapshot(running: true)));
      state.handleWsMessage(
        jsonEncode({
          'type': 'text',
          'sessionId': 'a',
          'runId': 'next-run',
          'text': '接续回复',
        }),
      );
      state.flushStreamTextBatch();
      state.handleWsMessage(
        jsonEncode({
          'type': 'done',
          'sessionId': 'a',
          'runId': 'next-run',
          'exitCode': 0,
        }),
      );
      expect(state.messages.map((dynamic message) => message.text).toList(), [
        '手机问题',
        '手机回复',
        '电脑问题',
        '电脑回复',
        '手机继续',
        '接续回复',
      ]);
      expect(state.running, isFalse);
      await disposeApp(tester, state);
    },
  );

  for (final error in {
    'native_session_is_busy': '电脑端仍在处理这个会话，请等它完成后再发送',
    'native_history_sync_failed': '会话历史同步失败，已有记录已保留，请重试',
  }.entries) {
    testWidgets(error.key + ' explains how to continue and preserves history', (
      tester,
    ) async {
      final dynamic state = await boot(tester);
      state.handleWsMessage(jsonEncode(snapshot()));
      state.handleWsMessage(
        jsonEncode({'type': 'error', 'sessionId': 'a', 'message': error.key}),
      );
      expect(state.messages.length, 5);
      expect(state.messages.last.text, '错误：' + error.value);
      expect(state.messages.first.text, '手机问题');
      await disposeApp(tester, state);
    });
  }
}
