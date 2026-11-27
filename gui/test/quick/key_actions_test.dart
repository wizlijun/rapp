import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/modifier_latch.dart';
import 'package:rapp/embed/strip_tools.dart';
import 'package:rapp/quick/key_actions.dart';

void main() {
  test('chord parses, prints and labels', () {
    final c = Chord.parse('ctrl+alt+x')!;
    expect(c.toJson(), 'ctrl+alt+x');
    expect(c.label, '⌃⌥X');
    expect(Chord.parse('shift+tab')!.label, '⇧Tab');
    expect(Chord.parse('cmd+t')!.label, '⌘T');
    for (final bad in ['', 'ctrl+', 'hyper+a', 'ctrl+ab', 'ctrl+more', 7, null]) {
      expect(Chord.parse(bad), isNull);
    }
  });
  test('chord wire names for the terminal', () {
    expect(Chord.parse('ctrl+r')!.termWire, 'Ctrl-R');
    expect(Chord.parse('shift+tab')!.termWire, 'Shift-Tab');
    expect(Chord.parse('alt+x')!.termWire, 'Alt-x');
    expect(Chord.parse('shift+x')!.termWire, 'X');
    expect(Chord.parse('ctrl+shift+r')!.termWire, 'Ctrl-Shift-R');
    expect(Chord.parse('ctrl+pgup')!.termWire, 'Ctrl-PageUp');
    expect(Chord.parse('cmd+t')!.termWire, isNull);
    expect(Chord.parse('cmd+t')!.termCommand, 't');
    expect(Chord.parse('cmd+k')!.termCommand, isNull);
    expect(Chord.parse('cmd+shift+t')!.termCommand, isNull);
  });
  test('chord mac key codes', () {
    expect(Chord.parse('ctrl+r')!.macKey, (code: 15, mods: latchCtrl));
    expect(Chord.parse('cmd+5')!.macKey, (code: 23, mods: latchCmd));
    expect(Chord.parse('shift+tab')!.macKey, (code: 48, mods: latchShift));
  });
  test('builtin actions and per-tool chords', () {
    expect(builtinKeyActions.map((a) => a.id), ['search', 'mode', 'expand', 'bg', 'clear', 'newtab']);
    final search = builtinKeyActions.first;
    expect(chordFor(search, null)!.toJson(), 'ctrl+r');
    expect(chordFor(search, agentTools.firstWhere((t) => t.id == 'opencode')), isNull);
    expect(KeyAction.fromJson(search.toJson()), search);
    expect(KeyAction.fromJson({'id': 'x', 'label': ' ', 'chord': 'ctrl+r'}), isNull);
    expect(
        KeyAction.fromJson({'id': 'x', 'label': 'a', 'chord': 'ctrl+r', 'per': {'codex': 'bad', 'gemini': null}})!.per,
        {'gemini': null});
    expect(quickId(), matches(RegExp(r'^[a-z0-9]{8}$')));
  });
}
