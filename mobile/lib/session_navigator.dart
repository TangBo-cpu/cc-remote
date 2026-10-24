part of 'main.dart';

typedef SessionSearch =
    Future<List<RemoteSessionSearchResult>> Function(
      String query, {
      String? projectId,
      SessionEngine? engine,
      bool? archived,
    });

// Sidebar geometry, following CherryStudio's mobile drawer: the panel stops
// short of the right edge so a strip of chat stays exposed beside it. The
// strip keeps the user's place visible and tapping it (or the scrim) closes
// the sidebar.
const double _sessionSidebarMaxWidth = 400;
const double _sessionSidebarChatStrip = 64;

Future<void> showSessionNavigator(
  BuildContext context, {
  required List<RemoteProjectSummary> projects,
  required List<RemoteSessionSummary> sessions,
  required String? activeProjectId,
  required String? activeSessionId,
  required bool running,
  ValueChanged<SessionEngine>? onOpenDirectory,
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
      return Stack(
        children: [
          const SheetScrim(),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: min(
                _sessionSidebarMaxWidth,
                width - _sessionSidebarChatStrip,
              ),
              height: double.infinity,
              // The slide transition shifts this cached layer instead of
              // re-rasterizing the panel per frame.
              child: RepaintBoundary(
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(-1, 0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(parent: animation, curve: AppMotion.enter),
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
                            catalog?.activeSessionId ?? activeSessionId,
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
    this.busyListenable,
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
  final ValueListenable<bool>? busyListenable;

  @override
  State<SessionNavigatorPage> createState() => _SessionNavigatorPageState();
}

class _SessionNavigatorPageState extends State<SessionNavigatorPage> {
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  final filterScroll = ScrollController();
  Timer? searchDebounce;
  int searchGeneration = 0;
  String searchQuery = '';
  String? projectFilter;
  SessionEngine? engineFilter;
  bool showArchived = false;
  bool searching = false;
  String? searchError;
  String? mutatingId;

  // Sidebar panels sit above the chat Scaffold, so a SnackBar there would be
  // hidden behind the panel; mutation failures report inline instead.
  String? mutationError;
  List<RemoteSessionSearchResult> searchResults = const [];
  late final Set<String> expandedProjects = {
    if (widget.activeProjectId != null) widget.activeProjectId!,
  };
  final visibleCounts = <String, int>{};
  bool recentExpanded = false;

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
    filterScroll.dispose();
    super.dispose();
  }

  String projectName(String? id) => id == null
      ? '所有项目'
      : widget.projects.where((item) => item.id == id).firstOrNull?.name ??
            '未知项目';

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
      final previousProject = projectFilter;
      update();
      if (projectFilter != previousProject && projectFilter != null) {
        expandedProjects.add(projectFilter!);
      }
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
          const Text(
            '选择项目',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (allowAll)
            ListTile(
              key: const ValueKey('project-all'),
              leading: const Icon(LucideIcons.layers),
              title: const Text('所有项目'),
              selected: selected == null,
              trailing: selected == null ? const Icon(LucideIcons.check) : null,
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
          for (final project in widget.projects)
            ListTile(
              key: ValueKey('project-${project.id}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              leading: Icon(LucideIcons.folder, color: AppMark.of(project.id)),
              title: Text(project.name),
              subtitle: Text(
                project.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              selected: selected == project.id,
              trailing: selected == project.id
                  ? const Icon(LucideIcons.check)
                  : null,
              onTap: () => Navigator.pop(sheetContext, project.id),
            ),
        ],
      ),
    );
  }

  Future<void> chooseProjectFilter() async {
    final id = await pickProject(selected: projectFilter, allowAll: true);
    if (!mounted || id == null) return;
    updateFilters(() => projectFilter = id.isEmpty ? null : id);
  }

  Future<void> createSession() async {
    if (busy || widget.projects.isEmpty) return;
    searchFocus.unfocus();
    var projectId =
        projectFilter ?? widget.activeProjectId ?? widget.projects.first.id;
    var engine = activeEngine;
    var creating = false;
    String? error;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      useSafeArea: true,
      sheetAnimationStyle: appOverlayAnimationStyle(context),
      backgroundColor: AppPalette.of(context).surface,
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
                  20,
                  24,
                  20,
                  24 + MediaQuery.viewInsetsOf(sheetContext).bottom,
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
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: creating
                                ? null
                                : () => Navigator.pop(sheetContext),
                            icon: const Icon(LucideIcons.x),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text('项目'),
                      ListTile(
                        key: const ValueKey('create-project-picker'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(project?.name ?? '选择项目'),
                        subtitle: Text(project?.path ?? '', softWrap: true),
                        trailing: const Icon(LucideIcons.chevronDown),
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
                            icon: const Icon(LucideIcons.folderOpen, size: 18),
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
    if (created == true && mounted) {
      Navigator.of(context).maybePop();
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
      final last =
          !item.archived &&
          widget.sessions
                  .where(
                    (other) =>
                        other.projectId == item.projectId && !other.archived,
                  )
                  .length ==
              1;
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
    final canMutate = !busy && !item.running;
    final canArchive =
        widget.sessions
            .where(
              (other) => other.projectId == item.projectId && !other.archived,
            )
            .length >
        1;
    return PopupMenuButton<_SessionAction>(
      key: ValueKey('session-menu-${item.id}'),
      tooltip: '${item.title} 的更多操作',
      icon: Icon(
        LucideIcons.moreHorizontal,
        size: AppIconSizes.inline,
        color: palette.muted,
      ),
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      onSelected: (action) => unawaited(handleAction(item, action)),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _SessionAction.details,
          child: sessionMenuLabel(LucideIcons.info, '会话详情'),
        ),
        if (!canMutate)
          const PopupMenuItem(enabled: false, child: Text('任务或附件操作中，暂不能整理会话')),
        PopupMenuItem(
          value: _SessionAction.pin,
          enabled: canMutate,
          child: sessionMenuLabel(
            item.pinned ? LucideIcons.pinOff : LucideIcons.pin,
            item.pinned ? '取消置顶' : '置顶',
            enabled: canMutate,
          ),
        ),
        PopupMenuItem(
          value: _SessionAction.rename,
          enabled: canMutate,
          child: sessionMenuLabel(
            LucideIcons.pencil,
            '重命名',
            enabled: canMutate,
          ),
        ),
        if (item.archived)
          PopupMenuItem(
            value: _SessionAction.restore,
            enabled: canMutate,
            child: sessionMenuLabel(
              LucideIcons.archiveRestore,
              '恢复会话',
              enabled: canMutate,
            ),
          )
        else
          PopupMenuItem(
            value: _SessionAction.archive,
            enabled: canMutate && canArchive,
            child: sessionMenuLabel(
              LucideIcons.archive,
              canArchive ? '归档' : '至少保留一个未归档会话',
              enabled: canMutate && canArchive,
            ),
          ),
        PopupMenuItem(
          value: _SessionAction.delete,
          enabled: canMutate,
          child: sessionMenuLabel(
            LucideIcons.trash2,
            '删除',
            enabled: canMutate,
            danger: true,
          ),
        ),
      ],
    );
  }

  DateTime? updatedDate(int timestamp) {
    if (timestamp <= 0) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } on RangeError {
      return null;
    }
  }

  Widget sessionRow(
    RemoteSessionSummary item, {
    bool nested = false,
    bool recent = false,
  }) {
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
      child: Material(
        color: active ? palette.accentSoft : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          side: BorderSide(
            color: active ? palette.lineStrong : Colors.transparent,
            width: 0.5,
          ),
        ),
        child: InkWell(
          key: ValueKey('${recent ? 'recent-' : ''}session-${item.id}'),
          borderRadius: BorderRadius.circular(AppRadii.control),
          hoverColor: palette.control,
          focusColor: palette.navigatorAccent.withValues(alpha: 0.12),
          splashColor: palette.ink.withValues(alpha: 0.04),
          highlightColor: palette.ink.withValues(alpha: 0.04),
          onTap: mutatingId != null ? null : () => widget.onSelect(item.id),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSizes.touchTarget),
            child: Padding(
              padding: EdgeInsets.only(left: nested ? 44 : 12),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: item.title,
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.4,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  if (status != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Tooltip(
                        message: status,
                        child: Icon(
                          item.needsAttention
                              ? LucideIcons.shield
                              : LucideIcons.clock,
                          size: AppIconSizes.inline,
                          color: item.needsAttention
                              ? palette.warning
                              : palette.navigatorAccent,
                        ),
                      ),
                    )
                  else if (active)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Tooltip(
                        message: '当前会话',
                        child: Icon(
                          LucideIcons.check,
                          size: AppIconSizes.inline,
                          color: palette.navigatorAccent,
                        ),
                      ),
                    ),
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
    );
  }

  Widget sectionTitle(String label, {required IconData icon}) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 20, 12, 4),
    child: Row(
      children: [
        Icon(
          icon,
          size: AppIconSizes.inline,
          color: AppPalette.of(context).muted,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppPalette.of(context).muted,
          ),
        ),
      ],
    ),
  );

  Widget emptyState(String title, String description, {bool clear = false}) =>
      ListView(
        padding: const EdgeInsets.fromLTRB(12, 40, 12, 24),
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Icon(LucideIcons.messageSquare, size: AppIconSizes.hero),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(color: AppPalette.of(context).muted),
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
    final sessions =
        widget.sessions
            .where(
              (item) =>
                  item.archived == showArchived &&
                  (projectFilter == null || item.projectId == projectFilter) &&
                  (engineFilter == null || item.engine == engineFilter),
            )
            .toList()
          ..sort((a, b) {
            final order = b.updatedAt.compareTo(a.updatedAt);
            return order != 0 ? order : a.id.compareTo(b.id);
          });
    if (sessions.isEmpty &&
        (showArchived ||
            projectFilter != null ||
            engineFilter != null ||
            widget.projects.isEmpty)) {
      return emptyState(
        showArchived ? '没有已归档的会话' : '没有符合条件的会话',
        showArchived
            ? '归档后会话会保留在这里，可随时查看或恢复。'
            : projectFilter != null || engineFilter != null
            ? '试试其他筛选条件，或新建会话。'
            : '选择一个项目，开始新的会话。',
        clear: projectFilter != null || engineFilter != null,
      );
    }
    final rows = <Widget>[];
    if (showArchived) {
      rows.add(sectionTitle('已归档', icon: LucideIcons.archive));
      rows.addAll(sessions.map((item) => sessionRow(item)));
    } else {
      final pinned = sessions.where((item) => item.pinned);
      if (pinned.isNotEmpty) {
        rows.add(sectionTitle('置顶', icon: LucideIcons.pin));
        rows.addAll(pinned.map((item) => sessionRow(item)));
      }
      final unpinned = sessions.where((item) => !item.pinned).toList();
      final grouped = <String, List<RemoteSessionSummary>>{};
      for (final item in unpinned) {
        (grouped[item.projectId] ??= []).add(item);
      }
      final projectIds = {
        for (final project in widget.projects)
          if ((projectFilter == null || project.id == projectFilter) &&
              (engineFilter == null ||
                  sessions.any((item) => item.projectId == project.id)))
            project.id,
        for (final item in sessions) item.projectId,
      };
      void addSessions(
        List<RemoteSessionSummary> items,
        String group, {
        bool nested = false,
        bool recent = false,
      }) {
        final count = visibleCounts[group] ?? 5;
        rows.addAll(
          items
              .take(count)
              .map((item) => sessionRow(item, nested: nested, recent: recent)),
        );
        if (items.length > count) {
          rows.add(
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: nested ? 32 : 0),
                child: TextButton(
                  key: ValueKey('session-more-$group'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.square(AppSizes.touchTarget),
                    foregroundColor: AppPalette.of(context).muted,
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  onPressed: () =>
                      setState(() => visibleCounts[group] = count + 5),
                  child: const Text('展开显示'),
                ),
              ),
            ),
          );
        }
      }

      if (projectIds.isNotEmpty) {
        rows.add(sectionTitle('项目', icon: LucideIcons.folders));
      }
      for (final id in projectIds) {
        final expanded = expandedProjects.contains(id);
        final items = grouped[id] ?? const <RemoteSessionSummary>[];
        rows.add(
          Semantics(
            button: true,
            value: expanded ? '已展开' : '已收起',
            child: Tooltip(
              message:
                  widget.projects
                      .where((project) => project.id == id)
                      .firstOrNull
                      ?.path ??
                  projectName(id),
              child: InkWell(
                key: ValueKey('session-project-$id'),
                borderRadius: BorderRadius.circular(AppRadii.control),
                hoverColor: AppPalette.of(context).control,
                focusColor: AppPalette.of(
                  context,
                ).navigatorAccent.withValues(alpha: 0.12),
                highlightColor: AppPalette.of(
                  context,
                ).ink.withValues(alpha: 0.04),
                onTap: () => setState(() {
                  if (!expandedProjects.remove(id)) expandedProjects.add(id);
                }),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSizes.touchTarget,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Icon(
                          expanded
                              ? LucideIcons.folderOpen
                              : LucideIcons.folder,
                          size: AppIconSizes.control,
                          // Jewel-tone identity per project, matching the
                          // project picker and the design system's colored
                          // session-navigation marks.
                          color: AppMark.of(id),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            projectName(id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedRotation(
                          turns: expanded ? 0.25 : 0,
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : AppMotion.micro,
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            LucideIcons.chevronRight,
                            size: AppIconSizes.inline,
                            color: AppPalette.of(context).muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        if (expanded) {
          if (items.isEmpty) {
            rows.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(44, 8, 12, 12),
                child: Text(
                  sessions.any((item) => item.projectId == id)
                      ? '会话已在置顶中'
                      : '暂无会话',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppPalette.of(context).muted,
                  ),
                ),
              ),
            );
          } else {
            addSessions(items, id, nested: true);
          }
        }
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Semantics(
            button: true,
            value: recentExpanded ? '已展开' : '已收起',
            child: InkWell(
              key: const ValueKey('session-recent-toggle'),
              borderRadius: BorderRadius.circular(AppRadii.control),
              hoverColor: AppPalette.of(context).control,
              focusColor: AppPalette.of(
                context,
              ).navigatorAccent.withValues(alpha: 0.12),
              onTap: () => setState(() => recentExpanded = !recentExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSizes.touchTarget,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.history,
                        size: AppIconSizes.inline,
                        color: AppPalette.of(context).muted,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '最近',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppPalette.of(context).muted,
                        ),
                      ),
                      const Spacer(),
                      AnimatedRotation(
                        turns: recentExpanded ? 0.25 : 0,
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : AppMotion.micro,
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          LucideIcons.chevronRight,
                          size: AppIconSizes.inline,
                          color: AppPalette.of(context).muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (recentExpanded) {
        addSessions(unpinned, 'recent', recent: true);
        if (unpinned.isEmpty) {
          rows.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Text(
                '暂无未置顶的会话',
                style: TextStyle(
                  fontSize: 13,
                  color: AppPalette.of(context).muted,
                ),
              ),
            ),
          );
        }
      }
    }
    return ListView(
      key: PageStorageKey(
        'session-list-$showArchived-$projectFilter-$engineFilter',
      ),
      padding: const EdgeInsets.only(bottom: 20),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: rows,
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

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: mutatingId == null,
      child: Material(
        key: const ValueKey('session-navigator-page'),
        color: palette.paper,
        child: DecoratedBox(
          // A hairline seam against the exposed chat strip keeps the sidebar
          // reading as part of the layout rather than a floating card.
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: palette.line)),
          ),
          position: DecorationPosition.foreground,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                  child: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('session-drawer-close'),
                        tooltip: '收起会话列表',
                        onPressed: mutatingId == null
                            ? () => Navigator.maybePop(context)
                            : null,
                        icon: const Icon(
                          LucideIcons.x,
                          size: AppIconSizes.control,
                        ),
                      ),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            showArchived ? '已归档' : '会话中心',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('session-archive-toggle'),
                        tooltip: showArchived ? '返回会话列表' : '查看已归档会话',
                        onPressed: mutatingId == null
                            ? () =>
                                  updateFilters(() => showArchived = !showArchived)
                            : null,
                        icon: Icon(
                          showArchived
                              ? LucideIcons.messagesSquare
                              : LucideIcons.archive,
                          size: AppIconSizes.control,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      TextField(
                        key: const ValueKey('session-search-field'),
                        controller: searchController,
                        focusNode: searchFocus,
                        textInputAction: TextInputAction.search,
                        onChanged: searchChanged,
                        onSubmitted: (value) =>
                            searchChanged(value, immediate: true),
                        decoration: InputDecoration(
                          hintText: '搜索标题与消息',
                          fillColor: palette.control.withValues(alpha: 0.65),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                            borderSide: BorderSide(
                              color: palette.line,
                              width: 0.75,
                            ),
                          ),
                          prefixIcon: Icon(
                            LucideIcons.search,
                            size: AppIconSizes.control,
                            color: palette.muted,
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
                                  icon: Icon(
                                    LucideIcons.x,
                                    size: AppIconSizes.inline,
                                    color: palette.muted,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // No persistent scrollbar on this row: its bottom thumb
                      // paints straight across the chips. The clipped last
                      // chip already signals that the row scrolls.
                      SingleChildScrollView(
                        controller: filterScroll,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(right: 16, bottom: 8),
                        child: Row(
                          children: [
                            ActionChip(
                              key: const ValueKey('open-project-browser'),
                              avatar: Icon(
                                LucideIcons.folder,
                                size: AppIconSizes.inline,
                                color: palette.muted,
                              ),
                              backgroundColor: palette.surface,
                              side: BorderSide(
                                color: palette.line,
                                width: 0.75,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.compact,
                                ),
                              ),
                              labelStyle: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: palette.ink,
                              ),
                              label: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 180,
                                ),
                                child: Text(
                                  projectName(projectFilter),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              onPressed: chooseProjectFilter,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                            ),
                            const SizedBox(width: 8),
                            for (final engine in <SessionEngine?>[
                              null,
                              ...SessionEngine.values,
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  key: ValueKey(
                                    'session-filter-${engine?.wireName ?? 'all'}',
                                  ),
                                  label: Text(
                                    engine?.wireName == 'claude'
                                        ? 'Claude'
                                        : engine?.label ?? '全部引擎',
                                  ),
                                  selected: engineFilter == engine,
                                  color: WidgetStateProperty.resolveWith(
                                    (states) => states
                                            .contains(WidgetState.selected)
                                        ? palette.accentSoft
                                        : palette.paper,
                                  ),
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.compact,
                                    ),
                                  ),
                                  labelStyle: TextStyle(
                                    fontSize: 13,
                                    fontWeight: engineFilter == engine
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: engineFilter == engine
                                        ? palette.ink
                                        : palette.muted,
                                  ),
                                  onSelected: (_) => updateFilters(
                                    () => engineFilter = engine,
                                  ),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.padded,
                                  chipAnimationStyle: MediaQuery
                                          .disableAnimationsOf(context)
                                      ? ChipAnimationStyle(
                                          enableAnimation:
                                              AnimationStyle.noAnimation,
                                          selectAnimation:
                                              AnimationStyle.noAnimation,
                                          avatarDrawerAnimation:
                                              AnimationStyle.noAnimation,
                                          deleteDrawerAnimation:
                                              AnimationStyle.noAnimation,
                                        )
                                      : null,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (widget.running)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                          child: Text(
                            '当前任务或附件操作尚未结束，暂不能新建或整理会话。',
                            style: TextStyle(fontSize: 12, color: palette.muted),
                          ),
                        ),
                      if (mutationError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
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
                        child: searchQuery.isEmpty ? sessionList() : searchBody(),
                      ),
                    ],
                  ),
                ),
              ),
              if (!keyboardOpen)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: SignalPressEffect(
                      enabled: !busy && widget.projects.isNotEmpty,
                      child: FilledButton.icon(
                        key: const ValueKey('create-session'),
                        onPressed: busy || widget.projects.isEmpty
                            ? null
                            : createSession,
                        icon: const Icon(
                          LucideIcons.plus,
                          size: AppIconSizes.control,
                        ),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('新建会话'),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
