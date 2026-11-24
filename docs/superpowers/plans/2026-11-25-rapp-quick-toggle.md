# 快捷区开关（方案 G）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The 快捷区 toggle becomes a square key inside the writing box, left of the text and right of ＋, plus a stack copy while the text area is folded. The round handle and the key bar's ⊙ go away.

**Architecture:**
- A new `quick_toggle.dart` holds a single `QuickToggle` widget in two looks: box (40·k secondary) and stack (56 stage button on iOS, secondary in the desktop corner row).
- `ComposerPanel` puts [＋][开关] on the left of the box, and the ＋ menu anchors to ＋'s left edge.
- The stack and the corner row add the toggle next to 输入 while the text area is folded, and `stackButtonCount` counts it.
- The `QuickHandle`, the `FloatingComposer.handle` slot and `BarKind.hide` are deleted.

**Tech Stack:** Flutter (gui/), flutter_test widget tests. Flutter is at `~/development/flutter/bin` (not on PATH).

**Spec:** `docs/superpowers/specs/2026-11-25-rapp-quick-toggle-design.md`

## Global Constraints

- Box order, left to right: ＋, 开关, text, 发送. 发送 stays at the far right with an unchanged style.
- The box keeps today's height: 56 inside the border at zoom k=1 (one line). Every key is 40·k square, with an even 8·k margin to the border.
- The toggle is `RappButton.secondary`, 40·k, `active: true` (accent border 1.5) while the 快捷区 shows, and unlit while it is hidden.
- A tap calls `setQuickHidden(term: termKind(st, s), hidden: !quickHidden(st, s))`. Terminals and apps keep separate settings.
- Labels: 「收起快捷区」 while shown, 「显示快捷区」 while hidden. The same text is the semantics label and the hover tooltip.
- Icon: a key grid, not ⌨ and not ⌘. Ruling: `Icons.grid_view_outlined`. RappButton takes `IconData`, and this is the stock glyph closest to the mock's grid. If wrong, swapping it is a one-line change.
- Block from top to bottom: box, gap 8, 快捷区. When the 快捷区 opens or closes, the box does not move.
- While the text area is folded, the toggle stands next to 输入 at the same size and in the same style. It shows only when `composerAllowed`.
- The key bar's ⊙ (`hide`) is gone on every platform, so the first row is 10 keys.
- Unchanged:
  - auto-fold on typing (`foldKeyBar`);
  - the ＋ menu's 快捷区 group;
  - voice hold;
  - 语音 in the stack;
  - drag and the saved position;
  - zoom.
- Test runs: `cd gui && ~/development/flutter/bin/flutter test <file>`. Revert `gui/pubspec.lock` afterwards (`git checkout gui/pubspec.lock`).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Tapping the toggle while typing.**
   - Expected: the editor keeps its text, and the panel stays open. Keys go nowhere remote, because the toggle holds for the panel as ＋ does.
   - Test: Task 2, 「tapping the toggle keeps the draft and the panel open」.
2. **The light follows every way the setting changes.**
   - Cases: auto-fold on typing, the ＋ menu, and the other kind's setting.
   - Expected: the light reflects the current session's kind.
   - Test: Task 2, 「the light follows foldKeyBar and the other kind is untouched」.
3. **The ＋ menu now starts from the left edge.**
   - Expected: it opens rightward from ＋ (left edges equal) and never off the stage's left.
   - Test: Task 2 changes the anchor assertions in `composer_panel_test.dart`.
4. **Zoom k=2.**
   - Expected: all three keys are 80 square, with the 16 margin. The text keeps a usable width on a phone-narrow stage (320).
   - Test: Task 2, 「zoomed and narrow」.
5. **A session that may not write (`composerAllowed` false).**
   - Expected: no box toggle and no stack toggle. The stack count is unchanged.
   - Test: Task 3, 「no toggle where the composer is not allowed」.

---

### Task 1: Drop the key bar's ⊙ key

**Files:**
- Modify: `gui/lib/embed/key_bar_keys.dart`
  - `BarKind` loses `hide`.
  - The `'hide'` entry goes.
  - `first` row: `['esc','stab','tab','cc','left','up','down','right','enter','more']`.
- Modify: `gui/lib/embed/key_bar.dart`
  - The `case BarKind.hide:` branch around line 323 goes.
  - The comment at line 227 changes to say that the toggle in the box (or the stack) shows the 快捷区 again.
- Test: `gui/test/embed/key_bar_keys_test.dart`, `gui/test/embed/key_bar_test.dart`

**Interfaces:**
- Produces: `keyBarRows(...)` gives a first row of 10 ids with no `hide`. Nothing else is renamed.

- [ ] **Step 1: Update the tests first**
  - In `key_bar_keys_test.dart`:
    - Rename 「one row of eleven, ⊙ last」 to `'one row of ten, ⋯ last; more adds the second row'`. Its expectation is the 10-id list above.
    - Replace the `hide key` test with `test('no hide key', () => expect(barKeys.containsKey('hide'), isFalse));`.
    - Drop `'hide'` from the id loop at line 69.
  - In `key_bar_test.dart`:
    - Replace 「⊙ is always the last key of the first row」 with `iosTest('⋯ is the last key of the first row; no ⊙', ...)`. It asserts:
      - `k('hide')` finds nothing;
      - `k('more')` finds one;
      - `find.bySemanticsLabel('收起快捷区')` finds nothing inside the KeyBar.
    - Delete 「⊙ hides the quick area of its kind…」. Task 2 re-tests per-kind toggling on the new toggle.
    - At line 674, replace `await tap(tester, 'hide');` with `s.setQuickHidden(term: false, hidden: false); await tester.pump();`.
- [ ] **Step 2: Run them and see them fail**
  - Run: `flutter test test/embed/key_bar_keys_test.dart test/embed/key_bar_test.dart`
  - Expected: FAIL on the row list and on `containsKey('hide')`.
- [ ] **Step 3: Remove `hide` from `key_bar_keys.dart` and `key_bar.dart` as listed under Files.**
- [ ] **Step 4: Run them again**
  - Run: the same command, plus `flutter analyze lib/embed/key_bar*.dart`.
  - Expected: all PASS and no analyzer issues. Grep `gui/lib` for `BarKind.hide`: there should be no hits.
- [ ] **Step 5: Commit** `feat(gui): the key bar drops its ⊙ key; the toggle moves to the box`

### Task 2: The toggle in the box, ＋ on the left

**Files:**
- Create: `gui/lib/embed/quick_toggle.dart`
- Modify: `gui/lib/embed/composer_panel.dart:414-494`, the box row.
- Modify: `gui/lib/embed/composer_plus.dart:298-301`, the menu anchor. Also fix the "below/above 「＋」" doc if it names right.
- Modify: `gui/lib/embed/composer_panel.dart:1-3`, the file header order: "[＋] [快捷区] [editor] [发送]".
- Test: `gui/test/embed/composer_panel_test.dart`; new `gui/test/embed/quick_toggle_test.dart`

**Interfaces:**
- Produces, in `quick_toggle.dart`:
  - `String quickToggleLabel({required bool shown})` returns `'收起快捷区'` when shown, else `'显示快捷区'`.
  - `void toggleQuick(MainState state, RemoteSession session)` calls `setQuickHidden(term: termKind(state, session), hidden: !quickHidden(state, session))`.
  - `class QuickToggle extends StatelessWidget`, with `QuickToggle({Key? key, required MainState state, required RemoteSession session, required QuickToggleLook look, double scale = 1})`.
  - `enum QuickToggleLook { box, stage, corner }`.
  - Behavior:
    - It rebuilds on `state` through a `ListenableBuilder`. `shown = !quickHidden(state, session)`.
    - It is wrapped in `Tooltip(message: label)`.
    - `Listener(onPointerDown: (_) => state.holdForPanel(session))` wraps the button, as ＋ does.
  - Looks:
    - **box**: `RappButton.secondary(key: Key('quick-toggle'), label/semanticLabel: label, icon: Icons.grid_view_outlined, size: 40 * scale, active: shown)`.
    - **stage**: `RappButton.stage(key: Key('quick-toggle-stack'), label, icon, size: stageButtonSize, active: shown)`.
    - **corner**: `RappButton.secondary(key: Key('quick-toggle-stack'), label/semanticLabel, icon, onPicture: true, seeThrough: true, active: shown)`. This is 输入's corner style.
- Consumes: `quickHidden`, `termKind` from `key_bar.dart`; `MainState.setQuickHidden`, `MainState.holdForPanel`.

- [ ] **Step 1: Write the failing tests**
  - In `quick_toggle_test.dart`, use the harness helpers `composer_panel_test.dart` already uses (`layer()`, `big()`, `rect()`):
    - `'label and light follow the kind: terminal sets quickHiddenTerm only'`
      - Box toggle shown: `active` is true and the semantics label is `收起快捷区`.
      - Tap it: `prefs.quickHiddenTerm` becomes true, `quickHiddenApp` is unchanged, and the label is now `显示快捷区`.
      - Tap again: back to shown.
      - The same on an app session flips `quickHiddenApp` only.
    - `'the light follows foldKeyBar and the other kind is untouched'`
      - `foldKeyBar(state, session)` makes the toggle unlit.
      - `state.setQuickHidden(term: !termKind(...), hidden: true)` does not change it.
    - `'tapping the toggle keeps the draft and the panel open'`
      - Set the draft to `'abc'` and tap the toggle.
      - Expect `composer.open` true and the draft `'abc'`.
    - `'tooltip names the action'`: `find.byTooltip('收起快捷区')` finds one.
  - In `composer_panel_test.dart`:
    - Rewrite 「＋ and 发送: 40 square…」 as `'＋ and the toggle on the left, 发送 on the right: 40 square, even 8, one-line box 56'`:
      - `plus.left - box.left == 8`
      - `toggle.left - plus.right == 4`
      - `box.right - send.right == 8`
      - top and bottom margins 8 on all three
      - `plus.top == toggle.top == send.top`
      - `box.height == 56`
      - The text starts right of the toggle: the editor's left edge is `toggle.right + 16`. That is 8 for the key margin plus 8 for the editor padding, the same as the 16 between the text and 发送.
    - Long-text test: all three bottoms are `box.bottom - 1 - 8`. Replace `plus.right == send.left - 4` with `toggle.left == plus.right + 4` and `plus.left == box.left + 1 + 8`.
    - Menu tests at about 698 and 825: `m.right == plus.right` becomes `m.left == plus.left`. Add `expect(m.left, greaterThanOrEqualTo(host.left))`.
    - New `'zoomed and narrow'`:
      - At `composerZoom` k=2, all three keys are `Size(80, 80)` and the box is 112 high inside its 1 px border.
      - At stage width 320 and k=1, the editor's width is `> 100`.
- [ ] **Step 2: Run and see them fail**
  - Run: `flutter test test/embed/quick_toggle_test.dart test/embed/composer_panel_test.dart`
  - Expected: FAIL. `quick_toggle.dart` is missing, and ＋ is still on the right.
- [ ] **Step 3: Implement**
  - Write `quick_toggle.dart` per Interfaces.
  - In the box `Row` (`crossAxisAlignment.end`), the children are:
    1. `Padding(all: edge)` around `Row[ComposerPlus, SizedBox(width 4), QuickToggle(look: box, scale: k)]`;
    2. `Expanded(editor, padding left 8, right 8)`;
    3. `Padding(all: edge)` around 发送 alone.
  - In ComposerPlus, set `targetAnchor` to `_down ? bottomLeft : topLeft` and `followerAnchor` to `_down ? topLeft : bottomLeft`.
  - The macOS NSTextView is a platform view laid out in the `Expanded`, so it moves with the Flutter padding. `ComposerNative.m` needs no change. Confirm in Task 5's macOS run.
- [ ] **Step 4: Run them again**
  - Run: the same command, plus `flutter analyze`.
  - Expected: all PASS and no analyzer issues.
- [ ] **Step 5: Commit** `feat(gui): the 快捷区 toggle sits in the box beside ＋, which moves left`

### Task 3: The toggle beside 输入 while the text area is folded

**Files:**
- Modify: `gui/lib/embed/stage_buttons.dart`
  - New `final Widget? quick;` parameter.
  - Stack order, bottom to top: voice, input, quick, restore. The upright row reads outward the same way.
  - `quick` is `_faded` and `_draggable` like `input`.
  - Update the class doc.
- Modify: `gui/lib/embed/input_dock.dart:53-57`
  - `stackButtonCount` adds 1 for the toggle when `composerAllowed`. Update its doc: 语音, 输入, 快捷区, 还原.
  - `openStackHeight` is unchanged: with the text area open, the toggle is in the box.
- Modify: `gui/lib/embed/composer_panel.dart`
  - `_iosStack`: pass `quick: button && !open ? QuickToggle(state: state, session: session, look: QuickToggleLook.stage) : null`.
  - `_cornerRow`: when `button && !open`, insert `QuickToggle(state: state, session: session, look: QuickToggleLook.corner)` plus `SizedBox(width 8)` immediately left of 输入.
- Test: `gui/test/embed/stage_buttons_test.dart`, `gui/test/embed/input_dock_test.dart`

**Interfaces:**
- Consumes: `QuickToggle`, `QuickToggleLook` from Task 2.
- Produces: `StageButtons(quick: ...)`. `stackButtonCount` now returns voice + 输入 + 快捷区 + 还原.

- [ ] **Step 1: Write the failing tests**
  - In `stage_buttons_test.dart`:
    - `'quick sits between input and restore, fades and drags like input'`
      - Column: quick's bottom is input's top minus 12, and restore's bottom is quick's top minus 12.
      - Upright: same order outward, 12 apart.
      - `hidden: true` gives quick opacity 0.
    - Replace the line-213 `quick-handle` expectation with `quick-toggle-stack` findsOneWidget, and `quick-toggle` (box) findsNothing.
  - In `input_dock_test.dart`:
    - `'stackButtonCount counts the toggle'`: with voice and allowed, 3; zoomed, 4; not allowed and not zoomed, 0.
    - `'iOS: text folded — the toggle stands in the stack, 56 square, lit while the 快捷区 shows'`.
    - `'desktop: text folded — the toggle stands left of 输入 in the corner row, 8 apart'`.
    - `'text open — no stack toggle, the box one only'`.
    - `'no toggle where the composer is not allowed'`: an `allowComposer: false` session (or however `composerAllowed` is made false in this file's harness) finds neither key.
- [ ] **Step 2: Run and see them fail**
  - Run: `flutter test test/embed/stage_buttons_test.dart test/embed/input_dock_test.dart`
  - Expected: FAIL.
- [ ] **Step 3: Implement as listed under Files.**
- [ ] **Step 4: Run them again**
  - Run: the same command, plus the tidy-card placement tests (`grep -l _TidyLayer\|tidy test/embed`). They use `closedStackHeight(stackButtonCount(...))` and must follow the new count.
  - Expected: PASS.
- [ ] **Step 5: Commit** `feat(gui): with the text area folded the 快捷区 toggle stands beside 输入`

### Task 4: Remove the round handle

**Files:**
- Modify: `gui/lib/embed/composer_float.dart`
  - Delete `quickHandleSize` and `_handleGap`.
  - Delete the `handle` param and its doc.
  - Delete `LayoutId(id: _handle…)` and the `_handle` id.
  - Delete `_Place.hasHandle`, its placement branch and its `shouldRelayout` term.
- Modify: `gui/lib/embed/input_dock.dart`
  - Delete `handle:`.
  - Delete the `QuickHandle` class (lines 303–334).
  - Delete `quickHandleSize` from the import.
  - Fix the class doc's last sentence: with both folded, nothing stands where the block was, and the toggle is in the stack.
- Modify: `gui/lib/embed/composer_panel.dart`: the `_TidyLayer` doc changes "(only the handle)" to "(both folded)".
- Test: `gui/test/embed/composer_float_test.dart`, `gui/test/embed/input_dock_test.dart`

**Interfaces:**
- Produces: `FloatingComposer` without `handle`. No other signature changes.

- [ ] **Step 1: Update the tests**
  - In `composer_float_test.dart`, delete the handle tests (about lines 265–400: every test passing `handle:`).
  - In `input_dock_test.dart`:
    - Rewrite 「Safari: only quick-handle…」 as `'Safari, both folded: no block, the stack toggle brings the KeyBar back'`. Expect `find.byKey(Key('quick-handle'))` finds nothing. Tap `quick-toggle-stack`, and the KeyBar shows on the anchor.
    - Rewrite 「⊙ folds the quick area; the handle comes back…」 to fold with the box `quick-toggle`. Keep its assertion that the open text area falls to the anchor.
    - Drop the `quickHandleSize` import.
- [ ] **Step 2: Run and see them fail**
  - Run: `flutter test test/embed/input_dock_test.dart test/embed/composer_float_test.dart`
  - Expected: FAIL, because the `quick-handle` widget still shows.
- [ ] **Step 3: Delete as listed under Files.**
- [ ] **Step 4: Run them again**
  - Run: the same command, plus `flutter analyze`. Grep `gui/` for `QuickHandle|quick-handle|quickHandleSize|hasHandle`: there should be no hits.
  - Expected: PASS.
- [ ] **Step 5: Commit** `refactor(gui): the round 快捷区 handle goes; the toggle replaces it`

### Task 5: Whole suite, builds, checks list

**Files:**
- Modify: `tasks/todo.md`, adding real-machine checks under a 快捷区开关 heading:
  1. macOS: the native editor's text starts right of the toggle, and the caret and IME candidates sit right.
  2. Linux: same check for the Flutter editor.
  3. iPhone portrait: the box with three keys still gives the text a comfortable width.
  4. iPad and iPhone: with the text area folded, the stack toggle sits beside 输入, lit or unlit correctly, and the stack drags to the other side with it.
  5. Typing into the picture auto-folds, and the light goes out.
  6. Zoom 加1 and 加2: the three keys scale, and no scroller appears.
  7. The ＋ menu opens rightward from ＋ and stays on stage when the block is dragged to the left edge.

- [ ] **Step 1: Run the full suite**
  - Run: `cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
  - Expected: all tests pass and there are no issues.
- [ ] **Step 2: Build macOS and iOS**
  - macOS: `flutter build macos --debug`.
  - iOS: `flutter build ios --debug --no-codesign` (this branch touches iOS-visible UI).
  - Expected: both builds succeed.
- [ ] **Step 3: Check the macOS editor inset**
  - Launch the macOS debug app once, open the text area and screenshot it.
  - Expected: the placeholder 「写给 …」 starts 16 right of the toggle.
- [ ] **Step 4: Add the checks list to `tasks/todo.md`. Revert `gui/pubspec.lock`.**
- [ ] **Step 5: Commit** `docs(todo): real-machine checks for the 快捷区 toggle`
