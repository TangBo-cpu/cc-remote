import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'notification_service.dart';
import 'attachments.dart';
import 'workspace_drawer.dart';

void main() {
  runApp(const CcRemoteApp());
}

class CcRemoteApp extends StatelessWidget {
  const CcRemoteApp({
    super.key,
    this.enableCamera = true,
    this.demoMode = false,
    this.notificationService,
    this.notificationPreferenceStore,
  });

  final bool enableCamera;
  final bool demoMode;
  final BackgroundNotificationService? notificationService;
  final NotificationPreferenceStore? notificationPreferenceStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CC Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.light,
        ),
        textTheme: Typography.blackMountainView.apply(
          bodyColor: AppColors.ink,
          displayColor: AppColors.ink,
        ),
      ),
      home: DemoShell(
        enableCamera: enableCamera,
        demoMode: demoMode,
        notificationService: notificationService,
        notificationPreferenceStore: notificationPreferenceStore,
      ),
    );
  }
}

class DemoShell extends StatefulWidget {
  const DemoShell({
    super.key,
    required this.enableCamera,
    required this.demoMode,
    this.notificationService,
    this.notificationPreferenceStore,
  });

  final bool enableCamera;
  final bool demoMode;
  final BackgroundNotificationService? notificationService;
  final NotificationPreferenceStore? notificationPreferenceStore;

  @override
  State<DemoShell> createState() => _DemoShellState();
}

class _DemoShellState extends State<DemoShell> with WidgetsBindingObserver {
  static const networkTimeout = Duration(seconds: 12);
  static const interruptedRunMessage = '上次任务可能仍在电脑端运行，请重连确认';

  ShellRoute route = ShellRoute.boot;
  bool running = false;
  bool pairing = false;
  bool handlingQr = false;
  bool wsReady = false;
  bool remoteOffline = false;
  String? pausedQrRaw;
  String? pairError;
  String? modelName;
  int? contextWindow;
  int? remainingContext;
  String? activeProjectId;
  String? activeSessionId;
  int remoteTranscriptRevision = 0;
  bool allowBypassPermissions = false;
  bool notificationsEnabled = true;
  bool notificationsReady = false;
  bool currentRunFailed = false;
  bool uploadingAttachments = false;
  PermissionMode selectedPermissionMode = PermissionMode.manual;
  PermissionMode activePermissionMode = PermissionMode.manual;
  SavedSession? session;
  WebSocketChannel? ws;
  StreamSubscription<dynamic>? wsSubscription;
  final TokenStore tokenStore = TokenStore();
  final TranscriptStore transcriptStore = TranscriptStore();
  final http.Client httpClient = http.Client();
  final TextEditingController promptController = TextEditingController();
  final AttachmentPicker attachmentPicker = AttachmentPicker();
  final List<TranscriptMessage> messages = [];
  final List<AttachmentDraft> pendingAttachments = [];
  final List<String> commands = [];
  final List<RemoteProjectSummary> projects = [];
  final List<RemoteSessionSummary> remoteSessions = [];
  final List<RemotePermissionRequest> pendingPermissions = [];
  final Set<String> respondingPermissionIds = {};
  Future<void> lastTranscriptWrite = Future<void>.value();
  late final BackgroundNotificationService notificationService;
  late final NotificationPreferenceStore notificationPreferenceStore;
  late final BackgroundNotificationController notificationController;
  String? pendingNotificationSessionId;

  @override
  void initState() {
    super.initState();
    notificationService =
        widget.notificationService ?? LocalBackgroundNotificationService();
    notificationPreferenceStore =
        widget.notificationPreferenceStore ?? NotificationPreferenceStore();
    notificationController = BackgroundNotificationController(
      service: notificationService,
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(initializeNotifications());
    bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    closeWs();
    httpClient.close();
    promptController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    notificationController.lifecycleState = state;
    if (state != AppLifecycleState.resumed) return;
    unawaited(cancelNotifications());
    openPendingNotificationSession();
    unawaited(refreshConnection());
  }

  Future<void> initializeNotifications() async {
    final storedEnabled = await notificationPreferenceStore.load();
    notificationController.enabled = storedEnabled;
    if (widget.demoMode) {
      notificationsEnabled = storedEnabled;
      notificationsReady = true;
      return;
    }
    var enabled = storedEnabled;
    try {
      await notificationService.initialize(onTap: handleNotificationTap);
      if (enabled) enabled = await notificationService.requestPermission();
    } catch (_) {
      enabled = false;
    }
    notificationController.enabled = enabled;
    await notificationPreferenceStore.save(enabled);
    if (!mounted) return;
    setState(() {
      notificationsEnabled = enabled;
      notificationsReady = true;
    });
  }

  Future<void> cancelNotifications() async {
    if (widget.demoMode) return;
    try {
      await notificationService.cancelAll();
    } catch (_) {}
  }

  Future<bool> setNotificationsEnabled(bool enabled) async {
    var next = enabled;
    if (enabled && !widget.demoMode) {
      try {
        next = await notificationService.requestPermission();
      } catch (_) {
        next = false;
      }
    }
    notificationController.enabled = next;
    await notificationPreferenceStore.save(next);
    if (!next && !widget.demoMode) {
      try {
        await notificationService.cancelAll();
      } catch (_) {}
    }
    if (mounted) setState(() => notificationsEnabled = next);
    return next;
  }

  void handleNotificationTap(String? payload) {
    if (payload == null || !payload.startsWith('session:')) return;
    pendingNotificationSessionId = payload.substring('session:'.length);
    openPendingNotificationSession();
  }

  void openPendingNotificationSession() {
    final sessionId = pendingNotificationSessionId;
    if (sessionId == null || route != ShellRoute.chat || !wsReady || running) {
      return;
    }
    pendingNotificationSessionId = null;
    if (sessionId == activeSessionId) return;
    selectRemoteSession(sessionId);
  }

  void showBackgroundNotification({
    required String key,
    required String title,
    String? detail,
  }) {
    if (!notificationsReady) return;
    RemoteProjectSummary? project;
    for (final item in projects) {
      if (item.id == activeProjectId) project = item;
    }
    RemoteSessionSummary? remoteSession;
    for (final item in remoteSessions) {
      if (item.id == activeSessionId) remoteSession = item;
    }
    unawaited(
      notificationController
          .notify(
            AppNotification(
              key: key,
              title: title,
              body: notificationBody(
                projectName: project?.name ?? session?.workspaceName,
                sessionTitle: remoteSession?.title,
                detail: detail,
              ),
              sessionId: activeSessionId,
            ),
          )
          .catchError((_) {}),
    );
  }

  String? lastAssistantSnippet() {
    for (final message in messages.reversed) {
      if (message.role != MessageRole.assistant) continue;
      final text = message.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return null;
      return text.length <= 120 ? text : '${text.substring(0, 120)}…';
    }
    return null;
  }

  Future<void> queueTranscriptWrite(Future<void> Function() write) {
    final previous = lastTranscriptWrite;
    lastTranscriptWrite = () async {
      try {
        await previous;
      } catch (_) {}
      try {
        await write();
      } catch (_) {}
    }();
    return lastTranscriptWrite;
  }

  Future<void> persistTranscriptSnapshot() {
    final snapshot = TranscriptSnapshot(
      messages: messages
          .where((message) => message.role != MessageRole.activity)
          .toList(),
      running: running,
      modelName: modelName,
      contextWindow: contextWindow,
      remainingContext: remainingContext,
    );
    return queueTranscriptWrite(() => transcriptStore.save(snapshot));
  }

  void persistTranscriptSnapshotLater() {
    unawaited(persistTranscriptSnapshot());
  }

  Future<void> restoreTranscriptSnapshot() async {
    final snapshot = await transcriptStore.load();
    if (snapshot == null || !mounted) return;
    setState(() {
      messages
        ..clear()
        ..addAll(
          snapshot.messages.where(
            (message) => message.role != MessageRole.activity,
          ),
        );
      running = snapshot.running;
      modelName = snapshot.modelName;
      contextWindow = snapshot.contextWindow;
      remainingContext = snapshot.remainingContext;
      if (snapshot.running &&
          !messages.any((message) => message.text == interruptedRunMessage)) {
        messages.add(TranscriptMessage.system(interruptedRunMessage));
      }
    });
    await persistTranscriptSnapshot();
  }

  Future<void> clearTranscriptStore() {
    return queueTranscriptWrite(transcriptStore.clear);
  }

  void removeInterruptedRunNotice() {
    messages.removeWhere(
      (message) =>
          message.role == MessageRole.system &&
          message.text == interruptedRunMessage,
    );
  }

  Future<void> refreshConnection() async {
    final current = session;
    if (widget.demoMode || route != ShellRoute.chat || current == null) return;
    setState(() {
      wsReady = false;
      remoteOffline = false;
    });
    try {
      final status = await fetchStatus(current);
      if (!mounted || session != current) return;
      final restored = current.copyWith(
        deviceName: status.deviceName,
        workspaceDir: status.workspaceDir,
      );
      setState(() {
        session = restored;
        remoteOffline = false;
        running = status.running;
        if (status.hasSessionInfo) {
          modelName = status.modelName;
          contextWindow = status.contextWindow;
          remainingContext = status.remainingContext;
        }
        applyCatalog(status.catalog);
        if (!status.running) removeInterruptedRunNotice();
      });
      persistTranscriptSnapshotLater();
      connectWs(restored);
    } catch (err) {
      if (!mounted || session != current) return;
      closeWs();
      if (err is UnauthorizedSession) {
        await tokenStore.clear();
        await clearTranscriptStore();
        if (!mounted || session != current) return;
        setState(() {
          session = null;
          route = ShellRoute.pair;
          pairError = '无法恢复连接，请重新扫码';
          remoteOffline = false;
          running = false;
          messages.clear();
        });
        return;
      }
      setState(() {
        remoteOffline = true;
        running = false;
      });
      persistTranscriptSnapshotLater();
    }
  }

  Future<void> bootstrap() async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (widget.demoMode) {
      if (mounted && route == ShellRoute.boot) {
        setState(() => route = ShellRoute.pair);
      }
      return;
    }

    final saved = await tokenStore.load();
    if (!mounted) return;
    if (saved == null) {
      await clearTranscriptStore();
      if (!mounted) return;
      setState(() => route = ShellRoute.pair);
      return;
    }

    await restoreTranscriptSnapshot();
    if (!mounted) return;

    try {
      final status = await fetchStatus(saved);
      if (!mounted) return;
      final restored = saved.copyWith(
        deviceName: status.deviceName,
        workspaceDir: status.workspaceDir,
      );
      setState(() {
        session = restored;
        route = ShellRoute.chat;
        remoteOffline = false;
        running = status.running;
        if (status.hasSessionInfo) {
          modelName = status.modelName;
          contextWindow = status.contextWindow;
          remainingContext = status.remainingContext;
        }
        applyCatalog(status.catalog);
        if (!status.running) removeInterruptedRunNotice();
      });
      persistTranscriptSnapshotLater();
      connectWs(restored);
    } catch (err) {
      if (!mounted) return;
      if (err is UnauthorizedSession) {
        await tokenStore.clear();
        await clearTranscriptStore();
        if (!mounted) return;
        setState(() {
          pairError = '无法恢复连接，请重新扫码';
          route = ShellRoute.pair;
          running = false;
          messages.clear();
        });
        return;
      }
      setState(() {
        session = saved;
        route = ShellRoute.chat;
        wsReady = false;
        remoteOffline = true;
        running = false;
      });
      persistTranscriptSnapshotLater();
    }
  }

  Future<void> connectDemoDevice() async {
    await clearTranscriptStore();
    if (!mounted) return;
    setState(() {
      session = SavedSession(
        origin: Uri.parse('https://tbhaoshuai.ccwu.cc'),
        token: 'demo',
        deviceName: 'Jayson PC',
        workspaceDir: 'cc-remote',
      );
      route = ShellRoute.chat;
      running = false;
      wsReady = true;
      remoteOffline = false;
      modelName = 'claude-opus-4-8';
      contextWindow = 200000;
      remainingContext = 174919;
      messages.clear();
      commands
        ..clear()
        ..addAll(['caveman:caveman-help', 'frontend-design', 'review']);
    });
  }

  void closeWs() {
    final subscription = wsSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    wsSubscription = null;
    ws?.sink.close();
    ws = null;
    wsReady = false;
  }

  void connectWs(SavedSession saved) {
    if (widget.demoMode) {
      setState(() => wsReady = true);
      return;
    }

    closeWs();
    setState(() => wsReady = false);

    try {
      final channel = WebSocketChannel.connect(wsUri(saved.origin));
      ws = channel;
      wsSubscription = channel.stream.listen(
        handleWsMessage,
        onError: (Object err) => handleWsClosed('连接错误：$err'),
        onDone: () => handleWsClosed('连接已断开'),
      );
      channel.sink.add(jsonEncode({'type': 'auth', 'token': saved.token}));
    } catch (err) {
      handleWsClosed('连接失败：$err');
    }
  }

  Uri wsUri(Uri origin) {
    final scheme = origin.scheme == 'https' ? 'wss' : 'ws';
    return Uri.parse('$scheme://${origin.authority}/ws');
  }

  void handleWsMessage(dynamic data) {
    final decoded = jsonDecode(data.toString());
    if (decoded is! Map<String, dynamic>) return;

    if (decoded['authenticated'] == false) {
      unawaited(recoverUnauthorizedSession());
      return;
    }

    final messageSessionId = decoded['sessionId'];
    if (messageSessionId is String &&
        activeSessionId != null &&
        messageSessionId != activeSessionId) {
      return;
    }

    switch (decoded['type']) {
      case 'catalog':
        final catalog = RemoteProjectCatalog.tryParse(decoded);
        if (catalog == null) return;
        setState(() {
          final changedSession =
              activeSessionId != null &&
              activeSessionId != catalog.activeSessionId;
          activeProjectId = catalog.activeProjectId;
          activeSessionId = catalog.activeSessionId;
          if (changedSession) {
            uploadingAttachments = false;
            pendingAttachments.clear();
            remoteTranscriptRevision = 0;
            messages.clear();
            pendingPermissions.clear();
            respondingPermissionIds.clear();
            modelName = null;
            contextWindow = null;
            remainingContext = null;
          }
          projects
            ..clear()
            ..addAll(catalog.projects);
          remoteSessions
            ..clear()
            ..addAll(catalog.sessions);
          final project = catalog.activeProject;
          if (project != null && session != null) {
            session = session!.copyWith(workspaceDir: project.path);
          }
        });
        if (session != null) unawaited(tokenStore.save(session!));
        openPendingNotificationSession();
      case 'status':
        setState(() {
          wsReady = decoded['authenticated'] == true;
          remoteOffline = false;
          running = decoded['running'] == true;
          if (running) currentRunFailed = false;
          if (!running) removeInterruptedRunNotice();
        });
        openPendingNotificationSession();
        persistTranscriptSnapshotLater();
      case 'transcript_snapshot':
        final snapshot = RemoteTranscriptSnapshot.tryParse(decoded);
        if (snapshot == null ||
            !shouldApplyRemoteTranscriptSnapshot(
              snapshot: snapshot,
              currentRevision: remoteTranscriptRevision,
              hasLocalMessages: messages.isNotEmpty,
            )) {
          return;
        }
        setState(() {
          remoteTranscriptRevision = snapshot.revision;
          running = snapshot.running;
          messages
            ..clear()
            ..addAll(snapshot.messages);
          modelName = snapshot.modelName;
          contextWindow = snapshot.contextWindow;
          remainingContext = snapshot.remainingContext;
          activePermissionMode = snapshot.permissionMode;
          pendingPermissions
            ..clear()
            ..addAll(snapshot.pendingPermissions);
          respondingPermissionIds.removeWhere(
            (requestId) => !pendingPermissions.any(
              (request) => request.requestId == requestId,
            ),
          );
        });
        persistTranscriptSnapshotLater();
      case 'permission_capabilities':
        setState(() {
          allowBypassPermissions = decoded['allowBypassPermissions'] == true;
          if (!allowBypassPermissions &&
              selectedPermissionMode == PermissionMode.bypassPermissions) {
            selectedPermissionMode = PermissionMode.manual;
          }
        });
      case 'permission_request':
        final request = RemotePermissionRequest.tryParse(decoded);
        if (request == null) return;
        setState(() {
          final index = pendingPermissions.indexWhere(
            (item) => item.requestId == request.requestId,
          );
          if (index >= 0) {
            pendingPermissions[index] = request;
          } else {
            pendingPermissions.add(request);
          }
        });
        showBackgroundNotification(
          key: 'permission-${request.requestId}',
          title: '需要权限确认',
          detail:
              request.description ??
              request.detail ??
              request.displayName ??
              request.toolName,
        );
      case 'permission_resolved':
        final requestId = decoded['requestId'];
        if (requestId is! String) return;
        setState(() {
          pendingPermissions.removeWhere(
            (request) => request.requestId == requestId,
          );
          respondingPermissionIds.remove(requestId);
        });
      case 'permission_expired':
        final requestId = decoded['requestId'];
        if (requestId is! String) return;
        setState(() {
          pendingPermissions.removeWhere(
            (request) => request.requestId == requestId,
          );
          respondingPermissionIds.remove(requestId);
          messages.add(TranscriptMessage.system('这个审批请求已失效'));
        });
        persistTranscriptSnapshotLater();
      case 'text':
        appendAssistantText(decoded['text'] as String? ?? '');
      case 'commands':
        final items = decoded['commands'];
        if (items is! List) return;
        setState(() {
          commands
            ..clear()
            ..addAll(items.whereType<String>());
        });
      case 'session_info':
        setState(() {
          modelName = decoded['model'] as String?;
          contextWindow = (decoded['contextWindow'] as num?)?.toInt();
          remainingContext = (decoded['remainingTokens'] as num?)?.toInt();
        });
        persistTranscriptSnapshotLater();
      case 'activity':
        final activity = RemoteActivity.tryParse(decoded);
        if (activity == null) return;
        setState(() => mergeRemoteActivity(messages, activity));
        persistTranscriptSnapshotLater();
      case 'done':
        final failed = currentRunFailed;
        setState(() {
          running = false;
          currentRunFailed = false;
          activePermissionMode = PermissionMode.manual;
          pendingPermissions.clear();
          respondingPermissionIds.clear();
          removeCurrentTurnActivities(messages);
          if (!hasAssistantReplyAfterLastUser(messages)) {
            messages.add(TranscriptMessage.system('本轮没有返回文本，请重试'));
          }
        });
        if (!failed) {
          showBackgroundNotification(
            key: 'done-${activeSessionId ?? 'current'}',
            title: '任务已完成',
            detail: lastAssistantSnippet(),
          );
        }
        persistTranscriptSnapshotLater();
      case 'stopped':
        setState(() {
          running = false;
          currentRunFailed = false;
          activePermissionMode = PermissionMode.manual;
          pendingPermissions.clear();
          respondingPermissionIds.clear();
          finishRunningActivities(messages, ActivityState.stopped);
          messages.add(TranscriptMessage.system('已停止'));
        });
        showBackgroundNotification(
          key: 'stopped-${activeSessionId ?? 'current'}',
          title: '任务已停止',
        );
        persistTranscriptSnapshotLater();
      case 'error':
        final errorMessage = decoded['message']?.toString() ?? '未知错误';
        setState(() {
          running = false;
          currentRunFailed = true;
          activePermissionMode = PermissionMode.manual;
          pendingPermissions.clear();
          respondingPermissionIds.clear();
          finishRunningActivities(messages, ActivityState.error);
          messages.add(TranscriptMessage.system('错误：$errorMessage'));
        });
        showBackgroundNotification(
          key: 'error-${activeSessionId ?? 'current'}',
          title: '任务执行失败',
          detail: errorMessage,
        );
        persistTranscriptSnapshotLater();
    }
  }

  Future<void> recoverUnauthorizedSession() async {
    closeWs();
    await tokenStore.clear();
    await clearTranscriptStore();
    if (!mounted) return;
    setState(() {
      session = null;
      route = ShellRoute.pair;
      pairError = '无法恢复连接，请重新扫码';
      remoteOffline = false;
      running = false;
      messages.clear();
      commands.clear();
      projects.clear();
      remoteSessions.clear();
      activeProjectId = null;
      activeSessionId = null;
      remoteTranscriptRevision = 0;
      allowBypassPermissions = false;
      selectedPermissionMode = PermissionMode.manual;
      activePermissionMode = PermissionMode.manual;
      pendingPermissions.clear();
      respondingPermissionIds.clear();
    });
  }

  void handleWsClosed(String message) {
    if (!mounted || route != ShellRoute.chat) return;
    setState(() {
      wsReady = false;
      remoteOffline = true;
      if (running) {
        running = false;
        finishRunningActivities(messages, ActivityState.stopped);
        messages.add(TranscriptMessage.system(message));
      }
    });
    persistTranscriptSnapshotLater();
  }

  void appendAssistantText(String text) {
    if (text.isEmpty) return;
    setState(() {
      final start =
          messages.lastIndexWhere(
            (message) => message.role == MessageRole.user,
          ) +
          1;
      finishRunningActivities(
        messages,
        ActivityState.done,
        start: start,
        kind: ActivityKind.thinking,
      );
      if (messages.isNotEmpty && messages.last.role == MessageRole.assistant) {
        final last = messages.removeLast();
        messages.add(TranscriptMessage.assistant(last.text + text));
      } else {
        messages.add(TranscriptMessage.assistant(text));
      }
    });
    persistTranscriptSnapshotLater();
  }

  Future<void> sendPrompt() async {
    final text = promptController.text.trim();
    if ((text.isEmpty && pendingAttachments.isEmpty) ||
        running ||
        uploadingAttachments) {
      return;
    }

    if (widget.demoMode) {
      setState(() {
        promptController.clear();
        pendingAttachments.clear();
        running = false;
        messages
          ..add(TranscriptMessage.user(text))
          ..add(TranscriptMessage.assistant('演示模式：真实对话需要连接 daemon WebSocket。'));
      });
      persistTranscriptSnapshotLater();
      return;
    }

    final channel = ws;
    final current = session;
    final currentSessionId = activeSessionId;
    if (!wsReady ||
        channel == null ||
        current == null ||
        currentSessionId == null) {
      if (current != null) refreshConnection();
      setState(() {
        running = false;
        messages.add(
          TranscriptMessage.system(
            remoteOffline ? '电脑端离线，请先重连' : '正在连接电脑端，请稍后再试',
          ),
        );
      });
      persistTranscriptSnapshotLater();
      return;
    }

    final drafts = List<AttachmentDraft>.from(pendingAttachments);
    var uploaded = const <RemoteAttachment>[];
    if (drafts.isNotEmpty) {
      setState(() => uploadingAttachments = true);
      try {
        uploaded = await AttachmentUploader(client: httpClient).upload(
          origin: current.origin,
          token: current.token,
          sessionId: currentSessionId,
          files: drafts,
        );
      } catch (error) {
        if (!mounted || activeSessionId != currentSessionId) {
          return;
        }
        setState(() => uploadingAttachments = false);
        if (error is AttachmentException && error.code == 'unauthorized') {
          await recoverUnauthorizedSession();
          return;
        }
        showAttachmentError(error);
        return;
      }
      if (!mounted || activeSessionId != currentSessionId) {
        return;
      }
    }
    if (!wsReady || ws != channel) {
      setState(() => uploadingAttachments = false);
      showAttachmentError(const AttachmentException('upload_aborted'));
      return;
    }

    setState(() {
      promptController.clear();
      pendingAttachments.clear();
      uploadingAttachments = false;
      running = true;
      currentRunFailed = false;
      activePermissionMode = selectedPermissionMode;
      beginPrompt(messages, text, attachments: uploaded);
      if (selectedPermissionMode == PermissionMode.bypassPermissions) {
        selectedPermissionMode = PermissionMode.manual;
      }
    });
    persistTranscriptSnapshotLater();
    channel.sink.add(
      jsonEncode({
        'type': 'prompt',
        'text': text,
        if (uploaded.isNotEmpty)
          'attachmentIds': uploaded.map((attachment) => attachment.id).toList(),
        'permissionMode': activePermissionMode.wireName,
        'sessionId': currentSessionId,
      }),
    );
  }

  Future<void> chooseAttachments() async {
    if (running || uploadingAttachments) return;
    if (pendingAttachments.length >= maxAttachmentsPerPrompt) {
      showAttachmentError(const AttachmentException('too_many_attachments'));
      return;
    }
    FocusScope.of(context).unfocus();
    final source = await showAttachmentSourceSheet(context);
    if (source == null || !mounted) return;
    try {
      final picked = switch (source) {
        AttachmentSource.camera => await attachmentPicker.takePhoto(),
        AttachmentSource.photos => await attachmentPicker.pickPhotos(),
        AttachmentSource.files => await attachmentPicker.pickFiles(),
      };
      if (!mounted || picked.isEmpty) return;
      final oversized = picked.where(
        (attachment) => attachment.size > maxAttachmentBytes,
      );
      if (oversized.isNotEmpty) {
        throw const AttachmentException('attachment_too_large');
      }
      final next = <AttachmentDraft>[...pendingAttachments];
      var wasTruncated = false;
      for (final attachment in picked) {
        if (next.any((existing) => existing.path == attachment.path)) continue;
        if (next.length >= maxAttachmentsPerPrompt) {
          wasTruncated = true;
          break;
        }
        next.add(attachment);
      }
      setState(() {
        pendingAttachments
          ..clear()
          ..addAll(next);
      });
      if (wasTruncated) {
        showAttachmentError(const AttachmentException('too_many_attachments'));
      }
    } catch (error) {
      if (mounted) showAttachmentError(error);
    }
  }

  void removePendingAttachment(AttachmentDraft attachment) {
    if (uploadingAttachments) return;
    setState(() => pendingAttachments.remove(attachment));
  }

  void showAttachmentError(Object error) {
    final code = error is AttachmentException ? error.code : error.toString();
    final message = switch (code) {
      'too_many_attachments' => '一次最多发送 5 个附件',
      'attachment_too_large' => '单个附件不能超过 25MB',
      'attachment_empty' => '不能发送空文件',
      'upload_aborted' => '上传已中断，请重试',
      _ => '附件上传失败，请重试',
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void selectPermissionMode(PermissionMode mode) {
    if (running ||
        (mode == PermissionMode.bypassPermissions && !allowBypassPermissions)) {
      return;
    }
    setState(() => selectedPermissionMode = mode);
  }

  void respondToPermission(RemotePermissionRequest request, String decision) {
    final channel = ws;
    if (channel == null ||
        !wsReady ||
        respondingPermissionIds.contains(request.requestId)) {
      return;
    }
    setState(() => respondingPermissionIds.add(request.requestId));
    channel.sink.add(
      jsonEncode({
        'type': 'permission_response',
        'requestId': request.requestId,
        'decision': decision,
        if (activeSessionId != null) 'sessionId': activeSessionId,
      }),
    );
  }

  void stopRun() {
    if (!running) return;

    if (widget.demoMode) {
      setState(() {
        running = false;
        messages.add(TranscriptMessage.system('已停止'));
      });
      persistTranscriptSnapshotLater();
      return;
    }

    final channel = ws;
    if (channel == null || !wsReady) {
      setState(() {
        running = false;
        messages.add(TranscriptMessage.system('未连接，无法发送停止指令'));
      });
      persistTranscriptSnapshotLater();
      return;
    }

    channel.sink.add(jsonEncode({'type': 'stop'}));
    setState(() => messages.add(TranscriptMessage.system('正在停止')));
    persistTranscriptSnapshotLater();
  }

  Future<void> beginNewConversation() async {
    if (running) return;

    if (widget.demoMode) {
      setState(() {
        modelName = null;
        contextWindow = null;
        remainingContext = null;
        messages
          ..clear()
          ..add(TranscriptMessage.system('已开启新对话'));
        pendingAttachments.clear();
        uploadingAttachments = false;
      });
      persistTranscriptSnapshotLater();
      return;
    }

    final current = session;
    if (current == null) return;

    try {
      final res = await httpClient
          .post(
            current.origin.resolve('/api/new-conversation'),
            headers: {'Authorization': 'Bearer ${current.token}'},
          )
          .timeout(networkTimeout);
      if (res.statusCode == 401) {
        if (!mounted || session != current) return;
        await tokenStore.clear();
        await clearTranscriptStore();
        await logoutDemoDevice();
        if (mounted) setState(() => pairError = '无法恢复连接，请重新扫码');
        return;
      }
      if (res.statusCode != 200) throw StateError('new_conversation_failed');
      if (!mounted || session != current) return;
      final body = jsonDecode(res.body);
      setState(() {
        if (body is Map<String, dynamic> && body['sessionId'] is String) {
          activeSessionId = body['sessionId'] as String;
        }
        remoteTranscriptRevision = 0;
        modelName = null;
        contextWindow = null;
        remainingContext = null;
        messages.clear();
        pendingAttachments.clear();
        uploadingAttachments = false;
        pendingPermissions.clear();
        respondingPermissionIds.clear();
      });
      persistTranscriptSnapshotLater();
    } catch (_) {
      if (!mounted || session != current) return;
      setState(() {
        messages.add(TranscriptMessage.system('开启新对话失败，请重试'));
      });
      persistTranscriptSnapshotLater();
    }
  }

  void fillPrompt(String text) {
    promptController.text = text;
    promptController.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<void> logoutDemoDevice() async {
    closeWs();
    await clearTranscriptStore();
    if (!mounted) return;
    setState(() {
      session = null;
      route = ShellRoute.pair;
      running = false;
      wsReady = false;
      remoteOffline = false;
      pausedQrRaw = null;
      modelName = null;
      contextWindow = null;
      remainingContext = null;
      messages.clear();
      commands.clear();
      projects.clear();
      remoteSessions.clear();
      activeProjectId = null;
      activeSessionId = null;
      remoteTranscriptRevision = 0;
      allowBypassPermissions = false;
      selectedPermissionMode = PermissionMode.manual;
      activePermissionMode = PermissionMode.manual;
      pendingPermissions.clear();
      respondingPermissionIds.clear();
      promptController.clear();
      pendingAttachments.clear();
      uploadingAttachments = false;
    });
  }

  void resetScanner() {
    setState(() {
      pausedQrRaw = null;
      pairError = null;
    });
  }

  Future<void> logoutPairedDevice() async {
    final current = session;
    if (current != null && !widget.demoMode) {
      try {
        await httpClient
            .post(
              current.origin.resolve('/api/logout'),
              headers: {'Authorization': 'Bearer ${current.token}'},
            )
            .timeout(networkTimeout);
      } catch (_) {
        // Local token is still cleared below.
      }
      await tokenStore.clear();
    }
    await logoutDemoDevice();
  }

  Future<RemoteStatus> fetchStatus(SavedSession saved) async {
    final res = await httpClient
        .get(
          saved.origin.resolve('/api/status'),
          headers: {'Authorization': 'Bearer ${saved.token}'},
        )
        .timeout(networkTimeout);
    if (res.statusCode == 401) throw const UnauthorizedSession();
    if (res.statusCode != 200) throw StateError('status_failed');
    return RemoteStatus.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  void openWorkspace() {
    final current = session;
    if (current == null) return;
    showWorkspaceDrawer(
      context,
      origin: current.origin,
      token: current.token,
      workspaceName: current.workspaceName,
      demoMode: widget.demoMode,
    );
  }

  void applyCatalog(RemoteProjectCatalog? catalog) {
    if (catalog == null) return;
    activeProjectId = catalog.activeProjectId;
    activeSessionId = catalog.activeSessionId;
    projects
      ..clear()
      ..addAll(catalog.projects);
    remoteSessions
      ..clear()
      ..addAll(catalog.sessions);
  }

  void openSessions() {
    if (projects.isEmpty) return;
    showSessionNavigator(
      context,
      projects: projects,
      sessions: remoteSessions,
      activeProjectId: activeProjectId,
      activeSessionId: activeSessionId,
      running: running,
      onSelect: selectRemoteSession,
      onCreate: createRemoteSession,
    );
  }

  void selectRemoteSession(String sessionId) {
    if (running || sessionId == activeSessionId) return;
    ws?.sink.add(
      jsonEncode({'type': 'select_session', 'sessionId': sessionId}),
    );
  }

  Future<void> createRemoteSession(String projectId) async {
    if (running) return;
    final current = session;
    if (current == null) return;
    try {
      final res = await httpClient
          .post(
            current.origin.resolve('/api/projects/$projectId/sessions'),
            headers: {'Authorization': 'Bearer ${current.token}'},
          )
          .timeout(networkTimeout);
      if (res.statusCode == 401) throw const UnauthorizedSession();
      if (res.statusCode != 201) throw StateError('create_session_failed');
    } on UnauthorizedSession {
      await recoverUnauthorizedSession();
    } catch (_) {
      if (!mounted) return;
      setState(() => messages.add(TranscriptMessage.system('新建会话失败，请重试')));
    }
  }

  Future<void> handleQr(String raw) async {
    if (handlingQr || pairing || raw == pausedQrRaw) return;
    setState(() {
      handlingQr = true;
      pausedQrRaw = raw;
      pairError = null;
    });

    try {
      final payload = PairingPayload.parse(raw);
      final confirmed = await showPairReviewSheet(context, payload);
      if (confirmed == true && mounted) await pairWithPayload(payload);
    } catch (err) {
      if (mounted) setState(() => pairError = errorText(err));
    } finally {
      if (mounted) setState(() => handlingQr = false);
    }
  }

  Future<void> pairWithPayload(PairingPayload payload) async {
    setState(() => pairing = true);
    try {
      final res = await httpClient
          .post(
            payload.origin.resolve('/api/pair'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'nonce': payload.nonce}),
          )
          .timeout(networkTimeout);
      if (res.statusCode != 200) throw StateError('pair_failed');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final token = body['token'];
      if (token is! String || token.isEmpty) {
        throw StateError('bad_pair_response');
      }
      final saved = SavedSession(
        origin: payload.origin,
        token: token,
        deviceName: body['deviceName'] as String? ?? payload.deviceName,
      );
      await tokenStore.save(saved);
      await clearTranscriptStore();
      if (!mounted) return;
      setState(() {
        session = saved;
        route = ShellRoute.chat;
        running = false;
        remoteOffline = false;
        pausedQrRaw = null;
        pairError = null;
        modelName = null;
        contextWindow = null;
        remainingContext = null;
        messages.clear();
        commands.clear();
        remoteTranscriptRevision = 0;
        allowBypassPermissions = false;
        selectedPermissionMode = PermissionMode.manual;
        activePermissionMode = PermissionMode.manual;
        pendingPermissions.clear();
        respondingPermissionIds.clear();
      });
      connectWs(saved);
    } catch (err) {
      if (mounted) setState(() => pairError = errorText(err));
    } finally {
      if (mounted) setState(() => pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: switch (route) {
          ShellRoute.boot => const BootstrapScreen(),
          ShellRoute.pair => PairScreen(
            enableCamera: widget.enableCamera,
            pairing: pairing,
            canResetScan: pausedQrRaw != null,
            error: pairError,
            onQr: handleQr,
            onClearError: resetScanner,
            onDemoConnect: widget.demoMode ? connectDemoDevice : null,
          ),
          ShellRoute.chat => ChatScreen(
            session: session,
            activeSessionId: activeSessionId,
            running: running,
            uploadingAttachments: uploadingAttachments,
            connected: wsReady,
            offline: remoteOffline,
            modelName: modelName,
            contextWindow: contextWindow,
            remainingContext: remainingContext,
            messages: messages,
            commands: commands,
            permissionMode: running
                ? activePermissionMode
                : selectedPermissionMode,
            allowBypassPermissions: allowBypassPermissions,
            notificationsEnabled: notificationsEnabled,
            pendingPermissions: pendingPermissions,
            respondingPermissionIds: respondingPermissionIds,
            promptController: promptController,
            pendingAttachments: pendingAttachments,
            onFillPrompt: fillPrompt,
            onReconnect: refreshConnection,
            onNotificationsChanged: setNotificationsEnabled,
            onNewConversation: beginNewConversation,
            onOpenSessions: openSessions,
            onOpenWorkspace: openWorkspace,
            onPermissionModeSelected: selectPermissionMode,
            onPermissionAllow: (request) =>
                respondToPermission(request, 'allow'),
            onPermissionDeny: (request) => respondToPermission(request, 'deny'),
            onAddAttachment: chooseAttachments,
            onRemoveAttachment: removePendingAttachment,
            onSend: sendPrompt,
            onStop: stopRun,
            onLogout: logoutPairedDevice,
          ),
        },
      ),
    );
  }
}

enum ShellRoute { boot, pair, chat }

class BootstrapScreen extends StatelessWidget {
  const BootstrapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('boot'),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.92),
                    Colors.white.withValues(alpha: 0.55),
                  ],
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.86)),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.shadow.withValues(alpha: 0.10),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Text(
                'CC',
                style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'CC Remote',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '正在检查本机连接',
              style: TextStyle(color: AppColors.muted, fontSize: 15),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 148,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.pill),
                child: const LinearProgressIndicator(
                  minHeight: 3,
                  color: AppColors.accent,
                  backgroundColor: Color(0xFFE8F0F3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PairScreen extends StatelessWidget {
  const PairScreen({
    super.key,
    required this.enableCamera,
    required this.pairing,
    required this.canResetScan,
    required this.onQr,
    required this.onClearError,
    this.error,
    this.onDemoConnect,
  });

  final bool enableCamera;
  final bool pairing;
  final bool canResetScan;
  final String? error;
  final ValueChanged<String> onQr;
  final VoidCallback onClearError;
  final VoidCallback? onDemoConnect;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      key: const ValueKey('pair'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                  child: const Icon(
                    Icons.qr_code_scanner_rounded,
                    size: 18,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '扫描电脑二维码',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '扫描电脑终端里的二维码',
                        style: TextStyle(color: AppColors.muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 0.86,
                  child: ScanFrame(
                    child: enableCamera
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: MobileScanner(
                              onDetect: (capture) {
                                for (final barcode in capture.barcodes) {
                                  final value = barcode.rawValue;
                                  if (value != null && value.isNotEmpty) {
                                    onQr(value);
                                    break;
                                  }
                                }
                              },
                            ),
                          )
                        : const ScanPlaceholder(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            GlassPanel(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.desktop_windows_rounded,
                          size: 19,
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              pairing ? '正在连接电脑' : '等待配对二维码',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              error ??
                                  (canResetScan
                                      ? '已暂停扫描，点重新扫描可继续'
                                      : '扫到后会确认设备信息再连接'),
                              style: TextStyle(
                                color: error == null
                                    ? AppColors.muted
                                    : AppColors.stop,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  StatusPill(
                    label: pairing
                        ? '配对中'
                        : error == null
                        ? canResetScan
                              ? '等待确认'
                              : '相机已就绪'
                        : '需要重试',
                    color: error == null ? AppColors.accent : AppColors.stop,
                  ),
                  if (pairing) ...[
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      child: const LinearProgressIndicator(
                        minHeight: 3,
                        color: AppColors.accent,
                        backgroundColor: Color(0xFFE8F3F6),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ActionButton(
                      label: onDemoConnect == null ? '扫描中' : '连接这台电脑',
                      icon: onDemoConnect == null
                          ? Icons.qr_code_scanner_rounded
                          : Icons.link_rounded,
                      onPressed: onDemoConnect,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: canResetScan || error != null
                          ? onClearError
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accent,
                        minimumSize: const Size.fromHeight(46),
                        side: BorderSide(
                          color: AppColors.accent.withValues(alpha: 0.22),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                        ),
                      ),
                      child: const Text('重新扫描'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScanPlaceholder extends StatelessWidget {
  const ScanPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Icon(Icons.qr_code_scanner_rounded, size: 54, color: AppColors.accent),
        SizedBox(height: 14),
        Text('等待二维码', style: TextStyle(color: AppColors.muted)),
      ],
    );
  }
}

Future<bool?> showPairReviewSheet(
  BuildContext context,
  PairingPayload payload,
) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => PairReviewSheet(payload: payload),
  );
}

class PairReviewSheet extends StatelessWidget {
  const PairReviewSheet({super.key, required this.payload});

  final PairingPayload payload;

  @override
  Widget build(BuildContext context) {
    final expired = payload.expiresAt.isBefore(DateTime.now());
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: GlassPanel(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.desktop_windows_rounded,
                      size: 19,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          payload.deviceName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          payload.origin.toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              StatusPill(
                label: expired ? '二维码已过期' : '二维码有效',
                color: expired ? AppColors.stop : AppColors.accent,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: expired
                      ? null
                      : () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                    ),
                  ),
                  child: const Text('连接这台电脑'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    minimumSize: const Size.fromHeight(46),
                    side: BorderSide(
                      color: AppColors.accent.withValues(alpha: 0.22),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                    ),
                  ),
                  child: const Text('重新扫描'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({
    super.key,
    required this.session,
    this.activeSessionId,
    required this.running,
    this.uploadingAttachments = false,
    required this.connected,
    required this.offline,
    required this.modelName,
    required this.contextWindow,
    required this.remainingContext,
    required this.messages,
    required this.commands,
    required this.permissionMode,
    required this.allowBypassPermissions,
    required this.notificationsEnabled,
    required this.pendingPermissions,
    required this.respondingPermissionIds,
    required this.promptController,
    this.pendingAttachments = const [],
    required this.onFillPrompt,
    required this.onReconnect,
    required this.onNotificationsChanged,
    required this.onNewConversation,
    required this.onOpenSessions,
    required this.onOpenWorkspace,
    required this.onPermissionModeSelected,
    required this.onPermissionAllow,
    required this.onPermissionDeny,
    this.onAddAttachment,
    this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
    required this.onLogout,
  });

  final SavedSession? session;
  final String? activeSessionId;
  final bool running;
  final bool uploadingAttachments;
  final bool connected;
  final bool offline;
  final String? modelName;
  final int? contextWindow;
  final int? remainingContext;
  final List<TranscriptMessage> messages;
  final List<String> commands;
  final PermissionMode permissionMode;
  final bool allowBypassPermissions;
  final bool notificationsEnabled;
  final List<RemotePermissionRequest> pendingPermissions;
  final Set<String> respondingPermissionIds;
  final TextEditingController promptController;
  final List<AttachmentDraft> pendingAttachments;
  final ValueChanged<String> onFillPrompt;
  final VoidCallback onReconnect;
  final Future<bool> Function(bool) onNotificationsChanged;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenSessions;
  final VoidCallback onOpenWorkspace;
  final ValueChanged<PermissionMode> onPermissionModeSelected;
  final ValueChanged<RemotePermissionRequest> onPermissionAllow;
  final ValueChanged<RemotePermissionRequest> onPermissionDeny;
  final VoidCallback? onAddAttachment;
  final ValueChanged<AttachmentDraft>? onRemoveAttachment;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final header = RepaintBoundary(
      child: ConnectionHeader(
        session: session,
        running: running,
        connected: connected,
        offline: offline,
        modelName: modelName,
        contextWindow: contextWindow,
        remainingContext: remainingContext,
        notificationsEnabled: notificationsEnabled,
        onReconnect: onReconnect,
        onNotificationsChanged: onNotificationsChanged,
        onNewConversation: onNewConversation,
        onOpenSessions: onOpenSessions,
        onOpenWorkspace: onOpenWorkspace,
        onLogout: onLogout,
      ),
    );
    final transcript = RepaintBoundary(
      child: TranscriptView(
        messages: messages,
        session: session,
        activeSessionId: activeSessionId,
        pendingPermissions: pendingPermissions,
        respondingPermissionIds: respondingPermissionIds,
        connected: connected,
        onFillPrompt: onFillPrompt,
        onPermissionAllow: onPermissionAllow,
        onPermissionDeny: onPermissionDeny,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final reservedHeight = modelName != null || remainingContext != null
            ? 312.0
            : 277.0;
        final suggestionMaxHeight = (constraints.maxHeight - reservedHeight)
            .clamp(48.0, 292.0);
        return SafeArea(
          key: const ValueKey('chat'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              children: [
                header,
                const SizedBox(height: 10),
                Expanded(child: transcript),
                const SizedBox(height: 10),
                PromptBar(
                  controller: promptController,
                  attachments: pendingAttachments,
                  commands: commands,
                  running: running,
                  uploading: uploadingAttachments,
                  connected: connected,
                  offline: offline,
                  permissionMode: permissionMode,
                  allowBypassPermissions: allowBypassPermissions,
                  suggestionMaxHeight: suggestionMaxHeight,
                  onPermissionModeSelected: onPermissionModeSelected,
                  onCommandSelected: (command) => onFillPrompt('/$command '),
                  onAddAttachment: onAddAttachment,
                  onRemoveAttachment: onRemoveAttachment,
                  onSend: onSend,
                  onStop: onStop,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class ConnectionHeader extends StatelessWidget {
  const ConnectionHeader({
    super.key,
    required this.session,
    required this.running,
    required this.connected,
    required this.offline,
    required this.modelName,
    required this.contextWindow,
    required this.remainingContext,
    required this.notificationsEnabled,
    required this.onReconnect,
    required this.onNotificationsChanged,
    required this.onNewConversation,
    required this.onOpenSessions,
    required this.onOpenWorkspace,
    required this.onLogout,
  });

  final SavedSession? session;
  final bool running;
  final bool connected;
  final bool offline;
  final String? modelName;
  final int? contextWindow;
  final int? remainingContext;
  final bool notificationsEnabled;
  final VoidCallback onReconnect;
  final Future<bool> Function(bool) onNotificationsChanged;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenSessions;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final statusLabel = running
        ? '运行中'
        : connected
        ? '已连接'
        : offline
        ? '电脑端离线'
        : '正在连接';
    final statusColor = running || connected
        ? AppColors.accent
        : offline
        ? AppColors.stop
        : AppColors.muted;
    final workspace = session?.workspaceName ?? 'cc-remote';
    final device = session?.deviceName ?? 'Jayson PC';

    return GlassPanel(
      radius: AppRadii.panel,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 96,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: onOpenSessions,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.forum_outlined, size: 21),
                      tooltip: '项目与会话',
                    ),
                    IconButton(
                      onPressed: onOpenWorkspace,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.folder_open_rounded, size: 21),
                      tooltip: '工作区',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      workspace,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            '$device · $statusLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 96,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: connected && !running
                          ? onNewConversation
                          : null,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.add_comment_rounded, size: 20),
                      tooltip: '新对话',
                    ),
                    IconButton(
                      onPressed: () => showSettingsSheet(
                        context,
                        session,
                        notificationsEnabled,
                        onReconnect,
                        onNotificationsChanged,
                        onLogout,
                      ),
                      icon: const Icon(Icons.more_horiz_rounded, size: 23),
                      tooltip: '设置',
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (modelName != null || remainingContext != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 44, 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 7,
                runSpacing: 5,
                children: [
                  if (modelName != null)
                    SessionMetric(
                      key: const ValueKey('model-metric'),
                      icon: Icons.smart_toy_outlined,
                      label: formatModelName(modelName!),
                    ),
                  if (remainingContext != null)
                    SessionMetric(
                      key: const ValueKey('context-metric'),
                      icon: Icons.donut_large_rounded,
                      label: contextWindow == null
                          ? '剩余 ${formatTokens(remainingContext!)}'
                          : '剩余 ${formatTokens(remainingContext!)} / ${formatTokens(contextWindow!)}',
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class SessionMetric extends StatelessWidget {
  const SessionMetric({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.075),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.accent),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

String formatModelName(String model) {
  final match = RegExp(r'^claude-([a-z]+)-(\d+)-(\d+)$').firstMatch(model);
  if (match == null) return model;
  final family = match.group(1)!;
  return '${family[0].toUpperCase()}${family.substring(1)} ${match.group(2)}.${match.group(3)}';
}

String formatTokens(int tokens) {
  if (tokens >= 1000000) {
    final value = tokens / 1000000;
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)}M';
  }
  if (tokens >= 1000) return '${(tokens / 1000).round()}K';
  return '$tokens';
}

Future<void> showSettingsSheet(
  BuildContext context,
  SavedSession? session,
  bool notificationsEnabled,
  VoidCallback onReconnect,
  Future<bool> Function(bool) onNotificationsChanged,
  VoidCallback onLogout,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => SettingsSheet(
      session: session,
      notificationsEnabled: notificationsEnabled,
      onReconnect: onReconnect,
      onNotificationsChanged: onNotificationsChanged,
      onLogout: onLogout,
    ),
  );
}

Future<void> showSessionNavigator(
  BuildContext context, {
  required List<RemoteProjectSummary> projects,
  required List<RemoteSessionSummary> sessions,
  required String? activeProjectId,
  required String? activeSessionId,
  required bool running,
  required ValueChanged<String> onSelect,
  required ValueChanged<String> onCreate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SessionNavigatorSheet(
      projects: projects,
      sessions: sessions,
      activeProjectId: activeProjectId,
      activeSessionId: activeSessionId,
      running: running,
      onSelect: (sessionId) {
        Navigator.pop(sheetContext);
        onSelect(sessionId);
      },
      onCreate: (projectId) {
        Navigator.pop(sheetContext);
        onCreate(projectId);
      },
    ),
  );
}

class SessionNavigatorSheet extends StatefulWidget {
  const SessionNavigatorSheet({
    super.key,
    required this.projects,
    required this.sessions,
    required this.activeProjectId,
    required this.activeSessionId,
    required this.running,
    required this.onSelect,
    required this.onCreate,
  });

  final List<RemoteProjectSummary> projects;
  final List<RemoteSessionSummary> sessions;
  final String? activeProjectId;
  final String? activeSessionId;
  final bool running;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onCreate;

  @override
  State<SessionNavigatorSheet> createState() => _SessionNavigatorSheetState();
}

class _SessionNavigatorSheetState extends State<SessionNavigatorSheet> {
  late String selectedProjectId =
      widget.activeProjectId ?? widget.projects.first.id;

  @override
  Widget build(BuildContext context) {
    final projectSessions = widget.sessions
        .where((session) => session.projectId == selectedProjectId)
        .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '项目与会话',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('create-session'),
                    onPressed: widget.running
                        ? null
                        : () => widget.onCreate(selectedProjectId),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('新会话'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final project in widget.projects) ...[
                      ChoiceChip(
                        key: ValueKey('project-${project.id}'),
                        selected: project.id == selectedProjectId,
                        label: Text(project.name),
                        avatar: project.running
                            ? const SizedBox.square(
                                dimension: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                ),
                              )
                            : null,
                        onSelected: (_) =>
                            setState(() => selectedProjectId = project.id),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: projectSessions.isEmpty
                    ? const Center(child: Text('这个项目还没有会话'))
                    : ListView.separated(
                        itemCount: projectSessions.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = projectSessions[index];
                          final active = item.id == widget.activeSessionId;
                          return ListTile(
                            key: ValueKey('session-${item.id}'),
                            enabled: !widget.running || active,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: Icon(
                              item.running
                                  ? Icons.pending_outlined
                                  : Icons.chat_bubble_outline_rounded,
                              color: item.running
                                  ? AppColors.accent
                                  : AppColors.muted,
                            ),
                            title: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              item.summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: active
                                ? const Icon(
                                    Icons.check_circle_rounded,
                                    color: AppColors.accent,
                                  )
                                : const Icon(Icons.chevron_right_rounded),
                            onTap: active || widget.running
                                ? null
                                : () => widget.onSelect(item.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.session,
    required this.notificationsEnabled,
    required this.onReconnect,
    required this.onNotificationsChanged,
    required this.onLogout,
  });

  final SavedSession? session;
  final bool notificationsEnabled;
  final VoidCallback onReconnect;
  final Future<bool> Function(bool) onNotificationsChanged;
  final VoidCallback onLogout;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late bool notificationsEnabled = widget.notificationsEnabled;
  bool changingNotifications = false;

  Future<void> changeNotifications(bool value) async {
    if (changingNotifications) return;
    setState(() {
      changingNotifications = true;
      notificationsEnabled = value;
    });
    final accepted = await widget.onNotificationsChanged(value);
    if (!mounted) return;
    setState(() {
      changingNotifications = false;
      notificationsEnabled = accepted;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: GlassPanel(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '设置',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              InfoRow(
                label: '电脑',
                value: widget.session?.deviceName ?? 'Jayson PC',
              ),
              InfoRow(
                label: '服务',
                value:
                    widget.session?.origin.toString() ??
                    'https://tbhaoshuai.ccwu.cc',
              ),
              InfoRow(
                label: '目录',
                value: widget.session?.workspaceName ?? 'cc-remote',
              ),
              SwitchListTile(
                key: const ValueKey('background-notifications-toggle'),
                contentPadding: EdgeInsets.zero,
                value: notificationsEnabled,
                onChanged: changingNotifications ? null : changeNotifications,
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('后台通知'),
                subtitle: const Text('任务完成、失败或等待权限时提醒'),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onReconnect();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新连接'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    minimumSize: const Size.fromHeight(46),
                    side: BorderSide(
                      color: AppColors.accent.withValues(alpha: 0.22),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => confirmLogout(context, widget.onLogout),
                  icon: const Icon(Icons.link_off_rounded),
                  label: const Text('退出配对'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.stop,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(label, style: const TextStyle(color: AppColors.muted)),
          ),
          Expanded(child: MonoText(value)),
        ],
      ),
    );
  }
}

Future<AttachmentSource?> showAttachmentSourceSheet(BuildContext context) {
  return showModalBottomSheet<AttachmentSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              subtitle: const Text('拍一张照片发送给 Claude Code'),
              onTap: () => Navigator.pop(context, AttachmentSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('选择图片'),
              subtitle: const Text('从相册选择一张或多张图片'),
              onTap: () => Navigator.pop(context, AttachmentSource.photos),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('选择文件'),
              subtitle: const Text('发送代码、日志、文档或压缩包'),
              onTap: () => Navigator.pop(context, AttachmentSource.files),
            ),
          ],
        ),
      ),
    ),
  );
}

String formatAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

Future<void> confirmLogout(BuildContext context, VoidCallback onLogout) async {
  final shouldLogout = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('退出配对'),
      content: const Text('退出后这台手机需要重新扫码。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.stop,
            foregroundColor: Colors.white,
          ),
          child: const Text('退出'),
        ),
      ],
    ),
  );
  if (shouldLogout != true || !context.mounted) return;
  Navigator.pop(context);
  onLogout();
}

class TranscriptView extends StatelessWidget {
  const TranscriptView({
    super.key,
    required this.messages,
    this.session,
    this.activeSessionId,
    required this.pendingPermissions,
    required this.respondingPermissionIds,
    required this.connected,
    required this.onFillPrompt,
    required this.onPermissionAllow,
    required this.onPermissionDeny,
  });

  final List<TranscriptMessage> messages;
  final SavedSession? session;
  final String? activeSessionId;
  final List<RemotePermissionRequest> pendingPermissions;
  final Set<String> respondingPermissionIds;
  final bool connected;
  final ValueChanged<String> onFillPrompt;
  final ValueChanged<RemotePermissionRequest> onPermissionAllow;
  final ValueChanged<RemotePermissionRequest> onPermissionDeny;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && pendingPermissions.isEmpty) {
      final title = connected ? '本机已连接，可以发送任务给 Claude Code' : '等待电脑端连接';
      final subtitle = connected ? '从下方输入，或先点一个快捷任务' : '恢复连接后即可发送任务';
      return LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withValues(alpha: 0.62),
                              Colors.white.withValues(alpha: 0.28),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.58),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.shadow.withValues(alpha: 0.04),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Icon(
                          connected
                              ? Icons.terminal_rounded
                              : Icons.cloud_off_rounded,
                          size: 30,
                          color: connected ? AppColors.accent : AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 13,
                        ),
                      ),
                      if (connected) ...[
                        const SizedBox(height: 20),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Column(
                            children: [
                              PromptChip(
                                icon: Icons.search_rounded,
                                label: '检查这个项目',
                                onTap: () => onFillPrompt('检查这个项目'),
                              ),
                              const SizedBox(height: 8),
                              PromptChip(
                                icon: Icons.play_arrow_rounded,
                                label: '运行测试',
                                onTap: () => onFillPrompt('运行测试并总结结果'),
                              ),
                              const SizedBox(height: 8),
                              PromptChip(
                                icon: Icons.folder_outlined,
                                label: '总结当前目录',
                                onTap: () => onFillPrompt('总结当前目录结构'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    final items = <Object>[...messages, ...pendingPermissions];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 16),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        final item = items[index];
        if (item is TranscriptMessage) {
          return MessageBlock(
            message: item,
            session: session,
            activeSessionId: activeSessionId,
          );
        }
        final request = item as RemotePermissionRequest;
        return PermissionRequestCard(
          request: request,
          responding: respondingPermissionIds.contains(request.requestId),
          connected: connected,
          onAllow: () => onPermissionAllow(request),
          onDeny: () => onPermissionDeny(request),
        );
      },
    );
  }
}

class PermissionRequestCard extends StatelessWidget {
  const PermissionRequestCard({
    super.key,
    required this.request,
    required this.responding,
    required this.connected,
    required this.onAllow,
    required this.onDeny,
  });

  final RemotePermissionRequest request;
  final bool responding;
  final bool connected;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final enabled = connected && !responding;
    return GlassPanel(
      key: ValueKey('permission-request-${request.requestId}'),
      radius: AppRadii.control,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.stop.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.shield_outlined,
                  size: 19,
                  color: AppColors.stop,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '等待权限确认',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      request.displayName ?? request.toolName,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (responding)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (request.description != null) ...[
            const SizedBox(height: 10),
            Text(request.description!),
          ],
          if (request.detail != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.58),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.shadow.withValues(alpha: 0.12),
                ),
              ),
              child: SelectableText(
                request.detail!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: enabled ? onDeny : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.stop,
                  ),
                  child: const Text('拒绝'),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: FilledButton(
                  onPressed: enabled ? onAllow : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                  ),
                  child: const Text('允许一次'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class MessageBlock extends StatelessWidget {
  const MessageBlock({
    super.key,
    required this.message,
    this.session,
    this.activeSessionId,
  });

  final TranscriptMessage message;
  final SavedSession? session;
  final String? activeSessionId;

  @override
  Widget build(BuildContext context) {
    if (message.role == MessageRole.system) {
      return Center(
        child: Text(
          message.text,
          style: const TextStyle(fontSize: 12, color: AppColors.muted),
        ),
      );
    }

    if (message.role == MessageRole.activity) {
      return ActivityBlock(message: message);
    }

    final isUser = message.role == MessageRole.user;
    if (!isUser) {
      return AssistantBubbleFrame(
        bubbleKey: const ValueKey('assistant-message'),
        child: MarkdownBody(
          data: message.text,
          selectable: true,
          softLineBreak: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: const TextStyle(
              height: 1.55,
              fontSize: 15,
              color: AppColors.ink,
            ),
            a: const TextStyle(color: AppColors.accent),
            code: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: AppColors.ink,
            ),
            h1: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.ink,
            ),
            h2: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.ink,
            ),
            h3: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.ink,
            ),
            blockSpacing: 10,
            listIndent: 22,
            codeblockPadding: const EdgeInsets.all(12),
            codeblockDecoration: BoxDecoration(
              color: const Color(0xFFEEF3F6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.shadow.withValues(alpha: 0.12),
              ),
            ),
            blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
            blockquoteDecoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.accent, width: 2),
              ),
            ),
          ),
        ),
      );
    }

    final maxWidth = MediaQuery.sizeOf(context).width * 0.76;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          key: const ValueKey('user-message'),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.10),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppRadii.bubble),
              topRight: Radius.circular(AppRadii.bubble),
              bottomLeft: Radius.circular(AppRadii.bubble),
              bottomRight: Radius.circular(6),
            ),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.10)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.attachments.isNotEmpty)
                AttachmentMessageGrid(
                  attachments: message.attachments,
                  session: session,
                  activeSessionId: activeSessionId,
                ),
              if (message.attachments.isNotEmpty && message.text.isNotEmpty)
                const SizedBox(height: 9),
              if (message.text.isNotEmpty)
                Text(
                  message.text,
                  style: const TextStyle(
                    height: 1.45,
                    color: AppColors.ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AttachmentMessageGrid extends StatelessWidget {
  const AttachmentMessageGrid({
    super.key,
    required this.attachments,
    required this.session,
    required this.activeSessionId,
  });

  final List<RemoteAttachment> attachments;
  final SavedSession? session;
  final String? activeSessionId;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < attachments.length; index++) ...[
          RemoteAttachmentTile(
            attachment: attachments[index],
            session: session,
            activeSessionId: activeSessionId,
          ),
          if (index != attachments.length - 1) const SizedBox(height: 7),
        ],
      ],
    );
  }
}

class RemoteAttachmentTile extends StatelessWidget {
  const RemoteAttachmentTile({
    super.key,
    required this.attachment,
    required this.session,
    required this.activeSessionId,
  });

  final RemoteAttachment attachment;
  final SavedSession? session;
  final String? activeSessionId;

  @override
  Widget build(BuildContext context) {
    final saved = session;
    final sessionId = activeSessionId;
    if (attachment.isImage && saved != null && sessionId != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: Image.network(
            attachment.contentUri(saved.origin, sessionId).toString(),
            headers: {'Authorization': 'Bearer ${saved.token}'},
            fit: BoxFit.cover,
            cacheWidth: 720,
            semanticLabel: attachment.name,
            errorBuilder: (_, _, _) => AttachmentFileTile(
              name: attachment.name,
              size: attachment.size,
              mimeType: attachment.mimeType,
            ),
          ),
        ),
      );
    }
    return AttachmentFileTile(
      name: attachment.name,
      size: attachment.size,
      mimeType: attachment.mimeType,
    );
  }
}

class AttachmentFileTile extends StatelessWidget {
  const AttachmentFileTile({
    super.key,
    required this.name,
    required this.size,
    required this.mimeType,
  });

  final String name;
  final int size;
  final String mimeType;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.shadow.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Icon(
            mimeType == 'application/pdf'
                ? Icons.picture_as_pdf_outlined
                : Icons.insert_drive_file_outlined,
            size: 22,
            color: AppColors.accent,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatAttachmentSize(size),
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AssistantBubbleFrame extends StatelessWidget {
  const AssistantBubbleFrame({
    super.key,
    required this.child,
    this.bubbleKey,
    this.compact = false,
  });

  final Widget child;
  final Key? bubbleKey;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.82;
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const AssistantAvatar(),
          const SizedBox(width: 9),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Container(
                key: bubbleKey,
                padding: compact
                    ? const EdgeInsets.fromLTRB(13, 10, 14, 10)
                    : const EdgeInsets.fromLTRB(15, 13, 15, 13),
                decoration: BoxDecoration(
                  color: const Color(0xE6F7FAFC),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(7),
                    topRight: Radius.circular(AppRadii.bubble),
                    bottomLeft: Radius.circular(AppRadii.bubble),
                    bottomRight: Radius.circular(AppRadii.bubble),
                  ),
                  border: Border.all(color: const Color(0x66FFFFFF)),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.shadow.withValues(alpha: 0.03),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AssistantAvatar extends StatelessWidget {
  const AssistantAvatar({super.key});

  static const assetPath = 'assets/assistant_avatar.jpg';

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('assistant-avatar'),
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.white.withValues(alpha: 0.92)),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadow.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset(
          assetPath,
          fit: BoxFit.cover,
          // Face sits lower in this portrait; bias crop toward it.
          alignment: const Alignment(0, 0.35),
          errorBuilder: (context, error, stackTrace) {
            return Container(
              color: Colors.white.withValues(alpha: 0.72),
              alignment: Alignment.center,
              child: const Icon(
                Icons.terminal_rounded,
                size: 16,
                color: AppColors.accent,
              ),
            );
          },
        ),
      ),
    );
  }
}

class ActivityBlock extends StatelessWidget {
  const ActivityBlock({super.key, required this.message});

  final TranscriptMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.activityKind == ActivityKind.thinking) {
      if (message.activityState == ActivityState.running) {
        return const AssistantBubbleFrame(
          bubbleKey: ValueKey('thinking-bubble'),
          compact: true,
          child: ThinkingIndicator(),
        );
      }
      return AssistantBubbleFrame(
        bubbleKey: const ValueKey('thinking-complete'),
        compact: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              message.activityState == ActivityState.error
                  ? Icons.error_outline_rounded
                  : Icons.check_rounded,
              size: 17,
              color: message.activityState == ActivityState.error
                  ? AppColors.stop
                  : AppColors.accent,
            ),
            const SizedBox(width: 8),
            Text(
              message.text,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    final detail = message.activityDetail;
    final title = Text(
      message.text,
      style: TextStyle(
        color: message.activityState == ActivityState.error
            ? AppColors.stop
            : AppColors.muted,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
    final icon = switch (message.activityState) {
      ActivityState.running => const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: AppColors.accent,
        ),
      ),
      ActivityState.done => const Icon(
        Icons.check_rounded,
        size: 17,
        color: AppColors.muted,
      ),
      ActivityState.error => const Icon(
        Icons.error_outline_rounded,
        size: 17,
        color: AppColors.stop,
      ),
      ActivityState.stopped => const Icon(
        Icons.stop_rounded,
        size: 17,
        color: AppColors.muted,
      ),
      null => const SizedBox.square(dimension: 16),
    };

    if (message.activityKind == ActivityKind.summary) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 13, 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.54),
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: AppColors.shadow.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  if (detail != null && detail.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (detail == null || detail.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 5, 5, 5),
        child: Row(
          children: [
            SizedBox(width: 22, child: Center(child: icon)),
            const SizedBox(width: 6),
            Expanded(child: title),
          ],
        ),
      );
    }

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: AppColors.shadow.withValues(alpha: 0.07)),
        ),
        child: ExpansionTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          leading: SizedBox(width: 20, child: Center(child: icon)),
          title: title,
          subtitle: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          shape: const Border(),
          collapsedShape: const Border(),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                detail,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({super.key});

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation;
  Timer? timer;
  var elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    )..repeat(reverse: true);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => elapsedSeconds += 1);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '正在思考，已用 $elapsedSeconds 秒',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              final value = animation.value;
              return Opacity(
                opacity: 0.52 + value * 0.48,
                child: Transform.rotate(
                  angle: (value - 0.5) * 0.18,
                  child: Transform.scale(
                    scale: 0.88 + value * 0.12,
                    child: child,
                  ),
                ),
              );
            },
            child: const Icon(
              Icons.auto_awesome_rounded,
              key: ValueKey('thinking-icon'),
              size: 18,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 9),
          const Text(
            '正在思考',
            style: TextStyle(
              color: AppColors.ink,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 9),
          Text(
            '$elapsedSeconds 秒',
            key: const ValueKey('thinking-elapsed'),
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class PromptBar extends StatelessWidget {
  const PromptBar({
    super.key,
    required this.controller,
    this.attachments = const [],
    required this.commands,
    required this.running,
    this.uploading = false,
    required this.connected,
    required this.offline,
    required this.permissionMode,
    required this.allowBypassPermissions,
    this.suggestionMaxHeight = 292,
    required this.onPermissionModeSelected,
    required this.onCommandSelected,
    this.onAddAttachment,
    this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final List<AttachmentDraft> attachments;
  final List<String> commands;
  final bool running;
  final bool uploading;
  final bool connected;
  final bool offline;
  final PermissionMode permissionMode;
  final bool allowBypassPermissions;
  final double suggestionMaxHeight;
  final ValueChanged<PermissionMode> onPermissionModeSelected;
  final ValueChanged<String> onCommandSelected;
  final VoidCallback? onAddAttachment;
  final ValueChanged<AttachmentDraft>? onRemoveAttachment;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final canSend =
            (value.text.trim().isNotEmpty || attachments.isNotEmpty) &&
            !running &&
            !uploading &&
            connected;
        final query = commandQuery(value.text);
        final matchingCommands = query == null
            ? const <String>[]
            : filterCommands(commands, query);
        final showSuggestions =
            query != null && !running && !uploading && connected;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSuggestions) ...[
              CommandSuggestions(
                commands: matchingCommands,
                loading: commands.isEmpty,
                maxHeight: suggestionMaxHeight,
                onSelected: onCommandSelected,
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: PermissionModeChip(
                mode: permissionMode,
                enabled: !running && !uploading,
                onPressed: () => showPermissionModePicker(
                  context,
                  selected: permissionMode,
                  allowBypassPermissions: allowBypassPermissions,
                  onSelected: onPermissionModeSelected,
                ),
              ),
            ),
            const SizedBox(height: 7),
            if (attachments.isNotEmpty) ...[
              PendingAttachmentStrip(
                attachments: attachments,
                uploading: uploading,
                onRemove: (attachment) => onRemoveAttachment?.call(attachment),
              ),
              const SizedBox(height: 7),
            ],
            GlassPanel(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              radius: AppRadii.input,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      onPressed: running || uploading || !connected
                          ? null
                          : onAddAttachment,
                      icon: const Icon(Icons.attach_file_rounded, size: 21),
                      tooltip: '添加附件',
                      color: AppColors.accent,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: !running && !uploading,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: uploading
                            ? '正在上传附件…'
                            : running
                            ? 'Claude 正在输出…'
                            : connected
                            ? '输入要发给 Claude Code 的内容'
                            : offline
                            ? '电脑端离线，请先重连'
                            : '正在连接电脑端',
                        hintStyle: TextStyle(
                          color: AppColors.muted.withValues(alpha: 0.9),
                          fontSize: 14,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (running)
                    SizedBox(
                      height: 40,
                      child: FilledButton.icon(
                        onPressed: onStop,
                        icon: const Icon(Icons.stop_rounded, size: 18),
                        label: const Text('停止'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.stop,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                          ),
                        ),
                      ),
                    )
                  else if (uploading)
                    const SizedBox(
                      width: 40,
                      height: 40,
                      child: Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      ),
                    )
                  else
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: IconButton.filled(
                        onPressed: canSend ? onSend : null,
                        icon: const Icon(Icons.send_rounded, size: 18),
                        tooltip: '发送',
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          disabledBackgroundColor: const Color(0xFFDCE6EA),
                          foregroundColor: Colors.white,
                          fixedSize: const Size.square(40),
                          shape: const CircleBorder(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class PendingAttachmentStrip extends StatelessWidget {
  const PendingAttachmentStrip({
    super.key,
    required this.attachments,
    required this.uploading,
    required this.onRemove,
  });

  final List<AttachmentDraft> attachments;
  final bool uploading;
  final ValueChanged<AttachmentDraft> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 68,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          return Container(
            key: ValueKey('pending-attachment-${attachment.path}'),
            width: 174,
            padding: const EdgeInsets.fromLTRB(7, 7, 2, 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: AppColors.shadow.withValues(alpha: 0.10),
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox.square(
                    dimension: 48,
                    child:
                        attachment.isImage && attachmentFileExists(attachment)
                        ? Image.file(
                            File(attachment.path),
                            fit: BoxFit.cover,
                            cacheWidth: 160,
                            semanticLabel: attachment.name,
                          )
                        : ColoredBox(
                            color: AppColors.accent.withValues(alpha: 0.08),
                            child: const Icon(
                              Icons.insert_drive_file_outlined,
                              color: AppColors.accent,
                              size: 22,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attachment.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        uploading
                            ? '上传中'
                            : formatAttachmentSize(attachment.size),
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    onPressed: uploading ? null : () => onRemove(attachment),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '移除 ${attachment.name}',
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

enum PermissionMode {
  manual,
  acceptEdits,
  auto,
  dontAsk,
  plan,
  bypassPermissions;

  String get wireName => name;

  String get label => switch (this) {
    PermissionMode.manual => '询问权限',
    PermissionMode.acceptEdits => '自动编辑',
    PermissionMode.auto => '自动判断',
    PermissionMode.dontAsk => '不询问',
    PermissionMode.plan => '规划模式',
    PermissionMode.bypassPermissions => '跳过权限',
  };

  String get description => switch (this) {
    PermissionMode.manual => '需要授权时在手机上确认',
    PermissionMode.acceptEdits => '自动允许文件编辑，其他操作仍询问',
    PermissionMode.auto => '交给 Claude Code 判断权限',
    PermissionMode.dontAsk => '未预先允许的操作直接拒绝',
    PermissionMode.plan => '只分析和规划，不执行修改',
    PermissionMode.bypassPermissions => '本次任务跳过全部权限检查',
  };

  IconData get icon => switch (this) {
    PermissionMode.manual => Icons.shield_outlined,
    PermissionMode.acceptEdits => Icons.edit_note_rounded,
    PermissionMode.auto => Icons.auto_mode_rounded,
    PermissionMode.dontAsk => Icons.do_not_disturb_alt_rounded,
    PermissionMode.plan => Icons.route_outlined,
    PermissionMode.bypassPermissions => Icons.warning_amber_rounded,
  };

  static PermissionMode fromWire(Object? value) {
    return PermissionMode.values.firstWhere(
      (mode) => mode.wireName == value,
      orElse: () => PermissionMode.manual,
    );
  }
}

class PermissionModeChip extends StatelessWidget {
  const PermissionModeChip({
    super.key,
    required this.mode,
    required this.enabled,
    required this.onPressed,
  });

  final PermissionMode mode;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final danger = mode == PermissionMode.bypassPermissions;
    final tone = danger ? AppColors.stop : AppColors.accent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('permission-mode-chip'),
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: enabled ? 0.62 : 0.40),
            borderRadius: BorderRadius.circular(AppRadii.pill),
            border: Border.all(color: tone.withValues(alpha: 0.16)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(mode.icon, size: 15, color: tone),
              const SizedBox(width: 6),
              Text(
                mode.label,
                style: TextStyle(
                  color: danger ? AppColors.stop : AppColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: AppColors.muted.withValues(alpha: 0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showPermissionModePicker(
  BuildContext context, {
  required PermissionMode selected,
  required bool allowBypassPermissions,
  required ValueChanged<PermissionMode> onSelected,
}) async {
  final mode = await showModalBottomSheet<PermissionMode>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Claude Code 权限模式',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            for (final item in PermissionMode.values)
              ListTile(
                key: ValueKey('permission-mode-${item.wireName}'),
                enabled:
                    item != PermissionMode.bypassPermissions ||
                    allowBypassPermissions,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  item.icon,
                  color: item == PermissionMode.bypassPermissions
                      ? AppColors.stop
                      : AppColors.accent,
                ),
                title: Text(item.label),
                subtitle: Text(
                  item == PermissionMode.bypassPermissions &&
                          !allowBypassPermissions
                      ? '电脑端未开启 ALLOW_BYPASS_PERMISSIONS'
                      : item.description,
                ),
                trailing: item == selected
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap:
                    item == PermissionMode.bypassPermissions &&
                        !allowBypassPermissions
                    ? null
                    : () => Navigator.pop(sheetContext, item),
              ),
          ],
        ),
      ),
    ),
  );
  if (mode == null || !context.mounted) return;
  if (mode == PermissionMode.bypassPermissions) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('本次任务跳过权限检查'),
        content: const Text('Claude Code 将能直接修改文件和执行命令。任务结束后会自动恢复询问权限。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.stop),
            child: const Text('仅本次开启'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  onSelected(mode);
}

String? commandQuery(String text) {
  if (!text.startsWith('/')) return null;
  final query = text.substring(1);
  if (query.contains(RegExp(r'\s'))) return null;
  return query.toLowerCase();
}

List<String> filterCommands(List<String> commands, String query) {
  final prefixMatches = commands
      .where((command) => command.toLowerCase().startsWith(query))
      .toList();
  final containsMatches = commands.where((command) {
    final normalized = command.toLowerCase();
    return !normalized.startsWith(query) && normalized.contains(query);
  });
  return [...prefixMatches, ...containsMatches];
}

class CommandSuggestions extends StatelessWidget {
  const CommandSuggestions({
    super.key,
    required this.commands,
    required this.loading,
    this.maxHeight = 292,
    required this.onSelected,
  });

  final List<String> commands;
  final bool loading;
  final double maxHeight;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      key: const ValueKey('command-suggestions'),
      radius: AppRadii.control,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: loading
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: AppColors.accent,
                      ),
                    ),
                    SizedBox(width: 10),
                    Text(
                      '正在获取 Claude Code 指令',
                      style: TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
              )
            : commands.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(
                  '没有匹配的指令',
                  style: TextStyle(color: AppColors.muted),
                ),
              )
            : ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: commands.length,
                itemBuilder: (context, index) {
                  final command = commands[index];
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: const Text(
                      '/',
                      style: TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    title: Text(command),
                    onTap: () => onSelected(command),
                  );
                },
              ),
      ),
    );
  }
}

class ScanFrame extends StatelessWidget {
  const ScanFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.74)),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadow.withValues(alpha: 0.14),
            blurRadius: 34,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Stack(
        children: [
          Center(child: child),
          const Positioned(top: 18, left: 18, child: ScanCorner()),
          const Positioned(
            top: 18,
            right: 18,
            child: RotatedBox(quarterTurns: 1, child: ScanCorner()),
          ),
          const Positioned(
            bottom: 18,
            right: 18,
            child: RotatedBox(quarterTurns: 2, child: ScanCorner()),
          ),
          const Positioned(
            bottom: 18,
            left: 18,
            child: RotatedBox(quarterTurns: 3, child: ScanCorner()),
          ),
        ],
      ),
    );
  }
}

class ScanCorner extends StatelessWidget {
  const ScanCorner({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: AppColors.accent, width: 3),
            left: BorderSide(color: AppColors.accent, width: 3),
          ),
        ),
      ),
    );
  }
}

class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      // Flat cool fog — no vertical hue split, no competing blobs.
      backgroundColor: AppColors.bgMid,
      body: ColoredBox(color: AppColors.bgMid, child: child),
    );
  }
}

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = AppRadii.panel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadow.withValues(alpha: 0.045),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.62)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.52),
                Colors.white.withValues(alpha: 0.34),
              ],
            ),
          ),
          child: Stack(
            children: [
              Padding(
                padding: padding,
                child: SizedBox(width: double.infinity, child: child),
              ),
              Positioned(
                left: 12,
                right: 12,
                top: 0,
                height: 1,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(1),
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.0),
                          Colors.white.withValues(alpha: 0.55),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ScreenTitle extends StatelessWidget {
  const ScreenTitle({super.key, required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 15, color: AppColors.muted),
        ),
      ],
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class ActionButton extends StatelessWidget {
  const ActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
      ),
    );
  }
}

class PromptChip extends StatelessWidget {
  const PromptChip({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: Colors.white.withValues(alpha: 0.78)),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadow.withValues(alpha: 0.05),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: AppColors.accent),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.muted.withValues(alpha: 0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: AppColors.muted,
        fontFamily: 'monospace',
        fontSize: 13,
      ),
    );
  }
}

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
  });

  final String id;
  final String projectId;
  final String title;
  final int updatedAt;
  final bool running;
  final int messageCount;
  final String? model;

  String get summary {
    final parts = <String>[];
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
    );
  }
}

class RemoteStatus {
  const RemoteStatus({
    required this.deviceName,
    required this.workspaceDir,
    required this.running,
    required this.hasSessionInfo,
    this.catalog,
    this.modelName,
    this.contextWindow,
    this.remainingContext,
  });

  final String? deviceName;
  final String? workspaceDir;
  final bool running;
  final bool hasSessionInfo;
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

class UnauthorizedSession implements Exception {
  const UnauthorizedSession();
}

class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_session';
  final FlutterSecureStorage storage;

  Future<SavedSession?> load() async {
    final raw = await storage.read(key: key);
    if (raw == null) return null;
    try {
      return SavedSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<void> save(SavedSession session) {
    return storage.write(key: key, value: jsonEncode(session.toJson()));
  }

  Future<void> clear() {
    return storage.delete(key: key);
  }
}

class TranscriptStore {
  TranscriptStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_transcript';
  final FlutterSecureStorage storage;

  Future<TranscriptSnapshot?> load() async {
    final raw = await storage.read(key: key);
    if (raw == null) return null;
    try {
      return TranscriptSnapshot.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<void> save(TranscriptSnapshot snapshot) {
    return storage.write(key: key, value: jsonEncode(snapshot.toJson()));
  }

  Future<void> clear() {
    return storage.delete(key: key);
  }
}

String errorText(Object err) {
  if (err is FormatException) return '这不是 CC Remote 配对二维码';
  if (err is TimeoutException) return '连接超时，请检查电脑端和隧道';
  return '配对失败，请重新生成二维码';
}

bool hasAssistantReplyAfterLastUser(List<TranscriptMessage> messages) {
  final lastUser = messages.lastIndexWhere(
    (message) => message.role == MessageRole.user,
  );
  if (lastUser < 0) return true;
  return messages
      .skip(lastUser + 1)
      .any((message) => message.role == MessageRole.assistant);
}

void beginPrompt(
  List<TranscriptMessage> messages,
  String text, {
  List<RemoteAttachment> attachments = const [],
}) {
  messages.add(TranscriptMessage.user(text, attachments: attachments));
  mergeRemoteActivity(
    messages,
    const RemoteActivity(
      id: 'thinking',
      kind: ActivityKind.thinking,
      state: ActivityState.running,
    ),
  );
}

void mergeRemoteActivity(
  List<TranscriptMessage> messages,
  RemoteActivity activity,
) {
  if (activity.kind == ActivityKind.summary) return;

  final start =
      messages.lastIndexWhere((message) => message.role == MessageRole.user) +
      1;

  if (activity.kind == ActivityKind.tool &&
      activity.state == ActivityState.running) {
    finishRunningActivities(
      messages,
      ActivityState.done,
      start: start,
      kind: ActivityKind.thinking,
    );
  }
  var existingIndex = -1;
  for (var index = messages.length - 1; index >= start; index--) {
    if (messages[index].activityId == activity.id) {
      existingIndex = index;
      break;
    }
  }

  final existing = existingIndex >= 0 ? messages[existingIndex] : null;
  final toolName = activity.toolName ?? existing?.activityTool;
  final detail = activity.detail ?? existing?.activityDetail;

  final next = TranscriptMessage.activity(
    activityLabel(activity.kind, toolName, activity.state),
    id: activity.id,
    kind: activity.kind,
    state: activity.state,
    tool: toolName,
    detail: detail,
  );
  if (existingIndex >= 0) {
    messages[existingIndex] = next;
  } else {
    messages.add(next);
  }
}

void removeCurrentTurnActivities(List<TranscriptMessage> messages) {
  final start =
      messages.lastIndexWhere((message) => message.role == MessageRole.user) +
      1;
  for (var index = messages.length - 1; index >= start; index--) {
    if (messages[index].role == MessageRole.activity) {
      messages.removeAt(index);
    }
  }
}

void finishRunningActivities(
  List<TranscriptMessage> messages,
  ActivityState state, {
  int start = 0,
  ActivityKind? kind,
}) {
  for (var index = start; index < messages.length; index++) {
    final message = messages[index];
    if (message.activityState != ActivityState.running ||
        (kind != null && message.activityKind != kind)) {
      continue;
    }
    messages[index] = TranscriptMessage.activity(
      activityLabel(message.activityKind!, message.activityTool, state),
      id: message.activityId!,
      kind: message.activityKind!,
      state: state,
      tool: message.activityTool,
      detail: message.activityDetail,
    );
  }
}

String activityLabel(ActivityKind kind, String? toolName, ActivityState state) {
  if (kind == ActivityKind.thinking) {
    return switch (state) {
      ActivityState.running => '正在思考',
      ActivityState.done => '思考完成',
      ActivityState.error => '思考失败',
      ActivityState.stopped => '已停止思考',
    };
  }
  if (kind == ActivityKind.summary) {
    return state == ActivityState.error ? '任务未完成' : '任务完成';
  }

  final action = switch (toolName) {
    'Read' => '读取文件',
    'Edit' => '修改文件',
    'Write' => '写入文件',
    'Bash' => '运行命令',
    'Grep' => '搜索内容',
    'Glob' => '查找文件',
    'Task' => '执行子任务',
    'WebSearch' => '搜索网页',
    'WebFetch' => '读取网页',
    final String name when name.isNotEmpty => '调用 $name',
    _ => '调用工具',
  };
  return switch (state) {
    ActivityState.running => '正在$action',
    ActivityState.done => '已$action',
    ActivityState.error => '$action失败',
    ActivityState.stopped => '已停止$action',
  };
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
    this.modelName,
    this.contextWindow,
    this.remainingContext,
  });

  final int revision;
  final bool running;
  final List<TranscriptMessage> messages;
  final PermissionMode permissionMode;
  final List<RemotePermissionRequest> pendingPermissions;
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

class AppRadii {
  static const panel = 22.0;
  static const bubble = 16.0;
  static const input = 16.0;
  static const control = 14.0;
  static const pill = 999.0;
}

class AppColors {
  static const ink = Color(0xFF172026);
  static const muted = Color(0xFF6B7880);
  static const accent = Color(0xFF168EB0);
  static const stop = Color(0xFFD96B6B);
  static const shadow = Color(0xFF7B8B96);
  // Single cool fog plate. Top/mid/bottom stay identical to kill banding.
  static const bgTop = Color(0xFFF3F6F8);
  static const bgMid = Color(0xFFF3F6F8);
  static const bgBottom = Color(0xFFF3F6F8);
}
