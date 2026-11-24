// The key bar (iOS input toggle, Task 2): the keys of keyBarRows drawn over a terminal or an app session, sticky ⌃ ⌥ ⌘,
// repeat, swipe up, paste, and the latch kept in step with A.
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
import 'package:rapp/paths.dart';
import 'package:rapp/platform_caps.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

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
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
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
    setUp(() => s.prefs.keyBarMore = true); // the second row holds ⌃ ⌥ ⌘ and copy / paste
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

    iosTest('⌥ then Enter sends Alt-Enter', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'opt');
      await tap(tester, 'enter');
      expect(termKeys(), [
        ['Alt-Enter'],
      ]);
    });

    iosTest('⌃ and ⌥ on a key that already has Ctrl: Ctrl-Alt-C, Ctrl not doubled', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'ctrl');
      await tap(tester, 'opt');
      await tap(tester, 'cc');
      expect(termKeys(), [
        ['Ctrl-Alt-C'],
      ]);
    });

    iosTest('复制 calls onCopy', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      await tap(tester, 'copy');
      expect(copied, 1);
      expect(term.calls.where((c) => c.$1 == 'keys'), isEmpty);
    });
  });

  group('app', () {
    setUp(() => s.prefs.keyBarMore = true); // the second row holds ⌃ ⌥ ⌘ and copy / paste
    iosTest('⇧Tab sends key(48, latchShift); ⌃ then ↑ sends key(126, latchCtrl) after keyEvent(59, down)', (tester) async {
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

    iosTest('复制 sends key(8, latchCmd)', (tester) async {
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
      await tap(tester, 'opt');
      port.calls.clear();
      await tester.pumpWidget(wrap(const SizedBox()));
      expect(appKeys(), [('up', 1, 58, 0)]);
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

    iosTest('modifier codes: ⌥ 58, ⌃ 59, ⌘ 55; each down carries every flag on, the up what stays', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'opt');
      await tap(tester, 'ctrl');
      await tap(tester, 'cmd');
      await tap(tester, 'enter');
      await tester.pump(const Duration(milliseconds: 20));
      const all = latchOpt | latchCtrl | latchCmd;
      expect(appKeys(), [
        ('down', 1, 58, latchOpt),
        ('down', 1, 59, latchOpt | latchCtrl),
        ('down', 1, 55, all),
        ('key', 1, 36, all),
        ('up', 1, 55, latchOpt | latchCtrl),
        ('up', 1, 58, latchCtrl),
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

    iosTest('a hardware key took the once ⌘ with ⌥ locked: ⌘ goes up, ⌥ stays and native is told', (tester) async {
      await tester.pumpWidget(bar(app, width: 900));
      await tap(tester, 'cmd');
      await tap(tester, 'opt');
      await tester.pump(const Duration(milliseconds: 50));
      await tap(tester, 'opt');
      port.calls.clear();
      port.emit(const LatchUsedEvent(1));
      await tester.pump();
      expect(appKeys(), [('up', 1, 55, latchOpt)]);
      expect([for (final c in port.calls) if (c.$1 == 'latch') c.$2['modifiers']], [latchOpt]);
      expect(s.appLatch.of(latchOpt), LatchState.locked);
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

  group('repeat and swipe', () {
    setUp(() => s.prefs.keyBarMore = true); // the second row holds ⌃ ⌥ ⌘ and copy / paste
    iosTest('hold ← 400 ms then 160 ms: three Left', (tester) async {
      await tester.pumpWidget(bar(tsess));
      final g = await tester.startGesture(tester.getCenter(k('left')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 160));
      await g.up();
      await tester.pump();
      expect(termKeys(), [
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
      ]);
    });

    iosTest('once repeating, a later swipe up does not fire the alt on release', (tester) async {
      await tester.pumpWidget(bar(tsess));
      final g = await tester.startGesture(tester.getCenter(k('up')));
      await tester.pump(const Duration(milliseconds: 400));
      await g.moveBy(const Offset(0, -40));
      await g.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(termKeys().every((e) => (e as List).single == 'Up'), isTrue);
    });

    iosTest('one click per press: a hold repeats without more, a swipe clicks once', (tester) async {
      await tester.pumpWidget(bar(tsess));
      await tap(tester, 'esc');
      expect(haptics.length, 1);
      final g = await tester.startGesture(tester.getCenter(k('left')));
      await tester.pump(const Duration(milliseconds: 560));
      await g.up();
      expect(haptics.length, 2);
      final g2 = await tester.startGesture(tester.getCenter(k('up')));
      await g2.moveBy(const Offset(0, -30));
      await g2.up();
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

    iosTest('swipe up on ↑ sends PageUp, not Up', (tester) async {
      await tester.pumpWidget(bar(tsess));
      final g = await tester.startGesture(tester.getCenter(k('up')));
      await g.moveBy(const Offset(0, -30));
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      expect(termKeys(), [
        ['PageUp'],
      ]);
    });

    iosTest('a short drag up (under 24) still sends the key', (tester) async {
      await tester.pumpWidget(bar(tsess));
      final g = await tester.startGesture(tester.getCenter(k('up')));
      await g.moveBy(const Offset(0, -10));
      await g.up();
      expect(termKeys(), [
        ['Up'],
      ]);
    });
  });

  group('paste', () {
    setUp(() => s.prefs.keyBarMore = true); // the second row holds ⌃ ⌥ ⌘ and copy / paste
    iosTest('粘贴 sends the clipboard and leaves composer draft unchanged', (tester) async {
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
      await tester.tap(k('left'));
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
      expect(k('bksp'), findsNothing);
      await tap(tester, 'more');
      expect(s.prefs.keyBarMore, isTrue);
      await tester.pump();
      expect(k('bksp'), findsOneWidget);
      expect(tester.getSize(find.byType(KeyBar)).height, keyBarHeightOf(s, tsess));
      expect(keyBarHeightOf(s, tsess), 100 + phraseStripHeight);
      await tap(tester, 'more');
      expect(s.prefs.keyBarMore, isFalse);
      expect(File('${tmp.path}/devices/123456789/gui.json').readAsStringSync(), contains('"key_bar_more":false'));
    });

    iosTest('⊙ is always the last key of the first row', (tester) async {
      await tester.pumpWidget(bar(tsess));
      expect(k('hide'), findsOneWidget);
      expect(k('more'), findsOneWidget);
      expect(find.bySemanticsLabel('收起快捷区'), findsOneWidget);
    });

    iosTest('⊙ hides the quick area of its kind: a terminal sets quick_hidden_term, Safari quick_hidden_app', (tester) async {
      await tester.pumpWidget(bar(tsess));
      expect(s.prefs.quickHiddenTerm, isFalse);
      await tap(tester, 'hide');
      expect(s.prefs.quickHiddenTerm, isTrue);
      expect(s.prefs.quickHiddenApp, isTrue);
      s.setQuickHidden(term: false, hidden: false);
      await tester.pumpWidget(bar(app));
      await tap(tester, 'hide');
      expect(s.prefs.quickHiddenApp, isTrue);
      expect(s.prefs.quickHiddenTerm, isTrue);
      await tester.pumpWidget(bar(tsess));
      await tap(tester, 'hide'); // ⊙ toggles: the terminal kind is shown again
      expect(s.prefs.quickHiddenTerm, isFalse);
      expect(s.prefs.quickHiddenApp, isTrue);
    });

    iosTest('the bar is as high as keyBarHeightOf says, even at zoom 1.75 widths', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 1260));
      expect(tester.getSize(find.byType(KeyBar)).height, 54 + phraseStripHeight);
      expect(keyBarHeightOf(s, tsess), 54 + phraseStripHeight);
      expect(k('more'), findsOneWidget);
    });

    iosTest('an arrow shows its swipe-up label in the corner', (tester) async {
      await tester.pumpWidget(bar(tsess));
      expect(find.descendant(of: k('up'), matching: find.text('PgUp')), findsOneWidget);
    });
  });

  group('常用语条', () {
    Finder ph(String id) => find.byKey(Key(id));

    iosTest('on a terminal: the strip tops the bar, 36 more; off globally it goes and the bar is 54', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      expect(ph('phrase-0'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(ph('phrases-all'), findsOneWidget);
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

    iosTest('no phrases: no strip', (tester) async {
      s.setPhrases(const []);
      expect(phraseStripShown(s, tsess), isFalse);
      s.setPhrases(defaultPhrases);
      expect(phraseStripShown(s, tsess), isTrue);
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

    iosTest('long press: 移到最前 and 删除, nothing sent', (tester) async {
      await tester.pumpWidget(bar(tsess, width: 900));
      term.calls.clear();
      await tester.longPress(ph('phrase-1'));
      await tester.pumpAndSettle();
      await tester.tap(ph('phrase-menu-first'));
      await tester.pumpAndSettle();
      expect(s.prefs.phrases.first.text, '确认');
      await tester.longPress(ph('phrase-0'));
      await tester.pumpAndSettle();
      await tester.tap(ph('phrase-menu-delete'));
      await tester.pumpAndSettle();
      expect(s.prefs.phrases.first.text, '继续');
      expect(s.prefs.phrases, hasLength(defaultPhrases.length - 1));
      expect(term.calls.where((c) => c.$1 != 'composer'), isEmpty);
    });

    iosTest('全部 ›: the whole list; a tap sends and closes it', (tester) async {
      app.setProfile(const ResolvedProfile(phrases: true));
      await tester.pumpWidget(bar(app));
      await tester.tap(ph('phrases-all'));
      await tester.pumpAndSettle();
      expect(ph('phrases-all-9'), findsOneWidget);
      port.calls.clear();
      await tester.tap(ph('phrases-all-2'));
      await tester.pumpAndSettle();
      expect(ph('phrases-all-2'), findsNothing);
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
      await tap(tester, 'hide');
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
