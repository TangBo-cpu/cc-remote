import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/workspace_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Finder _paragraph(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == text,
);

Widget _reply(
  String markdown, {
  double scale = 1,
  Brightness brightness = Brightness.light,
  ValueChanged<String>? onOpenPath,
}) => MaterialApp(
  key: ValueKey((markdown, scale, brightness)),
  theme: buildSignalConsoleTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: WorkspacePortal(
          workspaceDir: '/workspace/project',
          onOpenPath: onOpenPath,
          child: MessageBlock(message: TranscriptMessage.assistant(markdown)),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    final loader = FontLoader(AppTypography.assistantCodeFontFamily)
      ..addFont(rootBundle.load('assets/fonts/GeistMono-Regular.ttf'));
    await loader.load();
  });

  testWidgets(
    'paragraph gaps stay larger than tight and loose list item gaps',
    (tester) async {
      for (final list in [
        '- Item one\n- Item two',
        '- Item one\n\n- Item two',
        '1. Item one\n2. Item two',
        '- [ ] Item one\n- [x] Item two',
      ]) {
        await tester.pumpWidget(
          _reply('Paragraph one\n\nParagraph two\n\n$list'),
        );
        await tester.pumpAndSettle();
        final firstParagraph = tester.getRect(_paragraph('Paragraph one'));
        final secondParagraph = tester.getRect(_paragraph('Paragraph two'));
        final firstItem = tester.getRect(_paragraph('Item one'));
        final secondItem = tester.getRect(_paragraph('Item two'));
        expect(secondParagraph.top - firstParagraph.bottom, closeTo(12, 0.01));
        expect(secondItem.top - firstItem.bottom, closeTo(6, 0.01));
        expect(secondItem.left, closeTo(firstItem.left, 0.01));
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('nested lists keep compact spacing inside lists and quotes', (
    tester,
  ) async {
    for (final prefix in ['', '> ']) {
      final markdown = [
        '- Parent',
        '  - Child one',
        '  - Child two',
        '- Sibling',
      ].map((line) => '$prefix$line').join('\n');
      await tester.pumpWidget(_reply(markdown));
      await tester.pumpAndSettle();
      final parent = tester.getRect(_paragraph('Parent'));
      final child = tester.getRect(_paragraph('Child one'));
      final nextChild = tester.getRect(_paragraph('Child two'));
      final sibling = tester.getRect(_paragraph('Sibling'));
      expect(child.left, greaterThan(parent.left));
      expect(nextChild.left, closeTo(child.left, 0.01));
      expect(nextChild.top - child.bottom, closeTo(6, 0.01));
      expect(sibling.left, closeTo(parent.left, 0.01));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('number columns fit changing digit counts at large text sizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final start in [9, 99]) {
      for (final scale in [1.0, 1.4, 2.0]) {
        await tester.pumpWidget(
          _reply('$start. One\n${start + 1}. Two', scale: scale),
        );
        await tester.pumpAndSettle();
        final first = tester.getRect(_paragraph('One'));
        final second = tester.getRect(_paragraph('Two'));
        expect(second.left, closeTo(first.left, 0.01));
        for (final number in [start, start + 1]) {
          final label = '$number.';
          final marker = find.descendant(
            of: find.text(label),
            matching: find.byType(RichText),
          );
          final paragraph = tester.renderObject<RenderParagraph>(marker);
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: label.length),
          );
          expect(boxes.map((box) => box.top).toSet(), hasLength(1));
          expect(tester.getRect(marker).right, lessThanOrEqualTo(first.left));
        }
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('technical replies reflow and retain path taps in both themes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const markdown =
        '## 用户态数据搬运\n\n'
        '在 `src/capture.c:1419` 调用 `copy_from_user`，保留中文与代码的阅读节奏。\n\n'
        '- `_IOC_SIZE(cmd) <= 128` 时使用栈缓冲区。\n'
        '- `V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE` 需要检查多平面参数。\n'
        '  - 查看 `drivers/media/platform/example/video/capture.c:3016`。\n\n'
        '> 引用中的 `struct v4l2_buffer` 同样需要自然换行。\n\n'
        '```c\nint video_usercopy(unsigned int cmd) { return 0; }\n```\n\n'
        '| 函数 | 作用 |\n| --- | --- |\n'
        '| `check_array_args()` | 检查参数 |';
    for (final width in [320.0, 390.0]) {
      tester.view.physicalSize = Size(width, 1000);
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 1.4, 2.0]) {
          final openedPaths = <String>[];
          await tester.pumpWidget(
            _reply(
              markdown,
              scale: scale,
              brightness: brightness,
              onOpenPath: openedPaths.add,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AssistantSelectionArea), findsOneWidget);
          expect(find.byKey(const ValueKey('code-block-card')), findsOneWidget);
          expect(find.byType(Table), findsOneWidget);
          await tester.tap(find.text('src/capture.c'));
          expect(openedPaths, hasLength(1));
          expect(openedPaths.single, contains('src/capture.c'));
          expect(tester.takeException(), isNull);
        }
      }
    }
  });
}
