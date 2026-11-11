import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

enum Lamp {
  active,
  idle,
  connecting,
  disconnected,
  waiting,
  offline,
  notOpened,
}

enum LampShape { disc, ring, triangle, diamond, square }

enum LampStroke { none, solid, dashed, dotted }

typedef LampSpec = ({
  LampShape shape,
  LampStroke stroke,
  bool glow,
  bool spins,
  bool blinks,
});

String lampWord(Lamp l) => switch (l) {
  Lamp.active => '活动',
  Lamp.idle => '空闲',
  Lamp.connecting => '连接中',
  Lamp.disconnected => '已断开',
  Lamp.waiting => '等你',
  Lamp.offline => '离线',
  Lamp.notOpened => '未打开',
};

LampSpec lampSpec(Lamp l) {
  LampSpec s(
    LampShape shape,
    LampStroke stroke, {
    bool glow = false,
    bool spins = false,
    bool blinks = false,
  }) =>
      (shape: shape, stroke: stroke, glow: glow, spins: spins, blinks: blinks);
  return switch (l) {
    Lamp.active => s(LampShape.disc, LampStroke.none, glow: true),
    Lamp.idle => s(LampShape.ring, LampStroke.solid),
    Lamp.connecting => s(LampShape.ring, LampStroke.dashed, spins: true),
    Lamp.disconnected => s(LampShape.triangle, LampStroke.none),
    Lamp.waiting => s(LampShape.diamond, LampStroke.none, blinks: true),
    Lamp.offline => s(LampShape.ring, LampStroke.dotted),
    Lamp.notOpened => s(LampShape.square, LampStroke.none),
  };
}

Color _lampColor(Lamp l, RappTokens t) => switch (l) {
  Lamp.active || Lamp.connecting => t.on,
  Lamp.idle || Lamp.offline => t.muted,
  Lamp.disconnected || Lamp.waiting => t.accent,
  Lamp.notOpened => t.line,
};

/// Row background for a lamp state (design language section 2).
Decoration? rowBackdrop(Lamp l, RappTokens t) => switch (l) {
  Lamp.disconnected => _PatternDecoration(t.tint, stripes: true),
  Lamp.waiting => BoxDecoration(color: t.tint),
  Lamp.offline => _PatternDecoration(t.line, stripes: false),
  _ => null,
};

Color rowBorder(Lamp l, RappTokens t, {bool selected = false}) {
  if (l == Lamp.disconnected || l == Lamp.waiting) return t.accent;
  return selected ? t.text : t.line;
}

class _PatternDecoration extends Decoration {
  const _PatternDecoration(this.color, {required this.stripes});
  final Color color;
  final bool stripes;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _PatternPainter(color, stripes);
}

class _PatternPainter extends BoxPainter {
  _PatternPainter(this.color, this.stripes);
  final Color color;
  final bool stripes;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration cfg) {
    final size = cfg.size;
    if (size == null) return;
    canvas.save();
    canvas.clipRect(offset & size);
    canvas.translate(offset.dx, offset.dy);
    final p = Paint()..color = color;
    if (stripes) {
      // 135 degree stripes, one every 8px (measured along the row axis).
      p.strokeWidth = 1;
      for (var x = -size.height; x < size.width; x += 8) {
        canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), p);
      }
    } else {
      for (var y = 4.0; y < size.height; y += 8) {
        for (var x = 4.0; x < size.width; x += 8) {
          canvas.drawCircle(Offset(x, y), .75, p);
        }
      }
    }
    canvas.restore();
  }
}

/// A status lamp. Decorative: hidden from screen readers; put the
/// [lampWord] next to it.
class StatusLamp extends StatelessWidget {
  const StatusLamp(this.kind, {super.key, this.size = 10});
  final Lamp kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final spec = lampSpec(kind);
    final box = size * 1.3;
    Widget lamp = CustomPaint(
      size: Size.square(box),
      painter: _LampPainter(kind, _lampColor(kind, t), size, t),
    );
    if (!MediaQuery.disableAnimationsOf(context)) {
      if (spec.spins) lamp = _Motion(spin: true, child: lamp);
      if (spec.blinks) lamp = _Motion(spin: false, child: lamp);
    }
    return ExcludeSemantics(
      child: SizedBox.square(dimension: box, child: lamp),
    );
  }
}

class _Motion extends StatefulWidget {
  const _Motion({required this.spin, required this.child});
  final bool spin;
  final Widget child;

  @override
  State<_Motion> createState() => _MotionState();
}

class _MotionState extends State<_Motion> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.spin
        ? const Duration(milliseconds: 1400)
        : const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    return super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.spin) return RotationTransition(turns: _c, child: widget.child);
    // Hard blink: visible for 0.5s, hidden for 0.5s.
    return FadeTransition(
      opacity: Tween<double>(
        begin: 1,
        end: 0,
      ).animate(CurvedAnimation(parent: _c, curve: const Threshold(.5))),
      child: widget.child,
    );
  }
}

class _LampPainter extends CustomPainter {
  _LampPainter(this.kind, this.color, this.base, this.tokens);
  final Lamp kind;
  final Color color;
  final double base;
  final RappTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final k = base / 10;
    final c = size.center(Offset.zero);
    final spec = lampSpec(kind);
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * k;
    switch (spec.shape) {
      case LampShape.disc:
        if (spec.glow) {
          for (final s in tokens.glow) {
            canvas.drawCircle(
              c,
              5 * k,
              Paint()
                ..color = s.color
                ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.blurSigma),
            );
          }
        }
        canvas.drawCircle(c, 5 * k, fill);
      case LampShape.ring:
        final rect = Rect.fromCircle(center: c, radius: 4 * k);
        switch (spec.stroke) {
          case LampStroke.dashed:
            const n = 8;
            for (var i = 0; i < n; i++) {
              canvas.drawArc(
                rect,
                i * 2 * math.pi / n,
                math.pi / n,
                false,
                stroke,
              );
            }
          case LampStroke.dotted:
            stroke.strokeCap = StrokeCap.round;
            stroke.strokeWidth = 1.6 * k;
            const n = 10;
            for (var i = 0; i < n; i++) {
              canvas.drawArc(rect, i * 2 * math.pi / n, .01, false, stroke);
            }
          default:
            canvas.drawCircle(c, 4 * k, stroke);
        }
      case LampShape.triangle:
        final w = 12 * k, h = 11 * k;
        canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy - h / 2)
            ..lineTo(c.dx + w / 2, c.dy + h / 2)
            ..lineTo(c.dx - w / 2, c.dy + h / 2)
            ..close(),
          fill,
        );
      case LampShape.diamond:
        canvas.save();
        canvas.translate(c.dx, c.dy);
        canvas.rotate(math.pi / 4);
        canvas.drawRect(
          Rect.fromCenter(center: Offset.zero, width: 9 * k, height: 9 * k),
          fill,
        );
        canvas.restore();
      case LampShape.square:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: 8 * k, height: 8 * k),
            Radius.circular(2 * k),
          ),
          fill,
        );
    }
  }

  @override
  bool shouldRepaint(_LampPainter o) =>
      o.kind != kind || o.color != color || o.base != base;
}
