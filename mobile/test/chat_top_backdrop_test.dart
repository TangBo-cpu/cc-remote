import 'dart:io';
import 'dart:ui' as ui;

import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_TOP_FROST')) {
      final bytes = ByteData.sublistView(
        await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes(),
      );
      for (final family in ['Ahem', 'Roboto']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });

  testWidgets('top frost follows the full header before fading out', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sessionOpens = 0;

    for (final dark in [false, true]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('frost-preview'),
          child: MaterialApp(
            key: ValueKey(dark),
            debugShowCheckedModeBanner: false,
            theme: buildSignalConsoleTheme(
              dark ? Brightness.dark : Brightness.light,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                padding: const EdgeInsets.only(top: 24),
                textScaler: TextScaler.linear(dark ? 1.6 : 1),
              ),
              child: AppBackground(
                child: ChatScreen(
                  session: null,
                  running: false,
                  connected: !dark,
                  offline: dark,
                  modelName: null,
                  contextWindow: null,
                  remainingContext: null,
                  messages: [
                    TranscriptMessage.assistant(
                      List.filled(
                        60,
                        'Background text should blur beneath the floating header. '
                        '滚动到顶部的正文应该模糊，标题按钮保持清晰。',
                      ).join('\n\n'),
                    ),
                  ],
                  commands: const [],
                  permissionMode: PermissionMode.manual,
                  allowBypassPermissions: false,
                  pendingPermissions: const [],
                  respondingPermissionIds: const {},
                  promptController: controller,
                  onFillPrompt: (_) {},
                  onReconnect: () {},
                  onOpenSettings: () {},
                  onOpenModelPicker: (_) {},
                  onNewConversation: () {},
                  onOpenSessions: () => sessionOpens++,
                  onOpenWorkspace: () {},
                  onPermissionModeSelected: (_) {},
                  onPermissionAllow: (_) {},
                  onPermissionDeny: (_) {},
                  onSend: () {},
                  onStop: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final header = find.byType(ConnectionHeader);
      final topOverlay = find.ancestor(
        of: header,
        matching: find.byType(SizeChangedLayoutNotifier),
      );
      final mask = find.byKey(const ValueKey('chat-top-frost-mask'));
      final maskBounds = tester.getRect(mask);
      final headerBottom = tester.getRect(topOverlay).bottom - maskBounds.top;
      expect(maskBounds.height, closeTo(headerBottom / 2 + 14, 0.1));

      final decoration =
          tester.widget<DecoratedBox>(mask).decoration as BoxDecoration;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final bounds = Rect.fromLTWH(0, 0, 1, maskBounds.height);
        Canvas(recorder).drawRect(
          bounds,
          Paint()..shader = decoration.gradient!.createShader(bounds),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(1, maskBounds.height.ceil());
        picture.dispose();
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();

        expect(pixels!.getUint8((maskBounds.height.floor() - 1) * 4 + 3), 255);
      });

      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('transcript-list')),
      );
      list.controller!.jumpTo(300);
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('frost-preview')),
      );
      final filter = tester.renderObject<RenderBackdropFilter>(
        find.ancestor(of: mask, matching: find.byType(BackdropFilter)),
      );
      final originalFilter = filter.filter;
      Future<ByteData> capture(String suffix) async {
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final pixels = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (const bool.fromEnvironment('CAPTURE_TOP_FROST')) {
            await Directory('build/top-frost-preview').create(recursive: true);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              'build/top-frost-preview/${dark ? 'dark' : 'light'}-$suffix.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          }
          image.dispose();
          return pixels!;
        }))!;
      }

      final blurred = await capture('blurred');
      filter.filter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);
      await tester.pump();
      final sharp = await capture('sharp');
      filter.filter = originalFilter;
      await tester.pump();

      final width = boundary.size.width.toInt();
      double edgeContrast(ByteData pixels, int top, int bottom) {
        var total = 0;
        for (var y = top; y < bottom; y++) {
          for (var x = 32; x < width - 32; x++) {
            for (var channel = 0; channel < 3; channel++) {
              final offset = (y * width + x) * 4 + channel;
              total += (pixels.getUint8(offset) - pixels.getUint8(offset - 4))
                  .abs();
            }
          }
        }
        return total.toDouble();
      }

      final blurredEdges = edgeContrast(blurred, 0, 32);
      final sharpEdges = edgeContrast(sharp, 0, 32);
      expect(sharpEdges, greaterThan(1000));
      expect(
        blurredEdges,
        lessThan(sharpEdges * 0.5),
        reason:
            'The composed header must blur transcript edges: '
            '$blurredEdges with blur, $sharpEdges without blur.',
      );
      final bodyTop = maskBounds.bottom.ceil() + 16;
      // Backdrop repaints can round an unchanged 8-bit channel by one.
      for (var y = bodyTop; y < bodyTop + 40; y++) {
        for (var x = 32; x < width - 32; x++) {
          for (var channel = 0; channel < 3; channel++) {
            final offset = (y * width + x) * 4 + channel;
            expect(
              blurred.getUint8(offset),
              closeTo(sharp.getUint8(offset), 1),
            );
          }
        }
      }

      await tester.tap(find.byTooltip('项目与会话'));
      expect(sessionOpens, dark ? 2 : 1);
      expect(tester.takeException(), isNull);
    }
  });
}
