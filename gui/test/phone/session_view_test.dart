import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/session_view.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';

void main() {
  late Directory tmp;
  late FakeTransport t;
  late MainState s;
  late PhoneNav nav;
  late FakeSessionPort port;
  late FakeTermSessionPort term;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session_view_test');
  });
  tearDown(() {
    nav.dispose();
    s.dispose();
    term.dispose();
    tmp.deleteSync(recursive: true);
  });

  RemoteWindow win(int id, {int? texture}) => RemoteWindow(
        id: id,
        parent: 0,
        kind: WindowKind.normal,
        title: 'w$id',
        rect: const Rect.fromLTWH(0, 0, 400, 328),
        titleBar: 28,
        resizable: true,
        focused: true,
        texture: texture,
        visible: const Rect.fromLTWH(0, 0, 1, 1),
      );

  Future<void> boot(WidgetTester tester, {required String app, required bool phone, bool termFit = true}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    t = FakeTransport();
    final hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': 'm1', 'name': 'mini'},
      ],
    });
    await tester.runAsync(flush);
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    final prefs = UiPrefs()..termFit = termFit;
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: prefs, port: port, termPort: term);
    nav = PhoneNav(s);
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req'], 'port': 5001, 'token': 'tk'});
      }
    };
    await tester.runAsync(() async {
      s.openOrSwitch('m1', app, app);
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    if (phone) nav.enter('m1/$app');
    final theme = themeDataFor(RappTheme.matrix);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: phone ? PhoneSessionView(state: s, nav: nav) : Scaffold(body: Stage(state: s)),
    ));
    if (app.startsWith('term:')) {
      final panes = [
        TermPane(id: '%3', win: '@1', window: '@1', title: '', command: 'zsh', cols: 80, rows: 24, dead: false, active: true),
      ];
      term.paneLists[1] = panes;
      term.play(const ReadyEvent(1, 'zsh'));
      term.play(WindowsEvent(1, [win(3)]));
      term.play(const TrafficEvent(1, 0, 1));
    } else {
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [win(5, texture: 42)]));
    }
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    await tester.pump();
  }

  List<Map<String, Object?>> views() => [for (final c in term.calls) if (c.$1 == 'view') c.$2];

  testWidgets('phone terminal view never asks to fit', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: true);
    expect(views(), isNotEmpty);
    expect(views().every((v) => v['fit'] == false), isTrue);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(views().every((v) => v['fit'] == false), isTrue);
  });

  testWidgets('pad terminal still follows pref', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: false);
    expect(views(), isNotEmpty);
    expect(views().last['fit'], true);
  });

  testWidgets('phone picture does not call stageSize', (tester) async {
    await boot(tester, app: 'Safari', phone: true);
    await tester.pump(const Duration(seconds: 1));
    expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    expect(t.sent.where((m) => m['cmd'] == 'resize'), isEmpty);
  });

  testWidgets('back goes home', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: true);
    expect(s.phoneInSession, isTrue);
    await tester.tap(find.text('返回'));
    await tester.pump();
    expect(nav.now, PhoneView.home);
    expect(s.phoneInSession, isFalse);
  });

  // The phone session view hosts no composer in V1b (it mounts TermStage / Picture / DisconnectedStage only,
  // not composerLayer), so there is no editor caret to keep; the draft lives in RemoteSession.composer.
  testWidgets('draft survives a shell switch', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: true);
    final rs = s.currentRemote!;
    rs.composer.draft = 'hello';
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), home: Scaffold(body: Stage(state: s))));
    await tester.pump();
    expect(s.currentRemote!.composer.draft, 'hello');
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), home: PhoneSessionView(state: s, nav: nav)));
    await tester.pump();
    expect(s.currentRemote!.composer.draft, 'hello');
    await tester.pump(const Duration(seconds: 1));
  });
}
