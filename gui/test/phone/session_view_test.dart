import 'dart:io';

import 'package:flutter/foundation.dart';
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
    final before = views().length;
    tester.view.physicalSize = const Size(844, 390);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(views().length, greaterThan(before));
    expect(views().every((v) => v['fit'] == false), isTrue);
  });

  testWidgets('pad terminal still follows pref', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: false);
    expect(views(), isNotEmpty);
    expect(views().last['fit'], true);
  });

  // A Pad stage size is known and A's window is the wrong size for it: only the phone form holds the resize back.
  testWidgets('phone picture sends no resize', (tester) async {
    await boot(tester, app: 'Safari', phone: true);
    s.stageSize(const Size(1194, 834));
    port.emit(const ReadyEvent(1, 'Safari'));
    port.emit(const WindowsEvent(1, [
      RemoteWindow(
        id: 5, parent: 0, kind: WindowKind.normal, title: 'w', rect: Rect.fromLTWH(0, 0, 800, 628), titleBar: 28,
        resizable: true, focused: true, texture: 42, visible: Rect.fromLTWH(0, 0, 1, 1),
      ),
    ]));
    await tester.runAsync(flush);
    await tester.pump();
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

  testWidgets('the session ending sends the phone home', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: true);
    s.endCurrent();
    term.play(const ClosedEvent(1, ''));
    await tester.runAsync(flush);
    await tester.pump();
    await tester.pump();
    expect(s.current, isNull);
    expect(nav.now, PhoneView.home);
    expect(s.phoneInSession, isFalse);
  });

  testWidgets('a hub problem shows its words', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: true);
    await tester.runAsync(() async {
      await t.die();
      await flush();
    });
    await tester.pump();
    expect(s.hubProblem, isNotNull);
    expect(find.text(s.hubProblem!), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  // R34: the phone mounts the Pad's own composer layer, lock banner and host notice (one implementation).
  for (final ios in [false, true]) {
    testWidgets('phone terminal: the composer opens and sends${ios ? ' (iOS)' : ''}', (tester) async {
      if (ios) debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await boot(tester, app: 'term:pty:w', phone: true);
        expect(find.byKey(const Key('composer-open')), findsOneWidget);
        await tester.tap(find.byKey(const Key('composer-open')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(s.currentRemote!.composer.open, isTrue);
        await tester.enterText(find.byKey(const Key('composer-field')), 'ls');
        await tester.tap(find.byKey(const Key('composer-send')));
        await tester.pump();
        await tester.runAsync(flush);
        final pastes = [for (final c in term.calls) if (c.$1 == 'paste') c.$2];
        expect(pastes.single['data'], 'ls');
        expect(views().every((v) => v['fit'] == false), isTrue);
        await tester.runAsync(flush);
        await tester.pump(const Duration(seconds: 5)); // the history note's 4 s
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  // keyboardLift(fullscreen: false) takes the home bar off, so the page must keep standing above the home bar
  // while the keyboard is up (as the Pad's stage does): the 输入 button then sits over the keyboard, not under it.
  testWidgets('phone: the composer stands over the soft keyboard', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: true);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    tester.view.padding = FakeViewPadding.zero; // what iOS reports with the keyboard up
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getRect(find.byKey(const Key('composer-open'))).bottom, lessThanOrEqualTo(844 - 300));
    await tester.pump(const Duration(seconds: 1));
  });

  // F9: text typed in the phone's composer (the Pad's own panel, keyed by session) is there on the Pad after a swap.
  testWidgets('text typed on the phone is in the Pad composer after a swap', (tester) async {
    await boot(tester, app: 'term:pty:w', phone: true);
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('composer-field')), 'half a line');
    await tester.pump();
    // FormSwitch puts one empty frame between the two shells, so the phone's panel lets go before the Pad's takes over.
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), home: const SizedBox.expand()));
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), home: Scaffold(body: Stage(state: s))));
    await tester.pump();
    final field = find.descendant(of: find.byKey(const Key('composer-field')), matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(field).controller.text, 'half a line');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('phone picture shows the lock banner', (tester) async {
    await boot(tester, app: 'Safari', phone: true);
    expect(find.text('输入系统密码'), findsNothing);
    port.emit(const ScreenLockedEvent(1, true));
    await tester.runAsync(flush);
    await tester.pump();
    expect(find.text(s.lockBanner!.text), findsOneWidget);
    expect(find.text('输入系统密码'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('phone picture shows the host notice', (tester) async {
    await boot(tester, app: 'Safari', phone: true);
    expect(find.byKey(const Key('host-notice')), findsNothing);
    port.emit(const CoveredEvent(1, 3, '通知中心', 'com.apple.notificationcenterui', true));
    await tester.runAsync(flush);
    await tester.pump();
    expect(find.byKey(const Key('host-notice')), findsOneWidget);
    expect(find.text('关掉它'), findsOneWidget);
    await tester.pump(hostNoticeFor);
  });

  testWidgets('phone picture: the composer opens over it, no resize', (tester) async {
    await boot(tester, app: 'Safari', phone: true);
    expect(find.byKey(const Key('composer-open')), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
    expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
  });

  // The draft lives in RemoteSession.composer, not in either shell's widgets (F9).
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
