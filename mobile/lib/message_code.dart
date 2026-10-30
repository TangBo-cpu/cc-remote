import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' as hl;

import 'signal_console_theme.dart';

List<hl.Node>? _highlightCode(({String code, String language}) input) {
  try {
    return hl.highlight.parse(input.code, language: input.language).nodes;
  } catch (_) {
    return null;
  }
}

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
  static const backgroundHighlightThreshold = 8000;
  List<hl.Node>? nodes;
  List<InlineSpan>? spans;
  AppPalette? spanPalette;
  int parseGeneration = 0;
  bool parsing = false;

  @override
  void initState() {
    super.initState();
    parseCode();
  }

  void parseCode() {
    parseGeneration++;
    nodes = null;
    spans = null;
    final language = widget.language?.trim().toLowerCase();
    if (language == null || language.isEmpty) return;
    if (widget.code.length < backgroundHighlightThreshold) {
      nodes = _highlightCode((code: widget.code, language: language));
    } else {
      unawaited(highlightInBackground());
    }
  }

  Future<void> highlightInBackground() async {
    if (parsing) return;
    parsing = true;
    try {
      while (mounted && widget.code.length >= backgroundHighlightThreshold) {
        final language = widget.language?.trim().toLowerCase();
        if (language == null || language.isEmpty) return;
        final generation = parseGeneration;
        final result = await compute(_highlightCode, (
          code: widget.code,
          language: language,
        ), debugLabel: 'code highlighting');
        if (!mounted) return;
        // Only the latest text may replace the plain-text fallback.
        if (generation != parseGeneration) continue;
        setState(() {
          nodes = result;
          spans = null;
        });
        return;
      }
    } catch (_) {
      // Keep the code readable if the worker cannot finish.
    } finally {
      parsing = false;
    }
  }

  @override
  void didUpdateWidget(covariant MessageCodeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.code != oldWidget.code ||
        widget.language != oldWidget.language) {
      parseCode();
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
    if (nodes != null && (spans == null || spanPalette != palette)) {
      spans = nodes!
          .map((node) => tokenSpan(node, palette))
          .toList(growable: false);
      spanPalette = palette;
    }
    return Text.rich(
      TextSpan(text: nodes == null ? widget.code : null, children: spans),
      key: widget.textKey,
      style: widget.style,
      softWrap: widget.softWrap,
    );
  }
}
