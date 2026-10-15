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
      orElse: () => PermissionMode.auto,
    );
  }
}

enum CodexSandboxMode {
  readOnly('read-only', '只读', '允许读取工作区，不允许写入文件'),
  workspaceWrite('workspace-write', '工作区可写', '允许读取和修改当前工作区'),
  dangerFullAccess('danger-full-access', '完全访问', '关闭沙箱限制，可访问工作区外的文件和命令');

  const CodexSandboxMode(this.wireName, this.label, this.description);

  final String wireName;
  final String label;
  final String description;

  static const supportedModes = <CodexSandboxMode>[
    readOnly,
    workspaceWrite,
    dangerFullAccess,
  ];

  static CodexSandboxMode fromWire(Object? value) {
    if (value == null) return CodexSandboxMode.dangerFullAccess;
    return values.firstWhere(
      (mode) => mode.wireName == value,
      orElse: () => CodexSandboxMode.readOnly,
    );
  }

  static List<CodexSandboxMode>? listFromWire(Object? value) {
    if (value is! List) return null;
    final modes = <CodexSandboxMode>[];
    for (final raw in value) {
      for (final mode in supportedModes) {
        if (mode.wireName == raw && !modes.contains(mode)) {
          modes.add(mode);
          break;
        }
      }
    }
    return modes.isEmpty ? const [CodexSandboxMode.readOnly] : modes;
  }
}
