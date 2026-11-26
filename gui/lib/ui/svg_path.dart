// SVG path data (the `d` attribute) as a Flutter [Path], so brand marks can be kept exactly as their makers
// publish them instead of being redrawn by hand.
import 'dart:ui';

/// The [Path] that SVG path data [d] describes: every command (M L H V C S Q T A Z, upper case absolute,
/// lower case relative), implicit repeats, and numbers packed the way minifiers write them. Throws
/// [FormatException] on anything else rather than drawing half a mark.
Path parseSvgPath(String d) => _Parser(d).run();

class _Parser {
  _Parser(this.d);
  final String d;
  int i = 0;
  final path = Path();
  double x = 0, y = 0; // current point
  double sx = 0, sy = 0; // start of the subpath
  double cx = 0, cy = 0; // last control point, for S and T
  String last = '';

  Path run() {
    String? cmd;
    while (true) {
      _space();
      if (i >= d.length) break;
      final c = d[i];
      if (_isCommand(c)) {
        cmd = c;
        i++;
      } else if (cmd == null || cmd == 'z' || cmd == 'Z') {
        throw FormatException('path data: number without a command', d, i);
      }
      _one(cmd);
      // After a moveto, more coordinate pairs are linetos of the same case.
      if (cmd == 'M') cmd = 'L';
      if (cmd == 'm') cmd = 'l';
    }
    return path;
  }

  static bool _isCommand(String c) => 'MmLlHhVvCcSsQqTtAaZz'.contains(c);

  void _space() {
    while (i < d.length && (d[i] == ' ' || d[i] == ',' || d[i] == '\n' || d[i] == '\t' || d[i] == '\r')) {
      i++;
    }
  }

  double _num() {
    _space();
    final start = i;
    if (i < d.length && (d[i] == '-' || d[i] == '+')) i++;
    var dot = false, digits = false;
    while (i < d.length) {
      final c = d.codeUnitAt(i);
      if (c >= 48 && c <= 57) {
        digits = true;
        i++;
      } else if (c == 46 && !dot) {
        dot = true;
        i++;
      } else {
        break;
      }
    }
    if (digits && i < d.length && (d[i] == 'e' || d[i] == 'E')) {
      i++;
      if (i < d.length && (d[i] == '-' || d[i] == '+')) i++;
      while (i < d.length && d.codeUnitAt(i) >= 48 && d.codeUnitAt(i) <= 57) {
        i++;
      }
    }
    if (!digits) throw FormatException('path data: number expected', d, start);
    return double.parse(d.substring(start, i));
  }

  /// An arc flag: a single 0 or 1, which may be packed against what follows ("01" is two flags).
  bool _flag() {
    _space();
    if (i < d.length && (d[i] == '0' || d[i] == '1')) return d[i++] == '1';
    throw FormatException('path data: arc flag expected', d, i);
  }

  void _one(String cmd) {
    final rel = cmd == cmd.toLowerCase();
    final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
    var nx = x, ny = y;
    switch (cmd.toUpperCase()) {
      case 'M':
        nx = ox + _num();
        ny = oy + _num();
        path.moveTo(nx, ny);
        sx = nx;
        sy = ny;
      case 'L':
        nx = ox + _num();
        ny = oy + _num();
        path.lineTo(nx, ny);
      case 'H':
        nx = ox + _num();
        path.lineTo(nx, ny);
      case 'V':
        ny = oy + _num();
        path.lineTo(nx, ny);
      case 'C':
        final x1 = ox + _num(), y1 = oy + _num(), x2 = ox + _num(), y2 = oy + _num();
        nx = ox + _num();
        ny = oy + _num();
        path.cubicTo(x1, y1, x2, y2, nx, ny);
        cx = x2;
        cy = y2;
      case 'S':
        final (x1, y1) = 'CcSs'.contains(last) ? (2 * x - cx, 2 * y - cy) : (x, y);
        final x2 = ox + _num(), y2 = oy + _num();
        nx = ox + _num();
        ny = oy + _num();
        path.cubicTo(x1, y1, x2, y2, nx, ny);
        cx = x2;
        cy = y2;
      case 'Q':
        final x1 = ox + _num(), y1 = oy + _num();
        nx = ox + _num();
        ny = oy + _num();
        path.quadraticBezierTo(x1, y1, nx, ny);
        cx = x1;
        cy = y1;
      case 'T':
        final (x1, y1) = 'QqTt'.contains(last) ? (2 * x - cx, 2 * y - cy) : (x, y);
        nx = ox + _num();
        ny = oy + _num();
        path.quadraticBezierTo(x1, y1, nx, ny);
        cx = x1;
        cy = y1;
      case 'A':
        final rx = _num(), ry = _num(), rot = _num();
        final large = _flag(), sweep = _flag();
        nx = ox + _num();
        ny = oy + _num();
        if (rx == 0 || ry == 0) {
          path.lineTo(nx, ny);
        } else {
          path.arcToPoint(Offset(nx, ny),
              radius: Radius.elliptical(rx.abs(), ry.abs()), rotation: rot, largeArc: large, clockwise: sweep);
        }
      case 'Z':
        path.close();
        nx = sx;
        ny = sy;
    }
    x = nx;
    y = ny;
    last = cmd;
  }
}
