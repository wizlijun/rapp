import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/voice_key_gate.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_model.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../embed/voice_button_test.dart' show FakeVoice;
import '../ui/helpers.dart';

RemoteWindow _win(int id) => RemoteWindow(
      id: id,
      parent: 0,
      kind: WindowKind.normal,
      title: 'p$id',
      rect: Rect.zero,
      titleBar: 0,
      resizable: false,
      focused: true,
      texture: null,
      visible: Rect.zero,
    );

TermScreen _scr() => TermScreen(
      pane: '%3',
      rev: 1,
      cols: 40,
      rows: 1,
      cx: 0,
      cy: 0,
      cursor: true,
      alt: false,
      full: true,
      more: false,
      lines: const [(0, '\$ ')],
      wrapped: const {},
    );

void main() {
  group('hold-to-talk hotkey on a text terminal (macOS)', () {
    late Directory tmp;
    late MainState state;
    late RemoteSession session;
    late FakeTermSessionPort port;
    late TermModel model;
    late List<(Object, VoiceKeyPhase)> voiceKeys;
    late StreamSubscription<(Object, VoiceKeyPhase)> sub;
    late List<KeyEvent> bubbled;
    late FakeVoice voice;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('term_stage_voice_test');
      model = TermModel()..expect('%3');
      port = FakeTermSessionPort()
        ..seed(1, model: model, panes: [
          TermPane(
              id: '%3', win: '@3', window: 'claude', title: 'claude', command: 'claude', cols: 80, rows: 24, dead: false, active: true),
        ]);
      state = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), termPort: port, voice: voice = FakeVoice());
      session = RemoteSession(1, 'term')..apply(WindowsEvent(1, [_win(3)]));
      voiceKeys = [];
      sub = state.voiceKeys.listen(voiceKeys.add);
      bubbled = [];
    });
    tearDown(() async {
      await sub.cancel();
      state.dispose();
      port.dispose();
      tmp.deleteSync(recursive: true);
    });

    Future<void> show(WidgetTester t) async {
      model.apply(_scr());
      await t.pumpWidget(wrap(Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          bubbled.add(e);
          return KeyEventResult.ignored;
        },
        child: SizedBox(width: 800, height: 480, child: TermStage(state: state, session: session, port: port)),
      )));
      await t.tap(find.byKey(const Key('term-grid')));
      await t.pump();
      port.calls.clear();
      bubbled.clear();
    }

    List<Object?> sent() => [
          for (final c in port.calls)
            if (c.$1 == 'keys') c.$2['keys'] else if (c.$1 == 'type') 'type:${c.$2['text']}',
        ];

    Future<void> down(WidgetTester t, LogicalKeyboardKey k) => t.sendKeyDownEvent(k, platform: 'macos');
    Future<void> up(WidgetTester t, LogicalKeyboardKey k) => t.sendKeyUpEvent(k, platform: 'macos');

    testWidgets('a quick tap of right option still reaches the terminal', (t) async {
      await show(t);
      await down(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 100));
      await up(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 400));
      // The held down is flushed to the terminal handler (which, as ever, has nothing to send for Option alone),
      // and the up goes on to it like any key's.
      expect(bubbled.whereType<KeyUpEvent>().length, 1);
      expect(sent(), isEmpty);
      expect(voiceKeys, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('flushed option reaches the terminal before the letter', (t) async {
      await show(t);
      await down(t, LogicalKeyboardKey.altRight);
      await down(t, LogicalKeyboardKey.keyB);
      await up(t, LogicalKeyboardKey.keyB);
      await up(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 400));
      // Option+b as without the gate: the terminal's Alt-b (ESC b).
      expect(sent(), [
        ['Alt-b'],
      ]);
      expect(voiceKeys, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the held option is flushed to the terminal handler before the letter', (t) async {
      await show(t);
      final seen = <String>[];
      debugTermKeySeen = (e) => seen.add('${e.runtimeType}:${e.physicalKey.debugName}');
      addTearDown(() => debugTermKeySeen = null);
      await down(t, LogicalKeyboardKey.altRight);
      expect(seen, isEmpty); // swallowed while pending
      await down(t, LogicalKeyboardKey.keyB);
      expect(seen, ['KeyDownEvent:Alt Right', 'KeyDownEvent:Key B']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a mouse hold on the voice button keeps every key from the pane', (t) async {
      await show(t);
      state.voiceMouseHold = 1;
      await t.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
      await t.sendKeyEvent(LogicalKeyboardKey.tab, platform: 'macos');
      await t.sendKeyEvent(LogicalKeyboardKey.keyA, platform: 'macos');
      await t.pump();
      expect(sent(), isEmpty);
      state.voiceMouseHold = null;
      await t.sendKeyEvent(LogicalKeyboardKey.keyA, platform: 'macos');
      await t.pump();
      expect(sent(), ['type:a']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('esc during a mouse hold cancels the voice and sends nothing to the pane', (t) async {
      await show(t);
      // The terminal stage with the composer row over it, as the app lays them out.
      await t.pumpWidget(wrap(Focus(
        autofocus: true,
        child: SizedBox(
          width: 800,
          height: 480,
          child: Stack(children: [
            Positioned.fill(child: TermStage(state: state, session: session, port: port)),
            ...composerLayer(state: state, session: session, port: port, editor: FlutterEditor.new),
          ]),
        ),
      )));
      await t.tap(find.byKey(const Key('term-grid')));
      await t.pump();
      port.calls.clear();
      final g = await t.startGesture(t.getCenter(find.byKey(const Key('voice-hold'))));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(state.voiceMouseHold, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.keyA, platform: 'macos'); // during the hold
      await t.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
      await t.pump(const Duration(milliseconds: 200));
      expect(voice.cancelled, isTrue);
      expect(sent(), isEmpty);
      await g.up();
      await t.pump(const Duration(milliseconds: 200));
      expect(state.voiceMouseHold, isNull);
      expect(sent(), isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('holding right option starts voice and swallows it', (t) async {
      await show(t);
      await down(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 300));
      expect(voiceKeys, [(1, VoiceKeyPhase.start)]);
      await up(t, LogicalKeyboardKey.altRight);
      await t.pump();
      expect(voiceKeys, [(1, VoiceKeyPhase.start), (1, VoiceKeyPhase.release)]);
      expect(sent(), isEmpty);
      expect(bubbled, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('esc while recording cancels and nothing reaches the terminal', (t) async {
      await show(t);
      await down(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 300));
      await down(t, LogicalKeyboardKey.escape);
      await up(t, LogicalKeyboardKey.escape);
      await up(t, LogicalKeyboardKey.altRight);
      await t.pump();
      expect(voiceKeys, [(1, VoiceKeyPhase.start), (1, VoiceKeyPhase.cancel)]);
      expect(sent(), isEmpty);
      expect(bubbled, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('not ready with the panel open', (t) async {
      await show(t);
      session.composer.open = true;
      await t.pump();
      await down(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 400));
      await up(t, LogicalKeyboardKey.altRight);
      await t.pump();
      expect(voiceKeys, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('changing the hotkey while recording cancels and leaves no key swallowed', (t) async {
      await show(t);
      await down(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 300));
      expect(voiceKeys, [(1, VoiceKeyPhase.start)]);
      state.setVoiceHotkey(VoiceHotkey.off); // 关 clicked in the side panel mid-hold
      await t.pump();
      expect(voiceKeys, [(1, VoiceKeyPhase.start), (1, VoiceKeyPhase.cancel)]);
      state.voiceEnd(1);
      await t.pump();
      await up(t, LogicalKeyboardKey.altRight);
      expect(sent(), isEmpty);
      expect(bubbled, isEmpty);
      await t.sendKeyEvent(LogicalKeyboardKey.keyA, platform: 'macos');
      await t.pump();
      expect(sent(), ['type:a']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('changing the hotkey while pending drops the hold timer', (t) async {
      await show(t);
      await down(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 100));
      state.setVoiceHotkey(const VoiceHotkey.holdModifier(63));
      await t.pump(const Duration(milliseconds: 400));
      expect(voiceKeys, isEmpty);
      await up(t, LogicalKeyboardKey.altRight);
      await t.sendKeyEvent(LogicalKeyboardKey.keyA, platform: 'macos');
      await t.pump();
      expect(sent(), ['type:a']);
      expect(voiceKeys, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('voice_end returns the gate', (t) async {
      await show(t);
      await down(t, LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 300));
      expect(voiceKeys, [(1, VoiceKeyPhase.start)]);
      state.voiceEnd(1);
      await t.pump();
      await down(t, LogicalKeyboardKey.keyA);
      await up(t, LogicalKeyboardKey.keyA);
      expect(sent(), isEmpty);
      await up(t, LogicalKeyboardKey.altRight);
      expect(sent(), isEmpty);
      expect(bubbled, isEmpty);
      await down(t, LogicalKeyboardKey.keyA);
      await up(t, LogicalKeyboardKey.keyA);
      await t.pump();
      expect(sent(), ['type:a']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });
}
