import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/embed/strip_tools.dart';
import 'package:rapp/quick/key_actions.dart';
import 'package:rapp/quick/key_layout.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/quick/quick_usage.dart';

AgentTool _tool(String id) => agentTools.firstWhere((t) => t.id == id);

void main() {
  test('migration: search moves to the keys, order kept, ids added, at 0', () {
    final q = QuickPrefs.migrate(defaultStripItems);
    expect(q.phrases.whereType<StripCmd>().map((c) => c.id), isNot(contains('search')));
    expect(q.phrases.length, defaultStripItems.length - 1);
    expect(q.keys.map((a) => a.id), ['search', 'expand', 'bg', 'clear', 'newtab']);
    expect(q.phrases.whereType<Phrase>().every((p) => p.id != null), isTrue);
    for (final n in [...quickDocNames, 'usage']) {
      expect(q.atOf(n), 0);
    }
    expect(q.layout.rows, KeyLayout.fallback.rows);
  });
  test('migration: a search changed to text stays a command', () {
    final custom = StripCmd('search', per: {'codex': const CmdText('/history')});
    final q = QuickPrefs.migrate([custom, Phrase('继续')]);
    expect(q.phrases, [const StripCmd('mode'), custom, const Phrase('继续')]);
    expect(q.keys.where((a) => a.id == 'search').length, 1);
  });
  test('migration: a search with only keys becomes the action with those keys', () {
    final q = QuickPrefs.migrate([StripCmd('search', per: {'codex': const CmdKey('co')})]);
    expect(q.phrases, [const StripCmd('mode')]); // only the added 切模式
    expect(chordFor(q.keys.first, agentTools.firstWhere((t) => t.id == 'codex'))!.toJson(), 'ctrl+o');
  });
  test('migration from gui.json adds 切模式 after 新对话', () {
    final q = QuickPrefs.migrate([const Phrase('a'), const StripCmd('new'), const StripCmd('model')]);
    expect(q.phrases.map(refOf).take(4).toList(), [refOf(q.phrases[0]), 'p:new', 'p:mode', 'p:model']);
  });
  test('migration adds 切模式 at the front when 新对话 was deleted', () {
    final q = QuickPrefs.migrate([const Phrase('a'), const StripCmd('model')]);
    expect(q.phrases.map(refOf).first, 'p:mode');
    expect(q.phrases, hasLength(3));
  });
  test('migration does not add a second 切模式', () {
    final q = QuickPrefs.migrate(defaultStripItems);
    expect(q.phrases.whereType<StripCmd>().where((c) => c.id == 'mode'), hasLength(1));
  });
  test('a quick.json that already exists without 切模式 does not get it back', () {
    final dir = Directory.systemTemp.createTempSync().path;
    QuickPrefs.load(dir, legacy: [const Phrase('a')]);
    final q = QuickPrefs.load(dir, legacy: [const Phrase('a')]);
    q.setPhrases([for (final it in q.phrases) if (!(it is StripCmd && it.id == 'mode')) it]);
    final back = QuickPrefs.load(dir, legacy: [const Phrase('a')]);
    expect(back.phrases.whereType<StripCmd>().map((c) => c.id), isNot(contains('mode')));
  });
  test('round trip through quick.json, at from the clock and never below the floor', () async {
    final dir = Directory.systemTemp.createTempSync().path;
    var t = DateTime.fromMillisecondsSinceEpoch(1000);
    final q = QuickPrefs.load(dir, legacy: defaultStripItems, clock: () => t);
    q.floor['stars'] = 5000;
    q.toggleStar('k:search');
    expect(q.atOf('stars'), 5000);
    final back = QuickPrefs.load(dir, legacy: const [], clock: () => t);
    expect(back.stars, ['k:search']);
    expect(back.phrases.map(refOf), q.phrases.map(refOf));
  });
  test('at only ever grows', () {
    var t = DateTime.fromMillisecondsSinceEpoch(1000);
    final q = QuickPrefs.migrate(defaultStripItems, clock: () => t);
    // Adopted from a device whose clock runs ahead; this clock is behind it and no floor is known (after a restart).
    q.adopt('stars', const QuickDoc(9000, ['k:mode']));
    q.toggleStar('k:search');
    expect(q.atOf('stars'), greaterThan(9000));
    final was = q.atOf('stars');
    q.toggleStar('k:bg');
    expect(q.atOf('stars'), greaterThan(was), reason: 'the same ms again');
    t = DateTime.fromMillisecondsSinceEpoch(500); // the clock went back
    q.toggleStar('k:clear');
    expect(q.atOf('stars'), greaterThan(was + 1));
  });
  test('deleting an action drops its star and its layout cell', () {
    final q = QuickPrefs.migrate(const [])
      ..setKeys([...builtinKeyActions, KeyAction('u1', label: 'X', chord: Chord.parse('ctrl+x')!)])
      ..setLayout(const KeyLayout([['esc', 'k:u1'], []]))
      ..toggleStar('k:u1');
    q.setKeys(builtinKeyActions);
    expect(q.stars, isEmpty);
    expect(q.layout.rows[0], ['esc']);
  });
  test('a broken quick.json is set aside and rebuilt', () {
    final dir = Directory.systemTemp.createTempSync().path;
    File('$dir/quick.json').writeAsStringSync('{nope');
    final q = QuickPrefs.load(dir, legacy: [Phrase('继续')]);
    expect(q.phrases.whereType<Phrase>().single, Phrase('继续'));
    expect(File('$dir/quick.json.bad').existsSync(), isTrue);
  });

  // ---- beyond the brief ----

  test('migration: a search with no per is dropped, the built-in action stays as it was', () {
    final q = QuickPrefs.migrate([const StripCmd('search'), const Phrase('继续')]);
    expect(q.phrases, [const StripCmd('mode'), const Phrase('继续')]);
    expect(q.keys, builtinKeyActions);
  });
  test('migration: keys of a search keep the built-in per for the tools it does not name; a cleared tool is off', () {
    final q = QuickPrefs.migrate([
      const StripCmd('search', per: {'codex': CmdKey('stab'), 'gemini': null, 'claude-code': CmdKey('pgup')}),
    ]);
    final a = q.keys.first;
    expect(a.id, 'search');
    expect(chordFor(a, _tool('codex'))!.toJson(), 'shift+tab');
    expect(chordFor(a, _tool('claude-code'))!.toJson(), 'pgup');
    expect(chordFor(a, _tool('gemini')), isNull);
    expect(chordFor(a, _tool('agy')), isNull); // the built-in has none there
    expect(a.chord.toJson(), 'ctrl+r');
  });
  test('migration: a renamed search keeps its name on the action', () {
    final q = QuickPrefs.migrate([const StripCmd('search', label: '找')]);
    expect(q.keys.first.label, '找');
  });
  test('migration: phrases, other commands and their order stay; ids are new and distinct', () {
    final legacy = [const Phrase('a', put: true), const StripCmd('new'), const StripCmd('u9', label: '我的'), const Phrase('b')];
    final q = QuickPrefs.migrate(legacy);
    expect(q.phrases, [legacy[0], legacy[1], const StripCmd('mode'), legacy[2], legacy[3]]);
    final ids = [for (final p in q.phrases.whereType<Phrase>()) p.id];
    expect(ids.toSet(), hasLength(2));
    expect(ids.every((i) => RegExp(r'^[a-z0-9]{8}$').hasMatch(i!)), isTrue);
    expect(q.phrases.map(refOf), ['p:${ids[0]}', 'p:new', 'p:mode', 'p:u9', 'p:${ids[1]}']);
  });
  test('no dir: nothing is written, the docs live in memory', () {
    var t = DateTime.fromMillisecondsSinceEpoch(1000);
    final q = QuickPrefs.load(null, legacy: [const Phrase('a')], clock: () => t);
    q.toggleStar(refOf(q.phrases.whereType<Phrase>().single));
    expect(q.stars, hasLength(1));
    expect(q.atOf('stars'), 1000);
  });
  test('dirOf, when set, decides where each write goes', () {
    final dir = Directory.systemTemp.createTempSync().path;
    String? where;
    final q = QuickPrefs.load(null, legacy: const [Phrase('a')])..dirOf = () => where;
    q.toggleStar('k:mode');
    expect(File('$dir/quick.json').existsSync(), isFalse);
    where = dir;
    q.toggleStar('k:bg');
    expect(QuickPrefs.load(dir, legacy: const []).stars, ['k:mode', 'k:bg']);
  });
  test('migration writes quick.json at once, so the new ids stay', () {
    final dir = Directory.systemTemp.createTempSync().path;
    final q = QuickPrefs.load(dir, legacy: [const Phrase('a')]);
    final j = jsonDecode(File('$dir/quick.json').readAsStringSync()) as Map;
    expect(j['v'], 1);
    for (final n in [...quickDocNames, 'usage']) {
      expect((j[n] as Map)['at'], 0);
    }
    expect(((j['phrases'] as Map)['data'] as List).last, {'text': 'a', 'id': (q.phrases.last as Phrase).id});
    expect(File('$dir/quick.json.tmp').existsSync(), isFalse);
    final back = QuickPrefs.load(dir, legacy: [const Phrase('x')]);
    expect((back.phrases.last as Phrase).id, (q.phrases.last as Phrase).id);
  });
  test('one bad doc goes back to its default alone, at 0', () {
    final dir = Directory.systemTemp.createTempSync().path;
    File('$dir/quick.json').writeAsStringSync(jsonEncode({
      'v': 1,
      'phrases': {'at': 7, 'data': [{'text': '留着', 'id': 'aaaaaaaa'}]},
      'keys': {'at': 8, 'data': 'nope'},
      'layout': 3,
      'stars': {'at': 9, 'data': ['p:aaaaaaaa']},
    }));
    final q = QuickPrefs.load(dir, legacy: [const Phrase('旧')]);
    expect(q.phrases, [const Phrase('留着')]);
    expect(q.atOf('phrases'), 7);
    expect(q.keys, builtinKeyActions);
    expect(q.atOf('keys'), 0);
    expect(q.layout.rows, KeyLayout.fallback.rows);
    expect(q.atOf('layout'), 0);
    expect(q.stars, ['p:aaaaaaaa']);
    expect(q.usage, isEmpty);
    expect(File('$dir/quick.json.bad').existsSync(), isFalse);
  });
  test('fresh install and 恢复默认 share one default: the commands without search, then the phrases', () {
    expect(defaultQuickPhrases.whereType<StripCmd>().map((c) => c.id), isNot(contains('search')));
    expect(defaultQuickPhrases, [
      for (final id in builtinCmdOrder) if (id != 'search') StripCmd(id),
      ...defaultPhrases,
    ]);
    expect(QuickPrefs.migrate(defaultStripItems).phrases, defaultQuickPhrases);
  });
  test('hostile docs never throw, in load or adopt; bad entries are dropped', () {
    final dir = Directory.systemTemp.createTempSync().path;
    final hostile = {
      'v': 1,
      'phrases': {'at': 3, 'data': [5, null, {'text': 7}, {'kind': 'cmd', 'id': 7, 'per': 'x'}, {'kind': 'cmd', 'id': 'new', 'per': {'codex': 7, '3': [1]}}]},
      'keys': {'at': 4, 'data': [{'id': 5}, null, [], {'id': 'a', 'label': 'x', 'chord': 'ctrl+x', 'per': {'codex': 7, 'gemini': {'a': 1}}}]},
      'layout': {'at': 5, 'data': {'rows': [[1, null, {}], 'x', 5, null]}},
      'stars': {'at': 6, 'data': [1, null, {}, 'p:x']},
      'usage': {'at': 7, 'data': {'2026-11-27': {'p:x': 'y', 'k:a': null}, 'x': 5, '5': [1]}},
    };
    File('$dir/quick.json').writeAsStringSync(jsonEncode(hostile));
    late QuickPrefs q;
    expect(() => q = QuickPrefs.load(dir, legacy: const [Phrase('旧')]), returnsNormally);
    expect(q.layout.rows, isNotEmpty);
    expect(q.stars, ['p:x']);
    for (final n in [...quickDocNames, 'usage']) {
      expect(() => q.adopt(n, QuickDoc(9, hostile[n] is Map ? (hostile[n] as Map)['data'] : null)), returnsNormally);
      expect(() => q.adopt(n, const QuickDoc(9, {'rows': 'x', 'id': [], 'kind': 'cmd'})), returnsNormally);
    }
  });
  test('a local change bumps at, saves, notifies and tells onLocal; adopt does not tell', () {
    var t = DateTime.fromMillisecondsSinceEpoch(2000);
    final q = QuickPrefs.migrate(const [Phrase('a')], clock: () => t);
    final told = <String>[];
    var notes = 0;
    q.onLocal = told.add;
    q.addListener(() => notes++);
    q.setLayout(const KeyLayout([['esc'], []]));
    expect(q.atOf('layout'), 2000);
    expect(told, ['layout']);
    expect(notes, 1);
    q.adopt('layout', const QuickDoc(9000, {'rows': [['tab'], []]}));
    expect(q.layout.rows[0], ['tab']);
    expect(q.atOf('layout'), 9000);
    expect(told, ['layout']);
    expect(notes, 2);
    q.adopt('keys', const QuickDoc(10, 'bad'));
    expect(q.keys, builtinKeyActions);
    expect(q.atOf('keys'), 10);
    expect(q.docOf('layout').data, {'rows': [['tab'], <String>[]]});
  });
  test('deleting a phrase drops its star, stars of the keys stay', () {
    var t = DateTime.fromMillisecondsSinceEpoch(3000);
    final q = QuickPrefs.migrate(const [Phrase('a'), Phrase('b')], clock: () => t);
    final told = <String>[];
    q.onLocal = told.add;
    final a = refOf(q.phrases[0]);
    q
      ..toggleStar(a)
      ..toggleStar('k:mode');
    told.clear();
    q.setPhrases([q.phrases[1]]);
    expect(q.stars, ['k:mode']);
    expect(told, ['phrases', 'stars']);
  });
  test('setPhrases gives a new phrase an id and keeps the ones it has', () {
    final q = QuickPrefs.migrate(const [Phrase('a')]);
    final id = (q.phrases.last as Phrase).id;
    q.setPhrases([...q.phrases, const Phrase('b')]);
    expect((q.phrases[1] as Phrase).id, id);
    expect((q.phrases[2] as Phrase).id, isNotNull);
  });
  test('stars: toggle adds at the end and removes; starFirst moves to the front', () {
    final q = QuickPrefs.migrate(const [])
      ..toggleStar('k:mode')
      ..toggleStar('k:bg')
      ..toggleStar('k:clear');
    expect(q.stars, ['k:mode', 'k:bg', 'k:clear']);
    q.toggleStar('k:bg');
    expect(q.stars, ['k:mode', 'k:clear']);
    q.starFirst('k:clear');
    expect(q.stars, ['k:clear', 'k:mode']);
  });
  test('recordUse counts today and drops days past 30', () {
    var t = DateTime(2026, 11, 27, 10);
    final q = QuickPrefs.migrate(const [], clock: () => t);
    q.adopt('usage', QuickDoc(1, {
      'k:mode': {'2026-10-01': 4},
    }));
    q.recordUse('k:mode');
    q.recordUse('k:mode');
    expect(q.usage, {
      'k:mode': {'2026-11-27': 2},
    });
    expect(q.atOf('usage'), t.millisecondsSinceEpoch + 1); // two changes in the same ms: the second goes 1 above
  });
  test('setOthers keeps the other devices\' counts and notifies', () {
    final q = QuickPrefs.migrate(const []);
    var notes = 0;
    q.addListener(() => notes++);
    final Usage u = {'k:bg': {'2026-11-27': 1}};
    q.setOthers({'dev2': u});
    expect(q.others['dev2'], u);
    expect(notes, 1);
  });
  test('Phrase id: written when set, read back, not part of ==', () {
    const p = Phrase('a', id: 'abcdefgh');
    expect(p.toJson(), {'text': 'a', 'id': 'abcdefgh'});
    expect(const Phrase('a').toJson(), {'text': 'a'});
    expect(Phrase.fromJson(p.toJson())!.id, 'abcdefgh');
    expect(p, const Phrase('a'));
    expect(p.withId('x').id, 'x');
    expect(p.copyWith(put: true).id, 'abcdefgh');
  });
}
