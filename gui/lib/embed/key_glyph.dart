// Key faces that are drawn, not typeset: return and the four arrows. Font symbols for these look different (and thin)
// on every platform; a drawn thick-line arrow looks the same everywhere and as heavy as the words beside it.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum KeyGlyph { enter, up, down, left, right }

/// The drawn glyph for a key [label], or null when the label is drawn as text.
KeyGlyph? keyGlyphOf(String label) => switch (label) {
      '⏎' => KeyGlyph.enter,
      '↑' => KeyGlyph.up,
      '↓' => KeyGlyph.down,
      '←' => KeyGlyph.left,
      '→' => KeyGlyph.right,
      _ => null,
    };

/// The glyph's box, in logical pixels.
const keyGlyphSize = 23.0;

/// Line width on the glyph's 24×24 grid (the user picked 「粗线箭头」).
const keyGlyphStroke = 2.8;

class KeyGlyphIcon extends StatelessWidget {
  const KeyGlyphIcon({super.key, required this.glyph, required this.color, this.size = keyGlyphSize});
  final KeyGlyph glyph;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GlyphPainter(glyph, color));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);
  final KeyGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = keyGlyphStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (glyph == KeyGlyph.enter) {
      // ↵: down the right side, round the corner, left to an open arrowhead.
      canvas.drawPath(
          Path()
            ..moveTo(19.5, 5)
            ..lineTo(19.5, 11.5)
            ..quadraticBezierTo(19.5, 14.5, 16.5, 14.5)
            ..lineTo(4.5, 14.5),
          line);
      canvas.drawPath(Path()..moveTo(9.5, 9.5)..lineTo(4.5, 14.5)..lineTo(9.5, 19.5), line);
      return;
    }
    final turns = switch (glyph) { KeyGlyph.down => .5, KeyGlyph.left => -.25, KeyGlyph.right => .25, _ => 0.0 };
    canvas
      ..translate(12, 12)
      ..rotate(turns * 2 * math.pi)
      ..translate(-12, -12);
    canvas.drawLine(const Offset(12, 19.5), const Offset(12, 4.5), line);
    canvas.drawPath(Path()..moveTo(5.5, 11)..lineTo(12, 4.5)..lineTo(18.5, 11), line);
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}
