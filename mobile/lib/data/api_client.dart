import 'package:http/http.dart' as http;

import 'remote_origin.dart';

class RemoteApiClient {
  RemoteApiClient({http.Client? client}) : client = client ?? http.Client();

  final http.Client client;

  Future<http.Response> get(
    Uri origin,
    String path, {
    String? token,
    Duration timeout = const Duration(seconds: 12),
  }) {
    return client
        .get(resolveRemotePath(origin, path), headers: _headers(token))
        .timeout(timeout);
  }

  Future<http.Response> post(
    Uri origin,
    String path, {
    String? token,
    Object? body,
    bool jsonBody = false,
    Duration timeout = const Duration(seconds: 12),
  }) {
    return client
        .post(
          resolveRemotePath(origin, path),
          headers: _headers(token, jsonBody: jsonBody),
          body: body,
        )
        .timeout(timeout);
  }

  Future<http.Response> delete(
    Uri origin,
    String path, {
    String? token,
    Duration timeout = const Duration(seconds: 12),
  }) {
    return client
        .delete(resolveRemotePath(origin, path), headers: _headers(token))
        .timeout(timeout);
  }

  void close() => client.close();

  Map<String, String> _headers(String? token, {bool jsonBody = false}) {
    return {
      if (token != null) 'Authorization': 'Bearer $token',
      if (jsonBody) 'Content-Type': 'application/json',
    };
  }
}
