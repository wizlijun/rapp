import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';

import 'fakes.dart';

void main() {
  group('codec', () {
    test('encodeLine writes one JSON object terminated by newline', () {
      final line = encodeLine({'cmd': 'hosts', 'req': 1});
      expect(line, '{"cmd":"hosts","req":1}\n');
    });

    test('decodeLine parses objects and rejects garbage', () {
      expect(decodeLine('{"event":"hosts","hosts":[]}'),
          {'event': 'hosts', 'hosts': []});
      expect(decodeLine('  {"a":1}\r'), {'a': 1});
      expect(decodeLine('not json'), isNull);
      expect(decodeLine('[1,2]'), isNull);
      expect(decodeLine(''), isNull);
    });
  });

  group('HubClient', () {
    late FakeTransport t;
    late HubClient hub;

    setUp(() {
      t = FakeTransport();
      hub = HubClient(t);
    });

    test('open with embed sends the flag and keeps port and token', () async {
      final f = hub.open('a', 'com.x', embed: true);
      final cmd = t.sent.last;
      expect(cmd, {'cmd': 'open', 'id': 'a', 'app': 'com.x', 'embed': true, 'req': anything});
      t.emit({
        'event': 'opened', 'sid': 1, 'id': 'a', 'app': 'com.x', 'path': 'lan',
        'port': 5000, 'token': 'tk', 'req': cmd['req'],
      });
      final s = await f;
      expect([s.port, s.token], [5000, 'tk']);
    });

    test('open without embed sends no embed key', () async {
      final f = hub.open('a', 'com.x');
      expect(t.sent.last.containsKey('embed'), isFalse);
      t.emit({'event': 'opened', 'sid': 1, 'id': 'a', 'app': 'com.x', 'path': 'lan', 'req': t.sent.last['req']});
      final s = await f;
      expect([s.port, s.token], [null, null]);
    });

    test('close carries reason user', () {
      hub.close(3, reason: 'user');
      expect(t.sent.last, {'cmd': 'close', 'sid': 3, 'reason': 'user'});
      hub.close(4);
      expect(t.sent.last, {'cmd': 'close', 'sid': 4});
    });

    test('open marks reconnect', () async {
      final f = hub.open('111', 'a', embed: true, reconnect: true);
      expect(t.sent.last['reconnect'], isTrue);
      t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'a', 'path': 'lan', 'req': t.sent.last['req']});
      await f;
      final g = hub.open('111', 'a', embed: true);
      expect(t.sent.last.containsKey('reconnect'), isFalse);
      t.emit({'event': 'opened', 'sid': 2, 'id': '111', 'app': 'a', 'path': 'lan', 'req': t.sent.last['req']});
      await g;
    });

    test('net: the level as pushed, none forgets it; askNet, watch and netSuspect send their commands', () async {
      expect(hub.net, isNull);
      t.emit({'event': 'net', 'level': 'ok', 'rtt_ms': 160, 'loss': 0.03});
      await Future<void>.delayed(Duration.zero);
      expect(hub.net, const NetStatus(NetLevel.ok, 160, 0.03));
      t.emit({'event': 'net', 'level': 'down', 'loss': 1});
      await Future<void>.delayed(Duration.zero);
      expect(hub.net, const NetStatus(NetLevel.down, null, 1.0));
      t.emit({'event': 'net', 'level': 'none'});
      await Future<void>.delayed(Duration.zero);
      expect(hub.net, isNull);
      t.emit({'event': 'net', 'level': 'bogus'});
      await Future<void>.delayed(Duration.zero);
      expect(hub.net, isNull);
      hub.askNet();
      expect(t.sent.last, {'cmd': 'net'});
      hub.watch('111', true);
      expect(t.sent.last, {'cmd': 'watch', 'id': '111', 'on': true});
      hub.watch('111', false);
      expect(t.sent.last, {'cmd': 'watch', 'id': '111', 'on': false});
      hub.netSuspect();
      expect(t.sent.last, {'cmd': 'net_suspect'});
    });

    test('apps carry the desktop entry\'s screens; bad screens are skipped', () async {
      final f = hub.apps('111');
      t.emit({
        'event': 'apps', 'id': '111', 'path': 'lan', 'req': t.sent.last['req'],
        'apps': [
          {
            'app': 'desktop:', 'name': '桌面',
            'displays': [
              {'id': '1', 'name': 'Built-in', 'main': true, 'width': 1512, 'height': 982},
              {'id': '69733382', 'name': 'LG', 'main': false, 'width': 2560, 'height': 1440},
              {'id': 7, 'width': 1, 'height': 1},
              'junk',
            ],
          },
          {'app': 'com.apple.Safari', 'name': 'Safari'},
        ],
      });
      final apps = (await f).apps;
      final d = apps.first.displays;
      expect(d.map((x) => (x.id, x.name, x.main, x.width, x.height)),
          [('1', 'Built-in', true, 1512, 982), ('69733382', 'LG', false, 2560, 1440)]);
      expect(apps.last.displays, isEmpty);
    });

    test('presence is queued and drained', () async {
      final f = hub.apps('111');
      final req = t.sent.last['req'];
      t.emit({'event': 'presence', 'id': '111', 'online': true});
      t.emit({'event': 'presence', 'id': '222', 'online': false});
      await Future<void>.delayed(Duration.zero);
      expect(hub.takePresence(), [(id: '111', online: true, error: null), (id: '222', online: false, error: null)]);
      expect(hub.takePresence(), isEmpty);
      t.emit({'event': 'apps', 'id': '111', 'path': 'lan', 'apps': [], 'req': req});
      expect((await f).id, '111');
    });

    test('presence keeps only the latest entry per id, so it cannot grow without a reader', () async {
      t.emit({'event': 'presence', 'id': '111', 'online': true});
      t.emit({'event': 'presence', 'id': '222', 'online': false});
      for (var i = 0; i < 50; i++) {
        t.emit({'event': 'presence', 'id': '111', 'online': i.isEven});
      }
      await Future<void>.delayed(Duration.zero);
      expect(hub.takePresence(), [(id: '222', online: false, error: null), (id: '111', online: false, error: null)]);
    });

    test('presence carries the error when offline', () async {
      t.emit({'event': 'presence', 'id': '111', 'online': false, 'error': 'relay unreachable: timed out'});
      t.emit({'event': 'presence', 'id': '222', 'online': true});
      await Future<void>.delayed(Duration.zero);
      expect(hub.takePresence(), [
        (id: '111', online: false, error: 'relay unreachable: timed out'),
        (id: '222', online: true, error: null),
      ]);
    });

    test('hosts carry route', () async {
      t.emit({
        'event': 'hosts',
        'hosts': [
          {'id': '1', 'name': 'a', 'route': 'relay'},
          {'id': '2', 'name': 'b'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(hub.hosts[0].forcedRelay, isTrue);
      expect(hub.hosts[0].route, 'relay');
      expect(hub.hosts[1].forcedRelay, isFalse);
      expect(hub.hosts[1].route, isNull);
    });

    test('path events update hostPaths and queue the latest per host', () async {
      t.emit({'event': 'path', 'id': '1', 'path': 'relay'});
      t.emit({'event': 'path', 'id': '2', 'path': 'direct'});
      t.emit({'event': 'path', 'id': '1', 'path': 'lan'});
      await Future<void>.delayed(Duration.zero);
      expect(hub.hostPaths, {'1': 'lan', '2': 'direct'});
      expect(hub.takePaths(), [(id: '2', path: 'direct'), (id: '1', path: 'lan')]);
      expect(hub.takePaths(), isEmpty);
      expect(hub.hostPaths['1'], 'lan');
    });

    test('a hosts list drops the paths of removed hosts; set_home and hub exit forget them all', () async {
      t.emit({'event': 'path', 'id': '1', 'path': 'relay'});
      t.emit({'event': 'path', 'id': '2', 'path': 'lan'});
      t.emit({'event': 'hosts', 'hosts': [{'id': '2', 'name': 'b'}]});
      await Future<void>.delayed(Duration.zero);
      expect(hub.hostPaths, {'2': 'lan'});
      final f = hub.setHome('/x');
      t.emit({'event': 'home_set', 'req': t.sent.last['req']});
      await f;
      expect(hub.hostPaths, isEmpty);
      t.emit({'event': 'path', 'id': '2', 'path': 'lan'});
      await Future<void>.delayed(Duration.zero);
      await t.die();
      await Future<void>.delayed(Duration.zero);
      expect(hub.hostPaths, isEmpty);
    });

    test('setRoute sends set_route and waits for hosts', () async {
      var done = false;
      final f = hub.setRoute('1', 'relay').then((_) => done = true);
      final cmd = t.sent.last;
      expect(cmd, {'cmd': 'set_route', 'id': '1', 'route': 'relay', 'req': anything});
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      t.emit({
        'event': 'hosts',
        'req': cmd['req'],
        'hosts': [
          {'id': '1', 'name': 'a', 'route': 'relay'},
        ],
      });
      await f;
      expect(hub.hosts.single.forcedRelay, isTrue);
    });

    test('setRoute fails on an error reply', () async {
      final f = hub.setRoute('9', 'auto');
      t.emit({'event': 'error', 'req': t.sent.last['req'], 'error': 'unknown host'});
      await expectLater(f, throwsA(isA<HubException>()));
    });

    test('routeFailed sends route_failed and waits for nothing', () {
      hub.routeFailed('1');
      expect(t.sent.last, {'cmd': 'route_failed', 'id': '1'});
    });

    test('note sends what and windows', () {
      hub.note(1, 'detach', 2);
      expect(t.sent.last, {'cmd': 'note', 'sid': 1, 'what': 'detach', 'windows': 2});
    });

    test('focus sends the sid', () {
      hub.focus(3);
      expect(t.sent.last, {'cmd': 'focus', 'sid': 3});
    });

    test('hosts request carries req and resolves with the hosts event', () async {
      final f = hub.refreshHosts();
      expect(t.sent.single['cmd'], 'hosts');
      final req = t.sent.single['req'];
      expect(req, isNotNull);
      expect(t.rawSent.single.endsWith('\n'), isTrue);
      t.emit({
        'event': 'hosts',
        'req': req,
        'hosts': [
          {'id': '123456789', 'name': 'mac-a'},
          {'id': '987654321', 'name': 'mac-b'},
        ],
      });
      final hosts = await f;
      expect(hosts.map((h) => h.id), ['123456789', '987654321']);
      expect(hub.hosts.map((h) => h.name), ['mac-a', 'mac-b']);
    });

    test('add_host sends id+password and adds the host on host_added', () async {
      final f = hub.addHost('123456789', 'pw12');
      final cmd = t.sent.single;
      expect(cmd['cmd'], 'add_host');
      expect(cmd['id'], '123456789');
      expect(cmd['password'], 'pw12');
      t.emit({'event': 'host_added', 'req': cmd['req'], 'id': '123456789', 'name': 'mac-a'});
      final h = await f;
      expect(h.name, 'mac-a');
      expect(hub.hosts.single.id, '123456789');
    });

    test('host_added for a saved host keeps its route and LAN addresses', () async {
      t.emit({
        'event': 'hosts',
        'hosts': [
          {'id': '123456789', 'name': 'old', 'lan': ['192.168.1.5:22028'], 'route': 'relay'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      final f = hub.addHost('123456789', '');
      t.emit({'event': 'host_added', 'req': t.sent.last['req'], 'id': '123456789', 'name': 'mac-a'});
      await f;
      final h = hub.hosts.single;
      expect((h.name, h.forcedRelay), ('mac-a', true));
      expect(h.lan, ['192.168.1.5:22028']);
    });

    test('error event with req fails the matching request', () async {
      final f = hub.addHost('123456789', 'bad');
      final req = t.sent.single['req'];
      t.emit({'event': 'error', 'req': req, 'error': 'bad password'});
      await expectLater(
          f, throwsA(isA<HubException>().having((e) => e.message, 'message', 'bad password')));
      expect(hub.hosts, isEmpty);
    });

    test('error event without req is surfaced as lastError', () async {
      t.emit({'event': 'error', 'error': 'offline'});
      await pumpEventQueue();
      expect(hub.lastError, 'offline');
    });

    test('remove_host resolves with the refreshed list', () async {
      final f = hub.removeHost('123456789');
      final cmd = t.sent.single;
      expect(cmd['cmd'], 'remove_host');
      expect(cmd['id'], '123456789');
      t.emit({'event': 'hosts', 'req': cmd['req'], 'hosts': []});
      expect(await f, isEmpty);
    });

    test('setHome sends set_home and waits for home_set', () async {
      final f = hub.setHome('/new/local');
      final cmd = t.sent.single;
      expect(cmd['cmd'], 'set_home');
      expect(cmd['dir'], '/new/local');
      t.emit({'event': 'home_set', 'req': cmd['req']});
      await f;
    });

    test('apps resolves with path and app list', () async {
      final f = hub.apps('123456789');
      final cmd = t.sent.single;
      expect(cmd, containsPair('cmd', 'apps'));
      expect(cmd, containsPair('id', '123456789'));
      t.emit({
        'event': 'apps',
        'req': cmd['req'],
        'id': '123456789',
        'path': 'lan',
        'apps': [
          {'app': 'com.apple.Safari', 'name': 'Safari'},
        ],
      });
      final r = await f;
      expect(r.path, 'lan');
      expect(r.apps.single.app, 'com.apple.Safari');
      expect(r.apps.single.name, 'Safari');
    });

    test('a reply without req still resolves the oldest pending request of that kind', () async {
      final f = hub.apps('1');
      t.emit({'event': 'apps', 'id': '1', 'path': 'lan', 'apps': []});
      expect((await f).path, 'lan');
    });

    test('open → opened adds a session, closed removes it', () async {
      var notified = 0;
      hub.addListener(() => notified++);
      final f = hub.open('123456789', 'com.apple.Safari');
      final cmd = t.sent.single;
      expect(cmd['cmd'], 'open');
      expect(cmd['id'], '123456789');
      expect(cmd['app'], 'com.apple.Safari');
      t.emit({
        'event': 'opened',
        'req': cmd['req'],
        'sid': 7,
        'id': '123456789',
        'app': 'com.apple.Safari',
        'path': 'direct',
      });
      final s = await f;
      expect(s.sid, 7);
      expect(s.path, 'direct');
      expect(hub.sessions.single.app, 'com.apple.Safari');

      hub.close(7);
      expect(t.sent.last, containsPair('cmd', 'close'));
      expect(t.sent.last['sid'], 7);

      t.emit({'event': 'closed', 'sid': 7, 'reason': 'client exited'});
      await pumpEventQueue();
      expect(hub.sessions, isEmpty);
      expect(notified, greaterThanOrEqualTo(2));
    });

    test('garbage lines are ignored', () async {
      t.emitRaw('hello from hub');
      final f = hub.refreshHosts();
      t.emit({'event': 'hosts', 'req': t.sent.single['req'], 'hosts': []});
      expect(await f, isEmpty);
    });

    test('hub exit fails pending requests, clears sessions and marks it dead', () async {
      final f = hub.open('1', 'x');
      t.emit({'event': 'opened', 'sid': 1, 'id': '1', 'app': 'x', 'path': 'lan', 'req': t.sent.single['req']});
      await f;
      final g = hub.apps('1');
      await t.die();
      await expectLater(g, throwsA(isA<HubException>()));
      expect(hub.alive, isFalse);
      expect(hub.sessions, isEmpty);
      expect(hub.lastError, isNotNull);
    });

    test('shutdown closes the transport', () async {
      await hub.shutdown();
      expect(t.closed, isTrue);
    });

    test('a watch event without req updates the list and does not answer a pending request', () async {
      var done = false;
      final f = hub.terms('A').then((l) {
        done = true;
        return l;
      });
      final req = t.sent.last['req'];
      expect(t.sent.last, {'cmd': 'terms', 'id': 'A', 'req': anything});
      t.emit({
        'event': 'terms',
        'id': 'B',
        'terms': [
          {'id': 'term:tmux:w', 'host': null, 'name': 'w', 'command': 'vim', 'panes': 2, 'attached': 1, 'activity': 100,
           'dead': false, 'unread': true},
        ],
        'hosts': [
          {'host': null},
          {'host': 'gpu1', 'target': 'me@gpu1', 'tmux': '/x/tmux', 'error': 'refused'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      final b = hub.termLists['B']!;
      expect(b.terms.single.panes, 2);
      expect((b.terms.single.unread, b.terms.single.dead, b.terms.single.activity), (true, false, 100));
      expect((b.hosts[0].host, b.hosts[1].host, b.hosts[1].target, b.hosts[1].error), (null, 'gpu1', 'me@gpu1', 'refused'));
      expect(done, isFalse);
      t.emit({'event': 'terms', 'id': 'A', 'path': 'lan', 'terms': [], 'hosts': [], 'req': req});
      final a = await f;
      expect(done, isTrue);
      expect((a.id, a.path), ('A', 'lan'));
      expect(a.terms, isEmpty);
      expect(hub.termLists['A']!.path, 'lan');
    });

    test('off and error lists parse', () async {
      t.emit({'event': 'terms', 'id': 'A', 'off': true});
      t.emit({'event': 'terms', 'id': 'B', 'error': 'timed out'});
      await Future<void>.delayed(Duration.zero);
      expect(hub.termLists['A']!.off, isTrue);
      expect(hub.termLists['A']!.terms, isEmpty);
      expect((hub.termLists['B']!.off, hub.termLists['B']!.error), (false, 'timed out'));
      final f = hub.terms('A');
      t.emit({'event': 'terms', 'id': 'A', 'off': true, 'req': t.sent.last['req']});
      expect((await f).off, isTrue);
    });

    test('term targets are asked with the optional tmux path left out', () async {
      final f = hub.addTermTarget('A', 'gpu1', 'me@gpu1');
      expect(t.sent.last, {'cmd': 'add_term_target', 'id': 'A', 'name': 'gpu1', 'target': 'me@gpu1', 'req': anything});
      t.emit({'event': 'term_targets', 'id': 'A', 'targets': [], 'req': t.sent.last['req']});
      await f;
      final g = hub.addTermTarget('A', 'gpu1', 'me@gpu1', tmux: '/x/tmux');
      expect(t.sent.last['tmux'], '/x/tmux');
      t.emit({'event': 'error', 'error': 'bad target', 'req': t.sent.last['req']});
      await expectLater(g, throwsA(isA<HubException>()));
      final h = hub.removeTermTarget('A', 'gpu1');
      expect(t.sent.last, {'cmd': 'remove_term_target', 'id': 'A', 'name': 'gpu1', 'req': anything});
      t.emit({'event': 'term_targets', 'id': 'A', 'targets': [], 'req': t.sent.last['req']});
      await h;
    });

    test('newTerm leaves null host and name out and answers the term id', () async {
      final f = hub.newTerm('A', command: ['claude --resume'], cols: 100, rows: 30);
      expect(t.sent.last, {'cmd': 'new_term', 'id': 'A', 'command': ['claude --resume'], 'cols': 100, 'rows': 30, 'req': anything});
      t.emit({'event': 'term_created', 'id': 'A', 'term': 'term:tmux:%1', 'req': t.sent.last['req']});
      expect(await f, 'term:tmux:%1');
      final g = hub.newTerm('A', host: 'gpu1', name: 'x', command: [], cols: 1, rows: 2);
      expect((t.sent.last['host'], t.sent.last['name']), ('gpu1', 'x'));
      expect(t.sent.last['command'], isEmpty);
      t.emit({'event': 'error', 'error': 'no tmux', 'req': t.sent.last['req']});
      await expectLater(g, throwsA(isA<HubException>()));
    });
  });
}
