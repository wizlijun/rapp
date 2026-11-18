import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/geometry.dart';
import 'package:rapp/embed/zoom_view.dart';

void main() {
  const stage = Size(1000, 700);
  const content = Size(800, 600);
  final fit = fitRect(content, stage);

  group('ZoomView', () {
    test('z 1 is fit', () {
      final v = ZoomView();
      expect(v.z, 1);
      expect(v.zoomed, false);
      expect(v.zfit(fit, stage), fit);
    });

    test('zoomTo clamps to 1-4', () {
      final v = ZoomView();
      v.zoomTo(9, stage.center(Offset.zero), fit, stage);
      expect(v.z, ZoomView.maxZoom);
      v.zoomTo(0.2, stage.center(Offset.zero), fit, stage);
      expect(v.z, 1);
    });

    test('zoomTo keeps the point under the focal', () {
      final v = ZoomView();
      const focal = Offset(300, 200);
      final before = v.zfit(fit, stage);
      final fx = (focal.dx - before.left) / before.width, fy = (focal.dy - before.top) / before.height;
      v.zoomTo(2.5, focal, fit, stage);
      final after = v.zfit(fit, stage);
      expect((focal.dx - after.left) / after.width, closeTo(fx, 1e-6));
      expect((focal.dy - after.top) / after.height, closeTo(fy, 1e-6));
    });

    test('pan stops at the stage edges', () {
      final v = ZoomView()..zoomTo(2, stage.center(Offset.zero), fit, stage);
      v.panBy(const Offset(-9000, -9000), fit, stage);
      var r = v.zfit(fit, stage);
      expect(r.right, stage.width);
      expect(r.bottom, stage.height);
      v.panBy(const Offset(9000, 9000), fit, stage);
      r = v.zfit(fit, stage);
      expect(r.left, 0);
      expect(r.top, 0);
      // Not accumulated on the edge: one step back moves it at once.
      v.panBy(const Offset(-10, 0), fit, stage);
      expect(v.zfit(fit, stage).left, closeTo(-10, 1e-6));
    });

    test('the keyboard lowers the top bound, never moves the view', () {
      final v = ZoomView()..zoomTo(2, stage.center(Offset.zero), fit, stage);
      final plain = v.zfit(fit, stage);
      expect(v.zfit(fit, stage, keyboard: 300), plain);
      v.panBy(const Offset(0, -9000), fit, stage, keyboard: 300);
      expect(v.zfit(fit, stage, keyboard: 300).bottom, 400);
    });

    test('a stage resize keeps z and centre', () {
      final v = ZoomView()..zoomTo(3, const Offset(300, 200), fit, stage);
      final z = v.z, c = v.centre;
      const tall = Size(700, 1000);
      final fit2 = fitRect(content, tall);
      final r = v.zfit(fit2, tall);
      expect(v.z, z);
      expect(v.centre, c);
      expect(r.left, lessThanOrEqualTo(0));
      expect(r.right, greaterThanOrEqualTo(tall.width));
      expect(r.top, lessThanOrEqualTo(0));
      expect(r.bottom, greaterThanOrEqualTo(tall.height));
    });

    testWidgets('restore reaches 1 in 200 ms; backdrop lasts 1 s more', (tester) async {
      final v = ZoomView()..zoomTo(2, stage.center(Offset.zero), fit, stage);
      var n = 0;
      v.addListener(() => n++);
      final c = v.centre;
      v.restore();
      expect(v.restoring, true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(v.z, inExclusiveRange(1, 2));
      expect(v.restoring, true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(v.z, 1);
      expect(v.restoring, false);
      expect(v.centre, c);
      expect(n, greaterThan(2));
      expect(v.backdrop, true);
      await tester.pump(const Duration(milliseconds: 900));
      expect(v.backdrop, true);
      await tester.pump(const Duration(milliseconds: 200));
      expect(v.backdrop, false);
      v.dispose();
    });

    testWidgets('zoomTo from 2 back to 1 keeps the backdrop 1 s more', (tester) async {
      final v = ZoomView()..zoomTo(2, stage.center(Offset.zero), fit, stage);
      v.zoomTo(1, stage.center(Offset.zero), fit, stage);
      expect(v.z, 1);
      expect(v.zoomed, false);
      expect(v.backdrop, true);
      var n = 0;
      v.addListener(() => n++);
      await tester.pump(const Duration(milliseconds: 900));
      expect(v.backdrop, true);
      await tester.pump(const Duration(milliseconds: 200));
      expect(v.backdrop, false);
      expect(n, 1);
      v.dispose();
    });

    test('adopt takes z and centre without animation', () {
      final a = ZoomView()..zoomTo(2, const Offset(300, 200), fit, stage);
      final b = ZoomView()..adopt(a);
      expect(b.z, 2);
      expect(b.centre, a.centre);
      expect(b.restoring, false);
    });
  });

  group('viewRange / viewFactor', () {
    test('seen plus a quarter of its size on each side', () {
      expect(viewRange(const Rect.fromLTWH(100, 100, 200, 100), content), const Rect.fromLTWH(50, 75, 300, 150));
    });

    test('kept inside the content', () {
      expect(viewRange(const Rect.fromLTWH(0, 500, 200, 100), content), const Rect.fromLTWH(0, 475, 250, 125));
    });

    test('the factor is capped by what the range can hold', () {
      expect(viewFactor(2, const Rect.fromLTWH(0, 0, 400, 300), content), 2);
      expect(viewFactor(4, const Rect.fromLTWH(0, 0, 600, 450), content), closeTo(1.3333, 1e-3));
    });
  });

  group('ViewLink', () {
    late List<(int, Rect, double)> sent;
    late ViewLink link;
    setUp(() {
      sent = [];
      link = ViewLink((w, r, z) => sent.add((w, r, z)));
    });
    const seen = Rect.fromLTWH(100, 100, 200, 100);

    test('the first settle sends the range', () {
      link.settled(3, seen, content, 2);
      expect(sent, [(3, const Rect.fromLTWH(50, 75, 300, 150), 2.0)]);
    });

    test('seen inside the range with the same factor sends nothing; outside sends', () {
      link.settled(3, seen, content, 2);
      link.settled(3, const Rect.fromLTWH(120, 110, 200, 100), content, 2);
      expect(sent.length, 1);
      link.settled(3, const Rect.fromLTWH(300, 100, 200, 100), content, 2);
      expect(sent.length, 2);
    });

    test('another window sends', () {
      link.settled(3, seen, content, 2);
      link.settled(4, seen, content, 2);
      expect(sent.length, 2);
    });

    test('a factor change under 10 % is quiet, over it sends', () {
      link.settled(3, seen, content, 2);
      link.settled(3, seen, content, 2.1);
      expect(sent.length, 1);
      link.settled(3, seen, content, 2.5);
      expect(sent.length, 2);
    });

    test('z 1 sends unlimited once', () {
      link.settled(3, seen, content, 2);
      link.settled(3, seen, content, 1);
      expect(sent.last, (0, Rect.zero, 1.0));
      expect(sent.length, 2);
      link.unlimited();
      link.settled(3, seen, content, 1);
      expect(sent.length, 2);
    });

    test('resend repeats the last range, and nothing when there is none', () {
      link.resend();
      expect(sent, isEmpty);
      link.settled(3, seen, content, 2);
      link.resend();
      expect(sent.length, 2);
      expect(sent[1], sent[0]);
      link.unlimited();
      link.resend();
      expect(sent.length, 3);
    });
  });
}
