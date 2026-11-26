import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/device_os.dart';
import 'package:rapp/ui/os_mark.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';

void main() {
  testWidgets('every mark paints at the lamp box size in the muted colour, words on hover', (tester) async {
    for (final theme in RappTheme.values) {
      for (final os in DeviceOs.values) {
        await tester.pumpWidget(wrap(OsMark(os), theme: theme));
        await tester.pumpAndSettle(); // MaterialApp eases from the last theme's colours
        expect(tester.takeException(), isNull, reason: '$theme $os');
        final paint = tester.widget<CustomPaint>(find.byKey(const Key('os-mark-paint')));
        final p = paint.painter! as OsMarkPainter;
        expect((p.os, p.color), (os, tokensFor(theme).muted), reason: '$theme $os');
        expect(tester.getSize(find.byKey(const Key('os-mark-paint'))), const Size.square(13));
        expect(find.byTooltip(osWord(os)), findsOneWidget);
      }
    }
  });

  // A look at the marks for the user: RAPP_OS_SHEET=<dir> writes os-marks.png (big) and os-marks-actual.png.
  final sheet = Platform.environment['RAPP_OS_SHEET'];
  testWidgets('sheet', skip: sheet == null, (tester) async {
    for (final (name, size, pixelRatio) in [('os-marks.png', 40.0, 2.0), ('os-marks-actual.png', 10.0, 2.0)]) {
      final key = GlobalKey();
      await tester.binding.setSurfaceSize(const Size(1400, 800));
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final theme in RappTheme.values)
                Container(
                  color: tokensFor(theme).bg,
                  padding: EdgeInsets.all(size / 2),
                  child: Theme(
                    data: themeDataFor(theme),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      for (final os in DeviceOs.values)
                        Padding(padding: EdgeInsets.symmetric(horizontal: size / 2), child: OsMark(os, size: size)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ));
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: pixelRatio);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$sheet/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
    await tester.binding.setSurfaceSize(null);
  });
}
