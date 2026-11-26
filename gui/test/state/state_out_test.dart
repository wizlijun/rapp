import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/state/state_link.dart';
import 'package:rapp/state/state_out.dart';

void main() {
  late HttpServer server;
  late StateLink link;
  late StateOut out;
  final events = <Map<String, Object?>>[];
  final desks = <(String, Object?)>[];
  final batches = <int>[];
  var requests = 0;
  var inflight = 0;
  Completer<void>? hold;
  int Function(HttpRequest) status = (_) => 204;

  setUp(() async {
    events.clear();
    desks.clear();
    batches.clear();
    requests = 0;
    inflight = 0;
    hold = null;
    status = (_) => 204;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      requests++;
      inflight++;
      final body = await utf8.decodeStream(r);
      final h = hold;
      if (h != null) await h.future;
      final code = status(r);
      if (code < 300) {
        if (r.uri.path == '/v1/events') {
          batches.add(body.split('\n').where((l) => l.isNotEmpty).length);
          for (final l in body.split('\n').where((l) => l.isNotEmpty)) {
            events.add(jsonDecode(l) as Map<String, Object?>);
          }
        } else if (r.uri.path.startsWith('/v1/desk/')) {
          desks.add((r.uri.pathSegments.last, jsonDecode(body)));
        }
      }
      r.response.statusCode = code;
      await r.response.close();
      inflight--;
    });
    link = StateLink(Uri.parse('http://127.0.0.1:${server.port}'));
    out = StateOut(
      clock: () => DateTime.fromMillisecondsSinceEpoch(10000),
      epoch: () => 'e1',
      deskDelay: const Duration(milliseconds: 20),
      retry: const Duration(milliseconds: 50),
    );
  });
  tearDown(() async {
    out.detach();
    link.close();
    await server.close(force: true);
  });

  /// Waits until nothing is in flight and the request count has stopped moving.
  Future<void> settle() async {
    var last = -1;
    var still = 0;
    for (var i = 0; i < 300 && still < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (inflight == 0 && requests == last) {
        still++;
      } else {
        still = 0;
      }
      last = requests;
    }
  }

  const blocked = (state: 'blocked', kind: 'permission', app: 'claude', name: 'Claude');

  test('attach sends a snap per reported device, an empty one for a stale device, then the desk', () async {
    out.setMe('appA', 'iPad');
    out.report(fp: 'devA', id: '111111111', session: 'com.x', now: blocked);
    out.setDesk([
      {'id': '111111111', 'fp': 'devA', 'app': 'com.x', 'name': 'Claude'},
    ]);
    out.attach(link, {
      'desks': [],
      'devices': [
        {
          'fp': 'devB',
          'sessions': [
            {'session': 'com.y', 'by': 'appA', 'src': 'app'},
          ],
        },
        {
          'fp': 'devC',
          'sessions': [
            {'session': 'term:pty:1', 'by': 'devC', 'src': 'term'},
          ],
        },
      ],
    });
    await settle();
    expect(events.map((e) => (e['t'], e['fp'])), [('snap', 'devA'), ('snap', 'devB')]);
    expect(events[0], containsPair('via', 'appA'));
    expect(events[0], containsPair('src', 'app'));
    expect(events[0].containsKey('device'), isFalse);
    expect(
      (events[0]['sessions'] as List).single,
      allOf(
        containsPair('session', 'com.x'),
        containsPair('state', 'blocked'),
        containsPair('kind', 'permission'),
        containsPair('name', 'Claude'),
        contains('since'),
      ),
    );
    expect(events[1]['sessions'], isEmpty);
    expect(events.map((e) => e['n']), [1, 2]);
    expect(desks.single.$1, 'appA');
    expect(
      desks.single.$2,
      {
        'device': 'iPad',
        'sessions': [
          {'id': '111111111', 'fp': 'devA', 'app': 'com.x', 'name': 'Claude'},
        ],
      },
    );
  });

  test('a change sends state, the same again sends nothing, null sends gone', () async {
    out.setMe('appA', 'iPad');
    out.attach(link, {'devices': [], 'desks': []});
    out.report(fp: 'devA', id: '1', session: 'com.x', now: (state: 'running', kind: null, app: null, name: 'X'));
    await settle();
    out.report(fp: 'devA', id: '1', session: 'com.x', now: (state: 'running', kind: null, app: null, name: 'X'));
    await settle();
    expect(events.map((e) => e['t']), ['state']);
    expect(events.single, allOf(containsPair('session', 'com.x'), containsPair('state', 'running'), containsPair('id', '1')));
    expect(events.single.containsKey('kind'), isFalse);
    out.report(fp: 'devA', id: '1', session: 'com.x', now: null);
    await settle();
    out.report(fp: 'devA', id: '1', session: 'com.x', now: null);
    await settle();
    expect(events.map((e) => e['t']), ['state', 'gone']);
    expect(events.last['session'], 'com.x');
  });

  test('nothing is sent before attach or without me', () async {
    out.setMe(null, null);
    out.attach(link, {'devices': [], 'desks': []});
    out.report(fp: 'devA', id: '1', session: 'a', now: blocked);
    out.setDesk([]);
    await settle();
    expect(requests, 0);
    final other = StateOut(deskDelay: const Duration(milliseconds: 20));
    other.setMe('appA', null);
    other.report(fp: 'devA', id: '1', session: 'a', now: blocked);
    other.setDesk([]);
    await settle();
    expect(requests, 0);
    other.detach();
    out.setMe('appA', 'iPad');
    await settle();
    expect(events.map((e) => e['t']), ['snap']);
    expect(desks, hasLength(1));
  });

  test('a failed post re-sends the whole picture after retry', () async {
    out.setMe('appA', 'iPad');
    out.report(fp: 'devA', id: '1', session: 'a', now: blocked);
    var first = true;
    status = (r) {
      if (first) {
        first = false;
        return 500;
      }
      return 204;
    };
    out.attach(link, {'devices': [], 'desks': []});
    await settle();
    expect(events.map((e) => e['t']), ['snap']);
    expect(events.single['n'], 2);
    expect(requests, 2);
  });

  test('a 404 desk is not retried while attached', () async {
    out.setMe('appA', 'iPad');
    status = (r) => r.uri.path.startsWith('/v1/desk/') ? 404 : 204;
    out.attach(link, {'devices': [], 'desks': []});
    out.setDesk([]);
    await settle();
    final after = requests;
    expect(after, 1);
    out.setDesk([
      {'id': '1', 'app': 'x'},
    ]);
    out.setDesk([]);
    await settle();
    expect(requests, after);
    out.report(fp: 'devA', id: '1', session: 'a', now: blocked);
    await settle();
    expect(events.map((e) => e['t']), ['state'], reason: 'events still go out');
    final before = requests;
    out.detach();
    out.attach(link, {'devices': [], 'desks': []});
    await settle();
    expect(requests, before + 2, reason: 'one more desk try, then the snap');
  });

  test('more than 200 pending drops the oldest and re-sends whole', () async {
    out.setMe('appA', 'iPad');
    out.attach(link, {'devices': [], 'desks': []});
    hold = Completer<void>();
    out.report(fp: 'devA', id: '1', session: 's-first', now: blocked);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (var i = 0; i < 201; i++) {
      out.report(fp: 'devA', id: '1', session: 's$i', now: blocked);
    }
    hold!.complete();
    hold = null;
    await settle();
    expect(events.first['t'], 'state');
    expect(events[1]['t'], 'snap');
    expect((events[1]['sessions'] as List), hasLength(202));
    expect(events, hasLength(2));
  });
  test('a service without desks (P2) gets no reports, snaps or desk; a later attach looks again', () async {
    out.setMe('appA', 'iPad');
    out.report(fp: 'devA', id: '1', session: 'a', now: blocked);
    out.setDesk([
      {'id': '1', 'app': 'x'},
    ]);
    out.attach(link, {
      'devices': [
        {
          'fp': 'devB',
          'sessions': [
            {'session': 'com.y', 'by': 'appA', 'src': 'app'},
          ],
        },
      ],
    });
    await settle();
    out.report(fp: 'devA', id: '1', session: 'b', now: blocked);
    out.setDesk([]);
    out.setMe('appA', 'iPad2');
    await settle();
    expect(requests, 0);
    out.attach(link, {'devices': [], 'desks': []});
    await settle();
    expect(events.map((e) => e['t']), ['snap']);
    expect(desks, hasLength(1));
  });

  test('a device whose shared row lists me in vias gets an empty snap', () async {
    out.setMe('appA', 'iPad');
    out.attach(link, {
      'desks': [],
      'devices': [
        {
          'fp': 'devB',
          'sessions': [
            {'session': 'com.y', 'by': 'appMac', 'vias': ['appA', 'appMac'], 'src': 'app'},
          ],
        },
        {
          'fp': 'devC',
          'sessions': [
            {'session': 'com.z', 'by': 'appMac', 'vias': ['appMac'], 'src': 'app'},
          ],
        },
      ],
    });
    await settle();
    expect(events.map((e) => (e['t'], e['fp'])), [('snap', 'devB')]);
  });

  test('events go out at most 50 per post, the rest right after', () async {
    out.setMe('appA', 'iPad');
    out.attach(link, {'devices': [], 'desks': []});
    hold = Completer<void>();
    out.report(fp: 'devA', id: '1', session: 's-first', now: blocked);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (var i = 0; i < 120; i++) {
      out.report(fp: 'devA', id: '1', session: 's$i', now: blocked);
    }
    hold!.complete();
    hold = null;
    await settle();
    expect(batches, [1, 50, 50, 20]);
    expect(events, hasLength(121));
  });

  test('a desk refused with any 4xx is not retried while attached', () async {
    out.setMe('appA', 'iPad');
    status = (r) => r.uri.path.startsWith('/v1/desk/') ? 400 : 204;
    out.attach(link, {'devices': [], 'desks': []});
    out.setDesk([]);
    await settle();
    expect(requests, 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    out.setDesk([
      {'id': '1', 'app': 'x'},
    ]);
    await settle();
    expect(requests, 1, reason: 'no retry, no new try');
    out.report(fp: 'devA', id: '1', session: 'a', now: blocked);
    await settle();
    expect(events.map((e) => e['t']), ['state'], reason: 'events still go out');
  });
}
