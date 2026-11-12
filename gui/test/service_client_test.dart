import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/service_client.dart';

/// A tiny fake of rapp-service's IPC (§3), bound to an ephemeral port.
class FakeService {
  FakeService(this.token);
  final String token;
  late ServerSocket server;
  final received = <Map<String, dynamic>>[];
  final firstLines = <Map<String, dynamic>>[];
  final _subscribers = <Socket>[];
  final _all = <Socket>[];
  int sessions = 0;
  Map<String, dynamic> perms = {'screen_recording': true, 'accessibility': false};
  List<Map<String, dynamic>> history = [];

  /// The status's `update` object and `permissions_lost_after_update` (absent when null).
  Map<String, dynamic>? update;
  bool? lostAfterUpdate;

  /// Replies to the update and reset commands, by `cmd`; `{"ok":true}` when not set.
  final replies = <String, Map<String, dynamic>>{};

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
        case 'set_password':
        case 'set_relay':
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
              'permissions_reset':
          s.write('${jsonEncode(replies[m['cmd']] ?? {'ok': true})}\n');
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
        'relay': 'connected',
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
      'relay': 'off',
      'relay_error': 'bad relay key',
      'permissions': {'screen_recording': false, 'accessibility': true},
      'sessions': [
        {'sid': 3, 'peer': '1.2.3.4:5', 'app': 'com.apple.Safari', 'path': 'relay', 'since': 17},
      ],
    });
    expect(s.id, '123456789');
    expect(s.relay, 'off');
    expect(s.relayError, 'bad relay key');
    expect(s.screenRecording, isFalse);
    expect(s.accessibility, isTrue);
    expect(s.sessions.single.sid, 3);
    expect(s.sessions.single.peer, '1.2.3.4:5');
    expect(s.sessions.single.path, 'relay');
  });

  test('without a connected relay the ID is shown as id@ip, one per address', () {
    final lan = ['123456789@192.168.1.5', '123456789@100.64.0.7'];
    final off = ServiceStatus.fromJson({'ok': true, 'id': '123456789', 'relay': 'off', 'lan_ids': lan});
    expect(off.lanIds, lan);
    expect(off.shownIds, lan);
    final on = ServiceStatus.fromJson({'ok': true, 'id': '123456789', 'relay': 'connected', 'lan_ids': lan});
    expect(on.shownIds, ['123456789']);
    final noNet = ServiceStatus.fromJson({'ok': true, 'id': '123456789', 'relay': 'off', 'lan_ids': []});
    expect(noNet.shownIds, ['123456789']);
  });

  test('ServiceStatus tolerates a null id and missing optional fields', () {
    final s = ServiceStatus.fromJson({'ok': true, 'id': null, 'relay': 'connecting', 'sessions': []});
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
      expect(st.relay, 'connected');
      expect(st.screenRecording, isTrue);

      await c.setPassword('newpw');
      await c.setRelay('vps:21116', 'K');
      await c.kick(5);
      expect(svc.received.map((m) => m['cmd']), ['status', 'set_password', 'set_relay', 'kick']);
      expect(svc.received[1]['password'], 'newpw');
      expect(svc.received[2], {'cmd': 'set_relay', 'relay': 'vps:21116', 'key': 'K'});
      expect(svc.received[3], {'cmd': 'kick', 'sid': 5});
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
      expect(svc.received.map((r) => r['cmd']).where((c) => c != 'status' && c != 'subscribe'),
          ['set_update', 'update_check', 'update_apply', 'update_dismiss', 'update_rollback', 'permissions_reset']);
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
