import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/model_preference.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'model preference defaults to the computer and persists an override',
    () async {
      final store = ClaudeModelPreferenceStore();

      expect(await store.load(), ClaudeModelPreference.followComputer);
      await store.save(ClaudeModelPreference.opus);
      expect(await store.load(), ClaudeModelPreference.opus);
      await store.save(ClaudeModelPreference.followComputer);
      expect(await store.load(), ClaudeModelPreference.followComputer);
    },
  );

  test(
    'unknown stored models safely follow the computer configuration',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        ClaudeModelPreferenceStore.key: 'unknown-model',
      });

      expect(
        await ClaudeModelPreferenceStore().load(),
        ClaudeModelPreference.followComputer,
      );
    },
  );
}
