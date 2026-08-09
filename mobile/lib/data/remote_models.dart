import 'dart:convert';

import 'package:cc_remote/attachments.dart';

import 'permission_mode.dart';

class PairingPayload {
  const PairingPayload({
    required this.origin,
    required this.nonce,
    required this.deviceName,
    required this.expiresAt,
  });

  final Uri origin;
  final String nonce;
  final String deviceName;
  final DateTime expiresAt;

  static PairingPayload parse(String raw) {
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('bad_pairing_payload');
    }
    if (data['type'] != 'cc-remote-pair' || data['version'] != 1) {
      throw const FormatException('bad_pairing_payload');
    }

    final origin = Uri.tryParse(data['origin'] as String? ?? '');
    final nonce = data['nonce'];
    final expiresAt = data['expiresAt'];
    if (origin == null ||
        !origin.hasScheme ||
        (origin.scheme != 'https' && origin.scheme != 'http') ||
        nonce is! String ||
        nonce.trim().isEmpty ||
        expiresAt is! int) {
      throw const FormatException('bad_pairing_payload');
    }
    if (expiresAt <= DateTime.now().millisecondsSinceEpoch) {
      throw const FormatException('expired_pairing_payload');
    }

    return PairingPayload(
      origin: origin,
      nonce: nonce.trim(),
      deviceName: data['deviceName'] as String? ?? 'Unknown PC',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
    );
  }
}

class SavedSession {
  const SavedSession({
    required this.origin,
    required this.token,
    required this.deviceName,
    this.workspaceDir,
  });

  final Uri origin;
  final String token;
  final String deviceName;
  final String? workspaceDir;

  String get workspaceName {
    final dir = workspaceDir;
    if (dir == null || dir.isEmpty) return 'cc-remote';
    return dir.replaceAll(r'\', '/').split('/').last;
  }

  SavedSession copyWith({String? deviceName, String? workspaceDir}) {
    return SavedSession(
      origin: origin,
      token: token,
      deviceName: deviceName ?? this.deviceName,
      workspaceDir: workspaceDir ?? this.workspaceDir,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'origin': origin.toString(),
      'token': token,
      'deviceName': deviceName,
      if (workspaceDir != null) 'workspaceDir': workspaceDir,
    };
  }

  static SavedSession fromJson(Map<String, dynamic> json) {
    final origin = Uri.parse(json['origin'] as String);
    return SavedSession(
      origin: origin,
      token: json['token'] as String,
      deviceName: json['deviceName'] as String? ?? 'Unknown PC',
      workspaceDir: json['workspaceDir'] as String?,
    );
  }
}

class RemoteProjectCatalog {
  const RemoteProjectCatalog({
    required this.activeProjectId,
    required this.activeSessionId,
    required this.projects,
    required this.sessions,
  });

  final String activeProjectId;
  final String activeSessionId;
  final List<RemoteProjectSummary> projects;
  final List<RemoteSessionSummary> sessions;

  RemoteProjectSummary? get activeProject {
    for (final project in projects) {
      if (project.id == activeProjectId) return project;
    }
    return null;
  }

  static RemoteProjectCatalog? tryParse(Map<String, dynamic> json) {
    final activeProjectId = json['activeProjectId'];
    final activeSessionId = json['activeSessionId'];
    final rawProjects = json['projects'];
    final rawSessions = json['sessions'];
    if (activeProjectId is! String ||
        activeSessionId is! String ||
        rawProjects is! List ||
        rawSessions is! List) {
      return null;
    }
    return RemoteProjectCatalog(
      activeProjectId: activeProjectId,
      activeSessionId: activeSessionId,
      projects: rawProjects
          .whereType<Map>()
          .map(
            (item) =>
                RemoteProjectSummary.tryParse(Map<String, dynamic>.from(item)),
          )
          .whereType<RemoteProjectSummary>()
          .toList(),
      sessions: rawSessions
          .whereType<Map>()
          .map(
            (item) =>
                RemoteSessionSummary.tryParse(Map<String, dynamic>.from(item)),
          )
          .whereType<RemoteSessionSummary>()
          .toList(),
    );
  }
}

class RemoteProjectSummary {
  const RemoteProjectSummary({
    required this.id,
    required this.name,
    required this.path,
    required this.sessionCount,
    required this.running,
  });

  final String id;
  final String name;
  final String path;
  final int sessionCount;
  final bool running;

  static RemoteProjectSummary? tryParse(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final path = json['path'];
    if (id is! String || name is! String || path is! String) return null;
    return RemoteProjectSummary(
      id: id,
      name: name,
      path: path,
      sessionCount: (json['sessionCount'] as num?)?.toInt() ?? 0,
      running: json['running'] == true,
    );
  }
}

class RemoteSessionSummary {
  const RemoteSessionSummary({
    required this.id,
    required this.projectId,
    required this.title,
    required this.updatedAt,
    required this.running,
    required this.messageCount,
    this.model,
    this.archived = false,
  });

  final String id;
  final String projectId;
  final String title;
  final int updatedAt;
  final bool running;
  final int messageCount;
  final String? model;
  final bool archived;

  String get summary {
    final parts = <String>[];
    if (archived) parts.add('已归档');
    if (running) parts.add('运行中');
    if (model != null) parts.add(formatModelName(model!));
    parts.add('$messageCount 条消息');
    return parts.join(' · ');
  }

  static RemoteSessionSummary? tryParse(Map<String, dynamic> json) {
    final id = json['id'];
    final projectId = json['projectId'];
    final title = json['title'];
    if (id is! String || projectId is! String || title is! String) return null;
    return RemoteSessionSummary(
      id: id,
      projectId: projectId,
      title: title,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      running: json['running'] == true,
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      model: json['model'] as String?,
      archived: json['archived'] == true || json['archivedAt'] is num,
    );
  }
}

String formatModelName(String model) {
  final match = RegExp(r'^claude-([a-z]+)-(\d+)-(\d+)$').firstMatch(model);
  if (match == null) return model;
  final family = match.group(1)!;
  return '${family[0].toUpperCase()}${family.substring(1)} ${match.group(2)}.${match.group(3)}';
}

class RemoteStatus {
  const RemoteStatus({
    required this.deviceName,
    required this.workspaceDir,
    required this.running,
    required this.hasSessionInfo,
    this.stopping = false,
    this.runId,
    this.startedAt,
    this.catalog,
    this.modelName,
    this.contextWindow,
    this.remainingContext,
  });

  final String? deviceName;
  final String? workspaceDir;
  final bool running;
  final bool hasSessionInfo;
  final bool stopping;
  final String? runId;
  final DateTime? startedAt;
  final RemoteProjectCatalog? catalog;
  final String? modelName;
  final int? contextWindow;
  final int? remainingContext;

  static RemoteStatus fromJson(Map<String, dynamic> json) {
    final rawSessionInfo = json['sessionInfo'];
    final sessionInfo = rawSessionInfo is Map<String, dynamic>
        ? rawSessionInfo
        : const <String, dynamic>{};
    return RemoteStatus(
      deviceName: json['deviceName'] as String?,
      workspaceDir: json['workspaceDir'] as String?,
      running: json['running'] == true,
      hasSessionInfo: rawSessionInfo is Map<String, dynamic>,
      stopping: json['stopping'] == true,
      runId: json['runId'] as String?,
      startedAt: _dateTimeFromMilliseconds(json['startedAt']),
      catalog: json['catalog'] is Map<String, dynamic>
          ? RemoteProjectCatalog.tryParse(
              json['catalog'] as Map<String, dynamic>,
            )
          : null,
      modelName: sessionInfo['model'] as String?,
      contextWindow: (sessionInfo['contextWindow'] as num?)?.toInt(),
      remainingContext: (sessionInfo['remainingTokens'] as num?)?.toInt(),
    );
  }
}

class RemoteActivity {
  const RemoteActivity({
    required this.id,
    required this.kind,
    required this.state,
    this.toolName,
    this.detail,
    this.durationMs,
    this.numTurns,
    this.permissionDenials,
  });

  final String id;
  final ActivityKind kind;
  final ActivityState state;
  final String? toolName;
  final String? detail;
  final int? durationMs;
  final int? numTurns;
  final int? permissionDenials;

  static RemoteActivity? tryParse(Map<String, dynamic> json) {
    final id = json['id'];
    final kind = switch (json['kind']) {
      'thinking' => ActivityKind.thinking,
      'tool' => ActivityKind.tool,
      'summary' => ActivityKind.summary,
      _ => null,
    };
    final state = switch (json['state']) {
      'running' => ActivityState.running,
      'done' => ActivityState.done,
      'error' => ActivityState.error,
      'stopped' => ActivityState.stopped,
      _ => null,
    };
    if (id is! String || kind == null || state == null) return null;
    return RemoteActivity(
      id: id,
      kind: kind,
      state: state,
      toolName: json['toolName'] as String?,
      detail: json['detail'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      numTurns: (json['numTurns'] as num?)?.toInt(),
      permissionDenials: (json['permissionDenials'] as num?)?.toInt(),
    );
  }
}

class RemotePermissionRequest {
  const RemotePermissionRequest({
    required this.requestId,
    required this.toolName,
    this.detail,
    this.title,
    this.displayName,
    this.description,
    this.decisionReason,
  });

  final String requestId;
  final String toolName;
  final String? detail;
  final String? title;
  final String? displayName;
  final String? description;
  final String? decisionReason;

  static RemotePermissionRequest? tryParse(Map<String, dynamic> json) {
    final requestId = json['requestId'];
    final toolName = json['toolName'];
    if (requestId is! String || toolName is! String) return null;
    return RemotePermissionRequest(
      requestId: requestId,
      toolName: toolName,
      detail: json['detail'] as String?,
      title: json['title'] as String?,
      displayName: json['displayName'] as String?,
      description: json['description'] as String?,
      decisionReason: json['decisionReason'] as String?,
    );
  }
}

class RemoteTranscriptSnapshot {
  const RemoteTranscriptSnapshot({
    required this.revision,
    required this.running,
    required this.messages,
    required this.permissionMode,
    required this.pendingPermissions,
    this.stopping = false,
    this.runId,
    this.startedAt,
    this.modelName,
    this.contextWindow,
    this.remainingContext,
  });

  final int revision;
  final bool running;
  final List<TranscriptMessage> messages;
  final PermissionMode permissionMode;
  final List<RemotePermissionRequest> pendingPermissions;
  final bool stopping;
  final String? runId;
  final DateTime? startedAt;
  final String? modelName;
  final int? contextWindow;
  final int? remainingContext;

  static RemoteTranscriptSnapshot? tryParse(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['revision'] is! num) return null;
    final rawMessages = json['messages'];
    if (rawMessages is! List) return null;
    final rawSessionInfo = json['sessionInfo'];
    final sessionInfo = rawSessionInfo is Map<String, dynamic>
        ? rawSessionInfo
        : const <String, dynamic>{};
    try {
      return RemoteTranscriptSnapshot(
        revision: (json['revision'] as num).toInt(),
        running: json['running'] == true,
        messages: rawMessages
            .map(
              (message) => TranscriptMessage.fromJson(
                Map<String, dynamic>.from(message as Map),
              ),
            )
            .toList(),
        permissionMode: PermissionMode.fromWire(json['permissionMode']),
        stopping: json['stopping'] == true,
        runId: json['runId'] as String?,
        startedAt: _dateTimeFromMilliseconds(json['startedAt']),
        pendingPermissions: (json['pendingPermissions'] as List? ?? const [])
            .map(
              (item) => RemotePermissionRequest.tryParse(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .whereType<RemotePermissionRequest>()
            .toList(),
        modelName: sessionInfo['model'] as String?,
        contextWindow: (sessionInfo['contextWindow'] as num?)?.toInt(),
        remainingContext: (sessionInfo['remainingTokens'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

bool shouldApplyRemoteTranscriptSnapshot({
  required RemoteTranscriptSnapshot snapshot,
  required int currentRevision,
  required bool hasLocalMessages,
}) {
  if (snapshot.revision < currentRevision) return false;
  return snapshot.revision != 0 || !hasLocalMessages;
}

DateTime? _dateTimeFromMilliseconds(Object? value) {
  if (value is! num) return null;
  return DateTime.fromMillisecondsSinceEpoch(value.toInt());
}

class TranscriptSnapshot {
  const TranscriptSnapshot({
    required this.messages,
    required this.running,
    this.modelName,
    this.contextWindow,
    this.remainingContext,
  });

  static const schemaVersion = 1;
  final List<TranscriptMessage> messages;
  final bool running;
  final String? modelName;
  final int? contextWindow;
  final int? remainingContext;

  Map<String, dynamic> toJson() {
    return {
      'version': schemaVersion,
      'running': running,
      'modelName': modelName,
      'contextWindow': contextWindow,
      'remainingContext': remainingContext,
      'messages': messages.map((message) => message.toJson()).toList(),
    };
  }

  static TranscriptSnapshot fromJson(Map<String, dynamic> json) {
    if (json['version'] != schemaVersion) {
      throw const FormatException('bad_transcript_snapshot');
    }
    final rawMessages = json['messages'];
    if (rawMessages is! List) {
      throw const FormatException('bad_transcript_snapshot');
    }
    return TranscriptSnapshot(
      running: json['running'] == true,
      modelName: json['modelName'] as String?,
      contextWindow: (json['contextWindow'] as num?)?.toInt(),
      remainingContext: (json['remainingContext'] as num?)?.toInt(),
      messages: rawMessages
          .map(
            (message) =>
                TranscriptMessage.fromJson(message as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

class TranscriptMessage {
  const TranscriptMessage(
    this.role,
    this.text, {
    this.attachments = const [],
    this.activityId,
    this.activityKind,
    this.activityState,
    this.activityTool,
    this.activityDetail,
  });

  factory TranscriptMessage.user(
    String text, {
    List<RemoteAttachment> attachments = const [],
  }) => TranscriptMessage(MessageRole.user, text, attachments: attachments);
  factory TranscriptMessage.assistant(String text) =>
      TranscriptMessage(MessageRole.assistant, text);
  factory TranscriptMessage.system(String text) =>
      TranscriptMessage(MessageRole.system, text);
  factory TranscriptMessage.activity(
    String text, {
    required String id,
    required ActivityKind kind,
    required ActivityState state,
    String? tool,
    String? detail,
  }) => TranscriptMessage(
    MessageRole.activity,
    text,
    activityId: id,
    activityKind: kind,
    activityState: state,
    activityTool: tool,
    activityDetail: detail,
  );

  final MessageRole role;
  final String text;
  final List<RemoteAttachment> attachments;
  final String? activityId;
  final ActivityKind? activityKind;
  final ActivityState? activityState;
  final String? activityTool;
  final String? activityDetail;

  Map<String, dynamic> toJson() {
    return {
      'role': role.name,
      'text': text,
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map((attachment) => attachment.toJson())
            .toList(),
      if (activityId != null) 'activityId': activityId,
      if (activityKind != null) 'activityKind': activityKind!.name,
      if (activityState != null) 'activityState': activityState!.name,
      if (activityTool != null) 'activityTool': activityTool,
      if (activityDetail != null) 'activityDetail': activityDetail,
    };
  }

  static TranscriptMessage fromJson(Map<String, dynamic> json) {
    final role = switch (json['role']) {
      'user' => MessageRole.user,
      'assistant' => MessageRole.assistant,
      'system' => MessageRole.system,
      'activity' => MessageRole.activity,
      _ => throw const FormatException('bad_transcript_message'),
    };
    final text = json['text'];
    if (text is! String) throw const FormatException('bad_transcript_message');
    final rawAttachments = json['attachments'];
    final attachments = rawAttachments is List
        ? rawAttachments
              .map(
                (attachment) => RemoteAttachment.fromJson(
                  Map<String, dynamic>.from(attachment as Map),
                ),
              )
              .toList()
        : const <RemoteAttachment>[];
    if (role != MessageRole.activity) {
      return TranscriptMessage(role, text, attachments: attachments);
    }

    final id = json['activityId'];
    final kind = ActivityKind.values.where(
      (value) => value.name == json['activityKind'],
    );
    final state = ActivityState.values.where(
      (value) => value.name == json['activityState'],
    );
    if (id is! String || kind.isEmpty || state.isEmpty) {
      throw const FormatException('bad_transcript_message');
    }
    return TranscriptMessage.activity(
      text,
      id: id,
      kind: kind.first,
      state: state.first,
      tool: json['activityTool'] as String?,
      detail: json['activityDetail'] as String?,
    );
  }
}

enum MessageRole { user, assistant, system, activity }

enum ActivityKind { thinking, tool, summary }

enum ActivityState { running, done, error, stopped }
