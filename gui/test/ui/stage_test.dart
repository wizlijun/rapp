import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/fullscreen.dart';
import 'package:rapp/ui/main_window.dart';
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
      if (th == RappTheme.ironMan) {
        // 设计语言"全屏叠"：网格盖在内容（顶栏、面板）上面，不在下面。
        final stack = tester.widget<Stack>(
            find.descendant(of: find.byType(Backdrop), matching: find.byType(Stack)).first);
        expect(stack.children.last, isA<Positioned>());
        expect((stack.children.last as Positioned).child, isA<IgnorePointer>());
      }
      if (th != RappTheme.westworld) {
        expect(find.descendant(of: find.byType(Backdrop), matching: find.byType(IgnorePointer)),
            findsWidgets);
      }
    });
  }

  group('embedded', () {
    late FakeSessionPort port;
    late MainState es;

    RemoteWindow rw(int id, double w, double h, {int? texture = 42}) => RemoteWindow(
          id: id,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w$id',
          rect: Rect.fromLTWH(0, 0, w, h),
          titleBar: 28,
          resizable: true,
          focused: true,
          texture: texture,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    Future<void> openEmbedded(WidgetTester tester) async {
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5001, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
    }

    setUp(() {
      port = FakeSessionPort();
      es = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: port);
    });
    tearDown(() => es.dispose());

    Widget embedded({RappTheme theme = RappTheme.matrix}) => SizedBox(
          width: 800,
          height: 600,
          child: Backdrop(theme: theme, hole: es.pictureHole, child: Stage(state: es)),
        );

    testWidgets('stage shows connecting, then the texture', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester);
      expect(find.text('正在连接'), findsOneWidget);
      port.emit(const ReadyEvent(1, 'Safari'));
      await tester.pump();
      expect(find.text('正在连接'), findsOneWidget);
      port.emit(WindowsEvent(1, [rw(5, 400, 328)]));
      await tester.pump();
      expect(find.text('正在连接'), findsNothing);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
    });

    testWidgets('stage size goes to A once the window settles', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 400, 328)]));
      await tester.pump();
      final r = port.calls.where((c) => c.$1 == 'resize').toList();
      expect(r.length, 1);
      expect(r.single.$2, equals({'sid': 1, 'window': 5, 'w': 800, 'h': 600}));
    });

    testWidgets('IRON MAN grid leaves the picture uncovered', (tester) async {
      await tester.pumpWidget(wrap(embedded(theme: RappTheme.ironMan), theme: RappTheme.ironMan));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 400, 328)]));
      await tester.pump();
      await tester.pump();
      Rect? hole() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<HoloGrid>()
          .single
          .hole;
      final origin = tester.getTopLeft(find.byType(Backdrop));
      expect(hole(), tester.getRect(find.byType(Texture)).shift(-origin));
      expect(es.pictureHole.value, isNotNull);
      port.emit(const ClosedEvent(1, 'quit'));
      await tester.pump();
      await tester.pump();
      expect(es.pictureHole.value, isNull);
      expect(hole(), isNull);
    });

    testWidgets('overlays never resize', (tester) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final monitor = ServiceMonitor(readToken: () async => null);
      await tester.pumpWidget(wrap(MainWindow(
        state: es,
        monitor: monitor,
        control: null,
        configDir: tmp.path,
        fullscreen: _NoFullscreen(),
      )));
      await openEmbedded(tester);
      final size = tester.getSize(find.byKey(const Key('stage')));
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, size.width, size.height + 28)]));
      await tester.pump();
      port.calls.removeWhere((c) => c.$1 == 'resize');
      await tester.tap(find.byTooltip('面板')); // left panel opens...
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('面板')); // ...and closes
      // Task 10 adds Key('traffic'): tap it here too, for the stream menu.
      await tester.pump(const Duration(seconds: 1));
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    });
  });
}

class _NoFullscreen implements FullscreenControl {
  @override
  Stream<bool> get changes => const Stream.empty();
  @override
  Future<bool> isFullScreen() async => false;
  @override
  Future<void> setFullScreen(bool on) async {}
}
