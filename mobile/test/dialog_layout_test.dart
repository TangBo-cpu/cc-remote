import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dialog actions do not overflow at 320pt with 2x text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: AppDialog(
            title: const Text('当前对话使用完全访问'),
            content: const Text('Codex 将能访问工作区外的文件和命令。之后的消息沿用此模式。'),
            actions: [
              TextButton(onPressed: () {}, child: const Text('取消')),
              FilledButton(onPressed: () {}, child: const Text('对当前对话开启')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('long dialog content stays inside a short screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: AppDialog(
            title: const Text('删除会话？'),
            content: const Text(
              '将永久删除 CC Remote 中「一个非常长的会话标题用于测试溢出」的消息记录与附件，无法恢复。'
              '电脑上原生客户端的历史记录会保留。这是项目中最后一个未归档会话，删除后会自动创建一个同引擎的空白会话。',
            ),
            actions: [
              TextButton(onPressed: () {}, child: const Text('取消')),
              FilledButton(onPressed: () {}, child: const Text('删除')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('rename dialog keeps its text field editable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: AppDialog(
            title: const Text('重命名会话'),
            content: TextField(
              key: const ValueKey('rename-session-field'),
              decoration: const InputDecoration(hintText: '会话标题'),
            ),
            actions: [
              TextButton(onPressed: () {}, child: const Text('取消')),
              FilledButton(onPressed: () {}, child: const Text('保存')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rename-session-field')),
      '新标题',
    );
    await tester.pump();
    expect(find.text('新标题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
