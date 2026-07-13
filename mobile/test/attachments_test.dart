import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cc_remote/attachments.dart';

void main() {
  test(
    'uploads multipart files with bearer auth and parses metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cc-remote-mobile-attachment-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}error.log');
      await file.writeAsString('failure');
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/sessions/session-1/attachments');
        expect(request.headers['authorization'], 'Bearer secret');
        expect(
          request.headers['content-type'],
          startsWith('multipart/form-data'),
        );
        expect(request.bodyBytes, isNotEmpty);
        return http.Response(
          jsonEncode({
            'attachments': [
              {
                'id': 'attachment-1',
                'name': 'error.log',
                'mimeType': 'text/plain',
                'size': 7,
              },
            ],
          }),
          201,
        );
      });
      addTearDown(client.close);

      final attachments = await AttachmentUploader(client: client).upload(
        origin: Uri.parse('https://cc.example'),
        token: 'secret',
        sessionId: 'session-1',
        files: [
          AttachmentDraft(
            path: file.path,
            name: 'error.log',
            size: await file.length(),
            mimeType: 'text/plain',
          ),
        ],
      );

      expect(attachments.single.id, 'attachment-1');
      expect(attachments.single.name, 'error.log');
    },
  );

  test(
    'rejects files over the mobile upload limit before networking',
    () async {
      final client = MockClient((_) async {
        fail('network should not be called');
      });
      addTearDown(client.close);

      await expectLater(
        AttachmentUploader(client: client).upload(
          origin: Uri.parse('https://cc.example'),
          token: 'secret',
          sessionId: 'session-1',
          files: const [
            AttachmentDraft(
              path: 'large.bin',
              name: 'large.bin',
              size: maxAttachmentBytes + 1,
              mimeType: 'application/octet-stream',
            ),
          ],
        ),
        throwsA(
          isA<AttachmentException>().having(
            (error) => error.code,
            'code',
            'attachment_too_large',
          ),
        ),
      );
    },
  );
}
