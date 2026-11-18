// Hold-to-talk on the stage picture, the Dart twin of `Sources/RappSession/VoiceKeyGate.swift`:
// which key starts the voice input, and the pure state machine that decides, event by event,
// whether the hotkey is being held for voice and what still goes on to A. The rules are pinned by
// the shared case table `Tests/voice_key_gate.json`, which both twins run. No timers here: the
// caller schedules `elapsed` when a step says `arm`.
//
// Key codes are macOS virtual key codes and flags are KeyFlags (CGEventFlags) bits, as in Swift.
import 'package:flutter/services.dart';

const int _shift = 1 << 17;
const int _control = 1 << 18;
const int _option = 1 << 19;
const int _command = 1 << 20;
const int _function = 1 << 23;

/// ⌃ ⌥ ⇧ ⌘: the modifiers a combo hotkey compares.
const int _comboMask = _control | _option | _shift | _command;

/// Key codes of the modifier keys (⌘ 54/55, ⇧ 56/60, ⇪ 57, ⌥ 58/61, ⌃ 59/62, fn 63).
const modifierCodes = {54, 55, 56, 57, 58, 59, 60, 61, 62, 63};

/// Modifier keys a `hold_modifier` hotkey may use (every modifier except caps lock).
const _holdModifierCodes = {54, 55, 56, 58, 59, 60, 61, 62, 63};

/// Whether `code` held with `mods` may be a `hold_combo` hotkey: a non-modifier key other than
/// Esc (53) and Tab (48), with at least one of ⌃ ⌥ ⌘, and not one of rapp's own shortcuts
/// (⌃⌘ anything, ⌘Q, ⌃↩).
bool acceptsCombo(int code, int mods) {
  if (modifierCodes.contains(code) || code == 53 || code == 48) return false;
  if (mods & (_control | _option | _command) == 0) return false;
  if (mods & (_control | _command) == (_control | _command)) return false;
  final m = mods & _comboMask;
  if (m == _command && code == 12) return false;
  if (m == _control && (code == 36 || code == 76)) return false;
  return true;
}

enum _HotkeyKind { modifier, combo, off }

class VoiceHotkey {
  /// Long press of one modifier key, alone.
  const VoiceHotkey.holdModifier(this.keyCode)
      : _kind = _HotkeyKind.modifier,
        modifiers = 0;

  /// A key held with exactly these modifiers (within ⌃ ⌥ ⇧ ⌘); starts at once.
  const VoiceHotkey.holdCombo(this.keyCode, this.modifiers) : _kind = _HotkeyKind.combo;

  const VoiceHotkey._off()
      : _kind = _HotkeyKind.off,
        keyCode = -1,
        modifiers = 0;

  static const off = VoiceHotkey._off();

  /// Long press of Right Option.
  static const standard = VoiceHotkey.holdModifier(61);

  /// Parses the value gui.json stores: `"off"`, `{"kind":"hold_modifier","key_code":61}` or
  /// `{"kind":"hold_combo","key_code":49,"modifiers":786432}`. Anything invalid or missing gives
  /// [standard].
  factory VoiceHotkey.fromJson(Object? j) {
    if (j == 'off') return off;
    if (j is! Map) return standard;
    final kind = j['kind'];
    final code = j['key_code'];
    if (kind is! String || code is! int || code < 0 || code > 0xFFFF) return standard;
    switch (kind) {
      case 'hold_modifier' when _holdModifierCodes.contains(code):
        return VoiceHotkey.holdModifier(code);
      case 'hold_combo':
        final rawMods = j['modifiers'];
        if (rawMods is! int || rawMods < 0) return standard;
        final mods = rawMods & _comboMask;
        return acceptsCombo(code, mods) ? VoiceHotkey.holdCombo(code, mods) : standard;
      default:
        return standard;
    }
  }

  final _HotkeyKind _kind;

  /// The hotkey's key code; -1 when [isOff].
  final int keyCode;

  /// The combo's KeyFlags bits; 0 unless a combo.
  final int modifiers;

  bool get isOff => _kind == _HotkeyKind.off;
  bool get isModifier => _kind == _HotkeyKind.modifier;

  Object toJson() => switch (_kind) {
        _HotkeyKind.off => 'off',
        _HotkeyKind.modifier => {'kind': 'hold_modifier', 'key_code': keyCode},
        _HotkeyKind.combo => {'kind': 'hold_combo', 'key_code': keyCode, 'modifiers': modifiers},
      };

  @override
  bool operator ==(Object other) =>
      other is VoiceHotkey &&
      other._kind == _kind &&
      other.keyCode == keyCode &&
      other.modifiers == modifiers;

  @override
  int get hashCode => Object.hash(_kind, keyCode, modifiers);

  @override
  String toString() => 'VoiceHotkey(${toJson()})';
}

enum VoiceKeyPhase { start, release, cancel, edit }

enum VoiceGateInputKind { down, up, pointer, scroll, elapsed, resign, ended }

class VoiceGateInput {
  const VoiceGateInput.down(this.code, this.flags, {this.repeat = false})
      : kind = VoiceGateInputKind.down;
  const VoiceGateInput.up(this.code)
      : kind = VoiceGateInputKind.up,
        flags = 0,
        repeat = false;
  const VoiceGateInput._(this.kind)
      : code = -1,
        flags = 0,
        repeat = false;

  static const pointer = VoiceGateInput._(VoiceGateInputKind.pointer);
  static const scroll = VoiceGateInput._(VoiceGateInputKind.scroll);
  static const elapsed = VoiceGateInput._(VoiceGateInputKind.elapsed);
  static const resign = VoiceGateInput._(VoiceGateInputKind.resign);
  static const ended = VoiceGateInput._(VoiceGateInputKind.ended);

  final VoiceGateInputKind kind;

  /// The macOS key code of a down or up; -1 otherwise.
  final int code;

  /// The KeyFlags bits held with a down.
  final int flags;
  final bool repeat;

  @override
  bool operator ==(Object other) =>
      other is VoiceGateInput &&
      other.kind == kind &&
      other.code == code &&
      other.flags == flags &&
      other.repeat == repeat;

  @override
  int get hashCode => Object.hash(kind, code, flags, repeat);

  @override
  String toString() => switch (kind) {
        VoiceGateInputKind.down => 'down($code, $flags${repeat ? ', repeat' : ''})',
        VoiceGateInputKind.up => 'up($code)',
        _ => kind.name,
      };
}

class VoiceGateStep {
  VoiceGateStep({this.flush = false, this.pass = false, this.arm = false, this.voice});

  /// Send the held hotkey down to A first (it was swallowed while pending).
  bool flush;

  /// This event goes on to A (pointer and scroll always do).
  bool pass;

  /// Feed `elapsed` in [VoiceKeyGate.holdDelay] seconds.
  bool arm;
  VoiceKeyPhase? voice;

  @override
  bool operator ==(Object other) =>
      other is VoiceGateStep &&
      other.flush == flush &&
      other.pass == pass &&
      other.arm == arm &&
      other.voice == voice;

  @override
  int get hashCode => Object.hash(flush, pass, arm, voice);

  @override
  String toString() =>
      'VoiceGateStep(flush: $flush, pass: $pass, arm: $arm, voice: ${voice?.name})';
}

enum _State {
  idle,

  /// The hotkey modifier is down and swallowed; a long enough hold starts recording.
  pending,
  recording,

  /// Recording was cancelled, sent to the editor or ended: everything is swallowed until the
  /// hotkey itself is released.
  decided,
}

class VoiceKeyGate {
  VoiceKeyGate({this._hotkey = VoiceHotkey.standard});

  /// How long a `hold_modifier` hotkey must be held before recording starts, in seconds.
  static const holdDelay = 0.3;

  /// The hotkey in force; changed only through [setHotkey].
  VoiceHotkey get hotkey => _hotkey;
  VoiceHotkey _hotkey;

  var _state = _State.idle;

  /// When [_State.pending] began, in seconds.
  double _since = 0;

  /// Keys the gate has seen go down and not yet come up.
  final _down = <int>{};

  /// Keys whose down was swallowed, so their up is swallowed too.
  final _swallowed = <int>{};

  bool get recording => _state == _State.recording;

  /// The setting changes (关, 恢复默认 or a new key recorded) while keys may be held. A real change starts
  /// over: a hold of the old key is no hold any more, and its up never reaches the hotkey rules, so a
  /// recording is cancelled here (or it would end in `decided`, swallowing every key with no hotkey up to
  /// return it). Held and swallowed keys are kept, so the old key's up stays away from the target. The
  /// caller drops its hold timer and the held down. Setting the same hotkey does nothing.
  VoiceGateStep setHotkey(VoiceHotkey h) {
    if (h == _hotkey) return VoiceGateStep();
    _hotkey = h;
    final wasRecording = _state == _State.recording;
    _state = _State.idle;
    return VoiceGateStep(voice: wasRecording ? VoiceKeyPhase.cancel : null);
  }

  /// The step for [i] at [ms] milliseconds; [ready] says whether a recording may start now.
  VoiceGateStep handle(VoiceGateInput i, {required int ms, required bool ready}) {
    final seconds = ms / 1000;
    switch (i.kind) {
      case VoiceGateInputKind.down:
        final code = i.code;
        // A key already held whose down reached A: a swallowed repeat must not swallow its up
        // too, or A keeps it down (a key held before a combo start).
        final reachedA = _down.contains(code) && !_swallowed.contains(code);
        _swallowed.remove(code);
        final step = _keyDown(code, i.flags, i.repeat, seconds, ready);
        _down.add(code);
        if (step.flush) _flushHotkey();
        if (!step.pass && !reachedA) _swallowed.add(code);
        return step;
      case VoiceGateInputKind.up:
        final code = i.code;
        final wasSwallowed = _swallowed.remove(code);
        _down.remove(code);
        var step = VoiceGateStep(pass: !wasSwallowed);
        if (hotkey.isOff || code != hotkey.keyCode) return step;
        switch (_state) {
          case _State.idle:
            break;
          case _State.pending:
            step = VoiceGateStep(flush: true, pass: true); // a tap: A gets the down and the up
          case _State.recording:
            step = VoiceGateStep(voice: VoiceKeyPhase.release);
          case _State.decided:
            step = VoiceGateStep();
        }
        _state = _State.idle;
        return step;
      case VoiceGateInputKind.pointer:
      case VoiceGateInputKind.scroll:
        final step = VoiceGateStep(pass: true);
        switch (_state) {
          case _State.pending:
            step.flush = true;
            _flushHotkey();
            _state = _State.idle;
          case _State.recording when i.kind == VoiceGateInputKind.pointer:
            step.voice = VoiceKeyPhase.cancel;
            _state = _State.decided;
          default:
            break;
        }
        return step;
      case VoiceGateInputKind.elapsed:
        if (_state != _State.pending || !(seconds - _since >= holdDelay)) return VoiceGateStep();
        _state = _State.recording;
        return VoiceGateStep(voice: VoiceKeyPhase.start);
      case VoiceGateInputKind.resign:
        // A loses the keyboard: forget what is held (its ups may never come), but keep the
        // swallowed codes so the hotkey's eventual up still stays away from A.
        final wasRecording = _state == _State.recording;
        _state = _State.idle;
        _down.clear();
        return VoiceGateStep(voice: wasRecording ? VoiceKeyPhase.cancel : null);
      case VoiceGateInputKind.ended:
        if (_state == _State.recording) _state = _State.decided;
        return VoiceGateStep();
    }
  }

  /// The step for a key down; [_down] and [_swallowed] are updated by the caller.
  VoiceGateStep _keyDown(int code, int flags, bool repeat, double seconds, bool ready) {
    switch (_state) {
      case _State.idle:
        if (hotkey.isOff) return VoiceGateStep(pass: true);
        final key = hotkey.keyCode;
        if (hotkey.isModifier) {
          if (code != key || repeat || !ready || _othersDown(key, flags)) {
            return VoiceGateStep(pass: true);
          }
          _state = _State.pending;
          _since = seconds;
          return VoiceGateStep(arm: true);
        }
        if (code != key || repeat || !ready || flags & _comboMask != hotkey.modifiers) {
          return VoiceGateStep(pass: true);
        }
        _state = _State.recording;
        return VoiceGateStep(voice: VoiceKeyPhase.start);
      case _State.pending:
        if (code == hotkey.keyCode) return VoiceGateStep(); // a repeat of the held key
        _state = _State.idle; // anything else pressed with the hotkey: it was a modifier for A
        return VoiceGateStep(flush: true, pass: true);
      case _State.recording:
        if (code == 53) {
          _state = _State.decided;
          return VoiceGateStep(voice: VoiceKeyPhase.cancel);
        }
        if (code == 48) {
          _state = _State.decided;
          return VoiceGateStep(voice: VoiceKeyPhase.edit);
        }
        return VoiceGateStep();
      case _State.decided:
        return VoiceGateStep();
    }
  }

  /// The held hotkey down goes to A after all, so its up must reach A too.
  void _flushHotkey() {
    if (!hotkey.isOff) _swallowed.remove(hotkey.keyCode);
  }

  /// Whether anything besides the hotkey modifier itself is held.
  bool _othersDown(int key, int flags) {
    if (_down.any((c) => c != key)) return true;
    final own = switch (key) {
      58 || 61 => _option,
      59 || 62 => _control,
      56 || 60 => _shift,
      54 || 55 => _command,
      63 => _function,
      _ => 0,
    };
    return flags & (_comboMask | _function) & ~own != 0;
  }
}

/// macOS virtual key code → Flutter physical key, inverted once.
final Map<PhysicalKeyboardKey, int> _macCodes = {
  for (final e in kMacOsToPhysicalKey.entries) e.value: e.key,
};

/// The macOS virtual key code of [k], or null when macOS has none.
int? macKeyCode(PhysicalKeyboardKey k) => _macCodes[k];

/// The KeyFlags bits (⌃ ⌥ ⇧ ⌘ fn) held on [hk] now.
int macFlags(HardwareKeyboard hk) {
  var f = 0;
  if (hk.isControlPressed) f |= _control;
  if (hk.isAltPressed) f |= _option;
  if (hk.isShiftPressed) f |= _shift;
  if (hk.isMetaPressed) f |= _command;
  if (hk.physicalKeysPressed.contains(PhysicalKeyboardKey.fn)) f |= _function;
  return f;
}
