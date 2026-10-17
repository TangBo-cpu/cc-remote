import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TranscriptReadingPosition {
  const TranscriptReadingPosition({
    required this.followingBottom,
    required this.scrollOffset,
    this.rawIndex,
    this.role,
    this.textPrefix,
    this.anchorOffset = 0,
  });

  final bool followingBottom;
  final double scrollOffset;
  final int? rawIndex;
  final String? role;
  final String? textPrefix;
  final double anchorOffset;

  Map<String, dynamic> toJson() => {
    'followingBottom': followingBottom,
    'scrollOffset': scrollOffset,
    'rawIndex': rawIndex,
    'role': role,
    'textPrefix': textPrefix,
    'anchorOffset': anchorOffset,
  };

  factory TranscriptReadingPosition.fromJson(Map<String, dynamic> json) {
    double finiteOffset(String key) {
      final value = (json[key] as num?)?.toDouble() ?? 0;
      return value.isFinite ? value : 0;
    }

    return TranscriptReadingPosition(
      followingBottom: json['followingBottom'] != false,
      scrollOffset: finiteOffset('scrollOffset'),
      rawIndex: (json['rawIndex'] as num?)?.toInt(),
      role: json['role'] as String?,
      textPrefix: json['textPrefix'] as String?,
      anchorOffset: finiteOffset('anchorOffset'),
    );
  }
}

class SessionMemory {
  TextEditingValue draft = TextEditingValue.empty;
  TranscriptReadingPosition? readingPosition;

  Map<String, dynamic> toJson() => {
    'text': draft.text,
    'selectionBase': draft.selection.baseOffset,
    'selectionExtent': draft.selection.extentOffset,
    'selectionAffinity': draft.selection.affinity.name,
    'selectionDirectional': draft.selection.isDirectional,
    if (readingPosition != null) 'readingPosition': readingPosition!.toJson(),
  };

  static SessionMemory fromJson(Map<String, dynamic> json) {
    final memory = SessionMemory();
    final text = json['text'] as String? ?? '';
    int selectionOffset(String key) =>
        ((json[key] as num?)?.toInt() ?? text.length).clamp(0, text.length);
    memory.draft = TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: selectionOffset('selectionBase'),
        extentOffset: selectionOffset('selectionExtent'),
        affinity: json['selectionAffinity'] == TextAffinity.upstream.name
            ? TextAffinity.upstream
            : TextAffinity.downstream,
        isDirectional: json['selectionDirectional'] == true,
      ),
    );
    final reading = json['readingPosition'];
    if (reading is Map<String, dynamic>) {
      memory.readingPosition = TranscriptReadingPosition.fromJson(reading);
    }
    return memory;
  }
}

class SessionMemoryStore {
  SessionMemoryStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_session_memory';
  final FlutterSecureStorage storage;
  final Map<String, SessionMemory> _sessions = {};
  Timer? _saveTimer;
  Future<void> _lastWrite = Future<void>.value();
  String? _lastQueuedRaw;
  String? _pendingRaw;
  bool _snapshotWriteQueued = false;
  int _generation = 0;

  SessionMemory forSession(String sessionId) =>
      _sessions.putIfAbsent(sessionId, SessionMemory.new);

  bool contains(String sessionId, SessionMemory memory) =>
      identical(_sessions[sessionId], memory);

  void forget(String sessionId) {
    _sessions.remove(sessionId);
    unawaited(flush());
  }

  Future<void> load() async {
    try {
      final raw = await storage.read(key: key);
      if (raw == null) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic> || json['version'] != 1) return;
      final sessions = json['sessions'];
      if (sessions is! Map<String, dynamic>) return;
      for (final entry in sessions.entries) {
        try {
          _sessions[entry.key] = SessionMemory.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        } catch (_) {
          // A damaged entry must not discard other sessions' drafts.
        }
      }
    } catch (_) {
      // Chat remains available if local storage cannot be read.
    }
  }

  void scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(flush());
    });
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final raw = jsonEncode({
      'version': 1,
      'sessions': _sessions.map((id, memory) => MapEntry(id, memory.toJson())),
    });
    if (raw == _lastQueuedRaw) return _lastWrite;
    _lastQueuedRaw = raw;
    _pendingRaw = raw;
    if (_snapshotWriteQueued) return _lastWrite;
    _snapshotWriteQueued = true;
    final generation = _generation;
    return _queueWrite(() async {
      if (generation != _generation) return;
      final latest = _pendingRaw;
      _pendingRaw = null;
      _snapshotWriteQueued = false;
      if (latest == null) return;
      try {
        await storage.write(key: key, value: latest);
      } catch (_) {
        if (generation == _generation && _lastQueuedRaw == latest) {
          _lastQueuedRaw = null;
        }
        rethrow;
      }
    });
  }

  Future<void> clear() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _generation++;
    _pendingRaw = null;
    _snapshotWriteQueued = false;
    _lastQueuedRaw = null;
    _sessions.clear();
    return _queueWrite(() => storage.delete(key: key));
  }

  Future<void> _queueWrite(Future<void> Function() write) {
    final previous = _lastWrite;
    _lastWrite = () async {
      await previous;
      try {
        await write();
      } catch (_) {}
    }();
    return _lastWrite;
  }
}
