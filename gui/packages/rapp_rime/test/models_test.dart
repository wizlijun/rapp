import 'package:flutter_test/flutter_test.dart';
import 'package:rapp_rime/rapp_rime.dart';

void main() {
  test('RimeUpdate.parse reads a full update', () {
    final u = RimeUpdate.parse({
      'commit': 'x',
      'preedit': 'ni hao',
      'caret': 2,
      'input': 'nihao',
      'ascii': true,
      'menu': {
        'rows': [
          {'index': 0, 'label': '1', 'text': '你好'},
          {'index': 1, 'label': '2', 'text': '拟好'},
        ],
        'cursor': 1,
        'previous': false,
        'next': true,
      },
    })!;
    expect(u.commit, 'x');
    expect(u.preedit, 'ni hao');
    expect(u.caret, 2);
    expect(u.input, 'nihao');
    expect(u.ascii, true);
    expect(u.menu.rows.length, 2);
    expect(u.menu.rows[1].text, '拟好');
    expect(u.menu.cursor, 1);
    expect(u.menu.next, true);
    expect(u.menu.previous, false);
  });

  test('a row with a non-int index makes the update null', () {
    expect(
      RimeUpdate.parse({
        'menu': {
          'rows': [
            {'index': 'a', 'label': '1', 'text': 'x'},
          ],
        },
      }),
      isNull,
    );
  });

  test('non-map args give null', () {
    expect(RimeUpdate.parse(null), isNull);
    expect(RimeUpdate.parse('x'), isNull);
  });

  test('caret is clamped into the preedit', () {
    expect(RimeUpdate.parse({'preedit': 'abc', 'caret': 99})!.caret, 3);
    expect(RimeUpdate.parse({'preedit': 'abc', 'caret': -4})!.caret, 0);
  });

  test('RimeStatus.parse', () {
    final s = RimeStatus.parse({'state': 'error', 'message': 'x', 'keyboard': true});
    expect(s.state, RimeState.error);
    expect(s.message, 'x');
    expect(s.keyboard, true);
    final off = RimeStatus.parse(null);
    expect(off.state, RimeState.off);
    expect(off.message, '');
    expect(off.keyboard, false);
    expect(RimeStatus.parse({'state': 7, 'message': 3}).state, RimeState.off);
  });
}
