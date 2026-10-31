import 'dart:async';

import 'package:cc_remote/codex_model_picker.dart';
import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/model_preference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Codex catalog retains provider-qualified model IDs', () {
    final models = CodexModelOption.fromWire([
      {'model': 'gpt-test-codex'},
      {'model': 'workbuddy-ai/deepseek-v4.1-flash'},
      {'model': 'workbuddy/deepseek-v4.1-flash'},
      {'model': 'invalid model'},
    ]);
    expect(models.map((item) => item.model), [
      'gpt-test-codex',
      'workbuddy-ai/deepseek-v4.1-flash',
      'workbuddy/deepseek-v4.1-flash',
    ]);
  });

  test(
    'prompt uses the selected model for its engine and preserves defaults',
    () {
      Map<String, Object> payload(SessionEngine engine, String? codexModel) =>
          buildPromptMessage(
            promptId: 'p',
            text: 'hello',
            attachmentIds: const [],
            permissionMode: PermissionMode.auto,
            sessionId: 's',
            model: ClaudeModelPreference.opus,
            codexModel: codexModel,
            engine: engine,
          );
      expect(
        payload(SessionEngine.codex, 'gpt-test-codex')['model'],
        'gpt-test-codex',
      );
      expect(
        payload(SessionEngine.codex, 'workbuddy/deepseek-v4.1-flash')['model'],
        'workbuddy/deepseek-v4.1-flash',
      );
      expect(payload(SessionEngine.claude, 'gpt-test-codex')['model'], 'opus');
      expect(payload(SessionEngine.codex, null).containsKey('model'), isFalse);
      expect(
        payload(SessionEngine.codex, 'invalid model').containsKey('model'),
        isFalse,
      );
      expect(
        payload(SessionEngine.codex, null)['sandboxMode'],
        'danger-full-access',
      );
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'Codex models load and current selection remains visible in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final catalog = Completer<List<CodexModelOption>>();
        String? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showCodexModelPicker(
                      context,
                      selected: 'model-19',
                      loadModels: () => catalog.future,
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.text('正在获取电脑端模型'), findsOneWidget);
        catalog.complete(
          List.generate(
            20,
            (index) => CodexModelOption(
              model: 'model-$index',
              displayName: 'Model $index',
            ),
          ),
        );
        await tester.pumpAndSettle();
        final current = find.byKey(
          const ValueKey('codex-model-option-model-19'),
        );
        expect(current.hitTestable(), findsOneWidget);
        expect(find.byTooltip('关闭选择器').hitTestable(), findsOneWidget);
        final follow = find.byKey(const ValueKey('codex-model-option-follow'));
        await tester.ensureVisible(follow);
        await tester.pumpAndSettle();
        await tester.tap(follow);
        await tester.pumpAndSettle();
        expect(result, '');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Codex catalog failure can be retried without closing the picker',
    (tester) async {
      var attempts = 0;
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showCodexModelPicker(
                    context,
                    selected: null,
                    loadModels: () async {
                      if (++attempts == 1) throw StateError('offline');
                      return const [
                        CodexModelOption(
                          model: 'gpt-test-codex',
                          displayName: 'Test Codex',
                        ),
                      ];
                    },
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('模型获取失败，点击刷新重试'), findsOneWidget);
      await tester.tap(find.byTooltip('刷新模型'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('codex-model-option-gpt-test-codex')),
      );
      await tester.pumpAndSettle();
      expect(result, 'gpt-test-codex');
      expect(attempts, 2);
    },
  );

  testWidgets(
    'Codex model button opens picker and native compact fills the prompt',
    (tester) async {
      final controller = TextEditingController(text: '/com');
      addTearDown(controller.dispose);
      var opened = false;
      var refreshed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: PromptBar(
                controller: controller,
                commands: const ['compact', 'review', 'inspect'],
                running: false,
                connected: true,
                offline: false,
                permissionMode: PermissionMode.auto,
                allowBypassPermissions: false,
                engine: SessionEngine.codex,
                selectedCodexModel: 'gpt-test-codex',
                modelName: 'previous-model',
                onModelPressed: (_) => opened = true,
                onRefreshCommands: () => refreshed = true,
                onPermissionModeSelected: (_) {},
                onCommandSelected: (command) => controller.text = '/$command ',
                onReconnect: () {},
                onSend: () {},
                onStop: () {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('composer-model-button')));
      expect(opened, isTrue);
      expect(find.text('previous-model'), findsNothing);
      await tester.tap(find.byTooltip('刷新指令'));
      expect(refreshed, isTrue);
      expect(find.text('review'), findsNothing);
      await tester.tap(find.text('compact'));
      await tester.pumpAndSettle();
      expect(controller.text, '/compact ');
      expect(find.byKey(const ValueKey('command-suggestions')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty command catalog ends loading and failure offers retry', (
    tester,
  ) async {
    var refreshed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommandSuggestions(
            commands: const [],
            loading: false,
            failed: true,
            onRefresh: () => refreshed = true,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('正在获取指令'), findsNothing);
    expect(find.text('指令获取失败，请刷新重试'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新指令'));
    expect(refreshed, isTrue);
  });
}
