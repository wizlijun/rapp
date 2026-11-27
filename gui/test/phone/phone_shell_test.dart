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
import 'package:rapp/ui/main_state.dart';
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
        t.emit({'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req'], if (m['embed'] == true) ...{'port': 5000 + sid, 'token': 'tk'}});
      }
    };
    await tester.runAsync(flush);
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort(), termPort: FakeTermSessionPort());
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

  group('iOS without a key', () {
    late PlatformCaps was;
    setUp(() {
      was = caps;
      caps = PlatformCaps.forOs('ios');
    });
    tearDown(() => caps = was);

    testWidgets('new user sees access setup', (tester) async {
      await boot(tester, at: phoneSize);
      t.emit({'event': 'access', 'relay': null, 'has_key': false, 'name': 'iPhone'});
      await tester.runAsync(flush);
      await tester.pump();
      expect(find.byType(AccessSetup), findsOneWidget);
      expect(tester.getSize(find.byType(AccessSetup)).width, lessThanOrEqualTo(480));
      expect(find.byType(TextField), findsNWidgets(2));
      final xs = {for (final f in tester.widgetList(find.byType(TextField)).map((w) => tester.getTopLeft(find.byWidget(w)).dx)) f};
      expect(xs.length, 1);
      expect(tester.takeException(), isNull);
    });
  });
}
