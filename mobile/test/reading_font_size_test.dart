import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/reading_font_size.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('reading font scale defaults and persists continuous values', () async {
    final store = ReadingFontSizePreferenceStore();

    expect(await store.load(), kReadingFontScaleDefault);
    await store.save(1.15);
    expect(await store.load(), closeTo(1.15, 0.001));
    await store.save(kReadingFontScaleDefault);
    expect(await store.load(), kReadingFontScaleDefault);
  });

  test('legacy enum wire names still load', () async {
    FlutterSecureStorage.setMockInitialValues({
      ReadingFontSizePreferenceStore.key: 'large',
    });
    expect(await ReadingFontSizePreferenceStore().load(), closeTo(1.15, 0.001));

    FlutterSecureStorage.setMockInitialValues({
      ReadingFontSizePreferenceStore.key: 'medium',
    });
    expect(await ReadingFontSizePreferenceStore().load(), closeTo(1.0, 0.001));
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

  test('snap and clamp keep slider values in range', () {
    expect(snapReadingFontScale(0.5), kReadingFontScaleMin);
    expect(snapReadingFontScale(2.0), kReadingFontScaleMax);
    expect(snapReadingFontScale(1.12), closeTo(1.10, 0.001));
  });

  test('multiplied text scaler preserves parent curve and applies factor', () {
    final parent = TextScaler.linear(1.2);
    final scaled = multiplyReadingTextScaler(parent, 1.15);
    expect(scaled.scale(15.5), closeTo(1.2 * 1.15 * 15.5, 0.001));
  });
}
