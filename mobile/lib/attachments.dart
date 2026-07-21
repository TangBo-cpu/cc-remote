import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

const maxAttachmentBytes = 25 * 1024 * 1024;
const maxAttachmentsPerPrompt = 5;

enum AttachmentSource { camera, photos, files }

class AttachmentDraft {
  const AttachmentDraft({
    required this.path,
    required this.name,
    required this.size,
    required this.mimeType,
  });

  final String path;
  final String name;
  final int size;
  final String mimeType;

  bool get isImage => mimeType.startsWith('image/');
}

class RemoteAttachment {
  const RemoteAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.size,
  });

  final String id;
  final String name;
  final String mimeType;
  final int size;

  bool get isImage => mimeType.startsWith('image/');

  Uri contentUri(Uri origin, String sessionId) => origin.resolve(
    '/api/sessions/${Uri.encodeComponent(sessionId)}/attachments/'
    '${Uri.encodeComponent(id)}/content',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'size': size,
  };

  static RemoteAttachment fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final mimeType = json['mimeType'];
    final size = json['size'];
    if (id is! String ||
        name is! String ||
        mimeType is! String ||
        size is! num) {
      throw const FormatException('bad_attachment');
    }
    return RemoteAttachment(
      id: id,
      name: name,
      mimeType: mimeType,
      size: size.toInt(),
    );
  }
}

class AttachmentPicker {
  AttachmentPicker({ImagePicker? imagePicker})
    : imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker imagePicker;

  Future<List<AttachmentDraft>> takePhoto() async {
    final photo = await imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 88,
    );
    return photo == null ? const [] : [await draftFromXFile(photo)];
  }

  Future<List<AttachmentDraft>> pickPhotos() async {
    final photos = await imagePicker.pickMultiImage(
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 88,
    );
    return Future.wait(photos.map(draftFromXFile));
  }

  Future<List<AttachmentDraft>> pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (result == null) return const [];
    return result.files
        .where((file) => file.path != null)
        .map(
          (file) => AttachmentDraft(
            path: file.path!,
            name: file.name,
            size: file.size,
            mimeType: mimeTypeForName(file.name),
          ),
        )
        .toList();
  }

  Future<AttachmentDraft> draftFromXFile(XFile file) async {
    return AttachmentDraft(
      path: file.path,
      name: file.name,
      size: await file.length(),
      mimeType: file.mimeType ?? mimeTypeForName(file.name),
    );
  }
}

class AttachmentUploader {
  const AttachmentUploader({required this.client});

  final http.Client client;

  Future<List<RemoteAttachment>> upload({
    required Uri origin,
    required String token,
    required String sessionId,
    required List<AttachmentDraft> files,
  }) async {
    if (files.isEmpty) return const [];
    if (files.length > maxAttachmentsPerPrompt) {
      throw const AttachmentException('too_many_attachments');
    }
    if (files.any((file) => file.size <= 0)) {
      throw const AttachmentException('attachment_empty');
    }
    if (files.any((file) => file.size > maxAttachmentBytes)) {
      throw const AttachmentException('attachment_too_large');
    }

    final request = http.MultipartRequest(
      'POST',
      origin.resolve(
        '/api/sessions/${Uri.encodeComponent(sessionId)}/attachments',
      ),
    )..headers['Authorization'] = 'Bearer $token';
    for (final file in files) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'files',
          file.path,
          filename: file.name,
          contentType: MediaType.parse(file.mimeType),
        ),
      );
    }

    final streamed = await client
        .send(request)
        .timeout(const Duration(minutes: 2));
    final response = await http.Response.fromStream(streamed);
    final decoded = response.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 401) {
      throw const AttachmentException('unauthorized');
    }
    if (response.statusCode != 201) {
      throw AttachmentException(decoded['error'] as String? ?? 'upload_failed');
    }
    final rawAttachments = decoded['attachments'];
    if (rawAttachments is! List) {
      throw const AttachmentException('bad_upload_response');
    }
    return rawAttachments
        .map(
          (item) =>
              RemoteAttachment.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }
}

class AttachmentException implements Exception {
  const AttachmentException(this.code);

  final String code;

  @override
  String toString() => code;
}

String mimeTypeForName(String name) {
  final extension = name.toLowerCase().split('.').last;
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' || 'heif' => 'image/heic',
    'txt' || 'log' || 'md' => 'text/plain',
    'json' => 'application/json',
    'pdf' => 'application/pdf',
    'zip' => 'application/zip',
    'csv' => 'text/csv',
    'dart' ||
    'js' ||
    'ts' ||
    'tsx' ||
    'jsx' ||
    'py' ||
    'java' ||
    'kt' ||
    'swift' ||
    'go' ||
    'rs' ||
    'c' ||
    'h' ||
    'cpp' ||
    'hpp' ||
    'css' ||
    'html' ||
    'xml' ||
    'yaml' ||
    'yml' => 'text/plain',
    _ => 'application/octet-stream',
  };
}

bool attachmentFileExists(AttachmentDraft attachment) =>
    File(attachment.path).existsSync();
