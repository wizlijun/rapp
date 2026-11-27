import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/quick/quick_sync.dart';
import 'package:rapp/state/state_config.dart';
import 'package:rapp/state/state_link.dart';
import 'package:rapp/state/state_out.dart';
import 'package:rapp/state/state_sync.dart';

class CountOut extends StateOut {
  int attaches = 0;
  int detaches = 0;
  Map<String, Object?>? snapshot;
  @override
  void attach(StateLink link, Map<String, Object?> snapshot) {
    attaches++;
    this.snapshot = snapshot;
  }
  @override
  void detach() => detaches++;
}

class FakeLink extends StateLink {
  FakeLink(super.base);
  bool healthy = true;
  bool hasPrefs = false;
  int prefsAllCalls = 0;
  Map<String, Object?> stateBody = {'devices': [], 'needs': []};
  Map<String, Object?> queueBody = {'events': [], 'more': false};
  Object? seenError;
  final seenCalls = <Map<String, String?>>[];
  late final watchCtl = StreamController<Map<String, Object?>>(onListen: () => calls.add('watch'));
  bool closed = false;
  int healthCalls = 0;

  /// The order of the calls: health, watch (when it is listened to), state, queue.
  final calls = <String>[];

  /// While set, `state()` waits for it.
  Completer<void>? hold;

  @override
  Future<bool> health() async {
    healthCalls++;
    calls.add('health');
    prefs = hasPrefs;
    return healthy;
  }

  @override
  Future<QuickDoc?> putPref(String name, {required int at, required int base, required Object? data}) async => null;

  @override
  Future<void> putUsage(String device, {required int at, required Object? data}) async {}

  @override
  Future<Map<String, Object?>> prefsAll() async {
    prefsAllCalls++;
    return {'store': 's1'};
  }

  @override
  Future<Map<String, Object?>> state() async {
    calls.add('state');
    await hold?.future;
    return stateBody;
  }

  @override
  Future<Map<String, Object?>> queue({String? before, int limit = 50}) async {
    calls.add('queue');
    return queueBody;
  }
  @override
  Future<void> seen({String? fp, String? session, String? eid, bool handled = false}) async {
    seenCalls.add({'fp': fp, 'session': session, 'eid': eid});
    if (seenError != null) throw seenError!;
  }

  @override
  Stream<Map<String, Object?>> watch() => watchCtl.stream;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

Map<String, Object?> row(String eid, int at, [String session = 't1']) =>
    {'eid': eid, 'at': at, 'session': session, 'fp': 'F'};

void main() {
  late Directory dir;
  late List<FakeLink> links;
  late List<Uri> urls;
  late FakeLink Function(FakeLink) configure;
  late StateSync sync;
  String? found = 'http://h:1';

  final realPrint = debugPrint;
  setUp(() {
    debugPrint = (String? m, {int? wrapWidth}) {};
    dir = Directory.systemTemp.createTempSync('state_sync');
    links = [];
    urls = [];
    configure = (l) => l;
    found = 'http://h:1';
  });
  tearDown(() {
    debugPrint = realPrint;
    dir.deleteSync(recursive: true);
  });

  StateSync make() => sync = StateSync(
    localDir: dir.path,
    find: () async => found,
    link: (u) {
      urls.add(u);
      final l = configure(FakeLink(u));
      links.add(l);
      return l;
    },
    clock: () => DateTime.fromMillisecondsSinceEpoch(0),
  );

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void withState() => configure = (l) => l
    ..stateBody = {
      'devices': [
        {
          'fp': 'F',
          'id': '111',
          'sessions': [
            {'session': 't1', 'seen': 100},
          ],
        },
      ],
      'needs': [],
    }
    ..queueBody = {'events': [row('F:e:2', 200), row('F:e:1', 50)], 'more': false};

  test('off and none open no link', () async {
    const StateConfig(StateMode.off).save(dir.path);
    make().start();
    await settle();
    expect(sync.status, StateStatus.off);
    expect(urls, isEmpty);
    sync.dispose();

    const StateConfig(StateMode.auto).save(dir.path);
    found = null;
    make().start();
    await settle();
    expect(sync.status, StateStatus.none);
    expect(urls, isEmpty);
    sync.dispose();
  });

  test('connect fetches state and a queue page, then watches', () async {
    withState();
    make().start();
    await settle();
    expect(sync.status, StateStatus.connecting);
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    expect(sync.status, StateStatus.connected);
    expect(sync.url, Uri.parse('http://h:1'));
    expect(sync.fpOf('111'), 'F');
    expect(sync.idOf('F'), '111');
    expect(sync.rows.map((r) => r['eid']), ['F:e:2', 'F:e:1']);
    expect(sync.fresh(sync.rows[0]), isTrue);
    expect(sync.fresh(sync.rows[1]), isFalse);
    expect(sync.session('F', 't1')!['seen'], 100);
    sync.dispose();
  });

  test('pushed changes update rows, sessions, needs and seen', () async {
    withState();
    make().start();
    await settle();
    final c = links.single.watchCtl;
    c.add({'what': 'hello'});
    c.add({'what': 'queue', 'row': row('F:e:2', 200)});
    await settle();
    expect(sync.rows.length, 2);
    c.add({'what': 'queue', 'row': row('F:e:3', 300)});
    c.add({'what': 'need', 'needs': [{'fp': 'F', 'session': 't1'}]});
    c.add({'what': 'session', 'fp': 'F', 'session': 't2', 'row': {'session': 't2', 'state': 'working'}});
    c.add({'what': 'seen', 'fp': 'F', 'session': 't1', 'at': 250});
    await settle();
    expect(sync.rows.first['eid'], 'F:e:3');
    expect(sync.needs.length, 1);
    expect(sync.session('F', 't2')!['state'], 'working');
    expect(sync.fresh(sync.rows.first), isTrue);
    expect(sync.fresh(sync.rows[1]), isFalse);
    c.add({'what': 'session', 'fp': 'F', 'session': 't2', 'row': null});
    await settle();
    expect(sync.session('F', 't2'), isNull);
    sync.dispose();
  });

  test('pushes it does not know (prefs.phrases, routes) are ignored and the watch stays open', () async {
    withState();
    make().start();
    await settle();
    final c = links.single.watchCtl;
    c.add({'what': 'hello'});
    await settle();
    final before = sync.rows.length;
    c.add({'what': 'prefs.phrases', 'rev': 1, 'items': []});
    c.add({'what': 'routes', 'routes': []});
    c.add({'what': 'queue', 'row': row('F:e:9', 900)});
    await settle();
    expect(sync.status, StateStatus.connected);
    expect(sync.rows.length, before + 1);
    expect(sync.rows.first['eid'], 'F:e:9');
    expect(links.length, 1);
    expect(links.single.closed, isFalse);
    sync.dispose();
  });

  test('rows are capped at 200', () async {
    withState();
    make().start();
    await settle();
    final c = links.single.watchCtl;
    c.add({'what': 'hello'});
    for (var i = 0; i < 250; i++) {
      c.add({'what': 'queue', 'row': row('F:e:x$i', 1000 + i)});
    }
    await settle();
    expect(sync.rows.length, 200);
    expect(sync.rows.first['eid'], 'F:e:x249');
    sync.dispose();
  });

  test('a wrong health is unreachable and retries with backoff', () {
    fakeAsync((fa) {
      configure = (l) => l..healthy = false;
      make().start();
      fa.flushMicrotasks();
      expect(sync.status, StateStatus.unreachable);
      expect(sync.outage, 1);
      expect(links.length, 1);
      fa.elapse(const Duration(seconds: 1, milliseconds: 900));
      expect(links.length, 1);
      fa.elapse(const Duration(milliseconds: 200));
      expect(links.length, 2);
      expect(links[0].closed, isTrue);
      fa.elapse(const Duration(seconds: 3, milliseconds: 700));
      expect(links.length, 2);
      fa.elapse(const Duration(milliseconds: 200));
      expect(links.length, 3);
      expect(sync.outage, 1);
      // 8, 16, 32, 60, 60
      fa.elapse(const Duration(seconds: 8 + 16 + 32 + 60 + 60));
      expect(links.length, 8);
      sync.dispose();
    });
  });

  test('backoff resets after a hello', () {
    fakeAsync((fa) {
      configure = (l) => l..healthy = false;
      make().start();
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 2)); // second attempt
      fa.elapse(const Duration(seconds: 4)); // third attempt
      expect(links.length, 3);
      // the next attempt gets a healthy link
      configure = (l) => l;
      fa.elapse(const Duration(seconds: 8));
      expect(links.length, 4);
      fa.flushMicrotasks();
      links.last.watchCtl.add({'what': 'hello'});
      fa.flushMicrotasks();
      expect(sync.status, StateStatus.connected);
      links.last.watchCtl.addError(const StateLinkError(0));
      fa.flushMicrotasks();
      expect(sync.status, StateStatus.unreachable);
      expect(sync.outage, 2);
      fa.elapse(const Duration(seconds: 2));
      expect(links.length, 5);
      sync.dispose();
    });
  });

  test('auto with nothing found looks again after 60 seconds, not an outage', () {
    fakeAsync((fa) {
      found = null;
      make().start();
      fa.flushMicrotasks();
      expect(sync.status, StateStatus.none);
      found = 'http://h:1';
      fa.elapse(const Duration(seconds: 59));
      expect(sync.status, StateStatus.none);
      fa.elapse(const Duration(seconds: 2));
      expect(sync.status, StateStatus.connecting);
      expect(sync.outage, 0);
      sync.dispose();
    });
  });

  test('seen while unreachable is kept and sent on reconnect, at most 200', () async {
    configure = (l) => l..healthy = false;
    final s = make();
    s.start();
    await settle();
    expect(s.status, StateStatus.unreachable);
    // fpOf needs a known device: go through one good connect first
    s.dispose();

    withState();
    final s2 = make();
    s2.start();
    await settle();
    links.last.watchCtl.add({'what': 'hello'});
    await settle();
    links.last.watchCtl.addError(const StateLinkError(0));
    await settle();
    expect(s2.status, StateStatus.unreachable);
    for (var i = 0; i < 201; i++) {
      s2.markSeen('111', 's$i');
    }
    s2.markSeen('999', 'unknown');
    expect(links.last.seenCalls, isEmpty);
    await s2.refresh();
    await settle();
    final l = links.last;
    l.watchCtl.add({'what': 'hello'});
    await settle();
    expect(l.seenCalls.length, 200);
    expect(l.seenCalls.first['session'], 's1');
    expect(l.seenCalls.last['session'], 's200');
    s2.dispose();
  });

  test('markSeen while connected sends at once; a 404 is dropped, a network error is kept', () async {
    withState();
    make().start();
    await settle();
    final l = links.single;
    l.watchCtl.add({'what': 'hello'});
    await settle();
    sync.markSeen('111', 't1');
    await settle();
    expect(l.seenCalls.length, 1);
    expect(l.seenCalls.single['fp'], 'F');
    l.seenError = const StateLinkError(404);
    sync.markSeen('111', 't9');
    await settle();
    expect(l.seenCalls.length, 2);
    l.seenError = const StateLinkError(0);
    sync.markSeen('111', 't8');
    await settle();
    expect(l.seenCalls.length, 3);
    // a later hello resends only the kept one
    l.seenError = null;
    l.watchCtl.add({'what': 'hello'});
    await settle();
    expect(l.seenCalls.length, 4);
    expect(l.seenCalls.last['session'], 't8');
    sync.dispose();
  });

  test('refresh refetches and a watch error goes unreachable then reconnects', () async {
    withState();
    make().start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    await sync.refresh();
    await settle();
    expect(links.length, 2);
    expect(links[0].closed, isTrue);
    links[1].watchCtl.add({'what': 'hello'});
    await settle();
    expect(sync.status, StateStatus.connected);
    links[1].watchCtl.addError(const StateLinkError(0));
    await settle();
    expect(sync.status, StateStatus.unreachable);
    expect(sync.outage, 1);
    sync.dispose();
  });

  test('a watch that ends normally is unreachable too', () async {
    withState();
    make().start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    await links.single.watchCtl.close();
    await settle();
    expect(sync.status, StateStatus.unreachable);
    sync.dispose(); // the 2 s retry timer goes with it
  });

  test('the second queue page replaces newer rows and keeps older ones', () async {
    withState();
    make().start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    links.single.watchCtl.add({'what': 'queue', 'row': row('F:e:9', 900)});
    await settle();
    expect(sync.rows.map((r) => r['eid']), ['F:e:9', 'F:e:2', 'F:e:1']);
    configure = (l) => l..queueBody = {'events': [row('F:e:3', 300), row('F:e:2', 200)], 'more': false};
    await sync.refresh();
    await settle();
    links.last.watchCtl.add({'what': 'hello'});
    await settle();
    // page oldest at=200: rows with at>=200 replaced by the page; e:1 (at 50) stays
    expect(sync.rows.map((r) => r['eid']), ['F:e:3', 'F:e:2', 'F:e:1']);
    sync.dispose();
  });

  test('pause closes the link and keeps the status; refresh starts again', () async {
    withState();
    make().start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    sync.pause();
    expect(links.single.closed, isTrue);
    expect(sync.status, StateStatus.connected);
    await sync.refresh();
    await settle();
    expect(links.length, 2);
    sync.dispose();
  });

  test('start twice is a no-op', () async {
    withState();
    make()
      ..start()
      ..start();
    await settle();
    expect(links.length, 1);
    sync.dispose();
  });

  test('setConfig saves and reconnects to the manual url', () async {
    withState();
    make().start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    await sync.setConfig(const StateConfig(StateMode.manual, url: 'http://z:9'));
    await settle();
    expect(urls.last, Uri.parse('http://z:9'));
    expect(links.first.closed, isTrue);
    expect(StateConfig.load(dir.path).url, 'http://z:9');
    await sync.setConfig(const StateConfig(StateMode.off));
    await settle();
    expect(sync.status, StateStatus.off);
    expect(links.last.closed, isTrue);
    sync.dispose();
  });

  test('the watch opens first; a push during the fetch is applied after the snapshot', () async {
    withState();
    make().start();
    await settle();
    final l = links.single;
    final hold = l.hold = Completer<void>();
    l.watchCtl.add({'what': 'hello'});
    await settle();
    expect(l.calls, ['health', 'watch', 'state']);
    expect(sync.status, StateStatus.connecting);
    l.watchCtl
      ..add({'what': 'queue', 'row': row('F:e:3', 300)})
      ..add({'what': 'session', 'fp': 'F', 'session': 't2', 'row': {'session': 't2', 'state': 'working'}})
      ..add({'what': 'seen', 'fp': 'F', 'session': 't1', 'at': 250});
    await settle();
    expect(sync.rows, isEmpty, reason: 'held until the snapshot is in');
    hold.complete();
    await settle();
    expect(l.calls, ['health', 'watch', 'state', 'queue']);
    expect(sync.status, StateStatus.connected);
    expect(sync.rows.map((r) => r['eid']), ['F:e:3', 'F:e:2', 'F:e:1']);
    expect(sync.session('F', 't2')!['state'], 'working');
    expect(sync.session('F', 't1')!['seen'], 250);
    sync.dispose();
  });

  test('a session push for a device unknown at connect adds it', () async {
    withState();
    make().start();
    await settle();
    final l = links.single;
    l.watchCtl.add({'what': 'hello'});
    await settle();
    expect(sync.fpOf('222'), isNull);
    l.watchCtl.add({
      'what': 'session',
      'fp': 'G',
      'id': '222',
      'device': 'pad',
      'session': 't5',
      'row': {'session': 't5', 'name': 'build', 'state': 'working'},
    });
    await settle();
    expect(sync.fpOf('222'), 'G');
    expect(sync.idOf('G'), '222');
    expect(sync.session('G', 't5')!['name'], 'build');
    sync.markSeen('222', 't5');
    await settle();
    expect(l.seenCalls.last, {'fp': 'G', 'session': 't5', 'eid': null});
    sync.dispose();
  });

  test('a session push of an unknown device without id fetches the state again, once, a second later', () {
    fakeAsync((fa) {
      withState();
      make().start();
      fa.flushMicrotasks();
      final l = links.single;
      l.watchCtl.add({'what': 'hello'});
      fa.flushMicrotasks();
      expect(l.calls.where((c) => c == 'state'), hasLength(1));
      l.stateBody = {
        'devices': [
          ...(l.stateBody['devices'] as List),
          {
            'fp': 'G',
            'id': '222',
            'sessions': [
              {'session': 't5', 'name': 'build'},
            ],
          },
        ],
        'needs': [],
      };
      for (final sid in ['t5', 't6']) {
        l.watchCtl.add({'what': 'session', 'fp': 'G', 'session': sid, 'row': {'session': sid}});
      }
      fa.flushMicrotasks();
      sync.markSeen('222', 't5');
      fa.flushMicrotasks();
      expect(l.seenCalls, isEmpty);
      fa.elapse(const Duration(milliseconds: 900));
      expect(l.calls.where((c) => c == 'state'), hasLength(1));
      fa.elapse(const Duration(milliseconds: 200));
      expect(l.calls.where((c) => c == 'state'), hasLength(2));
      expect(sync.fpOf('222'), 'G');
      expect(sync.session('G', 't5')!['name'], 'build');
      expect(l.seenCalls, [
        {'fp': 'G', 'session': 't5', 'eid': null},
      ]);
      sync.dispose();
    });
  });

  test('refresh while connected keeps the snapshot; only a second failed try is an outage', () {
    fakeAsync((fa) {
      withState();
      make().start();
      fa.flushMicrotasks();
      links.single.watchCtl.add({'what': 'hello'});
      fa.flushMicrotasks();
      expect(sync.hasSnapshot, isTrue);
      sync.pause();
      configure = (l) => l..healthy = false;
      sync.refresh();
      fa.flushMicrotasks();
      expect(links, hasLength(2));
      expect(sync.status, StateStatus.connecting);
      expect(sync.hasSnapshot, isTrue);
      expect(sync.outage, 0);
      expect(sync.rows, hasLength(2));
      fa.elapse(const Duration(seconds: 1, milliseconds: 900));
      expect(links, hasLength(2));
      fa.elapse(const Duration(milliseconds: 200));
      expect(links, hasLength(3));
      expect(sync.status, StateStatus.unreachable);
      expect(sync.hasSnapshot, isFalse);
      expect(sync.outage, 1);
      sync.dispose();
    });
  });

  test('refresh while connected that succeeds never leaves the service view', () async {
    withState();
    make().start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    final seen = <(StateStatus, bool)>[];
    sync.addListener(() => seen.add((sync.status, sync.hasSnapshot)));
    await sync.refresh();
    await settle();
    links.last.watchCtl.add({'what': 'hello'});
    await settle();
    expect(seen.every((s) => s.$2), isTrue, reason: '$seen');
    expect(sync.status, StateStatus.connected);
    expect(sync.outage, 0);
    sync.dispose();
  });

  test('the snapshot goes with a new config and with off', () async {
    withState();
    make().start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    expect(sync.hasSnapshot, isTrue);
    await sync.setConfig(const StateConfig(StateMode.manual, url: 'http://z:9'));
    expect(sync.hasSnapshot, isFalse);
    expect(sync.rows, isEmpty);
    expect(sync.fpOf('111'), isNull);
    await settle();
    links.last.watchCtl.add({'what': 'hello'});
    await settle();
    expect(sync.hasSnapshot, isTrue);
    await sync.setConfig(const StateConfig(StateMode.off));
    expect(sync.hasSnapshot, isFalse);
    expect(sync.needs, isEmpty);
    sync.dispose();
  });

  test('a mark made before the first connect is sent once connected', () async {
    withState();
    make();
    sync.markSeen('111', 't1');
    sync.start();
    await settle();
    final l = links.single;
    expect(l.seenCalls, isEmpty);
    l.watchCtl.add({'what': 'hello'});
    await settle();
    expect(l.seenCalls, [
      {'fp': 'F', 'session': 't1', 'eid': null},
    ]);
    sync.dispose();
  });

  test('marks of one session waiting together go out as one PUT', () async {
    withState();
    make().start();
    await settle();
    final l = links.single;
    for (var i = 0; i < 5; i++) {
      sync.markSeen('111', 't1');
    }
    sync.markSeen('111', 't2');
    l.watchCtl.add({'what': 'hello'});
    await settle();
    expect(l.seenCalls.map((c) => c['session']), ['t1', 't2']);
    sync.dispose();
  });

  test('nothing fires after dispose', () {
    fakeAsync((fa) {
      configure = (l) => l..healthy = false;
      make().start();
      fa.flushMicrotasks();
      sync.dispose();
      fa.elapse(const Duration(minutes: 5));
      expect(links.length, 1);
    });
  });

  test('desks come from the state and from desk pushes', () async {
    configure = (l) => l
      ..stateBody = {
        'devices': [],
        'needs': [],
        'desks': [
          {'fp': 'appA', 'at': 1, 'sessions': []},
        ],
      };
    make().start();
    await settle();
    final c = links.single.watchCtl;
    c.add({'what': 'hello'});
    await settle();
    expect(sync.desks.map((d) => d['fp']), ['appA']);
    c.add({
      'what': 'desk',
      'fp': 'appB',
      'desk': {'at': 2, 'sessions': []},
    });
    await settle();
    expect(sync.desks.map((d) => d['fp']), ['appA', 'appB']);
    c.add({'what': 'desk', 'fp': 'appA', 'desk': null});
    await settle();
    expect(sync.desks.map((d) => d['fp']), ['appB']);
    sync.dispose();
  });

  test('the snapshot attaches out, a drop detaches it', () async {
    final out = CountOut();
    withState();
    sync = StateSync(
      localDir: dir.path,
      find: () async => found,
      link: (u) => configure(FakeLink(u))..also(links.add),
      out: out,
    )..start();
    await settle();
    expect(out.attaches, 0);
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    expect(out.attaches, 1);
    final before = out.detaches;
    links.single.watchCtl.addError('x');
    await settle();
    expect(sync.status, StateStatus.unreachable);
    expect(out.detaches, greaterThan(before));
    expect(sync.desks, isEmpty);
    sync.dispose();
  });

  test('out sees desks only when the service gave them', () async {
    final out = CountOut();
    withState();
    sync = StateSync(
      localDir: dir.path,
      find: () async => found,
      link: (u) => configure(FakeLink(u))..also(links.add),
      out: out,
    )..start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    expect(out.snapshot!.containsKey('desks'), isFalse, reason: 'a P2 service has no desks key');
    sync.dispose();

    links.clear();
    configure = (l) => l..stateBody = {'devices': [], 'desks': [], 'needs': []};
    sync = StateSync(
      localDir: dir.path,
      find: () async => found,
      link: (u) => configure(FakeLink(u))..also(links.add),
      out: out,
    )..start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    expect(out.snapshot!['desks'], isEmpty);
    sync.dispose();
  });

  group('quick sync', () {
    late QuickPrefs qp;
    late QuickSync quick;
    setUp(() {
      qp = QuickPrefs.migrate(const []);
      quick = QuickSync(prefs: qp, localDir: dir.path, device: 'dev-a');
    });
    tearDown(() => quick.dispose());

    StateSync makeQ() => sync = StateSync(
          localDir: dir.path,
          find: () async => found,
          quick: quick,
          link: (u) {
            final l = configure(FakeLink(u));
            links.add(l);
            return l;
          },
        );

    test('a service with prefs: synced; without: local; dropped: waiting', () async {
      configure = (l) => l..hasPrefs = true;
      makeQ().start();
      await settle();
      links.single.watchCtl.add({'what': 'hello'});
      await settle();
      expect(quick.status, QuickSyncStatus.synced);
      expect(links.single.prefsAllCalls, 1);
      links.single.watchCtl.addError('boom');
      await settle();
      expect(quick.status, QuickSyncStatus.waiting);
      sync.dispose();

      links.clear();
      configure = (l) => l;
      makeQ().start();
      await settle();
      links.single.watchCtl.add({'what': 'hello'});
      await settle();
      expect(quick.status, QuickSyncStatus.local);
      sync.dispose();
    });

    test('a pushed prefs doc changes the local prefs', () async {
      configure = (l) => l..hasPrefs = true;
      makeQ().start();
      await settle();
      final c = links.single.watchCtl;
      c.add({'what': 'hello'});
      await settle();
      c.add({
        'what': 'prefs.stars',
        'doc': {'at': DateTime.now().millisecondsSinceEpoch + 100000, 'data': ['k:mode']},
      });
      await settle();
      expect(qp.stars, ['k:mode']);
      sync.dispose();
    });

    test('refresh reconnects and fetches /prefs/v1/all again', () async {
      configure = (l) => l..hasPrefs = true;
      makeQ().start();
      await settle();
      links.single.watchCtl.add({'what': 'hello'});
      await settle();
      sync.refresh();
      await settle();
      links.last.watchCtl.add({'what': 'hello'});
      await settle();
      expect(links.fold<int>(0, (a, l) => a + l.prefsAllCalls), 2);
      sync.dispose();
    });

    test('a failed first try after refresh keeps the quick line synced', () {
      fakeAsync((fa) {
        configure = (l) => l..hasPrefs = true;
        makeQ().start();
        fa.flushMicrotasks();
        links.single.watchCtl.add({'what': 'hello'});
        fa.flushMicrotasks();
        expect(quick.status, QuickSyncStatus.synced);
        final seen = <QuickSyncStatus>[];
        quick.addListener(() => seen.add(quick.status));
        sync.pause();
        configure = (l) => l
          ..hasPrefs = true
          ..healthy = false;
        sync.refresh();
        fa.flushMicrotasks();
        expect(links, hasLength(2));
        expect(quick.status, QuickSyncStatus.synced, reason: 'one failed try after a refresh is not an outage yet');
        fa.elapse(const Duration(seconds: 2, milliseconds: 100));
        expect(links, hasLength(3));
        expect(quick.status, QuickSyncStatus.waiting, reason: 'the second one is');
        expect(seen, [QuickSyncStatus.waiting]);
        sync.dispose();
      });
    });

    test('off goes back to local', () async {
      const StateConfig(StateMode.off).save(dir.path);
      makeQ().start();
      await settle();
      expect(quick.status, QuickSyncStatus.local);
      sync.dispose();
    });
  });
}

extension<T> on T {
  void also(void Function(T) f) => f(this);
}
