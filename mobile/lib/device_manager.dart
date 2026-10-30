part of 'main.dart';

typedef RemoteDeviceFetcher = Future<List<RemoteDevice>> Function();
typedef RemoteDeviceRevoker = Future<bool> Function(String deviceId);

Future<String> currentDeviceName() async {
  try {
    if (!kIsWeb && Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      final model = info.model.trim();
      final manufacturer = info.manufacturer.trim();
      if (model.isNotEmpty) {
        final duplicated = manufacturer.isNotEmpty &&
            model.toLowerCase().contains(manufacturer.toLowerCase());
        return duplicated ? model : '$manufacturer $model';
      }
    }
  } catch (_) {}
  return 'Android 设备';
}

String? formatDeviceTimestamp(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return null;
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  final now = DateTime.now();
  final clock =
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  final sameDay =
      time.year == now.year && time.month == now.month && time.day == now.day;
  return sameDay ? clock : '${time.month}月${time.day}日 $clock';
}

Future<void> showDeviceManagerSheet(
  BuildContext context, {
  required ValueListenable<int> revisionListenable,
  required RemoteDeviceFetcher fetchDevices,
  required RemoteDeviceRevoker revokeDevice,
  required VoidCallback onSelfRevoked,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: appOverlayAnimationStyle(context),
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (sheetContext) => appModalSheetScaffold(
      _SettingsModalSurface(
        surfaceKey: const ValueKey('devices-surface'),
        child: DeviceManagerPage(
          revisionListenable: revisionListenable,
          fetchDevices: fetchDevices,
          revokeDevice: revokeDevice,
          onSelfRevoked: onSelfRevoked,
        ),
      ),
      barrierColor: AppPalette.of(sheetContext).scrim,
    ),
  );
}

class DeviceManagerPage extends StatefulWidget {
  const DeviceManagerPage({
    super.key,
    required this.revisionListenable,
    required this.fetchDevices,
    required this.revokeDevice,
    required this.onSelfRevoked,
  });

  final ValueListenable<int> revisionListenable;
  final RemoteDeviceFetcher fetchDevices;
  final RemoteDeviceRevoker revokeDevice;
  final VoidCallback onSelfRevoked;

  @override
  State<DeviceManagerPage> createState() => _DeviceManagerPageState();
}

class _DeviceManagerPageState extends State<DeviceManagerPage> {
  List<RemoteDevice>? _devices;
  String? _error;
  String? _revokingDeviceId;

  @override
  void initState() {
    super.initState();
    widget.revisionListenable.addListener(_refreshIfMounted);
    _load();
  }

  @override
  void dispose() {
    widget.revisionListenable.removeListener(_refreshIfMounted);
    super.dispose();
  }

  void _refreshIfMounted() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    try {
      final devices = await widget.fetchDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'device_list_failed');
    }
  }

  Future<void> _confirmRevoke(RemoteDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: appOverlayAnimationStyle(context),
      builder: (dialogContext) => AppDialog(
        title: Text(device.current ? '撤销本机？' : '撤销「${device.name}」？'),
        content: Text(
          device.current
              ? '撤销后这台手机将立即退出配对并回到扫码界面，其他设备不受影响。'
              : '撤销后该设备将立即断开并无法再访问这台电脑，需要重新扫码配对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('device-revoke-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _revokingDeviceId = device.id);
    try {
      final revoked = await widget.revokeDevice(device.id);
      if (!mounted) return;
      if (revoked && device.current) {
        Navigator.of(context).pop();
        widget.onSelfRevoked();
        return;
      }
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('撤销失败，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _revokingDeviceId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      key: const ValueKey('devices-page'),
      children: [
        _SettingsPageHeader(
          title: '已配对设备',
          onClose: () => Navigator.pop(context),
        ),
        Expanded(
          child: _buildBody(context, palette),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, AppPalette palette) {
    final devices = _devices;
    if (_error != null) {
      return _DeviceStatusView(
        icon: LucideIcons.cloudOff,
        message: '设备列表加载失败',
        actionLabel: '重试',
        onAction: _load,
      );
    }
    if (devices == null) {
      return const Center(
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (devices.isEmpty) {
      return const _DeviceStatusView(
        icon: LucideIcons.smartphone,
        message: '暂无已配对设备',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        _SettingsGroupCard(
          children: [
            for (final device in devices) ...[
              if (device != devices.first) const _SettingsDivider(),
              _DeviceRow(
                device: device,
                revoking: _revokingDeviceId == device.id,
                onRevoke: () => _confirmRevoke(device),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '每台设备的访问权限相互独立；撤销会立即断开对方连接。新增设备请在电脑端刷新配对二维码。',
            style: TextStyle(
              color: palette.muted,
              fontSize: 12,
              height: 1.45,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.revoking,
    required this.onRevoke,
  });

  final RemoteDevice device;
  final bool revoking;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final pairedAt = formatDeviceTimestamp(device.pairedAt);
    final lastSeen = formatDeviceTimestamp(device.lastSeen);
    final activity = lastSeen != null && lastSeen != pairedAt
        ? '最近活跃 $lastSeen'
        : null;
    return Padding(
      key: ValueKey('device-row-${device.id}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          _SettingsLeadingIcon(
            icon: device.current ? LucideIcons.smartphone : LucideIcons.tablet,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        device.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: palette.ink,
                        ),
                      ),
                    ),
                    if (device.current) ...[
                      const SizedBox(width: 8),
                      _DeviceCurrentBadge(),
                    ],
                  ],
                ),
                if (pairedAt != null || activity != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (pairedAt != null) '配对于 $pairedAt',
                      ?activity,
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.muted,
                      height: 1.35,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          SizedBox.square(
            dimension: AppSizes.touchTarget,
            child: revoking
                ? const Center(
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    key: ValueKey('device-revoke-${device.id}'),
                    tooltip: '撤销此设备',
                    icon: SmartIcon(
                      LucideIcons.trash2,
                      size: AppIconSizes.control,
                      color: palette.danger,
                    ),
                    onPressed: onRevoke,
                  ),
          ),
        ],
      ),
    );
  }
}

class _DeviceCurrentBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '本机',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: palette.accent,
          height: 1.35,
        ),
      ),
    );
  }
}

class _DeviceStatusView extends StatelessWidget {
  const _DeviceStatusView({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SmartIcon(icon, size: 30, color: palette.muted),
          const SizedBox(height: 10),
          Text(message, style: TextStyle(color: palette.muted, fontSize: 14)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
