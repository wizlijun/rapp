import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/quick/key_layout.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/quick/quick_usage.dart';

void main() {
  test('migration: gui.json\'s list stays as it is, 搜历史 a command like the others, ids added, at 0', () {
    final q = QuickPrefs.migrate(defaultStripItems);
    expect(q.phrases.whereType<StripCmd>().map((c) => c.id), builtinCmdOrder);
    expect(q.phrases.length, defaultStripItems.length);
    expect(q.phrases.whereType<Phrase>().every((p) => p.id != null), isTrue);
    for (final n in [...quickDocNames, 'usage']) {
      expect(q.atOf(n), 0);
    }
    expect(quickDocNames, isNot(contains('keys')));
    expect(q.layout.rows, KeyLayout.fallback.rows);
  });
  test('migration: a search with keys or text of its own stays the command it was', () {
    final keys = StripCmd('search', per: {'codex': const CmdKey('co')});
    final text = StripCmd('search', label: '找', per: {'codex': const CmdText('/history')});
    expect(QuickPrefs.migrate([keys, const Phrase('继续')]).phrases, [const StripCmd('mode'), keys, const Phrase('继续')]);
    expect(QuickPrefs.migrate([text]).phrases, [const StripCmd('mode'), text]);
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
    q.toggleStar('p:search');
    expect(q.atOf('stars'), 5000);
    final back = QuickPrefs.load(dir, legacy: const [], clock: () => t);
    expect(back.stars, ['p:search']);
    expect(back.phrases.map(refOf), q.phrases.map(refOf));
  });
  test('at only ever grows', () {
    var t = DateTime.fromMillisecondsSinceEpoch(1000);
    final q = QuickPrefs.migrate(defaultStripItems, clock: () => t);
    // Adopted from a device whose clock runs ahead; this clock is behind it and no floor is known (after a restart).
    q.adopt('stars', const QuickDoc(9000, ['p:mode']));
    q.toggleStar('p:search');
    expect(q.atOf('stars'), greaterThan(9000));
    final was = q.atOf('stars');
    q.toggleStar('p:bg');
    expect(q.atOf('stars'), greaterThan(was), reason: 'the same ms again');
    t = DateTime.fromMillisecondsSinceEpoch(500); // the clock went back
    q.toggleStar('p:clear');
    expect(q.atOf('stars'), greaterThan(was + 1));
  });
  test('a k: cell of the old 按键动作 in a layout is not drawn', () {
    final q = QuickPrefs.migrate(const [])..setLayout(const KeyLayout([['esc', 'k:search', 'k:u1'], ['tab']]));
    expect(q.layout.rows, [['esc'], ['tab']]);
  });

  test('a broken quick.json that cannot be set aside is never overwritten', () {
    final dir = Directory.systemTemp.createTempSync().path;
    File('$dir/quick.json').writeAsStringSync('{nope');
    File('$dir/quick.json.bad/x').createSync(recursive: true); // a folder in the way: the move fails
    final q = QuickPrefs.load(dir, legacy: [Phrase('继续')])..dirOf = () => dir;
    q.toggleStar('p:esc');
    expect(q.stars, ['p:esc'], reason: 'it still works in memory');
    expect(File('$dir/quick.json').readAsStringSync(), '{nope', reason: 'the only copy of the user\'s file is kept');
    expect(q.lastSaveError, isNotNull, reason: 'the app can say the settings are not saved');
  });

  test('a quick.json from a newer version is read but never rewritten as v 1', () {
    final dir = Directory.systemTemp.createTempSync().path;
    final body = jsonEncode({
      'v': 2,
      'stars': {'at': 5, 'data': ['p:esc']},
      'layout': {'at': 5, 'data': 'a shape this version does not know'},
    });
    File('$dir/quick.json').writeAsStringSync(body);
    final q = QuickPrefs.load(dir, legacy: const [])..dirOf = () => dir;
    expect(q.stars, ['p:esc']);
    q.toggleStar('p:tab');
    expect(File('$dir/quick.json').readAsStringSync(), body);
    expect(q.lastSaveError, isNotNull);
  });

  test('a failed first write is kept for whoever wires onSaveError later', () {
    final dir = Directory.systemTemp.createTempSync().path;
    File('$dir/blocker').writeAsStringSync('a file, not a folder');
    final q = QuickPrefs.load('$dir/blocker/dev', legacy: const []);
    expect(q.lastSaveError, isNotNull);
    final ok = QuickPrefs.load(Directory.systemTemp.createTempSync().path, legacy: const []);
    expect(ok.lastSaveError, isNull);
  });

  test('a broken quick.json is set aside and rebuilt', () {
    final dir = Directory.systemTemp.createTempSync().path;
    File('$dir/quick.json').writeAsStringSync('{nope');
    final q = QuickPrefs.load(dir, legacy: [Phrase('继续')]);
    expect(q.phrases.whereType<Phrase>().single, Phrase('继续'));
    expect(File('$dir/quick.json.bad').existsSync(), isTrue);
  });

  // ---- beyond the brief ----

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
    q.toggleStar('p:mode');
    expect(File('$dir/quick.json').existsSync(), isFalse);
    where = dir;
    q.toggleStar('p:bg');
    expect(QuickPrefs.load(dir, legacy: const []).stars, ['p:mode', 'p:bg']);
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
      'layout': 3,
      'stars': {'at': 9, 'data': ['p:aaaaaaaa']},
    }));
    final q = QuickPrefs.load(dir, legacy: [const Phrase('旧')]);
    expect(q.phrases, [const Phrase('留着')]);
    expect(q.atOf('phrases'), 7);
    expect(q.layout.rows, KeyLayout.fallback.rows);
    expect(q.atOf('layout'), 0);
    expect(q.stars, ['p:aaaaaaaa']);
    expect(q.usage, isEmpty);
    expect(File('$dir/quick.json.bad').existsSync(), isFalse);
  });
  test('fresh install and 恢复默认 share one default: every built-in command, 搜历史 too, then the phrases', () {
    expect(defaultQuickPhrases, [
      for (final id in builtinCmdOrder) StripCmd(id),
      ...defaultPhrases,
    ]);
    expect(QuickPrefs.migrate(defaultStripItems).phrases, defaultQuickPhrases);
  });
  test('restoring default phrases keeps stars on default items', () {
    final q = QuickPrefs.migrate(defaultStripItems);
    final keep = q.phrases.whereType<Phrase>().firstWhere((p) => p.text == '进度');
    q.toggleStar(refOf(keep));
    // The user's own list: the default one gone, another added.
    q.setPhrases([for (final it in q.phrases) if (!(it is Phrase && it.text == '进度')) it, const Phrase('我的')]);
    expect(q.stars, isEmpty);
    q.toggleStar(refOf(q.phrases.whereType<Phrase>().firstWhere((p) => p.text == '继续')));
    q.setPhrases(defaultQuickPhrases); // 恢复默认
    expect(q.stars, ['p:${q.phrases.whereType<Phrase>().firstWhere((p) => p.text == '继续').id}'],
        reason: 'the star on 继续 stays');
    // The same ids every time, and on every device.
    expect(defaultQuickPhrases.map(refOf), defaultQuickPhrases.map(refOf));
    expect(defaultQuickPhrases.map(refOf).toSet(), hasLength(defaultQuickPhrases.length));
    expect(QuickPrefs.migrate(defaultStripItems).phrases.map(refOf), defaultQuickPhrases.map(refOf));
    expect(q.phrases.whereType<Phrase>().firstWhere((p) => p.text == '进度').id, keep.id);
  });
  test('a fixed default id is used once: a second phrase of that text gets its own', () {
    final q = QuickPrefs.migrate([const Phrase('继续'), const Phrase('继续', put: true), const Phrase('别的')]);
    final ids = [for (final p in q.phrases.whereType<Phrase>()) p.id];
    expect(ids.toSet().length, ids.length);
    expect(ids.first, defaultQuickPhrases.whereType<Phrase>().firstWhere((p) => p.text == '继续').id);
  });
  test('hostile docs never throw, in load or adopt; bad entries are dropped', () {
    final dir = Directory.systemTemp.createTempSync().path;
    final hostile = {
      'v': 1,
      'phrases': {'at': 3, 'data': [5, null, {'text': 7}, {'kind': 'cmd', 'id': 7, 'per': 'x'}, {'kind': 'cmd', 'id': 'new', 'per': {'codex': 7, '3': [1]}}]},
      'keys': {'at': 4, 'data': [{'id': 5}, null, [], {'id': 'a', 'label': 'x', 'chord': 'ctrl+x', 'per': {'codex': 7, 'gemini': {'a': 1}}}]},
      'layout': {'at': 5, 'data': {'rows': [[1, null, {}], 'x', 5, null]}},
      'stars': {'at': 6, 'data': [1, null, {}, 'p:x']},
      'usage': {'at': 7, 'data': {'2026-11-27': {'p:x': 'y', 'p:a': null}, 'x': 5, '5': [1]}},
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
    q.adopt('keys', const QuickDoc(10, [])); // an old version's doc: not read
    expect(q.atOf('keys'), 0);
    expect(notes, 2);
    expect(q.docOf('layout').data, {'rows': [['tab'], <String>[]]});
  });
  test('deleting a phrase drops its star, other stars stay', () {
    var t = DateTime.fromMillisecondsSinceEpoch(3000);
    final q = QuickPrefs.migrate(const [Phrase('a'), Phrase('b')], clock: () => t);
    final told = <String>[];
    q.onLocal = told.add;
    final a = refOf(q.phrases[1]), b = refOf(q.phrases[2]);
    q
      ..toggleStar(a)
      ..toggleStar(b);
    told.clear();
    q.setPhrases([q.phrases[0], q.phrases[2]]);
    expect(q.stars, [b]);
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
      ..toggleStar('p:mode')
      ..toggleStar('p:bg')
      ..toggleStar('p:clear');
    expect(q.stars, ['p:mode', 'p:bg', 'p:clear']);
    q.toggleStar('p:bg');
    expect(q.stars, ['p:mode', 'p:clear']);
    q.starFirst('p:clear');
    expect(q.stars, ['p:clear', 'p:mode']);
  });
  test('recordUse counts today and drops days past 30', () {
    var t = DateTime(2026, 11, 27, 10);
    final q = QuickPrefs.migrate(const [], clock: () => t);
    q.adopt('usage', QuickDoc(1, {
      'p:mode': {'2026-10-01': 4},
    }));
    q.recordUse('p:mode');
    q.recordUse('p:mode');
    expect(q.usage, {
      'p:mode': {'2026-11-27': 2},
    });
    expect(q.atOf('usage'), t.millisecondsSinceEpoch + 1); // two changes in the same ms: the second goes 1 above
  });
  test('setOthers keeps the other devices\' counts and notifies', () {
    final q = QuickPrefs.migrate(const []);
    var notes = 0;
    q.addListener(() => notes++);
    final Usage u = {'p:bg': {'2026-11-27': 1}};
    q.setOthers({'dev2': u});
    expect(q.others['dev2'], u);
    expect(notes, 1);
  });
  group('a quick.json of 0.15.63/64, with its 按键动作 doc', () {
    final day = DateTime(2026, 11, 27, 12);
    Map<String, Object?> old({List<Object?>? phrases, Object? keys}) => {
          'v': 1,
          'phrases': {
            'at': 7,
            'data': phrases ??
                [
                  {'kind': 'cmd', 'id': 'new'},
                  {'kind': 'cmd', 'id': 'mode'},
                  {'kind': 'cmd', 'id': 'compact'},
                  {'text': '继续', 'id': 'aaaaaaaa'},
                ],
          },
          'keys': {'at': 8, 'data': keys ?? [{'id': 'search', 'label': '找', 'chord': 'ctrl+r'}, {'id': 'bg', 'label': '后台', 'chord': 'ctrl+b'}]},
          'layout': {'at': 4, 'data': {'rows': [['esc', 'k:bg'], <String>[]]}},
          'stars': {'at': 9, 'data': ['k:search', 'k:bg', 'p:aaaaaaaa']},
          'usage': {'at': 5, 'data': {'k:search': {'2026-11-27': 2}, 'k:bg': {'2026-11-27': 1}, 'p:new': {'2026-11-26': 1}}},
        };
    String write(Map<String, Object?> j) {
      final dir = Directory.systemTemp.createTempSync().path;
      File('$dir/quick.json').writeAsStringSync(jsonEncode(j));
      return dir;
    }

    test('搜历史 comes back as a command after the last one, with the name it was given', () {
      final q = QuickPrefs.load(write(old()), legacy: const [], clock: () => day);
      expect(q.phrases.map(refOf), ['p:new', 'p:mode', 'p:compact', 'p:search', 'p:aaaaaaaa']);
      expect(q.phrases[3], const StripCmd('search', label: '找'));
    });
    test('its star and its counts carry over to the command; the other actions\' go', () {
      final q = QuickPrefs.load(write(old()), legacy: const [], clock: () => day);
      expect(q.stars, ['p:search', 'p:aaaaaaaa']);
      expect(q.usage, {
        'p:search': {'2026-11-27': 2},
        'p:new': {'2026-11-26': 1},
      });
    });
    test('the docs it changed move on so the sync sends them; the keys doc is gone, so it happens once', () {
      final dir = write(old());
      final q = QuickPrefs.load(dir, legacy: const [], clock: () => day);
      final now = day.millisecondsSinceEpoch;
      expect([q.atOf('phrases'), q.atOf('stars'), q.atOf('usage')], [now, now, now]);
      expect(q.atOf('layout'), 4, reason: 'a k: cell is only not drawn');
      final j = jsonDecode(File('$dir/quick.json').readAsStringSync()) as Map;
      expect(j.containsKey('keys'), isFalse);
      final back = QuickPrefs.load(dir, legacy: const [], clock: () => day.add(const Duration(hours: 1)));
      expect(back.atOf('phrases'), now);
      expect(back.phrases.map(refOf), q.phrases.map(refOf));
    });
    test('an unrenamed search comes back plain; one already among the commands is not added twice', () {
      final plain = QuickPrefs.load(write(old(keys: [{'id': 'search', 'label': '搜历史', 'chord': 'ctrl+r'}])),
          legacy: const [], clock: () => day);
      expect(plain.phrases[3], const StripCmd('search'));
      expect((plain.phrases[3] as StripCmd).label, isNull);
      final had = QuickPrefs.load(
          write(old(phrases: [
            {'kind': 'cmd', 'id': 'search', 'per': {'codex': {'text': '/history'}}},
            {'text': '继续', 'id': 'aaaaaaaa'},
          ])),
          legacy: const [],
          clock: () => day);
      expect(had.phrases.map(refOf), ['p:search', 'p:aaaaaaaa']);
      expect(had.atOf('phrases'), 7);
    });
    test('an action list it cannot read still brings 搜历史 back', () {
      final q = QuickPrefs.load(write(old(keys: [5, null, {'id': 7}])), legacy: const [], clock: () => day);
      expect(q.phrases[3], const StripCmd('search'));
    });
  });
  test('stars from a device still on 0.15.63/64: k:search is the command, other k: refs go', () {
    final q = QuickPrefs.migrate(defaultStripItems);
    q.adopt('stars', const QuickDoc(5, ['k:search', 'k:bg', 'p:new']));
    expect(q.stars, ['p:search', 'p:new']);
  });
  test('counts of a device still on 0.15.63/64: k:search counts for the command, other k: refs go', () {
    final q = QuickPrefs.migrate(defaultStripItems);
    q.setOthers({
      'dev2': {
        'k:search': {'2026-11-27': 3},
        'p:search': {'2026-11-27': 1, '2026-11-26': 1},
        'k:bg': {'2026-11-27': 1},
      },
    });
    expect(q.others['dev2'], {
      'p:search': {'2026-11-27': 4, '2026-11-26': 1},
    });
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
