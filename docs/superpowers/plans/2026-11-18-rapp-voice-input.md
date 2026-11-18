# 按住说话 + 单手舞台按钮 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On iOS (iPad and Duo), put a hold-to-talk voice button, 「输入」 and 「还原」 into one vertical stack of round buttons on the stage edge (draggable to the other side). Releasing the voice button sends the recognised text the same way the writing panel sends, so it lands in the input history.

**Architecture:** Voice text goes through `ComposerModel` via a new `submitText` that leaves the draft alone. That way `InputRecorder`'s hooks, 「直接回车」 and failure handling apply unchanged. A Dart `VoiceInput` wraps a new native channel `rapp/speech` (Swift `SpeechPlugin`: SpeechAnalyzer on iOS 26+, SFSpeechRecognizer below). On iOS, `composerLayer` swaps the old horizontal button row for a `StageButtons` stack. macOS and Linux keep the old row.

**Tech Stack:** Flutter/Dart (gui/), Swift iOS runner (gui/ios/Runner/), Speech + AVFoundation frameworks.

**Spec:** `docs/superpowers/specs/2026-11-18-rapp-voice-input-design.md`

## Global Constraints

- Flutter: `export PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH"`; run tests from `gui/` with `flutter test <file>`. Revert `gui/pubspec.lock` and `rust/Cargo.lock` if a build or test touched them (`git checkout -- gui/pubspec.lock rust/Cargo.lock`).
- Commit with explicit paths (no `git add -A`, no bare `git stash`). End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never commit to main.
- Use `/usr/bin/grep` (plain `grep` here is ugrep and behaves differently).
- Never read `docs/archives/`.
- iOS deployment target stays 17.0; SpeechAnalyzer code goes behind `if #available(iOS 26, *)`. No new Dart or CocoaPods dependencies.
- Platform gate in Dart: `defaultTargetPlatform == TargetPlatform.iOS` (tests flip it with `debugDefaultTargetPlatformOverride`). macOS and Linux rendering must not change.
- All colours come from `RappTokens` (`t.raise`, `t.float`, `t.line`, `t.text`, `t.accent`, `t.accentInk`, `t.floatBox()`); no literal colours.
- Exact copy (spec): 「正在听…」「松开取消」「没听清」「连接已断开或正在移动，内容尚未发送」「上一段还在发送，已放进输入板」「需要麦克风和语音识别权限」「去设置」「正在准备语音识别，请稍后再试」「这台设备不能识别语音」 (the last one is the plan's call). Semantic labels: 「语音」「输入」「还原」.
- Exact sizes (spec §4.1): voice ⌀64, 输入 ⌀56, 还原 ⌀48; gap 12; 12 from the screen edge; 12 from the bottom.
- Exact timings and distances (spec §4.2, §5.1): drag starts after 10 pt; snap animation about 200 ms; cancel when the finger is 80 pt above the press point; wait at most 1 s for the final result; 60 s cap; 「没听清」 shows about 1.5 s; the permission hint shows about 4 s; the put-back hints show about 2 s.
- Pref key `stage_buttons_side`, values `left` / `right`, default `right`.

## Review Focus

1. **A voice send while the draft holds a private (password-field) or recalled text.** The draft's privacy and recalled state must stay exactly as they were. Today `InputRecorder.onSubmitted` treats every new `Outgoing` as "the draft went", which resets both. Test in Task 1.
2. **A voice send while the draft holds attached blocks (pasted images or files).** The blocks stay held and the draft is untouched, because `submit()`'s `_release` must not run for voice. Test in Task 1.
3. **The finger lifts while `start()` is still waiting on the native side** (a quick tap). Nothing is sent, the native recogniser is cancelled, and no hint is stuck on screen. Test in Task 2.
4. **The pointer is cancelled by the system mid-hold** (a notification pull-down, an incoming call). Treat it as cancel and send nothing. Test in Task 5.
5. **A tap on 「输入」 with a small finger wobble (under 10 pt).** It still opens the composer and does not move the stack. Test in Task 4.

---

### Task 1: `ComposerModel.submitText` and draft-safe recording

**Files:**
- Modify: `gui/lib/embed/composer_model.dart` (class `Outgoing` near line 26; next to `submit()` near line 460)
- Modify: `gui/lib/history/input_recorder.dart` (`c.onSubmitted` in `attach`, near line 176)
- Test: `gui/test/embed/composer_model_test.dart`, `gui/test/history/input_recorder_test.dart`

**Interfaces:**
- Produces:
  - `Outgoing(List<Object> parts, {bool draftless = false})` plus the field `final bool draftless`. A draftless row was not taken from the draft.
  - `bool get busy` on `ComposerModel`: `sending || _taking || _inFlight != null`.
  - `Submit submitText(String text)`, synchronous:
    - Trims `text`; if it is empty, returns `SubmitNothing()`.
    - If `busy`, returns `SubmitNothing()` without touching anything.
    - Otherwise builds `Outgoing([trimmed], draftless: true)..at = now`, calls `onSubmitted`, sets `_lastSend`, `_inFlight` and `sending`, notifies, and returns `SubmitPieces(o.pieces())`.
    - Never reads or changes `draft`, the editor or held blocks (no `_release`).
  - `void keep(String text)`: appends the trimmed text to the draft end (`insert(draft.isEmpty ? t : '\n$t')`).

- [ ] **Step 1: Write the failing model tests** in `composer_model_test.dart`, in a new `group('submitText')`:
  - `'sends the text alone and leaves the draft as it was'`:
    - Setup: `m.draft = 'half written'`.
    - `final r = m.submitText('  你好  ')`; expect `r` to be a `SubmitPieces` whose pieces are just the text `'你好'`.
    - Expect `m.draft == 'half written'`, `m.sending` true, `m.inFlight!.draftless` true.
  - `'empty or blank text sends nothing'`: `m.submitText('   ')` is `SubmitNothing` and `m.sending` stays false.
  - `'while a round runs it sends nothing and busy says so'`:
    - Start one round with `m.submitText('a')`; expect `m.busy` true.
    - `m.submitText('b')` is `SubmitNothing`, and `m.draft` is unchanged.
  - `'keep appends on a new line'`: with `m.draft = 'x'`, `m.keep(' y ')` gives `m.draft == 'x\ny'`; with an empty draft, `m.keep('y')` gives `'y'`.
  - `'held blocks stay held after a voice send'`: hold a block the way the existing block tests do, call `submitText('t')`, and expect the block still held (not dropped through `onDrop`).
  - `'done ends a voice round like any other'`: `submitText('t')`, then `m.done(1, null)`; expect `m.sending` false and `onAllSent` called once.
- [ ] **Step 2: Run them and watch them fail.**
  Run: `cd gui && flutter test test/embed/composer_model_test.dart --plain-name submitText`
  Expected: compile errors (`submitText`, `keep`, `busy`, `draftless` undefined).
- [ ] **Step 3: Implement `Outgoing.draftless`, `busy`, `submitText` and `keep`** in `composer_model.dart` as specified in Interfaces.
- [ ] **Step 4: Write the failing recorder tests** in `input_recorder_test.dart`, using that file's existing attach and finish helpers:
  - `'a voice send is recorded like a panel send'`: `submitText('语音一句')`, then finish all. The written record's text is `'语音一句'`, with the same shape as a `submit()` record.
  - `'a voice send leaves the draft private and recalled state alone'`:
    - Make the draft private the way the existing secure-focus test does, and recall a history row into it.
    - `submitText('x')`, then finish.
    - The draft is still private and still recalled (whatever the existing private/recalled tests assert).
    - The voice record is written, because the voice text itself is not private when `rs.secureFocus` is false.
- [ ] **Step 5: Run and watch them fail.** Run: `cd gui && flutter test test/history/input_recorder_test.dart`. Expected: the second new test fails (draft privacy reset).
- [ ] **Step 6: In `attach`'s `c.onSubmitted`,** compute `submitting = !identical(c.inFlight, o) && !o.draftless`. A draftless row's privacy is `_private[o] == true || rs.secureFocus` only, and it never resets `d.privateText` or `d.recalled`.
- [ ] **Step 7: Run both files, then the full Dart suite.**
  Run: `cd gui && flutter test test/embed/composer_model_test.dart test/history/input_recorder_test.dart && flutter test`
  Expected: all pass.
- [ ] **Step 8: Commit** `gui/lib/embed/composer_model.dart gui/lib/history/input_recorder.dart` and the two test files: `feat(composer): submitText sends a text alone, leaving the draft`.

### Task 2: `VoiceInput` (Dart side of `rapp/speech`)

**Files:**
- Create: `gui/lib/embed/voice_input.dart`
- Test: `gui/test/embed/voice_input_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum VoiceStart { ok, asked, denied, unavailable, preparing }
  enum VoicePhase { idle, starting, listening, finishing }
  class VoiceInput extends ChangeNotifier {
    VoiceInput({MethodChannel? channel, Duration finalWait = const Duration(seconds: 1), Duration maxLength = const Duration(seconds: 60)});
    VoicePhase get phase;
    String get text;                 // latest partial (or final) transcript
    Future<VoiceStart> start();      // native 'start' → 'ok'|'asked'|'denied'|'unavailable'|'preparing'
    Future<String> stop();           // native 'stop'; resolves with the final text, or the last partial after finalWait
    Future<void> cancel();           // native 'cancel'; text cleared, phase idle
    VoidCallback? onMaxLength;       // fired once when maxLength passes while listening
    void Function(String code)? onError; // native 'error' {code}; phase goes idle
    @visibleForTesting Future<Object?> handle(MethodCall call); // native → Dart: 'partial' {text}, 'final' {text}, 'error' {code}
  }
  ```
  - The channel name is `rapp/speech`, and the constructor registers `handle` as its method-call handler.
  - Unknown or failed `start` replies map to `unavailable`.
  - A `stop()` or `cancel()` that arrives while `start()` is still pending: when `start` resolves `ok`, call native `cancel` and resolve `stop()` with `''`.

- [ ] **Step 1: Write the failing tests**, mocking the channel with `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler` and recording calls:
  - `'start ok → listening; partials update text'`: after `start()` returns `VoiceStart.ok`, phase is `listening`. After `handle(MethodCall('partial', {'text': '你'}))`, text is `'你'`.
  - `'stop resolves with the final text'`: `stop()` sends `'stop'`; feed `final {text: '你好'}`; the future resolves `'你好'`; phase is `idle`.
  - `'stop falls back to the last partial after 1 s'` (fakeAsync): feed partial `'你好'`, call `stop()`, elapse 1 s; it resolves `'你好'`.
  - `'cancel clears and calls native cancel'`.
  - `'60 s fires onMaxLength once'` (fakeAsync).
  - `'error goes idle and reports the code'`: feed `error {code: 'interrupted'}`; `onError` gets `'interrupted'`; phase is `idle`.
  - `'a stop before start answers cancels and gives empty text'`: the mock delays the `'start'` reply. Call `stop()` before it resolves. `'cancel'` is sent and `stop()` resolves `''`. (Review Focus 3.)
  - `'start maps replies'`: `'asked'`, `'denied'`, `'preparing'` map to the matching enum values; an unknown reply or a PlatformException maps to `unavailable`.
- [ ] **Step 2: Run and watch them fail.** Run: `cd gui && flutter test test/embed/voice_input_test.dart`. Expected: compile error (file missing).
- [ ] **Step 3: Implement `voice_input.dart`** as specified in Interfaces.
- [ ] **Step 4: Run again.** Expected: all pass.
- [ ] **Step 5: Commit** `gui/lib/embed/voice_input.dart gui/test/embed/voice_input_test.dart`: `feat(ios): VoiceInput, the Dart side of rapp/speech`.

### Task 3: Native `SpeechPlugin` (iOS)

**Files:**
- Create: `gui/ios/Runner/SpeechPlugin.swift` (add it to the Runner target in `gui/ios/Runner.xcodeproj/project.pbxproj` the same way `IosPlugin.swift` is listed)
- Modify: `gui/ios/Runner/AppDelegate.swift` (register it like `IosPlugin`, registrar name `"RappSpeech"`)
- Modify: `gui/ios/Runner/Info.plist` (two usage strings)

**Interfaces:**
- Consumes: the channel contract from Task 2.
  - `start` returns one of the strings `ok`, `asked`, `denied`, `unavailable`, `preparing`.
  - `stop` and `cancel` return nil.
  - Native → Dart: `partial` `{text}`, `final` `{text}`, `error` `{code}`.
- Produces: nothing new for Dart.

- [ ] **Step 1: Info.plist.**
  - `NSMicrophoneUsageDescription` = 「按住语音按钮说话时录音，转成文字发给远程程序」
  - `NSSpeechRecognitionUsageDescription` = 「把你按住语音按钮时说的话转成文字」
- [ ] **Step 2: Write `SpeechPlugin.swift`.**
  - **`start`:**
    - Check authorisation for speech (`SFSpeechRecognizer.authorizationStatus()`) and the microphone (`AVAudioApplication.shared.recordPermission`).
    - Either one not determined: request both in turn and return `asked` (this hold does not record).
    - Either one denied or restricted: return `denied`.
  - **Locale:** `Locale.current`; if the recogniser does not support it, use `zh-CN`.
  - **iOS 26+:**
    - Use `SpeechTranscriber(locale:, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])` with `SpeechAnalyzer(modules: [transcriber])`, fed by an `AsyncStream<AnalyzerInput>` from the audio engine tap.
    - Convert buffers to `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` with `AVAudioConverter`.
    - If `AssetInventory.assetInstallationRequest(supporting: [transcriber])` returns a request, start its `downloadAndInstall()` in a detached Task and return `preparing`.
    - Volatile results go out as `partial`; finalised results accumulate and go out as one `final` after `finalizeAndFinishThroughEndOfInput()`.
  - **Below iOS 26:**
    - Use `SFSpeechRecognizer(locale:)` with `SFSpeechAudioBufferRecognitionRequest`, `shouldReportPartialResults = true`, and `requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition`.
    - Partials go out as `partial`; `isFinal` goes out as `final`.
    - `stop` → `request.endAudio()`.
  - **Neither recogniser available** (nil recogniser, `isAvailable == false`): return `unavailable`.
  - **Audio:**
    - Category `.record`, mode `.measurement`, option `.duckOthers`; `setActive(true)`; tap `AVAudioEngine.inputNode` (bus 0, the node's output format).
    - When a session ends (stop, cancel or error): remove the tap, stop the engine, `setActive(false, options: .notifyOthersOnDeactivation)`.
    - Observe `AVAudioSession.interruptionNotification` (`.began`) and `UIApplication.willResignActiveNotification`. Either one cancels and sends `error {code: "interrupted"}`.
  - **Threading:** every `channel.invokeMethod` runs on the main thread. A second `start` while one runs cancels the first.
- [ ] **Step 3: Build for the simulator.** Run: `scripts/build-ios.sh sim` (with the sandbox disabled). Expected: `Runner.app` builds with no Swift errors. Then revert the lock files as the Global Constraints say.
- [ ] **Step 4: Commit** `gui/ios/Runner/SpeechPlugin.swift gui/ios/Runner/AppDelegate.swift gui/ios/Runner/Info.plist gui/ios/Runner.xcodeproj/project.pbxproj`: `feat(ios): SpeechPlugin on rapp/speech (SpeechAnalyzer, SFSpeechRecognizer below 26)`.

### Task 4: `StageButtons`, the vertical edge stack with side switching (iOS)

**Files:**
- Create: `gui/lib/embed/stage_buttons.dart`
- Modify: `gui/lib/ui/controls.dart` (a round icon variant on `RappButton`)
- Modify: `gui/lib/ui/prefs.dart` (`stageButtonsSide`)
- Modify: `gui/lib/ui/main_state.dart` (notifier and setter, next to `composerZoom` near line 2968)
- Modify: `gui/lib/embed/composer_panel.dart` (`composerLayer`'s last `Positioned`, near line 626)
- Test: `gui/test/embed/stage_buttons_test.dart`, `gui/test/ui/prefs_test.dart`, `gui/test/ui/controls_test.dart`

**Interfaces:**
- Produces:
  - `enum StageSide { left, right }` (in `prefs.dart`).
  - `UiPrefs.stageButtonsSide` (load and save under `stage_buttons_side`; missing or bad means `right`).
  - `MainState.stageSide` (`late final ValueNotifier<StageSide>`) and `void setStageSide(StageSide s)`, which saves.
  - `RappButton.round({Key? key, required String label, required IconData icon, required double size, VoidCallback? onPressed, bool active = false})`:
    - A circle on picture, with the secondary on-picture fill (`Color.alphaBlend(t.raise.first, t.float.first)`), a `t.line` border and a `t.text` icon.
    - With `active`, the fill is `t.accent` and the icon `t.accentInk`.
    - Semantic label = `label`. Same press scale as the other kinds.
  - `class StageButtons extends StatefulWidget`:
    - Constructor: `StageButtons({required StageSide side, required ValueChanged<StageSide> onSide, Widget? voice, Widget? input, Widget? restore, List<Widget> beside = const [], bool lock = false})`.
    - Lays out bottom to top: `voice`, `input`, `restore`, with a gap of 12.
    - `beside` widgets stack upward on the inner side, bottom-aligned with the stack's lowest button, 12 from it.
    - `lock` ignores input and restore and turns off dragging (used while recording).
  - Layout constant: `const stageButtonsEdge = 12.0;` (edge and bottom inset).

- [ ] **Step 1: Failing prefs test** in `prefs_test.dart`, `'stage_buttons_side round-trips; missing or bad is right'`:
  - save `left` → load gives `StageSide.left`;
  - a missing key gives `right`;
  - `'up'` gives `right`.
- [ ] **Step 2: Failing controls test** in `controls_test.dart`, `'round: a circle of the given size, accent when active'`:
  - Size is 64×64.
  - The shape is a `CircleBorder`.
  - With `active: true`, the background is `RappTokens.of(ctx).accent`.
- [ ] **Step 3: Failing `stage_buttons_test.dart`** (`debugDefaultTargetPlatformOverride = TargetPlatform.iOS`, a 1000×700 stage, built through `composerLayer` like `composer_panel_test.dart`'s `layer()` helper):
  - `'iOS: 输入 is a 56 circle 12 from the right and 12 from the bottom; no text label'`.
  - `'zoomed: 还原 (48) sits 12 above 输入'`.
  - `'macOS keeps the old row'` (override macOS): the `composer-open` button is 48 square and in a Row, as before.
  - `'dragging 输入 past the middle moves the stack to the left and saves it'`:
    - `tester.drag(find.byKey(Key('composer-open')), Offset(-700, 0))` then `pumpAndSettle`.
    - The button's left edge is 12; `state.prefs.stageButtonsSide == StageSide.left`; the composer did not open.
  - `'a drag that ends before the middle snaps back right'` (drag -200).
  - `'a wobble under 10 pt is still a tap'` (Review Focus 5): a gesture with move (6, 0) then up opens the composer, and the stack stays right.
  - `'left side: the transfer strip is on the right of the stack'`.
  - `'soft keyboard: the stack rises by the keyboard'` (`keyboard: 300` → bottom 312).
  - `'terminal key row on: the stack stands 8 above the key row'`: bottom = `keyRowBottom + keyRowKeySize.height + 8`.
- [ ] **Step 4: Run and watch them fail.**
  Run: `cd gui && flutter test test/embed/stage_buttons_test.dart test/ui/prefs_test.dart test/ui/controls_test.dart`
  Expected: compile errors or failures.
- [ ] **Step 5: Implement** the prefs field, `MainState.stageSide` and `setStageSide`, `RappButton.round` and `StageButtons`.
  - **Drag:** a `RawGestureDetector` with a `HorizontalDragGestureRecognizer` whose `gestureSettings` is `DeviceGestureSettings(touchSlop: 10)`, wrapped around input and restore.
  - **While dragging:** the stack follows the finger horizontally.
  - **On end:** compare the stack's centre x with the stage's half width, `onSide` the result, and animate to the edge with an `AnimatedPositioned` of 200 ms.
- [ ] **Step 6: Wire it into `composerLayer`.**
  - **On iOS:** replace the last `Positioned` with a full-stage layer holding `StageButtons`.
    - `side` and `onSide` come from `state.stageSide` / `state.setStageSide`.
    - `input` is `RappButton.round(key: Key('composer-open'), label: '输入', icon: Icons.keyboard_outlined, size: 56, ...)`.
    - `restore` is `RappButton.round(key: Key('zoom-reset'), label: '还原', icon: Icons.zoom_in_map, size: 48, ...)`.
    - The transfer strip (text + 取消) goes in `beside`.
    - Keep the existing visibility rule and the `holdForPanel` listener.
    - Bottom inset: `12 + keyboard`, or with the key row `keyRowBottom + keyRowKeySize.height + 8 + keyboard`.
    - `voice` stays null for now.
  - **On other platforms:** the old `Positioned` code, unchanged.
- [ ] **Step 7: Run the three files, then the full suite.** Run: `cd gui && flutter test`. Expected: all pass. The existing `composer_panel_test.dart` iOS tests still pass, since they open the composer through its model, not through the button's position.
- [ ] **Step 8: Commit** all files of this task: `feat(ios): stage buttons in a one-hand edge stack, draggable to the other side`.

### Task 5: The voice button: hold, bubble, send

**Files:**
- Create: `gui/lib/embed/voice_button.dart`
- Modify: `gui/lib/ui/main_state.dart` (constructor parameter `VoiceInput? voice`; on iOS the default is `VoiceInput()`, elsewhere null; dispose it)
- Modify: `gui/lib/embed/composer_panel.dart` (`composerLayer` iOS branch passes `voice:` and the bubble into `StageButtons`)
- Modify: `tasks/todo.md` (real-machine acceptance 1–9 from spec §8, under a new 「按住说话（0.14.x）」 heading)
- Test: `gui/test/embed/voice_button_test.dart`

**Interfaces:**
- Consumes:
  - `ComposerModel.submitText`, `keep` and `busy` (Task 1).
  - `VoiceInput`, `VoiceStart` and `VoicePhase` (Task 2).
  - `StageButtons(voice:, beside:, lock:)` and `RappButton.round` (Task 4).
  - `state.isDetaching(sid)`, `state.sendBlocked(sid)`, `session.prepareInput()`, `port.composerSend(sid, pieces)`, `iosChannel.openSettings()`.
- Produces:
  - `String? sendVoice({required MainState state, required RemoteSession session, required SessionPort port, required String text})`. It returns the hint to show, or null when sent.
    - Blank text → 「没听清」.
    - Blocked or detaching → `keep`, then 「连接已断开或正在移动，内容尚未发送」.
    - `busy` → `keep`, then 「上一段还在发送，已放进输入板」.
    - Otherwise `prepareInput()` + `composerSend`, then null.
  - `class VoiceHold extends ChangeNotifier`:
    - Fields: `phase` (`idle | listening | cancelArmed | finishing`), `hint` (`String?`), `settings` (`bool`: show 「去设置」).
    - `VoiceHold({required VoiceInput voice, required String? Function(String text) send})`.
  - `Widget voiceButton(VoiceHold hold)`: the `RappButton.round(key: Key('voice-hold'), label: '语音', icon: phase == idle ? Icons.mic_none : Icons.mic, size: 64, active: phase == listening)` inside a `Listener`.
  - `Widget voiceBubble(VoiceHold hold, VoiceInput voice)`: a `t.floatBox()` box, at most 3 lines, showing the tail when longer.
    - Shows 「正在听…」 while the text is empty and 「松开取消」 when cancel is armed; otherwise it shows the transcript or the hint.
    - Adds a 「去设置」 `RappButton.secondary` when `settings` is set.
    - Max width: the stage width − 64 − 3 × 12.

- [ ] **Step 1: Failing tests** in `voice_button_test.dart` (iOS override, a fake `VoiceInput` subclass with scripted `start`/`stop` results, a fake port recording `composerSend`):
  - `'hold shows 正在听…, release sends the final text through the composer'`:
    - `startGesture` on `voice-hold`; pump; expect 「正在听…」.
    - The fake pushes partial `'你好'`; expect `'你好'`.
    - Lift; the fake's `stop` returns `'你好'`.
    - Expect `port.composerSend` called once with pieces `['你好']`, the draft unchanged, and the bubble gone.
  - `'slide up 80 arms cancel; release sends nothing'`:
    - Move (0, -81) → 「松开取消」; up → no `composerSend`; `fake.cancelled` true.
    - Moving back to (0, -40) before up disarms it and sends.
  - `'blank result shows 没听清 for 1.5 s and sends nothing'`.
  - `'pointer cancel cancels'` (Review Focus 4): `gesture.cancel()` → no send, `cancelled` true.
  - `'a frozen session keeps the text in the draft with the hint'`: freeze the record the way `main_state_test` does for `sendBlocked` → `rs.composer.draft` ends with the text, the hint matches exactly, and no send.
  - `'start asked: nothing recorded, no hint'`; `'start denied: 需要麦克风和语音识别权限 with 去设置 for 4 s'`; `'start preparing: 正在准备语音识别，请稍后再试'`; `'start unavailable: 这台设备不能识别语音'` (my call: the spec names no copy for it).
  - `'60 s: sends what it has'`: the fake fires `onMaxLength` → it behaves as release.
  - `'while recording 输入 does nothing'`: hold voice, tap `composer-open` with a second pointer → the composer stays closed.
  - `'press gives a medium haptic'`: check `SystemChannels.platform` for `HapticFeedback.vibrate` with `HapticFeedbackType.mediumImpact`.
  - `'macOS: no voice button'`.
- [ ] **Step 2: Run and watch them fail.** Run: `cd gui && flutter test test/embed/voice_button_test.dart`. Expected: compile error.
- [ ] **Step 3: Implement `voice_button.dart`, then wire it into `composerLayer`.**
  - Show the voice button exactly when 输入 shows (`session.composerAllowed && !session.composer.open`) and `state.voice != null`.
  - Pass `lock: hold.phase != idle` to `StageButtons`.
  - While a hint or recording is showing, the bubble sits above the transfer strip in `beside`.
  - Hint lifetimes per the Global Constraints.
  - `HapticFeedback.mediumImpact()` on press.
  - Release while `starting` → `voice.stop()` (VoiceInput handles the cancel), with no hint.
- [ ] **Step 4: Add the acceptance list to `tasks/todo.md`** (spec §8 items 1–9, one line each).
- [ ] **Step 5: Run the full suite.** Run: `cd gui && flutter test`. Expected: all pass.
- [ ] **Step 6: Build for the simulator** with `scripts/build-ios.sh sim` (sandbox disabled). Expected: it builds. Revert the lock files.
- [ ] **Step 7: Commit** `gui/lib/embed/voice_button.dart gui/lib/ui/main_state.dart gui/lib/embed/composer_panel.dart gui/test/embed/voice_button_test.dart tasks/todo.md`: `feat(ios): hold to talk on the stage, sent through the composer into history`.
