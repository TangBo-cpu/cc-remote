import 'dart:async';
import 'dart:convert';

import 'package:cc_remote/data/remote_models.dart';
import 'package:cc_remote/main.dart' show TranscriptStore;
import 'package:cc_remote/session_memory.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TranscriptSnapshot transcript(String text) => TranscriptSnapshot(
    sessionId: 'session',
    messages: [TranscriptMessage.assistant(text)],
    running: false,
  );

  test(
    'slow transcript storage writes only the latest pending snapshot',
    () async {
      final storage = _RecordingStorage()..barrier = Completer<void>();
      final store = TranscriptStore(storage: storage);
      final first = store.save(transcript('first'));
      await Future<void>.delayed(Duration.zero);
      final writes = [first];
      for (var i = 0; i < 20; i++) {
        writes.add(store.save(transcript('reply $i')));
      }
      storage.barrier!.complete();
      await Future.wait(writes);

      expect(storage.writes, hasLength(2));
      final json = jsonDecode(storage.value!) as Map<String, dynamic>;
      expect(json['messages'][0]['text'], 'reply 19');
    },
  );

  test(
    'clearing a transcript drops pending snapshots before the next save',
    () async {
      final storage = _RecordingStorage()..barrier = Completer<void>();
      final store = TranscriptStore(storage: storage);
      final first = store.save(transcript('old'));
      await Future<void>.delayed(Duration.zero);
      final pending = store.save(transcript('pending'));
      final clearing = store.clear();
      final latest = store.save(transcript('new'));
      storage.barrier!.complete();
      await Future.wait([first, pending, clearing, latest]);

      expect(storage.writes, hasLength(2));
      expect(storage.value, contains('new'));
      expect(storage.value, isNot(contains('pending')));
    },
  );

  test('transcript saving can recover after a storage failure', () async {
    final storage = _RecordingStorage()..failNext = true;
    final store = TranscriptStore(storage: storage);
    await expectLater(store.save(transcript('retry')), throwsStateError);
    await store.save(transcript('retry'));
    expect(storage.writes, hasLength(2));
    expect(storage.value, contains('retry'));
  });

  test('unchanged session memory is written only once', () async {
    final storage = _RecordingStorage();
    final store = SessionMemoryStore(storage: storage);
    store.forSession('session').draft = const TextEditingValue(text: 'draft');
    for (var i = 0; i < 20; i++) {
      await store.flush();
    }
    expect(storage.writes, hasLength(1));
  });

  test(
    'slow storage coalesces pending snapshots into the latest one',
    () async {
      final storage = _RecordingStorage()..barrier = Completer<void>();
      final store = SessionMemoryStore(storage: storage);
      final memory = store.forSession('session');
      memory.draft = const TextEditingValue(text: 'first');
      final writes = [store.flush()];
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 20; i++) {
        memory.draft = TextEditingValue(text: 'draft $i');
        writes.add(store.flush());
      }
      storage.barrier!.complete();
      await Future.wait(writes);

      expect(storage.writes, hasLength(2));
      final json = jsonDecode(storage.value!) as Map<String, dynamic>;
      expect(json['sessions']['session']['text'], 'draft 19');
    },
  );

  test('a failed write can retry the same snapshot', () async {
    final storage = _RecordingStorage()..failNext = true;
    final store = SessionMemoryStore(storage: storage);
    store.forSession('session').draft = const TextEditingValue(text: 'retry');
    await store.flush();
    await store.flush();
    expect(storage.writes, hasLength(2));
    expect(storage.value, contains('retry'));
  });

  test(
    'clearing memory cancels old pending snapshots before a new save',
    () async {
      final storage = _RecordingStorage()..barrier = Completer<void>();
      final store = SessionMemoryStore(storage: storage);
      store.forSession('old').draft = const TextEditingValue(text: 'old');
      final first = store.flush();
      await Future<void>.delayed(Duration.zero);
      store.forSession('old').draft = const TextEditingValue(text: 'pending');
      final pending = store.flush();
      final clearing = store.clear();
      store.forSession('new').draft = const TextEditingValue(text: 'new');
      final latest = store.flush();
      storage.barrier!.complete();
      await Future.wait([first, pending, clearing, latest]);

      expect(storage.writes, hasLength(2));
      final json = jsonDecode(storage.value!) as Map<String, dynamic>;
      expect((json['sessions'] as Map).keys, ['new']);
      expect(json['sessions']['new']['text'], 'new');
    },
  );
}

class _RecordingStorage extends FlutterSecureStorage {
  final writes = <String>[];
  Completer<void>? barrier;
  bool failNext = false;
  String? value;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes.add(value!);
    if (barrier != null && writes.length == 1) await barrier!.future;
    if (failNext) {
      failNext = false;
      throw StateError('storage unavailable');
    }
    this.value = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    value = null;
  }
}
