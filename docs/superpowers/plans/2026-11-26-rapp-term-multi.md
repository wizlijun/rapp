# Multi Text Terminals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘T opens a new text terminal beside the focused one (same directory, same shell, same Terminal window); 「结束终端」/⌘W really ends a terminal and its host tab closes; host Terminal tabs read `<dir> · <prog>`.

**Architecture:** The holder (`rapp-term run`) learns the foreground program and directory once a second, rewrites the host window's title, answers a new local `end` op and leaves an `ended/<tty>` marker. `serve` gains `Req::End`, `Open.from`, a marker sweep that closes empty Terminal tabs, and two new TermRow fields. The wire grows `Op::EndTerm` and `OpenTerm.from`; the hub grows `end_term`. The GUI adds ⌘T/⌘W, the 「关闭」/「结束终端」 menu items and clean removal of ended terminals.

**Tech Stack:** Rust (tokio, portable_pty, libc), AppleScript via osascript, Flutter/Dart.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-term-multi-design.md` — read §4 in full before any task; it is the authority.

## Global Constraints

- client-core `VERSION` stays 16: no protocol bump. New features are gated on `TermRow.shell` being present (old devices send none).
- Window title format: `<dir> · <prog>` plus ` — <program title>` when the program set one; home → `~`; a dir over 32 chars keeps its last two levels as `…/a/b`.
- Title written only on change, at most once per second; written as `ESC ] 0 ; <title> BEL`; nothing written when stdout is not a tty.
- Program name: basename of `argv[0]`, leading `-` stripped (macOS `sysctl KERN_PROCARGS2`, Linux `/proc/<pid>/cmdline`), falling back to the process name.
- The source directory never leaves the device; `log_fields` records only whether `from` is present.
- Ended markers older than 10 min are deleted without closing; the close-tab osascript has a 5 s timeout; errors are only logged.
- Sweep 1.5 s after an `end` reply, at serve start and on each `ask_pty` round. macOS only.
- Copy (verbatim): 「关闭」, 「结束终端」, 「结束终端？」, 「里面还在跑 <fg>，结束后它也会被关掉。」, 「结束」/「取消」, 「已结束 <名字>」, 「这台设备没有可用的终端窗口」, 「这台设备的 rApp 太旧，不能结束终端」.
- Never take over terminals rapp did not open; the sweep only closes tabs whose tty matches a marker and that have no processes.
- Tests: `PATH=$HOME/.cargo/bin:$PATH cargo test --workspace --no-fail-fast` (protocol fields need testkit); flutter at `~/development/flutter/bin`; `git checkout gui/pubspec.lock` after flutter runs. `grep` is ugrep: use `/usr/bin/grep` or `git grep`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A program writing its title split across two output chunks (`ESC ]` at the end of one read, `0;x BEL` in the next): the window must still get exactly one rewritten title and no stray bytes. → Task 2 test `osc_split_across_chunks`.
2. ⌘T on a terminal whose directory was deleted meanwhile: it must still open, in the default directory. → Task 4 test `open_from_missing_cwd_falls_back`.
3. 「结束终端」 on a holder of an older version (answers `unsupported`): hint 「这台设备的 rApp 太旧，不能结束终端」, record untouched. → Task 6 test `end_term_old_holder_hint`.
4. A user's own Terminal tab sharing nothing with rapp: the sweep must never close it. Markers are named by tty and the tab must have no processes. → Task 4 test `sweep_only_targets_marked_ttys`.
5. Pressing ⌘T three times quickly: three terminals open, in order. → Task 6 test `new_term_from_queues`.

---

### Task 1: Foreground probe + status fields

**Files:**
- Create: `rust/term/src/pty/fg.rs`
- Modify: `rust/term/src/pty/mod.rs` (`pub mod fg;`, `Shared` gains `fg: Mutex<Fg>`, `Shared::status()`), `rust/term/src/pty/local.rs:96` (`Status`), `rust/term/src/pty/holder.rs` (1 s tick)

**Interfaces:**
- Produces:
  - `pub struct Fg { pub prog: Option<String>, pub cwd: Option<PathBuf>, pub shell: bool }` (Default: all none/false).
  - `pub fn prog_name(argv0: &str) -> String`: basename, leading `-` stripped.
  - `pub fn probe(pgrp: i32) -> (Option<String>, Option<PathBuf>)`: macOS sysctl/proc_pidinfo, Linux /proc.
  - `Fg::update(&mut self, pgrp: Option<i32>, child_pid: u32) -> bool`: true when anything changed. A failed read keeps the last value. `shell = pgrp == child_pid`.
  - New `Status` fields, all `#[serde(default, skip_serializing_if = ...)]`: `fg: Option<String>`, `cwd: Option<String>`, `shell: Option<bool>`, `tty: Option<String>`. `tty` comes from `ttyname(0)` once at holder start.
  - `Shared.fg` is read by Task 2 (title) and Task 4 (serve `from`).

- [ ] **Step 1: Failing tests in `fg.rs`.**
  - `prog_name_strips_dash_and_path`: `prog_name("-zsh") == "zsh"`, `prog_name("/usr/local/bin/claude") == "claude"`.
  - `probe_self_reads_cwd`: `probe(std::process::id() as i32).1 == Some(std::env::current_dir()?)`.
  - `probe_self_reads_prog`: the name is non-empty.
  - `update_keeps_last_on_failure`: `update(Some(i32::MAX), 1)` after a good update keeps `prog`/`cwd`.
  - `status_roundtrips_without_new_fields`: an old status JSON without the new fields deserializes, and the new ones are `None`.
- [ ] **Step 2: Run them and watch them fail.** `cargo test -p rapp-term fg::`
- [ ] **Step 3: Implement.**
  - Use `libc` (already a dependency; check `rust/term/Cargo.toml`): `sysctl([CTL_KERN, KERN_PROCARGS2, pid])`, skip the argc i32 and the exec path, then take the first argv string.
  - Use `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, …)` for `pvi_cdir.vip_path`.
  - Process-name fallback: `proc_name` on macOS, `/proc/<pid>/comm` on Linux.
  - In holder.rs, add a `tokio::time::interval(1s)` arm to the main `select!`. It calls `pair.master.process_group_leader()` and `shared.fg.lock().update(..)`. When `update` returns true, notify the title composer (Task 2) via a `watch::Sender<u64>` bump or a direct call: implementer's choice, documented in a comment.
- [ ] **Step 4: Run the tests and see them pass.** `cargo test -p rapp-term`
- [ ] **Step 5: Commit** `feat(term): holder knows the foreground program and directory`

### Task 2: Host window title rewriter

**Files:**
- Create: `rust/term/src/pty/wintitle.rs`
- Modify: `rust/term/src/pty/fit.rs` (`Window::output` passes bytes through the rewriter when `tty`), `rust/term/src/pty/holder.rs`

**Interfaces:**
- Consumes: `Fg` (Task 1), `title::clean`.
- Produces:
  - `pub struct OscStrip` with `fn feed(&mut self, bytes: &[u8], out: &mut Vec<u8>) -> Option<String>`. It copies `bytes` to `out` minus complete OSC 0/1/2 sequences, and returns the last program title seen (cleaned). It is stateful across chunks. It passes through, unchanged, a partial sequence that grows over 4096 bytes or is broken by a non-OSC byte. Other OSC numbers (7, 8, 7501…) pass untouched. Terminators: BEL or `ESC \`.
  - `pub fn compose(home: &Path, fg: &Fg, prog_title: Option<&str>) -> Option<String>`. It returns `None` when there is neither dir nor prog.
  - `pub fn short_dir(home: &Path, dir: &Path) -> String`.
  - `Window` gains `fn set_title(&mut self, t: &str)`, which writes `ESC ] 0 ; t BEL` only if it differs from the last written title and at least 1 s has passed. A pending one is flushed on the next tick.
- Rules (spec §4.2):
  - When `fg.shell` is true, the program title is dropped.
  - A program title equal to the prog name or to the short dir is dropped.
  - The emulator and `title.rs` keep getting the raw bytes. Only the window stream is stripped.

- [ ] **Step 1: Failing tests in `wintitle.rs`.**
  - `strips_osc0_bel` and `strips_osc2_st`: input `b"a\x1b]0;hi\x07b"` gives out `b"ab"` and returns `Some("hi")`.
  - `osc_split_across_chunks`: feed `b"a\x1b]"` then `b"2;x\x07b"`; the combined out is `b"ab"` and the title is `"x"`.
  - `keeps_osc7_and_8`: unchanged.
  - `overlong_passes_through`: a 5000-byte unterminated OSC 0 comes out byte for byte.
  - `short_dir_home_tilde`: `short_dir("/Users/u", "/Users/u/git/rapp") == "~/git/rapp"`.
  - `short_dir_long_keeps_two`: a 40-char path gives `"…/a/b"`.
  - `compose_shell_drops_title`: shell true, title `"zsh"` gives `"~/git · zsh"`.
  - `compose_with_title`: `"~/git · claude — Fix bug"`.
  - `compose_drops_title_equal_prog`.
- [ ] **Step 2: Run them and watch them fail.**
- [ ] **Step 3: Implement.**
  - Wire `OscStrip` into `Window::output` only when `tty`.
  - The holder recomputes `compose` on a Task 1 change, or at once when `feed` returns a new title, and calls `set_title`.
  - The home dir comes from `$HOME`, read once.
- [ ] **Step 4: Run** `cargo test -p rapp-term` **and see it pass.**
- [ ] **Step 5: Commit** `feat(term): host tab title shows directory and program`

### Task 3: Holder `end` op + ended marker

**Files:**
- Modify: `rust/term/src/pty/holder.rs` (`client()` op match, run loop), `rust/term/src/pty/local.rs` (new `pub async fn end(path, token) -> Result<(), Probe>` mirroring `rename`), `rust/term/src/pty/mod.rs` (`Shared` gains `end: Notify` or a `watch`)

**Interfaces:**
- Produces:
  - `local::end(path: &Path, token: &str) -> Result<(), Probe>`: `Ok` on `{"ok":true}`, and `Refused("unsupported")` from an old holder.
  - The holder answers `{"ok":true}` first, then runs the existing Signal(SIGHUP) path: SIGHUP the program, kill after `KILL_WAIT`, then `session ended`.
  - Marker: when the holder has a ticket and `isatty(1)`, on exit (any cause) it writes `<term dir>/ended/<basename of ttyname(0)>` containing the Unix seconds. This uses `local::ensure_dirs` plus the new `ended` dir. Write errors are ignored.

- [ ] **Step 1: Failing tests (holder test module, following the existing holder tests that spawn `run` with a short `--dir`).**
  - `end_op_answers_then_exits`: `local::end` returns Ok; the holder process exits within `KILL_WAIT + 2s`; a viewer gets `session ended`.
  - `end_op_kills_stubborn_child`: the child traps HUP (`sh -c 'trap "" HUP; sleep 100'`) and is still gone after `KILL_WAIT`.
  - `no_marker_without_tty`: the test run has no tty, so no `ended/` file appears.
- [ ] **Step 2: Watch them fail.**
- [ ] **Step 3: Implement.** Extract the marker filename as `fn marker_name(tty: &str) -> Option<String>` (basename, non-empty, no `/`) and unit-test it: `marker_name("/dev/ttys012") == Some("ttys012")`.
- [ ] **Step 4: Run** `cargo test -p rapp-term` **and see it pass.** (pty tests can flake under load: rerun a single failure once before you investigate.)
- [ ] **Step 5: Commit** `feat(term): holder end op and ended marker`

### Task 4: serve — End, Open.from, tab sweep, TermRow fields

**Files:**
- Modify:
  - `rust/term/src/serve.rs`: `Req`, `conn()` dispatch, `open()`, `ask_pty`, `status_rows`.
  - `rust/term/src/list.rs`: `TermRow` gains `fg: Option<String>` and `shell: Option<bool>`, both `skip_serializing_if none`.
  - `rust/term/src/pty/launch.rs`: `command_file` gains `cwd: Option<&Path>`; `TERMINAL_TAB` and `terminal_tab` gain a source tty arg; `open` gains `source_tty: Option<&str>`.
- Create: `rust/term/src/pty/sweep.rs` (marker sweep + `CLOSE_TABS` osascript)

**Interfaces:**
- Consumes: Task 1 `Status.fg/cwd/shell/tty`, Task 3 `local::end`.
- Produces:
  - `Req::End { term: String }`, answered `{"ok":true}` / `{"error": ...}`. Errors: `BAD_ID`, `NO_TEXT_TERMINAL`, `OLD_RUN` for `unsupported`.
  - `Req::Open { shell, app, from: Option<String> }` (`#[serde(default)]`).
  - `open(shell, app, from)`:
    - If `from` names a live session with `cwd` that `is_dir()`, add `--cwd`.
    - If no `shell` was given and the source `command` matches an installed shell's path, use it.
    - Pass the source `tty` to `launch::open`.
  - `TERMINAL_TAB` argv:
    - item 3 is the source tty, `""` for none.
    - When it is non-empty, first look for a window whose tab `tty` equals it.
    - Otherwise use the existing `processes contains marker` rule.
  - `sweep::sweep(dir: &Path, close: impl Fn(&[String]))`:
    - reads `dir/ended/*`;
    - deletes each marker;
    - passes the ttys of markers ≤ 10 min old to `close`.
  - The real `close` runs one osascript (5 s timeout via `bounded_command`) that closes Terminal tabs whose `tty` is in the list and whose `processes` is empty and `busy` is false.
  - It runs at `Worker::new` (spawned, off the runtime), on each `ask_pty` round and 1.5 s after an `End` reply. All three are macOS only, and are skipped when `launch_with` is set (tests).

- [ ] **Step 1: Failing tests (serve.rs test module and `sweep.rs`).**
  - `end_unknown_term_is_no_such`.
  - `end_reaches_holder`: a live holder in a temp dir; `Req::End` gets ok; the session leaves the list.
  - `open_passes_cwd_from_source`: use the `launch_with` fake launcher that records the `.command` body; the body contains `--cwd '<dir>'`.
  - `open_from_missing_cwd_falls_back`: source cwd deleted; no `--cwd`; still opens.
  - `open_from_uses_source_shell`.
  - `sweep_only_targets_marked_ttys`: the markers `ttys001` (fresh) and `ttys002` (mtime 11 min ago, set with `filetime` or `File::set_modified`) give `close` called with `["ttys001"]`; both files are gone.
  - `rows_carry_fg_and_shell`.
  - `command_file_with_cwd`: an exact string assert.
- [ ] **Step 2: Watch them fail.**
- [ ] **Step 3: Implement.** The CLOSE_TABS script, for the implementer to finish and verify by compiling with `osacompile` in a test (the existing pattern at launch.rs:397):

```applescript
on run argv
	if not (application "Terminal" is running) then return
	tell application "Terminal"
		repeat with w in windows
			repeat with t in tabs of w
				try
					if (argv contains (tty of t)) and (busy of t is false) and ((count of processes of t) is 0) then close t
				end try
			end repeat
		end repeat
	end tell
end run
```

  Pass the ttys as full `/dev/ttysNNN` paths: markers keep the basename, and the sweep prefixes `/dev/`.
- [ ] **Step 4: Run** `cargo test -p rapp-term` **and see it pass.**
- [ ] **Step 5: Commit** `feat(term): serve ends terminals, opens beside a source, closes ended tabs`

### Task 5: Wire, service, hub

**Files:**
- Modify:
  - `rust/net/src/msg.rs`: `Op::EndTerm { term: String }`; `OpenTerm` gains `#[serde(default, skip_serializing_if = "Option::is_none")] from: Option<String>`.
  - `rust/service/src/term.rs`: `request` forwards `{"op":"end","term":..}`; `open` forwards `from`; `log_fields` gives `end_term` and `{"op":"open_term","app":app,"from":bool}`.
  - `rust/service/src/peer.rs:221` allow-list.
  - `rust/service/src/relay_link.rs:368` if it is relevant (EndTerm is no session: leave it out, and say so in a comment).
  - `rust/hub/src/lib.rs:433` `"end_term"`.
  - `rust/hub/src/terms.rs` `event`: `Op::EndTerm{term}` gives `{"event":"term_ended","id":id,"term":term}`.
  - testkit: `rust/testkit/tests/term.rs` and `hub_terms.rs`, plus any assertions a new field breaks.

**Interfaces:**
- Produces: hub command `{"cmd":"end_term","id":..,"term":..}` answered with event `term_ended`; `open_term` accepts `from`.

- [ ] **Step 1: Failing tests.**
  - msg.rs `end_term_roundtrip`, `open_term_from_is_optional`: old JSON without `from` parses.
  - service term.rs `end_term_log_has_no_term`: the term id string does not appear in `log_fields`.
  - `open_term_log_from_is_bool`.
  - hub terms.rs `end_term_is_answered_with_term_ended`.
  - testkit `end_term_reaches_the_worker` (mirror `rename_term_reaches_the_worker`).
- [ ] **Step 2: Watch them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `PATH=$HOME/.cargo/bin:$PATH cargo test --workspace --no-fail-fast` **and** `cargo clippy --workspace --all-targets -- -D warnings`**; both must pass.**
- [ ] **Step 5: Commit** `feat(net): end_term and open_term from`

### Task 6: GUI

**Files:**
- Modify:
  - `gui/lib/hub_client.dart`:
    - `TermRow` gains `fg` (String?) and `shell` (bool?), parsed wherever TermRow is built.
    - `openTerm` gains `String? from`.
    - New `Future<void> endTerm(String id, String term)` (`end_term` → `term_ended`, then refresh `terms(id)`).
  - `gui/lib/term/term_keys.dart`: `TermShortcut` gains `newTerm` and `closeTerm`; `_shortcut` maps `t` → newTerm and `w` → closeTerm. Ctrl+Shift on non-mac comes free from the existing branch.
  - `gui/lib/term/term_stage.dart` `_termKey`: newTerm calls `widget.state.newTermFrom(...)`, closeTerm calls `widget.state.endTermAsk(...)`. Both are handled before the `_canInput` gate.
  - `gui/lib/ui/main_state.dart`:
    - `newTermFrom(String device, String term)`, queued through a `Future` chain so repeated presses run in order;
    - `endTerm(String key)`;
    - the record removal on `session ended` / `no such text terminal`.
  - `gui/lib/embed/stream_menu.dart:536` and `gui/lib/ui/stage.dart:179`: for text terminals the label 「关闭」 (same action as today); add 「结束终端」 after it in danger colour, but only when the row's `shell != null`.
  - The confirm dialog: a new small widget in `gui/lib/term/end_term_dialog.dart`.

**Interfaces:**
- Consumes: hub `end_term` / `term_ended`, `open_term.from`, `TermRow.fg/shell`.
- Produces:
  - `MainState.newTermFrom(String device, String term) → Future<void>`. It is like `openText`, but passes `from: term` and keeps the hint 「这台设备没有可用的终端窗口」.
  - `MainState.endTerm(String key) → Future<void>`. On success it calls `_endRecord` and hints 「已结束 <名字>」. On `unsupported`/OLD_RUN words it hints 「这台设备的 rApp 太旧，不能结束终端」. On other failures the hint carries the hub's words.
  - `endTermAsk`: when `row.shell == false`, it shows the dialog first:
    - title 「结束终端？」;
    - body 「里面还在跑 ${row.fg}，结束后它也会被关掉。」;
    - buttons 「结束」/「取消」, with autofocus on 取消.
  - ⌘W with no `shell` field returns `KeyEventResult.ignored`, so it bubbles as today.
  - In `_planRetry`'s caller (where `DisconnectedEvent` lands for a term record): reason `session ended` or `no such text terminal` gives `_endRecord(r)` and 「已结束 <名字>」 instead of 已断开. Network reasons are unchanged.

- [ ] **Step 1: Failing tests (gui/test, following the existing main_state and term_keys tests).**
  - `term_keys`: ⌘T gives `TermAction(newTerm)`; ⌘W gives `TermAction(closeTerm)`; on non-mac Ctrl+Shift+T and Ctrl+Shift+W do the same; Ctrl+T alone still gives the `Ctrl-t` key.
  - `new_term_from_queues`: three calls, then the fake hub sees three `open_term` with `from` in order.
  - `end_term_old_holder_hint`: the fake hub refuses with the OLD_RUN words; the hint matches, and the record stays.
  - `end_term_removes_record`.
  - `session_ended_removes_term_record`: a `DisconnectedEvent(sid,'session ended')` on a term record removes it, hints 「已结束 …」, and no retry is planned.
  - `network_drop_still_reconnects`.
  - `end_dialog_when_program_running`: a widget test pumps the dialog and checks the copy, with focus on 取消.
  - `menu_shows_end_term_only_with_shell`.
- [ ] **Step 2: Watch them fail:** `cd gui && ~/development/flutter/bin/flutter test <files>`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test` **(all) and** `flutter analyze`**; both must be clean. Then run** `git checkout gui/pubspec.lock`**.**
- [ ] **Step 5: Commit** `feat(gui): ⌘T new terminal, 结束终端, clean end of text terminals`

### Task 7: Docs, todo checks, full gate

**Files:**
- Modify: `tasks/todo.md` (add a 「多终端」 section with spec §6 checks 1–10, 8a, 8b, copied verbatim), and the user docs that describe text terminals (`git grep -l "文字终端" -- docs README* | /usr/bin/grep -v archives`) where the shortcuts and the 结束终端 item belong.

- [ ] **Step 1: Write the todo section and the doc lines.**
- [ ] **Step 2: Full gate.**
  - `PATH=$HOME/.cargo/bin:$PATH cargo test --workspace --no-fail-fast`
  - `cargo clippy --workspace --all-targets -- -D warnings`
  - `flutter test`
  - `flutter analyze`
  - `git checkout gui/pubspec.lock`
  - The macOS app build compiles, if `gui/macos` was touched.
- [ ] **Step 3: Commit** `docs: multi-terminal checks and shortcuts`
