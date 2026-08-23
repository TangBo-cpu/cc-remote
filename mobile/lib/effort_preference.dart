import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum ClaudeEffortPreference {
  automatic('auto', '自动'),
  low('low', '低'),
  medium('medium', '中'),
  high('high', '高'),
  xhigh('xhigh', '超高'),
  max('max', '最大');

  const ClaudeEffortPreference(this.wireName, this.label);

  final String wireName;
  final String label;

  static ClaudeEffortPreference fromWireName(String? value) {
    return values.firstWhere(
      (preference) => preference.wireName == value,
      orElse: () => automatic,
    );
  }
}

class ClaudeEffortPreferenceStore {
  ClaudeEffortPreferenceStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_effort_preference';
  final FlutterSecureStorage storage;

  Future<ClaudeEffortPreference> load() async {
    try {
      return ClaudeEffortPreference.fromWireName(await storage.read(key: key));
    } catch (_) {
      return ClaudeEffortPreference.automatic;
    }
  }

  Future<void> save(ClaudeEffortPreference preference) {
    if (preference == ClaudeEffortPreference.automatic ||
        preference == ClaudeEffortPreference.max) {
      return storage.delete(key: key);
    }
    return storage.write(key: key, value: preference.wireName);
  }
}

String effortPreferenceDescription(
  ClaudeEffortPreference preference, {
  String engineLabel = 'Claude Code',
}) {
  return switch (preference) {
    ClaudeEffortPreference.automatic => '使用当前模型与 $engineLabel 的默认强度',
    ClaudeEffortPreference.low => '适合短小、明确、重视响应速度的任务',
    ClaudeEffortPreference.medium => '降低耗时与用量，适合日常轻量任务',
    ClaudeEffortPreference.high => '能力与速度均衡，也是多数模型的默认档',
    ClaudeEffortPreference.xhigh => '更深入推理，适合复杂编码与高自主任务',
    ClaudeEffortPreference.max => '最深推理，仅当前会话使用，可能过度思考',
  };
}
