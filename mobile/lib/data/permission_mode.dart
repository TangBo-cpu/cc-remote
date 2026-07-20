enum PermissionMode {
  manual,
  acceptEdits,
  auto,
  dontAsk,
  plan,
  bypassPermissions;

  String get wireName => name;

  static PermissionMode fromWire(Object? value) {
    return PermissionMode.values.firstWhere(
      (mode) => mode.wireName == value,
      orElse: () => PermissionMode.manual,
    );
  }
}
