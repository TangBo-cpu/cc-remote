import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:cc_remote/chat_background.dart';

void main() {
  test('storage failures always fall back to the default background', () async {
    final readFailure = ChatBackgroundPreferenceStore(
      backend: FakeChatBackgroundStorage(
        value: '{"version":1}',
        throwOnRead: true,
      ),
    );
    final readFailureBackend = readFailure.backend as FakeChatBackgroundStorage;
    final malformedValue = ChatBackgroundPreferenceStore(
      backend: FakeChatBackgroundStorage(
        value: '{not-json',
        throwOnDelete: true,
      ),
    );
    final fileCheckBackend = FakeChatBackgroundStorage(
      value:
          '{"version":1,"kind":"localImage","imagePath":"wall.png",'
          '"overlayOpacity":0.32}',
    );
    final fileCheckFailure = ChatBackgroundPreferenceStore(
      backend: fileCheckBackend,
      fileExists: (_) async => throw const FileSystemException('busy'),
    );

    expect(await readFailure.load(), ChatBackgroundPreference.defaultValue);
    expect(readFailureBackend.deleteCount, 0);
    expect(readFailureBackend.value, '{"version":1}');
    expect(await malformedValue.load(), ChatBackgroundPreference.defaultValue);
    expect(
      await fileCheckFailure.load(),
      ChatBackgroundPreference.defaultValue,
    );
    expect(fileCheckBackend.deleteCount, 0);
  });

  test(
    'local background image is copied into app storage and safely deleted',
    () async {
      final sourceDirectory = await Directory.systemTemp.createTemp(
        'cc_remote_background_source',
      );
      final supportDirectory = await Directory.systemTemp.createTemp(
        'cc_remote_background_support',
      );
      addTearDown(() => sourceDirectory.delete(recursive: true));
      addTearDown(() => supportDirectory.delete(recursive: true));
      final source = File(
        '${sourceDirectory.path}${Platform.pathSeparator}picked.png',
      );
      await source.writeAsBytes(const [1, 2, 3, 4]);
      final service = LocalChatBackgroundImageService(
        imagePicker: FakeImagePicker(XFile(source.path)),
        supportDirectory: () async => supportDirectory,
      );

      final storedPath = await service.pickAndStore();

      expect(storedPath, isNotNull);
      expect(storedPath, contains('chat_background'));
      expect(await File(storedPath!).readAsBytes(), const [1, 2, 3, 4]);

      await service.deleteStoredImage(source.path);
      expect(await source.exists(), isTrue);

      await service.deleteStoredImage(storedPath);
      expect(await File(storedPath).exists(), isFalse);
    },
  );

  test('canceling the image picker leaves the background unchanged', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'cc_remote_background_cancel',
    );
    addTearDown(() => supportDirectory.delete(recursive: true));
    final service = LocalChatBackgroundImageService(
      imagePicker: FakeImagePicker(null),
      supportDirectory: () async => supportDirectory,
    );

    expect(await service.pickAndStore(), isNull);
    expect(await supportDirectory.list().toList(), isEmpty);
  });
}

class FakeImagePicker extends ImagePicker {
  FakeImagePicker(this.file);

  final XFile? file;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    expect(source, ImageSource.gallery);
    expect(maxWidth, 2160);
    expect(maxHeight, 2160);
    expect(imageQuality, 88);
    return file;
  }
}

class FakeChatBackgroundStorage implements ChatBackgroundStorage {
  FakeChatBackgroundStorage({
    this.value,
    this.throwOnRead = false,
    this.throwOnDelete = false,
  });

  String? value;
  final bool throwOnRead;
  final bool throwOnDelete;
  int deleteCount = 0;

  @override
  Future<String?> read() async {
    if (throwOnRead) throw StateError('read_failed');
    return value;
  }

  @override
  Future<void> write(String value) async {
    this.value = value;
  }

  @override
  Future<void> delete() async {
    deleteCount += 1;
    if (throwOnDelete) throw StateError('delete_failed');
    value = null;
  }
}
