import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'code reader supports reading and copying on a narrow phone in ${brightness.name}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final transcriptController = ScrollController();
        addTearDown(transcriptController.dispose);
        String? copiedText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copiedText =
                  (call.arguments as Map<Object?, Object?>)['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final code =
            '  // preserve indentation\n\n${List.generate(80, (index) => 'final value$index = "${'long value ' * 15}";').join('\n')}';
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSignalConsoleTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                controller: transcriptController,
                child: Column(
                  children: [
                    const SizedBox(height: 250),
                    MessageBlock(
                      message: TranscriptMessage.assistant(
                        '```dart\n$code\n```',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('code-expand-button')),
        );
        final transcriptOffset = transcriptController.offset;
        await tester.tap(find.byKey(const ValueKey('code-expand-button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('code-reader-page')), findsOneWidget);
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(tester.takeException(), isNull);
        final text = tester.widget<Text>(
          find.byKey(const ValueKey('code-reader-text')),
        );
        expect(text.textSpan!.toPlainText(), code);
        expect(text.softWrap, isFalse);
        final horizontal = tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('code-reader-horizontal-scroll')),
            )
            .controller!;
        final vertical = tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('code-reader-vertical-scroll')),
            )
            .controller!;
        expect(horizontal.position.maxScrollExtent, greaterThan(0));
        expect(vertical.position.maxScrollExtent, greaterThan(0));
        horizontal.jumpTo(horizontal.position.maxScrollExtent);
        vertical.jumpTo(vertical.position.maxScrollExtent);
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const ValueKey('code-reader-wrap')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('code-reader-horizontal-scroll')),
          findsNothing,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('code-reader-text')))
              .softWrap,
          isTrue,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('code-reader-wrap')),
              )
              .isSelected,
          isTrue,
        );
        await tester.tap(find.byKey(const ValueKey('code-reader-font-size')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('code-reader-font-18')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('code-reader-text')))
              .style!
              .fontSize,
          18,
        );
        await tester.tap(find.byKey(const ValueKey('code-reader-copy')));
        await tester.pump();
        expect(copiedText, code);
        expect(find.byTooltip('已复制'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('code-reader-wrap')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('code-reader-horizontal-scroll')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('code-reader-text')))
              .textSpan!.toPlainText(),
          code,
        );
        await tester.tap(find.byKey(const ValueKey('code-reader-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('code-reader-page')), findsNothing);
        expect(
          find.byKey(const ValueKey('code-expand-button')),
          findsOneWidget,
        );
        expect(transcriptController.offset, transcriptOffset);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'code reader opens the chosen unlabeled block and resets reading options',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: MessageBlock(
              message: TranscriptMessage.assistant(
                '```dart\nfirst();\n```\n\n```\n  second();\n```',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('code-expand-button')).last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('code-reader-text')))
            .textSpan!.toPlainText(),
        '  second();',
      );
      expect(find.text('代码'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('code-reader-wrap')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('code-reader-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('code-expand-button')).first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('code-reader-text')))
            .textSpan!.toPlainText(),
        'first();',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('code-reader-wrap')))
            .isSelected,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
