final _terminalEscapes = RegExp(
  r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|(?:\x1B\[|\x9B)[0-?]*[ -/]*[@-~]|\x1B[@-_]',
);
final _terminalControls = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');
final _credentialAssignment = RegExp(
  r'''(["']?\b(?:[\w-]*(?:api[_-]?key|token|secret|password)|authorization)["']?\s*[:=]\s*)(?:Bearer\s+|Basic\s+)?(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&}\]]+)''',
  caseSensitive: false,
);
final _authorizationValue = RegExp(
  r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/-]+=*',
  caseSensitive: false,
);
final _apiKeyValue = RegExp(r'\bsk-[A-Za-z0-9_-]{8,}\b');
final _urlCredentials = RegExp(r'(https?://)[^/\s@]+@');
final _logPrefix = RegExp(
  r'^(?:\[?\d{4}-\d{2}-\d{2}|\[?(?:WARN|INFO|DEBUG|TRACE)\b)',
  caseSensitive: false,
);

String cleanFailureLog(String raw) => raw
    .replaceAll(_terminalEscapes, '')
    .replaceAll(_terminalControls, '')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .trim();

// shortcut: Only common credential formats are masked; extend for new log formats.
String safeFailureLog(String raw) => cleanFailureLog(raw)
    .replaceAllMapped(_credentialAssignment, (match) => '${match[1]}[已隐藏]')
    .replaceAllMapped(_authorizationValue, (match) => '${match[1]} [已隐藏]')
    .replaceAll(_apiKeyValue, '[已隐藏]')
    .replaceAllMapped(_urlCredentials, (match) => '${match[1]}[已隐藏]@');

String failureSummary(String raw) {
  final text = safeFailureLog(raw);
  if (text.isEmpty) return '未收到具体错误信息，请检查电脑端状态。';
  if (text.contains('\n') || text.length > 180 || _logPrefix.hasMatch(text)) {
    return '查看错误详情以定位问题。';
  }
  return text;
}
