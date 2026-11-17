import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/sgr.dart';
import 'package:rapp/term/term_layout.dart';

Future<ByteData> render(int rune, {int w = 10, int h = 20}) async {
  final rec = PictureRecorder();
  final c = Canvas(rec);
  final ok = drawBoxChar(c, rune, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Colors.white);
  expect(ok, isTrue);
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData())!;
}

bool lit(ByteData d, int x, int y, {int w = 10}) => d.getUint8((y * w + x) * 4 + 3) > 200;

void main() {
  test('a mixed row is laid out by column', () {
    final runs = layoutRow(parseRow('中文ab│x'));
    expect(runs.map((r) => (r.col, r.cols, r.text, r.kind)).toList(), [
      (0, 2, '中', GlyphKind.single),
      (2, 2, '文', GlyphKind.single),
      (4, 2, 'ab', GlyphKind.run),
      (6, 1, '│', GlyphKind.box),
      (7, 1, 'x', GlyphKind.run),
    ]);
  });
  test('a style change splits a run', () {
    expect(layoutRow(parseRow('ab\x1b[31mcd')).map((r) => r.text).toList(), ['ab', 'cd']);
  });
  test('metrics: width not rounded, height rounded up', () {
    final m = TermMetrics.measure(const TextStyle(fontSize: 13.3, fontFamily: 'Roboto'));
    expect(m.cellH, m.cellH.ceilToDouble());
    expect(m.cellW, greaterThan(0));
  });
  test('gridScale fits the grid, up only when asked', () {
    expect(gridScale(w: 400, h: 200, gridW: 100, gridH: 100, up: true), 2);
    expect(gridScale(w: 400, h: 200, gridW: 100, gridH: 100, up: false), 1);
    expect(gridScale(w: 50, h: 200, gridW: 100, gridH: 100, up: false), 0.5);
    expect(gridScale(w: 0, h: 200, gridW: 100, gridH: 100, up: true), 1);
    expect(gridScale(w: 400, h: 0, gridW: 100, gridH: 100, up: true), 1);
    expect(gridScale(w: 400, h: 200, gridW: 0, gridH: 100, up: true), 1);
    expect(gridScale(w: 400, h: 200, gridW: 100, gridH: 0, up: true), 1);
  });
  testWidgets('box lines reach the cell edges', (t) async {
    await t.runAsync(() async {
      final h = await render(0x2500);
      expect(lit(h, 0, 10), isTrue);
      expect(lit(h, 9, 10), isTrue);
      expect(lit(h, 5, 0), isFalse);
      final v = await render(0x2502);
      expect(lit(v, 5, 0), isTrue);
      expect(lit(v, 5, 19), isTrue);
      expect(lit(v, 0, 10), isFalse);
      final corner = await render(0x250C);
      expect(lit(corner, 9, 10), isTrue);
      expect(lit(corner, 5, 19), isTrue);
      expect(lit(corner, 0, 10), isFalse);
      expect(lit(corner, 5, 0), isFalse);
      final dbl = await render(0x2550);
      expect(lit(dbl, 0, 9), isTrue);
      expect(lit(dbl, 9, 11), isTrue);
      expect(lit(dbl, 5, 10), isFalse);
    });
  });
  test('unknown box runes fall back to the font', () {
    expect(drawBoxChar(Canvas(PictureRecorder()), 0x2571, const Rect.fromLTWH(0, 0, 10, 20), Colors.white), isFalse);
  });
  test('every advertised rune is drawn', () {
    for (final r in [...'─│┌┐└┘├┤┬┴┼━┃┏┓┗┛┣┫┳┻╋═║╔╗╚╝╠╣╦╩╬╭╮╯╰┄┆┈┊▀▄█▌▐░▒▓'.runes]) {
      expect(drawBoxChar(Canvas(PictureRecorder()), r, const Rect.fromLTWH(0, 0, 10, 20), Colors.white), isTrue,
          reason: r.toRadixString(16));
    }
  });
}
