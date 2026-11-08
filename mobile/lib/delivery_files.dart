import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'attachments.dart';
import 'data/remote_models.dart';

Future<File> downloadDelivery({
  required http.Client client,
  required RemoteAttachment attachment,
  required SavedSession session,
  required String sessionId,
  required void Function(double) onProgress,
}) async {
  if (attachment.size <= 0 || attachment.size > maxAttachmentBytes) {
    throw const AttachmentException('attachment_too_large');
  }
  final request =
      http.Request('GET', attachment.contentUri(session.origin, sessionId))
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer ${session.token}';
  final response = await client
      .send(request)
      .timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw AttachmentException(switch (response.statusCode) {
      401 || 403 => 'unauthorized',
      404 => 'attachment_not_found',
      _ => 'download_failed',
    });
  }
  final root = await getTemporaryDirectory();
  final cache = await Directory(
    '${root.path}/deliveries',
  ).create(recursive: true);
  final directory = await cache.createTemp('file-');
  var name = attachment.name.replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_');
  if (name.trim().isEmpty || name == '.' || name == '..') name = 'file';
  if (utf8.encode(name).length > 200) {
    final extension = name.contains('.') ? '.${name.split('.').last}' : '';
    name =
        String.fromCharCodes(name.runes.take(40)) +
        (extension.length <= 12 ? extension : '');
  }
  final file = File('${directory.path}/$name');
  try {
    final output = await file.open(mode: FileMode.write);
    try {
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        received += chunk.length;
        if (received > attachment.size || received > maxAttachmentBytes) {
          throw const AttachmentException('attachment_too_large');
        }
        await output.writeFrom(chunk);
        onProgress(received / attachment.size);
      }
      if (received != attachment.size) {
        throw const AttachmentException('incomplete_download');
      }
    } finally {
      await output.close();
    }
    return file;
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}

Future<void> openDeliveryFile(
  File file,
  String mimeType, {
  bool share = false,
}) => const MethodChannel('cc_remote/delivery_files').invokeMethod<void>(
  share ? 'share' : 'open',
  {'path': file.path, 'mimeType': mimeType},
);
