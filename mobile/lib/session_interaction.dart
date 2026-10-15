import 'attachments.dart';
import 'data/permission_mode.dart';
import 'data/remote_models.dart';

enum SessionOpenIntent { ignore, jumpInPlace, peek, switchActive }

enum QueuedPromptRelease { send, restore }

class QueuedPrompt {
  const QueuedPrompt({
    required this.sessionId,
    required this.text,
    this.attachments = const [],
    this.permissionMode = PermissionMode.auto,
    this.codexSandboxMode = CodexSandboxMode.dangerFullAccess,
  });

  final String sessionId;
  final List<AttachmentDraft> attachments;
  final PermissionMode permissionMode;
  final CodexSandboxMode codexSandboxMode;
  final String text;

  bool get isEmpty => text.trim().isEmpty && attachments.isEmpty;

  String get preview =>
      queuedPreviewLabel(text, hasAttachments: attachments.isNotEmpty);
}

class SessionPeekPayload {
  const SessionPeekPayload({
    required this.sessionId,
    required this.projectId,
    required this.title,
    required this.messages,
    this.archived = false,
  });

  final String sessionId;
  final String projectId;
  final String title;
  final List<TranscriptMessage> messages;
  final bool archived;

  static SessionPeekPayload? tryParse(Map<String, dynamic> json) {
    final sessionId = json['sessionId'];
    final projectId = json['projectId'];
    final title = json['title'];
    final transcriptJson = json['transcript'];
    if (sessionId is! String ||
        projectId is! String ||
        title is! String ||
        transcriptJson is! Map) {
      return null;
    }
    final snapshot = RemoteTranscriptSnapshot.tryParse(
      Map<String, dynamic>.from(transcriptJson),
    );
    if (snapshot == null) return null;
    return SessionPeekPayload(
      sessionId: sessionId,
      projectId: projectId,
      title: title,
      archived: json['archived'] == true,
      messages: snapshot.messages,
    );
  }
}

class SessionPeekView {
  const SessionPeekView({
    required this.sessionId,
    required this.title,
    required this.messages,
    this.loading = false,
    this.failed = false,
    this.liveRunning = false,
    this.hasLiveUpdate = false,
    this.queuedPreview,
  });

  final String sessionId;
  final String title;
  final List<TranscriptMessage> messages;
  final bool loading;
  final bool failed;
  final bool liveRunning;
  final bool hasLiveUpdate;
  final String? queuedPreview;
}

SessionOpenIntent sessionOpenIntent({
  required String targetSessionId,
  required String? activeSessionId,
  required bool running,
  required bool uploading,
  required bool wsReady,
  required bool archived,
}) {
  if (archived || uploading) return SessionOpenIntent.ignore;
  if (targetSessionId == activeSessionId) return SessionOpenIntent.jumpInPlace;
  if (running) return SessionOpenIntent.peek;
  if (!wsReady) return SessionOpenIntent.ignore;
  return SessionOpenIntent.switchActive;
}

QueuedPromptRelease queuedPromptReleaseForTurn(String endType) {
  return endType == 'done'
      ? QueuedPromptRelease.send
      : QueuedPromptRelease.restore;
}

String queuedPreviewLabel(String text, {bool hasAttachments = false}) {
  final trimmed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (trimmed.isEmpty) {
    return hasAttachments ? '排队发送附件' : '排队发送';
  }
  if (trimmed.length <= 24) return '排队发送：$trimmed';
  return '排队发送：${trimmed.substring(0, 24)}…';
}

bool shouldFlushQueuedPrompt({
  required bool running,
  required bool uploading,
  required String? queuedSessionId,
  required String? activeSessionId,
}) {
  if (running || uploading) return false;
  if (queuedSessionId == null || activeSessionId == null) return false;
  return queuedSessionId == activeSessionId;
}

List<TranscriptMessage> demoSessionPeekMessages(String sessionId) {
  return switch (sessionId) {
    'demo-session-polish' => const [
      TranscriptMessage(MessageRole.user, '图标改成实心小标'),
      TranscriptMessage(MessageRole.assistant, '实心小标已经换好。'),
    ],
    'demo-session-glass' => const [
      TranscriptMessage(MessageRole.user, '把控制面改成玻璃'),
      TranscriptMessage(MessageRole.assistant, '玻璃控制面已经落地。'),
    ],
    'demo-session-mobile' => const [
      TranscriptMessage(MessageRole.user, '配对页扫码'),
      TranscriptMessage(MessageRole.assistant, '扫码页已接好相机权限。'),
    ],
    _ => const [TranscriptMessage(MessageRole.system, '这是只读预览，不会打断当前任务。')],
  };
}
