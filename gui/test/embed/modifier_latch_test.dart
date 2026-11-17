// The sticky modifiers of the app key row (iPad P1 task 9): a tap is once, a quick second tap locks.
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/modifier_latch.dart';

void main() {
  test('the modifier bits are CGEventFlags', () {
    expect(latchCmd, 1048576);
    expect(latchOpt, 524288);
    expect(latchCtrl, 262144);
    expect(latchShift, 131072);
  });

  test('a tap is once; another within 150 ms locks; one after 400 ms turns it off', () {
    final l = ModifierLatch();
    addTearDown(l.dispose);
    l.tap(latchCmd);
    expect(l.of(latchCmd), LatchState.once);
    l.tap(latchCmd, sinceLast: const Duration(milliseconds: 150));
    expect(l.of(latchCmd), LatchState.locked);
    l.tap(latchCmd);
    expect(l.of(latchCmd), LatchState.off);

    l.tap(latchCmd);
    l.tap(latchCmd, sinceLast: const Duration(milliseconds: 400));
    expect(l.of(latchCmd), LatchState.off);
  });

  test('without sinceLast the latch times the taps itself', () {
    var now = DateTime(2026, 11, 17);
    final l = ModifierLatch(clock: () => now);
    addTearDown(l.dispose);
    l.tap(latchOpt);
    now = now.add(const Duration(milliseconds: 349));
    l.tap(latchOpt);
    expect(l.of(latchOpt), LatchState.locked);
    l.tap(latchOpt);
    l.tap(latchOpt);
    now = now.add(const Duration(milliseconds: 350));
    l.tap(latchOpt);
    expect(l.of(latchOpt), LatchState.off);
  });

  test('used() clears once and leaves locked', () {
    final l = ModifierLatch();
    addTearDown(l.dispose);
    l.tap(latchCmd);
    l.tap(latchShift);
    l.tap(latchShift, sinceLast: const Duration(milliseconds: 100));
    l.used();
    expect(l.of(latchCmd), LatchState.off);
    expect(l.of(latchShift), LatchState.locked);
    expect(l.flags, latchShift);
  });

  test('⌘ once and ⌥ locked: flags is both bits', () {
    final l = ModifierLatch();
    addTearDown(l.dispose);
    l.tap(latchCmd);
    l.tap(latchOpt);
    l.tap(latchOpt, sinceLast: const Duration(milliseconds: 100));
    expect(l.flags, 1048576 | 524288);
  });

  test('releaseAll() turns every modifier off, locked too, and notifies once', () {
    final l = ModifierLatch();
    addTearDown(l.dispose);
    l.tap(latchCmd);
    l.tap(latchCtrl);
    l.tap(latchCtrl, sinceLast: const Duration(milliseconds: 100));
    var n = 0;
    l.addListener(() => n++);
    l.releaseAll();
    expect(l.flags, 0);
    expect(l.of(latchCtrl), LatchState.off);
    expect(n, 1);
    l.releaseAll();
    l.used();
    expect(n, 1, reason: 'nothing changed: no notify');
  });
}
