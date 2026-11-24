# Input Dock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The 快捷区 (常用语条 + 按键区) and the 文本区 (writing panel) become one floating block on every platform. The remote picture never moves again. Each part folds on its own, and the 快捷区 settings move into the ＋ menu.

**Architecture:**
- `IosDock` becomes `InputDock` (`lib/embed/input_dock.dart`), used on iOS, macOS and Linux.
- It puts one `FloatingComposer` per session over the stage. The floating composer holds a column: the text area on top, an 8 gap, and the quick area (`KeyBar` at panel width) at the bottom.
- Two controllers size the parts with `Align(heightFactor:)`. The block's bottom centre (the anchor) never moves when a part opens or folds.
- A hidden quick area leaves a 28 ⊙ handle, laid out by `FloatingComposer` beside the block's bottom.
- `stage.dart` loses `_lifted`. `composerLayer` has one path for both platforms. The desktop row stays in the corner, and the iOS stack follows the block.

**Tech Stack:** Flutter/Dart (`gui/`). No Rust, no protocol change.

**Spec:** `docs/superpowers/specs/2026-11-24-rapp-input-dock-design.md`

## Global Constraints

- The picture never translates, scales or resizes: no `Transform` on the stage child, and `pictureLift` / `_lifted` are gone.
- Anchor = the block's bottom centre (`InputPoint`).
  - Apps (terminal apps included) keep `profile.composerAt`, with no migration.
  - All text terminals share the pref `term_composer_at`.
  - iOS default: `defaultComposerAt` (0.5, 8 from bottom).
  - Desktop default: (0.5, `controlHeightOf(context)` + 12 + 8 from bottom).
- Block order, bottom to top:
  - KeyBar rows;
  - 常用语条 (inside KeyBar, as today);
  - 8 gap (only while both parts show; it scales with how far both are shown);
  - text area;
  - grip (none when only the handle is left).
- Quick-area state is per kind:
  - `termKind` (text terminal or `terminalApps`) → `quick_hidden_term`, default false;
  - any other app → `quick_hidden_app`, default true.
  - Only ⊙, the handle and auto-hide change it. Voice and opening or folding the text area never do.
- Old `key_bar_slim: true` reads as `quick_hidden_term = true`. `key_bar_slim` is never written again.
- `quick_auto_hide`: missing means on for macOS/Linux and off for iOS.
  - It counts only non-modifier key downs typed into the picture: the picture focused and the editor not, or the macOS `KeyTypedEvent`.
  - The ⌘ / Linux Ctrl / lit-latch exceptions stay.
- Motion: 340 ms `easeOutCubic` (`dockMove`); the closing text area fades over its last 100 ms. Under `MediaQuery.disableAnimationsOf` everything jumps.
- Key rows are always the narrow ones, even at zoom 1.75 (where 720×1.75 = 1260 is over the old 860 threshold).
  - Row 1: `esc stab tab cc left up down right enter more hide`.
  - ⋯ adds row 2. The wide row and slim mode are deleted.
- Copy, verbatim:
  - ⊙ key spoken 「收起快捷区」;
  - handle semantics 「显示快捷区」;
  - ＋ group header 「快捷区」 with rows 「打字后自动收起」, 「显示常用语条」, 「更多按键」, 「编辑常用语…」;
  - stage toggle 「输入」 / 「收起」.
- Every way of folding (toggle, Esc, ＋ 收起, 直接回车且隐藏, iOS pull) folds the text area only. There is no grip × on any platform.
- Tests: `cd gui && $HOME/development/flutter/bin/flutter test <files>`. Redirect long output to a file in the scratchpad and read the tail. After any flutter run, `git checkout gui/pubspec.lock`. Before each commit, `flutter analyze` must report no issues.

## Review Focus

1. **Swipe up on ↑/←/→/↓ in the quick area:** it sends PgUp/Home/End/PgDn and must not drag the block. `_BarKeyView` uses a raw `Listener`, so `PanelPan` would otherwise win. Covered in Task 4.
2. **Typing into the open editor with auto-hide on:** the quick area stays and the editor does not drop. Covered in Task 3.
3. **Block dragged to the stage's right edge with the quick area hidden:** the handle flips to the left side and stays fully on stage. Covered in Task 4.
4. **Switching from a terminal (quick shown) to Safari (quick hidden):** Safari shows only the handle, and the old session's `KeyBar` handler is gone, so a key no longer folds the terminal's quick area. Covered in Task 5.
5. **iOS soft keyboard up with only the handle left:** the handle stands 8 above the keyboard, and the stack sits at `restStackBottom(keyboard)`. Covered in Task 5.

---

### Task 1: Prefs and state for the quick area and the terminal place

**Files:**
- Modify: `gui/lib/ui/prefs.dart`
- Modify: `gui/lib/ui/main_state.dart` (the `setKeyBarSlim` area at about line 3252; `placeComposer` at about line 2655)
- Test: `gui/test/ui/prefs_test.dart`, `gui/test/ui/main_state_test.dart`

**Interfaces:**
- Produces `UiPrefs` fields:
  - `bool quickHiddenTerm` (`quick_hidden_term`);
  - `bool quickHiddenApp` (`quick_hidden_app`);
  - `bool? quickAutoHide` (`quick_auto_hide`, written only when non-null);
  - `InputPoint? termComposerAt` (`term_composer_at`, via `InputPoint.toJson` / `fromJson`).
- Removes `keyBarSlim` and `setKeyBarSlim`.
- Produces on `MainState`:
  - `bool get quickAutoHide`: the pref, or `defaultTargetPlatform != TargetPlatform.iOS` when null;
  - `void setQuickAutoHide(bool v)`;
  - `void setQuickHidden({required bool term, required bool hidden})`;
  - `InputPoint? composerAtOf(RemoteSession rs)`: `prefs.termComposerAt` when `termPort?.owns(rs.sid) == true`, else `rs.profile.composerAt`.
  - `placeComposer(rs, p)` now writes `prefs.termComposerAt` (and saves) for a text terminal. Apps are handled as before.
  - Every setter calls `_save()` and notifies.

- [ ] **Step 1: Write the failing tests**

```dart
// prefs_test.dart
test('quick area prefs: defaults', () {
  final p = UiPrefs();
  expect(p.quickHiddenTerm, false);
  expect(p.quickHiddenApp, true);
  expect(p.quickAutoHide, isNull);
  expect(p.termComposerAt, isNull);
});
test('old key_bar_slim true reads as quick_hidden_term; never written back', () {
  // write {'key_bar_slim': true} to gui.json, load
  expect(loaded.quickHiddenTerm, true);
  loaded.save(dir);
  expect(jsonDecode(File('$dir/gui.json').readAsStringSync()).containsKey('key_bar_slim'), false);
});
test('quick_hidden_term false wins over an old key_bar_slim true', () { /* both keys present → false */ });
test('round trip: quick_hidden_*, quick_auto_hide, term_composer_at', () {
  // InputPoint(0.3, 120, fromBottom: true) survives save/load; bad term_composer_at → null
});
// main_state_test.dart
test('quickAutoHide: null pref is on for macOS, off for iOS', () { /* debugDefaultTargetPlatformOverride */ });
test('placeComposer on a text terminal writes term_composer_at; composerAtOf reads it for every terminal', () {});
test('placeComposer on an app still writes the profile; composerAtOf reads the profile', () {});
```

- [ ] **Step 2: Run them and check they fail.** Run `flutter test test/ui/prefs_test.dart test/ui/main_state_test.dart`. Expected: compile errors on the new fields.
- [ ] **Step 3: Implement the fields, the parse and save, and the `MainState` members above.**
  - Parse: `quickHiddenTerm = qt is bool ? qt : j['key_bar_slim'] == true`.
  - Fix every other `keyBarSlim` reference so the app compiles:
    - in `key_bar.dart`, read `quickHidden(...)`, which comes in Task 3; for now use `prefs.quickHiddenTerm`;
    - in tests, delete them, or leave them for Task 3 to rewrite.
- [ ] **Step 4: Run the same tests and check they pass.** Also run `flutter analyze` and expect no issues.
- [ ] **Step 5: Commit** with `feat(gui): prefs for the quick area and a shared terminal panel place`.

---

### Task 2: ＋ menu, the same on both platforms

**Files:**
- Modify: `gui/lib/embed/composer_plus.dart`:
  - delete `composerKeys`, `termComposerKeys`, `_keyCell`, `_termKeyCell`, `_sticky` and the grid rows;
  - add the 快捷区 group.
- Modify: `gui/lib/embed/composer_panel.dart:468-484`:
  - pass `state`;
  - `onAddPhrase: widget.state.addPhrase` on every platform.
- Test: `gui/test/embed/composer_panel_test.dart` (the ＋ group, about lines 678–930), `gui/test/term/term_composer_test.dart:257`

**Interfaces:**
- Consumes (Task 1): `state.quickAutoHide`, `state.setQuickAutoHide`.
- Also uses the existing `state.prefs.phraseStrip` / `setPhraseStrip`, `state.prefs.keyBarMore` / `setKeyBarMore` and `openPhrasesPage(context, state)`.
- Produces: `ComposerPlus({required MainState state, ...})`. The menu rebuilds on `state` (wrap the group in `ListenableBuilder(listenable: state)`).
- Rows use `RappSwitchRow`, like `_returnAfter`:
  - keys `quick-auto-hide`, `quick-phrase-strip`, `quick-more`;
  - 「编辑常用语…」 is an `InkWell` row with key `quick-edit-phrases`. It closes the menu, then opens the page.
- Order:
  1. 附件…
  2. 在远端复制
  3. 输入历史
  4. 直接回车且隐藏
  5. 大小
  6. header 「快捷区」 (muted, key `composer-plus-quick`)
  7. the three switches, then 编辑常用语…
  8. Esc 收起

- [ ] **Step 1: Write the failing tests.** Replace these tests:
  - `plus opens a menu above it: 附件…, 在远端复制, the keys, 收起`
  - `iOS ＋ menu: no 按键 grid…`
  - `macOS ＋ menu unchanged: the 按键 grid stays`
  - `keys go to A in W9 order…`
  - `a latched sticky key is a raise box…`
  - `「＋」 has the 15 terminal keys…`

  Use these instead:

```dart
for (final platform in [TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.iOS])
  testWidgets('${platform.name} ＋ menu: 附件, 在远端复制, 输入历史, 直接回车且隐藏, 大小, 快捷区 group, 收起; no key grid', (tester) async {
    expect(find.text('按键 · 直接发给远端'), findsNothing);
    expect(find.byKey(const Key('composer-plus-quick')), findsOneWidget);
    // vertical order: 大小 above 快捷区 above 打字后自动收起 above 显示常用语条 above 更多按键 above 编辑常用语… above 收起
  });
testWidgets('快捷区 switches flip quickAutoHide, phraseStrip, keyBarMore and the menu stays open', (tester) async {});
testWidgets('打字后自动收起 shows on for macOS by default, off for iOS', (tester) async {});
testWidgets('编辑常用语… closes the menu and pushes PhrasesPage', (tester) async {});
testWidgets('macOS 输入历史 has 加到常用语', (tester) async {});
testWidgets('terminal ＋ menu: 附件… grey, no 在远端复制, the 快捷区 group present', (tester) async {});
```

  Also trim `the sticky keys and the menu never carry over to another session` down to the menu part.
- [ ] **Step 2: Run them and check they fail.** Run `flutter test test/embed/composer_panel_test.dart test/term/term_composer_test.dart`.
- [ ] **Step 3: Implement the changes above.**
- [ ] **Step 4: Run them and check they pass.** Then run `flutter analyze`.
- [ ] **Step 5: Commit** with `feat(gui): one ＋ menu on every platform, with the 快捷区 settings`.

---

### Task 3: Key rows, ⊙ folds the quick area, auto-hide counts picture keys only

**Files:**
- Modify: `gui/lib/embed/key_bar_keys.dart`:
  - `keyBarRows`;
  - `BarKind.slim` → `BarKind.hide`, id `'hide'`, label `⊙`, spoken `收起快捷区`;
  - delete `keyBarOneRowAt` and `keyBarGroupGap` if nothing else uses them.
- Modify: `gui/lib/embed/key_bar.dart`:
  - `_rowsOf`, `phraseStripShown`, `keyBarHeightOf`, `foldKeyBar`;
  - the `_onKey` handler on every platform;
  - `BarKind.hide` fires `setQuickHidden`;
  - the box is `seeThroughBox(t)`.
- Modify: `gui/lib/embed/composer_panel.dart:110-113`: the NativeEditor `onTyped` no longer folds. Drop the argument, and the parameter if nothing else uses it.
- Modify: the callers of `keyBarHeightOf` and `keyBarWhenClosed` (`stage.dart`, `ios_dock.dart`, `composer_panel.dart`). Just make them compile; Task 5 replaces them.
- Test: `gui/test/embed/key_bar_keys_test.dart`, `gui/test/embed/key_bar_test.dart`

**Interfaces:**
- Consumes (Task 1): `prefs.quickHiddenTerm`, `prefs.quickHiddenApp`, `state.quickAutoHide`, `state.setQuickHidden`.
- Produces:
  - `List<List<String>> keyBarRows({required bool app, required bool more})`: no nulls, no width;
  - `double keyBarHeightOf(MainState state, RemoteSession session)`;
  - `bool termKind(MainState state, RemoteSession session)`: a text terminal (`_isTerm`) or `terminalApps.contains(session.appId)`. It replaces `keyBarWhenClosed`;
  - `bool quickHidden(MainState state, RemoteSession session)`: the pref of the session's kind;
  - `bool typedIntoPicture(MainState state, RemoteSession session)`: `state.pictureFocused == session.sid && !session.composer.editorFocused`;
  - `void foldKeyBar(MainState state, RemoteSession session)`: returns without doing anything when `!state.quickAutoHide`, when `quickHidden` is already set, or while `keyLatchOf(...).flags != 0`. Otherwise it calls `setQuickHidden(term: termKind(...), hidden: true)`.
- `_onKey`: `collapsesKeyBar(e) && typedIntoPicture(...)` → `foldKeyBar`. `KeyTypedEvent` (macOS) folds without the focus check, because it only comes from the picture.

- [ ] **Step 1: Write the failing tests.**

```dart
// key_bar_keys_test.dart: replace narrow/wide/hardware/slim cases
test('one row of eleven, ⊙ last; more adds the second row', () {
  expect(keyBarRows(app: false, more: false), [['esc','stab','tab','cc','left','up','down','right','enter','more','hide']]);
  expect(keyBarRows(app: false, more: true)[1], ['ctrl','opt','cr','co','ct','cb','cd','bksp','copy','paste']);
});
test('app: ⌘ after ⌥, ⌃D gives way', () {});
test('hide key: ⊙, spoken 收起快捷区, kind hide', () {});
// key_bar_test.dart
testWidgets('⊙ hides the quick area of its kind: a terminal sets quick_hidden_term, Safari quick_hidden_app', (tester) async {});
for (final platform in [TargetPlatform.macOS, TargetPlatform.linux])
  testWidgets('${platform.name}: a letter typed into the focused picture folds; typed with the editor focused it does not', (tester) async {
    // state.focusPicture(sid) → press KeyA → quickHidden true
    // reset; session.composer.editorFocused = true → press KeyA → quickHidden false   (Review Focus 2)
  });
testWidgets('quick_auto_hide off: a picture key does not fold', (tester) async {});
testWidgets('iOS with quick_auto_hide turned on: a hardware key into the picture folds', (tester) async {});
testWidgets('macOS KeyTypedEvent for this sid folds; another sid does not', (tester) async {});
testWidgets('the 常用语条 shows whatever the quick state was (no slim rule) and the bar height adds phraseStripHeight', (tester) async {});
```

  Keep:
  - `collapsesKeyBar` and the ⌘ / Linux-Ctrl / lit-latch cases (point them at `quickHidden`);
  - the phrase, repeat, swipe and paste groups.

  Drop:
  - `the desktop too, and it stays while slim (iOS hides it while slim)`;
  - the slim and hardware row cases.
- [ ] **Step 2: Run them and check they fail.** Run `flutter test test/embed/key_bar_keys_test.dart test/embed/key_bar_test.dart`.
- [ ] **Step 3: Implement the changes above.**
- [ ] **Step 4: Run them and check they pass.** Then run `flutter analyze`.
- [ ] **Step 5: Commit** with `feat(gui): ⊙ hides the 快捷区; auto-hide counts only keys typed into the picture`.

---

### Task 4: FloatingComposer carries the whole block

**Files:**
- Modify: `gui/lib/embed/composer_float.dart`
- Test: `gui/test/embed/composer_float_test.dart`, `gui/test/embed/composer_panel_test.dart` (the float group, about lines 1380–1660)

**Interfaces:**
- Produces:
  - `FloatingComposer({required RemoteSession session, required InputPoint? at, InputPoint defaultAt = defaultComposerAt, bool grip = true, Widget? handle, required ValueChanged<InputPoint?> onPlace, required Widget child, double scale = 1, double keyboard = 0, ValueNotifier<Rect?>? place, VoidCallback? onPullClose})`.
    - `_at` becomes `widget.at ?? widget.defaultAt`. It no longer reads `profile.composerAt`.
  - `final composerNoDrag = Object()`: wrap a subtree in `MetaData(metaData: composerNoDrag)` and neither `PanelPan` nor `_TextHold` starts there. Generalise `_onText` into `_onMeta(e, marker)`.
  - `const quickHandleSize = 28.0`.
- Grip row:
  - only the grip, centred, `gripSize` tall;
  - no `_closeSize` blanks;
  - no `composer-grip-close`;
  - nothing at all when `grip` is false.
- The handle and the block become a `CustomMultiChildLayout`:
  - the block is placed as today (`_topLeftOf`);
  - the handle is bottom-aligned with the block's bottom, 8 right of the block's right edge;
  - when that would cross `stage.width - composerMargin`, the handle goes 8 left of the block's left edge;
  - the handle is clamped inside the stage.
  - `PanelPlace` still wraps only the block (with its grip). An empty block (no grip, zero-height child) reports a zero-height rect.

- [ ] **Step 1: Write the failing tests.** Delete these tests:
  - `the grip × is at least 40 square on macOS`
  - `a small × right beside the grip shows with the bar and collapses the panel`

  Rename `a touch on the panel shows the bar and the ×` to `…shows the bar` and drop its × assertion. Then add:

```dart
testWidgets('no × on any platform: composer-grip-close is never built', (tester) async {});
testWidgets('at null uses defaultAt; a drag saves through onPlace; double-tap gives null', (tester) async {});
testWidgets('grip false: no composer-grip, the block is only the child', (tester) async {});
testWidgets('handle sits 8 right of the block, bottoms level', (tester) async {});
testWidgets('block at the right edge: the handle flips to 8 left of it, inside the stage', (tester) async {}); // Review Focus 3
testWidgets('a drag starting inside composerNoDrag does not move the block', (tester) async {});
testWidgets('a growing child keeps the bottom centre where it was', (tester) async {
  // child SizedBox height 60 → 200: tester.getRect(block).bottomCenter unchanged
});
```

  Also, in `composer_panel_test.dart` or Task 5's dock test once the KeyBar sits in the block, add:
  `testWidgets('swipe up on bar-up sends PgUp and leaves the block where it was')` (Review Focus 1).
- [ ] **Step 2: Run them and check they fail.** Run `flutter test test/embed/composer_float_test.dart test/embed/composer_panel_test.dart`.
- [ ] **Step 3: Implement the changes above.** At the two existing call sites in `composer_panel.dart`, pass `at: state.composerAtOf(session)`.
- [ ] **Step 4: Run them and check they pass.** Then run `flutter analyze`.
- [ ] **Step 5: Commit** with `feat(gui): the floating composer carries the whole input block; no grip ×`.

---

### Task 5: InputDock on every platform; the picture stays still

**Files:**
- Create: `gui/lib/embed/input_dock.dart`, made from `ios_dock.dart` with `git mv`. Delete `PullDown`, `closedStackBottom` and `keyBarWhenClosed`.
- Modify: `gui/lib/embed/composer_panel.dart`:
  - `composerLayer` has one path;
  - `_iosLayer` folds into it;
  - delete `pictureLift`;
  - the terminal `Align`/`Padding`/`PullDown` branches go away.
- Modify: `gui/lib/ui/stage.dart`: delete `_lifted` and `_lift`. Both call sites (lines about 214 and 229) use the bare stage.
- Test: `git mv gui/test/embed/ios_dock_test.dart gui/test/embed/input_dock_test.dart`. Also update `gui/test/term/term_composer_test.dart:365-456` and `gui/test/embed/composer_panel_test.dart:1340`.

**Interfaces:**
- Consumes:
  - Task 3: `termKind`, `quickHidden`, `keyBarHeightOf`, `setQuickHidden`;
  - Task 4: `FloatingComposer(at:, defaultAt:, grip:, handle:)`, `composerNoDrag`, `quickHandleSize`;
  - Task 1: `composerAtOf`, `placeComposer`.
- Produces:
  - `InputDock({required MainState state, required RemoteSession session, required SessionPort port, required double keyboard, required Listenable listenable, required bool voice, required Widget Function(BuildContext, double maxHeight) text, required Widget Function(BuildContext, double bottom, Size stage) stack})`, keyed by `ValueKey(session.sid)` at the call site.
  - `double restStackBottom(double keyboard)`: `max(stageButtonsUp, keyboard > 0 ? keyboard + stageButtonsEdge : 0)`.
  - `double stackBottomOf({required Size stage, required Rect? block, required double keyboard, required double stackHeight})`:
    - `restStackBottom(keyboard)` when `block` is null or zero-height;
    - otherwise `max(rest, min(stage.height - block.top + 8, stage.height - 8 - stackHeight))`.
  - `InputPoint desktopComposerAt(double rowHeight)`: `InputPoint(0.5, rowHeight + 20, fromBottom: true)`.
  - Keep `dockMove` and `openStackHeight`.
- Inside `InputDock`:
  - Text controller `_shown`: keep the existing `_opacity` fade line, but drop `_sink` / `_drop`. The text part is `IgnorePointer(!open) → Opacity(fade) → ClipRect → Align(alignment: bottomCenter, heightFactor: eased _shown)`. It stays mounted while `open || !_shown.isDismissed`, so the same `ComposerPanel` State survives a quick reopen. The close still calls `composer.releaseFocus()`, and a reopen before the close ends calls `wantFocus()`.
  - Quick controller `_quick`: driven by `quickHidden(state, session)` through a listener on `state`. The quick part is `MetaData(composerNoDrag) → Opacity(eased) → ClipRect → Align(heightFactor: eased) → KeyBar(key: ValueKey(('quick', sid)))`. It stays mounted while `!hidden || !_quick.isDismissed`.
  - Gap: `SizedBox(height: 8 * min(eased _shown, eased _quick))`.
  - `FloatingComposer`:
    - `at: state.composerAtOf(s)`;
    - `defaultAt`: iOS `defaultComposerAt`, else `desktopComposerAt(controlHeightOf(context))`;
    - `keyboard: k`;
    - `onPullClose`: iOS and the text area open → `composer.collapse`, else null;
    - `grip: textMounted || quickMounted`;
    - `handle`: when `_quick.isDismissed && hidden` → `QuickHandle`.
  - `QuickHandle`: 28 round, `seeThroughBox`, `Icons.adjust`, key `quick-handle`, semantics 「显示快捷区」. On tap, `setQuickHidden(term: termKind, hidden: false)`.
  - `composerAllowed` false: no block and no handle.
  - Stack: `widget.stack(context, stackBottomOf(stage: c.biggest, block: panelPlaceOf(s).value, keyboard: k, stackHeight: …), c.biggest)`.
    - The stack height is `openStackHeight(upright, voice)` while the text area is open.
    - Otherwise it is the closed count, using the same arithmetic `_TidyLayer._ios` uses today. Move that into a shared `closedStackHeight({required int buttons, required bool upright})` in `input_dock.dart`.
- `composerLayer` (all platforms) returns:
  - `[Positioned.fill(_InputStage(key: sid, buttons: (hold) => InputDock(...)))`, where `_InputStage` is `_IosStage` renamed. It owns the `VoiceHold` only on iOS; on desktop `hold` is null;
  - `Positioned.fill(_TidyLayer(...))]`.
  - The `stack` builder is `_iosStack` on iOS. On desktop it is the existing corner row (Task 6 changes the row's contents).

- [ ] **Step 1: Write the failing tests** in `input_dock_test.dart`. Give the harness a `dockTest(platform, …)` variant for macOS too, and seed `UiPrefs(phraseStrip: false)` as today.

```dart
for (final p in [TargetPlatform.iOS, TargetPlatform.macOS]) {
  dockTest(p, 'terminal: quick area at panelWidth, bottom at the default anchor, no handle', ...);
  dockTest(p, 'Safari: only quick-handle, 28 square, 8 right of the anchor block; tap → KeyBar shows, quick_hidden_app false', ...);
  dockTest(p, 'opening the text area leaves every bar-* key rect unchanged; the text area ends 8 above the bar', ...);
  dockTest(p, 'showing the quick area keeps the block bottom; an open text area rises by keyBarHeightOf + 8', ...);
  dockTest(p, '⊙ folds the quick area; the handle comes back; the open text area falls to the anchor', ...);
  dockTest(p, 'close then open within 200ms: one ComposerPanel, same State, draft intact', ...);
  dockTest(p, 'disableAnimations: text and quick land in one frame', ...);
  dockTest(p, 'session switch terminal → Safari: handle only, the terminal KeyBar is gone; a picture key no longer changes quick_hidden_term', ...); // Review Focus 4
}
iosTest('keyboard 300: the block bottom 308; with only the handle, the handle bottom 308 and the stack at restStackBottom(300)', ...); // Review Focus 5
iosTest('keyboard rising 0→300 over frames: the block bottom is max(anchor, keyboard + 8) every frame', ...);
iosTest('the stack stands 8 above the block top; with only the handle at restStackBottom', ...);
iosTest('a voice hold changes neither quick_hidden_* nor the stack bottom', ...);
iosTest('terminal block at its lowest: pull 80 folds the text area only, the KeyBar stays; pull 40 springs back', ...);
iosTest('输入 and 收起 are one element: the icon turns over (R12)', ...); // kept
iosTest('swipe up 40 on bar-up sends PgUp; the block rect is unchanged', ...); // Review Focus 1
```

  Replace the picture-lift tests:
  - In `term_composer_test.dart`, `opening and closing the panel lifts the picture by $pictureLift…` and `iOS stage lift…` become `the stage child's rect is identical before and after opening the text area and showing/hiding the quick area` (terminal, iOS and macOS).
  - In `composer_panel_test.dart`, `opening, growing and closing never move the picture` keeps its name and drops any lift tolerance.
  - Delete `no lift over a detached placeholder`; there is no lift any more.
  - Update `with the soft keyboard up the panel sits 8 above it` to say the block bottom is 8 above the keyboard.
- [ ] **Step 2: Run them and check they fail.** Run `flutter test test/embed/input_dock_test.dart test/term/term_composer_test.dart test/embed/composer_panel_test.dart`.
- [ ] **Step 3: Implement the changes above.** Update every import of `ios_dock.dart`; check with `grep -rn ios_dock gui/lib gui/test`.
- [ ] **Step 4: Run them and check they pass.** Then run `flutter analyze` and the whole suite with `flutter test`. Expect everything green except the environmental `linux_detach_test`.
- [ ] **Step 5: Commit** with `feat(gui): one input dock on every platform; the picture never moves`.

---

### Task 6: Stage buttons, the tidy card, real-machine checks

**Files:**
- Modify: `gui/lib/ui/controls.dart`:
  - `RappButton.secondary` gets `this.active = false`, replacing `active = false` in its initializer;
  - check that the border at about line 188 applies to it.
- Modify: `gui/lib/embed/composer_panel.dart`:
  - the desktop row: stays while open, and the toggle comes from `_openToggle`'s logic as a secondary button;
  - `_TidyLayer._desktop` and `_TidyLayer._ios`.
- Modify: `tasks/todo.md`: add the spec's §8 checks 1–12 under a new 「输入块」 heading.
- Test: `gui/test/embed/composer_panel_test.dart` (`hidden while the writing panel is open`, about line 1168, and the tidy card group), `gui/test/embed/input_dock_test.dart`

**Interfaces:**
- Consumes (Task 5): `stackBottomOf`, `closedStackHeight`, `panelPlaceOf(s)` (now the whole block), `desktopComposerAt`.
- Desktop row:
  - Drop the `session.composer.open && button` hide; the row's padding is `bottom: 12 + keyboard`.
  - The `composer-open` button:
    - label and semantics are 「收起」 while open and 「输入」 while closed;
    - the icon is `keyboard_hide_outlined` while open and `keyboard_outlined` while closed;
    - `active: open`;
    - `onPressed`: `collapse` while open, else `open = true`.
  - 还原 keeps its `!composer.open` condition.
- `_TidyLayer`:
  - Drop the `bar` and `closedBar` parameters.
  - Desktop: when `panelPlaceOf(s).value` has height > 0, the card sits above the block, right-aligned, 8 up; below the block when there is no room above; the corner otherwise. With no block, the corner above the row.
  - iOS: the card's bottom is the stack's top + 12, using `stackBottomOf` plus the same stack height that `InputDock` uses.

- [ ] **Step 1: Write the failing tests.**

```dart
// composer_panel_test.dart (macOS and Linux)
testWidgets('输入 stays while open, reads 收起 and is active; a tap folds the text area only, the draft and the quick area stay', (tester) async {});
testWidgets('the row rect is the same with the text area open or closed, and with the quick area shown or hidden', (tester) async {});
testWidgets('desktop default: block bottom is controlHeight + 20 up, centred, not overlapping the row at a 1000-wide stage', (tester) async {});
testWidgets('tidy card: above the block, right-aligned with it; below it with no room above; never off the stage', (tester) async {});
// input_dock_test.dart (iOS)
iosTest('tidy card stands 12 above the stack, which stands above the block', ...);
```

  Update the old tests:
  - `hidden while the writing panel is open` becomes the first test above.
  - `open: one line, 720 wide, centred, 8 above the stage bottom` and `the panel starts bottom centre, 8 up, the grip above it` now expect the desktop default (`controlHeight + 20`) on macOS.
- [ ] **Step 2: Run them and check they fail.** Run `flutter test test/embed/composer_panel_test.dart test/embed/input_dock_test.dart`.
- [ ] **Step 3: Implement the changes above, and write the 12 checks into `tasks/todo.md`.**
- [ ] **Step 4: Run `flutter analyze` and the whole `flutter test`.** Expect everything green except the environmental `linux_detach_test`. Build-check macOS with `cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug` (compile only). Build-check iOS in this worktree the way earlier iOS branches did. Then `git checkout gui/pubspec.lock`.
- [ ] **Step 5: Commit** with `feat(gui): the desktop 输入/收起 toggle stays in its corner; tidy card follows the block; real-machine checks`.

---

## Plan decisions (beyond the spec)

- Key rows are always narrow, with no width parameter. The spec assumed that panel width stays under 860, but zoom 1.3 and up goes past it. The intent ("一律窄排") wins.
- Parts open and fold by height (`Align.heightFactor`) inside the bottom-anchored block, not by translating. This keeps the anchor fixed by construction. The iOS "panel sinks below the bar" move (`_sink` / `_drop`) goes away, because the quick area no longer sits under the panel at the stage's bottom.
- The handle always stands beside the block (right, or left at the edge) at the anchor's height. So it does not jump when the text area opens.
- A drag never starts on the quick area (`composerNoDrag`): a swipe up on a key is that key's alternate key. A quick-only block is moved by its grip.
- The iOS pull-close is only there while the text area is open. A pull on a quick-only block does nothing.
