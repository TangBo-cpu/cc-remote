import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum ClaudeModelPreference {
  followComputer(null, '跟随电脑配置'),
  opus('opus', 'Opus'),
  sonnet('sonnet', 'Sonnet'),
  fable('fable', 'Fable');

  const ClaudeModelPreference(this.wireName, this.label);

  final String? wireName;
  final String label;

  static ClaudeModelPreference fromWireName(String? value) {
    return values.firstWhere(
      (preference) => preference.wireName == value,
      orElse: () => followComputer,
    );
  }
}

class ClaudeModelPreferenceStore {
  ClaudeModelPreferenceStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_model_preference';
  final FlutterSecureStorage storage;

  Future<ClaudeModelPreference> load() async {
    try {
      return ClaudeModelPreference.fromWireName(await storage.read(key: key));
    } catch (_) {
      return ClaudeModelPreference.followComputer;
    }
  }

  Future<void> save(ClaudeModelPreference preference) {
    final value = preference.wireName;
    if (value == null) return storage.delete(key: key);
    return storage.write(key: key, value: value);
  }
}

String modelPreferenceDescription(
  ClaudeModelPreference preference,
  String? currentModel,
) {
  if (preference != ClaudeModelPreference.followComputer) {
    return '后续消息使用 ${preference.label}';
  }
  final current = currentModel?.trim();
  return current == null || current.isEmpty ? '使用电脑端默认模型' : '当前：$current';
}
