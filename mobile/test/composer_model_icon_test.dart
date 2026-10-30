import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('model button follows the engine, theme, and enabled state', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var presses = 0;

    for (final brightness in Brightness.values) {
      for (final engine in SessionEngine.values) {
        for (final enabled in [true, false]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildSignalConsoleTheme(brightness),
              home: Scaffold(
                body: SizedBox(
                  width: 320,
                  child: PromptBar(
                    controller: controller,
                    commands: const [],
                    running: false,
                    connected: true,
                    offline: false,
                    permissionMode: PermissionMode.manual,
                    allowBypassPermissions: false,
                    engine: engine,
                    onModelPressed: enabled ? () => presses++ : null,
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

          final button = find.byKey(const ValueKey('composer-model-button'));
          final imageFinder = find.descendant(
            of: button,
            matching: find.byType(Image),
          );
          final image = tester.widget<Image>(imageFinder);
          expect(
            (image.image as AssetImage).assetName,
            engine == SessionEngine.codex
                ? 'assets/brands/openai-mark.png'
                : 'assets/brands/claude-mark.png',
          );
          expect(
            image.color,
            engine == SessionEngine.codex
                ? AppPalette.of(tester.element(button)).composerControlInk
                : isNull,
          );
          expect(image.excludeFromSemantics, isTrue);
          expect(tester.getSize(imageFinder), const Size.square(24));
          expect(tester.getSize(button), const Size.square(48));
          final opacity = tester.widget<Opacity>(
            find.descendant(of: button, matching: find.byType(Opacity)).last,
          );
          expect(opacity.opacity, enabled ? 1 : 0.4);
          final previousPresses = presses;
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(presses, previousPresses + (enabled ? 1 : 0));
          expect(tester.takeException(), isNull);
        }
      }
    }
  });
}
