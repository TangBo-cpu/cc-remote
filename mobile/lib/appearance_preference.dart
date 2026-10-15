import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

String appearanceLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => '跟随系统',
  ThemeMode.light => '浅色',
  ThemeMode.dark => '深色',
};

class AppearancePreferenceStore {
  AppearancePreferenceStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_appearance';
  final FlutterSecureStorage storage;

  Future<ThemeMode> load() async {
    try {
      return switch (await storage.read(key: key)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      return ThemeMode.system;
    }
  }

  Future<void> save(ThemeMode mode) => mode == ThemeMode.system
      ? storage.delete(key: key)
      : storage.write(key: key, value: mode.name);
}

class AppearanceController extends ValueNotifier<ThemeMode> {
  AppearanceController(this.store) : super(ThemeMode.system);

  final AppearancePreferenceStore store;
  int _revision = 0;
  bool _disposed = false;
  Future<void> _lastWrite = Future<void>.value();

  Future<void> initialize() async {
    final revision = _revision;
    final saved = await store.load();
    if (!_disposed && revision == _revision) value = saved;
  }

  Future<void> select(ThemeMode mode) async {
    final previous = value;
    final revision = ++_revision;
    value = mode;
    final write = _lastWrite.then((_) => store.save(mode));
    _lastWrite = write.then<void>((_) {}, onError: (Object _) {});
    try {
      await write;
    } catch (_) {
      if (!_disposed && revision == _revision) value = previous;
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);
  static AppearanceController of(BuildContext context) => maybeOf(context)!;

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
