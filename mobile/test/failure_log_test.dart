import 'package:cc_remote/failure_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('terminal formatting is removed without losing diagnostic lines', () {
    const raw =
        '\u001b[33mWARN\u001b[0m plugin\r\n'
        '\u001b]8;;https://example.test\u0007details\u001b]8;;\u0007\r'
        '\u009b31m  final line\u009b0m\u0000';
    expect(cleanFailureLog(raw), 'WARN plugin\ndetails\n  final line');
    expect(raw, contains('\u001b'));
  });

  test('common credentials are hidden in displayed and copied logs', () {
    const raw =
        'OPENAI_API_KEY=sk-fake12345678\n'
        'Authorization: Bearer fake-bearer-value\n'
        'authorization: Basic dXNlcjpmYWtl\n'
        'https://user:pass@example.test/api?token=fake-query&mode=debug\n'
        '{"api_key":"fake-json","refresh_token":"fake-refresh"}\n'
        "password='fake password with spaces'\n"
        'key from provider: sk-fake_unlabelled_123\n'
        'ERROR plugin failed with exit code 1';
    final safe = safeFailureLog(raw);
    for (final secret in [
      'sk-fake12345678',
      'fake-bearer-value',
      'dXNlcjpmYWtl',
      'user:pass',
      'fake-query',
      'fake-json',
      'fake-refresh',
      'fake password',
      'sk-fake_unlabelled_123',
    ]) {
      expect(safe, isNot(contains(secret)));
    }
    expect(safe, contains('example.test/api?token=[已隐藏]&mode=debug'));
    expect(safe, contains('ERROR plugin failed with exit code 1'));
  });

  test('short errors remain specific and secrets do not reach summaries', () {
    expect(failureSummary('命令退出码为 1'), '命令退出码为 1');
    expect(failureSummary('\u001b[31m连接超时\u001b[0m'), '连接超时');
    expect(failureSummary('api_key=fake-value'), 'api_key=[已隐藏]');
  });

  test('long unbroken diagnostics are preserved', () {
    final log = 'diagnostic_' * 2000;
    expect(safeFailureLog(log), log);
  });

  test('logs and empty failures do not invent a root cause', () {
    for (final log in [
      'WARN plugin failed to load',
      '[INFO] engine starting',
      '2026-10-30T10:00:00 WARN plugin',
      'first line\nlast line',
      'x' * 181,
    ]) {
      expect(failureSummary(log), '查看错误详情以定位问题。');
    }
    expect(failureSummary('\u001b[0m '), '未收到具体错误信息，请检查电脑端状态。');
  });
}
