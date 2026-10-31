import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'noto_icon.dart';
import 'signal_console_theme.dart';

Future<T?> showConversationLensPicker<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool requestFocus = true,
}) {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()!;
  final trigger = context.findRenderObject();
  final source =
      trigger is RenderBox &&
          trigger.hasSize &&
          trigger.size.width <= 96 &&
          trigger.size.height <= 96
      ? trigger.localToGlobal(Offset.zero, ancestor: overlay) & trigger.size
      : null;
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push<T>(
    _ConversationLensRoute<T>(
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      requestFocus: requestFocus,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      pageBuilder: (sheetContext, animation, _) {
        final media = MediaQuery.of(sheetContext);
        return themes.wrap(
          Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                SheetScrim(
                  color: AppPalette.of(sheetContext).scrim,
                  onTap: () => Navigator.pop(sheetContext),
                ),
                Flow(
                  key: const ValueKey('conversation-lens-transition'),
                  clipBehavior: Clip.none,
                  delegate: _ConversationLensFlow(
                    animation: animation,
                    source: source,
                    padding: EdgeInsets.fromLTRB(
                      16,
                      media.padding.top + 100,
                      16,
                      math.max(media.padding.bottom, media.viewInsets.bottom) +
                          20,
                    ),
                    maxWidth: media.size.width >= 720 ? 560 : 480,
                  ),
                  children: [
                    SnapshotWhileAnimating(
                      animation: animation,
                      child: builder(sheetContext),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _ConversationLensRoute<T> extends RawDialogRoute<T> {
  _ConversationLensRoute({
    required this.reduceMotion,
    required super.pageBuilder,
    required super.barrierLabel,
    required super.requestFocus,
  }) : super(
         barrierColor: Colors.transparent,
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
         transitionDuration: reduceMotion
             ? Duration.zero
             : const Duration(milliseconds: 420),
         transitionBuilder: (context, animation, secondaryAnimation, child) =>
             child,
       );

  final bool reduceMotion;

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : AppMotion.standard;
}

class _ConversationLensFlow extends FlowDelegate {
  _ConversationLensFlow({
    required this.animation,
    required this.source,
    required this.padding,
    required this.maxWidth,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Rect? source;
  final EdgeInsets padding;
  final double maxWidth;

  @override
  BoxConstraints getConstraintsForChild(int index, BoxConstraints constraints) {
    final width = math.max(
      0.0,
      math.min(maxWidth, constraints.maxWidth - padding.horizontal),
    );
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.max(0, constraints.maxHeight - padding.vertical),
    );
  }

  @override
  void paintChildren(FlowPaintingContext context) {
    final size = context.getChildSize(0)!;
    if (size.isEmpty) return;
    final target = Rect.fromLTWH(
      (context.size.width - size.width) / 2,
      context.size.height - padding.bottom - size.height,
      size.width,
      size.height,
    );
    final origin =
        source ??
        Rect.fromCenter(
          center: target.bottomCenter - const Offset(0, 24),
          width: 48,
          height: 48,
        );
    final progress = AppMotion.enter.transform(animation.value);
    final rect = Rect.lerp(origin, target, progress)!;
    // Paint transforms keep the catalogue laid out once while the lens unfolds.
    context.paintChild(
      0,
      opacity: (animation.value * 5).clamp(0, 1),
      transform: Matrix4.identity()
        ..translateByDouble(rect.left, rect.top, 0, 1)
        ..scaleByDouble(
          rect.width / size.width,
          rect.height / size.height,
          1,
          1,
        ),
    );
  }

  @override
  bool shouldRelayout(_ConversationLensFlow oldDelegate) =>
      padding != oldDelegate.padding || maxWidth != oldDelegate.maxWidth;

  @override
  bool shouldRepaint(_ConversationLensFlow oldDelegate) =>
      animation != oldDelegate.animation ||
      source != oldDelegate.source ||
      shouldRelayout(oldDelegate);
}

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
    this.lens = false,
  });

  final String title;
  final String detail;
  final T selected;
  final List<ConversationPickerOption<T>> options;
  final Widget? headerAction;
  final Widget? status;
  final bool lens;

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
                    icon: SmartIcon(
                      LucideIcons.x,
                      size: AppIconSizes.control,
                      color: palette.muted,
                    ),
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
                      lens: widget.lens,
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
    required this.lens,
  });

  final ConversationPickerOption<T> option;
  final bool selected;
  final bool lens;

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
      child: DecoratedBox(
        decoration: lens
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    (selected ? palette.control : palette.surface).withValues(
                      alpha: MediaQuery.highContrastOf(context)
                          ? 1
                          : selected
                          ? 0.72
                          : 0.32,
                    ),
                    (selected ? palette.control : palette.surface).withValues(
                      alpha: MediaQuery.highContrastOf(context)
                          ? 1
                          : selected
                          ? 0.42
                          : 0.08,
                    ),
                  ],
                ),
                border: Border.all(
                  color: selected
                      ? color.withValues(alpha: 0.22)
                      : option.danger && option.enabled
                      ? palette.stop.withValues(alpha: 0.12)
                      : palette.glassHighlight.withValues(
                          alpha: palette.glassHighlight.a * 0.24,
                        ),
                ),
              )
            : const BoxDecoration(),
        child: Material(
          color: lens
              ? Colors.transparent
              : selected
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
                        data: IconThemeData(
                          size: AppIconSizes.control,
                          color: color,
                        ),
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
