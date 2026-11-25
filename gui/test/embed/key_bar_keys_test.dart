// The virtual key bar's keys and layout: which keys each row holds.
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar_keys.dart';
import 'package:rapp/embed/modifier_latch.dart';

void main() {
  test('one row of eleven by intent: Tab ⇧Tab, Esc ⌃C, ⌃, ↑ ↓, ⌫ ⏎, then ⋯ and ⌄ at the end; more adds the second row', () {
    expect(keyBarRows(app: false, more: false), [
      ['tab', 'stab', 'esc', 'cc', 'ctrl', 'up', 'down', 'bksp', 'enter', 'more', 'hide'],
    ]);
    expect(keyBarRows(app: false, more: true)[1],
        ['copy', 'paste', 'opt', 'left', 'right', 'co', 'cr', 'ct', 'cb', 'cl']);
  });

  test('app: ⌘ after ⌥', () {
    expect(keyBarRows(app: true, more: true)[1],
        ['copy', 'paste', 'opt', 'cmd', 'left', 'right', 'co', 'cr', 'ct', 'cb', 'cl']);
  });

  test('no key is on the bar twice', () {
    for (final app in [false, true]) {
      final ids = [for (final row in keyBarRows(app: app, more: true)) ...row];
      expect(ids.toSet().length, ids.length, reason: 'app: $app');
    }
  });

  test('⌄ folds the 快捷区: a hide key, said 收起快捷区, sending nothing', () {
    final k = barKeys['hide']!;
    expect(k.kind, BarKind.hide);
    expect(k.label, '⌄');
    expect(k.spoken, '收起快捷区');
    expect(k.wire, isNull);
    expect(k.code, isNull);
    expect(barKeys.containsKey('slim'), isFalse);
  });

  test('heights', () {
    expect(keyBarHeight(1), 54);
    expect(keyBarHeight(2), 100);
  });

  test('every id in a row is in barKeys; ⌃C is Ctrl-C and 8+ctrl', () {
    for (final app in [false, true]) {
      for (final more in [false, true]) {
        for (final row in keyBarRows(app: app, more: more)) {
          for (final id in row) {
            expect(barKeys.containsKey(id), isTrue, reason: 'unknown key id $id');
          }
        }
      }
    }
    final cc = barKeys['cc']!;
    expect(cc.wire, 'Ctrl-C');
    expect(cc.code, 8);
    expect(cc.mods, latchCtrl);
  });

  test('macLetterCodes: 26 letters, each ⌃-letter key carries its code', () {
    expect(macLetterCodes.length, 26);
    const ctrlKeys = {'cc': 'c', 'cr': 'r', 'co': 'o', 'ct': 't', 'cb': 'b', 'cl': 'l'};
    for (final e in ctrlKeys.entries) {
      expect(barKeys[e.key]!.code, macLetterCodes[e.value], reason: e.key);
    }
  });

  test('⌃L is Ctrl-L on a terminal and L with ⌃ on an app', () {
    final cl = barKeys['cl']!;
    expect(cl.label, '⌃L');
    expect(cl.wire, 'Ctrl-L');
    expect(cl.code, 37);
    expect(cl.mods, latchCtrl);
  });

  test('copy and paste show their shortcut and are spoken by name', () {
    expect(barKeys['copy']!.label, '⌘C');
    expect(barKeys['copy']!.spoken, '复制');
    expect(barKeys['paste']!.label, '⌘V');
    expect(barKeys['paste']!.spoken, '粘贴');
  });

  test('key table: arrows swipe to their partner and repeat; non-send keys carry no wire or code', () {
    expect(barKeys['left']!.alt, 'home');
    expect(barKeys['up']!.alt, 'pgup');
    expect(barKeys['down']!.alt, 'pgdn');
    expect(barKeys['right']!.alt, 'end');
    for (final id in ['left', 'up', 'down', 'right', 'bksp']) {
      expect(barKeys[id]!.repeats, isTrue, reason: id);
    }
    expect(barKeys['enter']!.repeats, isFalse);
    expect(barKeys['ctrl']!.bit, latchCtrl);
    expect(barKeys['opt']!.bit, latchOpt);
    expect(barKeys['cmd']!.bit, latchCmd);
    for (final id in ['ctrl', 'opt', 'cmd', 'copy', 'paste', 'more', 'hide']) {
      final k = barKeys[id]!;
      expect(k.wire, isNull, reason: id);
      expect(k.code, isNull, reason: id);
      expect(k.mods, 0, reason: id);
    }
  });
}
