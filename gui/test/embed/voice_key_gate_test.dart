// Runs the shared case table `Tests/voice_key_gate.json` (the Swift VoiceKeyGateTests read the
// same file), with the same mini-language and `out` tokens.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/voice_key_gate.dart';

const _modifierWords = <String, int>{
  'shift': 1 << 17,
  'ctrl': 1 << 18,
  'opt': 1 << 19,
  'cmd': 1 << 20,
  'fn': 1 << 23,
};

VoiceGateInput? _parseInput(String text) {
  final words = text.split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return null;
  switch (words.first) {
    case 'pointer':
      return words.length == 1 ? VoiceGateInput.pointer : null;
    case 'scroll':
      return words.length == 1 ? VoiceGateInput.scroll : null;
    case 'elapsed':
      return words.length == 1 ? VoiceGateInput.elapsed : null;
    case 'resign':
      return words.length == 1 ? VoiceGateInput.resign : null;
    case 'ended':
      return words.length == 1 ? VoiceGateInput.ended : null;
    case 'up':
      final code = words.length == 2 ? int.tryParse(words[1]) : null;
      return code == null ? null : VoiceGateInput.up(code);
    case 'down':
      final code = words.length >= 2 ? int.tryParse(words[1]) : null;
      if (code == null) return null;
      var flags = 0;
      var repeat = false;
      for (final w in words.skip(2)) {
        if (w == 'repeat') {
          repeat = true;
        } else if (_modifierWords[w] case final f?) {
          flags |= f;
        } else {
          return null;
        }
      }
      return VoiceGateInput.down(code, flags, repeat: repeat);
    default:
      return null;
  }
}

VoiceGateStep? _parseOutput(String text, VoiceGateInput input) {
  final isKey = input.kind == VoiceGateInputKind.down || input.kind == VoiceGateInputKind.up;
  final step = VoiceGateStep();
  // pointer and scroll always go on to A
  if (input == VoiceGateInput.pointer || input == VoiceGateInput.scroll) step.pass = true;
  for (final w in text.split(' ').where((w) => w.isNotEmpty)) {
    switch (w) {
      case 'flush':
        step.flush = true;
      case 'pass':
        step.pass = true;
      case 'arm':
        step.arm = true;
      case 'swallow':
        if (!isKey) return null; // swallow only describes key events
        step.pass = false;
      case 'none':
        break;
      default:
        final phase = VoiceKeyPhase.values.where((p) => p.name == w).firstOrNull;
        if (phase == null) return null;
        step.voice = phase;
    }
  }
  return step;
}

void main() {
  test('every case in the shared table', () {
    final cases = (jsonDecode(File('../Tests/voice_key_gate.json').readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    var ran = 0;
    for (final c in cases) {
      final name = c['name'] as String? ?? '?';
      final gate = VoiceKeyGate(
          hotkey: c.containsKey('hotkey') ? VoiceHotkey.fromJson(c['hotkey']) : VoiceHotkey.standard);
      final caseReady = c['ready'] as bool? ?? true;
      final steps = (c['steps'] as List).cast<Map<String, dynamic>>();
      for (final (i, s) in steps.indexed) {
        final label = '$name step $i (${s['t']}: ${s['in']})';
        final input = _parseInput(s['in'] as String? ?? '');
        expect(input, isNotNull, reason: label);
        final want = _parseOutput(s['out'] as String? ?? '', input!);
        expect(want, isNotNull, reason: label);
        final got = gate.handle(input,
            ms: (s['t'] as num).toInt(), ready: s['ready'] as bool? ?? caseReady);
        expect(got, want, reason: label);
      }
      ran++;
    }
    expect(ran, 26);
  });

  test('hotkey json round-trips', () {
    expect(VoiceHotkey.fromJson({'kind': 'hold_combo', 'key_code': 49, 'modifiers': 786432}),
        const VoiceHotkey.holdCombo(49, (1 << 18) | (1 << 19)));
    expect(VoiceHotkey.fromJson('off'), VoiceHotkey.off);
    expect(VoiceHotkey.fromJson({'kind': 'hold_modifier', 'key_code': 0}), VoiceHotkey.standard);
    expect(VoiceHotkey.fromJson({'kind': 'hold_combo', 'key_code': 12, 'modifiers': 1 << 20}),
        VoiceHotkey.standard);
    expect(VoiceHotkey.fromJson(null), VoiceHotkey.standard);
    expect(const VoiceHotkey.holdCombo(49, 786432).toJson(),
        {'kind': 'hold_combo', 'key_code': 49, 'modifiers': 786432});
    for (final h in [
      VoiceHotkey.off,
      VoiceHotkey.standard,
      const VoiceHotkey.holdModifier(63),
      const VoiceHotkey.holdCombo(49, 786432),
    ]) {
      expect(VoiceHotkey.fromJson(h.toJson()), h);
    }
  });

  test('mac key codes', () {
    expect(macKeyCode(PhysicalKeyboardKey.altRight), 61);
    expect(macKeyCode(PhysicalKeyboardKey.escape), 53);
    expect(macKeyCode(PhysicalKeyboardKey.fn), 63);
  });
}
