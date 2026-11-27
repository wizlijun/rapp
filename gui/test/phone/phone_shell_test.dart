import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/home_screen.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/phone_shell.dart';
import 'package:rapp/phone/session_view.dart';
import 'package:rapp/phone/sheet.dart';
import 'package:rapp/platform_caps.dart';
import 'package:rapp/ui/access_setup.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/unlock.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import '../ui/main_window_test.dart' show FakeFullscreen;

void main() {
  late Directory tmp;
  late FakeTransport t;
  late MainState s;
  late PhoneNav nav;
  late FakeSessionPort port;
  var sid = 0;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    sid = 0;
    tmp = Directory.systemTemp.createTempSync('phone_shell_test');
  });
  tearDown(() {
    nav.dispose();
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> term(String id, String state) => {
        'id': 'term:pty:$id',
        'name': id,
        'command': 'zsh',
        'activity': 1,
        'unread': false,
        'fg': 'codex',
        'ps': {'state': state, 'kind': state == 'blocked' ? 'permission' : null, 'msg': 'ok?', 'since': 10, 'seq': 1},
      };

  void size(WidgetTester tester, double w, double h) {
    tester.view.physicalSize = Size(w, h);
    tester.view.devicePixelRatio = 1;
  }

  /// A pad (MainWindow) with the terminals [open] opened, [rows] listed; returns after the first frame.
  Future<void> boot(WidgetTester tester, {List<String> open = const [], List<Map<String, Object?>> rows = const [], Size at = const Size(1194, 834)}) async {
    size(tester, at.width, at.height);
    addTearDown(tester.view.reset);
    t = FakeTransport();
    final hub = HubClient(t);
    t.emit({'event': 'hosts', 'hosts': [{'id': 'm1', 'name': 'mini'}]});
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req'], 'port': 5000 + sid, 'token': 'tk'});
      }
    };
    await tester.runAsync(flush);
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port = FakeSessionPort(), unlockStore: UnlockStore(supported: false, memory: false), termPort: FakeTermSessionPort());
    nav = PhoneNav(s);
    t.emit({'event': 'terms', 'id': 'm1', 'path': 'lan', 'terms': rows, 'hosts': []});
    await tester.runAsync(() async {
      for (final k in open) {
        s.openOrSwitch('m1', 'term:pty:$k', k);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      }
    });
    await tester.pumpWidget(MaterialApp(
      theme: themeDataFor(RappTheme.matrix),
      home: phoneFormSwitch(
        state: s,
        nav: nav,
        data: DataDir(tmp.path),
        pad: (_) => MainWindow(state: s, monitor: null, control: null, fullscreen: FakeFullscreen()),
      ),
    ));
    await tester.pump();
  }

  Future<void> resize(WidgetTester tester, Size to) async {
    size(tester, to.width, to.height);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  const phoneSize = Size(390, 844), padSize = Size(1194, 834);

  testWidgets('fold to home when something waits', (tester) async {
    await boot(tester, open: ['x'], rows: [term('x', 'working'), term('y', 'blocked')]);
    expect(s.currentKey, 'm1/term:pty:x');
    await resize(tester, phoneSize);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('刚才在：codex · x'), findsOneWidget);
    expect(nav.now, PhoneView.home);
  });

  testWidgets('fold stays in session when nothing waits', (tester) async {
    await boot(tester, open: ['x'], rows: [term('x', 'working')]);
    await resize(tester, phoneSize);
    expect(find.byType(PhoneSessionView), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(nav.now, PhoneView.session);
  });

  testWidgets('unfold goes to entered', (tester) async {
    await boot(tester, open: ['x', 'y'], rows: [term('x', 'working'), term('y', 'blocked')]);
    s.select('m1/term:pty:x');
    await resize(tester, phoneSize);
    expect(find.byType(HomeScreen), findsOneWidget);
    nav.enter('m1/term:pty:y');
    await tester.pump();
    await resize(tester, padSize);
    expect(s.currentKey, 'm1/term:pty:y');
    expect(s.overview, isFalse);
    expect(find.byType(MainWindow), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // the Pad's resize policy settles
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unfold closes phone sheets', (tester) async {
    await boot(tester, rows: [term('y', 'blocked')]);
    await resize(tester, phoneSize);
    unawaited(showPhoneSheet(tester.element(find.byType(HomeScreen)), nav));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('设备'), findsOneWidget);
    await resize(tester, padSize);
    expect(find.text('设备'), findsNothing);
    expect(find.byType(MainWindow), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // the Pad's resize policy settles
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('every phone view renders inside the shell', (tester) async {
    await boot(tester, open: ['x'], rows: [term('x', 'working')], at: phoneSize);
    expect(find.byType(PhoneSessionView), findsOneWidget);
    for (final v in [PhoneView.home, PhoneView.devices, PhoneView.settings, PhoneView.session]) {
      if (v == PhoneView.session) {
        nav.enter('m1/term:pty:x');
      } else {
        nav.open(v);
      }
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$v');
      expect(nav.now, v);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an old phone visit does not beat where the Pad is now', (tester) async {
    await boot(tester, open: ['x', 'y', 'z'], rows: [term('x', 'working'), term('w', 'blocked')]);
    s.select('m1/term:pty:x');
    await resize(tester, phoneSize);
    nav.enter('m1/term:pty:y');
    await tester.pump();
    await resize(tester, padSize);
    expect(s.currentKey, 'm1/term:pty:y');
    s.select('m1/term:pty:z');
    await tester.pump();
    await resize(tester, phoneSize);
    await resize(tester, padSize);
    expect(s.currentKey, 'm1/term:pty:z');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('fold from the overview, enter on the phone, unfold lands in it', (tester) async {
    await boot(tester, open: ['x', 'y'], rows: [term('x', 'working')]);
    s.toggleOverview();
    await tester.pump();
    expect(s.overview, isTrue);
    await resize(tester, phoneSize);
    expect(find.byType(HomeScreen), findsOneWidget);
    nav.enter('m1/term:pty:y');
    await tester.pump();
    await resize(tester, padSize);
    expect(s.currentKey, 'm1/term:pty:y');
    expect(s.overview, isFalse);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('fold from the overview, unfold: the overview', (tester) async {
    await boot(tester, open: ['x'], rows: [term('x', 'working')]);
    s.toggleOverview();
    await tester.pump();
    await resize(tester, phoneSize);
    await resize(tester, padSize);
    expect(s.overview, isTrue);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a session that ended on the phone is not landed on', (tester) async {
    await boot(tester, open: ['x'], rows: [term('x', 'working')]);
    await tester.runAsync(() async {
      s.openOrSwitch('m1', 'app', 'App');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    final appSid = sid;
    s.toggleOverview();
    await tester.pump();
    await resize(tester, phoneSize);
    nav.enter('m1/app');
    await tester.pump();
    port.emit(ReadyEvent(appSid, 'App'));
    port.emit(ClosedEvent(appSid, 'closed'));
    await tester.runAsync(flush);
    await tester.pump();
    expect(s.entries.any((e) => e.key == 'm1/app'), isFalse);
    await resize(tester, padSize);
    expect(s.overview, isTrue);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unlock ask in the phone form shows the password dialog', (tester) async {
    await boot(tester, rows: [term('y', 'blocked')], at: phoneSize);
    await tester.runAsync(() async {
      s.openOrSwitch('m1', 'app', 'App');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    port.emit(ReadyEvent(sid, 'App'));
    port.emit(ScreenLockedEvent(sid, true));
    await tester.runAsync(flush);
    await tester.pump();
    port.emit(ScreenLockedEvent(sid, false));
    port.emit(ScreenLockedEvent(sid, true));
    await tester.runAsync(flush);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(UnlockDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  // M1: fold and unfold close the old form's menus and dialogs, but a pending system-password ask is not dropped:
  // the dialog is there again in the new form.
  testWidgets('an open password dialog survives fold and unfold', (tester) async {
    await boot(tester, rows: [term('y', 'working')]);
    await tester.runAsync(() async {
      s.openOrSwitch('m1', 'app', 'App');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    port.emit(ReadyEvent(sid, 'App'));
    port.emit(ScreenLockedEvent(sid, true));
    await tester.runAsync(flush);
    await tester.pump();
    port.emit(ScreenLockedEvent(sid, false));
    port.emit(ScreenLockedEvent(sid, true));
    await tester.runAsync(flush);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(UnlockDialog), findsOneWidget);
    await resize(tester, phoneSize);
    await tester.runAsync(flush);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PhoneSessionView), findsOneWidget);
    expect(find.byType(UnlockDialog), findsOneWidget);
    await resize(tester, padSize);
    await tester.runAsync(flush);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MainWindow), findsOneWidget);
    expect(find.byType(UnlockDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(UnlockDialog), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });

  group('iOS without a key', () {
    late PlatformCaps was;
    setUp(() {
      was = caps;
      caps = PlatformCaps.forOs('ios');
    });
    tearDown(() => caps = was);

    testWidgets('new user sees access setup', (tester) async {
      await boot(tester, at: const Size(844, 390));
      t.emit({'event': 'access', 'relay': null, 'has_key': false, 'name': 'iPhone'});
      await tester.runAsync(flush);
      await tester.pump();
      expect(find.byType(AccessSetup), findsOneWidget);
      // The inner column, not the outer Center: one column, at most 480 wide, even on a wide phone (landscape).
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      expect({for (var i = 0; i < 2; i++) tester.getTopLeft(fields.at(i)).dx}.length, 1);
      expect(tester.getSize(fields.at(0)).width, lessThanOrEqualTo(480));
      expect(tester.getSize(find.descendant(of: find.byType(AccessSetup), matching: find.byType(ConstrainedBox)).first).width, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
    });

    // The hub answered `access` before the shell came up: the shell takes it on its first frame, and the relay
    // flag (which notifies MainState's listeners) is set after that frame, not while the tree builds.
    testWidgets('known access under a listening root sets the relay after the frame', (tester) async {
      size(tester, 390, 844);
      addTearDown(tester.view.reset);
      t = FakeTransport();
      final hub = HubClient(t);
      t.emit({'event': 'access', 'relay': 'r', 'has_key': true, 'name': 'iPhone'});
      await tester.runAsync(flush);
      expect(hub.lastAccess, isNotNull);
      s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port = FakeSessionPort(), unlockStore: UnlockStore(supported: false, memory: false));
      nav = PhoneNav(s);
      expect(s.relaySet, isFalse);
      await tester.pumpWidget(ListenableBuilder(
        listenable: s,
        builder: (_, _) => MaterialApp(
          theme: themeDataFor(RappTheme.matrix),
          home: phoneFormSwitch(state: s, nav: nav, data: DataDir(tmp.path), pad: (_) => const SizedBox()),
        ),
      ));
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(s.relaySet, isTrue);
      expect(find.byType(AccessSetup), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
