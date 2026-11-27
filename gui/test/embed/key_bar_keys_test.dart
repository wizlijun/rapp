// The virtual key bar's keys and layout: which keys each row holds.
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar_keys.dart';
import 'package:rapp/embed/modifier_latch.dart';

void main() {
  test('first row: Tab ⇧Tab Esc ⌃C ⌫ ⏎, then ↑ and ⋯ at the end; more adds the second row, ← ↓ → under ↑ ⋯', () {
    for (final app in [false, true]) {
      expect(keyBarRows(app: app, more: false), [
        ['tab', 'stab', 'esc', 'cc', 'bksp', 'enter', 'up', 'more'],
      ], reason: 'app: $app');
      expect(keyBarRows(app: app, more: true)[1],
          ['copy', 'paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right'],
          reason: 'app: $app');
    }
  });

  test('the arrow block keeps its columns: ↑ ⋯ over ↓ →, one key wide each, ← left of ↓', () {
    expect(keyBarColumns, 10);
    expect(keyBarTail(['tab', 'stab', 'esc', 'cc', 'bksp', 'enter', 'up', 'more']), 2);
    expect(keyBarTail(['copy', 'paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right']), 3);
  });

  test('no ⌄ key and no swipe-up keys: Home and End are gone, an arrow is only its arrow', () {
    expect(barKeys.containsKey('hide'), isFalse);
    expect(barKeys.containsKey('home'), isFalse);
    expect(barKeys.containsKey('end'), isFalse);
    expect(BarKind.values.map((k) => k.name), isNot(contains('hide')));
  });

  test('⌘T reads ⌘T, sends nothing by itself (the bar runs it), and is said Command T', () {
    final k = barKeys['cmdt']!;
    expect(k.kind, BarKind.cmdT);
    expect(k.label, '⌘T');
    expect(k.spoken, 'Command T');
  });

  test('no ⌥ and no ⌃-letter keys on the bar; the ⌃-letters stay in barKeys for the 常用语条 commands', () {
    for (final app in [false, true]) {
      final ids = {for (final row in keyBarRows(app: app, more: true)) ...row};
      for (final gone in ['opt', 'co', 'cr', 'ct', 'cb', 'cl']) {
        expect(ids.contains(gone), isFalse, reason: '$gone, app: $app');
      }
    }
    expect(barKeys['cr']!.wire, 'Ctrl-R');
  });

  test('no key is on the bar twice', () {
    for (final app in [false, true]) {
      final ids = [for (final row in keyBarRows(app: app, more: true)) ...row];
      expect(ids.toSet().length, ids.length, reason: 'app: $app');
    }
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

  test('key table: arrows and ⌫ repeat; non-send keys carry no wire or code', () {
    for (final id in ['left', 'up', 'down', 'right', 'bksp']) {
      expect(barKeys[id]!.repeats, isTrue, reason: id);
    }
    expect(barKeys['enter']!.repeats, isFalse);
    expect(barKeys['ctrl']!.bit, latchCtrl);
    expect(barKeys['opt']!.bit, latchOpt);
    expect(barKeys['cmd']!.bit, latchCmd);
    for (final id in ['ctrl', 'opt', 'cmd', 'cmdt', 'copy', 'paste', 'more']) {
      final k = barKeys[id]!;
      expect(k.wire, isNull, reason: id);
      expect(k.code, isNull, reason: id);
      expect(k.mods, 0, reason: id);
    }
  });
}
