import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Adjusts block and list spacing without rebuilding parsed inline spans.
class MessageMarkdownBody extends MarkdownBody {
  const MessageMarkdownBody({
    super.key,
    required super.data,
    required super.styleSheet,
    super.selectable,
    super.softLineBreak,
    super.onTapLink,
    super.builders,
  });

  @override
  Widget build(BuildContext context, List<Widget>? children) {
    final layout = _MessageMarkdownLayout(
      context,
      blockSpacing: styleSheet?.blockSpacing ?? 12,
      bodyFontSize: styleSheet?.p?.fontSize ?? 16,
    );
    return super.build(
      context,
      children == null ? null : layout.applyChildren(children),
    );
  }
}

class _MessageMarkdownLayout {
  _MessageMarkdownLayout(
    this.context, {
    required this.blockSpacing,
    required this.bodyFontSize,
  });

  final BuildContext context;
  final double blockSpacing;
  final double bodyFontSize;

  // flutter_markdown_plus renders each list as alternating rows and spacers.
  bool _isListRow(Widget widget) {
    if (widget is! Row || widget.children.length != 2) return false;
    final marker = widget.children.first;
    if (marker is! SizedBox || widget.children.last is! Flexible) return false;
    final padding = marker.child;
    if (padding is! Padding) return false;
    return padding.child is Text || padding.child is Icon;
  }

  bool _isBlockSpacer(Widget widget) =>
      widget is SizedBox &&
      widget.height == blockSpacing &&
      widget.width == null &&
      widget.child == null;

  bool _isListColumn(Column column) {
    if (column.children.isEmpty || column.children.length.isEven) return false;
    for (var index = 0; index < column.children.length; index++) {
      final child = column.children[index];
      if (index.isEven ? !_isListRow(child) : !_isBlockSpacer(child)) {
        return false;
      }
    }
    return true;
  }

  double _markerWidth(Row row) {
    final box = row.children.first as SizedBox;
    final padding = box.child! as Padding;
    final marker = padding.child!;
    final inset = padding.padding
        .resolve(Directionality.of(context))
        .horizontal;
    final minWidth =
        (MediaQuery.textScalerOf(context).scale(bodyFontSize) * 1.5)
            .ceilToDouble();
    if (marker is Text) {
      final label = marker.data ?? '';
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: DefaultTextStyle.of(context).style.merge(marker.style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width.ceilToDouble();
      painter.dispose();
      return math.max(minWidth, width) + inset;
    }
    return math.max(minWidth, (marker as Icon).size ?? 16) + inset;
  }

  double _spacingAfter(Widget widget) {
    if (widget is Column && widget.children.isNotEmpty) {
      return _spacingAfter(widget.children.last);
    }
    if (widget is Padding && widget.child is Wrap) {
      final bottom = widget.padding.resolve(Directionality.of(context)).bottom;
      if (bottom > 0) return bottom;
    }
    return blockSpacing;
  }

  List<Widget> applyChildren(
    List<Widget> children, {
    bool isList = false,
    double? markerWidth,
  }) {
    final result = <Widget>[];
    Widget? previous;
    for (final child in children) {
      if (_isBlockSpacer(child) && previous != null) {
        result.add(SizedBox(height: isList ? 6 : _spacingAfter(previous)));
      } else {
        result.add(apply(child, markerWidth: markerWidth));
        previous = child;
      }
    }
    return result;
  }

  Widget apply(Widget widget, {double? markerWidth}) {
    if (widget is Column) {
      final isList = _isListColumn(widget);
      final width = isList
          ? widget.children.whereType<Row>().map(_markerWidth).reduce(math.max)
          : null;
      final column = Column(
        key: widget.key,
        mainAxisAlignment: widget.mainAxisAlignment,
        mainAxisSize: widget.mainAxisSize,
        crossAxisAlignment: widget.crossAxisAlignment,
        textDirection: widget.textDirection,
        verticalDirection: widget.verticalDirection,
        textBaseline: widget.textBaseline,
        spacing: widget.spacing,
        children: applyChildren(
          widget.children,
          isList: isList,
          markerWidth: width,
        ),
      );
      return isList
          ? Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: column,
            )
          : column;
    }
    if (_isListRow(widget)) {
      final row = widget as Row;
      final marker = row.children.first as SizedBox;
      final body = row.children.last as Flexible;
      return Row(
        key: row.key,
        mainAxisAlignment: row.mainAxisAlignment,
        mainAxisSize: row.mainAxisSize,
        crossAxisAlignment: row.crossAxisAlignment,
        textDirection: row.textDirection,
        verticalDirection: row.verticalDirection,
        textBaseline: row.textBaseline,
        spacing: row.spacing,
        children: [
          SizedBox(
            key: marker.key,
            width: markerWidth ?? _markerWidth(row),
            height: marker.height,
            child: marker.child,
          ),
          Flexible(
            key: body.key,
            flex: body.flex,
            fit: body.fit,
            child: apply(body.child),
          ),
        ],
      );
    }
    if (widget is Padding && widget.child != null) {
      final insets = widget.padding.resolve(Directionality.of(context));
      // Move text-block margins into sibling spacers, trimming the final block.
      final padding = widget.child is Wrap && insets.bottom > 0
          ? insets.copyWith(bottom: 0)
          : widget.padding;
      return Padding(
        key: widget.key,
        padding: padding,
        child: apply(widget.child!),
      );
    }
    if (widget is DecoratedBox && widget.child != null) {
      return DecoratedBox(
        key: widget.key,
        decoration: widget.decoration,
        position: widget.position,
        child: apply(widget.child!),
      );
    }
    return widget;
  }
}
