# Top-bar session switcher + icon-only menu buttons — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking the top bar's session block lists every open session grouped by device and switches on tap; the 本机/远程 menu buttons become icon-only (⋯ / ≡) and the panel button gets a sidebar icon.

**Architecture:** The list is a fourth `CornerPopover` corner (`Corner.sessions`), so it shares closing, scrim, mutual exclusion and the opaque float surface with 本机/远程/需要你. Rows are the side panel's session rows, extracted into a shared widget.

**Tech Stack:** Flutter (gui/), flutter_test. Flutter is at `~/development/flutter/bin` (not on PATH); revert `gui/pubspec.lock` after running tests.

**Spec:** `docs/superpowers/specs/2026-11-15-top-bar-session-switcher-design.md`

## Global Constraints

- Icons: 本机 `Icons.more_horiz`, 远程 `Icons.menu`, panel button `Icons.view_sidebar_outlined`.
- Menu buttons are 48 wide at every bar width; no 本机/远程 word on them. Tooltips and semantics labels unchanged.
- Border rule unchanged: 本机 `t.line` 1px, 远程 `t.accent` 1.5px, open → `t.text` with `raiseBox`.
- The list groups by device always (`Grouping.device`), whatever `state.grouping` is. No 常用 rows.
- Picking a row: `state.select(key)` and the list closes; the current project is not changed.
- All user-facing text Chinese; code and commits English. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Tapping the row of the session that is already current must still close the list (the key does not change, so `notifyListeners`' auto-close does not fire).
2. The last session ends while the list is open: the list closes and the block stops being a button; no empty popover left behind.
3. Narrow window (bar 320 wide): the left-aligned 340-wide popover must stay inside the window, not run off the right edge.
4. Opening the list while 本机/远程/需要你 is open switches to it in one tap (and the reverse), as the corners do among themselves.
5. Switching sessions from the list must not leave the old session's 本机/远程 menu open (already handled by the auto-close on key change; pin it).

---

### Task 1: Icon-only menu buttons and the panel icon

**Files:**
- Modify: `gui/lib/embed/stream_menu.dart` (`MenuCornerButton`, `menuButtonWidth`, `StreamMenuAnchor.compact`)
- Modify: `gui/lib/ui/top_bar.dart` (panel icon; `words`/`splitW`; `_menu(..., compact)` calls)
- Test: `gui/test/ui/top_bar_test.dart`, `gui/test/embed/stream_menu_test.dart`

**Interfaces:**
- Produces: `MenuCornerButton({required bool remote, required bool open, required VoidCallback onTap})` — `compact` removed; always 48 wide. `menuButtonWidth` deleted. `StreamMenuAnchor.compact` stays (the traffic label still uses it).

- [ ] **Step 1: Write the failing tests** in `top_bar_test.dart`, embedded group (the one with `FakeSessionPort`, bar width 1200 so `split` holds):

```dart
testWidgets('the 本机 and 远程 buttons are icons only, even in a wide bar', (tester) async {
  // pump TopBar at width 1200, openOrSwitch('111','Safari','Safari'), flush ×4, pump
  final local = find.byKey(const Key('session-menu'));
  final remote = find.byKey(const Key('remote-menu'));
  expect(find.descendant(of: local, matching: find.byIcon(Icons.more_horiz)), findsOneWidget);
  expect(find.descendant(of: remote, matching: find.byIcon(Icons.menu)), findsOneWidget);
  expect(find.descendant(of: local, matching: find.text('本机')), findsNothing);
  expect(find.descendant(of: remote, matching: find.text('远程')), findsNothing);
  expect(tester.getSize(local).width, 48);
  expect(tester.getSize(remote).width, 48);
  expect(find.byTooltip('本机菜单：会话、剪贴板、输入法'), findsOneWidget);
});
```

And in the top-level group: `'the panel button shows the sidebar icon'` — `find.descendant(of: find.byKey(Key('panel-button')), matching: find.byIcon(Icons.view_sidebar_outlined))` findsOneWidget; `find.byIcon(Icons.menu)` findsNothing (no session open, so no remote button).

- [ ] **Step 2: Run them, expect FAIL**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/top_bar_test.dart`
Expected: the two new tests fail (laptop/desktop icons, word shown, width 88).

- [ ] **Step 3: Implement**

`MenuCornerButton`: icon `remote ? Icons.menu : Icons.more_horiz`, no text, no ▾, width 48. In `TopBar`: panel icon swap; `splitW = embedded ? (term ? 1 : 2) * 48.0 : 0.0`; drop `words` and pass nothing for the buttons' compact. Fix `stream_menu_test.dart` call sites that pass `compact:` to `MenuCornerButton`.

- [ ] **Step 4: Run the whole suite, expect PASS**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`
Expected: `No issues found!`, `All tests passed!` (the width-fit loops at 300–600 must still pass). Then `git checkout -- pubspec.lock`.

- [ ] **Step 5: Commit** — `feat(gui): 本机 and 远程 menu buttons are icons only (⋯, ≡); the panel button shows a sidebar`

### Task 2: Session switcher list

**Files:**
- Create: `gui/lib/ui/session_row.dart` — `SessionRow` and `SessionGroupTitle`, moved from `sessions_tab.dart`'s `_SessionRow` / `_GroupTitle` unchanged.
- Modify: `gui/lib/ui/sessions_tab.dart` (use the shared widgets)
- Modify: `gui/lib/ui/main_state.dart:44` (`Corner.sessions`)
- Modify: `gui/lib/ui/corner_popover.dart` (alignment)
- Create: `gui/lib/ui/session_switcher.dart` — the list's content
- Modify: `gui/lib/ui/top_bar.dart` (session block becomes the anchor)
- Test: `gui/test/ui/top_bar_test.dart`

**Interfaces:**
- Consumes: `groupSessions(List<SessionEntry>, Grouping, {projects, first})`, `state.forcedRelay`, `state.embeds`, `state.currentKey`, `state.toggleCorner/closeCorner`.
- Produces:
  - `enum Corner { stream, needs, session, remote, sessions }`
  - `CornerPopover({..., bool alignLeft = false})` — false keeps today's right alignment exactly.
  - `SessionRow({required SessionEntry entry, bool forced = false, required bool selected, required bool byDevice, required bool embedded, required VoidCallback onTap})`, `SessionGroupTitle(String title, {Key? key, VoidCallback? onTap})`.
  - `SessionSwitcher({required MainState state})` — keys: block `Key('session-block')`, scrim `Key('sessions-scrim')`, rows `ValueKey('switch-${entry.key}')`.

- [ ] **Step 1: Write the failing tests** in `top_bar_test.dart` top-level group (two hosts: add `{'id': '222', 'name': 'studio'}` to that test's hosts emit, or emit a second `hosts` event before opening):

```dart
testWidgets('the session block lists open sessions by device and switches on tap', (tester) async {
  // open 111/Mail, 111/Safari, 222/Notes; select 111/Mail; bar inside an 800×600 Align(topLeft)
  await tester.tap(find.byKey(const Key('session-block')));
  await tester.pump();
  expect(s.corner, Corner.sessions);
  expect(find.byKey(const Key('sessions-scrim')), findsOneWidget);
  expect(find.text('mini'), findsOneWidget);    // group titles
  expect(find.text('studio'), findsOneWidget);
  expect(find.byKey(const ValueKey('switch-111/Mail')), findsOneWidget);
  expect(find.descendant(of: find.byKey(const ValueKey('switch-222/Notes')), matching: find.byType(StatusLamp)), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('switch-222/Notes')));
  await tester.pump();
  expect(s.currentKey, '222/Notes');
  expect(s.corner, isNull);
});

testWidgets('picking the current session just closes the list', ...);       // tap switch-111/Mail → corner null, key unchanged
testWidgets('the list groups by device even when the panel groups by app', ...); // s.setGrouping(Grouping.app) first; titles are device names
testWidgets('no session: the block is not a button', ...);                  // tap 'session-block' area → s.corner isNull; no Icons.arrow_drop_down in the block
testWidgets('the last session ending closes the open list', ...);           // open one, open list, emit {'event':'closed','sid':1} → corner null, no 'sessions-scrim'
testWidgets('the list fits a 320-wide window', ...);                        // bar 320 in a 320×600 view; open list; popover rect right ≤ 320 and left ≥ 0
```

And in the embedded group: `'opening the list closes 本机, and 本机 closes the list'` — tap `session-menu` → `Corner.session`; tap `session-block` → `Corner.sessions` in one tap; tap `session-menu` → `Corner.session`.

- [ ] **Step 2: Run them, expect FAIL** (`session-block` not found).

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/top_bar_test.dart`

- [ ] **Step 3: Extract `SessionRow` / `SessionGroupTitle`** into `session_row.dart`, switch `sessions_tab.dart` to them. Run `flutter test test/ui/` — all existing tests still pass.

- [ ] **Step 4: `CornerPopover.alignLeft`.** When true: `targetAnchor: Alignment.bottomLeft`, `followerAnchor: Alignment.topLeft`, width `min(340, screenWidth - 16)`, and shift left by `max(0, targetLeft + width - (screenWidth - 8))` so it never passes the right edge (`targetLeft` from the popover's own render box `localToGlobal(Offset.zero).dx` in `overlayChildBuilder`).

- [ ] **Step 5: `Corner.sessions` + `SessionSwitcher` + top bar.**
  - `SessionSwitcher`: `ListView(shrinkWrap: true, padding: EdgeInsets.all(10))` over `groupSessions(state.entries, Grouping.device, projects: state.projects)`; each group a `SessionGroupTitle(g.title)` then `SessionRow(byDevice: true, selected: e.key == state.currentKey, forced: state.forcedRelay(e.id), embedded: state.embeds, onTap: () { state.select(e.key); state.closeCorner(); })` with 6px bottom gap, keyed `ValueKey('switch-${e.key}')`.
  - Top bar: when `state.sessionCount > 0`, wrap the session block in `CornerPopover(open: state.corner == Corner.sessions, alignLeft: true, scrimKey: Key('sessions-scrim'), onClose: state.closeCorner, popover: SessionSwitcher(state: state), child: InkWell(key: Key('session-block'), onTap: () => state.toggleCorner(Corner.sessions), ...))`; add `Icons.arrow_drop_down` (size 18, `t.muted`) after the name column; when open, the block's decoration is `t.raiseBox(border: t.text)`. With no session, the block stays plain text and keyed `session-block` with no tap.
  - Closing on the last session: `open` is `state.corner == Corner.sessions && state.sessionCount > 0`, and `MainState` clears `corner == Corner.sessions` in `notifyListeners` when `_entries` is empty.
  - The block's `Semantics` keeps its label and adds `button: true` when tappable.
  - `sessionMax` must account for the ▾ (18) so the 300–600 width-fit tests still pass.

- [ ] **Step 6: Run the whole suite, expect PASS**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`
Expected: `No issues found!`, `All tests passed!`. Then `git checkout -- pubspec.lock`.

- [ ] **Step 7: Commit** — `feat(gui): the session block lists every open session by device and switches on tap`
