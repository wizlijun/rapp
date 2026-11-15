# 按字母键打开写作面板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On an app picture with focus, a plain letter key opens the writing panel and becomes its first character (on Mac through B's own IME); every other key still goes to A; opening the panel by any route first switches A's IME to English.

**Architecture:** Dart tells the runner per focused session whether type-to-compose applies (`picture_focus {sid, compose}`). The Mac key monitor holds a compose letter (and every main-window key after it) instead of sending it to A, emits `compose_key {sid}`; Dart opens the panel, takes the caret, blurs the picture, then calls `compose_replay {sid}` and the runner re-dispatches the held events into its own window, so they reach Flutter's text input and B's IME. Linux decides in `handleKeyEvent` and inserts the letter as-is. A listener on the composer's closed→open transition switches A to English.

**Tech Stack:** Swift (RappSession package + macOS Runner plugin), Flutter/Dart (gui/), XCTest, flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-15-rapp-type-to-compose-design.md`

## Global Constraints

- Flutter: `~/development/flutter/bin/flutter`, run from `gui/`. After any test run: `git checkout pubspec.lock`.
- Swift tests: `swift test` from the repo root (RappSession package).
- Git in this worktree: one plain git command per call (no `-C`, `&&`, `;`, pipes). Never push; rapp-49 integrates.
- A letter: a keyDown, not a repeat, without ⌘ ⌃ ⌥ (Shift and Caps Lock allowed), whose characters under the current layout are exactly one Character that is a Unicode letter. By character, not key position.
- Applies only when: main-window picture has focus; the session is an app window (not a terminal); `composerAllowed` (no `noComposer` window rule); the app's `typeToCompose` is not `false`. Also when the panel is already open but the picture has focus. Detached windows never.
- Hold expiry: 500 ms (`0.5` s); hold cap 32 events. An expired hold is dropped, never replayed late.
- Channel names: method `picture_focus {sid, compose}` (compose optional, default false), method `compose_replay {sid}`, event `compose_key {sid}`.
- English on open: on the composer's closed→open transition, if `inputSource != null && !inputSource.ascii`, call `selectInput('')` once. `prepareInput()` before send stays.
- Profile field `typeToCompose`, default `true`, written to apps.json only when `false` (exactly like `recordInput`).
- Settings switch (below 「记下发给这个 app 的话」): key `type-to-compose-switch`, title 「在画面上按字母键时打开写作面板」, subtitle 「关掉后字母直接发给这个 app，适合 Figma、游戏、密码管理器」.
- Logs never contain typed text: the trigger key and held events are never logged (no characters, no key codes in log lines).
- Spec §5 spike: no automated test can drive the macOS IME, so the replay path is built as designed (Tasks 1–3, 5) and the pinyin check (`nihao` + space → 「你好」) is the user's real-machine step after Task 8.
- Mac fallback (only if the user's real-machine pinyin check fails): native emits the existing `composer_insert {sid, text: event.characters}` instead of holding and replaying. Not built now.

## Review Focus

1. Fast typing `nihao` before Dart answers → all five letters reach the panel in order, none goes to A (Task 1 test `hold queues later events in order`; Task 3 replay order is by queue).
2. The letter's keyUp arrives before the replay → it is queued and replayed after its keyDown, never sent to A and never delivered to Flutter unmatched (Task 1 test `compose keyUp is not sent to A`).
3. Dart never calls `compose_replay` (panel not allowed after all, session gone) → after 500 ms the hold is dropped and later keys route normally (Task 1 test `expired hold is dropped`).
4. A replayed event comes back through the key monitor while the picture is (wrongly) still focused → it goes local, it does not trigger compose again (Task 3 `replaying` guard; Task 1 test `take clears the hold`).
5. Profile edit to `typeToCompose: false` while the picture already has focus → the runner gets `picture_focus {compose: false}` at once, so the next V goes to A (Task 5 test `profile change re-sends compose`).

---

### Task 1: Swift: compose letter test and the hold

**Files:**
- Modify: `Sources/RappSession/KeyRouting.swift`
- Test: `Tests/RappSessionTests/KeyRoutingTests.swift`

**Interfaces:**
- Produces:
  - `public func isComposeKey(characters: String?, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool`
  - `public struct ComposeHold<Event>` with `init(expiry: TimeInterval = 0.5, cap: Int = 32)`, `mutating func start(sid: Int64, _ e: Event, now: TimeInterval)`, `mutating func add(_ e: Event, now: TimeInterval) -> Bool` (true: queued; false: no live hold, or it just expired or hit the cap and was dropped — the caller routes the event normally), `mutating func take(sid: Int64, now: TimeInterval) -> [Event]` (the queue in arrival order when the hold is for `sid` and not expired, else `[]`; always clears), `var holding: Bool { get }`.

- [ ] **Step 1: Write the failing tests** in `KeyRoutingTests.swift`:
  - `testComposeKeyLetters`: `isComposeKey("a", [], false)`, `("A", [.shift], false)`, `("a", [.capsLock], false)`, `("é", [], false)`, `("я", [], false)` are true.
  - `testComposeKeyRejects`: `("a", [.command], false)`, `("a", [.control], false)`, `("å", [.option], false)`, `("a", [], true)`, `("1", [], false)`, `(" ", [], false)`, `("\r", [], false)`, `("ab", [], false)`, `("", [], false)`, `(nil, [], false)`, `("\u{F700}", [], false)` (arrow) are false.
  - `testHoldQueuesLaterEventsInOrder`: `start(sid: 7, "n", now: 0)`; `add("i", now: 0.1)`, `add("h", 0.2)` true; `take(sid: 7, now: 0.3) == ["n","i","h"]`; `holding == false`.
  - `testComposeKeyUpIsNotSentToA`: a `KeyTracker` that never saw the press routes the release of that key code `.local` with `pictureFocused: true` (pins the existing rule the compose path relies on).
  - `testExpiredHoldIsDropped`: `start(sid: 7, "n", now: 0)`; `add("i", now: 0.6)` is false and `holding == false`; `take(sid: 7, now: 0.6) == []`.
  - `testTakeClearsTheHold`: `take(sid: 8, …)` on a hold for 7 returns `[]` and clears; a second `take(sid: 7, …)` returns `[]`.
  - `testHoldCap`: with `cap: 3`, start + 2 adds true, the 3rd add false and `holding == false`.

- [ ] **Step 2: Run** `swift test --filter KeyRoutingTests` — Expected: compile failure, `isComposeKey`/`ComposeHold` not found.

- [ ] **Step 3: Implement** both in `KeyRouting.swift`. `isComposeKey`: reject when `isRepeat` or flags intersect `[.command, .control, .option]`; else `characters` must be exactly one `Character` whose `isLetter` is true. `ComposeHold`: stores sid, start time, events; expiry is `now - started > expiry`.

- [ ] **Step 4: Run** `swift test --filter KeyRoutingTests` — Expected: all pass.

- [ ] **Step 5: Commit** `git add Sources/RappSession/KeyRouting.swift Tests/RappSessionTests/KeyRoutingTests.swift` then `git commit -m "feat(session): compose letter test and key hold for type-to-compose"`.

### Task 2: Swift channel: `compose` flag and `compose_replay`

**Files:**
- Modify: `Sources/RappSession/Channel.swift` (`ChannelCommand`, `channelCommand` known list and parse)
- Test: `Tests/RappSessionTests/ChannelTests.swift`

**Interfaces:**
- Produces: `case pictureFocus(sid: Int64?, compose: Bool)`, `case composeReplay(sid: Int64)`; method string `"compose_replay"`.

- [ ] **Step 1: Write the failing tests** in `ChannelTests.swift`: update the existing `.pictureFocus(sid: 3)` expectation to `.pictureFocus(sid: 3, compose: false)` (args without `compose`); add `{"sid": 3, "compose": true}` → `.pictureFocus(sid: 3, compose: true)`; `{"sid": NSNull()}` → `.pictureFocus(sid: nil, compose: false)`; `channelCommand("compose_replay", ["sid": 5]) == .composeReplay(sid: 5)`; `compose_replay` without `sid` throws `.bad`.

- [ ] **Step 2: Run** `swift test --filter ChannelTests` — Expected: compile failure on the new case shapes.

- [ ] **Step 3: Implement.** `compose` read as optional bool (absent or NSNull → false). Add `"compose_replay"` to `known`.

- [ ] **Step 4: Run** `swift test` — Expected: all RappSession tests pass (the plugin is not part of the package; it is fixed in Task 3).

- [ ] **Step 5: Commit** `git add Sources/RappSession/Channel.swift Tests/RappSessionTests/ChannelTests.swift` then `git commit -m "feat(session): picture_focus carries compose; compose_replay command"`.

### Task 3: Mac plugin: hold, `compose_key`, replay

**Files:**
- Modify: `gui/macos/Runner/SessionPlugin.swift` (`.pictureFocus` handling ~204, `route(_:)` ~334)

**Interfaces:**
- Consumes: Task 1 `isComposeKey`, `ComposeHold<NSEvent>`; Task 2 `.pictureFocus(sid:compose:)`, `.composeReplay(sid:)`.
- Produces: event to Dart `channel.invokeMethod("compose_key", arguments: ["sid": sid])`.

- [ ] **Step 1: Implement.** New fields `composeOn = false`, `hold = ComposeHold<NSEvent>()`, `replaying = false`. `.pictureFocus(sid, compose)`: as today, plus `composeOn = compose && sid != nil`. In `route(_:)`, first: `if replaying { return event }`. In the `.main` branch, before `keys.route`: if `hold.add(event, now:)` returns true → `return nil`; else if `down`, `event.type == .keyDown`, `composeOn`, `targetSid != nil` and `isComposeKey(characters: event.characters, flags: event.modifierFlags, isRepeat: event.isARepeat)` → `hold.start(sid:, event, now:)`, invoke `compose_key`, `return nil`. `now` is `ProcessInfo.processInfo.systemUptime`. `.composeReplay(sid)`: `let events = hold.take(sid:now:)`, then `replaying = true`, `NSApp.sendEvent` each in order, `replaying = false`, `result(nil)`. Detached and `.local` routes never touch the hold.

- [ ] **Step 2: Build** from `gui/`: `~/development/flutter/bin/flutter build macos --debug` — Expected: `✓ Built build/macos/Build/Products/Debug/rapp.app` (app name as the project names it), no Swift errors.

- [ ] **Step 3: Commit** `git add gui/macos/Runner/SessionPlugin.swift` then `git commit -m "feat(mac): hold a compose letter, emit compose_key, replay into rapp's window"`.

### Task 4: `typeToCompose` in the profile, settings page and config doc

**Files:**
- Modify: `gui/lib/embed/app_profile.dart` (`AppProfile` field/copy/toJson/fromJson; `ResolvedProfile`; `resolveProfile`), `gui/lib/pages/app_profile_page.dart` (draft merge ~270, no-change check ~104, switch row after ~353), `docs/superpowers/specs/2026-11-13-rapp-app-profiles-design.md` (row after `recordInput`, ~line 60)
- Test: `gui/test/embed/app_profile_test.dart`, `gui/test/ui/app_profile_page_test.dart`

**Interfaces:**
- Produces: `AppProfile.typeToCompose` (`bool?`), `ResolvedProfile.typeToCompose` (`bool`, default `true`).

- [ ] **Step 1: Write the failing tests**, each mirroring its `recordInput` sibling:
  - app_profile_test `typeToCompose round-trips and is written only when false`: `{"ids":["x"],"typeToCompose":false}` → `typeToCompose == false`, `toJson()['typeToCompose'] == false`; a profile without it → `toJson()` has no `typeToCompose` key; resolved default `true`; a later matching profile's `false` wins as `recordInput` does.
  - app_profile_page_test `type-to-compose switch writes apps.json`: switch `Key('type-to-compose-switch')` shows title 「在画面上按字母键时打开写作面板」 and subtitle 「关掉后字母直接发给这个 app，适合 Figma、游戏、密码管理器」; tapping it off and saving writes `"typeToCompose": false`; turning it back on removes the key.

- [ ] **Step 2: Run** from `gui/`: `~/development/flutter/bin/flutter test test/embed/app_profile_test.dart test/ui/app_profile_page_test.dart` — Expected: FAIL (`typeToCompose` undefined).

- [ ] **Step 3: Implement** following every `recordInput` site. Doc row: `| \`typeToCompose\` | \`false\`：在这个 app 的画面上按字母键不打开写作面板，字母直接发给远端（Figma、游戏、密码管理器）（《按字母键打开写作面板》§2） | \`true\` |`.

- [ ] **Step 4: Run** the Step 2 command — Expected: all pass. Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** `git add` the four files, then `git commit -m "feat(gui): per-app typeToCompose switch"`.

### Task 5: Dart port, events, panel replay, MainState compose flag

**Files:**
- Modify: `gui/lib/embed/session_port.dart` (`ComposeKeyEvent`, decode `'compose_key'`, `pictureFocus`, `composeReplay`), `gui/lib/embed/composer_model.dart` (`replayPending`, `takeReplay`), `gui/lib/embed/remote_session.dart` (`apply` case), `gui/lib/embed/composer_panel.dart` (`_takeCaret`), `gui/lib/ui/main_state.dart` (`focusPicture` ~404, reroute ~1276, focused-session listener)
- Test: `gui/test/embed/session_port_test.dart`, `gui/test/embed/remote_session_test.dart`, `gui/test/embed/composer_panel_test.dart`, `gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 4 `ResolvedProfile.typeToCompose`.
- Produces: `final class ComposeKeyEvent extends SessionEvent { ComposeKeyEvent(super.sid); }`; `void pictureFocus(Object? sid, {bool compose = false})` sending `{'sid': sid, 'compose': compose}`; `void composeReplay(Object sid)` sending `compose_replay {'sid': sid}`; `ComposerModel.replayPending` (bool) and `bool takeReplay()` (returns and clears it); `MainState` private `bool _composeFor(Object sid)` = session is a `RemoteSession` app window (not terminal) `&& rs.composerAllowed && rs.profile.typeToCompose`.

- [ ] **Step 1: Write the failing tests:**
  - session_port_test `compose_key decodes`: `parseSessionEvent('compose_key', {'sid': 3})` is a `ComposeKeyEvent` with sid 3.
  - remote_session_test `compose_key opens the panel and asks for a replay`: applying `ComposeKeyEvent` → `composer.open`, `focusTick` bumped, `takeReplay()` true then false.
  - composer_panel_test `compose_key: caret in the editor, picture blurred, then replay`: with the panel closed, emit `ComposeKeyEvent(sid)` on the fake port, pump twice → editor has focus; the fake port's `calls` contain `('picture_focus', {'sid': null, ...})` before `('compose_replay', {'sid': sid})`, exactly one `compose_replay`. Same with the panel already open and the picture focused.
  - composer_panel_test `no replay without compose_key`: opening by the 「输入」 button sends no `compose_replay`.
  - main_state_test `focusPicture sends compose`: an app session → last `picture_focus` has `compose: true`; `typeToCompose: false` profile → `compose: false`; a window matching a `noComposer` rule → `compose: false`.
  - main_state_test `profile change re-sends compose`: picture focused, then the profile store sets `typeToCompose: false` → a new `picture_focus {sid, compose: false}` is sent; no extra send when the value is unchanged.

- [ ] **Step 2: Run** from `gui/`: `~/development/flutter/bin/flutter test test/embed/session_port_test.dart test/embed/remote_session_test.dart test/embed/composer_panel_test.dart test/ui/main_state_test.dart` — Expected: FAIL (`ComposeKeyEvent` undefined).

- [ ] **Step 3: Implement.** `RemoteSession.apply(ComposeKeyEvent)`: `composer.replayPending = true; composer.open = true; composer.wantFocus();`. Panel `_takeCaret`: after `_ed.focus(); blurPicture();`, if `session.composer.takeReplay()` → `addPostFrameCallback` calling `port.composeReplay(sid)`. MainState sends `compose: _composeFor(sid)` wherever it sends `pictureFocus(sid)` for an app session, and on any change of the focused session's `_composeFor` (listen to that `RemoteSession`; compare with the last value sent). Terminal sessions keep going to the term port untouched.

- [ ] **Step 4: Run** the Step 2 command — Expected: all pass. `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** `git add` the nine files, then `git commit -m "feat(gui): compose_key opens the panel and replays the letter; picture_focus carries compose"`.

### Task 6: English on open

**Files:**
- Modify: `gui/lib/embed/remote_session.dart` (constructor: composer listener; dispose)
- Test: `gui/test/embed/remote_session_test.dart`

**Interfaces:**
- Consumes: existing `RemoteSession.inputSource`, `selectInput(String)`, `ComposerModel.open`.

- [ ] **Step 1: Write the failing tests** `opening the panel switches A to English`: `inputSource = (id: 'pinyin', name: '拼音', ascii: false)`; `composer.open = true` → exactly one `select_input {id: ''}` (or whatever arg name `selectInput` sends today) on the fake port; setting `open = true` again sends nothing more; close and reopen sends one more. `already English, no call`: `ascii: true` → none. `no source reported, no call`: `inputSource == null` → none.

- [ ] **Step 2: Run** `~/development/flutter/bin/flutter test test/embed/remote_session_test.dart` — Expected: FAIL (no `select_input` call).

- [ ] **Step 3: Implement** a listener on `composer` remembering the last `open`; on false→true with a non-ascii `inputSource`, call `selectInput('')`. Remove the listener in `dispose`.

- [ ] **Step 4: Run** the Step 2 command, then the full suite `~/development/flutter/bin/flutter test` — Expected: all pass (prior baseline 1386 passed, 8 skipped, plus the new ones). `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** `git add gui/lib/embed/remote_session.dart gui/test/embed/remote_session_test.dart` then `git commit -m "feat(gui): opening the writing panel switches A's input method to English"`.

### Task 7: Linux: letter into the draft

**Files:**
- Modify: `gui/lib/embed/linux_session_port.dart` (`invoke` `picture_focus` ~217, `handleKeyEvent` ~109)
- Test: `gui/test/embed/linux_session_port_test.dart`

**Interfaces:**
- Consumes: Task 5's `picture_focus {sid, compose}` args; existing `ComposerInsertEvent(sid, PasteResult(text: ch))`, which `RemoteSession.apply` already turns into open + wantFocus + insert.

- [ ] **Step 1: Write the failing tests:**
  - `a letter opens the draft with it`: seeded focused session, `invoke('picture_focus', {'sid': sid, 'compose': true})`, `handleKeyEvent(sid, KeyDownEvent(character: 'a', logicalKey: keyA, physicalKey: keyA, …))` returns true, emits one `ComposerInsertEvent` with text `a`, writes nothing to the worker process; the matching `KeyUpEvent` is not sent to the worker either.
  - `digits, Ctrl+letter and compose off still go to A`: `1`; `a` with Ctrl held; `a` after `picture_focus {compose: false}` (or without `compose`) → sent to the worker as today, no event.

- [ ] **Step 2: Run** `~/development/flutter/bin/flutter test test/embed/linux_session_port_test.dart` — Expected: FAIL.

- [ ] **Step 3: Implement.** Store `_compose = args['compose'] == true` with `_focused`. In `handleKeyEvent`, after the existing early returns and before key-code mapping: a `KeyDownEvent` (not `KeyRepeatEvent`), `_compose`, no Ctrl/Alt/Meta held, `event.character` matching `RegExp(r'^\p{L}$', unicode: true)` → remember the physical key as swallowed, `_emit(ComposerInsertEvent(sid, PasteResult(text: ch)))`, return true. A `KeyUpEvent` for a swallowed key is consumed (return true, nothing sent) and forgotten.

- [ ] **Step 4: Run** the Step 2 command, then `~/development/flutter/bin/flutter analyze` and the full `~/development/flutter/bin/flutter test` — Expected: no issues; all pass. `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** `git add gui/lib/embed/linux_session_port.dart gui/test/embed/linux_session_port_test.dart` then `git commit -m "feat(linux): a letter on the picture opens the draft with it"`.

### Task 8: Spec status and real-machine checklist

**Files:**
- Modify: `docs/superpowers/specs/2026-11-15-rapp-type-to-compose-design.md` (status line)

- [ ] **Step 1:** Status line → 「状态：用户已确认（2026-11-15），已实现（feat/type-to-compose）；待真机确认 §5 拼音检查和 Figma 关开关后 V/R。」
- [ ] **Step 2: Run** `swift test` and, from `gui/`, `~/development/flutter/bin/flutter analyze` — Expected: all pass, no issues.
- [ ] **Step 3: Commit** `git add` the spec, then `git commit -m "docs: type-to-compose implemented; real-machine checks pending"`.
