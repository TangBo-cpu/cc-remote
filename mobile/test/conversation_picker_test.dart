import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cc_remote/main.dart';
import 'package:cc_remote/data/permission_mode.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/model_preference.dart';
import 'package:cc_remote/session_interaction.dart';

void main() {
  test(
    'missing Codex modes use full access and explicit limits are retained',
    () {
      expect(
        CodexSandboxMode.fromWire(null),
        CodexSandboxMode.dangerFullAccess,
      );
      expect(CodexSandboxMode.fromWire('read-only'), CodexSandboxMode.readOnly);
      expect(CodexSandboxMode.fromWire('unknown'), CodexSandboxMode.readOnly);
      expect(CodexSandboxMode.listFromWire([]), [CodexSandboxMode.readOnly]);
      expect(
        const QueuedPrompt(sessionId: 's', text: 'hello').codexSandboxMode,
        CodexSandboxMode.dangerFullAccess,
      );
      final snapshot = RemoteTranscriptSnapshot.tryParse({
        'version': 1,
        'revision': 1,
        'messages': [],
      });
      expect(snapshot?.codexSandboxMode, CodexSandboxMode.dangerFullAccess);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'model picker fits short screen and enlarged text in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        ClaudeModelPreference? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    selected = await showClaudeModelPicker(
                      context,
                      selected: ClaudeModelPreference.fable,
                    );
                  },
                  child: const Text('打开模型'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开模型'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final current = find.byKey(const ValueKey('model-option-fable'));
        expect(current.hitTestable(), findsOneWidget);
        expect(
          tester.getSemantics(current).flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(find.byTooltip('关闭选择器').hitTestable(), findsOneWidget);
        final opus = find.byKey(const ValueKey('model-option-opus'));
        await tester.ensureVisible(opus);
        await tester.pumpAndSettle();
        await tester.tap(opus);
        await tester.pumpAndSettle();
        expect(selected, ClaudeModelPreference.opus);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Claude unavailable bypass is locked and cannot be selected', (
    tester,
  ) async {
    PermissionMode? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPermissionModePicker(
                context,
                selected: PermissionMode.auto,
                allowBypassPermissions: false,
                onSelected: (value) => selected = value,
              ),
              child: const Text('打开权限'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开权限'));
    await tester.pumpAndSettle();
    final bypass = find.byKey(
      const ValueKey('permission-mode-bypassPermissions'),
    );
    await tester.ensureVisible(bypass);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(bypass).flagsCollection.isEnabled,
      Tristate.isFalse,
    );
    await tester.tap(bypass);
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.text('电脑端尚未允许跳过权限检查'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭选择器'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });

  testWidgets(
    'Codex confirmation persists scope and cancel preserves selection',
    (tester) async {
      CodexSandboxMode? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCodexSandboxModePicker(
                  context,
                  selected: CodexSandboxMode.readOnly,
                  onSelected: (value) => selected = value,
                ),
                child: const Text('打开沙箱'),
              ),
            ),
          ),
        ),
      );
      Future<void> openFullAccess() async {
        await tester.tap(find.text('打开沙箱'));
        await tester.pumpAndSettle();
        final full = find.byKey(
          const ValueKey('codex-sandbox-danger-full-access'),
        );
        await tester.ensureVisible(full);
        await tester.pumpAndSettle();
        await tester.tap(full);
        await tester.pumpAndSettle();
      }

      await openFullAccess();
      expect(find.text('当前对话使用完全访问'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await openFullAccess();
      await tester.tap(find.text('使用完全访问'));
      await tester.pumpAndSettle();
      expect(selected, CodexSandboxMode.dangerFullAccess);
    },
  );

  test('Codex prompt payload defaults to full access', () {
    final payload = buildPromptMessage(
      promptId: 'prompt',
      text: 'inspect',
      attachmentIds: const [],
      permissionMode: PermissionMode.auto,
      sessionId: 'session',
      model: ClaudeModelPreference.followComputer,
      engine: SessionEngine.codex,
    );
    expect(payload['sandboxMode'], 'danger-full-access');
  });

  for (final brightness in Brightness.values) {
    for (final codex in [true, false]) {
      testWidgets(
        'permission sheet fits short screen in $brightness codex=$codex',
        (tester) async {
          tester.view.physicalSize = const Size(320, 480);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.6)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      if (codex) {
                        showCodexSandboxModePicker(
                          context,
                          selected: CodexSandboxMode.dangerFullAccess,
                          onSelected: (_) {},
                        );
                      } else {
                        showPermissionModePicker(
                          context,
                          selected: PermissionMode.auto,
                          allowBypassPermissions: false,
                          onSelected: (_) {},
                        );
                      }
                    },
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final current = find.byKey(
            ValueKey(
              codex
                  ? 'codex-sandbox-danger-full-access'
                  : 'permission-mode-auto',
            ),
          );
          expect(current.hitTestable(), findsOneWidget);
          expect(
            tester.getSemantics(current).flagsCollection.isSelected,
            Tristate.isTrue,
          );
          expect(find.byTooltip('关闭选择器').hitTestable(), findsOneWidget);
          await tester.tap(find.byTooltip('关闭选择器'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
