import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/state_rules.dart';

/// Spec §6.5: no built-in signal is `tested` yet, so this list is empty.
const verified = <String>{};

void main() {
  final root = jsonDecode(File('assets/state_rules.json').readAsStringSync()) as Map;
  final packs = (root['packs'] as List).cast<Map>();

  test('four packs with the spec ids', () {
    expect(root['version'], 1);
    expect(packs.map((p) => p['id']), ['generic-chat', 'chatgpt-desktop', 'claude-desktop', 'antigravity-app']);
    for (final p in packs) {
      expect(p['format'], '1.0');
    }
    expect(packs[1]['ids'], ['com.openai.codex']);
    expect(packs[2]['ids'], ['com.anthropic.claudefordesktop']);
    expect(packs[3]['ids'], ['com.google.antigravity']);
  });

  test('every pack resolves within the limit and tested signals are on the verified list', () {
    final lib = StateRulesLibrary.parse(File('assets/state_rules.json').readAsStringSync(), {});
    for (final p in packs) {
      final c = lib.choose('x', p['id'] as String)!;
      expect(utf8.encode(c.json).length, lessThanOrEqualTo(stateRulesLimit));
      final sigs = (jsonDecode(c.json) as Map)['signals'] as Map? ?? {};
      for (final e in sigs.entries) {
        if ((e.value as Map)['status'] == 'tested') expect(verified, contains(e.key));
      }
    }
  });
}
