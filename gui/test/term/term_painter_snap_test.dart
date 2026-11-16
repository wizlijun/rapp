import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/term_layout.dart';
import 'package:rapp/term/term_model.dart';
import 'package:rapp/term/term_painter.dart';
import 'package:rapp/term/term_palette.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/tokens.dart';

void main() {
  late TermMetrics metrics;
  late TermPalette palette;
  late TermModel model;

  setUp(() {
    final tokens = themeDataFor(RappTheme.matrix).extension<RappTokens>()!;
    metrics = TermMetrics.measure(termTextStyle(tokens));
    palette = termPaletteFor(RappTheme.matrix, tokens);
    model = TermModel()..expect('%1');
    model.apply(TermScreen(
      pane: '%1',
      rev: 1,
      cols: 10,
      rows: 4,
      cx: 0,
      cy: 0,
      cursor: false,
      alt: false,
      full: true,
      more: false,
      lines: [for (var i = 0; i < 4; i++) (i, 'abcdefghij')],
    ));
  });

  TermPainter make(TermRowCache cache, {required double dpr, required double scale}) => TermPainter(
        model: model,
        metrics: metrics,
        palette: palette,
        cache: cache,
        version: 1,
        dpr: dpr,
        scale: scale,
        focused: false,
      );

  testWidgets('the row pictures are recorded again when the scale changes the pixel ratio', (t) async {
    final cache = TermRowCache();
    void paint(double scale) {
      final rec = ui.PictureRecorder();
      make(cache, dpr: 2, scale: scale).paint(ui.Canvas(rec), const Size(400, 400));
      rec.endRecording().dispose();
    }

    paint(1);
    expect(cache.recorded, 4);
    paint(1);
    expect(cache.recorded, 4);
    paint(2);
    expect(cache.recorded, 8);
    cache.dispose();
  });

  test('snapping is to the device pixels of the scaled drawing', () {
    final cache = TermRowCache();
    expect(make(cache, dpr: 2, scale: 1).snapRatio, 2);
    expect(make(cache, dpr: 2, scale: 2).snapRatio, 4);
    expect(make(cache, dpr: 1, scale: 1.5).snapRatio, 1.5);
    cache.dispose();
  });

  test('a changed scale or pixel ratio repaints even when the version is the same', () {
    final cache = TermRowCache();
    final a = make(cache, dpr: 2, scale: 1);
    expect(a.shouldRepaint(make(cache, dpr: 2, scale: 1)), isFalse);
    expect(a.shouldRepaint(make(cache, dpr: 2, scale: 2)), isTrue);
    expect(a.shouldRepaint(make(cache, dpr: 1, scale: 1)), isTrue);
    cache.dispose();
  });
}
