import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/quick/key_actions.dart';
import 'package:rapp/quick/key_layout.dart';
import 'package:rapp/quick/quick_merge.dart';
import 'package:rapp/quick/quick_prefs.dart';

QuickDoc d(int at, [Object? data = 'x']) => QuickDoc(at, data);

MergeStep go(QuickDoc local, int synced, QuickDoc? server, {int now = 10000, void Function(String)? log}) =>
    decide(local: local, synced: synced, server: server, nowMs: now, log: log);

List<Object?> phrases(List<Phrase> l) => [for (final p in l) p.toJson()];
Object? key(String id, String label, Chord c) => KeyAction(id, label: label, chord: c).toJson();

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
    // the service is far ahead of this clock; the local change (floored at server.at + 1 by QuickPrefs) is later
    final r = go(d(50001, 'mine'), 100, d(50000), now: 1000) as Push;
    expect(r.base, 50000);
    expect(r.doc.at, greaterThan(50000));
    // a local at that is not above the service's can never be pushed under it
    final r2 = go(d(40000, 'mine'), 100, d(100)) as Push;
    expect(r2.doc.at, 40000);
    final r3 = go(d(100), 50, d(50)) as Push;
    expect(r3.doc.at, greaterThan(50));
  });
  test('no copy on the server: push with base 0', () {
    final r = go(d(5, 'mine'), 0, null) as Push;
    expect(r.base, 0);
  });

  group('first join', () {
    test('local at 0 adopts the server', () {
      final s = d(7, ['a']);
      final r = firstJoin(local: {'stars': d(0, ['k:x'])}, server: {'stars': s}, nowMs: 100);
      expect((r['stars'] as Adopt).doc, same(s));
    });
    test('both edited: phrases and keys merged, nothing lost, stars remapped and united', () {
      final local = {
        'phrases': d(50, phrases([const Phrase('继续', id: 'L1'), const Phrase('只在本机', id: 'L2')])),
        'keys': d(50, [
          key('search', '搜历史', const Chord('r', ctrl: true)),
          key('mine1', '我的', const Chord('g', ctrl: true)),
          key('own2', '本机独有', const Chord('h', ctrl: true)),
        ]),
        'stars': d(50, ['p:L1', 'p:L2', 'k:mine1', 'k:own2', 'k:search']),
        'layout': d(50, KeyLayout.fallback.toJson()),
      };
      final server = {
        'phrases': d(80, phrases([const Phrase('继续', id: 'S1'), const Phrase('服务的', id: 'S2')])),
        'keys': d(80, [
          key('search', '搜历史', const Chord('r', ctrl: true)),
          key('srv9', '我的', const Chord('g', ctrl: true)),
        ]),
        'stars': d(80, ['p:S2']),
        'layout': d(80, KeyLayout.fallback.toJson()),
      };
      final r = firstJoin(local: local, server: server, nowMs: 60);
      final p = r['phrases'] as Push;
      expect(p.base, 80);
      expect(p.doc.at, 81); // max(now 60, server 80 + 1)
      expect([for (final e in p.doc.data as List) (e as Map)['text']], ['继续', '服务的', '只在本机']);
      final k = r['keys'] as Push;
      expect([for (final e in k.doc.data as List) (e as Map)['id']], ['search', 'srv9', 'own2']);
      final st = r['stars'] as Push;
      expect(st.doc.data, ['p:S2', 'p:S1', 'p:L2', 'k:srv9', 'k:own2', 'k:search']);
      // layout identical to the server's: nothing to send
      expect(r['layout'], isA<Adopt>());
    });
    test('server default layout yields to a custom local one', () {
      const custom = KeyLayout([['tab', 'esc'], ['k:mine1']]);
      final r = firstJoin(
        local: {
          'layout': d(5, custom.toJson()),
          'keys': d(5, [key('mine1', '我的', const Chord('g', ctrl: true))]),
        },
        server: {
          'layout': d(9, KeyLayout.fallback.toJson()),
          'keys': d(9, [key('srv', '我的', const Chord('g', ctrl: true))]),
        },
        nowMs: 1,
      );
      final l = r['layout'] as Push;
      expect(l.base, 9);
      expect(l.doc.data, {
        'rows': [
          ['tab', 'esc'],
          ['k:srv']
        ]
      });
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
