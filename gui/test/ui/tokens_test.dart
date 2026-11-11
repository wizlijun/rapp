import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/tokens.dart';

void main() {
  test('MATRIX token values match the design language table', () {
    final t = tokensFor(RappTheme.matrix);
    expect(t.bg, const Color(0xFF020A04));
    expect(t.panel, [const Color(0xFF041208)]);
    expect(t.line, const Color(0xFF176A33));
    expect(t.text, const Color(0xFF7DFF9E));
    expect(t.accent, const Color(0xFFF2FFF5));
    expect(t.accentInk, const Color(0xFF02240C));
    expect(t.tint, const Color.fromRGBO(125, 255, 158, .17));
    expect(t.r, 0);
    expect(t.monoBody, isTrue);
  });
  test('AVATAR panel and raise are vertical two-stop gradients', () {
    final t = tokensFor(RappTheme.avatar);
    expect(t.panel, [
      const Color.fromRGBO(255, 255, 255, .035),
      const Color.fromRGBO(255, 255, 255, .01),
    ]);
    expect(t.raise, [
      const Color.fromRGBO(150, 225, 255, .14),
      const Color.fromRGBO(150, 225, 255, .07),
    ]);
    expect(t.r, 4);
  });
  test('IRON MAN and WESTWORLD values match the table', () {
    final i = tokensFor(RappTheme.ironMan);
    expect(i.bg, const Color(0xFF030A12));
    expect(i.text, const Color(0xFFD9F3FF));
    expect(i.accent, const Color(0xFFFF5A3C));
    expect(i.r, 2);
    final w = tokensFor(RappTheme.westworld);
    expect(w.bg, const Color(0xFF070707));
    expect(w.text, const Color(0xFFF4F4F2));
    expect(w.accent, const Color(0xFFFF3B30));
    expect(w.r, 2);
  });
  test('every theme has an opaque bg, a lamp glow, and sane flags', () {
    for (final th in RappTheme.values) {
      final t = tokensFor(th);
      expect(t.bg.a, 1.0, reason: '$th');
      expect(t.glow, isNotEmpty, reason: '$th');
      expect(t.monoBody, th == RappTheme.matrix, reason: '$th');
      expect(
        t.textGlow.isNotEmpty,
        th == RappTheme.matrix || th == RappTheme.ironMan,
        reason: '$th',
      );
      expect(
        t.labelSpacing,
        (th == RappTheme.ironMan || th == RappTheme.westworld) ? 0.12 : 0.06,
        reason: '$th',
      );
    }
  });
  test('dropdown order and labels', () {
    expect(themeOrder.map(themeLabel), [
      'AVATAR',
      'IRON MAN',
      'MATRIX',
      'WESTWORLD',
    ]);
  });
  test('themeDataFor carries the tokens and 48px buttons', () {
    final d = themeDataFor(RappTheme.westworld);
    expect(d.extension<RappTokens>()!.accent, const Color(0xFFFF3B30));
    expect(d.filledButtonTheme.style!.minimumSize!.resolve({})!.height, 48);
    expect(d.textButtonTheme.style!.minimumSize!.resolve({})!.height, 48);
    expect(d.colorScheme.surface, const Color(0xFF070707));
  });
  test('panelBox uses a gradient for two stops and a solid for one', () {
    final a = tokensFor(RappTheme.avatar).panelBox();
    expect(a.gradient, isA<LinearGradient>());
    final m = tokensFor(RappTheme.matrix).panelBox();
    expect(m.color, const Color(0xFF041208));
    expect(m.gradient, isNull);
    expect(m.borderRadius, BorderRadius.circular(0));
  });
}
