// The key bar's layout: two rows of cells, cleaned against what exists (spec §8).
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar_keys.dart';
import 'package:rapp/quick/key_layout.dart';

void main() {
  test('default layout gives today’s rows', () {
    expect(keyBarRows(layout: KeyLayout.fallback, more: true), [
      ['tab', 'esc', 'cc', 'bksp', 'enter', 'up', 'more'],
      ['copy', 'paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right'],
    ]);
    expect(keyBarRows(layout: KeyLayout.fallback, more: false), [
      ['tab', 'esc', 'cc', 'bksp', 'enter', 'up', 'more'],
    ]);
    expect(KeyLayout.fallback.isDefault, isTrue);
    expect(KeyLayout.fallback.rows[0], isNot(contains('stab')));
  });

  test('cleaning drops unknown, duplicate and 按键动作 (k:) cells and caps the rows', () {
    final l = KeyLayout([['esc', 'nope', 'esc', 'k:gone', 'k:search', 'more'], List.filled(12, 'tab')]).cleaned();
    expect(l.rows[0], ['esc']);
    expect(l.rows[1], ['tab']);
    final ids = ['esc', 'tab', 'stab', 'cc', 'cr', 'co', 'ct', 'cb', 'cl', 'bksp'];
    final wide = KeyLayout([ids, ['up']]).cleaned();
    expect(wide.rows[0].length, 9);
    expect(KeyLayout([ids, []]).cleaned().rows[0].length, 10);
    expect(KeyLayout([[], []]).cleaned().rows, KeyLayout.fallback.rows);
    expect(KeyLayout.fromJson('junk').rows, KeyLayout.fallback.rows);
  });

  test('empty second row: no ⋯', () {
    expect(keyBarRows(layout: const KeyLayout([['esc', 'up'], []]), more: true), [['esc', 'up']]);
  });

  test('json round trip, and a user layout is not the default', () {
    const l = KeyLayout([['esc', 'k:a'], ['up']]);
    expect(KeyLayout.fromJson(l.toJson()).rows, l.rows);
    expect(l.isDefault, isFalse);
    expect(KeyLayout.fromJson({'rows': [1, ['esc', 3]]}).rows, [<String>[], ['esc']]);
  });
}
