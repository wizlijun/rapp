import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/backdrop.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('stage_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    s = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Widget stage() => SizedBox(width: 800, height: 600, child: Stage(state: s));

  Future<void> openActive(WidgetTester tester) async {
    await tester.runAsync(() async {
      t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'Safari', 'path': 'lan'});
      await flush();
    });
    s.select('111/Safari');
    await tester.pump();
  }

  testWidgets('empty stage invites opening the panel', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    expect(find.text('打开左侧面板，选一个会话或到设备里打开 app'), findsOneWidget);
    await tester.tap(find.text('打开面板'));
    expect(s.panel, isNotNull);
  });

  testWidgets('stage placeholder focus button sends focus', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    await openActive(tester);
    expect(find.text('Safari 在单独的窗口里 · mini · 局域网'), findsOneWidget);
    await tester.tap(find.byKey(const Key('focus-button')));
    expect(t.sent.last, {'cmd': 'focus', 'sid': 1});
  });

  testWidgets('end button needs two taps', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    await openActive(tester);
    await tester.tap(find.byKey(const Key('end-button')));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
    await tester.tap(find.byKey(const Key('end-button')));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'close').single, {'cmd': 'close', 'sid': 1});
  });

  testWidgets('armed end button does not carry over to the next session', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    await tester.runAsync(() async {
      t.emit({'event': 'opened', 'sid': 2, 'id': '111', 'app': 'Notes', 'path': 'lan'});
      await flush();
    });
    await openActive(tester);
    await tester.tap(find.byKey(const Key('end-button')));
    await tester.pump();
    expect(find.text('再点一次确认'), findsOneWidget);
    await tester.runAsync(() async {
      t.emit({'event': 'closed', 'sid': 1, 'reason': 'app quit'});
      await flush();
    });
    await tester.pump();
    expect(s.current?.appName, 'Notes');
    expect(find.text('再点一次确认'), findsNothing);
    await tester.tap(find.byKey(const Key('end-button')));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
  });

  testWidgets('stage shows connecting while open is pending', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    s.openOrSwitch('111', 'Safari', 'Safari');
    await tester.pump(const Duration(milliseconds: 100));
    final lamp = tester.widget<StatusLamp>(find.byType(StatusLamp));
    expect(lamp.kind, Lamp.connecting);
    expect(find.text('正在连接'), findsOneWidget);
  });

  testWidgets('stage shows hub problem after hub dies', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    await openActive(tester);
    await tester.runAsync(() async {
      await t.die();
      await flush();
    });
    await tester.pump();
    expect(find.text('rapp-hub 已退出 — 重启 rapp 以恢复'), findsOneWidget);
    expect(find.byKey(const Key('focus-button')), findsNothing);
  });

  for (final th in RappTheme.values) {
    testWidgets('backdrop ${th.name} keeps child and ignores pointers', (tester) async {
      await tester.pumpWidget(wrap(
        SizedBox(width: 300, height: 200, child: Backdrop(theme: th, child: const Text('hi'))),
        theme: th,
      ));
      expect(find.text('hi'), findsOneWidget);
      if (th != RappTheme.westworld) {
        expect(find.descendant(of: find.byType(Backdrop), matching: find.byType(IgnorePointer)),
            findsWidgets);
      }
    });
  }
}
