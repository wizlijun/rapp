import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/pointer.dart';

void main() {
  test('click counter counts within interval and slop', () {
    final c = ClickCounter(const Duration(milliseconds: 500));
    Duration ms(int n) => Duration(milliseconds: n);
    expect(c.down(Offset.zero, ms(0), kPrimaryButton), 1);
    expect(c.down(const Offset(3, 0), ms(300), kPrimaryButton), 2);
    expect(c.down(const Offset(3, 0), ms(600), kPrimaryButton), 3);
    expect(c.down(const Offset(10, 0), ms(700), kPrimaryButton), 1); // moved past the slop
    expect(c.down(const Offset(10, 0), ms(1300), kPrimaryButton), 1); // too late
    expect(c.down(const Offset(10, 0), ms(1400), kSecondaryButton), 1); // other button
    expect(c.down(const Offset(10, 0), ms(1500), kSecondaryButton), 2);
  });

  test('click counter slop is configurable', () {
    final c = ClickCounter(const Duration(milliseconds: 500), slop: 10);
    expect(c.down(Offset.zero, Duration.zero, kPrimaryButton), 1);
    expect(c.down(const Offset(8, 0), const Duration(milliseconds: 100), kPrimaryButton), 2);
  });

  test('wheel is flipped, trackpad pan passes through', () {
    // A notch is 40 pt in Flutter and 10 in rapp-client's scroll messages.
    expect(wheelToRemote(const Offset(0, 40)), const Offset(0, -10));
    expect(wheelToRemote(const Offset(-8, 0)), const Offset(2, 0));
    expect(panToRemote(const Offset(0, 12)), const Offset(0, 12));
  });

  test('clampTo keeps a point inside the rect', () {
    const r = Rect.fromLTWH(0, 100, 800, 400);
    expect(clampTo(const Offset(850, 300), r), const Offset(800, 300));
    expect(clampTo(const Offset(-5, 50), r), const Offset(0, 100));
    expect(clampTo(const Offset(10, 120), r), const Offset(10, 120));
  });
}
