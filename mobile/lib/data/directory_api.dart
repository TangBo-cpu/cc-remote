import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'remote_models.dart';

class RemoteDirectory {
  const RemoteDirectory({required this.name, required this.path});

  final String name;
  final String path;

  factory RemoteDirectory.fromJson(Map<String, dynamic> json) {
    if (json['name'] is! String || json['path'] is! String) {
      throw const FormatException('bad_directory_entry');
    }
    return RemoteDirectory(
      name: json['name'] as String,
      path: json['path'] as String,
    );
  }
}

class RemoteDirectoryListing {
  const RemoteDirectoryListing({
    this.path,
    this.parentPath,
    this.roots = const [],
    this.directories = const [],
    this.truncated = false,
  });

  final String? path;
  final String? parentPath;
  final List<RemoteDirectory> roots;
  final List<RemoteDirectory> directories;
  final bool truncated;

  factory RemoteDirectoryListing.fromJson(Map<String, dynamic> json) {
    List<RemoteDirectory> entries(String key) {
      final raw = json[key];
      if (raw is! List) throw const FormatException('bad_directory_listing');
      return raw.map((entry) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('bad_directory_entry');
        }
        return RemoteDirectory.fromJson(entry);
      }).toList();
    }

    if ((json['path'] != null && json['path'] is! String) ||
        (json['parentPath'] != null && json['parentPath'] is! String)) {
      throw const FormatException('bad_directory_path');
    }
    return RemoteDirectoryListing(
      path: json['path'] as String?,
      parentPath: json['parentPath'] as String?,
      roots: entries('roots'),
      directories: entries('directories'),
      truncated: json['truncated'] == true,
    );
  }
}

class DirectoryRequestException implements Exception {
  const DirectoryRequestException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  String get message => switch (code) {
    'unauthorized' => '连接授权已失效，请返回重新连接电脑',
    'directory_selection_unavailable' => '请先更新电脑端，再使用目录选择功能',
    'directory_path_invalid' => '请输入电脑上的完整绝对路径',
    'directory_not_found' => '目录不存在，请检查路径或选择其他目录',
    'directory_not_directory' => '此路径是文件，请选择文件夹',
    'directory_access_denied' => '电脑端无法访问此目录，请选择其他目录或检查权限',
    'claude_is_busy' || 'directory_busy' => '当前任务或附件操作尚未结束，请稍后再新建对话',
    'connection_changed' => '连接或当前会话已变化，请返回后重新选择目录',
    _ => '操作未完成，请检查电脑连接后重试',
  };
}

String directoryErrorMessage(Object error) =>
    error is DirectoryRequestException ? error.message : '无法连接电脑，请检查连接后重试';

class DirectoryApi {
  const DirectoryApi({
    required this.client,
    required this.origin,
    required this.token,
  });

  final RemoteApiClient client;
  final Uri origin;
  final String token;

  Map<String, dynamic> decode(http.Response response, int expectedStatus) {
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      if (response.statusCode == expectedStatus) rethrow;
    }
    if (response.statusCode != expectedStatus) {
      final code = body is Map<String, dynamic> ? body['error'] : null;
      throw DirectoryRequestException(
        response.statusCode == 401
            ? 'unauthorized'
            : response.statusCode == 404 && code != 'directory_not_found'
            ? 'directory_selection_unavailable'
            : code is String
            ? code
            : 'directory_request_failed',
        statusCode: response.statusCode,
      );
    }
    if (body is! Map<String, dynamic>) {
      throw const FormatException('bad_directory_response');
    }
    return body;
  }

  Future<RemoteDirectoryListing> browse(String? path) async {
    final route = Uri(
      path: '/api/directories',
      queryParameters: path == null ? null : {'path': path},
    );
    final response = await client.get(origin, route.toString(), token: token);
    return RemoteDirectoryListing.fromJson(decode(response, 200));
  }

  Future<RemoteProjectCatalog> createSession(
    String path,
    SessionEngine engine,
  ) async {
    final response = await client.post(
      origin,
      '/api/projects/open-directory',
      token: token,
      jsonBody: true,
      body: jsonEncode({'path': path, 'engine': engine.wireName}),
    );
    final body = decode(response, 201);
    final rawCatalog = body['catalog'];
    final catalog = rawCatalog is Map<String, dynamic>
        ? RemoteProjectCatalog.tryParse(rawCatalog)
        : null;
    if (catalog == null) throw const FormatException('bad_directory_catalog');
    return catalog;
  }
}
