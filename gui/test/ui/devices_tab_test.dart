import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/app_profile_page.dart';
import 'package:rapp/ui/devices_tab.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;
  Map<String, dynamic>? appsPermissions;
  String? openError;
  bool offline = false;
  bool holdApps = false;
  String? addTargetError;
  var termsOff = false;
  String? removeTargetError;
  var termHosts = <Map<String, dynamic>>[{'host': null}];

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    appsPermissions = null;
    openError = null;
    offline = false;
    holdApps = false;
    addTargetError = null;
    termsOff = false;
    removeTargetError = null;
    termHosts = [{'host': null}];
    tmp = Directory.systemTemp.createTempSync('devices_tab_test');
    t = FakeTransport();
    hub = HubClient(t);
    final hosts = <Map<String, dynamic>>[
      {'id': '111', 'name': 'mini', 'lan': ['127.0.0.1:22028', '192.168.2.7:22028']},
      {'id': '222', 'name': 'far'},
    ];
    t.onSend = (cmd) {
      final req = cmd['req'];
      switch (cmd['cmd']) {
        case 'hosts':
          t.emit({'event': 'hosts', 'req': req, 'hosts': hosts});
        case 'add_host':
          if (cmd['password'] == 'bad') {
            t.emit({'event': 'error', 'req': req, 'error': 'bad password'});
          } else {
            hosts.add({'id': cmd['id'], 'name': 'new-mac'});
            t.emit({'event': 'host_added', 'req': req, 'id': cmd['id'], 'name': 'new-mac'});
          }
        case 'remove_host':
          hosts.removeWhere((h) => h['id'] == cmd['id']);
          t.emit({'event': 'hosts', 'req': req, 'hosts': hosts});
        case 'apps':
          if (holdApps) return;
          if (offline && cmd['id'] == '111') {
            return t.emit({'event': 'error', 'req': req, 'error': 'connect timed out'});
          }
          t.emit({
            'event': 'apps',
            'req': req,
            'id': cmd['id'],
            'path': 'lan',
            'apps': [
              {'app': 'com.apple.Safari', 'name': 'Safari'},
            ],
            'permissions': ?appsPermissions,
          });
        case 'terms':
          if (termsOff) return t.emit({'event': 'terms', 'req': req, 'id': cmd['id'], 'off': true});
          t.emit({'event': 'terms', 'req': req, 'id': cmd['id'], 'path': 'lan', 'terms': [], 'hosts': termHosts});
        case 'add_term_target':
          if (addTargetError != null) return t.emit({'event': 'error', 'req': req, 'error': addTargetError});
          termHosts.add({'host': cmd['name'], 'target': cmd['target']});
          t.emit({'event': 'term_targets', 'req': req, 'id': cmd['id'], 'targets': []});
        case 'remove_term_target':
          if (removeTargetError != null) return t.emit({'event': 'error', 'req': req, 'error': removeTargetError});
          termHosts.removeWhere((h) => h['host'] == cmd['name']);
          t.emit({'event': 'term_targets', 'req': req, 'id': cmd['id'], 'targets': []});
        case 'set_route':
          for (final h in hosts) {
            if (h['id'] != cmd['id']) continue;
            if (cmd['route'] == 'relay') {
              h['route'] = 'relay';
            } else {
              h.remove('route');
            }
          }
          t.emit({'event': 'hosts', 'req': req, 'hosts': hosts});
        case 'open':
          if (openError != null) return t.emit({'event': 'error', 'req': req, 'error': openError});
          t.emit({'event': 'opened', 'req': req, 'sid': 1, 'id': cmd['id'], 'app': cmd['app'], 'path': 'lan'});
      }
    };
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pumpTab(WidgetTester tester,
      {bool settle = true, bool localBadge = false, Future<void> Function(String host)? screenShare}) async {
    s.togglePanel(PanelTab.devices);
    // MainState's constructor already asked for the hosts, in setUp's real zone.
    await tester.runAsync(() async {
      for (var i = 0; i < 3; i++) {
        await flush();
      }
    });
    await tester.pumpWidget(wrap(SizedBox(
      width: 420,
      height: 900,
      child: DevicesTab(state: s, local: const Text('local-body'), localBadge: localBadge, screenShare: screenShare),
    )));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> selectMini(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('device-111')));
    await tester.pumpAndSettle();
  }

  testWidgets('lists saved devices from the hub on start', (tester) async {
    await pumpTab(tester);
    expect(t.sent.where((m) => m['cmd'] == 'hosts'), isNotEmpty);
    expect(find.byKey(const Key('device-111')), findsOneWidget);
    expect(find.textContaining('mini'), findsWidgets);
  });

  testWidgets('屏幕共享 opens A by its first non-loopback LAN address', (tester) async {
    final opened = <String>[];
    await pumpTab(tester, screenShare: (h) async => opened.add(h));
    await selectMini(tester);
    await tester.tap(find.byKey(const Key('screen-share')));
    await tester.pumpAndSettle();
    expect(opened, ['192.168.2.7']);
  });

  testWidgets('no 屏幕共享 without a known LAN address or without an opener', (tester) async {
    await pumpTab(tester, screenShare: (_) async {});
    await tester.tap(find.byKey(const Key('device-222')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen-share')), findsNothing);
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.byKey(const Key('screen-share')), findsNothing);
  });

  test('screenShareHost picks a reachable host part', () {
    expect(screenShareHost(const ['127.0.0.1:1', '[::1]:2']), isNull);
    expect(screenShareHost(const ['[fd7a::5]:22028']), 'fd7a::5');
    expect(screenShareHost(const ['100.64.0.9:22028']), '100.64.0.9');
    expect(screenShareHost(const []), isNull);
  });

  testWidgets('typed add form text survives switching device chips', (tester) async {
    await pumpTab(tester);
    await tester.enterText(find.byKey(const Key('add-id')), '999');
    await tester.tap(find.byKey(const Key('device-111')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('add-id'))).controller!.text, '999');
    await tester.tap(find.byKey(const Key('device-local')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('add-id'))).controller!.text, '999');
  });

  testWidgets('tapping an offline or the selected chip re-probes', (tester) async {
    offline = true;
    await pumpTab(tester);
    int n() => t.sent.where((m) => m['cmd'] == 'apps').length;
    final before = n();
    await selectMini(tester); // offline: retry
    expect(n(), before + 1);
    offline = false;
    await selectMini(tester); // selected: retry
    expect(n(), before + 2);
    expect(s.probes['111']!.lamp, Lamp.active);
  });

  testWidgets('no second apps while one is pending', (tester) async {
    holdApps = true;
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs()); // asks again, now held
    await pumpTab(tester, settle: false);
    int n() => t.sent.where((m) => m['cmd'] == 'apps').length;
    final first = n();
    expect(first, 4); // setUp's state + the new one, for each of the two devices
    await tester.tap(find.byKey(const Key('device-local')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('device-111')));
    await tester.pump();
    s.probeAll();
    expect(n(), first);
  });

  testWidgets('local chip shows a quiet dot', (tester) async {
    await pumpTab(tester, localBadge: true);
    final chip = find.byKey(const Key('device-local'));
    final dot = find.descendant(of: chip, matching: find.byKey(const Key('update-dot')));
    expect(dot, findsOneWidget);
    final t = RappTokens.of(tester.element(chip));
    final box = tester.widget<Container>(dot).decoration as BoxDecoration;
    expect(box.color, t.muted);
    expect(box.shape, BoxShape.circle);
    expect(tester.getSize(dot), const Size(8, 8));
    expect(find.descendant(of: chip, matching: find.byType(FadeTransition)), findsNothing);
    expect(find.descendant(of: chip, matching: find.byType(AnimatedBuilder)), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.getSemantics(chip).label, contains('本机，有新版本'));

    await pumpTab(tester);
    expect(find.byKey(const Key('update-dot')), findsNothing);
    expect(tester.getSemantics(find.byKey(const Key('device-local'))).label, '本机');
  });

  testWidgets('shows 本机 first and probes every device on start', (tester) async {
    await pumpTab(tester);
    expect(find.text('local-body'), findsOneWidget);
    expect(find.byKey(const Key('device-local')), findsOneWidget);
    expect(t.sent.where((m) => m['cmd'] == 'apps'), isNotEmpty);
    expect(s.probes['111']!.lamp, Lamp.active);
  });

  testWidgets('adds a device and switches to it', (tester) async {
    await pumpTab(tester);
    final before = t.sent.where((m) => m['cmd'] == 'apps').length;
    await tester.enterText(find.byKey(const Key('add-id')), '222');
    await tester.enterText(find.byKey(const Key('add-password')), 'pw');
    await tester.ensureVisible(find.byKey(const Key('add-button')));
    await tester.tap(find.byKey(const Key('add-button')));
    await tester.pumpAndSettle();
    final add = t.sent.firstWhere((m) => m['cmd'] == 'add_host');
    expect(add['id'], '222');
    expect(add['password'], 'pw');
    expect(s.deviceTab, '222');
    expect(t.sent.where((m) => m['cmd'] == 'apps').length, before + 1);
    expect(t.sent.last, containsPair('id', '222'));
    // form cleared
    expect(tester.widget<TextField>(find.byKey(const Key('add-password'))).controller!.text, '');
    expect(tester.widget<TextField>(find.byKey(const Key('add-id'))).controller!.text, '');
  });

  testWidgets('password field is obscured', (tester) async {
    await pumpTab(tester);
    expect(tester.widget<TextField>(find.byKey(const Key('add-password'))).obscureText, isTrue);
  });

  testWidgets('add error is shown inline and nothing switches', (tester) async {
    await pumpTab(tester);
    await tester.enterText(find.byKey(const Key('add-id')), '333');
    await tester.enterText(find.byKey(const Key('add-password')), 'bad');
    await tester.ensureVisible(find.byKey(const Key('add-button')));
    await tester.tap(find.byKey(const Key('add-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('密码不对'), findsOneWidget);
    expect(s.deviceTab, isNull);
  });

  testWidgets('app rows show 打开 / 切到 by session state', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.byKey(const Key('app-com.apple.Safari')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('open-com.apple.Safari')), matching: find.text('打开')),
        findsOneWidget);
    t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'com.apple.Safari', 'path': 'lan'});
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('open-com.apple.Safari')), matching: find.text('切到')),
        findsOneWidget);
  });

  testWidgets('a connecting session disables 打开', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    t.onSend = null; // open never answers
    s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
    s.togglePanel(PanelTab.devices);
    await tester.pump();
    final b = find.descendant(of: find.byKey(const Key('open-com.apple.Safari')), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(b).onPressed, isNull);
  });

  testWidgets('tapping 打开 opens and closes the panel', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await tester.tap(find.byKey(const Key('open-com.apple.Safari')));
    await tester.pumpAndSettle();
    final open = t.sent.lastWhere((m) => m['cmd'] == 'open');
    expect(open['id'], '111');
    expect(open['app'], 'com.apple.Safari');
    expect(s.panel, isNull);
  });

  testWidgets('bundle id field opens any app', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await tester.enterText(find.byKey(const Key('bundle-id')), 'com.apple.TextEdit');
    await tester.ensureVisible(find.byKey(const Key('open-bundle')));
    await tester.tap(find.byKey(const Key('open-bundle')));
    await tester.pumpAndSettle();
    expect(t.sent.lastWhere((m) => m['cmd'] == 'open'), containsPair('app', 'com.apple.TextEdit'));
  });

  testWidgets('remove device needs two taps; selected device falls back to 本机 and its sessions stay',
      (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'com.apple.Safari', 'path': 'lan'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-device')));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'remove_host'), isEmpty);
    await tester.tap(find.byKey(const Key('remove-device')));
    await tester.pumpAndSettle();
    expect(t.sent.where((m) => m['cmd'] == 'remove_host'), hasLength(1));
    expect(s.deviceTab, isNull);
    expect(find.text('local-body'), findsOneWidget);
    expect(s.sessionCount, 1);
  });

  testWidgets('armed remove button does not carry over to another device', (tester) async {
    await pumpTab(tester);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
        {'id': '222', 'name': 'studio'},
      ],
    });
    await tester.pumpAndSettle();
    await selectMini(tester);
    await tester.tap(find.byKey(const Key('remove-device')));
    await tester.pump();
    expect(find.text('再点一次确认'), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-222')));
    await tester.pumpAndSettle();
    expect(find.text('再点一次确认'), findsNothing);
    await tester.tap(find.byKey(const Key('remove-device')));
    await tester.pumpAndSettle();
    expect(t.sent.where((m) => m['cmd'] == 'remove_host'), isEmpty);
  });

  testWidgets('offline device shows 离线 and the error in plain words', (tester) async {
    offline = true;
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.text('离线'), findsWidgets);
    expect(find.text('连接超时'), findsOneWidget);
    expect(find.textContaining('connect timed out'), findsNothing);
  });

  testWidgets('route toggle shows only with a relay', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.byKey(const Key('route-toggle')), findsNothing);
    s.setRelaySet(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('route-toggle')), findsOneWidget);
    expect(find.text('强制走中继'), findsOneWidget);
    await tester.tap(find.byKey(const Key('route-toggle')));
    await tester.pumpAndSettle();
    expect(t.sent.where((m) => m['cmd'] == 'set_route').last, {'cmd': 'set_route', 'id': '111', 'route': 'relay', 'req': anything});
    expect(find.text('恢复自动'), findsOneWidget);
    expect(find.text('强制走中继'), findsNothing);
    await tester.tap(find.byKey(const Key('route-toggle')));
    await tester.pumpAndSettle();
    expect(t.sent.where((m) => m['cmd'] == 'set_route').last['route'], 'auto');
    expect(find.text('强制走中继'), findsOneWidget);
  });

  testWidgets('route toggle is disabled once the hub is gone', (tester) async {
    s.setRelaySet(true);
    await pumpTab(tester);
    await selectMini(tester);
    await t.die();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('route-toggle')));
    await tester.pumpAndSettle();
    expect(t.sent.where((m) => m['cmd'] == 'set_route'), isEmpty);
  });

  testWidgets('device row path follows path events', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.text('局域网'), findsOneWidget);
    t.emit({'event': 'path', 'id': '111', 'path': 'relay'});
    await tester.pumpAndSettle();
    expect(find.text('局域网'), findsNothing);
    expect(find.text('中继'), findsOneWidget);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini', 'route': 'relay'},
        {'id': '222', 'name': 'far'},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('中继（强制）'), findsOneWidget);
  });

  testWidgets('offline from presence shows the relay error', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    t.emit({'event': 'presence', 'id': '111', 'online': false, 'error': 'relay unreachable: timed out'});
    await tester.pumpAndSettle();
    expect(find.text('离线'), findsWidgets);
    expect(find.text('中继连不上'), findsOneWidget);
    expect(find.textContaining('relay unreachable'), findsNothing);
  });

  testWidgets('missing permissions on a remote host show the remote hint', (tester) async {
    appsPermissions = {'screen_recording': false, 'accessibility': true};
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.text('「mini」缺少 屏幕录制 权限。请在那台电脑上打开 rapp，在 本机 › 权限 里点「打开系统设置」。'),
        findsOneWidget);
  });

  testWidgets('no hint when every permission is granted', (tester) async {
    appsPermissions = {'screen_recording': true, 'accessibility': true};
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.textContaining('缺少'), findsNothing);
  });

  testWidgets('an open that fails for permissions explains it in Chinese', (tester) async {
    openError = 'rapp-host exited: missing permission: Accessibility\nAllow rapp under System Settings.';
    await pumpTab(tester);
    await selectMini(tester);
    await tester.tap(find.byKey(const Key('open-com.apple.Safari')));
    await tester.pumpAndSettle();
    expect(s.hint, '「mini」缺少 辅助功能 权限。请在那台电脑上打开 rapp，在 本机 › 权限 里点「打开系统设置」。');
  });

  testWidgets('app row is 68 tall', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    expect(tester.getSize(find.byKey(const Key('app-com.apple.Safari'))).height, 68);
  });

  testWidgets('empty app list says so', (tester) async {
    t.onSend = (cmd) {
      if (cmd['cmd'] == 'apps') {
        t.emit({'event': 'apps', 'req': cmd['req'], 'id': cmd['id'], 'path': 'lan', 'apps': []});
      }
    };
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.text('对方没有可共享的窗口'), findsOneWidget);
  });

  testWidgets('app row label carries the state word', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.bySemanticsLabel(RegExp('Safari.*未打开')), findsWidgets);
  });

  testWidgets('hub gone: open and add are disabled, no crash', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await t.die();
    await tester.runAsync(flush);
    await tester.pumpAndSettle();
    expect(s.hubUsable, isFalse);
    final b = find.descendant(of: find.byKey(const Key('open-com.apple.Safari')), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(b).onPressed, isNull);
    await tester.ensureVisible(find.byKey(const Key('add-button')));
    final add = tester.widget<FilledButton>(
        find.descendant(of: find.byKey(const Key('add-button')), matching: find.byType(FilledButton)));
    expect(add.onPressed, isNull);
    await tester.tap(find.byKey(const Key('add-button')), warnIfMissed: false);
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'add_host'), isEmpty);
  });

  testWidgets('设为常用 toggles and the label follows', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    const app = 'com.apple.Safari';
    final fav = find.byKey(const Key('fav-$app'));
    expect(find.descendant(of: fav, matching: find.text('设为常用')), findsOneWidget);
    await tester.tap(fav);
    await tester.pumpAndSettle();
    expect(s.isFavorite('111', app), isTrue);
    expect(find.descendant(of: fav, matching: find.text('取消常用')), findsOneWidget);
    await tester.tap(fav);
    await tester.pumpAndSettle();
    expect(s.isFavorite('111', app), isFalse);
    expect(find.descendant(of: fav, matching: find.text('设为常用')), findsOneWidget);
  });

  testWidgets('设为常用 works without the hub', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await t.die();
    await tester.runAsync(flush);
    await tester.pumpAndSettle();
    expect(s.hubUsable, isFalse);
    await tester.tap(find.byKey(const Key('fav-com.apple.Safari')));
    await tester.pumpAndSettle();
    expect(s.isFavorite('111', 'com.apple.Safari'), isTrue);
  });

  testWidgets('fav button is at least 48 tall', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    expect(tester.getSize(find.byKey(const Key('fav-com.apple.Safari'))).height, greaterThanOrEqualTo(48));
  });

  testWidgets('⋯ on an app row opens its app 配置 page', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await tester.tap(find.byKey(const Key('profile-com.apple.Safari')));
    await tester.pumpAndSettle();
    expect(find.byType(AppProfilePage), findsOneWidget);
  });

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Map<String, dynamic> termRow(String id, String name, String command,
          {String? host, int panes = 1, int attached = 1, int? activity, bool dead = false, bool unread = false}) =>
      {
        'id': id, 'host': host, 'name': name, 'command': command, 'panes': panes, 'attached': attached,
        'activity': activity ?? now() - 7200, 'dead': dead, 'unread': unread,
      };

  Future<void> emitTerms(WidgetTester tester, List<Map<String, dynamic>> terms, {List<Map<String, dynamic>>? hosts}) async {
    t.emit({'event': 'terms', 'id': '111', 'path': 'lan', 'terms': terms, 'hosts': hosts ?? termHosts});
    // An active lamp never settles.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the terminal group lists sessions and opens one', (tester) async {
    final port = FakeSessionPort();
    final term = FakeTermSessionPort();
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, [
      termRow('term:tmux:work', 'work', 'claude', panes: 2, unread: true),
      termRow('term:tmux@gpu1:train', 'train', 'python', host: 'gpu1', panes: 3, activity: now() - 2),
      termRow('term:tmux:old', 'old', 'sh', dead: true),
      termRow('term:tmux:idle', 'idle', 'zsh', activity: now() - 30),
    ]);
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('train @gpu1'), findsOneWidget);
    expect(find.textContaining('3 个面板'), findsOneWidget);
    expect(find.text('刚刚有输出'), findsOneWidget);
    expect(find.text('未读'), findsOneWidget);
    expect(find.text('已退出'), findsOneWidget);
    expect(find.text('不到 1 分钟没动静'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('open-term:tmux:work')));
    await tester.tap(find.byKey(const Key('open-term:tmux:work')));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final open = t.sent.lastWhere((m) => m['cmd'] == 'open');
    expect((open['id'], open['app']), ('111', 'term:tmux:work'));
    term.dispose();
  });

  test('the status words of a terminal row', () {
    TermRow row(int ago, {bool dead = false, bool unread = false}) =>
        TermRow('term:tmux:w', 'w', 'sh', null, 1, 1, 1000 - ago, dead, unread);
    expect(termStatus(row(5), 1000), '刚刚有输出');
    expect(termStatus(row(10), 1000), '不到 1 分钟没动静');
    expect(termStatus(row(59), 1000), '不到 1 分钟没动静');
    expect(termStatus(row(60), 1000), '1 分钟没动静');
    expect(termStatus(row(3599), 1000), '59 分钟没动静');
    expect(termStatus(row(3600), 1000), '1 小时没动静');
    expect(termStatus(row(5, unread: true), 1000), '未读');
    expect(termStatus(row(5, unread: true, dead: true), 1000), '已退出');
    expect(termLamp(row(5), 1000), Lamp.active);
    expect(termLamp(row(50), 1000), Lamp.idle);
    expect(termLamp(row(5, unread: true), 1000), Lamp.waiting);
    expect(termLamp(row(5, dead: true), 1000), Lamp.disconnected);
  });

  testWidgets('no group when terminal sessions are off', (tester) async {
    termsOff = true;
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.text('终端'), findsNothing);
    expect(hub.termLists['111']!.off, isTrue);
    expect(find.byKey(const Key('add-ssh-host')), findsNothing);
  });

  testWidgets('an error list says so, and an empty one says there are no sessions', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    t.emit({'event': 'terms', 'id': '111', 'error': 'timed out'});
    await tester.pumpAndSettle();
    expect(find.text('终端：timed out'), findsOneWidget);
    await emitTerms(tester, []);
    expect(find.text('这台设备的 tmux 里现在没有会话。'), findsOneWidget);
  });

  Future<void> fillHost(WidgetTester tester, {String tmux = ''}) async {
    await tester.ensureVisible(find.byKey(const Key('add-ssh-host')));
    await tester.tap(find.byKey(const Key('add-ssh-host')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ssh-name')), 'gpu1');
    await tester.enterText(find.byKey(const Key('ssh-target')), 'me@gpu1');
    if (tmux.isNotEmpty) await tester.enterText(find.byKey(const Key('ssh-tmux')), tmux);
    await tester.tap(find.byKey(const Key('ssh-add')));
    await tester.pumpAndSettle();
  }

  testWidgets('adding an SSH host sends add_term_target and refreshes', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, []);
    t.sent.clear();
    await fillHost(tester);
    final add = t.sent.firstWhere((m) => m['cmd'] == 'add_term_target');
    expect(add, {'cmd': 'add_term_target', 'id': '111', 'name': 'gpu1', 'target': 'me@gpu1', 'req': anything});
    expect(t.sent.map((m) => m['cmd']).toList().sublist(t.sent.indexOf(add)), ['add_term_target', 'terms']);
    expect(find.byKey(const Key('ssh-name')), findsNothing);
    expect(find.text('gpu1 · me@gpu1'), findsOneWidget);
  });

  testWidgets('a tmux path is sent when filled, and a refused host keeps the dialog with the hub words', (tester) async {
    addTargetError = 'bad target: me@gpu1';
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, []);
    await fillHost(tester, tmux: '/opt/tmux');
    expect(t.sent.lastWhere((m) => m['cmd'] == 'add_term_target')['tmux'], '/opt/tmux');
    expect(find.byKey(const Key('ssh-name')), findsOneWidget);
    expect(find.text('bad target: me@gpu1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ssh-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ssh-name')), findsNothing);
  });

  testWidgets('a host that cannot be reached says why and can be removed', (tester) async {
    termHosts = [
      {'host': null},
      {'host': 'gpu1', 'target': 'me@gpu1', 'error': 'connection refused'},
    ];
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, []);
    expect(find.textContaining('gpu1 · me@gpu1'), findsOneWidget);
    expect(find.textContaining('连不上：connection refused'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('remove-host-gpu1')));
    await tester.tap(find.byKey(const Key('remove-host-gpu1')));
    await tester.pumpAndSettle();
    final rm = t.sent.lastWhere((m) => m['cmd'] == 'remove_term_target');
    expect((rm['id'], rm['name']), ('111', 'gpu1'));
    expect(t.sent.last['cmd'], 'terms');
    expect(find.byKey(const Key('remove-host-gpu1')), findsNothing);
  });

  testWidgets('a failed remove of an SSH host says so with the hub words and keeps the host', (tester) async {
    removeTargetError = 'no such host: gpu1';
    termHosts = [
      {'host': null},
      {'host': 'gpu1', 'target': 'me@gpu1'},
    ];
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, []);
    await tester.ensureVisible(find.byKey(const Key('remove-host-gpu1')));
    await tester.tap(find.byKey(const Key('remove-host-gpu1')));
    await tester.pumpAndSettle();
    expect(find.text('移除失败：no such host: gpu1'), findsOneWidget);
    expect(find.byKey(const Key('remove-host-gpu1')), findsOneWidget);
  });
}
