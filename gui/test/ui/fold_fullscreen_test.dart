// FoldFullscreen: the Duo folded (a window whose short side is under 600) leaves fullscreen, unfolded brings it back.
import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/fullscreen.dart';

class _Fake implements FullscreenControl {
  bool on = false;
  final sets = <bool>[];
  final _c = StreamController<bool>.broadcast();

  @override
  Stream<bool> get changes => _c.stream;
  @override
  Future<bool> isFullScreen() async => on;
  @override
  Future<void> setFullScreen(bool v) async {
    sets.add(v);
    if (v == on) return;
    on = v;
    _c.add(v);
  }
}

const inner = Size(744, 1000), innerSide = Size(1000, 744), outer = Size(390, 844), outerSide = Size(844, 390);

void main() {
  late _Fake fake;
  late FoldFullscreen fs;
  setUp(() {
    fake = _Fake();
    fs = FoldFullscreen(fake);
  });

  test('unfolded at start with 启动时全屏: fullscreen', () async {
    await fs.start(want: true, size: inner);
    expect(fake.on, isTrue);
  });

  test('folded at start: not fullscreen, and unfolding turns it on', () async {
    await fs.start(want: true, size: outer);
    expect(fake.sets, isEmpty);
    await fs.windowSize(inner);
    expect(fake.on, isTrue);
  });

  test('without 启动时全屏 nothing turns it on', () async {
    await fs.start(want: false, size: outer);
    await fs.windowSize(inner);
    expect(fake.sets, isEmpty);
  });

  test('folding leaves fullscreen, unfolding comes back; rotating either screen changes nothing', () async {
    await fs.start(want: true, size: inner);
    await fs.windowSize(innerSide);
    expect(fake.sets, [true]);
    await fs.windowSize(outer);
    expect(fake.on, isFalse);
    await fs.windowSize(outerSide);
    expect(fake.sets, [true, false], reason: 'the outer screen held sideways is still folded');
    await fs.windowSize(inner);
    expect(fake.on, isTrue);
    expect(fake.sets, [true, false, true]);
  });

  test('not fullscreen when folded: unfolding leaves it off', () async {
    await fs.start(want: false, size: inner);
    await fs.windowSize(outer);
    await fs.windowSize(inner);
    expect(fake.sets, isEmpty);
  });

  test('turned off by hand: unfolding later keeps it off', () async {
    await fs.start(want: true, size: inner);
    await fs.setFullScreen(false);
    await fs.windowSize(outer);
    await fs.windowSize(inner);
    expect(fake.on, isFalse);
  });

  test('turned on by hand while folded stays on; folding again leaves it, unfolding brings it back', () async {
    await fs.start(want: false, size: outer);
    await fs.setFullScreen(true);
    await fs.windowSize(inner);
    expect(fake.on, isTrue);
    await fs.windowSize(outer);
    expect(fake.on, isFalse);
    await fs.windowSize(inner);
    expect(fake.on, isTrue);
  });

  test('a fold and unfold reported back to back end the way the last size says', () async {
    await fs.start(want: true, size: inner);
    unawaited(fs.windowSize(outer));
    await fs.windowSize(inner);
    expect(fake.on, isTrue);
    expect(fake.sets, [true, false, true]);
  });

  test('changes and isFullScreen are the wrapped control\'s', () async {
    final seen = <bool>[];
    final sub = fs.changes.listen(seen.add);
    await fs.start(want: true, size: inner);
    await fs.windowSize(outer);
    await Future<void>.delayed(Duration.zero);
    expect(seen, [true, false]);
    expect(await fs.isFullScreen(), isFalse);
    await sub.cancel();
  });
}
