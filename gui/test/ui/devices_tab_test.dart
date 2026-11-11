import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/devices_tab.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

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

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    appsPermissions = null;
    openError = null;
    offline = false;
    tmp = Directory.systemTemp.createTempSync('devices_tab_test');
    t = FakeTransport();
    hub = HubClient(t);
    final hosts = <Map<String, dynamic>>[
      {'id': '111', 'name': 'mini'},
    ];
    t.emit({'event': 'hosts', 'hosts': hosts});
    await flush();
    t.onSend = (cmd) {
      final req = cmd['req'];
      switch (cmd['cmd']) {
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
        case 'open':
          if (openError != null) return t.emit({'event': 'error', 'req': req, 'error': openError});
          t.emit({'event': 'opened', 'req': req, 'sid': 1, 'id': cmd['id'], 'app': cmd['app'], 'path': 'lan'});
      }
    };
    s = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pumpTab(WidgetTester tester) async {
    s.togglePanel(PanelTab.devices);
    await tester.pumpWidget(wrap(SizedBox(
      width: 420,
      height: 900,
      child: DevicesTab(state: s, local: const Text('local-body')),
    )));
    await tester.pumpAndSettle();
  }

  Future<void> selectMini(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('device-111')));
    await tester.pumpAndSettle();
  }

  testWidgets('shows 本机 first and probes every device on start', (tester) async {
    await pumpTab(tester);
    expect(find.text('local-body'), findsOneWidget);
    expect(find.byKey(const Key('device-local')), findsOneWidget);
    expect(t.sent.where((m) => m['cmd'] == 'apps').length, 1);
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
    expect(find.textContaining('bad password'), findsOneWidget);
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

  testWidgets('offline device shows 离线 and the error', (tester) async {
    offline = true;
    await pumpTab(tester);
    await selectMini(tester);
    expect(find.text('离线'), findsWidgets);
    expect(find.textContaining('connect timed out'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('add-button')), warnIfMissed: false);
    await tester.pump();
  });
}
