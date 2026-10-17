import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'signal_console_theme.dart';

class WorkspaceDiffView extends StatefulWidget {
  const WorkspaceDiffView({super.key, required this.diff});

  final String diff;

  @override
  State<WorkspaceDiffView> createState() => _WorkspaceDiffViewState();
}

class _WorkspaceDiffViewState extends State<WorkspaceDiffView> {
  final verticalController = ScrollController();
  final horizontalController = ScrollController();
  late List<_DiffLine> lines;
  bool wrapLines = false;
  double fontSize = 13;
  double? contentWidth;
  double? numberWidth;

  @override
  void initState() {
    super.initState();
    lines = _parseDiff(widget.diff);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    resetMeasurements();
  }

  @override
  void didUpdateWidget(covariant WorkspaceDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diff != widget.diff) {
      lines = _parseDiff(widget.diff);
      resetMeasurements();
    }
  }

  void resetMeasurements() {
    contentWidth = null;
    numberWidth = null;
  }

  @override
  void dispose() {
    verticalController.dispose();
    horizontalController.dispose();
    super.dispose();
  }

  TextStyle codeStyle(AppPalette palette) => TextStyle(
    color: palette.ink,
    fontFamily: AppTypography.codeFontFamily,
    fontFamilyFallback: AppTypography.codeFontFamilyFallback,
    fontSize: fontSize,
    height: 1.55,
    letterSpacing: 0,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  void measureColumns(TextStyle style, TextScaler scaler) {
    if (numberWidth != null && (wrapLines || contentWidth != null)) return;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    );
    try {
      final maxNumber = lines.fold<int>(
        1,
        (value, line) =>
            math.max(value, math.max(line.oldNumber ?? 0, line.newNumber ?? 0)),
      );
      painter.text = TextSpan(text: maxNumber.toString(), style: style);
      painter.layout();
      numberWidth = math.max(24, painter.width.ceilToDouble() + 12);
      if (!wrapLines && contentWidth == null) {
        var widest = 0.0;
        for (final line in lines) {
          painter.text = TextSpan(text: line.text, style: style);
          painter.layout();
          widest = math.max(widest, painter.width);
        }
        contentWidth = widest.ceilToDouble() + 1;
      }
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final style = codeStyle(palette);
    measureColumns(style, MediaQuery.textScalerOf(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.line, width: 0.5)),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 14, end: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '差异',
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                ),
                IconButton(
                  key: const ValueKey('workspace-diff-wrap'),
                  tooltip: wrapLines ? '关闭自动换行' : '自动换行',
                  isSelected: wrapLines,
                  onPressed: () => setState(() => wrapLines = !wrapLines),
                  icon: const Icon(
                    LucideIcons.arrowLeftRight,
                    size: AppIconSizes.control,
                  ),
                  selectedIcon: const Icon(
                    LucideIcons.wrapText,
                    size: AppIconSizes.control,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: wrapLines ? palette.accentSoft : null,
                    foregroundColor: palette.ink,
                  ),
                ),
                PopupMenuButton<double>(
                  key: const ValueKey('workspace-diff-font-size'),
                  tooltip: '代码字号',
                  icon: Icon(
                    LucideIcons.type,
                    size: AppIconSizes.control,
                    color: palette.ink,
                  ),
                  onSelected: (value) => setState(() {
                    fontSize = value;
                    resetMeasurements();
                  }),
                  itemBuilder: (_) => [
                    for (final size in const <double>[12, 13, 14, 16, 18])
                      CheckedPopupMenuItem<double>(
                        value: size,
                        checked: fontSize == size,
                        child: Text('${size.toInt()} pt'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: lines.isEmpty
              ? Center(
                  child: Text(
                    '没有可显示的差异',
                    style: TextStyle(color: palette.muted, fontSize: 13),
                  ),
                )
              : SelectionArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final list = ListView.builder(
                        key: const ValueKey('workspace-diff'),
                        controller: verticalController,
                        padding: const EdgeInsets.only(top: 8, bottom: 32),
                        itemCount: lines.length,
                        itemBuilder: (context, index) => buildLine(
                          lines[index],
                          palette: palette,
                          style: style,
                        ),
                      );
                      if (wrapLines) {
                        return Scrollbar(
                          controller: verticalController,
                          child: list,
                        );
                      }
                      return Scrollbar(
                        controller: verticalController,
                        notificationPredicate: (notification) =>
                            notification.metrics.axis == Axis.vertical,
                        child: Scrollbar(
                          controller: horizontalController,
                          scrollbarOrientation: ScrollbarOrientation.bottom,
                          thumbVisibility: true,
                          notificationPredicate: (notification) =>
                              notification.metrics.axis == Axis.horizontal,
                          child: SingleChildScrollView(
                            key: const ValueKey(
                              'workspace-diff-horizontal-scroll',
                            ),
                            controller: horizontalController,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: math.max(
                                constraints.maxWidth,
                                numberWidth! * 2 + contentWidth! + 32,
                              ),
                              height: constraints.maxHeight,
                              child: list,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget buildLine(
    _DiffLine line, {
    required AppPalette palette,
    required TextStyle style,
  }) {
    final background = switch (line.kind) {
      _DiffLineKind.added => palette.success.withValues(alpha: 0.08),
      _DiffLineKind.removed => palette.danger.withValues(alpha: 0.07),
      _DiffLineKind.hunk => palette.accent.withValues(alpha: 0.06),
      _ => Colors.transparent,
    };
    Widget number(int? value) => SizedBox(
      width: numberWidth,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          value?.toString() ?? '',
          textAlign: TextAlign.right,
          textDirection: TextDirection.ltr,
          style: style.copyWith(color: palette.muted),
        ),
      ),
    );
    return ColoredBox(
      color: background,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          textDirection: TextDirection.ltr,
          children: [
            SelectionContainer.disabled(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(color: palette.line, width: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  textDirection: TextDirection.ltr,
                  children: [number(line.oldNumber), number(line.newNumber)],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  line.text.isEmpty ? ' ' : line.text,
                  softWrap: wrapLines,
                  textDirection: TextDirection.ltr,
                  style: line.kind == _DiffLineKind.hunk
                      ? style.copyWith(color: palette.accent)
                      : style,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DiffLineKind { metadata, hunk, context, added, removed }

class _DiffLine {
  const _DiffLine(this.text, this.kind, {this.oldNumber, this.newNumber});

  final String text;
  final _DiffLineKind kind;
  final int? oldNumber;
  final int? newNumber;
}

final _diffHunk = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

List<_DiffLine> _parseDiff(String diff) {
  final result = <_DiffLine>[];
  var oldNumber = 0;
  var newNumber = 0;
  var oldRemaining = 0;
  var newRemaining = 0;
  for (final text in const LineSplitter().convert(diff)) {
    final hunk = _diffHunk.firstMatch(text);
    if (hunk != null) {
      oldNumber = int.parse(hunk[1]!);
      newNumber = int.parse(hunk[3]!);
      oldRemaining = int.parse(hunk[2] ?? '1');
      newRemaining = int.parse(hunk[4] ?? '1');
      result.add(_DiffLine(text, _DiffLineKind.hunk));
      continue;
    }
    if (text.startsWith('diff --git ')) {
      oldRemaining = 0;
      newRemaining = 0;
    }
    if (text.startsWith('+') && newRemaining > 0) {
      result.add(_DiffLine(text, _DiffLineKind.added, newNumber: newNumber++));
      newRemaining--;
    } else if (text.startsWith('-') && oldRemaining > 0) {
      result.add(
        _DiffLine(text, _DiffLineKind.removed, oldNumber: oldNumber++),
      );
      oldRemaining--;
    } else if (text.startsWith(' ') && oldRemaining > 0 && newRemaining > 0) {
      result.add(
        _DiffLine(
          text,
          _DiffLineKind.context,
          oldNumber: oldNumber++,
          newNumber: newNumber++,
        ),
      );
      oldRemaining--;
      newRemaining--;
    } else {
      result.add(_DiffLine(text, _DiffLineKind.metadata));
    }
  }
  return result;
}
