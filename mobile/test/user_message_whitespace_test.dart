import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'synced prompts hide boundary blank lines and preserve inner formatting',
    (tester) async {
      const original = '\r\n \r\n  第一行\n\n    第二行\r\n \r\n';
      final message = TranscriptMessage.user(original);
      Widget bubble(TranscriptMessage value) => MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(body: MessageBlock(message: value, session: null)),
      );
      await tester.pumpWidget(bubble(message));
      expect(find.text('  第一行\n\n    第二行'), findsOneWidget);
      expect(message.text, original);
      final height = tester
          .getSize(find.byKey(const ValueKey('user-message')))
          .height;
      await tester.pumpWidget(
        bubble(TranscriptMessage.user('  第一行\n\n    第二行')),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('user-message'))).height,
        height,
      );
    },
  );
}
