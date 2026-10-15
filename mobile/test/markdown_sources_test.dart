import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source extraction preserves order, link labels and complete URLs', () {
    final sources = extractMarkdownSourceLinks('''
[第一份资料](https://example.com/report?q=one&lang=zh#part)
[重复资料](https://example.com/report?q=one&lang=zh#part)
[**手册** v2](https://docs.example.com/a_(b))
[参考资料][reference]
<https://auto.example.com/article>
https://bare.example.com/article

[reference]: https://ref.example.com/article
''');
    expect(sources.map((source) => source.uri.toString()), [
      'https://example.com/report?q=one&lang=zh#part',
      'https://docs.example.com/a_(b)',
      'https://ref.example.com/article',
      'https://auto.example.com/article',
      'https://bare.example.com/article',
    ]);
    expect(sources.map((source) => source.label), [
      '第一份资料',
      '手册 v2',
      '参考资料',
      'https://auto.example.com/article',
      'https://bare.example.com/article',
    ]);
  });

  test('source extraction excludes code, images and non-web links', () {
    final sources = extractMarkdownSourceLinks('''
[来源](http://example.com/source)
`[行内代码](https://inline.example.com)`

```md
[代码块](https://fenced.example.com)
https://fenced.example.com/bare
```

    [缩进代码](https://indented.example.com)

![图片](https://images.example.com/image.png)
[![链接图片](https://images.example.com/image.png)](https://image-target.example.com)
[邮件](mailto:example@example.com)
[文件](file:///tmp/file)
[相对路径](/docs/source)
[脚本](javascript:alert(1))
''');
    expect(sources.map((source) => source.uri.toString()), [
      'http://example.com/source',
    ]);
    expect(extractMarkdownSourceLinks('没有来源链接的正文。'), isEmpty);
  });

  for (final streaming in [false, true]) {
    for (final markdown in [false, true]) {
      testWidgets(
        'assistant citations hide protocol tokens (streaming: $streaming, markdown: $markdown)',
        (tester) async {
          final text =
              '${markdown ? '**核对结果**：' : ''}'
              '内核头文件将它放在对应的初始化阶段。'
              '\uE200cite\uE202turn1search2\uE201';
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MessageBlock(
                  message: TranscriptMessage.assistant(text),
                  isStreaming: streaming,
                ),
              ),
            ),
          );
          final visible = tester
              .widgetList<RichText>(find.byType(RichText))
              .map((widget) => widget.text.toPlainText())
              .join('\n');
          expect(visible, contains('内核头文件将它放在对应的初始化阶段。'));
          expect(visible, isNot(contains('turn1search2')));
          expect(visible, isNot(contains('\uE200')));
          expect(visible, contains('来源链接未提供'));
          final selection = tester.widget<AssistantSelectionArea>(
            find.byType(AssistantSelectionArea),
          );
          expect(selection.text, isNot(contains('turn1search2')));
          expect(selection.text, contains('来源链接未提供'));
          expect(
            find.byKey(const ValueKey('markdown-sources-bar')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'citation rendering follows stream updates without changing history',
    (tester) async {
      Future<void> pumpReply(String data, {bool streaming = true}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MessageBlock(
                  message: TranscriptMessage.assistant(data),
                  isStreaming: streaming,
                ),
              ),
            ),
          );
      String copyText() => tester
          .widget<AssistantSelectionArea>(find.byType(AssistantSelectionArea))
          .text;
      await pumpReply('正文\uE200ci');
      expect(copyText(), '正文');
      await pumpReply('正文\uE200cite\uE202turn1search2');
      expect(copyText(), '正文');
      const raw = '正文\uE200cite\uE202turn1search2\uE201';
      await pumpReply(raw);
      expect(copyText(), '正文〔来源链接未提供〕');
      await pumpReply(raw, streaming: false);
      expect(copyText(), '正文〔来源链接未提供〕');
      expect(
        tester.widget<MessageBlock>(find.byType(MessageBlock)).message.text,
        raw,
      );
      await pumpReply('[来源](https://example.com)$raw', streaming: false);
      expect(find.text('链接来源 · 1'), findsOneWidget);
      expect(copyText(), isNot(contains('turn1search2')));
      await pumpReply('下一条回复');
      expect(copyText(), '下一条回复');
      expect(find.byKey(const ValueKey('markdown-sources-bar')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('user messages preserve literal citation markers', (
    tester,
  ) async {
    const text = '排查 \uE200cite\uE202turn1search2\uE201';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBlock(message: TranscriptMessage.user(text)),
        ),
      ),
    );
    expect(find.text(text), findsOneWidget);
    expect(find.byType(AssistantSelectionArea), findsNothing);
  });

  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  for (final brightness in Brightness.values) {
    testWidgets(
      'source bar deduplicates links and opens them on a narrow phone in ${brightness.name}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        MethodCall? launchCall;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            launchCall = call;
            return true;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        const data =
            '[第一份资料](https://example.com/report?q=one&lang=zh#part)\n\n'
            '[重复](https://example.com/report?q=one&lang=zh#part)\n\n'
            '[第二份资料](https://docs.example.com/guide)';
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
                child: MessageBlock(message: TranscriptMessage.assistant(data)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('markdown-sources-bar')),
          findsOneWidget,
        );
        expect(find.text('链接来源 · 2'), findsOneWidget);
        expect(find.text('第一份资料'), findsOneWidget);
        expect(find.byKey(const ValueKey('markdown-source-2')), findsNothing);
        expect(find.byType(MarkdownBody), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('markdown-source-0')),
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('markdown-source-0')))
              .height,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(find.byKey(const ValueKey('markdown-source-0')));
        await tester.pump();
        final args = launchCall!.arguments as Map<Object?, Object?>;
        expect(launchCall!.method, 'launch');
        expect(args['url'], 'https://example.com/report?q=one&lang=zh#part');
        expect(args['useWebView'], isFalse);
        await tester.longPress(find.byKey(const ValueKey('markdown-source-0')));
        await tester.pumpAndSettle();
        expect(
          find.text('第一份资料\nhttps://example.com/report?q=one&lang=zh#part'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('链接来源 · 2'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('markdown-source-1')),
        );
        await tester.tap(find.byKey(const ValueKey('markdown-source-1')));
        await tester.pump();
        expect(
          (launchCall!.arguments as Map<Object?, Object?>)['url'],
          'https://docs.example.com/guide',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'source bar updates with the reply and waits for streaming to finish',
    (tester) async {
      Future<void> pumpReply(String data, {bool streaming = false}) =>
          tester.pumpWidget(
            MaterialApp(
              theme: buildSignalConsoleTheme(),
              home: Scaffold(
                body: MessageBlock(
                  message: TranscriptMessage.assistant(data),
                  isStreaming: streaming,
                ),
              ),
            ),
          );
      await pumpReply('[旧链接](https://old.example.com)');
      expect(find.text('1 · old.example.com'), findsOneWidget);
      await pumpReply('[新链接](https://new.example.com)');
      expect(find.text('1 · new.example.com'), findsOneWidget);
      expect(find.text('1 · old.example.com'), findsNothing);
      await pumpReply('```md\n[代码](https://code.example.com)\n```');
      expect(find.byKey(const ValueKey('markdown-sources-bar')), findsNothing);
      await pumpReply('[链接](https://stream.example.com)', streaming: true);
      expect(find.byKey(const ValueKey('markdown-sources-bar')), findsNothing);
      await pumpReply('[链接](https://stream.example.com)');
      expect(find.text('1 · stream.example.com'), findsOneWidget);
      await pumpReply('[相对链接](/file)');
      expect(find.byKey(const ValueKey('markdown-sources-bar')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source bar uses the existing failure feedback when launch fails',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBlock(
              message: TranscriptMessage.assistant('[来源](https://example.com)'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('markdown-source-0')));
      await tester.pump();
      expect(find.text('无法打开来源链接'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('markdown-sources-bar')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
