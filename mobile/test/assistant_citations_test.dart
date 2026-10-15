import 'package:cc_remote/assistant_citations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const citation = '\uE200cite\uE202turn1search2\uE201';

  test('citations become readable placeholders without inventing URLs', () {
    const text =
        '核对实现。$citation\n'
        '多个来源。\uE200cite\uE202turn1search3\uE202turn7view0\uE201\n'
        '文件来源。\uE200filecite\uE202turn0file0\uE202L1-L10\uE201';
    expect(
      normalizeAssistantCitations(text),
      '核对实现。〔来源链接未提供〕\n'
      '多个来源。〔来源链接未提供〕\n'
      '文件来源。〔文件引用未提供路径〕',
    );
  });

  test('every streamed citation prefix stays hidden until it is complete', () {
    for (final marker in [
      citation,
      '\uE200filecite\uE202turn0file0\uE202L1-L10\uE201',
    ]) {
      for (var end = 1; end < marker.length; end++) {
        expect(
          normalizeAssistantCitations(
            '正文${marker.substring(0, end)}',
            isStreaming: true,
          ),
          '正文',
          reason: 'prefix length $end of $marker',
        );
      }
    }
    expect(
      normalizeAssistantCitations('正文$citation', isStreaming: true),
      '正文〔来源链接未提供〕',
    );
    expect(
      normalizeAssistantCitations('正文\uE200cite\uE202turn1search2'),
      '正文〔来源链接未提供〕',
    );
  });

  test('inline code and fenced code preserve literal citation markers', () {
    for (final code in [
      '`$citation`',
      '``a`$citation``',
      '```text\n$citation\n```',
      '~~~~text\r\n$citation\r\n~~~~~',
      '```text\n$citation',
    ]) {
      expect(
        normalizeAssistantCitations('$code\n正文$citation'),
        code.endsWith(citation) ? '$code\n正文$citation' : '$code\n正文〔来源链接未提供〕',
      );
      expect(normalizeAssistantCitations(code, isStreaming: true), code);
    }
  });

  test('a shorter fence inside a code block does not end the block', () {
    const text = '````text\n```\n$citation\n````\n正文$citation';
    expect(
      normalizeAssistantCitations(text),
      '````text\n```\n$citation\n````\n正文〔来源链接未提供〕',
    );
  });

  test(
    'Markdown links, file paths and unrelated private characters survive',
    () {
      const text =
          '[来源](https://example.com/a_(b)?q=one&lang=zh#part) '
          '[文件](/src/driver.c:12) `ov8858_write_reg()` '
          '\uE200other\uE202payload\uE201';
      expect(normalizeAssistantCitations(text), text);
      expect(normalizeAssistantCitations('普通回复。'), '普通回复。');
    },
  );
}
