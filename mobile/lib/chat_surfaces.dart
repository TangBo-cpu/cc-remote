import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'signal_console_theme.dart';

class ChatGlass extends StatelessWidget {
  const ChatGlass({
    super.key,
    required this.shape,
    required this.child,
    this.elevated = true,
    this.focused = false,
    this.translucent = true,
    this.fillOpacity,
  });

  final ShapeBorder shape;
  final Widget child;
  final bool elevated;
  final bool focused;
  final bool translucent;
  final double? fillOpacity;

  static ui.ImageFilter _filter(double saturation) {
    final matrix = <double>[];
    const weights = [0.2126, 0.7152, 0.0722];
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        matrix.add(
          weights[col] * (1 - saturation) + (row == col ? saturation : 0),
        );
      }
      matrix.addAll([0, 0]);
    }
    matrix.addAll([0, 0, 0, 1, 0]);
    return ui.ImageFilter.compose(
      outer: ColorFilter.matrix(matrix),
      inner: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
    );
  }

  static final _lightFilter = _filter(1.3);
  static final _darkFilter = _filter(1.2);

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final dark = palette.brightness == Brightness.dark;
    final opaque =
        !translucent ||
        MediaQuery.highContrastOf(context) ||
        SignalScrollBlurState.isScrolling(context);
    final fill = palette.chatGlassFill.withValues(
      alpha: opaque ? 1 : fillOpacity ?? (dark ? 0.72 : 0.70),
    );
    final surface = CustomPaint(
      foregroundPainter: _ChatGlassEdges(shape, palette, focused),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: fill),
        child: child,
      ),
    );
    return CustomPaint(
      painter: elevated ? _ChatGlassShadow(shape, palette) : null,
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: BackdropFilter.grouped(
          enabled: !opaque,
          filter: dark ? _darkFilter : _lightFilter,
          child: surface,
        ),
      ),
    );
  }
}

class _ChatGlassShadow extends CustomPainter {
  const _ChatGlassShadow(this.shape, this.palette);
  final ShapeBorder shape;
  final AppPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outline = shape.getOuterPath(rect);
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect.inflate(80)),
      outline,
    );
    final dark = palette.brightness == Brightness.dark;
    canvas.save();
    // 阴影只落在外部，避免透过半透明填充使玻璃发灰。
    canvas.clipPath(outside);
    for (final shadow in [
      BoxShadow(
        color: palette.chatShadow.withValues(alpha: dark ? 0.35 : 0.08),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
      BoxShadow(
        color: palette.chatShadow.withValues(alpha: dark ? 0.25 : 0.05),
        blurRadius: 3,
        offset: const Offset(0, 1),
      ),
    ]) {
      canvas.drawPath(outline.shift(shadow.offset), shadow.toPaint());
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ChatGlassShadow old) =>
      old.shape != shape || old.palette != palette;
}

class _ChatGlassEdges extends CustomPainter {
  const _ChatGlassEdges(this.shape, this.palette, this.focused);
  final ShapeBorder shape;
  final AppPalette palette;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final width = focused ? 1.5 : 0.5;
    final path = shape.getOuterPath(rect.deflate(width / 2));
    final brush = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = focused ? palette.liquidFocus : palette.chatGlassEdge;
    canvas.drawPath(path, brush);
    if (focused) return;
    brush
      ..strokeWidth = 0.8
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          palette.chatGlassRim,
          palette.chatGlassRim.withValues(alpha: 0),
        ],
        stops: const [0, 0.45],
      ).createShader(rect);
    canvas.drawPath(path, brush);
  }

  @override
  bool shouldRepaint(_ChatGlassEdges old) =>
      old.shape != shape || old.palette != palette || old.focused != focused;
}

class ChatBackdrop extends SingleChildRenderObjectWidget {
  const ChatBackdrop({super.key, required super.child, this.veil = false});
  final bool veil;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderChatBackdrop(AppPalette.of(context), veil);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderChatBackdrop).update(AppPalette.of(context), veil);
  }
}

class _RenderChatBackdrop extends RenderProxyBox {
  _RenderChatBackdrop(this.palette, this.veil);
  AppPalette palette;
  bool veil;

  void update(AppPalette nextPalette, bool nextVeil) {
    if (palette == nextPalette && veil == nextVeil) return;
    palette = nextPalette;
    veil = nextVeil;
    markNeedsPaint();
  }

  void _background(Canvas canvas, Size area) {
    final rect = Offset.zero & area;
    final brush = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.bgTop, palette.bgBottom],
      ).createShader(rect);
    canvas.drawRect(rect, brush);
    for (final (center, radius, color) in [
      (
        Offset(area.width * 0.92, 0),
        area.longestSide * 0.62,
        palette.bgGlowPrimary,
      ),
      (
        Offset(0, area.height),
        area.longestSide * 0.55,
        palette.bgGlowSecondary,
      ),
    ]) {
      brush.shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(rect, brush);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final rect = offset & size;
    canvas.save();
    canvas.clipRect(rect);
    if (veil) canvas.saveLayer(rect, Paint());
    canvas.translate(offset.dx, offset.dy);
    RenderObject? ancestor = parent;
    while (ancestor != null &&
        !(ancestor is _RenderChatBackdrop && !ancestor.veil)) {
      ancestor = ancestor.parent;
    }
    if (veil && ancestor is _RenderChatBackdrop) {
      // 使用整页坐标重画背景，键盘和输入框高度变化时不会产生色带。
      final origin = MatrixUtils.transformPoint(
        getTransformTo(ancestor),
        Offset.zero,
      );
      canvas.translate(-origin.dx, -origin.dy);
      _background(canvas, ancestor.size);
      canvas.translate(origin.dx, origin.dy);
    } else {
      _background(canvas, size);
    }
    if (veil) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black, Colors.black],
            stops: [0, 0.45, 1],
          ).createShader(Offset.zero & size),
      );
      canvas.restore();
    }
    canvas.restore();
    super.paint(context, offset);
  }
}
