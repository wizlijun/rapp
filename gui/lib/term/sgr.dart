import 'char_width.dart';

const int bold = 1,
    dim = 2,
    italic = 4,
    underline = 8,
    reverse = 16,
    strike = 32;

/// Colour: -1 default, 0-255 palette, `0x1000000 | rgb` truecolor.
class TermStyle {
  const TermStyle({this.fg = -1, this.bg = -1, this.flags = 0});
  final int fg, bg, flags;

  @override
  bool operator ==(Object other) =>
      other is TermStyle &&
      other.fg == fg &&
      other.bg == bg &&
      other.flags == flags;

  @override
  int get hashCode => Object.hash(fg, bg, flags);
}

class TermCell {
  const TermCell(this.ch, this.width, this.style);
  final String ch;
  final int width;
  final TermStyle style;
}

class TermLine {
  const TermLine(this.cells, this.text);
  final List<TermCell> cells;
  final String text;
  int get columns => cells.fold(0, (n, c) => n + c.width);
}

const _graphics = {
  '_': ' ',
  '`': '◆',
  'a': '▒',
  'b': '␉',
  'c': '␌',
  'd': '␍',
  'e': '␊',
  'f': '°',
  'g': '±',
  'h': '␤',
  'i': '␋',
  'j': '┘',
  'k': '┐',
  'l': '┌',
  'm': '└',
  'n': '┼',
  'o': '⎺',
  'p': '⎻',
  'q': '─',
  'r': '⎼',
  's': '⎽',
  't': '├',
  'u': '┤',
  'v': '┴',
  'w': '┬',
  'x': '│',
  'y': '≤',
  'z': '≥',
  '{': 'π',
  '|': '≠',
  '}': '£',
  '~': '·',
};

TermLine parseRow(String row) {
  final cells = <TermCell>[];
  final text = StringBuffer();
  var style = const TermStyle();
  var graphics = false;
  final n = row.length;
  var i = 0;
  while (i < n) {
    final c = row.codeUnitAt(i);
    if (c == 0x1b) {
      if (i + 1 >= n) break;
      final k = row[i + 1];
      if (k == '[') {
        var j = i + 2;
        while (j < n &&
            (row.codeUnitAt(j) < 0x40 || row.codeUnitAt(j) > 0x7e)) {
          j++;
        }
        if (j >= n) break;
        if (row[j] == 'm') style = _sgr(style, row.substring(i + 2, j));
        i = j + 1;
      } else if (k == ']') {
        var j = i + 2;
        while (j < n &&
            row.codeUnitAt(j) != 0x07 &&
            !(row.codeUnitAt(j) == 0x1b && j + 1 < n && row[j + 1] == '\\')) {
          j++;
        }
        i = j >= n ? n : (row.codeUnitAt(j) == 0x07 ? j + 1 : j + 2);
      } else if (k == '(' || k == ')') {
        i += 3;
      } else {
        i += 2;
      }
      continue;
    }
    if (c == 0x0e || c == 0x0f) {
      graphics = c == 0x0e;
      i++;
      continue;
    }
    if (c < 0x20 || c == 0x7f) {
      i++;
      continue;
    }
    final rune = row.runeAt(i);
    var ch = String.fromCharCode(rune);
    i += ch.length;
    if (graphics) ch = _graphics[ch] ?? ch;
    final w = cellWidth(ch.runes.first);
    text.write(ch);
    if (w == 0 && cells.isNotEmpty) {
      final p = cells.removeLast();
      cells.add(TermCell(p.ch + ch, p.width, p.style));
    } else {
      cells.add(TermCell(ch, w == 0 ? 1 : w, style));
    }
  }
  return TermLine(cells, text.toString());
}

extension on String {
  int runeAt(int i) {
    final u = codeUnitAt(i);
    if (u >= 0xD800 && u < 0xDC00 && i + 1 < length) {
      final l = codeUnitAt(i + 1);
      if (l >= 0xDC00 && l < 0xE000) {
        return 0x10000 + ((u - 0xD800) << 10) + (l - 0xDC00);
      }
    }
    return u;
  }
}

TermStyle _sgr(TermStyle s, String params) {
  var fg = s.fg, bg = s.bg, flags = s.flags;
  // Each parameter is a list of colon-separated sub-values.
  final ps = params.isEmpty
      ? <List<int>>[
          [0],
        ]
      : params
            .split(';')
            .map((p) => p.split(':').map((x) => int.tryParse(x) ?? 0).toList())
            .toList();
  for (var i = 0; i < ps.length; i++) {
    final p = ps[i];
    final v = p[0];
    switch (v) {
      case 0:
        fg = -1;
        bg = -1;
        flags = 0;
      case 1:
        flags |= bold;
      case 2:
        flags |= dim;
      case 3:
        flags |= italic;
      case 4:
        if (p.length > 1 && p[1] == 0) {
          flags &= ~underline;
        } else {
          flags |= underline;
        }
      case 7:
        flags |= reverse;
      case 9:
        flags |= strike;
      case 22:
        flags &= ~(bold | dim);
      case 23:
        flags &= ~italic;
      case 24:
        flags &= ~underline;
      case 27:
        flags &= ~reverse;
      case 29:
        flags &= ~strike;
      case >= 30 && <= 37:
        fg = v - 30;
      case >= 40 && <= 47:
        bg = v - 40;
      case >= 90 && <= 97:
        fg = v - 90 + 8;
      case >= 100 && <= 107:
        bg = v - 100 + 8;
      case 39:
        fg = -1;
      case 49:
        bg = -1;
      case 38 || 48:
        int? color;
        if (p.length > 1) {
          // Colon form: 38:5:n or 38:2:[cs]:r:g:b
          if (p[1] == 5 && p.length > 2) {
            color = p[2] & 0xff;
          } else if (p[1] == 2 && p.length >= 5) {
            final rgb = p.sublist(p.length - 3);
            color =
                0x1000000 |
                ((rgb[0] & 0xff) << 16) |
                ((rgb[1] & 0xff) << 8) |
                (rgb[2] & 0xff);
          }
        } else if (i + 1 < ps.length) {
          final mode = ps[i + 1][0];
          if (mode == 5 && i + 2 < ps.length) {
            color = ps[i + 2][0] & 0xff;
            i += 2;
          } else if (mode == 2 && i + 4 < ps.length) {
            color =
                0x1000000 |
                ((ps[i + 2][0] & 0xff) << 16) |
                ((ps[i + 3][0] & 0xff) << 8) |
                (ps[i + 4][0] & 0xff);
            i += 4;
          } else {
            i = ps.length;
          }
        }
        if (color != null) {
          if (v == 38) {
            fg = color;
          } else {
            bg = color;
          }
        }
    }
  }
  return TermStyle(fg: fg, bg: bg, flags: flags);
}
