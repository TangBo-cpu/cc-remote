import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'noto_icon.dart';
import 'signal_console_theme.dart';

class PairingCodeForm extends StatefulWidget {
  const PairingCodeForm({
    super.key,
    required this.pairing,
    required this.onSubmit,
    required this.onScan,
    this.error,
  });

  final bool pairing;
  final String? error;
  final void Function(Uri origin, String code) onSubmit;
  final VoidCallback onScan;

  @override
  State<PairingCodeForm> createState() => _PairingCodeFormState();
}

class _PairingCodeFormState extends State<PairingCodeForm> {
  final formKey = GlobalKey<FormState>();
  final address = TextEditingController();
  final code = TextEditingController();

  @override
  void dispose() {
    address.dispose();
    code.dispose();
    super.dispose();
  }

  String? validateAddress(String? value) {
    try {
      final uri = Uri.parse(value?.trim() ?? '');
      if ((uri.scheme == 'https' || uri.scheme == 'http') &&
          uri.hasAuthority &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          uri.port > 0 &&
          uri.port <= 65535) {
        return null;
      }
    } on FormatException {
      // Keep invalid input in the form so it can be corrected.
    }
    return '请输入完整服务地址，以 https:// 或 http:// 开头';
  }

  void submit() {
    if (widget.pairing || !formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    widget.onSubmit(Uri.parse(address.text.trim()), code.text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return SafeArea(
      key: const ValueKey('pair-code'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: widget.pairing ? null : widget.onScan,
                      icon: SmartIcon(
                        LucideIcons.scanLine,
                        color: palette.accentStrong,
                      ),
                      label: const Text('返回扫码'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '使用配对码连接',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '在电脑启动器或终端查看服务地址和 8 位配对码。',
                    style: TextStyle(color: palette.muted),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: address,
                    enabled: !widget.pairing,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '服务地址',
                      hintText: 'https://your-computer.example.com',
                      errorMaxLines: 2,
                    ),
                    validator: validateAddress,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: code,
                    enabled: !widget.pairing,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(8),
                    ],
                    decoration: const InputDecoration(
                      labelText: '8 位配对码',
                      hintText: '输入电脑上显示的数字',
                    ),
                    validator: (value) =>
                        RegExp(r'^\d{8}$').hasMatch(value ?? '')
                        ? null
                        : '请输入 8 位数字',
                    onFieldSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '5 分钟有效，使用后失效。输错 5 次需在电脑刷新。',
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                  if (widget.error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        widget.error!,
                        style: TextStyle(color: palette.danger),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: widget.pairing ? null : submit,
                    icon: widget.pairing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const SmartIcon(LucideIcons.link),
                    label: Text(widget.pairing ? '正在连接' : '连接电脑'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
