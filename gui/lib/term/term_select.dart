import 'sgr.dart';

class TermPoint {
  const TermPoint(this.y, this.x); // x is a column
  final int y, x;
}

class TermSelection {
  TermSelection(
    this.anchor,
    this.head, {
    this.block = false,
    required this.snapshot,
  });
  final TermPoint anchor;
  TermPoint head;
  final bool block; // rectangle dragged with option
  final Map<int, String> snapshot; // plain text of each selected row when made
}

typedef LineAt = TermLine? Function(int y);
typedef WrappedAt = bool Function(int y);

String _text(TermLine? l) => l == null ? '' : l.cells.map((c) => c.ch).join();

bool _before(TermPoint a, TermPoint b) => a.y != b.y ? a.y < b.y : a.x <= b.x;

/// Endpoints are inclusive columns; the earlier point becomes the anchor.
TermSelection select(
  TermPoint a,
  TermPoint b,
  LineAt line, {
  bool block = false,
}) {
  final first = _before(a, b) ? a : b;
  final last = identical(first, a) ? b : a;
  return TermSelection(
    first,
    last,
    block: block,
    snapshot: {for (var y = first.y; y <= last.y; y++) y: _text(line(y))},
  );
}

/// Moves the selection up by [d] rows; null if any row's text changed (C4).
TermSelection? shifted(TermSelection s, int d, LineAt line) {
  final snap = <int, String>{};
  for (final e in s.snapshot.entries) {
    if (_text(line(e.key - d)) != e.value) return null;
    snap[e.key - d] = e.value;
  }
  return TermSelection(
    TermPoint(s.anchor.y - d, s.anchor.x),
    TermPoint(s.head.y - d, s.head.x),
    block: s.block,
    snapshot: snap,
  );
}

/// Text of the cells touching columns [c0, c1]; a wide cell counts if either
/// of its columns is inside.
String _slice(TermLine? l, int c0, int c1) {
  if (l == null) return '';
  final b = StringBuffer();
  var col = 0;
  for (final c in l.cells) {
    if (col > c1) break;
    if (col + c.width - 1 >= c0) b.write(c.ch);
    col += c.width;
  }
  return b.toString();
}

String _trimRight(String s) => s.replaceFirst(RegExp(r' +$'), '');

String selectionText(TermSelection s, LineAt line, WrappedAt wrapped) {
  final a = s.anchor, h = s.head;
  final out = StringBuffer();
  const big = 1 << 30;
  final bc0 = a.x < h.x ? a.x : h.x, bc1 = a.x < h.x ? h.x : a.x;
  for (var y = a.y; y <= h.y; y++) {
    final int c0, c1;
    if (s.block) {
      c0 = bc0;
      c1 = bc1;
    } else {
      c0 = y == a.y ? a.x : 0;
      c1 = y == h.y ? h.x : big;
    }
    final t = _slice(line(y), c0, c1);
    if (!s.block && wrapped(y) && y != h.y) {
      out.write(t);
    } else {
      out.write(_trimRight(t));
      if (y != h.y) out.write('\n');
    }
  }
  return out.toString();
}

int selectedChars(String text) => text.replaceAll('\n', '').runes.length;

const _nonWord = '"\'`()[]{}<>|│┃';

bool _isWordCell(TermCell c) =>
    c.ch.trim().isNotEmpty && !_nonWord.contains(c.ch);

/// [start, end) columns of the word at column [x].
(int, int) wordAt(TermLine line, int x) {
  var col = 0;
  var i = 0;
  final cells = line.cells;
  while (i < cells.length && col + cells[i].width <= x) {
    col += cells[i].width;
    i++;
  }
  if (i >= cells.length) return (x, x + 1);
  if (!_isWordCell(cells[i])) return (col, col + cells[i].width);
  var j = i, start = col, end = col + cells[i].width;
  while (j > 0 && _isWordCell(cells[j - 1])) {
    j--;
    start -= cells[j].width;
  }
  for (var k = i + 1; k < cells.length && _isWordCell(cells[k]); k++) {
    end += cells[k].width;
  }
  return (start, end);
}

(int, int) _wrapRange(int y, WrappedAt wrapped) {
  var top = y, bottom = y;
  while (wrapped(top - 1)) {
    top--;
  }
  while (wrapped(bottom)) {
    bottom++;
  }
  return (top, bottom);
}

/// Triple click: the whole line including its wrapped continuation rows.
(TermPoint, TermPoint) lineAtPoint(int y, WrappedAt wrapped, LineAt line) {
  final (top, bottom) = _wrapRange(y, wrapped);
  final cols = line(bottom)?.columns ?? 0;
  return (TermPoint(top, 0), TermPoint(bottom, cols > 0 ? cols - 1 : 0));
}

class LinkSpan {
  const LinkSpan(this.y, this.x0, this.x1, this.url);
  final int y, x0, x1; // [x0, x1) columns
  final String url;
}

final _url = RegExp(
  r'https?://[^\s<>"'
  "'"
  r'`]+',
);

int _count(String s, String ch) => ch.allMatches(s).length;

List<LinkSpan> linksIn(int fromY, int toY, LineAt line, WrappedAt wrapped) {
  final out = <LinkSpan>[];
  var y = _wrapRange(fromY, wrapped).$1;
  while (y <= toY) {
    final (_, bottom) = _wrapRange(y, wrapped);
    // Join the logical line, remembering each UTF-16 unit's row and columns.
    final buf = StringBuffer();
    final rowOf = <int>[], colOf = <int>[], widthOf = <int>[];
    for (var r = y; r <= bottom; r++) {
      var col = 0;
      for (final c in line(r)?.cells ?? const <TermCell>[]) {
        for (var k = 0; k < c.ch.length; k++) {
          rowOf.add(r);
          colOf.add(col);
          widthOf.add(c.width);
        }
        buf.write(c.ch);
        col += c.width;
      }
    }
    final text = buf.toString();
    for (final m in _url.allMatches(text)) {
      var end = m.end;
      while (end > m.start) {
        final u = text.substring(m.start, end);
        final last = u[u.length - 1];
        if ('.,;:!?'.contains(last) ||
            (last == ')' && _count(u, ')') > _count(u, '('))) {
          end--;
        } else {
          break;
        }
      }
      final url = text.substring(m.start, end);
      var i = m.start;
      while (i < end) {
        final r = rowOf[i];
        var j = i;
        while (j + 1 < end && rowOf[j + 1] == r) {
          j++;
        }
        if (r >= fromY && r <= toY) {
          out.add(LinkSpan(r, colOf[i], colOf[j] + widthOf[j], url));
        }
        i = j + 1;
      }
    }
    y = bottom + 1;
  }
  return out;
}
