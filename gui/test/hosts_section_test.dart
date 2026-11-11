import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/hosts_section.dart';

import 'fakes.dart';

/// What the scripted A reports with its app list, and how an open fails (null: it works).
Map<String, dynamic>? appsPermissions;
String? openError;

/// Answers like a well-behaved rapp-hub with one saved host.
void scriptHub(FakeTransport t) {
  final hosts = <Map<String, dynamic>>[
    {'id': '111111111', 'name': 'mac-a'},
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
          hosts.add({'id': cmd['id'], 'name': 'mac-new'});
          t.emit({'event': 'host_added', 'req': req, 'id': cmd['id'], 'name': 'mac-new'});
        }
      case 'remove_host':
        hosts.removeWhere((h) => h['id'] == cmd['id']);
        t.emit({'event': 'hosts', 'req': req, 'hosts': hosts});
      case 'apps':
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
}

void main() {
  late FakeTransport t;
  late HubClient hub;

  Future<void> pumpSection(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: HostsSection(hub: hub)))));
    await tester.pumpAndSettle();
  }

  setUp(() {
    appsPermissions = null;
    openError = null;
    t = FakeTransport();
    scriptHub(t);
    hub = HubClient(t);
  });

  testWidgets('lists hosts from the hub on start', (tester) async {
    await pumpSection(tester);
    expect(t.sent.first['cmd'], 'hosts');
    expect(find.text('mac-a'), findsOneWidget);
    expect(find.text('111111111'), findsOneWidget);
  });

  testWidgets('adds a host by ID and password', (tester) async {
    await pumpSection(tester);
    await tester.enterText(find.byKey(const Key('add-id')), '222222222');
    await tester.enterText(find.byKey(const Key('add-password')), 'pw');
    await tester.tap(find.byKey(const Key('add-button')));
    await tester.pumpAndSettle();
    final add = t.sent.firstWhere((m) => m['cmd'] == 'add_host');
    expect(add['id'], '222222222');
    expect(add['password'], 'pw');
    expect(find.text('mac-new'), findsOneWidget);
  });

  testWidgets('shows the hub error when adding fails', (tester) async {
    await pumpSection(tester);
    await tester.enterText(find.byKey(const Key('add-id')), '333333333');
    await tester.enterText(find.byKey(const Key('add-password')), 'bad');
    await tester.tap(find.byKey(const Key('add-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('bad password'), findsOneWidget);
  });

  testWidgets('removes a host', (tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const Key('remove-111111111')));
    await tester.pumpAndSettle();
    expect(t.sent.last['cmd'], 'remove_host');
    expect(find.text('mac-a'), findsNothing);
  });

  testWidgets('tap host → app list → tap app opens it; bundle id field opens any app', (tester) async {
    await pumpSection(tester);
    await tester.tap(find.text('mac-a'));
    await tester.pumpAndSettle();
    expect(t.sent.last, containsPair('cmd', 'apps'));
    expect(find.text('Safari'), findsOneWidget);
    expect(find.textContaining('lan'), findsWidgets);

    await tester.tap(find.text('Safari'));
    await tester.pumpAndSettle();
    final open = t.sent.lastWhere((m) => m['cmd'] == 'open');
    expect(open['id'], '111111111');
    expect(open['app'], 'com.apple.Safari');
    expect(hub.sessions, hasLength(1));

    await tester.enterText(find.byKey(const Key('bundle-id')), 'com.apple.TextEdit');
    await tester.tap(find.byKey(const Key('open-bundle')));
    await tester.pumpAndSettle();
    expect(t.sent.last, containsPair('app', 'com.apple.TextEdit'));
  });

  testWidgets('warns before opening when A is missing permissions', (tester) async {
    appsPermissions = {'screen_recording': false, 'accessibility': true};
    await pumpSection(tester);
    await tester.tap(find.text('mac-a'));
    await tester.pumpAndSettle();
    expect(find.text('「mac-a」缺少 屏幕录制 权限。请在那台电脑上打开 rapp，在 本机 › 权限 里点「打开系统设置」。'), findsOneWidget);
  });

  testWidgets('no warning when A has every permission', (tester) async {
    appsPermissions = {'screen_recording': true, 'accessibility': true};
    await pumpSection(tester);
    await tester.tap(find.text('mac-a'));
    await tester.pumpAndSettle();
    expect(find.textContaining('缺少'), findsNothing);
  });

  testWidgets('an open that fails for permissions explains it in Chinese', (tester) async {
    openError = 'rapp-host exited: missing permission: Accessibility\nAllow rapp under System Settings.';
    await pumpSection(tester);
    await tester.tap(find.text('mac-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Safari'));
    await tester.pumpAndSettle();
    expect(find.text('「mac-a」缺少 辅助功能 权限。请在那台电脑上打开 rapp，在 本机 › 权限 里点「打开系统设置」。'), findsOneWidget);
    expect(find.textContaining('missing permission'), findsNothing);
  });
}
