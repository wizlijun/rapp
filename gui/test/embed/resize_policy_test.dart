import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/resize_policy.dart';
import 'package:rapp/embed/session_port.dart';

RemoteWindow win(int id, double w, double h, {bool resizable = true}) => RemoteWindow(
      id: id,
      parent: 0,
      kind: WindowKind.normal,
      title: 't',
      rect: Rect.fromLTWH(0, 0, w, h),
      titleBar: 28,
      resizable: resizable,
      focused: true,
      texture: 1,
      visible: const Rect.fromLTWH(0, 0, 1, 1),
    );

void main() {
  late List<(int, int, int)> sent;
  late ResizePolicy p;
  setUp(() {
    sent = [];
    p = ResizePolicy((id, w, h) => sent.add((id, w, h)));
  });

  test('tab switch resizes at once', () {
    fakeAsync((a) {
      p.stage(const Size(800, 600));
      a.elapse(const Duration(milliseconds: 400));
      sent.clear();
      p.current(win(2, 640, 480 + 28, resizable: true));
      expect(sent, [(2, 800, 600)]);
    });
  });

  test('stage resize settles then sends once', () {
    fakeAsync((a) {
      p.current(win(1, 800, 628));
      sent.clear();
      for (final w in [810.0, 820.0, 830.0]) {
        p.stage(Size(w, 600));
        a.elapse(const Duration(milliseconds: 100));
      }
      expect(sent, isEmpty);
      a.elapse(const Duration(milliseconds: 300));
      expect(sent, [(1, 830, 600)]);
    });
  });

  test('A refusing the size does not trigger another resize', () {
    fakeAsync((a) {
      p.stage(const Size(800, 600));
      p.current(win(1, 640, 508));
      expect(sent, [(1, 800, 600)]);
      p.current(win(1, 700, 528));
      a.elapse(const Duration(seconds: 1));
      expect(sent.length, 1);
    });
  });

  test('non-resizable windows are left alone', () {
    fakeAsync((a) {
      p.stage(const Size(800, 600));
      p.current(win(1, 640, 508, resizable: false));
      p.stage(const Size(900, 600));
      a.elapse(const Duration(seconds: 1));
      expect(sent, isEmpty);
    });
  });

  test('a matching size sends nothing; dispose cancels the timer', () {
    fakeAsync((a) {
      p.current(win(1, 800, 628));
      p.stage(const Size(800, 600));
      a.elapse(const Duration(seconds: 1));
      expect(sent, isEmpty);
      p.stage(const Size(900, 600));
      p.dispose();
      a.elapse(const Duration(seconds: 1));
      expect(sent, isEmpty);
    });
  });
}
