# Text Terminal Follows the Console Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A console viewing a text terminal makes the host's Terminal window take the console's rows×columns (so every terminal shows at the same 14pt), and any scaling that remains is drawn by relaying out at the scaled font size instead of stretching.

**Architecture:** The console's existing `view` message gains `fit`. `rapp-term run` keeps a small actor state machine (`pty/fit.rs`): when the acting viewer's size should apply, it queues a size, and the thread that writes program output to the window emits `ESC[8;rows;colst` at a point where no escape sequence or UTF-8 character is open. The window's SIGWINCH then flows through the existing `resize()`. In the GUI, `TermStage` stops using `canvas.scale` and instead measures metrics at `14 × scale`, and in fit mode it never scales up.

**Tech Stack:** Rust (tokio, alacritty_terminal, portable-pty), Flutter/Dart.

**Spec:** `docs/superpowers/specs/2026-11-17-rapp-term-fit-design.md`

## Global Constraints

- Work in worktree `.claude/worktrees/term-fit`, branch `feat/term-fit`. Never commit to `main` or push.
- Window resize sequence: `ESC [ 8 ; <rows> ; <cols> t`. Floor 20 columns, 5 rows (`MIN_COLS = 20`, `MIN_ROWS = 5`).
- Handover: another viewer takes over only after the actor has made no operation for 2 s (`HANDOVER = 2s`).
- Operations: `keys`, `type`, the last chunk of a paste (`PasteStep::Ready`), a `view` turning `fit` from false to true. Not operations: `ack`, `history`, any other `view`.
- `fit` on the wire: `#[serde(default)]` (missing = false). The GUI always sends it.
- Menu copy exactly `跟着我的窗口`; pref key `term_fit`, default `true`.
- Base font size stays 14 (`termTextStyle`). No Z3 font steps.
- Rust tests: `cd rust && cargo test -p rapp-term`. Flutter: `~/development/flutter/bin/flutter test` and `flutter analyze` in `gui/`; afterwards `git checkout gui/pubspec.lock` if it changed.
- No protocol version bump. `rust/service/src/term.rs` splices the view lines verbatim, so nothing to change there.

## Review Focus

1. Heavy program output with an escape sequence split across two reads, exactly when a resize is pending: the resize waits for the sequence to close, and the window's byte stream is never corrupted (Task 2 test `resize_waits_for_an_open_sequence`).
2. A CJK character split across two reads while a resize is pending: the sequence is not inserted inside the UTF-8 character (Task 2 test `resize_waits_for_a_split_utf8_char`).
3. Mixed versions: an old GUI sends `view` without `fit`, so nothing is written to the window; an old `run` gets `fit` and ignores it (Task 3 test `a_view_without_fit_never_resizes_the_window`).
4. The host user resizes by hand, then the acting console keeps typing: the window is not pulled back (Task 1 test `typing_by_the_actor_does_not_rewrite`).
5. A stage squeezed to zero or near zero in fit mode: no divide-by-zero or infinite pointer math, and the host never gets below 20×5 (Task 1 test `sizes_are_floored`, Task 7 test `a stage squeezed to nothing in fit mode keeps size 14 and does not throw`).

---

### Task 1: The actor state machine (`pty/fit.rs`, part 1)

**Files:**
- Create: `rust/term/src/pty/fit.rs`
- Modify: `rust/term/src/pty/mod.rs` (add `pub mod fit;`)

**Interfaces:**
- Produces:
  - `pub type Conn = u64;`
  - `pub const MIN_COLS: u16 = 20; pub const MIN_ROWS: u16 = 5; pub const HANDOVER: Duration = Duration::from_secs(2);`
  - `#[derive(Default)] pub struct Fit`
  - `impl Fit`:
    - `pub fn join(&mut self) -> Conn`
    - `pub fn view(&mut self, c: Conn, fit: bool, cols: u16, rows: u16, now: Instant)`
    - `pub fn input(&mut self, c: Conn, now: Instant)`
    - `pub fn leave(&mut self, c: Conn)`
    - `pub fn take(&mut self) -> Option<(u16, u16)>` returns `(cols, rows)`, already floored

Rules. The implementer writes the body; these rules determine it.
- Each conn has an optional `Want { fit, cols, rows }`, from its last `view`.
- **Operation** `op(c, now)`:
  - If `actor == Some(c)`, set `last_op = now`.
  - Otherwise, if there is no actor, or the actor's `last_op` is `None`, or `now - last_op >= HANDOVER`: set `actor = c`, `last_op = now`, and `request()`.
  - Otherwise ignore it.
- **`request()`:** if the actor's `Want` exists and `fit` is true, `pending = Some((cols.max(MIN_COLS), rows.max(MIN_ROWS)))`.
- **`view(c, fit, cols, rows, now)`:**
  - Store the new `Want`, keeping the old one.
  - If the old one existed with `fit == false` and the new `fit` is true, that is an operation: `op`, then `request()` when `actor == Some(c)`.
  - Else, if there is no actor and `fit` is true: `actor = c`, `last_op = None`, `request()`.
  - Else, if `actor == Some(c)`, `fit` is true, and `(cols, rows)` differ from the old `Want`: `request()`.
- **`input(c, now)`** is `op`.
- **`leave(c)`** removes the `Want`. If `c` was the actor: `actor = None`, `last_op = None`.
- **`take`** is `pending.take()`.

- [ ] **Step 1: Write the failing tests** in `#[cfg(test)] mod tests` in `fit.rs`. Use `let t0 = Instant::now();` and `t0 + Duration::from_millis(n)` as the clock.
  - `the_first_fit_view_takes_over`: `a = join()`, then `view(a, true, 100, 30, t0)`, then `take() == Some((100, 30))`; a second `take() == None`.
  - `a_fit_false_view_never_requests`: `view(a, false, 100, 30, t0)`, then `input(a, t0)`, then `take() == None`.
  - `a_second_viewer_opening_does_not_take_over`: A views `100×30`, then `take()`. B views `true, 80×20`, then `take() == None`.
  - `handover_waits_for_two_idle_seconds`: A views and is taken, B views. `input(a, t0+0)`, then `input(b, t0+500ms)`, then `take() == None`. `input(b, t0+2000ms)`, then `take() == Some((80, 20))`. `input(b, t0+2100ms)`, then `take() == None`.
  - `typing_by_the_actor_does_not_rewrite`: A views and is taken. `input(a, ..)` three times; `take() == None` after each.
  - `the_actor_s_new_size_applies_but_a_bystander_s_does_not`: A is the actor, B is a viewer. `view(b, true, 90, 25, ..)`, then `take() == None`. `view(a, true, 110, 35, ..)`, then `take() == Some((110, 35))`.
  - `turning_fit_on_is_an_operation`: A is the actor with fit, B starts with `fit = false`, and A is idle more than 2 s. `view(b, true, 80, 20, t)`, then `take() == Some((80, 20))`.
  - `the_actor_leaving_frees_the_seat`: A is the actor. `leave(a)`, then `take() == None`. `view(b, true, 70, 20, ..)` (a repeat view with the same fit), then `take() == Some((70, 20))`.
  - `sizes_are_floored`: `view(a, true, 10, 3, t0)`, then `take() == Some((20, 5))`.
- [ ] **Step 2:** `cd rust && cargo test -p rapp-term fit::` must FAIL to compile (`Fit` is not defined).
- [ ] **Step 3: Implement** the `Fit` struct and its methods in `fit.rs` per the rules above, using `HashMap<Conn, Want>`. The module doc says what it is for and cites the spec §4.3.
- [ ] **Step 4:** `cargo test -p rapp-term fit::` must PASS. `cargo clippy -p rapp-term --tests` must be clean.
- [ ] **Step 5: Commit** `feat(term): the actor rules for a window that follows the console`.

### Task 2: Writing the resize into the window safely (`pty/fit.rs`, part 2)

**Files:**
- Modify: `rust/term/src/pty/fit.rs`

**Interfaces:**
- Consumes: `Fit::take` (Task 1).
- Produces:
  - `#[derive(Default)] pub struct SeqTracker` with `pub fn feed(&mut self, bytes: &[u8])` and `pub fn ground(&self) -> bool`.
  - `pub struct Window<W: Write>` with:
    - `pub fn new(out: W) -> Self`
    - `pub fn output(&mut self, bytes: &[u8]) -> std::io::Result<()>`: write all, flush, then feed the tracker
    - `pub fn resize_if_idle(&mut self, fit: &Mutex<Fit>) -> std::io::Result<bool>`: when `ground()` and `fit.take()` is `Some((c, r))`, write `format!("\x1b[8;{r};{c}t")`, flush, and return true. A poisoned lock uses `into_inner`, as elsewhere in `pty/`.
  - `#[cfg(test)] pub fn get_ref(&self) -> &W`

`SeqTracker` states:
- **Ground.** `ESC` goes to Esc. A UTF-8 lead byte goes to Utf8(n): `0xC0..=0xDF` gives n=1, `0xE0..=0xEF` n=2, `0xF0..=0xF7` n=3.
- **Utf8(n).** A continuation byte `0x80..=0xBF` decrements n, and n=0 returns to Ground. Any other byte is reprocessed as if in Ground.
- **Esc.** `[` goes to Csi. `]`, `P`, `X`, `^`, `_` go to Str. `0x20..=0x2F` stays in Esc. Anything else goes to Ground.
- **Csi.** `0x40..=0x7E` goes to Ground; anything else stays.
- **Str.** `BEL` goes to Ground; `ESC` goes to StrEsc.
- **StrEsc.** `\` goes to Ground; anything else goes back to Str.
- **Any state.** `CAN` (0x18) or `SUB` (0x1A) goes to Ground.

- [ ] **Step 1: Write the failing tests:**
  - `resize_is_written_at_once_when_idle`: `Window::new(Vec::new())`. `output(b"hi")`. Fit has pending `(100, 30)`. `resize_if_idle` returns true, and the bytes end with `b"\x1b[8;30;100t"`.
  - `resize_waits_for_an_open_sequence`: `output(b"a\x1b[3")`, then `resize_if_idle` is false and no `8;` is written. `output(b"1mX")`, then `resize_if_idle` is true, and the whole buffer equals `b"a\x1b[31mX\x1b[8;30;100t"`.
  - `resize_waits_for_a_split_utf8_char`: `"中"` is `E4 B8 AD`. Feed `E4 B8`, then the resize is not written. Feed `AD`, then it is written right after `AD`.
  - `an_osc_title_holds_the_resize_until_bel_or_st`: test `b"\x1b]0;t"` closed first by `\x07`, then by `\x1b\\`.
  - `nothing_pending_writes_nothing`.
- [ ] **Step 2:** `cargo test -p rapp-term fit::` must FAIL (`Window` is not defined).
- [ ] **Step 3: Implement** `SeqTracker` and `Window` per the state list above.
- [ ] **Step 4:** `cargo test -p rapp-term fit::` must PASS. Clippy must be clean.
- [ ] **Step 5: Commit** `feat(term): put the window resize between escape sequences`.

### Task 3: Wire it through `proto`, the viewer and `run`

**Files:**
- Modify: `rust/term/src/proto.rs` (`In::View` gets `#[serde(default)] fit: bool`; fix the test at the `matches!` near line 239 to use `..`).
- Modify: `rust/term/src/pty/mod.rs` (`Shared` gets `pub fit: Mutex<fit::Fit>`).
- Modify: `rust/term/src/pty/holder.rs`:
  - The `Shared` construction (around line 95) and the test helper (around line 416) get `fit: Mutex::default()`.
  - `pump_output` takes `window: &Mutex<fit::Window<W>>` instead of `mut window: impl Write`. After each chunk: `w.output(..)`, then `w.resize_if_idle(&shared.fit)`. Errors are ignored, as now.
  - Create `let window = Arc::new(Mutex::new(fit::Window::new(std::io::stdout())));` and share it with the pump thread.
  - The main loop's `tick` arm also calls `window.lock().resize_if_idle(&shared.fit)`, so a resize lands while output is quiet (TICK is 50 ms).
  - Update the module doc (line 8, "viewers never change the pty's size"): a viewer may ask the window to resize, and the pty follows the window.
- Modify: `rust/term/src/pty/view.rs`:
  - The `Shared` test helper (around line 319) gets `fit: Mutex::default()`.
  - `Counted` also holds `conn: Conn`: `new` calls `fit.join()` and `drop` calls `fit.leave(conn)`. `Viewer` gets `conn`.
  - In `handle`, after the pane check:
    - `In::View { fit, cols, rows, .. }` calls `shared.fit.lock().view(conn, fit, cols, rows, Instant::now())`.
    - After a `Keys` or `Type` was sent to the pty, and on `PasteStep::Ready` after the bytes went in, call `input(conn, Instant::now())`.
  - Replace the comment at line 263 ("the size is ignored") with what happens now.
- Test: `rust/term/tests/pty.rs`.

**Interfaces:**
- Consumes: `Fit`, `Window`, `Conn` (Tasks 1–2).
- Produces: the wire field `fit` on `{"t":"view"}`, which Task 4 sends.

- [ ] **Step 1: Write the failing integration tests** in `tests/pty.rs`, using the existing `Window::start`, `Viewer::connect` and `v.open()` helpers. `open()` sends a view without `fit`.
  - `a_view_without_fit_never_resizes_the_window`: open, wait 300 ms, then `w.output()` does not contain `"\x1b[8;"`.
  - `a_fit_view_resizes_the_window`: open, then send `{"t":"view","pane":"%0","cols":90,"rows":20,"fit":true}`, then `w.wait_output("\x1b[8;20;90t")`.
  - `typing_from_a_second_viewer_takes_over_after_two_seconds`:
    1. A sends a fit view `90×20`; wait for its sequence. Then A sends a `keys` message, so A has just operated (a seat taken by a view alone has no last operation, and anyone typing takes it at once).
    2. B opens and sends a fit view `70×15`, then a `keys` message right away. After 300 ms the output has no `"\x1b[8;15;70t"`.
    3. Sleep 2 s, then B sends `keys` again; `wait_output("\x1b[8;15;70t")`.

  Use `keys: ["a"]`, the same keys shape the existing tests send.
  - Also keep `a_viewer_cannot_change_the_size` passing: it sends `refit`, which must still be a bad message.
- [ ] **Step 2:** `cargo test -p rapp-term --test pty` must FAIL: no sequence is written.
- [ ] **Step 3: Implement** the changes in the file list above.
- [ ] **Step 4:** `cargo test -p rapp-term` (all of it) must PASS, and `cargo clippy -p rapp-term --tests` must be clean. If a pty test is load-flaky, rerun that test alone before judging it.
- [ ] **Step 5: Commit** `feat(term): a viewer with fit resizes the host window`.

### Task 4: The GUI sends `fit`

**Files:**
- Modify: `gui/lib/term/term_wire.dart:179`: `viewMsg(String? pane, int cols, int rows, {bool fit = false})` adds `'fit': fit`.
- Modify: `gui/lib/term/term_session_port.dart`:
  - `view(Object sid, int window, int cols, int rows, {bool fit = false})`.
  - The record type becomes `({String pane, int cols, int rows, bool fit})` in `_Term.view` and in `_sendView`, so dedupe includes `fit`.
  - Update the doc comment.
- Modify: `gui/test/fakes.dart:231`: `FakeTermSessionPort.view` gets the same named parameter and records `'fit': fit`.
- Test: `gui/test/term/term_wire_test.dart`, `gui/test/term/term_session_port_test.dart`.

**Interfaces:**
- Produces: `TermSessionPort.view(sid, window, cols, rows, {bool fit})`, used by Task 7.

- [ ] **Step 1: Write the failing tests:**
  - wire: `viewMsg('%0', 80, 24, fit: true)` equals `{'t':'view','pane':'%0','cols':80,'rows':24,'fit':true}`. The default gives `'fit': false`.
  - port, following the existing dedupe test near line 100: `view(1, 3, 80, 24, fit: true)` twice sends one message; then `view(1, 3, 80, 24)` (fit false) sends a second one, whose `fit` is false.
- [ ] **Step 2:** `flutter test test/term/term_wire_test.dart test/term/term_session_port_test.dart` must FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** The same tests must PASS, and `flutter analyze` must be clean.
- [ ] **Step 5: Commit** `feat(gui): the terminal view carries fit`.

### Task 5: The 「跟着我的窗口」 switch

**Files:**
- Modify: `gui/lib/ui/prefs.dart`: `bool termFit` (constructor default `true`), JSON `'term_fit'`, parsed as `v is bool ? v : true`, next to `termKeyRow`.
- Modify: `gui/lib/ui/main_state.dart` (next to `setTermKeyRow` at line 2783): `void setTermFit(bool v)`, which does the same as `setTermKeyRow`.
- Modify: `gui/lib/embed/stream_menu.dart`:
  - `StreamMenuAnchor` and `StreamMenu` get `final bool termFit` (default `true`) and `final ValueChanged<bool>? onTermFit`, passed through as `termKeyRow` is.
  - In the terminal group under `_head(t, '本机')`, add `_Item('跟着我的窗口', key: const Key('term-fit'), checked: widget.termFit, enabled: widget.onTermFit != null, onTap: () => _then(() => widget.onTermFit!(!widget.termFit)))` before the `按键排` item.
  - Line 7's comment: replace 「按我的屏幕重排」 with 「跟着我的窗口」.
- Modify: `gui/lib/ui/top_bar.dart:265`: pass `termFit: state.prefs.termFit, onTermFit: state.setTermFit`.
- Test: `gui/test/ui/prefs_test.dart`, `gui/test/term/term_key_row_test.dart` (or wherever the `term-key-row` menu item is tested; follow that test).

**Interfaces:**
- Produces: `UiPrefs.termFit`, `MainState.setTermFit(bool)`, used by Task 7.

- [ ] **Step 1: Write the failing tests:**
  - prefs: a missing `term_fit` reads as true; `false` round-trips.
  - menu: in a terminal session's traffic menu, `find.byKey(Key('term-fit'))` shows `跟着我的窗口` checked. Tapping it calls `onTermFit(false)`, and the popover closes as the `按键排` test expects.
- [ ] **Step 2:** The tests must FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** The tests must PASS, and `flutter analyze` must be clean.
- [ ] **Step 5: Commit** `feat(gui): 跟着我的窗口 in the terminal menu`.

### Task 6: Scaled drawing by relayout (approach C)

Behaviour stays "scale up and down to fit"; only how it is drawn changes.

**Files:**
- Modify: `gui/lib/term/term_layout.dart`: add `double gridScale({required double w, required double h, required double gridW, required double gridH, required bool up})`. It returns `min(w/gridW, h/gridH)`, capped at 1 when `!up`, and returns 1 when any of the four is ≤ 0.
- Modify: `gui/lib/term/term_stage.dart`:
  - `_metrics` stays the 14pt metrics, used for the cols/rows the stage asks for. Add `late TermMetrics _drawn`, cached by font size, and `_drawn = _metricsAt(14 * s)`, where `s = gridScale(..., up: true)` (this task keeps up-scaling).
  - `_metricsAt(size)` measures `termTextStyle(t).copyWith(fontSize: size)`. If `cols × cellW > w + 0.5` or `rows × cellH > h + 0.5`, it measures once more at `size × min(w / (cols × cellW), h / (rows × cellH))`.
  - Pass `metrics: _drawn, scale: 1` to `TermPainter`.
  - `_cellAt` uses `_drawn` cells with no division by `_scale`. `_scroll` and the pan/fling code use `_drawn.cellH`.
  - Remove `_scale` if nothing uses it any more.
- Test: `gui/test/term/term_stage_test.dart`, `gui/test/term/term_layout_test.dart`.

**Interfaces:**
- Produces: `gridScale(...)` and the stage field `_drawn`, used by Task 7.

- [ ] **Step 1: Update and add tests:**
  - layout:
    - `gridScale(w: 400, h: 200, gridW: 100, gridH: 100, up: true) == 2`; with `up: false` it is `1`.
    - `gridScale(w: 50, h: 200, gridW: 100, gridH: 100, up: false) == 0.5`.
    - `gridScale(w: 0, ...) == 1`.
  - stage: the `cell()` helper uses `painter(t).metrics.cellW` and `.cellH` directly, with no `scale` factor.
    - `a small pane is scaled up to fill`: expect `painter(t).scale == 1`, `painter(t).metrics.style.fontSize` close to `56` (±1), and `10 × painter(t).metrics.cellW <= 40 × cw + 0.5`.
    - `a large pane is scaled down`: `fontSize < 14`, and the grid fits within `600×400` (+0.5).
    - The existing `selection maps to cells when scaled up` and `a stage squeezed to nothing mid-drag keeps scale 1 and does not throw` keep passing, with assertions changed to `fontSize` where they read `scale`.
- [ ] **Step 2:** The updated tests must FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** All of `flutter test test/term/` must PASS, including `term_painter_snap_test.dart` and `term_paint_perf_test.dart`. `flutter analyze` must be clean.
- [ ] **Step 5: Commit** `fix(gui): scaled terminals are laid out at the scaled size, not stretched`.

### Task 7: Fit mode on the stage

**Files:**
- Modify: `gui/lib/term/term_stage.dart`:
  - `_View` becomes `({int window, int cols, int rows, bool fit})`. `_queueView` takes `fit` from `widget.state.prefs.termFit`.
  - In `_flushView`, a view whose `fit` differs from `_sent.fit` goes out at once, like a first view; size changes still wait for `_viewPause`.
  - `_sendView` calls `port.view(..., fit: v.fit)`.
  - The scale is `gridScale(..., up: !widget.state.prefs.termFit)`. When it is 1 the pane draws at 14pt from the top left, and the rest of the stage is `_palette.bg`, which the existing `ColoredBox` already gives.
- Modify: `docs/superpowers/specs/2026-11-16-rapp-text-terminal-design.md` §6 and `docs/superpowers/specs/2026-11-16-rapp-term-entry-design.md` §2.6: add one line at the top of each section, `> 2026-11-17 起：勾着「跟着我的窗口」时被控端窗口跟着主控台走，见 2026-11-17-rapp-term-fit-design.md。`
- Test: `gui/test/term/term_stage_test.dart`.

**Interfaces:**
- Consumes: `UiPrefs.termFit` (Task 5), `port.view(..., fit:)` (Task 4), `gridScale` and `_drawn` (Task 6).

- [ ] **Step 1: Write and update tests:**
  - `the view asks with fit by default`: `views().first['fit'] == true`.
  - `turning fit off sends a view at once`: show; pump past 0.3 s; `state.setTermFit(false)`; `await show(t)` (pumpWidget again); `await t.pump()`. Without waiting 0.3 s, the last view's `fit` is false.
  - `fit on and the pane is the asked size draws at 14`: pane `40` cols × `n` rows, stage `40*cw` × `n*ch`; `fontSize == 14`.
  - `fit on and a smaller pane stays at 14`: pane 10 cols × 2 rows, stage `40*cw × 20*ch`; `fontSize == 14`.
  - `fit on and a larger pane is scaled down`: pane 200 × 60, stage 600 × 400; `fontSize < 14`.
  - `a stage squeezed to nothing in fit mode keeps size 14 and does not throw`: copy the existing squeeze test with the default prefs.
  - Existing up-scale tests (`a small pane is scaled up to fill`, `selection maps to cells when scaled up`): set `state.prefs.termFit = false` before `show`.
- [ ] **Step 2:** The new tests must FAIL.
- [ ] **Step 3: Implement**, including the two doc lines.
- [ ] **Step 4:** The whole `flutter test` must PASS, `flutter analyze` must be clean, and `cd rust && cargo test -p rapp-term` must still pass. Then `git checkout gui/pubspec.lock` if it changed.
- [ ] **Step 5: Commit** `feat(gui): the terminal stage follows its window by default`.

### After the tasks

- Whole-branch review. Then hand the branch name `feat/term-fit` to rapp-49 to merge (do not merge or push yourself).
- Real-machine checks 1–6 from the spec §8 go to the user.
