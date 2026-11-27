import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/form.dart';
import 'package:rapp/phone/landing.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import '../ui/main_window_test.dart' show FakeFullscreen;

class CountState extends MainState {
  CountState({required super.hub, required super.data, required super.prefs, super.port, super.termPort});
  final phoneCalls = <({bool form, bool inSession})>[];
  @override
  void setPhone({required bool form, bool inSession = false}) {
    phoneCalls.add((form: form, inSession: inSession));
    super.setPhone(form: form, inSession: inSession);
  }
}

void main() {
  late Directory tmp;
  late FakeTransport t;
  late CountState s;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('form_test');
    t = FakeTransport();
    s = CountState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs());
  });
  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  const settle = Duration(milliseconds: 250);
  const padKey = Key('pad'), phoneKey = Key('phone');

  void size(WidgetTester tester, double w, double h) {
    tester.view.physicalSize = Size(w, h);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget host({
    Widget? pad,
    Widget? phone,
    void Function(({PhoneScreen screen, String? cameFrom}))? onFold,
    String? Function()? entered,
    int Function()? waiting,
    bool Function(String)? isWaiting,
    MainState? state,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: FormSwitch(
            state: state ?? s,
            settle: settle,
            pad: (_) => pad ?? const Text('pad', key: padKey),
            phone: (_) => phone ?? const Text('phone', key: phoneKey),
            onFold: onFold,
            entered: entered,
            waiting: waiting,
            isWaiting: isWaiting,
          ),
        ),
      );

  testWidgets('first frame picks form at once', (tester) async {
    size(tester, 599, 800);
    await tester.pumpWidget(host());
    expect(find.byKey(phoneKey), findsOneWidget);
    expect(find.byKey(padKey), findsNothing);
    expect(s.phoneForm, isTrue);
    await tester.pumpWidget(const SizedBox());
    size(tester, 600, 800);
    final other = CountState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs());
    addTearDown(other.dispose);
    await tester.pumpWidget(host(state: other));
    expect(find.byKey(padKey), findsOneWidget);
    expect(find.byKey(phoneKey), findsNothing);
  });

  testWidgets('first frame in phone form under a listening root', (tester) async {
    size(tester, 390, 844);
    final got = <({PhoneScreen screen, String? cameFrom})>[];
    await tester.pumpWidget(ListenableBuilder(
      listenable: s,
      builder: (_, _) => MaterialApp(
        home: FormSwitch(
          state: s,
          settle: settle,
          pad: (_) => const Text('pad', key: padKey),
          phone: (_) => const Text('phone', key: phoneKey),
          onFold: got.add,
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byKey(phoneKey), findsOneWidget);
    await tester.pump();
    expect(s.phoneForm, isTrue);
    expect(got.length, 1);
  });

  testWidgets('drag across 600 flips once after settle', (tester) async {
    size(tester, 700, 800);
    await tester.pumpWidget(host());
    for (var i = 0; i < 20; i++) {
      tester.view.physicalSize = Size(i.isEven ? 590 : 610, 800);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(padKey), findsOneWidget);
    }
    tester.view.physicalSize = const Size(590, 800);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(padKey), findsOneWidget);
    await tester.pump(settle - const Duration(milliseconds: 50));
    expect(find.byKey(padKey), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(); // the frame between the two shells (F9)
    expect(find.byKey(phoneKey), findsOneWidget);
    expect(s.phoneCalls.where((c) => c.form).length, 1);
  });

  testWidgets('transitional sizes inside settle do nothing', (tester) async {
    size(tester, 1194, 834);
    await tester.pumpWidget(host());
    tester.view.physicalSize = const Size(500, 834);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(padKey), findsOneWidget);
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pump();
    await tester.pump(settle * 2);
    expect(find.byKey(padKey), findsOneWidget);
    expect(s.phoneCalls, isEmpty);
  });

  testWidgets('size while paused does not flip', (tester) async {
    size(tester, 1194, 834);
    await tester.pumpWidget(host());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.view.physicalSize = const Size(500, 834);
    await tester.pump();
    await tester.pump(settle * 3);
    expect(find.byKey(padKey), findsOneWidget);
    expect(s.phoneCalls, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    expect(find.byKey(phoneKey), findsOneWidget);
    // A transitional size seen only while paused and gone by the time the app is back does nothing.
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pump();
    await tester.pump(settle * 2);
    await tester.pump(); // the frame between the two shells (F9)
    expect(find.byKey(padKey), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.view.physicalSize = const Size(500, 834);
    await tester.pump(const Duration(milliseconds: 16));
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pump(const Duration(milliseconds: 16));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(settle * 2);
    expect(find.byKey(padKey), findsOneWidget);
  });

  testWidgets('onFold gets the landing', (tester) async {
    size(tester, 1194, 834);
    final got = <({PhoneScreen screen, String? cameFrom})>[];
    await tester.pumpWidget(host(onFold: got.add, waiting: () => 2, isWaiting: (_) => false));
    s.currentKey = 'k1';
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    expect(got, [(screen: PhoneScreen.home, cameFrom: 'k1')]);
  });

  testWidgets('onFold with nothing waiting stays in the session', (tester) async {
    size(tester, 1194, 834);
    final got = <({PhoneScreen screen, String? cameFrom})>[];
    await tester.pumpWidget(host(onFold: got.add));
    s.currentKey = 'k1';
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    expect(got, [(screen: PhoneScreen.session, cameFrom: null)]);
    expect(s.phoneInSession, isTrue);
  });

  testWidgets('entered drives the unfold position', (tester) async {
    size(tester, 1194, 834);
    String? entered;
    await tester.pumpWidget(host(entered: () => entered));
    s.toggleOverview();
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    expect(s.overview, isFalse);
    // Back with nothing entered: the wall comes back (F8).
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    expect(find.byKey(padKey), findsOneWidget);
    expect(s.phoneForm, isFalse);
    expect(s.overview, isTrue);
  });

  testWidgets('fold closes an open menu', (tester) async {
    size(tester, 1194, 834);
    await tester.pumpWidget(host(
      pad: PopupMenuButton<int>(
        key: padKey,
        itemBuilder: (_) => const [PopupMenuItem(value: 1, child: Text('menu-item'))],
      ),
    ));
    await tester.tap(find.byKey(padKey));
    await tester.pumpAndSettle();
    expect(find.text('menu-item'), findsOneWidget);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    await tester.pumpAndSettle();
    expect(find.byKey(phoneKey), findsOneWidget);
    expect(find.text('menu-item'), findsNothing);
  });

  testWidgets('shell switch keeps session state', (tester) async {
    final term = FakeTermSessionPort();
    final port = FakeSessionPort();
    final tr = FakeTransport();
    final st = CountState(hub: HubClient(tr), data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
    addTearDown(st.dispose);
    final monitor = ServiceMonitor(readToken: () async => null);
    tr.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        tr.emit({'event': 'hosts', 'req': m['req'], 'hosts': [{'id': '111', 'name': 'mini'}]});
      }
      if (m['cmd'] == 'open') {
        term.seed(1);
        tr.emit({'event': 'opened', 'req': m['req'], 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'port': 5001, 'token': 'tk'});
      }
    };
    size(tester, 1194, 834);
    await tester.runAsync(() async {
      st.openOrSwitch('111', 'term:pty:a', 'a');
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    final rs = st.currentRemote!;
    rs.composer.draft = '半句话';
    final model = term.model(rs.sid);
    final sentBefore = tr.sent.length;
    await tester.pumpWidget(MaterialApp(
      theme: themeDataFor(RappTheme.matrix),
      home: FormSwitch(
        state: st,
        settle: settle,
        pad: (_) => MainWindow(state: st, monitor: monitor, control: null, fullscreen: FakeFullscreen()),
        phone: (_) => const SizedBox(key: phoneKey),
      ),
    ));
    final key = st.currentKey;
    expect(key, isNotNull);
    expect(find.byType(MainWindow), findsOneWidget);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    expect(find.byKey(phoneKey), findsOneWidget);
    expect(find.byType(MainWindow), findsNothing);
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MainWindow), findsOneWidget);
    expect(st.currentKey, key);
    expect(st.currentRemote, same(rs));
    expect(rs.composer.draft, '半句话');
    expect(identical(term.model(rs.sid), model), isTrue);
    expect(tr.closed, isFalse);
    final after = tr.sent.skip(sentBefore).map((m) => m['cmd']);
    expect(after.where((c) => c == 'open' || c == 'close'), isEmpty);
  });

  /// A MainState with one graphic session (Safari, sid 1) on a fake port; [win] is its current window.
  Future<({CountState st, FakeSessionPort port, FakeTransport tr})> graphic(WidgetTester tester) async {
    final port = FakeSessionPort();
    final tr = FakeTransport();
    final st = CountState(hub: HubClient(tr), data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    addTearDown(st.dispose);
    tr.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        tr.emit({'event': 'hosts', 'req': m['req'], 'hosts': [{'id': '111', 'name': 'mini'}]});
      }
      if (m['cmd'] == 'open') {
        tr.emit({'event': 'opened', 'req': m['req'], 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'port': 5001, 'token': 'tk'});
      }
    };
    await tester.runAsync(() async {
      st.openOrSwitch('111', 'Safari', 'Safari');
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    return (st: st, port: port, tr: tr);
  }

  RemoteWindow win(double w, double h) => RemoteWindow(
        id: 5,
        parent: 0,
        kind: WindowKind.normal,
        title: 'w',
        rect: Rect.fromLTWH(0, 0, w, h + 28),
        titleBar: 28,
        resizable: true,
        focused: true,
        texture: 42,
        visible: const Rect.fromLTWH(0, 0, 1, 1),
      );

  Widget graphicHost(CountState st) => MaterialApp(
        theme: themeDataFor(RappTheme.matrix),
        home: FormSwitch(
          state: st,
          settle: settle,
          pad: (_) => MainWindow(
              state: st, monitor: ServiceMonitor(readToken: () async => null), control: null, fullscreen: FakeFullscreen()),
          phone: (_) => const SizedBox(key: phoneKey),
        ),
      );

  List<Map<String, Object?>> resizes(FakeSessionPort port) => [for (final c in port.calls) if (c.$1 == 'resize') c.$2];

  /// Mounts the Pad at 1194x834 with a window of the wrong size, takes the one resize that earns, then tells the
  /// policy the window now has the stage's size (as A would). Returns how many resizes are out.
  Future<int> settledPad(WidgetTester tester, CountState st, FakeSessionPort port) async {
    size(tester, 1194, 834);
    await tester.pumpWidget(graphicHost(st));
    port.emit(const ReadyEvent(1, 'Safari'));
    port.emit(WindowsEvent(1, [win(800, 600)]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final r = resizes(port);
    expect(r.length, 1);
    port.emit(WindowsEvent(1, [win((r.single['w'] as num).toDouble(), (r.single['h'] as num).toDouble())]));
    await tester.pump();
    return r.length;
  }

  testWidgets('round trip with the same stage sends no resize', (tester) async {
    final e = await graphic(tester);
    final before = await settledPad(tester, e.st, e.port);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    expect(find.byKey(phoneKey), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(resizes(e.port).length, before);
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(MainWindow), findsOneWidget);
    expect(resizes(e.port).length, before);
  });

  testWidgets('round trip to a different stage sends one resize after 400 ms', (tester) async {
    final e = await graphic(tester);
    final before = await settledPad(tester, e.st, e.port);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    await tester.pump(const Duration(seconds: 1));
    expect(resizes(e.port).length, before);
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pump();
    // 390 ms in, the stage has not been still for 400 ms yet.
    await tester.pump(const Duration(milliseconds: 390));
    await tester.pump(); // the frame between the two shells (F9)
    expect(find.byType(MainWindow), findsOneWidget);
    expect(resizes(e.port).length, before);
    await tester.pump(const Duration(milliseconds: 400));
    expect(resizes(e.port).length, before + 1);
    await tester.pump(const Duration(seconds: 1));
    expect(resizes(e.port).length, before + 1);
  });

  testWidgets('entered open session lands the Pad on it', (tester) async {
    final e = await graphic(tester);
    final other = e.st.currentKey;
    expect(other, isNotNull);
    e.st.toggleOverview();
    size(tester, 1194, 834);
    await tester.pumpWidget(MaterialApp(
      theme: themeDataFor(RappTheme.matrix),
      home: FormSwitch(
        state: e.st,
        settle: settle,
        pad: (_) => const SizedBox(key: padKey),
        phone: (_) => const SizedBox(key: phoneKey),
        entered: () => other,
      ),
    ));
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pump();
    await tester.pump(settle + const Duration(milliseconds: 10));
    await tester.pump(); // the frame between the two shells (F9)
    expect(find.byKey(padKey), findsOneWidget);
    expect(e.st.overview, isFalse);
    expect(e.st.currentKey, other);
  });
}
