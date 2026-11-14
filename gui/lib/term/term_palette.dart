import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../ui/tokens.dart';

double _lin(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) => 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

/// WCAG contrast ratio, 1..21.
double contrastRatio(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Moves [c] towards white (dark [bg]) or black (light [bg]) until it reads on [bg] at [minRatio].
Color _readable(Color c, Color bg, [double minRatio = 4.5]) {
  final toward = _luminance(bg) < 0.5 ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  for (var i = 0; i <= 100 && contrastRatio(c, bg) < minRatio; i++) {
    c = Color.lerp(c, toward, 0.04)!;
  }
  return c;
}

/// Colours 0–15 start from the prototype's sample set (red #FF7B72 ... cyan #56D4DD; bright ones
/// are lighter), then [termPaletteFor] adjusts 1–14 to 4.5:1 on the theme background.
const _normal = [
  Color(0xFF2B3036), // 0 black-ish
  Color(0xFFFF7B72), // 1 red
  Color(0xFF56D364), // 2 green
  Color(0xFFE3B341), // 3 yellow
  Color(0xFF79C0FF), // 4 blue
  Color(0xFFD2A8FF), // 5 magenta
  Color(0xFF56D4DD), // 6 cyan
  Color(0xFFC9D1D9), // 7 light grey
];
const _bright = [
  Color(0xFF6E7681), // 8 dark grey
  Color(0xFFFFA198), // 9
  Color(0xFF7EE787), // 10
  Color(0xFFF2CC60), // 11
  Color(0xFFA5D6FF), // 12
  Color(0xFFE2C5FF), // 13
  Color(0xFF8BE9F0), // 14
  Color(0xFFF0F6FC), // 15 white-ish
];

/// Resolves the colour codes of the cell parser (`sgr.dart`): -1 default, 0–255 palette,
/// `0x1000000 | rgb` truecolor.
class TermPalette {
  TermPalette({required this.fg, required this.bg, required this.base16}) : _table = _build(base16);

  final Color fg, bg;
  final List<Color> base16;
  final List<Color> _table;

  static const _steps = [0, 95, 135, 175, 215, 255];

  static List<Color> _build(List<Color> base) {
    return [
      ...base,
      for (var i = 0; i < 216; i++)
        Color.fromARGB(255, _steps[i ~/ 36], _steps[i ~/ 6 % 6], _steps[i % 6]),
      for (var i = 0; i < 24; i++) Color.fromARGB(255, 8 + 10 * i, 8 + 10 * i, 8 + 10 * i),
    ];
  }

  Color index(int n) => _table[n];

  Color resolve(int code, {required bool foreground}) {
    if (code < 0) return foreground ? fg : bg;
    if (code & 0x1000000 != 0) return Color(0xFF000000 | (code & 0xFFFFFF));
    return _table[code & 0xFF];
  }
}

TermPalette termPaletteFor(RappTheme theme, RappTokens t) {
  // Every theme is dark today; _readable also handles a light background (darkens).
  final base = [..._normal, ..._bright];
  return TermPalette(
    fg: t.text,
    bg: t.bg,
    base16: [
      for (var i = 0; i < 16; i++) i == 0 || i == 15 ? base[i] : _readable(base[i], t.bg),
    ],
  );
}
