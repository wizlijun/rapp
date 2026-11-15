# 写作面板浮动、可拖动 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In app-window sessions the writing panel floats over a still picture, is dragged by a grip on its top edge, and its place is remembered per app in `apps.json`; terminals are unchanged.

**Architecture:** A new `composerAt` field (an `InputPoint`, the panel's bottom-centre) on the app profile, written by a store setter on release. A new `FloatingComposer` widget lays the panel out with a `CustomSingleChildLayout` from that point, clamped into the stage, and owns the grip's drag. `composerLayer` uses it for non-terminal ports; `Stage` stops lifting the picture for app windows.

**Tech Stack:** Flutter/Dart (gui/), flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-15-rapp-floating-composer-design.md` (changes W4 of `docs/superpowers/specs/2026-11-14-rapp-composer-writing-panel-design.md`).

## Global Constraints

- Flutter: `~/development/flutter/bin/flutter`, run from `gui/`. After any test run: `git checkout pubspec.lock`.
- Git in this worktree: one plain git command per call (no `-C`, `&&`, `;`, pipes). Never push.
- Terminal sessions (`port is TermSessionPort`): lift, key row, bottom-centre panel, no grip — all exactly as today.
- JSON key `composerAt`, same shape as `input`: `{"x": 0.5, "bottom": 8}` or `{"x": 0.3, "top": 120}` (`InputPoint.toJson`/`fromJson`).
- Default (no `composerAt`): bottom centre, panel bottom edge 8 above the stage bottom — `InputPoint(0.5, 8, fromBottom: true)`.
- Margin to every stage edge: 8.
- Grip hit area at least 48×20, top edge centre; tooltip copy `拖动；双击回到底部居中`; semantics label `移动写作面板`; grab cursor on desktop.
- Written to `apps.json` once per release, never during the drag. Double-tap on the grip clears it (back to default).
- Settings copy: `写作面板位置：底部居中（默认）` / `写作面板位置：左起 30%，距底 8` (`距顶` when from the top; numbers rounded); button `回到默认`.
- The stage's size never changes; A is never resized (main-window spec §5 item 1).
- Logs never contain typed text.

## Review Focus

1. Window shrinks after a position near the right or top edge was saved → panel stays fully on stage; window grows back → panel returns to the saved place, and `apps.json` is not rewritten by the resize (Task 2 test `resize clamps without rewriting`).
2. Releasing a drag writes the profile, which rebuilds the session → the `ComposerPanel` must not remount: typed text and the editor's caret survive (Task 2 test `drag keeps text and caret`).
3. Dragging past an edge and then back → the panel moves back at once, no dead zone (Task 2 test `no dead zone past the edge`).
4. A session with an empty `appId` → dragging works for the drag, nothing is saved, no profile with an empty id is created (Task 1 test `placeComposer ignores an unknown app`).
5. Two sessions of different apps → each panel sits where its own app's `composerAt` says (Task 2 test `each app its own place`).

---

### Task 1: `composerAt` in the profile, store and MainState

**Files:**
- Modify: `gui/lib/embed/app_profile.dart` (`AppProfile`, `ResolvedProfile`, `resolveProfile`)
- Modify: `gui/lib/ui/app_profile_store.dart` (next to `setInputPoint`)
- Modify: `gui/lib/ui/main_state.dart` (next to `markInputAt` / `clearInputMark`, ~1721)
- Test: `gui/test/embed/app_profile_test.dart`, `gui/test/ui/app_profile_store_test.dart`, `gui/test/ui/main_state_test.dart`

**Interfaces:**
- Produces:
  - `AppProfile.composerAt: InputPoint?` (in constructor, `copy()`, `toJson` as `'composerAt'`, `fromJson` via `InputPoint.fromJson`).
  - `ResolvedProfile.composerAt: InputPoint?` (null = default), picked mine-over-builtin like `input`.
  - `const defaultComposerAt = InputPoint(0.5, 8, fromBottom: true);` in `app_profile.dart`.
  - `AppProfileStore.setComposerAt(String appId, String appName, InputPoint? p)` — `null` when there is no profile of mine or mine has no `composerAt` is a no-op (no profile created, no write).
  - `MainState.placeComposer(RemoteSession rs, InputPoint? p)` — no-op when `rs.appId.isEmpty`; else `profiles.setComposerAt(rs.appId, rs.appName, p)`.

- [ ] **Step 1: Write the failing tests**

`app_profile_test.dart`:
```dart
test('composerAt round-trips and resolves mine over built-in', () {
  final p = AppProfile.fromJson({'ids': ['a'], 'composerAt': {'x': 0.3, 'top': 120}})!;
  expect(p.composerAt, const InputPoint(0.3, 120));
  expect(p.toJson()['composerAt'], {'x': 0.3, 'top': 120});
  expect(p.copy().composerAt, p.composerAt);
  expect(AppProfile.fromJson({'ids': ['a'], 'composerAt': {'x': 2, 'top': 1}})!.composerAt, isNull);
  final b = AppProfile(ids: ['a'], composerAt: const InputPoint(0.5, 8, fromBottom: true));
  expect(resolveProfile('a', mine: [p], builtin: [b]).composerAt, const InputPoint(0.3, 120));
  expect(resolveProfile('a', mine: [], builtin: [b]).composerAt, b.composerAt);
  expect(resolveProfile('z', mine: [p], builtin: [b]).composerAt, isNull);
});
```
`app_profile_store_test.dart` (use the file's existing temp-dir setup):
```dart
test('setComposerAt writes once; clearing nothing creates nothing', () {
  // store over an empty temp dir
  store.setComposerAt('com.x', 'X', null);
  expect(store.mine, isEmpty);
  expect(File('$dir/apps.json').existsSync(), isFalse);
  store.setComposerAt('com.x', 'X', const InputPoint(0.3, 8, fromBottom: true));
  expect(store.resolve('com.x').composerAt, const InputPoint(0.3, 8, fromBottom: true));
  expect(jsonDecode(File('$dir/apps.json').readAsStringSync())['apps'][0]['composerAt'], {'x': 0.3, 'bottom': 8});
  store.setComposerAt('com.x', 'X', null);
  expect(store.resolve('com.x').composerAt, isNull);
});
```
`main_state_test.dart` (existing harness for a remote session):
```dart
test('placeComposer ignores an unknown app', () { /* rs with appId '' */
  state.placeComposer(rs, const InputPoint(0.2, 8, fromBottom: true));
  expect(state.profiles.mine, isEmpty);
});
test('placeComposer saves for the session\'s app and the session sees it', () {
  state.placeComposer(rs, const InputPoint(0.2, 8, fromBottom: true));
  expect(rs.profile.composerAt, const InputPoint(0.2, 8, fromBottom: true));
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `~/development/flutter/bin/flutter test test/embed/app_profile_test.dart test/ui/app_profile_store_test.dart test/ui/main_state_test.dart`
Expected: compile errors (`composerAt`, `setComposerAt`, `placeComposer` not defined).

- [ ] **Step 3: Implement the field, `defaultComposerAt`, `setComposerAt`, `placeComposer`** as in Interfaces.

- [ ] **Step 4: Run to verify they pass** (same command; all green). Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit**

```
git add lib/embed/app_profile.dart lib/ui/app_profile_store.dart lib/ui/main_state.dart test/embed/app_profile_test.dart test/ui/app_profile_store_test.dart test/ui/main_state_test.dart
git commit -m "feat(gui): composerAt in app profiles: where the writing panel sits"
```

---

### Task 2: FloatingComposer — placement, grip, drag; no picture lift for app windows

**Files:**
- Create: `gui/lib/embed/composer_float.dart`
- Modify: `gui/lib/embed/composer_panel.dart` (`composerLayer`, ~460: non-terminal branch)
- Modify: `gui/lib/ui/stage.dart` (drop `if (picture && rs != null) stage = _lifted(rs, stage);` ~187; `_lifted`'s doc says terminal only)
- Test: create `gui/test/embed/composer_float_test.dart`; modify `gui/test/embed/composer_panel_test.dart` `group('stage')` lift tests (~800–885); `gui/test/term/term_composer_test.dart` (one assertion)

**Interfaces:**
- Consumes: `defaultComposerAt`, `ResolvedProfile.composerAt` (via `session.profile`), `MainState.placeComposer`, `ComposerModel.wantFocus()`, `panelWidth`.
- Produces (in `composer_float.dart`):
  - `const composerMargin = 8.0;`
  - `Offset composerTopLeft(InputPoint at, Size stage, Size panel)` — pure. Bottom-centre from `at.inContent(stage)`; left clamped to `[8, stage.width - 8 - panel.width]`, bottom clamped to `[8 + panel.height, stage.height - 8]` (if a range is empty, the lower bound wins: left 8, top 8). Returns top-left.
  - `class FloatingComposer extends StatefulWidget { session, onPlace: ValueChanged<InputPoint?>, child }` — lays out `Column[grip, Flexible(child)]` at `composerTopLeft(_drag ?? session.profile.composerAt ?? defaultComposerAt, …)`, child width `panelWidth(stage.width)`, max height `stage.height - 16`. Grip: `Key('composer-grip')`, centred, ≥48×20, short horizontal bar painted in `t.line`, `Tooltip('拖动；双击回到底部居中')`, `Semantics(label: '移动写作面板')`, `MouseRegion(cursor: grab / grabbing while dragging)`. Pan start: `_drag` = the point now shown; update: move it, clamped so the panel stays on stage (read the panel's current size, e.g. via a key); end: `onPlace(InputPoint.at(shownBottomCentre, stage))`, clear `_drag`, `session.composer.wantFocus()`. Double-tap: `onPlace(null)`, `wantFocus()`.
  - In `composerLayer`, the non-terminal open branch becomes `FloatingComposer(session: session, onPlace: (p) => state.placeComposer(session, p), child: ComposerPanel(key: ValueKey(session.sid), …, maxHeight: c.maxHeight / 2))`. The terminal branch is untouched.

- [ ] **Step 1: Write the failing tests**

`composer_float_test.dart` — pure placement:
```dart
const stage = Size(800, 600), panel = Size(720, 70);
test('default: bottom centre, 8 up', () =>
    expect(composerTopLeft(defaultComposerAt, stage, panel), const Offset(40, 522)));
test('clamped to 8 from every edge', () {
  expect(composerTopLeft(const InputPoint(1, 0, fromBottom: true), stage, panel), const Offset(72, 522));
  expect(composerTopLeft(const InputPoint(0.5, 0), stage, panel), const Offset(40, 8));
});
test('resize clamps without rewriting', () {
  const at = InputPoint(0.9, 8, fromBottom: true);
  // centre 666 → left 306, clamped to 740 − 8 − 720 = 12; bottom 292 → top 222
  expect(composerTopLeft(at, const Size(740, 300), const Size(720, 70)), const Offset(12, 222));
  // the same point on the big stage: centre 720 → left 520, clamped to 800 − 8 − 400 = 392
  expect(composerTopLeft(at, stage, const Size(400, 70)), const Offset(392, 522));
});
```

`composer_panel_test.dart` `group('stage')` — replace the five lift tests (`opening lifts the picture 64…`, `growing does not move…`, `the lift moves over…`, `reduced motion lifts…`, `a click on the lifted picture…`) with:
```dart
testWidgets('opening, growing and closing never move the picture; A is never resized', ...);
  // y0 == top(tester) after open, after setDraft(10 lines), after Esc; no 'resize' calls
testWidgets('a click on the picture with the panel open lands as with it closed', ...);
  // same x/y in the 'mouse' down call, seen.dy == 300
testWidgets('the panel starts bottom centre, 8 up', ...);
  // rect('composer-panel').bottom == 600 - 8 (panel below the grip), centre dx == 400
testWidgets('dragging the grip moves the panel and saves once on release', ...);
  // count es.profiles notifications: 0 during three moves, 1 after up;
  // es.profiles.resolve('Safari').composerAt == InputPoint.at(newBottomCentre, Size(800, 600))
testWidgets('double-tap on the grip goes back to default', ...);
testWidgets('drag keeps text and caret', ...);
  // enterText 'keep'; drag; text(tester) == 'keep'; fieldFocused(tester) isTrue
testWidgets('no dead zone past the edge', ...);
  // drag right by +2000 then −100 in one gesture: panel moved left by 100 from the clamped place
testWidgets('each app its own place', ...);
  // composerAt set for 'Safari' only; second session of another app sits at default
testWidgets('the panel grows upward; its bottom stays', ...);
  // bottom before and after setDraft(10 lines) equal
```
Keep `no lift over a detached placeholder` (it still holds). `term_composer_test.dart`: in the existing lift test add `expect(find.byKey(const Key('composer-grip')), findsNothing);`.

- [ ] **Step 2: Run to verify they fail**

Run: `~/development/flutter/bin/flutter test test/embed/composer_float_test.dart test/embed/composer_panel_test.dart test/term`
Expected: compile error in `composer_float_test.dart`; the new stage tests fail (picture moves 64, no grip).

- [ ] **Step 3: Implement `composer_float.dart`, wire `composerLayer`, drop the app-window lift in `stage.dart`.**

- [ ] **Step 4: Run to verify they pass**

Run: `~/development/flutter/bin/flutter test test/embed test/term test/ui/stage_test.dart`
Expected: all green; terminal lift and key-row tests unchanged and passing. Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit**

```
git add lib/embed/composer_float.dart lib/embed/composer_panel.dart lib/ui/stage.dart test/embed/composer_float_test.dart test/embed/composer_panel_test.dart test/term/term_composer_test.dart
git commit -m "feat(gui): the writing panel floats over app windows; drag its grip, the place is the app's"
```

---

### Task 3: 「＋」 menu opens downward near the top

**Files:**
- Modify: `gui/lib/embed/composer_plus.dart` (`_toggle`, `_menu` ~215)
- Test: `gui/test/embed/composer_panel_test.dart` `group('plus menu and hint line')`

**Interfaces:**
- Consumes: nothing new.
- Produces: at open time the menu decides its side once: if the 「＋」 button's top (in the overlay's coordinates) is in the overlay's upper half, `targetAnchor: Alignment.bottomRight, followerAnchor: Alignment.topRight, offset: Offset(0, 8)`; else today's (`topRight` / `bottomRight` / `Offset(0, -8)`).

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('plus menu opens up from a panel at the bottom', ...);
  // menu rect bottom <= plus button rect top
testWidgets('plus menu opens down from a panel near the top', ...);
  // composerAt InputPoint(0.5, 200) for the app; menu rect top >= plus button rect bottom; fully on stage
```

- [ ] **Step 2: Run to verify the second fails**

Run: `~/development/flutter/bin/flutter test test/embed/composer_panel_test.dart`
Expected: `opens down` fails (menu above the button, off stage).

- [ ] **Step 3: Implement the side choice in `composer_plus.dart`.**

- [ ] **Step 4: Run to verify they pass** (same command, then `flutter test test/term`); `git checkout pubspec.lock`.

- [ ] **Step 5: Commit**

```
git add lib/embed/composer_plus.dart test/embed/composer_panel_test.dart
git commit -m "feat(gui): the plus menu opens downward when the panel is near the top"
```

---

### Task 4: Settings page row and the docs

**Files:**
- Modify: `gui/lib/pages/app_profile_page.dart` (after the `input-point` row, ~357–368)
- Test: `gui/test/ui/app_profile_page_test.dart`
- Modify docs:
  - `docs/superpowers/specs/2026-11-14-rapp-composer-writing-panel-design.md`: W4 (~105) and the 「画面上移」 paragraph (~95): lift only for terminals, app windows float per the floating-composer spec; line 64 option B and line 80 likewise; §7 S0 item 4 add 「拖动时原生编辑区跟不跟得上」.
  - `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md`: §3.5 (~119) and §5 item 1 (~176): 「输入区打开时画面上移一行」 → terminals only.
  - `docs/superpowers/specs/2026-11-13-rapp-app-profiles-design.md`, `2026-11-13-rapp-app-profile-authoring.md`, `2026-11-13-rapp-config-reference.md`: add `composerAt` next to `input`, same shape, meaning (panel's bottom centre), default, written on release.

**Interfaces:**
- Consumes: `AppProfile.composerAt` on the page's draft `d`.
- Produces: row `Key('composer-at')` text per Global Constraints; button `Key('composer-at-clear')` label `回到默认`, shown only when `d.composerAt != null`, sets `d.composerAt = null` (saved with 保存 like the input-point 清除).

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('panel place row: default, then a saved place, then 回到默认', ...);
  // no composerAt → '写作面板位置：底部居中（默认）', no clear button
  // composerAt InputPoint(0.3, 8, fromBottom: true) → '写作面板位置：左起 30%，距底 8'
  // tap 'composer-at-clear', 保存 → store.resolve(id).composerAt isNull
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/development/flutter/bin/flutter test test/ui/app_profile_page_test.dart`
Expected: `composer-at` not found.

- [ ] **Step 3: Implement the row; edit the five docs.**

- [ ] **Step 4: Full suite**

Run: `~/development/flutter/bin/flutter analyze` then `~/development/flutter/bin/flutter test`
Expected: analyze clean; all tests pass. Then `git checkout pubspec.lock`.

- [ ] **Step 5: Commit**

```
git add lib/pages/app_profile_page.dart test/ui/app_profile_page_test.dart ../docs/superpowers/specs
git commit -m "feat(gui): app settings show and reset the writing panel's place; specs follow"
```
