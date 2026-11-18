// How a voice hotkey reads in the settings row, and the recorder that turns the keys a user
// presses into a new one. Acceptance rules live in voice_key_gate.dart (`acceptsCombo`).
import 'voice_key_gate.dart';

const int _shift = 1 << 17;
const int _control = 1 << 18;
const int _option = 1 << 19;
const int _command = 1 << 20;

const _modifierNames = {
  61: '右 ⌥',
  58: '左 ⌥',
  62: '右 ⌃',
  59: '左 ⌃',
  60: '右 ⇧',
  56: '左 ⇧',
  54: '右 ⌘',
  55: '左 ⌘',
  63: 'Fn',
};

/// ANSI macOS virtual key codes to key names.
const _keyNames = {
  0: 'A', 11: 'B', 8: 'C', 2: 'D', 14: 'E', 3: 'F', 5: 'G', 4: 'H', 34: 'I', 38: 'J',
  40: 'K', 37: 'L', 46: 'M', 45: 'N', 31: 'O', 35: 'P', 12: 'Q', 15: 'R', 1: 'S', 17: 'T',
  32: 'U', 9: 'V', 13: 'W', 7: 'X', 16: 'Y', 6: 'Z',
  29: '0', 18: '1', 19: '2', 20: '3', 21: '4', 23: '5', 22: '6', 26: '7', 28: '8', 25: '9',
  122: 'F1', 120: 'F2', 99: 'F3', 118: 'F4', 96: 'F5', 97: 'F6',
  98: 'F7', 100: 'F8', 101: 'F9', 109: 'F10', 103: 'F11', 111: 'F12',
  123: '←', 124: '→', 126: '↑', 125: '↓', 49: 'Space', 36: '↩',
};

/// 「长按 右 ⌥」, 「按住 ⌃⌥Space」 or 「关」.
String voiceHotkeyLabel(VoiceHotkey h, {bool linux = false}) {
  if (h.isOff) return '关';
  if (h.isModifier) {
    var name = _modifierNames[h.keyCode] ?? '键 ${h.keyCode}';
    if (linux) name = name.replaceAll('⌥', 'Alt').replaceAll('⌃', 'Ctrl').replaceAll('⇧', 'Shift').replaceAll('⌘', 'Super');
    return '长按 $name';
  }
  final m = h.modifiers;
  if (linux) {
    final keys = [if (m & _control != 0) 'Ctrl', if (m & _option != 0) 'Alt',
      if (m & _shift != 0) 'Shift', if (m & _command != 0) 'Super', _keyNames[h.keyCode] ?? '键 ${h.keyCode}'];
    return '按住 ${keys.join('+')}';
  }
  final glyphs = '${m & _control != 0 ? '⌃' : ''}${m & _option != 0 ? '⌥' : ''}'
      '${m & _shift != 0 ? '⇧' : ''}${m & _command != 0 ? '⌘' : ''}';
  return '按住 $glyphs${_keyNames[h.keyCode] ?? '键 ${h.keyCode}'}';
}

sealed class RecordOutcome {
  const RecordOutcome();
}

/// Still waiting for more keys.
class RecordPending extends RecordOutcome {
  const RecordPending();
}

class RecordSet extends RecordOutcome {
  const RecordSet(this.hotkey);
  final VoiceHotkey hotkey;
}

/// The key cannot be a hotkey.
class RecordRejected extends RecordOutcome {
  const RecordRejected();
}

/// Esc: the user gave up.
class RecordAborted extends RecordOutcome {
  const RecordAborted();
}

class VoiceHotkeyRecorder {
  VoiceHotkeyRecorder({this.linux = false});
  final bool linux;
  /// A modifier that went down and nothing else has since: it becomes a hold on its release.
  int? _lone;

  /// Modifier keys currently held.
  final _held = <int>{};

  /// A second modifier or another key went down during this hold: no lone tap until all
  /// modifiers are up.
  bool _poisoned = false;

  RecordOutcome down(int code, int flags) {
    if (code == 53) {
      _lone = null;
      _held.clear();
      _poisoned = false;
      return const RecordAborted();
    }
    // These keys belong to the Linux desktop or rapp's window navigation.
    if (linux && (code == 54 || code == 55 || code == 103 || flags & _command != 0 ||
        (flags & (_control | _option | _shift) == _control && {31, 33, 30}.contains(code)))) {
      _lone = null;
      _poisoned = true;
      return const RecordRejected();
    }
    if (modifierCodes.contains(code)) {
      if (code == 57) {
        _lone = null;
        _poisoned = true;
        return const RecordRejected();
      }
      _held.add(code);
      if (_held.length > 1 || _poisoned) {
        _poisoned = true;
        _lone = null;
      } else {
        _lone = code;
      }
      return const RecordPending();
    }
    _lone = null;
    if (_held.isNotEmpty) _poisoned = true;
    final mods = flags & (_control | _option | _shift | _command);
    return acceptsCombo(code, mods) ? RecordSet(VoiceHotkey.holdCombo(code, mods)) : const RecordRejected();
  }

  RecordOutcome up(int code) {
    final lone = _lone;
    _held.remove(code);
    if (_held.isEmpty) _poisoned = false;
    if (lone != null && code == lone) {
      _lone = null;
      return RecordSet(VoiceHotkey.holdModifier(code));
    }
    return const RecordPending();
  }
}
