import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'noto_icon.dart';
import 'signal_console_theme.dart';

class ConversationPickerOption<T> {
  const ConversationPickerOption({
    required this.value,
    required this.id,
    required this.title,
    required this.description,
    required this.leading,
    required this.group,
    this.enabled = true,
    this.danger = false,
    this.badge,
  });

  final T value;
  final String id;
  final String title;
  final String description;
  final Widget leading;
  final String group;
  final bool enabled;
  final bool danger;
  final Widget? badge;
}

class ConversationOptionSheet<T> extends StatefulWidget {
  const ConversationOptionSheet({
    super.key,
    required this.title,
    required this.detail,
    required this.selected,
    required this.options,
    this.headerAction,
    this.status,
  });

  final String title;
  final String detail;
  final T selected;
  final List<ConversationPickerOption<T>> options;
  final Widget? headerAction;
  final Widget? status;

  @override
  State<ConversationOptionSheet<T>> createState() =>
      _ConversationOptionSheetState<T>();
}

class _ConversationOptionSheetState<T>
    extends State<ConversationOptionSheet<T>> {
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    revealSelection();
  }

  @override
  void didUpdateWidget(covariant ConversationOptionSheet<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.options.length != widget.options.length ||
        oldWidget.selected != widget.selected) {
      revealSelection();
    }
  }

  void revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selectedContext = _selectedKey.currentContext;
      if (!mounted || selectedContext == null) return;
      Scrollable.ensureVisible(selectedContext, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // No horizontal padding: the surface already insets the content, so the
        // title sits flush with the option rows below it.
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (widget.headerAction != null) widget.headerAction!,
                  IconButton(
                    tooltip: '关闭选择器',
                    onPressed: () => Navigator.pop(context),
                    icon: SmartIcon(LucideIcons.x, size: AppIconSizes.control, color: palette.muted),
                  ),
                ],
              ),
              Text(
                widget.detail,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              if (widget.status != null) widget.status!,
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('conversation-picker-list'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var index = 0; index < widget.options.length; index++) ...[
                  if (index == 0 ||
                      widget.options[index].group !=
                          widget.options[index - 1].group)
                    Padding(
                      // Sits on the row's icon column (12), not the row box edge.
                      padding: EdgeInsets.fromLTRB(
                        12,
                        index == 0 ? 8 : 16,
                        12,
                        4,
                      ),
                      child: Text(
                        widget.options[index].group,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  Padding(
                    key: widget.options[index].value == widget.selected
                        ? _selectedKey
                        : null,
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _ConversationOptionRow<T>(
                      key: ValueKey(widget.options[index].id),
                      option: widget.options[index],
                      selected: widget.options[index].value == widget.selected,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ConversationOptionRow<T> extends StatelessWidget {
  const _ConversationOptionRow({
    super.key,
    required this.option,
    required this.selected,
  });

  final ConversationPickerOption<T> option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = !option.enabled
        ? palette.muted
        : option.danger
        ? palette.stop
        : palette.ink;
    return Semantics(
      selected: selected,
      enabled: option.enabled,
      button: true,
      child: Material(
        color: selected
            ? palette.accentSoft
            : option.danger && option.enabled
            ? palette.stop.withValues(alpha: 0.06)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected
                ? color.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: option.enabled
              ? () => Navigator.pop(context, option.value)
              : null,
          child: ConstrainedBox(
            // Cherry Studio parity: a 48pt floor and one 32pt avatar keep a long
            // catalogue scannable without a tall icon seat on every row.
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconTheme(
                      data: IconThemeData(size: AppIconSizes.control, color: color),
                      child: Center(child: option.leading),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          option.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: color,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                        if (option.description.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            option.description,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (option.badge != null) ...[
                    const SizedBox(width: 8),
                    option.badge!,
                  ],
                  if (selected) ...[
                    const SizedBox(width: 8),
                    ExcludeSemantics(
                      child: SmartIcon(
                        LucideIcons.circleCheck,
                        size: AppIconSizes.control,
                        color: color,
                      ),
                    ),
                  ] else if (!option.enabled) ...[
                    const SizedBox(width: 8),
                    ExcludeSemantics(
                      child: SmartIcon(
                        LucideIcons.lockKeyhole,
                        size: AppIconSizes.control,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact capability mark on an option row, in the Cherry Studio mobile
/// recipe: 20pt chip, 8pt corners, 12pt icon. The row already speaks its title
/// and description, so the mark stays out of the accessibility tree and carries
/// [label] for the cases where it is the only place the trait is written.
class ConversationPickerBadge extends StatelessWidget {
  const ConversationPickerBadge({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
  });

  final Widget icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: ExcludeSemantics(
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: IconTheme(
          data: IconThemeData(size: AppIconSizes.badge, color: color),
          child: Center(child: icon),
        ),
      ),
    ),
  );
}
