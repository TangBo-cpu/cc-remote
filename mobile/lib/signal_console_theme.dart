import 'dart:math' as math;

import 'package:flutter/material.dart';

class AppColors {
  static const ink = Color(0xFF14130F);
  static const muted = Color(0xFF6A675F);
  static const mint = Color(0xFF54E6B1);
  static const mintSoft = Color(0xFFD9F7E9);
  static const yellow = Color(0xFFFFD84A);
  static const yellowSoft = Color(0xFFFFF1B0);
  static const coral = Color(0xFFFF786B);
  static const coralSoft = Color(0xFFFFDCD7);
  static const accent = mint;
  static const accentSoft = mintSoft;
  static const success = Color(0xFF28B985);
  static const warning = Color(0xFFE0A91D);
  static const stop = coral;
  static const shadow = ink;
  static const line = Color(0xFFDED8CA);
  static const lineStrong = Color(0xFFB8B1A4);
  static const porcelain = Color(0xFFFFFDF5);
  static const porcelainMuted = Color(0xFFF1EDE1);
  static const code = ink;
  static const codeMuted = Color(0xFFB8BBB3);
  static const bgTop = Color(0xFFFBF8EF);
  static const bgMid = Color(0xFFF8F4E8);
  static const bgBottom = Color(0xFFF3EDDE);
}

class AppTypography {
  static const fontFamily = 'sans-serif-rounded';
  static const fontFamilyFallback = <String>[
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'PingFang SC',
    'Microsoft YaHei',
    'sans-serif',
  ];
}

class AppRadii {
  static const panel = 26.0;
  static const bubble = 18.0;
  static const input = 28.0;
  static const control = 15.0;
  static const compact = 10.0;
  static const pill = 999.0;
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

ThemeData buildSignalConsoleTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.accent,
        onPrimary: AppColors.ink,
        secondary: AppColors.success,
        surface: AppColors.porcelain,
        onSurface: AppColors.ink,
        error: AppColors.stop,
        outline: AppColors.lineStrong,
        outlineVariant: AppColors.line,
        surfaceContainerHighest: AppColors.porcelainMuted,
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
      fontFamily: AppTypography.fontFamily,
      fontFamilyFallback: AppTypography.fontFamilyFallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  final materialText = Typography.blackMountainView.apply(
    bodyColor: AppColors.ink,
    displayColor: AppColors.ink,
    fontFamily: AppTypography.fontFamily,
  );
  final textTheme = materialText.copyWith(
    displayLarge: signalText(
      materialText.displayLarge,
      size: 52,
      weight: FontWeight.w900,
      height: 0.98,
      letterSpacing: -2.2,
    ),
    displayMedium: signalText(
      materialText.displayMedium,
      size: 43,
      weight: FontWeight.w900,
      height: 1.02,
      letterSpacing: -1.7,
    ),
    displaySmall: signalText(
      materialText.displaySmall,
      size: 36,
      weight: FontWeight.w900,
      height: 1.06,
      letterSpacing: -1.3,
    ),
    headlineLarge: signalText(
      materialText.headlineLarge,
      size: 32,
      weight: FontWeight.w900,
      height: 1.08,
      letterSpacing: -1.05,
    ),
    headlineMedium: signalText(
      materialText.headlineMedium,
      size: 28,
      weight: FontWeight.w900,
      height: 1.1,
      letterSpacing: -0.9,
    ),
    headlineSmall: signalText(
      materialText.headlineSmall,
      size: 24,
      weight: FontWeight.w800,
      height: 1.14,
      letterSpacing: -0.65,
    ),
    titleLarge: signalText(
      materialText.titleLarge,
      size: 21,
      weight: FontWeight.w800,
      height: 1.18,
      letterSpacing: -0.5,
    ),
    titleMedium: signalText(
      materialText.titleMedium,
      size: 17,
      weight: FontWeight.w800,
      height: 1.22,
      letterSpacing: -0.28,
    ),
    titleSmall: signalText(
      materialText.titleSmall,
      size: 15,
      weight: FontWeight.w700,
      height: 1.28,
      letterSpacing: -0.12,
    ),
    bodyLarge: signalText(
      materialText.bodyLarge,
      size: 17,
      weight: FontWeight.w500,
      height: 1.46,
      letterSpacing: -0.08,
    ),
    bodyMedium: signalText(
      materialText.bodyMedium,
      size: 15,
      weight: FontWeight.w500,
      height: 1.46,
      letterSpacing: -0.04,
    ),
    bodySmall: signalText(
      materialText.bodySmall,
      size: 13,
      weight: FontWeight.w500,
      height: 1.42,
      color: AppColors.muted,
    ),
    labelLarge: signalText(
      materialText.labelLarge,
      size: 15,
      weight: FontWeight.w800,
      height: 1.2,
      letterSpacing: 0.02,
    ),
    labelMedium: signalText(
      materialText.labelMedium,
      size: 13,
      weight: FontWeight.w700,
      height: 1.2,
      letterSpacing: 0.08,
    ),
    labelSmall: signalText(
      materialText.labelSmall,
      size: 11.5,
      weight: FontWeight.w700,
      height: 1.2,
      letterSpacing: 0.18,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    splashFactory: InkSparkle.splashFactory,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bgMid,
    fontFamily: AppTypography.fontFamily,
    fontFamilyFallback: AppTypography.fontFamilyFallback,
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
      fillColor: AppColors.porcelainMuted,
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
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        animationDuration: AppMotion.fast,
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontFamilyFallback: AppTypography.fontFamilyFallback,
            fontWeight: FontWeight.w800,
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
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
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
            fontWeight: FontWeight.w800,
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
        minimumSize: const WidgetStatePropertyAll(Size.square(48)),
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
      backgroundColor: AppColors.porcelain,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: AppColors.porcelain,
      modalBarrierColor: Color(0x660D1D22),
      showDragHandle: true,
      dragHandleColor: AppColors.lineStrong,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.porcelain,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
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

class LivelyTerminalPal extends StatelessWidget {
  const LivelyTerminalPal({
    super.key,
    this.mood = TerminalPalMood.ready,
    this.showBadge = false,
  });

  final TerminalPalMood mood;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: switch (mood) {
        TerminalPalMood.ready => '终端伙伴已准备好',
        TerminalPalMood.working => '终端伙伴正在工作',
        TerminalPalMood.offline => '终端伙伴正在等待连接',
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            left: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: mood == TerminalPalMood.offline
                    ? AppColors.lineStrong
                    : AppColors.coral,
                borderRadius: BorderRadius.circular(34),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(painter: _TerminalPalPainter(mood)),
          ),
          if (showBadge)
            const Positioned(
              right: -4,
              bottom: -4,
              child: LivelySparkBadge(size: 38),
            ),
        ],
      ),
    );
  }
}

enum TerminalPalMood { ready, working, offline }

class LivelySparkBadge extends StatelessWidget {
  const LivelySparkBadge({super.key, this.size = 42});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.yellow,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.ink, width: 2.2),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.auto_awesome_rounded, size: size * 0.46),
    );
  }
}

class _TerminalPalPainter extends CustomPainter {
  const _TerminalPalPainter(this.mood);

  final TerminalPalMood mood;

  @override
  void paint(Canvas canvas, Size size) {
    final body = Paint()..color = AppColors.ink;
    final shell = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, size.width - 8, size.height - 8),
      topLeft: Radius.circular(size.width * 0.48),
      topRight: Radius.circular(size.width * 0.48),
      bottomLeft: const Radius.circular(30),
      bottomRight: const Radius.circular(30),
    );
    canvas.drawRRect(shell, body);

    final eyeY = size.height * 0.38;
    final eyeW = size.width * 0.17;
    final eyeH = size.height * 0.12;
    final eyePaint = Paint()..color = AppColors.porcelain;
    for (final centerX in [size.width * 0.34, size.width * 0.66]) {
      final eye = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(centerX, eyeY),
          width: eyeW,
          height: eyeH,
        ),
        Radius.circular(eyeH),
      );
      canvas.drawRRect(eye, eyePaint);
      canvas.drawCircle(
        Offset(
          centerX + (mood == TerminalPalMood.working ? eyeW * 0.12 : 0),
          eyeY,
        ),
        eyeH * 0.24,
        body,
      );
    }

    final mouthPaint = Paint()
      ..color = mood == TerminalPalMood.offline
          ? AppColors.lineStrong
          : AppColors.coral
      ..strokeWidth = math.max(5, size.width * 0.026)
      ..strokeCap = StrokeCap.round;
    final mouthY = size.height * 0.58;
    if (mood == TerminalPalMood.working) {
      canvas.drawArc(
        Rect.fromCenter(
          center: Offset(size.width * 0.5, mouthY),
          width: size.width * 0.19,
          height: size.height * 0.09,
        ),
        0,
        math.pi,
        false,
        mouthPaint..style = PaintingStyle.stroke,
      );
    } else {
      canvas.drawLine(
        Offset(size.width * 0.43, mouthY),
        Offset(size.width * 0.57, mouthY - 1),
        mouthPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TerminalPalPainter oldDelegate) {
    return mood != oldDelegate.mood;
  }
}

class SignalPressEffect extends StatefulWidget {
  const SignalPressEffect({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  State<SignalPressEffect> createState() => _SignalPressEffectState();
}

class _SignalPressEffectState extends State<SignalPressEffect> {
  bool pressed = false;

  void setPressed(bool value) {
    if (!widget.enabled || pressed == value) return;
    setState(() => pressed = value);
  }

  @override
  void didUpdateWidget(covariant SignalPressEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && pressed) pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: widget.enabled ? (_) => setPressed(true) : null,
      onPointerUp: widget.enabled ? (_) => setPressed(false) : null,
      onPointerCancel: widget.enabled ? (_) => setPressed(false) : null,
      child: AnimatedScale(
        scale: pressed && !reduceMotion ? 0.985 : 1,
        duration: reduceMotion
            ? Duration.zero
            : pressed
            ? AppMotion.press
            : AppMotion.fast,
        curve: pressed ? AppMotion.exit : AppMotion.settle,
        child: widget.child,
      ),
    );
  }
}

class SignalCutCornerBorder extends ShapeBorder {
  const SignalCutCornerBorder({
    this.side = const BorderSide(color: AppColors.line),
    this.radius = AppRadii.control,
    this.cut = 13,
  });

  final BorderSide side;
  final double radius;
  final double cut;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  ShapeBorder scale(double t) => SignalCutCornerBorder(
    side: side.scale(t),
    radius: radius * t,
    cut: cut * t,
  );

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return getOuterPath(rect.deflate(side.width), textDirection: textDirection);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final r = math.min(radius, math.min(rect.width, rect.height) / 2);
    return Path()
      ..moveTo(rect.left + r, rect.top)
      ..lineTo(rect.right - cut, rect.top)
      ..lineTo(rect.right, rect.top + cut)
      ..lineTo(rect.right, rect.bottom - r)
      ..quadraticBezierTo(rect.right, rect.bottom, rect.right - r, rect.bottom)
      ..lineTo(rect.left + r, rect.bottom)
      ..quadraticBezierTo(rect.left, rect.bottom, rect.left, rect.bottom - r)
      ..lineTo(rect.left, rect.top + r)
      ..quadraticBezierTo(rect.left, rect.top, rect.left + r, rect.top)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawPath(
      getOuterPath(rect.deflate(side.width / 2), textDirection: textDirection),
      side.toPaint()..style = PaintingStyle.stroke,
    );
  }
}

class SignalTrack extends StatefulWidget {
  const SignalTrack({
    super.key,
    required this.color,
    required this.active,
    this.broken = false,
  });

  final Color color;
  final bool active;
  final bool broken;

  @override
  State<SignalTrack> createState() => _SignalTrackState();
}

class _SignalTrackState extends State<SignalTrack>
    with SingleTickerProviderStateMixin {
  bool reduceMotion = false;
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: AppMotion.signal,
  );

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduceMotion = MediaQuery.disableAnimationsOf(context);
    syncAnimation();
  }

  @override
  void didUpdateWidget(covariant SignalTrack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) syncAnimation();
  }

  void syncAnimation() {
    if (widget.active && !reduceMotion) {
      if (!controller.isAnimating) controller.repeat();
      return;
    }
    controller
      ..stop()
      ..value = 0.5;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 8,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final progress = reduceMotion || !widget.active
                  ? 0.5
                  : controller.value;
              final dotLeft = math.max(
                0.0,
                (constraints.maxWidth - 7) * progress,
              );
              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Positioned.fill(
                    top: 3.5,
                    bottom: 3.5,
                    child: CustomPaint(
                      painter: _SignalLinePainter(
                        color: widget.color,
                        broken: widget.broken,
                      ),
                    ),
                  ),
                  if (widget.active)
                    Positioned(
                      left: dotLeft,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.color,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: widget.color.withValues(alpha: 0.28),
                              blurRadius: 7,
                            ),
                          ],
                        ),
                        child: const SizedBox.square(dimension: 7),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _SignalLinePainter extends CustomPainter {
  const _SignalLinePainter({required this.color, required this.broken});

  final Color color;
  final bool broken;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: broken ? 0.36 : 0.58)
      ..strokeWidth = 1;
    if (!broken) {
      canvas.drawLine(Offset.zero, Offset(size.width, 0), paint);
      return;
    }
    const dash = 8.0;
    const gap = 7.0;
    for (double x = 0; x < size.width; x += dash + gap) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(math.min(x + dash, size.width), 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SignalLinePainter oldDelegate) {
    return color != oldDelegate.color || broken != oldDelegate.broken;
  }
}

class ContextDial extends StatelessWidget {
  const ContextDial({
    super.key,
    required this.remaining,
    this.total,
    this.size = 38,
  });

  final int remaining;
  final int? total;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fraction = total == null || total! <= 0
        ? 1.0
        : (remaining / total!).clamp(0.0, 1.0);
    return Semantics(
      label: total == null
          ? '剩余上下文 $remaining'
          : '剩余上下文 ${(fraction * 100).round()}%',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _ContextDialPainter(fraction: fraction),
          child: Center(
            child: Text(
              '${(fraction * 100).round()}',
              style: TextStyle(
                color: AppColors.ink,
                fontSize: size * 0.25,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
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
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 22,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                Positioned(
                  top: 0,
                  bottom: 0,
                  width: 1,
                  child: ColoredBox(color: color.withValues(alpha: 0.24)),
                ),
                Positioned(
                  top: compact ? 10 : 14,
                  child: Container(
                    width: active ? 10 : 8,
                    height: active ? 10 : 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.porcelain, width: 2),
                      boxShadow: active
                          ? [
                              BoxShadow(
                                color: color.withValues(alpha: 0.28),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ContextDialPainter extends CustomPainter {
  const _ContextDialPainter({required this.fraction});

  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = math.max(2.2, size.width * 0.075);
    final inset = stroke / 2;
    final arcRect = rect.deflate(inset);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = AppColors.line;
    final active = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = AppColors.accent;
    const start = -math.pi / 2 + 0.28;
    const sweep = math.pi * 2 - 0.56;
    canvas.drawArc(arcRect, start, sweep, false, base);
    canvas.drawArc(arcRect, start, sweep * fraction, false, active);
  }

  @override
  bool shouldRepaint(covariant _ContextDialPainter oldDelegate) {
    return fraction != oldDelegate.fraction;
  }
}
