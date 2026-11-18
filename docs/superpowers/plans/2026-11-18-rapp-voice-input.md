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
- Exact copy (spec): 「正在听…」「松手 发送」「松手 取消」「松手 改一改再发」「编辑」「取消」「没听清」「连接已断开或正在移动，内容尚未发送」「上一段还在发送，已放进输入板」「需要麦克风和语音识别权限」「去设置」「正在准备语音识别，请稍后再试」「这台设备不能识别语音」 (the last one is the plan's call). Semantic labels: 「语音」「输入」「还原」.
- Exact sizes (spec §4.1): voice ⌀64, 输入 ⌀56, 还原 ⌀48; gap 12; 12 from the screen edge; 12 from the bottom.
- Exact timings and distances (spec §4.2, §5.1): drag starts after 10 pt; snap animation about 200 ms; wait at most 1 s for the final result; 60 s cap; 「没听清」 shows about 1.5 s; the permission hint shows about 4 s; the put-back hints show about 2 s.
- Voice geometry (spec §5.1), stage W×H, thumb = voice button centre: `R = min(1.1·W, 0.9·H)`; apex `max(0.23·R − 44, 84)` above the thumb; ring inner radius `1.033·R`, band `max(0.113·R, 48)`; gap axis 22.5° from straight up toward the stage centre; tips `0.059·R` apart along the band's mid radius; tip depth `0.36·band`; segments 19° long, solid for 55% then fading to about 8%; labels 12° from the axis; 编辑 is the segment nearer straight up. Inside the disc = send; outside = 编辑 or 取消 by the side of the axis.
- Voice animation (spec §5.1): press 240 ms `easeOutCubic` (button→disc morph from radius 32; icon out in 80 ms; 输入/还原 out 120 ms; scrim in 160 ms; bubble from 80 ms for 160 ms, rising 8; bands from 120 ms for 160 ms, sweeping out from the tip). Release 200 ms `easeInCubic` (bands out 100 ms; disc shrinks back; icon in over the last 80 ms; on send the bubble rises 8 as it fades). Reduced motion: no morph or movement.
- Style is minimal (user, 2026-11-18): flat fills and 1 px lines; no glow, shadow or gradient other than the bands' outward fade. Scrim is `t.bg` at 60%.
- Pref key `stage_buttons_side`, values `left` / `right`, default `right`.

## Review Focus

1. **A voice send while the draft holds a private (password-field) or recalled text.** The draft's privacy and recalled state must stay exactly as they were. Today `InputRecorder.onSubmitted` treats every new `Outgoing` as "the draft went", which resets both. Test in Task 1.
2. **A voice send while the draft holds attached blocks (pasted images or files).** The blocks stay held and the draft is untouched, because `submit()`'s `_release` must not run for voice. Test in Task 1.
3. **The finger lifts while `start()` is still waiting on the native side** (a quick tap). Nothing is sent, the native recogniser is cancelled, and no hint is stuck on screen. Test in Task 2.
4. **The pointer is cancelled by the system mid-hold** (a notification pull-down, an incoming call). Treat it as cancel and send nothing. Test in Task 7.
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
  - `RappButton.round({Key? key, required String label, required IconData icon, required double size, VoidCallback? onPressed})`:
    - Minimal: a circle on picture, with the secondary on-picture fill (`Color.alphaBlend(t.raise.first, t.float.first)`), a 1 px `t.line` border, a `t.text` icon, elevation 0, no shadow.
    - Semantic label = `label`. Same press scale as the other kinds.
  - `class StageButtons extends StatefulWidget`:
    - Constructor: `StageButtons({required StageSide side, required ValueChanged<StageSide> onSide, Widget? voice, Widget? input, Widget? restore, List<Widget> beside = const [], bool hidden = false})`.
    - Lays out bottom to top: `voice`, `input`, `restore`, with a gap of 12.
    - `beside` widgets stack upward on the inner side, bottom-aligned with the stack's lowest button, 12 from it.
    - `hidden` (used while recording) fades `input`, `restore` and `beside` out over 120 ms (at once with reduced motion), ignores their input and turns off dragging. `voice` keeps its place; how it draws is its own business.
  - Layout constant: `const stageButtonsEdge = 12.0;` (edge and bottom inset).

- [ ] **Step 1: Failing prefs test** in `prefs_test.dart`, `'stage_buttons_side round-trips; missing or bad is right'`:
  - save `left` → load gives `StageSide.left`;
  - a missing key gives `right`;
  - `'up'` gives `right`.
- [ ] **Step 2: Failing controls test** in `controls_test.dart`, `'round: a minimal circle of the given size'`:
  - Size is 64×64.
  - The shape is a `CircleBorder` with a 1 px `t.line` side; elevation 0.
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
  - `'hidden: 输入 fades out and ignores taps; dragging is off'` (pump `StageButtons` directly with `hidden: true`, settle; the `composer-open` button's opacity is 0 and a tap does nothing).
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
    - Keep the existing visibility rule and the `holdForPanel` listener. `hidden` stays false for now.
    - Bottom inset: `12 + keyboard`, or with the key row `keyRowBottom + keyRowKeySize.height + 8 + keyboard`.
    - `voice` stays null for now.
  - **On other platforms:** the old `Positioned` code, unchanged.
- [ ] **Step 7: Run the three files, then the full suite.** Run: `cd gui && flutter test`. Expected: all pass. The existing `composer_panel_test.dart` iOS tests still pass, since they open the composer through its model, not through the button's position.
- [ ] **Step 8: Commit** all files of this task: `feat(ios): stage buttons in a one-hand edge stack, draggable to the other side`.

### Task 5: Microphone level and the early final

**Files:**
- Modify: `gui/ios/Runner/SpeechPlugin.swift`
- Modify: `gui/lib/embed/voice_input.dart`
- Test: `gui/test/embed/voice_input_test.dart`

**Interfaces:**
- Consumes: `VoiceInput` (Task 2) and `SpeechPlugin` (Task 3).
- Produces:
  - Native event `level {value: Double}`, 0–1, at most every 50 ms, only while recording.
  - `ValueListenable<double> get level` on `VoiceInput`. It reads 0 whenever the phase is not `listening`.
  - A `final` that arrives while `listening` is kept. The next `stop()` returns it at once, without the 1 s wait.

- [ ] **Step 1: Failing Dart tests** in `voice_input_test.dart`:
  - `'level follows native level while listening, clamped to 0..1'`:
    - Start ok.
    - `handle(MethodCall('level', {'value': .4}))` gives `level.value == .4`.
    - A value of `1.7` gives `1.0`; `-1` gives `0.0`.
  - `'level is 0 and ignored when not listening'`:
    - While idle, a level event leaves the value at 0.
    - After `cancel()`, the value is back to 0.
  - `'a final while listening makes stop return it at once'` (`fakeAsync`):
    - Start ok, then `handle('final', {'text': '好'})`.
    - Call `stop()` and `flushMicrotasks()` without elapsing time.
    - The future has completed with `'好'`, and the phase is idle.
- [ ] **Step 2: Run them and watch them fail.** Run: `cd gui && flutter test test/embed/voice_input_test.dart`. Expected: the three new tests fail.
- [ ] **Step 3: Implement the Dart side.**
  - Use a `ValueNotifier<double>`.
  - Reset it to 0 on every move to idle.
  - Dispose it in `dispose`.
- [ ] **Step 4: Implement the native side in `SpeechPlugin.swift`.**
  - Add `static func level(rms: Float) -> Double`: decibels `20·log10(max(rms, 1e-7))`, mapped linearly from −50 dB → 0 to 0 dB → 1, clamped.
  - In the tap, compute the RMS of channel 0 of each buffer.
  - Throttle by the time of the last send (50 ms), dispatch to main, and `channel.invokeMethod("level", arguments: ["value": v])`.
  - Drop `.duckOthers`: `setCategory(.record, mode: .measurement, options: [])` with no fallback (ledger minor from Task 3).
- [ ] **Step 5: Build.** Run: `scripts/build-ios.sh sim` (sandbox disabled). Expected: it builds. Then revert the lock files.
- [ ] **Step 6: Run the Dart tests again.** Expected: all pass.
- [ ] **Step 7: Commit** `gui/ios/Runner/SpeechPlugin.swift gui/lib/embed/voice_input.dart gui/test/embed/voice_input_test.dart` with the message `feat(ios): microphone level for the voice waveform; keep an early final`.

### Task 6: Ring geometry (`VoiceRing`)

**Files:**
- Create: `gui/lib/embed/voice_ring.dart`
- Test: `gui/test/embed/voice_ring_test.dart`

**Interfaces:**
- Produces:
  - `enum VoicePick { send, edit, cancel }`.
  - `class VoiceRing`, pure geometry with no widgets, every value from the Global Constraints:
    - Constructor: `VoiceRing({required Size stage, required Offset thumb, required bool right})`. `right` means the hand edge is the right one.
    - Fields:
      - `double r`: the disc radius.
      - `Offset centre`: straight below the thumb.
      - `double inner`: `1.033·r`.
      - `double band`.
      - `double axis`: the gap axis in radians from straight up, positive clockwise. It is `−22.5°` when `right` and `+22.5°` when left.
    - `VoicePick pick(Offset p)`:
      - Distance to `centre` ≤ `r` gives `send`.
      - Otherwise compare the angle of `p` with `axis`. The side nearer straight up gives `edit`, the other side gives `cancel`.
    - `Path segment(VoicePick which, {double sweep = 1})`:
      - The band polygon from the spec: an outer arc, the flattened tip, and the inner arc back.
      - Its length is `19°·sweep`, measured from the tip root. `sweep` is 0–1 for the grow animation.
      - Only `edit` and `cancel` are valid.
    - `Offset labelAt(VoicePick which)` and `double labelTurn(VoicePick which)`: a point 12° from the axis on the band's mid radius, and the tangent rotation for the label there.
    - `@visibleForTesting Offset probe(VoicePick which)`: a point that `pick` maps to `which`. For `send` it is the thumb; for the others it is the label point.

- [ ] **Step 1: Failing tests** in `voice_ring_test.dart`. Use stage `Size(400, 900)` and thumb `Offset(356, 812)` for the right hand; the left case mirrors it, with thumb x = 44.
  - `'radius, band and centre follow the spec'`:
    - `r == 440`.
    - `band == closeTo(49.7, .1)`.
    - `centre.dx == 356`.
    - `centre.dy - r == 812 - 84`: the apex is `max(0.23·440 − 44, 84) = 84` above the thumb.
  - `'iPad landscape: r = 0.9·H'`: with `Size(1180, 820)`, `r == 738`.
  - `'the thumb picks send; out past the edge, the vertical side is edit'`:
    - `pick(thumb) == send`.
    - With `rot = axis − 10°` toward straight up: `pick(centre + polar(r + 5, rot)) == edit`.
    - With `axis + 10°`: the result is `cancel`.
  - `'left hand mirrors'`: the same three picks with the mirrored points; `axis` is positive.
  - `'segments stay inside the band and keep the gap'`:
    - The bounds of `segment(edit)` and of `segment(cancel)` lie within `inner − .5 … inner + band + .5` of `centre` (sample the path with `computeMetrics`).
    - The two tips are at least `0.059·r − 1` apart.
  - `'sweep 0 is empty, 1 is 19° long'`: compare the path metrics length at each sweep.
  - `'probe maps back to its own pick'`, for all three picks on both hands.
- [ ] **Step 2: Run them and watch them fail.** Run: `cd gui && flutter test test/embed/voice_ring_test.dart`. Expected: a compile error.
- [ ] **Step 3: Implement `voice_ring.dart`.**
  - Polar angles are measured from straight up, clockwise.
  - The tip uses the spec's flattened round head. For `t` from 1 to −1: radius `mid + t·band/2`, angle `cap ∓ depth·sqrt(1−t²)/radius`, where `depth = 0.36·band`.
  - The tip angle is offset from the axis by `(0.0295·r + depth) / mid`.
- [ ] **Step 4: Run the tests again.** Expected: all pass.
- [ ] **Step 5: Commit** `gui/lib/embed/voice_ring.dart gui/test/embed/voice_ring_test.dart` with the message `feat(ios): voice ring geometry (send disc, edit/cancel bands)`.

### Task 7: The voice button: hold, disc, bands, send

**Files:**
- Create: `gui/lib/embed/voice_button.dart`: `sendVoice`, `VoiceHold` and `voiceButton`.
- Create: `gui/lib/embed/voice_overlay.dart`: `VoiceOverlay`, `VoiceRingPainter` and `voiceHint`.
- Modify: `gui/lib/ui/main_state.dart`:
  - Add the constructor parameter `VoiceInput? voice`.
  - On iOS the default is `VoiceInput()`; elsewhere it is null.
  - Dispose it.
- Modify: `gui/lib/embed/composer_panel.dart`:
  - The `composerLayer` iOS branch passes `voice:` and `hidden:` into `StageButtons`.
  - It puts `VoiceOverlay` over the stage.
- Modify: `tasks/todo.md`: real-machine acceptance from spec §8 (1, 2, 3, 3b, 4–11) under a new 「按住说话（0.14.x）」 heading.
- Test: `gui/test/embed/voice_button_test.dart`.

**Interfaces:**
- Consumes:
  - `ComposerModel.submitText`, `keep`, `busy` and `open` (Task 1, plus the existing setter).
  - `VoiceInput`, `VoiceStart`, `VoicePhase` and `level` (Tasks 2 and 5).
  - `StageButtons(voice:, beside:, hidden:)` and `RappButton.round` (Task 4).
  - `VoiceRing` and `VoicePick` (Task 6).
  - `state.isDetaching(sid)`, `state.sendBlocked(sid)`, `session.prepareInput()`, `port.composerSend(sid, pieces)` and `iosChannel.openSettings()`.
- Produces:
  - `String? sendVoice({required MainState state, required RemoteSession session, required SessionPort port, required String text})`. It returns the hint to show, or null when the text was sent:
    - Blank text → 「没听清」.
    - Blocked or detaching → `keep`, then 「连接已断开或正在移动，内容尚未发送」.
    - `busy` → `keep`, then 「上一段还在发送，已放进输入板」.
    - Otherwise `prepareInput()` and `composerSend`, then null.
  - `class VoiceHold extends ChangeNotifier`:
    - Fields:
      - `bool holding`: true from an `ok` start until release.
      - `VoicePick pick`.
      - `String? hint`.
      - `bool settings`: show 「去设置」.
      - `VoiceRing? ring`: set on press from the stage size, the voice button centre and the side.
    - Constructor: `VoiceHold({required VoiceInput voice, required String? Function(String text) send, required void Function(String text) edit})`.
    - Methods: `down(Offset thumb, Size stage, bool right)`, `move(Offset p)`, `up()` and `cancel()`.
  - `Widget voiceButton(VoiceHold hold)`:
    - `RappButton.round(key: Key('voice-hold'), label: '语音', icon: Icons.mic_none, size: 64)` inside a `Listener` that feeds `VoiceHold`.
    - It fades to 0 opacity while the overlay shows (see Step 3).
  - `class VoiceOverlay extends StatefulWidget`:
    - Constructor: `VoiceOverlay({required VoiceHold hold, required VoiceInput voice})`.
    - It owns one `AnimationController`: 240 ms forward with `easeOutCubic`, 200 ms reverse with `easeInCubic`.
    - It draws through a `CustomPaint(key: Key('voice-ring'), painter: VoiceRingPainter(...))`.
  - `class VoiceRingPainter extends CustomPainter`, with public fields `ring`, `pick` and `progress` (0–1), plus the tokens.
  - `Widget voiceHint(VoiceHold hold)`: the small after-release bubble (spec §5.1 「松手后的提示」), with 「去设置」 when `settings` is set.

- [ ] **Step 1: Failing tests** in `voice_button_test.dart`:
  - Setup:
    - Override the platform to iOS.
    - Use a fake `VoiceInput` subclass with scripted `start`/`stop` results and a settable level.
    - Use a fake port that records `composerSend`.
    - Move points come from `VoiceRing(...).probe(...)`, built with the same stage size, the centre of `voice-hold` and the side.
  - `'hold grows the disc; release in the disc sends the final text'`:
    - `startGesture` on `voice-hold`, then pump 240 ms.
    - Expect: `VoiceRingPainter.progress == 1`, the `voice-hold` opacity is 0, and the text 「正在听…」 and 「松手 发送」.
    - The fake pushes partial `'你好'`; expect `'你好'`.
    - Lift; the fake's `stop` returns `'你好'`.
    - Expect: `composerSend` called once with pieces `['你好']`, the draft unchanged, and after 200 ms the painter is gone and `voice-hold` opacity is 1.
  - `'slide to 取消: band lights, release sends nothing; back into the disc sends'`:
    - Move to `probe(cancel)`; expect `pick == cancel`, 「松手 取消」 and one `HapticFeedback.selectionClick`.
    - Lift: no `composerSend`, and `fake.cancelled` is true.
    - Second run: move to `probe(cancel)`, then back to `probe(send)`, then lift. It sends.
  - `'slide to 编辑: the text goes to the draft end and the composer opens; nothing sent'`:
    - Start with `draft = 'x'` and move to `probe(edit)`; expect 「松手 改一改再发」.
    - Lift with `stop` returning `'好'`.
    - Expect `draft == 'x\n好'`, `composer.open` true, and no `composerSend`.
  - `'left side mirrors: 编辑 is still the vertical band'`:
    - With side left, `probe(edit)` gives 「松手 改一改再发」.
  - `'reduced motion: the disc is there on the first frame'`:
    - Use `MediaQuery(disableAnimations: true)`.
    - After one `pump()`, `progress == 1`.
  - `'the level drives the bars'`:
    - Set the fake level to `.8` and pump.
    - The painter or bubble reads it: expose `VoiceOverlay`'s bar heights through a `Key('voice-bars')` `CustomPaint` whose painter has `level`.
  - `'blank result shows 没听清 for 1.5 s and sends nothing'`: the hint is `voiceHint`; there is no disc.
  - `'pointer cancel cancels'` (Review Focus 4): `gesture.cancel()` gives no send, and `cancelled` is true.
  - `'a frozen session keeps the text in the draft with the hint'`:
    - Freeze the record the way `main_state_test` does for `sendBlocked`.
    - Expect: `rs.composer.draft` ends with the text, the hint matches exactly, no send, and the composer stays closed.
  - Start results:
    - `'start asked: no disc, no hint'`.
    - `'start denied: 需要麦克风和语音识别权限 with 去设置 for 4 s'`.
    - `'start preparing: 正在准备语音识别，请稍后再试'`.
    - `'start unavailable: 这台设备不能识别语音'`.
  - `'60 s: acts as release on the current pick'`:
    - The fake fires `onMaxLength` while the pick is `cancel`; nothing is sent.
    - While the pick is `send`, it sends.
  - `'while holding 输入 is hidden and does nothing'`:
    - Tap `composer-open` with a second pointer; the composer stays closed.
  - `'press gives a medium haptic'`: `SystemChannels.platform` sees `HapticFeedback.vibrate` with `HapticFeedbackType.mediumImpact`.
  - `'macOS: no voice button'`.
- [ ] **Step 2: Run them and watch them fail.** Run: `cd gui && flutter test test/embed/voice_button_test.dart`. Expected: a compile error.
- [ ] **Step 3: Implement `voice_button.dart` and `voice_overlay.dart`, then wire them into `composerLayer`.**
  - **Visibility:**
    - Show the voice button exactly when 输入 shows (`session.composerAllowed && !session.composer.open`) and `state.voice != null`.
    - Pass `hidden: hold.holding || overlay animating` to `StageButtons`.
  - **Morph:**
    - The disc circle is the lerp from (button centre, 32) to (`ring.centre`, `ring.r`) by the curved progress.
    - The voice button's own opacity follows `1 − clamp(progress / (80/240))`.
  - **Overlay, in paint order:**
    - Scrim: `t.bg` at 60% × progress over 160 ms.
    - Disc: `t.raise.first` fill, a 1.5 px `t.text` border when the pick is send, else a 1 px `t.line` border.
    - Bands: from 120 ms, sweeping 0→1 over 160 ms.
    - Labels: an icon plus two characters, rotated by `labelTurn`.
    - Bubble: up to 4 lines, showing the tail, on the hand side. It fades in from 80 ms and rises 8 px. Bubble styles and the hint line follow the spec §5.1 table.
    - Bars: 24 bars inside the bubble.
  - **Reverse on release:** bands out in the first 100 ms. On send, the bubble rises 8 px as it fades.
  - **Haptics:** `HapticFeedback.mediumImpact()` on an `ok` press, and `selectionClick` on each pick change.
  - **Release paths:**
    - Release while `starting` → `voice.stop()`, with no disc and no hint.
    - Release on `send`: `stop()`, then `sendVoice`.
    - Release on `edit`: `stop()`; for non-blank text, `keep` plus `composer.open = true`.
    - Release on `cancel`: `voice.cancel()`.
  - **Hints:** they go to `voiceHint` in `beside`, with lifetimes from the Global Constraints.
- [ ] **Step 4: Add the acceptance list to `tasks/todo.md`**: spec §8, one line each.
- [ ] **Step 5: Run the full suite.** Run: `cd gui && flutter test`. Expected: all pass.
- [ ] **Step 6: Build for the simulator** with `scripts/build-ios.sh sim` (sandbox disabled). Expected: it builds. Then revert the lock files.
- [ ] **Step 7: Commit** these paths with the message `feat(ios): hold to talk with WeChat-style send disc and edit/cancel bands`:
  - `gui/lib/embed/voice_button.dart`
  - `gui/lib/embed/voice_overlay.dart`
  - `gui/lib/ui/main_state.dart`
  - `gui/lib/embed/composer_panel.dart`
  - `gui/test/embed/voice_button_test.dart`
  - `tasks/todo.md`
