import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/state_rules.dart';

Map packOf(String builtin, String id) =>
    ((jsonDecode(builtin) as Map)['packs'] as List).cast<Map>().firstWhere((p) => p['id'] == id);

void main() {
  final builtin = File('assets/state_rules.json').readAsStringSync();
  final lib = StateRulesLibrary.parse(builtin, {});

  test('merge: objects by key, null deletes, arrays replace', () {
    expect(mergeRules({'a': {'x': 1, 'y': 2}, 'b': [1, 2]}, {'a': {'y': null, 'z': 4}, 'b': [9]}),
        {'a': {'x': 1, 'z': 4}, 'b': [9]});
  });

  test('choose: by ids, off, by name, and nothing for an unknown app', () {
    expect(lib.choose('com.openai.codex', null)!.id, 'chatgpt-desktop');
    expect(lib.choose('com.openai.codex', 'off'), isNull);
    expect(lib.choose('com.example.chat', null), isNull); // generic-chat has empty ids
    expect(lib.choose('com.example.chat', 'generic-chat')!.id, 'generic-chat');
    expect(lib.choose('com.example.chat', 'nope'), isNull);
    expect(lib.choose('COM.OPENAI.CODEX', null)!.id, 'chatgpt-desktop');
  });

  test('extends resolves; the child wins; variants stay', () {
    final c = lib.choose('com.anthropic.claudefordesktop', null)!;
    final m = jsonDecode(c.json) as Map;
    expect(m.containsKey('extends'), isFalse);
    expect(m['regions']['sidebar'], isNotNull);
    expect(m['signals']['rowDot']['detect']['color'], 'green');
  });

  test('three layers stack: extends, then a variant (on the host), then a mine patch', () {
    final lib = StateRulesLibrary.parse(builtin, {
      'fix.json': '{"format":"1.0","patchOf":"chatgpt-desktop","rev":3,"patch":{"states":[{"state":"idle"}]}}'
    });
    final c = lib.choose('com.openai.codex', null)!;
    expect(c.layer, RulesLayer.mine);
    expect(c.patched, isTrue);
    expect(c.rev, 1);
    expect((jsonDecode(c.json) as Map)['states'], [
      {'state': 'idle'}
    ]);
  });

  test('a newer rev wins whatever its layer; a tie goes to mine', () {
    final newer = jsonEncode({...packOf(builtin, 'chatgpt-desktop'), 'rev': 2, 'name': 'mine'});
    expect(StateRulesLibrary.parse(builtin, {'a.json': newer}).choose('com.openai.codex', null)!.layer, RulesLayer.mine);
    final older = jsonEncode({...packOf(builtin, 'chatgpt-desktop'), 'rev': 0});
    expect(StateRulesLibrary.parse(builtin, {'a.json': older}).choose('com.openai.codex', null)!.layer,
        RulesLayer.builtin);
    final tie = jsonEncode({...packOf(builtin, 'chatgpt-desktop')});
    expect(StateRulesLibrary.parse(builtin, {'a.json': tie}).choose('com.openai.codex', null)!.layer, RulesLayer.mine);
  });

  test('bad mine files are listed and skipped; cycles and oversize packs are not chosen', () {
    final lib = StateRulesLibrary.parse(builtin, {
      'bad.json': '{',
      'future.json': '{"format":"2.0","id":"x"}',
      'a.json': '{"format":"1.0","id":"a","ids":["com.a"],"extends":"b"}',
      'b.json': '{"format":"1.0","id":"b","extends":"a"}',
      'big.json': jsonEncode({'format': '1.0', 'id': 'big', 'ids': ['com.big'], 'pad': 'x' * stateRulesLimit})
    });
    expect(lib.errors, hasLength(2));
    expect(lib.choose('com.a', null), isNull);
    expect(lib.choose('com.big', null), isNull);
    expect(lib.choose('com.openai.codex', null), isNotNull);
  });

  test('a broken or missing built-in asset is no built-in packs, not a throw', () {
    expect(StateRulesLibrary.parse('{', {}).choose('com.openai.codex', null), isNull);
    expect(StateRulesLibrary.parse(null, {}).choose('com.openai.codex', null), isNull);
  });

  test('tally counts signal statuses of the resolved pack', () {
    final t = lib.choose('com.openai.codex', null)!.tally;
    expect(t.tested + t.seen + t.reported + t.untested, greaterThan(0));
    expect(t.seen, 2); // rowDot, workedFor
    expect(t.untested, 3); // stop, rowBusy, ask
  });

  test('merge onto a non-object base strips nulls like Swift', () {
    expect(mergeRules(5, {'a': null, 'b': {'c': null}}), {'b': <String, Object?>{}});
    expect(mergeRules({'a': 5}, {'a': {'x': null, 'y': 1}}), {'a': {'y': 1}});
  });

  test('a hostile deep file is an error, and choose does not throw', () {
    final deep = '${'{"a":' * 20000}1${'}' * 20000}';
    final lib = StateRulesLibrary.parse(builtin, {
      'deep.json': '{"format":"1.0","id":"d","ids":["com.d"],"x":$deep}'
    });
    expect(lib.errors, hasLength(1));
    expect(lib.choose('com.d', null), isNull);
    expect(lib.choose('com.openai.codex', null), isNotNull);
  });

  test('a patch on the base reaches the extender, flagged patched and mine', () {
    final lib = StateRulesLibrary.parse(builtin, {
      'g.json': '{"format":"1.0","patchOf":"generic-chat","patch":{"regions":{"tail":{"box":{"height":99}}}}}'
    });
    final c = lib.choose('com.anthropic.claudefordesktop', null)!;
    expect(c.patched, isTrue);
    expect(c.layer, RulesLayer.mine);
    expect((jsonDecode(c.json) as Map)['regions']['tail']['box']['height'], 99);
    expect(c.id, 'claude-desktop');
  });

  test('equal rev and layer: the extender beats its base, then file name ascending', () {
    final base = {'format': '1.0', 'id': 'b', 'rev': 1, 'ids': ['com.t']};
    final ext = {'format': '1.0', 'id': 'e', 'rev': 1, 'extends': 'b', 'ids': ['com.t']};
    expect(StateRulesLibrary.parse(null, {'1.json': jsonEncode(base), '2.json': jsonEncode(ext)}).choose('com.t', null)!.id, 'e');
    expect(StateRulesLibrary.parse(null, {'1.json': jsonEncode(ext), '2.json': jsonEncode(base)}).choose('com.t', null)!.id, 'e');
    final x = {'format': '1.0', 'id': 'x', 'rev': 1, 'ids': ['com.u']};
    final y = {'format': '1.0', 'id': 'y', 'rev': 1, 'ids': ['com.u']};
    expect(StateRulesLibrary.parse(null, {'b.json': jsonEncode(x), 'a.json': jsonEncode(y)}).choose('com.u', null)!.id, 'y');
  });

  test('choosing does not change the stored pack', () {
    final l = StateRulesLibrary.parse(builtin, {});
    final a = l.choose('com.openai.codex', null)!.json;
    expect(l.choose('com.openai.codex', null)!.json, a);
    expect(l.choose('x', 'chatgpt-desktop')!.json, a);
  });
}
