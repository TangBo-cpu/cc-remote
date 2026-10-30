import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'remote_models.dart';

class NativeDesktopSession {
  const NativeDesktopSession({
    required this.sessionId,
    required this.engine,
    required this.title,
    required this.workspaceDir,
    required this.updatedAt,
  });

  final String sessionId;
  final SessionEngine engine;
  final String title;
  final String workspaceDir;
  final DateTime updatedAt;

  factory NativeDesktopSession.fromJson(Map<String, dynamic> json) {
    if (json['sessionId'] is! String ||
        (json['sessionId'] as String).isEmpty ||
        !SessionEngine.values.any(
          (engine) => engine.wireName == json['engine'],
        ) ||
        json['title'] is! String ||
        json['workspaceDir'] is! String ||
        json['updatedAt'] is! num ||
        !(json['updatedAt'] as num).isFinite) {
      throw const FormatException('bad_native_session');
    }
    return NativeDesktopSession(
      sessionId: json['sessionId'] as String,
      engine: SessionEngine.fromWire(json['engine']),
      title: json['title'] as String,
      workspaceDir: json['workspaceDir'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num).toInt(),
      ),
    );
  }
}

typedef NativeSessionPage = ({
  List<NativeDesktopSession> sessions,
  String? nextCursor,
  int maxSessionBytes,
});
typedef NativeSessionImport = ({
  RemoteProjectCatalog catalog,
  Map<String, dynamic> transcript,
});

class NativeSessionException implements Exception {
  const NativeSessionException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  String get message => switch (code) {
    'unauthorized' => '连接授权已失效，请返回重新连接电脑',
    'native_sessions_unavailable' => '请先更新电脑端，再使用会话同步',
    'native_session_not_found' => '此会话已不存在或已被过滤，请刷新列表',
    'native_session_too_large' => '此会话已超过同步大小限制，请选择其他会话',
    'native_session_list_failed' => '无法读取会话列表，请确认电脑上已安装并登录此引擎',
    'native_history_sync_failed' => '同步失败，已有会话已保留，请重试',
    'directory_not_found' ||
    'directory_not_directory' ||
    'directory_path_invalid' => '此会话的电脑目录已不可用，请先恢复目录',
    'directory_access_denied' => '电脑端无法访问此会话的目录，请检查权限',
    'claude_is_busy' => '当前任务或附件操作尚未结束，请稍后同步',
    'connection_changed' => '连接或当前会话已变化，请返回后重新选择',
    _ => '操作未完成，请检查电脑连接后重试',
  };
}

String nativeSessionErrorMessage(Object error) =>
    error is NativeSessionException ? error.message : '操作未完成，请检查电脑连接后重试';

class NativeSessionApi {
  const NativeSessionApi({
    required this.client,
    required this.origin,
    required this.token,
  });

  final RemoteApiClient client;
  final Uri origin;
  final String token;

  Map<String, dynamic> decode(http.Response response) {
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      if (response.statusCode == 200) rethrow;
    }
    if (response.statusCode != 200) {
      final code = body is Map<String, dynamic> ? body['error'] : null;
      throw NativeSessionException(
        response.statusCode == 401
            ? 'unauthorized'
            : response.statusCode == 404 &&
                  (code == null || code == 'not_found')
            ? 'native_sessions_unavailable'
            : code is String
            ? code
            : 'native_session_request_failed',
        statusCode: response.statusCode,
      );
    }
    if (body is! Map<String, dynamic>) {
      throw const FormatException('bad_native_session_response');
    }
    return body;
  }

  Future<NativeSessionPage> list(SessionEngine engine, String? cursor) async {
    final route = Uri(
      path: '/api/native-sessions',
      queryParameters: {'engine': engine.wireName, 'cursor': ?cursor},
    );
    final body = decode(
      await client.get(
        origin,
        route.toString(),
        token: token,
        timeout: const Duration(seconds: 30),
      ),
    );
    final sessions = body['sessions'];
    final nextCursor = body['nextCursor'];
    final maxSessionBytes = body['maxSessionBytes'];
    if (sessions is! List ||
        nextCursor != null && nextCursor is! String ||
        cursor != null && nextCursor == cursor ||
        maxSessionBytes is! int ||
        maxSessionBytes <= 0) {
      throw const FormatException('bad_native_session_list');
    }
    return (
      sessions: sessions.map((entry) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('bad_native_session');
        }
        final session = NativeDesktopSession.fromJson(entry);
        if (session.engine != engine) {
          throw const FormatException('bad_native_session_engine');
        }
        return session;
      }).toList(),
      nextCursor: nextCursor as String?,
      maxSessionBytes: maxSessionBytes,
    );
  }

  Future<NativeSessionImport> sync(NativeDesktopSession session) async {
    final body = decode(
      await client.post(
        origin,
        '/api/native-sessions/sync',
        token: token,
        jsonBody: true,
        timeout: const Duration(seconds: 60),
        body: jsonEncode({
          'engine': session.engine.wireName,
          'sessionId': session.sessionId,
        }),
      ),
    );
    final rawCatalog = body['catalog'];
    final catalog = rawCatalog is Map<String, dynamic>
        ? RemoteProjectCatalog.tryParse(rawCatalog)
        : null;
    final transcript = body['transcript'];
    if (catalog == null ||
        transcript is! Map<String, dynamic> ||
        transcript['sessionId'] != catalog.activeSessionId ||
        transcript['engine'] != session.engine.wireName ||
        RemoteTranscriptSnapshot.tryParse(transcript) == null) {
      throw const FormatException('bad_native_session_import');
    }
    return (catalog: catalog, transcript: transcript);
  }
}
