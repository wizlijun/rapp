import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/voice_hotkey.dart';
import 'package:rapp/embed/voice_key_gate.dart';

const _shift = 1 << 17;
const _ctrl = 1 << 18;
const _opt = 1 << 19;
const _cmd = 1 << 20;

void main() {
  test('labels', () {
    expect(voiceHotkeyLabel(VoiceHotkey.standard), '长按 右 ⌥');
    expect(voiceHotkeyLabel(const VoiceHotkey.holdCombo(49, 786432)), '按住 ⌃⌥Space');
    expect(voiceHotkeyLabel(VoiceHotkey.off), '关');
    expect(voiceHotkeyLabel(const VoiceHotkey.holdModifier(63)), '长按 Fn');
    expect(voiceHotkeyLabel(const VoiceHotkey.holdCombo(0, _opt | _shift)), '按住 ⌥⇧A');
    expect(voiceHotkeyLabel(const VoiceHotkey.holdCombo(122, _opt)), '按住 ⌥F1');
    expect(voiceHotkeyLabel(const VoiceHotkey.holdCombo(123, _opt)), '按住 ⌥←');
    expect(voiceHotkeyLabel(const VoiceHotkey.holdCombo(18, _opt)), '按住 ⌥1');
    expect(voiceHotkeyLabel(const VoiceHotkey.holdCombo(99, _opt)), '按住 ⌥F3');
    expect(voiceHotkeyLabel(const VoiceHotkey.holdCombo(50, _opt)), '按住 ⌥键 50');
  });

  test('a lone modifier tap sets a hold', () {
    final r = VoiceHotkeyRecorder();
    expect(r.down(62, _ctrl), isA<RecordPending>());
    final o = r.up(62);
    expect(o, isA<RecordSet>());
    expect((o as RecordSet).hotkey, const VoiceHotkey.holdModifier(62));
  });

  test('a combo sets at once', () {
    final r = VoiceHotkeyRecorder();
    expect(r.down(59, _ctrl), isA<RecordPending>());
    final o = r.down(49, _ctrl);
    expect((o as RecordSet).hotkey, const VoiceHotkey.holdCombo(49, 1 << 18));
  });

  test('rejected keys', () {
    for (final (code, flags) in [
      (0, 0),
      (0, _shift),
      (48, _opt),
      (12, _cmd),
      (36, _ctrl),
      (0, _ctrl | _cmd),
      (57, 0),
    ]) {
      expect(VoiceHotkeyRecorder().down(code, flags), isA<RecordRejected>(), reason: '$code $flags');
    }
    final r = VoiceHotkeyRecorder();
    expect(r.down(57, 0), isA<RecordRejected>());
    expect(r.up(57), isA<RecordPending>());
  });

  test('esc aborts', () {
    expect(VoiceHotkeyRecorder().down(53, 0), isA<RecordAborted>());
  });

  test('modifier then a key is not a lone tap', () {
    final r = VoiceHotkeyRecorder();
    expect(r.down(58, _opt), isA<RecordPending>());
    expect((r.down(0, _opt) as RecordSet).hotkey, const VoiceHotkey.holdCombo(0, _opt));
    expect(r.up(58), isA<RecordPending>());
  });
}
