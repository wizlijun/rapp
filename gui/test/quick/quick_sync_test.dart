import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/quick/key_layout.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/quick/quick_sync.dart';
import 'package:rapp/quick/quick_usage.dart';
import 'package:rapp/state/state_link.dart';

/// A center service in memory: `PUT` takes a doc when `base` is the stored `at`, else answers 409 with it.
class FakeLink extends StateLink {
  FakeLink({this.store = 's1'}) : super(Uri.parse('http://fake')) {
    prefs = true;
  }

  String store;
  final docs = <String, QuickDoc>{};
  final usage = <String, QuickDoc>{};
  final puts = <({String name, int at, int base, Object? data})>[];
  final usagePuts = <({String device, int at, Object? data})>[];
  /// A PUT of this doc is decided at once but answered only when the completer completes.
  final hold = <String, Completer<void>>{};

  /// `prefsAll` answers (with what was there when it was called) only when this completes.
  Completer<void>? holdAll;
  bool failAll = false;
  bool failPuts = false;

  /// Each PUT finds the service a step ahead (someone else keeps writing).
  bool raceForever = false;

  @override
  Future<bool> health() async => true;

  @override
  Future<Map<String, Object?>> prefsAll() async {
    if (failAll) throw const StateLinkError(0);
    final snap = {
      'store': store,
      for (final e in docs.entries) e.key: {'at': e.value.at, 'data': e.value.data},
      if (usage.isNotEmpty)
        'usage': {for (final e in usage.entries) e.key: {'at': e.value.at, 'data': e.value.data}},
    };
    if (holdAll != null) await holdAll!.future;
    return snap;
  }

  @override
  Future<QuickDoc?> putPref(String name, {required int at, required int base, required Object? data}) async {
    puts.add((name: name, at: at, base: base, data: jsonDecode(jsonEncode(data))));
    if (failPuts) throw const StateLinkError(0);
    if (raceForever) {
      final cur = docs[name];
      docs[name] = QuickDoc((cur?.at ?? 0) + 1, cur?.data ?? const <Object?>[]);
    }
    final cur = docs[name];
    final QuickDoc? answer;
    if ((cur?.at ?? 0) != base) {
      answer = cur ?? const QuickDoc(0, null);
    } else {
      docs[name] = QuickDoc(at, jsonDecode(jsonEncode(data)));
      answer = null;
    }
    if (hold[name] case final c?) await c.future;
    return answer;
  }

  @override
  Future<void> putUsage(String device, {required int at, required Object? data}) async {
    usagePuts.add((device: device, at: at, data: data));
    if (failPuts) throw const StateLinkError(0);
    usage[device] = QuickDoc(at, data);
  }
}

final t0 = DateTime(2026, 11, 27, 12).millisecondsSinceEpoch;

String tmp() => Directory.systemTemp.createTempSync('quick_sync').path;

/// A fake-async world: a clock that follows the fake time, prefs from gui.json's defaults.
class World {
  World(this.a, {String? dir, String? device = 'dev-a', Duration usageEvery = const Duration(minutes: 1)})
      : dir = dir ?? tmp() {
    prefs = QuickPrefs.migrate(defaultStripItems, clock: clock);
    sync = make(device: device, usageEvery: usageEvery);
  }

  final FakeAsync a;
  final String dir;
  late final QuickPrefs prefs;
  late QuickSync sync;

  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(t0 + a.elapsed.inMilliseconds);

  QuickSync make({String? device = 'dev-a', Duration usageEvery = const Duration(minutes: 1)}) => QuickSync(
        prefs: prefs,
        localDir: dir,
        device: device,
        host: () async => 'mac-1',
        clock: clock,
        usageEvery: usageEvery,
      );

  void attach(FakeLink l) {
    sync.attach(l);
    a.flushMicrotasks();
  }

  /// Every doc of [prefs] on [link] and marked synced in quick-sync.json under [store], `at` 100.
  void inStep(FakeLink link, {String store = 's1', int at = 100}) {
    for (final n in quickDocNames) {
      prefs.adopt(n, QuickDoc(at, prefs.docOf(n).data));
      link.docs[n] = QuickDoc(at, prefs.docOf(n).data);
    }
    File('$dir/quick-sync.json').writeAsStringSync(jsonEncode({
      'store': store,
      'synced': {for (final n in quickDocNames) n: at},
      'others': {},
    }));
    sync.dispose();
    sync = make();
  }
}

void main() {
  test('attach adopts newer docs and pushes changed ones', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      const mine = KeyLayout([
        ['esc', 'tab'],
        ['left', 'right'],
      ]);
      link.docs['layout'] = QuickDoc(500, mine.toJson());
      w.prefs.toggleStar('p:search'); // changed while not attached
      w.attach(link);
      expect(w.sync.status, QuickSyncStatus.synced);
      expect(w.sync.hostId, 'mac-1');
      expect(w.prefs.layout.rows, mine.rows);
      expect(w.prefs.atOf('layout'), 500);
      expect(w.prefs.floor['layout'], 501);
      expect(link.puts.map((p) => p.name), ['stars']);
      expect(link.puts.single.base, 100);
      expect(link.docs['stars']!.data, ['p:search']);
      a.elapse(const Duration(seconds: 5));
      expect(link.puts, hasLength(1));
    });
  });

  test('a local change is pushed once after the debounce', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      w.attach(link);
      expect(link.puts, isEmpty);
      w.prefs.toggleStar('p:search');
      a.elapse(const Duration(milliseconds: 500));
      w.prefs.toggleStar('p:mode');
      a.elapse(const Duration(milliseconds: 999));
      expect(link.puts, isEmpty);
      a.elapse(const Duration(milliseconds: 2));
      expect(link.puts, hasLength(1));
      expect(link.puts.single.data, ['p:search', 'p:mode']);
      a.elapse(const Duration(seconds: 5));
      expect(link.puts, hasLength(1));
      // the next change goes above what was pushed even at the same ms
      w.prefs.toggleStar('p:model');
      expect(w.prefs.atOf('stars'), greaterThan(link.docs['stars']!.at));
    });
  });

  test('a 409 retries with the returned doc', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      w.attach(link);
      link.docs['stars'] = const QuickDoc(300, ['p:mode']); // written elsewhere, push not heard
      w.prefs.toggleStar('p:search');
      a.elapse(const Duration(seconds: 2));
      expect(link.puts.map((p) => p.base), [100, 300]);
      expect(link.docs['stars']!.data, ['p:search']);
      expect(w.prefs.stars, ['p:search']);

      // a service that is always a step ahead: three more rounds, then wait
      link.puts.clear();
      link.raceForever = true;
      w.prefs.toggleStar('p:model');
      a.elapse(const Duration(seconds: 2));
      expect(link.puts, hasLength(4));
      a.elapse(const Duration(minutes: 5));
      expect(link.puts, hasLength(4));
    });
  });

  test('a watch push older than a pending local edit does not overwrite it', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      w.attach(link);
      a.elapse(const Duration(seconds: 10));
      w.prefs.toggleStar('p:search'); // at t0 + 10 s, still in the debounce
      link.docs['stars'] = QuickDoc(t0, const ['p:mode']);
      w.sync.onPush({
        'what': 'prefs.stars',
        'doc': {'at': t0, 'data': ['p:mode']},
      });
      a.flushMicrotasks();
      expect(w.prefs.stars, ['p:search']);
      a.elapse(const Duration(seconds: 2));
      expect(w.prefs.stars, ['p:search']);
      expect(link.docs['stars']!.data, ['p:search']);
      expect(link.puts.last.base, t0);

      // one at or below synced is ignored
      final pushes = link.puts.length;
      w.sync.onPush({
        'what': 'prefs.stars',
        'doc': {'at': 100, 'data': ['p:compact']},
      });
      a.elapse(const Duration(seconds: 2));
      expect(w.prefs.stars, ['p:search']);
      expect(link.puts, hasLength(pushes));

      // a newer one with nothing pending here is taken
      w.sync.onPush({
        'what': 'prefs.stars',
        'doc': {'at': t0 + 999999, 'data': ['p:compact']},
      });
      a.flushMicrotasks();
      expect(w.prefs.stars, ['p:compact']);
      expect(link.puts, hasLength(pushes));
    });
  });

  test('usage is pushed at most once a minute, others are summed in', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      final today = usageDay(w.clock());
      link.usage['dev-b'] = QuickDoc(5, {
        'p:search': {today: 3},
      });
      w.attach(link);
      expect(w.prefs.others.keys, ['dev-b']);
      expect(w.prefs.others['dev-b']!['p:search']![today], 3);

      w.prefs.recordUse('p:search');
      a.flushMicrotasks();
      a.elapse(const Duration(seconds: 10));
      w.prefs.recordUse('p:search');
      a.elapse(const Duration(seconds: 10));
      w.prefs.recordUse('p:mode');
      a.elapse(const Duration(seconds: 30));
      expect(link.usagePuts, hasLength(1));
      a.elapse(const Duration(seconds: 11));
      expect(link.usagePuts, hasLength(2));
      expect(link.usagePuts.last.device, 'dev-a');
      expect((link.usagePuts.last.data as Map)['p:search'], {today: 2});
      a.elapse(const Duration(minutes: 5));
      expect(link.usagePuts, hasLength(2));
      expect(link.puts, isEmpty);

      w.sync.onPush({
        'what': 'prefs.usage',
        'device': 'dev-c',
        'doc': {
          'at': 9,
          'data': {
            'p:model': {today: 1},
          },
        },
      });
      w.sync.onPush({
        'what': 'prefs.usage',
        'device': 'dev-a',
        'doc': {'at': 1, 'data': {}},
      });
      expect(w.prefs.others.keys.toSet(), {'dev-b', 'dev-c'});
      expect(w.prefs.usage['p:search']![today], 2);
    });
  });

  test('no device id: usage is never pushed', () {
    fakeAsync((a) {
      final w = World(a, device: null);
      final link = FakeLink();
      w.attach(link);
      w.prefs.recordUse('p:search');
      a.elapse(const Duration(minutes: 3));
      expect(link.usagePuts, isEmpty);
    });
  });

  test('a new store id is a first join', () {
    fakeAsync((a) {
      final w = World(a);
      final old = FakeLink(store: 's0');
      w.inStep(old, store: 's0');
      w.prefs.adopt('stars', const QuickDoc(100, ['p:model']));
      final link = FakeLink(store: 's1');
      link.docs['stars'] = const QuickDoc(50, ['p:mode']);
      w.attach(link);
      // known service: 50 <= synced 100 and unchanged here would be a keep; a first join merges
      expect(link.docs['stars']!.data, ['p:mode', 'p:model']);
      expect(w.prefs.stars, ['p:mode', 'p:model']);
      // the docs the service did not have went up as they were
      expect({for (final p in link.puts) p.name}, {'phrases', 'layout', 'stars'});
      final j = jsonDecode(File('${w.dir}/quick-sync.json').readAsStringSync()) as Map;
      expect(j['store'], 's1');
      expect((j['synced'] as Map)['stars'], link.docs['stars']!.at);
    });
  });

  test('a factory doc pushed to an empty service gets a real at', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.attach(link);
      for (final n in quickDocNames) {
        expect(link.docs[n]!.at, greaterThan(0), reason: n);
        expect(w.prefs.atOf(n), link.docs[n]!.at, reason: n);
      }
    });
  });

  test('quick-sync.json survives a restart', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      final today = usageDay(w.clock());
      link.usage['dev-b'] = QuickDoc(5, {
        'p:search': {today: 3},
      });
      w.attach(link);
      w.sync.detach(reachable: false);
      w.sync.dispose();
      final j = jsonDecode(File('${w.dir}/quick-sync.json').readAsStringSync()) as Map;
      expect(j['store'], 's1');
      expect((j['synced'] as Map).keys.toSet(), quickDocNames.toSet());
      expect((j['others'] as Map).keys, ['dev-b']);

      // changed here while away, then later elsewhere: a known service, so the later one wins (no merge)
      a.elapse(const Duration(minutes: 1));
      final prefs2 = QuickPrefs.migrate(const [], clock: w.clock);
      for (final n in [...quickDocNames, 'usage']) {
        prefs2.adopt(n, w.prefs.docOf(n));
      }
      prefs2.toggleStar('p:model');
      link.docs['stars'] = QuickDoc(prefs2.atOf('stars') + 10, const ['p:mode']);
      link.puts.clear();
      final s2 = QuickSync(prefs: prefs2, localDir: w.dir, device: 'dev-a', clock: w.clock);
      expect(prefs2.others.keys, ['dev-b']);
      s2.attach(link);
      a.flushMicrotasks();
      expect(prefs2.stars, ['p:mode']);
      expect(link.puts, isEmpty);
      s2.dispose();
    });
  });

  test('a failed push stays pending and goes with the next change', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      w.attach(link);
      link.failPuts = true;
      w.prefs.toggleStar('p:search');
      a.elapse(const Duration(seconds: 2));
      expect(link.puts, hasLength(1));
      a.elapse(const Duration(minutes: 5));
      expect(link.puts, hasLength(1)); // no retry timer
      link.failPuts = false;
      w.prefs.setLayout(const KeyLayout([
        ['esc'],
        [],
      ]));
      a.elapse(const Duration(seconds: 2));
      expect({for (final p in link.puts.skip(1)) p.name}, {'stars', 'layout'});
      expect(link.docs['stars']!.data, ['p:search']);
    });
  });

  test('detach: waiting when unreachable, local when no prefs', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      expect(w.sync.status, QuickSyncStatus.local);
      w.attach(link);
      expect(w.sync.status, QuickSyncStatus.synced);
      w.prefs.toggleStar('p:search');
      w.sync.detach(reachable: false);
      expect(w.sync.status, QuickSyncStatus.waiting);
      a.elapse(const Duration(seconds: 5));
      expect(link.puts, isEmpty);
      w.sync.onPush({
        'what': 'prefs.stars',
        'doc': {'at': t0 + 999999, 'data': ['p:compact']},
      });
      a.flushMicrotasks();
      expect(w.prefs.stars, ['p:search']);
      w.sync.detach(reachable: true);
      expect(w.sync.status, QuickSyncStatus.local);

      final none = FakeLink()..prefs = false;
      w.attach(none);
      expect(w.sync.status, QuickSyncStatus.local);
      final down = FakeLink()..failAll = true;
      w.attach(down);
      expect(w.sync.status, QuickSyncStatus.waiting);

      // reattached: the edit made while away goes up
      w.attach(link);
      expect(w.sync.status, QuickSyncStatus.synced);
      expect(link.docs['stars']!.data, ['p:search']);
    });
  });
  test('an edit to another doc during a PUT is not overwritten by the stale step', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink(); // empty service: every doc is pushed in one round
      final gate = link.hold['layout'] = Completer<void>();
      w.sync.attach(link);
      a.flushMicrotasks();
      expect(link.puts.map((p) => p.name), ['phrases', 'layout']);
      w.prefs.toggleStar('p:usage');
      gate.complete();
      a.flushMicrotasks();
      expect(w.prefs.stars, ['p:usage']);
      a.elapse(const Duration(seconds: 2));
      expect(w.prefs.stars, ['p:usage']);
      expect(link.docs['stars']!.data, ['p:usage']);
    });
  });

  test('an edit during our own PUT is still pushed when the service clock is ahead', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      w.attach(link);
      final ahead = t0 + 10000000;
      link.docs['stars'] = QuickDoc(ahead, w.prefs.docOf('stars').data);
      w.sync.onPush({
        'what': 'prefs.stars',
        'doc': {'at': ahead, 'data': w.prefs.docOf('stars').data},
      });
      a.flushMicrotasks();
      expect(w.prefs.atOf('stars'), ahead);
      final gate = link.hold['stars'] = Completer<void>();
      w.prefs.toggleStar('p:search');
      a.elapse(const Duration(milliseconds: 1001));
      expect(link.puts.single.at, ahead + 1);
      w.prefs.toggleStar('p:model'); // the clock is still behind the service
      link.hold.remove('stars');
      gate.complete();
      a.elapse(const Duration(seconds: 2));
      expect(w.prefs.stars, ['p:search', 'p:model']);
      expect(link.docs['stars']!.data, ['p:search', 'p:model']);
    });
  });

  test('a newer watch push during our PUT is not rolled back by its 204', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      w.attach(link);
      final gate = link.hold['stars'] = Completer<void>();
      w.prefs.toggleStar('p:search');
      a.elapse(const Duration(milliseconds: 1001));
      expect(link.puts, hasLength(1));
      final later = link.puts.single.at + 5000;
      link.docs['stars'] = QuickDoc(later, const ['p:mode']);
      w.sync.onPush({
        'what': 'prefs.stars',
        'doc': {'at': later, 'data': ['p:mode']},
      });
      gate.complete();
      a.elapse(const Duration(seconds: 2));
      expect(w.prefs.stars, ['p:mode']);
      expect(w.prefs.atOf('stars'), later);
    });
  });

  test('a usage push heard while fetching beats the older fetched cell', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      w.inStep(link);
      final today = usageDay(w.clock());
      link.usage['dev-b'] = QuickDoc(5, {
        'p:search': {today: 3},
      });
      final gate = link.holdAll = Completer<void>();
      w.sync.attach(link);
      a.flushMicrotasks();
      w.sync.onPush({
        'what': 'prefs.usage',
        'device': 'dev-b',
        'doc': {
          'at': 9,
          'data': {
            'p:search': {today: 7},
          },
        },
      });
      gate.complete();
      a.flushMicrotasks();
      expect(w.sync.status, QuickSyncStatus.synced);
      expect(w.prefs.others['dev-b']!['p:search']![today], 7);
    });
  });

  test('an edit on a device whose clock is behind the last sync is still pushed', () {
    fakeAsync((a) {
      final w = World(a);
      final link = FakeLink();
      // Last synced at a time an hour ahead of this clock (another device's clock); then a restart: inStep makes a
      // new QuickSync over quick-sync.json, and the floor the old one had in memory is gone.
      final ahead = t0 + const Duration(hours: 1).inMilliseconds;
      w.inStep(link, at: ahead);
      w.prefs.floor.clear();
      w.sync.dispose();
      w.sync = w.make();
      expect(w.prefs.floor['stars'], ahead + 1, reason: 'the floor comes back from quick-sync.json');
      w.prefs.toggleStar('p:search'); // while not attached yet
      expect(w.prefs.atOf('stars'), greaterThan(ahead));
      w.attach(link);
      expect(link.puts.map((p) => p.name), ['stars']);
      expect(link.docs['stars']!.data, ['p:search']);
    });
  });
}
