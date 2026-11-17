// Draws the terminal grid: one recorded picture per row (D6), with the cursor, the selection and the link
// underlines drawn over the rows each frame.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'sgr.dart';
import 'term_layout.dart';
import 'term_model.dart';
import 'term_palette.dart';
import 'term_select.dart';

double _snap(double v, double dpr) => (v * dpr).round() / dpr;

/// The row pictures, keyed by the row object: a changed row is a new [TermLine], so an unchanged row is
/// never recorded twice. Everything is dropped when the cell width, the palette or the pixel ratio changes.
class TermRowCache {
  TermMetrics? _metrics;
  TermPalette? _palette;
  double _dpr = 0;
  double _baseline = 0;
  LinkedHashMap<TermLine, ui.Picture> _pics = LinkedHashMap.identity();
  LinkedHashMap<TermLine, ui.Picture> _next = LinkedHashMap.identity();
  final _styles = <(Color, int), ui.TextStyle>{};
  late ui.ParagraphStyle _para;

  /// Rows recorded so far (D6: only changed rows are).
  @visibleForTesting
  int recorded = 0;

  void _begin(TermMetrics m, TermPalette p, double dpr) {
    final km = _metrics;
    if (km != null && km.cellW == m.cellW && km.cellH == m.cellH && identical(p, _palette) && dpr == _dpr) return;
    _clear();
    _metrics = m;
    _palette = p;
    _dpr = dpr;
    _styles.clear();
    _para = ui.ParagraphStyle(textDirection: ui.TextDirection.ltr, maxLines: 1);
    final probe = _paragraph('M', p.fg, 0);
    _baseline = probe.alphabeticBaseline + (m.cellH - probe.height) / 2;
    probe.dispose();
  }

  ui.Picture _row(TermLine line) {
    final pic = _next[line] ?? _pics.remove(line) ?? _record(line);
    _next[line] = pic;
    return pic;
  }

  /// Drops the pictures of rows not drawn this frame.
  void _end() {
    for (final p in _pics.values) {
      p.dispose();
    }
    _pics.clear();
    final t = _pics;
    _pics = _next;
    _next = t;
  }

  void _clear() {
    for (final p in [..._pics.values, ..._next.values]) {
      p.dispose();
    }
    _pics.clear();
    _next.clear();
  }

  void dispose() => _clear();

  ui.Paragraph _paragraph(String text, Color fg, int flags) {
    final style = _styles.putIfAbsent((fg, flags), () {
      return _metrics!.style
          .copyWith(
            color: fg,
            fontWeight: flags & bold != 0 ? FontWeight.bold : null,
            fontStyle: flags & italic != 0 ? FontStyle.italic : null,
          )
          .getTextStyle();
    });
    final b = ui.ParagraphBuilder(_para)
      ..pushStyle(style)
      ..addText(text);
    return b.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  (Color, Color) _colors(TermStyle s) {
    final p = _palette!;
    var fg = p.resolve(s.fg, foreground: true), bg = p.resolve(s.bg, foreground: false);
    if (s.flags & reverse != 0) (fg, bg) = (bg, fg);
    if (s.flags & dim != 0) fg = Color.lerp(bg, fg, 0.6)!;
    return (fg, bg);
  }

  Rect _cells(int col, int cols) {
    final w = _metrics!.cellW;
    return Rect.fromLTRB(_snap(col * w, _dpr), 0, _snap((col + cols) * w, _dpr), _metrics!.cellH);
  }

  /// Draws one glyph run in [fg] at its columns (row coordinates: the row's top is 0).
  void _glyphs(Canvas c, GlyphRun r, Color fg, int flags) {
    final cell = _cells(r.col, r.cols);
    if (r.kind == GlyphKind.box && drawBoxChar(c, r.text.runes.first, cell, fg, dpr: _dpr)) return;
    if (r.kind == GlyphKind.run && r.text.trim().isEmpty) return;
    final p = _paragraph(r.text, fg, flags);
    // A run is placed by its first column; a single glyph is centred in its cells, so a fallback font's
    // advance never moves it off the grid.
    final x = r.kind == GlyphKind.run ? cell.left : cell.left + (cell.width - p.maxIntrinsicWidth) / 2;
    c.drawParagraph(p, Offset(x, _baseline - p.alphabeticBaseline));
    p.dispose();
  }

  ui.Picture _record(TermLine line) {
    recorded++;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final runs = layoutRow(line);
    final bg0 = _palette!.bg;
    final h = _metrics!.cellH;
    final thick = math.max(1.0, _snap(h / 14, _dpr));
    for (final r in runs) {
      final (_, bg) = _colors(r.style);
      if (bg != bg0) c.drawRect(_cells(r.col, r.cols), Paint()..color = bg);
    }
    for (final r in runs) {
      final (fg, _) = _colors(r.style);
      final f = r.style.flags;
      _glyphs(c, r, fg, f);
      if (f & (underline | strike) != 0) {
        final cell = _cells(r.col, r.cols);
        final paint = Paint()..color = fg;
        if (f & underline != 0) {
          final y = _snap(math.min(_baseline + thick, h - thick), _dpr);
          c.drawRect(Rect.fromLTWH(cell.left, y, cell.width, thick), paint);
        }
        if (f & strike != 0) {
          final y = _snap(h / 2 - thick / 2, _dpr);
          c.drawRect(Rect.fromLTWH(cell.left, y, cell.width, thick), paint);
        }
      }
    }
    return rec.endRecording();
  }
}

/// Paints [model] from the top left at [scale]. Repaints only when [version] changes: the stage bumps it for
/// every model update and every change to what is drawn over the rows.
class TermPainter extends CustomPainter {
  TermPainter({
    required this.model,
    required this.metrics,
    required this.palette,
    required this.cache,
    required this.version,
    this.dpr = 1,
    this.scale = 1,
    this.selection,
    this.links = const [],
    this.focused = false,
    this.waiting = false,
  });

  final TermModel model;
  final TermMetrics metrics;
  final TermPalette palette;
  final TermRowCache cache;
  final int version;
  final double dpr, scale;
  final TermSelection? selection;
  final List<LinkSpan> links;
  final bool focused;

  /// Input went out and no new screen came within 0.3 s (K6): an ellipsis one cell after the cursor.
  final bool waiting;

  /// Device pixels per unit drawn here: drawing is under `canvas.scale(scale)`, so a device pixel is `1 / snapRatio` of
  /// a unit. Everything is snapped to it, and the row pictures are recorded snapped to it.
  @visibleForTesting
  double get snapRatio => dpr * scale;

  /// The line at the top of the view (partly hidden while the offset is fractional).
  int get topY => (-model.offset).floor();

  /// The line drawn at view row [i]; null when blank or not fetched yet.
  TermLine? lineAtRow(int i) => model.lineAt(topY + i);

  double _top(int y) => (y + model.offset) * metrics.cellH;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.bg);
    final m = model;
    if (m.screen.isEmpty) return;
    final ratio = snapRatio;
    cache._begin(metrics, palette, ratio);
    final cw = metrics.cellW, ch = metrics.cellH;
    final gridH = m.rows * ch;
    double snap(double v) => _snap(v, ratio);
    canvas.save();
    if (scale != 1) canvas.scale(scale);
    canvas.clipRect(Rect.fromLTWH(0, 0, m.cols * cw, gridH));
    for (var y = topY; y < m.rows; y++) {
      final top = _top(y);
      if (top >= gridH) break;
      final line = m.lineAt(y);
      if (line == null) continue;
      canvas.save();
      canvas.translate(0, snap(top));
      canvas.drawPicture(cache._row(line));
      canvas.restore();
    }
    cache._end();

    bool visible(int y) {
      final top = _top(y);
      return top > -ch && top < gridH;
    }

    final s = selection;
    if (s != null) {
      final paint = Paint()..color = palette.fg.withValues(alpha: 0.3);
      final b0 = math.min(s.anchor.x, s.head.x), b1 = math.max(s.anchor.x, s.head.x);
      for (var y = math.max(s.anchor.y, topY); y <= s.head.y && y < m.rows; y++) {
        if (_top(y) >= gridH) break;
        final c0 = s.block ? b0 : (y == s.anchor.y ? s.anchor.x : 0);
        final c1 = s.block ? b1 : (y == s.head.y ? s.head.x : m.cols - 1);
        final top = snap(_top(y));
        canvas.drawRect(Rect.fromLTRB(snap(c0 * cw), top, snap((c1 + 1) * cw), top + ch), paint);
      }
    }

    final thick = math.max(1.0, snap(ch / 14));
    for (final l in links) {
      if (!visible(l.y)) continue;
      final y = snap(_top(l.y) + math.min(cache._baseline + thick, ch - thick));
      canvas.drawRect(Rect.fromLTRB(snap(l.x0 * cw), y, snap(l.x1 * cw), y + thick), Paint()..color = palette.fg);
    }

    if (m.cursor && m.cy >= 0 && m.cy < m.rows && visible(m.cy)) _cursor(canvas, snap);
    if (waiting && m.cy >= 0 && m.cy < m.rows && visible(m.cy)) _ellipsis(canvas, snap);
    canvas.restore();
  }

  /// The cell under the cursor, for its width and its glyph; null when none starts there.
  TermCell? _underCursor() {
    final m = model;
    var col = 0;
    for (final c in m.lineAt(m.cy)?.cells ?? const <TermCell>[]) {
      if (col + c.width > m.cx) return col == m.cx ? c : null;
      col += c.width;
    }
    return null;
  }

  /// K6: a muted 「…」 in the cell after the cursor (the last column when the cursor is at the edge).
  void _ellipsis(Canvas canvas, double Function(double) snap) {
    final m = model;
    final x = math.min(m.cx + (_underCursor()?.width ?? 1), m.cols - 1);
    canvas.save();
    canvas.translate(snap(x * metrics.cellW), snap(_top(m.cy)));
    final muted = Color.lerp(palette.bg, palette.fg, 0.6)!;
    cache._glyphs(canvas, const GlyphRun(0, 1, '…', TermStyle(), GlyphKind.single), muted, 0);
    canvas.restore();
  }

  void _cursor(Canvas canvas, double Function(double) snap) {
    final m = model;
    final cw = metrics.cellW, ch = metrics.cellH;
    final under = _underCursor();
    final top = snap(_top(m.cy));
    final r = Rect.fromLTRB(snap(m.cx * cw), top, snap((m.cx + (under?.width ?? 1)) * cw), top + ch);
    final paint = Paint()..color = palette.fg;
    final line = math.max(1.0, snap(2));
    if (!focused) {
      canvas.drawRect(r.deflate(0.5), paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
      return;
    }
    switch (m.shape) {
      case 'bar':
        canvas.drawRect(Rect.fromLTWH(r.left, r.top, line, ch), paint);
      case 'underline':
        canvas.drawRect(Rect.fromLTWH(r.left, r.bottom - line, r.width, line), paint);
      default:
        canvas.drawRect(r, paint);
        final u = under;
        if (u == null || u.ch.trim().isEmpty) return;
        // The glyph under a solid block, in the background colour.
        final g = layoutRow(TermLine([u], u.ch)).first;
        canvas.save();
        canvas.translate(r.left, top);
        cache._glyphs(canvas, GlyphRun(0, u.width, g.text, g.style, g.kind), palette.bg, u.style.flags);
        canvas.restore();
    }
  }

  @override
  bool shouldRepaint(TermPainter old) =>
      old.version != version || old.dpr != dpr || old.scale != scale || !identical(old.metrics, metrics);
}
