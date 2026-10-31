import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' as semantics;
import 'package:cc_remote/main.dart';
import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/signal_console_theme.dart';

void main() => runApp(const ProcessPreview());

class ProcessPreview extends StatefulWidget {
  const ProcessPreview({super.key});
  @override
  State<ProcessPreview> createState() => _ProcessPreviewState();
}

class _ProcessPreviewState extends State<ProcessPreview> {
  final prompt = TextEditingController(text: '继续检查连接状态');
  final semanticsHandle = semantics.SemanticsBinding.instance.ensureSemantics();
  bool dark = Uri.base.queryParameters['dark'] == '1';
  bool running = Uri.base.queryParameters['live'] == '1';

  @override
  void dispose() {
    prompt.dispose();
    semanticsHandle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildSignalConsoleTheme(),
    darkTheme: buildSignalConsoleTheme(Brightness.dark),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    themeAnimationDuration: Duration.zero,
    home: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('组件预览 · 示例数据', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: () => setState(() => running = !running),
                  child: Text(running ? '结束' : '运行'),
                ),
                TextButton(
                  onPressed: () => setState(() => dark = !dark),
                  child: const Text('外观'),
                ),
              ],
            ),
            Expanded(
              child: AppBackground(
                child: ChatScreen(
                  session: SavedSession(
                    origin: Uri.parse('https://cc-remote.example.com'),
                    token: 'preview',
                    deviceName: 'Demo',
                    workspaceDir: 'cc-remote',
                  ),
                  activeSessionId: 'preview',
                  running: running,
                  runStartedAt: running
                      ? DateTime.now().subtract(const Duration(seconds: 8))
                      : null,
                  connected: true,
                  offline: false,
                  modelName: 'claude-opus',
                  contextWindow: 200000,
                  remainingContext: 174000,
                  messages: [
                    TranscriptMessage.user('检查这个项目的连接状态，并运行测试。'),
                    TranscriptMessage.activity(
                      '思考完成',
                      id: 'thinking',
                      kind: ActivityKind.thinking,
                      state: ActivityState.done,
                      detail: '先检查**连接恢复逻辑**，确认草稿和会话不会丢失。\n接着核对权限请求与停止反馈。',
                      durationMs: 4200,
                    ),
                    TranscriptMessage.activity(
                      '已读取文件',
                      id: 'read',
                      kind: ActivityKind.tool,
                      state: ActivityState.done,
                      tool: 'Read',
                      detail: 'mobile/lib/main.dart',
                    ),
                    TranscriptMessage.assistant('已读取连接逻辑，接下来查找恢复路径。'),
                    TranscriptMessage.activity(
                      '已搜索代码',
                      id: 'search',
                      kind: ActivityKind.tool,
                      state: ActivityState.done,
                      tool: 'Grep',
                      detail: 'connectionState',
                    ),
                    TranscriptMessage.activity(
                      '思考完成',
                      id: 'thinking-review',
                      kind: ActivityKind.thinking,
                      state: ActivityState.done,
                      detail: '已经定位到恢复路径。接下来运行测试，核对草稿和会话是否保持。',
                      durationMs: 2400,
                    ),
                    TranscriptMessage.activity(
                      running ? '正在运行测试' : '已运行命令',
                      id: 'test',
                      kind: ActivityKind.tool,
                      state: running
                          ? ActivityState.running
                          : ActivityState.done,
                      tool: 'Bash',
                      detail: 'flutter test',
                    ),
                    if (!running)
                      TranscriptMessage.assistant(
                        '检查已完成。\n\n会话和草稿在外观切换后保持不变，连接恢复测试已通过。\n\n```dart\nfinal palette = AppPalette.of(context);\n```',
                      ),
                  ],
                  commands: const [],
                  permissionMode: PermissionMode.auto,
                  allowBypassPermissions: false,
                  pendingPermissions: const [],
                  respondingPermissionIds: const {},
                  promptController: prompt,
                  onFillPrompt: (text) => prompt.text = text,
                  onReconnect: () {},
                  onOpenSettings: () {},
                  onOpenModelPicker: (_) {},
                  onNewConversation: () {},
                  onOpenSessions: () {},
                  onOpenWorkspace: () {},
                  onPermissionModeSelected: (_) {},
                  onPermissionAllow: (_) {},
                  onPermissionDeny: (_) {},
                  onSend: () {},
                  onStop: () => setState(() => running = false),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
