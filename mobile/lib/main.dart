import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:phosphor_icons/phosphor_icons.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import 'activity_disclosure.dart';
import 'assistant_citations.dart';
import 'attachments.dart';
import 'camera_permission.dart';
import 'conversation_option_sheet.dart';
import 'codex_model_picker.dart';
import 'appearance_preference.dart';
import 'data/api_client.dart';
import 'data/permission_mode.dart';
import 'data/remote_models.dart';
import 'data/websocket_client.dart';
import 'effort_gauge.dart';
import 'effort_preference.dart';
import 'model_preference.dart';
import 'noto_icon.dart';
import 'notification_service.dart';
import 'reading_font_size.dart';
import 'signal_console_theme.dart';
import 'workspace_drawer.dart';
import 'workspace_paths.dart';
import 'session_interaction.dart';
import 'thinking_block.dart';
import 'tool_activity_detail.dart';

export 'thinking_block.dart';

void main() {
  const isPreview = bool.fromEnvironment('CC_REMOTE_PREVIEW');
  runApp(CcRemoteApp(enableCamera: !isPreview, demoMode: isPreview));
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

bool shouldForceReconnectAfterBackground({
  required Duration? backgroundDuration,
  required Duration livenessThreshold,
}) {
  return backgroundDuration != null && backgroundDuration >= livenessThreshold;
}

class CcRemoteApp extends StatefulWidget {
  const CcRemoteApp({
    super.key,
    this.enableCamera = true,
    this.demoMode = false,
    this.wsClient,
    this.apiClient,
    this.notificationService,
    this.notificationPreferenceStore,
    this.modelPreferenceStore,
    this.effortPreferenceStore,
    this.appearancePreferenceStore,
    this.readingFontSizePreferenceStore,
    this.cameraPermissionService,
  });

  final bool enableCamera;
  final bool demoMode;
  final RemoteWebSocketClient? wsClient;
  final RemoteApiClient? apiClient;
  final BackgroundNotificationService? notificationService;
  final NotificationPreferenceStore? notificationPreferenceStore;
  final ClaudeModelPreferenceStore? modelPreferenceStore;
  final ClaudeEffortPreferenceStore? effortPreferenceStore;
  final AppearancePreferenceStore? appearancePreferenceStore;
  final ReadingFontSizePreferenceStore? readingFontSizePreferenceStore;
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
  late final AppearanceController appearance;

  @override
  void initState() {
    super.initState();
    readingFontSizePreferenceStore =
        widget.readingFontSizePreferenceStore ??
        ReadingFontSizePreferenceStore();
    unawaited(initializeReadingFontSize());
    appearance = AppearanceController(
      widget.appearancePreferenceStore ?? AppearancePreferenceStore(),
    );
    unawaited(appearance.initialize());
  }

  @override
  void dispose() {
    readingFontScale.dispose();
    appearance.dispose();
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
    return AppearanceScope(
      controller: appearance,
      child: ListenableBuilder(
        listenable: appearance,
        builder: (context, _) => MaterialApp(
          title: 'CC Remote',
          debugShowCheckedModeBanner: false,
          theme: buildSignalConsoleTheme(),
          darkTheme: buildSignalConsoleTheme(Brightness.dark),
          themeMode: appearance.value,
          themeAnimationDuration: Duration.zero,
          home: DemoShell(
            enableCamera: widget.enableCamera,
            demoMode: widget.demoMode,
            wsClient: widget.wsClient,
            apiClient: widget.apiClient,
            notificationService: widget.notificationService,
            notificationPreferenceStore: widget.notificationPreferenceStore,
            modelPreferenceStore: widget.modelPreferenceStore,
            effortPreferenceStore: widget.effortPreferenceStore,
            cameraPermissionService: widget.cameraPermissionService,
            readingFontScaleListenable: readingFontScale,
            onReadingFontScaleChanged: setReadingFontScale,
          ),
        ),
      ),
    );
  }
}

class DemoShell extends StatefulWidget {
  const DemoShell({
    super.key,
    required this.enableCamera,
    required this.demoMode,
    this.wsClient,
    this.apiClient,
    this.notificationService,
    this.notificationPreferenceStore,
    this.modelPreferenceStore,
    this.effortPreferenceStore,
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
  final RemoteWebSocketClient? wsClient;
  final RemoteApiClient? apiClient;
  final BackgroundNotificationService? notificationService;
  final NotificationPreferenceStore? notificationPreferenceStore;
  final ClaudeModelPreferenceStore? modelPreferenceStore;
  final ClaudeEffortPreferenceStore? effortPreferenceStore;
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

class TranscriptJumpRequest {
  const TranscriptJumpRequest({
    required this.generation,
    required this.sessionId,
    required this.messageIndex,
    required this.role,
    required this.snippet,
  });

  final int generation;
  final String sessionId;
  final int messageIndex;
  final RemoteSessionSearchRole role;
  final String snippet;
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
  static const backgroundReconnectThreshold = Duration(seconds: 60);
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
  BootstrapPhase bootstrapPhase = BootstrapPhase.readingConnection;
  bool running = false;
  bool stopping = false;
  bool pairing = false;
  bool handlingQr = false;
  bool wsReady = false;
  bool remoteOffline = false;
  RemoteConnectionSnapshot reconnectSnapshot =
      const RemoteConnectionSnapshot.idle();
  String? pausedQrRaw;
  String? pairError;
  String? modelName;
  int? contextWindow;
  int? remainingContext;
  String? activeProjectId;
  String? activeSessionId;
  String? activeRunId;
  DateTime? runStartedAt;
  WorkspaceChangeEcho? workspaceChangeEcho;
  int workspaceEchoGeneration = 0;
  int remoteTranscriptRevision = 0;
  bool allowBypassPermissions = false;
  List<CodexSandboxMode> codexSandboxModes = CodexSandboxMode.supportedModes;
  bool notificationsEnabled = true;
  bool notificationsReady = false;
  bool currentRunFailed = false;
  bool uploadingAttachments = false;
  ClaudeModelPreference selectedModel = ClaudeModelPreference.followComputer;
  String? selectedCodexModel;
  final codexModelPreferenceStore = CodexModelPreferenceStore();
  ClaudeEffortPreference selectedEffort = ClaudeEffortPreference.automatic;
  CodexSandboxMode selectedCodexSandboxMode = CodexSandboxMode.dangerFullAccess;
  CodexSandboxMode activeCodexSandboxMode = CodexSandboxMode.dangerFullAccess;
  PermissionMode selectedPermissionMode = PermissionMode.auto;
  PermissionMode activePermissionMode = PermissionMode.auto;
  SavedSession? session;
  late final RemoteWebSocketClient wsClient =
      widget.wsClient ?? RemoteWebSocketClient();
  final TokenStore tokenStore = TokenStore();
  final TranscriptStore transcriptStore = TranscriptStore();
  late final RemoteApiClient apiClient = widget.apiClient ?? RemoteApiClient();
  final TextEditingController promptController = TextEditingController();
  final AttachmentPicker attachmentPicker = AttachmentPicker();
  final List<TranscriptMessage> messages = [];
  final ValueNotifier<int> transcriptRevision = ValueNotifier(0);
  final List<AttachmentDraft> pendingAttachments = [];
  final List<String> commands = [];
  bool commandsLoading = false;
  bool commandsFailed = false;
  String? commandsSessionId;
  int commandCatalogGeneration = 0;
  final List<RemoteProjectSummary> projects = [];
  final List<RemoteSessionSummary> remoteSessions = [];
  final List<RemotePermissionRequest> pendingPermissions = [];
  final Set<String> respondingPermissionIds = {};
  Future<void> lastTranscriptWrite = Future<void>.value();
  Future<void>? refreshConnectionInFlight;
  bool refreshConnectionForcesReconnect = false;
  int connectionRefreshGeneration = 0;
  bool _recoveringUnauthorizedSession = false;
  DateTime? appBackgroundedAt;
  // ponytail: batch stream paint/persist; tighten if first glyph feels late
  static const streamTextBatchInterval = Duration(milliseconds: 80);
  static const streamPersistInterval = Duration(milliseconds: 1500);
  String pendingAssistantText = '';
  Timer? streamTextFlushTimer;
  Timer? streamPersistTimer;
  DateTime? lastStreamPersistAt;
  late final Future<void> modelPreferenceInitialization;
  int modelPreferenceRevision = 0;
  late final Future<void> effortPreferenceInitialization;
  int effortPreferenceRevision = 0;
  int transcriptJumpGeneration = 0;
  TranscriptJumpRequest? transcriptJumpRequest;
  late final BackgroundNotificationService notificationService;
  late final NotificationPreferenceStore notificationPreferenceStore;
  late final BackgroundNotificationController notificationController;
  late final ClaudeModelPreferenceStore modelPreferenceStore;
  late final ClaudeEffortPreferenceStore effortPreferenceStore;
  late final CameraPermissionService cameraPermissionService;
  String? pendingNotificationSessionId;
  QueuedPrompt? queuedPrompt;
  int peekGeneration = 0;
  String? viewingSessionId;
  String? peekTitle;
  List<TranscriptMessage> peekMessages = [];
  bool peekLoading = false;
  bool peekFailed = false;
  int liveMessageCountAtPeek = 0;

  Object? get ws => wsClient.channel;
  SessionEngine get activeSessionEngine {
    for (final item in remoteSessions) {
      if (item.id == activeSessionId) return item.engine;
    }
    return SessionEngine.claude;
  }

  @override
  void initState() {
    super.initState();
    notificationService =
        widget.notificationService ?? LocalBackgroundNotificationService();
    notificationPreferenceStore =
        widget.notificationPreferenceStore ?? NotificationPreferenceStore();
    modelPreferenceStore =
        widget.modelPreferenceStore ?? ClaudeModelPreferenceStore();
    effortPreferenceStore =
        widget.effortPreferenceStore ?? ClaudeEffortPreferenceStore();
    cameraPermissionService =
        widget.cameraPermissionService ?? const SystemCameraPermissionService();
    notificationController = BackgroundNotificationController(
      service: notificationService,
    );
    WidgetsBinding.instance.addObserver(this);
    promptController.addListener(handlePromptChanged);
    unawaited(initializePermissions());
    modelPreferenceInitialization = initializeModelPreference();
    unawaited(modelPreferenceInitialization);
    effortPreferenceInitialization = initializeEffortPreference();
    unawaited(effortPreferenceInitialization);
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
    transcriptRevision.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    notificationController.lifecycleState = state;

    if (state != AppLifecycleState.resumed) {
      if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        appBackgroundedAt ??= DateTime.now();
      }
      return;
    }

    final backgroundDuration = appBackgroundedAt == null
        ? null
        : DateTime.now().difference(appBackgroundedAt!);
    appBackgroundedAt = null;
    final forceReconnect = shouldForceReconnectAfterBackground(
      backgroundDuration: backgroundDuration,
      livenessThreshold: backgroundReconnectThreshold,
    );

    unawaited(cancelNotifications());
    openPendingNotificationSession();
    // Preserve healthy sockets and handshakes already started by auto-recovery.
    unawaited(
      wsClient
          .ensureConnected(
            retryNow: true,
            probeTimeout: RemoteWebSocketClient.resumeProbeTimeout,
            reconnectNowOnProbeFailure: true,
          )
          .then((_) async {
            if (!mounted || wsClient.isAuthenticated) return;
            await refreshConnection(forceReconnect: forceReconnect);
          }),
    );
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
    final codexPreference = await codexModelPreferenceStore.load();
    if (!mounted || revision != modelPreferenceRevision) return;
    setState(() {
      selectedModel = preference;
      selectedCodexModel = codexPreference;
    });
  }

  Future<void> setModelPreference(ClaudeModelPreference preference) async {
    modelPreferenceRevision += 1;
    await modelPreferenceStore.save(preference);
    if (mounted) setState(() => selectedModel = preference);
  }

  Future<void> openModelPicker(BuildContext context) async {
    await modelPreferenceInitialization;
    if (!context.mounted) return;
    if (activeSessionEngine == SessionEngine.codex) {
      final sessionId = activeSessionId;
      final next = await showCodexModelPicker(
        context,
        selected: selectedCodexModel,
        loadModels: loadCodexModels,
      );
      if (next == null || !context.mounted || activeSessionId != sessionId) {
        return;
      }
      try {
        await codexModelPreferenceStore.save(next);
        if (mounted) {
          setState(() => selectedCodexModel = normalizeCodexModel(next));
        }
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('模型设置保存失败，请重试')));
      }
      return;
    }
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

  Future<List<CodexModelOption>> loadCodexModels() async {
    final saved = session;
    final sessionId = activeSessionId;
    if (saved == null || sessionId == null || widget.demoMode) {
      throw const FormatException('model_catalog_unavailable');
    }
    final response = await apiClient.get(
      saved.origin,
      '/api/models?sessionId=${Uri.encodeQueryComponent(sessionId)}',
      token: saved.token,
      timeout: const Duration(seconds: 35),
    );
    if (response.statusCode != 200 ||
        !mounted ||
        session?.origin != saved.origin ||
        session?.token != saved.token ||
        activeSessionId != sessionId) {
      throw const FormatException('model_catalog_unavailable');
    }
    final data = jsonDecode(response.body);
    if (data is! Map ||
        data['sessionId'] != sessionId ||
        data['engine'] != 'codex') {
      throw const FormatException('invalid_model_catalog');
    }
    return CodexModelOption.fromWire(data['models']);
  }

  void resetCommandCatalog() {
    commandCatalogGeneration++;
    commandsSessionId = null;
    commandsLoading = false;
    commandsFailed = false;
  }

  void handlePromptChanged() {
    if (commandQuery(promptController.text) != null &&
        commandsSessionId != activeSessionId) {
      unawaited(refreshCommandCatalog());
    }
  }

  Future<void> refreshCommandCatalog() async {
    final saved = session;
    final sessionId = activeSessionId;
    if (saved == null || sessionId == null || widget.demoMode) return;
    final generation = ++commandCatalogGeneration;
    setState(() {
      commandsSessionId = sessionId;
      commandsLoading = true;
      commandsFailed = false;
    });
    try {
      final response = await apiClient.get(
        saved.origin,
        '/api/commands?sessionId=${Uri.encodeQueryComponent(sessionId)}',
        token: saved.token,
        timeout: const Duration(seconds: 35),
      );
      if (!mounted ||
          generation != commandCatalogGeneration ||
          session?.origin != saved.origin ||
          session?.token != saved.token ||
          activeSessionId != sessionId) {
        return;
      }
      if (response.statusCode != 200) {
        throw const FormatException('commands_unavailable');
      }
      final data = jsonDecode(response.body);
      if (data is! Map ||
          data['sessionId'] != sessionId ||
          data['engine'] != activeSessionEngine.wireName ||
          data['commands'] is! List) {
        throw const FormatException('invalid_command_catalog');
      }
      setState(() {
        commands
          ..clear()
          ..addAll((data['commands'] as List).whereType<String>());
        commandsLoading = false;
      });
    } catch (_) {
      if (!mounted ||
          generation != commandCatalogGeneration ||
          session?.origin != saved.origin ||
          session?.token != saved.token ||
          activeSessionId != sessionId) {
        return;
      }
      setState(() {
        commandsLoading = false;
        commandsFailed = true;
      });
    }
  }

  Future<void> initializeEffortPreference() async {
    final revision = effortPreferenceRevision;
    final preference = await effortPreferenceStore.load();
    if (!mounted || revision != effortPreferenceRevision) return;
    setState(() => selectedEffort = preference);
  }

  Future<void> setEffortPreference(ClaudeEffortPreference preference) async {
    effortPreferenceRevision += 1;
    try {
      await effortPreferenceStore.save(preference);
      if (mounted) setState(() => selectedEffort = preference);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('思考强度保存失败，请重试')));
    }
  }

  void resetSessionOnlyEffort() {
    if (selectedEffort != ClaudeEffortPreference.max) return;
    effortPreferenceRevision += 1;
    selectedEffort = ClaudeEffortPreference.automatic;
  }

  Future<void> requestInitialCameraPermission() async {
    if (!widget.enableCamera || widget.demoMode) return;
    try {
      if (await cameraPermissionService.shouldRequestOnLaunch()) {
        await cameraPermissionService.request();
      }
    } catch (_) {}
  }

  void handleNotificationTap(String? payload) {
    if (payload == null || !payload.startsWith('session:')) return;
    pendingNotificationSessionId = payload.substring('session:'.length);
    openPendingNotificationSession();
  }

  void openPendingNotificationSession() {
    final sessionId = pendingNotificationSessionId;
    if (sessionId == null || route != ShellRoute.chat) return;
    if (uploadingAttachments) return;
    pendingNotificationSessionId = null;
    if (sessionId == activeSessionId) {
      if (viewingSessionId != null) {
        setState(clearSessionPeek);
      }
      return;
    }
    if (!wsReady && !running) return;
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
      sessionId: activeSessionId,
      messages: List<TranscriptMessage>.of(messages),
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
    // Bootstrap no longer waits for this read, so a host snapshot can land
    // first; that state is authoritative and must not be overwritten.
    if (remoteTranscriptRevision > 0) return;
    setState(() {
      activeSessionId = snapshot.sessionId;
      messages
        ..clear()
        ..addAll(snapshot.messages);
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

    if (type == 'permission_capabilities') {
      final messageSessionId = decoded['sessionId'];
      if (messageSessionId is String &&
          activeSessionId != null &&
          messageSessionId != activeSessionId) {
        return false;
      }
    }

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
      // An immediate retry request follows an in-flight soft refresh.
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
      forceReconnect: false,
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
    if (wsClient.isActive) {
      unawaited(wsClient.ensureConnected(retryNow: forceReconnect));
    } else {
      connectWs(current);
    }

    try {
      final status = await fetchStatus(current);
      if (!mounted ||
          session != current ||
          generation != connectionRefreshGeneration) {
        return;
      }
      final hasLiveSocket = wsClient.isAuthenticated;
      final restored = current.copyWith(
        deviceName: status.deviceName,
        workspaceDir: hasLiveSocket
            ? current.workspaceDir
            : status.workspaceDir,
      );
      setState(() {
        session = restored;
        remoteOffline = false;
        // A delayed HTTP response must not overwrite newer WebSocket state.
        if (!hasLiveSocket) {
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
          applyCatalog(status.catalog);
        }
      });
      persistTranscriptSnapshotLater();
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
      if (wsClient.isAuthenticated) return;
      setState(() {
        remoteOffline = true;
      });
      persistTranscriptSnapshotLater();
    }
  }

  Future<void> bootstrap() async {
    if (widget.demoMode) {
      if (mounted && route == ShellRoute.boot) {
        setState(() => route = ShellRoute.pair);
      }
      return;
    }

    final saved = await tokenStore.load();
    if (!mounted) return;
    if (saved == null) {
      updateBootstrapPhase(BootstrapPhase.preparingPairing);
      await clearTranscriptStore();
      if (!mounted) return;
      setState(() => route = ShellRoute.pair);
      return;
    }

    updateBootstrapPhase(BootstrapPhase.restoringSession);
    // Load the cached transcript without blocking the handshake: secure
    // storage reads for long sessions must not delay the first connect.
    final transcriptRestored = restoreTranscriptSnapshot();
    if (!mounted) return;
    updateBootstrapPhase(BootstrapPhase.contactingHost);
    setState(() {
      session = saved;
      route = ShellRoute.chat;
      wsReady = false;
      remoteOffline = false;
    });
    connectWs(saved);

    try {
      final status = await fetchStatus(saved);
      // Merge the cached transcript before applying status so a late disk
      // read cannot overwrite fresher host state.
      await transcriptRestored;
      if (!mounted ||
          route != ShellRoute.chat ||
          session == null ||
          _recoveringUnauthorizedSession) {
        return;
      }
      final current = session!;
      final hasLiveSocket = wsClient.isAuthenticated;
      final restored = current.copyWith(
        deviceName: status.deviceName,
        workspaceDir: hasLiveSocket
            ? current.workspaceDir
            : status.workspaceDir,
      );
      setState(() {
        session = restored;
        remoteOffline = false;
        if (!hasLiveSocket) {
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
        }
      });
      persistTranscriptSnapshotLater();
    } catch (err) {
      await transcriptRestored;
      if (!mounted ||
          route != ShellRoute.chat ||
          session == null ||
          _recoveringUnauthorizedSession) {
        return;
      }
      if (err is UnauthorizedSession) {
        await recoverUnauthorizedSession();
        return;
      }
      if (!wsClient.isAuthenticated) {
        setState(() {
          wsReady = false;
          remoteOffline = true;
          stopping = false;
        });
      }
      persistTranscriptSnapshotLater();
    }
  }

  void updateBootstrapPhase(BootstrapPhase phase) {
    if (!mounted || route != ShellRoute.boot || bootstrapPhase == phase) return;
    setState(() => bootstrapPhase = phase);
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
      projects
        ..clear()
        ..addAll(const [
          RemoteProjectSummary(
            id: 'demo-cc-remote',
            name: 'cc-remote',
            path: '/workspace/cc-remote',
            sessionCount: 2,
            running: false,
          ),
          RemoteProjectSummary(
            id: 'demo-mobile',
            name: 'mobile',
            path: '/workspace/cc-remote/mobile',
            sessionCount: 1,
            running: false,
          ),
        ]);
      remoteSessions
        ..clear()
        ..addAll(const [
          RemoteSessionSummary(
            id: 'demo-session-polish',
            projectId: 'demo-cc-remote',
            title: '图标改成实心小标',
            updatedAt: 3,
            running: false,
            messageCount: 8,
          ),
          RemoteSessionSummary(
            id: 'demo-session-glass',
            projectId: 'demo-cc-remote',
            title: '玻璃控制面',
            updatedAt: 2,
            running: false,
            messageCount: 4,
          ),
          RemoteSessionSummary(
            id: 'demo-session-mobile',
            projectId: 'demo-mobile',
            title: '配对页扫码',
            engine: SessionEngine.codex,
            updatedAt: 1,
            running: false,
            messageCount: 3,
          ),
        ]);
      activeProjectId = 'demo-cc-remote';
      activeSessionId = 'demo-session-polish';
    });
  }

  void closeWs() {
    wsClient.close();
    wsReady = false;
    reconnectSnapshot = const RemoteConnectionSnapshot.idle();
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
        onState: handleWsConnectionState,
      );
    } catch (err) {
      handleWsClosed('连接失败：$err');
    }
  }

  void handleWsConnectionState(RemoteConnectionSnapshot snapshot) {
    reconnectSnapshot = snapshot;
    if (!mounted || route != ShellRoute.chat) return;
    setState(() {
      reconnectSnapshot = snapshot;
      if (snapshot.phase == RemoteConnectionPhase.connecting) {
        respondingPermissionIds.clear();
      }
      if (snapshot.phase == RemoteConnectionPhase.connected) {
        wsReady = true;
        remoteOffline = false;
      }
    });
  }

  void reconnectNow() {
    if (widget.demoMode || route != ShellRoute.chat || session == null) return;
    connectionRefreshGeneration += 1;
    refreshConnectionInFlight = null;
    refreshConnectionForcesReconnect = false;
    if (wsClient.reconnect()) {
      setState(() {
        wsReady = false;
        remoteOffline = true;
      });
      return;
    }
    unawaited(refreshConnection(forceReconnect: true));
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
        setState(() => applyCatalog(catalog));
        if (session != null) unawaited(tokenStore.save(session!));
        openPendingNotificationSession();
      case 'status':
        final wasRunning = running;
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
        if (wasRunning && !running) releaseQueuedPromptIfTurnIdle();

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
        final wasRunning = running;
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
          selectedPermissionMode = snapshot.permissionMode;
          activeCodexSandboxMode = snapshot.codexSandboxMode;
          selectedCodexSandboxMode =
              codexSandboxModes.contains(snapshot.codexSandboxMode)
              ? snapshot.codexSandboxMode
              : codexSandboxModes.first;
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
        if (wasRunning && !running) releaseQueuedPromptIfTurnIdle();
        if (viewingSessionId != null && pendingPermissions.isNotEmpty) {
          setState(clearSessionPeek);
        }

      case 'permission_capabilities':
        setState(() {
          allowBypassPermissions = decoded['allowBypassPermissions'] == true;
          codexSandboxModes =
              CodexSandboxMode.listFromWire(decoded['codexSandboxModes']) ??
              CodexSandboxMode.supportedModes;
          if (!codexSandboxModes.contains(selectedCodexSandboxMode)) {
            selectedCodexSandboxMode = codexSandboxModes.first;
          }
          if (!allowBypassPermissions &&
              selectedPermissionMode == PermissionMode.bypassPermissions) {
            selectedPermissionMode = PermissionMode.auto;
          }
        });
      case 'permission_request':
        final request = RemotePermissionRequest.tryParse(decoded);
        if (request == null) return;
        setState(() {
          if (viewingSessionId != null) clearSessionPeek();

          final index = pendingPermissions.indexWhere(
            (item) => item.requestId == request.requestId,
          );
          if (index >= 0) {
            pendingPermissions[index] = request;
          } else {
            pendingPermissions.add(request);
            // A permission decision is the product's highest-stakes moment;
            // give it the same physical nudge the gauge detents already use.
            HapticFeedback.selectionClick();
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
          if (viewingSessionId != null) clearSessionPeek();
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
          commandsSessionId = decoded['loaded'] == false
              ? null
              : activeSessionId;
          commandsLoading = decoded['loading'] == true;
          commandsFailed = decoded['error'] != null;
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
          activePermissionMode = selectedPermissionMode;
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
        unawaited(refreshWorkspaceChangeEcho());
        releaseQueuedPromptAfterTurn('done');

      case 'stopped':
        flushStreamTextBatch();
        setState(() {
          running = false;
          stopping = false;
          currentRunFailed = false;
          activeRunId = null;
          runStartedAt = null;
          removeDisconnectedRunNotice();
          activePermissionMode = selectedPermissionMode;
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
        unawaited(refreshWorkspaceChangeEcho());
        releaseQueuedPromptAfterTurn('stopped');

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
          activePermissionMode = selectedPermissionMode;
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
        unawaited(refreshWorkspaceChangeEcho());
        releaseQueuedPromptAfterTurn('error');
    }
  }

  Future<void> recoverUnauthorizedSession() async {
    if (_recoveringUnauthorizedSession) return;
    _recoveringUnauthorizedSession = true;
    try {
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
        clearWorkspaceChangeEcho();
        clearSessionPeek();
        queuedPrompt = null;

        messages.clear();
        commands.clear();
        resetCommandCatalog();
        projects.clear();
        remoteSessions.clear();
        activeProjectId = null;
        activeSessionId = null;
        activeRunId = null;
        runStartedAt = null;
        remoteTranscriptRevision = 0;
        allowBypassPermissions = false;
        selectedPermissionMode = PermissionMode.auto;
        activePermissionMode = PermissionMode.auto;
        pendingPermissions.clear();
        respondingPermissionIds.clear();
      });
    } finally {
      _recoveringUnauthorizedSession = false;
    }
  }

  void handleWsClosed(String _) {
    if (!mounted || route != ShellRoute.chat) return;
    flushStreamTextBatch();
    setState(() {
      wsReady = false;
      remoteOffline = true;
      respondingPermissionIds.clear();
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
    // Keep whitespace deltas for streaming merge, but never start a blank bubble.
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
    if (text.isEmpty) return;
    // Hold a pure whitespace prefix until visible text arrives so indent is kept.
    if (text.trim().isEmpty) {
      final lastIsAssistant =
          messages.isNotEmpty && messages.last.role == MessageRole.assistant;
      if (!lastIsAssistant) return;
    }
    pendingAssistantText = '';
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
    if (!mounted) return;
    final lastIsAssistant =
        messages.isNotEmpty && messages.last.role == MessageRole.assistant;
    // Prefix-only whitespace must not open a bubble or finish thinking yet.
    if (!lastIsAssistant && text.trim().isEmpty) {
      return;
    }
    if (lastIsAssistant) {
      final lastIndex = messages.length - 1;
      final merged = messages[lastIndex].text + text;
      if (merged.trim().isEmpty) return;
      messages[lastIndex] = TranscriptMessage.assistant(merged);
    } else {
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
      messages.add(TranscriptMessage.assistant(text));
    }
    transcriptRevision.value++;
    if (persist) persistTranscriptSnapshotLater();
  }

  Future<void> sendPrompt() async {
    final text = promptController.text.trim();
    if (text.isEmpty && pendingAttachments.isEmpty) {
      return;
    }
    await Future.wait([
      modelPreferenceInitialization,
      effortPreferenceInitialization,
    ]);
    if (!mounted || uploadingAttachments) return;
    if (viewingSessionId != null) return;
    if (running) {
      if (queuedPrompt != null) return;
      final sessionId = activeSessionId;
      if (sessionId == null) return;
      setState(() {
        queuedPrompt = QueuedPrompt(
          sessionId: sessionId,
          text: text,
          attachments: List<AttachmentDraft>.from(pendingAttachments),
          permissionMode: selectedPermissionMode,
          codexSandboxMode: selectedCodexSandboxMode,
        );
        promptController.clear();
        pendingAttachments.clear();
      });
      HapticFeedback.selectionClick();
      return;
    }

    final engine = activeSessionEngine;

    if (widget.demoMode) {
      setState(() {
        promptController.clear();
        pendingAttachments.clear();
        running = false;
        stopping = false;
        clearWorkspaceChangeEcho();
        messages
          ..add(TranscriptMessage.user(text))
          ..add(TranscriptMessage.assistant('演示模式：真实对话需要连接 daemon WebSocket。'));
      });
      persistTranscriptSnapshotLater();
      unawaited(refreshWorkspaceChangeEcho());
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
    if (engine == SessionEngine.codex &&
        drafts.any((attachment) => !attachment.isImage)) {
      showAttachmentError(const AttachmentException('codex_images_only'));
      return;
    }
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
    final codexSandboxMode = selectedCodexSandboxMode;
    final sent = wsClient.sendPrompt(
      buildPromptMessage(
        promptId: createPromptId(),
        text: text,
        attachmentIds: uploaded.map((attachment) => attachment.id),
        permissionMode: permissionMode,
        sessionId: currentSessionId,
        model: selectedModel,
        codexModel: selectedCodexModel,
        effort: selectedEffort,
        engine: engine,
        codexSandboxMode: codexSandboxMode,
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
      clearWorkspaceChangeEcho();
      runStartedAt = DateTime.now();
      currentRunFailed = false;
      activePermissionMode = permissionMode;
      activeCodexSandboxMode = codexSandboxMode;
      beginPrompt(messages, text, attachments: uploaded);
    });
    persistTranscriptSnapshotLater();
  }

  Future<void> chooseAttachments() async {
    if (uploadingAttachments || queuedPrompt != null) return;

    if (pendingAttachments.length >= maxAttachmentsPerPrompt) {
      showAttachmentError(const AttachmentException('too_many_attachments'));
      return;
    }
    FocusScope.of(context).unfocus();
    final engine = activeSessionEngine;
    final source = await showAttachmentSourceSheet(
      context,
      imagesOnly: engine == SessionEngine.codex,
    );
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
      if (engine == SessionEngine.codex &&
          picked.any((attachment) => !attachment.isImage)) {
        throw const AttachmentException('codex_images_only');
      }
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
    if (uploadingAttachments || queuedPrompt != null) return;
    setState(() => pendingAttachments.remove(attachment));
  }

  void showAttachmentError(Object error) {
    final code = error is AttachmentException ? error.code : error.toString();
    final message = switch (code) {
      'too_many_attachments' => '一次最多发送 5 个附件',
      'attachment_too_large' => '单个附件不能超过 25MB',
      'attachment_empty' => '不能发送空文件',
      'upload_aborted' => '上传已中断，请重试',
      'codex_images_only' => 'Codex 会话只支持图片附件',
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

  void selectCodexSandboxMode(CodexSandboxMode mode) {
    if (running) return;
    setState(() => selectedCodexSandboxMode = mode);
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
      unawaited(refreshWorkspaceChangeEcho());
      releaseQueuedPromptAfterTurn('stopped');

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
    var engine = SessionEngine.claude;
    if (!widget.demoMode) {
      final selected = await showSessionEnginePicker(
        context,
        selected: activeSessionEngine,
      );
      if (selected == null || !mounted) return;
      engine = selected;
      if (running || uploadingAttachments) return;
    }

    if (widget.demoMode) {
      setState(() {
        resetSessionOnlyEffort();
        modelName = null;
        contextWindow = null;
        remainingContext = null;
        clearStreamTextBatch(apply: false);
        transcriptJumpRequest = null;
        clearWorkspaceChangeEcho();
        clearSessionPeek();
        queuedPrompt = null;

        messages
          ..clear()
          ..add(TranscriptMessage.system('已开启新对话'));
        pendingAttachments.clear();
        uploadingAttachments = false;
        selectedPermissionMode = PermissionMode.auto;
        activePermissionMode = PermissionMode.auto;
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
        body: jsonEncode({'engine': engine.wireName}),
        jsonBody: true,
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
        resetSessionOnlyEffort();
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
        transcriptJumpRequest = null;
        clearWorkspaceChangeEcho();
        clearSessionPeek();
        queuedPrompt = null;

        messages.clear();
        pendingAttachments.clear();
        uploadingAttachments = false;
        pendingPermissions.clear();
        respondingPermissionIds.clear();
        selectedPermissionMode = PermissionMode.auto;
        activePermissionMode = PermissionMode.auto;
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
    if (queuedPrompt != null || viewingSessionId != null) return;
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
      transcriptJumpRequest = null;
      clearWorkspaceChangeEcho();
      clearSessionPeek();
      queuedPrompt = null;

      messages.clear();
      commands.clear();
      resetCommandCatalog();
      projects.clear();
      remoteSessions.clear();
      activeProjectId = null;
      activeSessionId = null;
      activeRunId = null;
      runStartedAt = null;
      remoteTranscriptRevision = 0;
      allowBypassPermissions = false;
      selectedPermissionMode = PermissionMode.auto;
      activePermissionMode = PermissionMode.auto;
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
    openWorkspaceAt();
  }

  void openWorkspaceAt({int tab = 0, String? path}) {
    final current = session;
    if (current == null) return;
    showWorkspaceDrawer(
      context,
      origin: current.origin,
      token: current.token,
      workspaceName: current.workspaceName,
      demoMode: widget.demoMode,
      initialTab: tab,
      initialPath: path,
    );
  }

  void openWorkspacePath(String path) {
    openWorkspaceAt(path: path);
  }

  void openWorkspaceChanges() {
    final path = workspaceChangeEcho?.focusPath;
    if (path != null) {
      openWorkspaceAt(tab: 1, path: path);
      return;
    }
    openWorkspaceAt(tab: 1);
  }

  void clearWorkspaceChangeEcho() {
    workspaceEchoGeneration += 1;
    workspaceChangeEcho = null;
  }

  Future<void> refreshWorkspaceChangeEcho() async {
    final current = session;
    if (current == null) return;
    final generation = ++workspaceEchoGeneration;
    final api = WorkspaceApi(
      origin: current.origin,
      token: current.token,
      demoMode: widget.demoMode,
    );
    try {
      final snapshot = await api.snapshot();
      if (!mounted || generation != workspaceEchoGeneration) return;
      final changes = [
        for (final change in snapshot.changes)
          if (change.path.trim().isNotEmpty) change.path,
      ];
      setState(() {
        workspaceChangeEcho = changes.isEmpty
            ? null
            : WorkspaceChangeEcho(
                changeCount: changes.length,
                paths: changes,
                branch: snapshot.branch,
              );
      });
    } catch (_) {
      if (!mounted || generation != workspaceEchoGeneration) return;
    } finally {
      api.close();
    }
  }

  void applyCatalog(RemoteProjectCatalog? catalog) {
    if (catalog == null) return;
    final changedSession =
        activeSessionId != catalog.activeSessionId &&
        (activeSessionId != null || messages.isNotEmpty);
    final clearEcho = workspaceEchoShouldClear(
      currentSessionId: activeSessionId,
      nextSessionId: catalog.activeSessionId,
      currentWorkspaceDir: session?.workspaceDir,
      nextWorkspaceDir: catalog.activeProject?.path,
    );
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
      commands.clear();
      resetCommandCatalog();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) handlePromptChanged();
      });
      pendingPermissions.clear();
      respondingPermissionIds.clear();
      modelName = null;
      contextWindow = null;
      remainingContext = null;
      selectedPermissionMode = PermissionMode.auto;
      activePermissionMode = PermissionMode.auto;
      clearSessionPeek();
      queuedPrompt = null;
    }
    if (clearEcho) {
      clearWorkspaceChangeEcho();
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
      onSearchResult: openRemoteSearchResult,
      onCreate: createRemoteSession,
      onRename: renameRemoteSession,
      onArchive: archiveRemoteSession,
      onDelete: deleteRemoteSession,
      onSearch: searchRemoteSessions,
    );
  }

  Future<List<RemoteSessionSearchResult>> searchRemoteSessions(
    String query,
  ) async {
    if (widget.demoMode) return const [];
    final current = session;
    if (current == null) return const [];
    final encodedQuery = Uri(
      queryParameters: {'q': query, 'limit': '50'},
    ).query;
    final res = await apiClient.get(
      current.origin,
      '/api/search/sessions?$encodedQuery',
      token: current.token,
      timeout: networkTimeout,
    );
    if (res.statusCode == 401) {
      await recoverUnauthorizedSession();
      throw const UnauthorizedSession();
    }
    if (res.statusCode != 200) throw StateError('session_search_failed');
    final body = jsonDecode(res.body);
    if (body is! Map<String, dynamic> || body['results'] is! List) {
      throw const FormatException('bad_session_search_response');
    }
    return (body['results'] as List)
        .whereType<Map>()
        .map(
          (item) => RemoteSessionSearchResult.tryParse(
            Map<String, dynamic>.from(item),
          ),
        )
        .whereType<RemoteSessionSearchResult>()
        .toList();
  }

  SessionPeekView? currentSessionPeek() {
    final sessionId = viewingSessionId;
    if (sessionId == null) return null;
    return SessionPeekView(
      sessionId: sessionId,
      title: peekTitle ?? '会话',
      messages: peekMessages,
      loading: peekLoading,
      failed: peekFailed,
      liveRunning: running,
      hasLiveUpdate: messages.length > liveMessageCountAtPeek,
      queuedPreview: queuedPrompt?.preview,
    );
  }

  void clearSessionPeek() {
    peekGeneration += 1;
    viewingSessionId = null;
    peekTitle = null;
    peekMessages = [];
    peekLoading = false;
    peekFailed = false;
  }

  void restoreQueuedPrompt() {
    final queued = queuedPrompt;
    if (queued == null) return;
    queuedPrompt = null;
    if (promptController.text.trim().isEmpty && pendingAttachments.isEmpty) {
      promptController.text = queued.text;
      promptController.selection = TextSelection.collapsed(
        offset: queued.text.length,
      );
      pendingAttachments.addAll(queued.attachments);
      selectedPermissionMode = queued.permissionMode;
      selectedCodexSandboxMode = queued.codexSandboxMode;
    }
  }

  void releaseQueuedPromptIfTurnIdle() {
    if (queuedPrompt == null || running || uploadingAttachments) return;
    setState(restoreQueuedPrompt);
  }

  void releaseQueuedPromptAfterTurn(String endType) {
    if (queuedPrompt == null) return;
    if (queuedPromptReleaseForTurn(endType) == QueuedPromptRelease.send) {
      unawaited(flushQueuedPromptSend());
      return;
    }
    setState(restoreQueuedPrompt);
  }

  Future<void> flushQueuedPromptSend() async {
    final queued = queuedPrompt;
    if (queued == null) return;
    queuedPrompt = null;
    if (viewingSessionId != null) {
      setState(clearSessionPeek);
    }
    if (!mounted ||
        !shouldFlushQueuedPrompt(
          running: running,
          uploading: uploadingAttachments,
          queuedSessionId: queued.sessionId,
          activeSessionId: activeSessionId,
        )) {
      queuedPrompt = queued;
      return;
    }
    setState(() {
      promptController.text = queued.text;
      promptController.selection = TextSelection.collapsed(
        offset: queued.text.length,
      );
      pendingAttachments
        ..clear()
        ..addAll(queued.attachments);
      selectedPermissionMode = queued.permissionMode;
      selectedCodexSandboxMode = queued.codexSandboxMode;
    });
    await sendPrompt();
  }

  Future<void> openSessionPeek(
    RemoteSessionSummary target, {
    TranscriptJumpRequest? jump,
  }) async {
    final generation = ++peekGeneration;
    setState(() {
      viewingSessionId = target.id;
      peekTitle = target.title;
      peekMessages = [TranscriptMessage.system('正在读取会话…')];

      peekLoading = true;
      peekFailed = false;
      liveMessageCountAtPeek = messages.length;
      transcriptJumpRequest = jump;
    });
    try {
      final payload = widget.demoMode
          ? SessionPeekPayload(
              sessionId: target.id,
              projectId: target.projectId,
              title: target.title,
              messages: demoSessionPeekMessages(target.id),
            )
          : await fetchSessionPeek(target.id);
      if (!mounted || generation != peekGeneration) return;
      if (payload == null) {
        setState(() {
          peekLoading = false;
          peekFailed = true;
        });
        return;
      }
      setState(() {
        peekTitle = payload.title;
        peekMessages = payload.messages;
        peekLoading = false;
        peekFailed = false;
      });
    } catch (_) {
      if (!mounted || generation != peekGeneration) return;
      setState(() {
        peekLoading = false;
        peekFailed = true;
      });
    }
  }

  Future<SessionPeekPayload?> fetchSessionPeek(String sessionId) async {
    final current = session;
    if (current == null) return null;
    final res = await apiClient.get(
      current.origin,
      '/api/sessions/${Uri.encodeComponent(sessionId)}',
      token: current.token,
      timeout: networkTimeout,
    );
    if (res.statusCode == 401) {
      await recoverUnauthorizedSession();
      return null;
    }
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    if (body is! Map<String, dynamic>) return null;
    return SessionPeekPayload.tryParse(body);
  }

  void selectRemoteSession(String sessionId) {
    selectRemoteSessionWithJump(sessionId);
  }

  void openRemoteSearchResult(RemoteSessionSearchResult result) {
    final jump = result.messageIndex < 0
        ? null
        : TranscriptJumpRequest(
            generation: ++transcriptJumpGeneration,
            sessionId: result.sessionId,
            messageIndex: result.messageIndex,
            role: result.role,
            snippet: result.snippet,
          );
    if (result.sessionId == activeSessionId && jump == null) {
      if (viewingSessionId != null) {
        selectRemoteSessionWithJump(result.sessionId);
        return;
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('当前已在这个会话')));
      return;
    }
    selectRemoteSessionWithJump(result.sessionId, jump: jump);
  }

  bool selectRemoteSessionWithJump(
    String sessionId, {
    TranscriptJumpRequest? jump,
  }) {
    if (sessionId == activeSessionId) {
      final wasPeeking = viewingSessionId != null;
      if (!wasPeeking && jump == null) return false;
      setState(() {
        if (wasPeeking) clearSessionPeek();
        if (jump != null) transcriptJumpRequest = jump;
      });
      return true;
    }
    if (uploadingAttachments) return false;
    RemoteSessionSummary? target;
    for (final item in remoteSessions) {
      if (item.id == sessionId) {
        target = item;
        break;
      }
    }
    if (target == null || target.archived) return false;
    final intent = sessionOpenIntent(
      targetSessionId: sessionId,
      activeSessionId: activeSessionId,
      running: running,
      uploading: uploadingAttachments,
      wsReady: wsReady,
      archived: target.archived,
    );
    if (intent == SessionOpenIntent.peek) {
      if (pendingPermissions.isNotEmpty) return false;
      unawaited(openSessionPeek(target, jump: jump));
      return true;
    }
    if (intent != SessionOpenIntent.switchActive) return false;
    if (widget.demoMode) {
      final selected = target;
      setState(() {
        clearSessionPeek();
        transcriptJumpRequest = jump;
        if (selectedEffort == ClaudeEffortPreference.max) {
          resetSessionOnlyEffort();
        }
        activeSessionId = selected.id;
        activeProjectId = selected.projectId;
        queuedPrompt = null;
        pendingAttachments.clear();
        pendingPermissions.clear();
        respondingPermissionIds.clear();
        uploadingAttachments = false;
        stopping = false;
        remoteTranscriptRevision = 0;
        clearStreamTextBatch(apply: false);
        clearWorkspaceChangeEcho();
        messages
          ..clear()
          ..addAll(demoSessionPeekMessages(selected.id));
        for (final project in projects) {
          if (project.id == selected.projectId && session != null) {
            session = session!.copyWith(workspaceDir: project.path);
            break;
          }
        }
      });
      persistTranscriptSnapshotLater();
      return true;
    }
    final sent = wsClient.send({
      'type': 'select_session',
      'sessionId': sessionId,
    });
    if (!sent) return false;
    setState(() {
      clearSessionPeek();
      transcriptJumpRequest = jump;
      if (selectedEffort == ClaudeEffortPreference.max) {
        resetSessionOnlyEffort();
      }
    });
    return true;
  }

  void handleTranscriptJumpHandled(TranscriptJumpRequest request) {
    if (transcriptJumpRequest?.generation != request.generation) return;
    setState(() => transcriptJumpRequest = null);
  }

  Future<void> createRemoteSession(
    String projectId,
    SessionEngine engine,
  ) async {
    if (running || uploadingAttachments) return;
    final current = session;
    if (current == null) return;
    try {
      final res = await apiClient.post(
        current.origin,
        '/api/projects/$projectId/sessions',
        token: current.token,
        body: jsonEncode({'engine': engine.wireName}),
        jsonBody: true,
        timeout: networkTimeout,
      );
      if (res.statusCode == 401) throw const UnauthorizedSession();
      if (res.statusCode != 201) throw StateError('create_session_failed');
      if (!mounted || session != current) return;
      final body = jsonDecode(res.body);
      final rawCatalog = body is Map<String, dynamic> ? body['catalog'] : null;
      final catalog = rawCatalog is Map<String, dynamic>
          ? RemoteProjectCatalog.tryParse(rawCatalog)
          : null;
      if (catalog == null) {
        throw const FormatException('bad_create_session_response');
      }
      setState(() {
        resetSessionOnlyEffort();
        applyCatalog(catalog);
      });
      if (session != null) await tokenStore.save(session!);
      persistTranscriptSnapshotLater();
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
        resetCommandCatalog();
        remoteTranscriptRevision = 0;
        allowBypassPermissions = false;
        selectedPermissionMode = PermissionMode.auto;
        activePermissionMode = PermissionMode.auto;
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
      ShellRoute.boot => BootstrapScreen(phase: bootstrapPhase),
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
        reconnectSnapshot: reconnectSnapshot,
        modelName: modelName,
        selectedModel: selectedModel,
        selectedCodexModel: selectedCodexModel,
        engine: activeSessionEngine,
        selectedEffort: selectedEffort,
        contextWindow: contextWindow,
        remainingContext: remainingContext,
        messages: messages,
        transcriptRevisionListenable: transcriptRevision,
        transcriptJumpRequest: transcriptJumpRequest,
        readingFontScaleListenable: widget.readingFontScaleListenable,
        commands: commands,
        commandsLoading: commandsLoading,
        commandsFailed: commandsFailed,
        onRefreshCommands: () => unawaited(refreshCommandCatalog()),
        permissionMode: running ? activePermissionMode : selectedPermissionMode,
        allowBypassPermissions: allowBypassPermissions,
        codexSandboxModes: codexSandboxModes,
        codexSandboxMode: running
            ? activeCodexSandboxMode
            : selectedCodexSandboxMode,
        pendingPermissions: pendingPermissions,
        respondingPermissionIds: respondingPermissionIds,
        promptController: promptController,
        pendingAttachments: pendingAttachments,
        onFillPrompt: fillPrompt,
        onReconnect: reconnectNow,
        onOpenSettings: () => showSettingsSheet(
          context,
          session,
          notificationsEnabled,
          modelName,
          selectedModel,
          widget.readingFontScaleListenable.value,
          refreshConnection,
          setNotificationsEnabled,
          setModelPreference,
          widget.onReadingFontScaleChanged,
          logoutPairedDevice,
        ),
        onOpenModelPicker: () => openModelPicker(context),
        onEffortSelected: (effort) => unawaited(setEffortPreference(effort)),
        onNewConversation: beginNewConversation,
        onOpenSessions: openSessions,
        onOpenWorkspace: openWorkspace,
        onOpenWorkspaceChanges: openWorkspaceChanges,
        onOpenWorkspacePath: openWorkspacePath,
        workspaceChangeEcho: workspaceChangeEcho,
        onTranscriptJumpHandled: handleTranscriptJumpHandled,
        onPermissionModeSelected: selectPermissionMode,
        onCodexSandboxModeSelected: selectCodexSandboxMode,
        onPermissionAllow: (request) => respondToPermission(request, 'allow'),
        onPermissionDeny: (request) => respondToPermission(request, 'deny'),
        onAddAttachment: chooseAttachments,
        onRemoveAttachment: removePendingAttachment,
        onSend: sendPrompt,
        onStop: stopRun,
        peek: currentSessionPeek(),
        onExitPeek: () => setState(clearSessionPeek),
        queuedPreview: queuedPrompt?.preview,
        onCancelQueue: () => setState(restoreQueuedPrompt),
      ),
    };
    final colors = AppPalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: colors.paper,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: AppBackground(
        child: AnimatedSwitcher(
          key: const ValueKey('shell-route-switcher'),
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
            // Fade+slide over a boundary: shell rasters are cached and each
            // transition frame only re-composites them.
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: offset,
                child: SnapshotWhileAnimating(
                  animation: animation,
                  child: RepaintBoundary(child: child),
                ),
              ),
            );
          },
          child: KeyedSubtree(key: ValueKey(route), child: screen),
        ),
      ),
    );
  }
}

enum ShellRoute { boot, pair, chat }

enum BootstrapPhase {
  readingConnection('正在读取连接信息'),
  preparingPairing('正在准备配对'),
  restoringSession('正在恢复上次会话'),
  contactingHost('正在检查桌面主机');

  const BootstrapPhase(this.label);
  final String label;
}

class BootstrapScreen extends StatelessWidget {
  const BootstrapScreen({
    super.key,
    this.phase = BootstrapPhase.readingConnection,
  });

  final BootstrapPhase phase;

  @override
  Widget build(BuildContext context) {
    final colors = AppPalette.of(context);
    return ColoredBox(
      key: const ValueKey('boot'),
      color: colors.paper,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.monitorSmartphone,
                  size: AppIconSizes.hero,
                  color: colors.ink,
                ),
                const SizedBox(height: 20),
                Text(
                  'CC Remote',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    phase.label,
                    style: TextStyle(color: colors.muted),
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
        placeholderBuilder: (context) =>
            ColoredBox(color: AppPalette.of(context).control),
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
                          Row(
                            children: [
                              Icon(
                                LucideIcons.smartphone,
                                size: AppIconSizes.control,
                                color: AppPalette.of(context).accentStrong,
                              ),
                              SizedBox(width: 7),
                              Text(
                                '首次连接',
                                style: TextStyle(
                                  color: AppPalette.of(context).muted,
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
                          Text(
                            '扫描电脑终端里的二维码',
                            style: TextStyle(
                              color: AppPalette.of(context).muted,
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
                        color: AppPalette.of(context).surface,
                        borderRadius: BorderRadius.circular(AppRadii.surface),
                        border: Border.all(color: AppPalette.of(context).line),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        LucideIcons.monitor,
                        size: AppIconSizes.primary,
                        color: AppPalette.of(context).accentStrong,
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
                    color: AppPalette.of(context).surface,
                    borderRadius: BorderRadius.circular(AppRadii.surface),
                    border: Border.all(color: AppPalette.of(context).line),
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
                              color: AppPalette.of(context).control,
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              LucideIcons.scanLine,
                              size: AppIconSizes.control,
                              color: AppPalette.of(context).accentStrong,
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
                                        ? AppPalette.of(context).muted
                                        : AppPalette.of(context).danger,
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
                                ? AppPalette.of(context).muted
                                : AppPalette.of(context).danger,
                          ),
                        ],
                      ),
                      if (widget.pairing) ...[
                        const SizedBox(height: 14),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                          child: LinearProgressIndicator(
                            minHeight: 2,
                            color: AppPalette.of(context).accent,
                            backgroundColor: AppPalette.of(context).line,
                          ),
                        ),
                      ],
                      if (widget.onDemoConnect != null) ...[
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: SignalPressEffect(
                            scaleOnPress: false,
                            child: FilledButton.icon(
                              onPressed: widget.onDemoConnect,
                              icon: const SmartIcon(LucideIcons.link),
                              label: const Text('连接这台电脑'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppPalette.of(context).cta,
                                foregroundColor: AppPalette.of(context).onCta,
                                minimumSize: const Size.fromHeight(52),
                              ),
                            ),
                          ),
                        ),
                      ] else if (!widget.pairing &&
                          widget.error == null &&
                          !widget.canResetScan) ...[
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Icon(
                              LucideIcons.scan,
                              size: AppIconSizes.control,
                              color: AppPalette.of(context).muted,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '保持二维码完整可见，识别后会先确认设备信息',
                                style: TextStyle(
                                  color: AppPalette.of(context).muted,
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
                            icon: const SmartIcon(
                              LucideIcons.refreshCw,
                              size: AppIconSizes.control,
                            ),
                            label: const Text('重新扫描'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppPalette.of(context).ink,
                              backgroundColor: AppPalette.of(
                                context,
                              ).surfaceElevated,
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
      color: AppPalette.of(context).surface,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(compact ? 10 : 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.camera,
                size: compact ? 26 : 34,
                color: AppPalette.of(context).accentStrong,
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
                  style: TextStyle(
                    color: AppPalette.of(context).muted,
                    fontSize: 12,
                  ),
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
                    : SmartIcon(
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
            color: AppPalette.of(context).control,
            borderRadius: BorderRadius.circular(AppRadii.surface),
            border: Border.all(color: AppPalette.of(context).line),
          ),
          child: Icon(
            LucideIcons.qrCode,
            size: compact ? 28 : 42,
            color: AppPalette.of(context).accentStrong,
          ),
        ),
        SizedBox(height: compact ? 6 : 14),
        Text(
          '把二维码放进取景框',
          style: TextStyle(
            color: AppPalette.of(context).ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (!compact) ...[
          const SizedBox(height: 4),
          Text(
            '识别后会先显示电脑信息',
            style: TextStyle(color: AppPalette.of(context).muted, fontSize: 12),
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
    sheetAnimationStyle: appOverlayAnimationStyle(context),
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
        child: AppSheetSurface(
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
                      color: AppPalette.of(context).control,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      LucideIcons.monitor,
                      size: AppIconSizes.control,
                      color: AppPalette.of(context).accentStrong,
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
                          style: TextStyle(
                            color: AppPalette.of(context).muted,
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
                color: expired
                    ? AppPalette.of(context).danger
                    : AppPalette.of(context).muted,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: SignalPressEffect(
                  enabled: !expired,
                  scaleOnPress: false,
                  child: FilledButton(
                    onPressed: expired
                        ? null
                        : () {
                            // The scan's emotional peak needs a physical
                            // confirmation; the sheet's exit animation is
                            // too quiet to carry it alone.
                            HapticFeedback.mediumImpact();
                            Navigator.pop(context, true);
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppPalette.of(context).cta,
                      foregroundColor: AppPalette.of(context).onCta,
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
                    foregroundColor: AppPalette.of(context).ink,
                    backgroundColor: AppPalette.of(context).surface,
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

enum ConsoleTone { neutral, active, warning, danger }

@immutable
class ConsolePresentation {
  const ConsolePresentation(this.phase, {this.engine = SessionEngine.claude});

  final ConsolePhase phase;
  final SessionEngine engine;

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
    SessionEngine engine = SessionEngine.claude,
  }) {
    if (offline)
      return ConsolePresentation(ConsolePhase.offline, engine: engine);
    if (running && stopping) {
      return ConsolePresentation(ConsolePhase.stopping, engine: engine);
    }
    if (running && stopTimedOut) {
      return ConsolePresentation(ConsolePhase.stopTimedOut, engine: engine);
    }
    if (running && awaitingPermission) {
      return ConsolePresentation(
        ConsolePhase.awaitingPermission,
        engine: engine,
      );
    }
    if (running)
      return ConsolePresentation(ConsolePhase.running, engine: engine);
    if (uploading)
      return ConsolePresentation(ConsolePhase.uploading, engine: engine);
    if (!connected)
      return ConsolePresentation(ConsolePhase.connecting, engine: engine);
    if (failed) return ConsolePresentation(ConsolePhase.failed, engine: engine);
    if (stopped)
      return ConsolePresentation(ConsolePhase.stopped, engine: engine);
    return ConsolePresentation(ConsolePhase.connected, engine: engine);
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
    ConsolePhase.connecting => '连接后可以继续输入',
    ConsolePhase.connected ||
    ConsolePhase.stopped ||
    ConsolePhase.failed => '输入要发给 ${engine.displayName} 的内容',
    ConsolePhase.uploading => '正在上传附件…',
    ConsolePhase.running => '下一句可以先写着，点排队发送',

    ConsolePhase.awaitingPermission => '请先处理权限请求',
    ConsolePhase.stopping => '等待主机确认停止',
    ConsolePhase.stopTimedOut => '主机未确认停止，可再次尝试',
    ConsolePhase.offline => '重新连接后继续',
  };

  ConsoleTone get tone => switch (phase) {
    ConsolePhase.running ||
    ConsolePhase.awaitingPermission ||
    ConsolePhase.uploading => ConsoleTone.active,
    // Unconfirmed stop and a host that is gone but retrying are "degraded
    // but alive": amber, not red — red is reserved for finished failures.
    ConsolePhase.stopping || ConsolePhase.stopTimedOut => ConsoleTone.warning,
    ConsolePhase.failed || ConsolePhase.offline => ConsoleTone.danger,
    _ => ConsoleTone.neutral,
  };

  bool get canCompose => switch (phase) {
    ConsolePhase.connected ||
    ConsolePhase.stopped ||
    ConsolePhase.failed => true,
    _ => false,
  };

  bool get canDraft => switch (phase) {
    ConsolePhase.connected ||
    ConsolePhase.stopped ||
    ConsolePhase.failed ||
    ConsolePhase.running ||
    ConsolePhase.awaitingPermission ||
    ConsolePhase.stopTimedOut => true,
    _ => false,
  };

  bool get canQueue => switch (phase) {
    ConsolePhase.running ||
    ConsolePhase.awaitingPermission ||
    ConsolePhase.stopTimedOut => true,
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

({
  bool stopTimedOut,
  bool stopped,
  bool failed,
  String? failureDetail,
  String? previousPrompt,
})
_currentTurnEvidence(List<TranscriptMessage> messages) {
  var stopTimedOut = false;
  var stopped = false;
  var failed = false;
  var foundFailureDetail = false;
  String? failureDetail;
  String? previousPrompt;
  var inCurrentTurn = true;

  for (final message in messages.reversed) {
    if (message.role == MessageRole.user) {
      inCurrentTurn = false;
      if (previousPrompt == null && message.text.trim().isNotEmpty) {
        previousPrompt = message.text;
        break;
      }
      continue;
    }
    if (!inCurrentTurn) continue;

    if (message.role == MessageRole.system) {
      stopTimedOut |= message.text == '停止请求未确认，任务仍在运行';
      stopped |= message.text == '已停止';
      if (message.text.startsWith('错误：')) {
        failed = true;
        if (!foundFailureDetail) {
          foundFailureDetail = true;
          final detail = message.text.substring('错误：'.length).trim();
          failureDetail = detail.isEmpty ? null : detail;
        }
      }
    }
    stopped |= message.activityState == ActivityState.stopped;
    // Tool errors remain in the transcript; only a terminal result fails the turn.
    failed |=
        message.activityKind == ActivityKind.summary &&
        message.activityState == ActivityState.error;
  }

  return (
    stopTimedOut: stopTimedOut,
    stopped: stopped,
    failed: failed,
    failureDetail: failureDetail,
    previousPrompt: previousPrompt,
  );
}

bool hasStopTimeoutEvidence(List<TranscriptMessage> messages) =>
    _currentTurnEvidence(messages).stopTimedOut;

bool hasConfirmedStopEvidence(List<TranscriptMessage> messages) =>
    _currentTurnEvidence(messages).stopped;

bool hasCurrentFailureEvidence(List<TranscriptMessage> messages) =>
    _currentTurnEvidence(messages).failed;

String? currentFailureDetail(List<TranscriptMessage> messages) =>
    _currentTurnEvidence(messages).failureDetail;

String? lastUserPromptText(List<TranscriptMessage> messages) =>
    _currentTurnEvidence(messages).previousPrompt;

String? safeConnectionError(Object? error) {
  if (error == null) return null;
  final normalized = error.toString().toLowerCase();
  if (normalized.contains('timed out') || normalized.contains('timeout')) {
    return '连接电脑端超时';
  }
  if (normalized.contains('connection refused') ||
      normalized.contains('actively refused')) {
    return '电脑端拒绝连接';
  }
  if (normalized.contains('failed host lookup') ||
      normalized.contains('name or service not known')) {
    return '无法解析电脑端地址';
  }
  if (normalized.contains('handshake') || normalized.contains('certificate')) {
    return '安全连接握手失败';
  }
  if (normalized.contains('connection reset') ||
      normalized.contains('broken pipe') ||
      normalized.contains('closed before')) {
    return '网络连接被中断';
  }
  return '暂时无法建立网络连接';
}

String reconnectTimingLabel(DateTime? nextRetryAt) {
  if (nextRetryAt == null) return '即将再次尝试';
  final remaining = nextRetryAt.difference(DateTime.now()).inMilliseconds;
  final seconds = max(0, (remaining / 1000).ceil());
  return seconds == 0 ? '即将再次尝试' : '约 $seconds 秒后再次尝试';
}

String preservedConnectionEvidence({
  required bool hasTranscript,
  required bool hasDraft,
}) {
  if (hasTranscript && hasDraft) return '对话记录已保留，当前输入仍在编辑框中';
  if (hasTranscript) return '对话记录已保留';
  if (hasDraft) return '当前输入仍在编辑框中';
  return '连接恢复后会同步电脑端状态';
}

class SessionPeekDock extends StatelessWidget {
  const SessionPeekDock({
    super.key,
    required this.peek,
    required this.onReturn,
    this.onStop,
  });

  final SessionPeekView peek;
  final VoidCallback onReturn;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final title = peek.failed
        ? '读不到「${peek.title}」'
        : peek.loading
        ? '正在读取「${peek.title}」'
        : '只读查看「${peek.title}」';
    final subtitle = peek.hasLiveUpdate
        ? '原会话有新输出'
        : peek.liveRunning
        ? '原会话仍在运行'
        : '原会话已结束';
    final showStop = onStop != null && peek.liveRunning;
    return SignalLiquidGlass(
      key: const ValueKey('session-peek-dock'),
      blurSigma: 8,
      decoration: AppLiquidGlass.strong(
        context: context,
        borderRadius: BorderRadius.circular(AppRadii.composerFloat),
        elevated: true,
        backdrop: true,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (peek.loading)
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(
                  key: ValueKey('session-peek-loading'),
                  minHeight: 2,
                  color: AppPalette.of(context).accentStrong,
                ),
              ),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppPalette.of(context).ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppPalette.of(context).muted,
                fontSize: 12,
                height: 1.3,
              ),
            ),
            if (peek.queuedPreview != null) ...[
              const SizedBox(height: 6),
              Text(
                peek.queuedPreview!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppPalette.of(context).accentStrong,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('session-peek-return'),
                    onPressed: onReturn,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppPalette.of(context).cta,
                      foregroundColor: AppPalette.of(context).onCta,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: Text(peek.liveRunning ? '返回运行中的会话' : '返回当前会话'),
                  ),
                ),
                if (showStop) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('session-peek-stop'),
                    tooltip: '停止',
                    onPressed: onStop,
                    style: IconButton.styleFrom(
                      backgroundColor: AppPalette.of(context).stop,
                      foregroundColor: AppPalette.of(context).onStop,
                      minimumSize: const Size.square(44),
                      side: BorderSide(
                        color: AppPalette.of(
                          context,
                        ).onStop.withValues(alpha: 0.28),
                        width: 0.8,
                      ),
                      shadowColor: Colors.transparent,
                      elevation: 3,
                    ),
                    icon: const Icon(
                      PhosphorIconsFill.square,
                      size: AppIconSizes.inline,
                    ),
                  ),
                ],
              ],
            ),
          ],
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
    this.runStartedAt,
    this.uploadingAttachments = false,
    required this.connected,
    required this.offline,
    this.reconnectSnapshot = const RemoteConnectionSnapshot.idle(),
    required this.modelName,
    this.selectedModel = ClaudeModelPreference.followComputer,
    this.selectedCodexModel,
    this.engine = SessionEngine.claude,
    this.selectedEffort = ClaudeEffortPreference.automatic,
    required this.contextWindow,
    required this.remainingContext,
    required this.messages,
    this.transcriptRevisionListenable,
    this.transcriptJumpRequest,
    this.readingFontScaleListenable,
    required this.commands,
    this.commandsLoading = false,
    this.commandsFailed = false,
    this.onRefreshCommands,
    required this.permissionMode,
    required this.allowBypassPermissions,
    this.codexSandboxMode = CodexSandboxMode.dangerFullAccess,
    this.codexSandboxModes = CodexSandboxMode.supportedModes,
    required this.pendingPermissions,
    required this.respondingPermissionIds,
    required this.promptController,
    this.pendingAttachments = const [],
    required this.onFillPrompt,
    required this.onReconnect,
    required this.onOpenSettings,
    required this.onOpenModelPicker,
    this.onEffortSelected,
    required this.onNewConversation,
    required this.onOpenSessions,
    required this.onOpenWorkspace,
    this.workspaceChangeEcho,
    this.onOpenWorkspaceChanges,
    this.onOpenWorkspacePath,
    this.onTranscriptJumpHandled,
    required this.onPermissionModeSelected,
    this.onCodexSandboxModeSelected,
    required this.onPermissionAllow,
    required this.onPermissionDeny,
    this.onAddAttachment,
    this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
    this.peek,
    this.onExitPeek,
    this.queuedPreview,
    this.onCancelQueue,
  });

  final SavedSession? session;
  final String? activeSessionId;
  final bool running;
  final bool stopping;
  final DateTime? runStartedAt;
  final bool uploadingAttachments;
  final bool connected;
  final bool offline;
  final RemoteConnectionSnapshot reconnectSnapshot;
  final String? modelName;
  final ClaudeModelPreference selectedModel;
  final String? selectedCodexModel;
  final SessionEngine engine;
  final ClaudeEffortPreference selectedEffort;
  final int? contextWindow;
  final int? remainingContext;
  final List<TranscriptMessage> messages;
  final ValueListenable<int>? transcriptRevisionListenable;
  final ValueListenable<double>? readingFontScaleListenable;

  // ponytail: static fallback so tests without a listening shell skip wiring
  static final ValueNotifier<double> _unityReadingScale = ValueNotifier(1.0);
  final TranscriptJumpRequest? transcriptJumpRequest;
  final List<String> commands;
  final bool commandsLoading;
  final bool commandsFailed;
  final VoidCallback? onRefreshCommands;
  final PermissionMode permissionMode;
  final bool allowBypassPermissions;
  final CodexSandboxMode codexSandboxMode;
  final List<CodexSandboxMode> codexSandboxModes;
  final List<RemotePermissionRequest> pendingPermissions;
  final Set<String> respondingPermissionIds;
  final TextEditingController promptController;
  final List<AttachmentDraft> pendingAttachments;
  final ValueChanged<String> onFillPrompt;
  final VoidCallback onReconnect;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenModelPicker;
  final ValueChanged<ClaudeEffortPreference>? onEffortSelected;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenSessions;
  final VoidCallback onOpenWorkspace;
  final WorkspaceChangeEcho? workspaceChangeEcho;
  final VoidCallback? onOpenWorkspaceChanges;
  final ValueChanged<String>? onOpenWorkspacePath;
  final ValueChanged<TranscriptJumpRequest>? onTranscriptJumpHandled;
  final ValueChanged<PermissionMode> onPermissionModeSelected;
  final ValueChanged<CodexSandboxMode>? onCodexSandboxModeSelected;
  final ValueChanged<RemotePermissionRequest> onPermissionAllow;
  final ValueChanged<RemotePermissionRequest> onPermissionDeny;
  final VoidCallback? onAddAttachment;
  final ValueChanged<AttachmentDraft>? onRemoveAttachment;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final SessionPeekView? peek;
  final VoidCallback? onExitPeek;
  final String? queuedPreview;
  final VoidCallback? onCancelQueue;

  @override
  Widget build(BuildContext context) {
    final peeking = peek != null;
    final evidence = _currentTurnEvidence(messages);
    final presentation = ConsolePresentation.resolve(
      connected: connected,
      offline: offline,
      running: running,
      stopping: stopping,
      uploading: uploadingAttachments,
      awaitingPermission: pendingPermissions.isNotEmpty,
      stopTimedOut: evidence.stopTimedOut,
      stopped: evidence.stopped,
      failed: evidence.failed,
      engine: engine,
    );
    final previousPrompt = evidence.previousPrompt;
    final canRestorePreviousPrompt =
        presentation.phase == ConsolePhase.failed &&
        previousPrompt != null &&
        promptController.text.trim().isEmpty;
    final media = MediaQuery.of(context);

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
    Widget buildTranscriptView(double topPadding) => TranscriptView(
      topPadding: topPadding,
      messages: peeking ? peek!.messages : messages,
      jumpRequest: transcriptJumpRequest,
      session: session,
      activeSessionId: peeking ? peek!.sessionId : activeSessionId,
      running: peeking ? false : running,
      runStartedAt: peeking ? null : runStartedAt,
      pendingPermissions: peeking
          ? const <RemotePermissionRequest>[]
          : pendingPermissions,
      respondingPermissionIds: respondingPermissionIds,
      connected: connected,
      offline: offline,
      workspaceChangeEcho: peeking ? null : workspaceChangeEcho,
      onFillPrompt: onFillPrompt,
      onReconnect: onReconnect,
      onPermissionAllow: onPermissionAllow,
      onPermissionDeny: onPermissionDeny,
      onJumpHandled: onTranscriptJumpHandled,
      onOpenWorkspaceChanges: peeking ? null : onOpenWorkspaceChanges,
    );
    Widget buildTranscript(double topPadding) => RepaintBoundary(
      child: WorkspacePortal(
        workspaceDir: peeking ? null : session?.workspaceDir,
        onOpenPath: peeking ? null : onOpenWorkspacePath,
        child: transcriptRevisionListenable == null || peeking
            ? buildTranscriptView(topPadding)
            : ValueListenableBuilder<int>(
                valueListenable: transcriptRevisionListenable!,
                builder: (context, _, _) => buildTranscriptView(topPadding),
              ),
      ),
    );
    final showComposer =
        peeking || !(offline && messages.isEmpty && pendingPermissions.isEmpty);

    // Edge-to-edge: use viewPadding so the float clears the home indicator
    // even when MediaQuery.padding.bottom is 0.
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final composerBottomGap = keyboardVisible
        ? 0.0
        : (bottomInset > 0 ? bottomInset : 8.0);
    return SafeArea(
      key: const ValueKey('chat'),
      top: false,
      bottom: false,
      child: ValueListenableBuilder<double>(
        valueListenable: readingFontScaleListenable ?? _unityReadingScale,
        builder: (context, scale, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: multiplyReadingTextScaler(media.textScaler, scale),
          ),
          child: child!,
        ),
        child: _ChatOverlayLayout(
          initialTopExtent: media.padding.top + AppSizes.sessionHeader + 20,
          blurExtent: media.padding.top + AppSizes.sessionHeader + 32,
          topOverlay: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: media.textScaler),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      header,
                      if (!peeking &&
                          ConsoleStatusStrip.shouldShow(presentation)) ...[
                        const SizedBox(height: 8),
                        ConsoleStatusStrip(
                          presentation: presentation,
                          hostLabel: session?.deviceName,
                        ),
                      ],
                      if (!peeking)
                        Visibility(
                          visible: !keyboardVisible,
                          maintainState: true,
                          child: RecoveryStatePanel(
                            key: ValueKey(activeSessionId),
                            presentation: presentation,
                            hostLabel: session?.deviceName,
                            failureDetail: evidence.failureDetail,
                            failureKey: (
                              activeSessionId,
                              messages.lastIndexWhere(
                                (message) => message.role == MessageRole.user,
                              ),
                            ),
                            reconnectSnapshot: reconnectSnapshot,
                            hasTranscript: messages.isNotEmpty,
                            hasDraft:
                                promptController.text.trim().isNotEmpty ||
                                pendingAttachments.isNotEmpty,
                            onReconnect: onReconnect,
                            onStop: onStop,
                            onOpenWorkspace: onOpenWorkspace,
                            onEditPreviousPrompt: canRestorePreviousPrompt
                                ? () => onFillPrompt(previousPrompt)
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          bodyBuilder: (topPadding) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: buildTranscript(topPadding),
              ),
            ),
          ),
          floatingOverlay: showComposer
              ? Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(8, 0, 8, composerBottomGap),
                    child: RepaintBoundary(
                      child: peeking
                          ? SessionPeekDock(
                              peek: peek!,
                              onReturn: onExitPeek ?? () {},
                              onStop: peek!.liveRunning ? onStop : null,
                            )
                          : PromptBar(
                              controller: promptController,
                              attachments: pendingAttachments,
                              commands: commands,
                              commandsLoading: commandsLoading,
                              commandsFailed: commandsFailed,
                              onRefreshCommands: onRefreshCommands,
                              running: running,
                              stopping: stopping,
                              uploading: uploadingAttachments,
                              connected: connected,
                              offline: offline,
                              permissionMode: permissionMode,
                              allowBypassPermissions: allowBypassPermissions,
                              modelName: modelName,
                              contextWindow: contextWindow,
                              remainingContext: remainingContext,
                              engine: engine,
                              selectedModel: selectedModel,
                              selectedCodexModel: selectedCodexModel,
                              selectedEffort: selectedEffort,
                              codexSandboxMode: codexSandboxMode,
                              presentation: presentation,
                              queuedPreview: queuedPreview,
                              onCancelQueue: onCancelQueue,
                              onPermissionModeSelected:
                                  onPermissionModeSelected,
                              onCodexSandboxModeSelected:
                                  onCodexSandboxModeSelected,
                              onCommandSelected: (command) =>
                                  onFillPrompt('/$command '),
                              onAddAttachment: onAddAttachment,
                              onRemoveAttachment: onRemoveAttachment,
                              onModelPressed: onOpenModelPicker,
                              onEffortSelected: onEffortSelected,
                              onReconnect: onReconnect,
                              onSend: onSend,
                              onStop: onStop,
                            ),
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _ChatOverlayLayout extends StatefulWidget {
  const _ChatOverlayLayout({
    required this.initialTopExtent,
    required this.blurExtent,
    required this.topOverlay,
    required this.bodyBuilder,
    this.floatingOverlay,
  });

  final double initialTopExtent;
  final double blurExtent;
  final Widget topOverlay;
  final Widget Function(double topPadding) bodyBuilder;
  final Widget? floatingOverlay;

  @override
  State<_ChatOverlayLayout> createState() => _ChatOverlayLayoutState();
}

class _ChatOverlayLayoutState extends State<_ChatOverlayLayout> {
  final _topOverlayKey = GlobalKey();
  double? _topExtent;
  bool _measurementScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleMeasurement();
  }

  @override
  void didUpdateWidget(covariant _ChatOverlayLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasurement();
  }

  void _scheduleMeasurement() {
    if (_measurementScheduled) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      final box = _topOverlayKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final nextExtent = box.size.height;
      final currentExtent = _topExtent ?? widget.initialTopExtent;
      if ((nextExtent - currentExtent).abs() < 0.5) return;
      setState(() => _topExtent = nextExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final topExtent = _topExtent ?? widget.initialTopExtent;
    return Stack(
      key: const ValueKey('chat-overlay-layout'),
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: widget.bodyBuilder(topExtent + 8)),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: widget.blurExtent,
          child: const RepaintBoundary(child: _ChatTopBackdrop()),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: NotificationListener<SizeChangedLayoutNotification>(
            onNotification: (_) {
              _scheduleMeasurement();
              return true;
            },
            child: SizeChangedLayoutNotifier(
              key: _topOverlayKey,
              child: widget.topOverlay,
            ),
          ),
        ),
        if (widget.floatingOverlay != null) widget.floatingOverlay!,
      ],
    );
  }
}

class _ChatTopBackdrop extends StatelessWidget {
  const _ChatTopBackdrop();

  static final _filter = ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12);

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: IgnorePointer(
        child: ClipRect(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0, 0.55, 1],
            ).createShader(bounds),
            child: BackdropFilter(
              filter: _filter,
              blendMode: BlendMode.src,
              child: ColoredBox(
                color: AppPalette.of(context).paper.withValues(alpha: 0.36),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
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
    final showActivePill =
        console.phase == ConsolePhase.running ||
        console.phase == ConsolePhase.stopping ||
        console.phase == ConsolePhase.stopTimedOut ||
        console.phase == ConsolePhase.uploading ||
        console.phase == ConsolePhase.awaitingPermission;

    return SizedBox(
      key: const ValueKey('session-header'),
      height: AppSizes.sessionHeader,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            children: [
              SignalPressEffect(
                builder: (context, pressed, child) => SignalAnimatedSurface(
                  key: const ValueKey('session-menu-surface'),
                  duration: appPressAnimationDuration(context, pressed),
                  blurSigma: 8,
                  decoration: AppLiquidGlass.thin(
                    context: context,
                    shape: BoxShape.circle,
                    pressed: pressed,
                    backdrop: true,
                  ),
                  child: child,
                ),
                child: _HeaderIconButton(
                  tooltip: '项目与会话',
                  icon: LucideIcons.menu,
                  onPressed: uploadingAttachments ? null : onOpenSessions,
                ),
              ),
              const Spacer(),
              SignalPressEffect(
                builder: (context, pressed, child) => SignalAnimatedSurface(
                  key: const ValueKey('session-actions-surface'),
                  duration: appPressAnimationDuration(context, pressed),
                  blurSigma: 8,
                  decoration: AppLiquidGlass.thin(
                    context: context,
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                    pressed: pressed,
                    backdrop: true,
                  ),
                  child: child,
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
          if (showActivePill)
            _HeaderActivityPill(
              key: const ValueKey('session-activity-pill'),
              presentation: console,
              onTap: onOpenWorkspace,
            ),
        ],
      ),
    );
  }
}

class _HeaderActivityPill extends StatelessWidget {
  const _HeaderActivityPill({
    super.key,
    required this.presentation,
    this.onTap,
  });

  final ConsolePresentation presentation;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final toneColor = switch (presentation.tone) {
      ConsoleTone.active => AppPalette.of(context).accentStrong,
      ConsoleTone.warning => AppPalette.of(context).warning,
      ConsoleTone.danger => AppPalette.of(context).danger,
      ConsoleTone.neutral => AppPalette.of(context).muted,
    };

    final Widget indicator;
    if (presentation.phase == ConsolePhase.running) {
      indicator = _ActivityPulseDot(color: toneColor);
    } else if (presentation.phase == ConsolePhase.uploading) {
      indicator = Icon(
        LucideIcons.uploadCloud,
        size: AppIconSizes.badge,
        color: toneColor,
      );
    } else if (presentation.phase == ConsolePhase.stopping) {
      indicator = Icon(
        LucideIcons.square,
        size: AppIconSizes.badge,
        color: toneColor,
      );
    } else if (presentation.phase == ConsolePhase.stopTimedOut) {
      indicator = Icon(
        LucideIcons.circleAlert,
        size: AppIconSizes.badge,
        color: toneColor,
      );
    } else if (presentation.phase == ConsolePhase.awaitingPermission) {
      indicator = Icon(
        LucideIcons.shield,
        size: AppIconSizes.badge,
        color: toneColor,
      );
    } else {
      indicator = Icon(
        LucideIcons.activity,
        size: AppIconSizes.badge,
        color: toneColor,
      );
    }

    return Semantics(
      liveRegion: true,
      button: onTap != null,
      label: presentation.statusLabel,
      child: Tooltip(
        message: presentation.statusLabel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: SignalPressEffect(
            builder: (context, pressed, child) => SignalAnimatedSurface(
              key: const ValueKey('session-activity-pill-surface'),
              duration: appPressAnimationDuration(context, pressed),
              decoration: BoxDecoration(
                color: AppPalette.of(context).assistantBubble,
                borderRadius: BorderRadius.circular(AppRadii.pill),
                border: Border.all(color: AppPalette.of(context).bubbleOutline),
                boxShadow: AppElevation.liquidThin(
                  context: context,
                  pressed: pressed,
                ),
              ),
              child: child,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(AppRadii.pill),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      indicator,
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          presentation.statusLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: toneColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityPulseDot extends StatelessWidget {
  const _ActivityPulseDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.45),
            blurRadius: 4,
            spreadRadius: 1,
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
    return presentation.phase == ConsolePhase.awaitingPermission;
  }

  @override
  Widget build(BuildContext context) {
    final toneColor = switch (presentation.tone) {
      ConsoleTone.active => AppPalette.of(context).accentStrong,
      ConsoleTone.warning => AppPalette.of(context).warning,
      ConsoleTone.danger => AppPalette.of(context).danger,
      ConsoleTone.neutral => AppPalette.of(context).muted,
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
          color: AppPalette.of(context).surface,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: AppPalette.of(context).line),
        ),
        child: Row(
          children: [
            Icon(icon, size: AppIconSizes.inline, color: toneColor),
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
                  style: TextStyle(
                    color: AppPalette.of(context).muted,
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

class RecoveryStatePanel extends StatefulWidget {
  const RecoveryStatePanel({
    super.key,
    required this.presentation,
    this.hostLabel,
    this.failureDetail,
    this.failureKey,
    this.reconnectSnapshot = const RemoteConnectionSnapshot.idle(),
    this.hasTranscript = false,
    this.hasDraft = false,
    required this.onReconnect,
    required this.onStop,
    required this.onOpenWorkspace,
    this.onEditPreviousPrompt,
  });

  final ConsolePresentation presentation;
  final String? hostLabel;
  final String? failureDetail;
  final Object? failureKey;
  final RemoteConnectionSnapshot reconnectSnapshot;
  final bool hasTranscript;
  final bool hasDraft;
  final VoidCallback onReconnect;
  final VoidCallback onStop;
  final VoidCallback onOpenWorkspace;
  final VoidCallback? onEditPreviousPrompt;

  static bool shouldShow(ConsolePresentation presentation) {
    return switch (presentation.phase) {
      ConsolePhase.connecting ||
      ConsolePhase.stopping ||
      ConsolePhase.stopTimedOut ||
      ConsolePhase.stopped ||
      ConsolePhase.failed ||
      ConsolePhase.offline => true,
      _ => false,
    };
  }

  @override
  State<RecoveryStatePanel> createState() => _RecoveryStatePanelState();
}

class _RecoveryStatePanelState extends State<RecoveryStatePanel> {
  Timer? completionTimer;
  Timer? reconnectCountdownTimer;
  DateTime? reconnectCountdownTarget;
  int? reconnectSecondsRemaining;
  bool showCompletion = false;
  bool failureDismissed = false;

  @override
  void initState() {
    super.initState();
    syncReconnectCountdown();
  }

  @override
  void didUpdateWidget(covariant RecoveryStatePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.presentation.phase != oldWidget.presentation.phase ||
        widget.failureKey != oldWidget.failureKey ||
        widget.failureDetail != oldWidget.failureDetail) {
      failureDismissed = false;
    }
    final completed =
        widget.presentation.phase == ConsolePhase.connected &&
        switch (oldWidget.presentation.phase) {
          ConsolePhase.running ||
          ConsolePhase.awaitingPermission ||
          ConsolePhase.stopping ||
          ConsolePhase.stopTimedOut => true,
          _ => false,
        };
    if (completed) {
      showCompletion = true;
      // The turn's end moment: the thinking bloom vanishes and text starts
      // streaming, which reads as "still going". A light tick marks the
      // finish for a user who is looking away from the screen.
      HapticFeedback.lightImpact();
      completionTimer?.cancel();
      completionTimer = Timer(AppMotion.signal, () {
        if (!mounted) return;
        setState(() => showCompletion = false);
      });
    } else if (widget.presentation.phase != ConsolePhase.connected &&
        showCompletion) {
      completionTimer?.cancel();
      showCompletion = false;
    }
    syncReconnectCountdown();
  }

  @override
  void dispose() {
    completionTimer?.cancel();
    reconnectCountdownTimer?.cancel();
    super.dispose();
  }

  void syncReconnectCountdown() {
    final snapshot = widget.reconnectSnapshot;
    final target = snapshot.phase == RemoteConnectionPhase.retrying
        ? snapshot.nextRetryAt
        : null;
    if (target == reconnectCountdownTarget) return;
    reconnectCountdownTimer?.cancel();
    reconnectCountdownTimer = null;
    reconnectCountdownTarget = target;
    if (target == null) {
      reconnectSecondsRemaining = null;
      return;
    }
    final remaining = target.difference(DateTime.now()).inMilliseconds;
    reconnectSecondsRemaining = max(0, (remaining / 1000).ceil());
    if (reconnectSecondsRemaining == 0) return;
    reconnectCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = reconnectSecondsRemaining ?? 0;
      if (!mounted || current <= 0) {
        reconnectCountdownTimer?.cancel();
        reconnectCountdownTimer = null;
        return;
      }
      setState(() => reconnectSecondsRemaining = current - 1);
      if (current == 1) {
        reconnectCountdownTimer?.cancel();
        reconnectCountdownTimer = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final host = widget.hostLabel?.trim();
    final hostName = host == null || host.isEmpty ? '电脑端' : host;
    final reconnectAttempt = widget.reconnectSnapshot.attempt;
    final reconnecting =
        widget.reconnectSnapshot.phase == RemoteConnectionPhase.retrying ||
        (widget.reconnectSnapshot.phase == RemoteConnectionPhase.connecting &&
            reconnectAttempt > 0);
    final connectionError = safeConnectionError(
      widget.reconnectSnapshot.lastError,
    );
    final preservation = preservedConnectionEvidence(
      hasTranscript: widget.hasTranscript,
      hasDraft: widget.hasDraft,
    );
    final reconnectTiming = switch (reconnectSecondsRemaining) {
      null => reconnectTimingLabel(widget.reconnectSnapshot.nextRetryAt),
      0 => '即将再次尝试',
      final seconds => '约 $seconds 秒后再次尝试',
    };
    final reconnectDetail = switch (widget.reconnectSnapshot.phase) {
      RemoteConnectionPhase.retrying =>
        '自动重连第 $reconnectAttempt 次，'
            '$reconnectTiming。',
      RemoteConnectionPhase.connecting when reconnectAttempt > 0 =>
        '自动重连第 $reconnectAttempt 次正在进行，等待 $hostName 响应。',
      _ => '暂时无法连接 $hostName。恢复后会继续同步电脑端状态。',
    };
    final reconnectDetailWithError = connectionError == null
        ? reconnectDetail
        : '$reconnectDetail\n最近状态：$connectionError';
    final content = showCompletion
        ? const _RecoveryPanelContent(
            title: '任务已完成',
            detail: '电脑端已确认完成，可以查看结果或继续输入。',
            evidence: '最新输出已保留在对话中',
            icon: LucideIcons.circleCheck,
          )
        : widget.presentation.phase == ConsolePhase.failed && failureDismissed
        ? null
        : switch (widget.presentation.phase) {
            ConsolePhase.connecting => _RecoveryPanelContent(
              title: '正在连接电脑端',
              detail: '正在获取最新会话状态，无需重复操作。',
              evidence: preservation,
              icon: LucideIcons.monitor,
              loading: true,
            ),
            ConsolePhase.offline => _RecoveryPanelContent(
              title: reconnectAttempt >= 6
                  ? '连接仍未恢复'
                  : reconnecting
                  ? '正在自动重连'
                  : '连接已断开',
              detail: reconnectDetailWithError,
              evidence: reconnectAttempt >= 6
                  ? '$preservation；请检查电脑端服务和网络'
                  : preservation,
              icon: LucideIcons.unlink,
              actionLabel: '立即重连',
              actionIcon: LucideIcons.refreshCw,
              action: widget.onReconnect,
            ),
            ConsolePhase.stopping => const _RecoveryPanelContent(
              title: '停止请求已发送',
              detail: '正在等待电脑端确认，请不要重复点击。',
              evidence: '确认前任务仍按运行中处理',
              icon: LucideIcons.square,
            ),
            ConsolePhase.stopTimedOut => _RecoveryPanelContent(
              title: '停止尚未确认',
              detail: '电脑端没有在预期时间内返回确认，任务可能仍在运行。',
              evidence: '对话记录和工作区状态已保留',
              icon: LucideIcons.square,
              actionLabel: '再次停止',
              actionIcon: PhosphorIconsFill.square,
              action: widget.onStop,
              danger: true,
            ),
            ConsolePhase.stopped => _RecoveryPanelContent(
              title: '任务已停止',
              detail:
                  '电脑端已确认停止。你可以检查变更，或继续给 ${widget.presentation.engine.displayName} 新指令。',
              evidence: '对话记录和工作区状态已保留',
              icon: LucideIcons.circlePause,
              actionLabel: '查看工作区',
              actionIcon: LucideIcons.folderOpen,
              action: widget.onOpenWorkspace,
            ),
            ConsolePhase.failed => _RecoveryPanelContent(
              title: '任务执行失败',
              detail: widget.failureDetail?.trim().isNotEmpty == true
                  ? widget.failureDetail!.trim()
                  : '${widget.presentation.engine.displayName} 没有完成这次任务。请检查错误后重试。',
              evidence: '对话记录和工作区变更仍保留',
              icon: LucideIcons.circleAlert,
              actionLabel: widget.onEditPreviousPrompt == null
                  ? null
                  : '重新编辑上条指令',
              actionIcon: widget.onEditPreviousPrompt == null
                  ? null
                  : LucideIcons.pencil,
              action: widget.onEditPreviousPrompt,
            ),
            _ => null,
          };
    final toneColor = showCompletion
        ? AppPalette.of(context).accentStrong
        : widget.presentation.phase == ConsolePhase.offline && reconnecting
        ? AppPalette.of(context).warning
        : switch (widget.presentation.tone) {
            ConsoleTone.active => AppPalette.of(context).accentStrong,
            ConsoleTone.warning => AppPalette.of(context).warning,
            ConsoleTone.danger => AppPalette.of(context).danger,
            ConsoleTone.neutral => AppPalette.of(context).muted,
          };
    final semanticsDetail =
        widget.presentation.phase == ConsolePhase.offline && reconnecting
        ? '正在自动重连 $hostName。'
        : content?.detail;
    final phaseKey = showCompletion
        ? 'completed'
        : widget.presentation.phase.name;
    final transitionKey = widget.presentation.phase == ConsolePhase.offline
        ? '$phaseKey-${widget.reconnectSnapshot.phase.name}'
        : phaseKey;
    final duration = reduceMotion ? Duration.zero : AppMotion.standard;
    return AnimatedSize(
      duration: duration,
      curve: AppMotion.enter,
      alignment: Alignment.topCenter,
      child: content != null
          ? Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                container: true,
                label:
                    '${content.title}，$semanticsDetail，${content.evidence}'
                    '${content.actionLabel == null ? '' : '，${content.actionLabel}'}',
                child: Material(
                  key: const ValueKey('recovery-state-panel'),
                  color: AppPalette.of(context).surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.surface),
                    side: BorderSide(color: AppPalette.of(context).line),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: AnimatedSwitcher(
                    duration: reduceMotion ? Duration.zero : AppMotion.fast,
                    reverseDuration: reduceMotion
                        ? Duration.zero
                        : AppMotion.fast,
                    switchInCurve: AppMotion.enter,
                    switchOutCurve: AppMotion.exit,
                    child: KeyedSubtree(
                      key: ValueKey('recovery-content-$transitionKey'),
                      child: Padding(
                        key: ValueKey('recovery-state-$phaseKey'),
                        padding: const EdgeInsets.all(AppSpacing.md),
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
                                    color: AppPalette.of(context).control,
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.control,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: content.loading
                                      ? reduceMotion
                                            ? Icon(
                                                LucideIcons.loader,
                                                size: AppIconSizes.control,
                                                color: toneColor,
                                              )
                                            : SizedBox.square(
                                                dimension: AppIconSizes.control,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: toneColor,
                                                    ),
                                              )
                                      : Icon(
                                          content.icon,
                                          size: AppIconSizes.control,
                                          color: toneColor,
                                        ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        content.title,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          height: 1.3,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        content.detail,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: AppPalette.of(context).muted,
                                          fontSize: 13,
                                          height: 1.45,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (widget.presentation.phase ==
                                    ConsolePhase.failed)
                                  _HeaderIconButton(
                                    tooltip: '收起失败提示',
                                    icon: LucideIcons.x,
                                    onPressed: () =>
                                        setState(() => failureDismissed = true),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              content.evidence,
                              style: TextStyle(
                                color: AppPalette.of(context).muted,
                                fontSize: 12,
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (content.action != null &&
                                content.actionLabel != null) ...[
                              const SizedBox(height: 12),
                              SizedBox(
                                height: AppSizes.touchTarget,
                                child: SignalPressEffect(
                                  scaleOnPress: false,
                                  child: FilledButton.icon(
                                    onPressed: content.action,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: content.danger
                                          ? AppPalette.of(context).danger
                                          : AppPalette.of(context).control,
                                      foregroundColor: content.danger
                                          ? AppPalette.of(context).onStop
                                          : AppPalette.of(context).ink,
                                      overlayColor: content.danger
                                          ? AppPalette.of(
                                              context,
                                            ).onStop.withValues(alpha: 0.13)
                                          : AppPalette.of(
                                              context,
                                            ).ink.withValues(alpha: 0.08),
                                      minimumSize: const Size.fromHeight(
                                        AppSizes.touchTarget,
                                      ),
                                    ),
                                    icon: Icon(
                                      content.actionIcon,
                                      size: AppIconSizes.control,
                                    ),
                                    label: Text(content.actionLabel!),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _RecoveryPanelContent {
  const _RecoveryPanelContent({
    required this.title,
    required this.detail,
    required this.evidence,
    required this.icon,
    this.loading = false,
    this.actionLabel,
    this.actionIcon,
    this.action,
    this.danger = false,
  });

  final String title;
  final String detail;
  final String evidence;
  final IconData icon;
  final bool loading;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? action;
  final bool danger;
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
        icon: Icon(
          icon,
          size: filled ? 22 : 20,
          color: onPressed == null
              ? AppPalette.of(context).inactive
              : AppPalette.of(context).ink,
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
        icon: const SmartIcon(LucideIcons.ellipsis, size: AppIconSizes.control),
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
        SmartIcon(
          icon,
          size: AppIconSizes.control,
          color: notoGlyphFor(icon) == null ? AppPalette.of(context).ink : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: AppPalette.of(context).ink,
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
              style: TextStyle(
                color: AppPalette.of(context).muted,
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
  String? currentModel,
  ClaudeModelPreference selectedModel,
  double readingFontScale,
  VoidCallback onReconnect,
  Future<bool> Function(bool) onNotificationsChanged,
  Future<void> Function(ClaudeModelPreference) onModelChanged,
  Future<void> Function(double scale, {bool persist}) onReadingFontScaleChanged,
  VoidCallback onLogout,
) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: appOverlayAnimationStyle(context),
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    isScrollControlled: true,
    requestFocus: false,
    showDragHandle: false,
    builder: (context) => appModalSheetScaffold(
      SettingsSheet(
        session: session,
        notificationsEnabled: notificationsEnabled,
        currentModel: currentModel,
        selectedModel: selectedModel,
        readingFontScale: readingFontScale,
        onReconnect: onReconnect,
        onNotificationsChanged: onNotificationsChanged,
        onModelChanged: onModelChanged,
        onReadingFontScaleChanged: onReadingFontScaleChanged,
        onLogout: onLogout,
      ),
      barrierColor: AppPalette.of(context).scrim,
    ),
  );
  FocusManager.instance.primaryFocus?.unfocus();
}

Future<SessionEngine?> showSessionEnginePicker(
  BuildContext context, {
  SessionEngine selected = SessionEngine.claude,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  final engine = await showAppOptionPicker<SessionEngine>(
    context,
    requestFocus: false,
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppOptionSheetHeader(
          title: '选择会话引擎',
          detail: '每个会话独立保存引擎，创建后不可更改。',
        ),
        const SizedBox(height: 12),
        for (final engine in SessionEngine.values)
          AppOptionRow(
            key: ValueKey('session-engine-${engine.wireName}'),
            title: engine == SessionEngine.claude ? 'Claude Code' : 'Codex',
            description: engine == SessionEngine.claude
                ? '使用 Claude Code'
                : '使用 Codex CLI',
            selected: engine == selected,
            leading: Padding(
              key: ValueKey('session-engine-icon-${engine.wireName}'),
              padding: const EdgeInsets.all(8),
              child: Image.asset(
                engine == SessionEngine.claude
                    ? 'assets/brands/claude-mark.png'
                    : 'assets/brands/openai-mark.png',
                excludeFromSemantics: true,
                filterQuality: FilterQuality.high,
              ),
            ),
            onTap: () => Navigator.pop(sheetContext, engine),
          ),
      ],
    ),
  );
  FocusManager.instance.primaryFocus?.unfocus();
  return engine;
}

Future<void> showSessionNavigator(
  BuildContext context, {
  required List<RemoteProjectSummary> projects,
  required List<RemoteSessionSummary> sessions,
  required String? activeProjectId,
  required String? activeSessionId,
  required bool running,
  required ValueChanged<String> onSelect,
  required ValueChanged<RemoteSessionSearchResult> onSearchResult,
  required void Function(String projectId, SessionEngine engine) onCreate,
  required Future<void> Function(String sessionId, String title) onRename,
  required Future<void> Function(String sessionId) onArchive,
  required Future<void> Function(String sessionId) onDelete,
  required Future<List<RemoteSessionSearchResult>> Function(String query)
  onSearch,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(context).push(
    AppMaterialPageRoute<void>(
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (pageContext) => SessionNavigatorPage(
        projects: projects,
        sessions: sessions,
        activeProjectId: activeProjectId,
        activeSessionId: activeSessionId,
        running: running,
        onSelect: (sessionId) {
          Navigator.pop(pageContext);
          onSelect(sessionId);
        },
        onSearchResult: (result) {
          Navigator.pop(pageContext);
          onSearchResult(result);
        },
        onCreate: (projectId, engine) {
          Navigator.pop(pageContext);
          onCreate(projectId, engine);
        },
        onRename: (sessionId, title) async {
          Navigator.pop(pageContext);
          await onRename(sessionId, title);
        },
        onArchive: (sessionId) async {
          Navigator.pop(pageContext);
          await onArchive(sessionId);
        },
        onDelete: (sessionId) async {
          Navigator.pop(pageContext);
          await onDelete(sessionId);
        },
        onSearch: onSearch,
      ),
    ),
  );
}

enum _SessionNavigatorView { home, projects, search }

enum _SessionFilter {
  all('全部'),
  running('运行中'),
  archived('已归档'),
  claude('Claude'),
  codex('Codex');

  const _SessionFilter(this.label);

  final String label;
}

enum _SessionAction { rename, archive, delete }

class SessionNavigatorPage extends StatefulWidget {
  const SessionNavigatorPage({
    super.key,
    required this.projects,
    required this.sessions,
    required this.activeProjectId,
    required this.activeSessionId,
    required this.running,
    required this.onSelect,
    required this.onSearchResult,
    required this.onCreate,
    required this.onRename,
    required this.onArchive,
    required this.onDelete,
    required this.onSearch,
  });

  final List<RemoteProjectSummary> projects;
  final List<RemoteSessionSummary> sessions;
  final String? activeProjectId;
  final String? activeSessionId;
  final bool running;
  final ValueChanged<String> onSelect;
  final ValueChanged<RemoteSessionSearchResult> onSearchResult;
  final void Function(String projectId, SessionEngine engine) onCreate;
  final Future<void> Function(String sessionId, String title) onRename;
  final Future<void> Function(String sessionId) onArchive;
  final Future<void> Function(String sessionId) onDelete;
  final Future<List<RemoteSessionSearchResult>> Function(String query) onSearch;

  @override
  State<SessionNavigatorPage> createState() => _SessionNavigatorPageState();
}

/// Linear-style smart iconography inference for projects.
IconData inferProjectIcon(String name, [String? path]) {
  final target = '${name.toLowerCase()} ${(path ?? '').toLowerCase()}';
  if (target.contains('ios') || target.contains('apple')) {
    return PhosphorIconsFill.appleLogo;
  }
  if (target.contains('android')) {
    return PhosphorIconsFill.androidLogo;
  }
  if (target.contains('mobile') || target.contains('flutter')) {
    return PhosphorIconsFill.deviceMobile;
  }
  if (target.contains('web') ||
      target.contains('front') ||
      target.contains('ui') ||
      target.contains('vue') ||
      target.contains('react')) {
    return PhosphorIconsFill.globe;
  }
  if (target.contains('server') ||
      target.contains('api') ||
      target.contains('back') ||
      target.contains('service')) {
    return PhosphorIconsFill.hardDrives;
  }
  if (target.contains('cli') ||
      target.contains('tool') ||
      target.contains('script') ||
      target.contains('terminal')) {
    return PhosphorIconsFill.terminal;
  }
  if (target.contains('doc') ||
      target.contains('wiki') ||
      target.contains('spec') ||
      target.contains('prd')) {
    return PhosphorIconsFill.fileText;
  }
  return PhosphorIconsFill.cube;
}

/// Linear-style smart iconography inference for sessions.
IconData inferSessionIcon(String title, [bool archived = false]) {
  if (archived) return PhosphorIconsFill.archive;
  final t = title.toLowerCase();
  if (t.contains('ai') ||
      t.contains('agent') ||
      t.contains('思考') ||
      t.contains('prompt')) {
    return PhosphorIconsFill.sparkle;
  }
  if (t.contains('fix') ||
      t.contains('bug') ||
      t.contains('报错') ||
      t.contains('修复') ||
      t.contains('排查')) {
    return PhosphorIconsFill.bug;
  }
  if (t.contains('doc') ||
      t.contains('prd') ||
      t.contains('设计') ||
      t.contains('文档') ||
      t.contains('spec')) {
    return PhosphorIconsFill.fileText;
  }
  if (t.contains('review') ||
      t.contains('检查') ||
      t.contains('审视') ||
      t.contains('优化') ||
      t.contains('polish')) {
    return PhosphorIconsFill.sparkle;
  }
  if (t.contains('sync') ||
      t.contains('配对') ||
      t.contains('连接') ||
      t.contains('triage')) {
    return PhosphorIconsFill.arrowsLeftRight;
  }
  if (t.contains('plan') || t.contains('roadmap') || t.contains('路线')) {
    return PhosphorIconsFill.mapTrifold;
  }
  if (t.contains('mobile') ||
      t.contains('flutter') ||
      t.contains('ios') ||
      t.contains('android')) {
    return PhosphorIconsFill.deviceMobile;
  }
  return PhosphorIconsFill.chatCircle;
}

class _SessionNavigatorPageState extends State<SessionNavigatorPage> {
  Color get _selectedStatusColor => AppPalette.of(context).navigatorAccent;

  late String selectedProjectId =
      widget.activeProjectId ??
      (widget.projects.isEmpty ? '' : widget.projects.first.id);
  _SessionNavigatorView view = _SessionNavigatorView.home;
  bool viewMovingForward = true;
  bool searchTransitionActive = false;
  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();
  Timer? searchDebounce;
  Timer? searchFocusDelay;
  int searchGeneration = 0;
  String searchQuery = '';
  bool searching = false;
  String? searchError;
  List<RemoteSessionSearchResult> searchResults = const [];
  _SessionFilter sessionFilter = _SessionFilter.all;

  RemoteProjectSummary? get selectedProject {
    for (final project in widget.projects) {
      if (project.id == selectedProjectId) return project;
    }
    return widget.projects.isEmpty ? null : widget.projects.first;
  }

  @override
  void dispose() {
    searchDebounce?.cancel();
    searchFocusDelay?.cancel();
    searchController.dispose();
    searchFocusNode.dispose();
    super.dispose();
  }

  void handleSearchChanged(String value) {
    searchDebounce?.cancel();
    final query = value.trim();
    final generation = ++searchGeneration;
    setState(() {
      searchQuery = query;
      searchError = null;
      searching = query.isNotEmpty;
      if (query.isEmpty) searchResults = const [];
    });
    if (query.isEmpty) return;
    searchDebounce = Timer(
      const Duration(milliseconds: 300),
      () => runSearch(query, generation),
    );
  }

  void submitSearch(String value) {
    searchDebounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) return;
    final generation = ++searchGeneration;
    setState(() {
      searchQuery = query;
      searchError = null;
      searching = true;
    });
    unawaited(runSearch(query, generation));
  }

  Future<void> runSearch(String query, int generation) async {
    try {
      final results = await widget.onSearch(query);
      if (!mounted || generation != searchGeneration || query != searchQuery) {
        return;
      }
      setState(() {
        searchResults = results;
        searching = false;
        searchError = null;
      });
    } catch (_) {
      if (!mounted || generation != searchGeneration || query != searchQuery) {
        return;
      }
      setState(() {
        searchResults = const [];
        searching = false;
        searchError = '搜索失败，请重试';
      });
    }
  }

  void clearSearch() {
    searchController.clear();
    handleSearchChanged('');
  }

  void openView(_SessionNavigatorView next) {
    if (next == view) return;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    searchFocusDelay?.cancel();
    if (view == _SessionNavigatorView.search && next != view) {
      searchDebounce?.cancel();
      searchGeneration += 1;
      searchFocusNode.unfocus();
    }
    if (next == _SessionNavigatorView.search) {
      searchController.clear();
      searchQuery = '';
      searchResults = const [];
      searchError = null;
      searching = false;
    }
    setState(() {
      searchTransitionActive =
          next == _SessionNavigatorView.search ||
          view == _SessionNavigatorView.search;
      viewMovingForward = next != _SessionNavigatorView.home;
      view = next;
    });
    if (next == _SessionNavigatorView.search) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || view != _SessionNavigatorView.search) return;
        if (reduceMotion) {
          searchFocusNode.requestFocus();
          return;
        }
        searchFocusDelay = Timer(AppMotion.standard, () {
          if (mounted && view == _SessionNavigatorView.search) {
            searchFocusNode.requestFocus();
          }
        });
      });
    }
  }

  void chooseProject(String projectId) {
    setState(() {
      selectedProjectId = projectId;
      sessionFilter = _SessionFilter.all;
      searchTransitionActive = false;
      viewMovingForward = false;
      view = _SessionNavigatorView.home;
    });
  }

  Future<void> createSession() async {
    if (widget.running) return;
    var selectedEngine = SessionEngine.claude;
    for (final session in widget.sessions) {
      if (session.id == widget.activeSessionId) {
        selectedEngine = session.engine;
        break;
      }
    }
    final engine = await showSessionEnginePicker(
      context,
      selected: selectedEngine,
    );
    if (engine == null || !mounted) return;
    widget.onCreate(selectedProjectId, engine);
  }

  String projectName(String projectId) {
    for (final project in widget.projects) {
      if (project.id == projectId) return project.name;
    }
    return '未知项目';
  }

  Widget buildSearchBody() {
    if (searchError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.search,
              size: AppIconSizes.primary,
              color: AppPalette.of(context).muted,
            ),
            const SizedBox(height: 8),
            Text(searchError!),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => submitSearch(searchController.text),
              icon: const SmartIcon(
                LucideIcons.refreshCw,
                size: AppIconSizes.inline,
              ),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (searching && searchResults.isEmpty) {
      return const Center(child: Text('正在搜索所有会话…'));
    }
    if (searchResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.search,
              color: AppPalette.of(context).inactive,
              size: AppIconSizes.hero,
            ),
            const SizedBox(height: 12),
            const Text('没有找到匹配内容'),
            const SizedBox(height: 6),
            Text(
              '试试项目名、会话标题或报错关键词',
              style: TextStyle(
                color: AppPalette.of(context).muted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: searchResults.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final result = searchResults[index];
        final active = result.sessionId == widget.activeSessionId;
        final canOpen = !result.archived;

        return ListTile(
          key: ValueKey('search-session-${result.sessionId}'),
          enabled: canOpen,
          isThreeLine: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 4,
          ),
          leading: PhosphorIcon(
            inferSessionIcon(result.title, result.archived),
            size: AppMark.size,
            color: result.archived
                ? AppPalette.of(context).inactive
                : AppMark.of(result.sessionId, index),
          ),
          title: Text(
            result.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 3),
              buildHighlightedSnippet(result),
              const SizedBox(height: 4),
              Text(
                '${projectName(result.projectId)} · ${result.roleLabel} · '
                '${result.matchCount} 条匹配内容${result.archived ? ' · 已归档' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppPalette.of(context).muted,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
          trailing: active
              ? Icon(
                  LucideIcons.check,
                  size: AppIconSizes.control,
                  color: _selectedStatusColor,
                )
              : Icon(
                  LucideIcons.chevronRight,
                  size: AppIconSizes.inline,
                  color: AppPalette.of(context).inactive,
                ),
          onTap: canOpen ? () => widget.onSearchResult(result) : null,
        );
      },
    );
  }

  Widget buildHighlightedSnippet(RemoteSessionSearchResult result) {
    final start = result.matchStart.clamp(0, result.snippet.length);
    final end = result.matchEnd.clamp(start, result.snippet.length);
    final baseStyle = TextStyle(
      color: AppPalette.of(context).ink,
      fontSize: 13,
      height: 1.4,
    );
    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: [
          if (start > 0) TextSpan(text: result.snippet.substring(0, start)),
          TextSpan(
            text: result.snippet.substring(start, end),
            style: TextStyle(
              color: AppPalette.of(context).accentStrong,
              backgroundColor: AppPalette.of(
                context,
              ).navigatorAccent.withValues(alpha: 0.08),
              fontWeight: FontWeight.w700,
            ),
          ),
          if (end < result.snippet.length)
            TextSpan(text: result.snippet.substring(end)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: AppPalette.of(context).muted,
          fontWeight: FontWeight.w700,
          fontSize: 18,
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  Widget buildSessionStatus(RemoteSessionSummary item, {int? index}) {
    final iconData = inferSessionIcon(item.title, item.archived);
    final color = item.archived
        ? AppPalette.of(context).inactive
        : AppMark.of(item.id, index);

    if (item.running) {
      return SizedBox.square(
        dimension: 24,
        child: Stack(
          alignment: Alignment.center,
          children: [
            PhosphorIcon(iconData, size: AppMark.size, color: color),
            Positioned(
              right: 1,
              top: 1,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: AppPalette.of(context).navigatorAccent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return PhosphorIcon(iconData, size: AppMark.size, color: color);
  }

  Future<void> handleSessionAction(
    RemoteSessionSummary item,
    _SessionAction action,
  ) async {
    if (widget.running || item.running) return;
    switch (action) {
      case _SessionAction.rename:
        final next = await promptSessionTitle(context, initial: item.title);
        if (next == null || next.trim().isEmpty) return;
        await widget.onRename(item.id, next);
        if (mounted) setState(() {});
        return;
      case _SessionAction.archive:
        await widget.onArchive(item.id);
        return;
      case _SessionAction.delete:
        final confirmed = await confirmSessionDelete(context, item.title);
        if (confirmed == true) await widget.onDelete(item.id);
        return;
    }
  }

  Widget buildSessionRow(RemoteSessionSummary item, {int? index}) {
    final active = item.id == widget.activeSessionId;
    final canOpen = !item.archived;
    final canMutate = !widget.running && !item.running;
    final status = item.running
        ? '运行中'
        : active
        ? '当前'
        : item.engine.label;
    final meta = item.running || active
        ? '$status · ${item.engine.label} · ${item.summary}'
        : '${item.engine.label} · ${item.summary}';

    return Semantics(
      selected: active,
      child: ListTile(
        key: ValueKey('session-${item.id}'),
        enabled: canOpen,
        contentPadding: EdgeInsets.zero,
        horizontalTitleGap: 12,
        minVerticalPadding: 4,
        leading: SizedBox(
          width: 30,
          child: Center(child: buildSessionStatus(item, index: index)),
        ),
        title: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            fontSize: 16,
            letterSpacing: -0.15,
          ),
        ),
        subtitle: Text(
          meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: item.running
                ? AppPalette.of(context).ink
                : AppPalette.of(context).muted,
            fontSize: 12,
            height: 1.2,
          ),
        ),
        trailing: canMutate
            ? PopupMenuButton<_SessionAction>(
                key: ValueKey('session-menu-${item.id}'),
                tooltip: '${item.title} 的更多操作',
                icon: const SmartIcon(
                  LucideIcons.moreHorizontal,
                  size: AppIconSizes.control,
                ),
                onSelected: (action) => handleSessionAction(item, action),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _SessionAction.rename,
                    child: Row(
                      children: [
                        SmartIcon(
                          LucideIcons.pencil,
                          size: AppIconSizes.control,
                        ),
                        SizedBox(width: 12),
                        Text('重命名'),
                      ],
                    ),
                  ),
                  if (!item.archived)
                    const PopupMenuItem(
                      value: _SessionAction.archive,
                      child: Row(
                        children: [
                          SmartIcon(
                            LucideIcons.archive,
                            size: AppIconSizes.control,
                          ),
                          SizedBox(width: 12),
                          Text('归档'),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: _SessionAction.delete,
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.trash2,
                          size: AppIconSizes.control,
                          color: AppPalette.of(context).danger,
                        ),
                        SizedBox(width: 12),
                        Text(
                          '删除',
                          style: TextStyle(
                            color: AppPalette.of(context).danger,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : active
            ? null
            : Icon(
                LucideIcons.chevronRight,
                size: AppIconSizes.inline,
                color: AppPalette.of(context).inactive,
              ),
        onTap: canOpen && !active ? () => widget.onSelect(item.id) : null,
      ),
    );
  }

  Widget buildProjectRow(
    RemoteProjectSummary project, {
    bool compact = false,
    int? index,
  }) {
    final active = project.id == selectedProjectId;
    final subtitle = compact
        ? active
              ? '当前项目'
              : project.running
              ? '有会话正在运行'
              : '${project.sessionCount} 个会话'
        : project.path;

    return Semantics(
      selected: active,
      child: ListTile(
        key: ValueKey('project-${project.id}'),
        contentPadding: EdgeInsets.zero,
        horizontalTitleGap: 12,
        minVerticalPadding: 4,
        leading: SizedBox(
          width: 24,
          child: Center(
            child: PhosphorIcon(
              inferProjectIcon(project.name, project.path),
              key: ValueKey('project-icon-${project.id}'),
              size: AppMark.size,
              color: AppMark.of(project.id, index),
            ),
          ),
        ),
        title: Text(
          project.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            fontSize: 16,
            letterSpacing: -0.15,
          ),
        ),
        subtitle: Text(
          subtitle,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppPalette.of(context).muted,
            fontSize: 12,
            height: 1.2,
          ),
        ),
        trailing: Icon(
          LucideIcons.chevronRight,
          size: AppIconSizes.inline,
          color: AppPalette.of(context).inactive,
        ),
        onTap: () => chooseProject(project.id),
      ),
    );
  }

  bool sessionMatchesFilter(RemoteSessionSummary session) {
    switch (sessionFilter) {
      case _SessionFilter.all:
        return true;
      case _SessionFilter.running:
        return session.running;
      case _SessionFilter.archived:
        return session.archived;
      case _SessionFilter.claude:
        return session.engine == SessionEngine.claude;
      case _SessionFilter.codex:
        return session.engine == SessionEngine.codex;
    }
  }

  void selectSessionFilter(_SessionFilter filter) {
    if (filter == sessionFilter) return;
    setState(() => sessionFilter = filter);
  }

  Widget buildSessionFilterBar() {
    final palette = AppPalette.of(context);
    final animation = MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: Duration(milliseconds: 150),
            reverseDuration: Duration(milliseconds: 150),
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SingleChildScrollView(
        key: const ValueKey('session-filter-bar'),
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.hardEdge,
        child: Row(
          children: [
            for (final filter in _SessionFilter.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('session-filter-${filter.name}'),
                  label: Text(filter.label),
                  selected: sessionFilter == filter,
                  onSelected: (_) => selectSessionFilter(filter),
                  showCheckmark: true,
                  checkmarkColor: palette.ink,
                  chipAnimationStyle: ChipAnimationStyle(
                    enableAnimation: animation,
                    selectAnimation: animation,
                    avatarDrawerAnimation: animation,
                    deleteDrawerAnimation: animation,
                  ),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  labelStyle: TextStyle(
                    color: sessionFilter == filter
                        ? palette.ink
                        : palette.muted,
                    fontWeight: sessionFilter == filter
                        ? FontWeight.w700
                        : FontWeight.w600,
                    fontSize: 13,
                  ),
                  backgroundColor: palette.control,
                  selectedColor: palette.accentSoft,
                  side: BorderSide(
                    color: sessionFilter == filter
                        ? palette.navigatorAccent
                        : palette.line,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildSessionFilterEmptyState() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '没有符合条件的会话',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: AppPalette.of(context).ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '试试其他筛选条件',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppPalette.of(context).muted,
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('session-filter-clear'),
            onPressed: () => selectSessionFilter(_SessionFilter.all),
            icon: const SmartIcon(LucideIcons.x, size: AppIconSizes.inline),
            label: const Text('清除筛选'),
          ),
        ],
      ),
    );
  }

  Widget buildHomeView() {
    final project = selectedProject;
    final projectSessions = project == null
        ? const <RemoteSessionSummary>[]
        : widget.sessions
              .where((session) => session.projectId == project.id)
              .toList();
    final sessions = projectSessions.where(sessionMatchesFilter).toList();

    return ListView.builder(
      key: const ValueKey('session-home-view'),
      padding: const EdgeInsets.only(top: 12, bottom: 104),
      itemCount: sessions.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '项目与会话',
                key: const ValueKey('session-page-title'),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: AppPalette.of(context).ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 32,
                  height: 1.08,
                  letterSpacing: -0.9,
                ),
              ),
              const SizedBox(height: 30),
              ListTile(
                key: const ValueKey('open-project-browser'),
                contentPadding: EdgeInsets.zero,
                horizontalTitleGap: 12,
                leading: const SizedBox(
                  width: 24,
                  child: PhosphorIcon(
                    PhosphorIconsFill.squaresFour,
                    size: AppMark.size,
                    color: AppMark.slate,
                  ),
                ),
                title: Text(
                  '所有项目',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    letterSpacing: -0.2,
                  ),
                ),
                trailing: Icon(
                  LucideIcons.chevronRight,
                  size: AppIconSizes.inline,
                  color: AppPalette.of(context).inactive,
                ),
                onTap: () => openView(_SessionNavigatorView.projects),
              ),
              buildSectionTitle('会话'),
              if (projectSessions.isNotEmpty) buildSessionFilterBar(),
              if (projectSessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                  child: OutlinedButton.icon(
                    key: const ValueKey('session-empty-create'),
                    onPressed: widget.running ? null : createSession,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppPalette.of(context).ink,
                      backgroundColor: AppPalette.of(context).surface,
                      side: BorderSide(
                        color: AppPalette.of(context).lineStrong,
                      ),
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                    ),
                    icon: const SmartIcon(
                      LucideIcons.plus,
                      size: AppIconSizes.control,
                    ),
                    label: const Text('新建第一个会话'),
                  ),
                )
              else if (sessions.isEmpty)
                buildSessionFilterEmptyState(),
            ],
          );
        }
        if (index <= sessions.length) {
          return buildSessionRow(sessions[index - 1], index: index - 1);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            buildSectionTitle('项目'),
            for (var i = 0; i < widget.projects.take(3).length; i++)
              buildProjectRow(widget.projects[i], compact: true, index: i),
          ],
        );
      },
    );
  }

  Widget buildProjectView() {
    final current = selectedProject;
    final others = widget.projects
        .where((project) => project.id != selectedProjectId)
        .toList();

    return ListView.builder(
      key: const ValueKey('session-project-view'),
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      itemCount: others.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              buildSectionTitle('当前项目'),
              if (current != null) buildProjectRow(current, index: 0),
              buildSectionTitle('其他项目'),
            ],
          );
        }
        return buildProjectRow(others[index - 1], index: index);
      },
    );
  }

  Widget buildSearchPrompt() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.search,
            size: AppIconSizes.hero,
            color: AppPalette.of(context).inactive,
          ),
          const SizedBox(height: 12),
          Text(
            '搜索所有会话',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '输入标题或会话中的关键词',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppPalette.of(context).muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSearchView() {
    return Column(
      key: const ValueKey('session-search-view'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (searching) const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 12),
        Expanded(
          child: searchQuery.isEmpty ? buildSearchPrompt() : buildSearchBody(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final currentProjectName = selectedProject?.name ?? '项目';
    final titleText = switch (view) {
      _SessionNavigatorView.home => currentProjectName,
      _SessionNavigatorView.projects => '选择项目',
      _SessionNavigatorView.search => '',
    };
    final viewKey = switch (view) {
      _SessionNavigatorView.home => const ValueKey('session-home-transition'),
      _SessionNavigatorView.projects => const ValueKey(
        'session-project-transition',
      ),
      _SessionNavigatorView.search => const ValueKey(
        'session-search-transition',
      ),
    };

    return PopScope(
      canPop: view == _SessionNavigatorView.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && view != _SessionNavigatorView.home) {
          openView(_SessionNavigatorView.home);
        }
      },
      child: Scaffold(
        key: const ValueKey('session-navigator-page'),
        backgroundColor: AppPalette.of(context).paper,
        appBar: AppBar(
          backgroundColor: AppPalette.of(context).paper,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            key: view == _SessionNavigatorView.home
                ? const ValueKey('session-page-back')
                : view == _SessionNavigatorView.projects
                ? const ValueKey('session-back-projects')
                : const ValueKey('session-back-search'),
            tooltip: view == _SessionNavigatorView.home ? '返回聊天' : '返回项目与会话',
            onPressed: view == _SessionNavigatorView.home
                ? () => Navigator.maybePop(context)
                : () => openView(_SessionNavigatorView.home),
            icon: const SmartIcon(
              LucideIcons.arrowLeft,
              size: AppIconSizes.primary,
            ),
          ),
          title: Row(
            children: [
              SizedBox(
                key: const ValueKey('session-index-marker'),
                width: 22,
                height: 22,
                child: AnimatedSwitcher(
                  duration: reduceMotion ? Duration.zero : AppMotion.fast,
                  switchInCurve: AppMotion.enter,
                  switchOutCurve: AppMotion.exit,
                  child: view == _SessionNavigatorView.home
                      ? PhosphorIcon(
                          selectedProject != null
                              ? inferProjectIcon(
                                  selectedProject!.name,
                                  selectedProject!.path,
                                )
                              : PhosphorIconsFill.cube,
                          key: const ValueKey('session-context-icon-home'),
                          size: AppIconSizes.control,
                          color: AppPalette.of(context).navigatorAccent,
                        )
                      : Icon(
                          view == _SessionNavigatorView.projects
                              ? LucideIcons.layoutGrid
                              : LucideIcons.search,
                          key: ValueKey('session-context-icon-${view.name}'),
                          size: AppIconSizes.control,
                          color: view == _SessionNavigatorView.projects
                              ? AppPalette.of(context).ink
                              : AppPalette.of(context).navigatorAccent,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedSwitcher(
                  key: const ValueKey('session-title-switcher'),
                  duration: reduceMotion ? Duration.zero : AppMotion.standard,
                  reverseDuration: reduceMotion
                      ? Duration.zero
                      : AppMotion.fast,
                  switchInCurve: AppMotion.enter,
                  switchOutCurve: AppMotion.exit,
                  transitionBuilder: (child, animation) {
                    if (reduceMotion) return child;
                    final isSearchField =
                        child.key == const ValueKey('session-search-field');
                    final offset = Tween<Offset>(
                      begin: isSearchField
                          ? const Offset(0.08, 0)
                          : const Offset(0, 0.12),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: offset, child: child),
                    );
                  },
                  child: view == _SessionNavigatorView.search
                      ? TextField(
                          key: const ValueKey('session-search-field'),
                          controller: searchController,
                          focusNode: searchFocusNode,
                          maxLength: 200,
                          buildCounter:
                              (
                                context, {
                                required currentLength,
                                required isFocused,
                                required maxLength,
                              }) => null,
                          textInputAction: TextInputAction.search,
                          onChanged: handleSearchChanged,
                          onSubmitted: submitSearch,
                          decoration: InputDecoration(
                            hintText: '搜索标题与会话内容',
                            isDense: true,
                            filled: true,
                            fillColor: AppPalette.of(context).control,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            prefixIcon: const SmartIcon(
                              LucideIcons.search,
                              size: AppIconSizes.control,
                            ),
                            suffixIcon: searchQuery.isEmpty
                                ? null
                                : IconButton(
                                    key: const ValueKey('session-search-clear'),
                                    tooltip: '清除搜索',
                                    onPressed: clearSearch,
                                    icon: const SmartIcon(
                                      LucideIcons.x,
                                      size: AppIconSizes.control,
                                    ),
                                  ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              borderSide: BorderSide(
                                color: AppPalette.of(context).accentStrong,
                                width: 2,
                              ),
                            ),
                          ),
                        )
                      : Text(
                          titleText,
                          key: ValueKey(
                            'session-title-${view.name}-$selectedProjectId',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: AppPalette.of(context).ink,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                        ),
                ),
              ),
            ],
          ),
          actions: [
            AnimatedSwitcher(
              key: const ValueKey('session-actions-switcher'),
              duration: reduceMotion ? Duration.zero : AppMotion.fast,
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              transitionBuilder: (child, animation) {
                if (reduceMotion) return child;
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(
                      begin: 0.96,
                      end: 1,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: view == _SessionNavigatorView.home
                  ? Row(
                      key: const ValueKey('session-home-actions'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const ValueKey('open-session-search'),
                          tooltip: '搜索所有会话',
                          onPressed: () =>
                              openView(_SessionNavigatorView.search),
                          icon: const SmartIcon(
                            LucideIcons.search,
                            size: AppIconSizes.primary,
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('create-session'),
                          tooltip: '新建会话',
                          onPressed: widget.running ? null : createSession,
                          style: IconButton.styleFrom(padding: EdgeInsets.zero),
                          icon: AnimatedContainer(
                            duration: reduceMotion
                                ? Duration.zero
                                : AppMotion.fast,
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: widget.running
                                  ? AppPalette.of(context).control
                                  : AppPalette.of(context).ink,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Icon(
                                LucideIcons.plus,
                                size: AppIconSizes.control,
                                color: widget.running
                                    ? AppPalette.of(context).inactive
                                    : AppPalette.of(context).surface,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox(key: ValueKey('session-no-actions')),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
            child: AnimatedSwitcher(
              key: const ValueKey('session-view-switcher'),
              duration: reduceMotion ? Duration.zero : AppMotion.standard,
              reverseDuration: reduceMotion ? Duration.zero : AppMotion.fast,
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              transitionBuilder: (child, animation) {
                if (reduceMotion) return child;
                if (searchTransitionActive) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.99,
                        end: 1,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                }
                final incoming = child.key == viewKey;
                final direction = viewMovingForward ? 1.0 : -1.0;
                final offset = Tween<Offset>(
                  begin: Offset((incoming ? 0.045 : -0.025) * direction, 0),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(position: offset, child: child),
                );
              },
              child: KeyedSubtree(
                key: viewKey,
                child: switch (view) {
                  _SessionNavigatorView.home => buildHomeView(),
                  _SessionNavigatorView.projects => buildProjectView(),
                  _SessionNavigatorView.search => buildSearchView(),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsModalSurface extends StatelessWidget {
  const _SettingsModalSurface({required this.child, this.surfaceKey});

  final Widget child;
  final Key? surfaceKey;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = min(
      media.size.height * 0.94,
      media.size.height - media.padding.top - 8,
    );
    const borderRadius = BorderRadius.vertical(top: Radius.circular(28));
    return Align(
      alignment: Alignment.bottomCenter,
      child: RepaintBoundary(
        child: Container(
          key: surfaceKey,
          height: height,
          decoration: AppLiquidGlass.strong(
            context: context,
            borderRadius: borderRadius,
          ),
          child: ClipRRect(
            clipBehavior: Clip.hardEdge,
            borderRadius: borderRadius,
            child: Padding(
              padding: EdgeInsets.only(bottom: media.padding.bottom),
              child: RepaintBoundary(child: child),
            ),
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
    required this.currentModel,
    required this.selectedModel,
    required this.readingFontScale,
    required this.onReconnect,
    required this.onNotificationsChanged,
    required this.onModelChanged,
    required this.onReadingFontScaleChanged,
    required this.onLogout,
  });

  final SavedSession? session;
  final bool notificationsEnabled;
  final String? currentModel;
  final ClaudeModelPreference selectedModel;
  final double readingFontScale;
  final VoidCallback onReconnect;
  final Future<bool> Function(bool) onNotificationsChanged;
  final Future<void> Function(ClaudeModelPreference) onModelChanged;
  final Future<void> Function(double scale, {bool persist})
  onReadingFontScaleChanged;
  final VoidCallback onLogout;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late bool notificationsEnabled = widget.notificationsEnabled;
  late ClaudeModelPreference selectedModel = widget.selectedModel;
  late double readingFontScale = widget.readingFontScale;
  late double persistedReadingFontScale = widget.readingFontScale;
  bool changingNotifications = false;
  bool changingModel = false;
  bool savingReadingFontScale = false;
  bool changingAppearance = false;

  Future<void> changeNotifications(bool value) async {
    if (changingNotifications) return;
    final previous = notificationsEnabled;
    setState(() {
      changingNotifications = true;
      notificationsEnabled = value;
    });
    try {
      final accepted = await widget.onNotificationsChanged(value);
      if (mounted) setState(() => notificationsEnabled = accepted);
    } catch (_) {
      if (!mounted) return;
      setState(() => notificationsEnabled = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('通知设置保存失败，请重试')));
    } finally {
      if (mounted) setState(() => changingNotifications = false);
    }
  }

  Future<void> chooseAppearance() async {
    if (changingAppearance) return;
    final appearance = AppearanceScope.of(context);
    final next = await showAppOptionPicker<ThemeMode>(
      context,
      scrollContent: false,
      builder: (context) => ConversationOptionSheet<ThemeMode>(
        title: '外观',
        detail: '选择浅色、深色，或跟随系统自动切换。',
        selected: appearance.value,
        options: [
          for (final mode in ThemeMode.values)
            ConversationPickerOption(
              value: mode,
              id: 'appearance-${mode.name}',
              title: appearanceLabel(mode),
              description: switch (mode) {
                ThemeMode.system => '随系统设置自动切换浅色和深色',
                ThemeMode.light => '明亮背景，深色文字',
                ThemeMode.dark => '深色背景，浅色文字',
              },
              group: mode == ThemeMode.system ? '自动切换' : '固定外观',
              leading: SmartIcon(switch (mode) {
                ThemeMode.system => LucideIcons.contrast,
                ThemeMode.light => LucideIcons.sun,
                ThemeMode.dark => LucideIcons.moonStar,
              }, size: AppIconSizes.control),
            ),
        ],
      ),
    );
    if (next == null || !mounted) return;
    setState(() => changingAppearance = true);
    try {
      await appearance.select(next);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('外观设置保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => changingAppearance = false);
    }
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
    final appearance = AppearanceScope.maybeOf(context);
    final textTheme = Theme.of(context).textTheme;
    final rowTitleStyle = textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      height: 1.3,
    );
    final rowSubtitleStyle = textTheme.bodySmall?.copyWith(
      color: AppPalette.of(context).muted,
      height: 1.4,
    );

    final settingsPage = Column(
      key: const ValueKey('settings-page'),
      children: [
        _SettingsPageHeader(title: '设置', onClose: () => Navigator.pop(context)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            children: [
              const _SettingsSectionLabel('对话偏好'),
              const SizedBox(height: 10),
              _SettingsGroupCard(
                children: [
                  _SettingsPreferenceRow(
                    key: const ValueKey('model-setting'),
                    icon: LucideIcons.slidersHorizontal,
                    title: '模型',
                    subtitle: modelPreferenceDescription(
                      selectedModel,
                      widget.currentModel == null
                          ? null
                          : formatModelName(widget.currentModel!),
                    ),
                    trailing: changingModel
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const SmartIcon(
                            LucideIcons.chevronRight,
                            size: AppIconSizes.control,
                          ),
                    onTap: changingModel ? null : chooseModel,
                  ),
                  const _SettingsDivider(),
                  if (appearance != null)
                    _SettingsPreferenceRow(
                      key: const ValueKey('appearance-setting'),
                      icon: LucideIcons.sunMoon,
                      title: '外观',
                      subtitle: appearanceLabel(appearance.value),
                      trailing: const SmartIcon(
                        LucideIcons.chevronRight,
                        size: AppIconSizes.control,
                      ),
                      onTap: changingAppearance ? null : chooseAppearance,
                    ),
                  const _SettingsDivider(),
                  Padding(
                    key: const ValueKey('reading-font-size-setting'),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const _SettingsLeadingIcon(icon: LucideIcons.type),
                            const SizedBox(width: 12),
                            Expanded(child: Text('字体大小', style: rowTitleStyle)),
                            Text(
                              readingFontSizeLabel(readingFontScale),
                              style: textTheme.labelLarge?.copyWith(
                                color: AppPalette.of(context).accent,
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
                                color: AppPalette.of(context).muted,
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                key: const ValueKey('reading-font-size-slider'),
                                value: readingFontScale.clamp(
                                  kReadingFontScaleMin,
                                  kReadingFontScaleMax,
                                ),
                                min: kReadingFontScaleMin,
                                max: kReadingFontScaleMax,
                                divisions: 11,
                                label: readingFontSizeLabel(readingFontScale),
                                onChanged: previewReadingFontScale,
                                onChangeEnd: commitReadingFontScale,
                              ),
                            ),
                            Text(
                              'A',
                              style: textTheme.bodySmall?.copyWith(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.of(context).ink,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const _SettingsDivider(),
                  SwitchListTile(
                    key: const ValueKey('background-notifications-toggle'),
                    contentPadding: const EdgeInsets.fromLTRB(14, 4, 10, 4),
                    value: notificationsEnabled,
                    onChanged: changingNotifications
                        ? null
                        : changeNotifications,
                    secondary: const _SettingsLeadingIcon(
                      icon: LucideIcons.bell,
                    ),
                    title: Text('后台通知', style: rowTitleStyle),
                    subtitle: Text('任务完成、失败或等待权限时提醒', style: rowSubtitleStyle),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              const _SettingsSectionLabel('桌面主机'),
              const SizedBox(height: 10),
              _SettingsGroupCard(
                children: [
                  _SettingsPreferenceRow(
                    icon: LucideIcons.monitor,
                    title: widget.session?.deviceName ?? '未配对主机',
                    subtitle:
                        widget.session?.workspaceName ??
                        widget.session?.workspaceDir ??
                        '暂无工作区信息',
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
                    child: Column(
                      children: [
                        _SettingsDetailLine(
                          label: '服务',
                          value: widget.session?.origin.toString() ?? '暂无服务信息',
                        ),
                        const SizedBox(height: 8),
                        _SettingsDetailLine(
                          label: '目录',
                          value:
                              widget.session?.workspaceDir ??
                              widget.session?.workspaceName ??
                              '暂无工作区信息',
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  _SettingsActionRow(
                    icon: LucideIcons.refreshCw,
                    label: '重新连接',
                    onTap: () {
                      Navigator.pop(context);
                      widget.onReconnect();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _SettingsGroupCard(
                children: [
                  _SettingsActionRow(
                    icon: LucideIcons.unlink,
                    label: '退出配对',
                    color: AppPalette.of(context).danger,
                    onTap: () => confirmLogout(context, widget.onLogout),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '偏好只保存在这台手机；模型与阅读设置会用于之后发送的消息。',
                  style: TextStyle(
                    color: AppPalette.of(context).muted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return appModalSheetScaffold(
      _SettingsModalSurface(
        surfaceKey: const ValueKey('settings-surface'),
        child: settingsPage,
      ),
      barrierColor: AppPalette.of(context).scrim,
    );
  }
}

class _SettingsPageHeader extends StatelessWidget {
  const _SettingsPageHeader({required this.title, this.onClose});

  final String title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.4,
                height: 1.08,
              ),
            ),
          ),
          if (onClose != null)
            _SettingsIconButton(
              icon: LucideIcons.x,
              tooltip: '关闭',
              onPressed: onClose!,
            ),
        ],
      ),
    );
  }
}

class _SettingsIconButton extends StatelessWidget {
  const _SettingsIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: AppSizes.touchTarget,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        icon: DecoratedBox(
          decoration: BoxDecoration(
            color: AppPalette.of(context).surface,
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(
            dimension: AppSizes.iconControl,
            child: Icon(icon, size: AppIconSizes.control),
          ),
        ),
      ),
    );
  }
}

class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label,
        style: TextStyle(
          color: AppPalette.of(context).muted,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
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
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: AppPalette.of(context).control,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: SmartIcon(icon, size: AppIconSizes.control),
    );
  }
}

class _SettingsPreferenceRow extends StatelessWidget {
  const _SettingsPreferenceRow({
    super.key,
    this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData? icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SignalPressEffect(
      enabled: onTap != null,
      scaleOnPress: false,
      builder: (context, pressed, child) => SignalAnimatedSurface(
        duration: appPressAnimationDuration(context, pressed),
        decoration: BoxDecoration(
          color: pressed ? AppPalette.of(context).control : Colors.transparent,
        ),
        child: child,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 76),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                children: [
                  _SettingsLeadingIcon(icon: icon!),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppPalette.of(context).muted,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 10),
                    IconTheme(
                      data: IconThemeData(color: AppPalette.of(context).muted),
                      child: trailing!,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, indent: 70, endIndent: 14);
  }
}

class _SettingsGroupCard extends StatelessWidget {
  const _SettingsGroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.of(context).surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppElevation.surfaceCard(context: context),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _SettingsDetailLine extends StatelessWidget {
  const _SettingsDetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 38,
          child: Text(
            label,
            style: TextStyle(
              color: AppPalette.of(context).muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppPalette.of(context).ink,
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsActionRow extends StatelessWidget {
  const _SettingsActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppPalette.of(context).ink;
    return SignalPressEffect(
      scaleOnPress: false,
      builder: (context, pressed, child) => SignalAnimatedSurface(
        duration: appPressAnimationDuration(context, pressed),
        decoration: BoxDecoration(
          color: pressed ? color.withValues(alpha: 0.08) : Colors.transparent,
        ),
        child: child,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 50),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: AppIconSizes.inline, color: color),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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
  return showAppOptionPicker<ClaudeModelPreference>(
    context,
    scrollContent: false,
    builder: (sheetContext) => ConversationOptionSheet<ClaudeModelPreference>(
      title: '选择模型',
      detail: '用于之后发送的消息，当前任务继续使用原模型。',
      selected: selected,
      options: [
        for (final preference in ClaudeModelPreference.values)
          ConversationPickerOption(
            value: preference,
            id: 'model-option-${preference.wireName ?? 'follow'}',
            title: preference == ClaudeModelPreference.followComputer
                ? '跟随电脑配置'
                : preference.label,
            description: modelPreferenceOptionDescription(preference),
            group: preference == ClaudeModelPreference.followComputer
                ? '电脑默认'
                : 'Claude 模型',
            leading: SmartIcon(switch (preference) {
              ClaudeModelPreference.followComputer => LucideIcons.monitor,
              ClaudeModelPreference.opus => LucideIcons.diamond,
              ClaudeModelPreference.sonnet => LucideIcons.sparkle,
              ClaudeModelPreference.fable => LucideIcons.feather,
            }, size: AppIconSizes.control),
          ),
      ],
    ),
  );
}

Future<String?> showCodexModelPicker(
  BuildContext context, {
  required String? selected,
  required Future<List<CodexModelOption>> Function() loadModels,
}) {
  return showAppOptionPicker<String>(
    context,
    scrollContent: false,
    builder: (_) =>
        CodexModelPicker(selected: selected, loadModels: loadModels),
  );
}

Future<AttachmentSource?> showAttachmentSourceSheet(
  BuildContext context, {
  bool imagesOnly = false,
}) {
  return showModalBottomSheet<AttachmentSource>(
    context: context,
    sheetAnimationStyle: appOverlayAnimationStyle(context),
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const SmartIcon(LucideIcons.camera),
              title: const Text('拍照'),
              subtitle: const Text('拍一张照片作为附件'),
              onTap: () => Navigator.pop(context, AttachmentSource.camera),
            ),
            ListTile(
              leading: const SmartIcon(LucideIcons.image),
              title: const Text('选择图片'),
              subtitle: const Text('从相册选择一张或多张图片'),
              onTap: () => Navigator.pop(context, AttachmentSource.photos),
            ),
            if (!imagesOnly)
              ListTile(
                leading: const SmartIcon(LucideIcons.folderOpen),
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
    animationStyle: appOverlayAnimationStyle(context),
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
            backgroundColor: AppPalette.of(context).stop,
            foregroundColor: AppPalette.of(context).onStop,
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

class TranscriptView extends StatefulWidget {
  const TranscriptView({
    super.key,
    required this.messages,
    this.jumpRequest,
    this.session,
    this.activeSessionId,
    this.running = false,
    this.runStartedAt,
    required this.pendingPermissions,
    required this.respondingPermissionIds,
    required this.connected,
    this.offline = false,
    this.topPadding = 8,
    this.workspaceChangeEcho,
    required this.onFillPrompt,
    required this.onReconnect,
    required this.onPermissionAllow,
    required this.onPermissionDeny,
    this.onJumpHandled,
    this.onOpenWorkspaceChanges,
  });

  final List<TranscriptMessage> messages;
  final TranscriptJumpRequest? jumpRequest;
  final SavedSession? session;
  final String? activeSessionId;
  final bool running;
  final DateTime? runStartedAt;
  final List<RemotePermissionRequest> pendingPermissions;
  final Set<String> respondingPermissionIds;
  final bool connected;
  final bool offline;
  final double topPadding;
  final WorkspaceChangeEcho? workspaceChangeEcho;
  final ValueChanged<String> onFillPrompt;
  final VoidCallback onReconnect;
  final ValueChanged<RemotePermissionRequest> onPermissionAllow;
  final ValueChanged<RemotePermissionRequest> onPermissionDeny;
  final ValueChanged<TranscriptJumpRequest>? onJumpHandled;
  final VoidCallback? onOpenWorkspaceChanges;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _VisibleTranscriptRow {
  const _VisibleTranscriptRow(this.rawIndex, this.message);

  final int rawIndex;
  final TranscriptMessage message;
}

class _ProcessGroupRow {
  const _ProcessGroupRow(this.rows, {required this.running});

  final List<_VisibleTranscriptRow> rows;
  final bool running;

  TranscriptMessage get message => rows.first.message;
  int get rawIndex => rows.first.rawIndex;
}

List<Object> _groupTranscriptRows(
  List<_VisibleTranscriptRow> rows, {
  required bool running,
}) {
  final items = <Object>[];
  final lastUserIndex =
      rows
          .where((row) => row.message.role == MessageRole.user)
          .lastOrNull
          ?.rawIndex ??
      -1;
  bool isProcessPart(TranscriptMessage message) =>
      message.role == MessageRole.assistant ||
      (message.role == MessageRole.activity &&
          (message.activityKind == ActivityKind.tool ||
              message.activityKind == ActivityKind.thinking));
  var index = 0;
  while (index < rows.length) {
    final row = rows[index];
    if (!isProcessPart(row.message)) {
      items.add(row);
      index++;
      continue;
    }
    final process = <_VisibleTranscriptRow>[];
    while (index < rows.length && isProcessPart(rows[index].message)) {
      process.add(rows[index++]);
    }
    final result = process.last.message.role == MessageRole.assistant
        ? process.removeLast()
        : null;
    if (process.isNotEmpty) {
      items.add(
        _ProcessGroupRow(
          process,
          running: running && process.first.rawIndex > lastUserIndex,
        ),
      );
    }
    if (result != null) items.add(result);
  }
  return items;
}

class _TranscriptProcessBlock extends StatefulWidget {
  const _TranscriptProcessBlock({
    super.key,
    required this.group,
    required this.buildPart,
    this.revealRawIndex,
  });

  final _ProcessGroupRow group;
  final Widget Function(_VisibleTranscriptRow) buildPart;
  final int? revealRawIndex;

  @override
  State<_TranscriptProcessBlock> createState() =>
      _TranscriptProcessBlockState();
}

class _TranscriptProcessBlockState extends State<_TranscriptProcessBlock> {
  bool toolsExpanded = true;

  @override
  void didUpdateWidget(covariant _TranscriptProcessBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.rawIndex != widget.group.rawIndex) {
      toolsExpanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final tools = group.rows
        .where((row) => row.message.activityKind == ActivityKind.tool)
        .map((row) => row.message)
        .toList();
    final reveal = group.rows.any(
      (row) => row.rawIndex == widget.revealRawIndex,
    );
    final liveThought = group.running
        ? group.rows
              .where(
                (row) =>
                    row.message.activityKind == ActivityKind.thinking &&
                    row.message.activityState == ActivityState.running,
              )
              .lastOrNull
        : null;
    final historyRows = group.rows.where((row) => row != liveThought).toList();
    Widget buildParts(Widget Function(TranscriptMessage)? buildTool) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < historyRows.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          if (historyRows[i].message.activityKind == ActivityKind.tool)
            buildTool!(historyRows[i].message)
          else
            widget.buildPart(historyRows[i]),
        ],
      ],
    );
    final content = tools.isEmpty
        ? buildParts(null)
        : ActivityTimelineCard(
            activities: tools,
            running: group.running,
            expanded: toolsExpanded || reveal,
            onExpandedChanged: (value) => setState(() => toolsExpanded = value),
            revealActivityId: reveal
                ? group.rows
                      .firstWhere(
                        (row) => row.rawIndex == widget.revealRawIndex,
                      )
                      .message
                      .activityId
                : null,
            contentBuilder: (context, buildTool) => buildParts(buildTool),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        content,
        if (liveThought != null) widget.buildPart(liveThought),
      ],
    );
  }
}

class _TranscriptViewState extends State<TranscriptView> {
  static const highlightDuration = Duration(milliseconds: 1600);
  static const maxJumpAttempts = 48;

  final ScrollController scrollController = ScrollController();
  final Map<int, GlobalKey> rowKeys = {};
  Timer? highlightTimer;
  int? highlightedRawIndex;
  int? handledJumpGeneration;
  int? jumpInFlightGeneration;
  bool jumpScheduled = false;
  bool bottomJumpScheduled = false;
  bool didInitialBottomJump = false;
  bool followingBottom = true;
  int observedVisibleMessageCount = 0;
  int observedTailSignature = 0;
  int unreadOutputCount = 0;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(updateBottomFollowing);
    observeTranscript(reset: true);
    scheduleJump();
  }

  @override
  void didUpdateWidget(covariant TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeSessionId != widget.activeSessionId) {
      highlightTimer?.cancel();
      highlightedRawIndex = null;
      rowKeys.clear();
      didInitialBottomJump = false;
      followingBottom = true;
      unreadOutputCount = 0;
      observeTranscript(reset: true);
    } else {
      observeTranscript();
    }
    scheduleJump();
    scheduleBottomJump(force: !didInitialBottomJump);
  }

  @override
  void dispose() {
    highlightTimer?.cancel();
    scrollController.removeListener(updateBottomFollowing);
    scrollController.dispose();
    super.dispose();
  }

  void updateBottomFollowing() {
    if (!scrollController.hasClients || bottomJumpScheduled) return;
    final nextFollowing = scrollController.position.extentAfter <= 72;
    if (followingBottom == nextFollowing) return;
    followingBottom = nextFollowing;
    if (nextFollowing && unreadOutputCount > 0) {
      setState(() => unreadOutputCount = 0);
    }
  }

  void observeTranscript({bool reset = false}) {
    final rows = visibleRows();
    final visibleCount = rows.length;
    final last = rows.isEmpty ? null : rows.last.message;
    final tailSignature = last == null
        ? 0
        : Object.hash(
            last.role,
            last.text,
            last.attachments.length,
            last.activityId,
            last.activityKind,
            last.activityState,
            last.activityTool,
            last.activityDetail,
            last.activityDurationMs,
          );
    if (!reset &&
        !followingBottom &&
        widget.jumpRequest == null &&
        (visibleCount != observedVisibleMessageCount ||
            tailSignature != observedTailSignature)) {
      final added = max(0, visibleCount - observedVisibleMessageCount);
      unreadOutputCount += added > 0
          ? added
          : unreadOutputCount == 0
          ? 1
          : 0;
    }
    observedVisibleMessageCount = visibleCount;
    observedTailSignature = tailSignature;
  }

  Future<void> scrollToLatest() async {
    if (unreadOutputCount > 0) {
      setState(() => unreadOutputCount = 0);
    }
    followingBottom = true;
    if (!scrollController.hasClients) return;
    bottomJumpScheduled = true;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final target = scrollController.position.maxScrollExtent;
    try {
      if (reduceMotion) {
        scrollController.jumpTo(target);
      } else {
        await scrollController.animateTo(
          target,
          duration: AppMotion.standard,
          curve: AppMotion.enter,
        );
      }
    } finally {
      bottomJumpScheduled = false;
    }
    if (!mounted || !scrollController.hasClients) return;
    followingBottom = true;
    scheduleBottomJump(force: true);
  }

  void scheduleBottomJump({required bool force}) {
    if (widget.messages.isEmpty ||
        widget.jumpRequest != null ||
        bottomJumpScheduled ||
        (!force && !followingBottom)) {
      return;
    }
    bottomJumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bottomJumpScheduled = false;
      if (!mounted ||
          widget.messages.isEmpty ||
          widget.jumpRequest != null ||
          !scrollController.hasClients ||
          (!force && !followingBottom)) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      didInitialBottomJump = true;
      followingBottom = true;
    });
  }

  List<_VisibleTranscriptRow> visibleRows() {
    final rows = <_VisibleTranscriptRow>[];
    for (var index = 0; index < widget.messages.length; index++) {
      final message = widget.messages[index];
      if (isBlankAssistantMessage(message)) continue;
      if (message.activityKind == ActivityKind.thinking &&
          message.activityState != ActivityState.running &&
          (message.activityDetail?.trim().isEmpty ?? true)) {
        continue;
      }
      rows.add(_VisibleTranscriptRow(index, message));
    }
    return rows;
  }

  void scheduleJump() {
    final request = widget.jumpRequest;
    if (request == null ||
        request.sessionId != widget.activeSessionId ||
        request.generation == handledJumpGeneration ||
        request.generation == jumpInFlightGeneration ||
        jumpScheduled) {
      return;
    }
    jumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      jumpScheduled = false;
      if (!mounted) return;
      unawaited(performJump());
    });
  }

  Future<void> performJump() async {
    final request = widget.jumpRequest;
    if (request == null ||
        request.sessionId != widget.activeSessionId ||
        request.generation == handledJumpGeneration ||
        request.generation == jumpInFlightGeneration ||
        widget.messages.isEmpty) {
      return;
    }

    final targetRawIndex = resolveTargetRawIndex(request);
    if (targetRawIndex == null) {
      finishJump(request, found: false);
      return;
    }
    final rows = visibleRows();
    final targetRowIndex = rows.indexWhere(
      (row) => row.rawIndex == targetRawIndex,
    );
    if (targetRowIndex < 0) {
      finishJump(request, found: false);
      return;
    }

    jumpInFlightGeneration = request.generation;
    final found = await scrollToRow(
      request,
      rows,
      targetRowIndex,
      targetRawIndex,
    );
    if (!mounted || widget.jumpRequest?.generation != request.generation) {
      jumpInFlightGeneration = null;
      return;
    }
    finishJump(request, found: found, rawIndex: targetRawIndex);
  }

  int? resolveTargetRawIndex(TranscriptJumpRequest request) {
    final expectedRole = switch (request.role) {
      RemoteSessionSearchRole.user => MessageRole.user,
      RemoteSessionSearchRole.assistant => MessageRole.assistant,
      RemoteSessionSearchRole.title => null,
    };
    if (expectedRole == null) return null;
    final normalizedSnippet = request.snippet
        .replaceFirst(RegExp(r'^…\s*'), '')
        .replaceFirst(RegExp(r'\s*…$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    bool matches(int index) {
      if (index < 0 || index >= widget.messages.length) return false;
      final message = widget.messages[index];
      if (message.role != expectedRole) return false;
      if (normalizedSnippet.isEmpty) return true;
      final normalizedText = message.text
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return normalizedText.contains(normalizedSnippet);
    }

    if (matches(request.messageIndex)) return request.messageIndex;

    int? closest;
    var closestDistance = 1 << 30;
    for (var index = 0; index < widget.messages.length; index++) {
      if (!matches(index)) continue;
      final distance = (index - request.messageIndex).abs();
      if (distance < closestDistance) {
        closest = index;
        closestDistance = distance;
      }
    }
    return closest;
  }

  Future<bool> scrollToRow(
    TranscriptJumpRequest request,
    List<_VisibleTranscriptRow> rows,
    int targetRowIndex,
    int targetRawIndex,
  ) async {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    for (var attempt = 0; attempt < maxJumpAttempts; attempt++) {
      if (!mounted || widget.jumpRequest?.generation != request.generation) {
        return false;
      }
      final targetContext = rowKeys[targetRawIndex]?.currentContext;
      final targetObject = targetContext?.findRenderObject();
      if (targetContext != null &&
          targetContext.mounted &&
          targetObject != null &&
          scrollController.hasClients) {
        final position = scrollController.position;
        final inset = max(
          widget.topPadding + 12,
          position.viewportDimension * 0.18,
        );
        final revealOffset = RenderAbstractViewport.of(
          targetObject,
        ).getOffsetToReveal(targetObject, 0).offset;
        final targetOffset = (revealOffset - inset)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
        if (reduceMotion) {
          scrollController.jumpTo(targetOffset);
        } else {
          await scrollController.animateTo(
            targetOffset,
            duration: AppMotion.standard,
            curve: AppMotion.enter,
          );
        }
        return true;
      }

      if (!scrollController.hasClients) {
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }

      final position = scrollController.position;
      final builtRows = <({int index, double height})>[];
      for (var index = 0; index < rows.length; index++) {
        final rowContext = rowKeys[rows[index].rawIndex]?.currentContext;
        final renderObject = rowContext?.findRenderObject();
        if (renderObject is RenderBox && renderObject.hasSize) {
          builtRows.add((index: index, height: renderObject.size.height));
        }
      }

      double nextOffset;
      if (builtRows.isEmpty) {
        final fraction = rows.length <= 1
            ? 0.0
            : targetRowIndex / (rows.length - 1);
        nextOffset = position.maxScrollExtent * fraction;
      } else {
        final firstIndex = builtRows.first.index;
        final lastIndex = builtRows.last.index;
        final averageHeight =
            builtRows.fold<double>(0, (sum, row) => sum + row.height) /
            builtRows.length;
        if (targetRowIndex < firstIndex) {
          nextOffset =
              position.pixels - (firstIndex - targetRowIndex) * averageHeight;
        } else if (targetRowIndex > lastIndex) {
          nextOffset =
              position.pixels + (targetRowIndex - lastIndex) * averageHeight;
        } else {
          final fraction = rows.length <= 1
              ? 0.0
              : targetRowIndex / (rows.length - 1);
          nextOffset = position.maxScrollExtent * fraction;
        }
      }

      nextOffset = nextOffset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((nextOffset - position.pixels).abs() < 1 &&
          position.maxScrollExtent > position.minScrollExtent) {
        final direction =
            builtRows.isNotEmpty && targetRowIndex < builtRows.first.index
            ? -1.0
            : 1.0;
        nextOffset =
            (position.pixels + direction * position.viewportDimension * 0.8)
                .clamp(position.minScrollExtent, position.maxScrollExtent)
                .toDouble();
      }
      scrollController.jumpTo(nextOffset);
      await WidgetsBinding.instance.endOfFrame;
    }
    return rowKeys[targetRawIndex]?.currentContext != null;
  }

  void finishJump(
    TranscriptJumpRequest request, {
    required bool found,
    int? rawIndex,
  }) {
    jumpInFlightGeneration = null;
    handledJumpGeneration = request.generation;
    didInitialBottomJump = true;
    followingBottom = false;
    if (found && rawIndex != null) {
      highlightTimer?.cancel();
      setState(() => highlightedRawIndex = rawIndex);
      highlightTimer = Timer(highlightDuration, () {
        if (!mounted || highlightedRawIndex != rawIndex) return;
        setState(() => highlightedRawIndex = null);
      });
    } else {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('原消息可能已变化，已打开对应会话')));
    }
    widget.onJumpHandled?.call(request);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty && widget.pendingPermissions.isEmpty) {
      scheduleJump();
      if (!widget.connected) return const SizedBox.expand();
      final workspaceName = widget.session?.workspaceName;
      return LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                // Extra bottom inset so empty-state chips clear the floating composer.
                padding: EdgeInsets.fromLTRB(
                  0,
                  max(1.0, widget.topPadding - 7),
                  0,
                  188,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Text(
                      workspaceName == null ? '下一件事' : '接着处理 $workspaceName',
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      workspaceName == null
                          ? '从下方输入，或先点一个快捷任务'
                          : '从下方输入指令，或先点一个快捷任务',
                      style: TextStyle(
                        color: AppPalette.of(context).muted,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 7,
                          child: PromptChip(
                            icon: LucideIcons.scanSearch,
                            label: '检查项目',
                            caption: workspaceName == null
                                ? '看看哪里需要处理'
                                : '检查 $workspaceName',
                            onTap: () => widget.onFillPrompt(
                              workspaceName == null
                                  ? '检查这个项目'
                                  : '检查当前项目并总结需要处理的地方',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 5,
                          child: PromptChip(
                            icon: LucideIcons.play,
                            label: '运行测试',
                            caption: '跑完告诉我结果',
                            onTap: () => widget.onFillPrompt('运行测试并总结结果'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    final visibleMessages = visibleRows();
    final visibleRawIndices = visibleMessages
        .map((row) => row.rawIndex)
        .toSet();
    rowKeys.removeWhere((rawIndex, _) => !visibleRawIndices.contains(rawIndex));
    for (final row in visibleMessages) {
      rowKeys.putIfAbsent(row.rawIndex, GlobalKey.new);
    }
    scheduleJump();
    scheduleBottomJump(force: !didInitialBottomJump);
    final items = <Object>[
      ..._groupTranscriptRows(visibleMessages, running: widget.running),
      ...widget.pendingPermissions,
      if (widget.workspaceChangeEcho != null &&
          widget.onOpenWorkspaceChanges != null)
        widget.workspaceChangeEcho!,
    ];
    final lastUserIndex = widget.messages.lastIndexWhere(
      (message) => message.role == MessageRole.user,
    );
    final lastAssistantIndex = widget.messages.lastIndexWhere(
      (message) => message.role == MessageRole.assistant,
    );
    final streamingAssistantIndex =
        widget.running && lastAssistantIndex > lastUserIndex
        ? lastAssistantIndex
        : -1;
    final jump = widget.jumpRequest;
    final revealRawIndex =
        highlightedRawIndex ??
        (jump != null &&
                jump.sessionId == widget.activeSessionId &&
                jump.generation != handledJumpGeneration
            ? resolveTargetRawIndex(jump)
            : null);
    final workspaceDir = widget.session?.workspaceDir;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final newOutputLabel =
        '$unreadOutputCount 条新输出 · ${widget.running ? '仍在运行' : '已更新'}';
    return Stack(
      children: [
        Positioned.fill(
          // Scroll relayout/repaint stops here: per-frame scrolling must not
          // re-record the composer, pill, or background display lists.
          child: RepaintBoundary(
            child: ListView.builder(
              key: const ValueKey('transcript-list'),
              controller: scrollController,
              // Tall bottom padding: last bubble can rest above the dock, while
              // earlier lines still scroll *under* the floating composer.
              padding: EdgeInsets.fromLTRB(0, widget.topPadding, 0, 188),
              // Keep prefetch small so long markdown rows are not all built at once.
              cacheExtent: 180,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: true,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                Widget row;
                int? rawIndex;
                if (item is _VisibleTranscriptRow) {
                  rawIndex = item.rawIndex;
                  final highlighted = highlightedRawIndex == rawIndex;
                  row = MessageBlock(
                    key: ValueKey(transcriptRowKey(item.message, rawIndex)),
                    message: item.message,
                    session: widget.session,
                    activeSessionId: widget.activeSessionId,
                    runStartedAt: widget.runStartedAt,
                    searchHighlighted: highlighted,
                    isStreaming: item.rawIndex == streamingAssistantIndex,
                  );
                  if (highlighted) {
                    row = Semantics(
                      key: ValueKey('transcript-search-hit-$rawIndex'),
                      label: '搜索命中消息',
                      child: row,
                    );
                  }
                } else if (item is _ProcessGroupRow) {
                  row = _TranscriptProcessBlock(
                    key: ValueKey('transcript-process-${item.rawIndex}'),
                    group: item,
                    revealRawIndex: revealRawIndex,
                    buildPart: (part) {
                      final highlighted = highlightedRawIndex == part.rawIndex;
                      Widget child = MessageBlock(
                        key: ValueKey(
                          transcriptRowKey(part.message, part.rawIndex),
                        ),
                        message: part.message,
                        session: widget.session,
                        activeSessionId: widget.activeSessionId,
                        runStartedAt: widget.runStartedAt,
                        searchHighlighted: highlighted,
                        isStreaming: part.rawIndex == streamingAssistantIndex,
                      );
                      if (highlighted) {
                        child = Semantics(
                          key: ValueKey(
                            'transcript-search-hit-${part.rawIndex}',
                          ),
                          label: '搜索命中消息',
                          child: child,
                        );
                      }
                      return SizedBox(
                        key: rowKeys[part.rawIndex],
                        child: child,
                      );
                    },
                  );
                } else if (item is WorkspaceChangeEcho) {
                  row = WorkspaceChangeEchoChip(
                    key: const ValueKey('workspace-change-echo'),
                    echo: item,
                    onTap: widget.onOpenWorkspaceChanges!,
                  );
                } else {
                  final request = item as RemotePermissionRequest;
                  row = PermissionRequestCard(
                    key: ValueKey('perm-${request.requestId}'),
                    request: request,
                    responding: widget.respondingPermissionIds.contains(
                      request.requestId,
                    ),
                    connected: widget.connected,
                    workspaceDir: workspaceDir,
                    onAllow: () => widget.onPermissionAllow(request),
                    onDeny: () => widget.onPermissionDeny(request),
                  );
                }
                Object gapItem(Object value) {
                  if (value is _VisibleTranscriptRow) return value.message;
                  if (value is _ProcessGroupRow) return value.message;
                  return value;
                }

                final gap = index == items.length - 1
                    ? 0.0
                    : transcriptGapBetween(
                        gapItem(item),
                        gapItem(items[index + 1]),
                      );
                // Spacing without ListView.separated (one less child per gap).
                final paddedRow = Padding(
                  padding: EdgeInsets.only(bottom: gap),
                  child: row,
                );
                if (rawIndex == null) return paddedRow;
                return SizedBox(key: rowKeys[rawIndex], child: paddedRow);
              },
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 196,
          child: Center(
            child: AnimatedSwitcher(
              duration: reduceMotion ? Duration.zero : AppMotion.fast,
              reverseDuration: reduceMotion ? Duration.zero : AppMotion.fast,
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.96, end: 1).animate(animation),
                  child: child,
                ),
              ),
              child: unreadOutputCount == 0
                  ? const SizedBox.shrink()
                  : Semantics(
                      key: const ValueKey('transcript-new-output'),
                      liveRegion: true,
                      button: true,
                      label: '$newOutputLabel，返回最新输出',
                      onTap: scrollToLatest,
                      child: ExcludeSemantics(
                        child: SignalPressEffect(
                          child: Material(
                            color: AppPalette.of(context).ink,
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                            child: InkWell(
                              onTap: scrollToLatest,
                              borderRadius: BorderRadius.circular(
                                AppRadii.pill,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      LucideIcons.arrowDown,
                                      size: AppIconSizes.inline,
                                      color: AppPalette.of(context).onCta,
                                    ),
                                    const SizedBox(width: 7),
                                    Text(
                                      newOutputLabel,
                                      style: TextStyle(
                                        color: AppPalette.of(context).onCta,
                                        fontSize: 12,
                                        height: 1.25,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
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

  String get _impactLabel {
    final tool = request.toolName.toLowerCase();
    if (tool.contains('write') || tool.contains('edit')) {
      return '可能写入或覆盖工作区文件';
    }
    if (tool.contains('bash') || tool.contains('shell')) {
      return '可能在桌面主机执行命令';
    }
    if (tool.contains('read') ||
        tool.contains('glob') ||
        tool.contains('grep')) {
      return '可能读取工作区内容';
    }
    return '按工具说明执行一次性操作';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = connected && !responding;
    final riskTone = permissionRiskTone(
      request.toolName,
      AppPalette.of(context),
    );
    final summary = request.detail?.trim().isNotEmpty == true
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
        color: AppPalette.of(context).surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(color: AppPalette.of(context).line),
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
                    color: AppPalette.of(context).control,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    LucideIcons.shield,
                    size: AppIconSizes.control,
                    color: riskTone,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _headline,
                    style: TextStyle(
                      fontSize: 18,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.28,
                      color: AppPalette.of(context).ink,
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
                color: AppPalette.of(context).control,
                borderRadius: BorderRadius.circular(AppRadii.compact),
                border: Border.all(color: AppPalette.of(context).line),
              ),
              child: WorkspacePathText(
                summary,
                selectable: false,
                style: TextStyle(
                  color: AppPalette.of(context).ink,
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
                style: TextStyle(
                  color: AppPalette.of(context).muted,
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
                    ? AppPalette.of(context).ink
                    : AppPalette.of(context).muted,
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
                style: TextStyle(
                  color: AppPalette.of(context).muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: SignalPressEffect(
                enabled: enabled,
                scaleOnPress: false,
                child: FilledButton(
                  onPressed: enabled ? onAllow : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppPalette.of(context).cta,
                    foregroundColor: AppPalette.of(context).onCta,
                    disabledBackgroundColor: AppPalette.of(context).control,
                    disabledForegroundColor: AppPalette.of(context).inactive,
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
                scaleOnPress: false,
                child: OutlinedButton(
                  onPressed: enabled ? onDeny : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppPalette.of(context).ink,
                    backgroundColor: AppPalette.of(context).surface,
                    side: BorderSide(color: AppPalette.of(context).lineStrong),
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

/// Shared risk semantics for permission requests. Command execution and
/// file mutation can change the desktop host, so they carry danger weight;
/// read-only tools stay calm. Matches the card's impact copy (_impactLabel).
Color permissionRiskTone(
  String toolName, [
  AppPalette colors = AppPalette.light,
]) {
  final tool = toolName.toLowerCase();
  final mutating =
      tool.contains('write') ||
      tool.contains('edit') ||
      tool.contains('bash') ||
      tool.contains('shell') ||
      tool.contains('command');
  if (mutating) return colors.danger;
  final reading =
      tool.contains('read') ||
      tool.contains('glob') ||
      tool.contains('grep') ||
      tool.contains('search') ||
      tool.contains('list');
  return reading ? colors.warning : colors.accentStrong;
}

class _PermissionSectionLabel extends StatelessWidget {
  const _PermissionSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppPalette.of(context).muted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
    );
  }
}

String transcriptRowKey(TranscriptMessage message, int index) {
  final activityId = message.activityId;
  if (activityId != null && activityId.isNotEmpty) {
    return 'act-$index-$activityId';
  }
  // Index + role keeps identity stable while streaming only mutates last row.
  return 'msg-$index-${message.role.name}';
}

Color transcriptSearchHighlightFill(
  Color base, {
  Color accent = AppColors.accent,
}) {
  return Color.alphaBlend(accent.withValues(alpha: 0.18), base);
}

double transcriptGapBetween(Object current, Object next) {
  if (current is! TranscriptMessage || next is! TranscriptMessage) return 10;
  if (current.role == MessageRole.system || next.role == MessageRole.system) {
    return 8;
  }
  // Two-tier rhythm: a new round breathes wide, work inside one turn binds tight.
  if (next.role == MessageRole.user) return 20;
  if (current.role == MessageRole.user) return 12;
  if (current.role == MessageRole.assistant &&
      next.role == MessageRole.activity) {
    return 12;
  }
  if (current.role == MessageRole.activity ||
      next.role == MessageRole.activity) {
    return 4;
  }
  return 6;
}

const TextStyle _kAssistantPlainStyle = TextStyle(
  fontFamily: AppTypography.assistantFontFamily,
  fontFamilyFallback: AppTypography.assistantFontFamilyFallback,
  height: AppTypography.assistantBodyHeight,
  fontSize: AppTypography.assistantBodySize,
  letterSpacing: 0.1,
);

const TextStyle _kAssistantCodeStyle = TextStyle(
  fontFamily: AppTypography.codeFontFamily,
  fontFamilyFallback: AppTypography.codeFontFamilyFallback,
  fontSize: 13.5,
  height: 1.45,
);

/// Shared once — rebuilding MarkdownStyleSheet.fromTheme per bubble is costly
/// while scrolling long assistant transcripts.
/// Body-like roles must set fontSize explicitly: MarkdownBody still merges
/// Theme bodyMedium (14) / code (≈12) under the custom sheet.
final MarkdownStyleSheet kAssistantMarkdownStyleSheet = MarkdownStyleSheet(
  p: _kAssistantPlainStyle,
  pPadding: EdgeInsets.zero,
  a: const TextStyle(
    color: AppColors.link,
    fontWeight: FontWeight.w500,
    decoration: TextDecoration.underline,
    decorationThickness: 1,
  ),
  code: _kAssistantCodeStyle,
  h1: const TextStyle(
    fontFamily: AppTypography.assistantFontFamily,
    fontFamilyFallback: AppTypography.assistantFontFamilyFallback,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: AppColors.ink,
  ),
  h1Padding: const EdgeInsets.only(top: 18, bottom: 6),
  h2: const TextStyle(
    fontFamily: AppTypography.assistantFontFamily,
    fontFamilyFallback: AppTypography.assistantFontFamilyFallback,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    height: 1.35,
    color: AppColors.ink,
  ),
  h2Padding: const EdgeInsets.only(top: 16, bottom: 6),
  h3: const TextStyle(
    fontFamily: AppTypography.assistantFontFamily,
    fontFamilyFallback: AppTypography.assistantFontFamilyFallback,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.4,
    color: AppColors.ink,
  ),
  h3Padding: const EdgeInsets.only(top: 14, bottom: 4),
  h4: const TextStyle(
    fontFamily: AppTypography.assistantFontFamily,
    fontFamilyFallback: AppTypography.assistantFontFamilyFallback,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    height: 1.4,
    color: AppColors.ink,
  ),
  h4Padding: const EdgeInsets.only(top: 12, bottom: 4),
  h5: _kAssistantPlainStyle.copyWith(fontWeight: FontWeight.w700, height: 1.45),
  h5Padding: const EdgeInsets.only(top: 10, bottom: 4),
  h6: _kAssistantPlainStyle.copyWith(fontWeight: FontWeight.w700, height: 1.45),
  h6Padding: const EdgeInsets.only(top: 10, bottom: 4),
  em: const TextStyle(fontStyle: FontStyle.italic),
  strong: const TextStyle(fontWeight: FontWeight.w700),
  del: const TextStyle(decoration: TextDecoration.lineThrough),
  blockquote: _kAssistantPlainStyle,
  img: _kAssistantPlainStyle,
  checkbox: _kAssistantPlainStyle,
  blockSpacing: 12,
  listIndent: 22,
  listBullet: _kAssistantPlainStyle,
  listBulletPadding: const EdgeInsets.only(right: 8),
  tableHead: _kAssistantPlainStyle.copyWith(fontWeight: FontWeight.w600),
  tableBody: _kAssistantPlainStyle,
  // Intrinsic widths keep every column readable (no char-per-line squeezing);
  // flutter_markdown wraps wide tables in a horizontal scroll automatically.
  // Tables are rare and row-bounded, so intrinsic measurement cost is fine
  // here even though Flex would be cheaper.
  tableColumnWidth: const IntrinsicColumnWidth(),
  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
  blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  blockquoteDecoration: const BoxDecoration(
    border: Border(left: BorderSide(color: AppColors.lineStrong, width: 1)),
  ),
  horizontalRuleDecoration: const BoxDecoration(
    border: Border(top: BorderSide(color: AppColors.line)),
  ),
);

final _assistantMarkdownThemes = <Brightness, MarkdownStyleSheet>{};

MarkdownStyleSheet assistantMarkdownStyleSheet(BuildContext context) {
  final colors = AppPalette.of(context);
  return _assistantMarkdownThemes.putIfAbsent(colors.brightness, () {
    final base = kAssistantMarkdownStyleSheet;
    final body = _kAssistantPlainStyle.copyWith(color: colors.ink);
    return base.copyWith(
      p: body,
      a: base.a!.copyWith(color: colors.link),
      code: _kAssistantCodeStyle.copyWith(
        color: colors.ink,
        backgroundColor: colors.control,
      ),
      h1: base.h1!.copyWith(color: colors.ink),
      h2: base.h2!.copyWith(color: colors.ink),
      h3: base.h3!.copyWith(color: colors.ink),
      h4: base.h4!.copyWith(color: colors.ink),
      h5: base.h5!.copyWith(color: colors.ink),
      h6: base.h6!.copyWith(color: colors.ink),
      blockquote: body.copyWith(color: colors.muted),
      img: body,
      checkbox: body,
      listBullet: body,
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body,
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.lineStrong, width: 2)),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
    );
  });
}

/// Replaces the default `pre` rendering with a card that carries a language
/// label and a copy button (RikkaHub-style code block toolbar).
class _MarkdownPreGate {
  int depth = 0;
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.preGate);

  final _MarkdownPreGate preGate;
  String? language;
  String code = '';

  @override
  void visitElementBefore(md.Element element) {
    preGate.depth += 1;
    language = null;
    code = '';
    final children = element.children;
    if (children != null && children.isNotEmpty) {
      final first = children.first;
      if (first is md.Element) {
        final cls = first.attributes['class'];
        if (cls != null && cls.startsWith('language-')) {
          language = cls.substring('language-'.length);
        }
      }
    }
  }

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    code += text.text;
    return const SizedBox.shrink();
  }

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    try {
      return _CodeBlockCard(language: language, code: trimCodeBlock(code));
    } finally {
      preGate.depth -= 1;
    }
  }

  static String trimCodeBlock(String raw) {
    var text = raw;
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    return text;
  }
}

class _WorkspacePathMarkdownBuilder extends MarkdownElementBuilder {
  _WorkspacePathMarkdownBuilder(this.preGate);

  final _MarkdownPreGate preGate;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (element.tag == 'code') {
      if (preGate.depth > 0) return null;
      final cls = element.attributes['class'] ?? '';
      if (cls.startsWith('language-')) return null;
      if (element.textContent.contains('\n')) return null;
    } else if (element.children != null &&
        element.children!.any((node) => node is md.Element)) {
      return null;
    }
    final text = element.textContent;
    if (text.trim().isEmpty) return null;
    final portal = WorkspacePortal.of(context);
    if (portal?.onOpenPath == null) return null;
    final matches = findWorkspacePaths(
      text,
      workspaceDir: portal?.workspaceDir,
    );
    if (matches.isEmpty) {
      return null;
    }
    // Inline Markdown builders are inserted as WidgetSpans. A long path can
    // wrap inside that child and paint over the next Markdown line, so leave
    // long paths in the parent RichText's native layout.
    // ponytail: long inline Markdown paths lose the path tap affordance; use a
    // custom span renderer if that interaction becomes necessary.
    if (matches.any(
      (match) => text.substring(match.start, match.end).length > 20,
    )) {
      return null;
    }
    final style =
        preferredStyle ??
        parentStyle ??
        (element.tag == 'code' ? _kAssistantCodeStyle : _kAssistantPlainStyle);
    return Text.rich(
      workspacePathInlineSpan(
        text,
        style: style,
        linkColor: AppPalette.of(context).link,
        workspaceDir: portal?.workspaceDir,
        onOpenPath: (path) => WorkspacePortal.openPath(context, path),
      ),
    );
  }
}

class _CodeBlockCard extends StatefulWidget {
  const _CodeBlockCard({
    this.language,
    required this.code,
    this.fullScreen = false,
  });

  final String? language;
  final String code;
  final bool fullScreen;

  @override
  State<_CodeBlockCard> createState() => _CodeBlockCardState();
}

class _CodeBlockCardState extends State<_CodeBlockCard> {
  Timer? copiedResetTimer;
  bool copied = false;
  bool wrapLines = false;
  double fontSize = _kAssistantCodeStyle.fontSize!;
  late final ScrollController verticalController = ScrollController();
  late final ScrollController horizontalController = ScrollController();

  @override
  void dispose() {
    copiedResetTimer?.cancel();
    if (widget.fullScreen) {
      verticalController.dispose();
      horizontalController.dispose();
    }
    super.dispose();
  }

  void openFullScreen() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(
      AppMaterialPageRoute<void>(
        reduceMotion: MediaQuery.disableAnimationsOf(context),
        builder: (_) => _CodeBlockCard(
          language: widget.language,
          code: widget.code,
          fullScreen: true,
        ),
      ),
    );
  }

  Widget buildCodeText() {
    return Text(
      widget.code,
      key: widget.fullScreen ? const ValueKey('code-reader-text') : null,
      softWrap: widget.fullScreen && wrapLines,
      style: _kAssistantCodeStyle.copyWith(
        color: AppPalette.of(context).ink,
        fontSize: widget.fullScreen ? fontSize : null,
      ),
    );
  }

  Widget buildFullScreen() {
    final palette = AppPalette.of(context);
    return Scaffold(
      key: const ValueKey('code-reader-page'),
      backgroundColor: palette.paper,
      appBar: AppBar(
        backgroundColor: palette.paper,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          key: const ValueKey('code-reader-back'),
          tooltip: '返回对话',
          onPressed: () => Navigator.pop(context),
          icon: const SmartIcon(LucideIcons.arrowLeft),
        ),
        title: Text(
          widget.language ?? '代码',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('code-reader-wrap'),
            tooltip: '自动换行',
            isSelected: wrapLines,
            onPressed: () => setState(() => wrapLines = !wrapLines),
            icon: const SmartIcon(LucideIcons.arrowLeftRight),
            selectedIcon: const SmartIcon(LucideIcons.wrapText),
            style: IconButton.styleFrom(
              backgroundColor: wrapLines ? palette.accentSoft : null,
              foregroundColor: palette.ink,
            ),
          ),
          PopupMenuButton<double>(
            key: const ValueKey('code-reader-font-size'),
            tooltip: '代码字号',
            icon: const SmartIcon(LucideIcons.type),
            onSelected: (value) => setState(() => fontSize = value),
            itemBuilder: (_) => [
              for (final size in <double>{
                12,
                _kAssistantCodeStyle.fontSize!,
                16,
                18,
              }.toList()..sort())
                CheckedPopupMenuItem<double>(
                  key: ValueKey('code-reader-font-${size.toInt()}'),
                  value: size,
                  checked: fontSize == size,
                  child: Text('${size.toInt()} pt'),
                ),
            ],
          ),
          IconButton(
            key: const ValueKey('code-reader-copy'),
            tooltip: copied ? '已复制' : '复制代码',
            onPressed: copyCode,
            icon: SmartIcon(copied ? LucideIcons.check : LucideIcons.copy),
          ),
        ],
      ),
      body: SafeArea(
        child: SelectionArea(
          child: LayoutBuilder(
            builder: (context, constraints) => Scrollbar(
              controller: verticalController,
              child: SingleChildScrollView(
                key: const ValueKey('code-reader-vertical-scroll'),
                controller: verticalController,
                padding: const EdgeInsets.all(16),
                child: wrapLines
                    ? SizedBox(
                        width: constraints.maxWidth - 32,
                        child: buildCodeText(),
                      )
                    : Scrollbar(
                        controller: horizontalController,
                        notificationPredicate: (notification) =>
                            notification.depth == 0,
                        child: SingleChildScrollView(
                          key: const ValueKey('code-reader-horizontal-scroll'),
                          controller: horizontalController,
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: constraints.maxWidth - 32,
                            ),
                            child: buildCodeText(),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> copyCode() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => copied = true);
    copiedResetTimer?.cancel();
    copiedResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fullScreen) return buildFullScreen();
    return Container(
      key: const ValueKey('code-block-card'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppPalette.of(context).control,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: AppPalette.of(context).line, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: AppPalette.of(context).surface,
            padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
            child: SelectionContainer.disabled(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.language ?? '代码',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppPalette.of(context).muted,
                        fontFamily: AppTypography.codeFontFamily,
                        fontFamilyFallback:
                            AppTypography.codeFontFamilyFallback,
                      ),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: copied
                        ? Text(
                            '已复制',
                            key: ValueKey('code-copied-label'),
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.of(context).success,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  IconButton(
                    key: const ValueKey('code-expand-button'),
                    tooltip: '全屏阅读代码',
                    onPressed: openFullScreen,
                    iconSize: 18,
                    color: AppPalette.of(context).muted,
                    icon: const SmartIcon(LucideIcons.maximize2),
                  ),
                  IconButton(
                    key: const ValueKey('code-copy-button'),
                    tooltip: '复制代码',
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    color: copied
                        ? AppPalette.of(context).success
                        : AppPalette.of(context).muted,
                    onPressed: copyCode,
                    icon: SmartIcon(
                      copied ? LucideIcons.check : LucideIcons.copy,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: buildCodeText(),
          ),
        ],
      ),
    );
  }
}

const TextStyle _kUserBubbleStyle = TextStyle(
  fontFamily: AppTypography.fontFamily,
  fontFamilyFallback: AppTypography.fontFamilyFallback,
  height: AppTypography.userBodyHeight,
  fontSize: AppTypography.userBodySize,
  fontWeight: FontWeight.w400,
);

bool assistantTextLooksPlain(String text) {
  // Fast path: skip Markdown parser for plain replies (majority of short turns).
  return !text.contains('*') &&
      !text.contains('`') &&
      !text.contains('#') &&
      !text.contains('[') &&
      !text.contains('|') &&
      !text.contains('>') &&
      !text.contains('- ') &&
      !text.contains('1.') &&
      !text.contains('http');
}

Uri? searchSourceUri(String? href) {
  final uri = href == null ? null : Uri.tryParse(href);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

class MarkdownSourceLink {
  const MarkdownSourceLink({required this.uri, required this.label});

  final Uri uri;
  final String label;
}

List<MarkdownSourceLink> extractMarkdownSourceLinks(String data) {
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final sources = <Uri, MarkdownSourceLink>{};

  void visit(md.Node node) {
    if (node is! md.Element ||
        node.tag == 'pre' ||
        node.tag == 'code' ||
        node.tag == 'img') {
      return;
    }
    if (node.tag == 'a') {
      final uri = searchSourceUri(node.attributes['href']);
      final label = node.textContent.trim();
      if (uri != null && label.isNotEmpty) {
        sources.putIfAbsent(
          uri,
          () => MarkdownSourceLink(uri: uri, label: label),
        );
      }
      return;
    }
    for (final child in node.children ?? const <md.Node>[]) {
      visit(child);
    }
  }

  for (final node in document.parseLines(const LineSplitter().convert(data))) {
    visit(node);
  }
  return List.unmodifiable(sources.values);
}

Future<void> openSearchSource(BuildContext context, String? href) async {
  final uri = searchSourceUri(href);
  if (uri == null) return;

  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('无法打开来源链接')));
  }
}

/// Timeline furniture: a centered muted line between hairlines, so host and
/// system notices read as events between turns rather than turn content.
class _SystemNotice extends StatelessWidget {
  const _SystemNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 1,
              child: ColoredBox(color: AppPalette.of(context).line),
            ),
          ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: SelectableText(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AppPalette.of(context).muted,
                ),
              ),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 1,
              child: ColoredBox(color: AppPalette.of(context).line),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _copyAssistantReply(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  await HapticFeedback.selectionClick();
}

class AssistantSelectionArea extends StatelessWidget {
  const AssistantSelectionArea({
    super.key,
    required this.text,
    required this.child,
  });

  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      contextMenuBuilder: (context, state) {
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: [
            ContextMenuButtonItem(
              label: '复制全部',
              onPressed: () {
                ContextMenuController.removeAny();
                unawaited(_copyAssistantReply(text));
              },
            ),
            ...state.contextMenuButtonItems,
          ],
        );
      },
      child: child,
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
    this.searchHighlighted = false,
    this.isStreaming = false,
  });

  final TranscriptMessage message;
  final SavedSession? session;
  final String? activeSessionId;
  final DateTime? runStartedAt;
  final bool searchHighlighted;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    if (message.role == MessageRole.system) {
      return _SystemNotice(text: message.text);
    }

    if (message.role == MessageRole.activity) {
      return ActivityBlock(message: message, runStartedAt: runStartedAt);
    }

    final isUser = message.role == MessageRole.user;
    if (!isUser) {
      final text = normalizeAssistantCitations(
        message.text,
        isStreaming: isStreaming,
      );
      if (text.trim().isEmpty) {
        return const SizedBox.shrink();
      }
      // Defer parsing a growing Markdown reply until its turn is complete.
      final Widget assistantBody;
      if (isStreaming) {
        assistantBody = Text(text, style: _kAssistantPlainStyle);
      } else if (assistantTextLooksPlain(text)) {
        assistantBody = WorkspacePathText(text, style: _kAssistantPlainStyle);
      } else {
        assistantBody = _CachedMarkdownBody(data: text);
      }
      return Semantics(
        container: true,
        label: '助手回复',
        child: AssistantBubbleFrame(
          bubbleKey: const ValueKey('assistant-message'),
          searchHighlighted: searchHighlighted,
          child: AssistantSelectionArea(text: text, child: assistantBody),
        ),
      );
    }

    final maxWidth = MediaQuery.sizeOf(context).width * 0.84;
    return Semantics(
      container: true,
      label: '你',
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: DecoratedBox(
            key: const ValueKey('user-message'),
            decoration: BoxDecoration(
              color: searchHighlighted
                  ? transcriptSearchHighlightFill(
                      AppPalette.of(context).userBubble,
                      accent: AppPalette.of(context).accent,
                    )
                  : AppPalette.of(context).userBubble,
              borderRadius: const BorderRadius.all(
                Radius.circular(AppRadii.bubble),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
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
                    const SizedBox(height: 8),
                  if (message.text.isNotEmpty)
                    Text(message.text, style: _kUserBubbleStyle),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Transcript rows rebuild on every stream flush and WebSocket event. Keeping
// the MarkdownBody instance identical across builds while the text is unchanged
// lets Flutter skip the whole markdown subtree; flutter_markdown still reparses
// through its own didUpdateWidget when data actually changes.
class _CachedMarkdownBody extends StatefulWidget {
  const _CachedMarkdownBody({required this.data});

  final String data;

  @override
  State<_CachedMarkdownBody> createState() => _CachedMarkdownBodyState();
}

class _CachedMarkdownBodyState extends State<_CachedMarkdownBody> {
  Widget? cached;
  String? sourcesData;
  List<MarkdownSourceLink> sources = const [];
  String? cachedWorkspaceDir;
  ValueChanged<String>? cachedOnOpenPath;

  @override
  void didUpdateWidget(covariant _CachedMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data) cached = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    cached = null;
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    final portal = WorkspacePortal.of(context);
    if (cachedWorkspaceDir != portal?.workspaceDir ||
        cachedOnOpenPath != portal?.onOpenPath) {
      cachedWorkspaceDir = portal?.workspaceDir;
      cachedOnOpenPath = portal?.onOpenPath;
      cached = null;
    }
    if (cached != null) return cached!;
    if (sourcesData != widget.data) {
      sources = extractMarkdownSourceLinks(widget.data);
      sourcesData = widget.data;
    }
    final preGate = _MarkdownPreGate();
    final pathBuilder = _WorkspacePathMarkdownBuilder(preGate);
    final markdown = MarkdownBody(
      data: widget.data,
      selectable: false, // Parent AssistantSelectionArea owns selection.
      softLineBreak: true,
      onTapLink: (_, href, _) => unawaited(openSearchSource(context, href)),
      styleSheet: assistantMarkdownStyleSheet(context),
      builders: <String, MarkdownElementBuilder>{
        'pre': _CodeBlockBuilder(preGate),
        'code': pathBuilder,
        'strong': pathBuilder,
        'em': pathBuilder,
        'del': pathBuilder,
      },
    );
    if (sources.isEmpty) return cached = markdown;
    return cached = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        markdown,
        const SizedBox(height: 12),
        _MarkdownSourcesBar(sources: sources),
      ],
    );
  }
}

class _MarkdownSourcesBar extends StatelessWidget {
  const _MarkdownSourcesBar({required this.sources});

  final List<MarkdownSourceLink> sources;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return SelectionContainer.disabled(
      child: Column(
        key: const ValueKey('markdown-sources-bar'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '链接来源 · ${sources.length}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: palette.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            key: const ValueKey('markdown-sources-scroll'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var index = 0; index < sources.length; index++)
                  Padding(
                    padding: EdgeInsets.only(
                      right: index == sources.length - 1 ? 0 : 8,
                    ),
                    child: Tooltip(
                      message:
                          sources[index].label == sources[index].uri.toString()
                          ? sources[index].uri.toString()
                          : '${sources[index].label}\n${sources[index].uri}',
                      child: OutlinedButton.icon(
                        key: ValueKey('markdown-source-$index'),
                        onPressed: () => unawaited(
                          openSearchSource(
                            context,
                            sources[index].uri.toString(),
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: palette.ink,
                          backgroundColor: palette.control,
                          side: BorderSide(color: palette.lineStrong),
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        icon: const SmartIcon(
                          LucideIcons.externalLink,
                          size: AppIconSizes.inline,
                        ),
                        label: Text(
                          '${index + 1} · ${sources[index].uri.host}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
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
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (frame == null && !wasSynchronouslyLoaded) return child;
              return DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(color: AppPalette.of(context).line),
                ),
                child: child,
              );
            },
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
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.of(context).porcelainMuted,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppPalette.of(context).bubbleOutline,
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppPalette.of(context).surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppPalette.of(context).bubbleOutline,
                width: 0.5,
              ),
            ),
            child: Icon(
              mimeType == 'application/pdf'
                  ? LucideIcons.fileText
                  : LucideIcons.file,
              size: AppIconSizes.control,
              color: AppPalette.of(context).ink,
            ),
          ),
          const SizedBox(width: 12),
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
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatAttachmentSize(size),
                  style: TextStyle(
                    color: AppPalette.of(context).muted,
                    fontSize: 12,
                  ),
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
    this.searchHighlighted = false,
  });

  final Widget child;
  final Key? bubbleKey;
  final bool compact;
  final bool searchHighlighted;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        key: bubbleKey,
        decoration: BoxDecoration(
          color: searchHighlighted
              ? transcriptSearchHighlightFill(
                  palette.paper,
                  accent: palette.accent,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.compact),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 6 : 10),
          child: SizedBox(width: double.infinity, child: child),
        ),
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
  String? codexModel,
  ClaudeEffortPreference effort = ClaudeEffortPreference.automatic,
  SessionEngine engine = SessionEngine.claude,
  CodexSandboxMode codexSandboxMode = CodexSandboxMode.dangerFullAccess,
}) {
  final attachments = attachmentIds.toList(growable: false);
  return {
    'type': 'prompt',
    'promptId': promptId,
    'text': text,
    if (attachments.isNotEmpty) 'attachmentIds': attachments,
    'engine': engine.wireName,
    if (engine == SessionEngine.claude)
      'permissionMode': permissionMode.wireName,
    if (engine == SessionEngine.codex) 'sandboxMode': codexSandboxMode.wireName,
    'sessionId': sessionId,
    if (engine == SessionEngine.claude && model.wireName != null)
      'model': model.wireName!,
    if (engine == SessionEngine.codex &&
        normalizeCodexModel(codexModel) != null)
      'model': normalizeCodexModel(codexModel)!,
    'effort': effort.wireName,
  };
}

final Random _promptIdRandom = Random.secure();

String createPromptId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final random = _promptIdRandom.nextInt(0x7fffffff).toRadixString(36);
  return '$timestamp-$random';
}

IconData activityToolIconData(String? toolName, {bool isSkill = false}) {
  return switch (toolName) {
    'Skill' => LucideIcons.sparkles,
    'Bash' => LucideIcons.terminal,
    'Read' || 'Write' || 'Edit' => LucideIcons.fileCode,
    'WebSearch' || 'WebFetch' => LucideIcons.globe,
    'Grep' || 'Glob' => LucideIcons.search,
    'Task' => LucideIcons.blocks,
    _ => (isSkill ? LucideIcons.sparkles : LucideIcons.wrench),
  };
}

Widget buildActivityIcon(TranscriptMessage activity, BuildContext context) {
  final state = activity.activityState;
  final tool = activity.activityTool;
  final isSkill =
      tool == 'Skill' ||
      activity.text.contains('Skill') ||
      activity.text.contains('技能');

  if (state == ActivityState.running) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: AppPalette.of(context).accentSoft,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: SizedBox.square(
          dimension: AppIconSizes.badge,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            value: MediaQuery.disableAnimationsOf(context) ? 0.65 : null,
            color: AppPalette.of(context).accent,
          ),
        ),
      ),
    );
  }

  if (state == ActivityState.error) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: AppPalette.of(context).danger.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          LucideIcons.circleAlert,
          size: AppIconSizes.badge,
          color: AppPalette.of(context).danger,
        ),
      ),
    );
  }

  if (state == ActivityState.stopped) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: AppPalette.of(context).control,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          LucideIcons.square,
          size: AppIconSizes.badge,
          color: AppPalette.of(context).muted,
        ),
      ),
    );
  }

  final iconData = activityToolIconData(tool, isSkill: isSkill);
  final badgeColor = AppPalette.of(context).control;
  final iconColor = AppPalette.of(context).muted;

  return Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
    child: Center(
      child: SmartIcon(
        iconData,
        size: AppIconSizes.badge,
        color: notoGlyphFor(iconData) == null ? iconColor : null,
      ),
    ),
  );
}

Widget buildActivityTitle(TranscriptMessage activity, BuildContext context) {
  final isError = activity.activityState == ActivityState.error;
  final isSkill =
      activity.activityTool == 'Skill' ||
      activity.text.contains('Skill') ||
      activity.text.contains('技能');
  final skillName = isSkill ? activity.activityDetail : null;

  final displayText = activity.text == '已调用 Skill'
      ? '已调用技能'
      : (activity.text == '正在调用 Skill' ? '正在调用技能' : activity.text);

  return Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Flexible(
        child: Text(
          displayText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isError
                ? AppPalette.of(context).danger
                : AppPalette.of(context).muted,
            fontSize: AppTypography.activityBodySize,
            fontWeight: FontWeight.w400,
            height: 1.35,
          ),
        ),
      ),
      if (skillName != null && skillName.trim().isNotEmpty) ...[
        const SizedBox(width: 6),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: AppPalette.of(context).accentSoft,
              borderRadius: BorderRadius.circular(AppRadii.compact),
              border: Border.all(
                color: AppPalette.of(context).accent.withValues(alpha: 0.25),
                width: 0.6,
              ),
            ),
            child: Text(
              skillName.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: AppTypography.codeFontFamily,
                fontFamilyFallback: AppTypography.codeFontFamilyFallback,
                fontWeight: FontWeight.w600,
                color: AppPalette.of(context).accentStrong,
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

class ActivityBlock extends StatelessWidget {
  const ActivityBlock({super.key, required this.message, this.runStartedAt});

  final TranscriptMessage message;
  final DateTime? runStartedAt;

  @override
  Widget build(BuildContext context) {
    if (message.activityKind == ActivityKind.thinking) {
      return Padding(
        key: const ValueKey('thinking-bubble'),
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
        child: ThinkingHistoryBlock(
          message: message,
          initialElapsedSeconds: elapsedSecondsSince(runStartedAt),
        ),
      );
    }

    if (message.activityKind == ActivityKind.tool) {
      return ActivityTimelineCard(activities: [message]);
    }

    final railTone = switch (message.activityState) {
      ActivityState.running => AppPalette.of(context).accent,
      ActivityState.done => AppPalette.of(context).inactive,
      ActivityState.error => AppPalette.of(context).danger,
      ActivityState.stopped => AppPalette.of(context).muted,
      null => AppPalette.of(context).muted,
    };

    final detail = message.activityDetail;
    final title = buildActivityTitle(message, context);
    final icon = buildActivityIcon(message, context);

    if (message.activityKind == ActivityKind.summary) {
      return TaskRailFrame(
        color: railTone,
        active: message.activityState == ActivityState.running,
        child: Material(
          color: AppPalette.of(context).glassControl,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control + 2),
            side: BorderSide(color: AppPalette.of(context).line, width: 0.8),
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
                        WorkspacePathText(
                          detail,
                          style: TextStyle(
                            color: AppPalette.of(context).muted,
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
          color: AppPalette.of(context).glassControl,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control + 2),
            side: BorderSide(color: AppPalette.of(context).line, width: 0.8),
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
              style: TextStyle(
                color: AppPalette.of(context).muted,
                fontSize: 12,
              ),
            ),
            shape: const Border(),
            collapsedShape: const Border(),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.of(context).control,
                    borderRadius: BorderRadius.circular(AppRadii.compact),
                    border: Border.all(
                      color: AppPalette.of(context).line,
                      width: 0.6,
                    ),
                  ),
                  child: WorkspacePathText(
                    detail,
                    style: TextStyle(
                      color: AppPalette.of(context).ink,
                      fontFamily: AppTypography.codeFontFamily,
                      fontFamilyFallback: AppTypography.codeFontFamilyFallback,
                      fontSize: 11.5,
                      height: 1.45,
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

class ActivityTimelineCard extends StatefulWidget {
  const ActivityTimelineCard({
    super.key,
    required this.activities,
    this.running,
    this.thinking = false,
    this.expanded,
    this.onExpandedChanged,
    this.revealActivityId,
    this.contentBuilder,
  });

  final List<TranscriptMessage> activities;
  final bool? running;
  final bool thinking;
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;
  final String? revealActivityId;
  final Widget Function(BuildContext, Widget Function(TranscriptMessage))?
  contentBuilder;

  @override
  State<ActivityTimelineCard> createState() => _ActivityTimelineCardState();
}

String activityToolTitle(TranscriptMessage activity) {
  return switch (activity.activityTool) {
    'Read' => '读取文件',
    'Write' => '写入文件',
    'Edit' => '编辑文件',
    'Grep' => '搜索代码',
    'Glob' => '查找文件',
    'Bash' => '运行命令',
    'WebSearch' => '搜索网页',
    'WebFetch' => '读取网页',
    'Task' => '委派任务',
    'Skill' =>
      (activity.activityDetail?.trim().isNotEmpty ?? false)
          ? '使用技能 · ${activity.activityDetail!.trim()}'
          : '使用技能',
    final tool? when tool.trim().isNotEmpty => tool.trim(),
    _ => activity.text,
  };
}

class _ActivityTimelineCardState extends State<ActivityTimelineCard> {
  bool expanded = true;
  late String displayedTitle;
  DateTime titleChangedAt = DateTime.now();
  Timer? titleTimer;

  String groupTitle(List<TranscriptMessage> activities) {
    if (widget.thinking && widget.running != false) return '思考中';
    if (widget.running != false) {
      for (final activity in activities.reversed) {
        if (activity.activityState == ActivityState.running) {
          return activityToolTitle(activity);
        }
      }
    }
    if (widget.running == true) return '正在使用工具';
    final titles = activities.map(activityToolTitle).toSet().toList();
    return switch (titles.length) {
      1 => titles.first,
      2 => '${titles[0]}与${titles[1]}',
      _ => '工具操作',
    };
  }

  @override
  void initState() {
    super.initState();
    displayedTitle = groupTitle(widget.activities);
  }

  @override
  void didUpdateWidget(covariant ActivityTimelineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedGroup =
        oldWidget.activities.isNotEmpty &&
        widget.activities.isNotEmpty &&
        oldWidget.activities.first.activityId !=
            widget.activities.first.activityId;
    if (changedGroup) expanded = true;
    titleTimer?.cancel();
    titleTimer = null;
    final nextTitle = groupTitle(widget.activities);
    if (nextTitle != displayedTitle) {
      final running =
          widget.running ??
          widget.activities.any(
            (activity) => activity.activityState == ActivityState.running,
          );
      final urgent = widget.activities.any(
        (activity) =>
            activity.activityState == ActivityState.error ||
            activity.activityState == ActivityState.stopped,
      );
      final remaining =
          1200 - DateTime.now().difference(titleChangedAt).inMilliseconds;
      if (running && !urgent && !changedGroup && remaining > 0) {
        titleTimer = Timer(Duration(milliseconds: remaining), () {
          if (!mounted) return;
          setState(() {
            displayedTitle = nextTitle;
            titleChangedAt = DateTime.now();
            titleTimer = null;
          });
        });
      } else {
        displayedTitle = nextTitle;
        titleChangedAt = DateTime.now();
      }
    }
  }

  @override
  void dispose() {
    titleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activities = widget.activities;
    if (activities.isEmpty) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    final running =
        widget.running ??
        activities.any(
          (activity) => activity.activityState == ActivityState.running,
        );
    final isExpanded = widget.expanded ?? expanded;
    final failedCount = activities
        .where((activity) => activity.activityState == ActivityState.error)
        .length;
    final stoppedCount = activities
        .where((activity) => activity.activityState == ActivityState.stopped)
        .length;
    final status = failedCount > 0
        ? '$failedCount 个失败'
        : stoppedCount > 0
        ? '$stoppedCount 个已停止'
        : null;
    final tone = failedCount > 0
        ? palette.danger
        : stoppedCount > 0
        ? palette.warning
        : null;
    Widget buildToolRow(TranscriptMessage activity) => ToolActivityDetail(
      key: ValueKey('tool-inline-${activity.activityId}'),
      activity: activity,
      title: activityToolTitle(activity),
      titleWidget: buildActivityTitle(activity, context),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SmartIcon(
            activityToolIconData(activity.activityTool),
            size: AppIconSizes.inline,
          ),
          if (activity.activityState != ActivityState.done) ...[
            const SizedBox(width: 4),
            buildActivityIcon(activity, context),
          ],
        ],
      ),
      reveal:
          activity.activityId == widget.revealActivityId &&
          widget.revealActivityId != null,
      running: running && activity.activityState == ActivityState.running,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ActivityDisclosure(
            expanded: isExpanded,
            title: displayedTitle,
            leading: const SmartIcon(
              LucideIcons.wrench,
              size: AppIconSizes.inline,
            ),
            running: running,
            statusText: status,
            tone: tone,
            toggleKey: const ValueKey('activity-process-toggle'),
            semanticLabel:
                '$displayedTitle，${activities.length} 次操作'
                '${status == null ? '' : '，$status'}',
            onToggle: () {
              final next = !isExpanded;
              setState(() => expanded = next);
              widget.onExpandedChanged?.call(next);
            },
            child:
                widget.contentBuilder?.call(context, buildToolRow) ??
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final activity in activities) buildToolRow(activity),
                  ],
                ),
          ),
          if (running && !isExpanded)
            for (final activity in activities.skip(
              max(0, activities.length - 2),
            ))
              buildToolRow(activity),
        ],
      ),
    );
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
    this.commandsLoading = false,
    this.commandsFailed = false,
    this.onRefreshCommands,
    required this.running,
    this.stopping = false,
    this.uploading = false,
    required this.connected,
    required this.offline,
    required this.permissionMode,
    required this.allowBypassPermissions,
    this.modelName,
    this.contextWindow,
    this.remainingContext,
    this.engine = SessionEngine.claude,
    this.codexSandboxMode = CodexSandboxMode.dangerFullAccess,
    this.codexSandboxModes = CodexSandboxMode.supportedModes,
    this.selectedModel = ClaudeModelPreference.followComputer,
    this.selectedCodexModel,
    this.selectedEffort = ClaudeEffortPreference.automatic,
    this.presentation,
    this.suggestionMaxHeight = 292,
    required this.onPermissionModeSelected,
    this.onCodexSandboxModeSelected,
    required this.onCommandSelected,
    this.onAddAttachment,
    this.onRemoveAttachment,
    this.onModelPressed,
    this.onEffortSelected,
    required this.onReconnect,
    required this.onSend,
    required this.onStop,

    this.queuedPreview,
    this.onCancelQueue,
  });

  final TextEditingController controller;
  final List<AttachmentDraft> attachments;
  final List<String> commands;
  final bool commandsLoading;
  final bool commandsFailed;
  final VoidCallback? onRefreshCommands;
  final bool running;
  final bool stopping;
  final bool uploading;
  final bool connected;
  final bool offline;
  final PermissionMode permissionMode;
  final bool allowBypassPermissions;
  final String? modelName;
  final int? contextWindow;
  final int? remainingContext;
  final SessionEngine engine;
  final CodexSandboxMode codexSandboxMode;
  final List<CodexSandboxMode> codexSandboxModes;
  final ClaudeModelPreference selectedModel;
  final String? selectedCodexModel;
  final ClaudeEffortPreference selectedEffort;
  final ConsolePresentation? presentation;
  final double suggestionMaxHeight;
  final ValueChanged<PermissionMode> onPermissionModeSelected;
  final ValueChanged<CodexSandboxMode>? onCodexSandboxModeSelected;
  final ValueChanged<String> onCommandSelected;
  final VoidCallback? onAddAttachment;
  final ValueChanged<AttachmentDraft>? onRemoveAttachment;
  final VoidCallback? onModelPressed;
  final ValueChanged<ClaudeEffortPreference>? onEffortSelected;
  final VoidCallback onReconnect;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String? queuedPreview;
  final VoidCallback? onCancelQueue;

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final composerRadius = BorderRadius.vertical(
      top: const Radius.circular(AppRadii.composerFloat),
      bottom: Radius.circular(keyboardVisible ? 0 : AppRadii.composerFloat),
    );
    final composerElevated = !keyboardVisible;
    final console =
        presentation ??
        ConsolePresentation.resolve(
          connected: connected,
          offline: offline,
          running: running,
          stopping: stopping,
          uploading: uploading,
          engine: engine,
        );
    if (console.showsReconnect) {
      return Semantics(
        button: true,
        label: '重新连接电脑',
        child: SignalLiquidGlass(
          key: const ValueKey('composer'),
          blurSigma: 8,
          decoration: AppLiquidGlass.strong(
            context: context,
            borderRadius: composerRadius,
            elevated: composerElevated,
            backdrop: true,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onReconnect,
              borderRadius: composerRadius,
              child: Ink(
                width: double.infinity,
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Container(
                      width: AppSizes.iconControl,
                      height: AppSizes.iconControl,
                      decoration: BoxDecoration(
                        color: AppPalette.of(context).glassControl,
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        LucideIcons.refreshCw,
                        size: AppIconSizes.control,
                        color: AppPalette.of(context).ink,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '重新连接',
                        style: TextStyle(
                          color: AppPalette.of(context).ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      LucideIcons.chevronRight,
                      size: AppIconSizes.control,
                      color: AppPalette.of(context).muted,
                    ),
                  ],
                ),
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
        ).clamp(minScaleFactor: 0.85, maxScaleFactor: 2.0),
      ),
      child: Focus(
        canRequestFocus: false,
        includeSemantics: false,
        child: Builder(
          builder: (context) {
            final composerFocused = Focus.of(context).hasFocus;
            final reduceMotion = MediaQuery.disableAnimationsOf(context);
            final waiting =
                console.phase == ConsolePhase.uploading ||
                console.phase == ConsolePhase.stopping;
            final stoppingAction = console.showsStop && !waiting;
            final primaryTooltip = waiting
                ? console.phase == ConsolePhase.uploading
                      ? '正在上传附件'
                      : '等待主机确认停止'
                : stoppingAction
                ? console.stopTooltip
                : '发送';
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final query = commandQuery(value.text);
                    if (query == null ||
                        !console.canDraft ||
                        queuedPreview != null) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: CommandSuggestions(
                        commands: filterCommands(commands, query),
                        loading: commandsLoading,
                        failed: commandsFailed,
                        onRefresh: onRefreshCommands,
                        maxHeight: suggestionMaxHeight,
                        onSelected: onCommandSelected,
                      ),
                    );
                  },
                ),
                SignalLiquidGlass(
                  key: const ValueKey('composer'),
                  blurSigma: 8,
                  decoration: AppLiquidGlass.strong(
                    context: context,
                    borderRadius: composerRadius,
                    focused: composerFocused,
                    elevated: composerElevated,
                    backdrop: true,
                  ),
                  child: Container(
                    constraints: const BoxConstraints(
                      minHeight: AppSizes.composer,
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
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
                        if (queuedPreview != null) ...[
                          _QueuedPromptChip(
                            preview: queuedPreview!,
                            onCancel: onCancelQueue,
                          ),
                          const SizedBox(height: 8),
                        ],
                        TextField(
                          controller: controller,
                          enabled: console.canDraft && queuedPreview == null,

                          onTapOutside: (_) =>
                              FocusManager.instance.primaryFocus?.unfocus(),
                          cursorColor: AppPalette.of(context).accent,
                          style: TextStyle(
                            color: AppPalette.of(context).ink,
                            fontSize: 15,
                            height: 1.45,
                            fontWeight: FontWeight.w400,
                          ),
                          minLines: 1,
                          maxLines: 3,
                          decoration: InputDecoration(
                            filled: false,
                            hintText: console.inputHint,
                            hintStyle: TextStyle(
                              color: AppPalette.of(context).muted,
                              fontSize: 14,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.fromLTRB(
                              2,
                              0,
                              2,
                              10,
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: DecoratedBox(
                                  key: const ValueKey('composer-control-rail'),
                                  decoration: BoxDecoration(
                                    color: Colors.transparent,
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.pill,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _ComposerIconButton(
                                        key: const ValueKey(
                                          'composer-expand-button',
                                        ),
                                        tooltip: '添加附件',
                                        icon: LucideIcons.plus,
                                        onPressed:
                                            console.canDraft &&
                                                queuedPreview == null
                                            ? onAddAttachment
                                            : null,
                                      ),
                                      _ComposerEffortButton(
                                        effort: selectedEffort,
                                        enabled:
                                            console.canCompose &&
                                            onEffortSelected != null,
                                        onPressed: () => showEffortGaugeOverlay(
                                          context,
                                          selected: selectedEffort,
                                          onSelected: onEffortSelected!,
                                        ),
                                      ),
                                      Flexible(
                                        child: _ComposerModelButton(
                                          engine: engine,
                                          modelName: modelName,
                                          selectedModel: selectedModel,
                                          selectedCodexModel:
                                              selectedCodexModel,
                                          onPressed: onModelPressed,
                                        ),
                                      ),
                                      if (engine == SessionEngine.codex)
                                        _ComposerPermissionButton(
                                          sandboxMode: codexSandboxMode,
                                          enabled:
                                              console.canCompose &&
                                              onCodexSandboxModeSelected !=
                                                  null,
                                          onPressed: () =>
                                              showCodexSandboxModePicker(
                                                context,
                                                selected: codexSandboxMode,
                                                modes: codexSandboxModes,
                                                onSelected:
                                                    onCodexSandboxModeSelected!,
                                              ),
                                        )
                                      else
                                        _ComposerPermissionButton(
                                          mode: permissionMode,
                                          enabled: console.canCompose,
                                          onPressed: () =>
                                              showPermissionModePicker(
                                                context,
                                                selected: permissionMode,
                                                allowBypassPermissions:
                                                    allowBypassPermissions,
                                                onSelected:
                                                    onPermissionModeSelected,
                                              ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            ValueListenableBuilder<TextEditingValue>(
                              valueListenable: controller,
                              builder: (context, value, _) {
                                final hasContent =
                                    value.text.trim().isNotEmpty ||
                                    attachments.isNotEmpty;
                                final canSend =
                                    hasContent && console.canCompose;
                                final canQueueSend =
                                    hasContent &&
                                    console.canQueue &&
                                    queuedPreview == null;
                                final isStoppingActive =
                                    stoppingAction && console.canStop;
                                final primaryAction = waiting
                                    ? null
                                    : stoppingAction
                                    ? (console.canStop ? onStop : null)
                                    : (canSend ? onSend : null);

                                final primaryColor = waiting
                                    ? AppPalette.of(
                                        context,
                                      ).composerDisabledFill
                                    : stoppingAction
                                    ? (console.canStop
                                          ? AppPalette.of(context).stop
                                          : AppPalette.of(
                                              context,
                                            ).composerDisabledFill)
                                    : (canSend
                                          ? AppPalette.of(context).cta
                                          : AppPalette.of(context).control);
                                final primaryIcon = waiting
                                    ? SizedBox.square(
                                        key: const ValueKey(
                                          'composer-primary-waiting',
                                        ),
                                        dimension: 20,
                                        child: reduceMotion
                                            ? Icon(
                                                LucideIcons.loader,
                                                size: AppIconSizes.control,
                                                color: AppPalette.of(
                                                  context,
                                                ).accentStrong,
                                              )
                                            : CircularProgressIndicator(
                                                strokeWidth: 2.2,
                                                color: AppPalette.of(
                                                  context,
                                                ).accentStrong,
                                              ),
                                      )
                                    : Icon(
                                        stoppingAction
                                            ? PhosphorIconsFill.square
                                            : LucideIcons.arrowUp,
                                        key: ValueKey(
                                          stoppingAction
                                              ? 'composer-primary-stop'
                                              : 'composer-primary-send',
                                        ),
                                        size: stoppingAction ? 14 : 20,
                                        color: stoppingAction
                                            ? console.canStop
                                                  ? AppPalette.of(
                                                      context,
                                                    ).onStop
                                                  : AppPalette.of(
                                                      context,
                                                    ).inactive
                                            : canSend
                                            ? AppPalette.of(context).onCta
                                            : AppPalette.of(context).inactive,
                                      );
                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (remainingContext != null &&
                                        !canQueueSend) ...[
                                      _ComposerContextIndicator(
                                        contextWindow: contextWindow,
                                        remainingContext: remainingContext!,
                                      ),
                                      const SizedBox(width: AppSpacing.xs),
                                    ],
                                    if (canQueueSend) ...[
                                      SignalPressEffect(
                                        child: SizedBox.square(
                                          dimension: AppSizes.touchTarget,
                                          child: IconButton(
                                            key: const ValueKey(
                                              'composer-queue-action',
                                            ),
                                            onPressed: onSend,
                                            tooltip: '排队发送',
                                            padding: EdgeInsets.zero,
                                            icon: Container(
                                              width: 40,
                                              height: 40,
                                              decoration: BoxDecoration(
                                                color: AppPalette.of(
                                                  context,
                                                ).accentStrong,
                                                shape: BoxShape.circle,
                                              ),
                                              alignment: Alignment.center,
                                              child: Icon(
                                                LucideIcons.listPlus,
                                                size: AppIconSizes.control,
                                                color: AppPalette.of(
                                                  context,
                                                ).onCta,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.xs),
                                    ],
                                    SignalPressEffect(
                                      key: const ValueKey(
                                        'composer-primary-press',
                                      ),
                                      enabled: primaryAction != null,

                                      child: SizedBox.square(
                                        dimension: AppSizes.touchTarget,
                                        child: IconButton(
                                          key: const ValueKey(
                                            'composer-primary-action',
                                          ),
                                          onPressed: primaryAction,
                                          tooltip: primaryTooltip,
                                          padding: EdgeInsets.zero,
                                          icon: Container(
                                            key: const ValueKey(
                                              'composer-primary-visual',
                                            ),
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: primaryColor,
                                              shape: BoxShape.circle,
                                              border: isStoppingActive
                                                  ? Border.all(
                                                      color:
                                                          AppPalette.of(
                                                            context,
                                                          ).onStop.withValues(
                                                            alpha: 0.28,
                                                          ),
                                                      width: 0.8,
                                                    )
                                                  : null,
                                              boxShadow: isStoppingActive
                                                  ? AppElevation.stopControl(
                                                      context: context,
                                                    )
                                                  : (!waiting &&
                                                            !stoppingAction &&
                                                            canSend
                                                        ? AppElevation.surfaceCard(
                                                            context: context,
                                                          )
                                                        : null),
                                            ),
                                            alignment: Alignment.center,
                                            child: AnimatedSwitcher(
                                              key: const ValueKey(
                                                'composer-primary-icon-switcher',
                                              ),
                                              duration: reduceMotion
                                                  ? Duration.zero
                                                  : AppMotion.fast,
                                              reverseDuration: reduceMotion
                                                  ? Duration.zero
                                                  : AppMotion.fast,
                                              switchInCurve: const Cubic(
                                                0.2,
                                                0,
                                                0,
                                                1,
                                              ),
                                              switchOutCurve: const Cubic(
                                                0.2,
                                                0,
                                                0,
                                                1,
                                              ),
                                              transitionBuilder:
                                                  (
                                                    child,
                                                    animation,
                                                  ) => AnimatedBuilder(
                                                    animation: animation,
                                                    child: child,
                                                    builder: (context, child) {
                                                      final progress =
                                                          animation.value;
                                                      return Opacity(
                                                        opacity: progress,
                                                        child: Transform.scale(
                                                          scale:
                                                              0.25 +
                                                              progress * 0.75,
                                                          child: ImageFiltered(
                                                            imageFilter:
                                                                ui.ImageFilter.blur(
                                                                  sigmaX:
                                                                      4 *
                                                                      (1 -
                                                                          progress),
                                                                  sigmaY:
                                                                      4 *
                                                                      (1 -
                                                                          progress),
                                                                ),
                                                            child: child,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                              child: primaryIcon,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QueuedPromptChip extends StatelessWidget {
  const _QueuedPromptChip({required this.preview, this.onCancel});

  final String preview;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const ValueKey('composer-queued-chip'),
      decoration: BoxDecoration(
        color: AppPalette.of(context).composerControlFill,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(
              LucideIcons.listPlus,
              size: AppIconSizes.inline,
              color: AppPalette.of(context).accentStrong,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppPalette.of(context).ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('composer-queued-cancel'),
              tooltip: '取消排队',
              onPressed: onCancel,
              visualDensity: VisualDensity.compact,
              icon: const SmartIcon(LucideIcons.x, size: AppIconSizes.inline),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerGlassIconButton extends StatelessWidget {
  const _ComposerGlassIconButton({
    this.buttonKey,
    this.visualKey,
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.filled = false,
  });

  final Key? buttonKey;
  final Key? visualKey;
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: AppSizes.touchTarget,
      child: SignalPressEffect(
        enabled: onPressed != null,
        builder: (context, pressed, child) => IconButton(
          key: buttonKey,
          onPressed: onPressed,
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          icon: SignalAnimatedSurface(
            key: visualKey,
            duration: appPressAnimationDuration(context, pressed),
            decoration: BoxDecoration(
              color: pressed
                  ? AppPalette.of(context).composerControlPressed
                  : filled
                  ? AppPalette.of(context).glassControl
                  : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(
              dimension: filled ? 38 : AppSizes.iconControl,
              child: Center(child: child),
            ),
          ),
        ),
        child: child,
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
    return _ComposerGlassIconButton(
      filled: true,
      visualKey: const ValueKey('composer-expand-visual'),
      tooltip: tooltip,
      onPressed: onPressed,
      child: Icon(
        icon,
        size: AppIconSizes.control,
        color: enabled
            ? AppPalette.of(context).composerControlInk
            : AppPalette.of(context).inactive,
      ),
    );
  }
}

class _ComposerEffortButton extends StatelessWidget {
  const _ComposerEffortButton({
    required this.effort,
    required this.enabled,
    required this.onPressed,
  });

  final ClaudeEffortPreference effort;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _ComposerGlassIconButton(
      buttonKey: const ValueKey('composer-effort-button'),
      tooltip: '思考强度：${effort.label}',
      onPressed: enabled ? onPressed : null,
      child: EffortGaugeIcon(
        key: const ValueKey('composer-effort-visual'),
        effort: effort,
        enabled: enabled,
      ),
    );
  }
}

class _ComposerModelButton extends StatelessWidget {
  const _ComposerModelButton({
    required this.engine,
    required this.modelName,
    required this.selectedModel,
    this.selectedCodexModel,
    this.onPressed,
  });

  final SessionEngine engine;
  final String? modelName;
  final ClaudeModelPreference selectedModel;
  final String? selectedCodexModel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = engine == SessionEngine.codex
        ? selectedCodexModel != null
              ? formatModelName(selectedCodexModel!)
              : modelName == null
              ? '模型'
              : formatModelName(modelName!)
        : selectedModel == ClaudeModelPreference.followComputer
        ? modelName == null
              ? '模型'
              : formatModelName(modelName!)
        : selectedModel.label;
    return _ComposerGlassIconButton(
      buttonKey: const ValueKey('composer-model-button'),
      visualKey: const ValueKey('composer-model-visual'),
      tooltip: '选择模型：$label',
      onPressed: onPressed,
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1,
        child: const SmartIcon(LucideIcons.brain, size: AppIconSizes.primary),
      ),
    );
  }
}

class _ComposerPermissionButton extends StatelessWidget {
  const _ComposerPermissionButton({
    this.mode,
    this.sandboxMode,
    required this.enabled,
    required this.onPressed,
  });

  final PermissionMode? mode;
  final CodexSandboxMode? sandboxMode;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final danger =
        mode == PermissionMode.bypassPermissions ||
        sandboxMode == CodexSandboxMode.dangerFullAccess;
    final icon = sandboxMode?.icon ?? mode?.icon ?? LucideIcons.shield;
    final label = sandboxMode?.label ?? mode?.label ?? '权限';
    final ink = !enabled
        ? AppPalette.of(context).inactive
        : danger
        ? AppPalette.of(context).stop
        : AppPalette.of(context).composerControlInk;
    return _ComposerGlassIconButton(
      buttonKey: const ValueKey('permission-mode-chip'),
      visualKey: const ValueKey('permission-mode-visual'),
      tooltip: '访问权限：$label',
      onPressed: enabled ? onPressed : null,
      child: Icon(icon, size: AppIconSizes.control, color: ink),
    );
  }
}

class _ComposerContextIndicator extends StatelessWidget {
  const _ComposerContextIndicator({
    required this.contextWindow,
    required this.remainingContext,
  });

  final int? contextWindow;
  final int remainingContext;

  @override
  Widget build(BuildContext context) {
    final hasWindow = contextWindow != null && contextWindow! > 0;
    final fraction = hasWindow
        ? (remainingContext / contextWindow!).clamp(0.0, 1.0)
        : null;
    final usedFraction = fraction == null ? 0.0 : 1 - fraction;
    final shortLabel = fraction == null
        ? _formatTokenCount(remainingContext)
        : '${(fraction * 100).round()}%';
    final fullLabel = hasWindow
        ? '上下文剩余 ${_formatTokenCount(remainingContext)} / ${_formatTokenCount(contextWindow!)}，$shortLabel'
        : '上下文剩余 ${_formatTokenCount(remainingContext)}';
    final lowRemaining = fraction != null && fraction <= 0.15;
    final readoutColor = lowRemaining
        ? AppPalette.of(context).warning
        : AppPalette.of(context).muted;
    return Tooltip(
      message: fullLabel,
      child: Semantics(
        label: fullLabel,
        child: ExcludeSemantics(
          child: SizedBox(
            key: const ValueKey('composer-context-indicator'),
            height: AppSizes.touchTarget,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    value: usedFraction,
                    strokeWidth: 2,
                    strokeCap: StrokeCap.round,
                    backgroundColor: AppPalette.of(context).line,
                    color: lowRemaining
                        ? AppPalette.of(context).warning
                        : AppPalette.of(context).inactive,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  shortLabel,
                  maxLines: 1,
                  style: TextStyle(
                    color: readoutColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
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

String _formatTokenCount(int tokens) {
  if (tokens >= 1000000) {
    final value = tokens / 1000000;
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)}M';
  }
  if (tokens >= 1000) return '${(tokens / 1000).round()}K';
  return '$tokens';
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
              color: AppPalette.of(context).porcelainMuted,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppPalette.of(context).bubbleOutline,
                width: 0.5,
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
                            color: AppPalette.of(context).surface,
                            child: Icon(
                              LucideIcons.file,
                              color: AppPalette.of(context).muted,
                              size: AppIconSizes.control,
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
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        uploading
                            ? '上传中'
                            : formatAttachmentSize(attachment.size),
                        style: TextStyle(
                          color: AppPalette.of(context).muted,
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
                    icon: const SmartIcon(
                      LucideIcons.x,
                      size: AppIconSizes.control,
                    ),
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
    PermissionMode.bypassPermissions => '当前对话跳过全部权限检查',
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

extension CodexSandboxModePresentation on CodexSandboxMode {
  IconData get icon => switch (this) {
    CodexSandboxMode.readOnly => LucideIcons.eye,
    CodexSandboxMode.workspaceWrite => LucideIcons.pencil,
    CodexSandboxMode.dangerFullAccess => LucideIcons.triangleAlert,
  };
}

Future<void> showPermissionModePicker(
  BuildContext context, {
  required PermissionMode selected,
  required bool allowBypassPermissions,
  required ValueChanged<PermissionMode> onSelected,
}) async {
  final mode = await showAppOptionPicker<PermissionMode>(
    context,
    scrollContent: false,
    builder: (sheetContext) => ConversationOptionSheet<PermissionMode>(
      title: 'Claude Code 权限模式',
      detail: '决定文件修改和命令执行是否需要确认。',
      selected: selected,
      options: [
        for (final item in PermissionMode.values)
          ConversationPickerOption(
            value: item,
            id: 'permission-mode-${item.wireName}',
            title: item.label,
            description:
                item == PermissionMode.bypassPermissions &&
                    !allowBypassPermissions
                ? '电脑端尚未允许跳过权限检查'
                : item.description,
            group: item == PermissionMode.bypassPermissions ? '跳过检查' : '执行方式',
            enabled:
                item != PermissionMode.bypassPermissions ||
                allowBypassPermissions,
            danger: item == PermissionMode.bypassPermissions,
            leading: item == PermissionMode.bypassPermissions
                ? Icon(item.icon)
                : SmartIcon(item.icon, size: AppIconSizes.control),
          ),
      ],
    ),
  );

  if (mode == null || !context.mounted) return;
  if (mode == PermissionMode.bypassPermissions) {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: appOverlayAnimationStyle(context),
      builder: (dialogContext) => AlertDialog(
        title: const Text('当前对话跳过权限检查'),
        content: const Text(
          'Claude Code 将能直接修改文件和执行命令。此设置仅作用于当前对话，切换或新建对话后不会沿用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.of(context).stop,
              foregroundColor: AppPalette.of(context).onStop,
            ),
            child: const Text('对当前对话开启'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  onSelected(mode);
}

Future<void> showCodexSandboxModePicker(
  BuildContext context, {
  required CodexSandboxMode selected,
  List<CodexSandboxMode> modes = CodexSandboxMode.supportedModes,
  required ValueChanged<CodexSandboxMode> onSelected,
}) async {
  final mode = await showAppOptionPicker<CodexSandboxMode>(
    context,
    scrollContent: false,
    builder: (sheetContext) => ConversationOptionSheet<CodexSandboxMode>(
      title: 'Codex 沙箱模式',
      detail: '所选模式在当前对话沿用。Codex 执行中不会弹出权限审批。',
      selected: selected,
      options: [
        for (final item in modes)
          ConversationPickerOption(
            value: item,
            id: 'codex-sandbox-${item.wireName}',
            title: item.label,
            description: item.description,
            group: item == CodexSandboxMode.dangerFullAccess
                ? '不限制访问'
                : '限制访问范围',
            danger: item == CodexSandboxMode.dangerFullAccess,
            leading: item == CodexSandboxMode.dangerFullAccess
                ? Icon(item.icon)
                : SmartIcon(item.icon, size: AppIconSizes.control),
          ),
      ],
    ),
  );

  if (mode == null || !context.mounted) return;
  if (mode == CodexSandboxMode.dangerFullAccess && mode != selected) {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: appOverlayAnimationStyle(context),
      builder: (dialogContext) => AlertDialog(
        title: const Text('当前对话使用完全访问'),
        content: const Text('Codex 将能访问工作区外的文件和命令。之后的消息沿用此模式，可随时在沙箱模式中切换。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.of(context).stop,
              foregroundColor: AppPalette.of(context).onStop,
            ),
            child: const Text('使用完全访问'),
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
    this.failed = false,
    this.onRefresh,
    this.maxHeight = 292,
    required this.onSelected,
  });

  final List<String> commands;
  final bool loading;
  final bool failed;
  final VoidCallback? onRefresh;
  final double maxHeight;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      key: const ValueKey('command-suggestions'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: palette.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onRefresh != null)
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        failed ? '指令获取失败，请刷新重试' : '电脑端指令',
                        style: TextStyle(
                          color: failed ? palette.danger : palette.muted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新指令',
                      onPressed: loading ? null : onRefresh,
                      icon: const SmartIcon(
                        LucideIcons.refreshCw,
                        size: AppIconSizes.control,
                      ),
                    ),
                  ],
                ),
              ),
            Flexible(
              child: loading
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: palette.accent,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '正在获取指令',
                            style: TextStyle(color: palette.muted),
                          ),
                        ],
                      ),
                    )
                  : commands.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Text(
                        failed ? '点击刷新重新获取电脑端指令' : '没有匹配的指令',
                        style: TextStyle(color: palette.muted),
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
                          leading: Text(
                            '/',
                            style: TextStyle(
                              color: palette.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          title: Text(command),
                          onTap: () => onSelected(command),
                        );
                      },
                    ),
            ),
          ],
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
        color: AppPalette.of(context).surfaceElevated,
        borderRadius: BorderRadius.circular(
          compact ? AppRadii.surface : AppRadii.header,
        ),
        border: Border.all(color: AppPalette.of(context).line),
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
                  color: AppPalette.of(context).surfaceElevated,
                  borderRadius: BorderRadius.circular(AppRadii.compact),
                  border: Border.all(color: AppPalette.of(context).line),
                ),
                child: Text(
                  '对准二维码',
                  style: TextStyle(
                    color: AppPalette.of(context).muted,
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: AppPalette.of(context).accent, width: 3),
            left: BorderSide(color: AppPalette.of(context).accent, width: 3),
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
      resizeToAvoidBottomInset: false,
      backgroundColor: AppPalette.of(context).paper,
      body: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            key: const ValueKey('chat-background-layer'),
            decoration: BoxDecoration(color: AppPalette.of(context).paper),
          ),
          _KeyboardResizeBody(child: BackdropGroup(child: child)),
        ],
      ),
    );
  }
}

class _KeyboardResizeBody extends StatelessWidget {
  const _KeyboardResizeBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomInset = media.viewInsets.bottom;
    final stableViewInsets = EdgeInsets.fromLTRB(
      media.viewInsets.left > 0 ? 1 : 0,
      media.viewInsets.top > 0 ? 1 : 0,
      media.viewInsets.right > 0 ? 1 : 0,
      bottomInset > 0 ? 1 : 0,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: MediaQuery(
        // Descendants only need keyboard visibility. Keeping the animated
        // height here would rebuild the full transcript on every IME frame.
        data: media.copyWith(viewInsets: stableViewInsets),
        child: child,
      ),
    );
  }
}

Future<T?> showAppOptionPicker<T>(
  BuildContext context, {
  bool requestFocus = true,
  bool scrollContent = true,
  required Widget Function(BuildContext sheetContext) builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    sheetAnimationStyle: appOverlayAnimationStyle(context),
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    enableDrag: false,
    requestFocus: requestFocus,
    builder: (sheetContext) {
      // Option rows plus the header can outgrow short screens; keep the
      // sheet within bounds and scroll instead of clipping trailing rows.
      final media = MediaQuery.of(sheetContext);
      final available = media.size.height - media.padding.vertical - 120;
      return appModalSheetScaffold(
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: available),
              child: AppSheetSurface(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: scrollContent
                    ? SingleChildScrollView(child: builder(sheetContext))
                    : builder(sheetContext),
              ),
            ),
          ),
        ),
        barrierColor: AppPalette.of(sheetContext).scrim,
        onBarrierTap: () => Navigator.pop(sheetContext),
      );
    },
  );
}

class AppSheetSurface extends StatelessWidget {
  const AppSheetSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = AppRadii.panel,
    this.borderRadius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final effectiveBorderRadius = borderRadius ?? BorderRadius.circular(radius);
    return Container(
      decoration: AppLiquidGlass.strong(
        context: context,
        borderRadius: effectiveBorderRadius,
      ),
      child: ClipRRect(
        borderRadius: effectiveBorderRadius,
        child: Padding(
          padding: padding,
          child: SizedBox(width: double.infinity, child: child),
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
          style: TextStyle(fontSize: 15, color: AppPalette.of(context).muted),
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
        Icon(icon, size: AppIconSizes.inline, color: color),
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
      scaleOnPress: false,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: AppPalette.of(context).accent,
          foregroundColor: AppPalette.of(context).onCta,
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
    final borderRadius = BorderRadius.circular(AppRadii.surface);
    return SignalPressEffect(
      builder: (context, pressed, child) => SignalAnimatedSurface(
        duration: appPressAnimationDuration(context, pressed),
        decoration: AppLiquidGlass.thin(
          context: context,
          borderRadius: borderRadius,
          pressed: pressed,
        ),
        child: child,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (icon != null)
                      Icon(
                        icon,
                        size: AppIconSizes.control,
                        color: AppPalette.of(context).accentStrong,
                      ),
                    const Spacer(),
                    Icon(
                      LucideIcons.arrowUpRight,
                      size: AppIconSizes.control,
                      color: AppPalette.of(context).inactive,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: AppPalette.of(context).ink,
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
                    style: TextStyle(
                      color: AppPalette.of(context).muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
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
    final base = TextStyle(
      color: AppPalette.of(context).muted,
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
    animationStyle: appOverlayAnimationStyle(context),
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
    animationStyle: appOverlayAnimationStyle(context),
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

bool isBlankAssistantMessage(TranscriptMessage message) {
  return message.role == MessageRole.assistant && message.text.trim().isEmpty;
}

bool hasAssistantReplyAfterLastUser(List<TranscriptMessage> messages) {
  final lastUser = messages.lastIndexWhere(
    (message) => message.role == MessageRole.user,
  );
  if (lastUser < 0) return true;
  return messages
      .skip(lastUser + 1)
      .any(
        (message) =>
            message.role == MessageRole.assistant &&
            message.text.trim().isNotEmpty,
      );
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
  final durationMs = activity.durationMs ?? existing?.activityDurationMs;

  final next = TranscriptMessage.activity(
    activityLabel(activity.kind, toolName, activity.state),
    id: activity.id,
    kind: activity.kind,
    state: activity.state,
    tool: toolName,
    detail: detail,
    durationMs: durationMs,
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
  finishRunningActivities(messages, ActivityState.done, start: start);
}

void finishRunningActivities(
  List<TranscriptMessage> messages,
  ActivityState state, {
  int start = 0,
  ActivityKind? kind,
  int? durationMs,
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
      durationMs: durationMs ?? message.activityDurationMs,
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
    'Skill' => '调用技能',
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
