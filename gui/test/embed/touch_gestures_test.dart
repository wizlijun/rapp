import 'dart:ui' show Rect;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/touch_gestures.dart';

String _n(double v) => double.parse(v.toStringAsFixed(3)).toString();
String _o(Offset o) => '${_n(o.dx)},${_n(o.dy)}';

/// Writes down every intent, one line each.
class _Sink implements TouchSink {
  final calls = <String>[];
  @override
  void press(PointerDownEvent e) => calls.add('press ${_o(e.localPosition)}');
  @override
  void drag(PointerMoveEvent e) => calls.add('drag ${_o(e.localPosition)}');
  @override
  void release(Offset at, PointerEvent e) => calls.add('release ${_o(at)}');
  @override
  void scroll(Offset centre, Offset delta) => calls.add('scroll ${_o(centre)} ${_o(delta)}');
  @override
  void rightTap(Offset at) => calls.add('rightTap ${_o(at)}');
  @override
  void twoDown(Offset centre) => calls.add('twoDown ${_o(centre)}');
  @override
  void pan(Offset delta) => calls.add('pan ${_o(delta)}');
  @override
  void zoom(double z, Offset focal) => calls.add('zoom ${_n(z)} ${_o(focal)}');
  @override
  void settled() => calls.add('settled');
}

/// Feeds a [TouchGestures] touch events at a clock the test moves ([at]).
class _Fingers {
  _Fingers({this.z = 1, bool zoomable = true, Rect inside = const Rect.fromLTWH(0, 0, 400, 300)}) {
    g = TouchGestures(sink: sink, zoom: () => z, inside: inside.contains, zoomable: zoomable);
  }
  final sink = _Sink();
  late final TouchGestures g;
  final double z;
  Duration at = Duration.zero;
  final _where = <int, Offset>{};

  List<String> get calls => sink.calls;

  void down(int p, Offset o) {
    _where[p] = o;
    g.down(PointerDownEvent(kind: PointerDeviceKind.touch, pointer: p, position: o, timeStamp: at));
  }

  void moveTo(int p, Offset o) {
    final d = o - _where[p]!;
    _where[p] = o;
    g.move(PointerMoveEvent(kind: PointerDeviceKind.touch, pointer: p, position: o, delta: d, timeStamp: at));
  }

  void moveBy(int p, Offset d) => moveTo(p, _where[p]! + d);

  void up(int p) =>
      g.up(PointerUpEvent(kind: PointerDeviceKind.touch, pointer: p, position: _where.remove(p)!, timeStamp: at));

  void cancel(int p) =>
      g.up(PointerCancelEvent(kind: PointerDeviceKind.touch, pointer: p, position: _where.remove(p)!, timeStamp: at));
}

/// Moves the fake clock (timers, microtasks) and the events' time stamps together.
Future<void> _wait(WidgetTester tester, _Fingers f, int ms) async {
  f.at += Duration(milliseconds: ms);
  await tester.pump(Duration(milliseconds: ms));
}

void main() {
  group('not zoomed', () {
    testWidgets('holds a touch 150 ms then presses', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      await _wait(tester, f, 149);
      expect(f.calls, isEmpty);
      await _wait(tester, f, 1);
      expect(f.calls, ['press 100.0,100.0']);
      f.moveBy(1, const Offset(3, 0)); // pressed: every move is a drag now, however small
      f.up(1);
      expect(f.calls, ['press 100.0,100.0', 'drag 103.0,100.0', 'release 103.0,100.0']);
    });

    testWidgets('a move past 8 before 150 ms presses then drags', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      f.moveBy(1, const Offset(8, 0)); // 8 is still a tap's jitter
      await _wait(tester, f, 50);
      expect(f.calls, isEmpty);
      f.moveBy(1, const Offset(1, 0));
      expect(f.calls, ['press 100.0,100.0', 'drag 109.0,100.0']);
      f.moveBy(1, const Offset(5, 0));
      f.up(1);
      await _wait(tester, f, 300);
      expect(f.calls, ['press 100.0,100.0', 'drag 109.0,100.0', 'drag 114.0,100.0', 'release 114.0,100.0']);
    });

    testWidgets('a quick tap is press and release where it landed', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      f.moveBy(1, const Offset(6, 0));
      await _wait(tester, f, 40);
      f.up(1);
      await _wait(tester, f, 300);
      expect(f.calls, ['press 100.0,100.0', 'release 100.0,100.0']);
    });

    testWidgets('a cancelled held-back touch sends nothing', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      await _wait(tester, f, 40);
      f.cancel(1);
      await _wait(tester, f, 300);
      expect(f.calls, isEmpty);
    });

    testWidgets('a finger outside presses at once', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 350)); // below the picture
      expect(f.calls, ['press 100.0,350.0']);
      // It holds nothing: a second finger makes it a two-finger gesture (the letterbox swipe, review I1).
      f.down(2, const Offset(140, 290));
      expect(f.calls, ['press 100.0,350.0', 'twoDown 120.0,320.0']);
      f.moveBy(1, const Offset(0, -20));
      f.moveBy(2, const Offset(0, -20));
      await tester.pump();
      expect(f.calls.last, 'scroll 120.0,300.0 0.0,-20.0');
      f.up(1);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls.where((c) => c.startsWith('release') || c.startsWith('drag')), isEmpty);
    });

    testWidgets('two fingers moving together scroll after 8 px, buffered moves first', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      f.down(2, const Offset(140, 100));
      expect(f.calls, ['twoDown 120.0,100.0']);
      f.moveBy(1, const Offset(0, -6));
      f.moveBy(2, const Offset(0, -6));
      await tester.pump();
      expect(f.calls, ['twoDown 120.0,100.0']); // the centre moved 6: still held back
      // one batch: both fingers 14 more up; the 6 held back go out with it, as one scroll
      f.moveBy(1, const Offset(0, -14));
      f.moveBy(2, const Offset(0, -14));
      await tester.pump();
      expect(f.calls, ['twoDown 120.0,100.0', 'scroll 120.0,80.0 0.0,-20.0']);
      f.moveBy(1, const Offset(0, -4));
      f.moveBy(2, const Offset(0, -4));
      await tester.pump();
      expect(f.calls.last, 'scroll 120.0,76.0 0.0,-4.0');
      // lifting one finger keeps scrolling (T4): the other one's move is the centre's now
      f.up(1);
      f.moveBy(2, const Offset(0, -10));
      await tester.pump();
      expect(f.calls.last, 'scroll 140.0,66.0 0.0,-10.0');
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls.where((c) => !c.startsWith('scroll') && !c.startsWith('twoDown')), isEmpty);
    });

    testWidgets('a quick two-finger tap is a right tap at the start centre', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      await _wait(tester, f, 10);
      f.down(2, const Offset(140, 100));
      f.moveBy(1, const Offset(3, 3));
      await _wait(tester, f, 80);
      f.up(1);
      await _wait(tester, f, 10);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls, ['twoDown 120.0,100.0', 'rightTap 120.0,100.0']);
    });

    testWidgets('a two-finger hold past 250 ms is not a right tap', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      f.down(2, const Offset(140, 100));
      await _wait(tester, f, 251);
      f.up(1);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls, ['twoDown 120.0,100.0']);
    });

    testWidgets('a third finger is ignored while scrolling', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(200, 100));
      f.down(2, const Offset(240, 100));
      f.down(3, const Offset(300, 250));
      f.moveBy(3, const Offset(0, -30));
      await tester.pump();
      expect(f.calls, ['twoDown 220.0,100.0']);
      f.moveBy(1, const Offset(0, -20));
      await tester.pump();
      expect(f.calls, ['twoDown 220.0,100.0', 'scroll 220.0,90.0 0.0,-10.0']);
      f.up(1);
      f.up(2);
      f.up(3);
      await _wait(tester, f, 300);
      expect(f.calls.length, 2);
    });

    testWidgets('a second finger while the first is pressed is ignored', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(200, 100));
      await _wait(tester, f, 200);
      f.down(2, const Offset(240, 100));
      f.moveBy(2, const Offset(0, -20));
      f.up(2);
      f.up(1);
      await _wait(tester, f, 300);
      expect(f.calls, ['press 200.0,100.0', 'release 200.0,100.0']);
    });

    testWidgets('a finger left over after a press is lifted makes two with the next one', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(200, 100));
      await _wait(tester, f, 200);
      f.down(2, const Offset(240, 100)); // ignored for the press (T2) but still on the glass
      f.up(1);
      f.down(3, const Offset(260, 140));
      expect(f.calls, ['press 200.0,100.0', 'release 200.0,100.0', 'twoDown 250.0,120.0']);
      f.up(2);
      f.up(3);
      await _wait(tester, f, 300);
    });

    testWidgets('two fingers spreading 12 px pinch: zoom with start × ratio, pan by centre move, settled at the end', (
      tester,
    ) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      f.down(2, const Offset(140, 100)); // 40 apart, centre (120,100)
      f.moveBy(1, const Offset(-6, 0));
      await tester.pump();
      expect(f.calls, ['twoDown 120.0,100.0']); // 6 wider: not yet
      f.moveBy(2, const Offset(7, 0)); // 53 apart, the centre 0.5 right of the start: a pinch
      await tester.pump();
      expect(f.calls, ['twoDown 120.0,100.0', 'zoom 1.325 120.5,100.0', 'pan 0.5,0.0']);
      // both fingers in one batch: one zoom and one pan for it
      f.moveBy(1, const Offset(-13.5, 10));
      f.moveBy(2, const Offset(13.5, 10)); // 80 apart: twice as wide; the centre 10 down
      await tester.pump();
      expect(f.calls.sublist(3), ['zoom 2.0 120.5,110.0', 'pan 0.0,10.0']);
      // a pinch never turns into a scroll or a right tap, whatever the centre does
      f.moveBy(1, const Offset(0, 30));
      f.moveBy(2, const Offset(0, 30));
      await tester.pump();
      expect(f.calls.sublist(5), ['zoom 2.0 120.5,140.0', 'pan 0.0,30.0']);
      f.up(1);
      f.moveBy(2, const Offset(5, 0)); // one finger left: it only pans
      await tester.pump();
      expect(f.calls.sublist(7), ['pan 5.0,0.0']);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls.sublist(8), ['settled']);
    });

    testWidgets('a pinch starts from the zoom there was', (tester) async {
      final f = _Fingers(z: 1.5);
      f.down(1, const Offset(100, 100));
      await _wait(tester, f, 10);
      f.down(2, const Offset(160, 100)); // 60 apart
      f.moveBy(1, const Offset(15, 0));
      f.moveBy(2, const Offset(-15, 0)); // 30 apart: half
      await tester.pump();
      expect(f.calls, ['twoDown 130.0,100.0', 'zoom 0.75 130.0,100.0', 'pan 0.0,0.0']);
      f.up(1);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls.last, 'settled');
    });

    testWidgets('not zoomable: spreading fingers scroll, never zoom', (tester) async {
      final f = _Fingers(zoomable: false);
      f.down(1, const Offset(100, 100));
      f.down(2, const Offset(140, 100));
      for (var i = 0; i < 8; i++) {
        f.moveBy(1, const Offset(-4, 0));
        f.moveBy(2, const Offset(4, 0));
      } // 64 wider, the centre never more than 2 away
      await tester.pump();
      expect(f.calls, ['twoDown 120.0,100.0']);
      f.moveBy(2, const Offset(20, 0)); // the centre 10 right
      await tester.pump();
      expect(f.calls, ['twoDown 120.0,100.0', 'scroll 130.0,100.0 10.0,0.0']);
      f.up(1);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls.length, 2);
    });
  });

  group('zoomed', () {
    testWidgets('zoomed: a one-finger drag pans and never presses; settled on lift', (tester) async {
      final f = _Fingers(z: 2);
      f.down(1, const Offset(100, 100));
      f.moveBy(1, const Offset(5, 0));
      await _wait(tester, f, 100);
      expect(f.calls, isEmpty);
      f.moveBy(1, const Offset(5, 0)); // 10 from where it landed: a pan, all of it
      expect(f.calls, ['pan 10.0,0.0']);
      await _wait(tester, f, 600); // holding still while panning never presses
      f.moveBy(1, const Offset(0, -4));
      f.up(1);
      await _wait(tester, f, 300);
      expect(f.calls, ['pan 10.0,0.0', 'pan 0.0,-4.0', 'settled']);
    });

    testWidgets('zoomed: holding 500 ms presses, then drags; release on lift', (tester) async {
      final f = _Fingers(z: 2);
      f.down(1, const Offset(100, 100));
      await _wait(tester, f, 499);
      expect(f.calls, isEmpty);
      await _wait(tester, f, 1);
      expect(f.calls, ['press 100.0,100.0']);
      f.moveBy(1, const Offset(20, 0));
      f.up(1);
      await _wait(tester, f, 300);
      expect(f.calls, ['press 100.0,100.0', 'drag 120.0,100.0', 'release 120.0,100.0']);
    });

    testWidgets('zoomed: a tap between 150 and 500 ms is press and release', (tester) async {
      final f = _Fingers(z: 2);
      f.down(1, const Offset(100, 100));
      f.moveBy(1, const Offset(4, 0));
      await _wait(tester, f, 300);
      expect(f.calls, isEmpty);
      f.up(1);
      await _wait(tester, f, 600);
      expect(f.calls, ['press 100.0,100.0', 'release 100.0,100.0']);
    });

    testWidgets('zoomed: a finger outside the picture is held back too, and pans', (tester) async {
      final f = _Fingers(z: 2);
      f.down(1, const Offset(100, 350));
      expect(f.calls, isEmpty);
      f.moveBy(1, const Offset(0, -20));
      f.up(1);
      expect(f.calls, ['pan 0.0,-20.0', 'settled']);
    });

    testWidgets('zoomed: a second finger while panning starts a two-finger gesture', (tester) async {
      final f = _Fingers(z: 2);
      f.down(1, const Offset(100, 100));
      f.moveBy(1, const Offset(20, 0));
      expect(f.calls, ['pan 20.0,0.0']);
      await _wait(tester, f, 100);
      f.down(2, const Offset(160, 100));
      expect(f.calls, ['pan 20.0,0.0', 'twoDown 140.0,100.0']);
      f.moveBy(1, const Offset(0, 10));
      f.moveBy(2, const Offset(0, 10));
      await tester.pump();
      expect(f.calls.last, 'scroll 140.0,110.0 0.0,10.0'); // two fingers together scroll, zoomed or not
      f.moveBy(1, const Offset(0, 5)); // the first finger is no longer panning
      await tester.pump();
      expect(f.calls.where((c) => c.startsWith('pan')).length, 1);
      f.up(1);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls.last, 'settled'); // it panned: the view is somewhere new
    });

    testWidgets('zoomed: a second finger 200 ms after the first (still held back) can pinch', (tester) async {
      final f = _Fingers(z: 2);
      f.down(1, const Offset(100, 100));
      await _wait(tester, f, 200);
      f.down(2, const Offset(140, 100));
      expect(f.calls, ['twoDown 120.0,100.0']);
      await _wait(tester, f, 400); // the 500 ms hold is gone with the second finger
      expect(f.calls, ['twoDown 120.0,100.0']);
      f.moveBy(1, const Offset(-10, 0));
      f.moveBy(2, const Offset(10, 0)); // 60 apart
      await tester.pump();
      expect(f.calls, ['twoDown 120.0,100.0', 'zoom 3.0 120.0,100.0', 'pan 0.0,0.0']);
      f.up(1);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls.last, 'settled');
    });
  });

  group('trackpad', () {
    PointerPanZoomStartEvent start(Duration at) =>
        PointerPanZoomStartEvent(pointer: 9, position: const Offset(200, 150), timeStamp: at);
    PointerPanZoomUpdateEvent update(double scale, {Offset pan = Offset.zero}) =>
        PointerPanZoomUpdateEvent(pointer: 9, position: const Offset(200, 150), pan: pan, scale: scale);
    PointerPanZoomEndEvent end() => const PointerPanZoomEndEvent(pointer: 9, position: Offset(200, 150));

    testWidgets('trackpad scale zooms when zoomable, not otherwise; end settles', (tester) async {
      final f = _Fingers(z: 1.5);
      f.g.panZoomStart(start(Duration.zero));
      f.g.panZoomUpdate(update(1, pan: const Offset(0, 12))); // a pan only: the widget scrolls it
      expect(f.calls, isEmpty);
      f.g.panZoomUpdate(update(2));
      f.g.panZoomUpdate(update(1.2));
      f.g.panZoomEnd(end());
      expect(f.calls, ['zoom 3.0 200.0,150.0', 'zoom 1.8 200.0,150.0', 'settled']);

      final pan = _Fingers(z: 1.5);
      pan.g.panZoomStart(start(Duration.zero));
      pan.g.panZoomUpdate(update(1, pan: const Offset(0, 12)));
      pan.g.panZoomEnd(end());
      expect(pan.calls, isEmpty); // nothing zoomed: nothing to settle

      final flat = _Fingers(zoomable: false);
      flat.g.panZoomStart(start(Duration.zero));
      flat.g.panZoomUpdate(update(2));
      flat.g.panZoomEnd(end());
      expect(flat.calls, isEmpty);
    });
  });

  group('reset', () {
    testWidgets('reset drops a held-back press', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      f.g.reset();
      await _wait(tester, f, 300);
      f.up(1);
      expect(f.calls, isEmpty);
    });

    testWidgets('reset drops a scroll not yet sent and the gesture with it', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      f.down(2, const Offset(140, 100));
      f.moveBy(1, const Offset(0, -20));
      f.moveBy(2, const Offset(0, -20));
      f.g.reset();
      await tester.pump();
      f.moveBy(1, const Offset(0, -20));
      f.up(1);
      f.up(2);
      await _wait(tester, f, 300);
      expect(f.calls, ['twoDown 120.0,100.0']);
    });

    testWidgets('after dispose nothing more comes out', (tester) async {
      final f = _Fingers();
      f.down(1, const Offset(100, 100));
      f.g.dispose();
      await _wait(tester, f, 300);
      expect(f.calls, isEmpty);
    });
  });
}
