// A one-off speed check, not part of the normal run: RAPP_PERF=1 flutter test test/term/term_paint_perf_test.dart
@Tags(['perf'])
library;

import 'dart:io';
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

const cols = 200, rows = 60, frames = 120, changed = 5;

/// A full row of coloured words, different for every [seed].
String row(int seed) {
  final b = StringBuffer();
  var n = 0;
  for (var w = 0; n < cols; w++) {
    final word = 'w${seed}_$w ';
    final take = word.length > cols - n ? cols - n : word.length;
    b.write('\x1b[${31 + (seed + w) % 7}m${word.substring(0, take)}');
    n += take;
  }
  return '$b\x1b[0m';
}

TermScreen screen(int rev, Map<int, String> lines, {bool full = false}) => TermScreen(
      pane: '%1',
      rev: rev,
      cols: cols,
      rows: rows,
      cx: 0,
      cy: rows - 1,
      cursor: true,
      alt: false,
      full: full,
      more: false,
      lines: [for (final e in lines.entries) (e.key, e.value)],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TermPainter.paint on a full 200×60 screen with 5 rows changing per frame', () {
    final tokens = themeDataFor(RappTheme.matrix).extension<RappTokens>()!;
    final metrics = TermMetrics.measure(termTextStyle(tokens));
    final palette = termPaletteFor(RappTheme.matrix, tokens);
    final model = TermModel()..expect('%1');
    model.apply(screen(1, {for (var i = 0; i < rows; i++) i: row(i)}, full: true));
    final cache = TermRowCache();
    final size = Size(cols * metrics.cellW, rows * metrics.cellH);
    final watch = Stopwatch();
    for (var f = 0; f <= frames; f++) {
      if (f > 0) {
        model.apply(screen(f + 1, {for (var k = 0; k < changed; k++) (f * changed + k) % rows: row(1000 + f * changed + k)}));
      }
      final painter = TermPainter(
          model: model, metrics: metrics, palette: palette, cache: cache, version: f, dpr: 2, focused: true);
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      // Frame 0 records every row; it is not counted.
      if (f > 0) watch.start();
      painter.paint(canvas, size);
      watch.stop();
      rec.endRecording().dispose();
    }
    cache.dispose();
    final avg = watch.elapsedMicroseconds / frames / 1000;
    // ignore: avoid_print
    print('TermPainter.paint: ${avg.toStringAsFixed(3)} ms average over $frames frames '
        '($cols×$rows, $changed rows changed per frame)');
    expect(cache.recorded, rows + frames * changed);
  }, skip: Platform.environment['RAPP_PERF'] == null ? 'set RAPP_PERF=1 to run the speed check' : false);
}
