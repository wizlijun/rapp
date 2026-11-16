# Terminal Entry Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove everything tmux / SSH-host from rapp. A text terminal is opened with one click on an installed shell, can be renamed on the host, scales up as well as down in the stage, and is titled `CLI · <name>`.

**Architecture:** `rapp-term` loses its tmux backend and keeps only the `pty` one (`rapp-term run` holder + `serve`). `serve` reports the installed shells in the local host row, opens a window running `<shell> -l`, and gives each `run` a stable random key so its id (`term:pty:<key>`) no longer carries the name, which becomes renamable over the local socket. The net/service/hub layers lose the tmux ops and gain `rename_term`. The GUI drops every tmux path, turns the new-text dialog into a row of shell buttons plus a per-device 终端 app setting, adds inline rename, titles sessions `CLI · <name>`, and scales the stage grid both ways.

**Tech Stack:** Rust (tokio, serde, portable-pty, alacritty_terminal), Flutter/Dart.

**Spec:** `docs/superpowers/specs/2026-11-16-rapp-term-entry-design.md` (§4.6 is the full deletion inventory, with line numbers as of `c2a3389`).

## Global Constraints

- Work in a worktree: `.claude/worktrees/term-entry`, branch `feat/term-entry` from `main`.
- Rust tests: `cd rust && cargo test -p <crate>`. Flutter: `cd gui && export PATH=$HOME/development/flutter/bin:$PATH && flutter test <path>`, then `git checkout -- gui/pubspec.lock`.
- Shell candidates in order: macOS `zsh, bash, sh, fish, tcsh`; Linux `bash, sh, zsh, fish, dash`; Windows `cmd.exe, powershell.exe, pwsh.exe, bash.exe (Git Bash), sh.exe (Git Bash)`.
- Fallbacks: macOS/Linux `/bin/sh`, Windows `cmd.exe`. The fallback is always in the list.
- Windows button names: `cmd`, `PowerShell`, `pwsh`, `Git Bash`, `Git sh`. Unix names are the file name (`zsh`).
- `System32\bash.exe` is WSL and never counts as Git Bash.
- Extra unix dirs searched after `/etc/shells` and PATH: `/opt/homebrew/bin`, `/usr/local/bin`, `/bin`, `/usr/bin`.
- Session names: trimmed, non-empty, no control characters, at most 64 characters; duplicates allowed.
- Stable key: 16 lowercase hex characters, made by `run` at start. Id `term:pty:<key>`.
- Title copy: `CLI · <name>` (U+00B7 with one space each side).
- UI copy: `新开`, `终端 app`, `默认 shell`, `打开方式`, `这台设备上现在没有终端会话。`.
- Device error words are English, as today: `this shell is not found any more`, `this window was opened by an older version and cannot be renamed`, `invalid name`.
- Old peers: unknown fields are ignored by serde (no `deny_unknown_fields` on these types). Keep `TermRow.host/panes/dead` and `Pane.win/active/window` on the wire for old GUIs. `PROTO` stays 2.

## Review Focus

1. A window opened before the upgrade (`run` local v1, status without `key`): it must still be listed as `term:pty:<name>`, open, and refuse rename with the older-version words. Test: Task 2 Step 1 `an_old_run_is_listed_by_name_and_refuses_rename`.
2. The login shell is not a candidate (`/usr/local/bin/nu`), or is missing, or nothing at all is found: the first two put `nu`/fallback first; the last lists only `/bin/sh`. Test: Task 3 Step 1.
3. A shell uninstalled between listing and clicking: `open` answers `this shell is not found any more` and the GUI shows it under the shell row; nothing hangs. Tests: Task 3 Step 1 `open_refuses_a_shell_not_found_now`, Task 6 Step 1 `a refused open shows its words under the row`.
4. A rename seen by a second watcher: the watch stream pushes the new name at once (not after the 2 s poll), and the title of an open session follows. Tests: Task 2 Step 1 `a_rename_reaches_a_watch_at_once`, Task 8 Step 1 `the title follows a rename`.
5. A stage much larger than the grid (scale > 1): drag-selection and link hits still land on the right cell. Test: Task 8 Step 1 `selection maps to cells when scaled up`.

---

### Task 1: rapp-term without tmux

Delete the tmux backend from `rust/term` only; serve answers removed requests with its existing bad-request error. Other crates are untouched here and must still build (they call serve only over JSON).

**Files:**
- Delete: `rust/term/src/tmux/` (all), `rust/term/src/session.rs`, `rust/term/src/runner.rs`, `rust/term/tests/live.rs`, `rust/term/tests/locale.rs`, `rust/term/tests/grid_live.rs`, `rust/term/tests/common/mod.rs` (keep `common/pty.rs`; tests that used `mod common;` + `common::pty` switch to `#[path = "common/pty.rs"] mod pty;` or an equivalent).
- Modify: `rust/term/src/{lib,main,serve,list,config,id,keys,screen,proto,wire}.rs`, `rust/term/src/pty/{grid,view}.rs`, `rust/term/tests/{cli,serve}.rs`.

**Interfaces:**
- Produces: `rapp_term::wire::{HistoryRows, MAX_HISTORY, MAX_PASTE}` (moved from `tmux/mod.rs:14-25`, unchanged). `serve::HostRow { host: Option<String>, launchers: Vec<String> }` (target/tmux/error gone; `shells` comes in Task 3). `serve::ServeOpts` without `socket`, `ctl_dir`; `ServeOpts::new(config: PathBuf) -> ServeOpts`. `Req` = `List | Watch | View | Open` only.
- `rapp-term` CLI keeps `version`, `run`, `serve`.

- [ ] **Step 1: Move `HistoryRows`, `MAX_HISTORY`, `MAX_PASTE` into `wire.rs`** and point `wire.rs:5`, `pty/grid.rs:5`, `pty/view.rs:321` at them. Run `cargo test -p rapp-term` — PASS (pure move).
- [ ] **Step 2: Give `tests/serve.rs` a tmux-free harness.** `Worker::start` currently takes a tmux `Server`; change it to start `rapp-term serve` with only a temp `term.json` (`{"allow":true}`) and a short pty dir. Port the pty tests (565-704) onto it, dropping tmux rows from their expectations: e.g. `a_pty_session_is_listed` asserts `terms_of(&v) == ["term:pty:t"]` and `v[0]["hosts"] == json!([{"host": null}])` (no launchers under the test's `launch_with` unless the test sets it — keep whatever the existing open tests set). Delete tests 246-560 (tmux/targets). Run: `cargo test -p rapp-term --test serve` — PASS on a machine **without tmux on PATH** (check with `PATH=/usr/bin:/bin cargo test …` after building).
- [ ] **Step 3: Delete the tmux code** per spec §4.6 `rust/term` list: modules above; `list.rs` keeps only `TermRow`; `config.rs` keeps `allow`, `load`, `INVALID`, `OFF` (add a test `old_fields_are_ignored`: `{"allow":true,"tmux":"/x","targets":[{"name":"g","target":"me@g"}]}` loads with `allow == true`); `id.rs` drops `valid_host`, tests use `term:pty:`; `keys.rs` keeps `to_bytes`, `csi_form`; `screen.rs` keeps `Screen`, `strip_escapes`; `proto.rs` drops `Out::WindowOpened`, `In::NewWindow`, `In::Refit` (and `pty/view.rs` drops its answers to them — an unknown `In` line now gets the same reply any unparsable line gets today); `serve.rs` drops everything listed in §4.6; `main.rs` drops `list`, `watch`, `new`, `--ssh/--host/--tmux/--socket` and rewrites USAGE and the module doc comments (`serve.rs:1-6`, `main.rs:1-31`, `config.rs:1`) without tmux. `tests/cli.rs` keeps `version_json`, `bad_arguments_exit_2`, `run_refuses_a_cwd…`.
- [ ] **Step 4: Verify.** `cargo test -p rapp-term` — PASS. `grep -rni tmux rust/term` — only the `config.rs` ignore test's JSON. `cargo build` for the whole workspace — PASS (service/hub/testkit still compile; their tmux ops now get serve's bad-request error and are removed in Task 4).
- [ ] **Step 5: Commit** `refactor(term): drop the tmux backend, SSH targets and rapp-term new/list/watch`.

### Task 2: Stable key and rename (rapp-term)

**Files:**
- Modify: `rust/term/src/pty/{mod,local,holder,view}.rs`, `rust/term/src/serve.rs`
- Test: `rust/term/tests/serve.rs`, `rust/term/tests/pty.rs`, unit tests in `local.rs`

**Interfaces:**
- Consumes: Task 1's harness.
- Produces:
  - `local::LOCAL_V = 2`.
  - `local::Status` gains `#[serde(default, skip_serializing_if = "Option::is_none")] pub key: Option<String>` (v1 runs send none).
  - `local::Head` gains `pub name: Option<String>`, read from the request line `{"op":"rename","v":2,"name":"<new>"}`.
  - `pub async fn local::rename(path: &Path, token: &str, name: &str) -> Result<(), Probe>`: the run replies `{"ok":true}`, or `{"error":…}` → `Probe::Refused(words)`; a v1 run answers `{"error":"unsupported","v":1}`.
  - `pty::Meta { key: String, name: Mutex<String>, command, pid, ticket }`.
  - `serve::pty_id(s: &Status) -> String`: `term:pty:<key>` when `key` is some, else `term:pty:<name>`.
  - `serve::is_session(s: &Status, id_name: &str) -> bool`: `s.key == Some(id_name)`, or `s.key.is_none() && s.name == id_name`.
  - `pub fn id::clean_name(s: &str) -> Option<String>`: the name rule from Global Constraints.
  - `Req::Rename { term: String, name: String }` → reply `{"ok":true}` or `{"error":…}`; errors: `invalid name`, the existing `NO_TEXT_TERMINAL`, `this window was opened by an older version and cannot be renamed` (const `OLD_RUN`).
  - The worker owns a `rescan: Arc<Notify>`; `ask_pty` waits on `poll` **or** `rescan`; a successful rename calls `notify_one()`.

- [ ] **Step 1: Write the failing tests** in `tests/serve.rs`:
  - `a_pty_row_is_keyed_not_named`: start `Window` with `--name t`; the list row's `id` matches `^term:pty:[0-9a-f]{16}$` and `name == "t"`; `view` by that id gets a `hello`.
  - `rename_changes_the_name_not_the_id`: `{"op":"rename","term":<id>,"name":"  后端 "}` → `{"ok":true}`; the next list has the same id with `name == "后端"`.
  - `rename_refuses_bad_names`: `""`, `"a\u{7}"`, 65 × `"x"` → `{"error":"invalid name"}`; 64 × `"x"` → ok.
  - `rename_of_an_unknown_term_says_so`: unknown key → the `NO_TEXT_TERMINAL` words.
  - `a_rename_reaches_a_watch_at_once`: with `poll` set to 30 s in the harness, a watcher sees the new name within 1 s of the rename reply.
  - `an_old_run_is_listed_by_name_and_refuses_rename`: the test binds `pty/<n>.sock` itself, checks the token head, answers `status` with a v1 JSON (no `key`, `"v":1`, `name:"old"`) and anything else with `{"error":"unsupported","v":1}`; the list shows `term:pty:old`; rename → `OLD_RUN` words.
  - In `tests/pty.rs`: `two_runs_with_the_same_name_after_a_rename_stay_apart` — run `a` and `b`, rename `b` to `a`, both ids still view their own program.
- [ ] **Step 2: Run** `cargo test -p rapp-term --test serve --test pty` — FAIL (no key, no rename).
- [ ] **Step 3: Implement.** `holder.rs` makes the key once at start (same randomness source serve's `ticket()` uses) and answers `rename` (`clean_name` again, then replace `Meta.name`). Every reader of `meta.name` takes the lock (status, `view.rs:132` pane title). `serve.rs`: `pty_rows`, `wait_for` use `pty_id`; `view_pty` (`serve.rs:513`) uses `is_session`; add `Req::Rename`. `pick_name` and the name lock stay for default names.
- [ ] **Step 4: Run** `cargo test -p rapp-term` — PASS.
- [ ] **Step 5: Commit** `feat(term): stable session keys and rename over the local socket`.

### Task 3: Installed shells and open-by-shell (rapp-term)

**Files:**
- Create: `rust/term/src/shells.rs` (+ `pub mod shells` in `lib.rs`)
- Modify: `rust/term/src/pty/launch.rs`, `rust/term/src/serve.rs`
- Test: unit tests in `shells.rs` and `launch.rs`; `rust/term/tests/serve.rs`

**Interfaces:**
- Produces:
  - `#[derive(Serialize, Clone, Debug, PartialEq)] pub struct Shell { pub name: String, pub path: String, pub default: bool }`
  - `pub enum Os { Mac, Linux, Windows }`
  - `pub struct Env<'a> { pub etc_shells: &'a str, pub path: &'a str, pub login: Option<&'a str>, pub system_root: Option<&'a str>, pub program_files: Option<&'a str>, pub is_exec: &'a dyn Fn(&str) -> bool, pub subdirs: &'a dyn Fn(&str) -> Vec<String> }` (all paths are `&str` so Windows rules test on any OS; join with `/` or `\` by `Os`).
  - `pub fn find(os: Os, env: &Env) -> Vec<Shell>`: default entry first, the rest in candidate order, exactly one `default: true`, no duplicate names.
  - `#[cfg(unix)] pub fn here() -> Vec<Shell>`: reads `/etc/shells`, `PATH`, `getpwuid(getuid())->pw_shell`, real `is_exec` (regular file with any x bit).
  - `HostRow { host, launchers, #[serde(skip_serializing_if = "Vec::is_empty")] shells: Vec<Shell> }`, filled from `here()` on **every** list (local host row only).
  - `Req::Open { shell: Option<String>, app: String }` (old GUIs' `cwd`/`name`/`command` are ignored by serde).
  - `launch::command_file(bin: &Path, dir: &Path, ticket: &str, shell: &str) -> String`.

- [ ] **Step 1: Write the failing tests.**
  - `shells.rs`:
    - `mac_lists_only_what_exists`: is_exec true for `/bin/zsh`, `/bin/bash`, `/bin/sh` only; login `/bin/zsh` → names `[zsh, bash, sh]`, `zsh` default.
    - `homebrew_fish_is_found_without_path`: PATH `/usr/bin:/bin`, exec `/opt/homebrew/bin/fish` → `fish` present with that path.
    - `etc_shells_wins_over_path`: `/etc/shells` has `/usr/local/bin/bash`, PATH has `/bin/bash`, both exec → bash path `/usr/local/bin/bash`.
    - `a_login_shell_outside_the_candidates_comes_first`: login `/usr/local/bin/nu` (exec) → first is `{nu, /usr/local/bin/nu, default}`.
    - `a_missing_login_shell_falls_back_to_bin_sh`: login `/bin/nope` (not exec) → default is `{sh, /bin/sh}` and it is first.
    - `nothing_found_lists_only_the_fallback`: is_exec always false → exactly `[{sh, /bin/sh, default}]`.
    - `linux_order`: all exist, login `/bin/bash` → `[bash, sh, zsh, fish, dash]`.
    - `windows_rules`: SystemRoot `C:\Windows`, ProgramFiles `C:\Program Files`, exec set = `C:\Windows\System32\cmd.exe`, `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`, `C:\Windows\System32\bash.exe`, `C:\Program Files\PowerShell\7\pwsh.exe` (via `subdirs` of `C:\Program Files\PowerShell` = `[…\7]`), `C:\Program Files\Git\bin\bash.exe`, `C:\Program Files\Git\bin\sh.exe` → names `[cmd, PowerShell, pwsh, Git Bash, Git sh]`, `cmd` default, Git Bash path is the `Git\bin` one.
    - `wsl_bash_is_not_git_bash`: only `cmd.exe` and `System32\bash.exe` exec → `[cmd]`.
    - `windows_git_on_path`: PATH contains `D:\tools\Git\bin` with `bash.exe` → Git Bash found there; a PATH dir without `\Git\` holding `bash.exe` is ignored.
  - `launch.rs`: replace the command-file test: `command_file(Path::new("/A pp/rapp-term"), Path::new("/r/local/term"), "t1", "/opt/my shells/fish")` == `"#!/bin/sh\nexec '/A pp/rapp-term' run --dir '/r/local/term' --ticket 't1' -- '/opt/my shells/fish' -l\n"`.
  - `tests/serve.rs`:
    - `the_local_row_lists_shells`: list → `hosts[0]["shells"]` is a non-empty array with exactly one `default: true`.
    - `open_runs_the_shell_as_a_login_shell` (uses the existing `launch_with` fake): `{"op":"open","shell":<a listed path>,"app":"Terminal"}` → the session's `command` is `<path> -l` and `name` is its file name.
    - `open_refuses_a_shell_not_found_now`: `shell: "/no/such/sh"` → `{"error":"this shell is not found any more"}` and no window is started.
    - `open_without_shell_uses_the_default`: an old-GUI request `{"op":"open","cwd":"/tmp","name":"x","command":"claude","app":"Terminal"}` → session runs the default shell, name is the shell's, not `x`.
- [ ] **Step 2: Run** `cargo test -p rapp-term` — FAIL.
- [ ] **Step 3: Implement** `find` per spec §4.1, `here`, the `HostRow.shells` fill, and `Req::Open` (look the path up in a fresh `here()`; none → the default entry). The watch stream's "changed" comparison already covers the whole list, so a shell appearing is pushed.
- [ ] **Step 4: Run** `cargo test -p rapp-term` — PASS.
- [ ] **Step 5: Commit** `feat(term): list installed shells and open a window by shell`.

### Task 4: Protocol through net, service, hub, testkit

**Files:**
- Modify: `rust/net/src/msg.rs`, `rust/service/src/{term,peer,ipc}.rs`, `rust/hub/src/{terms,lib}.rs`, `rust/testkit/src/bin/fake-rapp-term.rs`, `rust/testkit/tests/{term,hub_terms}.rs`

**Interfaces:**
- Consumes: Task 2 `Req::Rename`, Task 3 `Req::Open { shell, app }`.
- Produces:
  - `Op::OpenTerm { #[serde(default, skip_serializing_if = "Option::is_none")] shell: Option<String>, app: String }` — JSON `{"op":"open_term","shell":…,"app":…}`.
  - `Op::RenameTerm { term: String, name: String }` — JSON `{"op":"rename_term","term":…,"name":…}`.
  - `Op::NewTerm`, `Op::AddTermTarget`, `Op::RemoveTermTarget` removed.
  - Service forwards `OpenTerm` as `{"op":"open","shell","app"}`, `RenameTerm` as `{"op":"rename","term","name"}`; `log_fields` gives `{"op":"rename_term"}` (no name, no term).
  - Local IPC `term`/`set_term` (`ipc.rs:122-123`) carry only `allow`.
  - Hub cmds: `terms`, `open_term`, `rename_term`. `rename_term` answers `{"event":"term_renamed","id":<device>,"term":<term>}`; `open_term` still answers `term_created`. Others → `unknown cmd`.

- [ ] **Step 1: Write the failing tests.** `msg.rs`: serialization of both new ops as above; `{"op":"new_term",…}` no longer parses as an `Op`. testkit `tests/term.rs`: `an_old_new_term_is_an_unknown_op` (reply `{"ok":false,"error":"unknown op"}`), `rename_term_reaches_the_worker` (fake records `{"op":"rename","term":"term:pty:k","name":"n"}`), `open_term_passes_the_shell`. `tests/hub_terms.rs`: `rename_term_answers_term_renamed`, `new_term_is_an_unknown_cmd`. Update `fake-rapp-term.rs` to report only `term:pty:` rows, a `hosts` of `[{"host":null,"launchers":["Terminal"],"shells":[{"name":"zsh","path":"/bin/zsh","default":true}]}]`, and to accept `rename`. Delete the target/new_term/ipc-tmux tests.
- [ ] **Step 2: Run** `cargo test -p rapp-net -p rapp-service -p rapp-hub -p rapp-testkit` — FAIL.
- [ ] **Step 3: Implement**, including the doc comments `service/term.rs:1-4`, `hub/terms.rs:1`.
- [ ] **Step 4: Run** `cd rust && cargo test` (workspace) — PASS. `grep -rniE 'tmux|term_target|new_term' rust --include=*.rs` — only the testkit "unknown" tests and the config-ignore test.
- [ ] **Step 5: Commit** `feat(net): rename_term and open_term by shell; drop the tmux and SSH target ops`.

### Task 5: GUI without tmux

**Files:**
- Modify: `gui/lib/hub_client.dart`, `gui/lib/ui/{devices_tab,terms_entry,main_state,main_window,top_bar,stream_menu,lifecycle}.dart`, `gui/lib/term/{term_session_port,term_wire}.dart`, `gui/lib/embed/session_port.dart`
- Test: the `gui/test` files listed in spec §4.6.

**Interfaces:**
- Produces:
  - `TermHost(String? host, {List<String> launchers})` (target/tmux/error gone; `shells` comes in Task 6).
  - `_termList` drops every row whose `parseTermId(id)?.backend != 'pty'`.
  - `HubClient` loses `addTermTarget`, `newTerm`, `removeTermTarget`.
  - `termsTarget` loses the tmux step (`AskNewText` stays until Task 6).
  - `TermSessionPort` loses the new-window queue; `MainState` loses `canNewTermWindow`, `newTermWindow`, `_newWindowPending`.
  - Removed: `TermWindowOpened`, `newWindowMsg`, `TermOpenedPaneEvent`, the top bar 「＋」新开窗口, and `stream_menu` 按我的屏幕重排.

- [ ] **Step 1: Write the failing tests.** `hub_client_test`: `a terms event from an old device keeps only pty rows` — a `terms` event with `term:tmux:a`, `term:tmux@gpu1:b`, `term:pty:c` and a `hosts` row with `target`/`tmux` → `terms` is `[term:pty:c]`, `hosts` is one local row. `devices_tab_test`: `no tmux or SSH controls` — no `new-term`, `add-ssh-host`, `remove-host-*` keys and no text containing `tmux` or `SSH`. `terms_entry_test`: with only tmux rows (from a raw list) and no launchers, text mode → `OpenPixels`.
- [ ] **Step 2: Run** these tests — FAIL.
- [ ] **Step 3: Delete** per spec §4.6 `gui/lib`. The 文本/tmux kind word in `_TermRow` goes, and the second line is just `row.command`. Rewrite tmux-only tests or delete them (`term_main_test` 157/230/298-360, `term_port_send_test` 232-340, `term_wire_test` 28/34/68, `terms_entry_test` 44-80, `hub_client_test` 469/484, the SSH/new-tmux parts of `devices_tab_test`). Switch `term:tmux:` fixture ids to `term:pty:` in the other files listed.
- [ ] **Step 4: Run** `flutter analyze` (no new issues) and `flutter test` — PASS. `grep -rni tmux gui/lib` — none.
- [ ] **Step 5: Commit** `refactor(gui): drop tmux sessions, SSH hosts and the new-window paths`.

### Task 6: GUI shell buttons and 终端 app setting

**Files:**
- Modify: `gui/lib/hub_client.dart`, `gui/lib/ui/{prefs,main_state,main_window,devices_tab,terms_entry}.dart`
- Test: `gui/test/hub_client_test.dart`, `gui/test/ui/{devices_tab,terms_entry,prefs}_test.dart` (prefs test: create if absent)

**Interfaces:**
- Consumes: Task 4's wire shapes.
- Produces:
  - `class TermShell { const TermShell(this.name, this.path, this.isDefault); final String name, path; final bool isDefault; }`
  - `TermHost.shells`: `List<TermShell>?` — **null when the row has no `shells` key** (old device).
  - `HubClient.openTerm(String id, {String? shell, required String app}) -> Future<String>`.
  - `UiPrefs.termApp: Map<String,String>` (`term_app` in gui.json; non-string values dropped on load). `String termAppFor(String device, List<String> launchers)` returns the stored value if it is in `launchers`, else `launchers.first`.
  - `MainState.setTermApp(String device, String app)`. `MainState.openText(String id, {String? shell}) -> Future<void>` uses `prefs.termAppFor`.
  - `TermsTarget`: `AskNewText` replaced by `class NewText extends TermsTarget { const NewText(this.shell); final String? shell; }` (the default shell's path, null for an old device). `_openTerms` calls `openText(id, shell: …)` directly.
  - `MainState.newTextAsks`, `showNewTextDialog`, `_NewTextDialog`, and the `main_window.dart` queue (~line 75/97) are removed.

- [ ] **Step 1: Write the failing tests.**
  - `hub_client_test`: `shells are parsed and absent means null`.
  - `prefs_test`: `term_app round-trips and a missing launcher falls back to the first` (`termAppFor('d', ['Terminal'])` with stored `iTerm` → `Terminal`).
  - `devices_tab_test`:
    - `one button per listed shell, default first` (keys `new-shell-<name>`, labels `zsh`, `bash`).
    - `tapping a shell opens it with the chosen app` (fake hub records `{'cmd':'open_term','shell':'/bin/bash','app':'iTerm'}` after `term-app-iTerm` is tapped).
    - `the 终端 app row shows only with two launchers`.
    - `an old device gets one 默认 shell button` (sends no `shell`).
    - `no new row without launchers`.
    - `a refused open shows its words under the row` (key `new-shell-error`, text = the hub's words; button busy while pending, then enabled).
  - `terms_entry_test`: text mode, no pty rows, launchers present → `NewText('/bin/zsh')`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** the panel rows per spec §2.1–§2.4 (Chinese copy from Global Constraints). Track busy/error per device in the devices tab state next to `_removeErrors`.
- [ ] **Step 4: Run** `flutter test` — PASS.
- [ ] **Step 5: Commit** `feat(gui): open a text terminal by shell; 终端 app is a per-device setting`.

### Task 7: GUI rename

**Files:**
- Modify: `gui/lib/hub_client.dart`, `gui/lib/ui/{main_state,devices_tab}.dart`, `gui/lib/term/term_id.dart`
- Test: `gui/test/ui/devices_tab_test.dart`, `gui/test/hub_client_test.dart`

**Interfaces:**
- Consumes: Task 4 `rename_term` / `term_renamed`; Task 6 `TermHost.shells`.
- Produces:
  - `HubClient.renameTerm(String id, String term, String name) -> Future<void>` (request `{'cmd':'rename_term','id','term','name'}`, waits for `term_renamed`, then `terms(id)`).
  - `String? cleanTermName(String s)` in `term_id.dart`: the same rule as Rust `clean_name`.
  - `MainState.renameTerm(String device, String term, String name) -> Future<void>`: throws on an invalid name or a refusal.
  - In `_TermRow` the name is an `InlineEdit` (key `term-name-<id>`) only when the local host row's `shells != null`; otherwise a plain `Text`.

- [ ] **Step 1: Write the failing tests:**
  - `renaming a row sends rename_term with the trimmed name`.
  - `an invalid name is not sent and the old name stays`.
  - `a refusal shows under the list` (key `rename-error`).
  - `an old device has no inline edit`.
  - `cleanTermName` table: `' a '`→`'a'`, `''`→null, 64/65 chars, a control character→null.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `flutter test` — PASS.
- [ ] **Step 5: Commit** `feat(gui): rename a text terminal on its device`.

### Task 8: `CLI ·` titles and a stage that scales both ways

**Files:**
- Modify: `gui/lib/term/term_id.dart`, `gui/lib/ui/{main_state,top_bar,session_model,session_row}.dart`, wherever favorites / project members / overview labels render a member's name, `gui/lib/term/term_stage.dart`, `gui/lib/term/term_painter.dart` (only if needed for crispness)
- Test: `gui/test/term/term_stage_test.dart`, `gui/test/term/term_main_test.dart`, `gui/test/ui/top_bar_test.dart` (or the existing top-bar test file)

**Interfaces:**
- Produces:
  - `String termTitle(String name) => 'CLI · $name'` in `term_id.dart`.
  - `MainState.termName(String device, String term) -> String?`: the row's current name from `hub.termLists`.
  - Every label of a session or member whose app `isTermApp` is `termTitle(termName(...) ?? <stored name>)`. This covers the top-bar title, the session list row, the overview tag and the favorites/project names; the device panel row keeps the bare name.
  - `SessionEntry.paneTitle` and the top bar's `pane.command ·` prefix and `· pane.title` suffix are removed.
  - Stage: `_scale = shown ? math.min(w / gridW, h / gridH) : 1.0`. `_scaledNote`, `_scaledNoteH`, the `term-scaled` text and any props only it used are removed.

- [ ] **Step 1: Write the failing tests:**
  - `the top bar says CLI · zsh`.
  - `the title follows a rename` (a `terms` event renames the row → top bar shows `CLI · 后端` without reopening).
  - `a favorite of a terminal is labelled CLI ·`.
  - Stage tests replacing `a pane larger than the stage is scaled down with the note`:
    - `a small pane is scaled up to fill`: 10×2 grid in a stage of 40 cells × 20 rows → `painter.scale` == `min(40cw/10cw, 20ch/2ch)` = 4.
    - `a large pane is scaled down`: scale < 1.
    - `no scaled note`: `term-scaled` is never found.
    - `selection maps to cells when scaled up`: at scale 4, a drag from the centre of cell (1,0) to the centre of cell (3,0) selects columns 1–3.
    - Also update `term_main_test.dart:263` (the old note test).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.** If glyphs drawn under `canvas.scale` look soft on a real Retina screen at scale 2–4 (check by running the app, `/run`), paint with metrics measured at `fontSize * scale` instead of scaling the canvas. The tests above must pass either way.
- [ ] **Step 4: Run** `flutter analyze` and `flutter test` — PASS.
- [ ] **Step 5: Commit** `feat(gui): CLI · titles; the terminal stage scales up as well as down`.

### Task 9: Docs and final check

**Files:**
- Modify: `docs/superpowers/specs/2026-11-16-rapp-text-terminal-design.md` (§2.1–§2.4, §4.2, §6 point to the new spec), `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md` (top note: tmux parts removed 2026-11-16, see the new spec), `docs/superpowers/specs/2026-11-13-rapp-config-reference.md` (§2.4 `term_app`; `term.json` only `allow`, old fields ignored), `docs/superpowers/specs/2026-11-16-rapp-term-entry-design.md` (status line → done, with the branch head).

- [ ] **Step 1: Edit the docs** as listed.
- [ ] **Step 2: Full verification.** `cd rust && cargo test` — PASS. `cd gui && flutter analyze && flutter test` — PASS, then `git checkout -- gui/pubspec.lock`. `grep -rniE 'tmux|ssh 主机|SSH host' rust gui/lib` — only the intentional compat tests.
- [ ] **Step 3: Commit** `docs: terminal entry cleanup — point the older specs at the new one`.
