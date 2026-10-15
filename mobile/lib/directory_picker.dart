import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'data/directory_api.dart';
import 'data/remote_models.dart';
import 'noto_icon.dart';
import 'signal_console_theme.dart';

class DirectoryPickerPage extends StatefulWidget {
  const DirectoryPickerPage({
    super.key,
    required this.onBrowse,
    required this.onCreate,
    required this.busyListenable,
    this.recentProjects = const [],
    this.currentPath,
    this.initialEngine = SessionEngine.claude,
  });

  final Future<RemoteDirectoryListing> Function(String? path) onBrowse;
  final Future<void> Function(String path, SessionEngine engine) onCreate;
  final ValueListenable<bool> busyListenable;
  final List<RemoteProjectSummary> recentProjects;
  final String? currentPath;
  final SessionEngine initialEngine;

  @override
  State<DirectoryPickerPage> createState() => _DirectoryPickerPageState();
}

class _DirectoryPickerPageState extends State<DirectoryPickerPage> {
  final pathController = TextEditingController();
  final pathFocus = FocusNode();
  RemoteDirectoryListing? listing;
  String? error;
  String? requestedPath;
  bool loading = true;
  bool creating = false;
  int browseGeneration = 0;
  late SessionEngine engine = widget.initialEngine;

  @override
  void initState() {
    super.initState();
    unawaited(browse(null));
  }

  @override
  void dispose() {
    browseGeneration++;
    pathController.dispose();
    pathFocus.dispose();
    super.dispose();
  }

  Future<bool> browse(String? path) async {
    final generation = ++browseGeneration;
    pathFocus.unfocus();
    setState(() {
      requestedPath = path;
      loading = true;
      error = null;
      pathController.text = path ?? '';
    });
    try {
      final next = await widget.onBrowse(path);
      if (!mounted || generation != browseGeneration) return false;
      setState(() {
        listing = next;
        pathController.text = next.path ?? '';
        loading = false;
      });
      return true;
    } catch (failure) {
      if (!mounted || generation != browseGeneration) return false;
      setState(() {
        loading = false;
        error = directoryErrorMessage(failure);
      });
      return false;
    }
  }

  void editPath(String _) {
    setState(() {
      browseGeneration++;
      loading = false;
      listing = null;
      error = null;
    });
  }

  Future<void> createSession() async {
    if (creating || loading || widget.busyListenable.value) return;
    final path = pathController.text.trim();
    if (path.isEmpty) {
      setState(() => error = '先选择文件夹，或输入电脑上的完整目录');
      pathFocus.requestFocus();
      return;
    }
    if (listing?.path != path || error != null) {
      if (!await browse(path)) return;
    }
    if (!mounted || widget.busyListenable.value || listing?.path == null) {
      return;
    }
    setState(() {
      creating = true;
      error = null;
    });
    try {
      await widget.onCreate(listing!.path!, engine);
      if (!mounted) return;
      creating = false;
      Navigator.of(context).pop();
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        creating = false;
        error = directoryErrorMessage(failure);
      });
    }
  }

  Widget directoryRow(RemoteDirectory directory, {bool recent = false}) {
    final palette = AppPalette.of(context);
    return ListTile(
      key: ValueKey('${recent ? 'recent' : 'directory'}-${directory.path}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: SmartIcon(
        recent ? LucideIcons.history : LucideIcons.folder,
        size: AppIconSizes.primary,
        color: palette.muted,
      ),
      title: Text(directory.name),
      subtitle: recent ? Text(directory.path, softWrap: true) : null,
      trailing: const SmartIcon(
        LucideIcons.chevronRight,
        size: AppIconSizes.inline,
      ),
      onTap: creating ? null : () => unawaited(browse(directory.path)),
    );
  }

  Widget sectionTitle(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final data = listing;
    final atRoots = data?.path == null && pathController.text.isEmpty;
    final entries = atRoots ? data?.roots : data?.directories;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: !creating,
      child: Scaffold(
        key: const ValueKey('directory-picker-page'),
        backgroundColor: palette.paper,
        appBar: AppBar(
          title: const Text('打开电脑目录'),
          backgroundColor: palette.paper,
          surfaceTintColor: Colors.transparent,
        ),
        body: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.currentPath != null) ...[
                      Text(
                        '当前对话目录',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        widget.currentPath!,
                        style: TextStyle(color: palette.muted, fontSize: 13),
                      ),
                      const SizedBox(height: 20),
                    ],
                    TextField(
                      key: const ValueKey('directory-path-input'),
                      controller: pathController,
                      focusNode: pathFocus,
                      readOnly: creating,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.go,
                      decoration: InputDecoration(
                        labelText: '电脑目录',
                        hintText: '输入或粘贴完整路径',
                        suffixIcon: IconButton(
                          key: const ValueKey('directory-path-open'),
                          tooltip: '打开输入的目录',
                          onPressed: creating
                              ? null
                              : () => unawaited(
                                  browse(pathController.text.trim()),
                                ),
                          icon: const SmartIcon(LucideIcons.arrowRight),
                        ),
                      ),
                      onChanged: editPath,
                      onSubmitted: (value) => unawaited(browse(value.trim())),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          key: const ValueKey('directory-roots'),
                          onPressed: creating
                              ? null
                              : () => unawaited(browse(null)),
                          icon: const SmartIcon(
                            LucideIcons.hardDrive,
                            size: AppIconSizes.inline,
                          ),
                          label: const Text('电脑磁盘'),
                        ),
                        if (data?.parentPath != null)
                          TextButton.icon(
                            key: const ValueKey('directory-parent'),
                            onPressed: creating
                                ? null
                                : () => unawaited(browse(data!.parentPath)),
                            icon: const SmartIcon(
                              LucideIcons.arrowUp,
                              size: AppIconSizes.inline,
                            ),
                            label: const Text('上一级'),
                          ),
                      ],
                    ),
                    if (error != null)
                      Semantics(
                        liveRegion: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              error!,
                              style: TextStyle(color: palette.danger),
                            ),
                            TextButton.icon(
                              key: const ValueKey('directory-retry'),
                              onPressed: creating
                                  ? null
                                  : () => unawaited(browse(requestedPath)),
                              icon: const SmartIcon(
                                LucideIcons.refreshCw,
                                size: AppIconSizes.inline,
                              ),
                              label: const Text('重新加载目录'),
                            ),
                          ],
                        ),
                      ),
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: LinearProgressIndicator(
                          semanticsLabel: '正在读取电脑目录',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!loading && error == null) ...[
              if (atRoots && widget.recentProjects.isNotEmpty) ...[
                SliverToBoxAdapter(child: sectionTitle('最近项目')),
                SliverList.list(
                  children: [
                    for (final project in widget.recentProjects.take(5))
                      directoryRow(
                        RemoteDirectory(name: project.name, path: project.path),
                        recent: true,
                      ),
                  ],
                ),
              ],
              SliverToBoxAdapter(
                child: sectionTitle(atRoots ? '电脑磁盘与主目录' : '文件夹'),
              ),
              if (entries != null && entries.isNotEmpty)
                SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => directoryRow(entries[index]),
                )
              else
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      data == null
                          ? '打开输入的路径以浏览文件夹'
                          : atRoots
                          ? '输入电脑上的完整目录以继续'
                          : '此目录没有子文件夹，可以直接在此新建对话',
                      style: TextStyle(color: palette.muted),
                    ),
                  ),
                ),
              if (data?.truncated == true)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '此目录文件夹较多，可输入完整路径定位',
                      style: TextStyle(color: palette.muted),
                    ),
                  ),
                ),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
          ],
        ),
        bottomNavigationBar: keyboardVisible
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: widget.busyListenable,
                    builder: (context, busy, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          busy
                              ? '当前任务或附件操作尚未结束，可以先浏览目录'
                              : '新对话使用所选目录，已有对话保留原目录',
                          style: TextStyle(color: palette.muted, fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final option in SessionEngine.values)
                              ChoiceChip(
                                key: ValueKey(
                                  'directory-engine-${option.wireName}',
                                ),
                                label: Text(option.displayName),
                                selected: engine == option,
                                onSelected: creating
                                    ? null
                                    : (_) => setState(() => engine = option),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.padded,
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          key: const ValueKey('directory-create-session'),
                          onPressed: busy || loading || creating
                              ? null
                              : createSession,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              children: [
                                if (creating)
                                  const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      semanticsLabel: '正在新建对话',
                                    ),
                                  ),
                                const Text(
                                  '在此新建对话',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
