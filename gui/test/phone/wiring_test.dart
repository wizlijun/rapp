import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/form.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/phone_shell.dart';
import 'package:rapp/phone/session_view.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/unlock.dart';

import '../fakes.dart';
import '../ui/main_window_test.dart' show FakeFullscreen;

void main() {
  late Directory tmp;
  late MainState s;
  late PhoneNav nav;
  late FakeTransport t;

  test('desktop without the flag has no switch', () {
    expect(phoneFormWanted({}), isFalse);
    expect(phoneFormWanted({'RAPP_PHONE_FORM': '1'}), isTrue);
    expect(phoneFormWanted({'RAPP_PHONE_FORM': '0'}), isFalse);
  });

  setUp(() => tmp = Directory.systemTemp.createTempSync('wiring_test'));
  var booted = false;
  tearDown(() {
    if (booted) {
      nav.dispose();
      s.dispose();
    }
    booted = false;
    tmp.deleteSync(recursive: true);
  });

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    t = FakeTransport();
    t.emit({'event': 'hosts', 'hosts': [{'id': 'm1', 'name': 'mini'}]});
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req'], 'port': 5001, 'token': 'tk'});
      }
    };
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort(), unlockStore: UnlockStore(supported: false, memory: false), termPort: FakeTermSessionPort());
    nav = PhoneNav(s);
    booted = true;
    t.emit({'event': 'terms', 'id': 'm1', 'path': 'lan', 'terms': [{'id': 'term:pty:x', 'name': 'x', 'command': 'zsh', 'activity': 1, 'unread': false}], 'hosts': []});
    await tester.runAsync(() async {
      s.openOrSwitch('m1', 'term:pty:x', 'x');
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
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
    tester.view.physicalSize = to;
    await tester.pump();
    await tester.pump(phoneFormSettle + const Duration(milliseconds: 10));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  testWidgets('switch sits under the root navigator', (tester) async {
    await boot(tester);
    // The exact shape main_ios.dart / main.dart use: the switch is MaterialApp.home.
    unawaited(showDialog<void>(context: tester.element(find.byType(MainWindow)), builder: (_) => const AlertDialog(title: Text('pad dialog'))));
    await tester.pump();
    expect(find.text('pad dialog'), findsOneWidget);
    await resize(tester, const Size(390, 844));
    expect(find.text('pad dialog'), findsNothing);
  });

  testWidgets('caret survives a real form swap', (tester) async {
    await boot(tester);
    final rs = s.currentRemote!;
    rs.composer.open = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final field = find.byKey(const Key('composer-field'));
    expect(find.byType(ComposerPanel), findsOneWidget);
    tester.widget<TextField>(field).controller!.value = const TextEditingValue(text: 'hello', selection: TextSelection.collapsed(offset: 2));
    await tester.pump();
    await resize(tester, const Size(390, 844));
    // R34: the phone mounts the same composer layer; its panel takes the text and the caret too.
    expect(find.byType(PhoneSessionView), findsOneWidget);
    expect(find.byType(ComposerPanel), findsOneWidget);
    final p = tester.widget<TextField>(field).controller!;
    expect(p.text, 'hello');
    expect(p.selection, const TextSelection.collapsed(offset: 2));
    await resize(tester, const Size(1194, 834));
    await tester.pump();
    expect(rs.composer.open, isTrue);
    final c = tester.widget<TextField>(field).controller!;
    expect(c.text, 'hello');
    expect(c.selection, const TextSelection.collapsed(offset: 2));
    await tester.pump(const Duration(seconds: 1));
  });
}

