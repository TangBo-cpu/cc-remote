import 'dart:async';

import 'package:cc_remote/data/directory_api.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/directory_picker.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const roots = RemoteDirectoryListing(
  roots: [RemoteDirectory(name: 'C:', path: 'C:\\')],
);
const projectPath = r'C:\Projects\中文 app';
final input = find.byKey(const ValueKey('directory-path-input'));
final create = find.byKey(const ValueKey('directory-create-session'));

Future<RemoteDirectoryListing> browse(String? path) async => path == null
    ? roots
    : RemoteDirectoryListing(
        path: path,
        parentPath: path == 'C:\\' ? null : 'C:\\',
      );

Future<void> pumpPicker(
  WidgetTester tester, {
  Future<RemoteDirectoryListing> Function(String?)? onBrowse,
  Future<void> Function(String, SessionEngine)? onCreate,
  ValueNotifier<bool>? busy,
  double scale = 1,
  Brightness brightness = Brightness.light,
  List<RemoteProjectSummary> recentProjects = const [],
}) async {
  final busyState = busy ?? ValueNotifier(false);
  if (busy == null) addTearDown(busyState.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildSignalConsoleTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DirectoryPickerPage(
                  onBrowse: onBrowse ?? browse,
                  onCreate: onCreate ?? (_, _) async {},
                  busyListenable: busyState,
                  recentProjects: recentProjects,
                  currentPath: '/projects/original',
                ),
              ),
            ),
            child: const Text('打开选择器'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开选择器'));
  await tester.pumpAndSettle();
}

Future<void> openPath(WidgetTester tester, String path) async {
  await tester.enterText(input, path);
  await tester.tap(find.byKey(const ValueKey('directory-path-open')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('recent projects and roots browse without creating a session', (
    tester,
  ) async {
    final visited = <String?>[];
    var creations = 0;
    await pumpPicker(
      tester,
      recentProjects: [
        const RemoteProjectSummary(
          id: 'project',
          name: 'app',
          path: projectPath,
          sessionCount: 2,
          running: false,
        ),
      ],
      onBrowse: (path) {
        visited.add(path);
        return browse(path);
      },
      onCreate: (_, _) async {
        creations++;
      },
    );
    final recent = find.byKey(const ValueKey('recent-$projectPath'));
    await tester.ensureVisible(recent);
    await tester.tap(recent);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, projectPath);
    expect(find.text('此目录没有子文件夹，可以直接在此新建对话'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('directory-parent')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, 'C:\\');
    await tester.tap(find.byKey(const ValueKey('directory-roots')));
    await tester.pumpAndSettle();
    expect(visited, [null, projectPath, 'C:\\', null]);
    expect(creations, 0);
  });

  testWidgets(
    'validated directory and selected engine create once then return to chat',
    (tester) async {
      final pending = Completer<void>();
      final calls = <(String, SessionEngine)>[];
      await pumpPicker(
        tester,
        onCreate: (path, engine) {
          calls.add((path, engine));
          return pending.future;
        },
      );
      await openPath(tester, projectPath);
      await tester.tap(find.byKey(const ValueKey('directory-engine-codex')));
      await tester.tap(create);
      await tester.pump();
      expect(calls, [(projectPath, SessionEngine.codex)]);
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      expect(find.text('在此新建对话'), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(DirectoryPickerPage), findsNothing);
      expect(find.text('打开选择器'), findsOneWidget);
    },
  );

  testWidgets('manual path is validated before session creation', (
    tester,
  ) async {
    final events = <String>[];
    await pumpPicker(
      tester,
      onBrowse: (path) {
        events.add('browse:$path');
        return browse(path);
      },
      onCreate: (path, _) async {
        events.add('create:$path');
      },
    );
    await tester.enterText(input, projectPath);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(events, [
      'browse:null',
      'browse:$projectPath',
      'create:$projectPath',
    ]);
  });

  testWidgets('busy tasks allow browsing and enable creation when finished', (
    tester,
  ) async {
    final busy = ValueNotifier(true);
    addTearDown(busy.dispose);
    await pumpPicker(tester, busy: busy);
    await openPath(tester, projectPath);
    expect(tester.widget<FilledButton>(create).onPressed, isNull);
    expect(find.text('当前任务或附件操作尚未结束，可以先浏览目录'), findsOneWidget);
    busy.value = false;
    await tester.pump();
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
  });

  testWidgets('late directory responses do not replace a newer navigation', (
    tester,
  ) async {
    final pending = Completer<RemoteDirectoryListing>();
    await pumpPicker(
      tester,
      onBrowse: (path) => path == projectPath ? pending.future : browse(path),
    );
    await tester.enterText(input, projectPath);
    await tester.tap(find.byKey(const ValueKey('directory-path-open')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('directory-roots')));
    await tester.pumpAndSettle();
    pending.complete(const RemoteDirectoryListing(path: projectPath));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(find.text('电脑磁盘与主目录'), findsOneWidget);
  });

  testWidgets('directory validation failure preserves the picker and retries', (
    tester,
  ) async {
    var attempts = 0;
    var creations = 0;
    await pumpPicker(
      tester,
      onBrowse: (path) {
        if (path != null && attempts++ == 0) {
          throw const DirectoryRequestException('directory_not_found');
        }
        return browse(path);
      },
      onCreate: (_, _) async {
        creations++;
      },
    );
    await openPath(tester, projectPath);
    expect(find.text('目录不存在，请检查路径或选择其他目录'), findsOneWidget);
    expect(creations, 0);
    await tester.tap(find.byKey(const ValueKey('directory-retry')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, projectPath);
    expect(find.text('目录不存在，请检查路径或选择其他目录'), findsNothing);
    expect(find.byType(DirectoryPickerPage), findsOneWidget);
  });

  testWidgets('failed creation keeps the selected path for another attempt', (
    tester,
  ) async {
    var attempts = 0;
    await pumpPicker(
      tester,
      onCreate: (_, _) async {
        if (attempts++ == 0) {
          throw const DirectoryRequestException('directory_busy');
        }
      },
    );
    await openPath(tester, projectPath);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(find.byType(DirectoryPickerPage), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, projectPath);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(DirectoryPickerPage), findsNothing);
  });

  testWidgets('legacy daemon gives an update instruction', (tester) async {
    await pumpPicker(
      tester,
      onBrowse: (_) async => throw const DirectoryRequestException(
        'directory_selection_unavailable',
      ),
    );
    expect(find.text('请先更新电脑端，再使用目录选择功能'), findsOneWidget);
    expect(find.byKey(const ValueKey('directory-retry')), findsOneWidget);
  });

  testWidgets(
    'directory picker fits narrow screens with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      for (final brightness in Brightness.values) {
        await pumpPicker(tester, scale: 2, brightness: brightness);
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.enterText(input, projectPath);
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
