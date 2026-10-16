import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' as hl;

import 'signal_console_theme.dart';

class MessageCodeText extends StatefulWidget {
  const MessageCodeText({
    super.key,
    required this.code,
    required this.style,
    this.language,
    this.softWrap = false,
    this.textKey,
  });

  final String code;
  final String? language;
  final TextStyle style;
  final bool softWrap;
  final Key? textKey;

  @override
  State<MessageCodeText> createState() => _MessageCodeTextState();
}

class _MessageCodeTextState extends State<MessageCodeText> {
  late List<hl.Node>? nodes = parseCode();

  List<hl.Node>? parseCode() {
    final language = widget.language?.trim().toLowerCase();
    if (language == null || language.isEmpty) return null;
    try {
      return hl.highlight.parse(widget.code, language: language).nodes;
    } catch (_) {
      return null;
    }
  }

  @override
  void didUpdateWidget(covariant MessageCodeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.code != oldWidget.code ||
        widget.language != oldWidget.language) {
      nodes = parseCode();
    }
  }

  Color? tokenColor(
    String? kind,
    AppPalette palette, {
    String? parentKind,
  }) => switch (kind) {
    'comment' || 'quote' => palette.codeComment,
    'keyword' || 'built_in' || 'meta-keyword' => palette.codeKeyword,
    'string' || 'regexp' || 'meta-string' || 'addition' => palette.codeString,
    'number' => palette.codeNumber,
    'literal' || 'symbol' || 'constant' => palette.codeConstant,
    'title' => parentKind == 'class' ? palette.codeType : palette.codeFunction,
    'section' => palette.codeFunction,
    'type' => palette.codeType,
    'variable' || 'template-variable' => palette.codeVariable,
    'attr' when widget.language?.trim().toLowerCase() == 'json' =>
      palette.codeProperty,
    'attr' || 'attribute' => palette.codeAttribute,
    'property' ||
    'tag' ||
    'name' ||
    'selector-tag' ||
    'selector-class' ||
    'deletion' => palette.codeProperty,
    'subst' || 'meta' || 'embedded' => palette.codeEmbedded,
    'operator' || 'punctuation' => palette.codeOperator,
    _ => null,
  };

  TextSpan tokenSpan(hl.Node node, AppPalette palette, {String? parentKind}) {
    final color = tokenColor(node.className, palette, parentKind: parentKind);
    return TextSpan(
      text: node.value,
      style: color == null ? null : TextStyle(color: color),
      children: node.children
          ?.map(
            (child) => tokenSpan(
              child,
              palette,
              parentKind: node.className ?? parentKind,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Text.rich(
      TextSpan(
        text: nodes == null ? widget.code : null,
        children: nodes
            ?.map((node) => tokenSpan(node, palette))
            .toList(growable: false),
      ),
      key: widget.textKey,
      style: widget.style,
      softWrap: widget.softWrap,
    );
  }
}
