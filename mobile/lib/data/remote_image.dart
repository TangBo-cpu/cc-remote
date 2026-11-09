import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import '../attachments.dart';
import 'peer_transport.dart';

ImageProvider remoteImageProvider(Uri url, String token) =>
    PeerHttpClient.hasPeer(url, token)
    ? RemoteImageProvider(url, token)
    : NetworkImage(url.toString(), headers: {'Authorization': 'Bearer $token'});

class RemoteImageProvider extends ImageProvider<RemoteImageProvider> {
  const RemoteImageProvider(this.url, this.token);

  final Uri url;
  final String token;

  @override
  Future<RemoteImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    RemoteImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final client = PeerHttpClient();
    try {
      final request = http.Request('GET', url)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $token';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw NetworkImageLoadException(
          statusCode: response.statusCode,
          uri: url,
        );
      }
      if ((response.contentLength ?? 0) > maxAttachmentBytes) {
        throw StateError('attachment_too_large');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (bytes.length + chunk.length > maxAttachmentBytes) {
          throw StateError('attachment_too_large');
        }
        bytes.add(chunk);
      }
      return await decode(
        await ui.ImmutableBuffer.fromUint8List(bytes.takeBytes()),
      );
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    } finally {
      client.close();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteImageProvider && other.url == url && other.token == token;

  @override
  int get hashCode => Object.hash(url, token);
}
