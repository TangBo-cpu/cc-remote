import 'dart:async';
import 'dart:math';

import 'package:cc_remote/appearance_preference.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/workspace_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('appearance defaults to system and restores explicit choices', () async {
    final store = AppearancePreferenceStore();
    expect(await store.load(), ThemeMode.system);
    await store.save(ThemeMode.dark);
    expect(await AppearancePreferenceStore().load(), ThemeMode.dark);
    await store.save(ThemeMode.light);
    expect(await AppearancePreferenceStore().load(), ThemeMode.light);
    await store.save(ThemeMode.system);
    expect(await store.load(), ThemeMode.system);
    expect(
      await store.storage.read(key: AppearancePreferenceStore.key),
      isNull,
    );
  });

  test('an unreadable or unknown preference falls back to system', () async {
    FlutterSecureStorage.setMockInitialValues({
      AppearancePreferenceStore.key: 'old-custom-theme',
    });
    expect(await AppearancePreferenceStore().load(), ThemeMode.system);
    expect(await _ReadFailureStore().load(), ThemeMode.system);
  });

  test('a late preference load cannot replace a new choice', () async {
    final store = _DelayedStore();
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    final initialization = controller.initialize();
    await controller.select(ThemeMode.dark);
    store.loaded.complete(ThemeMode.light);
    await initialization;
    expect(controller.value, ThemeMode.dark);
    expect(store.saved, [ThemeMode.dark]);
  });

  test('choosing system during initialization overrides a saved mode', () async {
    final store = _DelayedStore();
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    final initialization = controller.initialize();
    await controller.select(ThemeMode.system);
    store.loaded.complete(ThemeMode.dark);
    await initialization;
    expect(controller.value, ThemeMode.system);
    expect(store.saved, [ThemeMode.system]);
  });

  test('a failed save restores the previous appearance', () async {
    final controller = AppearanceController(_WriteFailureStore());
    addTearDown(controller.dispose);
    await expectLater(controller.select(ThemeMode.dark), throwsStateError);
    expect(controller.value, ThemeMode.system);
  });

  test('both palettes keep text and action labels readable', () {
    for (final colors in [AppPalette.light, AppPalette.dark]) {
      for (final background in [colors.paper, colors.surface, colors.control]) {
        expect(_contrast(colors.ink, background), greaterThanOrEqualTo(4.5));
        expect(_contrast(colors.muted, background), greaterThanOrEqualTo(4.5));
        expect(_contrast(colors.accent, background), greaterThanOrEqualTo(4.5));
        expect(_contrast(colors.danger, background), greaterThanOrEqualTo(4.5));
        expect(_contrast(colors.link, background), greaterThanOrEqualTo(4.5));
        expect(
          _contrast(colors.warning, background),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(
        _contrast(colors.link, colors.inlineCodeBackground),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(colors.ink, colors.inlineCodeBackground),
        greaterThanOrEqualTo(4.5),
      );
      expect(_contrast(colors.onCta, colors.cta), greaterThanOrEqualTo(4.5));
      expect(_contrast(colors.onStop, colors.stop), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets(
    'system appearance follows changes and explicit mode overrides it',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        const CcRemoteApp(enableCamera: false, demoMode: true),
      );
      await tester.pumpAndSettle();
      final shell = find.byType(DemoShell);
      expect(Theme.of(tester.element(shell)).brightness, Brightness.dark);
      final appearance = AppearanceScope.of(tester.element(shell));
      await appearance.select(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(shell)).brightness, Brightness.light);
      await appearance.select(ThemeMode.system);
      await tester.pumpAndSettle();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(shell)).brightness, Brightness.light);
    },
  );

  testWidgets('settings switches appearance without losing session or draft', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CcRemoteApp(enableCamera: false, demoMode: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();
    final shellState = tester.state(find.byType(DemoShell));
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    final sessionId = chat.activeSessionId;
    await tester.enterText(find.byType(TextField), '保留这条草稿');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.text('聊天背景'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-preference-preview')),
      findsNothing,
    );
    for (final mode in [ThemeMode.dark, ThemeMode.light, ThemeMode.system]) {
      await tester.tap(find.byKey(const ValueKey('appearance-setting')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('appearance-system')), findsOneWidget);
      expect(find.byKey(const ValueKey('appearance-light')), findsOneWidget);
      expect(find.byKey(const ValueKey('appearance-dark')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('appearance-${mode.name}')));
      await tester.pumpAndSettle();
      final brightness = mode == ThemeMode.dark
          ? Brightness.dark
          : Brightness.light;
      expect(
        Theme.of(tester.element(find.byType(SettingsSheet))).brightness,
        brightness,
      );
      expect(await AppearancePreferenceStore().load(), mode);
      final surface = tester.widget<Container>(
        find.byKey(const ValueKey('settings-surface')),
      );
      final decoration = surface.decoration! as BoxDecoration;
      final colors = mode == ThemeMode.dark
          ? AppPalette.dark
          : AppPalette.light;
      expect(decoration.color, isNull);
      expect(decoration.gradient, isNotNull);
      expect(decoration.border!.top.color, colors.glassHighlight);
    }
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(DemoShell)), same(shellState));
    final after = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(after.activeSessionId, sessionId);
    expect(after.promptController.text, '保留这条草稿');
    expect(find.byKey(const ValueKey('settings-surface')), findsNothing);
    final overlay = tester
        .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        )
        .last;
    expect(overlay.value.systemNavigationBarIconBrightness, Brightness.dark);
  });

  testWidgets('cached Markdown updates its palette when appearance changes', (
    tester,
  ) async {
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    final message = TranscriptMessage.assistant(
      '# 结果\n\n**已完成**，查看 `main.dart`。\n\n| 文件 | 状态 |\n| --- | --- |\n| main.dart | 已更新 |',
    );
    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (context, value, _) => MaterialApp(
          theme: buildSignalConsoleTheme(),
          darkTheme: buildSignalConsoleTheme(Brightness.dark),
          themeMode: value,
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: WorkspacePortal(
              workspaceDir: '/workspace/project',
              onOpenPath: (_) {},
              child: MessageBlock(message: message),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    List<Color?> pathLinkColors() => tester
        .widgetList<Text>(find.text('main.dart'))
        .where((text) => text.data == 'main.dart')
        .map((text) => text.style?.color)
        .toList();

    expect(pathLinkColors(), isNotEmpty);
    expect(pathLinkColors(), everyElement(AppPalette.light.link));
    expect(
      tester
          .widget<MarkdownBody>(find.bySubtype<MarkdownBody>())
          .styleSheet!
          .p!
          .color,
      AppPalette.light.ink,
    );
    mode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    final sheet = tester
        .widget<MarkdownBody>(find.bySubtype<MarkdownBody>())
        .styleSheet!;
    expect(sheet.p!.color, AppPalette.dark.ink);
    expect(sheet.h1!.color, AppPalette.dark.ink);
    expect(sheet.tableBody!.color, AppPalette.dark.ink);
    expect(pathLinkColors(), isNotEmpty);
    expect(pathLinkColors(), everyElement(AppPalette.dark.link));
    expect(tester.takeException(), isNull);
  });
}

double _contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return (max(first, second) + 0.05) / (min(first, second) + 0.05);
}

class _DelayedStore extends AppearancePreferenceStore {
  final loaded = Completer<ThemeMode>();
  final saved = <ThemeMode>[];
  @override
  Future<ThemeMode> load() => loaded.future;
  @override
  Future<void> save(ThemeMode mode) async => saved.add(mode);
}

class _WriteFailureStore extends AppearancePreferenceStore {
  @override
  Future<void> save(ThemeMode mode) async => throw StateError('save_failed');
}

class _ReadFailureStore extends AppearancePreferenceStore {
  _ReadFailureStore() : super(storage: _ReadFailureStorage());
}

class _ReadFailureStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw StateError('read_failed');
}
