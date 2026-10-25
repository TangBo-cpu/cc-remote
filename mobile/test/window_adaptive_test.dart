import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/window_adaptive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('expanded window mounts the session rail beside the chat', (
    tester,
  ) async {
    await _setWindowSize(tester, const Size(1280, 800));
    await _pumpDemoChat(tester);

    expect(find.byType(SessionRail), findsOneWidget);
    expect(find.byKey(const ValueKey('chat')), findsOneWidget);

    final railWidth = tester.getSize(find.byType(SessionRail)).width;
    final chatWidth = tester.getSize(find.byKey(const ValueKey('chat'))).width;
    expect(railWidth, SessionRail.kSessionRailWidth);
    expect(chatWidth, greaterThan(800));
  });

  testWidgets('the sessions header button toggles the rail on tablets', (
    tester,
  ) async {
    await _setWindowSize(tester, const Size(1280, 800));
    await _pumpDemoChat(tester);

    await tester.tap(find.byTooltip('项目与会话'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionRail), findsNothing);

    await tester.tap(find.byTooltip('项目与会话'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionRail), findsOneWidget);
  });

  testWidgets('compact window keeps the modal sidebar instead of the rail', (
    tester,
  ) async {
    await _setWindowSize(tester, const Size(412, 915));
    await _pumpDemoChat(tester);

    expect(find.byType(SessionRail), findsNothing);

    await tester.tap(find.byTooltip('项目与会话'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionNavigatorPage), findsOneWidget);
  });

  testWidgets('the floating composer stays aligned with the transcript column', (
    tester,
  ) async {
    await _setWindowSize(tester, const Size(1280, 800));
    await _pumpDemoChat(tester);

    final composer = tester.getSize(find.byType(PromptBar));
    expect(composer.width, lessThanOrEqualTo(760));
  });

  testWidgets('settings sheet caps its width on expanded windows', (
    tester,
  ) async {
    await _setWindowSize(tester, const Size(1280, 800));
    await _pumpDemoChat(tester);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    final surface = tester.getSize(
      find.byKey(const ValueKey('settings-surface')),
    );
    expect(surface.width, lessThanOrEqualTo(640));
  });

  testWidgets('dialogs cap their width on wide windows', (tester) async {
    await _setWindowSize(tester, const Size(1280, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSignalConsoleTheme(),
        home: const Scaffold(
          body: AppDialog(
            title: Text('宽屏对话框'),
            content: Text('在平板上不应拉伸到屏幕宽度。'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dialog = tester.getSize(find.text('宽屏对话框'));
    expect(dialog.width, lessThanOrEqualTo(560));
  });

  test('window width classes follow the Material breakpoints', () {
    expect(kWindowMediumBreakpoint, 600);
    expect(kWindowExpandedBreakpoint, 840);
  });
}

Future<void> _setWindowSize(WidgetTester tester, Size logical) async {
  tester.view.physicalSize = logical;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _pumpDemoChat(WidgetTester tester) async {
  await tester.pumpWidget(const CcRemoteApp(enableCamera: false, demoMode: true));
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.text('连接这台电脑'));
  await tester.pumpAndSettle();
}
