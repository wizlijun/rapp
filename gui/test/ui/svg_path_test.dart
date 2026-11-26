import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/svg_path.dart';

void main() {
  bool inside(Path p, double x, double y) => p.contains(Offset(x, y));

  test('absolute square with H/V and close', () {
    final p = parseSvgPath('M0,0H10V10H0Z');
    expect(p.getBounds(), const Rect.fromLTRB(0, 0, 10, 10));
    expect(inside(p, 5, 5), isTrue);
  });

  test('relative commands, implicit lineto after m, and a repeated m', () {
    // m 2 2 then implicit relative lineto pairs; second subpath with lowercase m after z.
    final p = parseSvgPath('m2 2 4 0 0 4-4 0zm10 0h4v4h-4z');
    expect(p.getBounds(), const Rect.fromLTRB(2, 2, 16, 6));
    expect(inside(p, 4, 4), isTrue);
    expect(inside(p, 8, 4), isFalse);
    expect(inside(p, 14, 4), isTrue);
  });

  test('numbers packed the way minifiers write them', () {
    // "1.5.5" is 1.5 then .5; "-.5" after a digit starts a new number.
    final p = parseSvgPath('M0 0L1.5.5l-.5-.5 10 10');
    expect(p.getBounds(), const Rect.fromLTRB(0, 0, 11, 10));
  });

  test('cubic and smooth cubic reflect the control point', () {
    final c = parseSvgPath('M0 10C0 0 10 0 10 10S20 20 20 10Z');
    final b = c.getBounds();
    expect(b.left, 0);
    expect(b.right, 20);
    expect(b.top, lessThan(5));
    expect(b.bottom, greaterThan(15));
  });

  test('quadratic and smooth quadratic', () {
    final p = parseSvgPath('M0 10Q5 0 10 10T20 10Z');
    final b = p.getBounds();
    expect(b.top, lessThan(10));
    expect(b.bottom, greaterThan(10));
  });

  test('arcs, with flags packed against the next number', () {
    // A half disc of radius 5 above y=5, written with packed flags "0 01".
    final p = parseSvgPath('M0 5a5 5 0 0110 0z');
    final b = p.getBounds();
    expect(b.left, closeTo(0, .01));
    expect(b.right, closeTo(10, .01));
    expect(b.top, closeTo(0, .05));
    expect(inside(p, 5, 2), isTrue);
    expect(inside(p, 5, 7), isFalse);
  });

  test('a bad path throws instead of drawing half', () {
    expect(() => parseSvgPath('M0 0 X 4'), throwsFormatException);
    expect(() => parseSvgPath('M0'), throwsFormatException);
  });
}
