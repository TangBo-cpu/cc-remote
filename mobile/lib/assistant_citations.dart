final _citation = RegExp(
  '\uE200(cite|filecite)\uE202[^\uE200\uE201\r\n]*\uE201',
);
final _markdownCode = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[^\n]*(?:\n|$)|(`+)([\s\S]*?[^`])\2(?!`)',
  multiLine: true,
);

/// Citation IDs have no URL mapping in the transcript. Keep that limitation
/// visible without rendering the protocol's private-use delimiters.
String normalizeAssistantCitations(String text, {bool isStreaming = false}) {
  if (!text.contains('\uE200')) return text;

  final result = StringBuffer();
  var cursor = 0;
  for (final code in _markdownCode.allMatches(text)) {
    if (code.start < cursor) continue;
    result.write(
      _normalizeCitationText(text.substring(cursor, code.start), isStreaming),
    );
    var end = code.end;
    final fence = code.group(1);
    if (fence != null) {
      final closing = RegExp(
        '^ {0,3}${RegExp.escape(fence[0])}{${fence.length},}'
        r'[ \t]*\r?$',
        multiLine: true,
      ).firstMatch(text.substring(end));
      end = closing == null ? text.length : end + closing.end;
    }
    result.write(text.substring(code.start, end));
    cursor = end;
  }
  result.write(_normalizeCitationText(text.substring(cursor), isStreaming));
  return result.toString();
}

String _normalizeCitationText(String text, bool isStreaming) {
  final result = text.replaceAllMapped(
    _citation,
    (match) => _missingCitationLabel(match.group(1)!),
  );
  final start = result.lastIndexOf('\uE200');
  if (start < 0) return result;
  final tail = result.substring(start + 1);
  if (tail.contains('\uE201') || tail.contains('\n') || tail.contains('\r')) {
    return result;
  }
  for (final kind in ['cite', 'filecite']) {
    final head = '$kind\uE202';
    if (isStreaming && head.startsWith(tail)) {
      return result.substring(0, start);
    }
    if (tail.startsWith(head)) {
      return result.substring(0, start) +
          (isStreaming ? '' : _missingCitationLabel(kind));
    }
  }
  return result;
}

String _missingCitationLabel(String kind) =>
    kind == 'filecite' ? '〔文件引用未提供路径〕' : '〔来源链接未提供〕';
