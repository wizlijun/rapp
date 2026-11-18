// The app key row (iPad P1 task 9): Esc Tab ⌘ ⌥ ⌃ ⇧ ← ↑ ↓ → ⌫ ⏎ over an app session's picture, the modifiers sticky.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_key_row.dart';
import 'package:rapp/embed/modifier_latch.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/platform_caps.dart';
import 'package:rapp/ui/disconnected_stage.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

const names = ['Esc', 'Tab', 'Cmd', 'Opt', 'Ctrl', 'Shift', 'Left', 'Up', 'Down', 'Right', 'Delete', 'Return'];

void main() {
  late FakeTransport t;
  late HubClient hub;
  late FakeSessionPort port;
  late MainState s;
  late Directory tmp;
  var nextSid = 1;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('app_key_row_test');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"123456789"}');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    nextSid = 1;
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({
          'event': 'opened', 'sid': nextSid++, 'id': m['id'], 'app': m['app'], 'path': 'lan',
          'port': 5001, 'token': 'tk', 'req': m['req'],
        });
      }
    };
    port = FakeSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Finder key(String name) => find.byKey(Key('appkey-$name'));

  /// The key traffic, in order: `('key', code, flags)` and `('down'|'up', code, flags)`.
  List<(String, Object?, Object?)> keys({Object? sid}) => [
        for (final c in port.calls)
          if ((c.$1 == 'key' || c.$1 == 'key_event') && (sid == null || c.$2['sid'] == sid))
            (c.$1 == 'key' ? 'key' : (c.$2['down'] == true ? 'down' : 'up'), c.$2['keyCode'], c.$2['modifiers']),
      ];
  List<Object?> latches() => [for (final c in port.calls) if (c.$1 == 'latch') c.$2['modifiers']];

  Future<void> mountRow(WidgetTester tester, {Object sid = 1, ModifierLatch? latch}) async {
    await tester.pumpWidget(wrap(SizedBox(
      width: 900,
      child: AppKeyRow(state: s, sid: sid, latch: latch ?? s.appLatch),
    )));
  }

  group('the row alone', () {
    testWidgets('⌘ then Tab: ⌘ down, Tab with ⌘, ⌘ up', (tester) async {
      await mountRow(tester);
      await tester.tap(key('Cmd'));
      await tester.pump();
      await tester.tap(key('Tab'));
      await tester.pump();
      expect(keys(), [('down', 55, 1048576), ('key', 48, 1048576), ('up', 55, 0)]);
      expect(latches(), [1048576, 0], reason: 'the hardware keyboard is told each change');
      expect(port.calls.where((c) => c.$1 == 'key_event').every((c) => c.$2['sid'] == 1), isTrue);
    });

    testWidgets('a double tap locks ⌘: two Tabs both carry it, nothing goes up', (tester) async {
      await mountRow(tester);
      await tester.tap(key('Cmd'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(key('Cmd'));
      await tester.pump();
      expect(s.appLatch.of(latchCmd), LatchState.locked);
      await tester.tap(key('Tab'));
      await tester.pump();
      await tester.tap(key('Tab'));
      await tester.pump();
      expect(keys(), [('down', 55, 1048576), ('key', 48, 1048576), ('key', 48, 1048576)]);
    });

    testWidgets('every key is at least 48 square, labelled', (tester) async {
      await mountRow(tester);
      for (final n in names) {
        final size = tester.getSize(key(n));
        expect(size.width, greaterThanOrEqualTo(48), reason: n);
        expect(size.height, greaterThanOrEqualTo(48), reason: n);
      }
      for (final label in ['Esc', 'Tab', '⌘', '⌥', '⌃', '⇧', '←', '↑', '↓', '→', '⌫', '⏎']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('each plain key sends its macOS key code', (tester) async {
      await mountRow(tester);
      for (final n in ['Esc', 'Tab', 'Left', 'Up', 'Down', 'Right', 'Delete', 'Return']) {
        await tester.tap(key(n));
        await tester.pump();
      }
      expect(keys(), [
        for (final c in [53, 48, 123, 126, 125, 124, 51, 36]) ('key', c, 0),
      ]);
    });

    testWidgets('modifier codes: ⌥ 58, ⌃ 59, ⇧ 56; the down carries every flag on, the up what stays', (tester) async {
      await mountRow(tester);
      await tester.tap(key('Opt'));
      await tester.pump();
      await tester.tap(key('Ctrl'));
      await tester.pump();
      await tester.tap(key('Shift'));
      await tester.pump();
      await tester.tap(key('Return'));
      await tester.pump();
      const all = 524288 | 262144 | 131072;
      expect(keys(), [
        ('down', 58, 524288),
        ('down', 59, 524288 | 262144),
        ('down', 56, all),
        ('key', 36, all),
        ('up', 58, 262144 | 131072),
        ('up', 59, 131072),
        ('up', 56, 0),
      ]);
    });

    testWidgets('a tap on a once modifier long after turns it off: its up goes', (tester) async {
      var now = DateTime(2026, 11, 17);
      final latch = ModifierLatch(clock: () => now);
      addTearDown(latch.dispose);
      await mountRow(tester, latch: latch);
      await tester.tap(key('Cmd'));
      await tester.pump();
      now = now.add(const Duration(seconds: 1));
      await tester.tap(key('Cmd'));
      await tester.pump();
      expect(keys(), [('down', 55, 1048576), ('up', 55, 0)]);
    });

    testWidgets('once and locked ⌘ are both a 2 px accent border on the raise fill', (tester) async {
      await mountRow(tester);
      Material look() => tester.widget<Material>(find.descendant(of: key('Cmd'), matching: find.byType(Material)));
      Color side(Material m) => (m.shape! as RoundedRectangleBorder).side.color;
      final accent = RappTokens.of(tester.element(key('Cmd'))).accent;
      final off = look();
      expect(side(off), isNot(accent));
      await tester.tap(key('Cmd'));
      await tester.pump();
      expect(side(look()), accent);
      expect(look().color, off.color);
      await tester.tap(key('Cmd'));
      await tester.pump();
      expect(side(look()), accent);
      expect((look().shape! as RoundedRectangleBorder).side.width, 2);
      expect(look().color, off.color);
    });

    testWidgets('no key left held on A (Review Focus 4): the row going away releases its modifiers', (tester) async {
      await mountRow(tester);
      await tester.tap(key('Cmd'));
      await tester.pump();
      await tester.tap(key('Shift'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(key('Shift'));
      await tester.pump();
      port.calls.clear();
      await tester.pumpWidget(wrap(const SizedBox()));
      expect(keys(), [('up', 55, 131072), ('up', 56, 0)]);
      expect(latches(), [0]);
      expect(s.appLatch.flags, 0);
    });

    testWidgets('another sid on the same row: the old one gets the ups, the new one starts clean', (tester) async {
      await mountRow(tester, sid: 1);
      await tester.tap(key('Cmd'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(key('Cmd'));
      await tester.pump();
      port.calls.clear();
      await mountRow(tester, sid: 2);
      expect(keys(sid: 1), [('up', 55, 0)]);
      expect(keys(sid: 2), isEmpty);
      await tester.tap(key('Tab'));
      await tester.pump();
      expect(keys(sid: 2), [('key', 48, 0)]);
    });

    testWidgets('releaseAll() (going to the background) sends the ups', (tester) async {
      await mountRow(tester);
      await tester.tap(key('Ctrl'));
      await tester.pump();
      port.calls.clear();
      s.appLatch.releaseAll();
      await tester.pump();
      expect(keys(), [('up', 59, 0)]);
    });

    testWidgets("a hardware key took the once ⌘ (native latch_used): it goes up, locked stays", (tester) async {
      await mountRow(tester);
      await tester.tap(key('Cmd'));
      await tester.pump();
      await tester.tap(key('Opt'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(key('Opt'));
      await tester.pump();
      port.calls.clear();
      port.emit(const LatchUsedEvent(1));
      await tester.pump();
      expect(keys(), [('up', 55, 524288)]);
      expect(latches(), [524288]);
      expect(s.appLatch.of(latchOpt), LatchState.locked);
    });

    testWidgets('⌘ locked, then a hardware key (latch_used): native gets ⌘ again for the next one', (tester) async {
      await mountRow(tester);
      await tester.tap(key('Cmd'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(key('Cmd'));
      await tester.pump();
      port.calls.clear();
      port.emit(const LatchUsedEvent(1));
      await tester.pump();
      expect(keys(), isEmpty, reason: 'a locked ⌘ stays down on A');
      expect(latches(), [1048576]);
      expect(s.appLatch.of(latchCmd), LatchState.locked);
    });

    testWidgets("another session's latch_used leaves the row's modifiers alone", (tester) async {
      await mountRow(tester);
      await tester.tap(key('Cmd'));
      await tester.pump();
      port.calls.clear();
      port.emit(const LatchUsedEvent(2));
      await tester.pump();
      expect(keys(), isEmpty);
      expect(latches(), isEmpty);
      expect(s.appLatch.of(latchCmd), LatchState.once);
    });
  });

  test('latch_used parses to LatchUsedEvent', () {
    final e = parseSessionEvent('latch_used', {'sid': 3});
    expect(e, isA<LatchUsedEvent>());
    expect(e!.sid, 3);
  });

  test('appKeyRow: off by default on the desktop, saved as app_key_row', () {
    expect(UiPrefs().appKeyRow, isFalse);
    expect(UiPrefs.load(tmp.path).appKeyRow, isFalse);
    UiPrefs(appKeyRow: true).save(tmp.path);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"app_key_row":true'));
    expect(UiPrefs.load(tmp.path).appKeyRow, isTrue);
  });

  group('its lift off the stage bottom (keyboardLift)', () {
    MediaQueryData mq({double inset = 0, double homeBar = 0}) =>
        MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset), viewPadding: EdgeInsets.only(bottom: homeBar));

    test('no soft keyboard: on the stage bottom, home bar or not, fullscreen or not', () {
      for (final full in [false, true]) {
        expect(keyboardLift(mq(), fullscreen: full), 0);
        expect(keyboardLift(mq(homeBar: 20), fullscreen: full), 0);
      }
    });

    test('the soft keyboard up: its height', () {
      expect(keyboardLift(mq(inset: 300), fullscreen: false), 300);
    });

    test('above the home bar the stage ends at the safe area: the bar comes off', () {
      expect(keyboardLift(mq(inset: 300, homeBar: 20), fullscreen: false), 280);
    });

    test('fullscreen: the stage runs to the bottom edge, so the row sits right on the soft keyboard', () {
      expect(keyboardLift(mq(inset: 300, homeBar: 20), fullscreen: true), 300);
    });
  });

  group('on the stage', () {
    Future<void> openApp(WidgetTester tester, String app) async {
      await tester.runAsync(() async {
        s.openOrSwitch('111', app, app);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      final sid = nextSid - 1;
      port.emit(ReadyEvent(sid, app));
      port.emit(WindowsEvent(sid, [
        RemoteWindow(
            id: 5, parent: 0, kind: WindowKind.normal, title: 'w5', rect: const Rect.fromLTWH(0, 0, 400, 328),
            titleBar: 28, resizable: true, focused: true, texture: 40 + sid, visible: const Rect.fromLTWH(0, 0, 1, 1)),
      ]));
      await tester.pump();
      await tester.pump();
    }

    Future<void> mountStage(WidgetTester tester,
        {double inset = 0, double width = 1100, double homeBar = 0, bool fullscreen = false}) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(SizedBox(
        width: width,
        height: 800,
        child: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                viewInsets: EdgeInsets.only(bottom: inset), viewPadding: EdgeInsets.only(bottom: homeBar)),
            child: Stage(state: s, fullscreen: fullscreen),
          ),
        ),
      )));
    }

    for (final full in [false, true]) {
      testWidgets('the soft keyboard pushes the app window\'s writing panel up to 8 above it (fullscreen $full)',
          (tester) async {
        await mountStage(tester, inset: 300, homeBar: 20, fullscreen: full);
        await openApp(tester, 'Safari');
        s.currentRemote!.composer.open = true;
        await tester.pump();
        await tester.pump();
        final stage = tester.getRect(find.byKey(const Key('stage')));
        // Out of fullscreen the stage stands on the home bar, which the keyboard covers too.
        final keyboard = full ? 300 : 280;
        expect(tester.getRect(find.byKey(const Key('composer-panel'))).bottom, stage.bottom - keyboard - 8);
      });
    }

    testWidgets('off by default: no row over an app picture', (tester) async {
      await mountStage(tester);
      await openApp(tester, 'Safari');
      s.focusPicture(1);
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(AppKeyRow), findsNothing);
    });

    testWidgets('held back: a focused picture on iOS with app_key_row on still shows no row (showAppKeyRow)',
        (tester) async {
      final was = caps;
      caps = PlatformCaps.forOs('ios');
      addTearDown(() => caps = was);
      s.prefs.appKeyRow = true;
      await mountStage(tester);
      await openApp(tester, 'Safari');
      s.focusPicture(1);
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
      expect(s.pictureFocused, 1);
      expect(find.byType(AppKeyRow), findsNothing);
      s.currentRemote!.composer.open = true;
      await tester.pump();
      expect(find.byType(AppKeyRow), findsNothing, reason: 'nor with the writing panel open');
    });

    group('shown', skip: showAppKeyRow ? false : 'held back until the row is redesigned: showAppKeyRow (stage.dart)',
        () {
      testWidgets('on: the row floats over the picture while it has the keys, the stage keeps its size', (tester) async {
        s.prefs.appKeyRow = true;
        await mountStage(tester);
        await openApp(tester, 'Safari');
        s.focusPicture(1);
        await tester.pump();
        expect(find.byType(AppKeyRow), findsOneWidget);
        final stage = tester.getRect(find.byKey(const Key('stage')));
        expect(tester.getRect(find.byType(AppKeyRow)).bottom, stage.bottom);
        expect(stage.size, const Size(1100, 800));
        s.blurPicture();
        await tester.pump();
        expect(find.byType(AppKeyRow), findsNothing, reason: 'no focus and no panel');
        s.currentRemote!.composer.open = true;
        await tester.pump();
        expect(find.byType(AppKeyRow), findsOneWidget, reason: 'the writing panel is open');
      });

      testWidgets('with the soft keyboard up the row sits on its top edge; the stage keeps its size (Z1)',
          (tester) async {
        s.prefs.appKeyRow = true;
        await mountStage(tester, inset: 300);
        await openApp(tester, 'Safari');
        s.focusPicture(1);
        await tester.pump();
        final stage = tester.getRect(find.byKey(const Key('stage')));
        expect(stage.size, const Size(1100, 800));
        expect(tester.getRect(find.byType(AppKeyRow)).bottom, stage.bottom - 300);
      });

      testWidgets('above the home bar the row still sits on the soft keyboard (the stage ends at the safe area)',
          (tester) async {
        s.prefs.appKeyRow = true;
        await mountStage(tester, inset: 300, homeBar: 20);
        await openApp(tester, 'Safari');
        s.focusPicture(1);
        await tester.pump();
        final stage = tester.getRect(find.byKey(const Key('stage')));
        expect(tester.getRect(find.byType(AppKeyRow)).bottom, stage.bottom - 280);
      });

      testWidgets('fullscreen: the stage runs to the bottom edge, so the row sits right on the soft keyboard',
          (tester) async {
        s.prefs.appKeyRow = true;
        await mountStage(tester, inset: 300, homeBar: 20, fullscreen: true);
        await openApp(tester, 'Safari');
        s.focusPicture(1);
        await tester.pump();
        final stage = tester.getRect(find.byKey(const Key('stage')));
        expect(stage.size, const Size(1100, 800));
        expect(tester.getRect(find.byType(AppKeyRow)).bottom, stage.bottom - 300);
      });

      for (final w in [834.0, 744.0, 600.0, 507.0]) {
        testWidgets('at $w the row keeps off 「输入」 and inside the stage (iPad split view)', (tester) async {
          s.prefs.appKeyRow = true;
          await mountStage(tester, width: w);
          await openApp(tester, 'Safari');
          s.focusPicture(1);
          await tester.pump();
          expect(tester.takeException(), isNull);
          final stage = tester.getRect(find.byKey(const Key('stage')));
          final row = tester.getRect(find.byType(AppKeyRow));
          final input = tester.getRect(find.byKey(const Key('composer-open')));
          expect(row.left, greaterThanOrEqualTo(stage.left));
          expect(row.right, lessThanOrEqualTo(input.left), reason: 'row $row, 输入 $input');
          // Too narrow for all twelve: the row scrolls to the rest, the first key still whole.
          final esc = tester.getRect(key('Esc'));
          expect(esc.left, greaterThanOrEqualTo(row.left));
          if (w >= 744) {
            expect(tester.getRect(key('Return')).right, lessThanOrEqualTo(row.right), reason: 'all twelve fit at $w');
          }
        });
      }

      testWidgets('the row only over a picture: gone once the body fills the stage (disconnected), as the composer layer',
          (tester) async {
        s.prefs.appKeyRow = true;
        await mountStage(tester);
        await openApp(tester, 'Safari');
        s.focusPicture(1);
        await tester.pump();
        expect(find.byType(AppKeyRow), findsOneWidget, reason: 'a picture: not full');
        expect(find.byKey(const Key('composer-open')), findsOneWidget);
        port.emit(const DisconnectedEvent(1, 'user'));
        await tester.pump();
        await tester.pump();
        expect(find.byType(DisconnectedStage), findsOneWidget, reason: 'the body fills the stage');
        expect(find.byType(AppKeyRow), findsNothing);
        expect(find.byKey(const Key('composer-open')), findsNothing);
      });

      testWidgets('a switch to another session releases the old one\'s modifiers', (tester) async {
        s.prefs.appKeyRow = true;
        await mountStage(tester);
        await openApp(tester, 'Safari');
        s.focusPicture(1);
        await tester.pump();
        await tester.tap(key('Cmd'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(key('Cmd'));
        await tester.pump();
        expect(s.appLatch.flags, latchCmd);
        await openApp(tester, 'Notes');
        expect(keys(sid: 1).last, ('up', 55, 0));
        expect(s.appLatch.flags, 0);
      });

      testWidgets('going to the background lets go of a held ⌘ before the session closes (iPad spec §9.1)',
          (tester) async {
        s.prefs.appKeyRow = true;
        await mountStage(tester);
        await openApp(tester, 'Safari');
        s.focusPicture(1);
        await tester.pump();
        await tester.tap(key('Cmd'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(key('Cmd'));
        await tester.pump();
        expect(s.appLatch.flags, latchCmd);
        port.calls.clear();
        List<(String, Object?, Object?)>? atClose;
        final answer = t.onSend;
        t.onSend = (m) {
          if (m['cmd'] == 'close') atClose ??= keys(sid: 1);
          answer?.call(m);
        };
        unawaited(s.enterBackground());
        await tester.pump();
        expect(atClose, [('up', 55, 0)], reason: 'the up goes out before the close');
        expect(s.appLatch.flags, 0);
        await tester.pump(const Duration(seconds: 5)); // the wait for the hub's closed
      });

      testWidgets('the picture losing the keys with no panel open takes the row and its modifiers away',
          (tester) async {
        s.prefs.appKeyRow = true;
        await mountStage(tester);
        await openApp(tester, 'Safari');
        s.focusPicture(1);
        await tester.pump();
        await tester.tap(key('Ctrl'));
        await tester.pump();
        expect(s.appLatch.flags, latchCtrl);
        s.blurPicture();
        await tester.pump();
        expect(find.byType(AppKeyRow), findsNothing);
        expect(keys(sid: 1).last, ('up', 59, 0));
        expect(s.appLatch.flags, 0);
      });
    });
  });
}
