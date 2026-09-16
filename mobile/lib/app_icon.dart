import 'dart:math' as math;

import 'package:flutter/material.dart';

enum AppGlyph {
  archive,
  back,
  checkCircle,
  chevronRight,
  circle,
  ellipsis,
  grid,
  message,
  pencil,
  plus,
  project,
  refresh,
  search,
  trash,
  x,
}

class AppIcon extends StatelessWidget {
  const AppIcon(
    this.glyph, {
    super.key,
    this.size = 24,
    this.color,
    this.strokeWidth = 2,
    this.semanticLabel,
  });

  final AppGlyph glyph;
  final double size;
  final Color? color;
  final double strokeWidth;
  final String? semanticLabel;

  bool get _directional =>
      glyph == AppGlyph.back || glyph == AppGlyph.chevronRight;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedColor =
        color ??
        iconTheme.color ??
        DefaultTextStyle.of(context).style.color ??
        Colors.black;
    final painted = ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _AppIconPainter(
            glyph: glyph,
            color: resolvedColor,
            strokeWidth: strokeWidth,
            mirror:
                _directional && Directionality.of(context) == TextDirection.rtl,
          ),
        ),
      ),
    );
    if (semanticLabel == null) return painted;
    return Semantics(label: semanticLabel, image: true, child: painted);
  }
}

class _AppIconPainter extends CustomPainter {
  const _AppIconPainter({
    required this.glyph,
    required this.color,
    required this.strokeWidth,
    required this.mirror,
  });

  final AppGlyph glyph;
  final Color color;
  final double strokeWidth;
  final bool mirror;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.save();
    if (mirror) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.scale(scale, scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (glyph) {
      case AppGlyph.archive:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(4, 7, 16, 13),
            const Radius.circular(2),
          ),
          stroke,
        );
        canvas.drawLine(const Offset(4, 10), const Offset(20, 10), stroke);
        canvas.drawLine(const Offset(9, 14), const Offset(15, 14), stroke);
      case AppGlyph.back:
        _drawPath(canvas, stroke, const [
          Offset(11, 6),
          Offset(5, 12),
          Offset(11, 18),
        ]);
        canvas.drawLine(const Offset(5, 12), const Offset(20, 12), stroke);
      case AppGlyph.checkCircle:
        canvas.drawCircle(const Offset(12, 12), 9, fill);
        final check = Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.15
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        _drawPath(canvas, check, const [
          Offset(7.8, 12.2),
          Offset(10.7, 15),
          Offset(16.5, 9.2),
        ]);
      case AppGlyph.chevronRight:
        _drawPath(canvas, stroke, const [
          Offset(9, 6.5),
          Offset(14.5, 12),
          Offset(9, 17.5),
        ]);
      case AppGlyph.circle:
        canvas.drawCircle(const Offset(12, 12), 8.5, stroke);
      case AppGlyph.ellipsis:
        for (final x in const [6.5, 12.0, 17.5]) {
          canvas.drawCircle(Offset(x, 12), 1.35, fill);
        }
      case AppGlyph.grid:
        for (final rect in const [
          Rect.fromLTWH(4, 4, 6, 6),
          Rect.fromLTWH(14, 4, 6, 6),
          Rect.fromLTWH(4, 14, 6, 6),
          Rect.fromLTWH(14, 14, 6, 6),
        ]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(1.5)),
            stroke,
          );
        }
      case AppGlyph.message:
        final bubble = Path()
          ..moveTo(7, 5)
          ..lineTo(17, 5)
          ..quadraticBezierTo(20, 5, 20, 8)
          ..lineTo(20, 14)
          ..quadraticBezierTo(20, 17, 17, 17)
          ..lineTo(10, 17)
          ..lineTo(5, 20)
          ..lineTo(6.2, 16.4)
          ..quadraticBezierTo(4, 15.5, 4, 13)
          ..lineTo(4, 8)
          ..quadraticBezierTo(4, 5, 7, 5);
        canvas.drawPath(bubble, stroke);
      case AppGlyph.pencil:
        final pencil = Path()
          ..moveTo(5, 19)
          ..lineTo(6.3, 14.7)
          ..lineTo(15.5, 5.5)
          ..lineTo(18.5, 8.5)
          ..lineTo(9.3, 17.7)
          ..close();
        canvas.drawPath(pencil, stroke);
        canvas.drawLine(
          const Offset(6.3, 14.7),
          const Offset(9.3, 17.7),
          stroke,
        );
      case AppGlyph.plus:
        canvas.drawLine(const Offset(12, 5.5), const Offset(12, 18.5), stroke);
        canvas.drawLine(const Offset(5.5, 12), const Offset(18.5, 12), stroke);
      case AppGlyph.project:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(5, 4, 14, 16),
            const Radius.circular(2.5),
          ),
          stroke,
        );
        canvas.drawLine(const Offset(9, 5), const Offset(9, 19), stroke);
        canvas.drawLine(const Offset(6, 9), const Offset(8, 9), stroke);
        canvas.drawLine(const Offset(6, 15), const Offset(8, 15), stroke);
      case AppGlyph.refresh:
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(12, 12), radius: 7.5),
          -math.pi * 0.82,
          math.pi * 1.62,
          false,
          stroke,
        );
        _drawPath(canvas, stroke, const [
          Offset(16.8, 4.7),
          Offset(19.7, 5.2),
          Offset(19.2, 8.1),
        ]);
      case AppGlyph.search:
        canvas.drawCircle(const Offset(10.5, 10.5), 5.8, stroke);
        canvas.drawLine(const Offset(14.8, 14.8), const Offset(20, 20), stroke);
      case AppGlyph.trash:
        canvas.drawLine(const Offset(7, 7), const Offset(17, 7), stroke);
        canvas.drawLine(const Offset(10, 4.5), const Offset(14, 4.5), stroke);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(7.5, 7, 9, 13),
            const Radius.circular(1.8),
          ),
          stroke,
        );
        canvas.drawLine(
          const Offset(10.5, 11),
          const Offset(10.5, 16.5),
          stroke,
        );
        canvas.drawLine(
          const Offset(13.5, 11),
          const Offset(13.5, 16.5),
          stroke,
        );
      case AppGlyph.x:
        canvas.drawLine(
          const Offset(6.5, 6.5),
          const Offset(17.5, 17.5),
          stroke,
        );
        canvas.drawLine(
          const Offset(17.5, 6.5),
          const Offset(6.5, 17.5),
          stroke,
        );
    }
    canvas.restore();
  }

  void _drawPath(Canvas canvas, Paint paint, List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _AppIconPainter oldDelegate) {
    return glyph != oldDelegate.glyph ||
        color != oldDelegate.color ||
        strokeWidth != oldDelegate.strokeWidth ||
        mirror != oldDelegate.mirror;
  }
}
