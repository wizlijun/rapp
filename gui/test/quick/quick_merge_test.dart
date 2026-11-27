import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/quick/key_layout.dart';
import 'package:rapp/quick/quick_merge.dart';
import 'package:rapp/quick/quick_prefs.dart';

QuickDoc d(int at, [Object? data = 'x']) => QuickDoc(at, data);

MergeStep go(QuickDoc local, int synced, QuickDoc? server,
    {int now = 10000, void Function(String)? log, String name = 'stars'}) =>
    decide(local: local, synced: synced, server: server, nowMs: now, log: log, name: name);

List<Object?> phrases(List<Phrase> l) => [for (final p in l) p.toJson()];

void main() {
  test('unchanged here, newer there: adopt', () {
    final s = d(500, 'srv');
    final r = go(d(100), 100, s);
    expect(r, isA<Adopt>());
    expect((r as Adopt).doc, same(s));
  });
  test('unchanged both sides: keep', () {
    expect(go(d(100), 100, d(100)), isA<Keep>());
  });
  test('changed here, same there: push with base synced', () {
    final r = go(d(300, 'mine'), 100, d(100, 'old')) as Push;
    expect(r.base, 100);
    expect(r.doc.at, 300);
    expect(r.doc.data, 'mine');
  });
  test('both changed, here later: push with base = server at', () {
    final r = go(d(900, 'mine'), 100, d(500)) as Push;
    expect(r.base, 500);
    expect(r.doc.at, 900);
  });
  test('both changed, there later: adopt and log', () {
    final logs = <String>[];
    final s = d(900, 'srv');
    final r = go(d(500), 100, s, log: logs.add);
    expect((r as Adopt).doc, same(s));
    expect(logs, hasLength(1));
  });
  test('clock skew: server at ahead of now still lets a newer local change win', () {
    // The push branches only run when local.at > server.at, so max() cannot show here; the real floor (server.at + 1
    // against a slow clock) lives in QuickPrefs.floor. This pins that a pushed at stays above the service's.
    final r = go(d(50001, 'mine'), 100, d(50000), now: 1000) as Push;
    expect(r.base, 50000);
    expect(r.doc.at, greaterThan(50000));
    // a local at that is not above the service's can never be pushed under it
    final r2 = go(d(40000, 'mine'), 100, d(100)) as Push;
    expect(r2.doc.at, 40000);
    final r3 = go(d(100), 50, d(50)) as Push;
    expect(r3.doc.at, greaterThan(50));
  });
  test('both changed with equal at: adopt and log', () {
    final logs = <String>[];
    final s = d(500, 'srv');
    expect((go(d(500), 100, s, log: logs.add) as Adopt).doc, same(s));
    expect(logs, hasLength(1));
  });
  test('decide: an unreadable server doc is replaced by the local one', () {
    final r = decide(local: d(50, ['a']), synced: 100, server: d(200, 'garbage'), nowMs: 1, name: 'stars') as Push;
    expect(r.base, 200);
    expect(r.doc.at, 201);
    expect(r.doc.data, ['a']);
  });
  test('no copy on the server: push with base 0', () {
    final r = go(d(5, 'mine'), 0, null) as Push;
    expect(r.base, 0);
  });

  group('first join', () {
    test('local at 0 adopts the server', () {
      final s = d(7, ['a']);
      final r = firstJoin(local: {'stars': d(0, ['p:x'])}, server: {'stars': s}, nowMs: 100);
      expect((r['stars'] as Adopt).doc, same(s));
    });
    test('both edited: phrases merged, nothing lost, stars remapped and united; a keys doc is not merged', () {
      final local = {
        'phrases': d(50, phrases([const Phrase('继续', id: 'L1'), const Phrase('只在本机', id: 'L2')])),
        'stars': d(50, ['p:L1', 'p:L2']),
        'layout': d(50, KeyLayout.fallback.toJson()),
      };
      final server = {
        'phrases': d(80, phrases([const Phrase('继续', id: 'S1'), const Phrase('服务的', id: 'S2')])),
        'keys': d(80, [{'id': 'search', 'label': '搜历史', 'chord': 'ctrl+r'}]),
        'stars': d(80, ['p:S2']),
        'layout': d(80, KeyLayout.fallback.toJson()),
      };
      final r = firstJoin(local: local, server: server, nowMs: 60);
      final p = r['phrases'] as Push;
      expect(p.base, 80);
      expect(p.doc.at, 81); // max(now 60, server 80 + 1)
      expect([for (final e in p.doc.data as List) (e as Map)['text']], ['继续', '服务的', '只在本机']);
      expect(r.containsKey('keys'), isFalse);
      final st = r['stars'] as Push;
      expect(st.doc.data, ['p:S2', 'p:S1', 'p:L2']);
      // layout identical to the server's: nothing to send
      expect(r['layout'], isA<Adopt>());
    });
    test('a local phrase whose id the server uses for different text is kept under a new id and its star follows it', () {
      final r = firstJoin(
        local: {
          'phrases': d(50, phrases([const Phrase('继续吧', id: 'L1')])),
          'stars': d(50, ['p:L1']),
        },
        server: {
          'phrases': d(80, phrases([const Phrase('继续', id: 'L1')])),
          'stars': d(80, <String>[]),
        },
        nowMs: 60,
      );
      final list = (r['phrases'] as Push).doc.data as List;
      expect([for (final e in list) (e as Map)['text']], ['继续', '继续吧']);
      final newId = (list[1] as Map)['id'] as String;
      expect(newId, isNot('L1'));
      expect((r['stars'] as Push).doc.data, ['p:$newId']);
      // stable across retries
      final again = firstJoin(
        local: {'phrases': d(50, phrases([const Phrase('继续吧', id: 'L1')]))},
        server: {'phrases': d(80, phrases([const Phrase('继续', id: 'L1')]))},
        nowMs: 99,
      );
      expect(((again['phrases'] as Push).doc.data as List)[1], list[1]);
    });
    test('first join: an unreadable server doc is replaced by the local one', () {
      final r = firstJoin(
        local: {
          'phrases': d(50, phrases([const Phrase('继续', id: 'L1')])),
          'stars': d(0, ['p:L1']),
          'layout': d(50, KeyLayout.fallback.toJson()),
        },
        server: {'phrases': d(80, 'garbage'), 'stars': d(80, 'x'), 'layout': d(80, 'y')},
        nowMs: 60,
      );
      for (final n in ['phrases', 'stars', 'layout']) {
        final p = r[n] as Push;
        expect(p.base, 80);
        expect(p.doc.at, 81);
      }
    });
    test('first join: an unreadable local doc yields to the server', () {
      final s = d(80, ['p:S']);
      final r = firstJoin(local: {'stars': d(50, 'junk')}, server: {'stars': s}, nowMs: 1);
      expect((r['stars'] as Adopt).doc, same(s));
    });
    test('a command on both sides is not duplicated', () {
      final cmd = {'kind': 'cmd', 'id': 'mode'};
      final r = firstJoin(
        local: {'phrases': d(50, [cmd, const Phrase('a', id: 'L').toJson()])},
        server: {'phrases': d(80, [cmd, const Phrase('b', id: 'S').toJson()])},
        nowMs: 60,
      );
      final list = (r['phrases'] as Push).doc.data as List;
      expect(list.where((e) => (e as Map)['kind'] == 'cmd'), hasLength(1));
      expect(list, hasLength(3));
    });
    test('server default layout yields to a custom local one', () {
      const custom = KeyLayout([['tab', 'esc'], ['left']]);
      final r = firstJoin(
        local: {'layout': d(5, custom.toJson())},
        server: {'layout': d(9, KeyLayout.fallback.toJson())},
        nowMs: 1,
      );
      final l = r['layout'] as Push;
      expect(l.base, 9);
      expect(l.doc.data, custom.toJson());
    });
    test('server custom layout stays', () {
      const custom = KeyLayout([['tab'], ['esc']]);
      final s = d(9, custom.toJson());
      final r = firstJoin(local: {'layout': d(5, KeyLayout.fallback.toJson())}, server: {'layout': s}, nowMs: 1);
      expect((r['layout'] as Adopt).doc, same(s));
    });
    test('missing on the server: push with base 0', () {
      final r = firstJoin(local: {'stars': d(0, <String>[])}, server: {}, nowMs: 1);
      expect((r['stars'] as Push).base, 0);
    });
  });

  test('isFirstJoin: new store / synced 0 / server older / server gone', () {
    bool f({String? known = 's', String store = 's', int synced = 10, QuickDoc? server}) =>
        isFirstJoin(knownStore: known, store: store, synced: synced, server: server ?? d(10));
    expect(f(), isFalse);
    expect(f(server: d(20)), isFalse);
    expect(f(known: 'other'), isTrue);
    expect(f(known: null), isTrue);
    expect(f(synced: 0), isTrue);
    expect(f(server: d(5)), isTrue);
    expect(isFirstJoin(knownStore: 's', store: 's', synced: 10, server: null), isTrue);
    expect(isFirstJoin(knownStore: 's', store: 's', synced: 0, server: null), isTrue);
  });
}
