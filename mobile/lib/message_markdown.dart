import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Adjusts list layout after Markdown parsing, retaining its inline spans.
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
    final layout = _MessageListLayout(
      context,
      blockSpacing: styleSheet?.blockSpacing ?? 12,
    );
    return super.build(
      context,
      children?.map(layout.apply).toList(growable: false),
    );
  }
}

class _MessageListLayout {
  _MessageListLayout(this.context, {required this.blockSpacing});

  final BuildContext context;
  final double blockSpacing;

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
      return math.max(label == '•' ? 18.0 : 24.0, width) + inset;
    }
    return math.max(18.0, (marker as Icon).size ?? 16) + inset;
  }

  Widget apply(Widget widget, {double? markerWidth}) {
    if (widget is Column) {
      final isList = _isListColumn(widget);
      final width = isList
          ? widget.children.whereType<Row>().map(_markerWidth).reduce(math.max)
          : null;
      return Column(
        key: widget.key,
        mainAxisAlignment: widget.mainAxisAlignment,
        mainAxisSize: widget.mainAxisSize,
        crossAxisAlignment: widget.crossAxisAlignment,
        textDirection: widget.textDirection,
        verticalDirection: widget.verticalDirection,
        textBaseline: widget.textBaseline,
        spacing: widget.spacing,
        children: [
          for (final child in widget.children)
            if (isList && _isBlockSpacer(child))
              const SizedBox(height: 6)
            else
              apply(child, markerWidth: width),
        ],
      );
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
      return Padding(
        key: widget.key,
        padding: widget.padding,
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
