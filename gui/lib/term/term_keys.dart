import 'package:flutter/services.dart';

/// What a local key event turns into on its way to the terminal.
sealed class TermInput {}

/// Wire key names (`[Ctrl-][Alt-][Shift-]<base>`, see rust/term/src/keys.rs).
class TermKeys extends TermInput {
  TermKeys(this.keys);
  final List<String> keys;
}

/// Literal text.
class TermText extends TermInput {
  TermText(this.text);
  final String text;
}

/// [newTerm]: ⌘T, a new terminal beside this one; [closeTerm]: ⌘W, end this one.
enum TermShortcut { copy, paste, newTerm, closeTerm }

class TermAction extends TermInput {
  TermAction(this.action);
  final TermShortcut action;
}

/// Kept for rApp (find, font size): swallowed, not sent.
class TermReserved extends TermInput {}

/// US-layout base and shifted characters per physical key.
final Map<PhysicalKeyboardKey, (String, String)> _us = {
  for (var i = 0; i < 26; i++)
    _letters[i]: (String.fromCharCode(0x61 + i), String.fromCharCode(0x41 + i)),
  PhysicalKeyboardKey.digit1: ('1', '!'),
  PhysicalKeyboardKey.digit2: ('2', '@'),
  PhysicalKeyboardKey.digit3: ('3', '#'),
  PhysicalKeyboardKey.digit4: ('4', r'$'),
  PhysicalKeyboardKey.digit5: ('5', '%'),
  PhysicalKeyboardKey.digit6: ('6', '^'),
  PhysicalKeyboardKey.digit7: ('7', '&'),
  PhysicalKeyboardKey.digit8: ('8', '*'),
  PhysicalKeyboardKey.digit9: ('9', '('),
  PhysicalKeyboardKey.digit0: ('0', ')'),
  PhysicalKeyboardKey.minus: ('-', '_'),
  PhysicalKeyboardKey.equal: ('=', '+'),
  PhysicalKeyboardKey.bracketLeft: ('[', '{'),
  PhysicalKeyboardKey.bracketRight: (']', '}'),
  PhysicalKeyboardKey.backslash: ('\\', '|'),
  PhysicalKeyboardKey.semicolon: (';', ':'),
  PhysicalKeyboardKey.quote: ("'", '"'),
  PhysicalKeyboardKey.backquote: ('`', '~'),
  PhysicalKeyboardKey.comma: (',', '<'),
  PhysicalKeyboardKey.period: ('.', '>'),
  PhysicalKeyboardKey.slash: ('/', '?'),
};

final List<PhysicalKeyboardKey> _letters = [
  PhysicalKeyboardKey.keyA, PhysicalKeyboardKey.keyB, PhysicalKeyboardKey.keyC,
  PhysicalKeyboardKey.keyD, PhysicalKeyboardKey.keyE, PhysicalKeyboardKey.keyF,
  PhysicalKeyboardKey.keyG, PhysicalKeyboardKey.keyH, PhysicalKeyboardKey.keyI,
  PhysicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyK, PhysicalKeyboardKey.keyL,
  PhysicalKeyboardKey.keyM, PhysicalKeyboardKey.keyN, PhysicalKeyboardKey.keyO,
  PhysicalKeyboardKey.keyP, PhysicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyR,
  PhysicalKeyboardKey.keyS, PhysicalKeyboardKey.keyT, PhysicalKeyboardKey.keyU,
  PhysicalKeyboardKey.keyV, PhysicalKeyboardKey.keyW, PhysicalKeyboardKey.keyX,
  PhysicalKeyboardKey.keyY, PhysicalKeyboardKey.keyZ,
];

final Map<LogicalKeyboardKey, String> _named = {
  LogicalKeyboardKey.escape: 'Esc',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.arrowUp: 'Up',
  LogicalKeyboardKey.arrowDown: 'Down',
  LogicalKeyboardKey.arrowLeft: 'Left',
  LogicalKeyboardKey.arrowRight: 'Right',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
};

/// Names that have a `Shift-` form on the wire.
const _shiftable = {
  'Up', 'Down', 'Left', 'Right', 'Home', 'End', 'PageUp', 'PageDown', 'Delete', //
  'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
};

bool _any(Set<LogicalKeyboardKey> p, List<LogicalKeyboardKey> keys) => keys.any(p.contains);

/// Translates a key event. `null` means "not the terminal's": let it bubble
/// (Ctrl+Enter, other macOS Cmd combos, key-up, unknown keys).
///
/// Where the wire grammar has no name for a chord, the closest valid name is
/// sent: Shift is dropped from Alt/Ctrl+Shift+Tab, Shift+Backspace, Shift+Esc.
TermInput? termInputOf(KeyEvent e, {required bool mac, required Set<LogicalKeyboardKey> pressed}) {
  if (e is! KeyDownEvent && e is! KeyRepeatEvent) return null;
  final ctrl = _any(pressed, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight]);
  final alt = _any(pressed, [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight]);
  final shift = _any(pressed, [LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight]);
  final meta = _any(pressed, [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight]);
  final phys = e.physicalKey;
  final logical = e.logicalKey;

  // K2 shortcuts: Cmd on macOS, Ctrl+Shift elsewhere.
  if (mac && meta) {
    return _shortcut(e);
  }
  if (!mac && meta) return null;
  if (!mac && ctrl && shift && !alt) {
    final s = _shortcut(e);
    if (s != null) return s;
  }

  if (logical == LogicalKeyboardKey.enter || logical == LogicalKeyboardKey.numpadEnter) {
    if (ctrl) return null;
    if (shift && !alt) return TermText('\u001b\r');
    return TermKeys(['${_prefix(ctrl, alt, false)}Enter']);
  }
  if (logical == LogicalKeyboardKey.space && (ctrl || alt)) {
    return TermKeys(['${_prefix(ctrl, alt, false)}Space']);
  }
  final name = _named[logical];
  if (name != null) {
    final bareShiftTab = name == 'Tab' && shift && !ctrl && !alt;
    final useShift = shift && (_shiftable.contains(name) || bareShiftTab);
    return TermKeys(['${_prefix(ctrl, alt, useShift)}$name']);
  }

  final us = _us[phys];
  if (ctrl) {
    if (us == null) return null;
    // Letters follow the layout (logical key); punctuation uses the US table.
    final letter = _logicalLetter(logical);
    if (letter != null) return TermKeys(['${_prefix(true, alt, false)}$letter']);
    final c = shift ? us.$2 : us.$1;
    if (RegExp(r'^[a-zA-Z]$').hasMatch(c)) {
      return TermKeys(['${_prefix(true, alt, false)}${c.toLowerCase()}']);
    }
    if ('[]\\@_'.contains(c)) return TermKeys(['${_prefix(true, alt, false)}$c']);
    return null;
  }
  if (alt) {
    if (us == null) return null;
    return TermKeys(['Alt-${shift ? us.$2 : us.$1}']);
  }
  final ch = e.character;
  if (ch == null || ch.isEmpty) return null;
  final u = ch.codeUnitAt(0);
  if (u < 0x20 || u == 0x7f) return null;
  return TermText(ch);
}

String _prefix(bool ctrl, bool alt, bool shift) => '${ctrl ? 'Ctrl-' : ''}${alt ? 'Alt-' : ''}${shift ? 'Shift-' : ''}';

/// The lowercase ASCII letter a logical key is labelled with, or null.
String? _logicalLetter(LogicalKeyboardKey k) {
  final l = k.keyLabel;
  return RegExp(r'^[a-zA-Z]$').hasMatch(l) ? l.toLowerCase() : null;
}

/// Copy / paste / new terminal / end it / find / font size. Letters follow the keyboard layout
/// (logical key, falling back to the US physical position); `=` and `-` use
/// the physical key. The caller has already checked the modifiers.
TermInput? _shortcut(KeyEvent e) {
  final phys = e.physicalKey;
  final letter = _logicalLetter(e.logicalKey) ?? _us[phys]?.$1;
  if (letter == 'c') return TermAction(TermShortcut.copy);
  if (letter == 'v') return TermAction(TermShortcut.paste);
  if (letter == 't') return TermAction(TermShortcut.newTerm);
  if (letter == 'w') return TermAction(TermShortcut.closeTerm);
  if (letter == 'f') return TermReserved();
  if (phys == PhysicalKeyboardKey.equal || phys == PhysicalKeyboardKey.minus) return TermReserved();
  return null;
}
