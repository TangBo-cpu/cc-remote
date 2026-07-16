import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

enum ChatBackgroundKind { defaultStyle, preset, localImage }

enum ChatBackgroundPreset { mint, sunrise, rose }

class ChatBackgroundPreference {
  const ChatBackgroundPreference({
    required this.kind,
    this.preset,
    this.imagePath,
    this.overlayOpacity = 0.32,
  });

  const ChatBackgroundPreference.defaultStyle()
    : kind = ChatBackgroundKind.defaultStyle,
      preset = null,
      imagePath = null,
      overlayOpacity = 0.32;

  const ChatBackgroundPreference.preset(ChatBackgroundPreset value)
    : kind = ChatBackgroundKind.preset,
      preset = value,
      imagePath = null,
      overlayOpacity = 0.32;

  const ChatBackgroundPreference.localImage(
    String this.imagePath, {
    this.overlayOpacity = 0.32,
  }) : kind = ChatBackgroundKind.localImage,
       preset = null;

  static const defaultValue = ChatBackgroundPreference.defaultStyle();

  final ChatBackgroundKind kind;
  final ChatBackgroundPreset? preset;
  final String? imagePath;
  final double overlayOpacity;

  ChatBackgroundPreference copyWith({double? overlayOpacity}) {
    return ChatBackgroundPreference(
      kind: kind,
      preset: preset,
      imagePath: imagePath,
      overlayOpacity: overlayOpacity ?? this.overlayOpacity,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': kind.name,
    if (preset != null) 'preset': preset!.name,
    if (imagePath != null) 'imagePath': imagePath,
    'overlayOpacity': overlayOpacity,
  };

  static ChatBackgroundPreference fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('bad_version');
    final kindName = json['kind'];
    if (kindName is! String) throw const FormatException('bad_kind');
    final kind = ChatBackgroundKind.values.byName(kindName);
    final opacity = ((json['overlayOpacity'] as num?)?.toDouble() ?? 0.32)
        .clamp(0.16, 0.64)
        .toDouble();
    return switch (kind) {
      ChatBackgroundKind.defaultStyle => defaultValue,
      ChatBackgroundKind.preset => ChatBackgroundPreference(
        kind: kind,
        preset: ChatBackgroundPreset.values.byName(json['preset'] as String),
        overlayOpacity: opacity,
      ),
      ChatBackgroundKind.localImage => ChatBackgroundPreference.localImage(
        _requiredImagePath(json['imagePath']),
        overlayOpacity: opacity,
      ),
    };
  }

  static String _requiredImagePath(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('bad_image_path');
    }
    return value;
  }

  @override
  bool operator ==(Object other) {
    return other is ChatBackgroundPreference &&
        other.kind == kind &&
        other.preset == preset &&
        other.imagePath == imagePath &&
        other.overlayOpacity == overlayOpacity;
  }

  @override
  int get hashCode => Object.hash(kind, preset, imagePath, overlayOpacity);
}

abstract class ChatBackgroundStorage {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class SecureChatBackgroundStorage implements ChatBackgroundStorage {
  SecureChatBackgroundStorage({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage storage;

  @override
  Future<String?> read() =>
      storage.read(key: ChatBackgroundPreferenceStore.key);

  @override
  Future<void> write(String value) {
    return storage.write(key: ChatBackgroundPreferenceStore.key, value: value);
  }

  @override
  Future<void> delete() {
    return storage.delete(key: ChatBackgroundPreferenceStore.key);
  }
}

class ChatBackgroundPreferenceStore {
  ChatBackgroundPreferenceStore({
    FlutterSecureStorage? storage,
    ChatBackgroundStorage? backend,
    Future<bool> Function(String path)? fileExists,
  }) : assert(storage == null || backend == null),
       backend = backend ?? SecureChatBackgroundStorage(storage: storage),
       fileExists = fileExists ?? ((path) => File(path).exists());

  static const key = 'cc_remote_chat_background';
  final ChatBackgroundStorage backend;
  final Future<bool> Function(String path) fileExists;

  Future<ChatBackgroundPreference> load() async {
    final String? raw;
    try {
      raw = await backend.read();
    } catch (_) {
      return ChatBackgroundPreference.defaultValue;
    }
    if (raw == null) return ChatBackgroundPreference.defaultValue;

    final ChatBackgroundPreference preference;
    try {
      preference = ChatBackgroundPreference.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      await _clearBestEffort();
      return ChatBackgroundPreference.defaultValue;
    }

    final path = preference.imagePath;
    if (path == null) return preference;
    final bool exists;
    try {
      exists = await fileExists(path);
    } catch (_) {
      return ChatBackgroundPreference.defaultValue;
    }
    if (exists) return preference;
    await _clearBestEffort();
    return ChatBackgroundPreference.defaultValue;
  }

  Future<void> save(ChatBackgroundPreference preference) {
    if (preference.kind == ChatBackgroundKind.defaultStyle) return clear();
    return backend.write(jsonEncode(preference.toJson()));
  }

  Future<void> clear() => backend.delete();

  Future<void> _clearBestEffort() async {
    try {
      await clear();
    } catch (_) {}
  }
}

abstract class ChatBackgroundImageService {
  Future<String?> pickAndStore();
  Future<void> deleteStoredImage(String? path);
}

class LocalChatBackgroundImageService implements ChatBackgroundImageService {
  LocalChatBackgroundImageService({
    ImagePicker? imagePicker,
    Future<Directory> Function()? supportDirectory,
  }) : imagePicker = imagePicker ?? ImagePicker(),
       supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final ImagePicker imagePicker;
  final Future<Directory> Function() supportDirectory;

  @override
  Future<String?> pickAndStore() async {
    final selected = await imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2160,
      maxHeight: 2160,
      imageQuality: 88,
    );
    if (selected == null) return null;
    final directory = await _backgroundDirectory();
    await directory.create(recursive: true);
    final destination = File(
      '${directory.path}${Platform.pathSeparator}'
      'background_${DateTime.now().microsecondsSinceEpoch}'
      '${_safeExtension(selected.name)}',
    );
    try {
      final copied = await File(selected.path).copy(destination.path);
      if (await copied.length() <= 0) throw const FileSystemException();
      return copied.path;
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  @override
  Future<void> deleteStoredImage(String? path) async {
    if (path == null || path.isEmpty) return;
    final candidate = File(path);
    final directory = await _backgroundDirectory();
    final directoryType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (directoryType != FileSystemEntityType.directory) return;
    final directoryPath = _normalized(directory.absolute.path);
    final parentPath = _normalized(candidate.parent.absolute.path);
    if (parentPath != directoryPath) return;
    final name = candidate.uri.pathSegments.last.toLowerCase();
    if (!RegExp(r'^background_\d+\.(jpg|jpeg|png|webp|heic)$').hasMatch(name)) {
      return;
    }
    final candidateType = await FileSystemEntity.type(
      candidate.path,
      followLinks: false,
    );
    if (candidateType != FileSystemEntityType.file) return;
    await candidate.delete();
  }

  Future<Directory> _backgroundDirectory() async {
    final root = await supportDirectory();
    return Directory('${root.path}${Platform.pathSeparator}chat_background');
  }

  String _normalized(String path) {
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  String _safeExtension(String name) {
    final match = RegExp(r'\.[a-zA-Z0-9]{2,5}$').firstMatch(name);
    final extension = match?.group(0)?.toLowerCase();
    return const {'.jpg', '.jpeg', '.png', '.webp', '.heic'}.contains(extension)
        ? extension!
        : '.jpg';
  }
}
