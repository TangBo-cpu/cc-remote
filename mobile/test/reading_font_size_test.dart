import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/reading_font_size.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('reading font scale defaults and persists continuous values', () async {
    final store = ReadingFontSizePreferenceStore();

    expect(kReadingFontScaleDefault, 1.0);
    expect(readingFontSizeLabel(kReadingFontScaleDefault), '100%');
    expect(await store.load(), kReadingFontScaleDefault);
    await store.save(1.07);
    expect(await store.load(), closeTo(1.07, 0.001));
    expect(readingFontSizeLabel(await store.load()), '107%');
    await store.save(kReadingFontScaleDefault);
    expect(await store.load(), kReadingFontScaleDefault);
  });

  test('legacy enum wire names load within the new range', () async {
    for (final entry in {
      'small': 0.90,
      'medium': 1.0,
      'large': 1.10,
      'xlarge': 1.10,
    }.entries) {
      FlutterSecureStorage.setMockInitialValues({
        ReadingFontSizePreferenceStore.key: entry.key,
      });
      expect(await ReadingFontSizePreferenceStore().load(), entry.value);
    }
  });

  test('stored numeric scales clamp and snap to the new range', () async {
    for (final entry in {'0.85': 0.90, '1.40': 1.10, '1.034': 1.03}.entries) {
      FlutterSecureStorage.setMockInitialValues({
        ReadingFontSizePreferenceStore.key: entry.key,
      });
      expect(await ReadingFontSizePreferenceStore().load(), entry.value);
    }
  });

  test('unknown stored sizes safely fall back to default', () async {
    FlutterSecureStorage.setMockInitialValues({
      ReadingFontSizePreferenceStore.key: 'unknown-size',
    });

    expect(
      await ReadingFontSizePreferenceStore().load(),
      kReadingFontScaleDefault,
    );
  });

  test('default scale is labeled 100 percent', () {
    expect(readingFontSizeDescription(1.0), '默认阅读尺寸');
    expect(readingFontSizeDescription(0.95), '更紧凑，适合一屏看更多');
    expect(readingFontSizeDescription(1.01), '更舒适的长文阅读');
    expect(readingFontSizeDescription(1.10), '最大阅读字号');
  });

  test('snap and clamp keep slider values in range', () {
    expect(snapReadingFontScale(0.5), 0.90);
    expect(snapReadingFontScale(2.0), 1.10);
    expect(snapReadingFontScale(1.12), closeTo(1.10, 0.001));
    expect(snapReadingFontScale(1.034), closeTo(1.03, 0.001));
    expect(snapReadingFontScale(1.036), closeTo(1.04, 0.001));
    for (var percent = 90; percent <= 110; percent++) {
      expect(readingFontSizeLabel(percent / 100), '$percent%');
    }
  });

  test('multiplied text scaler preserves parent curve and applies factor', () {
    final parent = TextScaler.linear(1.2);
    final scaled = multiplyReadingTextScaler(parent, 1.15);
    expect(scaled.scale(15.5), closeTo(1.2 * 1.15 * 15.5, 0.001));
  });
}
