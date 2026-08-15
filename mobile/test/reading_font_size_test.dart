import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/reading_font_size.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('reading font size defaults to medium and persists overrides', () async {
    final store = ReadingFontSizePreferenceStore();

    expect(await store.load(), ReadingFontSizePreference.medium);
    await store.save(ReadingFontSizePreference.large);
    expect(await store.load(), ReadingFontSizePreference.large);
    await store.save(ReadingFontSizePreference.medium);
    expect(await store.load(), ReadingFontSizePreference.medium);
  });

  test('unknown stored sizes safely fall back to medium', () async {
    FlutterSecureStorage.setMockInitialValues({
      ReadingFontSizePreferenceStore.key: 'unknown-size',
    });

    expect(
      await ReadingFontSizePreferenceStore().load(),
      ReadingFontSizePreference.medium,
    );
  });

  test('multiplied text scaler preserves parent curve and applies factor', () {
    final parent = TextScaler.linear(1.2);
    final scaled = multiplyReadingTextScaler(parent, 1.15);
    expect(scaled.scale(15.5), closeTo(1.2 * 1.15 * 15.5, 0.001));
  });
}
