import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/labels.dart';
import 'package:rapp/service_client.dart';

/// A tiny fake of rapp-service's IPC (§3), bound to an ephemeral port.
class FakeService {
  FakeService(this.token);
  final String token;
  late ServerSocket server;
  final received = <Map<String, dynamic>>[];

  /// The labels table it keeps (app → {title, note}); null: an older service that does not know labels.
  Map<String, Map<String, String>>? labels = {};
  var labelsRev = 0;
  final firstLines = <Map<String, dynamic>>[];
  final _subscribers = <Socket>[];
  final _all = <Socket>[];
  int sessions = 0;
  Map<String, dynamic> extraStatus = {};
  List<String> lanIds = [];
  Map<String, dynamic> perms = {'screen_recording': true, 'accessibility': false};
  List<Map<String, dynamic>> history = [];

  /// The status's `update` object and `permissions_lost_after_update` (absent when null).
  Map<String, dynamic>? update;
  bool? lostAfterUpdate;

  /// Replies to the update and reset commands, by `cmd`; `{"ok":true}` when not set.
  final replies = <String, Map<String, dynamic>>{};

  /// How long a command carrying `to` is held before its reply.
  Duration? holdRemote;

  /// What `watch_load` writes, line by line, keeping the connection open; null: `unknown cmd` and close, as an old
  /// service does.
  List<Map<String, dynamic>>? loadLines;

  /// What each `term_watch` writes: the nth watch gets the nth batch (the last batch again after that). A batch
  /// whose last line is not `ok` closes the connection after it, as the service does; null: `unknown cmd`.
  List<List<Map<String, dynamic>>>? termWatches;
  var _termWatchN = 0;

  int get port => server.port;

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  void _handle(Socket s) {
    _all.add(s);
    var authed = false;
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final m = jsonDecode(line) as Map<String, dynamic>;
      if (!authed) {
        firstLines.add(m);
        if (m['token'] != token) {
          s.destroy();
          return;
        }
        authed = true;
        return;
      }
      received.add(m);
      switch (m['cmd']) {
        case 'status':
          s.write('${jsonEncode(statusJson())}\n');
        case 'subscribe':
          _subscribers.add(s);
          s.write('{"ok":true}\n');
        case 'show_key':
          s.write('${jsonEncode(replies['show_key'] ?? {'ok': true, 'key': 'KEY-TEXT-123'})}\n');
        case 'set_relay':
          s.write('${jsonEncode(replies['set_relay'] ?? {'ok': true})}\n');
        case 'set_password':
        case 'kick':
          s.write('{"ok":true}\n');
        case 'history':
          s.write('${jsonEncode({'ok': true, 'events': history})}\n');
        case 'permissions':
          s.write('${jsonEncode({'ok': true, 'permissions': perms})}\n');
        case 'update_check' ||
              'update_apply' ||
              'update_dismiss' ||
              'update_rollback' ||
              'set_update' ||
              'set_auto_lock' ||
              'set_no_lock' ||
              'gui_windows' ||
              'state' ||
              'permissions_reset':
          s.write('${jsonEncode(replies[m['cmd']] ?? {'ok': true})}\n');
        case 'shares' || 'share' || 'unshare':
          final reply = '${jsonEncode(replies[m['cmd']] ?? {'ok': true, 'shares': [], 'known': []})}\n';
          if (holdRemote != null && m['to'] != null) {
            Future<void>.delayed(holdRemote!, () => s.write(reply));
          } else {
            s.write(reply);
          }
        case 'watch_load' when loadLines != null:
          for (final l in loadLines!) {
            s.write('${jsonEncode(l)}\n');
          }
        case 'watch_load':
          s.write('{"ok":false,"error":"unknown cmd"}\n');
          s.destroy();
        case 'term_watch' when termWatches != null:
          final all = termWatches!;
          final batch = all[_termWatchN < all.length ? _termWatchN : all.length - 1];
          _termWatchN++;
          for (final l in batch) {
            s.write('${jsonEncode(l)}\n');
          }
          if (batch.isNotEmpty && batch.last['ok'] != true) s.destroy();
        case 'term_watch':
          s.write('{"ok":false,"error":"unknown cmd"}\n');
          s.destroy();
        case 'term_open' || 'term_front':
          s.write('${jsonEncode(replies[m['cmd']] ?? {'ok': true, if (m['cmd'] == 'term_open') 'id': 'term:pty:n'})}\n');
        case 'labels' || 'set_label' || 'reset_label' when labels != null:
          final l = labels!;
          if (m['cmd'] == 'set_label') {
            l[m['app'] as String] = {'title': m['title'] as String, 'note': m['note'] as String};
            labelsRev++;
          } else if (m['cmd'] == 'reset_label' && l.remove(m['app']) != null) {
            labelsRev++;
          }
          s.write('${jsonEncode({'ok': true, 'rev': labelsRev, if (m['cmd'] == 'labels') 'labels': l})}\n');
        default:
          s.write('{"ok":false,"error":"unknown cmd"}\n');
      }
    }, onError: (_) {}, onDone: () {});
  }

  Map<String, dynamic> statusJson() => {
        'ok': true,
        'id': '123456789',
        'name': 'bruce-mac',
        'password': 'ab12cd34',
        ...extraStatus,
        'lan_ids': lanIds,
        'log_dir': '/Users/u/Library/Logs/rapp',
        'permissions': perms,
        'update': ?update,
        'permissions_lost_after_update': ?lostAfterUpdate,
        'sessions': [
          for (var i = 0; i < sessions; i++)
            {'sid': i + 1, 'peer': '10.0.0.$i:5000', 'app': 'com.apple.Safari', 'path': 'lan', 'since': 1700000000},
        ],
      };

  void pushChanged() {
    for (final s in _subscribers) {
      s.write('{"event":"changed"}\n');
    }
  }

  /// Drops every connection and keeps listening, as a service restarting on the same port would.
  void dropAll() {
    for (final s in _all) {
      s.destroy();
    }
    _all.clear();
    _subscribers.clear();
  }

  Future<void> stop() async {
    for (final s in _all) {
      s.destroy();
    }
    await server.close();
  }
}

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('ServiceStatus parses the §3 status reply', () {
    final s = ServiceStatus.fromJson({
      'ok': true,
      'id': '123456789',
      'name': 'n',
      'password': 'p',
      'permissions': {'screen_recording': false, 'accessibility': true},
      'sessions': [
        {'sid': 3, 'peer': '1.2.3.4:5', 'app': 'com.apple.Safari', 'path': 'lan', 'since': 17},
      ],
    });
    expect(s.id, '123456789');
    expect(s.screenRecording, isFalse);
    expect(s.accessibility, isTrue);
    expect(s.sessions.single.sid, 3);
    expect(s.sessions.single.peer, '1.2.3.4:5');
    expect(s.sessions.single.path, 'lan');
    // An old service sends neither field.
    expect(s.sessions.single.name, isNull);
    expect(s.sessions.single.side, isFalse);
  });

  test('a session carries the name the peer declared and whether it is a side connection', () {
    final s = ServiceStatus.fromJson({
      'ok': true,
      'sessions': [
        {'sid': 4, 'peer': 'dev1', 'name': 'iPad', 'app': 'a', 'path': 'relay', 'since': 1, 'side': true},
        {'sid': 5, 'peer': 'dev1', 'name': null, 'app': 'a', 'path': 'relay', 'since': 1, 'side': false},
      ],
    });
    expect(s.sessions[0].name, 'iPad');
    expect(s.sessions[0].side, isTrue);
    expect(s.sessions[1].name, isNull);
    expect(s.sessions[1].side, isFalse);
  });

  test('the ID is shown as id@ip, one per address', () {
    final lan = ['123456789@192.168.1.5', '123456789@100.64.0.7'];
    final off = ServiceStatus.fromJson({'ok': true, 'id': '123456789', 'lan_ids': lan});
    expect(off.lanIds, lan);
    expect(off.shownIds, lan);
    // with a relay set the bare ID comes first
    final withRelay = ServiceStatus.fromJson(
        {'ok': true, 'id': '123456789', 'relay_addr': 'vps:22026', 'has_key': true, 'lan_ids': lan});
    expect(withRelay.shownIds, ['123456789', ...lan]);
    // an address without a usable key is no relay
    final noKey =
        ServiceStatus.fromJson({'ok': true, 'id': '123456789', 'relay_addr': 'vps:22026', 'lan_ids': lan});
    expect(noKey.shownIds, lan);
    final noNet = ServiceStatus.fromJson({'ok': true, 'id': '123456789', 'lan_ids': []});
    expect(noNet.shownIds, ['123456789']);
  });

  test('fromJson reads the relay fields', () {
    final s = ServiceStatus.fromJson({
      'ok': true,
      'relay_addr': 'vps:22026',
      'has_key': true,
      'relay': 'error',
      'relay_error': 'bad key',
      'fp': 'abcd',
    });
    expect(s.relayAddr, 'vps:22026');
    expect(s.hasKey, isTrue);
    expect(s.relay, 'error');
    expect(s.relayError, 'bad key');
    expect(s.fp, 'abcd');
  });

  test('the relay is set only with both an address and a key', () {
    ServiceStatus st(Map<String, dynamic> m) => ServiceStatus.fromJson({'ok': true, ...m});
    expect(st({'relay_addr': 'vps:22026', 'has_key': true}).relaySet, isTrue);
    expect(st({'relay_addr': 'vps:22026', 'has_key': false}).relaySet, isFalse);
    expect(st({'has_key': true}).relaySet, isFalse);
    expect(st({}).relaySet, isFalse);
  });

  test('missing relay fields default to off', () {
    final s = ServiceStatus.fromJson({'ok': true, 'id': '1', 'relay_addr': ''});
    expect(s.relayAddr, isNull);
    expect(s.relay, 'off');
    expect(s.hasKey, isFalse);
    expect(s.relayError, isNull);
    expect(s.fp, isNull);
  });

  test('ServiceStatus tolerates a null id and missing optional fields', () {
    final s = ServiceStatus.fromJson({'ok': true, 'id': null, 'sessions': []});
    expect(s.id, isNull);
    expect(s.sessions, isEmpty);
    expect(s.screenRecording, isFalse);
  });

  group('ServiceConnection', () {
    late FakeService svc;
    setUp(() async {
      svc = FakeService('tok-1');
      await svc.start();
    });
    tearDown(() => svc.stop());

    test('sends the token line first, then commands', () async {
      final c = await ServiceConnection.connect(token: 'tok-1', port: svc.port);
      final st = await c.status();
      expect(svc.firstLines.single, {'token': 'tok-1'});
      expect(st.name, 'bruce-mac');
      expect(st.password, 'ab12cd34');
      expect(st.screenRecording, isTrue);

      await c.setPassword('newpw');
      await c.kick(5);
      expect(svc.received.map((m) => m['cmd']), ['status', 'set_password', 'kick']);
      expect(svc.received[1]['password'], 'newpw');
      expect(svc.received[2], {'cmd': 'kick', 'sid': 5});
      await c.close();
    });

    test('history asks for a limit and returns the events; status carries log_dir', () async {
      svc.history = [
        {'ev': 'auth_fail', 'peer': 'p'},
      ];
      final c = await ServiceConnection.connect(token: 'tok-1', port: svc.port);
      expect((await c.status()).logDir, '/Users/u/Library/Logs/rapp');
      expect(await c.history(limit: 7), svc.history);
      expect(svc.received.last, {'cmd': 'history', 'limit': 7});
      await c.close();
    });

    test('stateUrl reads url from the state reply', () async {
      final m = ServiceMonitor(readToken: () async => 'tok-1', port: svc.port, retry: const Duration(milliseconds: 20))..start();
      addTearDown(m.dispose);
      for (var i = 0; i < 100 && !m.running; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      svc.replies['state'] = {'ok': true, 'url': 'http://localhost:28003'};
      expect(await m.stateUrl(), 'http://localhost:28003');
      svc.replies['state'] = {'ok': true, 'url': null};
      expect(await m.stateUrl(), isNull);
      svc.replies['state'] = {'ok': false, 'error': 'no'};
      expect(await m.stateUrl(), isNull);
    });

    test('a wrong token makes requests fail instead of hanging', () async {
      final c = await ServiceConnection.connect(token: 'wrong', port: svc.port);
      await expectLater(c.status(), throwsA(isA<ServiceException>()));
      await c.close();
    });

    test('status parses update and lost flag', () async {
      svc.update = {'current': '0.4.1', 'state': 'ready', 'latest': '0.5.0', 'needs_confirm': true, 'can_rollback': true};
      svc.lostAfterUpdate = true;
      final c = await ServiceConnection.connect(token: 'tok-1', port: svc.port);
      final st = await c.status();
      expect(st.permissionsLostAfterUpdate, isTrue);
      expect(st.update!.current, '0.4.1');
      expect(st.update!.state, 'ready');
      expect(st.update!.latest, '0.5.0');
      expect(st.update!.needsConfirm, isTrue);
      expect(st.update!.canRollback, isTrue);
      await c.close();
    });

    test('an older status without update has update == null', () async {
      final c = await ServiceConnection.connect(token: 'tok-1', port: svc.port);
      final st = await c.status();
      expect(st.update, isNull);
      expect(st.permissionsLostAfterUpdate, isFalse);
      await c.close();
    });

    test('update commands send the right json', () async {
      svc.replies['permissions_reset'] = {'ok': true, 'screen_recording_reset': true, 'accessibility_reset': false};
      final c = await ServiceConnection.connect(token: 'tok-1', port: svc.port);
      await c.updateCheck();
      await c.updateApply();
      await c.updateApply(confirm: true);
      await c.updateDismiss('0.5.0');
      await c.updateRollback();
      await c.setUpdate(autoUpdate: false);
      await c.setUpdate(checkUpdates: true);
      final reset = await c.permissionsReset();
      expect(svc.received, [
        {'cmd': 'update_check'},
        {'cmd': 'update_apply', 'confirm_signature_change': false},
        {'cmd': 'update_apply', 'confirm_signature_change': true},
        {'cmd': 'update_dismiss', 'version': '0.5.0'},
        {'cmd': 'update_rollback'},
        {'cmd': 'set_update', 'auto_update': false},
        {'cmd': 'set_update', 'check_updates': true},
        {'cmd': 'permissions_reset'},
      ]);
      expect(reset['accessibility_reset'], isFalse);
      await c.close();
    });

    test('an update error keeps its page', () async {
      svc.replies['update_apply'] = {'ok': false, 'error': '这次需要管理员密码', 'page': 'https://example.invalid/tag'};
      final c = await ServiceConnection.connect(token: 'tok-1', port: svc.port);
      await expectLater(
          c.updateApply(),
          throwsA(isA<ServiceException>()
              .having((e) => e.message, 'message', '这次需要管理员密码')
              .having((e) => e.page, 'page', 'https://example.invalid/tag')));
      await c.close();
    });

    test('ok:false replies throw ServiceException with the error text', () async {
      final c = await ServiceConnection.connect(token: 'tok-1', port: svc.port);
      await expectLater(
          c.request({'cmd': 'nope'}),
          throwsA(isA<ServiceException>().having((e) => e.message, 'message', 'unknown cmd')));
      await c.close();
    });
  });

  group('ServiceMonitor', () {
    test('checkPermissions asks the service and refreshes the status', () async {
      final svc = FakeService('tok-3');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-3', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      expect(m.status!.accessibility, isFalse);

      svc.perms = {'screen_recording': true, 'accessibility': true};
      await m.checkPermissions(prompt: true);
      expect(svc.received.where((r) => r['cmd'] == 'permissions').single, {'cmd': 'permissions', 'prompt': true});
      expect(m.status!.accessibility, isTrue);
      await m.checkPermissions();
      expect(svc.received.where((r) => r['cmd'] == 'permissions').last, {'cmd': 'permissions', 'prompt': false});

      await svc.stop();
      m.dispose();
    });

    test('auto_lock defaults to true and setAutoLock sends the right json', () async {
      expect(ServiceStatus.fromJson({'id': '1'}).autoLock, isTrue);
      expect(ServiceStatus.fromJson({'id': '1', 'auto_lock': false}).autoLock, isFalse);
      final svc = FakeService('tok-al');
      await svc.start();
      final c = await ServiceConnection.connect(token: 'tok-al', port: svc.port);
      await c.setAutoLock(false);
      expect(svc.received, [
        {'cmd': 'set_auto_lock', 'on': false},
      ]);
      await c.close();
      await svc.stop();
    });

    test('status_reads_no_lock and setNoLock sends set_no_lock', () async {
      expect(ServiceStatus.fromJson({'id': '1'}).noLock, isFalse);
      final st = ServiceStatus.fromJson({'id': '1', 'no_lock': true, 'no_lock_held': true});
      expect(st.noLock, isTrue);
      expect(st.noLockHeld, isTrue);
      final svc = FakeService('tok-nl');
      await svc.start();
      final c = await ServiceConnection.connect(token: 'tok-nl', port: svc.port);
      await c.setNoLock(true);
      expect(svc.received, [
        {'cmd': 'set_no_lock', 'on': true},
      ]);
      await c.close();
      await svc.stop();
    });

    test('labels: read on connect, changed by setLabel / resetLabel, none from an older service', () async {
      final svc = FakeService('tok-lb')..labels = {'term:pty:k': {'title': '后端', 'note': ''}};
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-lb', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.labels != null);
      expect(m.labels!.labels['term:pty:k'], const SessionLabel(title: '后端'));
      await m.setLabel('com.apple.Safari', title: '', note: '查文档');
      expect(svc.received.where((r) => r['cmd'] == 'set_label').last,
          {'cmd': 'set_label', 'app': 'com.apple.Safari', 'title': '', 'note': '查文档'});
      expect(m.labels!.labels['com.apple.Safari'], const SessionLabel(note: '查文档'));
      await m.resetLabel('term:pty:k');
      expect(m.labels!.labels.containsKey('term:pty:k'), isFalse);
      expect(m.labels!.rev, 2);
      await svc.stop();
      m.dispose();

      final old = FakeService('tok-lb2')..labels = null;
      await old.start();
      final m2 = ServiceMonitor(readToken: () async => 'tok-lb2', port: old.port, retry: const Duration(milliseconds: 50));
      m2.start();
      await until(() => m2.status != null);
      expect((m2.labels, m2.labelsUnsupported), (null, true));
      await m2.refresh();
      expect(old.received.where((r) => r['cmd'] == 'labels'), hasLength(1));
      // Upgraded in place: the restarted service knows labels, and the monitor asks it again.
      old.labels = {'a': {'title': '新', 'note': ''}};
      old.dropAll();
      await until(() => m2.labels != null);
      expect((m2.labels!.labels['a'], m2.labelsUnsupported), (const SessionLabel(title: '新'), false));
      await old.stop();
      m2.dispose();
    });

    test('update wrappers ask the service and refresh the status', () async {
      final svc = FakeService('tok-4');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-4', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      svc.update = {'current': '0.4.1', 'state': 'idle', 'auto_update': false};
      await m.setUpdate(autoUpdate: false);
      expect(m.status!.update!.autoUpdate, isFalse);
      await m.updateCheck();
      await m.updateApply(confirm: true);
      await m.updateDismiss('0.5.0');
      await m.updateRollback();
      await m.permissionsReset();
      expect(svc.received.map((r) => r['cmd']).where((c) => c != 'status' && c != 'subscribe' && c != 'labels' && c != 'watch_load' && c != 'term_watch'),
          ['set_update', 'update_check', 'update_apply', 'update_dismiss', 'update_rollback', 'permissions_reset']);
      await svc.stop();
      m.dispose();
    });

    test('watch_load fills load from its own connection, and follows each line', () async {
      final svc = FakeService('tok-wl')
        ..loadLines = [
          {'ok': true, 'at': 10, 'headroom': 80, 'tightest': 'cpu', 'term': true, 'items': {}, 'disks': [], 'warnings': [],
           'history': [{'at': 10, 'cpu': 20.0}]},
          {'ok': true, 'at': 15, 'headroom': 75, 'tightest': 'cpu', 'term': true, 'items': {}, 'disks': [], 'warnings': [],
           'point': {'at': 15, 'cpu': 25.0}},
        ];
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-wl', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.load?.at == 15);
      expect((m.load!.headroom, m.load!.history.length), (75, 2));
      expect(svc.received.where((r) => r['cmd'] == 'watch_load').single, {'cmd': 'watch_load'});
      // The service restarts: the load is dropped with the rest and asked for again.
      svc.dropAll();
      await until(() => !m.running);
      expect(m.load, isNull);
      await until(() => m.load != null);
      expect(svc.received.where((r) => r['cmd'] == 'watch_load').length, 2);
      await svc.stop();
      m.dispose();
    });

    test('an old service that does not know watch_load: no load, and it is not asked again until a reconnect', () async {
      final svc = FakeService('tok-old');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-old', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      await until(() => svc.received.any((r) => r['cmd'] == 'watch_load'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(m.load, isNull);
      expect(m.running, isTrue);
      expect(svc.received.where((r) => r['cmd'] == 'watch_load').length, 1);
      await svc.stop();
      m.dispose();
    });

    Map<String, dynamic> terms(List<String> ids) => {
          'ok': true,
          'terms': [for (final id in ids) {'id': id, 'name': id.substring(9), 'command': 'zsh', 'host': null}],
          'hosts': [
            {'host': null, 'launchers': ['Terminal']},
          ],
        };
    int termWatches(FakeService svc) => svc.received.where((r) => r['cmd'] == 'term_watch').length;

    test('term_watch fills localTerms from its own connection and follows each line', () async {
      final svc = FakeService('tok-tw')
        ..termWatches = [
          [terms(['term:pty:a']), terms(['term:pty:a', 'term:pty:b'])],
        ];
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-tw', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.localTerms?.terms.length == 2);
      expect(m.localTerms!.terms.map((r) => r.id), ['term:pty:a', 'term:pty:b']);
      expect(m.localTerms!.hosts.single.launchers, ['Terminal']);
      expect(svc.received.where((r) => r['cmd'] == 'term_watch').single, {'cmd': 'term_watch'});
      // The service restarts: the list goes with the rest and is asked for again.
      svc.dropAll();
      await until(() => !m.running);
      expect(m.localTerms, isNull);
      await until(() => m.localTerms != null);
      expect(termWatches(svc), 2);
      await svc.stop();
      m.dispose();
    });

    test('a term_watch that ends with an error clears localTerms and is opened again on changed', () async {
      final svc = FakeService('tok-te')
        ..termWatches = [
          [terms(['term:pty:a']), {'ok': false, 'error': 'terminal sessions are off'}],
          [terms(['term:pty:c'])],
        ];
      await svc.start();
      final m = ServiceMonitor(
          readToken: () async => 'tok-te', port: svc.port, retry: const Duration(milliseconds: 50), rewatchGap: Duration.zero);
      m.start();
      await until(() => termWatches(svc) == 1 && m.localTerms == null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(m.localTerms, isNull);
      svc.pushChanged();
      await until(() => m.localTerms?.terms.single.id == 'term:pty:c');
      expect(termWatches(svc), 2);
      // Watching again: a changed asks nothing more.
      svc.pushChanged();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(termWatches(svc), 2);
      await svc.stop();
      m.dispose();
    });

    test('after an ended term_watch, changed events within the gap ask once', () async {
      final svc = FakeService('tok-tg')
        ..termWatches = [
          [{'ok': false, 'error': 'terminal sessions are off'}],
        ];
      await svc.start();
      final m = ServiceMonitor(
          readToken: () async => 'tok-tg', port: svc.port, retry: const Duration(milliseconds: 50), rewatchGap: const Duration(hours: 1));
      m.start();
      await until(() => termWatches(svc) == 1);
      svc.pushChanged();
      svc.pushChanged();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(termWatches(svc), 1);
      expect(m.localTerms, isNull);
      await svc.stop();
      m.dispose();
    });

    test('a changed within the gap is not lost: the watch is opened once when the gap is over', () async {
      final svc = FakeService('tok-tl')
        ..termWatches = [
          [{'ok': false, 'error': 'terminal sessions are off'}],
          [terms(['term:pty:on'])],
        ];
      await svc.start();
      final m = ServiceMonitor(
          readToken: () async => 'tok-tl',
          port: svc.port,
          retry: const Duration(milliseconds: 50),
          rewatchGap: const Duration(milliseconds: 400));
      m.start();
      await until(() => termWatches(svc) == 1);
      // Terminals turned on again right away: its changed comes inside the gap, and nothing else follows.
      svc.pushChanged();
      svc.pushChanged();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(termWatches(svc), 1);
      await until(() => m.localTerms?.terms.single.id == 'term:pty:on');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(termWatches(svc), 2);
      await svc.stop();
      m.dispose();
    });

    test("an old service's unknown cmd is not asked again until reconnect", () async {
      final svc = FakeService('tok-to');
      await svc.start();
      final m = ServiceMonitor(
          readToken: () async => 'tok-to', port: svc.port, retry: const Duration(milliseconds: 50), rewatchGap: Duration.zero);
      m.start();
      await until(() => termWatches(svc) == 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      svc.pushChanged();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(termWatches(svc), 1);
      expect(m.localTerms, isNull);
      // A restarted service may be a newer one: asked afresh.
      svc.dropAll();
      await until(() => termWatches(svc) == 2);
      await svc.stop();
      m.dispose();
    });

    test('termOpen and termFront send the right json', () async {
      final svc = FakeService('tok-tf');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-tf', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      expect(await m.termOpen(app: 'Terminal', from: 'last'), 'term:pty:n');
      expect(svc.received.where((r) => r['cmd'] == 'term_open').single, {'cmd': 'term_open', 'app': 'Terminal', 'from': 'last'});
      await m.termFront('term:pty:a');
      expect(svc.received.where((r) => r['cmd'] == 'term_front').single, {'cmd': 'term_front', 'term': 'term:pty:a'});
      svc.replies['term_front'] = {'ok': false, 'error': 'not-found'};
      await expectLater(
          m.termFront('term:pty:a'), throwsA(isA<ServiceException>().having((e) => e.message, 'message', 'not-found')));
      await svc.stop();
      m.dispose();
    });

    test('gui_windows is sent when it changes and again after a reconnect', () async {
      final svc = FakeService('tok-gw');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-gw', port: svc.port, retry: const Duration(milliseconds: 50));
      m.setGuiWindows(1); // before connecting: sent once connected
      m.start();
      await until(() => m.status != null);
      List<Object?> sent() => svc.received.where((r) => r['cmd'] == 'gui_windows').map((r) => r['count']).toList();
      await until(() => sent().length == 1);
      expect(sent(), [1]);
      m.setGuiWindows(2);
      m.setGuiWindows(2);
      await until(() => sent().length == 2);
      expect(sent(), [1, 2]);
      svc.dropAll();
      await until(() => !m.running);
      await until(() => m.running);
      await until(() => sent().length == 3);
      expect(sent(), [1, 2, 2]);
      await svc.stop();
      m.dispose();
    });

    test('a service that does not know gui_windows still connects', () async {
      final svc = FakeService('tok-gw2')..replies['gui_windows'] = {'ok': false, 'error': 'unknown cmd'};
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-gw2', port: svc.port, retry: const Duration(milliseconds: 50));
      m.setGuiWindows(3);
      m.start();
      await until(() => m.status != null);
      expect(m.error, isNull);
      await svc.stop();
      m.dispose();
    });

    test('remote share calls use their own connection', () async {
      final svc = FakeService('tok-r1')..holdRemote = const Duration(seconds: 1);
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-r1', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      var done = false;
      final call = m.shares(to: '123456789').then((_) => done = true);
      await until(() => svc.received.any((r) => r['cmd'] == 'shares'));
      await m.refresh().timeout(const Duration(milliseconds: 500));
      expect(done, isFalse);
      await call;
      expect(done, isTrue);
      await svc.stop();
      m.dispose();
    });

    test('stateService asks state with to', () async {
      final svc = FakeService('tok-ss');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-ss', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      svc.replies['state'] = {'ok': true, 'on': true, 'port': 8102};
      expect(await m.stateService(to: '111111111', on: true), {'ok': true, 'on': true, 'port': 8102});
      expect(svc.received.last, {'cmd': 'state', 'to': '111111111', 'on': true});
      await m.stateService();
      expect(svc.received.last, {'cmd': 'state'});
      await svc.stop();
      m.dispose();
    });

    test('stateHost reads outbox.dest', () async {
      final svc = FakeService('tok-sh');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-sh', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      svc.replies['state'] = {'ok': true, 'outbox': {'dest': {'id': '222222222', 'port': 8102}}};
      expect(await m.stateHost(), '222222222');
      svc.replies['state'] = {'ok': true, 'outbox': {'dest': {'local': 8102}}};
      expect(await m.stateHost(), m.status!.id);
      expect(m.status!.id, isNotNull);
      svc.replies['state'] = {'ok': true, 'outbox': {'dest': null}};
      expect(await m.stateHost(), isNull);
      await svc.stop();
      m.dispose();
    });

    test('share sends to, ports, note and allow; leaves out what is null', () async {
      final svc = FakeService('tok-r2');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-r2', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      await m.share(to: '123456789', ports: [8000]);
      expect(svc.received.last, {'cmd': 'share', 'to': '123456789', 'ports': [8000]});
      await m.share(ports: [22, 80], note: 'n', allow: ['ab']);
      expect(svc.received.last, {'cmd': 'share', 'ports': [22, 80], 'note': 'n', 'allow': ['ab']});
      await m.unshare(port: 8000);
      expect(svc.received.last, {'cmd': 'unshare', 'port': 8000});
      await svc.stop();
      m.dispose();
    });

    test('subscribe → changed triggers a fresh status', () async {
      final svc = FakeService('tok-2');
      await svc.start();
      final m = ServiceMonitor(readToken: () async => 'tok-2', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
      expect(m.running, isTrue);
      expect(m.status!.sessions, isEmpty);
      expect(svc.received.where((r) => r['cmd'] == 'subscribe'), hasLength(1));

      svc.sessions = 2;
      svc.pushChanged();
      await until(() => m.status!.sessions.length == 2);
      expect(svc.received.where((r) => r['cmd'] == 'status').length, greaterThanOrEqualTo(2));

      await svc.stop();
      await until(() => !m.running);
      m.dispose();
    });

    test('missing token file → not running with an error, no crash', () async {
      final m = ServiceMonitor(readToken: () async => null, port: 1, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.error != null);
      expect(m.running, isFalse);
      m.dispose();
    });

    test('nothing listening → not running', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final m = ServiceMonitor(readToken: () async => 't', port: port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.error != null);
      expect(m.running, isFalse);
      m.dispose();
    });
  });
}
