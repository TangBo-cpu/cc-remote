import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'activity_disclosure.dart';
import 'data/remote_models.dart';
import 'noto_icon.dart';
import 'signal_console_theme.dart';

String thinkingDurationLabel(int? durationMs) {
  if (durationMs == null || durationMs <= 0) return '';
  final seconds = math.max(1, (durationMs / 1000).round());
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  final remaining = seconds % 60;
  return remaining == 0 ? '$minutes 分钟' : '$minutes 分 $remaining 秒';
}

class ThinkingHistoryBlock extends StatefulWidget {
  const ThinkingHistoryBlock({
    super.key,
    required this.message,
    this.initialElapsedSeconds = 0,
  });

  final TranscriptMessage message;
  final int initialElapsedSeconds;

  @override
  State<ThinkingHistoryBlock> createState() => _ThinkingHistoryBlockState();
}

class _ThinkingHistoryBlockState extends State<ThinkingHistoryBlock> {
  bool expanded = false;

  @override
  void didUpdateWidget(covariant ThinkingHistoryBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.activityId != widget.message.activityId) {
      expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final message = widget.message;
    final running = message.activityState == ActivityState.running;
    final detail = message.activityDetail?.trim() ?? '';
    if (!running && detail.isEmpty) return const SizedBox.shrink();
    final title = switch (message.activityState) {
      ActivityState.error => '思考失败',
      ActivityState.stopped => '思考已停止',
      ActivityState.running => '思考中',
      _ => '已深度思考',
    };
    final duration = thinkingDurationLabel(message.activityDurationMs);
    final elapsed = running && widget.initialElapsedSeconds > 0
        ? '，本轮已运行 ${widget.initialElapsedSeconds} 秒'
        : duration.isEmpty
        ? ''
        : '，$duration';
    final textStyle = TextStyle(color: palette.ink, fontSize: 15, height: 1.6);
    return ActivityDisclosure(
      expanded: expanded,
      toggleKey: const ValueKey('thinking-history-toggle'),
      titleKey: const ValueKey('thinking-title'),
      title: title,
      running: running,
      titleWidget: running
          ? ThinkingIndicator(
              initialElapsedSeconds: widget.initialElapsedSeconds,
            )
          : null,
      leading: running
          ? null
          : const SmartIcon(LucideIcons.brain, size: AppIconSizes.inline),
      tone: message.activityState == ActivityState.error
          ? palette.danger
          : null,
      semanticLabel: '$title$elapsed',
      onToggle: detail.isNotEmpty || running
          ? () => setState(() => expanded = !expanded)
          : null,
      child: Container(
        key: const ValueKey('thinking-history-content'),
        width: double.infinity,
        padding: const EdgeInsetsDirectional.only(start: 12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(color: palette.lineStrong, width: 2),
          ),
        ),
        child: SelectionArea(
          child: MarkdownBody(
            data: detail,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                .copyWith(
                  p: textStyle,
                  blockquote: textStyle.copyWith(color: palette.muted),
                  code: textStyle.copyWith(
                    fontFamily: AppTypography.codeFontFamily,
                    fontFamilyFallback: AppTypography.codeFontFamilyFallback,
                    fontSize: 14,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: palette.control,
                    borderRadius: BorderRadius.circular(AppRadii.compact),
                  ),
                ),
          ),
        ),
      ),
    );
  }
}

class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({super.key, this.initialElapsedSeconds = 0});

  final int initialElapsedSeconds;

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  );
  Timer? elapsedTimer;
  late int elapsedSeconds;

  @override
  void initState() {
    super.initState();
    elapsedSeconds = widget.initialElapsedSeconds;
    elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => elapsedSeconds++);
    });
  }

  @override
  void didUpdateWidget(covariant ThinkingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    elapsedSeconds = math.max(elapsedSeconds, widget.initialElapsedSeconds);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context)) {
      animation.stop();
      animation.value = 0.5;
    } else if (!animation.isAnimating) {
      animation.repeat();
    }
  }

  @override
  void dispose() {
    elapsedTimer?.cancel();
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final elapsed = elapsedSeconds <= 0
        ? '本轮刚开始'
        : elapsedSeconds < 90
        ? '本轮已运行 $elapsedSeconds 秒'
        : '本轮已运行 ${(elapsedSeconds / 60).toStringAsFixed(1)} 分钟';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, _) => CustomPaint(
                key: const ValueKey('thinking-icon'),
                size: const Size.square(18),
                painter: _ThinkingBloomPainter(
                  (animation.value * 12).floor() % 12,
                  palette.muted,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ActivityShimmerText('思考中', color: palette.muted),
              Text(
                elapsed,
                key: const ValueKey('thinking-elapsed'),
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  height: 1.4,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ThinkingBloomPainter extends CustomPainter {
  const _ThinkingBloomPainter(this.frame, this.color);

  final int frame;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is _ThinkingBloomPainter &&
      other.frame == frame && other.color == color;

  @override
  int get hashCode => Object.hash(frame, color);

  @override
  void paint(Canvas canvas, Size size) {
    final stage = frame <= 5 ? frame : 11 - frame;
    final center = size.center(Offset.zero);
    if (stage == 0) {
      canvas.drawCircle(center, 1.45, Paint()..color = color);
      return;
    }
    final spokes = switch (stage) {
      1 => 4,
      2 || 4 => 8,
      _ => 6,
    };
    final radius = switch (stage) {
      1 => 4.1,
      2 => 4.8,
      3 => 5.2,
      4 => 5.5,
      _ => 5.8,
    };
    final rotation = switch (stage) {
      1 => math.pi / 4,
      2 => math.pi / 8,
      3 => math.pi / 6,
      _ => 0.0,
    };
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stage == 5 ? 1.9 : 1.55;
    for (var index = 0; index < spokes; index++) {
      final angle = rotation + index * 2 * math.pi / spokes;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final lengthFactor = spokes == 8 && index.isOdd ? 0.74 : 1.0;
      canvas.drawLine(
        center + direction * 1.35,
        center + direction * radius * lengthFactor,
        paint,
      );
    }
    canvas.drawCircle(center, 1.05, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ThinkingBloomPainter oldDelegate) =>
      oldDelegate.frame != frame || oldDelegate.color != color;
}
