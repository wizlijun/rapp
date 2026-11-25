# 终端名用程序标题、总览「终端」新建 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A text terminal that was never named by hand is shown by the title its program sets (OSC 0/1/2) instead of `zsh`; the overview's 常用 · 终端 tile always opens a new text terminal and says 「新建」.

**Architecture:** rapp-term's OSC scanner (`pty/ps.rs`) learns OSC 0/1/2; a new `pty/title.rs` keeps the tab name and the window title and cleans them. The output pump stores the shown title in `Shared`. `Status` (local socket) and `TermRow` (term list) carry an optional `title`, which is left out for hand-named sessions. The GUI's `TermRow` gains `title` and `shown` (`title ?? name`), and every display of a terminal name reads `shown`. The overview favourite takes a new `termsNewTarget` that prefers `NewText`.

**Tech Stack:** Rust (rapp-term, serde), Flutter/Dart (gui).

**Spec:** `docs/superpowers/specs/2026-11-25-rapp-term-title-design.md`

## Global Constraints

- Protocol stays v15; `title` is additive and optional: `#[serde(default, skip_serializing_if = "Option::is_none")]` on Rust structs; the GUI treats a missing or non-string `title` as null.
- Shown title = tab name (OSC 0 or 1) if set, else window title (OSC 0 or 2), else none.
- Cleaning: drop control characters (`char::is_control`), trim, strip leading decoration (whitespace and chars in U+2190–U+21FF, U+2300–U+23FF, U+25A0–U+27BF, U+2800–U+28FF, U+2B00–U+2BFF, `*`, `·`), cut to 64 chars (`chars()`), empty → none. `~`, `/`, `.`, letters, digits and CJK are never stripped.
- Hand-named (`run --name`, or any successful `rename`) → no title is reported, ever after, for that session.
- Copy: the favourite tile says 「新建」 for a new text terminal, 「打开」 otherwise; its semantics label is `常用 终端，点按新建` / unchanged otherwise.
- Not changed: device page 终端 entry, 打开应用 menu, project 全部打开, `name` rules, rename rules.
- Tests: `cargo test --workspace --no-fail-fast` (testkit asserts on row fields); `flutter test` from `gui/` with `~/development/flutter/bin` on PATH; restore `gui/pubspec.lock` afterwards. Never `dart format` whole files.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A title arriving split across two pty reads (`\x1b]0;ti` + `tle\x07`) must still be seen whole (Task 1 test).
- A program that sends a new title on every spinner frame (`⠂ task`, `⠐ task`) must not change the shown title (Task 1 test: cleaned result equal → `feed` returns false).
- `program_status: false` in term.json must not turn titles off (Task 2 test: pump with tracker `None` still sets the title).
- Renaming a terminal whose shown title is `~/git/rapp` to the same text sends nothing; renaming to anything else sticks and the title stops (Task 2 + Task 3 tests).
- A row with a 64-char title in a 1000-row list still fits `MAX_LINE` (Task 2: extend `a_long_list_is_cut_to_one_line` with `title: Some("t".repeat(64))`).

---

### Task 1: OSC 0/1/2 in the scanner, and `Titles`

**Files:**
- Modify: `rust/term/src/pty/ps.rs` (Scanner `Kind`, `osc_byte`, `finish`, `Event`; `Tracker::feed` ignores the new event; test `other_osc_is_ignored`)
- Create: `rust/term/src/pty/title.rs`
- Modify: `rust/term/src/pty/mod.rs` (`pub mod title;`)

**Interfaces:**
- Produces: `ps::Event::Title { slot: u8, text: String }` (slot 0, 1 or 2); `title::clean(raw: &str) -> Option<String>`; `title::Titles` (`Default`), `fn feed(&mut self, bytes: &[u8]) -> bool` (true when `shown()` changed), `fn shown(&self) -> Option<String>`.

- [ ] **Step 1: Write the failing tests**

In `ps.rs` tests, replace `other_osc_is_ignored`: `0;title` now yields a title event, the rest stay ignored. Extend the `events` helper so a title prints as `title{slot}:{text}`.

```rust
#[test]
fn osc_0_1_2_are_titles_and_other_osc_is_ignored() {
    assert_eq!(events(&[b"\x1b]0;a\x07\x1b]1;b\x1b\\\x1b]2;c\x07\x1b]75010;x\x07\x1b]1337;?\x07\x1b]10;?\x07"]),
        ["title0:a", "title1:b", "title2:c"]);
    assert_eq!(events(&[b"\x1b]0;ti", b"tle\x07"]), ["title0:title"]);
}
```

In `title.rs`:

```rust
#[test]
fn clean_strips_controls_spinners_and_cuts_at_64() {
    assert_eq!(clean("  ~/git/rapp \t"), Some("~/git/rapp".into()));
    assert_eq!(clean("✳ Claude Code"), Some("Claude Code".into()));
    assert_eq!(clean("⠐ Fix the build"), Some("Fix the build".into()));
    assert_eq!(clean("a\u{7}b"), Some("ab".into()));
    assert_eq!(clean("修复 终端"), Some("修复 终端".into()));
    assert_eq!(clean("⠂ "), None);
    assert_eq!(clean(""), None);
    assert_eq!(clean(&"x".repeat(80)).unwrap().chars().count(), 64);
}

#[test]
fn tab_name_wins_over_window_title() {
    let mut t = Titles::default();
    assert!(t.feed(b"\x1b]2;bruce@mac:~/git/rapp\x07"));
    assert_eq!(t.shown().as_deref(), Some("bruce@mac:~/git/rapp"));
    assert!(t.feed(b"\x1b]1;~/git/rapp\x07"));
    assert_eq!(t.shown().as_deref(), Some("~/git/rapp"));
    assert!(t.feed(b"\x1b]0;vim x\x07")); // 0 sets both
    assert_eq!(t.shown().as_deref(), Some("vim x"));
    assert!(t.feed(b"\x1b]0;\x07")); // empty clears both
    assert_eq!(t.shown(), None);
}

#[test]
fn a_spinner_frame_is_no_change() {
    let mut t = Titles::default();
    assert!(t.feed(b"\x1b]0;\xe2\xa0\x82 task\x07")); // ⠂
    assert!(!t.feed(b"\x1b]0;\xe2\xa0\x90 task\x07")); // ⠐
    assert!(!t.feed(b"plain output"));
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd rust && cargo test -p rapp-term --lib -- title osc_0_1_2`
Expected: compile errors (`title` module, `Event::Title` missing).

- [ ] **Step 3: Implement**

- `Scanner`: add `Kind::Title(u8)`. In `osc_byte`'s `Pending` branch, `0;`, `1;` and `2;` set `Kind::Title(slot)`. `0`, `1` and `2` count as live prefixes (so `1` does not skip `133;A`). A title body buffers like 7501, cut at `MAX_BUFFER` → Skip. `finish` emits `Event::Title { slot, text: from_utf8_lossy(body) }`.
- `Tracker::feed`: an `Event::Title` arm that does nothing.
- `title.rs`:
  - `Titles { scanner: Scanner, tab: Option<String>, window: Option<String> }`.
  - `feed` runs the scanner, applies each title: slot 0 → both slots, 1 → tab, 2 → window, each set to `clean(text)`.
  - It compares `shown()` before and after.
  - `clean` follows Global Constraints.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd rust && cargo test -p rapp-term --lib -- ps:: title::`
Expected: all pass, including the existing 7501 scanner tests.

- [ ] **Step 5: Commit**

```bash
git add rust/term/src/pty/ps.rs rust/term/src/pty/title.rs rust/term/src/pty/mod.rs
git commit -m "feat(term): read OSC 0/1/2 titles and clean them"
```

### Task 2: Carry the title to the list; hand-named sessions report none

**Files:**
- Modify: `rust/term/src/pty/mod.rs` (`Meta.named: AtomicBool`, `Shared.title: Mutex<Option<String>>`, `Shared::status`)
- Modify: `rust/term/src/pty/holder.rs` (construct `named` from `opts.name.is_some()`, `title: Mutex::new(None)`; `pump_output` always runs a `Titles`; the `"rename"` op sets `named`; test helper `shared_with_input`)
- Modify: `rust/term/src/pty/view.rs:338` (test `Shared` gets the new fields)
- Modify: `rust/term/src/pty/local.rs` (`Status.title`)
- Modify: `rust/term/src/list.rs` (`TermRow.title`), `rust/term/src/serve.rs` (`pty_rows` copies `s.title`; test rows)
- Modify: `rust/testkit/src/bin/fake-rapp-term.rs` and any other `Status {` / `TermRow {` literal the workspace build reports

**Interfaces:**
- Consumes: `title::Titles` (Task 1).
- Produces: `Status.title: Option<String>` and `TermRow.title: Option<String>`, both `#[serde(default, skip_serializing_if = "Option::is_none")]`. JSON key `"title"` in each term row.

- [ ] **Step 1: Write the failing tests** (in `holder.rs` tests)

```rust
#[test]
fn a_title_reaches_the_status_even_with_program_status_off() {
    let (sh, _rx) = shared_with_input(30, 4);
    let window = Mutex::new(Window::new(Vec::new()));
    let (tx, _d) = oneshot::channel();
    let pty = Chunks(VecDeque::from([&b"\x1b]1;~/git/rapp\x07"[..]]));
    pump_output(pty, &window, &sh, tx, Emu::feed, None);
    assert_eq!(sh.status().title.as_deref(), Some("~/git/rapp"));
}

#[test]
fn a_hand_named_session_reports_no_title() {
    let (sh, _rx) = shared_with_input(30, 4);
    sh.meta.named.store(true, Ordering::Relaxed);
    let window = Mutex::new(Window::new(Vec::new()));
    let (tx, _d) = oneshot::channel();
    pump_output(Chunks(VecDeque::from([&b"\x1b]0;vim\x07"[..]])), &window, &sh, tx, Emu::feed, None);
    assert_eq!(sh.status().title, None);
}
```

Add a rename test next to the existing local-op tests, using their harness: after a successful `rename`, `meta.named` is true and `status().title` is `None` even with a stored title. In `local.rs`, a `Status` JSON without `title` parses to `title: None`, and one with `"title":"x"` keeps it. In `serve.rs`, `a_long_list_is_cut_to_one_line` rows get `title: Some("t".repeat(64))`; a `pty_rows` check confirms a status's title lands in the row.

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd rust && cargo test -p rapp-term --lib -- title hand_named rename`
Expected: compile errors (`title`, `named` fields missing).

- [ ] **Step 3: Implement**

- `Shared::status()`: `title: if self.meta.named.load(Relaxed) { None } else { self.title.lock()...clone() }`.
- `pump_output` makes a `Titles` before its loop. On every chunk, it runs `titles.feed(&b[..n])` outside the tracker branch, and on `true` stores `titles.shown()` into `shared.title`.
- `rename` success: `named.store(true, Relaxed)` along with the name.

- [ ] **Step 4: Run the whole workspace**

Run: `cd rust && cargo test --workspace --no-fail-fast 2>&1 | /usr/bin/grep -E '^test result|FAILED|panicked'` and `cargo clippy --workspace --all-targets -- -D warnings`
Expected: every `test result: ok`; clippy clean. A fresh worktree may fail `linux_detach_test` only (no built `rapp-session`), which is known.

- [ ] **Step 5: Commit**

```bash
git add rust
git commit -m "feat(term): report the program's title in the status and the term list"
```

### Task 3: GUI shows `title ?? name`

**Files:**
- Modify: `gui/lib/hub_client.dart` (`TermRow` gains `final String? title;` named param, `String get shown => title ?? name;`; `_termList` reads `_str(r['title'])`, with an empty string treated as null)
- Modify: `gui/lib/ui/main_state.dart` (`termName` returns `.shown`; the queue `_trackPrograms` and the needs builder use `termDisplayName(r.shown, r.host)`; `openText`'s `shown`)
- Modify: `gui/lib/ui/terms_entry.dart:74` (`termDisplayName(pty.shown, pty.host)`)
- Modify: `gui/lib/ui/devices_tab.dart` (lines 404, 661 use `r.shown`/`row.shown`; `InlineEdit(text: row.shown)`; `_rename` compares with `r.shown`)
- Test: `gui/test/hub_client_test.dart`, `gui/test/ui/main_state_test.dart`, `gui/test/ui/devices_tab_test.dart`

**Interfaces:**
- Consumes: JSON `"title"` in term rows (Task 2).
- Produces: `TermRow.title`, `TermRow.shown`.

- [ ] **Step 1: Write the failing tests**
  - **hub_client_test:** a terms reply row `{'id': 'term:pty:k', 'name': 'zsh', 'title': '~/git/rapp', ...}` parses to `shown == '~/git/rapp'`. Without `title`, or with `'title': ''` or `'title': 3`, `shown == 'zsh'`.
  - **main_state_test:** with that row listed, an open session's entry has `appName == '~/git/rapp'`, and `labelOf(AppRef(... 'term:pty:k' ...)) == 'CLI · ~/git/rapp'`.
  - **devices_tab_test:**
    - The row shows `~/git/rapp`.
    - Committing the inline edit unchanged (`~/git/rapp`) sends no `rename_term`.
    - Committing `build` sends one with `'name': 'build'`.

- [ ] **Step 2: Run to see them fail**

Run: `cd gui && PATH=~/development/flutter/bin:$PATH flutter test test/hub_client_test.dart test/ui/main_state_test.dart test/ui/devices_tab_test.dart`
Expected: FAIL (no `title`/`shown`).

- [ ] **Step 3: Implement**, per Files.

- [ ] **Step 4: Run to see them pass**

Same command. Expected: PASS. Then `flutter analyze`: no issues.

- [ ] **Step 5: Commit**

```bash
git add gui/lib gui/test && git checkout gui/pubspec.lock
git commit -m "feat(gui): a text terminal is shown by its program's title"
```

### Task 4: Overview 常用 · 终端 says 「新建」 and always opens a new one

**Files:**
- Modify: `gui/lib/ui/terms_entry.dart` (add `termsNewTarget`)
- Modify: `gui/lib/ui/main_state.dart` (`_termsNewTargetOf(id)`, `bool favoriteCreates(AppRef f)`, `Future<void> openFavorite(AppRef f)`; refactor `_openTerms` so its switch takes a `TermsTarget`)
- Modify: `gui/lib/ui/overview.dart` (`_FavoriteBlock` takes `verb`: `'新建'`/`'打开'`; the onTap calls `state.openFavorite(f)`; the semantics uses `点按$verb`)
- Test: `gui/test/ui/terms_entry_test.dart`, `gui/test/ui/overview_test.dart`

**Interfaces:**
- Produces:
  - `TermsTarget termsNewTarget({required String mode, required TermList list, required List<HubApp> apps, bool graphical = true})`. In text mode (or `!graphical`), when the local host has launchers, it returns `NewText(<default shell path or null>)` even if pty sessions exist. Otherwise it returns exactly `termsTarget(...)`.
  - `MainState.favoriteCreates(AppRef f)`: true when `f.bundle == termsEntry` and `_termsNewTargetOf(f.device) is NewText`.
  - `MainState.openFavorite(AppRef f)`: the 终端 entry → `_termsNewTargetOf` → same handling as `_openTerms` (`select: true`). Anything else → `openOrSwitch(f.device, f.bundle, f.name)`.

- [ ] **Step 1: Write the failing tests**
  - **terms_entry_test:**
    - A text-mode list with a pty row and launchers → `termsNewTarget` is `NewText` with the default shell. `termsTarget` is still `OpenTerm` (unchanged).
    - Pixels mode → `OpenPixels`.
    - Text mode with no launchers but a pty row → `OpenTerm`.
  - **overview_test**, 「常用 · 终端 says 新建 and opens a new terminal each tap」:
    - Device `m1` in text mode, with a term list holding one pty row and a local host with launchers `['Terminal']`. `toggleFavorite('m1', termsEntry, termsEntryName)`.
    - Expect `find.descendant(of: ov-favorite-m1/terms:, matching: find.text('新建'))`, and the semantics label `常用 终端，点按新建`.
    - Tap twice (answer `open_term` like `devices_tab_test.dart:101`). Expect two `open_term` commands in `sent`.
    - Pixels mode: the tile says 「打开」.

- [ ] **Step 2: Run to see them fail**

Run: `cd gui && PATH=~/development/flutter/bin:$PATH flutter test test/ui/terms_entry_test.dart test/ui/overview_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement**, per Interfaces.

- [ ] **Step 4: Full gate**

Run: `cd gui && PATH=~/development/flutter/bin:$PATH flutter analyze && flutter test 2>&1 | tail -3`, then `git checkout gui/pubspec.lock`
Expected: analyze clean; all tests pass (count reported).

- [ ] **Step 5: Docs + commit**
  - `tasks/todo.md`: add a section 「终端名用标题、总览终端新建」 with the spec's §5 checks as unchecked real-machine items 1–6.

```bash
git add gui/lib gui/test tasks/todo.md
git commit -m "feat(gui): overview 常用 · 终端 creates a new terminal and says 新建"
```
