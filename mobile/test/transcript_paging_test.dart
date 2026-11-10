import 'dart:async';

import 'package:cc_remote/data/api_client.dart';
import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'session_mutation_test.dart' show boot, catalog, response;

String messageText(int index) => 'entry $index\n${'history line\n' * 5}';

Map<String, Object?> page(
  int start,
  int end, {
  int total = 30,
  int revision = 1,
}) => {
  'type': 'transcript_snapshot',
  'sessionId': 'a',
  'version': 1,
  'revision': revision,
  'running': false,
  'messages': [
    for (var i = start; i < end; i++)
      {'role': i.isEven ? 'user' : 'assistant', 'text': messageText(i)},
  ],
  'pendingPermissions': [],
  'history': {
    'start': start,
    'total': total,
    'before': start == 0 ? null : 'before-$start',
    'token': 'window-$revision-$start-$end',
  },
};

Map<String, Object?> payload(Map<String, Object?> snapshot) => {
  'sessionId': 'a',
  'projectId': 'project',
  'title': 'a',
  'transcript': snapshot,
};

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('pages join once and refreshed tails retain already loaded history', () {
    final tail = RemoteTranscriptSnapshot.tryParse(page(20, 30))!;
    final middle = RemoteTranscriptSnapshot.tryParse(page(10, 20))!;
    final merged = tail.prepend(middle)!;
    expect(merged.messages.length, 20);
    expect(merged.messageStart, 10);
    expect(merged.olderCursor, 'before-10');
    expect(merged.windowToken, tail.windowToken);
    expect(merged.prepend(middle), isNull);
    final refreshed = RemoteTranscriptSnapshot.tryParse(
      page(20, 30, revision: 2),
    )!;
    expect(refreshed.retainEarlier(merged).messages.length, 20);
    final replacement = RemoteTranscriptSnapshot.tryParse({
      ...page(20, 30, revision: 2),
      'messages': [
        for (var i = 20; i < 30; i++)
          {'role': 'user', 'text': 'replacement $i'},
      ],
    })!;
    expect(replacement.retainEarlier(merged).messages.length, 10);
    expect(
      RemoteTranscriptSnapshot.tryParse({
        ...page(20, 30),
        'history': {'start': -1},
      }),
      isNull,
    );
  });

  testWidgets(
    'loading earlier messages deduplicates requests and preserves the visible anchor',
    (tester) async {
      final pending = Completer<http.Response>();
      final requests = <http.Request>[];
      final dynamic state = await boot(
        tester,
        RemoteApiClient(
          client: MockClient((request) {
            requests.add(request);
            return pending.future;
          }),
        ),
      );
      state.handleWsMessage(page(20, 30));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('transcript-list')),
        const Offset(0, 6000),
      );
      await tester.pumpAndSettle();
      unawaited(state.loadEarlierMessages('a') as Future<void>);
      await tester.pump();
      expect(requests.length, 1);
      expect(requests.single.url.queryParameters['before'], 'before-20');
      final anchor = find.text(messageText(20).trim());
      expect(anchor, findsOneWidget);
      final oldY = tester.getTopLeft(anchor).dy;
      pending.complete(response(payload(page(10, 20))));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          anchor,
          findsOneWidget,
          reason: 'anchor missing at frame $frame',
        );
        expect(
          tester.getTopLeft(anchor).dy,
          closeTo(oldY, 2),
          reason: 'anchor moved at frame $frame',
        );
      }
      await tester.pumpAndSettle();
      expect(state.messages.length, 20);
      expect(state.cachedSessionTranscript('a').snapshot.messageStart, 10);
      expect(tester.getTopLeft(anchor).dy, closeTo(oldY, 2));
      state.handleWsMessage({
        ...page(20, 30),
        'unchanged': true,
        'messages': [],
      });
      await tester.pumpAndSettle();
      expect(state.messages.length, 20);
      expect(state.cachedSessionTranscript('a').snapshot.messageStart, 10);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'search loads older pages before resolving an absolute message index',
    (tester) async {
      final cursors = <String>[];
      final dynamic state = await boot(
        tester,
        RemoteApiClient(
          client: MockClient((request) async {
            final cursor = request.url.queryParameters['before']!;
            cursors.add(cursor);
            final end = int.parse(cursor.split('-').last);
            return response(payload(page(end - 10, end)));
          }),
        ),
      );
      state.handleWsMessage(page(20, 30));
      await tester.pumpAndSettle();
      state.selectRemoteSessionWithJump(
        'a',
        jump: const TranscriptJumpRequest(
          generation: 1,
          sessionId: 'a',
          messageIndex: 5,
          role: RemoteSessionSearchRole.assistant,
          snippet: 'entry 5',
        ),
      );
      await tester.pumpAndSettle();
      expect(cursors, ['before-20', 'before-10']);
      expect(state.messages.length, 30);
      expect(state.messages.map((message) => message.text).toSet().length, 30);
      expect(
        find.byKey(const ValueKey('transcript-load-earlier')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('transcript-search-hit-5')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final processBoundary in [false, true]) {
    testWidgets(
      'paging keeps every frame and mounted row stable (process: $processBoundary)',
      (tester) async {
        var start = 20;
        var loading = false;
        late StateSetter update;
        late Completer<void> pending;
        final messages = [
          for (var i = 0; i < 30; i++)
            if (processBoundary && i >= 18 && i <= 22)
              TranscriptMessage.activity(
                'read $i',
                id: 'tool-$i',
                kind: ActivityKind.tool,
                state: ActivityState.done,
                tool: 'Read',
                detail: 'file-$i.dart',
              )
            else
              TranscriptMessage.user(
                'entry $i\n${'variable height\n' * (i % 7 + 1)}',
              ),
        ];
        Future<void> load() async {
          pending = Completer<void>();
          update(() => loading = true);
          await pending.future;
          update(() {
            start -= 10;
            loading = false;
          });
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return TranscriptView(
                    messages: messages.sublist(start),
                    messageStart: start,
                    historyLoading: loading,
                    topPadding: 80,
                    onLoadEarlier: start == 0 ? null : () => unawaited(load()),
                    connected: true,
                    pendingPermissions: const [],
                    respondingPermissionIds: const {},
                    onFillPrompt: (_) {},
                    onReconnect: () {},
                    onPermissionAllow: (_) {},
                    onPermissionDeny: (_) {},
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<ScrollView>(find.byKey(const ValueKey('transcript-list')))
            .controller!;

        for (final pageStart in [20, 10]) {
          for (var attempt = 0; attempt < 8; attempt++) {
            controller.jumpTo(controller.position.minScrollExtent);
            await tester.pumpAndSettle();
            if (controller.position.extentBefore < 1) break;
          }
          final process = processBoundary && pageStart == 20;
          final anchor = process
              ? find.byWidgetPredicate(
                  (widget) =>
                      widget is ActivityTimelineCard &&
                      widget.activities.any(
                        (item) => item.activityId == 'tool-20',
                      ),
                )
              : find.text(messages[pageStart].text.trim());
          if (process) {
            await tester.tap(
              find.byKey(const ValueKey('activity-process-toggle')),
            );
            await tester.pumpAndSettle();
          }
          expect(
            anchor,
            findsOneWidget,
            reason: 'before loading page $pageStart',
          );
          final element = tester.element(anchor);
          final y = tester.getTopLeft(anchor).dy;
          await tester.tap(
            find.byKey(const ValueKey('transcript-load-earlier')),
          );
          await tester.pump();
          expect(tester.getTopLeft(anchor).dy, closeTo(y, 0.5));
          pending.complete();
          for (var frame = 0; frame < 12; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(anchor, findsOneWidget);
            expect(tester.element(anchor), same(element));
            expect(
              tester.getTopLeft(anchor).dy,
              closeTo(y, 0.5),
              reason: 'page $pageStart, frame $frame',
            );
          }
          if (process) {
            expect(
              find.byKey(const ValueKey('activity-detail-tool-20')),
              findsOneWidget,
            );
          }
          await tester.pumpAndSettle();
        }
        expect(
          find.byKey(const ValueKey('transcript-load-earlier')),
          findsNothing,
        );
        controller.jumpTo(controller.position.minScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text(messages.first.text.trim()), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('a late older page cannot replace another session', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final dynamic state = await boot(
      tester,
      RemoteApiClient(client: MockClient((_) => pending.future)),
    );
    state.handleWsMessage(page(20, 30));
    await tester.pumpAndSettle();
    final operation = state.loadEarlierMessages('a') as Future<void>;
    state.handleWsMessage({'type': 'catalog', ...catalog('b')});
    state.handleWsMessage({...page(0, 1, total: 1), 'sessionId': 'b'});
    pending.complete(response(payload(page(10, 20))));
    await operation;
    await tester.pumpAndSettle();
    expect(state.activeSessionId, 'b');
    expect(state.messages.length, 1);
    expect(state.messages.single.text, messageText(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'changed history resets to a fresh page instead of joining stale offsets',
    (tester) async {
      final paths = <Uri>[];
      final dynamic state = await boot(
        tester,
        RemoteApiClient(
          client: MockClient((request) async {
            paths.add(request.url);
            return paths.length == 1
                ? response({'error': 'transcript_history_changed'}, 409)
                : response(payload(page(0, 10, total: 10, revision: 2)));
          }),
        ),
      );
      state.handleWsMessage(page(20, 30));
      await tester.pumpAndSettle();
      await state.loadEarlierMessages('a');
      await tester.pumpAndSettle();
      expect(paths.length, 2);
      expect(paths.last.queryParameters.containsKey('before'), isFalse);
      expect(state.messages.length, 10);
      expect(state.messages.first.text, messageText(0));
      expect(find.byType(MessageBlock).hitTestable(), findsWidgets);
      expect(state.cachedSessionTranscript('a').snapshot.olderCursor, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
