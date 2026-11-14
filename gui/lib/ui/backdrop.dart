// Per-theme decorative backdrops. Never intercept pointer events.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tokens.dart';

class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.theme, required this.child});
  final RappTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final Widget? layer = switch (theme) {
      RappTheme.matrix => CustomPaint(painter: _Scanlines(t.line, t.bg)),
      RappTheme.avatar => _Blobs(t.on),
      RappTheme.westworld => null,
    };
    if (layer == null) return child;
    final fill = Positioned.fill(child: IgnorePointer(child: layer));
    // Every backdrop stays behind the content.
    return Stack(
      fit: StackFit.passthrough,
      children: [fill, child],
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
