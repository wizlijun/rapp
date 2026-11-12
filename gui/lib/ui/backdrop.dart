// Per-theme decorative backdrops. Never intercept pointer events.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.theme, required this.child, this.hole});
  final RappTheme theme;
  final Widget child;

  /// The remote picture's rect in global coordinates; IRON MAN's grid leaves it uncovered (R25).
  final ValueListenable<Rect?>? hole;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final Widget? layer = switch (theme) {
      RappTheme.matrix => CustomPaint(painter: _Scanlines(t.line, t.bg)),
      RappTheme.ironMan => _grid(context, t.on),
      RappTheme.avatar => _Blobs(t.on),
      RappTheme.westworld => null,
    };
    if (layer == null) return child;
    final fill = Positioned.fill(child: IgnorePointer(child: layer));
    // IRON MAN: "全屏叠" — the grid lies over everything, top bar and panels
    // included (prototype `holo` ::after, z-index 9). Others stay behind.
    final over = theme == RappTheme.ironMan;
    return Stack(
      fit: StackFit.passthrough,
      children: over ? [child, fill] : [fill, child],
    );
  }
}

extension on Backdrop {
  Widget _grid(BuildContext context, Color on) {
    final h = hole;
    if (h == null) return CustomPaint(painter: HoloGrid(on));
    return ValueListenableBuilder<Rect?>(
      valueListenable: h,
      builder: (context, global, _) {
        Rect? local;
        final box = context.findRenderObject();
        if (global != null) {
          if (box is RenderBox && box.attached && box.hasSize) {
            local = global.shift(-box.localToGlobal(Offset.zero));
          } else {
            local = global;
          }
        }
        return CustomPaint(painter: HoloGrid(on, hole: local));
      },
    );
  }
}

class _Scanlines extends CustomPainter {
  _Scanlines(this.line, this.bg);
  final Color line, bg;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = line.withValues(alpha: .08)
      ..strokeWidth = 1;
    for (var y = 0.0; y < size.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
    // Corner vignette: dark radial fade from each corner.
    final rad = size.shortestSide * .6;
    for (final c in [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(
            c,
            rad,
            [bg.withValues(alpha: .5), bg.withValues(alpha: 0)],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_Scanlines o) => o.line != line || o.bg != bg;
}

/// Prototype `holo`: 1px lines every 32px at 5% of the holo blue, plus a
/// faint blue light from the top centre (ellipse, 16% fading out by 60%).
class HoloGrid extends CustomPainter {
  HoloGrid(this.on, {this.hole});
  final Color on;

  /// Left unpainted, in this painter's own coordinates.
  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final h = hole;
    if (h == null) {
      canvas.clipRect(Offset.zero & size);
    } else {
      canvas.clipPath(Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(h));
    }
    final p = Paint()
      ..color = on.withValues(alpha: .05)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x + .5, 0), Offset(x + .5, size.height), p);
    }
    for (var y = 0.0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y + .5), Offset(size.width, y + .5), p);
    }
    // CSS "ellipse at 50% 0%" sizes to the farthest corner: radii w/2·√2, h·√2.
    const light = Color.fromRGBO(60, 150, 255, .16);
    canvas.save();
    canvas.translate(size.width / 2, 0);
    canvas.scale(size.width / 2 * math.sqrt2, size.height * math.sqrt2);
    canvas.drawCircle(
      Offset.zero,
      1,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [light, light.withValues(alpha: 0)],
          [0, .6],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(HoloGrid o) => o.on != on || o.hole != hole;
}

class _Blobs extends StatelessWidget {
  const _Blobs(this.on);
  final Color on;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
          child: CustomPaint(painter: _BlobPainter(on.withValues(alpha: .10))),
        ),
        CustomPaint(painter: _VLines(on.withValues(alpha: .04))),
      ],
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final r = size.shortestSide * .3;
    canvas.drawCircle(Offset(size.width * .2, size.height * .3), r, p);
    canvas.drawCircle(Offset(size.width * .7, size.height * .2), r * .8, p);
    canvas.drawCircle(Offset(size.width * .55, size.height * .8), r, p);
  }

  @override
  bool shouldRepaint(_BlobPainter o) => o.color != color;
}

class _VLines extends CustomPainter {
  _VLines(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 48) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_VLines o) => o.color != color;
}
