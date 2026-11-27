// Named key actions of the 快捷区 first row: a label and a key chord, optionally a different chord (or none) per AI
// tool. Pure data: the strip decides when to show them and the sender what goes out (spec §6).
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../embed/key_bar_keys.dart';
import '../embed/modifier_latch.dart';
import '../embed/strip_tools.dart';

/// The non-letter, non-digit keys a chord may end in.
const chordNamedKeys = ['esc', 'tab', 'enter', 'bksp', 'left', 'up', 'down', 'right', 'pgup', 'pgdn'];

/// The ⌘ letters the terminal stage runs itself (term_stage `_command`); other ⌘ chords are grey on a terminal.
const termCommandLetters = {'c', 'v', 't', 'w'};

final _plainKey = RegExp(r'^[a-z0-9]$');

/// A key with modifiers. JSON form: `ctrl+alt+shift+cmd` in that order, then the key (`ctrl+r`, `shift+tab`).
@immutable
class Chord {
  const Chord(this.key, {this.ctrl = false, this.alt = false, this.shift = false, this.cmd = false});

  /// `a`-`z`, `0`-`9` or one of [chordNamedKeys].
  final String key;
  final bool ctrl, alt, shift, cmd;

  /// Null when [j] is not a well-formed chord string.
  static Chord? parse(Object? j) {
    if (j is! String || j.isEmpty) return null;
    final parts = j.split('+');
    final key = parts.last;
    if (!_plainKey.hasMatch(key) && !chordNamedKeys.contains(key)) return null;
    final mods = parts.take(parts.length - 1).toList();
    if (mods.toSet().length != mods.length) return null;
    for (final m in mods) {
      if (!const {'ctrl', 'alt', 'shift', 'cmd'}.contains(m)) return null;
    }
    return Chord(key,
        ctrl: mods.contains('ctrl'), alt: mods.contains('alt'), shift: mods.contains('shift'), cmd: mods.contains('cmd'));
  }

  String toJson() => [if (ctrl) 'ctrl', if (alt) 'alt', if (shift) 'shift', if (cmd) 'cmd', key].join('+');

  /// The key face: ⌃⌥⇧⌘ then the letter upper-cased, the digit, or the bar key's label.
  String get label =>
      '${ctrl ? '⌃' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}${cmd ? '⌘' : ''}'
      '${_plainKey.hasMatch(key) ? key.toUpperCase() : barKeys[key]!.label}';

  bool get _isLetter => RegExp(r'^[a-z]$').hasMatch(key);

  /// The terminal wire name, `[Ctrl-][Alt-][Shift-]base`; null with ⌘ (a terminal has no ⌘ key).
  String? get termWire {
    if (cmd) return null;
    if (!_plainKey.hasMatch(key)) {
      final base = barKeys[key]!.wire!;
      // A named key carries its own Shift (Shift-Tab): fold it in.
      final parts = base.split('-');
      final s = shift || parts.contains('Shift');
      return '${ctrl ? 'Ctrl-' : ''}${alt ? 'Alt-' : ''}${s ? 'Shift-' : ''}${parts.last}';
    }
    // A bare shifted letter is just the capital; with ⌃ the letter is upper-case and Shift stays a prefix.
    final upper = ctrl || (shift && !ctrl && _isLetter);
    final base = upper ? key.toUpperCase() : key;
    final keepShift = shift && !(_isLetter && !ctrl);
    return '${ctrl ? 'Ctrl-' : ''}${alt ? 'Alt-' : ''}${keepShift ? 'Shift-' : ''}$base';
  }

  /// The letter for rApp's own ⌘ shortcut: only exactly ⌘ and a [termCommandLetters] letter.
  String? get termCommand => cmd && !ctrl && !alt && !shift && termCommandLetters.contains(key) ? key : null;

  /// The macOS key code and modifier bits, as an app session takes them.
  ({int code, int mods}) get macKey {
    final code = _plainKey.hasMatch(key) ? (macLetterCodes[key] ?? macDigitCodes[key]!) : barKeys[key]!.code!;
    final mods =
        (ctrl ? latchCtrl : 0) | (alt ? latchOpt : 0) | (shift ? latchShift : 0) | (cmd ? latchCmd : 0);
    return (code: code, mods: mods);
  }

  @override
  bool operator ==(Object other) =>
      other is Chord && other.key == key && other.ctrl == ctrl && other.alt == alt && other.shift == shift && other.cmd == cmd;

  @override
  int get hashCode => Object.hash(key, ctrl, alt, shift, cmd);

  @override
  String toString() => 'Chord(${toJson()})';
}

/// A named key action. [per] overrides the chord by AI tool id; a null value means the action is off on that tool.
@immutable
class KeyAction {
  const KeyAction(this.id, {required this.label, required this.chord, this.per = const {}});

  final String id, label;
  final Chord chord;
  final Map<String, Chord?> per;

  /// How layouts, stars and counts name it (Ruling 1).
  String get ref => 'k:$id';

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'chord': chord.toJson(),
        if (per.isNotEmpty) 'per': {for (final e in per.entries) e.key: e.value?.toJson()},
      };

  static KeyAction? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], label = j['label'];
    if (id is! String || id.isEmpty || label is! String || label.trim().isEmpty) return null;
    final chord = Chord.parse(j['chord']);
    if (chord == null) return null;
    final per = <String, Chord?>{};
    final raw = j['per'];
    if (raw is Map) {
      for (final e in raw.entries) {
        if (e.key is! String) continue;
        if (e.value == null) {
          per[e.key as String] = null;
        } else {
          final c = Chord.parse(e.value);
          if (c != null) per[e.key as String] = c;
        }
      }
    }
    return KeyAction(id, label: label, chord: chord, per: per);
  }

  @override
  bool operator ==(Object other) =>
      other is KeyAction && other.id == id && other.label == label && other.chord == chord && mapEquals(other.per, per);

  @override
  int get hashCode => Object.hash(id, label, chord, Object.hashAllUnordered(per.entries.map((e) => Object.hash(e.key, e.value))));
}

/// What [a] sends on [tool]; null when it is off there. No tool: the plain chord.
Chord? chordFor(KeyAction a, AgentTool? tool) =>
    tool != null && a.per.containsKey(tool.id) ? a.per[tool.id] : a.chord;

/// The five actions a fresh install holds, in menu order. `search` follows the per-tool table the 常用语条 had
/// (agy and opencode have no such key); the others were checked on 2026-11-27 and none does harm on any tool (spec §6.2).
const builtinKeyActions = <KeyAction>[
  KeyAction('search', label: '搜历史', chord: Chord('r', ctrl: true), per: {'agy': null, 'opencode': null}),
  KeyAction('expand', label: '展开输出', chord: Chord('o', ctrl: true)),
  KeyAction('bg', label: '转后台', chord: Chord('b', ctrl: true)),
  KeyAction('clear', label: '清屏', chord: Chord('l', ctrl: true)),
  KeyAction('newtab', label: '新标签', chord: Chord('t', cmd: true)),
];

/// A random 8-character id of `[a-z0-9]`.
String quickId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return String.fromCharCodes([for (var i = 0; i < 8; i++) chars.codeUnitAt(r.nextInt(chars.length))]);
}
