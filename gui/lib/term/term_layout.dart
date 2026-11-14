import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'sgr.dart';

class TermMetrics {
  const TermMetrics._(this.cellW, this.cellH, this.style);

  /// cellW is the width of 'M' (not rounded); cellH is its line height rounded up.
  static TermMetrics measure(TextStyle style) {
    final p = TextPainter(
      text: TextSpan(text: 'M', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final m = TermMetrics._(p.width, p.height.ceilToDouble(), style);
    p.dispose();
    return m;
  }

  final double cellW, cellH;
  final TextStyle style;
}

enum GlyphKind { run, single, box }

class GlyphRun {
  const GlyphRun(this.col, this.cols, this.text, this.style, this.kind);
  final int col, cols;
  final String text;
  final TermStyle style;
  final GlyphKind kind;
}

bool _isBox(int r) => r >= 0x2500 && r <= 0x259F;

/// Splits a row into glyph runs placed by column. Only same-style, one-column
/// ASCII-range cells are merged into a run; wide and other non-ASCII glyphs get
/// a run each, so a fallback font's advance can never push later cells off grid.
List<GlyphRun> layoutRow(TermLine line) {
  final out = <GlyphRun>[];
  var col = 0;
  StringBuffer? run;
  var runCol = 0, runCols = 0;
  TermStyle runStyle = const TermStyle();
  void flush() {
    if (run != null) {
      out.add(GlyphRun(runCol, runCols, run.toString(), runStyle, GlyphKind.run));
      run = null;
    }
  }

  for (final c in line.cells) {
    final r = c.ch.isEmpty ? 0x20 : c.ch.runes.first;
    if (c.width == 1 && r < 0x80 && c.ch.length == 1) {
      if (run != null && runStyle != c.style) flush();
      if (run == null) {
        run = StringBuffer();
        runCol = col;
        runCols = 0;
        runStyle = c.style;
      }
      run!.write(c.ch);
      runCols++;
    } else {
      flush();
      out.add(GlyphRun(col, c.width, c.ch, c.style, _isBox(r) ? GlyphKind.box : GlyphKind.single));
    }
    col += c.width;
  }
  flush();
  return out;
}

// Arm weights: 0 none, 1 light, 2 heavy, 3 double. Order: left, right, up, down.
const _l = 1, _h = 2, _d = 3;
final Map<int, List<int>> _arms = () {
  final m = <int, List<int>>{};
  void line(int w, Map<int, String> cps) {
    cps.forEach((cp, s) {
      m[cp] = [
        s.contains('l') ? w : 0,
        s.contains('r') ? w : 0,
        s.contains('u') ? w : 0,
        s.contains('d') ? w : 0,
      ];
    });
  }

  line(_l, {
    0x2500: 'lr', 0x2502: 'ud', 0x250C: 'rd', 0x2510: 'ld', 0x2514: 'ru', 0x2518: 'lu',
    0x251C: 'rud', 0x2524: 'lud', 0x252C: 'lrd', 0x2534: 'lru', 0x253C: 'lrud',
    0x2504: 'lr', 0x2506: 'ud', 0x2508: 'lr', 0x250A: 'ud',
    0x256D: 'rd', 0x256E: 'ld', 0x256F: 'lu', 0x2570: 'ru',
  });
  line(_h, {
    0x2501: 'lr', 0x2503: 'ud', 0x250F: 'rd', 0x2513: 'ld', 0x2517: 'ru', 0x251B: 'lu',
    0x2523: 'rud', 0x252B: 'lud', 0x2533: 'lrd', 0x253B: 'lru', 0x254B: 'lrud',
    0x2505: 'lr', 0x2507: 'ud', 0x2509: 'lr', 0x250B: 'ud',
  });
  line(_d, {
    0x2550: 'lr', 0x2551: 'ud', 0x2554: 'rd', 0x2557: 'ld', 0x255A: 'ru', 0x255D: 'lu',
    0x2560: 'rud', 0x2563: 'lud', 0x2566: 'lrd', 0x2569: 'lru', 0x256C: 'lrud',
  });
  return m;
}();

double _snap(double v, double dpr) => (v * dpr).round() / dpr;

/// Draws a box-drawing or block character into [cell]. Returns false for runes
/// it does not know, so the caller can fall back to the font.
bool drawBoxChar(Canvas c, int rune, Rect cell, Color color, {double dpr = 1.0}) {
  final paint = Paint()
    ..color = color
    ..isAntiAlias = false;
  void fill(double l, double t, double r, double b, [double? alpha]) {
    final p = alpha == null ? paint : (Paint()..color = color.withValues(alpha: alpha)..isAntiAlias = false);
    c.drawRect(Rect.fromLTRB(l, t, r, b), p);
  }

  final cx = cell.center.dx, cy = cell.center.dy;
  switch (rune) {
    case 0x2580:
      fill(cell.left, cell.top, cell.right, cy);
      return true;
    case 0x2584:
      fill(cell.left, cy, cell.right, cell.bottom);
      return true;
    case 0x2588:
      fill(cell.left, cell.top, cell.right, cell.bottom);
      return true;
    case 0x258C:
      fill(cell.left, cell.top, cx, cell.bottom);
      return true;
    case 0x2590:
      fill(cx, cell.top, cell.right, cell.bottom);
      return true;
    case 0x2591:
      fill(cell.left, cell.top, cell.right, cell.bottom, 0.25);
      return true;
    case 0x2592:
      fill(cell.left, cell.top, cell.right, cell.bottom, 0.5);
      return true;
    case 0x2593:
      fill(cell.left, cell.top, cell.right, cell.bottom, 0.75);
      return true;
  }
  final arms = _arms[rune];
  if (arms == null) return false;

  final thin = math.max(_snap(math.max(1.0, cell.width / 8), dpr), 1 / dpr);
  // Width of one stroke and the half extent of an arm across its axis.
  double stroke(int w) => w == _h ? thin * 2 : thin;
  double half(int w) => w == _d ? thin * 1.5 : stroke(w) / 2;

  // Centre of the glyph, snapped so strokes land on device pixels.
  final ox = _snap(cx - thin / 2, dpr) + thin / 2;
  final oy = _snap(cy - thin / 2, dpr) + thin / 2;

  // Draws the arm in direction d (0 left, 1 right, 2 up, 3 down).
  void arm(int d) {
    final w = arms[d];
    if (w == 0) return;
    final horiz = d < 2;
    final sign = d.isEven ? -1.0 : 1.0;
    final perpA = horiz ? 2 : 0, perpB = horiz ? 3 : 1; // arms across this axis
    final opposite = arms[d ^ 1] != 0;
    final pw = math.max(arms[perpA], arms[perpB]);
    final hasPerp = pw != 0;
    final centre = horiz ? ox : oy;
    final across = horiz ? oy : ox;
    final far = horiz ? (sign < 0 ? cell.left : cell.right) : (sign < 0 ? cell.top : cell.bottom);

    // Spans along the axis from `from` to the cell edge, and across by [o - s/2, o + s/2].
    void rect(double from, double o, double s) {
      final a = math.min(from, far), b = math.max(from, far);
      if (horiz) {
        fill(a, across + o - s / 2, b, across + o + s / 2);
      } else {
        fill(across + o - s / 2, a, across + o + s / 2, b);
      }
    }

    if (w != _d) {
      // Overshoot the centre by the perpendicular half width to close corners.
      final back = (!opposite && hasPerp) ? -sign * half(pw) : 0.0;
      rect(centre + back, 0, stroke(w));
      return;
    }
    // Double: two strokes at +-thin from the centre line.
    for (final o in [-thin, thin]) {
      // o is across the axis; is there a perpendicular arm on that side?
      final sideArm = arms[o < 0 ? perpA : perpB];
      final otherArm = arms[o < 0 ? perpB : perpA];
      double from;
      if (sideArm != 0) {
        from = centre + sign * thin / 2; // stop at the inner edge of the crossing stroke
      } else if (!opposite && otherArm != 0) {
        from = centre - sign * thin * 1.5; // close the outer corner
      } else {
        from = centre;
      }
      rect(from, o, thin);
    }
  }

  for (var d = 0; d < 4; d++) {
    arm(d);
  }
  return true;
}
