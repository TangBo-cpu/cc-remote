import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Continuous reading scale for transcript and UI text (0.95 = app default).
const double kReadingFontScaleDefault = 0.95;
const double kReadingFontScaleMin = 0.85;
const double kReadingFontScaleMax = 1.40;

double clampReadingFontScale(double value) {
  return value.clamp(kReadingFontScaleMin, kReadingFontScaleMax).toDouble();
}

/// Snap to 0.05 steps so the slider feels direct without float noise.
double snapReadingFontScale(double value) {
  final clamped = clampReadingFontScale(value);
  return (clamped * 20).round() / 20;
}

/// Parses stored wire values. Accepts continuous decimals and legacy enum names.
double parseReadingFontScale(String? raw) {
  if (raw == null || raw.isEmpty) return kReadingFontScaleDefault;
  switch (raw) {
    case 'small':
      return 0.90;
    case 'medium':
      // Legacy enum default was 1.0; keep wire value stable.
      return 1.0;
    case 'large':
      return 1.15;
    case 'xlarge':
      return 1.30;
  }
  final parsed = double.tryParse(raw);
  if (parsed == null) return kReadingFontScaleDefault;
  return clampReadingFontScale(parsed);
}

class ReadingFontSizePreferenceStore {
  ReadingFontSizePreferenceStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_reading_font_size';
  final FlutterSecureStorage storage;

  Future<double> load() async {
    try {
      return parseReadingFontScale(await storage.read(key: key));
    } catch (_) {
      return kReadingFontScaleDefault;
    }
  }

  Future<void> save(double scale) {
    final snapped = snapReadingFontScale(scale);
    if ((snapped - kReadingFontScaleDefault).abs() < 0.001) {
      return storage.delete(key: key);
    }
    return storage.write(key: key, value: snapped.toStringAsFixed(2));
  }
}

String readingFontSizeLabel(double scale) {
  final percent = (snapReadingFontScale(scale) * 100).round();
  return '$percent%';
}

String readingFontSizeDescription(double scale) {
  final snapped = snapReadingFontScale(scale);
  if (snapped < 0.95) return '更紧凑，适合一屏看更多';
  if (snapped <= 1.0) return '默认阅读尺寸';
  if (snapped < 1.25) return '更舒适的长文阅读';
  return '最大阅读字号';
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
