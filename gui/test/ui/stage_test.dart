import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

import 'package:flutter/gestures.dart';
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
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import 'helpers.dart';

class _KeyboardPort extends FakeSessionPort {
  final keys = <KeyEvent>[];
  @override
  bool handleKeyEvent(Object sid, KeyEvent event) { keys.add(event); return true; }
}

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

    Future<void> openEmbedded(WidgetTester tester, {String app = 'Safari'}) async {
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5001, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.openOrSwitch('111', app, app);
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

    testWidgets('Linux image renders in the stage and picture owns keyboard focus', (tester) async {
      es.dispose();
      final keyboard = _KeyboardPort();
      port = keyboard;
      es = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: port);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.red, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(4, 4));
      picture.dispose();
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Fixture'));
      port.emit(WindowsEvent(1, [RemoteWindow(id: 1, parent: 0, kind: WindowKind.normal,
          title: 'Window', rect: const Rect.fromLTWH(0,0,400,300), titleBar: 0,
          resizable: false, focused: true, texture: null, visible: const Rect.fromLTWH(0,0,1,1),
          image: image, source: const Rect.fromLTWH(0,0,4,4))]));
      await tester.pump();
      expect(find.text('正在连接'), findsNothing);
      expect(find.byType(Texture), findsNothing);
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(keyboard.keys.map((e) => e.logicalKey), containsAll([LogicalKeyboardKey.escape, LogicalKeyboardKey.keyA]));
      expect(es.pictureFocused, 1);
      expect(port.calls.where((c) => c.$1 == 'mouse').length, 2);
      await tester.pumpWidget(const SizedBox());
      image!.dispose();
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

    testWidgets('detached placeholder shows the words and buttons', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester, app: 'Calculator');
      port.emit(const ReadyEvent(1, 'Calculator'));
      port.emit(WindowsEvent(1, [rw(5, 400, 328)]));
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
      port.emit(const DetachedEvent(1, true));
      await tester.pump();
      expect(find.byType(Texture), findsNothing);
      expect(es.pictureHole.value, isNull);
      expect(find.text('Calculator 在单独的窗口里 · mini · 局域网'), findsOneWidget);
      expect(find.text('输入'), findsOneWidget);
      // Records compare their maps by identity: match the call by its parts.
      void last(String method) {
        expect(port.calls.last.$1, method);
        expect(port.calls.last.$2, equals({'sid': 1}));
      }

      await tester.tap(find.text('切到窗口'));
      await tester.pump();
      last('raise_detached');
      expect(t.sent.where((m) => m['cmd'] == 'focus'), isEmpty);
      await tester.tap(find.text('放回主窗口'));
      await tester.pump();
      last('attach');
      await tester.tap(find.text('结束会话'));
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'close'), isEmpty);
      await tester.tap(find.text('再点一次确认'));
      await tester.pump();
      last('close');
      // The runner's answer to 放回: the picture is back.
      port.emit(const DetachedEvent(1, false, current: 5));
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
      expect(find.text('放回主窗口'), findsNothing);
    });

    Future<void> showWindow(WidgetTester tester, RemoteWindow w) async {
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [w]));
      await tester.pump();
      await tester.pump();
    }

    List<Map<String, Object?>> mouse() => port.calls.where((c) => c.$1 == 'mouse').map((c) => c.$2).toList();
    final border = find.byKey(const Key('picture-focus'));

    testWidgets('picture focus follows taps', (tester) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(MainWindow(
        state: es,
        monitor: ServiceMonitor(readToken: () async => null),
        control: null,
        configDir: tmp.path,
        fullscreen: _NoFullscreen(),
      )));
      final size = tester.getSize(find.byKey(const Key('stage')));
      await showWindow(tester, rw(7, size.width, size.height + 28));
      final pictureCenter = tester.getCenter(find.byType(Texture));
      await tester.tapAt(pictureCenter);
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'picture_focus').map((c) => c.$2), contains(equals({'sid': 1})));
      expect(es.pictureFocused, 1);
      expect(border, findsOneWidget);
      final topBarPoint = tester.getCenter(find.byType(TopBar));
      await tester.tapAt(topBarPoint);
      await tester.pump();
      expect(port.calls.last.$1, 'picture_focus');
      expect(port.calls.last.$2, equals({'sid': null}));
      expect(es.pictureFocused, isNull);
      expect(border, findsNothing);
    });

    testWidgets('a session that stops being current loses picture focus', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      await tester.tapAt(tester.getCenter(find.byType(Texture)));
      await tester.pump();
      expect(es.pictureFocused, 1);
      port.calls.clear();
      es.select('111/Other');
      await tester.pump();
      expect(es.pictureFocused, isNull);
      expect(port.calls.where((c) => c.$1 == 'picture_focus').single.$2, equals({'sid': null}));
    });

    testWidgets('down outside the picture is not sent; drag is clamped', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      // Content 400x200 on an 800x600 stage: fit is (0,100) 800x400, bands above and below.
      await showWindow(tester, rw(7, 400, 228));
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      await tester.tapAt(o + const Offset(400, 50));
      await tester.pump();
      expect(mouse(), isEmpty);
      expect(es.pictureFocused, isNull);
      final g = await tester.startGesture(o + const Offset(400, 300), kind: PointerDeviceKind.mouse);
      await g.moveTo(o + const Offset(850, 300));
      await g.up();
      await tester.pump();
      final m = mouse();
      expect(m.map((c) => c['kind']), ['down', 'drag', 'up']);
      expect(m[1]['x'], 400.0);
      expect(m[1]['y'], 28 + 100.0);
      expect(m[2]['x'], 400.0);
    });

    testWidgets('a press in the letterbox blurs the picture and sends nothing', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 228)); // fit (0,100) 800x400
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      await tester.tapAt(o + const Offset(400, 300));
      await tester.pump();
      expect(es.pictureFocused, 1);
      port.calls.clear();
      await tester.tapAt(o + const Offset(400, 50));
      await tester.pump();
      expect(es.pictureFocused, isNull);
      expect(port.calls.single.$1, 'picture_focus');
      expect(port.calls.single.$2, equals({'sid': null}));
      expect(border, findsNothing);
    });

    testWidgets('a picture with no area sends nothing', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 0, 28));
      await tester.tapAt(tester.getCenter(find.byKey(const Key('stage'))));
      await tester.pump();
      expect(mouse(), isEmpty);
    });

    testWidgets('right button sends right', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      final g = await tester.startGesture(tester.getCenter(find.byType(Texture)),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await g.up();
      await tester.pump();
      expect(mouse().map((c) => (c['kind'], c['button'])), [('down', 'right'), ('up', 'right')]);
    });

    testWidgets('mouse down sends A points and click count', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      // Content 400x300 on 800x600: twice as big, no bands.
      await showWindow(tester, rw(7, 400, 328));
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(o + const Offset(200, 100), timeStamp: Duration.zero);
      await g.up(timeStamp: const Duration(milliseconds: 50));
      await g.down(o + const Offset(201, 100), timeStamp: const Duration(milliseconds: 200));
      await g.up(timeStamp: const Duration(milliseconds: 250));
      await g.down(o + const Offset(201, 100), timeStamp: const Duration(seconds: 2));
      await g.up(timeStamp: const Duration(milliseconds: 2050));
      await tester.pump();
      final downs = mouse().where((c) => c['kind'] == 'down').toList();
      expect(downs[0], equals({'sid': 1, 'kind': 'down', 'button': 'left', 'window': 7, 'x': 100.0, 'y': 78.0, 'clicks': 1}));
      expect(downs.map((c) => c['clicks']), [1, 2, 1]);
      expect(mouse().where((c) => c['kind'] == 'up').map((c) => c['clicks']), [1, 2, 1]);
    });

    testWidgets('wheel and trackpad scroll reach A', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      await tester.sendEventToBinding(PointerScrollEvent(position: o + const Offset(200, 100), scrollDelta: const Offset(0, 40)));
      final pad = TestPointer(9, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.panZoomStart(o + const Offset(200, 100)));
      await tester.sendEventToBinding(pad.panZoomUpdate(o + const Offset(200, 100), pan: const Offset(0, 12)));
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();
      final s = port.calls.where((c) => c.$1 == 'scroll').map((c) => c.$2).toList();
      expect(s.length, 2);
      expect(s[0], equals({'sid': 1, 'window': 7, 'x': 100.0, 'y': 78.0, 'dx': 0.0, 'dy': -10.0}));
      expect(s[1]['dy'], 12.0);
      expect(mouse(), isEmpty);
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

    RemoteWindow popup(int id, WindowKind kind, {int parent = 0, int texture = 43}) => RemoteWindow(
          id: id,
          parent: parent,
          kind: kind,
          title: '',
          rect: const Rect.fromLTWH(50, 78, 40, 20),
          titleBar: 0,
          resizable: false,
          focused: false,
          texture: texture,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    Future<void> showWindows(WidgetTester tester, List<RemoteWindow> ws) async {
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, ws));
      await tester.pump();
      await tester.pump();
    }

    // Main content 400x300 at scale 2 on the 800x600 stage: the popup lands at (100,100) 80x40.
    testWidgets('popup over a missing parent draws over the current window', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [popup(9, WindowKind.sheet, parent: 99), rw(5, 400, 328)]);
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final tex = find.byType(Texture);
      expect(tex, findsNWidgets(2));
      final pop = tester.widgetList<Texture>(tex).toList().indexWhere((x) => x.textureId == 43);
      expect(tester.getRect(tex.at(pop)), const Rect.fromLTWH(100, 100, 80, 40).shift(o));
      // Drawn after (over) the main texture.
      expect(tester.widgetList<Texture>(tex).last.textureId, 43);
      // A press on it goes to the popup's window, in its own coordinates.
      await tester.tapAt(o + const Offset(120, 120));
      await tester.pump();
      final m = mouse().first;
      expect(m['window'], 9);
      expect(m['x'], 10.0);
      expect(m['y'], 10.0);
    });

    testWidgets('a popup of another window is not drawn', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [rw(5, 400, 328), rw(6, 400, 328), popup(9, WindowKind.sheet, parent: 6)]);
      expect(find.byType(Texture), findsOneWidget);
    });

    testWidgets('hover over a menu popup sends move, over a normal window not', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [popup(9, WindowKind.menu, parent: 5), rw(5, 400, 328)]);
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final mouseGesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouseGesture.addPointer(location: o + const Offset(500, 500));
      await tester.pump();
      expect(mouse(), isEmpty);
      await mouseGesture.moveTo(o + const Offset(120, 120));
      await tester.pump();
      expect(mouse().single['kind'], 'move');
      expect(mouse().single['window'], 9);
      expect(mouse().single['x'], 10.0);
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
