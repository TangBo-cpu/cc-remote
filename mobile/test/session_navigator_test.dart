import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/signal_console_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const projects = [
  RemoteProjectSummary(
    id: 'p1',
    name: 'cc-remote',
    path: '/work/cc-remote',
    sessionCount: 3,
    running: false,
  ),
  RemoteProjectSummary(
    id: 'p2',
    name: '移动端应用',
    path: '/work/mobile',
    sessionCount: 2,
    running: false,
  ),
];

RemoteSessionSummary item(
  String id, {
  String project = 'p1',
  String? title,
  bool archived = false,
  bool pinned = false,
  bool running = false,
  bool attention = false,
  SessionEngine engine = SessionEngine.claude,
  int? updatedAt,
}) => RemoteSessionSummary(
  id: id,
  projectId: project,
  title: title ?? id,
  engine: engine,
  updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
  running: running,
  messageCount: 3,
  archived: archived,
  pinned: pinned,
  needsAttention: attention,
  preview: '已完成消息同步检查，保留当前会话的草稿与阅读位置。',
);

RemoteSessionSearchResult result(String id, {bool archived = false}) =>
    RemoteSessionSearchResult(
      sessionId: id,
      projectId: 'p1',
      title: id,
      updatedAt: 1,
      archived: archived,
      role: RemoteSessionSearchRole.assistant,
      messageIndex: 3,
      snippet: 'The reconnect panel is ready.',
      matchStart: 4,
      matchEnd: 13,
      matchCount: 2,
    );

Widget page({
  List<RemoteSessionSummary>? sessions,
  bool running = false,
  ValueChanged<String>? select,
  ValueChanged<RemoteSessionSearchResult>? selectSearch,
  FutureOr<void> Function(String, SessionEngine)? create,
  Future<void> Function(String, bool)? pin,
  Future<void> Function(String)? restore,
  SessionSearch? search,
  Brightness brightness = Brightness.light,
  double scale = 1,
}) {
  var theme = buildSignalConsoleTheme(brightness);
  if (const bool.fromEnvironment('CAPTURE_SESSION_CENTER')) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'SessionPreview'),
      filledButtonTheme: FilledButtonThemeData(
        style: theme.filledButtonTheme.style?.copyWith(
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: 'SessionPreview',
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
  return RepaintBoundary(
    key: const ValueKey('preview-boundary'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: SessionNavigatorPage(
        projects: projects,
        sessions: sessions ?? [item('current'), item('other', project: 'p2')],
        activeProjectId: 'p1',
        activeSessionId: 'current',
        running: running,
        onSelect: select ?? (_) {},
        onSearchResult: selectSearch ?? (_) {},
        onCreate: create ?? (_, _) {},
        onRename: (_, _) async {},
        onArchive: (_) async {},
        onDelete: (_) async {},
        onRestore: restore ?? (_) async {},
        onPin: pin ?? (_, _) async {},
        onSearch: search ?? (_, {projectId, engine, archived}) async => [],
      ),
    ),
  );
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_SESSION_CENTER')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preview-boundary')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/session-center-preview').create(recursive: true);
    await File(
      'build/session-center-preview/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_SESSION_CENTER')) {
      final bytes = ByteData.sublistView(
        await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes(),
      );
      for (final family in ['SessionPreview', 'Ahem', 'Roboto']) {
        final font = FontLoader(family)..addFont(Future.value(bytes));
        await font.load();
      }
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final entry in manifest.cast<Map<String, dynamic>>()) {
        final font = FontLoader(entry['family'] as String);
        for (final face in entry['fonts'] as List) {
          font.addFont(rootBundle.load(face['asset'] as String));
        }
        await font.load();
      }
    }
  });

  test(
    'parses optional session center fields while retaining old catalogs',
    () {
      final legacy = RemoteSessionSummary.tryParse({
        'id': 'a',
        'projectId': 'p1',
        'title': 'legacy',
      })!;
      expect(legacy.pinned, isFalse);
      expect(legacy.needsAttention, isFalse);
      expect(legacy.preview, isNull);
      final current = RemoteSessionSummary.tryParse({
        'id': 'a',
        'projectId': 'p1',
        'title': 'new',
        'pinned': true,
        'needsAttention': true,
        'preview': 'answer',
      })!;
      expect(current.pinned, isTrue);
      expect(current.needsAttention, isTrue);
      expect(current.preview, 'answer');
    },
  );

  testWidgets(
    'shows pinned then projects then recent and keeps archived sessions separate',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      await tester.pumpWidget(
        page(
          sessions: [
            item('current', pinned: true),
            item('waiting', project: 'p2', attention: true, running: true),
            item('old', updatedAt: 1),
            item('archive', archived: true),
          ],
          select: (id) => selected = id,
        ),
      );
      expect(find.text('会话中心'), findsOneWidget);
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('项目'), findsOneWidget);
      expect(find.text('最近'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-archive')), findsNothing);
      expect(
        tester.getTopLeft(find.text('置顶')).dy,
        lessThan(tester.getTopLeft(find.text('项目')).dy),
      );
      expect(find.byKey(const ValueKey('session-waiting')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('session-project-p2')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('等待授权'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('项目')).dy,
        lessThan(tester.getTopLeft(find.text('最近')).dy),
      );
      await tester.tap(find.byKey(const ValueKey('session-current')));
      expect(selected, 'current');
      await tester.tap(find.byKey(const ValueKey('session-archive-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-archive')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-archive')));
      expect(selected, 'archive');
    },
  );

  testWidgets(
    'compact project rows expand in batches and recent opens across projects',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      await tester.pumpWidget(
        page(
          sessions: [
            item('current', updatedAt: 1000),
            for (var index = 0; index < 7; index++)
              item('extra-$index', updatedAt: 900 - index),
            item('other', project: 'p2', updatedAt: 1100),
          ],
          select: (id) => selected = id,
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('session-current'))).height,
        48,
      );
      expect(find.text('已完成消息同步检查，保留当前会话的草稿与阅读位置。'), findsNothing);
      expect(find.byKey(const ValueKey('session-extra-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('session-extra-4')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('session-more-p1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-extra-6')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-project-p1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-current')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('session-project-p2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-other')), findsOneWidget);
      expect(selected, isNull);
      await tester.tap(find.byKey(const ValueKey('session-recent-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recent-session-other')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recent-session-current')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('recent-session-other')));
      expect(selected, 'other');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'project and engine filters combine without selecting an active session',
    (tester) async {
      var selected = false;
      await tester.pumpWidget(
        page(
          sessions: [
            item('current'),
            item('codex', project: 'p2', engine: SessionEngine.codex),
          ],
          select: (_) => selected = true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-project-browser')));
      await tester.pumpAndSettle();
      expect(find.text('/work/mobile'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('project-p2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-current')), findsNothing);
      expect(find.byKey(const ValueKey('session-codex')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('session-filter-claude')),
      );
      await tester.tap(find.byKey(const ValueKey('session-filter-claude')));
      await tester.pump();
      expect(find.text('没有符合条件的会话'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-filter-clear')));
      await tester.pump();
      expect(find.byKey(const ValueKey('session-current')), findsOneWidget);
      expect(selected, isFalse);
    },
  );

  testWidgets(
    'create sheet keeps project and engine after failure and blocks duplicate submission',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var calls = 0;
      final pending = Completer<void>();
      await tester.pumpWidget(
        page(
          create: (project, engine) {
            expect(project, 'p2');
            expect(engine, SessionEngine.codex);
            calls++;
            if (calls == 1) return Future<void>.error(StateError('offline'));
            return pending.future;
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('create-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('create-project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-p2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-engine-codex')));
      await tester.tap(find.byKey(const ValueKey('create-session-confirm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('新建失败'), findsOneWidget);
      expect(find.text('/work/mobile'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('session-engine-codex')),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('create-session-confirm')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('create-session-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(calls, 2);
      pending.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('create-session-confirm')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search debounces, applies server filters and discards stale results',
    (tester) async {
      final requests = <String>[];
      final first = Completer<List<RemoteSessionSearchResult>>();
      RemoteSessionSearchResult? selected;
      await tester.pumpWidget(
        page(
          selectSearch: (value) => selected = value,
          search: (query, {projectId, engine, archived}) async {
            requests.add(
              '$query:${projectId ?? 'all'}:${engine?.wireName ?? 'all'}',
            );
            return requests.length == 1
                ? first.future
                : [result('new', archived: true)];
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('session-search-field')),
        'old',
      );
      await tester.pump(const Duration(milliseconds: 299));
      expect(requests, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(requests.length, 1);
      await tester.enterText(
        find.byKey(const ValueKey('session-search-field')),
        'reconnect',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      first.complete([result('stale')]);
      await tester.pump();
      expect(find.byKey(const ValueKey('search-session-stale')), findsNothing);
      expect(
        find.textContaining('The reconnect panel is ready.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('search-session-new')));
      expect(selected?.messageIndex, 3);
      expect(selected?.archived, isTrue);
      await tester.tap(find.byKey(const ValueKey('open-project-browser')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-p2')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('session-filter-codex')),
      );
      await tester.tap(find.byKey(const ValueKey('session-filter-codex')));
      await tester.pumpAndSettle();
      expect(requests.last, 'reconnect:p2:codex');
      await tester.tap(find.byKey(const ValueKey('session-search-clear')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session-search-results')),
        findsNothing,
      );
      expect(find.text('没有符合条件的会话'), findsOneWidget);
    },
  );

  testWidgets(
    'pin and restore stay in the session center and failures remain actionable',
    (tester) async {
      String? pinned;
      String? restored;
      await tester.pumpWidget(
        page(
          sessions: [item('current'), item('archive', archived: true)],
          pin: (id, value) async {
            expect(value, true);
            pinned = id;
          },
          restore: (id) async {
            restored = id;
            throw StateError('offline');
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('session-menu-current')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect(pinned, 'current');
      expect(find.byType(SessionNavigatorPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-archive-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-menu-archive')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复会话'));
      await tester.pumpAndSettle();
      expect(restored, 'archive');
      expect(find.text('操作失败，请重试'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-archive')), findsOneWidget);
    },
  );

  testWidgets(
    'running task keeps history readable and explains unavailable mutations',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        page(running: true, select: (id) => selected = id),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('create-session')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('session-project-p2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-other')));
      expect(selected, 'other');
      await tester.tap(find.byKey(const ValueKey('session-menu-other')));
      await tester.pumpAndSettle();
      expect(find.text('任务或附件操作中，暂不能整理会话'), findsOneWidget);
      final entry = tester.widget<PopupMenuItem<dynamic>>(
        find
            .ancestor(
              of: find.text('删除'),
              matching: find.byWidgetPredicate(
                (widget) => widget is PopupMenuItem,
              ),
            )
            .first,
      );
      expect(entry.enabled, isFalse);
      await tester.tap(find.text('会话详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('消息：3 条'), findsOneWidget);
      expect(find.text('/work/mobile'), findsOneWidget);
    },
  );

  testWidgets(
    'last session deletion explains the replacement and native history scope',
    (tester) async {
      await tester.pumpWidget(page(sessions: [item('current')]));
      await tester.tap(find.byKey(const ValueKey('session-menu-current')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('自动创建一个同引擎的空白会话'), findsOneWidget);
      expect(find.textContaining('原生客户端的历史记录会保留'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('search restores the previous list position and filters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      page(
        sessions: List.generate(
          30,
          (index) => item('session-$index', updatedAt: 100 - index),
        ),
      ),
    );
    final list = find.byKey(
      const PageStorageKey('session-list-false-null-null'),
    );
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(find.byKey(const ValueKey('session-more-p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-more-p1')));
      await tester.pumpAndSettle();
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('session-session-14')),
      180,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    await tester.drag(list, const Offset(0, -650));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    final before = scroll.position.pixels;
    expect(before, greaterThan(0));
    await tester.enterText(
      find.byKey(const ValueKey('session-search-field')),
      'missing',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('session-search-clear')));
    await tester.pumpAndSettle();
    final restored = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    expect(restored.position.pixels, before);
  });

  testWidgets(
    'large text keeps compact titles and touch targets above the bottom action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        page(
          scale: 2,
          sessions: [
            item(
              'first',
              title: '正在检查发布流程中的权限请求与状态',
              running: true,
              attention: true,
            ),
            item('current', title: '修复会话切换后消息同步与草稿恢复', updatedAt: 1),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(
        const PageStorageKey('session-list-false-null-null'),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('session-current')),
        180,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(find.byTooltip('当前会话'));
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.byTooltip('当前会话')).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('create-session'))).dy,
        ),
      );
      final menu = find.byKey(const ValueKey('session-menu-current'));
      expect(tester.getSize(menu).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(menu).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.byKey(const ValueKey('session-current'))).height,
        48,
      );
      expect(find.text('1/1/1970'), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, 'large-scrolled');
    },
  );

  testWidgets(
    'missing and out of range timestamps stay unknown without breaking the list',
    (tester) async {
      await tester.pumpWidget(
        page(
          sessions: [
            item('current', updatedAt: 0),
            item('invalid', updatedAt: 9223372036854775807),
          ],
        ),
      );
      expect(find.textContaining('1970'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('session-menu-current')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会话详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('更新于：暂无记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an open session center and create sheet follow live catalog and busy changes',
    (tester) async {
      final busy = ValueNotifier(false);
      final catalog = ValueNotifier<RemoteProjectCatalog?>(null);
      addTearDown(busy.dispose);
      addTearDown(catalog.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSignalConsoleTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSessionNavigator(
                  context,
                  projects: projects,
                  sessions: [item('current')],
                  activeProjectId: 'p1',
                  activeSessionId: 'current',
                  running: false,
                  busyListenable: busy,
                  catalogListenable: catalog,
                  onSelect: (_) {},
                  onSearchResult: (_) {},
                  onCreate: (_, _) {},
                  onRename: (_, _) async {},
                  onArchive: (_) async {},
                  onRestore: (_) async {},
                  onPin: (_, _) async {},
                  onDelete: (_) async {},
                  onSearch: (_, {projectId, engine, archived}) async => [],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      catalog.value = RemoteProjectCatalog(
        activeProjectId: 'p1',
        activeSessionId: 'current',
        projects: projects,
        sessions: [item('current', title: 'updated title', pinned: true)],
      );
      await tester.pumpAndSettle();
      expect(find.text('updated title'), findsOneWidget);
      expect(find.text('置顶'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('create-session')));
      await tester.pumpAndSettle();
      busy.value = true;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('create-session-confirm')),
            )
            .onPressed,
        isNull,
      );
      busy.value = false;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('create-session-confirm')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-page-back')));
      await tester.pumpAndSettle();
    },
  );

  for (final brightness in Brightness.values) {
    for (final large in [false, true]) {
      testWidgets(
        'session center layout ${brightness.name}${large ? ' large' : ''}',
        (tester) async {
          await tester.binding.setSurfaceSize(
            large ? const Size(320, 568) : const Size(390, 844),
          );
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            page(
              brightness: brightness,
              scale: large ? 2 : 1,
              sessions: [
                item('current', title: '修复会话切换后消息同步与草稿恢复', pinned: true),
                item(
                  'waiting',
                  title: '检查发布流程中的权限请求',
                  project: 'p2',
                  attention: true,
                  running: true,
                ),
                item(
                  'today',
                  title: '会话管理页面的信息结构优化',
                  engine: SessionEngine.codex,
                ),
                item(
                  'old',
                  title: '整理 Android 客户端的历史记录',
                  updatedAt: DateTime.now()
                      .subtract(const Duration(days: 2))
                      .millisecondsSinceEpoch,
                ),
                item('other', project: 'p2', title: '优化 App 重连速度'),
              ],
            ),
          );
          await tester.pumpAndSettle();
          if (!large) {
            await tester.tap(find.byKey(const ValueKey('session-project-p2')));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          await capture(tester, brightness.name + (large ? '-large' : ''));
          if (const bool.fromEnvironment('CAPTURE_SESSION_CENTER')) {
            final shadowsDisabled = debugDisableShadows;
            try {
              // Paint the menu with real shadows before its route is cached.
              debugDisableShadows = false;
              await tester.tap(
                find.byKey(const ValueKey('session-menu-current')),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await capture(
                tester,
                '${brightness.name}-menu${large ? '-large' : ''}',
              );
              await tester.tapAt(const Offset(4, 4));
              await tester.pumpAndSettle();
            } finally {
              debugDisableShadows = shadowsDisabled;
            }
          }
          await tester.tap(find.byKey(const ValueKey('create-session')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('create-session-confirm')),
          );
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byTooltip('关闭'));
          await tester.tap(find.byTooltip('关闭'));
          await tester.pumpAndSettle();
        },
      );
    }
  }
}
