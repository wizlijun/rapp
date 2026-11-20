import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:rapp/llm_api.dart';
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
import 'platform_helpers.dart';

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

  test('tabOrder', () {
    expect(tabOrder(FirstLayer.device), [PanelTab.sessions, PanelTab.devices, PanelTab.projects, PanelTab.resources]);
    expect(tabOrder(FirstLayer.project), [PanelTab.sessions, PanelTab.projects, PanelTab.devices, PanelTab.resources]);
  });

  testWidgets('the dropdown shows 设备在前 by default and switches the tab order', (tester) async {
    await onPlatform(TargetPlatform.macOS, () async {
      await tester.pumpWidget(wrap(panel(), disableAnimations: true));
      expect(find.descendant(of: find.byKey(const Key('first-dropdown')), matching: find.text('设备在前')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('first-dropdown'))).height, 40);
      double x(String k) => tester.getTopLeft(find.byKey(Key(k))).dx;
      expect(x('tab-devices'), lessThan(x('tab-projects')));
      await tester.tap(find.byKey(const Key('first-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('项目在前').last);
      await tester.pumpAndSettle();
      expect(s.prefs.first, FirstLayer.project);
      expect(UiPrefs.load('${tmp.path}/devices/dev1').first, FirstLayer.project);
      expect(x('tab-projects'), lessThan(x('tab-devices')));
    });
  });

  testWidgets('reordering the tabs keeps the open tab', (tester) async {
    s.togglePanel(PanelTab.devices);
    await tester.pumpWidget(wrap(panel(), disableAnimations: true));
    s.setFirst(FirstLayer.project);
    await tester.pump();
    expect(s.panel, PanelTab.devices);
    expect(find.text('devices-body'), findsOneWidget);
  });

  testWidgets('theme dropdown lists the three films in order', (tester) async {
    await onPlatform(TargetPlatform.macOS, () async {
      await tester.pumpWidget(wrap(panel(), disableAnimations: true));
      expect(tester.getSize(find.byKey(const Key('theme-dropdown'))).height, 40);
      await tester.tap(find.byKey(const Key('theme-dropdown')));
      await tester.pumpAndSettle();
      final labels = [for (final th in themeOrder) themeLabel(th)];
      expect(labels, ['AVATAR', 'MATRIX', 'WESTWORLD']);
      final ys = [
        for (final l in labels)
          tester.getTopLeft(find.text(l).last).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      expect(ys.toSet().length, 3);
    });
  });

  testWidgets('全局设置 sits a step under the text size, on 40px rows', (tester) async {
    await onPlatform(TargetPlatform.macOS, () async {
      await tester.pumpWidget(MaterialApp(
        theme: themeDataFor(RappTheme.matrix, textSize: 13),
        home: Scaffold(body: Center(child: panel())),
      ));
      // A dropdown's own style used to replace the theme's: its label fell back to 14 and no font.
      for (final label in ['MATRIX', '设备在前', '启动时全屏', '网络差时自动省流量']) {
        final style = tester.widget<RichText>(find.descendant(of: find.text(label), matching: find.byType(RichText))).text.style!;
        expect((style.fontSize, style.fontFamily), (12.0, 'JetBrains Mono'), reason: label);
      }
      for (final key in ['theme-dropdown', 'first-dropdown']) {
        expect(tester.getSize(find.byKey(Key(key))).height, 40, reason: key);
      }
      for (final key in ['start-fullscreen', 'auto-save-traffic', 'settings-fold']) {
        expect(tester.getSize(find.byKey(Key(key))).height, 40, reason: key);
      }
      // The switch is scaled into a 38×24 box: measure the box, not the unscaled switch inside it.
      expect(tester.getSize(find.ancestor(of: find.byType(Switch).first, matching: find.byType(SizedBox)).first), const Size(38, 24));
    });
  });

  testWidgets('a settings dropdown keeps its small rows and goes semibold while open', (tester) async {
    await onPlatform(TargetPlatform.macOS, () async {
      await tester.pumpWidget(MaterialApp(
        theme: themeDataFor(RappTheme.matrix, textSize: 13, platform: TargetPlatform.macOS),
        home: Scaffold(body: Center(child: panel())),
      ));
      await tester.tap(find.byKey(const Key('theme-dropdown')));
      await tester.pumpAndSettle();
      final box = tester.renderObject<RenderParagraph>(find.text('MATRIX').first).text.style!;
      expect((box.fontSize, box.fontWeight), (12.0, FontWeight.w600));
      final row = tester.renderObject<RenderParagraph>(find.text('WESTWORLD')).text.style!;
      expect(row.fontSize, 12);
    });
  });

  testWidgets('on the iPad 全局设置 keeps 48px touch rows', (tester) async {
    await onPlatform(TargetPlatform.iOS, () async {
      await tester.pumpWidget(wrap(panel()));
      for (final key in ['start-fullscreen', 'auto-save-traffic', 'settings-fold']) {
        expect(tester.getSize(find.byKey(Key(key))).height, 48, reason: key);
      }
      expect(tester.getSize(find.byKey(const Key('theme-dropdown'))).height, 48);
    });
  });

  testWidgets('picking WESTWORLD changes prefs.theme', (tester) async {
    await tester.pumpWidget(wrap(panel(), disableAnimations: true));
    await tester.tap(find.byKey(const Key('theme-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WESTWORLD').last);
    await tester.pumpAndSettle();
    expect(s.prefs.theme, RappTheme.westworld);
    expect(UiPrefs.load('${tmp.path}/devices/dev1').theme, RappTheme.westworld);
  });

  testWidgets('start fullscreen switch saves', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    expect(find.text('启动时全屏'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-fullscreen')));
    await tester.pump();
    expect(s.prefs.startFullscreen, false);
    expect(UiPrefs.load('${tmp.path}/devices/dev1').startFullscreen, false);
  });

  testWidgets('auto save traffic switch is on by default and saves', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    expect(find.text('网络差时自动省流量'), findsOneWidget);
    expect(s.prefs.autoSaveTraffic, true);
    await tester.ensureVisible(find.byKey(const Key('auto-save-traffic')));
    await tester.tap(find.byKey(const Key('auto-save-traffic')));
    await tester.pump();
    expect(s.prefs.autoSaveTraffic, false);
    expect(UiPrefs.load('${tmp.path}/devices/dev1').autoSaveTraffic, false);
  });

  testWidgets('input history switch is on by default and saves', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    expect(find.text('记下写作面板发出去的话'), findsOneWidget);
    expect(find.text('存在数据目录的 inputs/ 里，会随 git 同步'), findsOneWidget);
    expect(s.prefs.inputHistory, true);
    await tester.ensureVisible(find.byKey(const Key('input-history')));
    await tester.tap(find.byKey(const Key('input-history')));
    await tester.pump();
    expect(s.prefs.inputHistory, false);
    expect(UiPrefs.load('${tmp.path}/devices/dev1').inputHistory, false);
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
      expect(find.text('已断开：远端关闭了 app'), findsOneWidget);
      expect(text(tester, 'session-status-111/c'), '');
      expect(find.bySemanticsLabel(RegExp('已断开：远端关闭了 app')), findsOneWidget);
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

  testWidgets('projects tab is half the window wide', (tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel(PanelTab.projects);
    await tester.pumpWidget(wrap(Stack(children: [
      Positioned(left: 0, top: 0, bottom: 0, child: panel()),
    ])));
    expect(tester.getSize(find.byType(SidePanel)).width, 597);
    expect(find.byType(ProjectsTab), findsOneWidget);
  });

  testWidgets('resources tab is the fourth tab and as wide as the sessions', (tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel();
    await tester.pumpWidget(wrap(Stack(children: [
      Positioned(left: 0, top: 0, bottom: 0, child: panel()),
    ])));
    expect(tester.getSize(find.byType(SidePanel)).width, 597);
    await tester.tap(find.byKey(const Key('tab-resources')));
    await tester.pump();
    expect(s.panel, PanelTab.resources);
    expect(tester.getSize(find.byType(SidePanel)).width, 597);
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

  testWidgets('every tab is half the window wide', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    for (final k in ['sessions', 'devices', 'projects', 'resources']) {
      await tester.tap(find.byKey(Key('tab-$k')));
      await tester.pump();
      expect(tester.getSize(find.byType(SidePanel)).width, 600, reason: k);
    }
  });

  testWidgets('全局设置 folds away, keeps the legend and totals, and the fold is saved', (tester) async {
    await tester.pumpWidget(wrap(panel()));
    expect(find.byKey(const Key('theme-dropdown')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-fold')));
    await tester.pump();
    for (final k in ['theme-dropdown', 'first-dropdown', 'start-fullscreen', 'auto-save-traffic', 'input-history']) {
      expect(find.byKey(Key(k)), findsNothing, reason: k);
    }
    expect(find.byKey(const Key('legend')), findsOneWidget);
    expect(find.byKey(const Key('total-sessions')), findsOneWidget);
    expect(s.prefs.settingsFolded, isTrue);
    expect(UiPrefs.load('${tmp.path}/devices/dev1').settingsFolded, isTrue);
    await tester.tap(find.byKey(const Key('settings-fold')));
    await tester.pump();
    expect(find.byKey(const Key('theme-dropdown')), findsOneWidget);
    expect(UiPrefs.load('${tmp.path}/devices/dev1').settingsFolded, isFalse);
  });

  testWidgets('LLM 接入点: typed values save to local/llm.json on 测试, and 测试 reports the gateway', (tester) async {
    final probed = <LlmEndpoint>[];
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), llmApi: _FakeLlm(probed));
    await tester.pumpWidget(wrap(panel()));
    await tester.enterText(find.byKey(const Key('llm-url')), 'localhost:28001');
    await tester.enterText(find.byKey(const Key('llm-key')), 'wrong');
    await tester.ensureVisible(find.byKey(const Key('llm-test')));
    await tester.tap(find.byKey(const Key('llm-test')));
    await tester.pump();
    expect(find.text('key 不对'), findsOneWidget);
    expect(probed.single, const LlmEndpoint(url: 'localhost:28001', key: 'wrong'));
    expect(LlmEndpoint.load('${tmp.path}/local').key, 'wrong');

    await tester.enterText(find.byKey(const Key('llm-key')), 'rl-k');
    await tester.pump();
    expect(find.byKey(const Key('llm-status')), findsNothing, reason: 'an edit clears the old result');
    await tester.tap(find.byKey(const Key('llm-test')));
    await tester.pump();
    expect(find.textContaining('已连通'), findsOneWidget);
    expect(find.textContaining('dictation'), findsOneWidget);
    expect(s.llm, const LlmEndpoint(url: 'localhost:28001', key: 'rl-k'));
    expect(LlmEndpoint.load('${tmp.path}/local'), s.llm);
  });

  testWidgets('LLM 接入点: a field left by focus saves, and a saved endpoint shows on open', (tester) async {
    const LlmEndpoint(url: 'localhost:28001', key: 'rl-old').save('${tmp.path}/local');
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
    await tester.pumpWidget(wrap(panel()));
    expect(find.text('localhost:28001'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('llm-url')), 'localhost:28002');
    await tester.showKeyboard(find.byKey(const Key('llm-key')));
    await tester.pump();
    expect(LlmEndpoint.load('${tmp.path}/local').url, 'localhost:28002');
    await tester.enterText(find.byKey(const Key('llm-key')), 'rl-new');
    await tester.ensureVisible(find.byKey(const Key('settings-fold')));
    await tester.tap(find.byKey(const Key('settings-fold'))); // folds with the key still being typed
    await tester.pump();
    expect(s.prefs.settingsFolded, isTrue);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(s.llm.key, 'rl-new');
  });

  testWidgets('a saved fold opens folded', (tester) async {
    s.prefs.settingsFolded = true;
    await tester.pumpWidget(wrap(panel()));
    expect(find.byKey(const Key('settings-fold')), findsOneWidget);
    expect(find.byKey(const Key('theme-dropdown')), findsNothing);
  });

  testWidgets('a session in two projects shows in both groups', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

  testWidgets('tapping a project group switches to it; 未归项目的 is not tappable and has no count', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final p = s.createProject('写周报')!;
    s.addMember(p.id, const AppRef('111', 'Safari', 'Safari'));
    s.togglePanel();
    await tester.pumpWidget(wrap(panel()));
    await open(tester, 1, 'Safari');
    await open(tester, 2, 'Mail');
    await tester.tap(find.byKey(const Key('group-project')));
    await tester.pump();
    expect(find.byKey(Key('group-${p.id}')), findsOneWidget);
    expect(find.text('未归项目的'), findsOneWidget);
    expect(tester.getSize(find.byKey(Key('group-${p.id}'))).height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(Key('group-${p.id}')));
    await tester.pump();
    expect(s.currentProject, p.id);
    expect(s.currentKey, '111/Safari');
    expect(s.cue, '');
    // Not a button, no count: the title is plain text.
    expect(find.ancestor(of: find.text('未归项目的'), matching: find.byType(InkWell)), findsNothing);
    expect(find.textContaining('未归项目的 '), findsNothing);
    expect(find.textContaining('未归项目的（'), findsNothing);
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
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

  testWidgets('all four navigation labels remain readable with Linux desktop text scaling', (tester) async {
    await tester.pumpWidget(wrap(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600), textScaler: TextScaler.linear(1.2222)),
      child: panel(),
    )));
    for (final k in ['sessions', 'devices', 'projects', 'resources']) {
      final label = find.descendant(of: find.byKey(Key('tab-$k')), matching: find.byType(RichText));
      final paragraph = tester.renderObject<RenderParagraph>(label);
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'tab-$k hides its label at desktop text scale');
    }
    expect(tester.takeException(), isNull);
  });

  for (final theme in RappTheme.values) {
    for (final scale in [1.2222, 1.5, 2.0]) {
      for (final width in [360.0, 800.0]) {
        testWidgets('navigation labels fit ${theme.name} at $scale text scale and $width width', (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 700));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(wrap(MediaQuery(
            data: MediaQueryData(size: Size(width, 700), textScaler: TextScaler.linear(scale)),
            child: panel(),
          ), theme: theme));
          for (final k in ['sessions', 'devices', 'projects', 'resources']) {
            final tab = find.byKey(Key('tab-$k'));
            final paragraph = tester.renderObject<RenderParagraph>(find.descendant(of: tab, matching: find.byType(RichText)));
            expect(paragraph.didExceedMaxLines, isFalse, reason: 'tab-$k label must remain complete');
            final bounds = tester.getRect(tab);
            expect(bounds.width, greaterThanOrEqualTo(48));
            expect(bounds.height, greaterThanOrEqualTo(48));
            expect(bounds.right, lessThanOrEqualTo(width));
          }
          final first = tester.getRect(find.byKey(const Key('tab-sessions')));
          final last = tester.getRect(find.byKey(const Key('tab-resources')));
          if (width == 360 && scale == 2) {
            expect(last.top, greaterThan(first.top), reason: 'whole tabs should wrap in the constrained window');
          }
          await tester.tap(find.byKey(const Key('tab-devices')));
          await tester.pump();
          expect(find.text('devices-body'), findsOneWidget);
          await tester.tap(find.byKey(const Key('tab-sessions')));
          await tester.pump();
          expect(s.panel, PanelTab.sessions);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('wrapped navigation and footer remain reachable at the minimum window height', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // The app top bar occupies 56px of the window's minimum 260px height.
    await tester.pumpWidget(wrap(MediaQuery(
      data: const MediaQueryData(size: Size(360, 260), textScaler: TextScaler.linear(2)),
      child: SizedBox(height: 204, child: panel()),
    )));
    for (final k in ['sessions', 'devices', 'projects', 'resources']) {
      final tab = find.byKey(Key('tab-$k'));
      await tester.ensureVisible(tab);
      final p = tester.renderObject<RenderParagraph>(find.descendant(of: tab, matching: find.byType(RichText)));
      expect(p.didExceedMaxLines, isFalse);
    }
    await tester.ensureVisible(find.byKey(const Key('theme-dropdown')));
    expect(find.byKey(const Key('theme-dropdown')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing across the short-panel layout preserves an in-progress editor', (tester) async {
    s.togglePanel(PanelTab.devices);
    Future<void> sized(double height) => tester.pumpWidget(wrap(MediaQuery(
      data: MediaQueryData(size: Size(360, height), textScaler: const TextScaler.linear(2)),
      child: SizedBox(width: 360, height: height, child: panel(devices: const TextField(key: Key('draft')))),
    )));
    await sized(600);
    await tester.enterText(find.byKey(const Key('draft')), 'unfinished device address');
    await sized(204);
    expect(find.text('unfinished device address'), findsOneWidget);
    await sized(600);
    expect(find.text('unfinished device address'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('panelWidth: half the window', () {
    expect(panelWidth(1194), 597);
    expect(panelWidth(744), 372);
  });
}

class _FakeLlm extends LlmApi {
  _FakeLlm(this.probed);
  final List<LlmEndpoint> probed;

  @override
  Future<LlmProbe> probe(LlmEndpoint e) async {
    probed.add(e);
    return e.key == 'rl-k' ? const LlmProbeOk(['dictation'], Duration(milliseconds: 12)) : const LlmProbeFailed('key 不对');
  }
}
