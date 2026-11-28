import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/devices_page.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/settings_page.dart';
import 'package:rapp/phone/sheet.dart';
import 'package:rapp/ui/add_device_form.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/session_block.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';

void main() {
  late Directory tmp;
  late FakeTransport t;
  late FakeSessionPort port;
  late MainState s;
  late PhoneNav nav;
  var sid = 0;
  var holdOpen = false;
  Map<String, dynamic>? held;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pages_test');
    sid = 0;
    holdOpen = false;
    held = null;
  });
  tearDown(() {
    nav.dispose();
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> boot(WidgetTester tester, {List<String> apps = const [], bool term = false}) async {
    t = FakeTransport();
    port = FakeSessionPort();
    t.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        t.emit({
          'event': 'hosts',
          'req': m['req'],
          'hosts': [
            {'id': 'm1', 'name': 'mini'},
            {'id': 'm2', 'name': 'mac2'},
          ],
        });
      } else if (m['cmd'] == 'apps') {
        t.emit({'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan', 'apps': []});
      } else if (m['cmd'] == 'open') {
        if (holdOpen) {
          held = m;
          return;
        }
        t.emit({
          'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan',
          if (m['embed'] == true) ...{'port': 5000 + sid, 'token': 'tk'},
          'req': m['req'],
        });
      }
    };
    s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term ? FakeTermSessionPort() : null);
    nav = PhoneNav(s);
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await flush();
      }
      for (final a in apps) {
        final p = a.split('/');
        s.openOrSwitch(p[0], p[1], p[1]);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      }
    });
  }

  Future<void> labelOn(WidgetTester tester, String app) async {
    await tester.runAsync(() async {
      t.emit({'event': 'labels', 'id': 'm1', 'rev': 1, 'labels': {app: {'title': 'zz'}}});
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
  }

  Future<void> land(WidgetTester tester) async {
    final m = held!;
    await tester.runAsync(() async {
      t.emit({
        'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan',
        if (m['embed'] == true) ...{'port': 5000 + sid, 'token': 'tk'},
        'req': m['req'],
      });
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
  }

  Widget app(RappTheme th, Widget home) => MaterialApp(theme: themeDataFor(th), home: Scaffold(body: home));

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  for (final th in RappTheme.values) {
    group(th.name, () {
      testWidgets('sheet has three rows', (tester) async {
        size(tester);
        await boot(tester);
        await tester.pumpWidget(app(th, Builder(builder: (c) => TextButton(onPressed: () => showPhoneSheet(c, nav), child: const Text('go')))));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        for (final w in ['助理', '设备', '设置']) {
          expect(find.text(w), findsOneWidget);
          expect(tester.getSize(find.ancestor(of: find.text(w), matching: find.byType(InkWell)).first).height, greaterThanOrEqualTo(56));
        }
        for (final w in ['项目', '已处理']) {
          expect(find.text(w), findsNothing);
        }
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        expect(nav.now, PhoneView.settings);
      });

      testWidgets('device rows are 56', (tester) async {
        size(tester);
        await boot(tester, apps: ['m1/a', 'm1/b', 'm2/a', 'm2/b']);
        await tester.pumpWidget(app(th, DevicesPage(state: s, nav: nav)));
        await tester.pump();
        expect(find.byType(SessionBlock), findsNWidgets(4));
        for (final b in tester.widgetList<SessionBlock>(find.byType(SessionBlock))) {
          final box = find.ancestor(of: find.byWidget(b), matching: find.byType(ConstrainedBox)).first;
          expect(tester.getSize(box).height, greaterThanOrEqualTo(56));
        }
        expect(find.text('mini'), findsOneWidget);
        expect(find.text('mac2'), findsOneWidget);
        await tester.tap(find.byKey(const Key('block-m2/b')));
        await tester.pump();
        expect(nav.now, PhoneView.session);
        expect(s.currentKey, 'm2/b');
      });

      testWidgets('standby tap enters once open', (tester) async {
        size(tester);
        await boot(tester, apps: ['m1/a']);
        await labelOn(tester, 'zz');
        await tester.pumpWidget(app(th, DevicesPage(state: s, nav: nav)));
        await tester.pump();
        holdOpen = true;
        await tester.tap(find.byKey(const Key('block-m1/zz')));
        await tester.pump();
        await tester.runAsync(() async {
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        expect(nav.now, PhoneView.home);
        expect(held, isNotNull);
        await land(tester);
        expect(nav.now, PhoneView.session);
        expect(s.currentKey, 'm1/zz');
      });

      testWidgets('standby open that never lands stays on list', (tester) async {
        size(tester);
        await boot(tester, apps: ['m1/a']);
        await labelOn(tester, 'zz');
        await tester.pumpWidget(app(th, DevicesPage(state: s, nav: nav)));
        await tester.pump();
        holdOpen = true;
        await tester.tap(find.byKey(const Key('block-m1/zz')));
        await tester.pump();
        await tester.runAsync(() => flush());
        await tester.pump();
        expect(nav.now, PhoneView.home);
        expect(find.byKey(const Key('block-m1/a')), findsOneWidget);
      });

      testWidgets('stopped standby enters the new terminal once open', (tester) async {
        size(tester);
        await boot(tester, apps: ['m1/a'], term: true);
        s.hub!.termLists['m1'] = TermList('m1', terms: const [], hosts: [TermHost(null, launchers: const ['Terminal'])]);
        final inner = t.onSend!;
        t.onSend = (m) {
          if (m['cmd'] == 'open_term') {
            t.emit({'event': 'term_created', 'req': m['req'], 'id': m['id'], 'term': 'term:pty:new'});
          } else if (m['cmd'] == 'terms') {
            t.emit({
              'event': 'terms', 'req': m['req'], 'id': m['id'], 'terms': [],
              'hosts': [{'host': null, 'launchers': ['Terminal']}],
            });
          } else {
            inner(m);
          }
        };
        await labelOn(tester, 'term:pty:old');
        await tester.pumpWidget(app(th, DevicesPage(state: s, nav: nav)));
        await tester.pump();
        holdOpen = true;
        await tester.tap(find.byKey(const Key('block-m1/term:pty:old')));
        await tester.pump();
        await tester.runAsync(() async {
          for (var i = 0; i < 8; i++) {
            await flush();
          }
        });
        await tester.pump();
        expect(nav.now, PhoneView.home);
        expect(held, isNotNull);
        expect(held!['app'], 'term:pty:new');
        await land(tester);
        expect(nav.now, PhoneView.session);
        expect(s.currentKey, 'm1/term:pty:new');
      });

      testWidgets('add device expands the form', (tester) async {
        size(tester);
        await boot(tester);
        await tester.pumpWidget(app(th, DevicesPage(state: s, nav: nav)));
        await tester.pump();
        expect(find.byType(AddDeviceForm), findsNothing);
        await tester.tap(find.text('添加设备'));
        await tester.pump();
        expect(find.byType(AddDeviceForm), findsOneWidget);
      });

      testWidgets('settings switches theme', (tester) async {
        size(tester);
        await boot(tester);
        await tester.pumpWidget(app(th, SettingsPage(state: s, nav: nav)));
        await tester.pump();
        expect(find.text('手机和展开后的 Pad 界面用同一个主题。'), findsOneWidget);
        for (final n in ['AVATAR', 'MATRIX', 'WESTWORLD']) {
          expect(tester.getSize(find.ancestor(of: find.text(n), matching: find.byType(InkWell)).first).height,
              greaterThanOrEqualTo(56));
        }
        await tester.tap(find.text('WESTWORLD'));
        await tester.pump();
        expect(s.prefs.theme, RappTheme.westworld);
      });
    });
  }
}
