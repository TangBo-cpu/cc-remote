part of 'main.dart';

typedef SessionSearch =
    Future<List<RemoteSessionSearchResult>> Function(
      String query, {
      String? projectId,
      SessionEngine? engine,
      bool? archived,
    });

// 保留聊天区域作为返回入口，圆角外侧延续侧栏底色。
const double _sessionSidebarMaxWidth = 400;
const double _sessionSidebarChatStrip = 64;

Future<void> showSessionNavigator(
  BuildContext context, {
  required List<RemoteProjectSummary> projects,
  required List<RemoteSessionSummary> sessions,
  required String? activeProjectId,
  required String? activeSessionId,
  String? viewingSessionId,
  required bool running,
  ValueChanged<SessionEngine>? onOpenDirectory,
  VoidCallback? onSyncDesktop,
  ValueListenable<RemoteProjectCatalog?>? catalogListenable,
  ValueListenable<bool>? busyListenable,
  required ValueChanged<String> onSelect,
  required ValueChanged<RemoteSessionSearchResult> onSearchResult,
  required FutureOr<void> Function(String projectId, SessionEngine engine)
  onCreate,
  required Future<void> Function(String sessionId, String title) onRename,
  required Future<void> Function(String sessionId) onArchive,
  required Future<void> Function(String sessionId) onRestore,
  required Future<void> Function(String sessionId, bool pinned) onPin,
  required Future<void> Function(String sessionId) onDelete,
  required SessionSearch onSearch,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭会话列表',
    // Transparent barrier: the framework barrier fade marks the whole overlay
    // dirty every frame and re-renders the chat below, blurs included.
    // SheetScrim fades inside its own repaint boundary instead, and the
    // transparent barrier still catches taps on the exposed chat strip.
    barrierColor: Colors.transparent,
    transitionDuration: reduceMotion ? Duration.zero : AppMotion.standard,
    pageBuilder: (pageContext, animation, secondaryAnimation) {
      final width = MediaQuery.sizeOf(pageContext).width;
      final panelWidth = min(
        _sessionSidebarMaxWidth,
        width - _sessionSidebarChatStrip,
      );
      return Stack(
        children: [
          const SheetScrim(),
          Positioned(
            left: panelWidth,
            right: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: FadeTransition(
                opacity: animation,
                child: CustomPaint(
                  key: const ValueKey('session-sidebar-edge'),
                  painter: _SessionSidebarEdgePainter(
                    AppPalette.of(pageContext).sessionSidebar,
                    MediaQuery.paddingOf(pageContext),
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: panelWidth,
              height: double.infinity,
              // The slide transition shifts this cached layer instead of
              // re-rasterizing the panel per frame.
              child: RepaintBoundary(
                child: SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(-1, 0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: AppMotion.enter,
                        ),
                      ),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      catalogListenable,
                      busyListenable,
                    ]),
                    builder: (_, _) {
                      final catalog = catalogListenable?.value;
                      return SessionNavigatorPage(
                        projects: catalog?.projects ?? projects,
                        sessions: catalog?.sessions ?? sessions,
                        activeProjectId:
                            catalog?.activeProjectId ?? activeProjectId,
                        activeSessionId:
                            viewingSessionId ??
                            catalog?.activeSessionId ??
                            activeSessionId,
                        running: busyListenable?.value ?? running,
                        onSelect: (id) {
                          Navigator.pop(pageContext);
                          onSelect(id);
                        },
                        onSearchResult: (result) {
                          Navigator.pop(pageContext);
                          onSearchResult(result);
                        },
                        onCreate: onCreate,
                        busyListenable: busyListenable,
                        onOpenDirectory: onOpenDirectory == null
                            ? null
                            : (engine) {
                                Navigator.pop(pageContext);
                                onOpenDirectory(engine);
                              },
                        onRename: onRename,
                        onSyncDesktop: onSyncDesktop == null
                            ? null
                            : () {
                                Navigator.pop(pageContext);
                                onSyncDesktop();
                              },
                        onArchive: onArchive,
                        onRestore: onRestore,
                        onPin: onPin,
                        onDelete: onDelete,
                        onSearch: onSearch,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
    // The panel slides itself through the route animation above; the default
    // material dialog fade would double-animate it.
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}

enum _SessionAction { details, pin, rename, archive, restore, delete }

enum _SessionNavigatorAction { engine, archive, close }

class _SessionSidebarEdgePainter extends CustomPainter {
  const _SessionSidebarEdgePainter(this.color, this.padding);

  final Color color;
  final EdgeInsets padding;

  @override
  void paint(Canvas canvas, Size size) {
    final chat = RRect.fromRectAndCorners(
      Rect.fromLTRB(0, padding.top, size.width, size.height - padding.bottom),
      topLeft: const Radius.circular(28),
      bottomLeft: const Radius.circular(28),
    );
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(chat),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SessionSidebarEdgePainter oldDelegate) =>
      color != oldDelegate.color || padding != oldDelegate.padding;
}

/// Persistent left rail for expanded windows (tablets). It reuses the modal
/// sidebar's page; unlike [showSessionNavigator] nothing pops on selection —
/// the rail stays mounted beside the chat.
class SessionRail extends StatelessWidget {
  const SessionRail({
    super.key,
    required this.projects,
    required this.sessions,
    required this.activeProjectId,
    required this.activeSessionId,
    this.viewingSessionId,
    required this.running,
    required this.onClose,
    this.onOpenDirectory,
    this.onSyncDesktop,
    this.catalogListenable,
    this.busyListenable,
    required this.onSelect,
    required this.onSearchResult,
    required this.onCreate,
    required this.onRename,
    required this.onArchive,
    required this.onRestore,
    required this.onPin,
    required this.onDelete,
    required this.onSearch,
    this.width = kSessionRailWidth,
  });

  static const double kSessionRailWidth = 360;

  final List<RemoteProjectSummary> projects;
  final List<RemoteSessionSummary> sessions;
  final String? activeProjectId;
  final String? activeSessionId;
  final String? viewingSessionId;
  final bool running;
  final ValueChanged<SessionEngine>? onOpenDirectory;
  final VoidCallback? onSyncDesktop;
  final ValueListenable<RemoteProjectCatalog?>? catalogListenable;
  final ValueListenable<bool>? busyListenable;
  final ValueChanged<String> onSelect;
  final ValueChanged<RemoteSessionSearchResult> onSearchResult;
  final FutureOr<void> Function(String projectId, SessionEngine engine)
  onCreate;
  final Future<void> Function(String sessionId, String title) onRename;
  final Future<void> Function(String sessionId) onArchive;
  final Future<void> Function(String sessionId) onRestore;
  final Future<void> Function(String sessionId, bool pinned) onPin;
  final Future<void> Function(String sessionId) onDelete;
  final SessionSearch onSearch;
  final double width;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      color: palette.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: palette.line, width: 1)),
        ),
        child: SizedBox(
          width: width,
          child: RepaintBoundary(
            child: ListenableBuilder(
              listenable: Listenable.merge([catalogListenable, busyListenable]),
              builder: (_, _) => SessionNavigatorPage(
                onClose: onClose,
                projects: catalogListenable?.value?.projects ?? projects,
                sessions: catalogListenable?.value?.sessions ?? sessions,
                activeProjectId:
                    catalogListenable?.value?.activeProjectId ??
                    activeProjectId,
                activeSessionId:
                    viewingSessionId ??
                    catalogListenable?.value?.activeSessionId ??
                    activeSessionId,
                running: busyListenable?.value ?? running,
                busyListenable: busyListenable,
                onSelect: onSelect,
                onSearchResult: onSearchResult,
                onCreate: onCreate,
                onOpenDirectory: onOpenDirectory,
                onSyncDesktop: onSyncDesktop,
                onRename: onRename,
                onArchive: onArchive,
                onRestore: onRestore,
                onPin: onPin,
                onDelete: onDelete,
                onSearch: onSearch,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SessionNavigatorPage extends StatefulWidget {
  const SessionNavigatorPage({
    super.key,
    required this.projects,
    required this.sessions,
    required this.activeProjectId,
    required this.activeSessionId,
    required this.running,
    required this.onSelect,
    required this.onSearchResult,
    required this.onCreate,
    required this.onRename,
    required this.onArchive,
    required this.onRestore,
    required this.onPin,
    required this.onDelete,
    required this.onSearch,
    this.onOpenDirectory,
    this.onSyncDesktop,
    this.busyListenable,
    this.onClose,
  });

  final List<RemoteProjectSummary> projects;
  final List<RemoteSessionSummary> sessions;
  final String? activeProjectId;
  final String? activeSessionId;
  final bool running;
  final ValueChanged<String> onSelect;
  final ValueChanged<RemoteSessionSearchResult> onSearchResult;
  final FutureOr<void> Function(String projectId, SessionEngine engine)
  onCreate;
  final Future<void> Function(String sessionId, String title) onRename;
  final Future<void> Function(String sessionId) onArchive;
  final Future<void> Function(String sessionId) onRestore;
  final Future<void> Function(String sessionId, bool pinned) onPin;
  final Future<void> Function(String sessionId) onDelete;
  final SessionSearch onSearch;
  final ValueChanged<SessionEngine>? onOpenDirectory;
  final VoidCallback? onSyncDesktop;
  final ValueListenable<bool>? busyListenable;
  final VoidCallback? onClose;

  @override
  State<SessionNavigatorPage> createState() => _SessionNavigatorPageState();
}

class _SessionNavigatorPageState extends State<SessionNavigatorPage> {
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  Timer? searchDebounce;
  int searchGeneration = 0;
  String searchQuery = '';
  String? projectFilter;
  bool searchOpen = false;
  bool projectsOpen = false;
  SessionEngine? engineFilter;
  bool showArchived = false;
  bool searching = false;
  String? searchError;
  String? mutatingId;

  // Sidebar panels sit above the chat Scaffold, so a SnackBar there would be
  // hidden behind the panel; mutation failures report inline instead.
  String? mutationError;
  List<RemoteSessionSearchResult> searchResults = const [];
  List<RemoteSessionSummary>? filteredSessions;
  List<RemoteSessionSummary> pinnedSessions = [];
  List<RemoteSessionSummary> unpinnedSessions = [];
  Map<String, RemoteProjectSummary>? projectIndex;
  Map<String, int>? unarchivedSessionCounts;

  @override
  void initState() {
    super.initState();
    projectFilter = widget.activeProjectId;
  }

  Map<String, RemoteProjectSummary> get projectsById => projectIndex ??= {
    for (final project in widget.projects) project.id: project,
  };

  Map<String, int> get activeSessionCounts {
    if (unarchivedSessionCounts != null) return unarchivedSessionCounts!;
    final counts = <String, int>{};
    for (final session in widget.sessions) {
      if (!session.archived) {
        counts[session.projectId] = (counts[session.projectId] ?? 0) + 1;
      }
    }
    return unarchivedSessionCounts = counts;
  }

  @override
  void didUpdateWidget(covariant SessionNavigatorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    filteredSessions = null;
    projectIndex = null;
    unarchivedSessionCounts = null;
    if (projectFilter != null &&
        !widget.projects.any((project) => project.id == projectFilter)) {
      projectFilter = null;
      if (searchQuery.isNotEmpty) {
        searchChanged(searchController.text, immediate: true);
      }
    }
  }

  bool get busy =>
      (widget.busyListenable?.value ?? widget.running) || mutatingId != null;
  SessionEngine get activeEngine =>
      widget.sessions
          .where((item) => item.id == widget.activeSessionId)
          .firstOrNull
          ?.engine ??
      SessionEngine.claude;

  @override
  void dispose() {
    searchGeneration++;
    searchDebounce?.cancel();
    searchController.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  String projectName(String? id) =>
      id == null ? '全部项目' : projectsById[id]?.name ?? '未知项目';

  void searchChanged(String value, {bool immediate = false}) {
    searchDebounce?.cancel();
    final query = value.trim();
    final generation = ++searchGeneration;
    setState(() {
      searchQuery = query;
      searching = query.isNotEmpty;
      searchError = null;
      searchResults = const [];
    });
    if (query.isEmpty) return;
    if (immediate) {
      unawaited(runSearch(query, generation));
    } else {
      searchDebounce = Timer(
        const Duration(milliseconds: 300),
        () => runSearch(query, generation),
      );
    }
  }

  Future<void> runSearch(String query, int generation) async {
    try {
      final results = await widget.onSearch(
        query,
        projectId: projectFilter,
        engine: engineFilter,
        archived: showArchived ? true : null,
      );
      if (!mounted || generation != searchGeneration) return;
      setState(() {
        searchResults = results;
        searching = false;
      });
    } catch (_) {
      if (!mounted || generation != searchGeneration) return;
      setState(() {
        searching = false;
        searchError = '搜索失败，请重试';
      });
    }
  }

  void updateFilters(VoidCallback update) {
    setState(() {
      update();
      filteredSessions = null;
    });
    if (searchQuery.isNotEmpty) {
      searchChanged(searchController.text, immediate: true);
    }
  }

  Future<String?> pickProject({
    required String? selected,
    required bool allowAll,
  }) {
    return showAppOptionPicker<String>(
      context,
      builder: (sheetContext) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppOptionSheetHeader(title: '选择项目'),
          const SizedBox(height: 12),
          if (allowAll)
            AppOptionRow(
              key: const ValueKey('project-all'),
              leading: const Icon(PhosphorIconsRegular.folders),
              title: '所有项目',
              description: '',
              boxedLeading: false,
              showDisclosure: false,
              selected: selected == null,
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
          for (final project in widget.projects)
            AppOptionRow(
              key: ValueKey('project-${project.id}'),
              boxedLeading: false,
              showDisclosure: false,
              leading: const Icon(PhosphorIconsRegular.folder),
              title: project.name,
              description: project.path,
              selected: selected == project.id,
              onTap: () => Navigator.pop(sheetContext, project.id),
            ),
        ],
      ),
    );
  }

  Future<void> chooseProjectFilter() async {
    searchFocus.unfocus();
    setState(() => projectsOpen = true);
  }

  Future<void> createSession() async {
    if (busy || widget.projects.isEmpty) return;
    searchFocus.unfocus();
    var projectId =
        projectFilter ?? widget.activeProjectId ?? widget.projects.first.id;
    var engine = activeEngine;
    var creating = false;
    String? error;
    final created = await showAppOptionPicker<bool>(
      context,
      requestFocus: false,
      scrollContent: false,
      builder: (sheetContext) => ListenableBuilder(
        listenable: Listenable.merge([widget.busyListenable]),
        builder: (_, _) => StatefulBuilder(
          builder: (sheetContext, update) {
            final project = widget.projects
                .where((item) => item.id == projectId)
                .firstOrNull;
            return PopScope(
              canPop: !creating,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  4,
                  8,
                  4,
                  12 + MediaQuery.viewInsetsOf(sheetContext).bottom,
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '新建会话',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: creating
                                ? null
                                : () => Navigator.pop(sheetContext),
                            icon: const Icon(PhosphorIconsRegular.x),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text('项目'),
                      AppOptionRow(
                        key: const ValueKey('create-project-picker'),
                        selected: false,
                        enabled: !creating,
                        title: project?.name ?? '选择项目',
                        description: project?.path ?? '',
                        boxedLeading: false,
                        leading: const Icon(PhosphorIconsRegular.folder),
                        onTap: creating
                            ? null
                            : () async {
                                final next = await pickProject(
                                  selected: projectId,
                                  allowAll: false,
                                );
                                if (next != null && sheetContext.mounted) {
                                  update(() => projectId = next);
                                }
                              },
                      ),
                      if (widget.onOpenDirectory != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('open-computer-directory'),
                            onPressed: creating
                                ? null
                                : () {
                                    Navigator.pop(sheetContext);
                                    widget.onOpenDirectory!(engine);
                                  },
                            icon: const Icon(
                              PhosphorIconsRegular.folderOpen,
                              size: 18,
                            ),
                            label: const Text('打开电脑目录'),
                          ),
                        ),
                      const SizedBox(height: 16),
                      const Text('引擎'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in SessionEngine.values)
                            ChoiceChip(
                              key: ValueKey(
                                'session-engine-${option.wireName}',
                              ),
                              label: Text(option.displayName),
                              selected: engine == option,
                              onSelected: creating
                                  ? null
                                  : (_) => update(() => engine = option),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                            ),
                        ],
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              error!,
                              style: TextStyle(
                                color: AppPalette.of(context).danger,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const ValueKey('create-session-confirm'),
                        onPressed: creating || busy
                            ? null
                            : () async {
                                if (creating || busy) return;
                                update(() {
                                  creating = true;
                                  error = null;
                                });
                                try {
                                  await widget.onCreate(projectId, engine);
                                  if (sheetContext.mounted) {
                                    Navigator.pop(sheetContext, true);
                                  }
                                } catch (_) {
                                  if (sheetContext.mounted) {
                                    update(() {
                                      creating = false;
                                      error = '新建失败，请重试。所选项目与引擎已保留。';
                                    });
                                  }
                                }
                              },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(creating ? '正在新建…' : '新建会话'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    if (created == true &&
        mounted &&
        widget.onClose == null &&
        Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> handleAction(
    RemoteSessionSummary item,
    _SessionAction action,
  ) async {
    if (action == _SessionAction.details) {
      await showAppOptionPicker<void>(
        context,
        builder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
              item.title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            SelectableText(
              '项目：${projectName(item.projectId)}\n引擎：${item.engine.displayName}\n模型：${item.model == null ? '暂无信息' : formatModelName(item.model!)}\n消息：${item.messageCount} 条\n更新于：${updatedDate(item.updatedAt)?.toString().split('.').first ?? '暂无记录'}',
            ),
            const SizedBox(height: 16),
            SelectableText(
              widget.projects
                      .where((project) => project.id == item.projectId)
                      .firstOrNull
                      ?.path ??
                  '项目路径不可用',
            ),
            if (item.preview?.isNotEmpty == true) ...[
              const SizedBox(height: 16),
              SelectableText('最近消息：${item.preview}'),
            ],
          ],
        ),
      );
      return;
    }
    if (busy || item.running) return;
    String? title;
    if (action == _SessionAction.rename) {
      title = await promptSessionTitle(context, initial: item.title);
      if (!mounted || title == null || title.trim().isEmpty) return;
    }
    if (action == _SessionAction.delete) {
      final last = !item.archived && activeSessionCounts[item.projectId] == 1;
      if (await confirmSessionDelete(context, item.title, lastSession: last) !=
              true ||
          !mounted) {
        return;
      }
    }
    if (busy) return;
    setState(() {
      mutatingId = item.id;
      mutationError = null;
    });
    try {
      switch (action) {
        case _SessionAction.details:
          return;
        case _SessionAction.pin:
          await widget.onPin(item.id, !item.pinned);
        case _SessionAction.rename:
          await widget.onRename(item.id, title!);
        case _SessionAction.archive:
          await widget.onArchive(item.id);
        case _SessionAction.restore:
          await widget.onRestore(item.id);
        case _SessionAction.delete:
          await widget.onDelete(item.id);
      }
      if (!mounted) return;
      if (searchQuery.isNotEmpty) {
        searchChanged(searchController.text, immediate: true);
      }
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        mutationError = failure.toString().contains('last_session')
            ? '项目至少需要保留一个未归档会话'
            : '操作失败，请重试';
      });
    } finally {
      if (mounted) setState(() => mutatingId = null);
    }
  }

  Widget sessionMenuLabel(
    IconData icon,
    String label, {
    bool enabled = true,
    bool danger = false,
  }) {
    final palette = AppPalette.of(context);
    return Row(
      children: [
        Icon(
          icon,
          size: AppIconSizes.control,
          color: !enabled
              ? palette.muted.withValues(alpha: 0.42)
              : danger
              ? palette.danger
              : palette.muted,
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            style: danger && enabled ? TextStyle(color: palette.danger) : null,
          ),
        ),
      ],
    );
  }

  PopupMenuButton<_SessionAction> sessionMenu(RemoteSessionSummary item) {
    final palette = AppPalette.of(context);
    return PopupMenuButton<_SessionAction>(
      key: ValueKey('session-menu-${item.id}'),
      tooltip: '${item.title} 的更多操作',
      icon: Icon(
        PhosphorIconsRegular.dotsThree,
        size: 24,
        color: palette.muted,
      ),
      onSelected: (action) => unawaited(handleAction(item, action)),
      itemBuilder: (_) => sessionMenuItems(item),
    );
  }

  Future<void> showSessionActions(
    RemoteSessionSummary item, {
    Offset? position,
  }) async {
    if (mutatingId != null) return;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final point =
        position ?? overlay.localToGlobal(overlay.size.center(Offset.zero));
    final local = overlay.globalToLocal(point);
    final action = await showMenu<_SessionAction>(
      context: context,
      position: RelativeRect.fromSize(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        overlay.size,
      ),
      items: sessionMenuItems(item),
    );
    if (mounted && action != null) await handleAction(item, action);
  }

  List<PopupMenuEntry<_SessionAction>> sessionMenuItems(
    RemoteSessionSummary item,
  ) {
    final canMutate = !busy && !item.running;
    final canArchive = (activeSessionCounts[item.projectId] ?? 0) > 1;
    return [
      PopupMenuItem(
        value: _SessionAction.details,
        child: sessionMenuLabel(PhosphorIconsRegular.info, '会话详情'),
      ),
      if (!canMutate)
        const PopupMenuItem(enabled: false, child: Text('任务或附件操作中，暂不能整理会话')),
      PopupMenuItem(
        value: _SessionAction.pin,
        enabled: canMutate,
        child: sessionMenuLabel(
          item.pinned
              ? PhosphorIconsRegular.pushPinSlash
              : PhosphorIconsRegular.pushPin,
          item.pinned ? '取消置顶' : '置顶',
          enabled: canMutate,
        ),
      ),
      PopupMenuItem(
        value: _SessionAction.rename,
        enabled: canMutate,
        child: sessionMenuLabel(
          PhosphorIconsRegular.pencilSimple,
          '重命名',
          enabled: canMutate,
        ),
      ),
      if (item.archived)
        PopupMenuItem(
          value: _SessionAction.restore,
          enabled: canMutate,
          child: sessionMenuLabel(
            PhosphorIconsRegular.arrowUUpLeft,
            '恢复会话',
            enabled: canMutate,
          ),
        )
      else
        PopupMenuItem(
          value: _SessionAction.archive,
          enabled: canMutate && canArchive,
          child: sessionMenuLabel(
            PhosphorIconsRegular.archive,
            canArchive ? '归档' : '至少保留一个未归档会话',
            enabled: canMutate && canArchive,
          ),
        ),
      PopupMenuItem(
        value: _SessionAction.delete,
        enabled: canMutate,
        child: sessionMenuLabel(
          PhosphorIconsRegular.trash,
          '删除',
          enabled: canMutate,
          danger: true,
        ),
      ),
    ];
  }

  DateTime? updatedDate(int timestamp) {
    if (timestamp <= 0) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } on RangeError {
      return null;
    }
  }

  Widget sessionRow(RemoteSessionSummary item) {
    final palette = AppPalette.of(context);
    final active = item.id == widget.activeSessionId;
    final status = item.needsAttention
        ? '等待授权'
        : item.running
        ? '运行中'
        : null;
    return Semantics(
      selected: active,
      label:
          '${projectName(item.projectId)}，${item.engine.label}'
          '${item.archived ? '，已归档，只读查看' : ''}',
      customSemanticsActions: {
        const CustomSemanticsAction(label: '会话操作'): () =>
            showSessionActions(item),
      },
      child: Tooltip(
        message: active ? '当前会话' : item.title,
        child: Material(
          color: active ? palette.sessionSelection : Colors.transparent,
          elevation: active ? 0.5 : 0,
          shadowColor: Colors.black.withValues(alpha: 0.12),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
            side: BorderSide(
              color: active
                  ? MediaQuery.highContrastOf(context)
                        ? palette.ink
                        : palette.bubbleOutline
                  : Colors.transparent,
              width: MediaQuery.highContrastOf(context) ? 1 : 0.5,
            ),
          ),
          child: GestureDetector(
            onSecondaryTapDown: (details) =>
                showSessionActions(item, position: details.globalPosition),
            child: InkWell(
              key: ValueKey('session-${item.id}'),
              borderRadius: BorderRadius.circular(AppRadii.control),
              onTap: mutatingId == null ? () => widget.onSelect(item.id) : null,
              onLongPress: mutatingId == null
                  ? () => showSessionActions(item)
                  : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, right: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 17,
                                  height: 1.4,
                                  fontWeight: active
                                      ? FontWeight.w500
                                      : FontWeight.w400,
                                ),
                              ),
                              if (projectFilter == null)
                                Text(
                                  projectName(item.projectId),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: palette.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (status != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Tooltip(
                            message: status,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  item.needsAttention
                                      ? PhosphorIconsRegular.shield
                                      : PhosphorIconsRegular.clock,
                                  size: 16,
                                  color: item.needsAttention
                                      ? palette.warning
                                      : palette.link,
                                ),
                                if (item.needsAttention) ...[
                                  const SizedBox(width: 4),
                                  Text(
                                    '待授权',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: palette.warning,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      if (active)
                        SizedBox.square(
                          dimension: AppSizes.touchTarget,
                          child: sessionMenu(item),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget sectionTitle(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 20, 8, 10),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: AppPalette.of(context).muted,
        ),
      ),
    ),
  );

  Widget emptyState(String title, String description, {bool clear = false}) =>
      ListView(
        padding: const EdgeInsets.fromLTRB(8, 24, 8, 24),
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(fontSize: 13, color: AppPalette.of(context).muted),
          ),
          if (clear)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('session-filter-clear'),
                onPressed: () => updateFilters(() {
                  projectFilter = null;
                  engineFilter = null;
                }),
                child: const Text('清除筛选'),
              ),
            ),
        ],
      );

  Widget sessionList() {
    if (filteredSessions == null) {
      final sessions =
          widget.sessions
              .where(
                (item) =>
                    item.archived == showArchived &&
                    (projectFilter == null ||
                        item.projectId == projectFilter) &&
                    (engineFilter == null || item.engine == engineFilter),
              )
              .toList()
            ..sort((a, b) {
              final order = b.updatedAt.compareTo(a.updatedAt);
              return order != 0 ? order : a.id.compareTo(b.id);
            });
      filteredSessions = sessions;
      pinnedSessions = sessions.where((item) => item.pinned).toList();
      unpinnedSessions = sessions.where((item) => !item.pinned).toList();
    }
    final sessions = filteredSessions!;
    if (sessions.isEmpty) {
      return emptyState(
        showArchived ? '没有已归档的会话' : '没有符合条件的会话',
        showArchived ? '归档后会话会保留在这里，可随时查看或恢复。' : '试试其他筛选条件，或新建会话。',
        clear: projectFilter != null || engineFilter != null,
      );
    }
    final rows = <Widget Function()>[];
    if (showArchived) {
      rows.addAll(
        sessions.map(
          (item) =>
              () => sessionRow(item),
        ),
      );
    } else {
      if (pinnedSessions.isNotEmpty) {
        rows.add(() => sectionTitle('置顶'));
        rows.addAll(
          pinnedSessions.map(
            (item) =>
                () => sessionRow(item),
          ),
        );
      }
      if (unpinnedSessions.isNotEmpty) {
        rows.add(() => sectionTitle('最近'));
        rows.addAll(
          unpinnedSessions.map(
            (item) =>
                () => sessionRow(item),
          ),
        );
      }
    }
    return ListView.builder(
      key: PageStorageKey(
        'session-list-$showArchived-$projectFilter-$engineFilter${searchOpen ? '-search' : ''}',
      ),
      padding: const EdgeInsets.only(bottom: 20),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: rows.length,
      itemBuilder: (_, index) => rows[index](),
    );
  }

  Widget highlightedSnippet(RemoteSessionSearchResult result) {
    final start = result.matchStart.clamp(0, result.snippet.length);
    final end = result.matchEnd.clamp(start, result.snippet.length);
    final palette = AppPalette.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: result.snippet.substring(0, start)),
          TextSpan(
            text: result.snippet.substring(start, end),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              backgroundColor: palette.navigatorAccent.withValues(alpha: 0.12),
            ),
          ),
          TextSpan(text: result.snippet.substring(end)),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 13, height: 1.4, color: palette.ink),
    );
  }

  Widget searchBody() {
    if (searching) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: '正在搜索会话'),
      );
    }
    if (searchError != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(searchError!),
          TextButton(
            onPressed: () =>
                searchChanged(searchController.text, immediate: true),
            child: const Text('重试'),
          ),
        ],
      );
    }
    if (searchResults.isEmpty) {
      return emptyState('没有找到匹配内容', '试试会话标题或消息关键词，也可以调整项目与引擎筛选。');
    }
    return ListView.separated(
      key: const PageStorageKey('session-search-results'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(top: 12, bottom: 20),
      itemCount: searchResults.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, index) {
        final result = searchResults[index];
        return ListTile(
          key: ValueKey('search-session-${result.sessionId}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          title: Text(
            result.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),
              highlightedSnippet(result),
              const SizedBox(height: 6),
              Text(
                '${projectName(result.projectId)} · ${result.engine.label} · ${result.matchCount} 条匹配内容'
                '${result.archived ? ' · 已归档，只读查看' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: AppPalette.of(context).muted,
                ),
              ),
            ],
          ),
          onTap: mutatingId == null
              ? () => widget.onSearchResult(result)
              : null,
        );
      },
    );
  }

  void closeSearch() {
    searchFocus.unfocus();
    searchController.clear();
    searchChanged('');
    setState(() => searchOpen = false);
  }

  void openSearch() {
    setState(() => searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && searchOpen) searchFocus.requestFocus();
    });
  }

  Future<void> chooseEngineFilter() async {
    searchFocus.unfocus();
    final value = await showAppOptionPicker<String>(
      context,
      builder: (sheetContext) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppOptionSheetHeader(title: '筛选引擎'),
          for (final engine in <SessionEngine?>[null, ...SessionEngine.values])
            AppOptionRow(
              key: ValueKey('session-filter-${engine?.wireName ?? 'all'}'),
              title: engine?.displayName ?? '全部引擎',
              description: '',
              boxedLeading: false,
              showDisclosure: false,
              selected: engineFilter == engine,
              onTap: () => Navigator.pop(sheetContext, engine?.wireName ?? ''),
            ),
        ],
      ),
    );
    if (!mounted || value == null) return;
    updateFilters(
      () => engineFilter = SessionEngine.values
          .where((engine) => engine.wireName == value)
          .firstOrNull,
    );
  }

  Widget navigatorMenu() => PopupMenuButton<_SessionNavigatorAction>(
    key: const ValueKey('session-options-menu'),
    tooltip: '更多会话选项',
    enabled: mutatingId == null,
    icon: Icon(
      PhosphorIconsRegular.dotsThree,
      size: 28,
      color: AppPalette.of(context).muted,
    ),
    onSelected: (action) {
      switch (action) {
        case _SessionNavigatorAction.engine:
          unawaited(chooseEngineFilter());
        case _SessionNavigatorAction.archive:
          closeSearch();
          updateFilters(() => showArchived = !showArchived);
        case _SessionNavigatorAction.close:
          if (widget.onClose != null) {
            widget.onClose!();
          } else {
            Navigator.pop(context);
          }
      }
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        key: const ValueKey('session-engine-filter'),
        value: _SessionNavigatorAction.engine,
        child: sessionMenuLabel(PhosphorIconsRegular.funnelSimple, '筛选引擎'),
      ),
      PopupMenuItem(
        key: const ValueKey('session-archive-toggle'),
        value: _SessionNavigatorAction.archive,
        child: sessionMenuLabel(
          PhosphorIconsRegular.archive,
          showArchived ? '最近会话' : '已归档会话',
        ),
      ),
      PopupMenuItem(
        key: const ValueKey('session-drawer-close'),
        value: _SessionNavigatorAction.close,
        child: sessionMenuLabel(PhosphorIconsRegular.x, '收起会话列表'),
      ),
    ],
  );

  Widget navigationRow({
    required Key key,
    required IconData icon,
    required String title,
    VoidCallback? onTap,
    bool disclosure = false,
  }) => InkWell(
    key: key,
    onTap: onTap,
    borderRadius: BorderRadius.circular(AppRadii.control),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 54),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Icon(
              icon,
              size: 24,
              color: onTap == null
                  ? AppPalette.of(context).inactive
                  : AppPalette.of(context).messageMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  height: 1.35,
                  color: onTap == null ? AppPalette.of(context).inactive : null,
                ),
              ),
            ),
            if (disclosure)
              Icon(
                PhosphorIconsRegular.caretRight,
                size: 14,
                color: AppPalette.of(context).muted,
              ),
          ],
        ),
      ),
    ),
  );

  Widget projectBrowser() {
    final palette = AppPalette.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
          child: Text(
            '查看哪个项目的会话',
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
        ),
        for (final project in <RemoteProjectSummary?>[null, ...widget.projects])
          Material(
            color: projectFilter == project?.id
                ? palette.sessionSelection
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.control),
            child: ListTile(
              key: ValueKey('project-${project?.id ?? 'all'}'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              leading: Icon(
                project == null
                    ? PhosphorIconsRegular.folders
                    : PhosphorIconsRegular.folder,
                size: 24,
                color: palette.messageMuted,
              ),
              title: Text(
                project?.name ?? '全部项目',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: project == null
                  ? null
                  : Text(
                      project.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
              trailing: projectFilter == project?.id
                  ? Icon(
                      PhosphorIconsRegular.check,
                      size: 18,
                      color: palette.link,
                    )
                  : null,
              onTap: () => updateFilters(() {
                projectFilter = project?.id;
                projectsOpen = false;
              }),
            ),
          ),
      ],
    );
  }

  Widget header() {
    if (projectsOpen || searchOpen || showArchived) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 14, 12),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('session-view-back'),
              tooltip: '返回会话列表',
              onPressed: mutatingId != null
                  ? null
                  : () {
                      if (projectsOpen) {
                        setState(() => projectsOpen = false);
                      } else if (searchOpen) {
                        closeSearch();
                      } else {
                        updateFilters(() => showArchived = false);
                      }
                    },
              icon: const Icon(PhosphorIconsRegular.caretLeft),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: searchOpen && !projectsOpen
                  ? TextField(
                      key: const ValueKey('session-search-field'),
                      controller: searchController,
                      focusNode: searchFocus,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(fontSize: 16),
                      onChanged: searchChanged,
                      onSubmitted: (value) =>
                          searchChanged(value, immediate: true),
                      decoration: InputDecoration(
                        hintText: '搜索标题与消息',
                        filled: false,
                        border: const UnderlineInputBorder(),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: AppPalette.of(context).lineStrong,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 4,
                        ),
                        suffixIcon: searchController.text.isEmpty
                            ? null
                            : IconButton(
                                key: const ValueKey('session-search-clear'),
                                tooltip: '清除搜索',
                                onPressed: () {
                                  searchController.clear();
                                  searchChanged('');
                                },
                                icon: const Icon(
                                  PhosphorIconsRegular.x,
                                  size: 18,
                                ),
                              ),
                      ),
                    )
                  : Text(
                      projectsOpen ? '选择项目' : '已归档',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
            if (!searchOpen && !projectsOpen) navigatorMenu(),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: const Text(
                'CC Remote',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.5,
                ),
              ),
            ),
          ),
          navigatorMenu(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop:
          mutatingId == null && !projectsOpen && !searchOpen && !showArchived,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || mutatingId != null) return;
        if (projectsOpen) {
          setState(() => projectsOpen = false);
        } else if (searchOpen) {
          closeSearch();
        } else if (showArchived) {
          updateFilters(() => showArchived = false);
        }
      },
      child: Material(
        key: const ValueKey('session-navigator-page'),
        color: palette.sessionSidebar,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header(),
                if (projectsOpen)
                  Expanded(child: projectBrowser())
                else ...[
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (searchOpen)
                            Row(
                              children: [
                                Expanded(
                                  child: TextButton(
                                    key: const ValueKey('open-project-browser'),
                                    onPressed: mutatingId == null
                                        ? chooseProjectFilter
                                        : null,
                                    style: TextButton.styleFrom(
                                      alignment: Alignment.centerLeft,
                                      foregroundColor: palette.muted,
                                    ),
                                    child: Text(
                                      projectName(projectFilter),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  key: const ValueKey('session-engine-filter'),
                                  onPressed: mutatingId == null
                                      ? chooseEngineFilter
                                      : null,
                                  icon: const Icon(
                                    PhosphorIconsRegular.funnelSimple,
                                    size: 16,
                                  ),
                                  label: Text(
                                    engineFilter?.displayName ?? '全部引擎',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            )
                          else ...[
                            const SizedBox(height: 4),
                            navigationRow(
                              key: const ValueKey('session-search-open'),
                              icon: PhosphorIconsRegular.magnifyingGlass,
                              title: '搜索会话',
                              onTap: mutatingId == null ? openSearch : null,
                            ),
                            navigationRow(
                              key: const ValueKey('open-project-browser'),
                              icon: PhosphorIconsRegular.folder,
                              title: projectName(projectFilter),
                              onTap: mutatingId == null
                                  ? chooseProjectFilter
                                  : null,
                              disclosure: true,
                            ),
                            if (widget.onSyncDesktop != null)
                              navigationRow(
                                key: const ValueKey(
                                  'open-native-session-picker',
                                ),
                                icon: PhosphorIconsRegular.arrowsClockwise,
                                title: '同步电脑会话',
                                onTap: busy ? null : widget.onSyncDesktop,
                              ),
                            const SizedBox(height: 12),
                            if (engineFilter != null)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  key: const ValueKey('session-engine-clear'),
                                  onPressed: () =>
                                      updateFilters(() => engineFilter = null),
                                  icon: const Icon(
                                    PhosphorIconsRegular.x,
                                    size: 14,
                                  ),
                                  label: Text(
                                    engineFilter!.displayName,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ),
                          ],
                          if (widget.running)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                              child: Text(
                                '任务或附件操作中，暂不能新建或整理会话。',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                          if (mutationError != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  mutationError!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: palette.danger,
                                  ),
                                ),
                              ),
                            ),
                          Expanded(
                            child: searchQuery.isEmpty
                                ? sessionList()
                                : searchBody(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!keyboardOpen && !searchOpen)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                        child: SignalPressEffect(
                          enabled: !busy && widget.projects.isNotEmpty,
                          child: FilledButton.icon(
                            key: const ValueKey('create-session'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 50),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              elevation: 2,
                              shadowColor: Colors.black.withValues(alpha: 0.18),
                              surfaceTintColor: Colors.transparent,
                              shape: StadiumBorder(
                                side: BorderSide(
                                  color: palette.onCta.withValues(alpha: 0.14),
                                  width: 0.5,
                                ),
                              ),
                              textStyle: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0,
                                  ),
                            ),
                            onPressed: busy || widget.projects.isEmpty
                                ? null
                                : createSession,
                            icon: const Icon(
                              PhosphorIconsRegular.plus,
                              size: 20,
                            ),
                            label: const Text('新建会话'),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
