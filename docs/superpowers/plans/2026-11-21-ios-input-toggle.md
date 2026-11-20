# iOS 输入键开合 + 按键区 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On iOS the 输入 key opens and closes the writing panel. The panel, the keyboard and the stage buttons move as one, and a pull-down closes the panel. A new key area for agent CLIs (Esc ⇧Tab Tab ⌃C, arrows, ⏎ …) replaces the six-key row, the app key row and the ＋ menu key grid.

**Architecture:** There are two new files. `key_bar_keys.dart` holds the key model and the layout as pure data. `key_bar.dart` holds the widget plus two senders: a terminal sender that sends wire names, and an app sender that sends macOS codes, with its latch sync lifted out of `AppKeyRow`. The iOS branch of `composerLayer` is rebuilt around a single "dock" value, which is how far up the panel's bottom sits (keyboard + bar). The bar, the panel, the stack and the picture lift are all computed from that value, so they move together. The panel stays mounted while it closes, so it can ride the keyboard down.

**Tech Stack:** Flutter (Dart), the app in `gui/`. Run tests with `~/development/flutter/bin/flutter test` from `gui/`, then `git checkout pubspec.lock`.

**Spec:** `docs/superpowers/specs/2026-11-21-rapp-ios-input-toggle-design.md`. Images are in `docs/superpowers/specs/2026-11-21-rapp-ios-input-toggle/` (`2-new.png`, `3-keys.png`, `4-keys-layout.png`).

## Global Constraints

- iOS only. macOS and Linux behaviour is unchanged: `TermKeyRow`, the ＋ grid, `FloatingComposer`'s ×, and `composerLayer`'s non-iOS branch all stay as they are.
- Work on branch `feat/ios-input-toggle` (this worktree). Never commit to main and don't push. When done, send the branch name to rapp-49.
- Copy is Chinese, as in the spec: 输入 / 收起; 复制 / 粘贴; Semantics labels Esc, Shift Tab, Control C, 左, 上, 下, 右, 回车, 删除.
- Durations:
  - Self-driven moves (no soft keyboard): 340 ms, `Curves.easeOutCubic`.
  - Icon swap: 200 ms.
  - Final fade-out of a closing panel: 100 ms.
  - Everything is instant under `MediaQuery.disableAnimationsOf`.
- Pull-down closes past 70 pt, or on a downward fling faster than 700 pt/s (my call).
- Key repeat on ← ↑ ↓ → ⌫ starts after 400 ms, then fires every 80 ms.
- Keys never take focus (`canRequestFocus: false`). Two Esc taps send two Esc, with no debounce.
- Each key press plays `HapticFeedback.selectionClick()`.
- Keys are grey and send nothing while `state.sendBlocked(sid)`.
- Don't read or search `docs/archives/` (CLAUDE.md).

## Review Focus

1. **⌃ lit with a Chinese soft keyboard.** The letter reaches the Flutter editor as composing (marked) text, not as an insert. Expected: the remote still gets ⌃letter, and neither the draft nor the composition keeps the letter. Test in Task 3.
2. **A session switch while ⌃/⌥/⌘ is latched, or while a repeat is held.** Expected: every modifier sent down to A gets its up for the old session, and the repeat timer stops. Test in Task 2.
3. **Closing while the soft keyboard is already down** (a hardware keyboard, or the system's hide-keyboard key). There is no keyboard to ride, so the panel slides down on its own 340 ms curve and is then unmounted. Expected: no frame where the stack jumps to 88 before the panel is gone. Test in Task 5.
4. **Reopening mid-close.** Tapping 收起 and then 输入 again within 340 ms. Expected: the same panel element stays, the draft is intact, and there is no second panel. Test in Task 5.
5. **A pull-down that starts in the editor.** Expected: no collapse, and text selection still works. Only the grip row and the panel's blank border start a pull. Test in Task 6.

---

### Task 1: Key model and layout

**Files:**
- Create: `gui/lib/embed/key_bar_keys.dart`
- Test: `gui/test/embed/key_bar_keys_test.dart`

**Interfaces:**
- Produces:
  - `enum BarKind { send, mod, copy, paste, more, slim }`
  - `typedef BarKey = ({String id, String label, String spoken, BarKind kind, String? wire, int? code, int mods, int? bit, String? alt, bool repeats})`
    - `wire` is the terminal wire name.
    - `code` and `mods` are the macOS key code and modifier bits for app sessions.
    - `bit` is the latch bit of a mod key (`latchCtrl` / `latchOpt` / `latchCmd`).
    - `alt` is the `id` of the swipe-up key.
  - `const barKeys = <String, BarKey>{…}`, keyed by `id`.
  - `const keyBarKeyHeight = 42.0`, `keyBarGap = 4.0`, `keyBarGroupGap = 12.0`, `keyBarPad = 6.0`, `keyBarOneRowAt = 860.0`.
  - `double keyBarHeight(int rows)`, equal to `rows*42 + (rows-1)*4 + 2*6`: 54 for one row, 100 for two.
  - `List<List<String?>> keyBarRows({required double width, required bool app, required bool more, required bool slim, required bool hardware})`. Each item is a list of key ids; `null` marks a group gap.
  - `const macLetterCodes = <String, int>{'a':0,'s':1,'d':2,'f':3,'h':4,'g':5,'z':6,'x':7,'c':8,'v':9,'b':11,'q':12,'w':13,'e':14,'r':15,'y':16,'t':17,'o':31,'u':32,'i':34,'p':35,'l':37,'j':38,'k':40,'n':45,'m':46}`

Key table: id → wire / macOS code+mods. Ctrl is `latchCtrl`, shift is `latchShift`.

| id | wire | macOS code + mods |
|---|---|---|
| esc | Esc | 53 |
| stab | Shift-Tab | 48 + shift |
| tab | Tab | 48 |
| cc | Ctrl-C | 8 + ctrl |
| cd | Ctrl-D | 2 + ctrl |
| cr | Ctrl-R | 15 + ctrl |
| co | Ctrl-O | 31 + ctrl |
| ct | Ctrl-T | 17 + ctrl |
| cb | Ctrl-B | 11 + ctrl |
| left | Left | 123, alt home |
| up | Up | 126, alt pgup |
| down | Down | 125, alt pgdn |
| right | Right | 124, alt end |
| enter | Enter | 36 |
| home | Home | 115 |
| end | End | 119 |
| pgup | PageUp | 116 |
| pgdn | PageDown | 121 |
| bksp | Backspace | 51 |

- The arrow keys and `bksp` repeat.
- The mod keys are `ctrl` ⌃, `opt` ⌥ and `cmd` ⌘ (app sessions only).
- The other keys are `copy` 复制, `paste` 粘贴, `more` ⋯ and `slim` ⊙.

- [ ] **Step 1: Write the failing tests**

```dart
test('narrow: one row of ten, ⋯ last; more adds the second row', () {
  expect(keyBarRows(width: 390, app: false, more: false, slim: false, hardware: false),
      [['esc','stab','tab','cc','left','up','down','right','enter','more']]);
  expect(keyBarRows(width: 390, app: false, more: true, slim: false, hardware: false)[1],
      ['ctrl','opt','cr','co','ct','cb','cd','bksp','copy','paste']);
});
test('narrow app: ⌘ after ⌥, ⌃D gives way', () {
  expect(keyBarRows(width: 390, app: true, more: true, slim: false, hardware: false)[1],
      ['ctrl','opt','cmd','cr','co','ct','cb','bksp','copy','paste']);
});
test('wide: one grouped row, Esc first, arrows and ⏎ last, no ⋯', () {
  expect(keyBarRows(width: 1180, app: false, more: false, slim: false, hardware: false), [[
    'esc','stab','tab',null,'ctrl','opt',null,'cc','cd','cr','co','ct','cb',null,
    'home','end','pgup','pgdn',null,'bksp','copy','paste',null,'left','up','down','right','enter']]);
});
test('hardware keyboard: ⊙ ends the first row', () {
  expect(keyBarRows(width: 390, app: false, more: false, slim: false, hardware: true)[0].last, 'slim');
  expect(keyBarRows(width: 1180, app: false, more: false, slim: false, hardware: true)[0].last, 'slim');
});
test('slim: Esc ⇧Tab and the slim key only, at any width', () {
  for (final w in [390.0, 1180.0]) {
    expect(keyBarRows(width: w, app: false, more: true, slim: true, hardware: true), [['esc','stab','slim']]);
  }
});
test('heights', () { expect(keyBarHeight(1), 54); expect(keyBarHeight(2), 100); });
test('every id in a row is in barKeys; ⌃C is Ctrl-C and 8+ctrl', () { … });
```

`slim` (⊙) ends the first row only when `hardware || slim`; the widget passes `hardware: hardwareKeyboard()`.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/key_bar_keys_test.dart`. Expected: compile error (the file doesn't exist yet).

- [ ] **Step 3: Implement `key_bar_keys.dart`** using the table above. "Wide" means `width >= keyBarOneRowAt`.

- [ ] **Step 4: Run the test and confirm it passes.** Then run `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with `feat(ios): 按键区的键和排布`.

---

### Task 2: KeyBar widget and its two senders

**Files:**
- Create: `gui/lib/embed/key_bar.dart`
- Modify: `gui/lib/embed/app_key_row.dart`. Lift `_bind/_unbind/_sync/_onEvent/_press` into a public `AppKeySender` class. `AppKeyRow` is deleted in Task 7, so move rather than copy.
- Modify: `gui/lib/embed/remote_session.dart`. Add `final keyLatch = ModifierLatch();` next to `termCtrl` (line 52) and dispose it at line 510.
- Modify: `gui/lib/term/term_stage.dart:785`. The sticky check also reads `session.keyLatch`. A letter goes as `Ctrl-X` / `Alt-x` (or both) when the latch has ctrl / opt. Afterwards call `keyLatch.used()`.
- Modify: `gui/lib/ui/prefs.dart`. Add `keyBarMore` (bool, default false, json `key_bar_more`) and `keyBarSlim` (bool, default false, json `key_bar_slim`). Add the setters `setKeyBarMore` / `setKeyBarSlim` in `main_state.dart`, next to `termKeyRow`'s setter at line 3190.
- Test: `gui/test/embed/key_bar_test.dart`. Move the latch-sync cases from `test/embed/app_key_row_test.dart` into it.

**Interfaces:**
- Consumes: from Task 1, `barKeys`, `keyBarRows`, `keyBarHeight` and the constants; `ModifierLatch` and `latchCtrl/Opt/Cmd/Shift`; `TermSessionPort.sendKeys / paste`; `SessionPort.key / keyEvent / latch / composerSend`.
- Produces:
  - `class KeyBar extends StatefulWidget { KeyBar({required MainState state, required RemoteSession session, required SessionPort port, VoidCallback? onCopy}) }`
    - It lays out at the incoming width.
    - Its height is always `keyBarHeightOf(state, session, width)`.
    - `onCopy` is the terminal stage's selection copy. Null means app (send ⌘C).
  - `double keyBarHeightOf(MainState state, RemoteSession session, double width)`. Later tasks use it for the dock and the lift.
  - `ModifierLatch keyLatchOf(MainState state, RemoteSession session)`. For a terminal it returns `session.keyLatch`; for an app, `state.appLatch`.
  - `bool sendLatchedLetter(MainState state, RemoteSession session, SessionPort port, String letter)`. It returns false when no ctrl/opt/cmd is on. Otherwise it sends the letter with the latch (wire `Ctrl-R`, or macOS `macLetterCodes[r]` plus the flags), calls `used()` and returns true. Task 3 uses it.

Behaviour, from spec K3:
- A `send` key goes to a terminal as `[Ctrl-][Alt-]wire`, with the prefixes from the latch. A key whose wire already has `Ctrl-` doesn't get it twice. For an app, the key goes as `port.key(sid, code, mods | latch.flags)`. Either way `used()` follows.
- A `mod` key calls `latch.tap(bit)`. Paint the three states: off, once (accent outline), locked (accent fill).
- 复制: `onCopy?.call()`, or for an app `port.key(sid, 8, latchCmd)`.
- 粘贴: read `Clipboard.getData('text/plain')`; nothing happens when it's empty. A terminal sends it with `paste(sid, text)`; an app with `composerSend(sid, [{'kind':'text','text':text}])`. Check the piece shape against `composer_panel`'s send. Paste never touches `session.composer`.
- `more` → `state.setKeyBarMore(!more)`. `slim` → `state.setKeyBarSlim(!slim)`.
- A swipe up of 24 pt or more on a key with `alt` sends the alt instead (my call). The key's top-right corner shows the alt label in 9 pt muted text.
- Repeat runs on a `Timer`. Cancel it on pointer up, cancel, dispose, or a session change.

- [ ] **Step 1: Write the failing tests** (use `iosTest`, and the fake ports already in `test/embed/` and `test/term/`):
  - `term: tap Esc twice sends [Esc] twice`
  - `term: ⇧Tab sends Shift-Tab; ⌃C sends Ctrl-C`
  - `term: ⌃ once then ← sends Ctrl-Left and ⌃ goes off; double-tap ⌃ locks, two ← both Ctrl-Left`
  - `term: ⌥ then Enter sends Alt-Enter`
  - `app: ⇧Tab sends key(48, latchShift); ⌃ then ↑ sends key(126, latchCtrl) after keyEvent(59, down)`
  - `app: session switch with ⌘ locked sends keyEvent(55, up) for the old sid` (Review Focus 2)
  - `hold ← 400 ms then 160 ms: three Left` (`tester.pump` with fake time). `switching session mid-hold stops the repeat` (Review Focus 2).
  - `swipe up on ↑ sends PageUp, not Up`
  - `粘贴 sends the clipboard and leaves composer draft unchanged`
  - `blocked: keys grey, taps send nothing`
  - `keys never take focus: a focused editor stays focused after a tap`
  - `⋯ shows the second row and writes prefs.keyBarMore`. `⊙ only with hardwareKeyboard; tapping it leaves esc, stab, slim`
  - `sendLatchedLetter: false with nothing latched; with ⌃ once sends Ctrl-R, latch off after`
  - `term_stage: hardware r with keyLatch ctrl sends Ctrl-R` (`test/term/`)

- [ ] **Step 2: Run the tests and confirm they fail.**

- [ ] **Step 3: Implement** `AppKeySender`, `KeyBar`, `keyBarHeightOf`, `keyLatchOf`, `sendLatchedLetter`, the prefs, and the `term_stage` change. Build the keys the way `TermKeyRow._Key` does: a `Material` + `InkWell(canRequestFocus: false)`, plus a `Semantics` label from `spoken`. Height is `keyBarKeyHeight`. Keys inside a group share the width equally (`Expanded`), with group gaps of `keyBarGroupGap`. The bar's background is `t.floatBox()`, full width.

- [ ] **Step 4: Run** `flutter test test/embed/key_bar_test.dart test/embed/app_key_row_test.dart test/term/` and confirm everything passes. Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with `feat(ios): 按键区组件（终端线上键名 / App 键码，粘滞、连发、上滑）`.

---

### Task 3: A latched ⌃ catches the editor's next letter

**Files:**
- Modify: `gui/lib/embed/composer_editor.dart`. Add a field to `EditorHandlers`: `final bool Function(String letter)? onLetter;` with the doc comment "A single ASCII letter about to go in by typing (soft keyboard, including a composing one; hardware key before Rime). true: it is dropped."
- Modify: `gui/lib/embed/flutter_editor.dart`.
  - Call `onLetter` from a `TextInputFormatter`. It applies when the new value is the old one with exactly one `[a-zA-Z]` added at the caret: either inserted, or as a fresh one-letter composing range. On true, return the old value.
  - Also call it from the hardware-key path, before the key reaches Rime.
- Modify: `gui/lib/embed/composer_panel.dart` (the `EditorHandlers(…)` at line 123): `onLetter: (l) => Platform.isIOS && sendLatchedLetter(widget.state, _s, widget.port, l)`.
- Test: `gui/test/embed/flutter_editor_test.dart` and `gui/test/embed/composer_panel_test.dart`.

**Interfaces:**
- Consumes: `sendLatchedLetter` from Task 2.
- Produces: `EditorHandlers.onLetter`. `NativeEditor` (macOS) ignores it.

- [ ] **Step 1: Write the failing tests:**
  - `typed r with onLetter true: text unchanged, onLetter got 'r'`
  - `composing r (Chinese keyboard) with onLetter true: no composing range left, text unchanged` (Review Focus 1)
  - `pasted "ab" never calls onLetter`. `typed "1" never calls onLetter`
  - In the panel, iOS: `⌃ once + typed r → port Ctrl-R, draft empty; next typed r goes into the draft`

- [ ] **Step 2: Run them and confirm they fail.** **Step 3: Implement.** **Step 4: Run them and confirm they pass.** Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with `feat(ios): ⌃ 亮着时编辑框打的字母直接以 ⌃字母 发给远端`.

---

### Task 4: 输入 becomes a toggle, and the stack stands above the panel (G1, G2)

**Files:**
- Modify: `gui/lib/embed/composer_panel.dart`:
  - The iOS `buttons:` builder, lines 637–712.
  - `_VoiceAbovePanel` (lines 873–912). Rename it to `_StackAbovePanel`, which holds 语音 and 收起.
  - `_ios` in the tidy-card placement (lines 838–856).
- Test: `gui/test/embed/stage_buttons_test.dart` and `gui/test/embed/voice_button_test.dart`.

**Interfaces:**
- Produces: `Key('composer-open')` stays the one key in both states.
  - Closed: label 输入, icon `Icons.keyboard_outlined`.
  - Open: label 收起, icon `Icons.keyboard_hide_outlined`, accent border.
  - `onPressed` toggles: `open = true` / `session.composer.collapse()`.
  - Size is `stageButtonSize` (56) in both states.

Layout while open:
- The stack (`StageButtons`, with `voice` and `input` only, not `restore` or `beside`) stands with its bottom 8 above `panelPlaceOf(session).value.top`. It stays on the `stageSide` side, `stageButtonsIn` in from that edge, and never above the stage top minus 8.
- Order: portrait is one row with 语音 outermost. Landscape and iPad use the `StageButtons` vertical column, with 收起 above 语音 (spec §4).
- While recording, `hidden` fades 收起 out, as it does today.
- The icon swap is an `AnimatedSwitcher` (200 ms, rotation + fade).

- [ ] **Step 1: Update and add tests:**
  - voice_button_test's panel-open case: `open` is now `findsOneWidget`, labelled 收起, bottom 8 above the panel top, next to the hold.
  - `tap 收起: composer closes, draft kept, the key reads 输入 again`
  - `open key is 56 square in both states`
  - `landscape: 收起 above 语音, both above the panel`
  - `recording hides 收起`

- [ ] **Step 2: Run them and confirm they fail.** **Step 3: Implement.** Also fix the tidy card's `_ios` so it sits above the two-key stack.

- [ ] **Step 4: Run** `flutter test test/embed/` and confirm it passes. Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with `feat(ios): 「输入」变开关，打开后语音和收起站在面板上方`.

---

### Task 5: Move as one, and the bar's place (G3, G5, K1)

**Files:**
- Modify: `gui/lib/embed/composer_panel.dart`. The iOS part of `composerLayer`: the panel block (lines 527–590), the terminal key-row block (592–607), and the closed stack bottom (lines 662–664).
- Modify: `gui/lib/ui/stage.dart`:
  - `_lifted` / `_lift` (lines 340–364): on iOS the lift becomes `(open ? pictureLift*scale : 0) + bar`, where `bar` is the bar height when it shows.
  - Wrap the app picture in the same lift when its closed bar shows.
  - Drop the `showAppKeyRow` block on iOS (lines 259–273).
- Create: `gui/lib/embed/ios_dock.dart`.
- Test: `gui/test/embed/ios_dock_test.dart` and `gui/test/ui/stage_test.dart` (update the lift case around line 321).

**Interfaces:**
- Consumes: from Task 2, `KeyBar` and `keyBarHeightOf`; from Task 4, `_StackAbovePanel`.
- Produces:
  - `bool keyBarWhenClosed(RemoteSession s, SessionPort port)`: `port is TermSessionPort || terminalApps.contains(s.appId)`. Use `terminalApps` from `lib/ui/terms_entry.dart`.
  - `class IosDock extends StatefulWidget`. It owns one `AnimationController` for "shown" (0 → 1).
    - It keeps the panel mounted until a close has finished.
    - It exposes `double panelBottom`, the panel's bottom offset off the stage's bottom: `keyboard + bar`, or `bar` when there's no soft keyboard. While closing with no soft keyboard, it is lowered by `(1 - shown) * (panelHeight + 8)` over 340 ms.
    - The closing panel fades out over its last 100 ms, then unmounts.
    - A reopen during the close reverses the same controller and keeps the same element (Review Focus 4).

Placement, bottom to top:
- Open:
  - The keyboard.
  - Then the `KeyBar` (all sessions, full width, flush with the keyboard; or at the stage bottom with no soft keyboard).
  - Then the panel, 8 above the bar. A terminal panel is centred; an app panel goes through `FloatingComposer` with `keyboard: keyboard + bar`.
  - Then the stack (Task 4).
- Closed:
  - A `KeyBar` at the stage bottom only when `keyBarWhenClosed`.
  - The stack bottom is `max(stageButtonsUp, bar + 8)`, and with the soft keyboard up it is `keyboard + bar + stageButtonsEdge`.
  - Remove the `TermKeyRow` blocks and `rowRight` math from the iOS path.

The stack's position is one continuous value. It eases between "above the panel" and "closed" by the controller, and both ends follow `keyboard` live, so nothing snaps. That holds whether the keyboard moves or not, in line with spec §4 (an interpolation, not two layouts).

- [ ] **Step 1: Write the failing tests** (`ios_dock_test.dart`, with keyboard via `tester.view.viewInsets`):
  - `open with keyboard 300: bar bottom 300, panel bottom 300+bar+8, stack 8 above panel`
  - `open, no keyboard: bar at 0, panel 8 above it` (G5)
  - `close, keyboard falling 300→0 over frames: panel still mounted and its bottom follows keyboard+bar each frame; unmounted after the fade`
  - `close with no keyboard: panel slides down 340ms, stack bottom never below its closed value and never jumps by more than one frame's step` (Review Focus 3)
  - `close then open within 200ms: one ComposerPanel, same State, draft intact` (Review Focus 4)
  - `closed terminal session: KeyBar shown, stack at max(88, 54+8)`. `closed Safari session: no KeyBar, stack at 88`. `closed com.apple.Terminal session: KeyBar shown`.
  - `stage lift: terminal closed with bar 54 → 54; open at scale 1 → 64+54`
  - `disableAnimations: open/close lands in one frame`

- [ ] **Step 2: Run them and confirm they fail.** **Step 3: Implement.**

- [ ] **Step 4: Run** `flutter test test/embed test/ui test/term` and confirm it passes. Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with `feat(ios): 键盘、按键区、面板、按键组一起走；按键区贴键盘`.

---

### Task 6: Pull down to collapse, and no × on iOS (G4, G6)

**Files:**
- Modify: `gui/lib/embed/composer_float.dart`:
  - `_move`, `_end` and `_cancel` (lines 140–160). Add the overshoot.
  - The × (lines 209–250): drop it on iOS, and keep the grip row's blanks so the grip stays centred.
- Modify: `gui/lib/embed/ios_dock.dart`. The terminal panel gets the same pull on its grip row and blank border, through a small `_Pull` recognizer that reuses `_PanelPan`'s arena rules.
- Test: `gui/test/embed/composer_float_test.dart` and `gui/test/embed/ios_dock_test.dart`.

**Interfaces:**
- Produces: `FloatingComposer({…, VoidCallback? onPullClose})` (iOS passes `session.composer.collapse`).
  - The overshoot is the part of a downward move that the bottom clamp in `_topLeftOf` swallows. It is how far the wanted bottom goes past `stage.height - composerMargin - keyboard`.
  - While the overshoot is above 0, the panel and the stack are translated down by it, 1:1.
  - On release, `overshoot > 70` or a fling `velocity.dy > 700` calls `onPullClose`. Otherwise it springs back (200 ms, easeOut), and the overshoot never becomes a saved place.

- [ ] **Step 1: Write the failing tests:**
  - `panel high up: dragging down 100 moves it, no collapse`
  - `panel at lowest: drag down 80, release → collapsed; down 40 → springs back, open, place unchanged`
  - `at lowest: fast fling down 30 → collapsed`
  - `drag that started high, reaches the bottom and goes 80 further → collapsed`
  - `pull starting in the editor text: no collapse, selection still works` (Review Focus 5)
  - `terminal panel: pull on grip row 80 → collapsed`
  - `iOS: no composer-grip-close`. `macOS: composer-grip-close still there`

- [ ] **Step 2: Run them and confirm they fail.** **Step 3: Implement.** **Step 4: Run them and confirm they pass.** Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with `feat(ios): 贴底后往下拉收起面板；去掉拖动条旁的 ×`.

---

### Task 7: Remove the old key surfaces on iOS, and full verification (K4)

**Files:**
- Delete: `gui/lib/embed/app_key_row.dart`'s `AppKeyRow` widget (`AppKeySender` stays), `showAppKeyRow` and `_appKeyRow` in `stage.dart`, and `prefs.appKeyRow` with its json, which is now unused. Remove `test/embed/app_key_row_test.dart` once its cases live in `key_bar_test.dart`.
- Modify: `gui/lib/embed/composer_plus.dart:286` (`_menu`). On iOS, leave out the 「按键 · 直接发给远端」 heading and grid. Every other row stays.
- Modify: `gui/lib/ui/top_bar.dart:277`. Hide the 按键排 toggle on iOS. `stage.dart:236` passes `keyRow: false` on iOS.
- Test: `test/embed/composer_panel_test.dart` and `test/term/term_main_test.dart`. Update the cases that look for `keyrow-*` on iOS, and keep them for macOS.

- [ ] **Step 1: Write and update the tests:**
  - `iOS ＋ menu: no 按键 grid, 附件/在远端复制/输入历史/直接回车/缩放/收起 present`
  - `macOS ＋ menu unchanged`
  - `iOS terminal with prefs.termKeyRow true: no keyrow-*, KeyBar instead`

- [ ] **Step 2: Implement and run the full suite:** `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`. Expected: no issues and all tests pass. Then `git checkout pubspec.lock`.

- [ ] **Step 3: Build for iOS.** This branch touches the iOS UI. Run `cd gui && ~/development/flutter/bin/flutter build ios --no-codesign --debug`. Expected: the build succeeds.

- [ ] **Step 4: Commit** with `refactor(ios): 按键区取代六颗大键、App 按键排和 ＋ 菜单按键格`. Then send `feat/ios-input-toggle` to rapp-49, with the spec's real-machine checks §7, 1–13, as the open items.
