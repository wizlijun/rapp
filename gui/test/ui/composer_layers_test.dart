// The layers that float over the remote picture (the composer bar, the closed
// 「输入」 button + transfer strip) must stay readable when the remote app is white.
// The pixel evidence: a really rendered white "picture" (a decoded ui.Image drawn
// by the same _FramePainter a Linux frame takes), the layer's fill composited over
// it, and WCAG contrast — white ink needs a fill of luminance ≤ .183 for 4.5:1.
// The design language fixes the recipe for stage-floating layers: `--bg` 实底、
// `--text` 边框、深色投影; `--panel` is glass on AVATAR and IRON MAN and washes out.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_bar.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import 'helpers.dart';

double _lum(int r, int g, int b) {
  double lin(int v) {
    final c = v / 255;
    return c <= .03928 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();
  }

  return .2126 * lin(r) + .7152 * lin(g) + .0722 * lin(b);
}

/// Mean relative luminance of the pixels in [rect] of [img].
Future<double> meanLum(ui.Image img, Rect rect) async {
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
  final w = img.width;
  var total = 0.0;
  var n = 0;
  for (var y = rect.top.floor(); y < rect.bottom; y++) {
    for (var x = rect.left.floor(); x < rect.right; x++) {
      final o = (y * w + x) * 4;
      total += _lum(data.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2));
      n++;
    }
  }
  return total / n;
}

void main() {
  Future<ui.Image> solidImage() async {
    final p = Uint8List(16);
    for (var i = 0; i < 4; i++) {
      p[i * 4] = 255;
      p[i * 4 + 1] = 255;
      p[i * 4 + 2] = 255;
      p[i * 4 + 3] = 255;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(p);
    final desc = ui.ImageDescriptor.raw(buffer,
        width: 2, height: 2, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await desc.instantiateCodec();
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  for (final theme in RappTheme.values) {
    group('${theme.name} over a white picture', () {
      late FakeTransport t;
      late HubClient hub;
      late FakeSessionPort port;
      late MainState es;
      late Directory tmp;

      Future<void> flush() => Future<void>.delayed(Duration.zero);

      Future<void> openEmbedded(WidgetTester tester) async {
        await tester.runAsync(() async {
          t.onSend = (m) {
            if (m['cmd'] == 'open') {
              t.emit({
                'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
                'port': 5001, 'token': 'tk', 'req': m['req'],
              });
            }
          };
          es.openOrSwitch('111', 'Safari', 'Safari');
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
      }

      setUp(() async {
        tmp = Directory.systemTemp.createTempSync('composer_layers_test');
        t = FakeTransport();
        hub = HubClient(t);
        port = FakeSessionPort();
        es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
        t.emit({
          'event': 'hosts',
          'hosts': [
            {'id': '111', 'name': 'mini'},
          ],
        });
        await flush();
      });

      tearDown(() {
        es.dispose();
        tmp.deleteSync(recursive: true);
      });

      Future<ui.Image> shoot(WidgetTester tester) async =>
          (await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const Key('shoot')));
            return boundary.toImage(pixelRatio: 1);
          }))!;

      Future<void> openStage(WidgetTester tester) async {
        final white = (await tester.runAsync(() => solidImage()))!;
        await tester.pumpWidget(wrap(
          RepaintBoundary(
            key: const Key('shoot'),
            child: SizedBox(width: 800, height: 600, child: Stage(state: es)),
          ),
          theme: theme,
        ));
        await openEmbedded(tester);
        port.emit(const ReadyEvent(1, 'Safari'));
        port.emit(WindowsEvent(1, [
          RemoteWindow(
            id: 5,
            parent: 0,
            kind: WindowKind.normal,
            title: 'w5',
            rect: const Rect.fromLTWH(0, 0, 800, 628),
            titleBar: 28,
            resizable: true,
            focused: true,
            texture: null,
            visible: const Rect.fromLTWH(0, 0, 1, 1),
            image: white,
            source: const Rect.fromLTWH(0, 0, 2, 2),
          ),
        ]));
        await tester.pump();
        await tester.pump();
      }

      testWidgets('the open bar keeps white ink readable on its fill', (tester) async {
        await openStage(tester);
        es.currentRemote!.composer.open = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(ComposerBar), findsOneWidget);

        final shot = await shoot(tester);
        final box = tester.renderObject<RenderBox>(find.byType(ComposerBar));
        final tl = box.localToGlobal(Offset.zero);

        // Sanity: the picture above the bar really is the white app.
        final picture = await tester
            .runAsync(() => meanLum(shot, Rect.fromLTWH(360, tl.dy - 40, 80, 20)));
        expect(picture, greaterThan(.95), reason: 'fixture must paint a white app');

        // The bar's own top padding strip: pure fill, no border, no glyphs. White
        // ink (every theme's --text) needs ≤ .183 here for 4.5:1.
        final fill = await tester
            .runAsync(() => meanLum(shot, Rect.fromLTWH(tl.dx + 20, tl.dy + 3, box.size.width - 40, 4)));
        expect(fill, lessThan(.183), reason: 'bar fill under white ink washes out');
      });

      testWidgets('the closed 「输入」 layer keeps white ink readable', (tester) async {
        await openStage(tester);
        port.emit(const TransferStatusEvent(1, '上传中 3%'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('composer-open')), findsOneWidget);

        final shot = await shoot(tester);
        final box = tester.renderObject<RenderBox>(find.byKey(const Key('composer-open')));
        final tl = box.localToGlobal(Offset.zero);

        // Inside the button, above the label: the fill white ink sits on.
        final fill = await tester
            .runAsync(() => meanLum(shot, Rect.fromLTWH(tl.dx + 6, tl.dy + 4, box.size.width - 12, 4)));
        expect(fill, lessThan(.183), reason: 'closed 「输入」 fill washes out on white');
      });
    });
  }
}
