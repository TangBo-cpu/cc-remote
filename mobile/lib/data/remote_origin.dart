Uri resolveRemotePath(Uri origin, String path) {
  final basePath = origin.path.isEmpty
      ? '/'
      : origin.path.endsWith('/')
      ? origin.path
      : '${origin.path}/';
  final relativePath = path.startsWith('/') ? path.substring(1) : path;
  return origin
      .replace(path: basePath, query: '', fragment: '')
      .resolve(relativePath);
}

Uri remoteWebSocketUri(Uri origin) {
  final resolved = resolveRemotePath(origin, 'ws');
  final scheme = resolved.scheme == 'https' ? 'wss' : 'ws';
  return resolved.replace(scheme: scheme);
}
