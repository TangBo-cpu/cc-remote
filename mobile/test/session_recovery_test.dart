import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/data/websocket_client.dart';
import 'package:cc_remote/main.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('cached transcript follows its session across restart', (
    tester,
  ) async {
    for (final useWs in [false, true]) {
      for (final cachedSessionId in [
        'previous-session',
        'current-session',
        null,
      ]) {
        await tester.pumpWidget(
          const CcRemoteApp(enableCamera: false, demoMode: true),
        );
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(DemoShell));
        await TranscriptStore().storage.write(
          key: TranscriptStore.key,
          value: jsonEncode({
            'version': 1,
            'sessionId': ?cachedSessionId,
            'running': false,
            'messages': [TranscriptMessage.assistant('cached reply').toJson()],
          }),
        );
        await state.restoreTranscriptSnapshot();
        state.session = SavedSession(
          origin: Uri.parse('https://example.test'),
          token: 'test',
          deviceName: 'Test host',
          workspaceDir: '/workspace/project',
        );
        state.route = ShellRoute.chat;
        final catalog = {
          'type': 'catalog',
          'activeProjectId': 'project',
          'activeSessionId': 'current-session',
          'projects': [
            {
              'id': 'project',
              'name': 'project',
              'path': '/workspace/project',
              'sessionCount': 1,
              'running': false,
            },
          ],
          'sessions': [
            {
              'id': 'current-session',
              'projectId': 'project',
              'title': 'Current session',
              'updatedAt': 1,
              'running': false,
              'messageCount': 0,
            },
          ],
        };
        if (useWs) {
          state.handleWsMessage(jsonEncode(catalog));
        } else {
          state.applyCatalog(RemoteProjectCatalog.tryParse(catalog));
        }
        state.handleWsMessage(
          jsonEncode({
            'type': 'status',
            'sessionId': 'current-session',
            'authenticated': true,
            'running': false,
          }),
        );
        state.handleWsMessage(
          jsonEncode({
            'type': 'transcript_snapshot',
            'sessionId': 'current-session',
            'version': 1,
            'revision': 0,
            'running': false,
            'messages': [],
            'pendingPermissions': [],
          }),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('cached reply'),
          cachedSessionId == 'current-session' ? findsOneWidget : findsNothing,
          reason: 'cached=$cachedSessionId, WS=$useWs',
        );
        await state.persistTranscriptSnapshot();
        expect(
          (await TranscriptStore().load())!.toJson()['sessionId'],
          'current-session',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('pending approval becomes actionable after reconnect', (
    tester,
  ) async {
    for (final manualReconnect in [false, true]) {
      await tester.pumpWidget(
        const CcRemoteApp(enableCamera: false, demoMode: true),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(DemoShell));
      await state.connectDemoDevice();
      final request = {
        'type': 'permission_request',
        'sessionId': 'demo-session-polish',
        'requestId': 'approval',
        'toolName': 'Bash',
        'detail': 'npm test',
      };
      state.respondingPermissionIds.add('approval');
      state.handleWsMessage(jsonEncode(request));
      await tester.pump();
      expect(
        tester
            .widget<PermissionRequestCard>(find.byType(PermissionRequestCard))
            .responding,
        isTrue,
      );

      if (manualReconnect) {
        state.handleWsConnectionState(
          const RemoteConnectionSnapshot(
            phase: RemoteConnectionPhase.connecting,
          ),
        );
      } else {
        state.handleWsClosed('test disconnect');
      }
      state.handleWsMessage(
        jsonEncode({
          'type': 'status',
          'sessionId': 'demo-session-polish',
          'authenticated': true,
          'running': false,
        }),
      );
      final snapshot = {
        'type': 'transcript_snapshot',
        'sessionId': 'demo-session-polish',
        'version': 1,
        'revision': 1,
        'running': false,
        'messages': [],
        'pendingPermissions': [request],
      };
      state.handleWsMessage(jsonEncode(snapshot));
      await tester.pump();
      final card = find.byType(PermissionRequestCard);
      expect(tester.widget<PermissionRequestCard>(card).responding, isFalse);
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(of: card, matching: find.byType(FilledButton)),
            )
            .onPressed,
        isNotNull,
      );
      state.handleWsMessage(
        jsonEncode({...snapshot, 'revision': 2, 'pendingPermissions': []}),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PermissionRequestCard), findsNothing);
      await state.lastTranscriptWrite;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}
