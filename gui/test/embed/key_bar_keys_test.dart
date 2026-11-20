// The virtual key bar's keys and layout (iOS input toggle, task 1): which keys a row holds at each width and mode.
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar_keys.dart';
import 'package:rapp/embed/modifier_latch.dart';

List<List<String?>> rows({
  required double width,
  bool app = false,
  bool more = false,
  bool slim = false,
  bool hardware = false,
}) =>
    keyBarRows(width: width, app: app, more: more, slim: slim, hardware: hardware);

void main() {
  test('narrow: one row of ten, ⋯ last; more adds the second row', () {
    expect(rows(width: 390), [
      ['esc', 'stab', 'tab', 'cc', 'left', 'up', 'down', 'right', 'enter', 'more'],
    ]);
    expect(rows(width: 390, more: true)[1],
        ['ctrl', 'opt', 'cr', 'co', 'ct', 'cb', 'cd', 'bksp', 'copy', 'paste']);
  });

  test('narrow app: ⌘ after ⌥, ⌃D gives way', () {
    expect(rows(width: 390, app: true, more: true)[1],
        ['ctrl', 'opt', 'cmd', 'cr', 'co', 'ct', 'cb', 'bksp', 'copy', 'paste']);
  });

  test('wide: one grouped row, Esc first, arrows and ⏎ last, no ⋯', () {
    expect(rows(width: 1180), [
      [
        'esc', 'stab', 'tab', null, 'ctrl', 'opt', null, 'cc', 'cd', 'cr', 'co', 'ct', 'cb', null,
        'home', 'end', 'pgup', 'pgdn', null, 'bksp', 'copy', 'paste', null, 'left', 'up', 'down', 'right', 'enter',
      ],
    ]);
  });

  test('wide app: ⌘ right after ⌥ in the modifier group', () {
    expect(rows(width: 1180, app: true)[0], [
      'esc', 'stab', 'tab', null, 'ctrl', 'opt', 'cmd', null, 'cc', 'cd', 'cr', 'co', 'ct', 'cb', null,
      'home', 'end', 'pgup', 'pgdn', null, 'bksp', 'copy', 'paste', null, 'left', 'up', 'down', 'right', 'enter',
    ]);
  });

  test('hardware keyboard: ⊙ ends the first row', () {
    expect(rows(width: 390, hardware: true)[0].last, 'slim');
    expect(rows(width: 1180, hardware: true)[0].last, 'slim');
  });

  test('slim: Esc ⇧Tab and the slim key only, at any width', () {
    for (final w in [390.0, 1180.0]) {
      expect(rows(width: w, more: true, slim: true, hardware: true), [['esc', 'stab', 'slim']]);
    }
  });

  test('heights', () {
    expect(keyBarHeight(1), 54);
    expect(keyBarHeight(2), 100);
  });

  test('every id in a row is in barKeys; ⌃C is Ctrl-C and 8+ctrl', () {
    for (final w in [390.0, 1180.0]) {
      for (final app in [false, true]) {
        for (final more in [false, true]) {
          for (final slim in [false, true]) {
            for (final hardware in [false, true]) {
              for (final row in rows(width: w, app: app, more: more, slim: slim, hardware: hardware)) {
                for (final id in row) {
                  if (id == null) continue;
                  expect(barKeys.containsKey(id), isTrue, reason: 'unknown key id $id');
                }
              }
            }
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
    const ctrlKeys = {'cc': 'c', 'cd': 'd', 'cr': 'r', 'co': 'o', 'ct': 't', 'cb': 'b'};
    for (final e in ctrlKeys.entries) {
      expect(barKeys[e.key]!.code, macLetterCodes[e.value], reason: e.key);
    }
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
    for (final id in ['ctrl', 'opt', 'cmd', 'copy', 'paste', 'more', 'slim']) {
      final k = barKeys[id]!;
      expect(k.wire, isNull, reason: id);
      expect(k.code, isNull, reason: id);
      expect(k.mods, 0, reason: id);
    }
  });
}
