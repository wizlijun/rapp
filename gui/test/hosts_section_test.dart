import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/hosts_section.dart';

import 'fakes.dart';

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
        });
      case 'open':
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
}
