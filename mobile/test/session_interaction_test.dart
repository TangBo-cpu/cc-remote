import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/session_interaction.dart';

void main() {
  test(
    'session open intent peeks other sessions only while a turn is running',
    () {
      expect(
        sessionOpenIntent(
          targetSessionId: 'a',
          activeSessionId: 'a',
          running: true,
          uploading: false,
          wsReady: true,
          archived: false,
        ),
        SessionOpenIntent.jumpInPlace,
      );
      expect(
        sessionOpenIntent(
          targetSessionId: 'b',
          activeSessionId: 'a',
          running: true,
          uploading: false,
          wsReady: true,
          archived: false,
        ),
        SessionOpenIntent.peek,
      );
      expect(
        sessionOpenIntent(
          targetSessionId: 'b',
          activeSessionId: 'a',
          running: false,
          uploading: false,
          wsReady: true,
          archived: false,
        ),
        SessionOpenIntent.switchActive,
      );
      expect(
        sessionOpenIntent(
          targetSessionId: 'b',
          activeSessionId: 'a',
          running: true,
          uploading: true,
          wsReady: true,
          archived: false,
        ),
        SessionOpenIntent.ignore,
      );
      expect(
        sessionOpenIntent(
          targetSessionId: 'b',
          activeSessionId: 'a',
          running: false,
          uploading: false,
          wsReady: false,
          archived: false,
        ),
        SessionOpenIntent.ignore,
      );
      expect(
        sessionOpenIntent(
          targetSessionId: 'b',
          activeSessionId: 'a',
          running: true,
          uploading: false,
          wsReady: true,
          archived: true,
        ),
        SessionOpenIntent.ignore,
      );
    },
  );

  test('queued prompt is sent on done and restored on stop or error', () {
    expect(queuedPromptReleaseForTurn('done'), QueuedPromptRelease.send);
    expect(queuedPromptReleaseForTurn('stopped'), QueuedPromptRelease.restore);
    expect(queuedPromptReleaseForTurn('error'), QueuedPromptRelease.restore);
  });

  test('queued preview label trims and truncates the next prompt', () {
    expect(queuedPreviewLabel('下一轮跑测试'), '排队发送：下一轮跑测试');
    expect(
      queuedPreviewLabel('abcdefghijklmnopqrstuvwxyz012345'),
      '排队发送：abcdefghijklmnopqrstuvwx…',
    );

    expect(queuedPreviewLabel('', hasAttachments: true), '排队发送附件');
  });

  test('queued prompt only flushes for the live idle session', () {
    expect(
      shouldFlushQueuedPrompt(
        running: false,
        uploading: false,
        queuedSessionId: 'a',
        activeSessionId: 'a',
      ),
      isTrue,
    );
    expect(
      shouldFlushQueuedPrompt(
        running: true,
        uploading: false,
        queuedSessionId: 'a',
        activeSessionId: 'a',
      ),
      isFalse,
    );
    expect(
      shouldFlushQueuedPrompt(
        running: false,
        uploading: false,
        queuedSessionId: 'a',
        activeSessionId: 'b',
      ),
      isFalse,
    );
  });

  test('session peek payload parses daemon GET /api/sessions/:id', () {
    final payload = SessionPeekPayload.tryParse({
      'projectId': 'project-1',
      'sessionId': 'session-2',
      'title': '玻璃控制面',
      'archived': false,
      'transcript': {
        'version': 1,
        'revision': 4,
        'running': false,
        'permissionMode': 'auto',
        'pendingPermissions': const [],
        'messages': [
          {'role': 'user', 'text': '把控制面改成玻璃'},
          {'role': 'assistant', 'text': '玻璃控制面已经落地。'},
        ],
      },
    });

    expect(payload, isNotNull);
    expect(payload!.sessionId, 'session-2');
    expect(payload.title, '玻璃控制面');
    expect(payload.messages.map((message) => message.text), [
      '把控制面改成玻璃',
      '玻璃控制面已经落地。',
    ]);
  });

  test('demo peek transcripts stay distinct from the live session', () {
    expect(
      demoSessionPeekMessages('demo-session-glass').last.text,
      '玻璃控制面已经落地。',
    );
    expect(
      demoSessionPeekMessages('demo-session-polish').last.text,
      '实心小标已经换好。',
    );
    expect(
      demoSessionPeekMessages('demo-session-mobile').first.role,
      MessageRole.user,
    );
  });

  test('queued prompt preview uses the stored text', () {
    const queued = QueuedPrompt(sessionId: 's1', text: '继续检查权限');
    expect(queued.preview, '排队发送：继续检查权限');
    expect(queued.isEmpty, isFalse);
  });
}
