import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Claude-style reading size steps for transcript and UI text.
enum ReadingFontSizePreference {
  small(0.9, '较小'),
  medium(1.0, '标准'),
  large(1.15, '较大'),
  xlarge(1.3, '最大');

  const ReadingFontSizePreference(this.scale, this.label);

  final double scale;
  final String label;

  static ReadingFontSizePreference fromWireName(String? value) {
    return values.firstWhere(
      (preference) => preference.name == value,
      orElse: () => medium,
    );
  }
}

class ReadingFontSizePreferenceStore {
  ReadingFontSizePreferenceStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_reading_font_size';
  final FlutterSecureStorage storage;

  Future<ReadingFontSizePreference> load() async {
    try {
      return ReadingFontSizePreference.fromWireName(await storage.read(key: key));
    } catch (_) {
      return ReadingFontSizePreference.medium;
    }
  }

  Future<void> save(ReadingFontSizePreference preference) {
    if (preference == ReadingFontSizePreference.medium) {
      return storage.delete(key: key);
    }
    return storage.write(key: key, value: preference.name);
  }
}

String readingFontSizeDescription(ReadingFontSizePreference preference) {
  return switch (preference) {
    ReadingFontSizePreference.small => '更紧凑，适合一屏看更多',
    ReadingFontSizePreference.medium => 'Claude 默认阅读尺寸',
    ReadingFontSizePreference.large => '更舒适的长文阅读',
    ReadingFontSizePreference.xlarge => '最大阅读字号',
  };
}

/// Multiplies a platform [TextScaler] by [factor], preserving nonlinear a11y
/// curves, then clamps each size into [minScaleFactor, maxScaleFactor].
TextScaler multiplyReadingTextScaler(
  TextScaler parent,
  double factor, {
  double minScaleFactor = 0.85,
  double maxScaleFactor = 1.6,
}) {
  return _MultipliedTextScaler(
    parent: parent,
    factor: factor,
    minScaleFactor: minScaleFactor,
    maxScaleFactor: maxScaleFactor,
  );
}

class _MultipliedTextScaler implements TextScaler {
  const _MultipliedTextScaler({
    required this.parent,
    required this.factor,
    required this.minScaleFactor,
    required this.maxScaleFactor,
  });

  final TextScaler parent;
  final double factor;
  final double minScaleFactor;
  final double maxScaleFactor;

  @override
  double scale(double fontSize) {
    final scaled = parent.scale(fontSize) * factor;
    return scaled.clamp(fontSize * minScaleFactor, fontSize * maxScaleFactor);
  }

  @override
  double get textScaleFactor {
    const reference = 14.0;
    return scale(reference) / reference;
  }

  @override
  TextScaler clamp({
    double minScaleFactor = 0,
    double maxScaleFactor = double.infinity,
  }) {
    return _MultipliedTextScaler(
      parent: parent,
      factor: factor,
      minScaleFactor: this.minScaleFactor > minScaleFactor
          ? this.minScaleFactor
          : minScaleFactor,
      maxScaleFactor: this.maxScaleFactor < maxScaleFactor
          ? this.maxScaleFactor
          : maxScaleFactor,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _MultipliedTextScaler &&
        other.parent == parent &&
        other.factor == factor &&
        other.minScaleFactor == minScaleFactor &&
        other.maxScaleFactor == maxScaleFactor;
  }

  @override
  int get hashCode =>
      Object.hash(parent, factor, minScaleFactor, maxScaleFactor);
}
