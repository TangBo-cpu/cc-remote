import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('overlay shadow layers', () {
    test('stacks contact, directed, and ambient blurs', () {
      final shadows = AppElevation.overlay();
      expect(shadows, hasLength(3));
      // Ordered tight to wide so the near edge stays crisp.
      expect(shadows.map((shadow) => shadow.blurRadius).toList(), [
        2.0,
        14.0,
        32.0,
      ]);
      expect(shadows.map((shadow) => shadow.offset.dy).toList(), [
        1.0,
        5.0,
        14.0,
      ]);
      // Negative spread keeps the wide layer from smearing past the surface.
      expect(shadows[1].spreadRadius, -3);
      expect(shadows[2].spreadRadius, -8);
    });

    test('stays subtle enough not to muddy the page', () {
      for (final shadow in AppElevation.overlay()) {
        expect(shadow.color.a, lessThan(0.1));
      }
    });
  });

  group('softCard shadow layers', () {
    test('is layered rather than a single blur', () {
      final shadows = AppElevation.softCard();
      expect(shadows, hasLength(3));
      expect(shadows.map((shadow) => shadow.blurRadius).toList(), [
        2.0,
        10.0,
        22.0,
      ]);
    });

    test('each layer stays faint', () {
      for (final shadow in AppElevation.softCard()) {
        expect(shadow.color.a, lessThan(0.1));
      }
    });
  });

  testWidgets('dark mode keeps every layer visible but fainter', (
    tester,
  ) async {
    late List<BoxShadow> light;
    late List<BoxShadow> dark;
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('light-theme'),
        theme: buildSignalConsoleTheme(Brightness.light),
        home: Builder(
          builder: (context) {
            light = AppElevation.overlay(context: context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    // A fresh key rebuilds the tree; MaterialApp otherwise animates the theme
    // change and the second read would still see the light palette.
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('dark-theme'),
        theme: buildSignalConsoleTheme(Brightness.dark),
        home: Builder(
          builder: (context) {
            dark = AppElevation.overlay(context: context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(dark, hasLength(light.length));
    for (var i = 0; i < light.length; i++) {
      expect(dark[i].color.a, lessThan(light[i].color.a));
      expect(dark[i].color.a, greaterThan(0));
    }
  });
  group('unchanged quiet surfaces', () {
    test('bubbles still carry no shadow', () {
      expect(AppElevation.softBubble(), isEmpty);
    });
  });

  testWidgets('sheets float above the page', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const Scaffold(body: AppSheetSurface(child: Text('content'))),
      ),
    );
    final container = tester.widget<Container>(find.byType(Container).first);
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.boxShadow, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialogs share the sheet shadow depth', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: Scaffold(
          body: AppDialog(
            title: const Text('删除会话？'),
            content: const Text('无法恢复。'),
            actions: [TextButton(onPressed: () {}, child: const Text('取消'))],
          ),
        ),
      ),
    );
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(AppDialog),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.boxShadow, hasLength(3));
    expect(find.text('删除会话？'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
