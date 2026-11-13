import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/traffic_label.dart' show formatRate;
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/session_model.dart';
import 'package:rapp/ui/side_panel.dart';
import 'package:rapp/ui/projects_tab.dart';
import 'package:rapp/ui/resources_tab.dart';
import 'package:rapp/ui/sessions_tab.dart';
import 'package:rapp/ui/workspace_store.dart';
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
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
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
    expect(UiPrefs.load('${tmp.path}/devices/dev1').theme, RappTheme.ironMan);
  });

  testWidgets('start fullscreen switch saves', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    expect(find.text('启动时全屏'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-fullscreen')));
    await tester.pump();
    expect(s.prefs.startFullscreen, false);
    expect(UiPrefs.load('${tmp.path}/devices/dev1').startFullscreen, false);
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

  testWidgets('non-embedded rows get no status text (R22)', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    t.onSend = (_) {}; // the open never answers: a pending row, lamp connecting
    s.openOrSwitch('111', 'Safari', 'Safari');
    await tester.runAsync(flush);
    await tester.pump();
    expect(find.byKey(const Key('session-111/Safari')), findsOneWidget);
    expect(find.byKey(const Key('session-status-111/Safari')), findsNothing);
  });

  group('embedded rows', () {
    late FakeSessionPort port;
    late MainState es;

    setUp(() {
      port = FakeSessionPort();
      es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
      var n = 0;
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          final sid = ++n;
          t.emit({
            'event': 'opened', 'sid': sid, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            'port': 5000 + sid, 'token': 'tk', 'req': m['req'],
          });
        }
      };
    });
    tearDown(() => es.dispose());

    Future<void> openThree(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        for (final a in ['a', 'b', 'c']) {
          es.openOrSwitch('111', a, a.toUpperCase());
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        }
      });
      await tester.pump();
    }

    String? text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data;

    testWidgets('session rows show rate, idle and reason', (tester) async {
      await tester.pumpWidget(wrap(SidePanel(state: es, devicesTab: const Text('d'))));
      await openThree(tester);
      port.emit(const TrafficEvent(1, 48000, 1));
      port.emit(const TrafficEvent(2, 0, 1));
      for (var i = 0; i < 10; i++) {
        port.emit(const TrafficEvent(2, 0, 0));
      }
      port.emit(const TrafficEvent(3, 100, 1));
      port.emit(const DisconnectedEvent(3, 'host says: Calculator quit'));
      await tester.pump();
      expect(text(tester, 'session-status-111/a'), '48.0 KB/s');
      expect(text(tester, 'session-status-111/b'), '空闲');
      expect(find.text('已断开：A 端关闭了 app'), findsOneWidget);
      expect(text(tester, 'session-status-111/c'), '');
      expect(find.bySemanticsLabel(RegExp('已断开：A 端关闭了 app')), findsOneWidget);
      // The state word is said once (M-4).
      expect(find.bySemanticsLabel(RegExp(r'^B，空闲(，局域网)?$')), findsOneWidget);
    });

    testWidgets('total traffic sums live sessions', (tester) async {
      await tester.pumpWidget(wrap(SidePanel(state: es, devicesTab: const Text('d'))));
      await openThree(tester);
      port.emit(const TrafficEvent(1, 3000, 1));
      port.emit(const TrafficEvent(2, 2000, 1));
      port.emit(const TrafficEvent(3, 9000, 1));
      port.emit(const DisconnectedEvent(3, 'connection closed'));
      await tester.pump();
      expect(text(tester, 'total-traffic'), formatRate(5000));
      expect(text(tester, 'total-traffic'), '5.0 KB/s');
      for (final sid in [1, 2]) {
        port.emit(DisconnectedEvent(sid, 'connection closed'));
      }
      await tester.pump();
      final z = tester.widget<Text>(find.byKey(const Key('total-traffic')));
      expect(z.data, '0 KB/s');
      expect(z.style!.color, tokensFor(RappTheme.matrix).muted);
    });
  });

  testWidgets('tabs switch panel and close button closes', (tester) async {
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await tester.tap(find.byKey(const Key('tab-devices')));
    await tester.pump();
    expect(s.panel, PanelTab.devices);
    expect(find.text('devices-body'), findsOneWidget);
    expect(find.byTooltip('收起面板'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tab-projects')));
    await tester.pump();
    expect(s.panel, PanelTab.projects);
    await tester.tap(find.byKey(const Key('panel-close')));
    await tester.pump();
    expect(s.panel, isNull);
  });

  testWidgets('projects tab is 720 wide on a big window', (tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel(PanelTab.projects);
    await tester.pumpWidget(wrap(Stack(children: [
      Positioned(left: 0, top: 0, bottom: 0, child: panel()),
    ])));
    expect(tester.getSize(find.byType(SidePanel)).width, 720);
    expect(find.byType(ProjectsTab), findsOneWidget);
  });

  testWidgets('resources tab is the fourth tab and 720 wide', (tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel();
    await tester.pumpWidget(wrap(Stack(children: [
      Positioned(left: 0, top: 0, bottom: 0, child: panel()),
    ])));
    expect(tester.getSize(find.byType(SidePanel)).width, 330);
    await tester.tap(find.byKey(const Key('tab-resources')));
    await tester.pump();
    expect(s.panel, PanelTab.resources);
    expect(tester.getSize(find.byType(SidePanel)).width, 720);
    expect(find.byType(ResourcesTab), findsOneWidget);
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

  testWidgets('a session in two projects shows in both groups', (tester) async {
    const safari = AppRef('111', 'com.apple.Safari', 'Safari');
    s.addMember(s.createProject('写周报')!.id, safari);
    s.addMember(s.createProject('发版')!.id, safari);
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'com.apple.Safari');
    await tester.tap(find.byKey(const Key('group-project')));
    await tester.pump();
    final rows = find.byKey(const Key('session-111/com.apple.Safari'));
    expect(rows, findsNWidgets(2));
    await tester.tap(rows.last);
    await tester.pump();
    expect(s.currentKey, '111/com.apple.Safari');
    expect(s.panel, isNull);
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
    await tester.tap(find.byKey(const Key('group-project')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.takeException(), isNull);
    s.togglePanel(PanelTab.devices);
    await tester.pump();
    expect(tester.takeException(), isNull);
    final p = s.createProject('写周报')!;
    s.addMember(p.id, const AppRef('111', 'Safari', 'Safari'));
    s.togglePanel(PanelTab.projects);
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
    // devices/ is a file, so devices/dev1/ cannot be created.
    File('${tmp.path}/devices').writeAsStringSync('x');
    final bad = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
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

  testWidgets('idle favorites list last with a not-opened lamp', (tester) async {
    s.toggleFavorite('111', 'com.apple.Notes', 'Notes');
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'com.apple.Safari');
    expect(find.byKey(const Key('group-favorites')), findsOneWidget);
    final row = find.byKey(const Key('favorite-111/com.apple.Notes'));
    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(find.byKey(const Key('session-111/com.apple.Safari'))).dy));
    final lamp = tester.widget<StatusLamp>(find.descendant(of: row, matching: find.byType(StatusLamp)));
    expect(lamp.kind, Lamp.notOpened);
    expect(tester.getSize(row).height, 60);
    expect(find.descendant(of: row, matching: find.text('mini')), findsOneWidget);
  });

  testWidgets('favorites show under the empty state', (tester) async {
    s.toggleFavorite('111', 'com.apple.Notes', 'Notes');
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    final empty = find.text('没有打开的会话。到「设备」里打开一个 app。');
    final row = find.byKey(const Key('favorite-111/com.apple.Notes'));
    expect(empty, findsOneWidget);
    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(empty).dy));
  });

  testWidgets('tapping a favorite opens it and closes the panel', (tester) async {
    s.toggleFavorite('111', 'com.apple.Notes', 'Notes');
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await tester.tap(find.byKey(const Key('favorite-111/com.apple.Notes')));
    await tester.runAsync(flush);
    await tester.pump();
    expect(t.sent.last, containsPair('cmd', 'open'));
    expect(t.sent.last, containsPair('id', '111'));
    expect(t.sent.last, containsPair('app', 'com.apple.Notes'));
    expect(s.panel, isNull);
  });

  testWidgets('an open favorite leaves the 常用 group and comes back when it ends', (tester) async {
    s.toggleFavorite('111', 'com.apple.Notes', 'Notes');
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'com.apple.Notes');
    expect(find.byKey(const Key('favorite-111/com.apple.Notes')), findsNothing);
    t.emit({'event': 'closed', 'sid': 1});
    await tester.runAsync(flush);
    await tester.pump();
    expect(find.byKey(const Key('favorite-111/com.apple.Notes')), findsOneWidget);
  });

  testWidgets('step skips favorites', (tester) async {
    s.toggleFavorite('111', 'com.apple.Notes', 'Notes');
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'com.apple.Safari');
    s.step(1);
    expect(s.currentKey, '111/com.apple.Safari');
  });

  testWidgets('tab titles are not cut off in the narrow sessions panel', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    for (final k in ['sessions', 'devices', 'projects', 'resources']) {
      final text = find.descendant(of: find.byKey(Key('tab-$k')), matching: find.byType(RichText));
      final p = tester.renderObject<RenderParagraph>(text);
      expect(p.didExceedMaxLines, isFalse, reason: 'tab-$k is ellipsized');
    }
  });
}
