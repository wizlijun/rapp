import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/state/state_config.dart';
import 'package:rapp/state/state_link.dart';
import 'package:rapp/state/state_sync.dart';

class FakeLink extends StateLink {
  FakeLink(super.base);
  bool healthy = true;
  Map<String, Object?> stateBody = {'devices': [], 'needs': []};
  Map<String, Object?> queueBody = {'events': [], 'more': false};
  Object? seenError;
  final seenCalls = <Map<String, String?>>[];
  final watchCtl = StreamController<Map<String, Object?>>();
  bool closed = false;
  int healthCalls = 0;

  @override
  Future<bool> health() async {
    healthCalls++;
    return healthy;
  }

  @override
  Future<Map<String, Object?>> state() async => stateBody;
  @override
  Future<Map<String, Object?>> queue({String? before, int limit = 50}) async => queueBody;
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
}
