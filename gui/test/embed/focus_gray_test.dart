import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/focus_gray.dart';
import 'package:rapp/embed/picture.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  test('lumaFilter is the 77/150/29 luma on all three rows', () {
    expect(lumaFilter, const ColorFilter.matrix(<double>[
      77 / 256, 150 / 256, 29 / 256, 0, 0, //
      77 / 256, 150 / 256, 29 / 256, 0, 0,
      77 / 256, 150 / 256, 29 / 256, 0, 0,
      0, 0, 0, 1, 0,
    ]));
  });

  test('the clipper keeps what is outside the rects, drops what is inside, overlaps included', () {
    final c = OutsideClipper(const [Rect.fromLTWH(10, 10, 40, 40), Rect.fromLTWH(30, 30, 40, 40)]);
    final p = c.getClip(const Size(100, 100));
    expect(p.contains(const Offset(5, 5)), isTrue);
    expect(p.contains(const Offset(90, 90)), isTrue);
    expect(p.contains(const Offset(20, 20)), isFalse);
    expect(p.contains(const Offset(60, 60)), isFalse);
    expect(p.contains(const Offset(40, 40)), isFalse); // the overlap stays colour
    expect(c.shouldReclip(OutsideClipper(const [Rect.fromLTWH(10, 10, 40, 40), Rect.fromLTWH(30, 30, 40, 40)])), isFalse);
    expect(c.shouldReclip(OutsideClipper(const [Rect.fromLTWH(10, 10, 40, 40)])), isTrue);
  });

  group('on the Picture', () {
    late MainState es;
    late RemoteSession rs;
    late Directory tmp;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('focus_gray_test');
      final t = FakeTransport();
      es = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort());
      rs = RemoteSession(1, 'Safari')..focusWanted = true;
    });
    tearDown(() {
      rs.dispose();
      es.dispose();
      tmp.deleteSync(recursive: true);
    });

    RemoteWindow win({ui.Image? image}) => RemoteWindow(
          id: 5,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w',
          rect: const Rect.fromLTWH(0, 0, 400, 328), // content 400x300
          titleBar: 28,
          resizable: true,
          focused: true,
          texture: image == null ? 42 : null,
          image: image,
          source: image == null ? null : const Rect.fromLTWH(0, 0, 4, 3),
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    Future<void> show(WidgetTester tester, RemoteWindow w) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Picture(state: es, session: rs, window: w))));
      await tester.pump();
    }

    void focusEvent(int window, List<Rect> rects) => rs.apply(FocusRegionEvent(1, window, rects));

    final gray = find.byKey(const Key('focus-gray'));

    Future<void> checks(WidgetTester tester, RemoteWindow w) async {
      await show(tester, w);
      expect(gray, findsNothing);
      // A's rect (0,28)-(200,178) is the top-left quarter-ish of the content; the picture is 800x600.
      focusEvent(5, const [Rect.fromLTWH(0, 28, 200, 150)]);
      await tester.pump();
      expect(gray, findsOneWidget);
      expect(tester.getRect(gray), const Rect.fromLTWH(0, 0, 800, 600)); // over the picture
      final clip = tester.widget<ClipPath>(find.descendant(of: gray, matching: find.byType(ClipPath)));
      final p = clip.clipper!.getClip(const Size(800, 600));
      expect(p.contains(const Offset(100, 100)), isFalse); // inside the rect, local (0,0)-(400,300)
      expect(p.contains(const Offset(600, 500)), isTrue);
      expect(find.descendant(of: gray, matching: find.byType(BackdropFilter)), findsOneWidget);
      // Above the surface: the gray comes after it in the stack.
      final surface = w.image != null
          ? find.descendant(
              of: find.byType(Picture),
              matching: find.byWidgetPredicate((x) => x is CustomPaint && x.painter.runtimeType.toString() == '_FramePainter'))
          : find.descendant(of: find.byType(Picture), matching: find.byType(Texture));
      expect(surface, findsOneWidget);
      final all = tester.allWidgets.toList();
      expect(all.indexOf(tester.widget(gray)), greaterThan(all.indexOf(tester.widget(surface))));

      focusEvent(5, const []);
      await tester.pump();
      expect(gray, findsNothing);
      focusEvent(9, const [Rect.fromLTWH(0, 28, 200, 150)]);
      await tester.pump();
      expect(gray, findsNothing);
      focusEvent(0, const []);
      await tester.pump();
      expect(gray, findsNothing);
      focusEvent(5, const [Rect.fromLTWH(0, 28, 200, 150)]);
      await tester.pump();
      expect(gray, findsOneWidget);
      rs.clearFocus();
      await tester.pump();
      expect(gray, findsNothing);
    }

    testWidgets('texture window', (tester) async {
      await checks(tester, win());
    });

    testWidgets('image window', (tester) async {
      final img = await tester.runAsync(() async {
        final rec = ui.PictureRecorder();
        Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 4, 3), Paint());
        return rec.endRecording().toImage(4, 3);
      });
      await checks(tester, win(image: img));
    });
  });
}
