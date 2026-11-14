import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/char_width.dart';
import 'package:rapp/term/sgr.dart';

void main() {
  test('wide characters take two cells, box drawing one', () {
    final l = parseRow('中文ab│x');
    expect(l.cells.map((c) => (c.ch, c.width)).toList(), [
      ('中', 2),
      ('文', 2),
      ('a', 1),
      ('b', 1),
      ('│', 1),
      ('x', 1),
    ]);
    expect(l.columns, 8);
    expect(cellWidth(0x1F600), 2);
    expect(cellWidth(0x0301), 0);
  });
  test('a combining mark joins the cell before it', () {
    expect(parseRow('éx').cells.map((c) => c.ch).toList(), ['é', 'x']);
  });
  test('colours: 16, 256, truecolor, and reset', () {
    final l = parseRow(
      '\x1b[31ma\x1b[38;5;196mb\x1b[38;2;1;2;3mc\x1b[39md\x1b[44;1me\x1b[0mf',
    );
    expect(l.cells.map((c) => c.style.fg).toList(), [
      1,
      196,
      0x1000000 | 0x010203,
      -1,
      -1,
      -1,
    ]);
    expect(l.cells[4].style, const TermStyle(bg: 4, flags: bold));
    expect(l.cells[5].style, const TermStyle());
    expect(l.text, 'abcdef');
  });
  test('colon forms of 38 and 48', () {
    final l = parseRow('\x1b[38:2::9:8:7ma\x1b[48:5:33mb');
    expect(l.cells[0].style.fg, 0x1000000 | 0x090807);
    expect(l.cells[1].style.bg, 33);
  });
  test('attributes switch on and off', () {
    final l = parseRow(
      '\x1b[1;2;3;4;7;9ma\x1b[22;23;24;27;29mb\x1b[4:3mc\x1b[4:0md\x1b[94;103me',
    );
    expect(
      l.cells[0].style.flags,
      bold | dim | italic | underline | reverse | strike,
    );
    expect(l.cells[1].style.flags, 0);
    expect(
      (l.cells[2].style.flags & underline, l.cells[3].style.flags & underline),
      (underline, 0),
    );
    expect((l.cells[4].style.fg, l.cells[4].style.bg), (12, 11));
  });
  test('other escapes are skipped', () {
    expect(
      parseRow('\x1b]8;;http://x\x1b\\ln\x1b]8;;\x1b\\\x1b[?25lk').text,
      'lnk',
    );
  });
  test('DEC line drawing between SO and SI', () {
    final l = parseRow('\x0elqqk\x0f ok');
    expect(l.text, '┌──┐ ok');
    expect(l.cells.length, 7);
  });
  test(
    'styles apply inside the graphics set; charset designations are skipped',
    () {
      final l = parseRow('\x1b(0\x1b)B\x1b[31m\x0ex_~\x0fx');
      expect(l.text, '│ ·x');
      expect(l.cells.map((c) => c.style.fg).toList(), [1, 1, 1, 1]);
      expect(parseRow('\x0eq\x0f').cells.single.width, 1);
    },
  );
}
