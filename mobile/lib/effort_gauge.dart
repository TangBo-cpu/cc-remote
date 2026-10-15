import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'effort_preference.dart';
import 'signal_console_theme.dart';

const _manualEfforts = <ClaudeEffortPreference>[
  ClaudeEffortPreference.low,
  ClaudeEffortPreference.medium,
  ClaudeEffortPreference.high,
  ClaudeEffortPreference.xhigh,
  ClaudeEffortPreference.max,
];

int _manualIndex(ClaudeEffortPreference effort) {
  final index = _manualEfforts.indexOf(effort);
  return index < 0 ? 2 : index;
}

Future<void> showEffortGaugeOverlay(
  BuildContext context, {
  required ClaudeEffortPreference selected,
  required ValueChanged<ClaudeEffortPreference> onSelected,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭思考强度',
    barrierColor: Colors.transparent,
    transitionDuration: reduceMotion ? Duration.zero : AppMotion.fast,
    pageBuilder: (dialogContext, _, _) =>
        _EffortGaugeOverlay(selected: selected, onSelected: onSelected),
    transitionBuilder: (context, animation, _, child) {
      if (reduceMotion) return child;
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: AppMotion.enter),
        child: child,
      );
    },
  );
}

class EffortGaugeIcon extends StatelessWidget {
  const EffortGaugeIcon({
    super.key,
    required this.effort,
    required this.enabled,
  });

  final ClaudeEffortPreference effort;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: const Size(25, 21),
        painter: _EffortGaugePainter(
          palette: AppPalette.of(context),
          level: _manualIndex(effort).toDouble(),
          automatic: effort == ClaudeEffortPreference.automatic,
          enabled: enabled,
          compact: true,
        ),
      ),
    );
  }
}

class _EffortGaugeOverlay extends StatefulWidget {
  const _EffortGaugeOverlay({required this.selected, required this.onSelected});

  final ClaudeEffortPreference selected;
  final ValueChanged<ClaudeEffortPreference> onSelected;

  @override
  State<_EffortGaugeOverlay> createState() => _EffortGaugeOverlayState();
}

class _EffortGaugeOverlayState extends State<_EffortGaugeOverlay> {
  late ClaudeEffortPreference current = widget.selected;
  late ClaudeEffortPreference committed = widget.selected;
  bool showFocusHighlight = false;

  int get currentManualIndex => _manualIndex(current);

  void select(ClaudeEffortPreference next, {required bool commit}) {
    if (next != current) {
      setState(() => current = next);
      unawaited(HapticFeedback.selectionClick());
    }
    if (!commit || next == committed) return;
    committed = next;
    widget.onSelected(next);
  }

  void selectManualAt(Offset position, Size size, {required bool commit}) {
    final index = ((position.dx / size.width) * _manualEfforts.length)
        .floor()
        .clamp(0, _manualEfforts.length - 1);
    select(_manualEfforts[index], commit: commit);
  }

  void increase() {
    final next = (currentManualIndex + 1).clamp(0, _manualEfforts.length - 1);
    select(_manualEfforts[next], commit: true);
  }

  void decrease() {
    final next = (currentManualIndex - 1).clamp(0, _manualEfforts.length - 1);
    select(_manualEfforts[next], commit: true);
  }

  void selectAutomatic() {
    select(ClaudeEffortPreference.automatic, commit: true);
  }

  bool isHubTap(Offset position, Size size) {
    return (position - _EffortGaugePainter.hubFor(size)).distance <= 28;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final palette = AppPalette.of(context);
    final size = media.size;
    final compact = size.width < 350;
    final gaugeSize = compact ? const Size(160, 126) : const Size(184, 142);
    final bottom = math.max(170.0, size.height * 0.255);
    final right = math.max(20.0, (size.width - 390) / 2 + 24);
    final reduceMotion = media.disableAnimations;
    final nextIndex = (currentManualIndex + 1).clamp(
      0,
      _manualEfforts.length - 1,
    );
    final previousIndex = (currentManualIndex - 1).clamp(
      0,
      _manualEfforts.length - 1,
    );
    final canIncrease = current != ClaudeEffortPreference.max;
    final canDecrease = current != ClaudeEffortPreference.low;

    return BlockSemantics(
      child: Material(
        color: Colors.transparent,
        child: Stack(
          key: const ValueKey('effort-gauge-overlay'),
          children: [
            Positioned.fill(
              child: Semantics(
                button: true,
                label: '关闭思考强度',
                onTap: () => Navigator.pop(context),
                child: GestureDetector(
                  key: const ValueKey('effort-gauge-dismiss'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.pop(context),
                  child: ClipRect(
                    child: BackdropFilter(
                      key: const ValueKey('effort-gauge-blur'),
                      filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.surfaceElevated.withValues(
                            alpha: 0.12,
                          ),
                          gradient: RadialGradient(
                            center: const Alignment(0.40, 0.34),
                            radius: 1.08,
                            colors: [
                              palette.surfaceElevated.withValues(alpha: 0.02),
                              palette.paper.withValues(alpha: 0.08),
                              palette.composerControlFill.withValues(
                                alpha: 0.20,
                              ),
                            ],
                            stops: const [0, 0.62, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: right,
              bottom: bottom,
              child: MediaQuery(
                data: media.copyWith(
                  textScaler: media.textScaler.clamp(
                    minScaleFactor: 0.9,
                    maxScaleFactor: 1.3,
                  ),
                ),
                child: Column(
                  key: const ValueKey('effort-gauge-surface'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      current.label,
                      key: const ValueKey('effort-gauge-label'),
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.arrowRight):
                            increase,
                        const SingleActivator(LogicalKeyboardKey.arrowUp):
                            increase,
                        const SingleActivator(LogicalKeyboardKey.arrowLeft):
                            decrease,
                        const SingleActivator(LogicalKeyboardKey.arrowDown):
                            decrease,
                        const SingleActivator(LogicalKeyboardKey.home):
                            selectAutomatic,
                      },
                      child: FocusableActionDetector(
                        autofocus: true,
                        onShowFocusHighlight: (value) {
                          if (showFocusHighlight != value) {
                            setState(() => showFocusHighlight = value);
                          }
                        },
                        child: AnimatedContainer(
                          duration: reduceMotion
                              ? Duration.zero
                              : AppMotion.fast,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            border: showFocusHighlight
                                ? Border.all(
                                    color: palette.accentStrong,
                                    width: 2,
                                  )
                                : null,
                          ),
                          child: Semantics(
                            slider: true,
                            excludeSemantics: true,
                            label: '思考强度',
                            value: current.label,
                            increasedValue: canIncrease
                                ? _manualEfforts[nextIndex].label
                                : null,
                            decreasedValue: canDecrease
                                ? _manualEfforts[previousIndex].label
                                : null,
                            hint: '左右滑动或点击档位；双击跟随模型',
                            onIncrease: canIncrease ? increase : null,
                            onDecrease: canDecrease ? decrease : null,
                            onTap: selectAutomatic,
                            child: GestureDetector(
                              key: const ValueKey('effort-gauge-control'),
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (details) {
                                if (isHubTap(
                                  details.localPosition,
                                  gaugeSize,
                                )) {
                                  selectAutomatic();
                                } else {
                                  selectManualAt(
                                    details.localPosition,
                                    gaugeSize,
                                    commit: true,
                                  );
                                }
                              },
                              onPanUpdate: (details) => selectManualAt(
                                details.localPosition,
                                gaugeSize,
                                commit: false,
                              ),
                              onPanEnd: (_) => select(current, commit: true),
                              onPanCancel: () {
                                if (current != committed) {
                                  setState(() => current = committed);
                                }
                              },
                              child: TweenAnimationBuilder<double>(
                                tween: Tween<double>(
                                  end: currentManualIndex.toDouble(),
                                ),
                                duration: reduceMotion
                                    ? Duration.zero
                                    : AppMotion.fast,
                                curve: AppMotion.enter,
                                builder: (context, value, _) => RepaintBoundary(
                                  child: CustomPaint(
                                    size: gaugeSize,
                                    painter: _EffortGaugePainter(
                                      palette: palette,
                                      level: value,
                                      automatic:
                                          current ==
                                          ClaudeEffortPreference.automatic,
                                      enabled: true,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EffortGaugePainter extends CustomPainter {
  const _EffortGaugePainter({
    required this.palette,
    required this.level,
    required this.automatic,
    required this.enabled,
    this.compact = false,
  });

  static const startAngle = math.pi * 10 / 9;
  static const sweepAngle = math.pi * 7 / 9;

  final AppPalette palette;
  final double level;
  final bool automatic;
  final bool enabled;
  final bool compact;

  static Offset hubFor(Size size, {bool compact = false}) =>
      Offset(size.width / 2, size.height * (compact ? 0.76 : 0.53));

  @override
  void paint(Canvas canvas, Size size) {
    final hub = hubFor(size, compact: compact);
    final radius = compact
        ? math.min(size.width * 0.40, size.height * 0.67)
        : math.min(size.width * 0.36, size.height * 0.58);
    final rect = Rect.fromCircle(center: hub, radius: radius);
    final trackColor = enabled
        ? compact
              ? palette.inactiveLight
              : Color.lerp(palette.inactiveLight, palette.inactive, 0.22)!
        : palette.line;
    final activeColor = enabled ? palette.accentStrong : palette.inactiveLight;
    final inkColor = enabled ? palette.ink : palette.inactive;
    final strokeWidth = compact ? 2.8 : 7.0;
    final dotRadius = compact ? 1.25 : 5.2;

    if (!compact) {
      final haloRect = Rect.fromCircle(
        center: hub - Offset(0, radius * 0.26),
        radius: radius * 1.32,
      );
      canvas.drawCircle(
        haloRect.center,
        haloRect.width / 2,
        Paint()
          ..shader = RadialGradient(
            colors: [
              palette.surfaceElevated.withValues(alpha: 0.82),
              palette.surfaceElevated.withValues(alpha: 0.38),
              palette.surfaceElevated.withValues(alpha: 0),
            ],
            stops: const [0, 0.54, 1],
          ).createShader(haloRect),
      );
      canvas.drawArc(
        rect.shift(const Offset(0, 1.2)),
        startAngle,
        sweepAngle,
        false,
        Paint()
          ..color = palette.ink.withValues(alpha: 0.10)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth + 1.4
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      );
    }

    canvas.drawArc(
      rect,
      startAngle,
      sweepAngle,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    final normalized = (level / (_manualEfforts.length - 1)).clamp(0.0, 1.0);
    if (!automatic) {
      if (!compact) {
        canvas.drawArc(
          rect,
          startAngle,
          sweepAngle * normalized,
          false,
          Paint()
            ..color = activeColor.withValues(alpha: 0.24)
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth + 2
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }
      canvas.drawArc(
        rect,
        startAngle,
        sweepAngle * normalized,
        false,
        Paint()
          ..color = activeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }

    if (!compact) {
      for (var index = 0; index < _manualEfforts.length; index += 1) {
        final fraction = index / (_manualEfforts.length - 1);
        final angle = startAngle + sweepAngle * fraction;
        final point = hub + Offset(math.cos(angle), math.sin(angle)) * radius;
        final active = !automatic && index <= level.round();
        canvas.drawCircle(
          point + const Offset(0, 1.2),
          dotRadius + 1.8,
          Paint()
            ..color = palette.ink.withValues(alpha: 0.13)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
        );
        canvas.drawCircle(
          point,
          dotRadius + 1.5,
          Paint()..color = active ? palette.surface : trackColor,
        );
        canvas.drawCircle(
          point,
          active ? dotRadius : dotRadius - 1.5,
          Paint()..color = active ? activeColor : palette.surface,
        );
      }
    }

    final needleAngle =
        startAngle + sweepAngle * (automatic ? 0.5 : normalized);
    final direction = Offset(math.cos(needleAngle), math.sin(needleAngle));
    final normal = Offset(-direction.dy, direction.dx);
    final needleLength = radius * (compact ? 0.70 : 0.90);
    final needleHalfWidth = compact ? 1.6 : 4.2;
    final needle = Path()
      ..moveTo(
        hub.dx + normal.dx * needleHalfWidth,
        hub.dy + normal.dy * needleHalfWidth,
      )
      ..lineTo(
        hub.dx + direction.dx * needleLength,
        hub.dy + direction.dy * needleLength,
      )
      ..lineTo(
        hub.dx - normal.dx * needleHalfWidth,
        hub.dy - normal.dy * needleHalfWidth,
      )
      ..close();
    if (!compact) {
      canvas.drawPath(
        needle.shift(const Offset(0, 1.5)),
        Paint()
          ..color = palette.ink.withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
      );
      canvas.drawCircle(
        hub + const Offset(0, 2),
        12.8,
        Paint()
          ..color = palette.ink.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    canvas.drawPath(needle, Paint()..color = inkColor);
    canvas.drawCircle(hub, compact ? 4.8 : 11.5, Paint()..color = inkColor);
    canvas.drawCircle(
      hub,
      compact ? 2.0 : 4.4,
      Paint()..color = compact ? palette.surface : trackColor,
    );

    if (!compact) {
      canvas.drawCircle(
        hub - const Offset(1.5, 1.5),
        1.6,
        Paint()..color = palette.surfaceElevated.withValues(alpha: 0.72),
      );
    }

    if (automatic && !compact) {
      final text = TextPainter(
        text: TextSpan(
          text: 'A',
          style: TextStyle(
            color: palette.ink,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, hub - Offset(text.width / 2, text.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _EffortGaugePainter oldDelegate) {
    return oldDelegate.palette != palette ||
        oldDelegate.level != level ||
        oldDelegate.automatic != automatic ||
        oldDelegate.enabled != enabled ||
        oldDelegate.compact != compact;
  }
}
