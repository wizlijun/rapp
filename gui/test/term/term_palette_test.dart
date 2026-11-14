import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/term_palette.dart';
import 'package:rapp/ui/tokens.dart';

void main() {
  for (final theme in RappTheme.values) {
    test('base colours 1–14 read on the $theme background', () {
      final t = tokensFor(theme);
      final p = termPaletteFor(theme, t);
      expect(p.base16, hasLength(16));
      for (var i = 1; i <= 14; i++) {
        expect(contrastRatio(p.base16[i], t.bg), greaterThanOrEqualTo(4.5), reason: 'colour $i');
      }
      expect((p.resolve(-1, foreground: true), p.resolve(-1, foreground: false)), (t.text, t.bg));
    });
  }

  test('the 256 table', () {
    final p = termPaletteFor(RappTheme.matrix, tokensFor(RappTheme.matrix));
    expect(p.index(196), const Color(0xFFFF0000));
    expect(p.index(232), const Color(0xFF080808));
    expect(p.index(255), const Color(0xFFEEEEEE));
    expect(p.index(16), const Color(0xFF000000));
    expect(p.index(231), const Color(0xFFFFFFFF));
    expect(p.index(4), p.base16[4]);
    expect(p.resolve(5, foreground: false), p.base16[5]);
    expect(p.resolve(0x1000000 | 0x102030, foreground: true), const Color(0xFF102030));
  });

  test('contrastRatio is the WCAG ratio', () {
    expect(contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.001));
    expect(contrastRatio(const Color(0xFF777777), const Color(0xFF777777)), closeTo(1, 0.001));
  });
}
