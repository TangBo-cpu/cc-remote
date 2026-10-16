import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class AppPalette {
  const AppPalette._(this.brightness);

  static const light = AppPalette._(Brightness.light);
  static const dark = AppPalette._(Brightness.dark);

  final Brightness brightness;

  static AppPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  bool get _isLight => brightness == Brightness.light;

  Color get paper =>
      _isLight ? const Color(0xFFF9F9F9) : const Color(0xFF111111);
  Color get surface =>
      _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1B1B1B);
  Color get surfaceElevated => surface;
  Color get control =>
      _isLight ? const Color(0xFFF0F0F0) : const Color(0xFF292929);
  Color get ink => _isLight ? const Color(0xFF202020) : const Color(0xFFEEEEEE);
  Color get muted =>
      _isLight ? const Color(0xFF626262) : const Color(0xFFB0B0B0);
  Color get inactive =>
      _isLight ? const Color(0xFF858585) : const Color(0xFF858585);
  Color get inactiveLight =>
      _isLight ? const Color(0xFFD0D0D0) : const Color(0xFF464646);
  Color get accent =>
      _isLight ? const Color(0xFF303030) : const Color(0xFFE7E7E7);
  Color get accentStrong => accent;
  Color get navigatorAccent =>
      _isLight ? const Color(0xFF3877A7) : const Color(0xFF87B7DB);
  Color get link =>
      _isLight ? const Color(0xFF2E6A9B) : const Color(0xFF87B7DB);
  Color get success =>
      _isLight ? const Color(0xFF4C7D63) : const Color(0xFF91B19E);
  Color get danger =>
      _isLight ? const Color(0xFFB42318) : const Color(0xFFFF8A80);
  Color get line =>
      _isLight ? const Color(0xFFE5E5E5) : const Color(0xFF363636);
  Color get lineStrong =>
      _isLight ? const Color(0xFFD2D2D2) : const Color(0xFF4A4A4A);
  Color get warning =>
      _isLight ? const Color(0xFF8A5A20) : const Color(0xFFEAB86A);
  Color get warningSoft =>
      _isLight ? const Color(0xFFFFF2D8) : const Color(0xFF4A3820);
  Color get assistantBubble => surface;
  Color get userBubble =>
      _isLight ? const Color(0xFFEDEDED) : const Color(0xFF2A2A2A);
  Color get messageInk =>
      _isLight ? const Color(0xFF171717) : const Color(0xFFEDEDED);
  Color get messageMuted =>
      _isLight ? const Color(0xFF4D4D4D) : const Color(0xFFA0A0A0);
  Color get messageLink =>
      _isLight ? const Color(0xFF005FF2) : const Color(0xFF47A8FF);
  Color get messageBorder =>
      _isLight ? const Color(0x15000000) : const Color(0x17FFFFFF);
  Color get messageSecondary =>
      _isLight ? const Color(0x0D000000) : const Color(0x12FFFFFF);
  Color get inlineCodeBackground => messageSecondary;
  Color get inlineCodeForeground =>
      _isLight ? const Color(0xFF107D32) : const Color(0xFF00CA50);
  Color get bubbleOutline =>
      _isLight ? const Color(0x14000000) : const Color(0x14FFFFFF);
  Color get composerControlFill => control;
  Color get composerControlRest =>
      _isLight ? const Color(0x0A000000) : const Color(0x0AFFFFFF);
  Color get composerControlPressed =>
      _isLight ? const Color(0x14000000) : const Color(0x14FFFFFF);
  Color get composerControlInk => ink;
  Color get composerDisabledFill => const Color(0x00000000);
  Color get glass =>
      _isLight ? const Color(0xE8FFFFFF) : const Color(0xE82A2A2A);
  Color get glassStrong =>
      _isLight ? const Color(0xF2FFFFFF) : const Color(0xF22A2A2A);
  Color get glassControl =>
      _isLight ? const Color(0xFFF2F2F2) : const Color(0xFF343434);
  Color get glassHighlight =>
      _isLight ? const Color(0xB3FFFFFF) : const Color(0x18FFFFFF);
  Color get liquidThinHighlight =>
      _isLight ? const Color(0xF8FFFFFF) : const Color(0xF8323232);
  Color get liquidThinBody =>
      _isLight ? const Color(0xF5FAFAFA) : const Color(0xF52C2C2C);
  Color get liquidThinEdge =>
      _isLight ? const Color(0xEFF5F5F5) : const Color(0xEF282828);
  Color get liquidStrongHighlight =>
      _isLight ? const Color(0xFCFFFFFF) : const Color(0xFC323232);
  Color get liquidStrongBody =>
      _isLight ? const Color(0xF9FDFDFD) : const Color(0xF92C2C2C);
  Color get liquidStrongEdge =>
      _isLight ? const Color(0xF5FAFAFA) : const Color(0xF5282828);
  Color get liquidFocus => accent.withValues(alpha: 0.28);
  Color get scrim =>
      _isLight ? const Color(0x52000000) : const Color(0x80000000);
  Color get cta => accent;
  Color get onCta =>
      _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF111111);
  Color get accentSoft =>
      _isLight ? const Color(0xFFEAEAEA) : const Color(0xFF343434);
  Color get stop => danger;
  Color get stopGlass => stop.withValues(alpha: 0.85);
  Color get stopGlow => stop.withValues(alpha: 0.12);
  Color get onStop =>
      _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF111111);
  Color get porcelain => surface;
  Color get porcelainMuted => control;
  Color get code => ink;
  Color get codeMuted => inactive;
  Color get codeBlockBackground =>
      _isLight ? const Color(0xFFF2F2F2) : const Color(0xFF1A1A1A);
  Color get codeKeyword =>
      _isLight ? const Color(0xFFA626A4) : const Color(0xFFC792EA);
  Color get codeString =>
      _isLight ? const Color(0xFF337533) : const Color(0xFFC3E88D);
  Color get codeNumber =>
      _isLight ? const Color(0xFF8D5E00) : const Color(0xFFF78C6C);
  Color get codeFunction =>
      _isLight ? const Color(0xFF2A5FD7) : const Color(0xFF82AAFF);
  Color get codeType =>
      _isLight ? const Color(0xFF915C00) : const Color(0xFFFFCB6B);
  Color get codeProperty =>
      _isLight ? const Color(0xFFC0332B) : const Color(0xFFF07178);
  Color get codeConstant =>
      _isLight ? codeNumber : const Color(0xFFFF9CAC);
  Color get codeAttribute => _isLight ? codeNumber : codeKeyword;
  Color? get codeVariable => _isLight ? codeProperty : null;
  Color get codeEmbedded =>
      _isLight ? const Color(0xFFCA1243) : const Color(0xFF89DDFF);
  Color? get codeOperator =>
      _isLight ? null : const Color(0xFF89DDFF);
  Color get codeComment => messageMuted;
  Color get bgTop => paper;
  Color get bgMid => paper;
  Color get bgBottom => paper;
}

/// Light static compatibility colors for callers that have not adopted AppPalette yet.
class AppColors {
  static const paper = Color(0xFFF9F9F9);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceElevated = Color(0xFFFFFFFF);
  static const control = Color(0xFFF0F0F0);
  static const ink = Color(0xFF202020);
  static const muted = Color(0xFF626262);
  static const inactive = Color(0xFF858585);
  static const inactiveLight = Color(0xFFD0D0D0);
  static const accent = Color(0xFF303030);
  static const accentStrong = accent;
  static const link = Color(0xFF2E6A9B);
  static const success = Color(0xFF4C7D63);
  static const danger = Color(0xFFB42318);
  static const line = Color(0xFFE5E5E5);
  static const lineStrong = Color(0xFFD2D2D2);
  static const warning = Color(0xFF8A5A20);
  static const warningSoft = Color(0xFFFFF2D8);
  static const assistantBubble = surface;
  static const userBubble = Color(0xFFEDEDED);
  static const bubbleOutline = Color(0x14000000);
  static const composerControlFill = control;
  static const composerControlRest = Color(0x0A000000);
  static const composerControlPressed = Color(0x14000000);
  static const composerControlInk = ink;
  static const composerDisabledFill = Color(0x00000000);
  static const glass = Color(0xE8FFFFFF);
  static const glassStrong = Color(0xF2FFFFFF);
  static const glassControl = Color(0xFFF2F2F2);
  static const glassHighlight = Color(0xB3FFFFFF);
  static const liquidThinHighlight = Color(0xF8FFFFFF);
  static const liquidThinBody = Color(0xF5FAFAFA);
  static const liquidThinEdge = Color(0xEFF5F5F5);
  static const liquidStrongHighlight = Color(0xFCFFFFFF);
  static const liquidStrongBody = Color(0xF9FDFDFD);
  static const liquidStrongEdge = Color(0xF5FAFAFA);
  static const liquidFocus = Color(0x47303030);
  static const scrim = Color(0x52000000);
  static const cta = accentStrong;
  static const onCta = Color(0xFFFFFFFF);
  static const accentSoft = Color(0xFFEAEAEA);
  static const stop = danger;
  static const stopGlass = Color(0xD9B42318);
  static const stopGlow = Color(0x1FB42318);
  static const onStop = Color(0xFFFFFFFF);
  static const porcelain = surfaceElevated;
  static const porcelainMuted = control;
  static const code = ink;
  static const codeMuted = inactive;
  static const bgTop = paper;
  static const bgMid = paper;
  static const bgBottom = paper;
}

class AppTypography {
  /// Null lets Flutter resolve the native UI font for the current platform.
  static const String? fontFamily = null;
  static const List<String>? fontFamilyFallback = null;

  /// Assistant text follows the same platform-native family as the UI.
  static const String? assistantFontFamily = fontFamily;
  static const List<String>? assistantFontFamilyFallback = fontFamilyFallback;
  static const assistantCodeFontFamily = 'GeistMono';
  static const codeFontFamily = 'monospace';
  static const codeFontFamilyFallback = <String>[
    'JetBrains Mono',
    'SFMono-Regular',
    'Consolas',
    'monospace',
  ];

  /// Base assistant body before reading-font scale factor.
  static const assistantBodySize = 16.0;
  static const assistantBodyHeight = 26 / assistantBodySize;
  static const userBodySize = 15.0;
  static const userBodyHeight = 1.6;
  static const activityBodySize = 13.0;
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

/// Icon size ladder — five steps. Pick the step that matches the icon's role
/// and never pass a raw number. A 2026-10 audit found 19 ad-hoc values in this
/// app (9, 10, 11 … 26, 28, 34, 40), which is what made the icon layer read as
/// inconsistent.
abstract final class AppIconSizes {
  /// Inside a badge, pill, or status dot.
  static const badge = 12.0;

  /// Inline with text — row chevrons and small leading glyphs.
  static const inline = 16.0;

  /// Standard control: buttons, list leading, 36pt seats.
  static const control = 20.0;

  /// App bar actions and prominent tiles.
  static const primary = 24.0;

  /// Empty-state and hero marks.
  static const hero = 32.0;
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
  static const violet = Color(
    0xFF8B5CF6,
  ); // Royal violet / Architecture / Backend
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
  static const composerFloat = 32.0;
  static const pill = 999.0;

  /// Soft chat bubbles (Claude / iMessage-like).
  static const bubbleSoft = 22.0;

  static const panel = surface;
  static const bubble = bubbleSoft;
  static const input = control;

  /// Top corners of a docked modal sheet — one value across the app.
  static const sheetTop = 22.0;
}

/// Shared recipe for one-shot option rows (session engine choice, settings):
/// 36pt icon seat, title + description two-level hierarchy, far-end check, one
/// corner value. Rows are what makes pickers read as "designed" versus a
/// settings-list pasted into a sheet.
///
/// [ConversationOptionSheet] keeps its own row instead: those options carry
/// longer descriptions and a live catalogue, so it uses a radio indicator and a
/// taller seat.
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
    final palette = AppPalette.of(context);
    final active = enabled && onTap != null;
    final accent = danger ? palette.danger : palette.accentStrong;
    final borderRadius = BorderRadius.circular(AppRadii.control);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Semantics(
        selected: selected,
        enabled: active,
        button: true,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? palette.composerControlFill : Colors.transparent,
            borderRadius: borderRadius,
            border: Border.all(
              color: selected
                  ? palette.accent.withValues(alpha: 0.22)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: borderRadius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: active ? onTap : null,
              borderRadius: borderRadius,
              splashColor: palette.accent.withValues(alpha: 0.08),
              highlightColor: palette.accent.withValues(alpha: 0.04),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    if (boxedLeading)
                      SizedBox.square(
                        dimension: AppSizes.iconControl,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: selected
                                ? palette.surfaceElevated
                                : palette.control.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(10),
                            border: selected
                                ? Border.all(
                                    color: palette.accent.withValues(
                                      alpha: 0.15,
                                    ),
                                    width: 1,
                                  )
                                : null,
                          ),
                          child: Center(
                            child: IconTheme(
                              data: IconThemeData(
                                size: AppIconSizes.control,
                                color: !enabled
                                    ? palette.inactive
                                    : (selected || danger
                                          ? accent
                                          : palette.muted),
                              ),
                              child: leading ?? const Icon(LucideIcons.circle),
                            ),
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: 24,
                        child: Center(
                          child:
                              leading ??
                              Icon(
                                LucideIcons.circle,
                                size: AppMark.size,
                                color: palette.muted,
                              ),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              letterSpacing: -0.15,
                              color: enabled ? palette.ink : palette.inactive,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            description,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.35,
                              color: selected
                                  ? palette.ink.withValues(alpha: 0.72)
                                  : palette.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (selected)
                      Icon(LucideIcons.check, size: AppIconSizes.control, color: accent)
                    else if (showDisclosure)
                      Icon(
                        LucideIcons.chevronRight,
                        size: AppIconSizes.control,
                        color: palette.inactive,
                      ),
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

/// Sheet header recipe: title + optional muted lead line, tight spacing,
/// drag handle above. Pickers previously shipped a bare bold text with the
/// sheet's own padding — this gives every sheet the same header rhythm.
class AppOptionSheetHeader extends StatelessWidget {
  const AppOptionSheetHeader({super.key, required this.title, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.center,
          child: Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: palette.lineStrong.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
          ),
        ),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: palette.ink,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 4),
          Text(
            detail!,
            style: TextStyle(fontSize: 12, height: 1.4, color: palette.muted),
          ),
        ],
      ],
    );
  }
}

class AppElevation {
  static Color _shadowColor(BuildContext? context, double alpha) {
    final dark =
        context != null && AppPalette.of(context).brightness == Brightness.dark;
    return Colors.black.withValues(alpha: dark ? alpha * 0.75 : alpha);
  }

  static List<BoxShadow> surfaceCard({
    BuildContext? context,
    bool pressed = false,
  }) => [
    BoxShadow(
      color: _shadowColor(context, pressed ? 0.025 : 0.035),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: _shadowColor(context, pressed ? 0.025 : 0.045),
      blurRadius: pressed ? 6 : 12,
      offset: Offset(0, pressed ? 1 : 3),
      spreadRadius: -4,
    ),
  ];

  static List<BoxShadow> stopControl({
    BuildContext? context,
    bool pressed = false,
  }) => [
    BoxShadow(
      color: (context == null ? AppPalette.light : AppPalette.of(context))
          .stopGlow,
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: _shadowColor(context, 0.08),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> floatingOverlay({BuildContext? context}) => [
    BoxShadow(
      color: _shadowColor(context, 0.04),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: _shadowColor(context, 0.09),
      blurRadius: 28,
      offset: const Offset(0, 10),
      spreadRadius: -6,
    ),
  ];

  static List<BoxShadow> softCard({
    BuildContext? context,
    double alpha = 0.07,
  }) => [
    BoxShadow(
      color: _shadowColor(context, alpha),
      blurRadius: 18,
      offset: const Offset(0, 6),
      spreadRadius: -4,
    ),
  ];

  static List<BoxShadow> softBubble({
    BuildContext? context,
    double alpha = 0.05,
  }) => const [];

  static List<BoxShadow> liquidThin({
    BuildContext? context,
    bool pressed = false,
  }) => [
    BoxShadow(
      color: _shadowColor(context, pressed ? 0.025 : 0.035),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: _shadowColor(context, pressed ? 0.035 : 0.055),
      blurRadius: pressed ? 7 : 12,
      offset: Offset(0, pressed ? 1 : 3),
      spreadRadius: -4,
    ),
  ];

  static List<BoxShadow> liquidStrong({
    BuildContext? context,
    bool pressed = false,
  }) => [
    BoxShadow(
      color: _shadowColor(context, pressed ? 0.03 : 0.045),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: _shadowColor(context, pressed ? 0.04 : 0.065),
      blurRadius: pressed ? 10 : 18,
      offset: Offset(0, pressed ? 2 : 5),
      spreadRadius: -4,
    ),
  ];
}

class AppLiquidGlass {
  static const thinBackdropGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xEAFFFFFF), Color(0xDDFDFDFD), Color(0xD4F6F6F6)],
    stops: [0, 0.58, 1],
  );
  static const thinBackdropPressedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xE5FCFCFC), Color(0xD9FAFAFA), Color(0xD4F2F2F2)],
    stops: [0, 0.48, 1],
  );
  static const strongBackdropGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xF5FFFFFF), Color(0xEDFFFFFF), Color(0xE6FAFAFA)],
    stops: [0, 0.54, 1],
  );
  static const strongBackdropPressedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xF0FCFCFC), Color(0xE9FBFBFB), Color(0xE2F6F6F6)],
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
    colors: [Color(0xF4FCFCFC), AppColors.liquidThinBody, Color(0xEFF2F2F2)],
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
    colors: [Color(0xF8FCFCFC), AppColors.liquidStrongBody, Color(0xF2F6F6F6)],
    stops: [0, 0.30, 1],
  );

  static LinearGradient _forPalette(
    LinearGradient gradient,
    AppPalette palette,
  ) {
    if (palette.brightness == Brightness.light) return gradient;
    const tones = [Color(0xFF323232), Color(0xFF2C2C2C), Color(0xFF282828)];
    return LinearGradient(
      begin: gradient.begin,
      end: gradient.end,
      stops: gradient.stops,
      colors: [
        for (var i = 0; i < tones.length; i++)
          tones[i].withValues(alpha: gradient.colors[i].a),
      ],
    );
  }

  static BoxDecoration thin({
    BuildContext? context,
    BorderRadius? borderRadius,
    BoxShape shape = BoxShape.rectangle,
    bool pressed = false,
    bool elevated = true,
    bool backdrop = false,
  }) {
    final palette = context == null ? AppPalette.light : AppPalette.of(context);
    final gradient = backdrop
        ? (pressed ? thinBackdropPressedGradient : thinBackdropGradient)
        : (pressed ? thinPressedGradient : thinGradient);
    return BoxDecoration(
      gradient: _forPalette(gradient, palette),
      borderRadius: shape == BoxShape.rectangle ? borderRadius : null,
      shape: shape,
      border: Border.all(color: palette.glassHighlight, width: 0.5),
      boxShadow: elevated
          ? AppElevation.liquidThin(context: context, pressed: pressed)
          : const [],
    );
  }

  static BoxDecoration strong({
    BuildContext? context,
    BorderRadius? borderRadius,
    bool pressed = false,
    bool focused = false,
    bool elevated = true,
    bool backdrop = false,
  }) {
    final palette = context == null ? AppPalette.light : AppPalette.of(context);
    final gradient = backdrop
        ? (pressed ? strongBackdropPressedGradient : strongBackdropGradient)
        : (pressed ? strongPressedGradient : strongGradient);
    return BoxDecoration(
      gradient: _forPalette(gradient, palette),
      border: Border.all(
        color: focused ? palette.liquidFocus : palette.glassHighlight,
        width: focused ? 2 : 0.5,
      ),
      borderRadius: borderRadius,
      boxShadow: elevated
          ? AppElevation.liquidStrong(context: context, pressed: pressed)
          : const [],
    );
  }
}

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
    final surface = DecoratedBox(
      decoration: decoration.copyWith(boxShadow: const []),
      child: child,
    );
    final blurred = BackdropFilter.grouped(
      filter: _blurFilterFor(blurSigma),
      child: surface,
    );
    final clipped = decoration.shape == BoxShape.circle
        ? ClipOval(child: blurred)
        : ClipRRect(
            borderRadius: decoration.borderRadius ?? BorderRadius.zero,
            child: blurred,
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: decoration.shape == BoxShape.rectangle
            ? decoration.borderRadius
            : null,
        shape: decoration.shape,
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
  static const micro = Duration(milliseconds: 150);
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
  const SheetScrim({super.key, this.color, this.onTap});

  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    final scrim = color ?? AppPalette.of(context).scrim;
    final Widget layer;
    if (animation == null || animation.value >= 1) {
      layer = ColoredBox(color: scrim);
    } else if (animation.value <= 0) {
      layer = const SizedBox.expand();
    } else {
      layer = AnimatedBuilder(
        animation: animation,
        builder: (context, _) => ColoredBox(
          color: scrim.withValues(alpha: scrim.a * animation.value),
        ),
      );
    }
    final painted = RepaintBoundary(child: layer);
    return Positioned.fill(
      child: onTap == null
          ? IgnorePointer(child: painted)
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: painted,
            ),
    );
  }
}

/// Wraps a modal sheet's builder result with a self-repainting scrim. Pair
/// with `barrierColor: Colors.transparent` on the route.
Widget appModalSheetScaffold(
  Widget sheet, {
  Color? barrierColor,
  VoidCallback? onBarrierTap,
}) {
  return Stack(
    children: [
      SheetScrim(color: barrierColor, onTap: onBarrierTap),
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

ThemeData buildSignalConsoleTheme([Brightness brightness = Brightness.light]) {
  final palette = brightness == Brightness.dark
      ? AppPalette.dark
      : AppPalette.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: palette.accent,
        brightness: brightness,
      ).copyWith(
        primary: palette.cta,
        onPrimary: palette.onCta,
        secondary: palette.accentStrong,
        onSecondary: palette.onCta,
        primaryContainer: palette.accentSoft,
        onPrimaryContainer: palette.ink,
        secondaryContainer: palette.accentSoft,
        onSecondaryContainer: palette.ink,
        tertiary: palette.accent,
        onTertiary: palette.onCta,
        tertiaryContainer: palette.control,
        onTertiaryContainer: palette.ink,
        surface: palette.surface,
        onSurface: palette.ink,
        error: palette.danger,
        onError: palette.onStop,
        outline: palette.lineStrong,
        outlineVariant: palette.line,
        surfaceTint: Colors.transparent,
        surfaceContainerLowest: palette.surface,
        surfaceContainerLow: palette.surface,
        surfaceContainer: palette.surface,
        surfaceContainerHigh: palette.control,
        surfaceContainerHighest: palette.control,
      );

  TextStyle signalText(
    TextStyle? base, {
    required double size,
    required FontWeight weight,
    required double height,
    double letterSpacing = 0,
    Color? color,
  }) {
    return (base ?? const TextStyle()).copyWith(
      color: color ?? palette.ink,
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
      color: palette.muted,
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
    brightness: brightness,
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
    scaffoldBackgroundColor: palette.paper,
    cardTheme: CardThemeData(
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: palette.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: textTheme.titleLarge,
    ),
    iconTheme: IconThemeData(color: palette.ink, size: AppIconSizes.control),
    dividerTheme: DividerThemeData(color: palette.line, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.control,
      hintStyle: textTheme.bodyMedium?.copyWith(color: palette.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: palette.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: palette.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: palette.accentStrong, width: 1.4),
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
            return palette.onCta.withValues(alpha: 0.13);
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
        side: WidgetStatePropertyAll(BorderSide(color: palette.lineStrong)),
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
            return palette.accent.withValues(alpha: 0.08);
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
            return palette.muted.withValues(alpha: 0.42);
          }
          return palette.ink;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return palette.accent.withValues(alpha: 0.10);
          }
          return null;
        }),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      modalBackgroundColor: palette.surface,
      modalBarrierColor: palette.scrim,
      showDragHandle: true,
      dragHandleColor: palette.lineStrong,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.header),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      textStyle: textTheme.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadii.surface)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.ink,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: palette.paper),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
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
                  border: Border.all(
                    color: AppPalette.of(context).porcelain,
                    width: 2,
                  ),
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

// Only the event that creates this state may start an entrance.
class SignalEntrance extends StatefulWidget {
  const SignalEntrance({
    super.key,
    required this.animate,
    required this.distance,
    required this.child,
  });

  final bool animate;
  final double distance;
  final Widget child;

  @override
  State<SignalEntrance> createState() => _SignalEntranceState();
}

class _SignalEntranceState extends State<SignalEntrance>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: AppMotion.fast,
    value: widget.animate ? 0 : 1,
  );
  late final progress = CurvedAnimation(
    parent: controller,
    curve: AppMotion.enter,
  );
  bool started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context)) {
      controller.value = 1;
      started = true;
    } else if (!started) {
      started = true;
      if (widget.animate) controller.forward();
    }
  }

  @override
  void dispose() {
    progress.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: progress,
    child: widget.child,
    builder: (context, child) => Transform.translate(
      offset: Offset(0, widget.distance * (1 - progress.value)),
      child: FadeTransition(opacity: progress, child: child),
    ),
  );
}

class SignalCopyIcon extends StatelessWidget {
  const SignalCopyIcon({super.key, required this.copied, this.size});

  final bool copied;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final dimension = size ?? IconTheme.of(context).size ?? 24;
    return SizedBox.square(
      dimension: dimension,
      child: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppMotion.micro,
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.enter,
        child: Icon(
          copied ? LucideIcons.check : LucideIcons.copy,
          key: ValueKey(copied),
          size: dimension,
        ),
      ),
    );
  }
}

class SignalCompletionIcon extends StatelessWidget {
  const SignalCompletionIcon({
    super.key,
    required this.color,
    required this.size,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final static =
        MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context);
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: static ? 1 : 0, end: 1),
        duration: static ? Duration.zero : AppMotion.standard,
        curve: AppMotion.enter,
        builder: (context, progress, _) => CustomPaint(
          size: Size.square(size),
          painter: _CompletionPainter(color, progress),
        ),
      ),
    );
  }
}

class _CompletionPainter extends CustomPainter {
  const _CompletionPainter(this.color, this.progress);

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(12, 12), 10, paint);
    final check = Path()
      ..moveTo(7.5, 12)
      ..lineTo(10.5, 15)
      ..lineTo(16.5, 9);
    final metric = check.computeMetrics().first;
    canvas.drawPath(metric.extractPath(0, metric.length * progress), paint);
  }

  @override
  bool shouldRepaint(_CompletionPainter oldDelegate) =>
      color != oldDelegate.color || progress != oldDelegate.progress;
}
