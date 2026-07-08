import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const CcRemoteApp());
}

class CcRemoteApp extends StatelessWidget {
  const CcRemoteApp({
    super.key,
    this.enableCamera = true,
    this.demoMode = false,
  });

  final bool enableCamera;
  final bool demoMode;

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
      home: DemoShell(enableCamera: enableCamera, demoMode: demoMode),
    );
  }
}

class DemoShell extends StatefulWidget {
  const DemoShell({
    super.key,
    required this.enableCamera,
    required this.demoMode,
  });

  final bool enableCamera;
  final bool demoMode;

  @override
  State<DemoShell> createState() => _DemoShellState();
}

class _DemoShellState extends State<DemoShell> with WidgetsBindingObserver {
  static const networkTimeout = Duration(seconds: 12);

  ShellRoute route = ShellRoute.boot;
  bool running = false;
  bool pairing = false;
  bool handlingQr = false;
  bool wsReady = false;
  bool remoteOffline = false;
  String? pausedQrRaw;
  String? pairError;
  SavedSession? session;
  WebSocketChannel? ws;
  StreamSubscription<dynamic>? wsSubscription;
  final TokenStore tokenStore = TokenStore();
  final http.Client httpClient = http.Client();
  final TextEditingController promptController = TextEditingController();
  final List<TranscriptMessage> messages = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (state != AppLifecycleState.resumed) return;
    unawaited(refreshConnection());
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
      });
      connectWs(restored);
    } catch (err) {
      if (!mounted || session != current) return;
      closeWs();
      if (err is UnauthorizedSession) {
        await tokenStore.clear();
        if (!mounted || session != current) return;
        setState(() {
          session = null;
          route = ShellRoute.pair;
          pairError = '无法恢复连接，请重新扫码';
          remoteOffline = false;
          running = false;
        });
        return;
      }
      setState(() {
        remoteOffline = true;
        running = false;
      });
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
      setState(() => route = ShellRoute.pair);
      return;
    }

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
      });
      connectWs(restored);
    } catch (err) {
      if (!mounted) return;
      if (err is UnauthorizedSession) {
        await tokenStore.clear();
        if (!mounted) return;
        setState(() {
          pairError = '无法恢复连接，请重新扫码';
          route = ShellRoute.pair;
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
    }
  }

  void connectDemoDevice() {
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
      messages.clear();
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

    switch (decoded['type']) {
      case 'status':
        setState(() {
          wsReady = decoded['authenticated'] == true;
          remoteOffline = false;
          running = decoded['running'] == true;
        });
      case 'text':
        appendAssistantText(decoded['text'] as String? ?? '');
      case 'done':
        setState(() => running = false);
      case 'stopped':
        setState(() {
          running = false;
          messages.add(TranscriptMessage.system('已停止'));
        });
      case 'error':
        setState(() {
          running = false;
          messages.add(
            TranscriptMessage.system('错误：${decoded['message'] ?? '未知错误'}'),
          );
        });
    }
  }

  void handleWsClosed(String message) {
    if (!mounted || route != ShellRoute.chat) return;
    setState(() {
      wsReady = false;
      remoteOffline = true;
      if (running) {
        running = false;
        messages.add(TranscriptMessage.system(message));
      }
    });
  }

  void appendAssistantText(String text) {
    if (text.isEmpty) return;
    setState(() {
      if (messages.isNotEmpty && messages.last.role == MessageRole.assistant) {
        final last = messages.removeLast();
        messages.add(TranscriptMessage.assistant(last.text + text));
      } else {
        messages.add(TranscriptMessage.assistant(text));
      }
    });
  }

  void sendPrompt() {
    final text = promptController.text.trim();
    if (text.isEmpty || running) return;

    if (widget.demoMode) {
      setState(() {
        promptController.clear();
        running = false;
        messages
          ..add(TranscriptMessage.user(text))
          ..add(TranscriptMessage.assistant('演示模式：真实对话需要连接 daemon WebSocket。'));
      });
      return;
    }

    final channel = ws;
    final current = session;
    if (!wsReady || channel == null || current == null) {
      if (current != null) refreshConnection();
      setState(() {
        messages.add(
          TranscriptMessage.system(
            remoteOffline ? '电脑端离线，请先重连' : '正在连接电脑端，请稍后再试',
          ),
        );
      });
      return;
    }

    setState(() {
      promptController.clear();
      running = true;
      messages.add(TranscriptMessage.user(text));
    });
    channel.sink.add(jsonEncode({'type': 'prompt', 'text': text}));
  }

  void stopRun() {
    if (!running) return;

    if (widget.demoMode) {
      setState(() {
        running = false;
        messages.add(TranscriptMessage.system('已停止'));
      });
      return;
    }

    final channel = ws;
    if (channel == null || !wsReady) {
      setState(() {
        running = false;
        messages.add(TranscriptMessage.system('未连接，无法发送停止指令'));
      });
      return;
    }

    channel.sink.add(jsonEncode({'type': 'stop'}));
    setState(() => messages.add(TranscriptMessage.system('正在停止')));
  }

  void fillPrompt(String text) {
    promptController.text = text;
    promptController.selection = TextSelection.collapsed(offset: text.length);
    setState(() {});
  }

  void logoutDemoDevice() {
    closeWs();
    setState(() {
      session = null;
      route = ShellRoute.pair;
      running = false;
      wsReady = false;
      remoteOffline = false;
      pausedQrRaw = null;
      messages.clear();
      promptController.clear();
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
    logoutDemoDevice();
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
      if (!mounted) return;
      setState(() {
        session = saved;
        route = ShellRoute.chat;
        remoteOffline = false;
        pausedQrRaw = null;
        pairError = null;
        messages.clear();
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
            running: running,
            connected: wsReady,
            offline: remoteOffline,
            messages: messages,
            promptController: promptController,
            onChanged: () => setState(() {}),
            onFillPrompt: fillPrompt,
            onReconnect: refreshConnection,
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
        child: GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CC Remote',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                '正在检查本地配对信息',
                style: TextStyle(color: AppColors.muted, fontSize: 15),
              ),
              const SizedBox(height: 26),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: const LinearProgressIndicator(
                  minHeight: 4,
                  color: AppColors.accent,
                  backgroundColor: Color(0xFFE8F0F3),
                ),
              ),
            ],
          ),
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
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ScreenTitle(title: 'CC Remote', subtitle: '扫描电脑终端里的二维码'),
            const SizedBox(height: 26),
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
            const SizedBox(height: 18),
            GlassPanel(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pairing ? '正在连接电脑' : '等待配对二维码',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error ??
                        (canResetScan ? '已暂停扫描，点刷新可重新确认' : '扫到二维码后会先确认设备信息'),
                    style: TextStyle(
                      color: error == null ? AppColors.muted : AppColors.stop,
                    ),
                  ),
                  const SizedBox(height: 10),
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
                    const LinearProgressIndicator(
                      minHeight: 3,
                      color: AppColors.accent,
                      backgroundColor: Color(0xFFE8F3F6),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: ActionButton(
                          label: onDemoConnect == null ? '扫描中' : '连接这台电脑',
                          icon: onDemoConnect == null
                              ? Icons.qr_code_scanner_rounded
                              : Icons.link_rounded,
                          onPressed: onDemoConnect,
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filledTonal(
                        onPressed: canResetScan || error != null
                            ? onClearError
                            : null,
                        icon: const Icon(Icons.refresh_rounded),
                        tooltip: '重新扫描',
                      ),
                    ],
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
              const Text(
                '确认配对',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 14),
              InfoRow(label: '电脑', value: payload.deviceName),
              InfoRow(label: '服务', value: payload.origin.toString()),
              const SizedBox(height: 8),
              StatusPill(
                label: expired ? '二维码已过期' : '二维码仍有效',
                color: expired ? AppColors.stop : AppColors.accent,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: expired
                          ? null
                          : () => Navigator.pop(context, true),
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('连接这台电脑'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '取消',
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

class ChatScreen extends StatelessWidget {
  const ChatScreen({
    super.key,
    required this.session,
    required this.running,
    required this.connected,
    required this.offline,
    required this.messages,
    required this.promptController,
    required this.onChanged,
    required this.onFillPrompt,
    required this.onReconnect,
    required this.onSend,
    required this.onStop,
    required this.onLogout,
  });

  final SavedSession? session;
  final bool running;
  final bool connected;
  final bool offline;
  final List<TranscriptMessage> messages;
  final TextEditingController promptController;
  final VoidCallback onChanged;
  final ValueChanged<String> onFillPrompt;
  final VoidCallback onReconnect;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      key: const ValueKey('chat'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          children: [
            ConnectionHeader(
              session: session,
              connected: connected,
              offline: offline,
              onReconnect: onReconnect,
              onLogout: onLogout,
            ),
            const SizedBox(height: 10),
            SessionStrip(
              running: running,
              connected: connected,
              offline: offline,
              onReconnect: onReconnect,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: TranscriptView(
                messages: messages,
                running: running,
                onFillPrompt: onFillPrompt,
              ),
            ),
            const SizedBox(height: 10),
            PromptBar(
              controller: promptController,
              running: running,
              connected: connected,
              offline: offline,
              onChanged: onChanged,
              onSend: onSend,
              onStop: onStop,
            ),
          ],
        ),
      ),
    );
  }
}

class ConnectionHeader extends StatelessWidget {
  const ConnectionHeader({
    super.key,
    required this.session,
    required this.connected,
    required this.offline,
    required this.onReconnect,
    required this.onLogout,
  });

  final SavedSession? session;
  final bool connected;
  final bool offline;
  final VoidCallback onReconnect;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session?.deviceName ?? 'Jayson PC',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                MonoText(session?.workspaceName ?? 'cc-remote'),
              ],
            ),
          ),
          StatusPill(
            label: connected
                ? '已连接'
                : offline
                ? '电脑端离线'
                : '正在连接',
            color: connected
                ? AppColors.accent
                : offline
                ? AppColors.stop
                : AppColors.muted,
          ),
          const SizedBox(width: 6),
          IconButton(
            onPressed: () => showSettingsSheet(
              context,
              session,
              onReconnect,
              onLogout,
            ),
            icon: const Icon(Icons.settings_rounded),
            tooltip: '设置',
          ),
        ],
      ),
    );
  }
}

Future<void> showSettingsSheet(
  BuildContext context,
  SavedSession? session,
  VoidCallback onReconnect,
  VoidCallback onLogout,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => SettingsSheet(
      session: session,
      onReconnect: onReconnect,
      onLogout: onLogout,
    ),
  );
}

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({
    super.key,
    required this.session,
    required this.onReconnect,
    required this.onLogout,
  });

  final SavedSession? session;
  final VoidCallback onReconnect;
  final VoidCallback onLogout;

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
              InfoRow(label: '电脑', value: session?.deviceName ?? 'Jayson PC'),
              InfoRow(
                label: '服务',
                value:
                    session?.origin.toString() ?? 'https://tbhaoshuai.ccwu.cc',
              ),
              InfoRow(
                label: '目录',
                value: session?.workspaceName ?? 'cc-remote',
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    onReconnect();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新连接'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => confirmLogout(context, onLogout),
                  icon: const Icon(Icons.link_off_rounded),
                  label: const Text('退出配对'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.stop,
                    foregroundColor: Colors.white,
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

class SessionStrip extends StatelessWidget {
  const SessionStrip({
    super.key,
    required this.running,
    required this.connected,
    required this.offline,
    required this.onReconnect,
  });

  final bool running;
  final bool connected;
  final bool offline;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final icon = running
        ? Icons.bolt_rounded
        : connected
        ? Icons.history_rounded
        : Icons.wifi_off_rounded;
    final color = running || connected
        ? AppColors.accent
        : offline
        ? AppColors.stop
        : AppColors.muted;
    final label = running
        ? 'Claude 正在运行'
        : connected
        ? '新会话'
        : offline
        ? '电脑端离线'
        : '正在连接电脑端';

    return GlassPanel(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (running)
            const SizedBox(
              width: 58,
              child: LinearProgressIndicator(
                minHeight: 3,
                color: AppColors.accent,
                backgroundColor: Color(0xFFE8F3F6),
              ),
            )
          else if (!connected)
            TextButton(onPressed: onReconnect, child: const Text('重连')),
        ],
      ),
    );
  }
}

class TranscriptView extends StatelessWidget {
  const TranscriptView({
    super.key,
    required this.messages,
    required this.running,
    required this.onFillPrompt,
  });

  final List<TranscriptMessage> messages;
  final bool running;
  final ValueChanged<String> onFillPrompt;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return GlassPanel(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.terminal_rounded,
                          size: 42,
                          color: AppColors.accent,
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          '本机已连接',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '可以发送任务给 Claude Code',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.muted),
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            PromptChip(
                              label: '检查这个项目',
                              onTap: () => onFillPrompt('检查这个项目'),
                            ),
                            PromptChip(
                              label: '运行测试',
                              onTap: () => onFillPrompt('运行测试并总结结果'),
                            ),
                            PromptChip(
                              label: '总结当前目录',
                              onTap: () => onFillPrompt('总结当前目录结构'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: ListView.separated(
        itemCount: messages.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final message = messages[index];
          return MessageBlock(
            message: message,
            streaming: running && index == messages.length - 1,
          );
        },
      ),
    );
  }
}

class MessageBlock extends StatelessWidget {
  const MessageBlock({
    super.key,
    required this.message,
    required this.streaming,
  });

  final TranscriptMessage message;
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

    final isUser = message.role == MessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: isUser
                ? AppColors.accent.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isUser
                  ? AppColors.accent.withValues(alpha: 0.26)
                  : Colors.white.withValues(alpha: 0.74),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.text,
                style: TextStyle(
                  height: 1.42,
                  color: isUser ? AppColors.ink : AppColors.ink,
                  fontFamily: message.text.contains('`') ? 'monospace' : null,
                ),
              ),
              if (streaming) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(
                  minHeight: 3,
                  color: AppColors.accent,
                  backgroundColor: Color(0xFFE8F3F6),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class PromptBar extends StatelessWidget {
  const PromptBar({
    super.key,
    required this.controller,
    required this.running,
    required this.connected,
    required this.offline,
    required this.onChanged,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool running;
  final bool connected;
  final bool offline;
  final VoidCallback onChanged;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final canSend = controller.text.trim().isNotEmpty && !running && connected;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      radius: 20,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !running,
              minLines: 1,
              maxLines: 4,
              onChanged: (_) => onChanged(),
              decoration: InputDecoration(
                hintText: connected
                    ? '发送任务给 Claude Code'
                    : offline
                    ? '电脑端离线，请先重连'
                    : '正在连接电脑端',
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: running ? onStop : (canSend ? onSend : null),
            icon: Icon(
              running ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            ),
            tooltip: running ? '停止' : '发送',
            style: IconButton.styleFrom(
              backgroundColor: running ? AppColors.stop : AppColors.accent,
              disabledBackgroundColor: const Color(0xFFD9E7EC),
              foregroundColor: Colors.white,
            ),
          ),
        ],
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
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFF7FAFC),
              Color(0xFFEAF5FF),
              Color(0xFFE6FBF5),
              Color(0xFFF0EEFA),
            ],
          ),
        ),
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
    this.radius = 22,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: double.infinity,
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.56),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.78)),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadow.withValues(alpha: 0.13),
                blurRadius: 30,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: child,
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
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
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
      ),
    );
  }
}

class PromptChip extends StatelessWidget {
  const PromptChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      onPressed: onTap,
      label: Text(label),
      side: BorderSide(color: AppColors.accent.withValues(alpha: 0.18)),
      backgroundColor: Colors.white.withValues(alpha: 0.54),
      labelStyle: const TextStyle(color: AppColors.ink),
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

class RemoteStatus {
  const RemoteStatus({required this.deviceName, required this.workspaceDir});

  final String? deviceName;
  final String? workspaceDir;

  static RemoteStatus fromJson(Map<String, dynamic> json) {
    return RemoteStatus(
      deviceName: json['deviceName'] as String?,
      workspaceDir: json['workspaceDir'] as String?,
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

String errorText(Object err) {
  if (err is FormatException) return '这不是 CC Remote 配对二维码';
  if (err is TimeoutException) return '连接超时，请检查电脑端和隧道';
  return '配对失败，请重新生成二维码';
}

class TranscriptMessage {
  const TranscriptMessage(this.role, this.text);

  factory TranscriptMessage.user(String text) =>
      TranscriptMessage(MessageRole.user, text);
  factory TranscriptMessage.assistant(String text) =>
      TranscriptMessage(MessageRole.assistant, text);
  factory TranscriptMessage.system(String text) =>
      TranscriptMessage(MessageRole.system, text);

  final MessageRole role;
  final String text;
}

enum MessageRole { user, assistant, system }

class AppColors {
  static const ink = Color(0xFF172026);
  static const muted = Color(0xFF6B7880);
  static const accent = Color(0xFF19A7CE);
  static const stop = Color(0xFFD96B6B);
  static const shadow = Color(0xFF7B8B96);
}
