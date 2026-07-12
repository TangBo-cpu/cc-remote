import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const _ink = Color(0xFF172026);
const _muted = Color(0xFF6B7880);
const _accent = Color(0xFF168EB0);
const _line = Color(0xFFDCE7EB);

Future<void> showWorkspaceDrawer(
  BuildContext context, {
  required Uri origin,
  required String token,
  required String workspaceName,
  bool demoMode = false,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭工作区',
    barrierColor: const Color(0xFF102128).withValues(alpha: 0.24),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) => Align(
      alignment: Alignment.centerLeft,
      child: SafeArea(
        child: SizedBox(
          width: math.min(MediaQuery.sizeOf(context).width * 0.92, 520),
          height: double.infinity,
          child: WorkspaceDrawer(
            origin: origin,
            token: token,
            workspaceName: workspaceName,
            demoMode: demoMode,
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: FadeTransition(opacity: animation, child: child),
      );
    },
  );
}

class WorkspaceDrawer extends StatefulWidget {
  const WorkspaceDrawer({
    super.key,
    required this.origin,
    required this.token,
    required this.workspaceName,
    this.demoMode = false,
    this.api,
  });

  final Uri origin;
  final String token;
  final String workspaceName;
  final bool demoMode;
  final WorkspaceApi? api;

  @override
  State<WorkspaceDrawer> createState() => _WorkspaceDrawerState();
}

class _WorkspaceDrawerState extends State<WorkspaceDrawer> {
  late final WorkspaceApi api;
  WorkspaceSnapshot? snapshot;
  WorkspaceDocument? document;
  bool loading = true;
  bool failed = false;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    api =
        widget.api ??
        WorkspaceApi(
          origin: widget.origin,
          token: widget.token,
          demoMode: widget.demoMode,
        );
    refresh();
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }

  Future<void> refresh() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final next = await api.snapshot();
      if (!mounted) return;
      setState(() {
        snapshot = next;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        failed = true;
        loading = false;
      });
    }
  }

  Future<void> openFile(String path) async {
    setState(() => document = WorkspaceDocument.loading(path));
    try {
      final next = await api.file(path);
      if (mounted) setState(() => document = next);
    } catch (_) {
      if (mounted) setState(() => document = WorkspaceDocument.failed(path));
    }
  }

  Future<void> openChange(WorkspaceChange change) async {
    return openDiff(
      change,
      staged: change.unstaged == null && change.staged != null,
    );
  }

  Future<void> openDiff(WorkspaceChange change, {required bool staged}) async {
    setState(() => document = WorkspaceDocument.loading(change.path));
    try {
      final diff = await api.diff(change.path, staged: staged);
      if (!mounted) return;
      if (diff.trim().isEmpty && change.unstaged == '?') {
        await openFile(change.path);
        return;
      }
      setState(() => document = WorkspaceDocument.diff(change.path, diff));
    } catch (_) {
      if (mounted) {
        setState(() => document = WorkspaceDocument.failed(change.path));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FCFD).withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x260E343F),
              blurRadius: 34,
              offset: Offset(10, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _header(),
            const Divider(height: 1, color: _line),
            Expanded(child: document == null ? _browser() : _document()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
      child: Row(
        children: [
          IconButton(
            onPressed: document == null
                ? () => Navigator.pop(context)
                : () => setState(() => document = null),
            icon: Icon(
              document == null ? Icons.close_rounded : Icons.arrow_back_rounded,
            ),
            tooltip: document == null ? '关闭' : '返回文件列表',
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document?.path.split('/').last ?? widget.workspaceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  document?.path ?? _workspaceSubtitle(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          if (document == null)
            IconButton(
              onPressed: loading ? null : refresh,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新工作区',
            ),
        ],
      ),
    );
  }

  String _workspaceSubtitle() {
    final data = snapshot;
    if (data == null) return '正在读取工作区';
    if (!data.gitAvailable) return '${data.files.length} 个文件';
    final branch = data.branch == null ? '' : ' · ${data.branch}';
    return '${data.files.length} 个文件$branch';
  }

  Widget _browser() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFFEAF2F4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _tabButton(0, Icons.folder_outlined, '文件'),
                _tabButton(
                  1,
                  Icons.difference_outlined,
                  '修改${snapshot == null ? '' : ' ${snapshot!.changes.length}'}',
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _browserBody()),
      ],
    );
  }

  Widget _tabButton(int value, IconData icon, String label) {
    final selected = tab == value;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => tab = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: selected
                ? const [BoxShadow(color: Color(0x140E343F), blurRadius: 8)]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: selected ? _accent : _muted),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? _ink : _muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _browserBody() {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (failed || snapshot == null) {
      return _EmptyState(
        icon: Icons.cloud_off_outlined,
        title: '无法读取工作区',
        detail: '检查电脑端连接后再刷新',
        action: refresh,
      );
    }
    return tab == 1 ? _changes(snapshot!) : _files(snapshot!);
  }

  Widget _files(WorkspaceSnapshot data) {
    if (data.files.isEmpty) {
      return const _EmptyState(
        icon: Icons.folder_off_outlined,
        title: '当前目录没有可查看的文件',
        detail: '忽略项和构建产物不会显示',
      );
    }
    final root = WorkspaceTreeNode.fromPaths(data.files);
    return ListView(
      key: const ValueKey('workspace-files'),
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
      children: root.children
          .map((node) => _TreeNodeTile(node: node, onFile: openFile))
          .toList(),
    );
  }

  Widget _changes(WorkspaceSnapshot data) {
    if (!data.gitAvailable) {
      return const _EmptyState(
        icon: Icons.source_outlined,
        title: '当前目录不是 Git 仓库',
        detail: '文件仍然可以正常查看',
      );
    }
    if (data.changes.isEmpty) {
      return const _EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: '工作区没有修改',
        detail: '当前内容和 Git 记录一致',
      );
    }
    return ListView.separated(
      key: const ValueKey('workspace-changes'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: data.changes.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 42, color: _line),
      itemBuilder: (context, index) {
        final change = data.changes[index];
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 3,
          ),
          leading: _ChangeBadge(change: change),
          title: Text(
            change.path.split('/').last,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            change.previousPath == null
                ? _parentPath(change.path)
                : '${change.previousPath} →',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: _muted,
              fontFamily: 'monospace',
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (change.staged != null)
                _DiffScopeChip(
                  label: '暂存 ${change.staged}',
                  onTap: () => openDiff(change, staged: true),
                ),
              if (change.unstaged != null) ...[
                if (change.staged != null) const SizedBox(width: 4),
                _DiffScopeChip(
                  label: change.unstaged == '?'
                      ? '未跟踪'
                      : '未暂存 ${change.unstaged}',
                  onTap: () => openDiff(change, staged: false),
                ),
              ],
            ],
          ),
          onTap: () => openChange(change),
        );
      },
    );
  }

  Widget _document() {
    final current = document!;
    if (current.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.2));
    }
    if (current.failed) {
      return const _EmptyState(
        icon: Icons.description_outlined,
        title: '无法显示这个文件',
        detail: '文件可能过大、是二进制内容或已经被删除',
      );
    }
    return current.isDiff
        ? _DiffView(diff: current.content)
        : _FileView(document: current);
  }
}

class WorkspaceApi {
  WorkspaceApi({
    required this.origin,
    required this.token,
    this.demoMode = false,
    http.Client? client,
  }) : client = client ?? http.Client();

  final Uri origin;
  final String token;
  final bool demoMode;
  final http.Client client;

  static const timeout = Duration(seconds: 12);

  Map<String, String> get headers => {'Authorization': 'Bearer $token'};

  void close() {
    client.close();
  }

  Future<WorkspaceSnapshot> snapshot() async {
    if (demoMode) return WorkspaceSnapshot.demo();
    final response = await client
        .get(origin.resolve('/api/workspace'), headers: headers)
        .timeout(timeout);
    if (response.statusCode != 200) throw StateError('workspace_failed');
    return WorkspaceSnapshot.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<WorkspaceDocument> file(String path) async {
    if (demoMode) {
      return WorkspaceDocument.file(
        path,
        "import 'package:flutter/material.dart';\n\nvoid main() {\n  runApp(const CcRemoteApp());\n}\n",
        truncated: false,
      );
    }
    final uri = origin
        .resolve('/api/workspace/file')
        .replace(queryParameters: {'path': path});
    final response = await client.get(uri, headers: headers).timeout(timeout);
    if (response.statusCode != 200) throw StateError('file_failed');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return WorkspaceDocument.file(
      data['path'] as String,
      data['content'] as String,
      truncated: data['truncated'] == true,
    );
  }

  Future<String> diff(String path, {required bool staged}) async {
    if (demoMode) {
      return "@@ -1,3 +1,4 @@\n import 'package:flutter/material.dart';\n+import 'workspace_drawer.dart';\n \n void main() {";
    }
    final uri = origin
        .resolve('/api/workspace/diff')
        .replace(queryParameters: {'path': path, if (staged) 'staged': '1'});
    final response = await client.get(uri, headers: headers).timeout(timeout);
    if (response.statusCode != 200) throw StateError('diff_failed');
    return (jsonDecode(response.body) as Map<String, dynamic>)['diff']
        as String;
  }
}

class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.rootName,
    required this.gitAvailable,
    required this.files,
    required this.changes,
    this.branch,
  });

  final String rootName;
  final bool gitAvailable;
  final String? branch;
  final List<String> files;
  final List<WorkspaceChange> changes;

  factory WorkspaceSnapshot.fromJson(Map<String, dynamic> json) {
    return WorkspaceSnapshot(
      rootName: json['rootName'] as String? ?? '',
      gitAvailable: json['gitAvailable'] == true,
      branch: json['branch'] as String?,
      files: (json['files'] as List? ?? const []).whereType<String>().toList(),
      changes: (json['changes'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(WorkspaceChange.fromJson)
          .toList(),
    );
  }

  factory WorkspaceSnapshot.demo() {
    return const WorkspaceSnapshot(
      rootName: 'cc-remote',
      gitAvailable: true,
      branch: 'codex/workspace-sidebar',
      files: [
        'README.md',
        'src/daemon.ts',
        'mobile/lib/main.dart',
        'mobile/lib/workspace_drawer.dart',
      ],
      changes: [
        WorkspaceChange(path: 'src/daemon.ts', unstaged: 'M'),
        WorkspaceChange(
          path: 'mobile/lib/workspace_drawer.dart',
          unstaged: '?',
        ),
      ],
    );
  }
}

class WorkspaceChange {
  const WorkspaceChange({
    required this.path,
    this.previousPath,
    this.staged,
    this.unstaged,
  });

  final String path;
  final String? previousPath;
  final String? staged;
  final String? unstaged;

  factory WorkspaceChange.fromJson(Map<String, dynamic> json) {
    return WorkspaceChange(
      path: json['path'] as String? ?? '',
      previousPath: json['previousPath'] as String?,
      staged: json['staged'] as String?,
      unstaged: json['unstaged'] as String?,
    );
  }
}

class WorkspaceDocument {
  const WorkspaceDocument._({
    required this.path,
    this.content = '',
    this.loading = false,
    this.failed = false,
    this.isDiff = false,
    this.truncated = false,
  });

  final String path;
  final String content;
  final bool loading;
  final bool failed;
  final bool isDiff;
  final bool truncated;

  factory WorkspaceDocument.loading(String path) =>
      WorkspaceDocument._(path: path, loading: true);
  factory WorkspaceDocument.failed(String path) =>
      WorkspaceDocument._(path: path, failed: true);
  factory WorkspaceDocument.diff(String path, String diff) =>
      WorkspaceDocument._(path: path, content: diff, isDiff: true);
  factory WorkspaceDocument.file(
    String path,
    String content, {
    required bool truncated,
  }) => WorkspaceDocument._(path: path, content: content, truncated: truncated);
}

class WorkspaceTreeNode {
  WorkspaceTreeNode(this.name, {this.path, this.directory = false});

  final String name;
  final String? path;
  final bool directory;
  final List<WorkspaceTreeNode> children = [];

  static WorkspaceTreeNode fromPaths(List<String> paths) {
    final root = WorkspaceTreeNode('', directory: true);
    for (final path in paths) {
      final parts = path.split('/');
      var parent = root;
      for (var index = 0; index < parts.length; index += 1) {
        final part = parts[index];
        final isFile = index == parts.length - 1;
        WorkspaceTreeNode? node;
        for (final child in parent.children) {
          if (child.name == part) node = child;
        }
        node ??= WorkspaceTreeNode(
          part,
          path: isFile ? path : null,
          directory: !isFile,
        );
        if (!parent.children.contains(node)) {
          parent.children.add(node);
        }
        parent = node;
      }
    }
    void sort(WorkspaceTreeNode node) {
      node.children.sort((a, b) {
        if (a.directory != b.directory) return a.directory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      for (final child in node.children) {
        sort(child);
      }
    }

    sort(root);
    return root;
  }
}

class _TreeNodeTile extends StatelessWidget {
  const _TreeNodeTile({required this.node, required this.onFile});

  final WorkspaceTreeNode node;
  final ValueChanged<String> onFile;

  @override
  Widget build(BuildContext context) {
    if (!node.directory) {
      return ListTile(
        dense: true,
        minTileHeight: 38,
        contentPadding: const EdgeInsets.only(left: 12, right: 8),
        leading: Icon(
          _fileIcon(node.name),
          size: 18,
          color: _fileColor(node.name),
        ),
        title: Text(
          node.name,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        onTap: () => onFile(node.path!),
      );
    }
    return ExpansionTile(
      tilePadding: const EdgeInsets.only(left: 8, right: 8),
      childrenPadding: const EdgeInsets.only(left: 13),
      dense: true,
      shape: const Border(),
      collapsedShape: const Border(),
      leading: const Icon(
        Icons.folder_rounded,
        size: 19,
        color: Color(0xFF5E9CAF),
      ),
      title: Text(
        node.name,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      children: node.children
          .map((child) => _TreeNodeTile(node: child, onFile: onFile))
          .toList(),
    );
  }
}

class _FileView extends StatelessWidget {
  const _FileView({required this.document});

  final WorkspaceDocument document;

  @override
  Widget build(BuildContext context) {
    final lines = document.content.split('\n');
    final width = lines.length.toString().length;
    const maxLineCharacters = 12000;
    final hasLongLine = lines.any((line) => line.length > maxLineCharacters);
    return Column(
      children: [
        if (document.truncated || hasLongLine)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: const Color(0xFFFFF3D9),
            child: Text(
              document.truncated && hasLongLine
                  ? '文件和超长单行均已截断显示'
                  : document.truncated
                  ? '文件较大，只显示前面的内容'
                  : '超长单行已截断显示',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('workspace-file-lines'),
            padding: const EdgeInsets.fromLTRB(14, 14, 20, 36),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final displayLine = line.length > maxLineCharacters
                  ? '${line.substring(0, maxLineCharacters)} … [本行过长，已截断]'
                  : line;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: (width * 8.0) + 18,
                    child: Text(
                      (index + 1).toString().padLeft(width),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Color(0xFF9AABB1),
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        height: 1.55,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        displayLine.isEmpty ? ' ' : displayLine,
                        style: const TextStyle(
                          color: Color(0xFF26353B),
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DiffView extends StatelessWidget {
  const _DiffView({required this.diff});

  final String diff;

  @override
  Widget build(BuildContext context) {
    final lines = diff.split('\n');
    return ListView.builder(
      key: const ValueKey('workspace-diff'),
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        final added = line.startsWith('+') && !line.startsWith('+++');
        final removed = line.startsWith('-') && !line.startsWith('---');
        final hunk = line.startsWith('@@');
        return Container(
          color: added
              ? const Color(0xFFE3F4EC)
              : removed
              ? const Color(0xFFFBE7E5)
              : hunk
              ? const Color(0xFFE8F2F7)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2.5),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              line.isEmpty ? ' ' : line,
              style: TextStyle(
                color: hunk ? _accent : _ink,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChangeBadge extends StatelessWidget {
  const _ChangeBadge({required this.change});

  final WorkspaceChange change;

  @override
  Widget build(BuildContext context) {
    final status = change.unstaged ?? change.staged ?? 'M';
    final label = status == '?' ? 'U' : status;
    final color = switch (label) {
      'A' || 'U' => const Color(0xFF2A9870),
      'D' => const Color(0xFFC95E5E),
      'R' => const Color(0xFF8A70B6),
      _ => _accent,
    };
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DiffScopeChip extends StatelessWidget {
  const _DiffScopeChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F2F5),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF4D6C76),
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: const Color(0xFF8EABB4)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _ink, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, fontSize: 12.5),
            ),
            if (action != null) ...[
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: action,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新读取'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _parentPath(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? '项目根目录' : path.substring(0, index);
}

IconData _fileIcon(String name) {
  final extension = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : '';
  return switch (extension) {
    'md' => Icons.article_outlined,
    'json' || 'yaml' || 'yml' => Icons.data_object_rounded,
    'png' || 'jpg' || 'jpeg' || 'webp' => Icons.image_outlined,
    'dart' || 'ts' || 'js' || 'tsx' || 'jsx' => Icons.code_rounded,
    _ => Icons.description_outlined,
  };
}

Color _fileColor(String name) {
  final extension = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : '';
  return switch (extension) {
    'dart' => const Color(0xFF168EB0),
    'ts' || 'js' || 'tsx' || 'jsx' => const Color(0xFFD0982A),
    'md' => const Color(0xFF6D7F89),
    _ => const Color(0xFF82959D),
  };
}
