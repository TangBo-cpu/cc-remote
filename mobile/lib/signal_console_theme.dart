import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppColors {
  static const paper = Color(0xFFF5F4EE);
  static const surface = Color(0xFFF8F7F2);
  static const surfaceElevated = Color(0xFFFBFAF7);
  static const control = Color(0xFFECEBE5);
  static const ink = Color(0xFF2B2A27);
  static const muted = Color(0xFF65625C);
  static const inactive = Color(0xFF8B877F);
  static const inactiveLight = Color(0xFFB8B4AB);

  /// Brand mark / large fills only — not body text or small labels.
  static const terracotta = Color(0xFFDA7756);

  /// CTA fills and terracotta-on-paper text that must meet ~4.5:1.
  static const terracottaDeep = Color(0xFFA65338);
  static const danger = Color(0xFF9E4D35);
  static const line = Color(0xFFD8D5CD);
  static const lineStrong = inactiveLight;

  /// Quiet warm-clay wash for the user's compact message bubble.
  static const userBubble = Color(0xFFE9E1D8);

  /// Soft wash behind composer + / model controls.
  static const composerControlFill = Color(0xFFF0E4DB);
  static const composerControlInk = Color(0xFF8A5340);

  static const accent = terracotta;
  static const cta = terracottaDeep;
  static const onCta = surfaceElevated;
  static const accentSoft = control;
  static const warning = terracottaDeep;
  static const stop = danger;
  static const porcelain = surfaceElevated;
  static const porcelainMuted = control;
  static const code = ink;
  static const codeMuted = inactive;
  static const bgTop = surfaceElevated;
  static const bgMid = paper;
  static const bgBottom = surface;
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
  static const touchTarget = 44.0;
  static const iconControl = 36.0;
  static const sessionHeader = 44.0;
  static const composer = 110.0;
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
}

/// Quiet paper lift — not glass, not heavy drop shadow.
class AppElevation {
  static List<BoxShadow> softCard({double alpha = 0.07}) => [
    BoxShadow(
      color: const Color(0xFF2B2A27).withValues(alpha: alpha),
      blurRadius: 18,
      offset: const Offset(0, 6),
      spreadRadius: -4,
    ),
  ];

  // No per-bubble shadow: N soft blurs while scrolling is a common FPS killer.
  static List<BoxShadow> softBubble({double alpha = 0.05}) => const [];

  /// Single light dock shadow (one layer only).
  static List<BoxShadow> floatingComposer() => const [
    BoxShadow(
      color: Color(0x1A2B2A27),
      blurRadius: 12,
      offset: Offset(0, 6),
      spreadRadius: -4,
    ),
  ];
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
        primary: AppColors.cta,
        onPrimary: AppColors.onCta,
        secondary: AppColors.terracottaDeep,
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
        borderSide: const BorderSide(
          color: AppColors.terracottaDeep,
          width: 1.4,
        ),
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
      backgroundColor: AppColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: AppColors.surfaceElevated,
      modalBarrierColor: Color(0x660D1D22),
      showDragHandle: true,
      dragHandleColor: AppColors.lineStrong,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.header),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      textStyle: textTheme.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.surface),
        side: const BorderSide(color: AppColors.line),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surfaceElevated,
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
