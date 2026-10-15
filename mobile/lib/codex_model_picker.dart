import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'conversation_option_sheet.dart';
import 'model_preference.dart';
import 'noto_icon.dart';
import 'signal_console_theme.dart';

class CodexModelOption {
  const CodexModelOption({
    required this.model,
    required this.displayName,
    this.description = '',
    this.isDefault = false,
  });

  final String model;
  final String displayName;
  final String description;
  final bool isDefault;

  static List<CodexModelOption> fromWire(Object? value) {
    if (value is! List) throw const FormatException('invalid_model_catalog');
    final models = <String, CodexModelOption>{};
    for (final item in value) {
      if (item is! Map || item['model'] is! String) continue;
      final model = normalizeCodexModel(item['model'] as String);
      if (model == null) continue;
      models[model] = CodexModelOption(
        model: model,
        displayName: item['displayName'] is String
            ? item['displayName'] as String
            : model,
        description: item['description'] is String
            ? item['description'] as String
            : '',
        isDefault: item['isDefault'] == true,
      );
    }
    return models.values.toList(growable: false);
  }
}

class CodexModelPicker extends StatefulWidget {
  const CodexModelPicker({
    super.key,
    required this.selected,
    required this.loadModels,
  });

  final String? selected;
  final Future<List<CodexModelOption>> Function() loadModels;

  @override
  State<CodexModelPicker> createState() => _CodexModelPickerState();
}

class _CodexModelPickerState extends State<CodexModelPicker> {
  List<CodexModelOption> models = const [];
  bool loading = true;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final next = await widget.loadModels();
      if (!mounted) return;
      setState(() {
        models = next;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ConversationOptionSheet<String>(
      title: '选择 Codex 模型',
      detail: '用于之后发送的消息，当前任务继续使用原模型。',
      selected: widget.selected ?? '',
      headerAction: IconButton(
        tooltip: '刷新模型',
        onPressed: loading ? null : load,
        icon: const SmartIcon(LucideIcons.rotateCw, size: AppIconSizes.control),
      ),
      status: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          loading
              ? '正在获取电脑端模型'
              : failed
              ? '模型获取失败，点击刷新重试'
              : models.isEmpty
              ? '电脑端未返回可选模型，可使用默认配置'
              : '已获取 ${models.length} 个模型',
          style: TextStyle(
            color: failed ? palette.danger : palette.muted,
            fontSize: 12,
          ),
        ),
      ),
      options: [
        const ConversationPickerOption(
          value: '',
          id: 'codex-model-option-follow',
          title: '跟随电脑配置',
          description: '使用电脑端或 Codex 的默认配置',
          leading: SmartIcon(LucideIcons.monitor, size: AppIconSizes.control),
          group: '电脑默认',
        ),
        if (widget.selected != null &&
            !models.any((item) => item.model == widget.selected))
          ConversationPickerOption(
            value: widget.selected!,
            id: 'codex-model-option-${widget.selected}',
            title: widget.selected!,
            description: loading ? '当前保存的模型' : '当前保存的模型，尚未在目录中找到',
            leading: const SmartIcon(LucideIcons.cpu, size: AppIconSizes.control),
            group: '当前选择',
          ),
        for (final model in models)
          ConversationPickerOption(
            value: model.model,
            id: 'codex-model-option-${model.model}',
            title: model.displayName,
            description: model.description,
            leading: const SmartIcon(LucideIcons.cpu, size: AppIconSizes.control),
            group: 'Codex 模型',
            badge: model.isDefault
                ? ConversationPickerBadge(
                    label: 'Codex 默认模型',
                    color: palette.success,
                    icon: const SmartIcon(
                      LucideIcons.badgeCheck,
                      size: AppIconSizes.badge,
                    ),
                  )
                : null,
          ),
      ],
    );
  }
}
