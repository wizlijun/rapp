import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/session_model.dart';
import 'package:rapp/ui/side_panel.dart';
import 'package:rapp/ui/sessions_tab.dart';
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
    tmp = Directory.systemTemp.createTempSync('side_panel_test');
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

  Future<void> open(WidgetTester tester, int sid, String app) async {
    t.emit({'event': 'opened', 'sid': sid, 'id': '111', 'app': app, 'path': 'lan'});
    await tester.runAsync(flush);
    await tester.pump();
  }

  Widget panel({Widget? devices}) => SidePanel(
        state: s,
        devicesTab: devices ?? const Text('devices-body'),
      );

  testWidgets('tapping a session selects it and closes the panel', (tester) async {
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'Safari');
    await tester.tap(find.byKey(const Key('session-111/Safari')));
    await tester.pump();
    expect(s.currentKey, '111/Safari');
    expect(s.panel, isNull);
  });

  testWidgets('empty state text', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    expect(find.text('没有打开的会话。到「设备」里打开一个 app。'), findsOneWidget);
  });

  testWidgets('grouping switch regroups', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'Safari');
    expect(find.text('mini'), findsOneWidget); // group title
    await tester.tap(find.byKey(const Key('group-app')));
    await tester.pump();
    expect(s.grouping, Grouping.app);
    expect(find.text('Safari'), findsWidgets);
    expect(find.text('mini · 局域网'), findsOneWidget);
    expect(find.text('局域网'), findsNothing);
  });

  testWidgets('session row semantics include the lamp word', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'Safari');
    final h = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Safari，活动，局域网'), findsOneWidget);
    h.dispose();
  });

  testWidgets('session row is 60 tall', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'Safari');
    expect(tester.getSize(find.byKey(const Key('session-111/Safari'))).height, 60);
  });

  testWidgets('selected row gets an inner stroke', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'Safari');
    await open(tester, 2, 'Mail');
    s.select('111/Safari');
    s.togglePanel();
    await tester.pump();
    expect(find.byKey(const Key('inner-stroke-111/Safari')), findsOneWidget);
    expect(find.byKey(const Key('inner-stroke-111/Mail')), findsNothing);
  });

  testWidgets('theme dropdown lists the four films in order', (tester) async {
    await tester.pumpWidget(wrap(panel(), disableAnimations: true));
    expect(tester.getSize(find.byKey(const Key('theme-dropdown'))).height,
        greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const Key('theme-dropdown')));
    await tester.pumpAndSettle();
    final labels = [for (final th in themeOrder) themeLabel(th)];
    expect(labels, ['AVATAR', 'IRON MAN', 'MATRIX', 'WESTWORLD']);
    final ys = [
      for (final l in labels)
        tester.getTopLeft(find.text(l).last).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(ys.toSet().length, 4);
  });

  testWidgets('picking IRON MAN changes prefs.theme', (tester) async {
    await tester.pumpWidget(wrap(panel(), disableAnimations: true));
    await tester.tap(find.byKey(const Key('theme-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IRON MAN').last);
    await tester.pumpAndSettle();
    expect(s.prefs.theme, RappTheme.ironMan);
    expect(UiPrefs.load(tmp.path).theme, RappTheme.ironMan);
  });

  testWidgets('start fullscreen switch saves', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    expect(find.text('启动时全屏'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-fullscreen')));
    await tester.pump();
    expect(s.prefs.startFullscreen, false);
    expect(UiPrefs.load(tmp.path).startFullscreen, false);
  });

  testWidgets('legend shows all seven words', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    for (final l in Lamp.values) {
      expect(find.text(lampWord(l)), findsOneWidget, reason: lampWord(l));
    }
  });

  testWidgets('legend lamps stand still so nothing blinks when nothing is waiting', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    final moving = find.descendant(
      of: find.byKey(const Key('legend')),
      matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Motion'),
    );
    expect(find.byKey(const Key('legend')), findsOneWidget);
    expect(moving, findsNothing);
  });

  testWidgets('totals show counts, literal traffic dash, muted zero', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    expect(find.text('在线设备'), findsOneWidget);
    expect(find.text('会话'), findsWidgets);
    expect(find.text('总流量'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    final zero = tester.widget<Text>(find.byKey(const Key('total-sessions')));
    expect(zero.data, '0');
    expect(zero.style!.color, tokensFor(RappTheme.matrix).muted);
    await open(tester, 1, 'Safari');
    final one = tester.widget<Text>(find.byKey(const Key('total-sessions')));
    expect(one.data, '1');
    expect(one.style!.color, tokensFor(RappTheme.matrix).text);
  });

  testWidgets('tabs switch panel and close button closes', (tester) async {
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await tester.tap(find.byKey(const Key('tab-devices')));
    await tester.pump();
    expect(s.panel, PanelTab.devices);
    expect(find.text('devices-body'), findsOneWidget);
    expect(find.byTooltip('收起面板'), findsOneWidget);
    await tester.tap(find.byKey(const Key('panel-close')));
    await tester.pump();
    expect(s.panel, isNull);
  });

  testWidgets('panel is clamped to the window width', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel(PanelTab.devices);
    await tester.pumpWidget(wrap(Stack(children: [
      Positioned(left: 0, top: 0, bottom: 0, child: panel()),
    ])));
    expect(tester.getSize(find.byType(SidePanel)).width, lessThanOrEqualTo(400));
  });

  testWidgets('sessions panel is 330 wide on a big window', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    expect(tester.getSize(find.byType(SidePanel)).width, 330);
  });

  testWidgets('no overflow on a 400x500 window', (tester) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'Safari');
    await open(tester, 2, 'Mail');
    expect(tester.takeException(), isNull);
    s.togglePanel(PanelTab.devices);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('hub exit: tapping a session does not throw', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'Safari');
    await tester.runAsync(() async {
      await t.die();
      await flush();
    });
    await tester.pump();
    expect(hub.alive, false);
    expect(tester.takeException(), isNull);
    expect(find.text('没有打开的会话。到「设备」里打开一个 app。'), findsOneWidget);
  });

  testWidgets('prefs save failure shows hint, UI still switches', (tester) async {
    final f = File('${tmp.path}/blocker')..writeAsStringSync('x');
    final bad = MainState(hub: hub, configDir: '${f.path}/sub', prefs: UiPrefs());
    addTearDown(bad.dispose);
    await tester.pumpWidget(wrap(SidePanel(state: bad, devicesTab: const SizedBox())));
    await tester.tap(find.byKey(const Key('start-fullscreen')));
    await tester.pump();
    expect(bad.prefs.startFullscreen, false);
    expect(bad.hint, startsWith('偏好没有保存：'));
  });

  testWidgets('SessionsTab alone builds', (tester) async {
    await tester.pumpWidget(wrap(SizedBox(width: 330, height: 400, child: SessionsTab(state: s))));
    expect(find.byType(SessionsTab), findsOneWidget);
  });
}
