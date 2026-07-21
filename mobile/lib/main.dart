import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'attachments.dart';
import 'chat_background.dart';
import 'data/api_client.dart';
import 'data/permission_mode.dart';
import 'data/remote_models.dart';
import 'data/websocket_client.dart';
import 'model_preference.dart';
import 'notification_service.dart';
import 'signal_console_theme.dart';
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
    this.modelPreferenceStore,
    this.chatBackgroundPreferenceStore,
    this.chatBackgroundImageService,
  });

  final bool enableCamera;
  final bool demoMode;
  final BackgroundNotificationService? notificationService;
  final NotificationPreferenceStore? notificationPreferenceStore;
  final ClaudeModelPreferenceStore? modelPreferenceStore;
  final ChatBackgroundPreferenceStore? chatBackgroundPreferenceStore;
  final ChatBackgroundImageService? chatBackgroundImageService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CC Remote',
      debugShowCheckedModeBanner: false,
      theme: buildSignalConsoleTheme(),
      home: DemoShell(
        enableCamera: enableCamera,
        demoMode: demoMode,
        notificationService: notificationService,
        notificationPreferenceStore: notificationPreferenceStore,
        modelPreferenceStore: modelPreferenceStore,
        chatBackgroundPreferenceStore: chatBackgroundPreferenceStore,
        chatBackgroundImageService: chatBackgroundImageService,
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
    this.modelPreferenceStore,
    this.chatBackgroundPreferenceStore,
    this.chatBackgroundImageService,
  });

  final bool enableCamera;
  final bool demoMode;
  final BackgroundNotificationService? notificationService;
  final NotificationPreferenceStore? notificationPreferenceStore;
  final ClaudeModelPreferenceStore? modelPreferenceStore;
  final ChatBackgroundPreferenceStore? chatBackgroundPreferenceStore;
  final ChatBackgroundImageService? chatBackgroundImageService;

  @override
  State<DemoShell> createState() => _DemoShellState();
}

class _DemoShellState extends State<DemoShell> with WidgetsBindingObserver {
  static const networkTimeout = Duration(seconds: 12);
  static const interruptedRunMessage = '上次任务可能仍在电脑端运行，请重连确认';
  static const disconnectedRunMessage = '连接已断开，正在等待电脑端状态';
  static const sessionScopedMessageTypes = <String>{
    'status',
    'transcript_snapshot',
    'permission_request',
    'permission_resolved',
    'permission_expired',
    'text',
    'commands',
    'session_info',
    'activity',
    'done',
    'stopped',
    'error',
  };
  static const runScopedMessageTypes = <String>{
    'text',
    'activity',
    'permission_request',
    'permission_resolved',
    'permission_expired',
    'done',
    'stopped',
    'error',
  };

  ShellRoute route = ShellRoute.boot;
  bool running = false;
  bool stopping = false;
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
  String? activeRunId;
  int remoteTranscriptRevision = 0;
  bool hasUnappliedLiveTranscriptChanges = false;
  bool allowBypassPermissions = false;
  bool notificationsEnabled = true;
  bool notificationsReady = false;
  bool currentRunFailed = false;
  bool uploadingAttachments = false;
  ClaudeModelPreference selectedModel = ClaudeModelPreference.followComputer;
  ChatBackgroundPreference chatBackground =
      ChatBackgroundPreference.defaultValue;
  PermissionMode selectedPermissionMode = PermissionMode.manual;
  PermissionMode activePermissionMode = PermissionMode.manual;
  SavedSession? session;
  final RemoteWebSocketClient wsClient = RemoteWebSocketClient();
  final TokenStore tokenStore = TokenStore();
  final TranscriptStore transcriptStore = TranscriptStore();
  final RemoteApiClient apiClient = RemoteApiClient();
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
  // ponytail: batch stream paint/persist; tighten if first glyph feels late
  static const streamTextBatchInterval = Duration(milliseconds: 40);
  static const streamPersistInterval = Duration(milliseconds: 1500);
  String pendingAssistantText = '';
  Timer? streamTextFlushTimer;
  Timer? streamPersistTimer;
  DateTime? lastStreamPersistAt;
  late final Future<void> modelPreferenceInitialization;
  int modelPreferenceRevision = 0;
  int chatBackgroundRevision = 0;
  late final BackgroundNotificationService notificationService;
  late final NotificationPreferenceStore notificationPreferenceStore;
  late final BackgroundNotificationController notificationController;
  late final ClaudeModelPreferenceStore modelPreferenceStore;
  late final ChatBackgroundPreferenceStore chatBackgroundPreferenceStore;
  late final ChatBackgroundImageService chatBackgroundImageService;
  String? pendingNotificationSessionId;

  Object? get ws => wsClient.channel;

  @override
  void initState() {
    super.initState();
    notificationService =
        widget.notificationService ?? LocalBackgroundNotificationService();
    notificationPreferenceStore =
        widget.notificationPreferenceStore ?? NotificationPreferenceStore();
    modelPreferenceStore =
        widget.modelPreferenceStore ?? ClaudeModelPreferenceStore();
    chatBackgroundPreferenceStore =
        widget.chatBackgroundPreferenceStore ?? ChatBackgroundPreferenceStore();
    chatBackgroundImageService =
        widget.chatBackgroundImageService ?? LocalChatBackgroundImageService();
    notificationController = BackgroundNotificationController(
      service: notificationService,
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(initializeNotifications());
    modelPreferenceInitialization = initializeModelPreference();
    unawaited(modelPreferenceInitialization);
    unawaited(initializeChatBackground());
    bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    streamTextFlushTimer?.cancel();
    streamPersistTimer?.cancel();
    closeWs();
    apiClient.close();
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

  Future<void> initializeModelPreference() async {
    final revision = modelPreferenceRevision;
    final preference = await modelPreferenceStore.load();
    if (!mounted || revision != modelPreferenceRevision) return;
    setState(() => selectedModel = preference);
  }

  Future<void> setModelPreference(ClaudeModelPreference preference) async {
    modelPreferenceRevision += 1;
    await modelPreferenceStore.save(preference);
    if (mounted) setState(() => selectedModel = preference);
  }

  Future<void> initializeChatBackground() async {
    final revision = chatBackgroundRevision;
    final preference = await chatBackgroundPreferenceStore.load();
    if (!mounted || revision != chatBackgroundRevision) return;
    setState(() => chatBackground = preference);
  }

  Future<ChatBackgroundPreference> setChatBackground(
    ChatBackgroundPreference preference,
  ) async {
    chatBackgroundRevision += 1;
    final previous = chatBackground;
    await chatBackgroundPreferenceStore.save(preference);
    if (mounted) setState(() => chatBackground = preference);
    if (previous.imagePath != null &&
        previous.imagePath != preference.imagePath) {
      await deleteChatBackgroundImage(previous.imagePath);
    }
    return preference;
  }

  Future<void> deleteChatBackgroundImage(String? path) async {
    try {
      await chatBackgroundImageService.deleteStoredImage(path);
    } catch (_) {}
  }

  Future<ChatBackgroundPreference?> pickChatBackgroundImage(
    double overlayOpacity,
  ) async {
    final path = await chatBackgroundImageService.pickAndStore();
    if (path == null) return null;
    final preference = ChatBackgroundPreference.localImage(
      path,
      overlayOpacity: overlayOpacity,
    );
    try {
      return await setChatBackground(preference);
    } catch (_) {
      await deleteChatBackgroundImage(path);
      rethrow;
    }
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
      stopping = false;
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

  void removeDisconnectedRunNotice() {
    messages.removeWhere(
      (message) =>
          message.role == MessageRole.system &&
          message.text == disconnectedRunMessage,
    );
  }

  bool acceptWsMessage(Map<String, dynamic> decoded) {
    final type = decoded['type'];
    if (type is! String) return false;

    if (sessionScopedMessageTypes.contains(type)) {
      final messageSessionId = decoded['sessionId'];
      if (messageSessionId is! String) return false;
      if (activeSessionId != null && messageSessionId != activeSessionId) {
        return false;
      }
    }

    if (!runScopedMessageTypes.contains(type)) return true;
    final messageRunId = decoded['runId'];
    if (messageRunId is! String) {
      return activeRunId == null;
    }
    if (activeRunId != null && messageRunId != activeRunId) return false;
    activeRunId ??= messageRunId;
    return true;
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
        stopping = false;
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
          stopping = false;
          messages.clear();
        });
        return;
      }
      setState(() {
        remoteOffline = true;
        stopping = false;
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
        stopping = false;
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
          stopping = false;
          messages.clear();
        });
        return;
      }
      setState(() {
        session = saved;
        route = ShellRoute.chat;
        wsReady = false;
        remoteOffline = true;
        stopping = false;
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
      stopping = false;
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
    wsClient.close();
    wsReady = false;
  }

  void connectWs(SavedSession saved) {
    if (widget.demoMode) {
      setState(() => wsReady = true);
      return;
    }

    closeWs();
    activeRunId = null;
    setState(() => wsReady = false);

    try {
      wsClient.connect(
        origin: saved.origin,
        token: saved.token,
        onMessage: handleWsMessage,
        onError: (Object err) => handleWsClosed('连接错误：$err'),
        onDone: () => handleWsClosed('连接已断开'),
      );
    } catch (err) {
      handleWsClosed('连接失败：$err');
    }
  }

  void handleWsMessage(dynamic data) {
    final decoded = jsonDecode(data.toString());
    if (decoded is! Map<String, dynamic>) return;

    if (decoded['authenticated'] == false) {
      unawaited(recoverUnauthorizedSession());
      return;
    }

    if (!acceptWsMessage(decoded)) return;

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
            stopping = false;
            pendingAttachments.clear();
            remoteTranscriptRevision = 0;
            activeRunId = null;
            hasUnappliedLiveTranscriptChanges = false;
            clearStreamTextBatch(apply: false);
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
          final nextRunId = decoded['runId'];
          activeRunId = running && nextRunId is String ? nextRunId : null;
          removeDisconnectedRunNotice();
          if (!running) stopping = false;
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
              hasUnappliedLiveChanges: hasUnappliedLiveTranscriptChanges,
            )) {
          return;
        }
        clearStreamTextBatch(apply: false);
        setState(() {
          remoteTranscriptRevision = snapshot.revision;
          running = snapshot.running;
          activeRunId = snapshot.running ? snapshot.runId ?? activeRunId : null;
          hasUnappliedLiveTranscriptChanges = false;
          removeDisconnectedRunNotice();
          if (!running) stopping = false;
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
          hasUnappliedLiveTranscriptChanges = true;
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
          hasUnappliedLiveTranscriptChanges = true;
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
          hasUnappliedLiveTranscriptChanges = true;
        });
        persistTranscriptSnapshotLater();
      case 'text':
        queueAssistantText(decoded['text'] as String? ?? '');
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
        setState(() {
          hasUnappliedLiveTranscriptChanges = true;
          mergeRemoteActivity(messages, activity);
        });
        persistTranscriptSnapshotLater();
      case 'done':
        final failed = currentRunFailed;
        flushStreamTextBatch();
        setState(() {
          running = false;
          stopping = false;
          currentRunFailed = false;
          activeRunId = null;
          hasUnappliedLiveTranscriptChanges = true;
          removeDisconnectedRunNotice();
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
        persistTranscriptSnapshotNow();
      case 'stopped':
        flushStreamTextBatch();
        setState(() {
          running = false;
          stopping = false;
          currentRunFailed = false;
          activeRunId = null;
          hasUnappliedLiveTranscriptChanges = true;
          removeDisconnectedRunNotice();
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
        persistTranscriptSnapshotNow();
      case 'error':
        final errorMessage = decoded['message']?.toString() ?? '未知错误';
        flushStreamTextBatch();
        setState(() {
          running = false;
          stopping = false;
          currentRunFailed = true;
          activeRunId = null;
          hasUnappliedLiveTranscriptChanges = true;
          removeDisconnectedRunNotice();
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
        persistTranscriptSnapshotNow();
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
      stopping = false;
      clearStreamTextBatch(apply: false);
      messages.clear();
      commands.clear();
      projects.clear();
      remoteSessions.clear();
      activeProjectId = null;
      activeSessionId = null;
      activeRunId = null;
      remoteTranscriptRevision = 0;
      hasUnappliedLiveTranscriptChanges = false;
      allowBypassPermissions = false;
      selectedPermissionMode = PermissionMode.manual;
      activePermissionMode = PermissionMode.manual;
      pendingPermissions.clear();
      respondingPermissionIds.clear();
    });
  }

  void handleWsClosed(String _) {
    if (!mounted || route != ShellRoute.chat) return;
    flushStreamTextBatch();
    setState(() {
      wsReady = false;
      remoteOffline = true;
      stopping = false;
      if (running) {
        hasUnappliedLiveTranscriptChanges = true;
        if (!messages.any(
          (item) =>
              item.role == MessageRole.system &&
              item.text == disconnectedRunMessage,
        )) {
          messages.add(TranscriptMessage.system(disconnectedRunMessage));
        }
      }
    });
    persistTranscriptSnapshotNow();
  }

  void queueAssistantText(String text) {
    if (text.isEmpty) return;
    hasUnappliedLiveTranscriptChanges = true;
    pendingAssistantText += text;
    streamTextFlushTimer ??= Timer(streamTextBatchInterval, flushStreamTextBatch);
  }

  void flushStreamTextBatch() {
    streamTextFlushTimer?.cancel();
    streamTextFlushTimer = null;
    final text = pendingAssistantText;
    pendingAssistantText = '';
    if (text.isEmpty) return;
    appendAssistantText(text, persist: false);
    scheduleStreamPersist();
  }

  void clearStreamTextBatch({required bool apply}) {
    streamTextFlushTimer?.cancel();
    streamTextFlushTimer = null;
    if (apply && pendingAssistantText.isNotEmpty) {
      final text = pendingAssistantText;
      pendingAssistantText = '';
      appendAssistantText(text, persist: false);
      return;
    }
    pendingAssistantText = '';
  }

  void scheduleStreamPersist() {
    final last = lastStreamPersistAt;
    final now = DateTime.now();
    if (last == null || now.difference(last) >= streamPersistInterval) {
      persistTranscriptSnapshotNow();
      return;
    }
    streamPersistTimer ??= Timer(streamPersistInterval, () {
      streamPersistTimer = null;
      persistTranscriptSnapshotNow();
    });
  }

  void persistTranscriptSnapshotNow() {
    streamPersistTimer?.cancel();
    streamPersistTimer = null;
    lastStreamPersistAt = DateTime.now();
    persistTranscriptSnapshotLater();
  }

  void appendAssistantText(String text, {bool persist = true}) {
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
    if (persist) persistTranscriptSnapshotLater();
  }

  Future<void> sendPrompt() async {
    final text = promptController.text.trim();
    if (text.isEmpty && pendingAttachments.isEmpty) {
      return;
    }
    await modelPreferenceInitialization;
    if (!mounted || running || uploadingAttachments) return;

    if (widget.demoMode) {
      setState(() {
        promptController.clear();
        pendingAttachments.clear();
        running = false;
        stopping = false;
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
        stopping = false;
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
        uploaded = await AttachmentUploader(client: apiClient.client).upload(
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
      stopping = false;
      currentRunFailed = false;
      activePermissionMode = selectedPermissionMode;
      hasUnappliedLiveTranscriptChanges = true;
      beginPrompt(messages, text, attachments: uploaded);
      if (selectedPermissionMode == PermissionMode.bypassPermissions) {
        selectedPermissionMode = PermissionMode.manual;
      }
    });
    persistTranscriptSnapshotLater();
    wsClient.send(
      buildPromptMessage(
        text: text,
        attachmentIds: uploaded.map((attachment) => attachment.id),
        permissionMode: activePermissionMode,
        sessionId: currentSessionId,
        model: selectedModel,
      ),
      expectedConnection: channel,
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
    wsClient.send({
      'type': 'permission_response',
      'requestId': request.requestId,
      'decision': decision,
      if (activeSessionId != null) 'sessionId': activeSessionId,
    }, expectedConnection: channel);
  }

  Future<void> stopRun() async {
    if (!running || stopping) return;

    setState(() {
      stopping = true;
      messages.add(TranscriptMessage.system('正在停止'));
    });
    persistTranscriptSnapshotLater();

    if (widget.demoMode) {
      await Future<void>.delayed(AppMotion.feedback);
      if (!mounted || !stopping) return;
      setState(() {
        running = false;
        stopping = false;
        messages.add(TranscriptMessage.system('已停止'));
      });
      persistTranscriptSnapshotLater();
      return;
    }

    final channel = ws;
    if (channel == null || !wsReady) {
      setState(() {
        stopping = false;
        hasUnappliedLiveTranscriptChanges = true;
        messages.add(TranscriptMessage.system('未连接，无法发送停止指令'));
      });
      persistTranscriptSnapshotLater();
      return;
    }

    wsClient.send({'type': 'stop'}, expectedConnection: channel);
    final requestedSessionId = activeSessionId;
    await Future<void>.delayed(networkTimeout);
    if (!mounted || !stopping || activeSessionId != requestedSessionId) return;
    setState(() {
      stopping = false;
      messages.add(TranscriptMessage.system('停止请求未确认，任务仍在运行'));
    });
    persistTranscriptSnapshotLater();
  }

  Future<void> beginNewConversation() async {
    if (running || uploadingAttachments) return;

    if (widget.demoMode) {
      setState(() {
        modelName = null;
        contextWindow = null;
        remainingContext = null;
        clearStreamTextBatch(apply: false);
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
      final res = await apiClient.post(
        current.origin,
        '/api/new-conversation',
        token: current.token,
        timeout: networkTimeout,
      );
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
        activeRunId = null;
        hasUnappliedLiveTranscriptChanges = false;
        modelName = null;
        contextWindow = null;
        remainingContext = null;
        clearStreamTextBatch(apply: false);
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
      stopping = false;
      wsReady = false;
      remoteOffline = false;
      pausedQrRaw = null;
      modelName = null;
      contextWindow = null;
      remainingContext = null;
      clearStreamTextBatch(apply: false);
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
        await apiClient.post(
          current.origin,
          '/api/logout',
          token: current.token,
          timeout: networkTimeout,
        );
      } catch (_) {
        // Local token is still cleared below.
      }
      await tokenStore.clear();
    }
    await logoutDemoDevice();
  }

  Future<RemoteStatus> fetchStatus(SavedSession saved) async {
    final res = await apiClient.get(
      saved.origin,
      '/api/status',
      token: saved.token,
      timeout: networkTimeout,
    );
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
    final changedSession =
        activeSessionId != null && activeSessionId != catalog.activeSessionId;
    activeProjectId = catalog.activeProjectId;
    activeSessionId = catalog.activeSessionId;
    if (changedSession) {
      // Match WS catalog handling so HTTP rename/archive/delete cannot leave
      // the previous session's transcript under the new activeSessionId.
      uploadingAttachments = false;
      stopping = false;
      pendingAttachments.clear();
      remoteTranscriptRevision = 0;
      clearStreamTextBatch(apply: false);
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
  }

  void openSessions() {
    if (projects.isEmpty || uploadingAttachments) return;
    showSessionNavigator(
      context,
      projects: projects,
      sessions: remoteSessions,
      activeProjectId: activeProjectId,
      activeSessionId: activeSessionId,
      running: running || uploadingAttachments,
      onSelect: selectRemoteSession,
      onCreate: createRemoteSession,
      onRename: renameRemoteSession,
      onArchive: archiveRemoteSession,
      onDelete: deleteRemoteSession,
    );
  }

  void selectRemoteSession(String sessionId) {
    if (running || uploadingAttachments || sessionId == activeSessionId) return;
    RemoteSessionSummary? target;
    for (final item in remoteSessions) {
      if (item.id == sessionId) {
        target = item;
        break;
      }
    }
    if (target?.archived == true) return;
    wsClient.send({'type': 'select_session', 'sessionId': sessionId});
  }

  Future<void> createRemoteSession(String projectId) async {
    if (running || uploadingAttachments) return;
    final current = session;
    if (current == null) return;
    try {
      final res = await apiClient.post(
        current.origin,
        '/api/projects/$projectId/sessions',
        token: current.token,
        timeout: networkTimeout,
      );
      if (res.statusCode == 401) throw const UnauthorizedSession();
      if (res.statusCode != 201) throw StateError('create_session_failed');
    } on UnauthorizedSession {
      await recoverUnauthorizedSession();
    } catch (_) {
      if (!mounted) return;
      setState(() => messages.add(TranscriptMessage.system('新建会话失败，请重试')));
    }
  }

  Future<void> renameRemoteSession(String sessionId, String title) async {
    if (running || uploadingAttachments) return;
    final current = session;
    if (current == null) return;
    try {
      final res = await apiClient.post(
        current.origin,
        '/api/sessions/$sessionId/title',
        token: current.token,
        jsonBody: true,
        body: jsonEncode({'title': title}),
        timeout: networkTimeout,
      );
      if (res.statusCode == 401) throw const UnauthorizedSession();
      if (res.statusCode != 200) throw StateError('rename_session_failed');
      final body = jsonDecode(res.body);
      if (body is Map<String, dynamic>) {
        final catalog = RemoteProjectCatalog.tryParse(body);
        if (catalog != null && mounted) {
          setState(() => applyCatalog(catalog));
        }
      }
    } on UnauthorizedSession {
      await recoverUnauthorizedSession();
    } catch (_) {
      if (!mounted) return;
      setState(() => messages.add(TranscriptMessage.system('重命名会话失败，请重试')));
    }
  }

  Future<void> archiveRemoteSession(String sessionId) async {
    if (running || uploadingAttachments) return;
    final current = session;
    if (current == null) return;
    try {
      final res = await apiClient.post(
        current.origin,
        '/api/sessions/$sessionId/archive',
        token: current.token,
        timeout: networkTimeout,
      );
      if (res.statusCode == 401) throw const UnauthorizedSession();
      if (res.statusCode != 200) throw StateError('archive_session_failed');
      final body = jsonDecode(res.body);
      if (body is Map<String, dynamic>) {
        final catalog = RemoteProjectCatalog.tryParse(body);
        if (catalog != null && mounted) {
          setState(() => applyCatalog(catalog));
        }
      }
    } on UnauthorizedSession {
      await recoverUnauthorizedSession();
    } catch (_) {
      if (!mounted) return;
      setState(() => messages.add(TranscriptMessage.system('归档会话失败，请重试')));
    }
  }

  Future<void> deleteRemoteSession(String sessionId) async {
    if (running || uploadingAttachments) return;
    final current = session;
    if (current == null) return;
    try {
      final res = await apiClient.delete(
        current.origin,
        '/api/sessions/$sessionId',
        token: current.token,
        timeout: networkTimeout,
      );
      if (res.statusCode == 401) throw const UnauthorizedSession();
      if (res.statusCode != 200) throw StateError('delete_session_failed');
      final body = jsonDecode(res.body);
      if (body is Map<String, dynamic>) {
        final catalog = RemoteProjectCatalog.tryParse(body);
        if (catalog != null && mounted) {
          setState(() => applyCatalog(catalog));
        }
      }
    } on UnauthorizedSession {
      await recoverUnauthorizedSession();
    } catch (_) {
      if (!mounted) return;
      setState(() => messages.add(TranscriptMessage.system('删除会话失败，请重试')));
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
      final res = await apiClient.post(
        payload.origin,
        '/api/pair',
        jsonBody: true,
        body: jsonEncode({'nonce': payload.nonce}),
        timeout: networkTimeout,
      );
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
        stopping = false;
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
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final screen = switch (route) {
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
        stopping: stopping,
        uploadingAttachments: uploadingAttachments,
        connected: wsReady,
        offline: remoteOffline,
        modelName: modelName,
        contextWindow: contextWindow,
        remainingContext: remainingContext,
        messages: messages,
        commands: commands,
        permissionMode: running ? activePermissionMode : selectedPermissionMode,
        allowBypassPermissions: allowBypassPermissions,
        pendingPermissions: pendingPermissions,
        respondingPermissionIds: respondingPermissionIds,
        promptController: promptController,
        pendingAttachments: pendingAttachments,
        onFillPrompt: fillPrompt,
        onReconnect: refreshConnection,
        onOpenSettings: () => showSettingsSheet(
          context,
          session,
          notificationsEnabled,
          chatBackground,
          modelName,
          selectedModel,
          refreshConnection,
          setNotificationsEnabled,
          setModelPreference,
          setChatBackground,
          pickChatBackgroundImage,
          logoutPairedDevice,
        ),
        onNewConversation: beginNewConversation,
        onOpenSessions: openSessions,
        onOpenWorkspace: openWorkspace,
        onPermissionModeSelected: selectPermissionMode,
        onPermissionAllow: (request) => respondToPermission(request, 'allow'),
        onPermissionDeny: (request) => respondToPermission(request, 'deny'),
        onAddAttachment: chooseAttachments,
        onRemoveAttachment: removePendingAttachment,
        onSend: sendPrompt,
        onStop: stopRun,
      ),
    };
    return AppBackground(
      chatBackground: route == ShellRoute.chat
          ? chatBackground
          : ChatBackgroundPreference.defaultValue,
      child: AnimatedSwitcher(
        duration: reduceMotion ? Duration.zero : AppMotion.standard,
        reverseDuration: reduceMotion ? Duration.zero : AppMotion.fast,
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        transitionBuilder: (child, animation) {
          if (reduceMotion) return child;
          final offset = Tween<Offset>(
            begin: const Offset(0.035, 0),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offset, child: child),
          );
        },
        child: KeyedSubtree(key: ValueKey(route), child: screen),
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
                color: AppColors.porcelain,
                border: Border.all(color: AppColors.line),
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 520;
          final content = Padding(
            padding: EdgeInsets.fromLTRB(18, compact ? 8 : 14, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.mintSoft,
                              borderRadius: BorderRadius.circular(
                                AppRadii.pill,
                              ),
                              border: Border.all(
                                color: AppColors.ink,
                                width: 1.2,
                              ),
                            ),
                            child: const Text(
                              '手机端 · 第一次见面',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          SizedBox(height: compact ? 7 : 10),
                          Text(
                            '让手机找到电脑',
                            style: TextStyle(
                              fontSize: compact ? 25 : 31,
                              height: 1.04,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -1.0,
                            ),
                          ),
                          const SizedBox(height: 5),
                          const Text(
                            '扫描电脑终端里的二维码',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: compact ? 10 : 14),
                    SizedBox(
                      width: compact ? 64 : 82,
                      height: compact ? 60 : 76,
                      child: const LivelyTerminalPal(
                        mood: TerminalPalMood.ready,
                        showBadge: true,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 12 : 16),
                if (compact)
                  SizedBox(
                    height: 126,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1.68,
                        child: ScanFrame(
                          compact: true,
                          child: enableCamera
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
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
                              : const ScanPlaceholder(compact: true),
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 0.94,
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
                SizedBox(height: compact ? 12 : 16),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
                  decoration: ShapeDecoration(
                    color: AppColors.porcelain,
                    shadows: const [
                      BoxShadow(
                        color: AppColors.coral,
                        blurRadius: 0,
                        offset: Offset(5, 6),
                      ),
                    ],
                    shape: const SignalCutCornerBorder(
                      side: BorderSide(color: AppColors.ink, width: 1.6),
                      radius: 22,
                      cut: 20,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: AppColors.yellow,
                              borderRadius: BorderRadius.circular(13),
                              border: Border.all(
                                color: AppColors.ink,
                                width: 1.4,
                              ),
                            ),
                            child: const Icon(
                              Icons.desktop_windows_rounded,
                              size: 20,
                              color: AppColors.ink,
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
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                const SizedBox(height: 3),
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
                          const SizedBox(width: 8),
                          StatusPill(
                            label: pairing
                                ? '配对中'
                                : error == null
                                ? canResetScan
                                      ? '等待确认'
                                      : '相机已就绪'
                                : '需要重试',
                            color: error == null
                                ? AppColors.success
                                : AppColors.stop,
                          ),
                        ],
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
                      if (onDemoConnect != null) ...[
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: SignalPressEffect(
                            child: FilledButton.icon(
                              onPressed: onDemoConnect,
                              icon: const Icon(Icons.link_rounded),
                              label: const Text('连接这台电脑'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.ink,
                                foregroundColor: AppColors.porcelain,
                                minimumSize: const Size.fromHeight(48),
                              ),
                            ),
                          ),
                        ),
                      ] else if (!pairing &&
                          error == null &&
                          !canResetScan) ...[
                        const SizedBox(height: 14),
                        const SignalTrack(color: AppColors.mint, active: true),
                      ],
                      if (canResetScan || error != null) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: onClearError,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('重新扫描'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.ink,
                              minimumSize: const Size.fromHeight(46),
                              side: const BorderSide(
                                color: AppColors.ink,
                                width: 1.3,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
          return compact ? SingleChildScrollView(child: content) : content;
        },
      ),
    );
  }
}

class ScanPlaceholder extends StatelessWidget {
  const ScanPlaceholder({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: compact ? 46 : 68,
          height: compact ? 46 : 68,
          decoration: BoxDecoration(
            color: AppColors.ink,
            borderRadius: BorderRadius.circular(compact ? 14 : 20),
          ),
          child: Icon(
            Icons.qr_code_2_rounded,
            size: compact ? 28 : 42,
            color: AppColors.porcelain,
          ),
        ),
        SizedBox(height: compact ? 6 : 14),
        const Text(
          '把二维码放进取景框',
          style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800),
        ),
        if (!compact) ...[
          const SizedBox(height: 4),
          const Text(
            '识别后会先显示电脑信息',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
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
                child: SignalPressEffect(
                  enabled: !expired,
                  child: FilledButton(
                    onPressed: expired
                        ? null
                        : () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                    ),
                    child: const Text('连接这台电脑'),
                  ),
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
                      borderRadius: BorderRadius.circular(AppRadii.control),
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
    this.stopping = false,
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
    required this.pendingPermissions,
    required this.respondingPermissionIds,
    required this.promptController,
    this.pendingAttachments = const [],
    required this.onFillPrompt,
    required this.onReconnect,
    required this.onOpenSettings,
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
  });

  final SavedSession? session;
  final String? activeSessionId;
  final bool running;
  final bool stopping;
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
  final List<RemotePermissionRequest> pendingPermissions;
  final Set<String> respondingPermissionIds;
  final TextEditingController promptController;
  final List<AttachmentDraft> pendingAttachments;
  final ValueChanged<String> onFillPrompt;
  final VoidCallback onReconnect;
  final VoidCallback onOpenSettings;
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

  @override
  Widget build(BuildContext context) {
    final header = RepaintBoundary(
      child: ConnectionHeader(
        session: session,
        running: running,
        stopping: stopping,
        uploadingAttachments: uploadingAttachments,
        connected: connected,
        offline: offline,
        modelName: modelName,
        contextWindow: contextWindow,
        remainingContext: remainingContext,
        onReconnect: onReconnect,
        onOpenSettings: onOpenSettings,
        onNewConversation: onNewConversation,
        onOpenSessions: onOpenSessions,
        onOpenWorkspace: onOpenWorkspace,
      ),
    );
    final transcript = RepaintBoundary(
      child: TranscriptView(
        messages: messages,
        session: session,
        activeSessionId: activeSessionId,
        running: running,
        pendingPermissions: pendingPermissions,
        respondingPermissionIds: respondingPermissionIds,
        connected: connected,
        onFillPrompt: onFillPrompt,
        onReconnect: onReconnect,
        onPermissionAllow: onPermissionAllow,
        onPermissionDeny: onPermissionDeny,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final reservedHeight = modelName != null || remainingContext != null
            ? 324.0
            : 292.0;
        final suggestionMaxHeight = (constraints.maxHeight - reservedHeight)
            .clamp(44.0, 292.0);
        return SafeArea(
          key: const ValueKey('chat'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Column(
              children: [
                header,
                const SizedBox(height: 12),
                Expanded(child: transcript),
                const SizedBox(height: 7),
                PromptBar(
                  controller: promptController,
                  attachments: pendingAttachments,
                  commands: commands,
                  running: running,
                  stopping: stopping,
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
    this.stopping = false,
    required this.uploadingAttachments,
    required this.connected,
    required this.offline,
    required this.modelName,
    required this.contextWindow,
    required this.remainingContext,
    required this.onReconnect,
    required this.onOpenSettings,
    required this.onNewConversation,
    required this.onOpenSessions,
    required this.onOpenWorkspace,
  });

  final SavedSession? session;
  final bool running;
  final bool stopping;
  final bool uploadingAttachments;
  final bool connected;
  final bool offline;
  final String? modelName;
  final int? contextWindow;
  final int? remainingContext;
  final VoidCallback onReconnect;
  final VoidCallback onOpenSettings;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenSessions;
  final VoidCallback onOpenWorkspace;

  @override
  Widget build(BuildContext context) {
    final statusLabel = stopping
        ? '正在停止任务'
        : running
        ? '任务运行中'
        : uploadingAttachments
        ? '正在收附件'
        : connected
        ? '已连接'
        : offline
        ? '电脑走丢了'
        : '正在找电脑';
    final title = offline
        ? '等电脑回来'
        : running
        ? '正在处理这件事'
        : '已经准备好了';
    final workspace = session?.workspaceName ?? 'cc-remote';
    final device = session?.deviceName ?? 'Jayson PC';
    final compact = MediaQuery.sizeOf(context).height < 720;

    if (compact) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: MediaQuery.textScalerOf(
            context,
          ).clamp(minScaleFactor: 1, maxScaleFactor: 1.2),
        ),
        child: Container(
          height: 84,
          padding: const EdgeInsets.fromLTRB(11, 8, 9, 8),
          decoration: BoxDecoration(
            color: offline ? AppColors.porcelainMuted : AppColors.mint,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.ink, width: 1.6),
            boxShadow: const [
              BoxShadow(
                color: AppColors.yellow,
                blurRadius: 0,
                offset: Offset(4, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      statusLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.25,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (modelName == null && remainingContext == null)
                      Text(
                        '$workspace · $device',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    else
                      Row(
                        children: [
                          if (modelName != null)
                            Flexible(
                              child: Text(
                                formatModelName(modelName!),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          if (modelName != null && remainingContext != null)
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4),
                              child: Text('·'),
                            ),
                          if (remainingContext != null)
                            Flexible(
                              child: Text(
                                contextWindow == null
                                    ? '剩余 ${formatTokens(remainingContext!)}'
                                    : '剩余 ${formatTokens(remainingContext!)} / ${formatTokens(contextWindow!)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      _HeroIconButton(
                        tooltip: '项目与会话',
                        icon: Icons.dashboard_customize_outlined,
                        dimension: 31,
                        onPressed: uploadingAttachments ? null : onOpenSessions,
                      ),
                      const SizedBox(width: 5),
                      _HeroIconButton(
                        tooltip: '工作区',
                        icon: Icons.folder_open_rounded,
                        dimension: 31,
                        onPressed: onOpenWorkspace,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _HeroIconButton(
                        tooltip: '新对话',
                        icon: Icons.add_rounded,
                        dimension: 31,
                        onPressed:
                            connected && !running && !uploadingAttachments
                            ? onNewConversation
                            : null,
                      ),
                      const SizedBox(width: 5),
                      _HeroIconButton(
                        tooltip: '设置',
                        icon: Icons.auto_awesome_rounded,
                        color: AppColors.yellow,
                        dimension: 31,
                        onPressed: onOpenSettings,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: MediaQuery.textScalerOf(
          context,
        ).clamp(minScaleFactor: 1, maxScaleFactor: 1.35),
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 84),
        decoration: BoxDecoration(
          color: offline ? AppColors.porcelainMuted : AppColors.mint,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.ink, width: 1.8),
          boxShadow: const [
            BoxShadow(
              color: AppColors.yellow,
              blurRadius: 0,
              offset: Offset(5, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 8, 11, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusPill(label: statusLabel, color: AppColors.ink),
                    const SizedBox(height: 5),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 23,
                        height: 1,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.7,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 154,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _HeroIconButton(
                          tooltip: '项目与会话',
                          icon: Icons.dashboard_customize_outlined,
                          dimension: 32,
                          onPressed: uploadingAttachments
                              ? null
                              : onOpenSessions,
                        ),
                        const SizedBox(width: 5),
                        _HeroIconButton(
                          tooltip: '工作区',
                          icon: Icons.folder_open_rounded,
                          dimension: 32,
                          onPressed: onOpenWorkspace,
                        ),
                        const SizedBox(width: 5),
                        _HeroIconButton(
                          tooltip: '新对话',
                          icon: Icons.add_rounded,
                          dimension: 32,
                          onPressed:
                              connected && !running && !uploadingAttachments
                              ? onNewConversation
                              : null,
                        ),
                        const SizedBox(width: 5),
                        _HeroIconButton(
                          tooltip: '设置',
                          icon: Icons.auto_awesome_rounded,
                          color: AppColors.yellow,
                          dimension: 32,
                          onPressed: onOpenSettings,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$workspace · $device',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (modelName != null || remainingContext != null) ...[
                      const SizedBox(height: 1),
                      SizedBox(
                        width: 154,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (modelName != null)
                                Text(
                                  formatModelName(modelName!),
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              if (modelName != null && remainingContext != null)
                                const SizedBox(width: 6),
                              if (remainingContext != null)
                                Text(
                                  contextWindow == null
                                      ? '剩余 ${formatTokens(remainingContext!)}'
                                      : '剩余 ${formatTokens(remainingContext!)} / ${formatTokens(contextWindow!)}',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroIconButton extends StatelessWidget {
  const _HeroIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color = AppColors.porcelain,
    this.dimension = 34,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: dimension,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 17),
        style: IconButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: color.withValues(alpha: 0.5),
          foregroundColor: AppColors.ink,
          disabledForegroundColor: AppColors.ink.withValues(alpha: 0.32),
          side: const BorderSide(color: AppColors.ink, width: 1.4),
        ),
      ),
    );
  }
}

class LegacyConnectionHeader extends StatelessWidget {
  const LegacyConnectionHeader({
    super.key,
    required this.session,
    required this.running,
    this.stopping = false,
    required this.uploadingAttachments,
    required this.connected,
    required this.offline,
    required this.modelName,
    required this.contextWindow,
    required this.remainingContext,
    required this.onReconnect,
    required this.onOpenSettings,
    required this.onNewConversation,
    required this.onOpenSessions,
    required this.onOpenWorkspace,
  });

  final SavedSession? session;
  final bool running;
  final bool stopping;
  final bool uploadingAttachments;
  final bool connected;
  final bool offline;
  final String? modelName;
  final int? contextWindow;
  final int? remainingContext;
  final VoidCallback onReconnect;
  final VoidCallback onOpenSettings;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenSessions;
  final VoidCallback onOpenWorkspace;

  @override
  Widget build(BuildContext context) {
    final statusLabel = stopping
        ? '正在停止'
        : running
        ? '运行中'
        : uploadingAttachments
        ? '上传中'
        : connected
        ? '已连接'
        : offline
        ? '电脑端离线'
        : '正在连接';
    final statusColor = stopping
        ? AppColors.warning
        : running || connected
        ? AppColors.accent
        : offline
        ? AppColors.stop
        : AppColors.warning;
    final workspace = session?.workspaceName ?? 'cc-remote';
    final device = session?.deviceName ?? 'Jayson PC';

    return GlassPanel(
      radius: AppRadii.panel,
      padding: const EdgeInsets.fromLTRB(6, 5, 6, 8),
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
                      onPressed: uploadingAttachments ? null : onOpenSessions,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.view_quilt_outlined, size: 20),
                      tooltip: '项目与会话',
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.porcelainMuted,
                        foregroundColor: AppColors.accent,
                        side: const BorderSide(color: AppColors.line),
                      ),
                    ),
                    IconButton(
                      onPressed: onOpenWorkspace,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.folder_open_outlined, size: 20),
                      tooltip: '工作区',
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.porcelainMuted,
                        foregroundColor: AppColors.accent,
                        side: const BorderSide(color: AppColors.line),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      workspace,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.35,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
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
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
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
                      onPressed: connected && !running && !uploadingAttachments
                          ? onNewConversation
                          : null,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.add_comment_rounded, size: 20),
                      tooltip: '新对话',
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.porcelainMuted,
                        side: const BorderSide(color: AppColors.line),
                      ),
                    ),
                    IconButton(
                      onPressed: onOpenSettings,
                      icon: const Icon(Icons.tune_rounded, size: 21),
                      tooltip: '设置',
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.porcelainMuted,
                        side: const BorderSide(color: AppColors.line),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: SignalTrack(
              color: statusColor,
              active: (running && !stopping) || uploadingAttachments,
              broken: offline,
            ),
          ),
          if (modelName != null || remainingContext != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 44, 1),
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
                    Row(
                      key: const ValueKey('context-metric'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ContextDial(
                          remaining: remainingContext!,
                          total: contextWindow,
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            contextWindow == null
                                ? '剩余 ${formatTokens(remainingContext!)}'
                                : '剩余 ${formatTokens(remainingContext!)} / ${formatTokens(contextWindow!)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
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
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.accentSoft.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.accent),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
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
  ChatBackgroundPreference chatBackground,
  String? currentModel,
  ClaudeModelPreference selectedModel,
  VoidCallback onReconnect,
  Future<bool> Function(bool) onNotificationsChanged,
  Future<void> Function(ClaudeModelPreference) onModelChanged,
  Future<ChatBackgroundPreference> Function(ChatBackgroundPreference)
  onChatBackgroundChanged,
  Future<ChatBackgroundPreference?> Function(double) onPickChatBackgroundImage,
  VoidCallback onLogout,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => SettingsSheet(
      session: session,
      notificationsEnabled: notificationsEnabled,
      chatBackground: chatBackground,
      currentModel: currentModel,
      selectedModel: selectedModel,
      onReconnect: onReconnect,
      onNotificationsChanged: onNotificationsChanged,
      onModelChanged: onModelChanged,
      onChatBackgroundChanged: onChatBackgroundChanged,
      onPickChatBackgroundImage: onPickChatBackgroundImage,
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
  required Future<void> Function(String sessionId, String title) onRename,
  required Future<void> Function(String sessionId) onArchive,
  required Future<void> Function(String sessionId) onDelete,
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
      onRename: (sessionId, title) async {
        Navigator.pop(sheetContext);
        await onRename(sessionId, title);
      },
      onArchive: (sessionId) async {
        Navigator.pop(sheetContext);
        await onArchive(sessionId);
      },
      onDelete: (sessionId) async {
        Navigator.pop(sheetContext);
        await onDelete(sessionId);
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
    required this.onRename,
    required this.onArchive,
    required this.onDelete,
  });

  final List<RemoteProjectSummary> projects;
  final List<RemoteSessionSummary> sessions;
  final String? activeProjectId;
  final String? activeSessionId;
  final bool running;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onCreate;
  final Future<void> Function(String sessionId, String title) onRename;
  final Future<void> Function(String sessionId) onArchive;
  final Future<void> Function(String sessionId) onDelete;

  @override
  State<SessionNavigatorSheet> createState() => _SessionNavigatorSheetState();
}

class _SessionNavigatorSheetState extends State<SessionNavigatorSheet> {
  late String selectedProjectId =
      widget.activeProjectId ?? widget.projects.first.id;

  RemoteProjectSummary? get selectedProject {
    for (final project in widget.projects) {
      if (project.id == selectedProjectId) return project;
    }
    return widget.projects.isEmpty ? null : widget.projects.first;
  }

  @override
  Widget build(BuildContext context) {
    final projectSessions = widget.sessions
        .where((session) => session.projectId == selectedProjectId)
        .toList();
    final selectedProject = this.selectedProject;
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
              if (selectedProject != null) ...[
                const SizedBox(height: 10),
                Text(
                  selectedProject.path,
                  key: const ValueKey('selected-project-path'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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
                          final canMutate = !widget.running && !item.running;
                          return ListTile(
                            key: ValueKey('session-${item.id}'),
                            enabled: (!widget.running || active) && !item.archived,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: Icon(
                              item.archived
                                  ? Icons.inventory_2_outlined
                                  : item.running
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
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (canMutate)
                                  PopupMenuButton<String>(
                                    key: ValueKey('session-menu-${item.id}'),
                                    onSelected: (value) async {
                                      if (value == 'rename') {
                                        final next = await promptSessionTitle(
                                          context,
                                          initial: item.title,
                                        );
                                        if (next == null || next.trim().isEmpty) {
                                          return;
                                        }
                                        await widget.onRename(item.id, next);
                                        if (mounted) setState(() {});
                                      } else if (value == 'archive') {
                                        await widget.onArchive(item.id);
                                      } else if (value == 'delete') {
                                        final confirmed =
                                            await confirmSessionDelete(
                                              context,
                                              item.title,
                                            );
                                        if (confirmed == true) {
                                          await widget.onDelete(item.id);
                                        }
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      const PopupMenuItem(
                                        value: 'rename',
                                        child: Text('重命名'),
                                      ),
                                      if (!item.archived)
                                        const PopupMenuItem(
                                          value: 'archive',
                                          child: Text('归档'),
                                        ),
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('删除'),
                                      ),
                                    ],
                                  ),
                                if (active)
                                  const Icon(
                                    Icons.check_circle_rounded,
                                    color: AppColors.accent,
                                  )
                                else
                                  const Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                            onTap: active || widget.running || item.archived
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
    required this.chatBackground,
    required this.currentModel,
    required this.selectedModel,
    required this.onReconnect,
    required this.onNotificationsChanged,
    required this.onModelChanged,
    required this.onChatBackgroundChanged,
    required this.onPickChatBackgroundImage,
    required this.onLogout,
  });

  final SavedSession? session;
  final bool notificationsEnabled;
  final ChatBackgroundPreference chatBackground;
  final String? currentModel;
  final ClaudeModelPreference selectedModel;
  final VoidCallback onReconnect;
  final Future<bool> Function(bool) onNotificationsChanged;
  final Future<void> Function(ClaudeModelPreference) onModelChanged;
  final Future<ChatBackgroundPreference> Function(ChatBackgroundPreference)
  onChatBackgroundChanged;
  final Future<ChatBackgroundPreference?> Function(double)
  onPickChatBackgroundImage;
  final VoidCallback onLogout;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late bool notificationsEnabled = widget.notificationsEnabled;
  late ChatBackgroundPreference chatBackground = widget.chatBackground;
  late ClaudeModelPreference selectedModel = widget.selectedModel;
  bool changingNotifications = false;
  bool changingModel = false;

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

  Future<ChatBackgroundPreference> changeChatBackground(
    ChatBackgroundPreference preference,
  ) async {
    final updated = await widget.onChatBackgroundChanged(preference);
    if (mounted) setState(() => chatBackground = updated);
    return updated;
  }

  Future<ChatBackgroundPreference?> pickChatBackgroundImage(
    double overlayOpacity,
  ) async {
    final updated = await widget.onPickChatBackgroundImage(overlayOpacity);
    if (updated != null && mounted) setState(() => chatBackground = updated);
    return updated;
  }

  Future<void> chooseModel() async {
    if (changingModel) return;
    final next = await showClaudeModelPicker(context, selected: selectedModel);
    if (next == null || next == selectedModel || !mounted) return;
    setState(() => changingModel = true);
    try {
      await widget.onModelChanged(next);
      if (mounted) setState(() => selectedModel = next);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('模型设置保存失败，请重试')));
    } finally {
      if (mounted) setState(() => changingModel = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sectionLabelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: AppColors.muted,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.55,
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: GlassPanel(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.82,
            ),
            child: SingleChildScrollView(
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
                  const SizedBox(height: 4),
                  Text('设备与服务', style: sectionLabelStyle),
                  const SizedBox(height: 4),
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
                    value: widget.session?.workspaceDir ??
                        widget.session?.workspaceName ??
                        'cc-remote',
                  ),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 14),
                  Text('对话偏好', style: sectionLabelStyle),
                  const SizedBox(height: 2),
                  ListTile(
                    key: const ValueKey('model-setting'),
                    contentPadding: EdgeInsets.zero,
                    minVerticalPadding: 8,
                    leading: const Icon(Icons.auto_awesome_rounded),
                    title: const Text('模型'),
                    subtitle: Text(
                      modelPreferenceDescription(
                        selectedModel,
                        widget.currentModel == null
                            ? null
                            : formatModelName(widget.currentModel!),
                      ),
                    ),
                    trailing: changingModel
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: changingModel ? null : chooseModel,
                  ),
                  ListTile(
                    key: const ValueKey('chat-background-setting'),
                    contentPadding: EdgeInsets.zero,
                    minVerticalPadding: 8,
                    leading: ChatBackgroundThumbnail(
                      preference: chatBackground,
                    ),
                    title: const Text('聊天背景'),
                    subtitle: Text(chatBackgroundLabel(chatBackground)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showChatBackgroundSheet(
                      context,
                      preference: chatBackground,
                      onChanged: changeChatBackground,
                      onPickImage: pickChatBackgroundImage,
                    ),
                  ),
                  const Divider(),
                  const SizedBox(height: 14),
                  Text('通知', style: sectionLabelStyle),
                  const SizedBox(height: 2),
                  SwitchListTile(
                    key: const ValueKey('background-notifications-toggle'),
                    contentPadding: EdgeInsets.zero,
                    value: notificationsEnabled,
                    onChanged: changingNotifications
                        ? null
                        : changeNotifications,
                    secondary: const Icon(Icons.notifications_active_outlined),
                    title: const Text('后台通知'),
                    subtitle: const Text('任务完成、失败或等待权限时提醒'),
                  ),
                  const Divider(),
                  const SizedBox(height: 14),
                  Text('连接与配对', style: sectionLabelStyle),
                  const SizedBox(height: 10),
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
                          borderRadius: BorderRadius.circular(AppRadii.control),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SignalPressEffect(
                      child: FilledButton.icon(
                        onPressed: () =>
                            confirmLogout(context, widget.onLogout),
                        icon: const Icon(Icons.link_off_rounded),
                        label: const Text('退出配对'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.stop,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<ClaudeModelPreference?> showClaudeModelPicker(
  BuildContext context, {
  required ClaudeModelPreference selected,
}) {
  return showModalBottomSheet<ClaudeModelPreference>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                '选择模型',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            for (final preference in ClaudeModelPreference.values)
              ListTile(
                key: ValueKey(
                  'model-option-${preference.wireName ?? 'follow'}',
                ),
                minTileHeight: 52,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Icon(
                  preference == ClaudeModelPreference.followComputer
                      ? Icons.computer_rounded
                      : Icons.psychology_alt_rounded,
                ),
                title: Text(preference.label),
                subtitle: Text(
                  preference == ClaudeModelPreference.followComputer
                      ? '使用电脑端或 Claude Code 的默认配置'
                      : '用于后续消息',
                ),
                selected: preference == selected,
                trailing: preference == selected
                    ? const Icon(
                        Icons.check_circle_rounded,
                        color: AppColors.accent,
                      )
                    : null,
                onTap: () => Navigator.pop(context, preference),
              ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showChatBackgroundSheet(
  BuildContext context, {
  required ChatBackgroundPreference preference,
  required Future<ChatBackgroundPreference> Function(ChatBackgroundPreference)
  onChanged,
  required Future<ChatBackgroundPreference?> Function(double) onPickImage,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => ChatBackgroundSheet(
      preference: preference,
      onChanged: onChanged,
      onPickImage: onPickImage,
    ),
  );
}

class ChatBackgroundSheet extends StatefulWidget {
  const ChatBackgroundSheet({
    super.key,
    required this.preference,
    required this.onChanged,
    required this.onPickImage,
  });

  final ChatBackgroundPreference preference;
  final Future<ChatBackgroundPreference> Function(ChatBackgroundPreference)
  onChanged;
  final Future<ChatBackgroundPreference?> Function(double) onPickImage;

  @override
  State<ChatBackgroundSheet> createState() => _ChatBackgroundSheetState();
}

class _ChatBackgroundSheetState extends State<ChatBackgroundSheet> {
  late ChatBackgroundPreference preference = widget.preference;
  late ChatBackgroundPreference savedPreference = widget.preference;
  bool changing = false;

  Future<void> apply(ChatBackgroundPreference next) async {
    if (changing || next == savedPreference) {
      setState(() => preference = next);
      return;
    }
    setState(() {
      changing = true;
      preference = next;
    });
    try {
      final updated = await widget.onChanged(next);
      if (!mounted) return;
      setState(() {
        preference = updated;
        savedPreference = updated;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => preference = savedPreference);
      showBackgroundError('背景保存失败，请重试');
    } finally {
      if (mounted) setState(() => changing = false);
    }
  }

  Future<void> pickImage() async {
    if (changing) return;
    setState(() => changing = true);
    try {
      final updated = await widget.onPickImage(preference.overlayOpacity);
      if (updated == null || !mounted) return;
      setState(() {
        preference = updated;
        savedPreference = updated;
      });
    } catch (_) {
      if (mounted) showBackgroundError('无法读取这张图片，请换一张重试');
    } finally {
      if (mounted) setState(() => changing = false);
    }
  }

  void showBackgroundError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final options = <(String, ChatBackgroundPreference)>[
      ('默认', ChatBackgroundPreference.defaultValue),
      ('薄荷', const ChatBackgroundPreference.preset(ChatBackgroundPreset.mint)),
      (
        '晨光',
        const ChatBackgroundPreference.preset(ChatBackgroundPreset.sunrise),
      ),
      ('陶粉', const ChatBackgroundPreference.preset(ChatBackgroundPreset.rose)),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 24, 14, 14),
        child: GlassPanel(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '聊天背景',
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
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ChatBackgroundPreview(preference: preference),
                        const SizedBox(height: 18),
                        const Text(
                          '内置背景',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final width = (constraints.maxWidth - 24) / 4;
                            return Row(
                              children: [
                                for (
                                  var index = 0;
                                  index < options.length;
                                  index++
                                ) ...[
                                  ChatBackgroundChoice(
                                    width: width,
                                    label: options[index].$1,
                                    preference: options[index].$2,
                                    selected:
                                        preference.kind ==
                                            options[index].$2.kind &&
                                        preference.preset ==
                                            options[index].$2.preset,
                                    onPressed: changing
                                        ? null
                                        : () => apply(options[index].$2),
                                  ),
                                  if (index != options.length - 1)
                                    const SizedBox(width: 8),
                                ],
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            key: const ValueKey('pick-chat-background-image'),
                            onPressed: changing ? null : pickImage,
                            icon: changing
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.photo_library_outlined),
                            label: const Text('从相册选择'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (preference.kind ==
                            ChatBackgroundKind.localImage) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  '图片淡化',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                              ),
                              Text(
                                '${(preference.overlayOpacity * 100).round()}%',
                                style: const TextStyle(
                                  color: AppColors.muted,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                          Slider(
                            key: const ValueKey(
                              'chat-background-opacity-slider',
                            ),
                            value: preference.overlayOpacity,
                            min: 0.16,
                            max: 0.64,
                            divisions: 12,
                            label:
                                '${(preference.overlayOpacity * 100).round()}%',
                            onChanged: changing
                                ? null
                                : (value) => setState(
                                    () => preference = preference.copyWith(
                                      overlayOpacity: value,
                                    ),
                                  ),
                            onChangeEnd: changing
                                ? null
                                : (value) => apply(
                                    preference.copyWith(overlayOpacity: value),
                                  ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Center(
                          child: TextButton.icon(
                            key: const ValueKey('reset-chat-background'),
                            onPressed:
                                changing ||
                                    savedPreference.kind ==
                                        ChatBackgroundKind.defaultStyle
                                ? null
                                : () => apply(
                                    ChatBackgroundPreference.defaultValue,
                                  ),
                            icon: const Icon(Icons.restart_alt_rounded),
                            label: const Text('恢复默认背景'),
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Center(
                          child: Text(
                            '图片只保存在这台手机，不会上传到电脑端',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatBackgroundChoice extends StatelessWidget {
  const ChatBackgroundChoice({
    super.key,
    required this.width,
    required this.label,
    required this.preference,
    required this.selected,
    required this.onPressed,
  });

  final double width;
  final String label;
  final ChatBackgroundPreference preference;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '背景：$label',
      child: SizedBox(
        width: width,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : AppMotion.fast,
                  width: width,
                  height: 64,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected ? AppColors.accent : AppColors.line,
                      width: selected ? 2.5 : 1.25,
                    ),
                  ),
                  child: _ChatBackgroundLayer(
                    preference: preference,
                    cacheWidth: 240,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatBackgroundPreview extends StatelessWidget {
  const ChatBackgroundPreview({super.key, required this.preference});

  final ChatBackgroundPreference preference;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '当前聊天背景预览',
      image: true,
      child: Container(
        height: 164,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.ink, width: 1.25),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _ChatBackgroundLayer(preference: preference, cacheWidth: 900),
            const Padding(
              padding: EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: _PreviewBubble(
                      color: AppColors.yellowSoft,
                      width: 138,
                    ),
                  ),
                  SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _PreviewBubble(
                      color: AppColors.porcelain,
                      width: 188,
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

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 46,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.ink, width: 1.1),
      ),
    );
  }
}

class ChatBackgroundThumbnail extends StatelessWidget {
  const ChatBackgroundThumbnail({super.key, required this.preference});

  final ChatBackgroundPreference preference;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.ink, width: 1.2),
      ),
      child: _ChatBackgroundLayer(preference: preference, cacheWidth: 160),
    );
  }
}

String chatBackgroundLabel(ChatBackgroundPreference preference) {
  return switch (preference.kind) {
    ChatBackgroundKind.defaultStyle => '默认纸感',
    ChatBackgroundKind.localImage => '自定义图片',
    ChatBackgroundKind.preset => switch (preference.preset) {
      ChatBackgroundPreset.mint => '薄荷纸感',
      ChatBackgroundPreset.sunrise => '晨光纸感',
      ChatBackgroundPreset.rose => '陶粉纸感',
      null => '内置背景',
    },
  };
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
    this.running = false,
    required this.pendingPermissions,
    required this.respondingPermissionIds,
    required this.connected,
    required this.onFillPrompt,
    required this.onReconnect,
    required this.onPermissionAllow,
    required this.onPermissionDeny,
  });

  final List<TranscriptMessage> messages;
  final SavedSession? session;
  final String? activeSessionId;
  final bool running;
  final List<RemotePermissionRequest> pendingPermissions;
  final Set<String> respondingPermissionIds;
  final bool connected;
  final ValueChanged<String> onFillPrompt;
  final VoidCallback onReconnect;
  final ValueChanged<RemotePermissionRequest> onPermissionAllow;
  final ValueChanged<RemotePermissionRequest> onPermissionDeny;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && pendingPermissions.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 1, 2, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    if (connected) ...[
                      const Text(
                        '下一件事',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.65,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '从下方输入，或先点一个快捷任务',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            flex: 7,
                            child: PromptChip(
                              tone: AppColors.yellow,
                              icon: Icons.arrow_outward_rounded,
                              label: '检查项目',
                              caption: '看看哪里需要处理',
                              onTap: () => onFillPrompt('检查这个项目'),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            flex: 5,
                            child: PromptChip(
                              tone: AppColors.coralSoft,
                              icon: Icons.bolt_rounded,
                              label: '运行测试',
                              caption: '跑完告诉我结果',
                              onTap: () => onFillPrompt('运行测试并总结结果'),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      SizedBox(
                        height: (constraints.maxHeight - 14).clamp(
                          224.0,
                          320.0,
                        ),
                        child: _OfflineReconnectCard(onReconnect: onReconnect),
                      ),
                    ],
                  ],
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
            streaming:
                running &&
                item.role == MessageRole.assistant &&
                identical(item, messages.isNotEmpty ? messages.last : null),
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

class _OfflineReconnectCard extends StatelessWidget {
  const _OfflineReconnectCard({required this.onReconnect});

  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onReconnect,
        borderRadius: BorderRadius.circular(26),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(17, 16, 15, 15),
          decoration: BoxDecoration(
            color: AppColors.coralSoft,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: AppColors.ink, width: 1.6),
            boxShadow: const [
              BoxShadow(
                color: AppColors.mint,
                blurRadius: 0,
                offset: Offset(4, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: AppColors.yellow,
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: AppColors.ink, width: 1.4),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.power_rounded, size: 24),
                  ),
                  const Spacer(),
                  Transform.rotate(
                    angle: 0.045,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.porcelain,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: AppColors.ink, width: 1.2),
                      ),
                      child: const Text(
                        '连接任务',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                '让电脑重新上线',
                style: TextStyle(
                  fontSize: 22,
                  height: 1.05,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: 7),
              const Text(
                '在电脑端重新运行 CC Remote，手机会自动接回这次会话。',
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: 12.5,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '会话和输入内容都会保留',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.ink,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '重新连接',
                          style: TextStyle(
                            color: AppColors.porcelain,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(width: 5),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 16,
                          color: AppColors.mint,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
    final tool = request.toolName.toLowerCase();
    final riskTone = tool.contains('write') || tool.contains('edit')
        ? AppColors.stop
        : tool.contains('bash') || tool.contains('shell')
        ? AppColors.warning
        : AppColors.accent;
    return Container(
      key: ValueKey('permission-request-${request.requestId}'),
      decoration: BoxDecoration(
        color: AppColors.coral,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.ink, width: 1.8),
        boxShadow: const [
          BoxShadow(color: AppColors.ink, blurRadius: 0, offset: Offset(4, 5)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.yellow,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.ink, width: 1.5),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    size: 19,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '需要你的小小确认',
                        style: TextStyle(
                          fontSize: 18,
                          height: 1,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Text(
                            '等待权限确认',
                            style: TextStyle(
                              color: AppColors.ink,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Text(
                            ' · ',
                            style: TextStyle(
                              color: AppColors.ink,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Flexible(
                            child: Text(
                              request.displayName ?? request.toolName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: riskTone,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: AppColors.code,
                  borderRadius: BorderRadius.circular(AppRadii.compact),
                  border: Border.all(color: const Color(0xFF2B3A3F)),
                ),
                child: SelectableText(
                  request.detail!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SignalPressEffect(
                    enabled: enabled,
                    child: OutlinedButton(
                      onPressed: enabled ? onDeny : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.ink,
                        backgroundColor: AppColors.porcelain,
                        side: const BorderSide(
                          color: AppColors.ink,
                          width: 1.4,
                        ),
                      ),
                      child: const Text('拒绝'),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: SignalPressEffect(
                    enabled: enabled,
                    child: FilledButton(
                      onPressed: enabled ? onAllow : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.ink,
                        foregroundColor: AppColors.porcelain,
                      ),
                      child: const Text('允许一次'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
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
    this.streaming = false,
  });

  final TranscriptMessage message;
  final SavedSession? session;
  final String? activeSessionId;
  final bool streaming;

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
      // ponytail: plain text while streaming; markdown only after done
      final assistantBody = streaming
          ? SelectableText(
              message.text,
              style: const TextStyle(
                height: 1.55,
                fontSize: 15,
                color: AppColors.ink,
              ),
            )
          : MarkdownBody(
              data: message.text,
              selectable: true,
              softLineBreak: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
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
                    tableColumnWidth: const IntrinsicColumnWidth(),
                    tableCellsPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    codeblockPadding: const EdgeInsets.all(12),
                    codeblockDecoration: BoxDecoration(
                      color: AppColors.porcelainMuted,
                      borderRadius: BorderRadius.circular(AppRadii.compact),
                      border: Border.all(color: AppColors.line),
                    ),
                    blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
                    blockquoteDecoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: AppColors.accent, width: 2),
                      ),
                    ),
                  ),
            );
      return AssistantBubbleFrame(
        bubbleKey: const ValueKey('assistant-message'),
        child: assistantBody,
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
            color: AppColors.accentSoft.withValues(alpha: 0.76),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppRadii.bubble),
              topRight: Radius.circular(AppRadii.bubble),
              bottomLeft: Radius.circular(AppRadii.bubble),
              bottomRight: Radius.circular(6),
            ),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.14)),
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
        color: AppColors.porcelainMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
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
                    : const EdgeInsets.fromLTRB(15, 12, 16, 13),
                decoration: BoxDecoration(
                  color: AppColors.porcelainMuted,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(7),
                    topRight: Radius.circular(AppRadii.bubble),
                    bottomLeft: Radius.circular(AppRadii.bubble),
                    bottomRight: Radius.circular(AppRadii.bubble),
                  ),
                  border: Border.all(color: AppColors.line),
                  boxShadow: compact
                      ? [
                          BoxShadow(
                            color: AppColors.shadow.withValues(alpha: 0.035),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
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

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('assistant-avatar'),
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.ink, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: AppColors.coral.withValues(alpha: 0.9),
            blurRadius: 0,
            offset: const Offset(2, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset(
          'assets/claude_mascot.png',
          fit: BoxFit.cover,
          filterQuality: FilterQuality.none,
          semanticLabel: 'Claude 吉祥物',
        ),
      ),
    );
  }
}

Map<String, Object> buildPromptMessage({
  required String text,
  required Iterable<String> attachmentIds,
  required PermissionMode permissionMode,
  required String sessionId,
  required ClaudeModelPreference model,
}) {
  final attachments = attachmentIds.toList(growable: false);
  return {
    'type': 'prompt',
    'text': text,
    if (attachments.isNotEmpty) 'attachmentIds': attachments,
    'permissionMode': permissionMode.wireName,
    'sessionId': sessionId,
    'model': ?model.wireName,
  };
}

class ActivityBlock extends StatelessWidget {
  const ActivityBlock({super.key, required this.message});

  final TranscriptMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.activityKind == ActivityKind.thinking) {
      if (message.activityState == ActivityState.running) {
        return const TaskRailFrame(
          color: AppColors.accent,
          active: true,
          compact: true,
          child: AssistantBubbleFrame(
            bubbleKey: ValueKey('thinking-bubble'),
            compact: true,
            child: ThinkingIndicator(),
          ),
        );
      }
      final thinkingTone = message.activityState == ActivityState.error
          ? AppColors.stop
          : AppColors.success;
      return TaskRailFrame(
        color: thinkingTone,
        compact: true,
        child: AssistantBubbleFrame(
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
                color: thinkingTone,
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
        ),
      );
    }

    final railTone = switch (message.activityState) {
      ActivityState.running => AppColors.accent,
      ActivityState.done => AppColors.success,
      ActivityState.error => AppColors.stop,
      ActivityState.stopped => AppColors.muted,
      null => AppColors.muted,
    };

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
      return TaskRailFrame(
        color: railTone,
        active: message.activityState == ActivityState.running,
        child: Material(
          color: AppColors.porcelain,
          shape: const SignalCutCornerBorder(),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 13, 10),
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
          ),
        ),
      );
    }

    if (detail == null || detail.isEmpty) {
      return TaskRailFrame(
        color: railTone,
        active: message.activityState == ActivityState.running,
        compact: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 5, 5, 5),
          child: Row(
            children: [
              SizedBox(width: 22, child: Center(child: icon)),
              const SizedBox(width: 6),
              Expanded(child: title),
            ],
          ),
        ),
      );
    }

    return TaskRailFrame(
      color: railTone,
      active: message.activityState == ActivityState.running,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          color: AppColors.porcelain,
          shape: const SignalCutCornerBorder(),
          clipBehavior: Clip.antiAlias,
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
  var reduceMotion = false;

  @override
  void initState() {
    super.initState();
    animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => elapsedSeconds += 1);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextReduceMotion = MediaQuery.disableAnimationsOf(context);
    if (nextReduceMotion == reduceMotion && animation.isAnimating) return;
    reduceMotion = nextReduceMotion;
    if (reduceMotion) {
      animation
        ..stop()
        ..value = 0.5;
    } else if (!animation.isAnimating) {
      animation.repeat(reverse: true);
    }
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
    this.stopping = false,
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
  final bool stopping;
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
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: MediaQuery.textScalerOf(
          context,
        ).clamp(minScaleFactor: 1, maxScaleFactor: 1.3),
      ),
      child: ValueListenableBuilder<TextEditingValue>(
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
                const SizedBox(height: 6),
              ],
              Container(
                padding: const EdgeInsets.fromLTRB(9, 7, 8, 7),
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.ink, width: 1.5),
                  boxShadow: const [
                    BoxShadow(
                      color: AppColors.coral,
                      blurRadius: 0,
                      offset: Offset(4, 5),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        PermissionModeChip(
                          mode: permissionMode,
                          enabled: !running && !uploading,
                          inverted: true,
                          onPressed: () => showPermissionModePicker(
                            context,
                            selected: permissionMode,
                            allowBypassPermissions: allowBypassPermissions,
                            onSelected: onPermissionModeSelected,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          stopping
                              ? '正在停止任务'
                              : running
                              ? '信号传输中'
                              : uploading
                              ? '正在上传'
                              : connected
                              ? '命令就绪'
                              : offline
                              ? '连接已中断'
                              : '正在握手',
                          style: TextStyle(
                            color: stopping
                                ? AppColors.warning
                                : running || connected
                                ? AppColors.accent
                                : offline
                                ? AppColors.stop
                                : AppColors.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 7),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: SignalTrack(
                        color: stopping
                            ? AppColors.warning
                            : running || connected
                            ? AppColors.accent
                            : offline
                            ? AppColors.stop
                            : AppColors.warning,
                        active: (running && !stopping) || uploading,
                        broken: offline,
                      ),
                    ),
                    if (attachments.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      PendingAttachmentStrip(
                        attachments: attachments,
                        uploading: uploading,
                        onRemove: (attachment) =>
                            onRemoveAttachment?.call(attachment),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: IconButton(
                            onPressed: running || uploading || !connected
                                ? null
                                : onAddAttachment,
                            icon: const Icon(
                              Icons.add_circle_outline_rounded,
                              size: 20,
                            ),
                            tooltip: '添加附件',
                            color: AppColors.accent,
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            enabled: !running && !uploading,
                            cursorColor: AppColors.mint,
                            style: const TextStyle(
                              color: AppColors.porcelain,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            minLines: 1,
                            maxLines: 3,
                            decoration: InputDecoration(
                              filled: false,
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
                                color: AppColors.codeMuted.withValues(
                                  alpha: 0.92,
                                ),
                                fontSize: 14,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (running)
                          SignalPressEffect(
                            enabled: !stopping,
                            child: SizedBox(
                              height: 40,
                              child: FilledButton.icon(
                                onPressed: stopping ? null : onStop,
                                icon: stopping
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.stop_rounded, size: 18),
                                label: Text(stopping ? '停止中' : '停止'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: stopping
                                      ? AppColors.warning
                                      : AppColors.stop,
                                  disabledBackgroundColor: AppColors.warning,
                                  disabledForegroundColor: Colors.white,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.control,
                                    ),
                                  ),
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
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                              ),
                            ),
                          )
                        else
                          SignalPressEffect(
                            enabled: canSend,
                            child: SizedBox(
                              width: 40,
                              height: 40,
                              child: IconButton.filled(
                                onPressed: canSend ? onSend : null,
                                icon: const Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 19,
                                ),
                                tooltip: '发送',
                                style: IconButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  disabledBackgroundColor: AppColors.line,
                                  foregroundColor: AppColors.ink,
                                  fixedSize: const Size.square(40),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
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
              color: AppColors.porcelainMuted,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: AppColors.line),
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

extension PermissionModePresentation on PermissionMode {
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
}

class PermissionModeChip extends StatelessWidget {
  const PermissionModeChip({
    super.key,
    required this.mode,
    required this.enabled,
    required this.onPressed,
    this.inverted = false,
  });

  final PermissionMode mode;
  final bool enabled;
  final VoidCallback onPressed;
  final bool inverted;

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
            color: enabled
                ? inverted
                      ? const Color(0xFF2A2A27)
                      : AppColors.porcelainMuted
                : AppColors.line.withValues(alpha: 0.54),
            borderRadius: BorderRadius.circular(AppRadii.pill),
            border: Border.all(
              color: inverted
                  ? Colors.white.withValues(alpha: 0.12)
                  : tone.withValues(alpha: 0.16),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(mode.icon, size: 15, color: tone),
              const SizedBox(width: 6),
              Text(
                mode.label,
                style: TextStyle(
                  color: danger
                      ? AppColors.stop
                      : inverted
                      ? AppColors.porcelain
                      : AppColors.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: inverted
                    ? AppColors.codeMuted
                    : AppColors.muted.withValues(alpha: 0.8),
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
  const ScanFrame({super.key, required this.child, this.compact = false});

  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.porcelain,
        borderRadius: BorderRadius.circular(compact ? 20 : 30),
        border: Border.all(color: AppColors.ink, width: 1.8),
        boxShadow: [
          BoxShadow(
            color: AppColors.yellow,
            blurRadius: 0,
            offset: Offset(compact ? 5 : 7, compact ? 6 : 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 18 : 28),
        child: Stack(
          children: [
            Center(child: child),
            Positioned(
              top: compact ? 10 : 14,
              left: compact ? 10 : 14,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 10,
                  vertical: compact ? 4 : 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.mintSoft,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  border: Border.all(color: AppColors.ink, width: 1.2),
                ),
                child: Text(
                  '对准二维码',
                  style: TextStyle(
                    fontSize: compact ? 10 : 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            Positioned(
              top: compact ? 12 : 18,
              right: compact ? 12 : 18,
              child: RotatedBox(
                quarterTurns: 1,
                child: ScanCorner(compact: compact),
              ),
            ),
            Positioned(
              bottom: compact ? 12 : 18,
              right: compact ? 12 : 18,
              child: RotatedBox(
                quarterTurns: 2,
                child: ScanCorner(compact: compact),
              ),
            ),
            Positioned(
              bottom: compact ? 12 : 18,
              left: compact ? 12 : 18,
              child: RotatedBox(
                quarterTurns: 3,
                child: ScanCorner(compact: compact),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScanCorner extends StatelessWidget {
  const ScanCorner({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: compact ? 22 : 34,
      height: compact ? 22 : 34,
      child: const DecoratedBox(
        decoration: BoxDecoration(
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
  const AppBackground({
    super.key,
    required this.child,
    this.chatBackground = ChatBackgroundPreference.defaultValue,
  });

  final Widget child;
  final ChatBackgroundPreference chatBackground;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: AppColors.bgMid,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: const ValueKey('chat-background-layer'),
            child: _ChatBackgroundLayer(preference: chatBackground),
          ),
          _KeyboardResizeBody(child: child),
        ],
      ),
    );
  }
}

class _ChatBackgroundLayer extends StatelessWidget {
  const _ChatBackgroundLayer({required this.preference, this.cacheWidth});

  final ChatBackgroundPreference preference;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    if (preference.kind == ChatBackgroundKind.localImage &&
        preference.imagePath != null) {
      final width =
          cacheWidth ??
          (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context))
              .round()
              .clamp(720, 2160)
              .toInt();
      return Stack(
        fit: StackFit.expand,
        children: [
          const _DecorativeBackground(
            backgroundColor: AppColors.bgMid,
            topColor: AppColors.mintSoft,
            bottomColor: AppColors.yellowSoft,
          ),
          Semantics(
            excludeSemantics: true,
            child: Image.file(
              File(preference.imagePath!),
              key: const ValueKey('custom-chat-background-image'),
              fit: BoxFit.cover,
              cacheWidth: width,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const _DecorativeBackground(
                backgroundColor: AppColors.bgMid,
                topColor: AppColors.mintSoft,
                bottomColor: AppColors.yellowSoft,
              ),
            ),
          ),
          ColoredBox(
            color: Colors.white.withValues(alpha: preference.overlayOpacity),
          ),
        ],
      );
    }
    final colors = switch (preference.preset) {
      ChatBackgroundPreset.mint => const (
        background: Color(0xFFE8F7EF),
        top: Color(0xFFC8F3DF),
        bottom: Color(0xFFFFF0B8),
      ),
      ChatBackgroundPreset.sunrise => const (
        background: Color(0xFFFFF4DE),
        top: Color(0xFFFFD8C8),
        bottom: Color(0xFFFFE99A),
      ),
      ChatBackgroundPreset.rose => const (
        background: Color(0xFFF7E9E4),
        top: Color(0xFFFFD2C4),
        bottom: Color(0xFFD9F1E6),
      ),
      null => const (
        background: AppColors.bgMid,
        top: AppColors.mintSoft,
        bottom: AppColors.yellowSoft,
      ),
    };
    return _DecorativeBackground(
      backgroundColor: colors.background,
      topColor: colors.top,
      bottomColor: colors.bottom,
    );
  }
}

class _DecorativeBackground extends StatelessWidget {
  const _DecorativeBackground({
    required this.backgroundColor,
    required this.topColor,
    required this.bottomColor,
  });

  final Color backgroundColor;
  final Color topColor;
  final Color bottomColor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: backgroundColor),
        Positioned(
          right: -74,
          top: -86,
          child: Container(
            width: 210,
            height: 210,
            decoration: BoxDecoration(color: topColor, shape: BoxShape.circle),
          ),
        ),
        Positioned(
          left: -92,
          bottom: 54,
          child: Container(
            width: 190,
            height: 190,
            decoration: BoxDecoration(
              color: bottomColor,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }
}

class _KeyboardResizeBody extends StatelessWidget {
  const _KeyboardResizeBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: child,
      ),
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
        color: AppColors.porcelain,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppColors.ink, width: 1.25),
        boxShadow: [
          BoxShadow(
            color: AppColors.ink.withValues(alpha: 0.09),
            blurRadius: 0,
            offset: const Offset(3, 4),
          ),
          BoxShadow(
            color: AppColors.ink.withValues(alpha: 0.055),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 1),
        child: ColoredBox(
          color: AppColors.porcelain,
          child: Padding(
            padding: padding,
            child: SizedBox(width: double.infinity, child: child),
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
    return SignalPressEffect(
      enabled: onPressed != null,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
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
    this.caption,
    this.tone = AppColors.porcelain,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final String? caption;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          decoration: BoxDecoration(
            color: tone,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.ink, width: 1.4),
            boxShadow: [
              BoxShadow(
                color: AppColors.ink.withValues(alpha: 0.12),
                blurRadius: 0,
                offset: const Offset(3, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null)
                    Container(
                      width: 31,
                      height: 31,
                      decoration: BoxDecoration(
                        color: AppColors.porcelain,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.ink, width: 1.2),
                      ),
                      alignment: Alignment.center,
                      child: Icon(icon, size: 17, color: AppColors.ink),
                    ),
                  const Spacer(),
                  const Icon(
                    Icons.north_east_rounded,
                    size: 17,
                    color: AppColors.ink,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.25,
                ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 3),
                Text(
                  caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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

Future<String?> promptSessionTitle(
  BuildContext context, {
  required String initial,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        key: const ValueKey('rename-session-field'),
        controller: controller,
        autofocus: true,
        maxLength: 48,
        decoration: const InputDecoration(hintText: '会话标题'),
        onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('rename-session-confirm'),
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

Future<bool?> confirmSessionDelete(BuildContext context, String title) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除会话？'),
      content: Text('将删除「$title」及其 transcript，不可恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('delete-session-confirm'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
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
