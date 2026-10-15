import 'package:cc_remote/workspace_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizeWorkspacePath strips the workspace root and quotes', () {
    expect(
      normalizeWorkspacePath(
        r'E:\work\cc-remote\src\daemon.ts',
        workspaceDir: r'E:\work\cc-remote',
      ),
      'src/daemon.ts',
    );
    expect(
      normalizeWorkspacePath('`mobile/lib/main.dart`'),
      'mobile/lib/main.dart',
    );
    expect(normalizeWorkspacePath('./README.md'), 'README.md');
  });

  test('normalizeWorkspacePath rejects urls, packages, and escapes', () {
    expect(normalizeWorkspacePath('https://example.com/main.dart'), isNull);
    expect(normalizeWorkspacePath('package:flutter/material.dart'), isNull);
    expect(normalizeWorkspacePath('../secret.txt'), isNull);
    expect(normalizeWorkspacePath(r'C:\Windows\notepad.exe'), isNull);
    expect(normalizeWorkspacePath('/etc/hosts'), isNull);
    expect(normalizeWorkspacePath('src/foo/..'), isNull);
    expect(normalizeWorkspacePath('src/foo/../bar.ts'), isNull);
  });

  test('looksLikeWorkspacePath accepts files and nested relative paths', () {
    expect(looksLikeWorkspacePath('src/daemon.ts'), isTrue);
    expect(looksLikeWorkspacePath('README.md'), isTrue);
    expect(looksLikeWorkspacePath('.env'), isTrue);
    expect(looksLikeWorkspacePath('docs/Makefile'), isTrue);
    expect(looksLikeWorkspacePath('ls'), isFalse);
    expect(looksLikeWorkspacePath('true'), isFalse);
    expect(looksLikeWorkspacePath('HTTP/2'), isFalse);
    expect(looksLikeWorkspacePath('and/or'), isFalse);
  });

  test('extractWorkspacePaths finds unique relative paths in mixed text', () {
    expect(
      extractWorkspacePaths(
        'updated src/daemon.ts and mobile/lib/workspace_drawer.dart, then src/daemon.ts again',
      ),
      ['src/daemon.ts', 'mobile/lib/workspace_drawer.dart'],
    );
    expect(findWorkspacePaths('src/daemon.ts then src/daemon.ts').length, 2);
  });

  test('extractWorkspacePaths rejects packages, hosts, and slash tokens', () {
    expect(
      extractWorkspacePaths('import package:flutter/material.dart;'),
      isEmpty,
    );
    expect(
      extractWorkspacePaths('see /etc/hosts and HTTP/2 and/or src/foo/..'),
      isEmpty,
    );
    expect(
      extractWorkspacePaths(
        'www.example.com/src/foo.ts and github.com/user/repo',
      ),
      isEmpty,
    );
    expect(extractWorkspacePaths('src/foo/../bar.ts'), isEmpty);
  });

  test('isSingleWorkspacePath only matches a lone path', () {
    expect(isSingleWorkspacePath('src/daemon.ts'), isTrue);
    expect(isSingleWorkspacePath('see src/daemon.ts'), isFalse);
    expect(isSingleWorkspacePath('ls -la'), isFalse);
  });

  test('WorkspaceChangeEcho labels a single file or a count', () {
    const one = WorkspaceChangeEcho(changeCount: 1, paths: ['src/daemon.ts']);
    const many = WorkspaceChangeEcho(
      changeCount: 2,
      paths: ['src/daemon.ts', 'mobile/lib/workspace_drawer.dart'],
    );
    expect(one.label, '改了 daemon.ts');
    expect(many.label, '改了 2 个文件');
    expect(one.caption, '看 diff · 仅桌面工作区');
    expect(one.focusPath, 'src/daemon.ts');
    expect(many.focusPath, isNull);
  });

  test('workspaceEchoShouldClear on session or workspace switch', () {
    expect(
      workspaceEchoShouldClear(
        currentSessionId: 'session-1',
        nextSessionId: 'session-2',
      ),
      isTrue,
    );
    expect(
      workspaceEchoShouldClear(
        currentSessionId: 'session-1',
        nextSessionId: 'session-1',
        currentWorkspaceDir: r'E:\work\cc-remote',
        nextWorkspaceDir: r'E:\work\other',
      ),
      isTrue,
    );
    expect(
      workspaceEchoShouldClear(
        currentSessionId: 'session-1',
        nextSessionId: 'session-1',
        currentWorkspaceDir: r'E:\work\cc-remote',
        nextWorkspaceDir: r'E:\work\cc-remote',
      ),
      isFalse,
    );
    expect(
      workspaceEchoShouldClear(
        currentSessionId: null,
        nextSessionId: 'session-1',
      ),
      isFalse,
    );
  });
}
