import 'package:cc_remote/noto_icon.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  testWidgets('Noto glyphs load from bundled assets', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Wrap(
            children: [for (final glyph in NotoGlyph.values) NotoIcon(glyph)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(NotoGlyph.values.length));
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    final palette = brightness == Brightness.light
        ? AppPalette.light
        : AppPalette.dark;

    testWidgets('color arguments keep the Noto family in $brightness', (
      tester,
    ) async {
      for (final color in [
        null,
        palette.ink,
        palette.danger,
        palette.inactive,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSignalConsoleTheme(brightness),
            home: Scaffold(
              body: SmartIcon(
                LucideIcons.trash2,
                size: 20,
                color: color,
                semanticLabel: '删除',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final icon = tester.widget<NotoIcon>(find.byType(NotoIcon));
        expect(icon.glyph, NotoGlyph.trash2);
        expect(icon.size, 20);
        expect(icon.opacity, color == palette.inactive ? 0.4 : 1);
        expect(find.bySemanticsLabel('删除'), findsOneWidget);
        expect(tester.widget<Image>(find.byType(Image)).color, isNull);
        expect(find.byType(Icon), findsNothing);
      }
    });

    testWidgets('structural symbols keep color and contrast in $brightness', (
      tester,
    ) async {
      for (final color in [
        null,
        palette.ink,
        palette.muted,
        palette.inactive,
        palette.danger,
        palette.success,
        palette.onCta,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSignalConsoleTheme(brightness),
            home: Scaffold(
              body: SmartIcon(LucideIcons.chevronRight, color: color),
            ),
          ),
        );
        final icon = tester.widget<Icon>(find.byType(Icon));
        final expected =
            color == palette.danger ||
                color == palette.success ||
                color == palette.onCta
            ? color
            : palette.iconAccent.withValues(
                alpha: color == palette.inactive ? 0.4 : 1,
              );
        expect(icon.color, expected);
        expect(icon.icon, LucideIcons.chevronRight);
      }
      for (final background in [palette.paper, palette.control]) {
        final foregroundLuminance = palette.iconAccent.computeLuminance();
        final backgroundLuminance = background.computeLuminance();
        final contrast = foregroundLuminance > backgroundLuminance
            ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
            : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
        expect(contrast, greaterThanOrEqualTo(3));
      }
    });
  }

  testWidgets('Noto glyphs inherit size and opacity from IconTheme', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const Scaffold(
          body: IconTheme(
            data: IconThemeData(size: 16, opacity: 0.5),
            child: SmartIcon(LucideIcons.folder),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final icon = tester.widget<NotoIcon>(find.byType(NotoIcon));
    expect(icon.size, 16);
    expect(icon.opacity, 0.5);
    expect(tester.widget<Image>(find.byType(Image)).opacity?.value, 0.5);
  });

  testWidgets('disabled buttons dim the same glyph and cannot be activated', (
    tester,
  ) async {
    var presses = 0;
    for (final enabled in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: IconButton(
              onPressed: enabled ? () => presses++ : null,
              tooltip: '设置',
              icon: const SmartIcon(LucideIcons.settings),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final icon = tester.widget<NotoIcon>(find.byType(NotoIcon));
      expect(icon.glyph, NotoGlyph.settings);
      expect(icon.opacity, enabled ? 1 : lessThan(1));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(presses, 1);
      expect(tester.takeException(), isNull);
    }
  });
}
