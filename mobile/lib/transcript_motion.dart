import 'data/remote_models.dart';

// UI-only cues. Snapshots and storage never carry animation state.
class TranscriptMotion {
  final Set<TranscriptMessage> _messages = Set.identity();
  final Set<String> _permissions = {};
  Object? _lastCompletedRun;
  Object? completionEvent;

  void recordMessage(TranscriptMessage message) => _messages.add(message);

  void replaceMessage(TranscriptMessage previous, TranscriptMessage next) {
    if (_messages.remove(previous)) _messages.add(next);
  }

  bool takeMessage(TranscriptMessage message) => _messages.remove(message);

  void recordPermission(String requestId) => _permissions.add(requestId);

  bool takePermission(String requestId) => _permissions.remove(requestId);

  void completeRun(Object runKey) {
    if (_lastCompletedRun == runKey) return;
    _lastCompletedRun = runKey;
    completionEvent = Object();
  }

  void discardEntrances() {
    _messages.clear();
    _permissions.clear();
  }

  void reset({bool preserveCompletedRun = false}) {
    discardEntrances();
    completionEvent = null;
    if (!preserveCompletedRun) _lastCompletedRun = null;
  }
}
