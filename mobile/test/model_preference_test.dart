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

  test(
    'Codex model preference is independent of Claude and can be cleared',
    () async {
      final claude = ClaudeModelPreferenceStore();
      final codex = CodexModelPreferenceStore();
      expect(await codex.load(), isNull);
      await claude.save(ClaudeModelPreference.opus);
      await codex.save('gpt-test-codex');
      expect(await codex.load(), 'gpt-test-codex');
      expect(await claude.load(), ClaudeModelPreference.opus);
      await codex.save(null);
      expect(await codex.load(), isNull);
      expect(await claude.load(), ClaudeModelPreference.opus);
    },
  );

  test('invalid stored Codex model follows the computer', () async {
    FlutterSecureStorage.setMockInitialValues({
      CodexModelPreferenceStore.key: 'invalid model\n--flag',
    });
    expect(await CodexModelPreferenceStore().load(), isNull);
  });
}
