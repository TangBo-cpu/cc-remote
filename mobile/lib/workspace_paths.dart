import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'signal_console_theme.dart';

const workspacePathExtensions = <String>{
  'bat',
  'c',
  'cc',
  'cfg',
  'cmd',
  'conf',
  'cpp',
  'cs',
  'css',
  'csv',
  'dart',
  'env',
  'fs',
  'gif',
  'go',
  'gradle',
  'graphql',
  'h',
  'hpp',
  'htm',
  'html',
  'ini',
  'java',
  'jpeg',
  'jpg',
  'js',
  'json',
  'jsx',
  'kt',
  'kts',
  'less',
  'lock',
  'm',
  'markdown',
  'md',
  'mjs',
  'mm',
  'php',
  'plist',
  'png',
  'properties',
  'proto',
  'ps1',
  'py',
  'rb',
  'rs',
  'scss',
  'sh',
  'sql',
  'svg',
  'svelte',
  'swift',
  'toml',
  'ts',
  'tsx',
  'txt',
  'vue',
  'webp',
  'xml',
  'yaml',
  'yml',
  'zsh',
};

const workspacePathBasenames = <String>{
  'changelog',
  'copying',
  'dockerfile',
  'gemfile',
  'justfile',
  'license',
  'makefile',
  'procfile',
  'rakefile',
};

const _hostTlds = <String>{
  'ai',
  'app',
  'cc',
  'cn',
  'co',
  'com',
  'dev',
  'edu',
  'gov',
  'info',
  'io',
  'me',
  'net',
  'org',
  'tv',
  'uk',
  'us',
  'xyz',
};

final _workspacePathCandidate = RegExp(
  r'[A-Za-z]:[\\/][^\s`<>|]+'
  r'|(?:\.{1,2}[\\/])?(?:[\w.+\-]+[\\/])+[\w.+\-]+'
  r'|[\w.\-]+\.[A-Za-z][A-Za-z0-9]{0,7}'
  r'|\.[\w.\-]+',
);

final _schemePrefix = RegExp(r'(?:^|[^a-z0-9+.-])[a-z][a-z0-9+.-]*:$');

@immutable
class WorkspacePathMatch {
  const WorkspacePathMatch({
    required this.start,
    required this.end,
    required this.path,
  });

  final int start;
  final int end;
  final String path;
}

@immutable
class WorkspaceChangeEcho {
  const WorkspaceChangeEcho({
    required this.changeCount,
    required this.paths,
    this.branch,
  });

  final int changeCount;
  final List<String> paths;
  final String? branch;

  String get label => changeCount == 1
      ? '改了 ${paths.first.split('/').last}'
      : '改了 $changeCount 个文件';

  String get caption => '看 diff · 仅桌面工作区';

  String? get focusPath => paths.length == 1 ? paths.first : null;
}

bool workspaceEchoShouldClear({
  required String? currentSessionId,
  required String? nextSessionId,
  String? currentWorkspaceDir,
  String? nextWorkspaceDir,
}) {
  if (currentSessionId != null && currentSessionId != nextSessionId) {
    return true;
  }
  if (currentWorkspaceDir != null &&
      currentWorkspaceDir.isNotEmpty &&
      nextWorkspaceDir != null &&
      nextWorkspaceDir.isNotEmpty &&
      currentWorkspaceDir != nextWorkspaceDir) {
    return true;
  }
  return false;
}

class WorkspacePortal extends InheritedWidget {
  const WorkspacePortal({
    super.key,
    required this.onOpenPath,
    this.workspaceDir,
    required super.child,
  });

  final ValueChanged<String>? onOpenPath;
  final String? workspaceDir;

  static WorkspacePortal? of(BuildContext context) {
    return context.getInheritedWidgetOfExactType<WorkspacePortal>();
  }

  static void openPath(BuildContext context, String path) {
    final portal = of(context);
    final resolved = normalizeWorkspacePath(
      path,
      workspaceDir: portal?.workspaceDir,
    );
    if (resolved == null || portal?.onOpenPath == null) return;
    portal!.onOpenPath!(resolved);
  }

  @override
  bool updateShouldNotify(WorkspacePortal oldWidget) {
    return onOpenPath != oldWidget.onOpenPath ||
        workspaceDir != oldWidget.workspaceDir;
  }
}

String? normalizeWorkspacePath(String raw, {String? workspaceDir}) {
  var path = raw.trim();
  if (path.length < 2 || path.length > 240) return null;
  path = path.replaceAll(r'\', '/');
  path = path.replaceFirst(RegExp('^[\\s`\'"(\\[{<]+'), '');
  path = path.replaceFirst(RegExp('[`\'",.;:)\\]}>\\s]+\$'), '');
  if (path.startsWith('./')) path = path.substring(2);
  final lower = path.toLowerCase();
  if (lower.contains('://') ||
      lower.startsWith('package:') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('tel:')) {
    return null;
  }
  final root = workspaceDir
      ?.trim()
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  if (root != null &&
      root.isNotEmpty &&
      path.toLowerCase().startsWith('${root.toLowerCase()}/')) {
    path = path.substring(root.length + 1);
  }
  if (RegExp(r'^[A-Za-z]:/').hasMatch(path) || path.startsWith('/')) {
    return null;
  }
  if (path.startsWith('../') || path.contains('/../')) return null;
  final segments = path.split('/');
  if (segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return null;
  }
  if (_looksLikeHostSegment(segments.first)) return null;
  if (path.isEmpty) return null;
  return path;
}

bool looksLikeNormalizedWorkspacePath(String path) {
  if (path.isEmpty || path.contains('://')) return false;
  final name = path.split('/').last;
  if (name.isEmpty || name == '.' || name == '..') return false;
  if (name.startsWith('.') && name.length > 1) return true;
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1) {
    final ext = name.substring(dot + 1).toLowerCase();
    if (workspacePathExtensions.contains(ext)) return true;
  }
  return workspacePathBasenames.contains(name.toLowerCase());
}

bool looksLikeWorkspacePath(String raw, {String? workspaceDir}) {
  final path = normalizeWorkspacePath(raw, workspaceDir: workspaceDir);
  return path != null && looksLikeNormalizedWorkspacePath(path);
}

List<WorkspacePathMatch> findWorkspacePaths(
  String text, {
  String? workspaceDir,
}) {
  final matches = <WorkspacePathMatch>[];
  for (final match in _workspacePathCandidate.allMatches(text)) {
    if (_hasRejectedPathContext(text, match.start)) continue;
    final path = normalizeWorkspacePath(
      match.group(0)!,
      workspaceDir: workspaceDir,
    );
    if (path == null || !looksLikeNormalizedWorkspacePath(path)) continue;
    matches.add(
      WorkspacePathMatch(start: match.start, end: match.end, path: path),
    );
  }
  return matches;
}

List<String> extractWorkspacePaths(String text, {String? workspaceDir}) {
  final seen = <String>{};
  return [
    for (final match in findWorkspacePaths(text, workspaceDir: workspaceDir))
      if (seen.add(match.path)) match.path,
  ];
}

bool isSingleWorkspacePath(String text, {String? workspaceDir}) {
  final trimmed = text.trim();
  final normalized = normalizeWorkspacePath(
    trimmed,
    workspaceDir: workspaceDir,
  );
  if (normalized == null) return false;
  final paths = extractWorkspacePaths(trimmed, workspaceDir: workspaceDir);
  return paths.length == 1 && paths.first == normalized;
}

bool _looksLikeHostSegment(String segment) {
  final lower = segment.toLowerCase();
  if (lower.startsWith('www.')) return true;
  final dot = lower.lastIndexOf('.');
  if (dot <= 0 || dot >= lower.length - 1) return false;
  return _hostTlds.contains(lower.substring(dot + 1));
}

bool _hasRejectedPathContext(String text, int start) {
  if (start <= 0) return false;
  final prev = text[start - 1];
  if (prev == '/' || prev == r'\') return true;
  if (prev != ':') return false;
  return _schemePrefix.hasMatch(text.substring(0, start).toLowerCase());
}

TextSpan workspacePathInlineSpan(
  String text, {
  TextStyle? style,
  String? workspaceDir,
  ValueChanged<String>? onOpenPath,
  List<TapGestureRecognizer>? recognizers,
  Color linkColor = AppColors.link,
}) {
  final matches = findWorkspacePaths(text, workspaceDir: workspaceDir);
  final base = style ?? const TextStyle();
  if (onOpenPath == null || matches.isEmpty) {
    return TextSpan(text: text, style: base);
  }
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in matches) {
    if (match.start < cursor) continue;
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    final label = text.substring(match.start, match.end);
    final pathStyle = base.copyWith(
      color: linkColor,
      fontWeight: FontWeight.w500,
      decoration: TextDecoration.combine([
        if (base.decoration != null) base.decoration!,
        TextDecoration.underline,
      ]),
      decorationThickness: 1,
    );
    if (label.length > 20) {
      // Long paths must share the parent RichText line metrics; a wrapping
      // Text inside a WidgetSpan can paint over the next paragraph line.
      final tapRecognizers = recognizers;
      final recognizer = tapRecognizers == null
          ? null
          : (TapGestureRecognizer()..onTap = () => onOpenPath(match.path));
      if (recognizer != null) {
        tapRecognizers!.add(recognizer);
      }
      spans.add(
        TextSpan(text: label, style: pathStyle, recognizer: recognizer),
      );
    } else {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onOpenPath(match.path),
              child: Text(label, style: pathStyle),
            ),
          ),
        ),
      );
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(style: base, children: spans);
}

class WorkspacePathText extends StatefulWidget {
  const WorkspacePathText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.selectable = false,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool selectable;

  @override
  State<WorkspacePathText> createState() => _WorkspacePathTextState();
}

class _WorkspacePathTextState extends State<WorkspacePathText> {
  final recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }
    recognizers.clear();
    final portal = WorkspacePortal.of(context);
    final span = workspacePathInlineSpan(
      widget.text,
      style: widget.style,
      workspaceDir: portal?.workspaceDir,
      onOpenPath: portal?.onOpenPath == null
          ? null
          : (path) => WorkspacePortal.openPath(context, path),
      recognizers: recognizers,
      linkColor: AppPalette.of(context).link,
    );
    if (widget.selectable) {
      return SelectableText.rich(span, maxLines: widget.maxLines);
    }
    return Text.rich(
      span,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}

class WorkspacePathLink extends StatelessWidget {
  const WorkspacePathLink({super.key, required this.path, this.style});

  final String path;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final portal = WorkspacePortal.of(context);
    final enabled = portal?.onOpenPath != null;
    final label = Text(
      path,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style:
          (style ??
                  const TextStyle(
                    fontFamily: AppTypography.codeFontFamily,
                    fontFamilyFallback: AppTypography.codeFontFamilyFallback,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ))
              .copyWith(
                color: enabled
                    ? AppPalette.of(context).link
                    : AppPalette.of(context).muted,
                decoration: enabled
                    ? TextDecoration.underline
                    : TextDecoration.none,
                decorationThickness: 1,
              ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: '打开工作区文件 $path',
      child: InkWell(
        onTap: enabled ? () => WorkspacePortal.openPath(context, path) : null,
        borderRadius: BorderRadius.circular(AppRadii.compact),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Align(alignment: Alignment.centerLeft, child: label),
        ),
      ),
    );
  }
}

class WorkspaceChangeEchoChip extends StatelessWidget {
  const WorkspaceChangeEchoChip({
    super.key,
    required this.echo,
    required this.onTap,
  });

  final WorkspaceChangeEcho echo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.surface);
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: Semantics(
        button: true,
        label: '${echo.label}，${echo.caption}',
        child: SignalPressEffect(
          builder: (context, pressed, child) => SignalAnimatedSurface(
            duration: appPressAnimationDuration(context, pressed),
            decoration: AppLiquidGlass.thin(
              context: context,
              borderRadius: radius,
              pressed: pressed,
            ),
            child: child,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: radius,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.gitCompare,
                      size: AppIconSizes.inline,
                      color: AppPalette.of(context).accentStrong,
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          echo.label,
                          style: TextStyle(
                            color: AppPalette.of(context).ink,
                            fontSize: 13,
                            height: 1.25,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          echo.caption,
                          style: TextStyle(
                            color: AppPalette.of(context).muted,
                            fontSize: 11,
                            height: 1.25,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
