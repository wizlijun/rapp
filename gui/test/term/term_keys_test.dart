import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/term_keys.dart';


KeyEvent down(PhysicalKeyboardKey p, LogicalKeyboardKey l, [String? ch]) =>
    KeyDownEvent(physicalKey: p, logicalKey: l, character: ch, timeStamp: Duration.zero);

final _ctrl = {LogicalKeyboardKey.controlLeft};
final _shift = {LogicalKeyboardKey.shiftLeft};
final _alt = {LogicalKeyboardKey.altLeft};
final _meta = {LogicalKeyboardKey.metaLeft};
final none = <LogicalKeyboardKey>{};

TermInput? run(KeyEvent e, Set<LogicalKeyboardKey> pressed, {bool mac = false}) =>
    termInputOf(e, mac: mac, pressed: pressed);

void expectKeys(TermInput? r, List<String> keys) {
  expect(r, isA<TermKeys>());
  expect((r as TermKeys).keys, keys);
}

void expectText(TermInput? r, String text) {
  expect(r, isA<TermText>());
  expect((r as TermText).text, text);
}

void main() {
  for (final mac in [false, true]) {
    group(mac ? 'mac' : 'non-mac', () {
      test('plain text', () {
        expectText(run(down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'a'), none, mac: mac), 'a');
        expectText(run(down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'A'), _shift, mac: mac), 'A');
        expectText(run(down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, '中'), none, mac: mac), '中');
        expectText(run(down(PhysicalKeyboardKey.space, LogicalKeyboardKey.space, ' '), none, mac: mac), ' ');
      });
      test('repeat counts, up does not', () {
        expectText(
            run(KeyRepeatEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: LogicalKeyboardKey.keyA, character: 'a', timeStamp: Duration.zero),
                none, mac: mac),
            'a');
        expect(run(KeyUpEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: LogicalKeyboardKey.keyA, timeStamp: Duration.zero), none, mac: mac),
            isNull);
      });
      test('enter', () {
        expectKeys(run(down(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter, '\r'), none, mac: mac), ['Enter']);
        expectText(run(down(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter, '\r'), _shift, mac: mac), '\u001b\r');
        expect(run(down(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter, '\r'), _ctrl, mac: mac), isNull);
      });
      test('named keys and modifiers', () {
        expectKeys(run(down(PhysicalKeyboardKey.escape, LogicalKeyboardKey.escape), none, mac: mac), ['Esc']);
        expectKeys(run(down(PhysicalKeyboardKey.tab, LogicalKeyboardKey.tab, '\t'), _shift, mac: mac), ['Shift-Tab']);
        expectKeys(run(down(PhysicalKeyboardKey.tab, LogicalKeyboardKey.tab, '\t'), none, mac: mac), ['Tab']);
        expectKeys(run(down(PhysicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowUp), _shift, mac: mac), ['Shift-Up']);
        expectKeys(run(down(PhysicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight), {..._ctrl, ..._shift}, mac: mac), ['Ctrl-Shift-Right']);
        expectKeys(run(down(PhysicalKeyboardKey.backspace, LogicalKeyboardKey.backspace), _alt, mac: mac), ['Alt-Backspace']);
        expectKeys(run(down(PhysicalKeyboardKey.f11, LogicalKeyboardKey.f11), none, mac: mac), ['F11']);
        expectKeys(run(down(PhysicalKeyboardKey.pageUp, LogicalKeyboardKey.pageUp), none, mac: mac), ['PageUp']);
        expectKeys(run(down(PhysicalKeyboardKey.delete, LogicalKeyboardKey.delete), none, mac: mac), ['Delete']);
      });
      test('shift is dropped where the wire grammar has no such name', () {
        // Alt+Shift+Tab, Ctrl+Shift+Tab: no valid name; closest is without Shift.
        expectKeys(run(down(PhysicalKeyboardKey.tab, LogicalKeyboardKey.tab), {..._alt, ..._shift}, mac: mac), ['Alt-Tab']);
        expectKeys(run(down(PhysicalKeyboardKey.tab, LogicalKeyboardKey.tab), {..._ctrl, ..._shift}, mac: mac), ['Ctrl-Tab']);
        expectKeys(run(down(PhysicalKeyboardKey.backspace, LogicalKeyboardKey.backspace), _shift, mac: mac), ['Backspace']);
        expectKeys(run(down(PhysicalKeyboardKey.escape, LogicalKeyboardKey.escape), _shift, mac: mac), ['Esc']);
      });
      test('ctrl', () {
        expectKeys(run(down(PhysicalKeyboardKey.keyR, LogicalKeyboardKey.keyR), _ctrl, mac: mac), ['Ctrl-r']);
        expectKeys(run(down(PhysicalKeyboardKey.keyL, LogicalKeyboardKey.keyL), _ctrl, mac: mac), ['Ctrl-l']);
        expectKeys(run(down(PhysicalKeyboardKey.bracketLeft, LogicalKeyboardKey.bracketLeft), _ctrl, mac: mac), ['Ctrl-[']);
        expectKeys(run(down(PhysicalKeyboardKey.bracketRight, LogicalKeyboardKey.bracketRight), _ctrl, mac: mac), ['Ctrl-]']);
        expectKeys(run(down(PhysicalKeyboardKey.backslash, LogicalKeyboardKey.backslash), _ctrl, mac: mac), ['Ctrl-\\']);
        expectKeys(run(down(PhysicalKeyboardKey.digit2, LogicalKeyboardKey.digit2), {..._ctrl, ..._shift}, mac: mac), ['Ctrl-@']);
        // Ctrl+Shift+- is reserved (font size) on non-mac, so Ctrl-_ is only reachable on mac.
        if (mac) {
          expectKeys(run(down(PhysicalKeyboardKey.minus, LogicalKeyboardKey.minus), {..._ctrl, ..._shift}, mac: mac), ['Ctrl-_']);
        }
        expectKeys(run(down(PhysicalKeyboardKey.space, LogicalKeyboardKey.space, ' '), _ctrl, mac: mac), ['Ctrl-Space']);
        expect(run(down(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1), _ctrl, mac: mac), isNull);
      });
      test('alt', () {
        expectKeys(run(down(PhysicalKeyboardKey.keyF, LogicalKeyboardKey.keyF, 'ƒ'), _alt, mac: mac), ['Alt-f']);
        expectKeys(run(down(PhysicalKeyboardKey.keyF, LogicalKeyboardKey.keyF, 'Ï'), {..._alt, ..._shift}, mac: mac), ['Alt-F']);
        expectKeys(run(down(PhysicalKeyboardKey.keyF, LogicalKeyboardKey.keyF), _alt, mac: mac), ['Alt-f']);
        expectKeys(run(down(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1), {..._alt, ..._shift}, mac: mac), ['Alt-!']);
        expectKeys(run(down(PhysicalKeyboardKey.period, LogicalKeyboardKey.period), _alt, mac: mac), ['Alt-.']);
        expectKeys(run(down(PhysicalKeyboardKey.space, LogicalKeyboardKey.space, ' '), _alt, mac: mac), ['Alt-Space']);
      });
    });
  }

  group('mac shortcuts', () {
    test('copy paste reserved', () {
      expect((run(down(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC, 'c'), _meta, mac: true) as TermAction).action, TermShortcut.copy);
      expect((run(down(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV, 'v'), _meta, mac: true) as TermAction).action, TermShortcut.paste);
      expect(run(down(PhysicalKeyboardKey.keyF, LogicalKeyboardKey.keyF, 'f'), _meta, mac: true), isA<TermReserved>());
      expect(run(down(PhysicalKeyboardKey.equal, LogicalKeyboardKey.equal, '='), _meta, mac: true), isA<TermReserved>());
      expect(run(down(PhysicalKeyboardKey.equal, LogicalKeyboardKey.equal, '+'), {..._meta, ..._shift}, mac: true), isA<TermReserved>());
      expect(run(down(PhysicalKeyboardKey.minus, LogicalKeyboardKey.minus, '-'), _meta, mac: true), isA<TermReserved>());
    });
    test('other meta combos bubble', () {
      expect(run(down(PhysicalKeyboardKey.keyQ, LogicalKeyboardKey.keyQ, 'q'), _meta, mac: true), isNull);
      expect(run(down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'a'), _meta, mac: true), isNull);
    });
    test('ctrl+shift+letter is plain Ctrl-letter on mac', () {
      expectKeys(run(down(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC), {..._ctrl, ..._shift}, mac: true), ['Ctrl-c']);
    });
  });

  group('non-mac shortcuts', () {
    final cs = {LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft};
    test('ctrl+shift', () {
      expect((run(down(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC), cs) as TermAction).action, TermShortcut.copy);
      expect((run(down(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV), cs) as TermAction).action, TermShortcut.paste);
      expect(run(down(PhysicalKeyboardKey.keyF, LogicalKeyboardKey.keyF), cs), isA<TermReserved>());
      expect(run(down(PhysicalKeyboardKey.equal, LogicalKeyboardKey.equal), cs), isA<TermReserved>());
      expect(run(down(PhysicalKeyboardKey.minus, LogicalKeyboardKey.minus), cs), isA<TermReserved>());
    });
    test('plain ctrl+c goes to the terminal', () {
      expectKeys(run(down(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC), _ctrl), ['Ctrl-c']);
    });
  });

  group('non-US layouts', () {
    test('ctrl+letter follows the logical key', () {
      // Dvorak: the key labelled C sits on the physical J position.
      expectKeys(run(down(PhysicalKeyboardKey.keyJ, LogicalKeyboardKey.keyC), _ctrl), ['Ctrl-c']);
      expectKeys(run(down(PhysicalKeyboardKey.keyJ, LogicalKeyboardKey.keyC), _ctrl, mac: true), ['Ctrl-c']);
    });
    test('mac Cmd+C and non-mac Ctrl+Shift+C follow the logical key', () {
      final e = down(PhysicalKeyboardKey.keyI, LogicalKeyboardKey.keyC, 'c');
      expect((run(e, _meta, mac: true) as TermAction).action, TermShortcut.copy);
      expect((run(e, {..._ctrl, ..._shift}) as TermAction).action,
          TermShortcut.copy);
      // The physical C position now holds another letter: not a shortcut.
      final other = down(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyJ, 'j');
      expect(run(other, _meta, mac: true), isNull);
    });
  });
}
