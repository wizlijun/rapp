// The key bar (iOS input toggle, Task 2): the keys of keyBarRows drawn over a terminal or an app session, sticky ⌃ ⌥ ⌘,
// repeat, paste, and the latch kept in step with A.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/key_bar_keys.dart';
import 'package:rapp/embed/modifier_latch.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/quick/key_actions.dart';
import 'package:rapp/quick/key_layout.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/platform_caps.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

const _oldTen = [
  Phrase('继续'), Phrase('确认'), Phrase('听你的'), Phrase('按你推荐的来'), Phrase('进度'),
  Phrase('全部做完，中途不用问我'), Phrase('先出方案，别改代码'), Phrase('跑一下测试'), Phrase('提交并推送'), Phrase('总结一下改了什么'),
];

void main() {
  late FakeTransport t;
  late HubClient hub;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  late Directory tmp;
  late RemoteSession app, tsess, app2, tapp;
  var copied = 0;
  var haptics = <String>[];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('key_bar_test');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"123456789"}');
    t = FakeTransport();
    hub = HubClient(t);
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(phrases: _oldTen), port: port, termPort: term);
    s.setStripItems(_oldTen); // the list these tests were written for: phrases only (the migration adds 切模式)
    term.seed(2);
    app = RemoteSession(1, 'Safari');
    tsess = RemoteSession(2, 'term');
    app2 = RemoteSession(3, 'Notes');
    tapp = RemoteSession(4, 'Terminal', appId: 'com.apple.Terminal');
    copied = 0;
  });

  tearDown(() {
    for (final r in [app, tsess, app2, tapp]) {
      r.dispose();
    }
    s.dispose();
    term.dispose();
    lastHardwareKey = null;
    tmp.deleteSync(recursive: true);
  });

  void iosTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          haptics = [];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
            if (c.method == 'HapticFeedback.vibrate') haptics.add('${c.arguments}');
            return null;
          });
          tester.view.physicalSize = const Size(1000, 900);
          tester.view.devicePixelRatio = 1;
          await body(tester);
        } finally {
          tester.view.reset();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Finder k(String id) => find.byKey(Key('bar-$id'));

  Widget bar(RemoteSession rs, {double width = 700, Widget? above}) {
    final p = rs == tsess ? term as dynamic : port;
    return wrap(Column(mainAxisSize: MainAxisSize.min, children: [
      ?above,
      SizedBox(
        width: width,
        child: KeyBar(state: s, session: rs, port: p, onCopy: rs == tsess ? () => copied++ : null),
      ),
    ]));
  }

  List<Object?> termKeys() => [for (final c in term.calls) if (c.$1 == 'keys') c.$2['keys']];
  List<(String, Object?, Object?, Object?)> appKeys() => [
        for (final c in port.calls)
          if (c.$1 == 'key' || c.$1 == 'key_event')
            (c.$1 == 'key' ? 'key' : (c.$2['down'] == true ? 'down' : 'up'), c.$2['sid'], c.$2['keyCode'], c.$2['modifiers']),
      ];

  Future<void> tap(WidgetTester tester, String id, {bool pump = true}) async {
    await tester.tap(k(id));
    if (pump) await tester.pump();
  }

  group('terminal', () {
    setUp(() => s.prefs.keyBarMore = true); // the second row holds ⌘C ⌘V ⌘T ⌘ ⌃ PgUp PgDn ← ↓ →
    iosTest('tap Esc twice sends [Esc] twice', (tester) async {
      await tester.pumpWidget(bar(tsess));
      await tap(tester, 'esc');
      await tap(tester, 'esc');
      expect(termKeys(), [
        ['Esc'],
        ['Esc'],
      ]);
    });

    iosTest('⇧Tab sends Shift-Tab; ⌃C sends Ctrl-C', (tester) async {
      s.setKeyLayout(const KeyLayout([
        ['tab', 'stab', 'esc', 'cc', 'bksp', 'enter', 'up'],
        ['copy', 'paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right'],
      ])); // ⇧Tab is not in the default row any more; put it back
      await tester.pumpWidget(bar(tsess));
      await tap(tester, 'stab');
      await tap(tester, 'cc');
      expect(termKeys(), [
        ['Shift-Tab'],
        ['Ctrl-C'],
      ]);
    });

    iosTest('⌃ once then ← sends Ctrl-Left and ⌃ goes off; double-tap ⌃ locks, two ← both Ctrl-Left', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'ctrl');
      expect(tsess.keyLatch.of(latchCtrl), LatchState.once);
      await tap(tester, 'left');
      await tester.pump(const Duration(milliseconds: 20));
      expect(termKeys(), [
        ['Ctrl-Left'],
      ]);
      expect(tsess.keyLatch.of(latchCtrl), LatchState.off);
      term.calls.clear();
      await tap(tester, 'ctrl');
      await tap(tester, 'ctrl');
      expect(tsess.keyLatch.of(latchCtrl), LatchState.locked);
      await tap(tester, 'left');
      await tester.pump(const Duration(milliseconds: 20));
      await tap(tester, 'left');
      await tester.pump(const Duration(milliseconds: 20));
      expect(termKeys(), [
        ['Ctrl-Left'],
        ['Ctrl-Left'],
      ]);
    });

    iosTest('⌘T runs the stage\'s ⌘T (termCommand t) and types nothing', (tester) async {
      final got = <String>[];
      tsess.termCommand = got.add;
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'cmdt');
      expect(got, ['t']);
      expect(term.calls.where((c) => c.$1 == 'keys' || c.$1 == 'type'), isEmpty);
    });

    iosTest('⌘ then a letter on the bar\'s session runs the rApp shortcut, not a key; ⌘ goes off', (tester) async {
      final got = <String>[];
      tsess.termCommand = got.add;
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'cmd');
      expect(tsess.keyLatch.of(latchCmd), LatchState.once);
      expect(sendLatchedLetter(s, tsess, term, 'W'), isTrue);
      expect(got, ['w']);
      expect(term.calls.where((c) => c.$1 == 'keys' || c.$1 == 'type'), isEmpty);
      expect(tsess.keyLatch.flags, 0);
    });

    iosTest('⌘ with ⌃ also lit: ⌘ wins, nothing sent; a letter rApp has no shortcut for sends nothing too', (tester) async {
      final got = <String>[];
      tsess.termCommand = got.add;
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'ctrl');
      await tap(tester, 'cmd');
      expect(sendLatchedLetter(s, tsess, term, 'x'), isTrue);
      expect(got, ['x'], reason: 'the stage decides x is nothing');
      expect(term.calls.where((c) => c.$1 == 'keys' || c.$1 == 'type'), isEmpty);
      expect(tsess.keyLatch.flags, 0);
    });

    iosTest('⌘ lit, then ← on the bar: plain Left and ⌘ goes off', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'cmd');
      await tap(tester, 'left');
      await tester.pump(const Duration(milliseconds: 20));
      expect(termKeys(), [
        ['Left'],
      ]);
      expect(tsess.keyLatch.flags, 0);
    });

    iosTest('PgUp / PgDn page the stage\'s own history (termPage) and send nothing', (tester) async {
      s.prefs.keyBarMore = true;
      final got = <bool>[];
      tsess.termPage = (up) {
        got.add(up);
        return true;
      };
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'pgup');
      await tap(tester, 'pgdn');
      await tester.pump(const Duration(milliseconds: 20));
      expect(got, [true, false]);
      expect(termKeys(), isEmpty);
    });

    iosTest('a key sent from the bar tells the stage (termSent, back to the latest); a page of history does not',
        (tester) async {
      s.prefs.keyBarMore = true;
      var sent = 0;
      tsess.termSent = () => sent++;
      tsess.termPage = (_) => true;
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'pgup');
      await tester.pump(const Duration(milliseconds: 20));
      expect(sent, 0);
      await tap(tester, 'enter');
      await tester.pump(const Duration(milliseconds: 20));
      expect(sent, 1);
    });

    iosTest('PgUp in a full-screen program (termPage false) goes to it as PageUp', (tester) async {
      s.prefs.keyBarMore = true;
      tsess.termPage = (_) => false;
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'pgup');
      await tester.pump(const Duration(milliseconds: 20));
      expect(termKeys(), [
        ['PageUp'],
      ]);
    });

    iosTest('PgUp with ⌃ lit is a key for the program, not a page of history; ⌃ goes off', (tester) async {
      s.prefs.keyBarMore = true;
      var paged = 0;
      tsess.termPage = (_) {
        paged++;
        return true;
      };
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'ctrl');
      await tap(tester, 'pgup');
      await tester.pump(const Duration(milliseconds: 20));
      expect(paged, 0);
      expect(termKeys(), [
        [termWire('PageUp', latchCtrl)],
      ]);
      expect(tsess.keyLatch.flags, 0);
    });

    iosTest('⌘C calls onCopy', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'copy');
      expect(copied, 1);
      expect(term.calls.where((c) => c.$1 == 'keys'), isEmpty);
    });
  });

  group('app', () {
    setUp(() => s.prefs.keyBarMore = true); // the second row holds ⌘C ⌘V ⌘T ⌘ ⌃ PgUp PgDn ← ↓ →
    iosTest('⇧Tab sends key(48, latchShift); ⌃ then ↑ sends key(126, latchCtrl) after keyEvent(59, down)', (tester) async {
      s.setKeyLayout(const KeyLayout([
        ['tab', 'stab', 'esc', 'cc', 'bksp', 'enter', 'up'],
        ['copy', 'paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right'],
      ])); // ⇧Tab is not in the default row any more; put it back
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'stab');
      expect(appKeys(), [('key', 1, 48, latchShift)]);
      port.calls.clear();
      await tap(tester, 'ctrl');
      await tap(tester, 'up');
      await tester.pump(const Duration(milliseconds: 20));
      expect(appKeys(), [
        ('down', 1, 59, latchCtrl),
        ('key', 1, 126, latchCtrl),
        ('up', 1, 59, 0),
      ]);
    });

    iosTest('⌘T sends key(17, latchCmd) to the app', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'cmdt');
      expect(appKeys(), [('key', 1, 17, latchCmd)]);
    });

    iosTest('PgUp / PgDn go to the app as key 116 / 121', (tester) async {
      s.prefs.keyBarMore = true;
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'pgup');
      await tap(tester, 'pgdn');
      await tester.pump(const Duration(milliseconds: 20));
      expect(appKeys(), [('key', 1, 116, 0), ('key', 1, 121, 0)]);
    });

    iosTest('⌘C sends key(8, latchCmd)', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'copy');
      expect(appKeys(), [('key', 1, 8, latchCmd)]);
    });

    iosTest('session switch with ⌘ locked sends keyEvent(55, up) for the old sid', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'cmd');
      await tap(tester, 'cmd');
      expect(s.appLatch.of(latchCmd), LatchState.locked);
      port.calls.clear();
      await tester.pumpWidget(bar(app2, width: 900));
      expect(appKeys().first, ('up', 1, 55, 0));
      expect(s.appLatch.flags, 0);
    });

    iosTest('keyed session switch with ⌘ latched: the new sid gets no modifier events', (tester) async {
      Widget keyed(RemoteSession rs) => KeyedSubtree(key: ValueKey(rs.sid), child: bar(rs, width: 900));
      await tester.pumpWidget(keyed(app));
      await tap(tester, 'cmd');
      port.calls.clear();
      await tester.pumpWidget(keyed(app2));
      await tester.pump();
      expect([for (final e in appKeys()) if (e.$2 == app2.sid) e], isEmpty);
      expect(appKeys().first, ('up', 1, 55, 0));
      expect(s.appLatch.flags, 0);
    });

    iosTest('going away releases the modifiers', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'ctrl');
      port.calls.clear();
      await tester.pumpWidget(wrap(const SizedBox()));
      expect(appKeys(), [('up', 1, 59, 0)]);
    });

    iosTest('a hardware key took the once ⌘ (latch_used): it goes up, locked stays', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'cmd');
      port.calls.clear();
      port.emit(const LatchUsedEvent(1));
      await tester.pump();
      expect(appKeys(), [('up', 1, 55, 0)]);
      expect(s.appLatch.flags, 0);
    });

    iosTest('modifier codes: ⌃ 59, ⌘ 55; each down carries every flag on, the up what stays', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'ctrl');
      await tap(tester, 'cmd');
      await tap(tester, 'enter');
      await tester.pump(const Duration(milliseconds: 20));
      const all = latchCtrl | latchCmd;
      expect(appKeys(), [
        ('down', 1, 59, latchCtrl),
        ('down', 1, 55, all),
        ('key', 1, 36, all),
        ('up', 1, 55, latchCtrl),
        ('up', 1, 59, 0),
      ]);
    });

    iosTest('releaseAll() (going to the background) sends the ups', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'ctrl');
      port.calls.clear();
      s.appLatch.releaseAll();
      await tester.pump();
      expect(appKeys(), [('up', 1, 59, 0)]);
    });

    iosTest('a hardware key took the once ⌘ with ⌃ locked: ⌘ goes up, ⌃ stays and native is told', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'cmd');
      await tap(tester, 'ctrl');
      await tester.pump(const Duration(milliseconds: 50));
      await tap(tester, 'ctrl');
      port.calls.clear();
      port.emit(const LatchUsedEvent(1));
      await tester.pump();
      expect(appKeys(), [('up', 1, 55, latchCtrl)]);
      expect([for (final c in port.calls) if (c.$1 == 'latch') c.$2['modifiers']], [latchCtrl]);
      expect(s.appLatch.of(latchCtrl), LatchState.locked);
    });

    iosTest('⌘ locked, then a hardware key (latch_used): native gets ⌘ again for the next one', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'cmd');
      await tester.pump(const Duration(milliseconds: 50));
      await tap(tester, 'cmd');
      port.calls.clear();
      port.emit(const LatchUsedEvent(1));
      await tester.pump();
      expect(appKeys(), isEmpty, reason: 'a locked ⌘ stays down on A');
      expect([for (final c in port.calls) if (c.$1 == 'latch') c.$2['modifiers']], [latchCmd]);
      expect(s.appLatch.of(latchCmd), LatchState.locked);
    });

    iosTest("another session's latch_used leaves the bar's modifiers alone", (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'cmd');
      port.calls.clear();
      port.emit(const LatchUsedEvent(2));
      await tester.pump();
      expect(appKeys(), isEmpty);
      expect([for (final c in port.calls) if (c.$1 == 'latch') c.$2['modifiers']], isEmpty);
      expect(s.appLatch.of(latchCmd), LatchState.once);
    });

    test('latch_used parses to LatchUsedEvent', () {
      final e = parseSessionEvent('latch_used', {'sid': 3});
      expect(e, isA<LatchUsedEvent>());
      expect(e!.sid, 3);
    });
  });

  group('repeat', () {
    setUp(() => s.prefs.keyBarMore = true); // the second row holds ⌘C ⌘V ⌘T ⌘ ⌃ PgUp PgDn ← ↓ →
    iosTest('hold ← : one Left at once, then at 400 ms and every 80 ms after', (tester) async {
      await tester.pumpWidget(bar(tsess));
      final g = await tester.startGesture(tester.getCenter(k('left')));
      expect(termKeys(), [
        ['Left'],
      ]);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 160));
      await g.up();
      await tester.pump();
      expect(termKeys(), [
        ['Left'],
        ['Left'],
        ['Left'],
        ['Left'],
      ]);
    });

    iosTest('a quick tap on ← sends one Left', (tester) async {
      await tester.pumpWidget(bar(tsess));
      await tap(tester, 'left');
      await tester.pump(const Duration(seconds: 1));
      expect(termKeys(), [
        ['Left'],
      ]);
    });

    iosTest('holding ⌫ sends at once, then repeats', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      final g = await tester.startGesture(tester.getCenter(k('bksp')));
      expect(termKeys().length, 1);
      await tester.pump(const Duration(milliseconds: 480));
      await g.up();
      expect(termKeys().length, 3);
    });

    iosTest('a hold keeps the first press\'s latch: ⌃ once, hold ← gives Ctrl-Left each time, latch off once', (tester) async {
      await tester.pumpWidget(bar(tsess));
      tsess.keyLatch.tap(latchCtrl);
      final g = await tester.startGesture(tester.getCenter(k('left')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tsess.keyLatch.flags, 0);
      await tester.pump(const Duration(milliseconds: 160));
      await g.up();
      expect(termKeys(), [
        ['Ctrl-Left'],
        ['Ctrl-Left'],
        ['Ctrl-Left'],
        ['Ctrl-Left'],
      ]);
    });

    iosTest('one click per press: a hold repeats without more', (tester) async {
      await tester.pumpWidget(bar(tsess));
      await tap(tester, 'esc');
      expect(haptics.length, 1);
      final g = await tester.startGesture(tester.getCenter(k('left')));
      await tester.pump(const Duration(milliseconds: 560));
      await g.up();
      expect(haptics.length, 2);
      await tap(tester, 'up');
      expect(haptics.length, 3);
    });

    iosTest('switching session mid-hold stops the repeat', (tester) async {
      await tester.pumpWidget(bar(app));
      final g = await tester.startGesture(tester.getCenter(k('left')));
      await tester.pump(const Duration(milliseconds: 500));
      final before = appKeys().where((e) => e.$1 == 'key').length;
      expect(before, greaterThan(0));
      await tester.pumpWidget(bar(app2));
      await tester.pump(const Duration(milliseconds: 500));
      expect(appKeys().where((e) => e.$1 == 'key').length, before);
      await g.up();
    });

    iosTest('a drag up on ↑ is still just ↑: no key hides behind a swipe', (tester) async {
      await tester.pumpWidget(bar(tsess));
      final g = await tester.startGesture(tester.getCenter(k('up')));
      await g.moveBy(const Offset(0, -40));
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      expect(termKeys(), [
        ['Up'],
      ]);
      expect(find.descendant(of: k('up'), matching: find.text('PgUp')), findsNothing);
    });
  });

  group('paste', () {
    setUp(() => s.prefs.keyBarMore = true); // the second row holds ⌘C ⌘V ⌘T ⌘ ⌃ PgUp PgDn ← ↓ →
    iosTest('⌘V sends the clipboard and leaves composer draft unchanged', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.getData') return {'text': 'hello'};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      app.composer.setDraft('mine');
      tsess.composer.setDraft('mine');
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'paste');
      await tester.pump();
      final sent = port.calls.where((c) => c.$1 == 'composer_send').toList();
      expect(sent.single.$2['pieces'], [
        {'text': 'hello'},
      ]);
      expect(app.composer.draft, 'mine');
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'paste');
      await tester.pump();
      expect(term.calls.where((c) => c.$1 == 'paste').single.$2['data'], 'hello');
      expect(tsess.composer.draft, 'mine');
    });

    iosTest('an empty clipboard sends nothing', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.getData') return {'text': ''};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'paste');
      await tester.pump();
      expect(term.calls.where((c) => c.$1 == 'paste'), isEmpty);
    });
  });

  group('first row', () {
    for (final width in [375.0, 900.0]) {
      iosTest('at $width: ↓ stands under ↑ and → under ⋯, ← left of ↓, each as wide as the key above', (tester) async {
        s.prefs.keyBarMore = true;
        await tester.pumpWidget(bar(tsess, width: width));
        Rect r(String id) => tester.getRect(k(id));
        expect(r('down').center.dx, moreOrLessEquals(r('up').center.dx, epsilon: .01));
        expect(r('down').width, moreOrLessEquals(r('up').width, epsilon: .01));
        expect(r('right').center.dx, moreOrLessEquals(r('more').center.dx, epsilon: .01));
        expect(r('down').top, greaterThan(r('up').bottom));
        expect(r('left').right, lessThan(r('down').left));
        expect(r('left').width, moreOrLessEquals(r('down').width, epsilon: .01));
        expect(r('left').center.dy, r('down').center.dy);
      });
    }

    iosTest('⌫ is there without ⋯ and ⌃ is not: ⌃ (second row) then ⌫ sends Ctrl-Backspace', (tester) async {
      await tester.pumpWidget(bar(tsess));
      expect(s.prefs.keyBarMore, isFalse);
      expect(k('ctrl'), findsNothing);
      expect(k('cmd'), findsNothing);
      await tap(tester, 'bksp');
      await tap(tester, 'more');
      await tap(tester, 'ctrl');
      await tap(tester, 'bksp');
      expect(termKeys(), [
        ['Backspace'],
        ['Ctrl-Backspace'],
      ]);
    });

    iosTest('left to right: Tab Esc ⌃C ⌫ ⏎ ↑ ⋯, no ⌄', (tester) async {
      await tester.pumpWidget(bar(tsess));
      expect(k('hide'), findsNothing);
      expect(find.descendant(of: find.byType(KeyBar), matching: find.bySemanticsLabel('收起快捷区')), findsNothing);
      const order = ['tab', 'esc', 'cc', 'bksp', 'enter', 'up', 'more'];
      final xs = [for (final id in order) tester.getCenter(k(id)).dx];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: '${order[i]} is right of ${order[i - 1]}');
      }
      final ys = {for (final id in order) tester.getCenter(k(id)).dy};
      expect(ys.length, 1);
    });

    iosTest('← ↓ → wait on the second row', (tester) async {
      await tester.pumpWidget(bar(tsess));
      expect(k('left'), findsNothing);
      expect(k('down'), findsNothing);
      expect(k('right'), findsNothing);
      await tap(tester, 'more');
      await tester.pump();
      await tap(tester, 'left');
      await tester.pump(const Duration(milliseconds: 20));
      expect(termKeys(), [
        ['Left'],
      ]);
    });

    iosTest('second row left to right: ⌘C ⌘V ⌘T ⌘ ⌃ PgUp PgDn ← ↓ →, on a terminal and on an app', (tester) async {
      s.prefs.keyBarMore = true;
      const order = ['copy', 'paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right'];
      for (final rs in [tsess, app]) {
        await tester.pumpWidget(bar(rs, width: 900));
        final xs = [for (final id in order) tester.getCenter(k(id)).dx];
        for (var i = 1; i < xs.length; i++) {
          expect(xs[i], greaterThan(xs[i - 1]), reason: '${order[i]} is right of ${order[i - 1]} (${rs.appName})');
        }
        expect(find.descendant(of: k('cmdt'), matching: find.text('⌘T')), findsOneWidget);
        expect(k('opt'), findsNothing);
      }
    });

    iosTest('the copy and paste keys read ⌘C and ⌘V', (tester) async {
      s.prefs.keyBarMore = true;
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(find.descendant(of: k('copy'), matching: find.text('⌘C')), findsOneWidget);
      expect(find.descendant(of: k('paste'), matching: find.text('⌘V')), findsOneWidget);
      expect(find.text('复制'), findsNothing);
      expect(find.text('粘贴'), findsNothing);
    });
  });

  group('state of the bar', () {
    iosTest('blocked: keys grey, taps send nothing', (tester) async {
      t.emit({'event': 'hosts', 'hosts': [{'id': '111', 'name': 'mini'}]});
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'port': 5001, 'token': 'tk', 'req': m['req']});
          }
        };
        s.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      expect(s.sendBlocked(1), isTrue);
      await tester.pumpWidget(bar(app));
      port.calls.clear();
      await tester.tap(k('esc'));
      await tester.tap(k('up'));
      await tester.pump(const Duration(seconds: 1));
      expect(appKeys(), isEmpty);
      expect(haptics, isEmpty);
      expect(tester.widget<Opacity>(find.descendant(of: k('esc'), matching: find.byType(Opacity))).opacity, lessThan(1));
    });

    iosTest('keys never take focus: a focused editor stays focused after a tap', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(bar(tsess, above: TextField(focusNode: node)));
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      await tap(tester, 'esc');
      await tap(tester, 'tab');
      expect(node.hasFocus, isTrue);
    });

    iosTest('⋯ shows the second row and writes prefs.keyBarMore', (tester) async {
      await tester.pumpWidget(bar(tsess));
      expect(k('left'), findsNothing);
      await tap(tester, 'more');
      expect(s.prefs.keyBarMore, isTrue);
      await tester.pump();
      expect(k('left'), findsOneWidget);
      expect(tester.getSize(find.byType(KeyBar)).height, keyBarHeightOf(s, tsess));
      expect(keyBarHeightOf(s, tsess), 100 + phraseStripHeight);
      await tap(tester, 'more');
      expect(s.prefs.keyBarMore, isFalse);
      expect(File('${tmp.path}/devices/123456789/gui.json').readAsStringSync(), contains('"key_bar_more":false'));
    });

    iosTest('⋯ folding the second row lets go of a lit ⌃ and ⌘ (terminal); on an app their ups go to A', (tester) async {
      s.prefs.keyBarMore = true;
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'ctrl');
      await tap(tester, 'cmd');
      expect(tsess.keyLatch.flags, latchCtrl | latchCmd);
      await tap(tester, 'more');
      expect(s.prefs.keyBarMore, isFalse);
      expect(tsess.keyLatch.flags, 0);
      await tap(tester, 'more');
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'ctrl');
      port.calls.clear();
      await tap(tester, 'more');
      expect(s.appLatch.flags, 0);
      expect(appKeys(), [('up', 1, 59, 0)]);
      await tap(tester, 'more');
      expect(s.prefs.keyBarMore, isTrue);
      expect(s.appLatch.flags, 0, reason: 'opening the row lights nothing');
    });

    iosTest('the 更多按键 switch turning the second row off lets go too: every terminal, and the app\'s ups go to A', (tester) async {
      s.remote[tsess.sid] = tsess;
      try {
        s.prefs.keyBarMore = true;
        await tester.pumpWidget(bar(app, width: 900));
        await tap(tester, 'cmd');
        tsess.keyLatch.tap(latchCtrl);
        port.calls.clear();
        s.setKeyBarMore(false);
        await tester.pump();
        expect(s.appLatch.flags, 0);
        expect(appKeys(), [('up', 1, 55, 0)]);
        expect(tsess.keyLatch.flags, 0);
      } finally {
        s.remote.remove(tsess.sid);
      }
    });

    iosTest('the bar is as high as keyBarHeightOf says, even at zoom 1.75 widths', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 1260));
      expect(tester.getSize(find.byType(KeyBar)).height, 54 + phraseStripHeight);
      expect(keyBarHeightOf(s, tsess), 54 + phraseStripHeight);
      expect(k('more'), findsOneWidget);
    });

  });

  group('常用语条', () {
    Finder ph(String id) => find.byKey(Key(id));

    iosTest('on a terminal: the strip tops the bar, 36 more; off globally it goes and the bar is 54', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(ph('phrase-0'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(ph('quick-menu-keys'), findsOneWidget);
      expect(ph('quick-menu-phrases'), findsOneWidget);
      expect(tester.getSize(find.byType(KeyBar)).height, 90);
      s.setPhraseStrip(false);
      await tester.pump();
      expect(ph('phrase-0'), findsNothing);
      expect(tester.getSize(find.byType(KeyBar)).height, 54);
    });

    iosTest('an app only when its profile says 常用语条', (tester) async {
      await tester.pumpWidget(bar(app));
      expect(ph('phrase-0'), findsNothing);
      expect(phraseStripShown(s, app), isFalse);
      app.setProfile(const ResolvedProfile(phrases: true));
      await tester.pumpWidget(bar(app));
      expect(ph('phrase-0'), findsOneWidget);
    });

    iosTest('no phrases: the strip still shows, its two menus alone', (tester) async {
      s.setStripItems(const []);
      s.setKeyActions(const []);
      expect(phraseStripShown(s, tsess), isTrue);
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(ph('phrase-0'), findsNothing);
      expect(ph('quick-menu-phrases'), findsOneWidget);
      expect(tester.getSize(find.byType(KeyBar)).height, 90);
      s.setPhraseStrip(false);
      expect(phraseStripShown(s, tsess), isFalse);
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.linux]) {
      testWidgets('${platform.name}: the 常用语条 shows whatever the quick state was (no slim rule) and the bar height adds phraseStripHeight', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          for (final hidden in [false, true]) {
            s.prefs.quickHiddenTerm = hidden;
            expect(phraseStripShown(s, tsess), isTrue);
            expect(keyBarHeightOf(s, tsess), keyBarHeight(1) + phraseStripHeight);
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    iosTest('a tap sends the text, ✓ and a light tap', (tester) async {
      app.setProfile(const ResolvedProfile(phrases: true));
      await tester.pumpWidget(bar(app));
      port.calls.clear();
      await tester.tap(ph('phrase-0'));
      await tester.pump();
      final sends = [for (final c in port.calls) if (c.$1 == 'composer_send') c.$2];
      expect(sends, hasLength(1));
      expect(sends.single.toString(), contains('继续'));
      expect(find.descendant(of: ph('phrase-0'), matching: find.byIcon(Icons.check)), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      await tester.pump(phraseTickTime);
      expect(find.byIcon(Icons.check), findsNothing);
      await tester.pump(phraseRepeatWindow);
    });

    iosTest('long press: 打星 and 删除, nothing sent', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      term.calls.clear();
      await tester.longPress(ph('phrase-1'));
      await tester.pumpAndSettle();
      await tester.tap(ph('phrase-menu-star'));
      await tester.pumpAndSettle();
      expect(s.quick.stars, ['p:${(s.quick.phrases[1] as Phrase).id}']);
      expect(ph('phrase-0'), findsNothing, reason: 'a star: the row is the starred alone');
      await tester.longPress(ph('phrase-1'));
      await tester.pumpAndSettle();
      await tester.tap(ph('phrase-menu-delete'));
      await tester.pumpAndSettle();
      expect((s.quick.phrases.first as Phrase).text, '继续');
      expect(s.quick.phrases, hasLength(_oldTen.length - 1));
      expect(s.quick.stars, isEmpty);
      expect(ph('phrase-0'), findsOneWidget);
      expect(term.calls.where((c) => c.$1 != 'composer'), isEmpty);
    });

    iosTest('常用语▾: the whole list; a tap sends and closes it', (tester) async {
      app.setProfile(const ResolvedProfile(phrases: true));
      await tester.pumpWidget(bar(app));
      await tester.tap(ph('quick-menu-phrases'));
      await tester.pumpAndSettle();
      expect(ph('menu-p-9'), findsOneWidget);
      port.calls.clear();
      await tester.tap(ph('menu-p-2'));
      await tester.pumpAndSettle();
      expect(ph('menu-p-2'), findsNothing);
      expect(port.calls.where((c) => c.$1 == 'composer_send').single.$2.toString(), contains('听你的'));
      await tester.pump(phraseRepeatWindow);
    });
  });

  group('a key typed into the picture folds the quick area', () {
    // A terminal app (terminalApps) is an app picture: focusPicture sets pictureFocused for it, and it folds the
    // terminal kind's pref. A text terminal's stage has the keys by its own Focus: term_stage_latch_test covers it
    // with the real stage, and the helper test below with termTakesKey.
    void deskTest(String name, Future<void> Function(WidgetTester) body, {bool macOnly = false}) {
      for (final platform in [TargetPlatform.macOS, if (!macOnly) TargetPlatform.linux]) {
        testWidgets('${platform.name}: $name', (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }

    deskTest('a letter typed into the focused picture folds; typed with the editor focused it does not', (tester) async {
      await tester.pumpWidget(bar(tapp));
      s.pictureFocused = tapp.sid;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(quickHidden(s, tapp), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(quickHidden(s, tapp), isTrue);
      expect(s.prefs.quickHiddenApp, isTrue, reason: 'the other kind is untouched');
      s.setQuickHidden(term: termKind(s, tapp), hidden: false);
      await tester.pump();
      expect(quickHidden(s, tapp), isFalse);
      tapp.composer.editorFocused = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(quickHidden(s, tapp), isFalse, reason: 'the editor has the key');
      tapp.composer.editorFocused = false;
      s.pictureFocused = null;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(quickHidden(s, tapp), isFalse, reason: 'the picture has no focus');
    });

    deskTest('an app folds quick_hidden_app, not the terminal pref', (tester) async {
      s.setQuickHidden(term: false, hidden: false);
      await tester.pumpWidget(bar(app));
      s.pictureFocused = app.sid;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(s.prefs.quickHiddenApp, isTrue);
      expect(s.prefs.quickHiddenTerm, isFalse);
    });

    deskTest('quick_auto_hide off: a picture key does not fold', (tester) async {
      s.setQuickAutoHide(false);
      await tester.pumpWidget(bar(tapp));
      s.pictureFocused = tapp.sid;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(quickHidden(s, tapp), isFalse);
    });

    deskTest('a repeat does not fold; no bar, no listening', (tester) async {
      await tester.pumpWidget(bar(tapp));
      s.pictureFocused = tapp.sid;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(s.prefs.quickHiddenTerm, isTrue);
      s.setQuickHidden(term: true, hidden: false);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(s.prefs.quickHiddenTerm, isFalse);
      await tester.pumpWidget(wrap(const SizedBox()));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(s.prefs.quickHiddenTerm, isFalse);
    });

    deskTest('macOS: key_typed from the picture folds its own session\'s bar; not while ⌘ on the bar is lit', (tester) async {
      expect(parseSessionEvent('key_typed', {'sid': 1}), isA<KeyTypedEvent>().having((e) => e.sid, 'sid', 1));
      s.setQuickHidden(term: false, hidden: false);
      s.prefs.keyBarMore = true;
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(bar(app, width: 900));
      port.emit(const KeyTypedEvent(3)); // another session's
      await tester.pump();
      expect(quickHidden(s, app), isFalse);
      await tap(tester, 'cmd');
      port.emit(const KeyTypedEvent(1));
      await tester.pump();
      expect(quickHidden(s, app), isFalse, reason: 'a lit ⌘ stays in sight');
      await tap(tester, 'cmd');
      await tap(tester, 'cmd'); // locked, then off
      expect(keyLatchOf(s, app).flags, 0);
      port.emit(const KeyTypedEvent(1));
      await tester.pump();
      expect(quickHidden(s, app), isTrue);
    }, macOnly: true);

    testWidgets('iOS with quick_auto_hide turned on: a hardware key into the picture folds', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        s.setQuickAutoHide(true);
        await tester.pumpWidget(bar(tapp));
        s.pictureFocused = tapp.sid;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(quickHidden(s, tapp), isTrue);
        s.setQuickHidden(term: true, hidden: false);
        tapp.composer.editorFocused = true;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(quickHidden(s, tapp), isFalse, reason: 'the iOS editor has the key');
        tapp.composer.editorFocused = false;
        s.setQuickAutoHide(false);
        s.pictureFocused = tapp.sid;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(quickHidden(s, tapp), isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Linux: first row has 7 keys ending in ↑ ⋯; second row has ⌘C ⌘V ⌘T ⌘ ⌃', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(bar(tsess, width: 720));
        const first = ['tab', 'esc', 'cc', 'bksp', 'enter', 'up', 'more'];
        final xs = [for (final id in first) tester.getCenter(k(id)).dx];
        for (var i = 1; i < xs.length; i++) {
          expect(xs[i], greaterThan(xs[i - 1]), reason: '${first[i]} right of ${first[i - 1]}');
        }
        await tap(tester, 'bksp');
        await tap(tester, 'more');
        await tester.pump();
        await tap(tester, 'ctrl');
        await tap(tester, 'bksp');
        expect(termKeys(), [
          ['Backspace'],
          ['Ctrl-Backspace'],
        ]);
        expect(find.descendant(of: k('copy'), matching: find.text('⌘C')), findsOneWidget);
        expect(find.descendant(of: k('paste'), matching: find.text('⌘V')), findsOneWidget);
        expect(find.descendant(of: k('copy'), matching: find.bySemanticsLabel('复制')), findsOneWidget);
        expect(find.descendant(of: k('paste'), matching: find.bySemanticsLabel('粘贴')), findsOneWidget);
        expect(k('cd'), findsNothing);
        expect(k('hide'), findsNothing);
        expect(k('cmdt'), findsOneWidget);
        expect(k('cmd'), findsOneWidget);
        expect(k('pgup'), findsOneWidget);
        expect(k('pgdn'), findsOneWidget);
        expect((tester.getCenter(k('down')).dx - tester.getCenter(k('up')).dx).abs(), lessThan(0.5));
        expect((tester.getCenter(k('right')).dx - tester.getCenter(k('more')).dx).abs(), lessThan(0.5));
        await tester.pumpWidget(bar(app, width: 720));
        port.calls.clear();
        await tap(tester, 'cmdt');
        expect(appKeys(), [('key', 1, 17, latchCmd)]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Linux: Ctrl-held keys (the app shortcuts) do not fold', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.pumpWidget(bar(tapp));
        s.pictureFocused = tapp.sid;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('typedIntoPicture: a text terminal by its stage\'s Focus, an app by pictureFocused; never the editor\'s', () {
      const a = KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA, logicalKey: LogicalKeyboardKey.keyA, character: 'a', timeStamp: Duration.zero);
      expect(typedIntoPicture(s, tsess, a), isFalse, reason: 'no stage mounted');
      var keys = true;
      KeyEvent? asked;
      tsess.termTakesKey = (e) {
        asked = e;
        return keys;
      };
      expect(typedIntoPicture(s, tsess, a), isTrue);
      expect(asked, same(a), reason: 'the stage is asked about this key (a voice hold may own it)');
      tsess.composer.editorFocused = true;
      expect(typedIntoPicture(s, tsess, a), isFalse, reason: 'the editor has the keys');
      tsess.composer.editorFocused = false;
      s.voiceMouseHold = tsess.sid;
      expect(typedIntoPicture(s, tsess, a), isFalse, reason: 'a mouse hold on 语音 owns the keys');
      s.voiceMouseHold = null;
      keys = false;
      expect(typedIntoPicture(s, tsess, a), isFalse);
      expect(typedIntoPicture(s, tapp, a), isFalse);
      s.pictureFocused = tapp.sid;
      expect(typedIntoPicture(s, tapp, a), isTrue);
      expect(termKind(s, tapp), isTrue, reason: 'a terminal app folds quick_hidden_term');
    });

    test('collapsesKeyBar: downs of non-modifier keys without ⌘', () {
      KeyDownEvent down(LogicalKeyboardKey l) =>
          KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: l, timeStamp: Duration.zero);
      expect(collapsesKeyBar(down(LogicalKeyboardKey.keyA)), isTrue);
      expect(collapsesKeyBar(down(LogicalKeyboardKey.enter)), isTrue);
      for (final m in [
        LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.controlRight, LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.capsLock, LogicalKeyboardKey.fn, LogicalKeyboardKey.altGraph,
        LogicalKeyboardKey.numLock,
      ]) {
        expect(collapsesKeyBar(down(m)), isFalse, reason: '$m');
      }
      expect(
          collapsesKeyBar(const KeyUpEvent(
              physicalKey: PhysicalKeyboardKey.keyA, logicalKey: LogicalKeyboardKey.keyA, timeStamp: Duration.zero)),
          isFalse);
    });
  });

  group('the bar follows the user\'s layout', () {
    iosTest('a custom layout: ⋯ ends row 1, ↑ sits over ← ↓ →', (tester) async {
      s.prefs.keyBarMore = true;
      s.setKeyLayout(const KeyLayout([
        ['pgup', 'esc', 'up'],
        ['left', 'down', 'right'],
      ]));
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(tester.getTopLeft(k('pgup')).dy, tester.getTopLeft(k('more')).dy);
      expect(tester.getTopLeft(k('more')).dx, greaterThan(tester.getTopLeft(k('up')).dx));
      expect(tester.getTopLeft(k('left')).dy, greaterThan(tester.getTopLeft(k('up')).dy));
      // The inverted T: ↓ under ↑, → under ⋯, ← one column before.
      expect(tester.getTopLeft(k('down')).dx, tester.getTopLeft(k('up')).dx);
      expect(tester.getTopLeft(k('right')).dx, tester.getTopLeft(k('more')).dx);
      expect(tester.getTopLeft(k('left')).dx, lessThan(tester.getTopLeft(k('up')).dx));
    });

    iosTest('a key action in row 1 draws, keeps the grid and ↑ stays over ←', (tester) async {
      s.prefs.keyBarMore = true;
      s.setKeyLayout(const KeyLayout([
        ['esc', 'k:search', 'up'],
        ['left', 'down', 'right'],
      ]));
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(find.byKey(const Key('bar-k-search')), findsOneWidget);
      expect(tester.getTopLeft(k('down')).dx, tester.getTopLeft(k('up')).dx);
      expect(tester.getTopLeft(k('right')).dx, tester.getTopLeft(k('more')).dx);
    });

    iosTest('row 1 without ⋯ (no row 2): no more, bar is one row', (tester) async {
      s.setKeyLayout(const KeyLayout([
        ['esc', 'up'],
        <String>[],
      ]));
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(k('more'), findsNothing);
      expect(k('esc'), findsOneWidget);
      expect(keyBarHeightOf(s, tsess), keyBarHeight(1) + (phraseStripShown(s, tsess) ? phraseStripHeight : 0));
    });

    iosTest('a key action cell sends its chord (Ctrl-R) and counts no use', (tester) async {
      s.setKeyLayout(const KeyLayout([
        ['esc', 'k:search'],
        <String>[],
      ]));
      await tester.pumpWidget(bar(tsess, width: 900));
      await tester.tap(find.byKey(const Key('bar-k-search')));
      await tester.pump();
      expect(termKeys(), [
        ['Ctrl-R'],
      ]);
      expect(s.quick.usage.isEmpty, isTrue);
    });

    iosTest('an unusable key action (⌘K on a terminal) is drawn grey and sends nothing', (tester) async {
      s.setKeyActions([const KeyAction('ck', label: '清屏', chord: Chord('k', cmd: true))]);
      s.setKeyLayout(const KeyLayout([
        ['esc', 'k:ck'],
        <String>[],
      ]));
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(find.byKey(const Key('bar-k-ck')), findsOneWidget);
      final dim = find.descendant(of: find.byKey(const Key('bar-k-ck')), matching: find.byType(Opacity));
      expect(tester.widget<Opacity>(dim.first).opacity, .4, reason: 'drawn blocked/grey');
      await tester.tap(find.byKey(const Key('bar-k-ck')));
      await tester.pump();
      expect(term.calls.where((c) => c.$1 == 'keys'), isEmpty);
    });

    iosTest('a synced row 1 of 11 distinct cells draws 9 of them and ⋯ at the end, no overflow', (tester) async {
      s.prefs.keyBarMore = true;
      s.quick.adopt('layout', const QuickDoc(9000, {
        'rows': [
          ['esc', 'tab', 'stab', 'cc', 'cr', 'co', 'ct', 'cb', 'cl', 'bksp', 'enter'],
          ['left', 'down', 'right'],
        ],
      }));
      await tester.pumpWidget(bar(tsess, width: 1000));
      expect(tester.takeException(), isNull);
      final row1 = tester.getTopLeft(k('esc')).dy;
      final drawn = [
        for (final id in ['esc', 'tab', 'stab', 'cc', 'cr', 'co', 'ct', 'cb', 'cl', 'bksp', 'enter', 'more'])
          if (k(id).evaluate().isNotEmpty && tester.getTopLeft(k(id)).dy == row1) id,
      ];
      expect(drawn, ['esc', 'tab', 'stab', 'cc', 'cr', 'co', 'ct', 'cb', 'cl', 'more']);
      expect(k('bksp'), findsNothing);
      final xs = [for (final id in drawn) tester.getTopLeft(k(id)).dx];
      expect(xs.last, xs.reduce((a, b) => a > b ? a : b), reason: '⋯ is last in the row');
    });

    iosTest('a synced layout with a missing action and repeated ids draws each once', (tester) async {
      s.prefs.keyBarMore = true;
      s.quick.adopt('layout', const QuickDoc(9000, {
        'rows': [
          ['esc', 'k:gone', 'tab', 'tab', 'cc', 'k:search', 'k:search'],
          ['left', 'down', 'right'],
        ],
      }));
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('bar-k-search')), findsOneWidget);
      expect(find.byKey(const Key('bar-tab')), findsOneWidget);
      expect(find.byKey(const Key('bar-k-gone')), findsNothing);
    });

    iosTest('↑ not directly before ⋯: the user\'s order wins, ← ↓ → stay right-aligned under ⋯', (tester) async {
      s.prefs.keyBarMore = true;
      s.setKeyLayout(const KeyLayout([
        ['esc', 'up', 'k:search'],
        ['left', 'down', 'right'],
      ]));
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(k('right')).dx, tester.getTopLeft(k('more')).dx);
      final col = tester.getSize(k('more')).width + keyBarGap;
      expect(tester.getTopLeft(k('down')).dx, tester.getTopLeft(k('more')).dx - col);
    });

    iosTest('an empty second row hides ⋯', (tester) async {
      s.prefs.keyBarMore = true;
      s.setKeyLayout(const KeyLayout([
        ['esc', 'tab'],
        <String>[],
      ]));
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(k('more'), findsNothing);
    });
  });

  group('helpers', () {
    test('keyLatchOf: a terminal has its own, an app the state\'s', () {
      expect(identical(keyLatchOf(s, tsess), tsess.keyLatch), isTrue);
      expect(identical(keyLatchOf(s, app), s.appLatch), isTrue);
    });

    test('sendLatchedLetter: false with nothing latched', () {
      expect(sendLatchedLetter(s, tsess, term, 'r'), isFalse);
      expect(term.calls.where((c) => c.$1 == 'keys'), isEmpty);
    });

    test('sendLatchedLetter: with ⌃ once on a terminal sends Ctrl-R, latch off after', () {
      tsess.keyLatch.tap(latchCtrl);
      expect(sendLatchedLetter(s, tsess, term, 'r'), isTrue);
      expect(termKeys(), [
        ['Ctrl-R'],
      ]);
      expect(tsess.keyLatch.flags, 0);
    });

    test('sendLatchedLetter: ⌥ on a terminal sends Alt-r', () {
      tsess.keyLatch.tap(latchOpt);
      expect(sendLatchedLetter(s, tsess, term, 'r'), isTrue);
      expect(termKeys(), [
        ['Alt-r'],
      ]);
    });

    test('sendLatchedLetter: ⌃ on an app sends the mac code with the flag', () {
      s.appLatch.tap(latchCtrl);
      expect(sendLatchedLetter(s, app, port, 'r'), isTrue);
      expect(appKeys(), [('key', 1, macLetterCodes['r'], latchCtrl)]);
      expect(s.appLatch.flags, 0);
    });
  });
}
