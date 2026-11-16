# Offline Freeze Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a session drops for a network reason, the stage keeps the live picture / terminal (frozen, no input to A), the writing panel stays usable with 发送 greyed, and a thin bar at the top says what is happening — instead of the full-stage `DisconnectedStage`.

**Architecture:** A `frozen` flag on `SessionRecord`, set in `MainState._disconnect` for network reasons and cleared when the reconnect's new session swaps in. `Stage` gets a new branch ahead of the `DisconnectedStage` branch that shows `Picture(frozen: true)` / `TermStage(frozen: true)` plus `composerLayer` plus a new `OfflineBar`. `ComposerPanel` asks `MainState.sendBlocked(sid)` before sending.

**Tech Stack:** Flutter (Dart), `flutter test`. Flutter is at `~/development/flutter/bin` (not on PATH); revert `gui/pubspec.lock` after test runs if it changed.

**Spec:** `docs/superpowers/specs/2026-11-16-rapp-offline-freeze-design.md`

## Global Constraints

- Network reasons = `autoReconnects(reason)` true (网络断了、连接超时、中继连不上、对方离线). Every other reason keeps today's `DisconnectedStage`, unchanged.
- While frozen nothing reaches A: no mouse, scroll, key, picture_focus, resize, composer_send, Return (R25).
- The stage widget must not be swapped on drop or on recovery (same `Picture` / `TermStage` / `ComposerPanel` elements) — no focus/caret/scroll jump.
- Draft text is never lost; carry-over on swap is the existing `ComposerModel.adoptFrom`.
- No queued sending. No 「结束会话」 on the bar. Detached sessions and sessions that never showed a frame keep today's behaviour.
- Type-to-compose (letters on the picture opening the panel) is not offered while frozen; the panel opens by 「输入」 or Ctrl+Enter.
- UI copy in Chinese; code comments English, project style (short doc comments citing the spec).

## Review Focus

- A network drop during a **live move** (reroute, `lastSid != null` while live): the frozen flag must only come from `_disconnect`, never from `lastSid` alone — a move keeps sending. (Task 1: by construction, checked in review.)
- A reconnect that fails again with a **non-network** reason (bad password, taken over): unfreezes and shows `DisconnectedStage`. (Task 1 test.)
- The **stage resizing** while frozen (window drag, panel toggle) sends no `resize`. (Task 2 test.)
- **Enter / 直接回车** in the panel while frozen sends neither `composer_send` nor a Return `key`, and the text stays. (Task 4 test.)
- **Recovery**: the frozen draft shows up in the new session's panel and 发送 is live again. (Task 4 test.)

---

### Task 1: The frozen flag, `sendBlocked`, and the bar's words

**Files:**
- Modify: `gui/lib/ui/lifecycle.dart` (`SessionRecord`; new `offlineWords`)
- Modify: `gui/lib/ui/main_state.dart` (`_disconnect` ~L1092, `_swapIfReady` ~L1361, new `sendBlocked`)
- Test: `gui/test/ui/lifecycle_test.dart`, `gui/test/ui/stage_test.dart` (the embedded group: it has `shown`, `port`, `es`, `t`)

**Interfaces:**
- Produces: `SessionRecord.frozen` (`bool`, default false); `bool MainState.sendBlocked(Object sid)`; `String offlineWords(SessionRecord r, {String? waiting})` in `lifecycle.dart`.

- [ ] **Step 1: Write the failing tests**

`lifecycle_test.dart`:
```dart
test('offlineWords: reconnecting, waiting, retrying, stopped', () {
  final r = SessionRecord('111', 'Safari', 'Safari', 'lan')..phase = Phase.disconnected..reason = 'connection closed';
  expect(offlineWords(r), '网络断了');
  r.retry = (1, DateTime(2026));
  expect(offlineWords(r), '网络断了，正在重连…');
  expect(offlineWords(r, waiting: '对方离线，上线后自动连'), '对方离线，上线后自动连');
  r.phase = Phase.connecting;
  expect(offlineWords(r, waiting: 'x'), '正在重连…');
});
```

`stage_test.dart` (embedded group; each test starts with `await shown(tester);`):
- `'a network drop freezes the record; a user disconnect does not'`: emit `DisconnectedEvent(1, 'connection closed')` → `es.currentRecord!.frozen` true, `es.sendBlocked(1)` true, `es.sendBlocked(99)` false. Separate case with `'user'` → `frozen` false, `sendBlocked(1)` false.
- `'a frozen record stays frozen while it reconnects, and thaws on the swap'`: network drop; `t.onSend` answers `open` with sid 11 (copy the pattern of `'reconnect opened but not swapped…'`); `es.reconnectCurrent()`; flush → `frozen` true, `sendBlocked(1)` true, `sendBlocked(11)` false. Then `port.emit(const ReadyEvent(11, 'Safari'))`, `port.emit(WindowsEvent(11, [rw(5, 400, 328)]))` → `frozen` false, `lastSid` null, `sendBlocked(11)` false.
- `'a reconnect that fails for a non-network reason thaws'`: network drop; `t.onSend` answers `open` with `{'event': 'error', 'req': m['req'], 'error': 'bad password'}`; `es.reconnectCurrent()`; flush → `frozen` false, `phase` disconnected.
- No test for a move: `frozen = true` is written only in `_disconnect`, never derived from `lastSid`; the reviewer checks that by grep.

Stop any auto-retry at the end of tests that start one (`es.stopReconnectCurrent()`), as the existing network-failure tests do, if pending timers complain.

- [ ] **Step 2: Run, verify they fail**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/lifecycle_test.dart test/ui/stage_test.dart`
Expected: compile errors (`frozen`, `sendBlocked`, `offlineWords` undefined).

- [ ] **Step 3: Implement**

- `SessionRecord`: `bool frozen = false;` doc: "Down for a network reason: the stage keeps its picture, frozen, until the reconnect's new session swaps in (offline-freeze spec)."
- `offlineWords`: phase ≠ disconnected → `'正在重连…'`; else `waiting` if non-null; else retry ≠ null → `'${disconnectWord(r.reason)}，正在重连…'`; else `disconnectWord(r.reason)`.
- `_disconnect`: after `r.reason = …` set `r.frozen = autoReconnects(r.reason);` (the desktop-screen early return stays before it).
- `reconnect()` does not touch `frozen` (it nulls `reason`; that is why the flag is stored).
- `_swapIfReady`: where it sets `r.lastSid = null`, also `r.frozen = false`.
- `sendBlocked(sid)`: true iff some record has `frozen && (lastSid ?? sid) == sid`. Doc: "[sid] is what a frozen record keeps on the stage: its writing panel sends nothing (offline-freeze)."

- [ ] **Step 4: Run, verify pass** — same command; all pass, including the existing stage tests.

- [ ] **Step 5: Commit** — `feat(lifecycle): frozen flag for network drops, sendBlocked, offlineWords`

---

### Task 2: `OfflineBar` and the frozen app stage

**Files:**
- Create: `gui/lib/ui/offline_bar.dart`
- Modify: `gui/lib/embed/picture.dart` (`Picture` gets `frozen`)
- Modify: `gui/lib/ui/stage.dart` (new branch before the `DisconnectedStage` branch at ~L69; bar in the top `Column` at ~L195)
- Test: `gui/test/ui/stage_test.dart`

**Interfaces:**
- Consumes: Task 1's `frozen`, `offlineWords`.
- Produces: `OfflineBar({Key? key, required String text, VoidCallback? onStop, VoidCallback? onReconnect, bool reconnect = false})` — `onStop != null` shows 「停止」 (`Key('stop-reconnect-button')`); else `reconnect` true shows 「重连」 (`Key('reconnect-button')`, greyed when `onReconnect` null); else no button. Root `Key('offline-bar')`, text `Key('offline-text')`. `Picture({…, bool frozen = false})`. `Widget? offlineBarFor(MainState state, SessionRecord rec)` (private helper in `stage.dart` is fine) used by Task 3 too.

- [ ] **Step 1: Write the failing tests** (`shown(tester)` first, then `port.emit(const DisconnectedEvent(1, 'connection closed'))`, pump):
- `'a network drop keeps the picture with a bar, not the disconnected stage'`: `find.byType(DisconnectedStage)` nothing; `find.byType(Picture)` one; `tex42` one; `offline-text` text `'网络断了，正在重连…'`; `stop-reconnect-button` one; no `disconnected-end-button`. Tap 停止 → `es.currentRecord!.retry` null, bar shows `reconnect-button`.
- `'a frozen picture takes no input and never resizes'`: `port.calls.clear()`; tap the stage centre, send a scroll (`tester.sendEventToBinding(PointerScrollEvent(...))` as in `'wheel and trackpad scroll reach A'`), `tester.sendKeyEvent(LogicalKeyboardKey.keyA)`, resize the host via `tester.binding.setSurfaceSize` or by re-pumping with a different `SizedBox` → no `mouse`, `scroll`, `key`, `picture_focus`, `resize` in `port.calls`; `es.pictureFocused` null.
- `'the picture element survives the drop'`: `final before = tester.element(find.byType(Picture));` before the drop, then after → `identical(tester.element(find.byType(Picture)), before)`.
- `'a non-network drop still shows the disconnected stage'`: existing `'disconnected shows the last frame…'` covers `'user'`; add `'bad password'` → `DisconnectedStage` one, no `offline-bar`.
- `'a frozen record without a frame falls back to the disconnected stage'`: the existing `'a first-open network failure waits with stop instead of reconnect'` must still pass unchanged.

- [ ] **Step 2: Run, verify fail** — `flutter test test/ui/stage_test.dart`.

- [ ] **Step 3: Implement**
- `OfflineBar`: one row, same weight as the lock banner (`t.floatBox()` or a `Material` strip with tokens), `StatusLamp(Lamp.disconnected)` or `Lamp.connecting` while `connecting`, text, the button. Fits at 360 px (text ellipsizes).
- `Picture.frozen`: when true, no event reaches `state.port` — wrap the pointer layer so nothing is sent (`IgnorePointer` around the `Listener`s is enough), `Focus(canRequestFocus: !frozen, …)`, `onKeyEvent` ignored when frozen. Popups still draw.
- `Stage`: new branch `rec != null && rec.frozen && rs != null && !rs.detached && win != null && termPort?.owns(rs.sid) != true` → `picture = true; body = Picture(state: state, session: rs, window: win, frozen: true);`. The `win` loop above already runs on `rs.ready`. The composer layer condition at ~L190 (`picture || detached`) then already holds. Add the bar to the top `Column` (with the lock banner, bar first). Bar built by the helper: text `offlineWords(rec, waiting: state.waitWordOf(rec))`; `onStop: rec.retry != null ? state.stopReconnectCurrent : null`; `reconnect: rec.phase == Phase.disconnected`; `onReconnect: state.hubUsable ? state.reconnectCurrent : null`.

- [ ] **Step 4: Run, verify pass** — `flutter test test/ui/stage_test.dart test/ui/main_window_test.dart`; then the whole suite `flutter test` (other files may assert `DisconnectedStage` after a network reason — update those assertions to the bar, and list them in the commit message).

- [ ] **Step 5: Commit** — `feat(stage): a network drop freezes the picture under a thin bar`

---

### Task 3: The frozen terminal stage

**Files:**
- Modify: `gui/lib/term/term_stage.dart` (`TermStage` gets `frozen`; `_canInput` ~L560)
- Modify: `gui/lib/ui/stage.dart` (the terminal branch; bar in the terminal `Stack` at ~L180)
- Test: `gui/test/term/term_main_test.dart` (has `openTerm`, `term`, `window()`)

**Interfaces:**
- Consumes: Task 2's bar helper.
- Produces: `TermStage({…, bool frozen = false})`.

- [ ] **Step 1: Write the failing tests** (`openTerm(tester, two)`, then `term.play(const DisconnectedEvent(1, 'connection closed'))`, `settle`):
- `'a network drop keeps the terminal on the stage with a bar'`: `TermStage` one, `DisconnectedStage` nothing, `offline-bar` one, `composer-open` (「输入」) one.
- `'a frozen terminal sends no keys, text or paste, but still copies'`: `term.calls.clear()`; tap the stage, `sendKeyEvent(LogicalKeyboardKey.keyA)`, `sendKeyEvent(LogicalKeyboardKey.enter)` → no `keys` / `type` / `paste` in `term.calls`. Copy: select by drag as in `term_select_test`/`term_stage_test`, ⌘C → clipboard has the text (mock `SystemChannels.platform` as those tests do).
- `'the frozen terminal element survives the drop and the reconnect swaps in a live one'`: element identical across the drop; then the reconnect steps of `'a reconnected terminal takes the stage again and is viewed'` → `offline-bar` gone, `TermStage.frozen` false, `view` sent for sid 2.
- The existing `'a reconnected terminal takes the stage again…'` uses `'session ended'` (not a network reason): it must still pass unchanged.

- [ ] **Step 2: Run, verify fail** — `flutter test test/term/term_main_test.dart`.

- [ ] **Step 3: Implement**
- `TermStage.frozen`: `_canInput` false when frozen (keys fall through as for a dead pane; copy runs before that check, keep it so). Pointer-down still takes focus and selects. `_sendView` / `fetchHistory` need no gate (the real port drops them on a disconnected link, N4).
- `Stage`: the terminal branch condition becomes `rs != null && termPort?.owns(rs.sid) == true && ((rec?.phase == Phase.live && rec?.lastSid == null) || (rec?.frozen == true && !rs.detached))`, passing `frozen: rec?.frozen == true`. In the terminal return `Stack`, add `Positioned(top: 0, left: 0, right: 0, child: bar)` when the bar is non-null.
- `MainState._focusNewTerm` stays live-only (a frozen terminal is not given focus on its own).

- [ ] **Step 4: Run, verify pass** — `flutter test test/term test/ui`.

- [ ] **Step 5: Commit** — `feat(term): a network drop freezes the terminal under the bar`

---

### Task 4: Writing panel — usable, but 发送 is grey while frozen

**Files:**
- Modify: `gui/lib/embed/composer_panel.dart` (`_submit` ~L236, `_retry` ~L248, send button ~L512, 重试 button ~L376)
- Test: `gui/test/ui/stage_test.dart` (end-to-end through `Stage`, so the real `sendBlocked` is used; pass `composerEditor: FlutterEditor.new` to `Stage` and reuse the field finder used in `composer_panel_test.dart`)

**Interfaces:**
- Consumes: `MainState.sendBlocked(Object sid)` (Task 1).

- [ ] **Step 1: Write the failing tests** (`shown(tester)`, open the panel: `es.currentRemote!.composer.open = true`, pump, `enterText` `'git push'`; then the network drop):
- `'a frozen panel keeps its text and greys 发送'`: `RappButton` at `composer-send` has `onPressed` null; the field still takes typing (`enterText` `'git push origin'` → text updated); `port.calls.clear()`; `sendKeyEvent(LogicalKeyboardKey.enter)` → no `composer_send`, no `key`; text still `'git push origin'`.
- `'直接回车 while frozen sends no Return'`: profile `afterSend: AfterSend.pressReturn`, empty field, Enter → no `key` call.
- `'the frozen draft comes back live after the swap'`: after the drop and typing, reconnect as in Task 1 (sid 11), `ReadyEvent(11)`, `WindowsEvent(11, …)`, pump → the panel's field shows `'git push origin'`, `composer-send` enabled, tap it → one `composer_send` for sid 11.
- A failed row while frozen: its 「重试」 `onPressed` null; 「放回输入框」 still works.

- [ ] **Step 2: Run, verify fail** — `flutter test test/ui/stage_test.dart`.

- [ ] **Step 3: Implement** — `final blocked = widget.state.sendBlocked(_s.sid);` read in `build`; send button `onPressed: _m.sending || blocked ? null : _submit`; 重试 likewise; `_submit` and `_retry` return at once when `sendBlocked` (Enter goes through `_submit`). Nothing else: the model's draft is untouched.

- [ ] **Step 4: Run, verify pass** — full suite: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`; expect no issues and all pass. `git checkout gui/pubspec.lock` if it changed.

- [ ] **Step 5: Commit** — `feat(composer): 发送 and 重试 grey while the session is frozen`

---

### Task 5: Real-machine checklist

**Files:**
- Modify: `docs/superpowers/specs/2026-11-16-rapp-offline-freeze-design.md` (append a `## 实机检查` section; do not touch `tasks/todo.md`, it has the user's uncommitted edits)

- [ ] **Step 1:** Add the real-machine checks: (1) Wi-Fi off during an app session: picture stays, bar says 网络断了，正在重连…, panel types, 发送 grey; Wi-Fi on: picture resumes, draft still there, 发送 works. (2) Same on a text terminal, plus select + ⌘C on the frozen screen. (3) 停止 on the bar → 重连 appears and works. (4) Take over from another device → today's 拿回来 stage, unchanged.
- [ ] **Step 2: Commit** — `docs(spec): offline freeze real-machine checks`
