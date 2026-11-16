import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/app_profile_page.dart';
import 'package:rapp/ui/controls.dart';
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
  Map<String, dynamic>? capabilities;
  String? openError;
  bool offline = false;
  bool holdApps = false;
  var termsOff = false;
  String? openTermError;
  var holdOpenTerm = false;
  String? renameError;
  var termHosts = <Map<String, dynamic>>[{'host': null}];
  var termRows = <Map<String, dynamic>>[];
  List<Map<String, dynamic>>? remoteApps;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    appsPermissions = null;
    capabilities = null;
    openError = null;
    offline = false;
    holdApps = false;
    termsOff = false;
    openTermError = null;
    holdOpenTerm = false;
    renameError = null;
    termHosts = [{'host': null}];
    termRows = [];
    remoteApps = null;
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
            'apps': remoteApps ?? [
              {
                'app': 'desktop:',
                'name': '桌面',
                'displays': [
                  {'id': '1', 'name': 'Built-in', 'main': true, 'width': 1512, 'height': 982},
                ],
              },
              {'app': 'com.apple.Safari', 'name': 'Safari'},
            ],
            'permissions': ?appsPermissions,
            'capabilities': ?capabilities,
          });
        case 'terms':
          if (termsOff) return t.emit({'event': 'terms', 'req': req, 'id': cmd['id'], 'off': true});
          t.emit({'event': 'terms', 'req': req, 'id': cmd['id'], 'path': 'lan', 'terms': termRows, 'hosts': termHosts});
        case 'open_term':
          if (holdOpenTerm) return;
          if (openTermError != null) return t.emit({'event': 'error', 'req': req, 'error': openTermError});
          termRows = [...termRows, {'id': 'term:pty:c', 'name': 'c', 'command': 'claude', 'activity': 0}];
          t.emit({'event': 'term_created', 'req': req, 'id': cmd['id'], 'term': 'term:pty:c'});
        case 'rename_term':
          if (renameError != null) return t.emit({'event': 'error', 'req': req, 'error': renameError});
          t.emit({'event': 'term_renamed', 'req': req, 'id': cmd['id'], 'term': cmd['term']});
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
      {bool settle = true, bool localBadge = false}) async {
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
      child: DevicesTab(state: s, local: const Text('local-body'), localBadge: localBadge),
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

  testWidgets('no 屏幕共享 button; 桌面 is an app row with a favourite star', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.byKey(const Key('screen-share')), findsNothing);
    expect(find.text('用屏幕共享打开'), findsNothing);
    expect(find.text('桌面'), findsOneWidget);
    expect(find.byKey(const Key('fav-desktop:')), findsOneWidget);
  });

  testWidgets('Linux terminal device hides graphical controls and macOS permission hints', (tester) async {
    capabilities = {'graphical': false, 'terminal': true, 'ports': true};
    remoteApps = [];
    termHosts = [{'host': null, 'launchers': ['kitty']}];
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.byKey(const Key('bundle-id')), findsNothing);
    expect(find.byKey(const Key('open-bundle')), findsNothing);
    expect(find.textContaining('暂不提供应用画面'), findsOneWidget);
    expect(find.textContaining('屏幕录制'), findsNothing);
    expect(find.text('终端'), findsWidgets);
  });

  testWidgets('remote no-graphics capability makes a saved pixels choice open the existing text terminal', (tester) async {
    capabilities = {'graphical': false, 'terminal': true, 'ports': true};
    remoteApps = [];
    termRows = [{'id': 'term:pty:work', 'name': 'work', 'command': 'bash', 'activity': 1}];
    s.prefs.termOpen['111'] = 'pixels';
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.byKey(const Key('term-open-pixels')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('term-open-text')),
        matching: find.byIcon(Icons.radio_button_checked)), findsOneWidget);
    expect(s.prefs.termOpenFor('111'), 'pixels', reason: 'capabilities affect the effective choice, not saved preferences');
    await tester.ensureVisible(find.byKey(const Key('open-terms:')));
    await tester.tap(find.byKey(const Key('open-terms:')));
    await tester.pumpAndSettle();
    expect(t.sent.lastWhere((m) => m['cmd'] == 'open')['app'], 'term:pty:work');
  });

  testWidgets('remote no-graphics capability opens a new text terminal with its advertised launcher', (tester) async {
    capabilities = {'graphical': false, 'terminal': true, 'ports': true};
    remoteApps = [];
    termHosts = [{'host': null, 'launchers': ['kitty']}];
    s.prefs.termOpen['111'] = 'pixels';
    await pumpTab(tester);
    await selectMini(tester);
    await tester.tap(find.byKey(const Key('open-terms:')));
    await tester.pumpAndSettle();
    expect(t.sent.lastWhere((m) => m['cmd'] == 'open_term')['app'], 'kitty');
    expect(t.sent.lastWhere((m) => m['cmd'] == 'open')['app'], 'term:pty:c');
  });

  testWidgets('typed add form text survives switching device chips', (tester) async {
    await pumpTab(tester);
    await tester.enterText(find.byKey(const Key('add-id')), '999');
    await tester.tap(find.byKey(const Key('device-111')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('add-id'))).controller!.text, '999');
    // Typing scrolled the form into view; with mini's 终端 group the chip row is off the top by then.
    await tester.scrollUntilVisible(find.byKey(const Key('device-local')), -300.0,
        scrollable: find.byType(Scrollable).first);
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
    expect(tester.widget<TextField>(find.descendant(of: find.byKey(const Key('add-password')), matching: find.byType(TextField))).controller!.text, '');
    expect(tester.widget<TextField>(find.byKey(const Key('add-id'))).controller!.text, '');
  });

  testWidgets('password field is obscured', (tester) async {
    await pumpTab(tester);
    expect(tester.widget<TextField>(find.descendant(of: find.byKey(const Key('add-password')), matching: find.byType(TextField))).obscureText, isTrue);
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
    // Below mini's 终端 group the form is past the list's cache extent: scrolled to, not just made visible.
    await tester.scrollUntilVisible(find.byKey(const Key('add-button')), 300.0, scrollable: find.byType(Scrollable).first);
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
      termRow('term:pty:work', 'work', 'claude', panes: 2, unread: true),
      termRow('term:pty:train', 'train', 'python', activity: now() - 2),
      termRow('term:pty:old', 'old', 'sh', dead: true),
      termRow('term:pty:idle', 'idle', 'zsh', activity: now() - 30),
    ]);
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('train'), findsOneWidget);
    expect(find.textContaining('个面板'), findsNothing);
    expect(find.text('刚刚有输出'), findsOneWidget);
    expect(find.text('未读'), findsOneWidget);
    expect(find.text('已退出'), findsOneWidget);
    expect(find.text('不到 1 分钟没动静'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('open-term:pty:work')));
    await tester.tap(find.byKey(const Key('open-term:pty:work')));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final open = t.sent.lastWhere((m) => m['cmd'] == 'open');
    expect((open['id'], open['app']), ('111', 'term:pty:work'));
    term.dispose();
  });

  test('the status words of a terminal row', () {
    TermRow row(int ago, {bool dead = false, bool unread = false}) =>
        TermRow('term:pty:w', 'w', 'sh', null, 1, 1, 1000 - ago, dead, unread);
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
    expect(find.text('这台设备上现在没有终端会话。'), findsOneWidget);
  });

  testWidgets('no tmux or SSH controls', (tester) async {
    termRows = [
      {'id': 'term:pty:a', 'name': 'a', 'command': 'zsh', 'activity': 0},
      {'id': 'term:tmux:old', 'name': 'old', 'command': 'zsh', 'activity': 0},
    ];
    termHosts = [
      {'host': null, 'launchers': ['Terminal']},
      {'host': 'gpu1', 'target': 'me@gpu1', 'tmux': '/x/tmux'},
    ];
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, termRows, hosts: termHosts);
    expect(find.byKey(const Key('term-term:pty:a')), findsOneWidget);
    expect(find.byKey(const Key('term-term:tmux:old')), findsNothing);
    for (final k in ['new-term', 'add-ssh-host', 'remove-host-gpu1']) {
      expect(find.byKey(Key(k)), findsNothing, reason: k);
    }
    expect(find.textContaining('tmux'), findsNothing);
    expect(find.textContaining('SSH'), findsNothing);
    expect(find.textContaining('gpu1'), findsNothing);
  });

  List<Map<String, dynamic>> appsWithTerminal() => [
        {'app': 'com.apple.Safari', 'name': 'Safari'},
        {'app': 'com.apple.Terminal', 'name': 'Terminal'},
        {'app': 'desktop:', 'name': '桌面'},
      ];

  testWidgets('desktop, then 终端, then the other apps; Terminal only inside 终端', (tester) async {
    remoteApps = appsWithTerminal();
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, [termRow('term:pty:claude', 'claude', 'claude')],
        hosts: [{'host': null, 'launchers': ['Terminal']}]);
    double y(Finder f) => tester.getTopLeft(f).dy;
    expect(y(find.text('桌面')), lessThan(y(find.text('终端'))));
    expect(y(find.text('终端')), lessThan(y(find.text('Safari'))));
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.byKey(const Key('app-com.apple.Terminal')), findsNothing);
    final row = find.byKey(const Key('term-app-com.apple.Terminal'));
    expect(find.descendant(of: row, matching: find.text('Terminal')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('只能用画面看')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('画面')), findsOneWidget);
    t.sent.clear();
    await tester.ensureVisible(find.byKey(const Key('pixels-com.apple.Terminal')));
    await tester.tap(find.byKey(const Key('pixels-com.apple.Terminal')));
    await tester.pump();
    final open = t.sent.lastWhere((m) => m['cmd'] == 'open');
    expect((open['id'], open['app']), ('111', 'com.apple.Terminal'));
  });

  testWidgets('without the entry, terminal apps stay in the app list', (tester) async {
    remoteApps = appsWithTerminal();
    termsOff = true;
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.text('终端'), findsNothing);
    expect(find.byKey(const Key('app-com.apple.Terminal')), findsOneWidget);
    expect(find.text('只能用画面看'), findsNothing);
  });

  testWidgets('the 终端 row opens the entry and can be a favourite', (tester) async {
    s.prefs.termOpen['111'] = 'pixels';
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, []);
    await tester.tap(find.byKey(const Key('fav-terms:')));
    await tester.pump();
    expect(s.isFavorite('111', 'terms:'), isTrue);
    expect(s.favorites.last.name, '终端');
    t.sent.clear();
    await tester.tap(find.byKey(const Key('open-terms:')));
    await tester.pump();
    expect(t.sent.lastWhere((m) => m['cmd'] == 'open')['app'], 'com.apple.Terminal');
  });

  testWidgets('a row shows no kind word, only the command', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, [termRow('term:pty:claude', 'claude', 'claude'), termRow('term:pty:work', 'work', 'zsh')]);
    final row = find.byKey(const Key('term-term:pty:work'));
    expect(find.descendant(of: row, matching: find.text('zsh')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('文本')), findsNothing);
    expect(find.descendant(of: row, matching: find.text('tmux')), findsNothing);
  });

  const shellsZshBash = [
    {'name': 'zsh', 'path': '/bin/zsh', 'default': true},
    {'name': 'bash', 'path': '/bin/bash'},
  ];

  // On a tab already showing mini.
  Future<void> showHost(WidgetTester tester, List<String> launchers, {List<Map<String, dynamic>>? shells}) async {
    await emitTerms(tester, [], hosts: [
      {'host': null, 'launchers': launchers, 'shells': ?shells}
    ]);
    t.sent.clear();
  }

  RappButton shellButton(WidgetTester tester, String key) => tester.widget<RappButton>(find.byKey(Key(key)));

  testWidgets('one button per listed shell, default first', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await showHost(tester, ['Terminal'], shells: shellsZshBash);
    expect(find.text('新开'), findsOneWidget);
    expect(find.byKey(const Key('new-shell-zsh')), findsOneWidget);
    expect(find.byKey(const Key('new-shell-bash')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('new-shell-zsh')), matching: find.text('zsh')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('new-shell-zsh'))).dx,
        lessThan(tester.getTopLeft(find.byKey(const Key('new-shell-bash'))).dx));
    expect(find.byKey(const Key('new-text-term')), findsNothing);
  });

  testWidgets('tapping a shell opens it with the chosen app', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await showHost(tester, ['Terminal', 'iTerm'], shells: shellsZshBash);
    await tester.ensureVisible(find.byKey(const Key('term-app-iTerm')));
    await tester.tap(find.byKey(const Key('term-app-iTerm')));
    await tester.pump();
    expect(s.prefs.termApp, {'111': 'iTerm'});
    await tester.ensureVisible(find.byKey(const Key('new-shell-bash')));
    await tester.tap(find.byKey(const Key('new-shell-bash')));
    await tester.pumpAndSettle();
    final m = t.sent.firstWhere((m) => m['cmd'] == 'open_term');
    expect(m, {'cmd': 'open_term', 'id': '111', 'shell': '/bin/bash', 'app': 'iTerm', 'req': anything});
    expect(t.sent.map((m) => m['cmd']), containsAllInOrder(['open_term', 'terms', 'open']));
    expect(t.sent.lastWhere((m) => m['cmd'] == 'open')['app'], 'term:pty:c');
  });

  testWidgets('the 终端 app row shows only with two launchers', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await showHost(tester, ['Terminal'], shells: shellsZshBash);
    expect(find.text('终端 app'), findsNothing);
    expect(find.byKey(const Key('term-app-Terminal')), findsNothing);
    await showHost(tester, ['Terminal', 'iTerm'], shells: shellsZshBash);
    expect(find.text('终端 app'), findsOneWidget);
    expect(find.byKey(const Key('term-app-Terminal')), findsOneWidget);
    expect(find.byKey(const Key('term-app-iTerm')), findsOneWidget);
  });

  testWidgets('an old device gets one 默认 shell button', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await showHost(tester, ['Terminal']);
    expect(find.text('默认 shell'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('new-shell-default')));
    await tester.tap(find.byKey(const Key('new-shell-default')));
    await tester.pumpAndSettle();
    final m = t.sent.firstWhere((m) => m['cmd'] == 'open_term');
    expect(m, {'cmd': 'open_term', 'id': '111', 'app': 'Terminal', 'req': anything});
  });

  testWidgets('no new row without launchers', (tester) async {
    await pumpTab(tester);
    await selectMini(tester);
    await showHost(tester, [], shells: shellsZshBash);
    expect(find.text('新开'), findsNothing);
    expect(find.text('终端 app'), findsNothing);
    expect(find.byKey(const Key('new-shell-zsh')), findsNothing);
  });

  testWidgets('a refused open shows its words under the row; the button is busy meanwhile', (tester) async {
    holdOpenTerm = true;
    await pumpTab(tester);
    await selectMini(tester);
    await showHost(tester, ['Terminal'], shells: shellsZshBash);
    await tester.ensureVisible(find.byKey(const Key('new-shell-bash')));
    await tester.tap(find.byKey(const Key('new-shell-bash')));
    await tester.pump();
    expect(shellButton(tester, 'new-shell-bash').onPressed, isNull);
    t.emit({'event': 'error', 'req': t.sent.lastWhere((m) => m['cmd'] == 'open_term')['req'], 'error': 'this shell is not found any more'});
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('new-shell-error'))).data, 'this shell is not found any more');
    expect(shellButton(tester, 'new-shell-bash').onPressed, isNotNull);
    expect(find.byKey(const Key('new-text-term')), findsNothing);
  });

  Future<void> showWork(WidgetTester tester, {List<Map<String, dynamic>>? shells = shellsZshBash}) async {
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, [termRow('term:pty:work', 'work', 'claude')],
        hosts: [{'host': null, 'launchers': ['Terminal'], 'shells': ?shells}]);
    t.sent.clear();
  }

  Future<void> renameTo(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.byKey(const Key('term-name-term:pty:work')));
    await tester.tap(find.byKey(const Key('term-name-term:pty:work')));
    await tester.pump();
    await tester.enterText(find.descendant(of: find.byKey(const Key('term-name-term:pty:work')), matching: find.byType(TextField)), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renaming a row sends rename_term with the trimmed name', (tester) async {
    await showWork(tester);
    await renameTo(tester, '  build  ');
    final m = t.sent.firstWhere((m) => m['cmd'] == 'rename_term');
    expect(m, {'cmd': 'rename_term', 'id': '111', 'term': 'term:pty:work', 'name': 'build', 'req': anything});
    expect(t.sent.map((m) => m['cmd']), containsAllInOrder(['rename_term', 'terms']));
    expect(find.byKey(const Key('rename-error')), findsNothing);
  });

  testWidgets('an invalid name is not sent and the old name stays', (tester) async {
    await showWork(tester);
    await renameTo(tester, '   ');
    expect(t.sent.where((m) => m['cmd'] == 'rename_term'), isEmpty);
    expect(find.text('work'), findsOneWidget);
  });

  testWidgets('a refusal shows under the list', (tester) async {
    renameError = 'this text terminal is too old to rename';
    await showWork(tester);
    await renameTo(tester, 'build');
    expect(tester.widget<Text>(find.byKey(const Key('rename-error'))).data, 'this text terminal is too old to rename');
    expect(find.text('work'), findsOneWidget);
  });

  testWidgets('an old device has no inline edit', (tester) async {
    await showWork(tester, shells: null);
    expect(find.byKey(const Key('term-name-term:pty:work')), findsNothing);
    expect(find.text('work'), findsOneWidget);
  });

  testWidgets('打开方式 is saved per device', (tester) async {
    Directory('${tmp.path}/local').createSync(recursive: true);
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    await pumpTab(tester);
    await selectMini(tester);
    await emitTerms(tester, []);
    expect(s.prefs.termOpenFor('111'), 'text');
    expect(tester.getSize(find.byKey(const Key('term-open-text'))).height, greaterThanOrEqualTo(48));
    await tester.ensureVisible(find.byKey(const Key('term-open-pixels')));
    await tester.tap(find.byKey(const Key('term-open-pixels')));
    await tester.pump();
    expect((s.prefs.termOpenFor('111'), s.prefs.termOpenFor('222')), ('pixels', 'text'));
    expect(UiPrefs.load(s.data.prefsDir()!).termOpenFor('111'), 'pixels');
    await tester.tap(find.byKey(const Key('term-open-text')));
    await tester.pump();
    expect(s.prefs.termOpenFor('111'), 'text');
  });
}
