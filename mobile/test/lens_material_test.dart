import 'package:cc_remote/codex_model_picker.dart';
import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/effort_gauge.dart';
import 'package:cc_remote/effort_preference.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/model_preference.dart';
import 'package:cc_remote/noto_icon.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('lens keeps the composer controls intact in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final draft = TextEditingController(text: '保留草稿');
      addTearDown(draft.dispose);
      ClaudeEffortPreference? effort;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(brightness),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: PromptBar(
                controller: draft,
                commands: const [],
                running: false,
                connected: true,
                offline: false,
                engine: SessionEngine.codex,
                permissionMode: PermissionMode.auto,
                allowBypassPermissions: false,
                selectedEffort: ClaudeEffortPreference.xhigh,
                remainingContext: 90000,
                contextWindow: 100000,
                onAddAttachment: () {},
                onModelPressed: (anchor) => showCodexModelPicker(
                  anchor,
                  selected: 'model-test',
                  loadModels: () async => const [
                    CodexModelOption(model: 'model-test', displayName: 'Test'),
                  ],
                ),
                onCodexSandboxModeSelected: (_) {},
                onEffortSelected: (value) => effort = value,
                onPermissionModeSelected: (_) {},
                onCommandSelected: (_) {},
                onReconnect: () {},
                onSend: () {},
                onStop: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final controls = [
        'composer-expand-button',
        'composer-effort-button',
        'composer-model-button',
        'permission-mode-chip',
        'composer-primary-action',
      ].map((key) => find.byKey(ValueKey(key))).toList();
      for (var i = 0; i < controls.length; i++) {
        expect(tester.getSize(controls[i]), const Size.square(48));
        if (i > 0) {
          expect(
            tester.getCenter(controls[i]).dx,
            greaterThan(tester.getCenter(controls[i - 1]).dx),
          );
        }
      }
      final plus = tester.widget<SmartIcon>(
        find.descendant(of: controls.first, matching: find.byType(SmartIcon)),
      );
      expect(plus.size, 18);
      final gauge = tester.widget<EffortGaugeIcon>(
        find.byKey(const ValueKey('composer-effort-visual')),
      );
      expect(gauge.effort, ClaudeEffortPreference.xhigh);
      expect(
        tester
            .widget<SignalLiquidGlass>(find.byKey(const ValueKey('composer')))
            .lens,
        isTrue,
      );
      await tester.tap(controls[2]);
      await tester.pumpAndSettle();
      expect(find.text('选择 Codex 模型'), findsOneWidget);
      final card = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byKey(const ValueKey('codex-model-option-follow')),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final border = (card.decoration as BoxDecoration).border! as Border;
      expect(
        border.top.color.a,
        lessThan(brightness == Brightness.dark ? 0.04 : 0.2),
      );
      await tester.tap(find.byTooltip('关闭选择器'));
      await tester.pumpAndSettle();
      await tester.tap(controls[3]);
      await tester.pumpAndSettle();
      expect(find.text('Codex 沙箱模式'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AppSheetSurface), findsNothing);
      expect(draft.text, '保留草稿');
      expect(effort, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'picker grows from its trigger and returns keyboard focus on dismissal',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: Builder(
                builder: (anchor) => SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    focusNode: focus,
                    tooltip: '打开',
                    onPressed: () => showClaudeModelPicker(
                      anchor,
                      selected: ClaudeModelPreference.opus,
                    ),
                    icon: const Icon(Icons.tune),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      final source = tester.getRect(find.byTooltip('打开'));
      await tester.tap(find.byTooltip('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      final surface = find.byType(AppSheetSurface);
      final early = tester.getRect(surface);
      await tester.pumpAndSettle();
      final settled = tester.getRect(surface);
      expect(early.width, lessThan(settled.width * 0.5));
      expect(
        (early.center - source.center).distance,
        lessThan((settled.center - source.center).distance),
      );
      expect(settled.left, 16);
      expect(settled.right, 374);
      expect(settled.bottom, 824);
      expect(focus.hasFocus, isFalse);
      final scrim = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(SheetScrim),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(scrim.color, AppPalette.light.scrim);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion is immediate and high contrast removes translucency',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: true, highContrast: true),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showClaudeModelPicker(
                  context,
                  selected: ClaudeModelPreference.opus,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pump();
      final sheet = find.byType(AppSheetSurface);
      final bounds = tester.getRect(sheet);
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.getRect(sheet), bounds);
      final glass = tester.widget<SignalLiquidGlass>(
        find.descendant(of: sheet, matching: find.byType(SignalLiquidGlass)),
      );
      expect(
        glass.decoration.gradient!.colors.every((color) => color.a == 1),
        isTrue,
      );
      expect(
        ModalRoute.of(tester.element(sheet))!.transitionDuration,
        Duration.zero,
      );
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
