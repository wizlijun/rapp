# macOS 按住说话 + 语音快捷键 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS, add a mouse-sized 「按住说话」 button to the stage's button row, for app pictures and text terminals alike. Add a configurable hold-to-talk hotkey, by default a long press of Right Option. Both reuse the iOS recogniser, `VoiceHold` and `sendVoice`, so voice text lands in the input history the same way. Recognition follows the system's first preferred language on both platforms.

**Architecture:**
- **Shared Swift.** `SpeechPlugin.swift` moves to `gui/macos/Runner/` and is shared by both Xcode projects, with iOS-only audio-session code behind `#if os(iOS)`. Locale choice becomes one tested function in the `RappSession` package.
- **Hotkey gates.** A pure `VoiceKeyGate` decides what happens to each key and mouse event:
  - The Swift copy sits at the front of `SessionPlugin.route`'s `.main` branch (app pictures).
  - A Dart twin sits at the front of `term_stage`'s key path (terminals).
  - Both run one shared JSON case table.
- **Dart UI.** `VoiceHold` gains pointer-free entry points. A new `voice_desktop.dart` draws the button, the bubble and the two targets inside `composerLayer`'s non-iOS row.

**Tech Stack:** Swift (RappSession package, macOS + iOS runners), Speech + AVFoundation, Flutter/Dart (gui/).

**Spec:** `docs/superpowers/specs/2026-11-18-rapp-macos-voice-design.md`. It amends the iOS spec `docs/superpowers/specs/2026-11-18-rapp-voice-input-design.md`, whose §5.1/§5.4 behaviour still holds.

## Global Constraints

- **Tooling**
  - Flutter: `export PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH"`. Run Dart tests from `gui/` with `flutter test <file>`.
  - Swift tests run from the repo root with `swift test --filter <Name>`.
  - Revert `gui/pubspec.lock` and `rust/Cargo.lock` after any build (`git checkout -- gui/pubspec.lock rust/Cargo.lock`).
  - Use `/usr/bin/grep` (plain `grep` is ugrep). There is no `timeout` command.
- **Commits**
  - Use explicit paths: no `git add -A`, no bare `git stash`.
  - End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Work on `feat/macos-voice`, never on main.
- **Documents:** never read `docs/archives/`.
- **No changes to:** the protocol, A, relay, iOS interaction, Linux UI, or detached windows. Add no new dependencies.
- **Deployment targets:** macOS stays 14.0 and iOS stays 17.0. SpeechAnalyzer code goes behind `#available(macOS 26, iOS 26, *)`.
- **Platform gate in Dart:** `defaultTargetPlatform == TargetPlatform.macOS`. Tests set `debugDefaultTargetPlatformOverride` and reset it.
- **Colours:** all from `RappTokens`; no literal colours. The bubble's three states:
  - Send: `t.text` fill, `t.bg` text.
  - Cancel: `t.raise.first` fill, `t.muted` text, `t.line` border, bars still.
  - Edit: `t.float.first` fill, `t.text` text, dashed `t.text` border, caret at the end.
  - A selected target: `t.accent` fill, `t.accentInk` text.
  - The stage is not dimmed.
- **Exact copy, kept from iOS:** 「按住说话」 (semantics 「语音」), 「正在听…」, 「松手 发送」, 「松手 取消」, 「松手 改一改再发」, 「编辑」, 「取消」, 「去设置」, 「没听清」, 「需要麦克风和语音识别权限」, 「正在准备语音识别，请稍后再试」.
- **Exact copy, new:**
  - Key hints after the target labels: 「Tab」 and 「Esc」.
  - Unavailable: 「这种系统语言暂不支持语音识别，可以在系统设置里换一种」.
  - Language hint: 「识别语言跟随系统。要换语言：系统设置 → 通用 → 语言与地区」.
  - Settings row: 「语音快捷键」, 「改」, 「关」, 「恢复默认」, 「请按下快捷键…（Esc 取消）」, 「这个键不能用」.
  - Hotkey labels: 「长按 右 ⌥」, 「按住 ⌃⌥Space」, 「关」.
- **Settings URLs:**
  - Microphone: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
  - Language & Region: `x-apple.systempreferences:com.apple.Localization-Settings.extension`.
  - Both open with `Process.run('open', [url])`, as `openSettingsPane` does.
- **Sizes and timings:**
  - The button is a `RappButton.secondary`, the same size as 「输入」.
  - Other row items fade out over 120 ms.
  - The bubble is `min(stageW − 32, 480)` wide, at most 4 lines showing the tail. It fades in over 160 ms while rising 8.
  - Target hit areas are inflated 6 on each side.
  - The final result is awaited for up to 1 s. The 60 s cap is unchanged.
  - Hotkey threshold: 0.3 s.
  - Reduced motion: things appear and disappear instantly.
- **macOS key codes:**
  - ⌥R 61, ⌥L 58, ⌃R 62, ⌃L 59, ⇧R 60, ⇧L 56, ⌘R 54, ⌘L 55, Fn 63, CapsLock 57.
  - Esc 53, Tab 48, Space 49, Return 36, keypad Enter 76, Q 12, ← 123.
  - Flag bits (`KeyFlags`): shift 1<<17, control 1<<18, option 1<<19, command 1<<20, function 1<<23.
- **gui.json keys:**
  - `voice_hotkey`: `{"kind":"hold_modifier","key_code":61}` | `{"kind":"hold_combo","key_code":n,"modifiers":flags}` | `"off"`. Missing or invalid means the default `hold_modifier 61`.
  - `voice_language_hint_shown`: bool, default false.

### Calls this plan makes (recorded so the executor need not re-derive them)

1. **No `set_voice_ready` channel method.** "Ready to talk" rides on `picture_focus` as `voice: true`, the way `compose: true` does.
   - The native gate only arms a session that has picture focus.
   - The panel opening, or a mouse hold, blurs the picture (`holdForPanel`), so readiness falls with it.
   - This satisfies spec §6.1's "例如 `set_voice_ready`".
2. **A Dart → native `voice_end {sid}`.** It tells the gate that a hold ended on the Dart side: the 60 s cap, an error, a failed start, or the widget being disposed.
   - The gate stops treating the hotkey as recording.
   - The hotkey's up is still swallowed, by the up-rule.
3. **`SpeechLocales` becomes `SpeechLanguage.swift` in `Sources/RappSession`**, so `swift test` covers it. `gui/ios/Runner/SpeechLocales.swift` is deleted.
4. **After Esc, Tab or a Dart-side end, keep swallowing keys until the hotkey is released.** This is the spec's "decided" state, applied to all three.
   - Window resign resets the gate to idle and cancels recording, because the up may never arrive.
   - Any new down of a key clears that key's swallowed mark.
5. **Bubble layout.** The bubble, the targets and the hint line form one right-aligned column whose bottom sits 8 above the button row. The language hint lives 6 s and shows after the first finished hold that left no other hint.
6. **The desktop bubble is a new widget** in `voice_desktop.dart`. It reuses `VoiceBarsPainter` and `_BubbleFrame`, made public as `VoiceBubbleFrame` with a new `tail` flag.

## Review Focus

1. **A second ⌥R press within 0.3 s of a tap.** The first press's timer must not start voice early on the second. Test: fixture case `stale-timer` (Task 3, run again in Task 5).
2. **The window loses key while ⌥R is pending or recording, and its up never arrives.** The next ⌥R press must behave normally. Test: fixture case `resign-then-fresh-press` (Tasks 3/5).
3. **A session switch or stage rebuild in the middle of a hotkey hold.** The words go to that session's draft, and `voice_end` is sent so the native gate does not keep swallowing keys. Test: `disposing during a hotkey hold sends voice_end` (Task 9).
4. **The user holds ⌥L and then presses ⌥R, or holds ⇧ and then presses ⌥R.** Both reach A untouched, with no hold. Test: fixture cases `left-option-held` and `shift-held` (Tasks 3/5).
5. **Option as Meta in a terminal.** A flushed ⌥R down must reach the terminal's key handling before the letter that flushed it, so ⌥b still works as Meta-b. Test: `flushed option reaches the terminal before the letter` (Task 10).

---

### Task 1: Shared speech code, locale from the first preferred language

**Files:**
- Create: `Sources/RappSession/SpeechLanguage.swift`
- Create: `Tests/RappSessionTests/SpeechLanguageTests.swift`
- Move: `gui/ios/Runner/SpeechPlugin.swift` → `gui/macos/Runner/SpeechPlugin.swift` (use `git mv`)
- Delete: `gui/ios/Runner/SpeechLocales.swift`
- Modify: `gui/ios/Runner.xcodeproj/project.pbxproj`:
  - F00E: `name = SpeechPlugin.swift; path = ../macos/Runner/SpeechPlugin.swift; sourceTree = SOURCE_ROOT;`, as SessionPlugin's ref is at line 72.
  - Remove F010 and F011 (SpeechLocales) from PBXFileReference, PBXBuildFile, the Runner group (~146) and Sources (~316).

**Interfaces:**
- Produces: `public func speechLocale(preferred: [String]) -> Locale`
  - Returns `Locale(identifier: normaliseSpeechLocale(preferred.first ?? "en-US"))`.
- Produces: `public func normaliseSpeechLocale(_ id: String) -> String`
  - The body of the old `SpeechLocales.normalise`, unchanged.
- `SpeechPlugin` keeps channel `rapp/speech` and its methods and events. It now has `import RappSession`, and `locales` becomes one `locale`.

- [ ] **Step 1: Write the failing tests** in `SpeechLanguageTests.swift`:

```swift
func testFirstPreferredLanguageOnly() {
    XCTAssertEqual(speechLocale(preferred: ["en-US", "zh-Hans-CN"]).identifier, "en-US")
}
func testChineseNormalised() {
    XCTAssertEqual(speechLocale(preferred: ["zh-Hans-CN"]).identifier, "zh-CN")
    XCTAssertEqual(normaliseSpeechLocale("zh-Hant-TW"), "zh-TW")
}
func testEmptyListFallsBackToEnglish() {
    XCTAssertEqual(speechLocale(preferred: []).identifier, "en-US")
}
func testNoChineseFallback() {   // the old candidates() appended zh-CN
    XCTAssertEqual(speechLocale(preferred: ["ja-JP"]).identifier, "ja-JP")
}
```

- [ ] **Step 2:** Run `swift test --filter SpeechLanguageTests`. Expected: FAIL (`cannot find 'speechLocale'`).
- [ ] **Step 3:** Implement `SpeechLanguage.swift`, then move the plugin.
  - Replace both uses of `Self.locales` with the single `Self.locale`:
    - `startAnalyzer`: `SpeechTranscriber.supportedLocale(equivalentTo: Self.locale)`. If that returns nil, reply `unavailable`.
    - `startRecognizer`: `SFSpeechRecognizer(locale: Self.locale)`.
  - Wrap these in `#if os(iOS)`:
    - `AVAudioSession` setCategory, setAllowHaptics and setActive, plus the deactivate in `stopAudio`.
    - The interruption and `willResignActiveNotification` observers.
    - `import UIKit` and `import Flutter`; macOS uses `import FlutterMacOS` and `import AppKit`.
  - `register` uses `registrar.messenger()` on iOS and `registrar.messenger` on macOS.
  - Availability checks become `#available(iOS 26, macOS 26, *)`.
  - The record-permission API: iOS uses `AVAudioApplication.shared.recordPermission`. macOS uses `AVCaptureDevice.authorizationStatus(for: .audio)` and `requestAccess(for: .audio)`, mapped to the same replies (ok / asked / denied).
- [ ] **Step 4:** Run `swift test --filter SpeechLanguageTests`. Expected: PASS. Then run `scripts/build-ios.sh sim`. Expected: exit 0 and `Built build/ios/iphonesimulator/Runner.app`.
- [ ] **Step 5: Commit** the new, moved and deleted Swift files and the iOS pbxproj, with message `feat(voice): share the speech plugin; recognise in the first preferred language`.

### Task 2: macOS speech plugin wiring

**Files:**
- Modify: `gui/macos/Runner.xcodeproj/project.pbxproj`. Add `SpeechPlugin.swift` as a file ref plus build file next to SessionPlugin (lines 31, 90, 185, 380), with new IDs `A5E5510000000000000000B1` and `…B2`.
- Modify: `gui/macos/Runner/MainFlutterWindow.swift`. Register `SpeechPlugin` as `"RappSpeech"` after `RegisterGeneratedPlugins`, the way SessionPlugin is registered.
- Modify: `gui/macos/Runner/Info.plist`. Add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`, with the exact strings from `gui/ios/Runner/Info.plist`.
- Modify: `gui/macos/Runner/DebugProfile.entitlements` and `Release.entitlements`. Add `<key>com.apple.security.device.audio-input</key><true/>`.
- Modify: `gui/macos/Runner/SpeechPlugin.swift`, inside `#if os(macOS)`:
  - Observe `NSWindow.didResignKeyNotification` for the app's main window only. The plugin is given the window at registration, as `SpeechPlugin.register(with:window:)`.
  - On resign it calls the same `interrupt()`, which sends `error {code: interrupted}`.

**Interfaces:**
- Produces: on macOS, Dart's `VoiceInput()` (channel `rapp/speech`) now answers.

- [ ] **Step 1:** Run `cd gui && flutter build macos --debug`. Expected: `✓ Built build/macos/Build/Products/Debug/rapp.app`. Use whatever `.app` name the build prints.
- [ ] **Step 2: Check the built app.**
  - Run `codesign -d --entitlements - gui/build/macos/Build/Products/Debug/*.app 2>/dev/null | /usr/bin/grep -c audio-input`. Expected: `1`.
  - Run `plutil -extract NSMicrophoneUsageDescription raw gui/build/macos/Build/Products/Debug/*.app/Contents/Info.plist`. Expected: the iOS string.
- [ ] **Step 3: Commit** the pbxproj, MainFlutterWindow, Info.plist, both entitlements files and SpeechPlugin, with message `feat(voice): speech plugin on macOS (mic entitlement, usage strings, resign-key interrupts)`.

### Task 3: Swift `VoiceKeyGate` and the shared case table

**Files:**
- Create: `Sources/RappSession/VoiceKeyGate.swift`
- Create: `Tests/voice_key_gate.json`. It sits outside every target directory, so SwiftPM ignores it. Dart reads it as `../Tests/voice_key_gate.json`.
- Create: `Tests/RappSessionTests/VoiceKeyGateTests.swift`. It reads the fixture via `URL(fileURLWithPath: #filePath)`, going up two directories.

**Interfaces (produces; Task 5 mirrors them in Dart under the same names):**

```swift
public enum VoiceHotkey: Equatable {
    case holdModifier(UInt16), holdCombo(UInt16, KeyFlags), off
    public static let standard = VoiceHotkey.holdModifier(61)
    public init(json: Any?)        // invalid or missing → .standard
}
public enum VoiceKeyPhase: String { case start, release, cancel, edit }
public enum VoiceGateInput: Equatable {
    case down(UInt16, KeyFlags, isRepeat: Bool), up(UInt16), pointer, scroll, elapsed, resign, ended
}
public struct VoiceGateStep: Equatable {
    public var flush = false   // send the held hotkey down to A first
    public var pass = false    // this event goes on to A (pointer/scroll always true)
    public var arm = false     // feed .elapsed in 0.3 s
    public var voice: VoiceKeyPhase?
}
public struct VoiceKeyGate {
    public var hotkey: VoiceHotkey
    public init(hotkey: VoiceHotkey = .standard)
    public var recording: Bool { get }
    public mutating func handle(_ input: VoiceGateInput, at seconds: Double, ready: Bool) -> VoiceGateStep
}
```

**Rules:**
- **State** is `idle | pending(since) | recording | decided`.
- **Tracking.** The gate keeps its own set of keys that are down, and a set of swallowed codes.
- **Modifier codes:** {54, 55, 56, 57, 58, 59, 60, 61, 62, 63}. The JSON accepts `hold_modifier` codes from {54, 55, 56, 58, 59, 60, 61, 62, 63}.
- **`hold_combo` validity** is `acceptsCombo(code, mods)`, which is public and also used by Task 6's recorder:
  - The code is not a modifier, not 53 and not 48.
  - `mods ∩ {control, option, command}` is non-empty.
  - The combo is not ⌃⌘ (both control and command).
  - It is not ⌘ with code 12.
  - It is not ⌃ with 36 or 76.
- **Up-rule.** A down that was swallowed puts its code in the swallowed set, and its up is swallowed and the code removed. Any new down first removes its own code from the swallowed set.
- **"Others down"** means the down-set (excluding the hotkey code) is non-empty, or `flags ∩ {control, option, shift, command, function}` minus the hotkey's own bit is non-empty. The own bit: option for 58/61, control for 59/62, shift for 56/60, command for 54/55, function for 63.
- **`elapsed`** counts only in `pending` and when `seconds − since ≥ 0.3`.
- **Combo start:** a down of the combo's code (not a repeat), with `flags ∩ {control, option, shift, command} == modifiers`, while ready and idle.

- [ ] **Step 1: Write the fixture.** It is a JSON array of `{"name", "hotkey" (default when absent), "ready" (default true), "steps": [{"t": ms, "in": "...", "out": "..."}]}`.
  - The `in` mini-language: `down <code> [shift|ctrl|opt|cmd|fn]... [repeat]`, `up <code>`, `pointer`, `scroll`, `elapsed`, `resign`, `ended`.
  - `out` is space-separated tokens from {flush, pass, swallow, arm, start, release, cancel, edit, none}. `swallow` means `pass == false` on a key event. `none` means no flags and no voice.
  - A step may carry `"ready": false`.
  - These cases, exactly:

| name | steps (t ms: in → out) |
|---|---|
| tap | 0: down 61 opt → swallow arm; 120: up 61 → flush pass |
| option-arrow | 0: down 61 opt → swallow arm; 80: down 123 opt fn → flush pass; 150: up 123 → pass; 200: up 61 → pass; 300: elapsed → none |
| hold-send | 0: down 61 opt → swallow arm; 300: elapsed → start; 2000: up 61 → swallow release |
| esc-cancels | 0: down 61 opt → swallow arm; 300: elapsed → start; 900: down 53 opt → swallow cancel; 950: up 53 → swallow; 1000: down 0 opt → swallow; 1050: up 0 → swallow; 1200: up 61 → swallow |
| tab-edits | 0: down 61 opt → swallow arm; 300: elapsed → start; 900: down 48 opt → swallow edit; 950: up 48 → swallow; 1200: up 61 → swallow |
| keys-swallowed-while-recording | 0: down 61 opt → swallow arm; 300: elapsed → start; 500: down 0 opt → swallow; 520: down 0 opt repeat → swallow; 600: up 0 → swallow; 900: up 61 → swallow release |
| other-key-already-down | 0: down 0 → pass; 50: down 61 opt → pass; 400: up 0 → pass; 450: up 61 → pass |
| left-option-held | 0: down 58 opt → pass; 50: down 61 opt → pass; 400: elapsed → none; 500: up 61 → pass; 550: up 58 → pass |
| shift-held | 0: down 56 shift → pass; 50: down 61 shift opt → pass; 500: up 61 → pass; 550: up 56 → pass |
| modifier-during-pending | 0: down 61 opt → swallow arm; 100: down 56 shift opt → flush pass; 300: elapsed → none; 400: up 56 → pass; 450: up 61 → pass |
| pointer-during-pending | 0: down 61 opt → swallow arm; 100: pointer → flush pass; 300: elapsed → none; 400: up 61 → pass |
| scroll-during-pending | 0: down 61 opt → swallow arm; 100: scroll → flush pass; 500: up 61 → pass |
| pointer-while-recording | 0: down 61 opt → swallow arm; 300: elapsed → start; 800: pointer → pass cancel; 900: up 61 → swallow |
| scroll-while-recording | 0: down 61 opt → swallow arm; 300: elapsed → start; 800: scroll → pass; 900: up 61 → swallow release |
| stale-timer | 0: down 61 opt → swallow arm; 100: up 61 → flush pass; 200: down 61 opt → swallow arm; 300: elapsed → none; 500: elapsed → start; 700: up 61 → swallow release |
| resign-pending | 0: down 61 opt → swallow arm; 100: resign → none; 200: up 61 → swallow |
| resign-recording | 0: down 61 opt → swallow arm; 300: elapsed → start; 800: resign → cancel; 900: up 61 → swallow |
| resign-then-fresh-press | 0: down 61 opt → swallow arm; 300: elapsed → start; 800: resign → cancel; 5000: down 61 opt → swallow arm; 5100: up 61 → flush pass |
| ended-then-up | 0: down 61 opt → swallow arm; 300: elapsed → start; 60300: ended → none; 60400: down 0 opt → swallow; 60450: up 0 → swallow; 60500: up 61 → swallow |
| not-ready | 0 (ready false): down 61 opt → pass; 400: up 61 → pass |
| off | hotkey "off"; 0: down 61 opt → pass; 400: up 61 → pass |
| fn-hold | hotkey hold_modifier 63; 0: down 63 fn → swallow arm; 300: elapsed → start; 900: up 63 → swallow release |
| combo-hold | hotkey hold_combo 49 ctrl+opt (786432); 0: down 59 ctrl → pass; 20: down 58 ctrl opt → pass; 40: down 49 ctrl opt → swallow start; 300: down 49 ctrl opt repeat → swallow; 500: up 59 → pass; 520: up 58 → pass; 900: up 49 → swallow release |
| combo-wrong-mods | hotkey hold_combo 49 786432; 0: down 59 ctrl → pass; 20: down 49 ctrl → pass; 80: up 49 → pass; 90: up 59 → pass |
| combo-esc | hotkey hold_combo 49 786432; 0: down 59 ctrl → pass; 20: down 58 ctrl opt → pass; 40: down 49 ctrl opt → swallow start; 300: down 53 ctrl opt → swallow cancel; 350: up 53 → swallow; 400: up 49 → swallow; 450: up 58 → pass; 460: up 59 → pass |

- [ ] **Step 2: Write the tests.**
  - `testFixtureCases`: run every case through one `VoiceKeyGate`, assert each step's tokens, and name the case and step on failure.
  - `testHotkeyJson`:
    - `VoiceHotkey(json: ["kind": "hold_combo", "key_code": 49, "modifiers": 786432]) == .holdCombo(49, [.control, .option])`.
    - `VoiceHotkey(json: "off") == .off`.
    - `VoiceHotkey(json: ["kind": "hold_modifier", "key_code": 0]) == .standard`, since 0 is not a modifier.
    - `VoiceHotkey(json: ["kind": "hold_combo", "key_code": 12, "modifiers": 1 << 20]) == .standard`, since ⌘Q is rejected.
    - `VoiceHotkey(json: nil) == .standard`.
- [ ] **Step 3:** Run `swift test --filter VoiceKeyGateTests`. Expected: FAIL (`cannot find 'VoiceKeyGate'`).
- [ ] **Step 4:** Implement `VoiceKeyGate.swift` to the rules above.
- [ ] **Step 5:** Run `swift test --filter VoiceKeyGateTests`. Expected: PASS, all cases. Then run `swift test --filter RappSessionTests`. Expected: PASS.
- [ ] **Step 6: Commit** the three files, with message `feat(voice): VoiceKeyGate — hold-to-talk hotkey rules with a shared case table`.

### Task 4: Native wiring — channel methods and SessionPlugin

**Files:**
- Modify: `Sources/RappSession/Channel.swift`:
  - `.pictureFocus(sid, compose:)` → `.pictureFocus(sid, compose:, voice:)`. `voice` is read like `compose`: true only when it is literally `true`.
  - Add `case setVoiceHotkey(VoiceHotkey)` from `set_voice_hotkey {hotkey}`.
  - Add `case voiceEnd(Int64)` from `voice_end {sid}`.
  - Add both names to the `known` set (~95–100).
- Modify: `Tests/RappSessionTests/ChannelTests.swift`.
- Modify: `gui/macos/Runner/SessionPlugin.swift`:
  - New fields: `gate = VoiceKeyGate()`, `voiceOn = false` (set beside `composeOn` in `.pictureFocus`), `gateHeld: NSEvent?`, `gateSid: Int64?`, `gateTimer: DispatchWorkItem?`.
  - Split the `.main` branch after `targetSid`: everything from `hold.add` down to the send becomes `private func routeMain(_ event: NSEvent, down: Bool, targetSid: Int64?) -> NSEvent?`.
  - At the front of `.main`:
    - Build the input from the event: `.down` or `.up`, using the `down` already computed; flagsChanged is mapped via `modifierKeyIsDown`.
    - Call `gate.handle(input, at: systemUptime, ready: voiceOn && targetSid != nil)`.
    - If `flush`: `routeMain(gateHeld!, …)`, then clear `gateHeld`.
    - If the step is pending-swallow (`arm`): store `gateHeld = event` and `gateSid = targetSid`, and schedule `gateTimer` for 0.3 s to feed `.elapsed`.
    - If `voice`: `channel.invokeMethod("voice_key", ["sid": gateSid, "phase": phase.rawValue])`.
    - Return `pass ? routeMain(event, …) : nil`.
  - `handle(.mouse)` with a press, and `handle(.scroll)`:
    - Feed `.pointer` or `.scroll` first, then flush and send `voice_key` as above.
    - Then send the mouse or scroll event as today.
  - The didResignKey observer feeds `.resign` before `releaseKeys()`, and drops `gateHeld` (A never saw it).
  - `.setVoiceHotkey(h)`: `gate.hotkey = h`. `.voiceEnd(sid)`: `if sid == gateSid { gate.handle(.ended, …) }`.

**Interfaces:**
- Consumes: Task 3's `VoiceKeyGate`, `VoiceHotkey(json:)`, `VoiceKeyPhase`.
- Produces, on channel `rapp/session`:
  - Dart → native: `picture_focus {sid, compose?, voice?}`, `set_voice_hotkey {hotkey: <gui.json value>}`, `voice_end {sid}`.
  - Native → Dart: `voice_key {sid, phase: "start"|"release"|"cancel"|"edit"}`.

- [ ] **Step 1: Write the failing tests** in `ChannelTests.swift`:
  - `testPictureFocusVoice`: `["sid": 3, "compose": true, "voice": true]` → `.pictureFocus(3, compose: true, voice: true)`, and without `voice` → `voice: false`.
  - `testSetVoiceHotkey`: `["hotkey": "off"]` → `.setVoiceHotkey(.off)`, and `["hotkey": 5]` → `.setVoiceHotkey(.standard)`.
  - `testVoiceEnd`: `["sid": 3]` → `.voiceEnd(3)`, and with no sid → nil.
- [ ] **Step 2:** Run `swift test --filter ChannelTests`. Expected: FAIL to compile (no `voice:` label).
- [ ] **Step 3:** Implement the Channel.swift changes, then the SessionPlugin wiring.
- [ ] **Step 4:** Run `swift test --filter RappSessionTests`. Expected: PASS. Then run `cd gui && flutter build macos --debug`. Expected: `✓ Built`.
- [ ] **Step 5: Commit** Channel.swift, ChannelTests.swift and SessionPlugin.swift, with message `feat(voice): native hotkey gate on the stage picture`.

### Task 5: Dart `VoiceKeyGate`

**Files:**
- Create: `gui/lib/embed/voice_key_gate.dart`
- Create: `gui/test/embed/voice_key_gate_test.dart`. It reads `File('../Tests/voice_key_gate.json')`.

**Interfaces (produces):** the Task 3 types under the same names, plus two helpers:
- `VoiceHotkey` is a class with `const VoiceHotkey.holdModifier(int keyCode)`, `const VoiceHotkey.holdCombo(int keyCode, int modifiers)` and `static const off`.
  - It has `static const standard = VoiceHotkey.holdModifier(61)`, `factory VoiceHotkey.fromJson(Object? j)` (invalid → standard) and `Object toJson()`, plus value equality.
  - It exposes the getters `bool get isOff`, `bool get isModifier`, `int get keyCode` and `int get modifiers`.
- `bool acceptsCombo(int code, int mods)` and `const modifierCodes = {54,…,63}`.
- `enum VoiceKeyPhase { start, release, cancel, edit }` and `VoiceGateInput`:
  - `VoiceGateInput.down(int code, int flags, {bool repeat = false})`
  - `VoiceGateInput.up(int code)`
  - `VoiceGateInput.pointer`, `.scroll`, `.elapsed`, `.resign`, `.ended`
- `class VoiceGateStep { bool flush, pass, arm; VoiceKeyPhase? voice; }`
- `class VoiceKeyGate { VoiceHotkey hotkey; bool get recording; VoiceGateStep handle(VoiceGateInput i, {required int ms, required bool ready}); }`
- Helpers:
  - `int? macKeyCode(PhysicalKeyboardKey k)`: the inverse of Flutter's `kMacOsToPhysicalKey`, built once.
  - `int macFlags(HardwareKeyboard hk)`: control, option, shift and command from `hk.isControlPressed` and friends; function when `hk.physicalKeysPressed.contains(PhysicalKeyboardKey.fn)`.

- [ ] **Step 1: Write the tests.**
  - `'every case in the shared table'`: run each fixture case with the Task 3 token semantics.
  - `'hotkey json round-trips'`: the same values as `testHotkeyJson`, plus `VoiceHotkey.holdCombo(49, 786432).toJson()` equals `{'kind': 'hold_combo', 'key_code': 49, 'modifiers': 786432}`.
  - `'mac key codes'`: `macKeyCode(PhysicalKeyboardKey.altRight) == 61`, `macKeyCode(PhysicalKeyboardKey.escape) == 53`, `macKeyCode(PhysicalKeyboardKey.fn) == 63`.
- [ ] **Step 2:** Run `flutter test test/embed/voice_key_gate_test.dart`. Expected: FAIL (missing file).
- [ ] **Step 3:** Implement `voice_key_gate.dart`.
- [ ] **Step 4:** Run `flutter test test/embed/voice_key_gate_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** both files, with message `feat(voice): Dart twin of VoiceKeyGate on the shared table`.

### Task 6: Hotkey labels, the key recorder, prefs

**Files:**
- Create: `gui/lib/embed/voice_hotkey.dart`
- Create: `gui/test/embed/voice_hotkey_test.dart`
- Modify: `gui/lib/ui/prefs.dart`. Add the fields `VoiceHotkey voiceHotkey = VoiceHotkey.standard` and `bool voiceLanguageHintShown = false`, with load and save under `voice_hotkey` and `voice_language_hint_shown`.
- Modify: the prefs test file, if `gui/test/ui/prefs_test.dart` exists; otherwise create it.

**Interfaces:**
- Consumes: Task 5's `VoiceHotkey`, `acceptsCombo`, `modifierCodes`.
- Produces: `String voiceHotkeyLabel(VoiceHotkey h)`.
  - Off → 「关」.
  - Modifier → 「长按 」 + one of: 61 「右 ⌥」, 58 「左 ⌥」, 62 「右 ⌃」, 59 「左 ⌃」, 60 「右 ⇧」, 56 「左 ⇧」, 54 「右 ⌘」, 55 「左 ⌘」, 63 「Fn」.
  - Combo → 「按住 」 + the modifier glyphs in the order ⌃⌥⇧⌘ + the key name.
  - Key names: 49 Space, letters as capitals, digits, F1–F12, arrows ←→↑↓, 36 ↩; anything else 「键 <code>」. Use the ANSI macOS key-code table.
- Produces: `sealed class RecordOutcome` with subclasses `RecordPending`, `RecordSet(VoiceHotkey)`, `RecordRejected` and `RecordAborted`.
- Produces: `class VoiceHotkeyRecorder { RecordOutcome down(int code, int flags); RecordOutcome up(int code); }`.
  - Esc (53) → aborted.
  - A modifier down remembers a lone candidate. Any other down clears it.
  - The lone modifier's up, if it is in the hold set (not 57), sets `holdModifier`.
  - A non-modifier down with `mods = flags & (ctrl|opt|shift|cmd)` sets `holdCombo` when `acceptsCombo(code, mods)`; otherwise it is rejected.
  - CapsLock is rejected.

- [ ] **Step 1: Write the failing tests:**
  - `'labels'`: `voiceHotkeyLabel(VoiceHotkey.standard) == '长按 右 ⌥'`, `voiceHotkeyLabel(const VoiceHotkey.holdCombo(49, 786432)) == '按住 ⌃⌥Space'`, `voiceHotkeyLabel(VoiceHotkey.off) == '关'`.
  - `'a lone modifier tap sets a hold'`: down(62, ctrl), then up(62) → `RecordSet(holdModifier(62))`.
  - `'a combo sets at once'`: down(59, ctrl) → pending; down(49, ctrl) → `RecordSet(holdCombo(49, 1<<18))`.
  - `'rejected keys'`: down(0, 0), down(0, shift), down(48, opt), down(12, cmd), down(36, ctrl), down(0, ctrl|cmd), and down(57) then up(57) → `RecordRejected`.
  - `'esc aborts'`: down(53, 0) → `RecordAborted`.
  - `'modifier then a key is not a lone tap'`: down(58, opt), down(0, opt) → `RecordSet(holdCombo(0, opt))`; then up(58) → pending.
  - `'prefs round-trip'`: save a `UiPrefs` with `voiceHotkey = holdCombo(49, 786432)` and `voiceLanguageHintShown = true`, then load it → equal. Write `{"voice_hotkey": 7}` → loads `standard`. A missing key → `standard` and `false`.
- [ ] **Step 2:** Run `flutter test test/embed/voice_hotkey_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement `voice_hotkey.dart` and the prefs fields.
- [ ] **Step 4:** Run `flutter test test/embed/voice_hotkey_test.dart test/ui/prefs_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** the files, with message `feat(voice): hotkey labels, key recorder, gui.json voice_hotkey`.

### Task 7: MainState and SessionPort wiring

**Files:**
- Modify: `gui/lib/embed/session_port.dart`:
  - `pictureFocus(Object? sid, {bool compose = false, bool voice = false})` sends `'voice': true` only when true.
  - `void setVoiceHotkey(VoiceHotkey h)` → `_send('set_voice_hotkey', {'hotkey': h.toJson()})`.
  - `void voiceEnd(Object sid)` → `_send('voice_end', {'sid': sid})`.
  - The event `voice_key` → `VoiceKeyEvent(sid, VoiceKeyPhase)`. An unknown phase → null.
- Modify: `gui/lib/ui/main_state.dart`:
  - Line 134: create the voice when `defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS`.
  - `_voiceFor(sid)` is true when all of these hold:
    - The platform is macOS and `voice != null`.
    - `remote[sid]` is an app picture: not detached, and not owned by termPort.
    - `rs.composerAllowed` is true and `rs.composer.open` is false.
  - `_sendFocus` passes `voice: _voiceFor(sid)`. `_syncCompose` re-sends when either flag moved, so a panel that opens or closes while the picture is focused updates the native side.
  - `Stream<(Object, VoiceKeyPhase)> get voiceKeys` comes from a broadcast controller. `void voiceKey(Object sid, VoiceKeyPhase p)` adds to it. `_onPortEvent` routes `VoiceKeyEvent` there.
  - `Stream<Object> get voiceEnds` and `void voiceEnd(Object sid)`:
    - For a terminal sid, add to `voiceEnds`, which Task 10's term gate listens to.
    - Otherwise call `portOf(sid)?.voiceEnd(sid)`.
  - `void setVoiceHotkey(VoiceHotkey h)` saves the prefs, calls `port?.setVoiceHotkey(h)` and notifies.
    - On macOS, the constructor sends `prefs.voiceHotkey` once through `port?.setVoiceHotkey`.
    - Terminal stages read `prefs.voiceHotkey` directly.
  - `void voiceLanguageHintDone()` sets `prefs.voiceLanguageHintShown = true` and saves.
- Modify: `gui/test/fakes.dart`, if `FakeSessionPort` needs overrides for the new methods (it records `calls`).
- Test: `gui/test/embed/voice_wiring_test.dart`.

**Interfaces:**
- Consumes: Tasks 4–6.
- Produces, for Tasks 8–11: `state.voiceKeys`, `state.voiceKey`, `state.voiceEnd`, `state.voiceEnds`, `state.setVoiceHotkey`, `state.voiceLanguageHintDone`.

- [ ] **Step 1: Write the failing tests**, all with the macOS override:
  - `'focusing an app picture tells native it may talk'`: `focusPicture(1)` → `port.calls` has `('picture_focus', {'sid': 1, …, 'voice': true})`.
  - `'an open panel takes voice away'`: with the composer open and the picture focused, the last `picture_focus` for sid 1 has no `voice` key.
  - `'linux sends no voice flag'`: Linux override → no `voice` key, and `state.voice == null`.
  - `'hotkey sent at start and on change'`: construction → `('set_voice_hotkey', {'hotkey': {'kind': 'hold_modifier', 'key_code': 61}})`; `setVoiceHotkey(VoiceHotkey.off)` → `{'hotkey': 'off'}`.
  - `'voice_key events reach voiceKeys'`: `port.emit(VoiceKeyEvent(1, VoiceKeyPhase.start))` → `voiceKeys` yields `(1, start)`.
  - `'voice_key parses'`: the SessionPort parser maps `{'event': 'voice_key', 'sid': 1, 'phase': 'edit'}` → `VoiceKeyEvent(1, edit)` and `'phase': 'x'` → null. Put this test next to the existing `compose_key` parse test.
- [ ] **Step 2:** Run `flutter test test/embed/voice_wiring_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `flutter test test/embed/voice_wiring_test.dart test/embed/remote_session_test.dart test/embed/composer_panel_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit**, with message `feat(voice): macOS voice wiring — picture_focus voice flag, hotkey, voice_key events`.

### Task 8: `VoiceHold` without a pointer, hints

**Files:**
- Modify: `gui/lib/embed/voice_button.dart`
- Modify: `gui/test/embed/voice_button_test.dart`

**Interfaces (produces, for Tasks 9 and 10):**
- `Future<void> start()`: the press without a ring. `down(thumb, stage, right)` becomes "set the ring, then `start()`"; its signature is unchanged.
- `void choose(VoicePick p)`: while holding, sets `pick` and notifies on change. No haptics.
- `void finish(VoicePick p)`:
  - While holding: `pick = p`, then release.
  - Pressed but not yet holding: `p == cancel` acts as `cancel()`; otherwise it acts as `up()`.
- Constructor: `void Function(VoicePick? pick)? onEnd`. It is called once per press when the press is over:
  - With the pick, after a release has finished.
  - With null when the start did not give `ok`, or on a quick tap.
  - With null from `dispose` when a hold was cut short.
- Constructor: `bool Function()? languageHintDue` and `void Function()? languageHintShown`.
  - After a release that set no other hint, if due: set `voiceLanguageHint` and call shown.
- `bool settings` becomes `VoiceSettings settings` (`enum VoiceSettings { none, privacy, language }`).
- Constants:
  - `voiceUnavailable` = 「这种系统语言暂不支持语音识别，可以在系统设置里换一种」.
  - `voiceLanguageHint` = 「识别语言跟随系统。要换语言：系统设置 → 通用 → 语言与地区」. It lives 6 s in `_life`.
- `voiceHint`'s 「去设置」:
  - On iOS, `privacy` → `iosChannel.openSettings()`, and `language` shows no button.
  - On macOS, `privacy` → `open` the microphone URL and `language` → `open` the Language & Region URL. Use a top-level `Future<void> openVoiceSettings(VoiceSettings s)`, with `Process.run` injectable for the test.

- [ ] **Step 1: Write the failing tests** (`FakeVoice` as today):
  - `'start without a ring holds and finish(send) sends'`: `start()` → `holding`; `finish(VoicePick.send)` with voice text 「你好」 → `port` got `composerSend`, and `onEnd` got `send`.
  - `'finish(cancel) drops the words'`: no `composerSend`; `onEnd(cancel)`.
  - `'finish(edit) puts the words in the draft'`: `edit` callback got 「你好」.
  - `'choose changes the pick without haptics'`: with the macOS override, `choose(VoicePick.cancel)` → `pick == cancel` and listeners were notified once; a second `choose(VoicePick.cancel)` does not notify. (No haptic call is made on macOS: `HapticFeedback` is only called under the iOS platform check.)
  - `'a refused start ends with null'`: `startResult = VoiceStart.denied` → `onEnd(null)`, `hint == voiceDenied`, `settings == VoiceSettings.privacy`.
  - `'language hint once, after the first hold'`:
    - With due → true, after a send: `hint == voiceLanguageHint` and `settings == VoiceSettings.language`, and shown was called once.
    - With due → false: no hint.
  - `'a 没听清 release does not show the language hint'`: empty text → `hint == voiceBlank`, and shown is not called.
  - `'macOS 去设置 opens the pane'`: `openVoiceSettings(VoiceSettings.language)` runs `open` with the Language & Region URL.
  - The existing iOS tests stay green, with the unavailable copy updated wherever a test spells it out.
- [ ] **Step 2:** Run `flutter test test/embed/voice_button_test.dart`. Expected: FAIL on the new tests.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `flutter test test/embed/voice_button_test.dart test/embed/voice_input_test.dart test/embed/voice_ring_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit**, with message `feat(voice): VoiceHold entry points without a pointer; language hint; per-platform 去设置`.

### Task 9: Desktop button, bubble and targets

**Files:**
- Create: `gui/lib/embed/voice_desktop.dart`
- Modify: `gui/lib/embed/voice_overlay.dart`. Rename `_BubbleFrame` to the public `VoiceBubbleFrame` with `final bool tail` (default true; when false, no tail and a plain rounded rect). Rename `_hintLine` to `voiceHintLine`.
- Modify: `gui/lib/embed/composer_panel.dart`, the non-iOS row (~697–757).
- Test: `gui/test/embed/voice_desktop_test.dart`

**Interfaces:**
- Consumes: Task 7's `state.voiceKeys` and `state.voiceEnd`, and Task 8's `VoiceHold.start`, `choose`, `finish` and `onEnd`.
- Produces: `VoicePick desktopPick(Offset p, Rect cancel, Rect edit)`. Each rect is inflated by 6; outside both → send.
- Produces: `class DesktopVoice extends StatefulWidget`. It is built by `composerLayer` with `(state, session, port)`. It owns one `VoiceHold` per session, created the way `_IosStage` creates one (edit → `c.keep(text); c.open = true`), with:
  - `onEnd: (p) { state.voiceEnd(sid); if (p == VoicePick.send || p == VoicePick.cancel) state.focusPicture(sid); }`
  - `languageHintDue: () => !state.prefs.voiceLanguageHintShown`
  - `languageHintShown: state.voiceLanguageHintDone`
- Its children:
  - **The button.** `RappButton.secondary`, Key `voice-hold`, semantics 「语音」, label 「按住说话」, icon `Icons.mic_none` (or `Icons.mic` while holding), `onPicture: true`.
    - A `Listener` on it: pointer down (primary button) → `state.holdForPanel`-style blur, then `hold.start()`.
    - Move → `hold.choose(desktopPick(global, cancelRect, editRect))`, with the rects taken from GlobalKeys on the targets.
    - Up → `hold.finish(hold.pick)`. Cancel → `hold.finish(VoicePick.cancel)`.
    - Ignored when `state.voiceKeys` started a hold.
  - **The column.** While `hold.active`: the bubble, the targets row 「编辑」+「Tab」 then 「取消」+「Esc」 (Keys `voice-edit` and `voice-cancel`; key names in `t.muted`), and the hint line `voiceHintLine(pick)`.
    - It is right-aligned, with its bottom 8 above the row.
    - The bubble is `min(W − 32, 480)` wide, with at most 4 lines showing the tail, `VoiceBarsPainter` bars, and 「正在听…」 before any text.
  - **Keys during a mouse hold.** A `HardwareKeyboard.instance` handler is registered only while a mouse hold is on: Esc → `finish(cancel)`, Tab → `finish(edit)`; both return true.
  - **Hotkey events.** A `voiceKeys` subscription for its sid:
    - start → `hold.start()`, ignored while a mouse hold is on.
    - release → `finish(send)`, cancel → `finish(cancel)`, edit → `finish(edit)`.
- `composerLayer`:
  - On macOS, when 「输入」 shows and `state.voice != null`, it puts `DesktopVoice` rightmost in the row.
  - While `hold.active`, the other row items and the progress line fade to 0 over 120 ms.
  - Reduced motion makes the fades and the 160 ms rise instant.

- [ ] **Step 1: Write the failing tests** (`FakeVoice`, `FakeSessionPort`, macOS override, a 1000×700 stage):
  - `'desktopPick inflates targets by 6'`: `desktopPick(Offset(105, 50), Rect.fromLTWH(110, 40, 60, 24), Rect.fromLTWH(10, 40, 60, 24)) == VoicePick.cancel`, and at `Offset(103, 50)` the result is `send`.
  - `'the row has 按住说话 rightmost on macOS'`: `find.byKey(Key('voice-hold'))` is to the right of `Key('composer-open')`. With the Linux override → not found.
  - `'press shows 正在听… then send'`:
    - `tester.startGesture` on `voice-hold` → `find.text('正在听…')` and 「松手 发送」.
    - Up with text 「你好」 → `composerSend` with 「你好」, and `port.calls` ends with `picture_focus` for sid 1 (refocused).
  - `'drag onto 取消 then release sends nothing'`: move the gesture to the `voice-cancel` centre → 「松手 取消」; up → no `composerSend`.
  - `'drag onto 编辑 opens the panel with the words'`: up over `voice-edit` → `session.composer.open`, and the draft ends with 「你好」.
  - `'Esc during a mouse hold cancels'`: `sendKeyEvent(LogicalKeyboardKey.escape)` → `voice.cancelled`, and the bubble is gone after settle.
  - `'hotkey start and release send'`: `state.voiceKey(1, start)` → 「正在听…」; then `voiceKey(1, release)` → `composerSend`.
  - `'disposing during a hotkey hold sends voice_end'`: start via `voiceKey`, then pump an empty widget tree → `port.calls` contains `('voice_end', {'sid': 1})`, and the draft kept the words.
  - `'bubble width'`: on a 400-wide stage, the bubble box is 368 wide. On a 1000-wide stage, it is 480.
  - `'other buttons fade while holding'`: during the hold, the `Opacity` above `composer-open` reaches 0 after 120 ms.
- [ ] **Step 2:** Run `flutter test test/embed/voice_desktop_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `flutter test test/embed/voice_desktop_test.dart test/embed/composer_panel_test.dart test/embed/voice_button_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit**, with message `feat(voice): 按住说话 on the macOS stage — bubble, 编辑/取消 targets, hotkey events`.

### Task 10: Hotkey in text terminals

**Files:**
- Modify: `gui/lib/term/term_stage.dart`
- Test: `gui/test/term/term_stage_voice_test.dart`

**Interfaces:**
- Consumes: Task 5's `VoiceKeyGate`, `macKeyCode` and `macFlags`, and Task 7's `state.voiceKey`, `state.voiceEnds` and `state.prefs.voiceHotkey`.
- New in `_TermStageState`: `final _gate = VoiceKeyGate()`, `KeyEvent? _gateHeld`, `Timer? _gateTimer`.
- `bool get _voiceReady` is true when the platform is macOS, `state.voice != null`, `session.composerAllowed` is true, the composer is not open, and the stage has focus.

**Changes:**
- **Key path.**
  - Rename the current body of `_onKey` to `_termKey(FocusNode, KeyEvent)`.
  - The new `_onKey` sets `_gate.hotkey = state.prefs.voiceHotkey` and maps the KeyEvent:
    - KeyDownEvent → `down(code, macFlags(HardwareKeyboard.instance))`.
    - KeyRepeatEvent → the same, with `repeat: true`.
    - KeyUpEvent → `up(code)`.
    - An event with no mac code bypasses the gate.
  - It then calls `handle(…, ms: monotonic ms, ready: _voiceReady)`:
    - If `flush`: `_termKey(node, _gateHeld!)`.
    - If `arm`: hold the event and start a 300 ms `_gateTimer` that feeds `elapsed`.
    - If `voice`: `state.voiceKey(sid, phase)`.
    - Return `pass ? _termKey(node, e) : KeyEventResult.handled`.
- **Pointer and focus.** `_onDown` feeds `pointer` first, `_onSignal` feeds `scroll`, and `_onFocus` on losing focus feeds `resign`, with flush and voice handled the same way.
- **Ends.** Subscribe to `state.voiceEnds` for this sid → feed `ended`.

- [ ] **Step 1: Write the failing tests** (macOS override, a terminal stage as in `term_stage_keys_test.dart`):
  - `'a quick tap of right option still reaches the terminal'`: press and release `altRight` within 100 ms → the terminal handler saw the down, as today's Option handling does; no `voiceKeys` event.
  - `'flushed option reaches the terminal before the letter'`: with Option as Meta on, down altRight, then down keyB with option held → the terminal input is `ESC b` (Meta-b), exactly as without the gate.
  - `'holding right option starts voice and swallows it'`: down altRight, `tester.pump(Duration(milliseconds: 300))` → `voiceKeys` yields `(sid, start)`; up altRight → `(sid, release)`, and the terminal saw neither.
  - `'esc while recording cancels and nothing reaches the terminal'`.
  - `'not ready with the panel open'`: with the composer open, holding altRight for 400 ms gives no `voiceKeys` event.
  - `'voice_end returns the gate'`: start, then `state.voiceEnd(sid)`; then down and up of keyA → nothing reaches the terminal; up altRight → swallowed; then a new tap of keyA → reaches the terminal.
- [ ] **Step 2:** Run `flutter test test/term/term_stage_voice_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `flutter test test/term/`. Expected: PASS. This is the whole terminal folder, so the existing key tests are included.
- [ ] **Step 5: Commit**, with message `feat(voice): hold-to-talk hotkey in text terminals`.

### Task 11: Settings row, todo checks

**Files:**
- Modify: `gui/lib/ui/side_panel.dart`. Right after the `input-history` toggle (~299), add a macOS-only row.
- Test: `gui/test/ui/side_panel_voice_test.dart`
- Modify: `tasks/todo.md`. Add a section 「macOS 按住说话（真机）」 that lists spec §9 items 1–18 as unchecked boxes, worded as in the spec.

**The row:**
- It has Key `voice-hotkey`, the text 「语音快捷键」, and the value `voiceHotkeyLabel(state.prefs.voiceHotkey)`.
- Buttons (`RappButton.secondary`, small): 「改」 (`voice-hotkey-change`), 「关」 (`voice-hotkey-off`), 「恢复默认」 (`voice-hotkey-default`).
- 「改」 swaps the value for 「请按下快捷键…（Esc 取消）」 and puts an autofocused `Focus` around the row.
  - Its `onKeyEvent` feeds a `VoiceHotkeyRecorder` with `macKeyCode` and `macFlags`, and always returns handled.
  - `RecordSet` → `state.setVoiceHotkey`, then leave recording.
  - `RecordRejected` → show 「这个键不能用」 under the row and keep recording.
  - `RecordAborted` → leave recording unchanged.

**Interfaces:**
- Consumes: Task 6's `voiceHotkeyLabel` and `VoiceHotkeyRecorder`, Task 5's `macKeyCode` and `macFlags`, and Task 7's `state.setVoiceHotkey`.

- [ ] **Step 1: Write the failing tests** (macOS override):
  - `'shows the default'`: 「长按 右 ⌥」.
  - `'Linux has no row'`: `find.byKey(Key('voice-hotkey'))` finds nothing.
  - `'record ⌃⌥Space'`:
    - Tap 「改」 → 「请按下快捷键…（Esc 取消）」.
    - `sendKeyDownEvent(controlLeft)`, `sendKeyDownEvent(altLeft)`, `sendKeyDownEvent(space)` → the row shows 「按住 ⌃⌥Space」.
    - `port.calls` has `set_voice_hotkey` with `{'kind': 'hold_combo', 'key_code': 49, 'modifiers': 786432}`, and gui.json holds the same.
  - `'a plain key is refused and recording goes on'`: 「改」, then keyA → 「这个键不能用」, and still 「请按下快捷键…」.
  - `'Esc leaves recording unchanged'`.
  - `'关 and 恢复默认'`: 「关」 → 「关」 and `{'hotkey': 'off'}`; 「恢复默认」 → 「长按 右 ⌥」.
- [ ] **Step 2:** Run `flutter test test/ui/side_panel_voice_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement the row, and add the todo section.
- [ ] **Step 4:** Run `flutter test`, the whole suite (in the background with output to a file; read the tail). Expected: `All tests passed!`. Then run `swift test`. Expected: PASS. Then run `cd gui && flutter build macos --debug && cd .. && scripts/build-ios.sh sim`. Expected: both built. Revert the lock files.
- [ ] **Step 5: Commit** side_panel.dart, the test and tasks/todo.md, with message `feat(voice): 语音快捷键 setting row; real-machine checks in todo`.
