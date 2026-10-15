import 'dart:convert';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/directory_api.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'directory browsing preserves host paths and bearer authentication',
    () async {
      const path = r'C:\Projects\中文 & app';
      final client = RemoteApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/tunnel/api/directories');
          expect(request.url.queryParameters['path'], path);
          expect(request.headers['authorization'], 'Bearer test-token');
          return http.Response(
            jsonEncode({
              'path': path,
              'parentPath': r'C:\Projects',
              'roots': [],
              'directories': [
                {'name': 'src', 'path': '$path\\src'},
              ],
              'truncated': false,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.close);
      final api = DirectoryApi(
        client: client,
        origin: Uri.parse('https://example.test/tunnel'),
        token: 'test-token',
      );
      final listing = await api.browse(path);
      expect(listing.path, path);
      expect(listing.directories.single.path, '$path\\src');
    },
  );

  test(
    'opening a directory sends the selected engine and reads the catalog',
    () async {
      final client = RemoteApiClient(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/projects/open-directory');
          expect(jsonDecode(request.body), {
            'path': '/projects/new',
            'engine': 'codex',
          });
          expect(request.headers['content-type'], 'application/json');
          return http.Response(
            jsonEncode({
              'ok': true,
              'catalog': {
                'version': 1,
                'activeProjectId': 'new-project',
                'activeSessionId': 'new-session',
                'projects': [
                  {'id': 'new-project', 'name': 'new', 'path': '/projects/new'},
                ],
                'sessions': [
                  {
                    'id': 'new-session',
                    'projectId': 'new-project',
                    'title': '新会话',
                    'engine': 'codex',
                  },
                ],
              },
            }),
            201,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.close);
      final api = DirectoryApi(
        client: client,
        origin: Uri.parse('https://example.test'),
        token: 'test-token',
      );
      final catalog = await api.createSession(
        '/projects/new',
        SessionEngine.codex,
      );
      expect(catalog.activeProject?.path, '/projects/new');
      expect(catalog.sessions.single.engine, SessionEngine.codex);
    },
  );

  for (final entry in [
    (401, 'unauthorized', 'unauthorized'),
    (404, 'not_found', 'directory_selection_unavailable'),
    (404, 'directory_not_found', 'directory_not_found'),
    (403, 'directory_access_denied', 'directory_access_denied'),
    (409, 'claude_is_busy', 'claude_is_busy'),
  ]) {
    test('directory error ${entry.$2} remains actionable', () async {
      final client = RemoteApiClient(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'error': entry.$2}), entry.$1),
        ),
      );
      addTearDown(client.close);
      final api = DirectoryApi(
        client: client,
        origin: Uri.parse('https://example.test'),
        token: 'test-token',
      );
      await expectLater(
        api.browse(null),
        throwsA(
          isA<DirectoryRequestException>().having(
            (failure) => failure.code,
            'code',
            entry.$3,
          ),
        ),
      );
    });
  }
}
