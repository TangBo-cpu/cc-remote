import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'attachments.dart';
import 'camera_permission.dart';
import 'chat_background.dart';
import 'data/api_client.dart';
import 'data/permission_mode.dart';
import 'data/remote_models.dart';
import 'data/websocket_client.dart';
import 'model_preference.dart';
import 'notification_service.dart';
import 'reading_font_size.dart';
import 'signal_console_theme.dart';
import 'workspace_drawer.dart';

void main() {
  runApp(const CcRemoteApp());
}

/// Keep a healthy chat socket across app resume / picker returns.
/// Manual reconnect and offline recovery still force a new connection.
bool shouldPreserveLiveWebSocket({
  required bool forceReconnect,
  required bool wsReady,
  required bool remoteOffline,
  required bool hasChannel,
}) {
  return !forceReconnect && wsReady && !remoteOffline && hasChannel;
}

class CcRemoteApp extends StatefulWidget {
  const CcRemoteApp({
    super.key,
    this.enableCamera = true,
    this.demoMode = false,
    this.notificationService,
    this.notificationPreferenceStore,
    this.modelPreferenceStore,
    this.chatBackgroundPreferenceStore,
    this.readingFontSizePreferenceStore,
    this.chatBackgroundImageService,
    this.cameraPermissionService,
  });

  final bool enableCamera;
  final bool demoMode;
  final BackgroundNotificationService? notificationService;
  final NotificationPreferenceStore? notificationPreferenceStore;
  final ClaudeModelPreferenceStore? modelPreferenceStore;
  final ChatBackgroundPreferenceStore? chatBackgroundPreferenceStore;
  final ReadingFontSizePreferenceStore? readingFontSizePreferenceStore;
  final ChatBackgroundImageService? chatBackgroundImageService;
  final CameraPermissionService? cameraPermissionService;

  @override
  State<CcRemoteApp> createState() => _CcRemoteAppState();
}

class _CcRemoteAppState extends State<CcRemoteApp> {
  late final ReadingFontSizePreferenceStore readingFontSizePreferenceStore;
  final ValueNotifier<double> readingFontScale = ValueNotifier(
    kReadingFontScaleDefault,
  );
  int readingFontSizeRevision = 0;

  @override
  void initState() {
    super.initState();
    readingFontSizePreferenceStore =
        widget.readingFontSizePreferenceStore ??
        ReadingFontSizePreferenceStore();
    unawaited(initializeReadingFontSize());
  }

  @override
  void dispose() {
    readingFontScale.dispose();
    super.dispose();
  }

  Future<void> initializeReadingFontSize() async {
    final revision = readingFontSizeRevision;
    final scale = await readingFontSizePreferenceStore.load();
    if (!mounted || revision != readingFontSizeRevision) return;
    readingFontScale.value = scale;
  }

  Future<void> setReadingFontScale(double scale, {bool persist = true}) async {
    final snapped = snapReadingFontScale(scale);
    readingFontSizeRevision += 1;
    readingFontScale.value = snapped;
    if (!persist) return;
    await readingFontSizePreferenceStore.save(snapped);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CC Remote',
      debugShowCheckedModeBanner: false,
      theme: buildSignalConsoleTheme(),
      builder: (context, child) {
        return ValueListenableBuilder<double>(
          valueListenable: readingFontScale,
          builder: (context, scale, _) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(
                textScaler: multiplyReadingTextScaler(media.textScaler, scale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
        );
      },
      home: DemoShell(
        enableCamera: widget.enableCamera,
        demoMode: widget.demoMode,
        notificationService: widget.notificationService,
        notificationPreferenceStore: widget.notificationPreferenceStore,
        modelPreferenceStore: widget.modelPreferenceStore,
        chatBackgroundPreferenceStore: widget.chatBackgroundPreferenceStore,
        chatBackgroundImageService: widget.chatBackgroundImageService,
        cameraPermissionService: widget.cameraPermissionService,
        readingFontScaleListenable: readingFontScale,
        onReadingFontScaleChanged: setReadingFontScale,
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
    this.cameraPermissionService,
    ValueListenable<double>? readingFontScaleListenable,
    Future<void> Function(double scale, {bool persist})?
    onReadingFontScaleChanged,
  }) : readingFontScaleListenable =
           readingFontScaleListenable ??
           const _StaticReadingFontScaleListenable(kReadingFontScaleDefault),
       onReadingFontScaleChanged =
           onReadingFontScaleChanged ?? _noopReadingFontScaleChanged;

  final bool enableCamera;
  final bool demoMode;
  final BackgroundNotificationService? notificationService;
  final NotificationPreferenceStore? notificationPreferenceStore;
  final ClaudeModelPreferenceStore? modelPreferenceStore;
  final ChatBackgroundPreferenceStore? chatBackgroundPreferenceStore;
  final ChatBackgroundImageService? chatBackgroundImageService;
  final CameraPermissionService? cameraPermissionService;
  final ValueListenable<double> readingFontScaleListenable;
  final Future<void> Function(double scale, {bool persist})
  onReadingFontScaleChanged;

  static Future<void> _noopReadingFontScaleChanged(
    double _, {
    bool persist = true,
  }) async {}

  @override
  State<DemoShell> createState() => _DemoShellState();
}

class _StaticReadingFontScaleListenable implements ValueListenable<double> {
  const _StaticReadingFontScaleListenable(this.value);

  @override
  final double value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _DemoShellState extends State<DemoShell> with WidgetsBindingObserver {
  static const networkTimeout = Duration(seconds: 12);
  static const interruptedRunMessage = '上次任务可能仍在电脑端运行，请重连确认';
  static const disconnectedRunMessage = '连接已断开，正在等待电脑端状态';
  static const sessionScopedMessageTypes = <String>{
    'status',
    'prompt_accepted',
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
    'prompt_accepted',
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
  DateTime? runStartedAt;
  int remoteTranscriptRevision = 0;
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
  Future<void>? refreshConnectionInFlight;
  bool refreshConnectionForcesReconnect = false;
  int connectionRefreshGeneration = 0;
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
  late final CameraPermissionService cameraPermissionService;
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
    cameraPermissionService =
        widget.cameraPermissionService ?? const SystemCameraPermissionService();
    notificationController = BackgroundNotificationController(
      service: notificationService,
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(initializePermissions());
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
    // Notification shade / attachment pickers also resume the app. Keep a
    // healthy socket; only force-reconnect when already offline.
    unawaited(refreshConnection(forceReconnect: false));
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

  Future<void> initializePermissions() async {
    await requestInitialCameraPermission();
    await initializeNotifications();
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

  Future<void> openModelPicker(BuildContext context) async {
    final next = await showClaudeModelPicker(context, selected: selectedModel);
    if (next == null || next == selectedModel || !context.mounted) return;
    try {
      await setModelPreference(next);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('模型设置保存失败，请重试')));
    }
  }

  Future<void> initializeChatBackground() async {
    final revision = chatBackgroundRevision;
    final preference = await chatBackgroundPreferenceStore.load();
    if (!mounted || revision != chatBackgroundRevision) return;
    setState(() => chatBackground = preference);
  }

  Future<void> requestInitialCameraPermission() async {
    if (!widget.enableCamera || widget.demoMode) return;
    try {
      if (await cameraPermissionService.shouldRequestOnLaunch()) {
        await cameraPermissionService.request();
      }
    } catch (_) {}
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

  Future<void> refreshConnection({bool forceReconnect = true}) {
    final inFlight = refreshConnectionInFlight;
    if (inFlight != null) {
      if (!forceReconnect || refreshConnectionForcesReconnect) {
        return inFlight;
      }
      // Soft probe is already running; ensure a forced reconnect follows it.
      late final Future<void> forced;
      forced = inFlight
          .then((_) {
            if (!mounted) return Future<void>.value();
            return _refreshConnection(forceReconnect: true);
          })
          .whenComplete(() {
            if (identical(refreshConnectionInFlight, forced)) {
              refreshConnectionInFlight = null;
              refreshConnectionForcesReconnect = false;
            }
          });
      refreshConnectionInFlight = forced;
      refreshConnectionForcesReconnect = true;
      return forced;
    }
    late final Future<void> operation;
    operation = _refreshConnection(forceReconnect: forceReconnect).whenComplete(
      () {
        if (identical(refreshConnectionInFlight, operation)) {
          refreshConnectionInFlight = null;
          refreshConnectionForcesReconnect = false;
        }
      },
    );
    refreshConnectionInFlight = operation;
    refreshConnectionForcesReconnect = forceReconnect;
    return operation;
  }

  Future<void> _refreshConnection({required bool forceReconnect}) async {
    final current = session;
    if (widget.demoMode || route != ShellRoute.chat || current == null) return;

    final generation = connectionRefreshGeneration;
    final keepLiveSocket = shouldPreserveLiveWebSocket(
      forceReconnect: forceReconnect,
      wsReady: wsReady,
      remoteOffline: remoteOffline,
      hasChannel: wsClient.channel != null,
    );
    if (!keepLiveSocket) {
      setState(() {
        wsReady = false;
        remoteOffline = false;
      });
    }

    try {
      final status = await fetchStatus(current);
      if (!mounted ||
          session != current ||
          generation != connectionRefreshGeneration) {
        return;
      }
      final restored = current.copyWith(
        deviceName: status.deviceName,
        workspaceDir: status.workspaceDir,
      );
      setState(() {
        session = restored;
        remoteOffline = false;
        // Live WS is authoritative for run/model; soft resume only refreshes
        // catalog/device metadata so a delayed /api/status cannot clobber it.
        if (!keepLiveSocket) {
          running = status.running;
          stopping = status.running && status.stopping;
          activeRunId = status.running ? status.runId : null;
          runStartedAt = status.running ? status.startedAt : null;
          if (status.hasSessionInfo) {
            modelName = status.modelName;
            contextWindow = status.contextWindow;
            remainingContext = status.remainingContext;
          }
          if (!status.running) removeInterruptedRunNotice();
        }
        applyCatalog(status.catalog);
      });
      persistTranscriptSnapshotLater();
      if (!forceReconnect && wsClient.channel != null) return;
      if (generation != connectionRefreshGeneration) return;
      connectWs(restored);
    } catch (err) {
      if (!mounted ||
          session != current ||
          generation != connectionRefreshGeneration) {
        return;
      }
      if (err is UnauthorizedSession) {
        await recoverUnauthorizedSession();
        return;
      }
      if (!forceReconnect && wsClient.channel != null) {
        // Soft probe: leave auto-reconnect / live socket alone.
        return;
      }
      setState(() {
        remoteOffline = true;
      });
      persistTranscriptSnapshotLater();
      if (generation != connectionRefreshGeneration) return;
      connectWs(current);
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
        stopping = status.running && status.stopping;
        activeRunId = status.running ? status.runId : null;
        runStartedAt = status.running ? status.startedAt : null;
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
        origin: Uri.parse('https://cc-remote.example.com'),
        token: 'demo',
        deviceName: 'My PC',
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
      activeRunId = null;
      runStartedAt = null;
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
            runStartedAt = null;
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
          stopping = running && decoded['stopping'] == true;
          final nextRunId = decoded['runId'];
          activeRunId = running && nextRunId is String ? nextRunId : null;
          final nextStartedAt = (decoded['startedAt'] as num?)?.toInt();
          runStartedAt = running && nextStartedAt != null
              ? DateTime.fromMillisecondsSinceEpoch(nextStartedAt)
              : null;
          removeDisconnectedRunNotice();
          if (running) currentRunFailed = false;
          if (!running) removeInterruptedRunNotice();
        });
        openPendingNotificationSession();
        persistTranscriptSnapshotLater();
      case 'prompt_accepted':
        return;
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
        clearStreamTextBatch(apply: false);
        setState(() {
          remoteTranscriptRevision = snapshot.revision;
          running = snapshot.running;
          stopping = snapshot.running && snapshot.stopping;
          activeRunId = snapshot.running ? snapshot.runId ?? activeRunId : null;
          runStartedAt = snapshot.running ? snapshot.startedAt : null;
          removeDisconnectedRunNotice();
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
          runStartedAt = null;
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
          runStartedAt = null;
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
          runStartedAt = null;
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
    connectionRefreshGeneration += 1;
    refreshConnectionInFlight = null;
    refreshConnectionForcesReconnect = false;
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
      runStartedAt = null;
      remoteTranscriptRevision = 0;
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
      if (running) {
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
    pendingAssistantText += text;
    streamTextFlushTimer ??= Timer(
      streamTextBatchInterval,
      flushStreamTextBatch,
    );
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

    final permissionMode = selectedPermissionMode;
    final sent = wsClient.sendPrompt(
      buildPromptMessage(
        promptId: createPromptId(),
        text: text,
        attachmentIds: uploaded.map((attachment) => attachment.id),
        permissionMode: permissionMode,
        sessionId: currentSessionId,
        model: selectedModel,
      ),
      expectedConnection: channel,
    );
    if (!sent) {
      setState(() {
        uploadingAttachments = false;
        messages.add(TranscriptMessage.system('发送失败，正在自动重连'));
      });
      persistTranscriptSnapshotLater();
      return;
    }
    setState(() {
      promptController.clear();
      pendingAttachments.clear();
      uploadingAttachments = false;
      running = true;
      stopping = false;
      runStartedAt = DateTime.now();
      currentRunFailed = false;
      activePermissionMode = permissionMode;
      beginPrompt(messages, text, attachments: uploaded);
      if (permissionMode == PermissionMode.bypassPermissions) {
        selectedPermissionMode = PermissionMode.manual;
      }
    });
    persistTranscriptSnapshotLater();
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
      if (source == AttachmentSource.camera) {
        final permission = await cameraPermissionService.request();
        if (permission != CameraPermissionState.granted) {
          if (mounted) showCameraPermissionMessage(permission);
          return;
        }
      }
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

  void showCameraPermissionMessage(CameraPermissionState state) {
    final needsSettings =
        state == CameraPermissionState.permanentlyDenied ||
        state == CameraPermissionState.restricted;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            needsSettings ? '请在系统设置中允许 CC Remote 使用相机' : '需要相机权限才能拍照',
          ),
          action: needsSettings
              ? SnackBarAction(
                  label: '去设置',
                  onPressed: () =>
                      unawaited(cameraPermissionService.openSettings()),
                )
              : null,
        ),
      );
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
    final sent = wsClient.send({
      'type': 'permission_response',
      'requestId': request.requestId,
      'decision': decision,
      if (activeSessionId != null) 'sessionId': activeSessionId,
    }, expectedConnection: channel);
    if (!sent) {
      setState(() {
        respondingPermissionIds.remove(request.requestId);
        messages.add(TranscriptMessage.system('审批发送失败，正在自动重连'));
      });
      persistTranscriptSnapshotLater();
    }
  }

  Future<void> stopRun() async {
    if (!running || stopping) return;

    final channel = ws;
    if (!widget.demoMode && (channel == null || !wsReady)) {
      setState(() {
        messages.add(TranscriptMessage.system('未连接，无法发送停止指令'));
      });
      persistTranscriptSnapshotLater();
      return;
    }

    if (!widget.demoMode) {
      final sent = wsClient.send({
        'type': 'stop',
      }, expectedConnection: channel!);
      if (!sent) {
        setState(() {
          messages.add(TranscriptMessage.system('停止指令发送失败，正在自动重连'));
        });
        persistTranscriptSnapshotLater();
        return;
      }
    }

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
        runStartedAt = null;
        messages.add(TranscriptMessage.system('已停止'));
      });
      persistTranscriptSnapshotLater();
      return;
    }

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
        runStartedAt = null;
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
      activeRunId = null;
      runStartedAt = null;
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
      activeRunId = null;
      runStartedAt = null;
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
        activeRunId = null;
        runStartedAt = null;
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
    return ValueListenableBuilder<double>(
      valueListenable: widget.readingFontScaleListenable,
      builder: (context, readingFontScale, _) {
        final screen = switch (route) {
          ShellRoute.boot => const BootstrapScreen(),
          ShellRoute.pair => PairScreen(
            enableCamera: widget.enableCamera,
            cameraPermissionService: cameraPermissionService,
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
            runStartedAt: runStartedAt,
            uploadingAttachments: uploadingAttachments,
            connected: wsReady,
            offline: remoteOffline,
            modelName: modelName,
            selectedModel: selectedModel,
            contextWindow: contextWindow,
            remainingContext: remainingContext,
            messages: messages,
            commands: commands,
            permissionMode: running
                ? activePermissionMode
                : selectedPermissionMode,
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
              readingFontScale,
              refreshConnection,
              setNotificationsEnabled,
              setModelPreference,
              setChatBackground,
              pickChatBackgroundImage,
              widget.onReadingFontScaleChanged,
              logoutPairedDevice,
            ),
            onOpenModelPicker: () => openModelPicker(context),
            onNewConversation: beginNewConversation,
            onOpenSessions: openSessions,
            onOpenWorkspace: openWorkspace,
            onPermissionModeSelected: selectPermissionMode,
            onPermissionAllow: (request) =>
                respondToPermission(request, 'allow'),
            onPermissionDeny: (request) =>
                respondToPermission(request, 'deny'),
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
      },
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
              key: const ValueKey('bootstrap-mark'),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.surface),
                color: AppColors.surface,
                border: Border.all(color: AppColors.line),
              ),
              alignment: Alignment.center,
              child: const Icon(
                LucideIcons.terminal,
                color: AppColors.terracottaDeep,
                size: 30,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'CC Remote',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.45,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '正在检查本机连接',
              style: TextStyle(color: AppColors.muted, fontSize: 14),
            ),
            const SizedBox(height: 22),
            const SizedBox(
              width: 148,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: AppColors.terracotta,
                backgroundColor: AppColors.line,
                borderRadius: BorderRadius.all(Radius.circular(AppRadii.pill)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PairScreen extends StatefulWidget {
  const PairScreen({
    super.key,
    required this.enableCamera,
    this.cameraPermissionService,
    required this.pairing,
    required this.canResetScan,
    required this.onQr,
    required this.onClearError,
    this.error,
    this.onDemoConnect,
  });

  final bool enableCamera;
  final CameraPermissionService? cameraPermissionService;
  final bool pairing;
  final bool canResetScan;
  final String? error;
  final ValueChanged<String> onQr;
  final VoidCallback onClearError;
  final VoidCallback? onDemoConnect;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> with WidgetsBindingObserver {
  late final CameraPermissionService cameraPermissionService =
      widget.cameraPermissionService ?? const SystemCameraPermissionService();
  late final MobileScannerController scannerController =
      MobileScannerController(autoStart: false);
  CameraPermissionState cameraPermission = CameraPermissionState.denied;
  bool checkingCamera = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.enableCamera) unawaited(checkCameraPermission());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(scannerController.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.enableCamera) {
      unawaited(checkCameraPermission());
    }
  }

  Future<void> checkCameraPermission({bool request = false}) async {
    if (checkingCamera) return;
    if (!mounted) return;
    setState(() => checkingCamera = true);
    try {
      final next = request
          ? await cameraPermissionService.request()
          : await cameraPermissionService.status();
      if (!mounted) return;
      setState(() => cameraPermission = next);
      if (next == CameraPermissionState.granted) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        await scannerController.start();
      } else {
        await scannerController.stop();
      }
    } catch (_) {
      if (mounted) {
        setState(() => cameraPermission = CameraPermissionState.denied);
      }
    } finally {
      if (mounted) setState(() => checkingCamera = false);
    }
  }

  Future<void> openCameraSettings() async {
    await cameraPermissionService.openSettings();
  }

  Widget buildScanner({bool compact = false}) {
    if (!widget.enableCamera) return ScanPlaceholder(compact: compact);
    if (cameraPermission != CameraPermissionState.granted) {
      final needsSettings =
          cameraPermission == CameraPermissionState.permanentlyDenied ||
          cameraPermission == CameraPermissionState.restricted;
      return CameraPermissionPlaceholder(
        compact: compact,
        checking: checkingCamera,
        needsSettings: needsSettings,
        onPressed: needsSettings
            ? openCameraSettings
            : () => checkCameraPermission(request: true),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 20 : 28),
      child: MobileScanner(
        controller: scannerController,
        placeholderBuilder: (_) => const ColoredBox(color: AppColors.control),
        errorBuilder: (context, error) => CameraPermissionPlaceholder(
          compact: compact,
          onPressed: () => checkCameraPermission(request: true),
        ),
        onDetect: (capture) {
          for (final barcode in capture.barcodes) {
            final value = barcode.rawValue;
            if (value != null && value.isNotEmpty) {
              widget.onQr(value);
              break;
            }
          }
        },
      ),
    );
  }

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
                          const Row(
                            children: [
                              Icon(
                                LucideIcons.smartphone,
                                size: 18,
                                color: AppColors.terracottaDeep,
                              ),
                              SizedBox(width: 7),
                              Text(
                                '首次连接',
                                style: TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: compact ? 7 : 10),
                          Text(
                            '让手机找到电脑',
                            style: TextStyle(
                              fontSize: compact ? 24 : 28,
                              height: 1.12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.56,
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
                    Container(
                      width: compact ? 52 : 60,
                      height: compact ? 52 : 60,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadii.surface),
                        border: Border.all(color: AppColors.line),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        LucideIcons.monitor,
                        size: 26,
                        color: AppColors.terracottaDeep,
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
                          child: buildScanner(compact: true),
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 0.94,
                        child: ScanFrame(child: buildScanner()),
                      ),
                    ),
                  ),
                SizedBox(height: compact ? 12 : 16),
                Container(
                  key: const ValueKey('pair-status-panel'),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadii.surface),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: AppSizes.iconControl,
                            height: AppSizes.iconControl,
                            decoration: BoxDecoration(
                              color: AppColors.control,
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(
                              LucideIcons.scanLine,
                              size: 20,
                              color: AppColors.terracottaDeep,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.pairing ? '正在连接电脑' : '等待配对二维码',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  widget.error ??
                                      (cameraPermission !=
                                                  CameraPermissionState
                                                      .granted &&
                                              widget.enableCamera
                                          ? '允许访问相机后即可扫描配对二维码'
                                          : widget.canResetScan
                                          ? '已暂停扫描，点重新扫描可继续'
                                          : '扫到后会确认设备信息再连接'),
                                  style: TextStyle(
                                    color: widget.error == null
                                        ? AppColors.muted
                                        : AppColors.danger,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          StatusLabel(
                            icon: widget.pairing
                                ? LucideIcons.refreshCw
                                : widget.error != null
                                ? LucideIcons.circleAlert
                                : cameraPermission !=
                                          CameraPermissionState.granted &&
                                      widget.enableCamera
                                ? LucideIcons.camera
                                : widget.canResetScan
                                ? LucideIcons.pause
                                : LucideIcons.camera,
                            label: widget.pairing
                                ? '配对中'
                                : widget.error == null
                                ? cameraPermission !=
                                              CameraPermissionState.granted &&
                                          widget.enableCamera
                                      ? '等待相机权限'
                                      : widget.canResetScan
                                      ? '等待确认'
                                      : '相机已就绪'
                                : '需要重试',
                            color: widget.error == null
                                ? AppColors.muted
                                : AppColors.danger,
                          ),
                        ],
                      ),
                      if (widget.pairing) ...[
                        const SizedBox(height: 14),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                          child: const LinearProgressIndicator(
                            minHeight: 2,
                            color: AppColors.terracotta,
                            backgroundColor: AppColors.line,
                          ),
                        ),
                      ],
                      if (widget.onDemoConnect != null) ...[
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: SignalPressEffect(
                            child: FilledButton.icon(
                              onPressed: widget.onDemoConnect,
                              icon: const Icon(LucideIcons.link),
                              label: const Text('连接这台电脑'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.cta,
                                foregroundColor: AppColors.onCta,
                                minimumSize: const Size.fromHeight(52),
                              ),
                            ),
                          ),
                        ),
                      ] else if (!widget.pairing &&
                          widget.error == null &&
                          !widget.canResetScan) ...[
                        const SizedBox(height: 14),
                        const Row(
                          children: [
                            Icon(
                              LucideIcons.scan,
                              size: 18,
                              color: AppColors.inactive,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '保持二维码完整可见，识别后会先确认设备信息',
                                style: TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (widget.canResetScan || widget.error != null) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: widget.onClearError,
                            icon: const Icon(LucideIcons.refreshCw, size: 18),
                            label: const Text('重新扫描'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.ink,
                              backgroundColor: AppColors.surfaceElevated,
                              minimumSize: const Size.fromHeight(48),
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

class CameraPermissionPlaceholder extends StatelessWidget {
  const CameraPermissionPlaceholder({
    super.key,
    required this.onPressed,
    this.compact = false,
    this.checking = false,
    this.needsSettings = false,
  });

  final Future<void> Function() onPressed;
  final bool compact;
  final bool checking;
  final bool needsSettings;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surface,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(compact ? 10 : 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.camera,
                size: compact ? 26 : 34,
                color: AppColors.terracottaDeep,
              ),
              SizedBox(height: compact ? 6 : 10),
              Text(
                needsSettings ? '相机权限已关闭' : '需要相机权限',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 4),
                Text(
                  needsSettings ? '请在系统设置中允许后返回' : '用于扫描电脑端的配对二维码',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
              SizedBox(height: compact ? 6 : 12),
              FilledButton.tonalIcon(
                key: const ValueKey('camera-permission-action'),
                onPressed: checking ? null : () => unawaited(onPressed()),
                icon: checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        needsSettings
                            ? LucideIcons.settings
                            : LucideIcons.camera,
                      ),
                label: Text(needsSettings ? '打开设置' : '允许使用相机'),
              ),
            ],
          ),
        ),
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
            color: AppColors.control,
            borderRadius: BorderRadius.circular(AppRadii.surface),
            border: Border.all(color: AppColors.line),
          ),
          child: Icon(
            LucideIcons.qrCode,
            size: compact ? 28 : 42,
            color: AppColors.terracottaDeep,
          ),
        ),
        SizedBox(height: compact ? 6 : 14),
        const Text(
          '把二维码放进取景框',
          style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w700),
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
        child: WarmSheetSurface(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: AppSizes.iconControl,
                    height: AppSizes.iconControl,
                    decoration: BoxDecoration(
                      color: AppColors.control,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      LucideIcons.monitor,
                      size: 20,
                      color: AppColors.terracottaDeep,
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
                            fontSize: 16,
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
                            fontFamily: AppTypography.codeFontFamily,
                            fontFamilyFallback:
                                AppTypography.codeFontFamilyFallback,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              StatusLabel(
                icon: expired ? LucideIcons.calendarX : LucideIcons.badgeCheck,
                label: expired ? '二维码已过期' : '二维码有效',
                color: expired ? AppColors.danger : AppColors.muted,
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
                      backgroundColor: AppColors.cta,
                      foregroundColor: AppColors.onCta,
                      minimumSize: const Size.fromHeight(52),
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
                    foregroundColor: AppColors.ink,
                    backgroundColor: AppColors.surface,
                    minimumSize: const Size.fromHeight(48),
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

enum ConsolePhase {
  connecting,
  connected,
  uploading,
  running,
  awaitingPermission,
  stopping,
  stopTimedOut,
  stopped,
  failed,
  offline,
}

enum ConsoleTone { neutral, active, danger }

@immutable
class ConsolePresentation {
  const ConsolePresentation(this.phase);

  final ConsolePhase phase;

  static ConsolePresentation resolve({
    required bool connected,
    required bool offline,
    required bool running,
    required bool stopping,
    required bool uploading,
    bool awaitingPermission = false,
    bool stopTimedOut = false,
    bool stopped = false,
    bool failed = false,
  }) {
    if (offline) return const ConsolePresentation(ConsolePhase.offline);
    if (running && stopping) {
      return const ConsolePresentation(ConsolePhase.stopping);
    }
    if (running && stopTimedOut) {
      return const ConsolePresentation(ConsolePhase.stopTimedOut);
    }
    if (running && awaitingPermission) {
      return const ConsolePresentation(ConsolePhase.awaitingPermission);
    }
    if (running) return const ConsolePresentation(ConsolePhase.running);
    if (uploading) return const ConsolePresentation(ConsolePhase.uploading);
    if (!connected) return const ConsolePresentation(ConsolePhase.connecting);
    if (failed) return const ConsolePresentation(ConsolePhase.failed);
    if (stopped) return const ConsolePresentation(ConsolePhase.stopped);
    return const ConsolePresentation(ConsolePhase.connected);
  }

  String get statusLabel => switch (phase) {
    ConsolePhase.connecting => '正在连接',
    ConsolePhase.connected => '已连接',
    ConsolePhase.uploading => '上传中',
    ConsolePhase.running => '运行中',
    ConsolePhase.awaitingPermission => '等待审批',
    ConsolePhase.stopping => '正在停止',
    ConsolePhase.stopTimedOut => '停止未确认',
    ConsolePhase.stopped => '已停止',
    ConsolePhase.failed => '执行失败',
    ConsolePhase.offline => '连接已断开',
  };

  String get inputHint => switch (phase) {
    ConsolePhase.connecting => '正在连接电脑端',
    ConsolePhase.connected ||
    ConsolePhase.stopped ||
    ConsolePhase.failed => '输入要发给 Claude Code 的内容',
    ConsolePhase.uploading => '正在上传附件…',
    ConsolePhase.running => 'Claude 正在输出…',
    ConsolePhase.awaitingPermission => '请先处理权限请求',
    ConsolePhase.stopping => '等待主机确认停止',
    ConsolePhase.stopTimedOut => '主机未确认停止，可再次尝试',
    ConsolePhase.offline => '重新连接后继续',
  };

  ConsoleTone get tone => switch (phase) {
    ConsolePhase.running ||
    ConsolePhase.awaitingPermission ||
    ConsolePhase.stopping ||
    ConsolePhase.uploading => ConsoleTone.active,
    ConsolePhase.stopTimedOut ||
    ConsolePhase.failed ||
    ConsolePhase.offline => ConsoleTone.danger,
    _ => ConsoleTone.neutral,
  };

  bool get canCompose => switch (phase) {
    ConsolePhase.connected ||
    ConsolePhase.stopped ||
    ConsolePhase.failed => true,
    _ => false,
  };

  bool get showsReconnect => phase == ConsolePhase.offline;

  bool get showsStop => switch (phase) {
    ConsolePhase.running ||
    ConsolePhase.awaitingPermission ||
    ConsolePhase.stopping ||
    ConsolePhase.stopTimedOut => true,
    _ => false,
  };

  bool get canStop => switch (phase) {
    ConsolePhase.running ||
    ConsolePhase.awaitingPermission ||
    ConsolePhase.stopTimedOut => true,
    _ => false,
  };

  String get stopTooltip => switch (phase) {
    ConsolePhase.stopping => '等待主机确认停止',
    ConsolePhase.stopTimedOut => '再次停止',
    _ => '停止',
  };
}

int currentTurnEvidenceStart(List<TranscriptMessage> messages) {
  return messages.lastIndexWhere(
        (message) => message.role == MessageRole.user,
      ) +
      1;
}

bool hasStopTimeoutEvidence(List<TranscriptMessage> messages) {
  return messages
      .skip(currentTurnEvidenceStart(messages))
      .any(
        (message) =>
            message.role == MessageRole.system &&
            message.text == '停止请求未确认，任务仍在运行',
      );
}

bool hasConfirmedStopEvidence(List<TranscriptMessage> messages) {
  return messages
      .skip(currentTurnEvidenceStart(messages))
      .any(
        (message) =>
            message.activityState == ActivityState.stopped ||
            (message.role == MessageRole.system && message.text == '已停止'),
      );
}

bool hasCurrentFailureEvidence(List<TranscriptMessage> messages) {
  return messages
      .skip(currentTurnEvidenceStart(messages))
      .any(
        (message) =>
            message.activityState == ActivityState.error ||
            (message.role == MessageRole.system &&
                message.text.startsWith('错误：')),
      );
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({
    super.key,
    required this.session,
    this.activeSessionId,
    required this.running,
    this.stopping = false,
    this.runStartedAt,
    this.uploadingAttachments = false,
    required this.connected,
    required this.offline,
    required this.modelName,
    this.selectedModel = ClaudeModelPreference.followComputer,
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
    required this.onOpenModelPicker,
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
  final DateTime? runStartedAt;
  final bool uploadingAttachments;
  final bool connected;
  final bool offline;
  final String? modelName;
  final ClaudeModelPreference selectedModel;
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
  final VoidCallback onOpenModelPicker;
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
    final presentation = ConsolePresentation.resolve(
      connected: connected,
      offline: offline,
      running: running,
      stopping: stopping,
      uploading: uploadingAttachments,
      awaitingPermission: pendingPermissions.isNotEmpty,
      stopTimedOut: hasStopTimeoutEvidence(messages),
      stopped: hasConfirmedStopEvidence(messages),
      failed: hasCurrentFailureEvidence(messages),
    );
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
        presentation: presentation,
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
        runStartedAt: runStartedAt,
        pendingPermissions: pendingPermissions,
        respondingPermissionIds: respondingPermissionIds,
        connected: connected,
        offline: offline,
        onFillPrompt: onFillPrompt,
        onReconnect: onReconnect,
        onPermissionAllow: onPermissionAllow,
        onPermissionDeny: onPermissionDeny,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        const reservedHeight = 292.0;
        final suggestionMaxHeight = (constraints.maxHeight - reservedHeight)
            .clamp(44.0, 292.0);
        return SafeArea(
          key: const ValueKey('chat'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Column(
              children: [
                header,
                if (ConsoleStatusStrip.shouldShow(presentation)) ...[
                  const SizedBox(height: 8),
                  ConsoleStatusStrip(
                    presentation: presentation,
                    hostLabel: session?.deviceName,
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(child: transcript),
                if (!(offline &&
                    messages.isEmpty &&
                    pendingPermissions.isEmpty)) ...[
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
                    modelName: modelName,
                    selectedModel: selectedModel,
                    presentation: presentation,
                    suggestionMaxHeight: suggestionMaxHeight,
                    onPermissionModeSelected: onPermissionModeSelected,
                    onCommandSelected: (command) => onFillPrompt('/$command '),
                    onAddAttachment: onAddAttachment,
                    onRemoveAttachment: onRemoveAttachment,
                    onModelPressed: onOpenModelPicker,
                    onReconnect: onReconnect,
                    onSend: onSend,
                    onStop: onStop,
                  ),
                ],
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
    this.presentation,
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
  final ConsolePresentation? presentation;
  final VoidCallback onReconnect;
  final VoidCallback onOpenSettings;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenSessions;
  final VoidCallback onOpenWorkspace;

  @override
  Widget build(BuildContext context) {
    final console =
        presentation ??
        ConsolePresentation.resolve(
          connected: connected,
          offline: offline,
          running: running,
          stopping: stopping,
          uploading: uploadingAttachments,
        );
    return SizedBox(
      key: const ValueKey('session-header'),
      height: AppSizes.sessionHeader,
      child: Row(
        children: [
          DecoratedBox(
            key: const ValueKey('session-menu-surface'),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.line),
            ),
            child: _HeaderIconButton(
              tooltip: '项目与会话',
              icon: LucideIcons.menu,
              onPressed: uploadingAttachments ? null : onOpenSessions,
            ),
          ),
          const Spacer(),
          DecoratedBox(
            key: const ValueKey('session-actions-surface'),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HeaderIconButton(
                  key: const ValueKey('session-new-button'),
                  tooltip: '新对话',
                  icon: LucideIcons.plus,
                  filled: true,
                  onPressed: console.canCompose ? onNewConversation : null,
                ),
                _SessionMoreButton(
                  offline: console.showsReconnect,
                  modelName: modelName,
                  onReconnect: onReconnect,
                  onOpenWorkspace: onOpenWorkspace,
                  onOpenSettings: onOpenSettings,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact status row under the floating header (not inside the header chrome).
class ConsoleStatusStrip extends StatelessWidget {
  const ConsoleStatusStrip({
    super.key,
    required this.presentation,
    this.hostLabel,
  });

  final ConsolePresentation presentation;
  final String? hostLabel;

  static bool shouldShow(ConsolePresentation presentation) {
    return presentation.phase != ConsolePhase.connected;
  }

  @override
  Widget build(BuildContext context) {
    final toneColor = switch (presentation.tone) {
      ConsoleTone.active => AppColors.terracottaDeep,
      ConsoleTone.danger => AppColors.danger,
      ConsoleTone.neutral => AppColors.muted,
    };
    final icon = switch (presentation.phase) {
      ConsolePhase.offline => LucideIcons.unlink,
      ConsolePhase.running || ConsolePhase.uploading => LucideIcons.loader,
      ConsolePhase.awaitingPermission => LucideIcons.shield,
      ConsolePhase.stopping || ConsolePhase.stopTimedOut => LucideIcons.square,
      ConsolePhase.stopped => LucideIcons.circlePause,
      ConsolePhase.failed => LucideIcons.circleAlert,
      _ => LucideIcons.monitor,
    };
    final host = hostLabel?.trim();
    final showHost =
        host != null &&
        host.isNotEmpty &&
        (presentation.phase == ConsolePhase.offline ||
            presentation.phase == ConsolePhase.failed);
    final detail = showHost ? host : null;

    return Semantics(
      liveRegion: true,
      label: detail == null
          ? presentation.statusLabel
          : '${presentation.statusLabel}，$detail',
      child: Container(
        key: const ValueKey('console-status-strip'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: toneColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                presentation.statusLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: toneColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
            if (detail != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.filled = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: AppSizes.touchTarget,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        icon: filled
            ? Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: onPressed == null
                      ? AppColors.inactiveLight
                      : AppColors.ink,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 14, color: AppColors.surfaceElevated),
              )
            : Icon(
                icon,
                size: 20,
                color: onPressed == null ? AppColors.inactive : AppColors.ink,
              ),
      ),
    );
  }
}

enum _SessionHeaderAction { workspace, reconnect, settings }

class _SessionMoreButton extends StatelessWidget {
  const _SessionMoreButton({
    required this.offline,
    required this.modelName,
    required this.onReconnect,
    required this.onOpenWorkspace,
    required this.onOpenSettings,
  });

  final bool offline;
  final String? modelName;
  final VoidCallback onReconnect;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final metaParts = <String>[
      if (modelName != null) formatModelName(modelName!),
    ];
    return SizedBox.square(
      dimension: AppSizes.touchTarget,
      child: PopupMenuButton<_SessionHeaderAction>(
        key: const ValueKey('session-more-button'),
        tooltip: '更多',
        padding: EdgeInsets.zero,
        offset: const Offset(0, 8),
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 196, maxWidth: 240),
        onSelected: (action) {
          switch (action) {
            case _SessionHeaderAction.workspace:
              onOpenWorkspace();
            case _SessionHeaderAction.reconnect:
              onReconnect();
            case _SessionHeaderAction.settings:
              onOpenSettings();
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: _SessionHeaderAction.workspace,
            height: 48,
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: _SessionMenuRow(icon: LucideIcons.folderOpen, label: '工作区'),
          ),
          if (offline)
            const PopupMenuItem(
              value: _SessionHeaderAction.reconnect,
              height: 48,
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: _SessionMenuRow(
                icon: LucideIcons.refreshCw,
                label: '重新连接',
              ),
            ),
          const PopupMenuItem(
            value: _SessionHeaderAction.settings,
            height: 48,
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: _SessionMenuRow(icon: LucideIcons.settings, label: '设置'),
          ),
          if (metaParts.isNotEmpty)
            _SessionMenuMetaEntry(text: metaParts.join(' · ')),
        ],
        icon: const Icon(LucideIcons.ellipsis, size: 20),
      ),
    );
  }
}

class _SessionMenuRow extends StatelessWidget {
  const _SessionMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.ink),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionMenuMetaEntry extends PopupMenuEntry<_SessionHeaderAction> {
  const _SessionMenuMetaEntry({required this.text});

  final String text;

  @override
  double get height => 49;

  @override
  bool represents(_SessionHeaderAction? value) => false;

  @override
  State<_SessionMenuMetaEntry> createState() => _SessionMenuMetaEntryState();
}

class _SessionMenuMetaEntryState extends State<_SessionMenuMetaEntry> {
  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '当前模型 ${widget.text}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PopupMenuDivider(height: 9),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              widget.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showSettingsSheet(
  BuildContext context,
  SavedSession? session,
  bool notificationsEnabled,
  ChatBackgroundPreference chatBackground,
  String? currentModel,
  ClaudeModelPreference selectedModel,
  double readingFontScale,
  VoidCallback onReconnect,
  Future<bool> Function(bool) onNotificationsChanged,
  Future<void> Function(ClaudeModelPreference) onModelChanged,
  Future<ChatBackgroundPreference> Function(ChatBackgroundPreference)
  onChatBackgroundChanged,
  Future<ChatBackgroundPreference?> Function(double) onPickChatBackgroundImage,
  Future<void> Function(double scale, {bool persist}) onReadingFontScaleChanged,
  VoidCallback onLogout,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SettingsSheet(
      session: session,
      notificationsEnabled: notificationsEnabled,
      chatBackground: chatBackground,
      currentModel: currentModel,
      selectedModel: selectedModel,
      readingFontScale: readingFontScale,
      onReconnect: onReconnect,
      onNotificationsChanged: onNotificationsChanged,
      onModelChanged: onModelChanged,
      onChatBackgroundChanged: onChatBackgroundChanged,
      onPickChatBackgroundImage: onPickChatBackgroundImage,
      onReadingFontScaleChanged: onReadingFontScaleChanged,
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
                    icon: const Icon(LucideIcons.plus, size: 18),
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
                            enabled:
                                (!widget.running || active) && !item.archived,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: Icon(
                              item.archived
                                  ? LucideIcons.archive
                                  : item.running
                                  ? LucideIcons.clock
                                  : LucideIcons.messageCircle,
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
                                        if (next == null ||
                                            next.trim().isEmpty) {
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
                                    LucideIcons.circleCheck,
                                    color: AppColors.accent,
                                  )
                                else
                                  const Icon(LucideIcons.chevronRight),
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
    required this.readingFontScale,
    required this.onReconnect,
    required this.onNotificationsChanged,
    required this.onModelChanged,
    required this.onChatBackgroundChanged,
    required this.onPickChatBackgroundImage,
    required this.onReadingFontScaleChanged,
    required this.onLogout,
  });

  final SavedSession? session;
  final bool notificationsEnabled;
  final ChatBackgroundPreference chatBackground;
  final String? currentModel;
  final ClaudeModelPreference selectedModel;
  final double readingFontScale;
  final VoidCallback onReconnect;
  final Future<bool> Function(bool) onNotificationsChanged;
  final Future<void> Function(ClaudeModelPreference) onModelChanged;
  final Future<ChatBackgroundPreference> Function(ChatBackgroundPreference)
  onChatBackgroundChanged;
  final Future<ChatBackgroundPreference?> Function(double)
  onPickChatBackgroundImage;
  final Future<void> Function(double scale, {bool persist})
  onReadingFontScaleChanged;
  final VoidCallback onLogout;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late bool notificationsEnabled = widget.notificationsEnabled;
  late ChatBackgroundPreference chatBackground = widget.chatBackground;
  late ClaudeModelPreference selectedModel = widget.selectedModel;
  late double readingFontScale = widget.readingFontScale;
  late double persistedReadingFontScale = widget.readingFontScale;
  bool changingNotifications = false;
  bool changingModel = false;
  bool savingReadingFontScale = false;

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

  void previewReadingFontScale(double value) {
    final snapped = snapReadingFontScale(value);
    if ((snapped - readingFontScale).abs() < 0.001) return;
    setState(() => readingFontScale = snapped);
    unawaited(widget.onReadingFontScaleChanged(snapped, persist: false));
  }

  Future<void> commitReadingFontScale(double value) async {
    final snapped = snapReadingFontScale(value);
    final previous = persistedReadingFontScale;
    setState(() {
      readingFontScale = snapped;
      savingReadingFontScale = true;
    });
    try {
      await widget.onReadingFontScaleChanged(snapped, persist: true);
      if (!mounted) return;
      setState(() => persistedReadingFontScale = snapped);
    } catch (_) {
      if (!mounted) return;
      setState(() => readingFontScale = previous);
      unawaited(widget.onReadingFontScaleChanged(previous, persist: false));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('字体大小保存失败，请重试')));
    } finally {
      if (mounted) setState(() => savingReadingFontScale = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final sectionLabelStyle = textTheme.labelMedium?.copyWith(
      color: AppColors.muted,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    final rowTitleStyle = textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      height: 1.3,
    );
    final rowSubtitleStyle = textTheme.bodySmall?.copyWith(
      color: AppColors.muted,
      height: 1.4,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: WarmSheetSurface(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
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
                      Expanded(
                        child: Text(
                          '设置',
                          style: textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.36,
                          ),
                        ),
                      ),
                      _SettingsCloseButton(
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('设备与服务', style: sectionLabelStyle),
                  const SizedBox(height: 8),
                  _SettingsInfoCard(
                    children: [
                      InfoRow(
                        label: '电脑',
                        value: widget.session?.deviceName ?? 'My PC',
                      ),
                      InfoRow(
                        label: '服务',
                        value:
                            widget.session?.origin.toString() ??
                            'https://cc-remote.example.com',
                      ),
                      InfoRow(
                        label: '目录',
                        value:
                            widget.session?.workspaceDir ??
                            widget.session?.workspaceName ??
                            'cc-remote',
                        isLast: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('对话偏好', style: sectionLabelStyle),
                  const SizedBox(height: 8),
                  _SettingsGroupCard(
                    children: [
                      ListTile(
                        key: const ValueKey('model-setting'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        minVerticalPadding: 10,
                        leading: const _SettingsLeadingIcon(
                          icon: LucideIcons.slidersHorizontal,
                        ),
                        title: Text('模型', style: rowTitleStyle),
                        subtitle: Text(
                          modelPreferenceDescription(
                            selectedModel,
                            widget.currentModel == null
                                ? null
                                : formatModelName(widget.currentModel!),
                          ),
                          style: rowSubtitleStyle,
                        ),
                        trailing: changingModel
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                LucideIcons.chevronRight,
                                color: AppColors.inactive,
                              ),
                        onTap: changingModel ? null : chooseModel,
                      ),
                      const Divider(height: 1, indent: 60, endIndent: 12),
                      ListTile(
                        key: const ValueKey('chat-background-setting'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        minVerticalPadding: 10,
                        leading: ChatBackgroundThumbnail(
                          preference: chatBackground,
                        ),
                        title: Text('聊天背景', style: rowTitleStyle),
                        subtitle: Text(
                          chatBackgroundLabel(chatBackground),
                          style: rowSubtitleStyle,
                        ),
                        trailing: const Icon(
                          LucideIcons.chevronRight,
                          color: AppColors.inactive,
                        ),
                        onTap: () => showChatBackgroundSheet(
                          context,
                          preference: chatBackground,
                          onChanged: changeChatBackground,
                          onPickImage: pickChatBackgroundImage,
                        ),
                      ),
                      const Divider(height: 1, indent: 60, endIndent: 12),
                      Padding(
                        key: const ValueKey('reading-font-size-setting'),
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const _SettingsLeadingIcon(
                                  icon: LucideIcons.type,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text('字体大小', style: rowTitleStyle),
                                ),
                                Text(
                                  readingFontSizeLabel(readingFontScale),
                                  style: textTheme.labelLarge?.copyWith(
                                    color: AppColors.terracottaDeep,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (savingReadingFontScale) ...[
                                  const SizedBox(width: 8),
                                  const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              readingFontSizeDescription(readingFontScale),
                              style: rowSubtitleStyle,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text(
                                  'A',
                                  style: textTheme.bodySmall?.copyWith(
                                    fontSize: 12,
                                    color: AppColors.muted,
                                  ),
                                ),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      activeTrackColor: AppColors.terracotta,
                                      inactiveTrackColor: AppColors.control,
                                      thumbColor: AppColors.terracottaDeep,
                                      overlayColor: AppColors.terracotta
                                          .withValues(alpha: 0.14),
                                      trackHeight: 3.5,
                                    ),
                                    child: Slider(
                                      key: const ValueKey(
                                        'reading-font-size-slider',
                                      ),
                                      value: readingFontScale.clamp(
                                        kReadingFontScaleMin,
                                        kReadingFontScaleMax,
                                      ),
                                      min: kReadingFontScaleMin,
                                      max: kReadingFontScaleMax,
                                      divisions: 11,
                                      label: readingFontSizeLabel(
                                        readingFontScale,
                                      ),
                                      onChanged: previewReadingFontScale,
                                      onChangeEnd: commitReadingFontScale,
                                    ),
                                  ),
                                ),
                                Text(
                                  'A',
                                  style: textTheme.bodySmall?.copyWith(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.ink,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('通知', style: sectionLabelStyle),
                  const SizedBox(height: 8),
                  _SettingsGroupCard(
                    children: [
                      SwitchListTile(
                        key: const ValueKey('background-notifications-toggle'),
                        contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                        value: notificationsEnabled,
                        onChanged: changingNotifications
                            ? null
                            : changeNotifications,
                        secondary: const _SettingsLeadingIcon(
                          icon: LucideIcons.bell,
                        ),
                        title: Text('后台通知', style: rowTitleStyle),
                        subtitle: Text(
                          '任务完成、失败或等待权限时提醒',
                          style: rowSubtitleStyle,
                        ),
                        activeThumbColor: AppColors.surfaceElevated,
                        activeTrackColor: AppColors.terracotta,
                        inactiveThumbColor: AppColors.surfaceElevated,
                        inactiveTrackColor: AppColors.control,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('连接与配对', style: sectionLabelStyle),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onReconnect();
                      },
                      icon: const Icon(LucideIcons.refreshCw, size: 18),
                      label: const Text('重新连接'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.ink,
                        backgroundColor: AppColors.surface,
                        side: const BorderSide(color: AppColors.line),
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: SignalPressEffect(
                      child: FilledButton.icon(
                        onPressed: () =>
                            confirmLogout(context, widget.onLogout),
                        icon: const Icon(LucideIcons.unlink, size: 18),
                        label: const Text('退出配对'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.danger,
                          foregroundColor: AppColors.surfaceElevated,
                          minimumSize: const Size.fromHeight(52),
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
class _SettingsCloseButton extends StatelessWidget {
  const _SettingsCloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: AppSizes.touchTarget,
      child: IconButton(
        onPressed: onPressed,
        tooltip: '关闭',
        padding: EdgeInsets.zero,
        icon: Container(
          width: AppSizes.iconControl,
          height: AppSizes.iconControl,
          decoration: BoxDecoration(
            color: AppColors.control,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          alignment: Alignment.center,
          child: const Icon(LucideIcons.x, size: 18),
        ),
      ),
    );
  }
}

class _SettingsLeadingIcon extends StatelessWidget {
  const _SettingsLeadingIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: AppColors.control,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 18, color: AppColors.ink),
    );
  }
}

class _SettingsGroupCard extends StatelessWidget {
  const _SettingsGroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(color: AppColors.line.withValues(alpha: 0.85)),
        boxShadow: AppElevation.softCard(alpha: 0.045),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.surface - 1),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _SettingsInfoCard extends StatelessWidget {
  const _SettingsInfoCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(color: AppColors.line.withValues(alpha: 0.85)),
        boxShadow: AppElevation.softCard(alpha: 0.04),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
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
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
        child: WarmSheetSurface(
          radius: 28,
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择模型',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                '应用于之后发送的消息',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              for (final preference in ClaudeModelPreference.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: preference == selected
                        ? AppColors.control
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadii.surface),
                    child: InkWell(
                      key: ValueKey(
                        'model-option-${preference.wireName ?? 'follow'}',
                      ),
                      onTap: () => Navigator.pop(context, preference),
                      borderRadius: BorderRadius.circular(AppRadii.surface),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: AppSizes.iconControl,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceElevated,
                                  borderRadius: BorderRadius.circular(
                                    AppRadii.control,
                                  ),
                                  border: Border.all(color: AppColors.line),
                                ),
                                child: Icon(
                                  preference ==
                                          ClaudeModelPreference.followComputer
                                      ? LucideIcons.monitor
                                      : LucideIcons.cpu,
                                  size: 19,
                                  color: preference == selected
                                      ? AppColors.terracottaDeep
                                      : AppColors.ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    preference.label,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    modelPreferenceOptionDescription(
                                      preference,
                                    ),
                                    style: const TextStyle(
                                      color: AppColors.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              preference == selected
                                  ? LucideIcons.circleCheck
                                  : LucideIcons.circle,
                              color: preference == selected
                                  ? AppColors.terracottaDeep
                                  : AppColors.inactiveLight,
                              size: 22,
                            ),
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
      ('暖纸', ChatBackgroundPreference.defaultValue),
      ('亚麻', const ChatBackgroundPreference.preset(ChatBackgroundPreset.mint)),
      (
        '陶纸',
        const ChatBackgroundPreference.preset(ChatBackgroundPreset.sunrise),
      ),
      ('砂岩', const ChatBackgroundPreference.preset(ChatBackgroundPreset.rose)),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 24, 14, 14),
        child: WarmSheetSurface(
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
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(LucideIcons.x),
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
                          style: TextStyle(fontWeight: FontWeight.w700),
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
                                : const Icon(LucideIcons.image),
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
                                  style: TextStyle(fontWeight: FontWeight.w700),
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
                            icon: const Icon(LucideIcons.rotateCcw),
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
                      color: selected
                          ? AppColors.terracottaDeep
                          : AppColors.line,
                      width: selected ? 2 : 1,
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
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
          border: Border.all(color: AppColors.line),
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
                    child: _PreviewBubble(color: AppColors.control, width: 138),
                  ),
                  SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _PreviewBubble(
                      color: AppColors.surfaceElevated,
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
        border: Border.all(color: AppColors.line),
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
      width: 36,
      height: 36,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: AppColors.line),
        color: AppColors.control,
      ),
      child: _ChatBackgroundLayer(preference: preference, cacheWidth: 144),
    );
  }
}

String chatBackgroundLabel(ChatBackgroundPreference preference) {
  return switch (preference.kind) {
    ChatBackgroundKind.defaultStyle => '默认纸感',
    ChatBackgroundKind.localImage => '自定义图片',
    ChatBackgroundKind.preset => switch (preference.preset) {
      ChatBackgroundPreset.mint => '亚麻纸感',
      ChatBackgroundPreset.sunrise => '陶纸纸感',
      ChatBackgroundPreset.rose => '砂岩纸感',
      null => '内置背景',
    },
  };
}

class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 6, bottom: isLast ? 6 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: MonoText(
              value,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
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
              leading: const Icon(LucideIcons.camera),
              title: const Text('拍照'),
              subtitle: const Text('拍一张照片发送给 Claude Code'),
              onTap: () => Navigator.pop(context, AttachmentSource.camera),
            ),
            ListTile(
              leading: const Icon(LucideIcons.image),
              title: const Text('选择图片'),
              subtitle: const Text('从相册选择一张或多张图片'),
              onTap: () => Navigator.pop(context, AttachmentSource.photos),
            ),
            ListTile(
              leading: const Icon(LucideIcons.folderOpen),
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
    this.runStartedAt,
    required this.pendingPermissions,
    required this.respondingPermissionIds,
    required this.connected,
    this.offline = false,
    required this.onFillPrompt,
    required this.onReconnect,
    required this.onPermissionAllow,
    required this.onPermissionDeny,
  });

  final List<TranscriptMessage> messages;
  final SavedSession? session;
  final String? activeSessionId;
  final bool running;
  final DateTime? runStartedAt;
  final List<RemotePermissionRequest> pendingPermissions;
  final Set<String> respondingPermissionIds;
  final bool connected;
  final bool offline;
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
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '从下方输入，或先点一个快捷任务',
                        style: TextStyle(color: AppColors.muted, fontSize: 14),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 7,
                            child: PromptChip(
                              icon: LucideIcons.arrowUpRight,
                              label: '检查项目',
                              caption: '看看哪里需要处理',
                              onTap: () => onFillPrompt('检查这个项目'),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            flex: 5,
                            child: PromptChip(
                              icon: LucideIcons.play,
                              label: '运行测试',
                              caption: '跑完告诉我结果',
                              onTap: () => onFillPrompt('运行测试并总结结果'),
                            ),
                          ),
                        ],
                      ),
                    ] else if (offline) ...[
                      SizedBox(
                        height: (constraints.maxHeight - 14).clamp(
                          224.0,
                          320.0,
                        ),
                        child: _OfflineReconnectCard(onReconnect: onReconnect),
                      ),
                    ] else ...[
                      SizedBox(
                        height: (constraints.maxHeight - 14).clamp(
                          180.0,
                          260.0,
                        ),
                        child: const _ConnectingStatusCard(),
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
    final workspaceDir = session?.workspaceDir;
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
            runStartedAt: runStartedAt,
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
          workspaceDir: workspaceDir,
          onAllow: () => onPermissionAllow(request),
          onDeny: () => onPermissionDeny(request),
        );
      },
    );
  }
}

class _ConnectingStatusCard extends StatelessWidget {
  const _ConnectingStatusCard();

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('connecting-status-card'),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.surface),
        side: const BorderSide(color: AppColors.line),
      ),
      child: const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: AppSizes.iconControl,
              height: AppSizes.iconControl,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.control,
                  borderRadius: BorderRadius.all(
                    Radius.circular(AppRadii.control),
                  ),
                ),
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.terracottaDeep,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: 16),
            Text(
              '正在重新连接',
              style: TextStyle(
                fontSize: 18,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.28,
              ),
            ),
            SizedBox(height: 6),
            Text(
              '正在联系电脑端，会话记录会保留。',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineReconnectCard extends StatelessWidget {
  const _OfflineReconnectCard({required this.onReconnect});

  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('offline-reconnect-card'),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.surface),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: AppSizes.iconControl,
              height: AppSizes.iconControl,
              decoration: BoxDecoration(
                color: AppColors.control,
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              alignment: Alignment.center,
              child: const Icon(
                LucideIcons.unlink,
                size: 20,
                color: AppColors.danger,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '让电脑重新上线',
              style: TextStyle(
                fontSize: 18,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.28,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '在电脑端重新运行 CC Remote，手机会自动接回这次会话。',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '会话和输入内容都会保留',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: SignalPressEffect(
                child: FilledButton.icon(
                  onPressed: onReconnect,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.cta,
                    foregroundColor: AppColors.onCta,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  icon: const Icon(LucideIcons.refreshCw, size: 18),
                  label: const Text('立即重连'),
                ),
              ),
            ),
          ],
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
    this.workspaceDir,
    required this.onAllow,
    required this.onDeny,
  });

  final RemotePermissionRequest request;
  final bool responding;
  final bool connected;
  final String? workspaceDir;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  String get _headline {
    final tool = (request.displayName ?? request.toolName).trim();
    final lower = request.toolName.toLowerCase();
    if (lower.contains('bash') || lower.contains('shell')) {
      return '允许 Claude 运行命令？';
    }
    if (lower.contains('write') || lower.contains('edit')) {
      return '允许 Claude 修改文件？';
    }
    if (tool.isEmpty) return '允许 Claude 使用工具？';
    return '允许 Claude 使用 $tool？';
  }

  String get _scopeLabel => '仅本次请求';

  String get _impactLabel {
    final tool = request.toolName.toLowerCase();
    if (tool.contains('write') || tool.contains('edit')) {
      return '可能写入或覆盖工作区文件';
    }
    if (tool.contains('bash') || tool.contains('shell')) {
      return '可能在桌面主机执行命令';
    }
    if (tool.contains('read') || tool.contains('glob') || tool.contains('grep')) {
      return '可能读取工作区内容';
    }
    return '按工具说明执行一次性操作';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = connected && !responding;
    final tool = request.toolName.toLowerCase();
    final riskTone = tool.contains('write') || tool.contains('edit')
        ? AppColors.danger
        : tool.contains('bash') || tool.contains('shell')
        ? AppColors.terracottaDeep
        : AppColors.terracottaDeep;
    final summary =
        request.detail?.trim().isNotEmpty == true
        ? request.detail!.trim()
        : (request.description?.trim().isNotEmpty == true
              ? request.description!.trim()
              : (request.displayName ?? request.toolName));
    final reason = request.decisionReason?.trim();
    final description = request.description?.trim();

    return Container(
      key: ValueKey('permission-request-${request.requestId}'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(color: AppColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: AppSizes.iconControl,
                  height: AppSizes.iconControl,
                  decoration: BoxDecoration(
                    color: AppColors.control,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  alignment: Alignment.center,
                  child: Icon(LucideIcons.shield, size: 20, color: riskTone),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _headline,
                    style: const TextStyle(
                      fontSize: 18,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.28,
                      color: AppColors.ink,
                    ),
                  ),
                ),
                if (responding)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _PermissionSectionLabel('命令或工具'),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.control,
                borderRadius: BorderRadius.circular(AppRadii.compact),
                border: Border.all(color: AppColors.line),
              ),
              child: SelectableText(
                summary,
                style: TextStyle(
                  color: AppColors.ink,
                  fontFamily: request.detail == null
                      ? AppTypography.fontFamily
                      : AppTypography.codeFontFamily,
                  fontFamilyFallback: request.detail == null
                      ? AppTypography.fontFamilyFallback
                      : AppTypography.codeFontFamilyFallback,
                  fontSize: request.detail == null ? 14 : 12,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (description != null &&
                description.isNotEmpty &&
                description != summary) ...[
              const SizedBox(height: 10),
              Text(
                description,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ],
            const SizedBox(height: 14),
            _PermissionSectionLabel('工作目录'),
            const SizedBox(height: 6),
            Text(
              () {
                final path = workspaceDir?.trim();
                if (path != null && path.isNotEmpty) return path;
                return '以桌面主机当前工作区为准（路径暂不可用）';
              }(),
              style: TextStyle(
                color: workspaceDir?.trim().isNotEmpty == true
                    ? AppColors.ink
                    : AppColors.muted,
                fontFamily: workspaceDir?.trim().isNotEmpty == true
                    ? AppTypography.codeFontFamily
                    : AppTypography.fontFamily,
                fontFamilyFallback: workspaceDir?.trim().isNotEmpty == true
                    ? AppTypography.codeFontFamilyFallback
                    : AppTypography.fontFamilyFallback,
                fontSize: workspaceDir?.trim().isNotEmpty == true ? 12 : 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            _PermissionSectionLabel('权限与影响'),
            const SizedBox(height: 6),
            Text(
              _impactLabel,
              style: TextStyle(
                color: riskTone,
                fontSize: 13,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (reason != null && reason.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                reason,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 14),
            _PermissionSectionLabel('授权范围'),
            const SizedBox(height: 6),
            Text(
              _scopeLabel,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 13,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: SignalPressEffect(
                enabled: enabled,
                child: FilledButton(
                  onPressed: enabled ? onAllow : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.cta,
                    foregroundColor: AppColors.onCta,
                    disabledBackgroundColor: AppColors.control,
                    disabledForegroundColor: AppColors.inactive,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: const Text('仅本次允许'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: SignalPressEffect(
                enabled: enabled,
                child: OutlinedButton(
                  onPressed: enabled ? onDeny : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.ink,
                    backgroundColor: AppColors.surface,
                    side: const BorderSide(color: AppColors.lineStrong),
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('拒绝并返回'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionSectionLabel extends StatelessWidget {
  const _PermissionSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.muted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        height: 1.3,
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
    this.runStartedAt,
    this.streaming = false,
  });

  final TranscriptMessage message;
  final SavedSession? session;
  final String? activeSessionId;
  final DateTime? runStartedAt;
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
      return ActivityBlock(message: message, runStartedAt: runStartedAt);
    }

    final isUser = message.role == MessageRole.user;
    if (!isUser) {
      // ponytail: plain text while streaming; markdown only after done
      final assistantBody = streaming
          ? SelectableText(
              message.text,
              style: const TextStyle(
                fontFamily: AppTypography.assistantFontFamily,
                fontFamilyFallback: AppTypography.assistantFontFamilyFallback,
                height: AppTypography.assistantBodyHeight,
                fontSize: AppTypography.assistantBodySize,
                color: AppColors.ink,
                letterSpacing: 0.1,
              ),
            )
          : MarkdownBody(
              data: message.text,
              selectable: true,
              softLineBreak: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: const TextStyle(
                      fontFamily: AppTypography.assistantFontFamily,
                      fontFamilyFallback:
                          AppTypography.assistantFontFamilyFallback,
                      height: AppTypography.assistantBodyHeight,
                      fontSize: AppTypography.assistantBodySize,
                      color: AppColors.ink,
                      letterSpacing: 0.1,
                    ),
                    a: const TextStyle(color: AppColors.terracottaDeep),
                    code: const TextStyle(
                      fontFamily: AppTypography.codeFontFamily,
                      fontFamilyFallback: AppTypography.codeFontFamilyFallback,
                      fontSize: 12.5,
                      height: 1.5,
                      color: AppColors.ink,
                    ),
                    h1: const TextStyle(
                      fontFamily: AppTypography.assistantFontFamily,
                      fontFamilyFallback:
                          AppTypography.assistantFontFamilyFallback,
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: AppColors.ink,
                    ),
                    h2: const TextStyle(
                      fontFamily: AppTypography.assistantFontFamily,
                      fontFamilyFallback:
                          AppTypography.assistantFontFamilyFallback,
                      fontSize: 18.5,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                      color: AppColors.ink,
                    ),
                    h3: const TextStyle(
                      fontFamily: AppTypography.assistantFontFamily,
                      fontFamilyFallback:
                          AppTypography.assistantFontFamilyFallback,
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
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
                      color: AppColors.control,
                      borderRadius: BorderRadius.circular(AppRadii.compact),
                      border: Border.all(color: AppColors.line),
                    ),
                    blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
                    blockquoteDecoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: AppColors.terracotta, width: 1),
                      ),
                    ),
                  ),
            );
      return AssistantBubbleFrame(
        bubbleKey: const ValueKey('assistant-message'),
        child: assistantBody,
      );
    }

    final maxWidth = MediaQuery.sizeOf(context).width * 0.82;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          key: const ValueKey('user-message'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: AppColors.control,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppRadii.bubble),
              topRight: Radius.circular(AppRadii.bubble),
              bottomLeft: Radius.circular(AppRadii.bubble),
              bottomRight: Radius.circular(8),
            ),
            border: Border.all(color: AppColors.line.withValues(alpha: 0.75)),
            boxShadow: AppElevation.softBubble(alpha: 0.04),
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
                    fontFamily: AppTypography.fontFamily,
                    fontFamilyFallback: AppTypography.fontFamilyFallback,
                    height: AppTypography.userBodyHeight,
                    fontSize: AppTypography.userBodySize,
                    color: AppColors.ink,
                    fontWeight: FontWeight.w400,
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
                ? LucideIcons.fileText
                : LucideIcons.file,
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
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatAttachmentSize(size),
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
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
    // Fill the transcript column; parent padding already sets reading margins.
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: bubbleKey,
        width: double.infinity,
        padding: compact
            ? const EdgeInsets.fromLTRB(14, 12, 16, 12)
            : const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(AppRadii.bubble),
            topRight: Radius.circular(AppRadii.bubble),
            bottomLeft: Radius.circular(8),
            bottomRight: Radius.circular(AppRadii.bubble),
          ),
          border: Border.all(color: AppColors.line.withValues(alpha: 0.7)),
          boxShadow: AppElevation.softBubble(),
        ),
        child: child,
      ),
    );
  }
}

Map<String, Object> buildPromptMessage({
  required String promptId,
  required String text,
  required Iterable<String> attachmentIds,
  required PermissionMode permissionMode,
  required String sessionId,
  required ClaudeModelPreference model,
}) {
  final attachments = attachmentIds.toList(growable: false);
  return {
    'type': 'prompt',
    'promptId': promptId,
    'text': text,
    if (attachments.isNotEmpty) 'attachmentIds': attachments,
    'permissionMode': permissionMode.wireName,
    'sessionId': sessionId,
    'model': ?model.wireName,
  };
}

final Random _promptIdRandom = Random.secure();

String createPromptId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final random = _promptIdRandom.nextInt(0x7fffffff).toRadixString(36);
  return '$timestamp-$random';
}

class ActivityBlock extends StatelessWidget {
  const ActivityBlock({super.key, required this.message, this.runStartedAt});

  final TranscriptMessage message;
  final DateTime? runStartedAt;

  @override
  Widget build(BuildContext context) {
    if (message.activityKind == ActivityKind.thinking) {
      if (message.activityState == ActivityState.running) {
        return TaskRailFrame(
          color: AppColors.terracotta,
          active: true,
          compact: true,
          child: AssistantBubbleFrame(
            bubbleKey: const ValueKey('thinking-bubble'),
            compact: true,
            child: ThinkingIndicator(
              initialElapsedSeconds: elapsedSecondsSince(runStartedAt),
            ),
          ),
        );
      }
      final thinkingTone = message.activityState == ActivityState.error
          ? AppColors.danger
          : AppColors.inactive;
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
                    ? LucideIcons.circleAlert
                    : LucideIcons.check,
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
      ActivityState.running => AppColors.terracotta,
      ActivityState.done => AppColors.inactive,
      ActivityState.error => AppColors.danger,
      ActivityState.stopped => AppColors.muted,
      null => AppColors.muted,
    };

    final detail = message.activityDetail;
    final title = Text(
      message.text,
      style: TextStyle(
        color: message.activityState == ActivityState.error
            ? AppColors.danger
            : AppColors.muted,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
    final icon = switch (message.activityState) {
      // Keep Material spinner: reliable dispose in tests, no pending timers.
      ActivityState.running => const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: AppColors.terracotta,
        ),
      ),
      ActivityState.done => const Icon(
        LucideIcons.check,
        size: 17,
        color: AppColors.muted,
      ),
      ActivityState.error => const Icon(
        LucideIcons.circleAlert,
        size: 17,
        color: AppColors.danger,
      ),
      ActivityState.stopped => const Icon(
        LucideIcons.square,
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
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
            side: const BorderSide(color: AppColors.line),
          ),
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
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
            side: const BorderSide(color: AppColors.line),
          ),
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
                    fontFamily: AppTypography.codeFontFamily,
                    fontFamilyFallback: AppTypography.codeFontFamilyFallback,
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
  const ThinkingIndicator({super.key, this.initialElapsedSeconds = 0});

  final int initialElapsedSeconds;

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
    elapsedSeconds = widget.initialElapsedSeconds;
    animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => elapsedSeconds += 1);
    });
  }

  @override
  void didUpdateWidget(covariant ThinkingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialElapsedSeconds > elapsedSeconds) {
      elapsedSeconds = widget.initialElapsedSeconds;
    }
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
    final body = Semantics(
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
              LucideIcons.brain,
              key: ValueKey('thinking-icon'),
              size: 18,
              color: AppColors.terracotta,
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
    return body;
  }
}

int elapsedSecondsSince(DateTime? startedAt) {
  if (startedAt == null) return 0;
  final seconds = DateTime.now().difference(startedAt).inSeconds;
  return seconds < 0 ? 0 : seconds;
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
    this.modelName,
    this.selectedModel = ClaudeModelPreference.followComputer,
    this.presentation,
    this.suggestionMaxHeight = 292,
    required this.onPermissionModeSelected,
    required this.onCommandSelected,
    this.onAddAttachment,
    this.onRemoveAttachment,
    this.onModelPressed,
    required this.onReconnect,
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
  final String? modelName;
  final ClaudeModelPreference selectedModel;
  final ConsolePresentation? presentation;
  final double suggestionMaxHeight;
  final ValueChanged<PermissionMode> onPermissionModeSelected;
  final ValueChanged<String> onCommandSelected;
  final VoidCallback? onAddAttachment;
  final ValueChanged<AttachmentDraft>? onRemoveAttachment;
  final VoidCallback? onModelPressed;
  final VoidCallback onReconnect;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final console =
        presentation ??
        ConsolePresentation.resolve(
          connected: connected,
          offline: offline,
          running: running,
          stopping: stopping,
          uploading: uploading,
        );
    if (console.showsReconnect) {
      return Semantics(
        button: true,
        label: '重新连接电脑',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onReconnect,
            borderRadius: BorderRadius.circular(AppRadii.surface),
            child: Ink(
              key: const ValueKey('composer'),
              width: double.infinity,
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(AppRadii.surface),
                border: Border.all(color: AppColors.line.withValues(alpha: 0.8)),
                boxShadow: AppElevation.softCard(alpha: 0.05),
              ),
              child: Row(
                children: [
                  Container(
                    width: AppSizes.iconControl,
                    height: AppSizes.iconControl,
                    decoration: BoxDecoration(
                      color: AppColors.control,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      LucideIcons.refreshCw,
                      size: 22,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '重新连接',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(
                    LucideIcons.chevronRight,
                    size: 20,
                    color: AppColors.muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        // Keep composer from exploding on huge a11y scales, but honor small reading size.
        textScaler: MediaQuery.textScalerOf(
          context,
        ).clamp(minScaleFactor: 0.85, maxScaleFactor: 1.3),
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final canSend =
              (value.text.trim().isNotEmpty || attachments.isNotEmpty) &&
              console.canCompose;
          final query = commandQuery(value.text);
          final matchingCommands = query == null
              ? const <String>[]
              : filterCommands(commands, query);
          final showSuggestions = query != null && console.canCompose;

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
                key: const ValueKey('composer'),
                constraints: const BoxConstraints(minHeight: AppSizes.composer),
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                  border: Border.all(color: AppColors.line.withValues(alpha: 0.8)),
                  boxShadow: AppElevation.softCard(alpha: 0.05),
                ),
                // Pin content to the box edges: text up top, tools on the floor.
                alignment: Alignment.bottomCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (attachments.isNotEmpty) ...[
                      PendingAttachmentStrip(
                        attachments: attachments,
                        uploading: uploading,
                        onRemove: (attachment) =>
                            onRemoveAttachment?.call(attachment),
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: controller,
                      enabled: console.canCompose,
                      cursorColor: AppColors.terracotta,
                      style: const TextStyle(
                        color: AppColors.ink,
                        fontSize: 15,
                        height: 1.45,
                        fontWeight: FontWeight.w400,
                      ),
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        filled: false,
                        hintText: console.inputHint,
                        hintStyle: const TextStyle(
                          color: AppColors.inactive,
                          fontSize: 14,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                      ),
                    ),
                    Row(
                      children: [
                        _ComposerIconButton(
                          key: const ValueKey('composer-expand-button'),
                          tooltip: '添加内容和设置权限',
                          icon: LucideIcons.plus,
                          onPressed: console.canCompose
                              ? () => showComposerToolsSheet(
                                  context,
                                  permissionMode: permissionMode,
                                  allowBypassPermissions:
                                      allowBypassPermissions,
                                  onPermissionModeSelected:
                                      onPermissionModeSelected,
                                  onAddAttachment: onAddAttachment,
                                )
                              : null,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        _ComposerModelButton(
                          modelName: modelName,
                          selectedModel: selectedModel,
                          onPressed: onModelPressed,
                        ),
                        const Spacer(),
                        if (console.showsStop)
                          SignalPressEffect(
                            enabled: console.canStop,
                            child: SizedBox.square(
                              dimension: AppSizes.touchTarget,
                              child: IconButton(
                                key: const ValueKey('composer-primary-action'),
                                onPressed: console.canStop ? onStop : null,
                                tooltip: console.stopTooltip,
                                padding: EdgeInsets.zero,
                                icon: Container(
                                  key: const ValueKey(
                                    'composer-primary-visual',
                                  ),
                                  width: AppSizes.iconControl,
                                  height: AppSizes.iconControl,
                                  decoration: BoxDecoration(
                                    color: console.canStop
                                        ? AppColors.danger
                                        : AppColors.composerControlFill,
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    LucideIcons.square,
                                    size: 18,
                                    color: console.canStop
                                        ? AppColors.onCta
                                        : AppColors.inactive,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else if (console.phase == ConsolePhase.uploading)
                          const SizedBox(
                            width: AppSizes.touchTarget,
                            height: AppSizes.touchTarget,
                            child: Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: AppColors.terracottaDeep,
                              ),
                            ),
                          )
                        else
                          SignalPressEffect(
                            enabled: canSend,
                            child: SizedBox.square(
                              dimension: AppSizes.touchTarget,
                              child: IconButton(
                                key: const ValueKey('composer-primary-action'),
                                onPressed: canSend ? onSend : null,
                                padding: EdgeInsets.zero,
                                icon: Container(
                                  key: const ValueKey(
                                    'composer-primary-visual',
                                  ),
                                  width: AppSizes.iconControl,
                                  height: AppSizes.iconControl,
                                  decoration: BoxDecoration(
                                    color: canSend
                                        ? AppColors.cta
                                        : AppColors.composerControlFill,
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    LucideIcons.arrowUp,
                                    size: 18,
                                    color: canSend
                                        ? AppColors.onCta
                                        : AppColors.inactive,
                                  ),
                                ),
                                tooltip: '发送',
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

class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox.square(
      dimension: AppSizes.touchTarget,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        icon: Container(
          key: const ValueKey('composer-expand-visual'),
          width: AppSizes.iconControl,
          height: AppSizes.iconControl,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.composerControlFill
                : AppColors.paper,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: enabled
                ? AppColors.composerControlInk
                : AppColors.inactive,
          ),
        ),
      ),
    );
  }
}

class _ComposerModelButton extends StatelessWidget {
  const _ComposerModelButton({
    required this.modelName,
    required this.selectedModel,
    this.onPressed,
  });

  final String? modelName;
  final ClaudeModelPreference selectedModel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = selectedModel == ClaudeModelPreference.followComputer
        ? modelName == null
              ? '模型'
              : formatModelName(modelName!)
        : selectedModel.label;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSizes.touchTarget),
      child: TextButton(
        key: const ValueKey('composer-model-button'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.composerControlInk,
          backgroundColor: AppColors.composerControlFill,
          disabledForegroundColor: AppColors.inactive,
          disabledBackgroundColor: AppColors.paper,
          minimumSize: const Size(0, AppSizes.iconControl),
          maximumSize: const Size(148, AppSizes.touchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
          shape: const StadiumBorder(),
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

Future<void> showComposerToolsSheet(
  BuildContext context, {
  required PermissionMode permissionMode,
  required bool allowBypassPermissions,
  required ValueChanged<PermissionMode> onPermissionModeSelected,
  VoidCallback? onAddAttachment,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '输入选项',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ListTile(
              key: const ValueKey('composer-add-attachment'),
              contentPadding: EdgeInsets.zero,
              enabled: onAddAttachment != null,
              leading: const Icon(LucideIcons.paperclip),
              title: const Text('添加附件'),
              onTap: onAddAttachment == null
                  ? null
                  : () => Navigator.pop(sheetContext, 'attachment'),
            ),
            ListTile(
              key: const ValueKey('permission-mode-chip'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(permissionMode.icon),
              title: const Text('权限模式'),
              subtitle: Text(permissionMode.label),
              trailing: const Icon(LucideIcons.chevronRight),
              onTap: () => Navigator.pop(sheetContext, 'permission'),
            ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == 'attachment') {
    onAddAttachment?.call();
    return;
  }
  await showPermissionModePicker(
    context,
    selected: permissionMode,
    allowBypassPermissions: allowBypassPermissions,
    onSelected: onPermissionModeSelected,
  );
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
                              LucideIcons.file,
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
                          height: 1.2,
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
                          fontSize: 12,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    onPressed: uploading ? null : () => onRemove(attachment),
                    icon: const Icon(LucideIcons.x, size: 18),
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
    PermissionMode.manual => LucideIcons.shield,
    PermissionMode.acceptEdits => LucideIcons.pencil,
    PermissionMode.auto => LucideIcons.sparkles,
    PermissionMode.dontAsk => LucideIcons.ban,
    PermissionMode.plan => LucideIcons.route,
    PermissionMode.bypassPermissions => LucideIcons.triangleAlert,
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
                LucideIcons.chevronDown,
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
                    ? const Icon(LucideIcons.check, color: AppColors.accent)
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
    return Container(
      key: const ValueKey('command-suggestions'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: AppColors.line),
      ),
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
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(
          compact ? AppRadii.surface : AppRadii.header,
        ),
        border: Border.all(color: AppColors.line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          compact ? AppRadii.surface - 1 : AppRadii.header - 1,
        ),
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
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(AppRadii.compact),
                  border: Border.all(color: AppColors.line),
                ),
                child: Text(
                  '对准二维码',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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
    if (preference.kind == ChatBackgroundKind.defaultStyle) {
      return const ColoredBox(color: AppColors.paper);
    }
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
          const ColoredBox(color: AppColors.paper),
          Semantics(
            excludeSemantics: true,
            child: Image.file(
              File(preference.imagePath!),
              key: const ValueKey('custom-chat-background-image'),
              fit: BoxFit.cover,
              cacheWidth: width,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: AppColors.paper),
            ),
          ),
          ColoredBox(
            color: Colors.white.withValues(alpha: preference.overlayOpacity),
          ),
        ],
      );
    }
    final color = switch (preference.preset) {
      ChatBackgroundPreset.mint => const Color(0xFFF0EEE6),
      ChatBackgroundPreset.sunrise => const Color(0xFFF3E7E0),
      ChatBackgroundPreset.rose => const Color(0xFFE9E4DA),
      null => AppColors.paper,
    };
    return ColoredBox(color: color);
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

class WarmSheetSurface extends StatelessWidget {
  const WarmSheetSurface({
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
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppColors.line.withValues(alpha: 0.85)),
        boxShadow: AppElevation.softCard(),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 1),
        child: ColoredBox(
          color: AppColors.surfaceElevated,
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

class StatusLabel extends StatelessWidget {
  const StatusLabel({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null)
                    Icon(icon, size: 20, color: AppColors.terracottaDeep),
                  const Spacer(),
                  const Icon(
                    LucideIcons.arrowUpRight,
                    size: 18,
                    color: AppColors.inactive,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 3),
                Text(
                  caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
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
  const MonoText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = const TextStyle(
      color: AppColors.muted,
      fontFamily: AppTypography.codeFontFamily,
      fontFamilyFallback: AppTypography.codeFontFamilyFallback,
      fontSize: 13,
      height: 1.35,
    );
    return Text(
      text,
      overflow: TextOverflow.ellipsis,
      maxLines: 3,
      style: style == null ? base : base.merge(style),
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
