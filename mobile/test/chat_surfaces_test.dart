import 'dart:ui' as ui;

import 'package:cc_remote/chat_surfaces.dart';
import 'package:cc_remote/noto_icon.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  testWidgets('moving snapshots preserve the device metrics of their content', (
    tester,
  ) async {
    late double contentRatio;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 3.5),
        child: SnapshotWhileAnimating(child: Builder(builder: (context) {
          contentRatio = MediaQuery.devicePixelRatioOf(context);
          return const SizedBox(width: 50, height: 50);
        })),
      ),
    ));
    expect(contentRatio, 3.5);
    expect(MediaQuery.devicePixelRatioOf(tester.element(find.byType(SnapshotWidget))), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass fallback keeps the field mounted and the draft intact', (
    tester,
  ) async {
    final controller = TextEditingController(text: '保留草稿');
    addTearDown(controller.dispose);
    Element? field;
    for (final mode in ['rest', 'scrolling', 'highContrast', 'rest']) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(highContrast: mode == 'highContrast'),
            child: SignalScrollBlurState(
              scrolling: mode == 'scrolling',
              child: Center(
                child: ChatGlass(
                  shape: const StadiumBorder(),
                  child: SizedBox(
                    width: 300,
                    child: Material(child: TextField(controller: controller)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final current = tester.element(find.byType(TextField));
      if (field != null) expect(current, same(field));
      field = current;
      expect(controller.text, '保留草稿');
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        mode == 'rest',
      );
      final fill = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((w) => w.decoration)
          .whereType<ShapeDecoration>()
          .single;
      expect(fill.color!.a, mode == 'rest' ? lessThan(1) : 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'bottom veil samples the stationary page through keyboard resizing',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final brightness in Brightness.values) {
        for (final inset in [0.0, 300.0]) {
          final captures = <List<int>>[];
          for (final showVeil in [false, true]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildSignalConsoleTheme(brightness),
                home: RepaintBoundary(
                  key: const ValueKey('capture'),
                  child: ChatBackdrop(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: inset),
                      child: Stack(
                        children: [
                          const Positioned.fill(child: SizedBox.expand()),
                          if (showVeil)
                            const Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              child: ChatBackdrop(
                                veil: true,
                                child: SizedBox(height: 120),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture')),
            );
            final pixels = <int>[];
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              for (final x in [20, 180, 370]) {
                for (final y in [
                  844 - inset.toInt() - 10,
                  844 - inset.toInt() - 90,
                ]) {
                  final offset = (y * image.width + x) * 4;
                  pixels.addAll(bytes.buffer.asUint8List(offset, 4));
                }
              }
              image.dispose();
            });
            captures.add(pixels);
          }
          for (var i = 0; i < captures.first.length; i++) {
            expect(
              (captures[0][i] - captures[1][i]).abs(),
              lessThanOrEqualTo(1),
            );
          }
        }
      }
    },
  );

  testWidgets('chat color icons retain disabled, danger and filled states', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      final palette = brightness == Brightness.light
          ? AppPalette.light
          : AppPalette.dark;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(brightness),
          home: ChatIconTheme(
            child: Row(
              children: [
                const SmartIcon(LucideIcons.folder, semanticLabel: '项目'),
                SmartIcon(LucideIcons.folder, color: palette.inactive),
                SmartIcon(
                  LucideIcons.shieldAlert,
                  color: palette.danger,
                  semanticLabel: '完全访问',
                ),
                SmartIcon(LucideIcons.trash2, color: palette.danger),
                SmartIcon(LucideIcons.check, color: palette.onCta),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final glyphs = tester
          .widgetList<NotoIcon>(find.byType(NotoIcon))
          .toList();
      expect(glyphs.map((icon) => icon.glyph), [
        NotoGlyph.folder,
        NotoGlyph.folder,
      ]);
      expect(glyphs.map((icon) => icon.opacity), [1, 0.4]);
      expect(
        tester.widget<Icon>(find.byIcon(LucideIcons.shieldAlert)).color,
        palette.danger,
      );
      expect(
        tester.widget<Icon>(find.byIcon(LucideIcons.trash2)).color,
        palette.danger,
      );
      expect(
        tester.widget<Icon>(find.byIcon(LucideIcons.check)).color,
        palette.onCta,
      );
      expect(find.bySemanticsLabel('项目'), findsOneWidget);
      expect(find.bySemanticsLabel('完全访问'), findsOneWidget);
    }
  });
}
