// The terminal stage reads the key bar's sticky modifiers (iOS input toggle, Task 2).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/modifier_latch.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/voice_key_gate.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/top_bar.dart';

import '../embed/voice_button_test.dart' show FakeVoice;
import '../fakes.dart';
import '../ui/helpers.dart';
import 'term_main_test.dart' show tp, windowsOf;

const app = 'term:pty:work';

const left = ['Ctrl', 'Esc', 'Ctrl-C', 'Tab'];
const right = ['Up', 'Down', 'Enter'];

void main() {
  late FakeTransport t;
  late HubClient hub;
  late Directory tmp;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  var nextSid = 1;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('term_stage_latch_test');
    // A device id: prefs are written to devices/<id>/gui.json.
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
    term = FakeTermSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
  });

  tearDown(() {
    s.dispose();
    term.dispose();
    tmp.deleteSync(recursive: true);
  });

  Widget window(double width) => SizedBox(
        width: width,
        height: 700,
        child: Column(children: [
          TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
          Expanded(child: Stage(state: s)),
        ]),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> openTerm(WidgetTester tester, {double width = 1200}) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(window(width), disableAnimations: true));
    final panes = [tp(3, 'claude', title: 'build-box', active: true), tp(4, '', title: 'sh')];
    term.paneLists[1] = panes;
    await tester.runAsync(() async {
      s.openOrSwitch('111', app, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    term.play(const ReadyEvent(1, 'work'));
    term.play(windowsOf(1, panes));
    term.play(const TrafficEvent(1, 0, 1));
    await settle(tester);
    expect(find.byType(TermStage), findsOneWidget);
  }

  List<Map<String, Object?>> callsOf(String m) => term.calls.where((c) => c.$1 == m).map((c) => c.$2).toList();
  List<Object?> keys() => [for (final c in callsOf('keys')) c['keys']];


  testWidgets('term_stage: hardware r with keyLatch ctrl sends Ctrl-R', (tester) async {
    await openTerm(tester);
    final rs = s.currentRemote!;
    rs.keyLatch.tap(latchCtrl);
    term.calls.clear();
    final grid = find.byKey(const Key('term-grid'));
    Focus.of(tester.element(grid)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(keys(), [
      ['Ctrl-R'],
    ]);
    expect(rs.keyLatch.flags, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(term.calls.where((c) => c.$1 == 'type').length, 1, reason: 'the latch was used up: the next r is plain');
  });

  testWidgets('term_stage: an arrow with keyLatch alt goes as Alt-Left', (tester) async {
    await openTerm(tester);
    final rs = s.currentRemote!;
    rs.keyLatch.tap(latchOpt);
    term.calls.clear();
    Focus.of(tester.element(find.byKey(const Key('term-grid')))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(keys(), [
      ['Alt-Left'],
    ]);
    expect(rs.keyLatch.flags, 0);
  });

  // input-dock spec §5.3: a key typed into the terminal stage folds the 快捷区, the way the app focuses it (no
  // pictureFocused: a terminal's keys are the stage's own Focus).
  for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
    testWidgets('${platform.name}: a key typed into the focused terminal stage folds the quick area', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await openTerm(tester);
        final rs = s.currentRemote!;
        expect(s.prefs.quickHiddenTerm, isFalse);
        expect(find.byType(KeyBar), findsOneWidget);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isFalse, reason: 'the stage does not have the keys');
        s.focusPicture(rs.sid);
        await tester.pump();
        await tester.pump();
        expect(Focus.of(tester.element(find.byKey(const Key('term-grid')))).hasFocus, isTrue);
        expect(s.pictureFocused, isNull, reason: 'a terminal never sets pictureFocused');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isFalse, reason: 'a modifier alone does not fold');
        rs.keyLatch.tap(latchCtrl);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isFalse, reason: 'a lit ⌃ stays in sight');
        expect(rs.keyLatch.flags, 0);
        rs.composer.editorFocused = true;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isFalse, reason: 'the editor has the key');
        rs.composer.editorFocused = false;
        s.voiceMouseHold = rs.sid;
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isFalse, reason: 'a key during a mouse hold on 语音 is the hold\'s (§5.6)');
        s.voiceMouseHold = null;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isTrue);
        expect(s.prefs.quickHiddenApp, isTrue, reason: 'the app kind is untouched');
        s.setQuickHidden(term: true, hidden: false);
        await tester.pump();
        s.setQuickAutoHide(false);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isFalse, reason: '打字后自动收起 off');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
  // Final review follow-up: a hotkey hold on the terminal owns its keys, so the quick area neither comes nor goes
  // (§5.6). Real key events through the stage's voice gate: the key bar's handler sees them first.
  Future<FakeVoice> voiced(WidgetTester tester) async {
    final voice = FakeVoice();
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term, voice: voice);
    await openTerm(tester);
    s.focusPicture(s.currentRemote!.sid);
    await tester.pump();
    await tester.pump();
    expect(Focus.of(tester.element(find.byKey(const Key('term-grid')))).hasFocus, isTrue);
    expect(s.prefs.quickHiddenTerm, isFalse);
    return voice;
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
    final p = platform == TargetPlatform.linux ? 'linux' : 'macos';
    for (final key in [LogicalKeyboardKey.escape, LogicalKeyboardKey.tab]) {
      testWidgets('${platform.name}: ${key.keyLabel} in a hotkey hold on the terminal leaves the quick area', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final voice = await voiced(tester);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight, platform: p);
          await tester.pump(const Duration(milliseconds: 400)); // past the hold delay
          await tester.pump();
          expect(voice.starts, 1, reason: 'the long ⌥ started a hold');
          await tester.sendKeyDownEvent(key, platform: p);
          await tester.sendKeyUpEvent(key, platform: p);
          await tester.pump();
          expect(s.prefs.quickHiddenTerm, isFalse, reason: '${key.keyLabel} ends the hold, not the quick area');
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA, platform: p);
          await tester.pump();
          expect(s.prefs.quickHiddenTerm, isFalse, reason: 'until ⌥ goes up every key is the hold\'s');
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight, platform: p);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(s.prefs.quickHiddenTerm, isFalse);
          if (key == LogicalKeyboardKey.escape) {
            await tester.sendKeyEvent(LogicalKeyboardKey.keyA, platform: p);
            await tester.pump();
            expect(s.prefs.quickHiddenTerm, isTrue, reason: 'the hold over, a typed key folds again');
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('${platform.name}: a combo hotkey\'s own key down does not fold the quick area', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final voice = await voiced(tester);
        s.setVoiceHotkey(const VoiceHotkey.holdCombo(49, 1 << 19)); // ⌥Space
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft, platform: p);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space, platform: p);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(voice.starts, 1, reason: '⌥Space started a hold');
        expect(s.prefs.quickHiddenTerm, isFalse, reason: 'the hotkey is not typing');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space, platform: p);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft, platform: p);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(s.prefs.quickHiddenTerm, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.space, platform: p);
        await tester.pump();
        expect(s.prefs.quickHiddenTerm, isTrue, reason: 'Space without ⌥ is typing');
      } finally {
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
