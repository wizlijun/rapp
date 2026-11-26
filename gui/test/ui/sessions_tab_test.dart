// The side panel's 会话 tab: the 别处开着 group lists sessions other apps have open (rapp-state P3).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/sessions_tab.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late MainState s;
  late FakeStateSync sync;
  late Directory tmp;
  var sid = 0;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sessions_tab_test');
    sid = 0;
  });
  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await flush();
      }
    });
    await tester.pump();
  }

  /// m1 (mini) online, nothing open, in an app whose own fingerprint is `appA`; [desks] from the state service.
  Future<void> boot(WidgetTester tester, List<Map<String, Object?>> desks, {StateStatus status = StateStatus.connected}) async {
    t = FakeTransport();
    t.onSend = (m) {
      switch (m['cmd']) {
        case 'hosts':
          t.emit({
            'event': 'hosts',
            'req': m['req'],
            'me': 'appA',
            'name': 'Mac',
            'hosts': [
              {'id': 'm1', 'name': 'mini', 'fp': 'devM'},
            ],
          });
        case 'apps':
          t.emit({'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan', 'apps': []});
        case 'open':
          t.emit({'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req']});
      }
    };
    sync = FakeStateSync(tmp.path)
      ..status = status
      ..desks = desks;
    s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), stateSync: sync);
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await flush();
      }
    });
    await tester.pumpWidget(wrap(SizedBox(width: 360, height: 700, child: SessionsTab(state: s))));
    await settle(tester);
  }

  final macDesk = {
    'fp': 'appB',
    'device': 'Mac',
    'at': 200,
    'sessions': [
      {'id': 'm1', 'app': 'com.x', 'name': 'X'},
    ],
  };

  testWidgets('别处开着 lists a session open on another app and opens it on tap, never by itself', (tester) async {
    await boot(tester, [macDesk]);
    expect(find.text('别处开着'), findsOneWidget);
    final card = find.byKey(const Key('elsewhere-m1/com.x'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('X')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('在 Mac 上开着')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('打开')), findsOneWidget);
    // the device's name gives way to where it is open
    expect(find.descendant(of: card, matching: find.textContaining('mini')), findsNothing);
    expect(t.sent.where((m) => m['cmd'] == 'open'), isEmpty);

    await tester.tap(card);
    await settle(tester);
    final open = t.sent.where((m) => m['cmd'] == 'open').single;
    expect((open['id'], open['app']), ('m1', 'com.x'));
    // open here now: it leaves 别处开着 for the open sessions
    expect(find.byKey(const Key('elsewhere-m1/com.x')), findsNothing);
    expect(find.byKey(const Key('session-m1/com.x')), findsOneWidget);
    expect(find.text('别处开着'), findsNothing);
  });

  testWidgets('no service, no 别处开着', (tester) async {
    await boot(tester, [macDesk], status: StateStatus.unreachable);
    expect(find.text('别处开着'), findsNothing);
    expect(find.byKey(const Key('elsewhere-m1/com.x')), findsNothing);
  });
}
