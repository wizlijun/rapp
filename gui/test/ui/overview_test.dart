import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/traffic_label.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late FakeSessionPort port;
  late MainState s;
  late Directory tmp;
  var hosts = <Map<String, String>>[];
  var sid = 0;
  var offline = <String>{};

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('overview_test');
    hosts = [
      {'id': 'm1', 'name': 'mini'},
    ];
    sid = 0;
    offline = {};
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Builds the state, opens [apps] (`id/app`) in order and shows the overview.
  Future<void> boot(WidgetTester tester, {List<String> apps = const [], bool embed = true}) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    t = FakeTransport();
    port = FakeSessionPort();
    t.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        t.emit({'event': 'hosts', 'req': m['req'], 'hosts': hosts});
      } else if (m['cmd'] == 'apps') {
        t.emit(offline.contains(m['id'])
            ? {'event': 'error', 'req': m['req'], 'error': 'connect timed out'}
            : {'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan', 'apps': []});
      } else if (m['cmd'] == 'open') {
        t.emit({
          'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan',
          if (m['embed'] == true) ...{'port': 5000 + sid, 'token': 'tk'},
          'req': m['req'],
        });
      }
    };
    final epoch = DateTime(2026, 11, 13, 12);
    s = MainState(
      hub: HubClient(t),
      configDir: tmp.path,
      prefs: UiPrefs(),
      port: embed ? port : null,
      clock: () => epoch,
    );
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

  Future<void> show(WidgetTester tester) async {
    s.toggleOverview();
    await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s))));
    await tester.pump();
  }

  void frame(int sidN, {int bytes = 0}) {
    port.emit(ReadyEvent(sidN, 'x'));
    port.emit(TrafficEvent(sidN, bytes, 1));
  }

  Finder inside(String key, Finder f) => find.descendant(of: find.byKey(Key(key)), matching: f);

  Text numberOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)).first);

  BoxDecoration deco(WidgetTester tester, String key) =>
      tester.widget<Container>(find.byKey(Key(key))).decoration! as BoxDecoration;

  RappTokens tokens(WidgetTester tester) => RappTokens.of(tester.element(find.byType(Overview)));

  testWidgets('two sessions, one disconnected: counts and blocks', (tester) async {
    await boot(tester, apps: ['m1/a', 'm1/b']);
    frame(1, bytes: 48000);
    port.emit(const DisconnectedEvent(2, 'connection closed'));
    await show(tester);
    expect(numberOf(tester, 'count-active').data, '1');
    expect(numberOf(tester, 'count-disconnected').data, '1');
    expect(find.byKey(const Key('block-m1/a')), findsOneWidget);
    expect(find.byKey(const Key('block-m1/b')), findsOneWidget);
    expect(inside('block-m1/a', find.text('48.0 KB/s')), findsOneWidget);
    final reason = s.entries.firstWhere((e) => e.app == 'b').reason!;
    expect(inside('block-m1/b', find.text('已断开：$reason')), findsOneWidget);
  });

  testWidgets('zero counts are muted', (tester) async {
    await boot(tester, apps: ['m1/a']);
    frame(1, bytes: 1000);
    await show(tester);
    expect(numberOf(tester, 'count-idle').style!.color, tokens(tester).muted);
    expect(numberOf(tester, 'count-active').style!.color, tokens(tester).text);
  });

  testWidgets('a nonzero disconnected count is accent with backdrop', (tester) async {
    await boot(tester, apps: ['m1/a', 'm1/b']);
    port.emit(const DisconnectedEvent(2, 'connection closed'));
    await show(tester);
    final tk = tokens(tester);
    expect(deco(tester, 'frame-count-disconnected').border!.top.color, tk.accent);
    expect(
      inside('count-disconnected', find.byType(DecoratedBox))
          .evaluate()
          .any((e) => (e.widget as DecoratedBox).decoration is! BoxDecoration),
      isTrue,
    );
    expect(deco(tester, 'frame-count-waiting').border!.top.color, tk.line);
    expect(deco(tester, 'frame-count-active').border!.top.color, tk.line);
  });

  testWidgets('the current block is outlined in text colour, not accent', (tester) async {
    await boot(tester, apps: ['m1/a', 'm1/b']);
    frame(1);
    frame(2);
    s.select('m1/b');
    await show(tester);
    final tk = tokens(tester);
    final cur = deco(tester, 'frame-block-m1/b').border!.top;
    expect((cur.color, cur.width), (tk.text, 2.0));
    final other = deco(tester, 'frame-block-m1/a').border!.top;
    expect((other.color, other.width), (tk.line, 1.0));
  });

  testWidgets('one click on a block enters it', (tester) async {
    await boot(tester, apps: ['m1/a', 'm1/b']);
    frame(1);
    frame(2);
    s.select('m1/a');
    await show(tester);
    expect(s.overview, true);
    await tester.tap(find.byKey(const Key('block-m1/b')));
    await tester.pump();
    expect(s.overview, false);
    expect(s.currentKey, 'm1/b');
  });

  testWidgets('windows count shows from two', (tester) async {
    await boot(tester, apps: ['m1/a']);
    frame(1);
    RemoteWindow rw(int id) => RemoteWindow(
          id: id,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w$id',
          rect: const Rect.fromLTWH(0, 0, 400, 328),
          titleBar: 28,
          resizable: true,
          focused: false,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );
    port.emit(WindowsEvent(1, [rw(1)]));
    await show(tester);
    expect(find.textContaining('个窗口'), findsNothing);
    port.emit(WindowsEvent(1, [rw(1), rw(2)]));
    await tester.pump();
    expect(inside('block-m1/a', find.text('2 个窗口')), findsOneWidget);
  });

  testWidgets('columns follow the device panel order; offline is grey', (tester) async {
    hosts = [
      {'id': 'm1', 'name': 'mini'},
      {'id': 'm2', 'name': 'air'},
    ];
    offline = {'m2'};
    await boot(tester, apps: ['m1/a']);
    await show(tester);
    double x(String k) => tester.getTopLeft(find.byKey(Key(k))).dx;
    expect(x('column-local'), lessThan(x('column-m1')));
    expect(x('column-m1'), lessThan(x('column-m2')));
    final title = tester.widget<Text>(inside('column-m2', find.text('air')));
    expect(title.style!.color, tokens(tester).muted);
    expect(inside('column-m2', find.text('离线')), findsOneWidget);
  });

  testWidgets('an empty host column offers 打开 app', (tester) async {
    await boot(tester, apps: []);
    await show(tester);
    expect(inside('column-local', find.text('没有打开的 app')), findsOneWidget);
    expect(inside('column-local', find.text('打开 app')), findsNothing);
    expect(inside('column-m1', find.text('没有打开的 app')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-app-m1')));
    await tester.pump();
    expect(s.panel, PanelTab.devices);
    expect(s.deviceTab, 'm1');
  });

  testWidgets('count taps', (tester) async {
    await boot(tester, apps: ['m1/a']);
    port.emit(const DisconnectedEvent(1, 'connection closed'));
    await show(tester);
    await tester.tap(find.byKey(const Key('count-disconnected')));
    await tester.pump();
    expect(s.corner, Corner.needs);
    s.closeCorner();
    await tester.tap(find.byKey(const Key('count-online')));
    await tester.pump();
    expect(s.panel, PanelTab.devices);
    expect(inside('count-active', find.byType(InkWell)), findsNothing);
    expect(find.ancestor(of: find.byKey(const Key('count-active')), matching: find.byType(InkWell)), findsNothing);
  });

  testWidgets('device online shows online/total without 本机', (tester) async {
    hosts = [
      {'id': 'm1', 'name': 'mini'},
      {'id': 'm2', 'name': 'air'},
    ];
    offline = {'m2'};
    await boot(tester);
    await show(tester);
    expect(inside('count-online', find.text('1/2')), findsOneWidget);
  });

  testWidgets('traffic cell uses formatRate and — without embedding', (tester) async {
    await boot(tester, apps: ['m1/a']);
    frame(1, bytes: 48000);
    await show(tester);
    expect(inside('count-traffic', find.text(formatRate(s.totalBytesPerSecond))), findsOneWidget);
    expect(inside('count-traffic', find.byType(LevelBars)), findsOneWidget);
    s.dispose();
    tmp.createSync();
    await boot(tester, embed: false);
    await show(tester);
    expect(inside('count-traffic', find.text('—')), findsOneWidget);
  });

  testWidgets('four columns of four fit without scrolling at 1194x834', (tester) async {
    hosts = [for (var i = 1; i <= 4; i++) {'id': 'm$i', 'name': 'mac$i'}];
    await boot(tester, apps: [
      for (var i = 1; i <= 4; i++)
        for (var j = 0; j < 4; j++) 'm$i/app$j',
    ]);
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 834 - 56, child: Overview(state: s))));
    s.toggleOverview();
    await tester.pump();
    expect(s.entries.length, 16);
    final scrollables = find.descendant(of: find.byKey(const Key('wall')), matching: find.byType(Scrollable));
    expect(scrollables, findsWidgets);
    for (final e in scrollables.evaluate()) {
      expect((e as StatefulElement).state is ScrollableState, isTrue);
      expect((e.state as ScrollableState).position.maxScrollExtent, 0);
    }
    for (final e in s.entries) {
      expect(find.byKey(Key('block-${e.key}')), findsOneWidget);
    }
  });

  testWidgets('blocks and buttons are at least 48 tall', (tester) async {
    hosts = [
      {'id': 'm1', 'name': 'mini'},
      {'id': 'm2', 'name': 'air'},
    ];
    await boot(tester, apps: ['m1/a']);
    port.emit(const DisconnectedEvent(1, 'connection closed'));
    await show(tester);
    for (final k in ['block-m1/a', 'open-app-m2', 'count-disconnected', 'count-online']) {
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48), reason: k);
    }
  });

  testWidgets('count lamps are still', (tester) async {
    await boot(tester, apps: ['m1/a']);
    await show(tester);
    final lamps = inside('counts', find.byType(StatusLamp));
    expect(lamps, findsWidgets);
    for (final e in lamps.evaluate()) {
      expect(MediaQuery.disableAnimationsOf(e), isTrue);
    }
  });
}
