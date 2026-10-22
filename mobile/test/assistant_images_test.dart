import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cc_remote/attachments.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'assistant pictures download with auth inside the reply without cropping',
    (tester) async {
      late HttpServer server;
      late HttpClient client;
      final requests = <String>[];
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(20, 40);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        image.dispose();
        picture.dispose();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        client = _RealHttp().createHttpClient(null);
        server.listen((request) {
          expect(request.headers.value('authorization'), 'Bearer image-token');
          requests.add(request.uri.path);
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(bytes);
          unawaited(request.response.close());
        });
      });
      debugNetworkImageHttpClientProvider = () => client;
      addTearDown(() async {
        debugNetworkImageHttpClientProvider = null;
        client.close(force: true);
        await server.close(force: true);
        PaintingBinding.instance.imageCache.clear();
      });
      final saved = SavedSession(
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'image-token',
        deviceName: 'fixture',
      );
      const attachment = RemoteAttachment(
        id: 'reply-image',
        name: 'chart.png',
        mimeType: 'image/png',
        size: 80,
        source: r'E:\workspace\chart.png',
      );
      final original = TranscriptMessage(
        MessageRole.assistant,
        '图表如下：\n\n![图表](<${attachment.source}>)',
        attachments: const [attachment],
      );
      final message = TranscriptMessage.fromJson(original.toJson());
      expect(message.attachments.single.source, attachment.source);
      const imageOnly = TranscriptMessage(
        MessageRole.assistant,
        '',
        attachments: [attachment],
      );
      expect(isBlankAssistantMessage(imageOnly), isFalse);
      expect(
        hasAssistantReplyAfterLastUser([
          TranscriptMessage.user('生成图片'),
          imageOnly,
        ]),
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageBlock(
                message: message,
                session: saved,
                activeSessionId: 'session-1',
              ),
            ),
          ),
        ),
      );
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null)) {
          break;
        }
      }
      expect(requests, [
        '/api/sessions/session-1/attachments/reply-image/content',
      ]);
      final displayed = tester.widget<RawImage>(find.byType(RawImage));
      expect(displayed.image, isNotNull);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('assistant-message')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
      final bounds = tester.getSize(find.byType(Image));
      expect(bounds.height / bounds.width, closeTo(2, 0.01));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageBlock(
                message: const TranscriptMessage(
                  MessageRole.assistant,
                  '',
                  attachments: [attachment],
                ),
                session: saved,
                activeSessionId: 'session-1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugNetworkImageHttpClientProvider = null;
    },
  );
}
