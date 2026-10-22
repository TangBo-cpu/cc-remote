import 'dart:async';
import 'dart:convert';

import 'package:cc_remote/signal_console_theme.dart';
import 'package:cc_remote/workspace_diff_view.dart';
import 'package:cc_remote/workspace_drawer.dart';
import 'package:cc_remote/workspace_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final count in [1, 2]) {
      testWidgets(
        'workspace change summary opens full screen and copies diff ($brightness, $count files)',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(320, 568));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          final echo = WorkspaceChangeEcho(
            changeCount: count,
            paths: ['src/daemon.ts', if (count > 1) 'mobile/lib/main.dart'],
          );
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
                body: Builder(
                  builder: (context) => WorkspaceChangeEchoChip(
                    echo: echo,
                    onTap: () => showWorkspaceDrawer(
                      context,
                      origin: Uri.parse('https://example.test'),
                      token: 'test',
                      workspaceName: 'cc-remote',
                      demoMode: true,
                      initialTab: 1,
                      initialPath: echo.focusPath,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byType(WorkspaceChangeEchoChip));
          await tester.pumpAndSettle();
          if (count > 1) {
            expect(
              find.byKey(const ValueKey('workspace-changes')),
              findsOneWidget,
            );
            await tester.tap(find.text('daemon.ts'));
            await tester.pumpAndSettle();
          }
          expect(
            tester
                .getSize(find.byKey(const ValueKey('workspace-document-page')))
                .width,
            320,
          );
          final diff = tester
              .widget<WorkspaceDiffView>(find.byType(WorkspaceDiffView))
              .diff;
          await tester.tap(find.byTooltip('复制差异'));
          await tester.pumpAndSettle();
          expect(copied, diff);
          expect(find.text('差异已复制'), findsOneWidget);
          await tester.tap(find.byTooltip('返回文件列表'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('workspace-changes')),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('关闭'));
          await tester.pumpAndSettle();
          expect(find.byType(WorkspaceDrawer), findsNothing);
          expect(find.byType(WorkspaceChangeEchoChip), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'workspace preview copies a new file and handles clipboard failure',
    (tester) async {
      const content = '  first line\n\nsecond line\n';
      String? copied;
      var failClipboard = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (failClipboard) {
              throw PlatformException(code: 'clipboard_unavailable');
            }
            copied = (call.arguments as Map)['text'] as String;
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
      final api = WorkspaceApi(
        origin: Uri.parse('https://example.test'),
        token: 'test',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(switch (request.url.path) {
              '/api/workspace' => {
                'gitAvailable': true,
                'files': ['new.txt'],
                'changes': [
                  {'path': 'new.txt', 'unstaged': '?'},
                ],
              },
              '/api/workspace/diff' => {'diff': ''},
              '/api/workspace/file' => {'path': 'new.txt', 'content': content},
              _ => throw StateError('unexpected request'),
            }),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: WorkspaceDrawer(
              origin: api.origin,
              token: api.token,
              workspaceName: 'test',
              api: api,
              initialTab: 1,
              initialPath: 'new.txt',
              fullScreen: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-document-file')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('复制文件内容'));
      await tester.pumpAndSettle();
      expect(find.text('复制失败，请重试'), findsOneWidget);
      expect(copied, isNull);
      failClipboard = false;
      await tester.tap(find.byTooltip('复制文件内容'));
      await tester.pumpAndSettle();
      expect(copied, content);
      expect(find.text('文件内容已复制'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workspace preview disables copy while loading and after read failure',
    (tester) async {
      final response = Completer<http.Response>();
      final api = WorkspaceApi(
        origin: Uri.parse('https://example.test'),
        token: 'test',
        client: MockClient(
          (request) async => request.url.path == '/api/workspace'
              ? http.Response(
                  jsonEncode({
                    'files': ['broken.txt'],
                  }),
                  200,
                )
              : response.future,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Scaffold(
            body: WorkspaceDrawer(
              origin: api.origin,
              token: api.token,
              workspaceName: 'test',
              api: api,
              initialPath: 'broken.txt',
              fullScreen: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final copy = find.byKey(const ValueKey('workspace-document-copy'));
      expect(
        find.byKey(const ValueKey('workspace-document-loading')),
        findsOneWidget,
      );
      expect(tester.widget<IconButton>(copy).onPressed, isNull);
      response.complete(http.Response('{}', 500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-document-failed')),
        findsOneWidget,
      );
      expect(tester.widget<IconButton>(copy).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
