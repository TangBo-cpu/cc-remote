import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'signal_console_theme.dart';

// Cherry Studio mobile: text-led status rows, adjacent chevrons, a 2s glyph
// sweep, and natural disclosure layout. Touch targets retain the app's 48dp.
class ActivityMotion {
  static const fast = Duration(milliseconds: 200);
  static const shimmer = Duration(milliseconds: 2000);
  static const settle = Cubic(0.22, 1, 0.36, 1);
}

class ActivityDisclosure extends StatefulWidget {
  const ActivityDisclosure({
    super.key,
    required this.expanded,
    required this.title,
    required this.child,
    this.running = false,
    this.statusText,
    this.tone,
    this.onToggle,
    this.toggleKey,
    this.titleKey,
    this.semanticLabel,
    this.leading,
    this.titleWidget,
  });

  final bool expanded;
  final String title;
  final Widget child;
  final bool running;
  final String? statusText;
  final Color? tone;
  final VoidCallback? onToggle;
  final Key? toggleKey;
  final Key? titleKey;
  final String? semanticLabel;
  final Widget? leading;
  final Widget? titleWidget;

  @override
  State<ActivityDisclosure> createState() => _ActivityDisclosureState();
}

class _ActivityDisclosureState extends State<ActivityDisclosure> {
  final headerKey = GlobalKey();

  @override
  void didUpdateWidget(covariant ActivityDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    final box = headerKey.currentContext?.findRenderObject();
    final position = Scrollable.maybeOf(context)?.position;
    if (box is! RenderBox || position == null) return;
    final anchorTop = box.localToGlobal(Offset.zero).dy;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || Scrollable.maybeOf(context)?.position != position) return;
      final currentBox = headerKey.currentContext?.findRenderObject();
      if (currentBox is! RenderBox ||
          !currentBox.attached ||
          !position.hasContentDimensions) {
        return;
      }
      final delta = currentBox.localToGlobal(Offset.zero).dy - anchorTop;
      if (delta.abs() < 0.5) return;
      final reversed =
          position.axisDirection == AxisDirection.up ||
          position.axisDirection == AxisDirection.left;
      position.jumpTo(
        (position.pixels + (reversed ? -delta : delta)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ActivityStatusRow(
        key: headerKey,
        buttonKey: widget.toggleKey,
        titleKey: widget.titleKey,
        title: widget.title,
        leading: widget.leading,
        titleWidget: widget.titleWidget,
        running: widget.running,
        statusText: widget.statusText,
        tone: widget.tone,
        expanded: widget.expanded,
        onTap: widget.onToggle,
        semanticLabel: widget.semanticLabel,
      ),
      if (widget.expanded) ...[const SizedBox(height: 6), widget.child],
    ],
  );
}

class ActivityStatusRow extends StatelessWidget {
  const ActivityStatusRow({
    super.key,
    required this.title,
    this.buttonKey,
    this.titleKey,
    this.leading,
    this.titleWidget,
    this.running = false,
    this.expanded,
    this.statusText,
    this.tone,
    this.onTap,
    this.semanticLabel,
  });

  final String title;
  final Key? buttonKey;
  final Key? titleKey;
  final Widget? leading;
  final Widget? titleWidget;
  final bool running;
  final bool? expanded;
  final String? statusText;
  final Color? tone;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = tone ?? palette.muted;
    return Material(
      color: Colors.transparent,
      child: Semantics(
        container: true,
        button: onTap != null,
        expanded: onTap == null ? null : expanded,
        onTap: onTap,
        liveRegion: running,
        label:
            semanticLabel ??
            '$title${statusText == null ? '' : '，$statusText'}',
        excludeSemantics: true,
        child: InkWell(
          key: buttonKey,
          excludeFromSemantics: true,
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.compact),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSizes.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child:
                                titleWidget ??
                                ActivityShimmerText(
                                  title,
                                  key: titleKey,
                                  active: running,
                                  color: color,
                                ),
                          ),
                          if (onTap != null) ...[
                            const SizedBox(width: 6),
                            AnimatedRotation(
                              turns: expanded == true ? 0.25 : 0,
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : ActivityMotion.fast,
                              curve: ActivityMotion.settle,
                              child: Icon(
                                LucideIcons.chevronRight,
                                size: AppIconSizes.badge,
                                color: color,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (statusText != null) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * 0.38,
                        ),
                        child: Text(
                          statusText!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: color,
                            fontSize: 12,
                            height: 1.4,
                          ),
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

class ActivityShimmerText extends StatefulWidget {
  const ActivityShimmerText(
    this.text, {
    super.key,
    this.active = true,
    this.color,
  });

  final String text;
  final bool active;
  final Color? color;

  @override
  State<ActivityShimmerText> createState() => _ActivityShimmerTextState();
}

class _ActivityShimmerTextState extends State<ActivityShimmerText>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: ActivityMotion.shimmer,
  );

  void syncAnimation() {
    final enabled =
        widget.active &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.of(context);
    if (enabled) {
      if (!animation.isAnimating) animation.repeat();
    } else {
      animation.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ActivityShimmerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncAnimation();
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final animating =
        widget.active &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.of(context);
    final base = animating ? palette.ink : widget.color ?? palette.muted;
    final text = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: base,
        fontSize: AppTypography.activityBodySize,
        height: 1.45,
      ),
    );
    if (!animating) return text;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: animation,
        child: text,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            final band = math.max(44.0, bounds.width * 0.55);
            final start = -band + (bounds.width + band) * animation.value;
            return LinearGradient(
              colors: [base, palette.muted, base],
              stops: const [0, 0.5, 1],
            ).createShader(Rect.fromLTWH(start, 0, band, bounds.height));
          },
          child: child,
        ),
      ),
    );
  }
}
