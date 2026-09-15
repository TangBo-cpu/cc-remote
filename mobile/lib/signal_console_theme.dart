import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class AppColors {
  static const paper = Color(0xFFF1F5F9);
  static const surface = Color(0xFFF7FAFC);
  static const surfaceElevated = Color(0xFFFBFCFD);
  static const control = Color(0xFFEEEFF0);
  static const ink = Color(0xFF1C1C1E);
  static const muted = Color(0xFF636B74);
  static const inactive = Color(0xFF8E8E93);
  static const inactiveLight = Color(0xFFBEC7D0);

  /// Calm interactive blue. Keep it rare; glass itself stays neutral.
  static const accent = Color(0xFF3877A7);
  static const accentStrong = accent;
  static const danger = Color(0xFFB54747);
  static const line = Color(0xFFDDE4EA);
  static const lineStrong = inactiveLight;

  /// "Degraded but alive" states: waiting on the host, reconnecting, unconfirmed stop.
  /// Amber must never mark a completed failure; that is danger's job.
  static const warning = Color(0xFF8A5A20);
  static const warningSoft = Color(0xFFF4E9DA);

  /// Quiet role separation without turning every message into an accent.
  /// A blue-leaning step that reads clearly over paper (the old near-twin
  /// of paper was invisible) while staying calmer than a selected state.
  static const userBubble = Color(0xFFCBD9E3);

  /// Neutral structural edge that keeps light bubbles visible on wallpapers.
  /// The color step above carries the hierarchy; this outline is only the
  /// wallpaper fallback, so it stays as faint as possible.
  static const bubbleOutline = Color(0x0A000000);

  /// Blue remains reserved for selected/search-highlighted states.
  static const composerControlFill = Color(0xFFE6EFF5);
  static const composerControlRest = Color(0x0A1C1C1E);
  static const composerControlPressed = Color(0x141C1C1E);
  static const composerControlInk = ink;
  static const composerDisabledFill = Color(0x00000000);

  /// Apple-like material roles. Only overlays use real backdrop blur.
  static const glass = Color(0xCCF8FBFE);
  static const glassStrong = Color(0xEBF9FBFD);
  static const glassControl = Color(0xBFFFFFFF);
  static const glassHighlight = Color(0xB3FFFFFF);
  static const liquidThinHighlight = Color(0xF0FFFFFF);
  static const liquidThinBody = Color(0xE3F8FAFC);
  static const liquidThinEdge = Color(0xD1E9F0F5);
  static const liquidStrongHighlight = Color(0xFCFFFFFF);
  static const liquidStrongBody = Color(0xF6F9FBFD);
  static const liquidStrongEdge = Color(0xEEF0F4F7);
  static const liquidFocus = Color(0x473877A7);
  static const scrim = Color(0x4A111820);

  static const cta = accentStrong;
  static const onCta = surfaceElevated;
  static const accentSoft = Color(0xFFE4EFF7);
  static const stop = danger;
  static const porcelain = surfaceElevated;
  static const porcelainMuted = control;
  static const code = ink;
  static const codeMuted = inactive;
  static const bgTop = Color(0xFFF8FAFD);
  static const bgMid = paper;
  static const bgBottom = Color(0xFFEAF0F6);
}

class AppTypography {
  /// Null lets Flutter resolve the native UI font for the current platform.
  static const String? fontFamily = null;
  static const List<String>? fontFamilyFallback = null;

  /// Assistant text follows the same platform-native family as the UI.
  static const String? assistantFontFamily = fontFamily;
  static const List<String>? assistantFontFamilyFallback = fontFamilyFallback;
  static const codeFontFamily = 'monospace';
  static const codeFontFamilyFallback = <String>[
    'JetBrains Mono',
    'SFMono-Regular',
    'Consolas',
    'monospace',
  ];

  /// Base assistant body before reading-font scale factor.
  static const assistantBodySize = 15.0;
  static const assistantBodyHeight = 1.6;
  static const userBodySize = 15.0;
  static const userBodyHeight = 1.6;
}

class AppSpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

class AppSizes {
  static const touchTarget = 48.0;
  static const iconControl = 36.0;
  static const sessionHeader = touchTarget;
  static const composer = 110.0;
}

/// Filled 16px identity marks (Linear-style). Color is the identifier;
/// do not sit these in a control well.
abstract final class AppMark {
  static const size = 16.0;

  // Linear-style crisp jewel tones calibrated for both light & dark contrast
  static const azure = Color(0xFF0EA5E9); // Sky / iOS / Primary focus
  static const emerald = Color(0xFF10B981); // Emerald / Mobile / Healthy
  static const moss = emerald;
  static const amber = Color(0xFFF59E0B); // Amber gold / Planning / CLI
  static const coral = Color(0xFFF97316); // Coral orange / Roadmap
  static const clay = coral;
  static const violet = Color(0xFF8B5CF6); // Royal violet / Architecture / Backend
  static const dusk = violet;
  static const teal = Color(0xFF14B8A6); // Teal cyan / Docs / PRD
  static const rose = Color(0xFFF43F5E); // Electric rose / AI / High-impact
  static const slate = Color(0xFF64748B); // Slate gray / General / Offline

  static const palette = [azure, emerald, violet, amber, rose, teal, coral];

  /// Deterministic jewel color with optional index offset to guarantee adjacent items don't clash.
  static Color of(String id, [int? index]) {
    if (index != null) {
      final base = (id.hashCode.abs() + index) % palette.length;
      return palette[base];
    }
    return palette[id.hashCode.abs() % palette.length];
  }
}

class AppRadii {
  static const compact = 8.0;
  static const control = 12.0;
  static const surface = 16.0;
  static const header = 22.0;

  /// Floating composer shell — softer than a docked bar.
  static const composerFloat = 28.0;
  static const pill = 999.0;

  /// Soft chat bubbles (Claude / iMessage-like).
  static const bubbleSoft = 22.0;

  static const panel = surface;
  static const bubble = bubbleSoft;
  static const input = control;

  /// Top corners of a docked modal sheet — one value across the app.
  static const sheetTop = 22.0;
}

/// Shared recipe for option rows inside modal pickers (permission mode,
/// sandbox mode, engine choice). 48pt icon seat, title + description two-level
/// hierarchy, far-end check, one corner value. Rows are what makes pickers
/// read as "designed" versus a settings-list pasted into a sheet.
class AppOptionRow extends StatelessWidget {
  const AppOptionRow({
    super.key,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    this.leading,
    this.enabled = true,
    this.danger = false,
    this.boxedLeading = true,
    this.showDisclosure = true,
  });

  final String title;
  final String description;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? leading;
  final bool enabled;
  final bool danger;
  final bool boxedLeading;
  final bool showDisclosure;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    final accent = danger ? AppColors.danger : AppColors.accentStrong;
    final borderRadius = BorderRadius.circular(AppRadii.control);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        enabled: active,
        button: true,
        child: Material(
          color: selected ? AppColors.composerControlFill : AppColors.surface,
          borderRadius: borderRadius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: active ? onTap : null,
            borderRadius: borderRadius,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  if (boxedLeading)
                    SizedBox.square(
                      dimension: AppSizes.iconControl,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: selected
                              ? AppColors.surfaceElevated
                              : AppColors.control,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: IconTheme(
                            data: IconThemeData(
                              size: 20,
                              color: !enabled
                                  ? AppColors.inactive
                                  : (selected || danger
                                        ? accent
                                        : AppColors.muted),
                            ),
                            child: leading ?? const Icon(LucideIcons.circle),
                          ),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      width: 20,
                      child: Center(
                        child:
                            leading ??
                            Icon(
                              LucideIcons.circle,
                              size: AppMark.size,
                              color: AppColors.muted,
                            ),
                      ),
                    ),
                  SizedBox(width: boxedLeading ? 12 : 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.15,
                            color: enabled ? AppColors.ink : AppColors.inactive,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          description,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(LucideIcons.check, size: 20, color: accent)
                  else if (showDisclosure)
                    const Icon(
                      LucideIcons.chevronRight,
                      size: 18,
                      color: AppColors.inactive,
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

/// Sheet header recipe: title + optional muted lead line, tight spacing,
/// drag handle above. Pickers previously shipped a bare bold text with the
/// sheet's own padding — this gives every sheet the same header rhythm.
class AppOptionSheetHeader extends StatelessWidget {
  const AppOptionSheetHeader({super.key, required this.title, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: AppColors.ink,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 4),
          Text(
            detail!,
            style: const TextStyle(
              fontSize: 12,
              height: 1.4,
              color: AppColors.muted,
            ),
          ),
        ],
      ],
    );
  }
}

/// Neutral material lift: pure black rings adapt to cool glass surfaces.
class AppElevation {
  /// Neutral ring + quiet lift for interactive cards on light surfaces.
  static List<BoxShadow> surfaceCard() => const [
    BoxShadow(color: Color(0x0F000000), spreadRadius: 1),
    BoxShadow(
      color: Color(0x0F000000),
      blurRadius: 2,
      offset: Offset(0, 1),
      spreadRadius: -1,
    ),
    BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 2)),
  ];

  static List<BoxShadow> floatingOverlay() => const [
    BoxShadow(color: Color(0x12000000), spreadRadius: 1),
    BoxShadow(
      color: Color(0x22000000),
      blurRadius: 30,
      offset: Offset(0, 14),
      spreadRadius: -8,
    ),
  ];

  static List<BoxShadow> softCard({double alpha = 0.07}) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: alpha),
      blurRadius: 18,
      offset: const Offset(0, 6),
      spreadRadius: -4,
    ),
  ];

  // No per-bubble shadow: N soft blurs while scrolling is a common FPS killer.
  static List<BoxShadow> softBubble({double alpha = 0.05}) => const [];

  static List<BoxShadow> liquidThin({bool pressed = false}) => pressed
      ? const [
          BoxShadow(color: Color(0x0A000000), spreadRadius: 1),
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 2,
            offset: Offset(0, 1),
            spreadRadius: -1,
          ),
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 7,
            offset: Offset(0, 3),
            spreadRadius: -3,
          ),
        ]
      : const [
          BoxShadow(color: Color(0x0F000000), spreadRadius: 1),
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 3,
            offset: Offset(0, 1),
            spreadRadius: -1,
          ),
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 12,
            offset: Offset(0, 5),
            spreadRadius: -4,
          ),
        ];

  static List<BoxShadow> liquidStrong({bool pressed = false}) => pressed
      ? const [
          BoxShadow(color: Color(0x0D000000), spreadRadius: 1),
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 2,
            offset: Offset(0, 1),
            spreadRadius: -1,
          ),
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 10,
            offset: Offset(0, 4),
            spreadRadius: -4,
          ),
        ]
      : const [
          BoxShadow(color: Color(0x0F000000), spreadRadius: 1),
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 3,
            offset: Offset(0, 1),
            spreadRadius: -1,
          ),
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 20,
            offset: Offset(0, 8),
            spreadRadius: -6,
          ),
        ];
}

class AppLiquidGlass {
  static const thinBackdropGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xA8FFFFFF), Color(0x66F7F8FA), Color(0x42E9ECEF)],
    stops: [0, 0.58, 1],
  );

  static const thinBackdropPressedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x8CFFFFFF), Color(0x5CF7F8FA), Color(0x4AE4E7EA)],
    stops: [0, 0.48, 1],
  );

  static const strongBackdropGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xB8FFFFFF), Color(0x7AF7F8FA), Color(0x55E9ECEF)],
    stops: [0, 0.54, 1],
  );

  static const strongBackdropPressedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xA6FFFFFF), Color(0x70F7F8FA), Color(0x5CE4E7EA)],
    stops: [0, 0.44, 1],
  );

  static const thinGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      AppColors.liquidThinHighlight,
      AppColors.liquidThinBody,
      AppColors.liquidThinEdge,
    ],
    stops: [0, 0.62, 1],
  );

  static const thinPressedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xE2FFFFFF), AppColors.liquidThinBody, Color(0xD8E7EEF4)],
    stops: [0, 0.34, 1],
  );

  static const strongGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      AppColors.liquidStrongHighlight,
      AppColors.liquidStrongBody,
      AppColors.liquidStrongEdge,
    ],
    stops: [0, 0.52, 1],
  );

  static const strongPressedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xF4FFFFFF), AppColors.liquidStrongBody, Color(0xF0EDF2F6)],
    stops: [0, 0.30, 1],
  );

  static BoxDecoration thin({
    BorderRadius? borderRadius,
    BoxShape shape = BoxShape.rectangle,
    bool pressed = false,
    bool elevated = true,
    bool backdrop = false,
  }) {
    return BoxDecoration(
      gradient: backdrop
          ? pressed
                ? thinBackdropPressedGradient
                : thinBackdropGradient
          : pressed
          ? thinPressedGradient
          : thinGradient,
      borderRadius: shape == BoxShape.rectangle ? borderRadius : null,
      shape: shape,
      boxShadow: elevated
          ? AppElevation.liquidThin(pressed: pressed)
          : const [],
    );
  }

  static BoxDecoration strong({
    BorderRadius? borderRadius,
    bool pressed = false,
    bool focused = false,
    bool elevated = true,
    bool backdrop = false,
  }) {
    return BoxDecoration(
      gradient: backdrop
          ? pressed
                ? strongBackdropPressedGradient
                : strongBackdropGradient
          : pressed
          ? strongPressedGradient
          : strongGradient,
      border: focused
          ? Border.all(color: AppColors.liquidFocus, width: 2)
          : null,
      borderRadius: borderRadius,
      boxShadow: elevated
          ? AppElevation.liquidStrong(pressed: pressed)
          : const [],
    );
  }
}

// Glass surfaces rebuild constantly (stream flushes, press animations, panel
// timers). Reusing one immutable filter per sigma keeps the identical-instance
// check in RenderBackdropFilter quiet, so an unchanged surface is not marked
// for paint — and not re-blurred — on unrelated rebuilds.
final Map<double, ui.ImageFilter> _blurFiltersBySigma = {};

ui.ImageFilter _blurFilterFor(double sigma) => _blurFiltersBySigma.putIfAbsent(
  sigma,
  () => ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
);

class SignalLiquidGlass extends StatelessWidget {
  const SignalLiquidGlass({
    super.key,
    required this.decoration,
    required this.child,
    this.blurSigma = 8,
  });

  final BoxDecoration decoration;
  final Widget child;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final material = BackdropFilter.grouped(
      filter: _blurFilterFor(blurSigma),
      child: DecoratedBox(
        decoration: decoration.copyWith(boxShadow: const []),
        child: child,
      ),
    );
    final clipped = decoration.shape == BoxShape.circle
        ? ClipOval(child: material)
        : ClipRRect(
            borderRadius: decoration.borderRadius ?? BorderRadius.zero,
            child: material,
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: decoration.shape,
        borderRadius: decoration.shape == BoxShape.rectangle
            ? decoration.borderRadius
            : null,
        boxShadow: decoration.boxShadow,
      ),
      child: clipped,
    );
  }
}

class SignalAnimatedSurface extends StatelessWidget {
  const SignalAnimatedSurface({
    super.key,
    required this.decoration,
    required this.duration,
    required this.child,
    this.blurSigma,
  });

  final Decoration decoration;
  final Duration duration;
  final Widget child;
  final double? blurSigma;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Decoration?>(
      tween: DecorationTween(begin: decoration, end: decoration),
      duration: duration,
      curve: Curves.easeOut,
      builder: (context, decoration, child) {
        if (blurSigma != null && decoration is BoxDecoration) {
          return SignalLiquidGlass(
            decoration: decoration,
            blurSigma: blurSigma!,
            child: child!,
          );
        }
        return DecoratedBox(decoration: decoration!, child: child);
      },
      child: child,
    );
  }
}

class AppMotion {
  static const press = Duration(milliseconds: 90);
  static const fast = Duration(milliseconds: 160);
  static const standard = Duration(milliseconds: 220);
  static const feedback = Duration(milliseconds: 320);
  static const signal = Duration(milliseconds: 1800);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;
  static const settle = Curves.easeOutBack;
}

AnimationStyle appOverlayAnimationStyle(BuildContext context) {
  return MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: AppMotion.standard,
          reverseDuration: AppMotion.fast,
        );
}

Duration appPressAnimationDuration(BuildContext context, bool pressed) {
  return MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : pressed
      ? AppMotion.press
      : AppMotion.fast;
}

// A modal scrim painted inside the sheet's own subtree. The framework barrier
// fade marks the whole overlay dirty every frame — overlay.dart has no repaint
// boundaries — which re-renders the entire page below, backdrop blurs included.
// This scrim repaints only itself, so opening a sheet costs compositing, not a
// full-screen re-raster.
class SheetScrim extends StatelessWidget {
  const SheetScrim({super.key, this.color = AppColors.scrim});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    final Widget layer;
    if (animation == null || animation.value >= 1) {
      layer = ColoredBox(color: color);
    } else if (animation.value <= 0) {
      layer = const SizedBox.expand();
    } else {
      layer = AnimatedBuilder(
        animation: animation,
        builder: (context, _) => ColoredBox(
          color: color.withValues(alpha: color.a * animation.value),
        ),
      );
    }
    return Positioned.fill(
      child: IgnorePointer(child: RepaintBoundary(child: layer)),
    );
  }
}

/// Wraps a modal sheet's builder result with a self-repainting scrim. Pair
/// with `barrierColor: Colors.transparent` on the route.
Widget appModalSheetScaffold(
  Widget sheet, {
  Color barrierColor = Colors.black54,
}) {
  return Stack(
    children: [
      SheetScrim(color: barrierColor),
      Align(
        alignment: Alignment.bottomCenter,
        // The entrance slide must not re-rasterize the sheet every frame.
        child: SnapshotWhileAnimating(child: sheet),
      ),
    ],
  );
}

class AppMaterialPageRoute<T> extends MaterialPageRoute<T> {
  AppMaterialPageRoute({required super.builder, required this.reduceMotion});

  final bool reduceMotion;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : super.reverseTransitionDuration;
}

// A full-screen surface re-executes its entire GPU draw on every animation
// frame: the raster cache keys on the layer transform, so a sliding or fading
// sheet never hits it and a near-fullscreen panel re-rasterizes at 15-30ms a
// frame (UI thread stays idle). While the owning animation runs, freeze the
// child into a texture (the same trick ZoomPageTransitionsBuilder uses) so
// each frame composites one quad; restore live content after the settle frame.
class SnapshotWhileAnimating extends StatefulWidget {
  const SnapshotWhileAnimating({
    super.key,
    this.animation,
    required this.child,
  });

  final Animation<double>? animation;
  final Widget child;

  @override
  State<SnapshotWhileAnimating> createState() => _SnapshotWhileAnimatingState();
}

class _SnapshotWhileAnimatingState extends State<SnapshotWhileAnimating> {
  final SnapshotController _controller = SnapshotController(
    allowSnapshotting: false,
  );
  Animation<double>? _animation;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    final animation = widget.animation ?? ModalRoute.of(context)?.animation;
    if (!identical(animation, _animation)) {
      _animation?.removeStatusListener(_onStatusChanged);
      _animation = animation;
      animation?.addStatusListener(_onStatusChanged);
    }
    _syncController();
  }

  @override
  void didUpdateWidget(covariant SnapshotWhileAnimating oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.animation, oldWidget.animation)) {
      _animation?.removeStatusListener(_onStatusChanged);
      _animation = widget.animation;
      _animation?.addStatusListener(_onStatusChanged);
      _syncController();
    }
  }

  void _onStatusChanged(AnimationStatus status) => _syncController();

  void _syncController() {
    final status = _animation?.status;
    final animating =
        status == AnimationStatus.forward || status == AnimationStatus.reverse;
    if (!animating) {
      // Drop the snapshot only after the settle frame has painted, so the
      // last animated frame is still the cheap texture and the live-content
      // re-raster lands on a frame where nothing is moving.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.allowSnapshotting = false;
      });
      return;
    }
    _controller.allowSnapshotting = !_reduceMotion;
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_onStatusChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SnapshotWidget(
      controller: _controller,
      mode: SnapshotMode.permissive,
      child: widget.child,
    );
  }
}

class _ReducedMotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const _ReducedMotionPageTransitionsBuilder(this.delegate);

  final PageTransitionsBuilder delegate;

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double>? secondaryAnimation,
    Widget child,
  ) {
    if (route == null || context == null || secondaryAnimation == null) {
      return child;
    }
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return delegate.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

ThemeData buildSignalConsoleTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.cta,
        onPrimary: AppColors.onCta,
        secondary: AppColors.accentStrong,
        onSecondary: AppColors.onCta,
        surface: AppColors.surface,
        onSurface: AppColors.ink,
        error: AppColors.danger,
        outline: AppColors.lineStrong,
        outlineVariant: AppColors.line,
        surfaceContainerHighest: AppColors.control,
      );

  TextStyle signalText(
    TextStyle? base, {
    required double size,
    required FontWeight weight,
    required double height,
    double letterSpacing = 0,
    Color color = AppColors.ink,
  }) {
    return (base ?? const TextStyle()).copyWith(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  final materialText = Typography.material2021(
    platform: defaultTargetPlatform,
    colorScheme: scheme,
  ).black;
  final textTheme = materialText.copyWith(
    displayLarge: signalText(
      materialText.displayLarge,
      size: 32,
      weight: FontWeight.w700,
      height: 1.18,
      letterSpacing: -0.64,
    ),
    displayMedium: signalText(
      materialText.displayMedium,
      size: 28,
      weight: FontWeight.w700,
      height: 1.2,
      letterSpacing: -0.56,
    ),
    displaySmall: signalText(
      materialText.displaySmall,
      size: 24,
      weight: FontWeight.w700,
      height: 1.22,
      letterSpacing: -0.48,
    ),
    headlineLarge: signalText(
      materialText.headlineLarge,
      size: 21,
      weight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.42,
    ),
    headlineMedium: signalText(
      materialText.headlineMedium,
      size: 20,
      weight: FontWeight.w700,
      height: 1.28,
      letterSpacing: -0.36,
    ),
    headlineSmall: signalText(
      materialText.headlineSmall,
      size: 18,
      weight: FontWeight.w700,
      height: 1.3,
      letterSpacing: -0.28,
    ),
    titleLarge: signalText(
      materialText.titleLarge,
      size: 16,
      weight: FontWeight.w700,
      height: 1.35,
      letterSpacing: -0.2,
    ),
    titleMedium: signalText(
      materialText.titleMedium,
      size: 15,
      weight: FontWeight.w700,
      height: 1.35,
      letterSpacing: -0.12,
    ),
    titleSmall: signalText(
      materialText.titleSmall,
      size: 14,
      weight: FontWeight.w600,
      height: 1.4,
      letterSpacing: 0,
    ),
    bodyLarge: signalText(
      materialText.bodyLarge,
      size: 15.5,
      weight: FontWeight.w400,
      height: 1.58,
      letterSpacing: 0.05,
    ),
    bodyMedium: signalText(
      materialText.bodyMedium,
      size: 14,
      weight: FontWeight.w400,
      height: 1.52,
      letterSpacing: 0.02,
    ),
    bodySmall: signalText(
      materialText.bodySmall,
      size: 12,
      weight: FontWeight.w400,
      height: 1.35,
      color: AppColors.muted,
    ),
    labelLarge: signalText(
      materialText.labelLarge,
      size: 14,
      weight: FontWeight.w600,
      height: 1.35,
      letterSpacing: 0,
    ),
    labelMedium: signalText(
      materialText.labelMedium,
      size: 13,
      weight: FontWeight.w600,
      height: 1.35,
      letterSpacing: 0,
    ),
    labelSmall: signalText(
      materialText.labelSmall,
      size: 12,
      weight: FontWeight.w500,
      height: 1.35,
      letterSpacing: 0,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    splashFactory: InkSparkle.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _ReducedMotionPageTransitionsBuilder(
          PredictiveBackPageTransitionsBuilder(),
        ),
        TargetPlatform.iOS: _ReducedMotionPageTransitionsBuilder(
          CupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.macOS: _ReducedMotionPageTransitionsBuilder(
          CupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.windows: _ReducedMotionPageTransitionsBuilder(
          ZoomPageTransitionsBuilder(),
        ),
        TargetPlatform.linux: _ReducedMotionPageTransitionsBuilder(
          ZoomPageTransitionsBuilder(),
        ),
        TargetPlatform.fuchsia: _ReducedMotionPageTransitionsBuilder(
          ZoomPageTransitionsBuilder(),
        ),
      },
    ),
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.paper,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: textTheme.titleLarge,
    ),
    iconTheme: const IconThemeData(color: AppColors.ink, size: 21),
    dividerTheme: const DividerThemeData(
      color: AppColors.line,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.control,
      hintStyle: textTheme.bodyMedium?.copyWith(color: AppColors.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: const BorderSide(color: AppColors.accentStrong, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        animationDuration: AppMotion.fast,
        minimumSize: const WidgetStatePropertyAll(
          Size(AppSizes.touchTarget, AppSizes.touchTarget),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontFamilyFallback: AppTypography.fontFamilyFallback,
            fontWeight: FontWeight.w600,
          ),
        ),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return Colors.white.withValues(alpha: 0.13);
          }
          return null;
        }),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        animationDuration: AppMotion.fast,
        minimumSize: const WidgetStatePropertyAll(
          Size(AppSizes.touchTarget, AppSizes.touchTarget),
        ),
        side: const WidgetStatePropertyAll(
          BorderSide(color: AppColors.lineStrong),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontFamilyFallback: AppTypography.fontFamilyFallback,
            fontWeight: FontWeight.w600,
          ),
        ),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return AppColors.accent.withValues(alpha: 0.08);
          }
          return null;
        }),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        animationDuration: AppMotion.fast,
        minimumSize: const WidgetStatePropertyAll(
          Size.square(AppSizes.touchTarget),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return AppColors.muted.withValues(alpha: 0.42);
          }
          return AppColors.ink;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return AppColors.accent.withValues(alpha: 0.10);
          }
          return null;
        }),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.glassStrong,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: AppColors.glassStrong,
      modalBarrierColor: AppColors.scrim,
      showDragHandle: true,
      dragHandleColor: AppColors.lineStrong,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.header),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.glassStrong,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: const Color(0x24000000),
      textStyle: textTheme.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.glassStrong,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadii.surface)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.ink,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
    ),
  );
}

class SignalPressEffect extends StatefulWidget {
  const SignalPressEffect({
    super.key,
    required this.child,
    this.enabled = true,
    this.scaleOnPress = true,
    this.builder,
  });

  final Widget child;
  final bool enabled;
  final bool scaleOnPress;
  final Widget Function(BuildContext context, bool pressed, Widget child)?
  builder;

  @override
  State<SignalPressEffect> createState() => _SignalPressEffectState();
}

class _SignalPressEffectState extends State<SignalPressEffect> {
  bool pressed = false;

  void setPressed(bool value) {
    if (!widget.enabled || !widget.scaleOnPress || pressed == value) return;
    setState(() => pressed = value);
  }

  @override
  void didUpdateWidget(covariant SignalPressEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!widget.enabled || !widget.scaleOnPress) && pressed) pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final child =
        widget.builder?.call(context, pressed, widget.child) ?? widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: widget.enabled && widget.scaleOnPress
          ? (_) => setPressed(true)
          : null,
      onPointerUp: widget.enabled && widget.scaleOnPress
          ? (_) => setPressed(false)
          : null,
      onPointerCancel: widget.enabled && widget.scaleOnPress
          ? (_) => setPressed(false)
          : null,
      child: AnimatedScale(
        scale: pressed && !reduceMotion ? 0.96 : 1,
        duration: reduceMotion
            ? Duration.zero
            : pressed
            ? AppMotion.press
            : AppMotion.fast,
        curve: Curves.easeOut,
        child: child,
      ),
    );
  }
}

class TaskRailFrame extends StatelessWidget {
  const TaskRailFrame({
    super.key,
    required this.color,
    required this.child,
    this.active = false,
    this.compact = false,
  });

  final Color color;
  final Widget child;
  final bool active;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // Top-aligned rail — avoid IntrinsicHeight (forces child double layout).
    final dot = active ? 10.0 : 8.0;
    final top = compact ? 10.0 : 14.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Padding(
            padding: EdgeInsets.only(top: top),
            child: Center(
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.porcelain, width: 2),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(child: child),
      ],
    );
  }
}
