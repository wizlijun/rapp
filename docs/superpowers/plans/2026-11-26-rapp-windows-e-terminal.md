# rApp Windows — Phase E (Text Terminal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From any controller, open, list, attach to and end text terminals on a Windows machine, and from a Windows controller use terminals on any host — Claude Code, vim and `cmd` behave as on macOS, and terminals survive a service restart and an upgrade.

**Architecture:** `rapp-term` keeps one code base. The modules that never touched the system stay as they are; `holder`, `local`, `launch`, `fg`, `saved`, `shell` each get a Windows arm behind a small internal seam, and the unix arm is not edited. `run` holds the program in a bundled ConPTY inside the user's terminal window; `serve` reaches it over loopback TCP.

**Tech Stack:** Rust; `portable-pty` 0.9.0 (already a dependency) with the bundled `conpty.dll` + `OpenConsole.exe`; `windows-sys` (the version in `rust/Cargo.lock`); tokio TCP.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` — §9, §8.1 (row 孤儿进程), §13.2 (private files), §15.5 (rows 文本终端). The terminal's own specs stay authoritative for behaviour: `docs/superpowers/specs/` `text-terminal`, `term-entry`, `term-fit`, `term-restore`. Line numbers in the Windows spec are for main `0decfe8d`; `rapp-term` has grown since (restore, shell reports) — find sites by content.

**Written before its probes.** Written 2026-11-26, before **T1, T5** (level 1) and **T2, T3, T4** (level 2) ran. Read the probe results first.

| Probe | If it failed | What changes here |
|---|---|---|
| T1 (bundled ConPTY passes OSC 7501/7502, `portable-pty` loads it) | `portable-pty` cannot load the bundled copy → Task 2 uses the own wrapper `pty/conpty.rs` (described there). The bundled copy also swallows the sequences → **stop and ask the user** (program status would be missing on Windows) | Task 2 |
| T5 (a tab can be opened from the background service and survives restarts) | no tab from the service → always open a plain console window. Does not survive → **stop and ask the user** | Task 5 |
| T2 (pass-through console) | list the failing feature for the legacy console window as a known limit | Task 3 |
| T3 (`ESC[8;r;ct`) | nothing: the controller already scales | — |
| T4 (reading another process's directory) | use the shell report or the start directory only | Task 4 |

## Decisions made in this plan (not in the spec; `rapp-term` gained these after the spec was written)

1. **Restore after reboot** (`pty/saved.rs`, `pty/resume.rs`) works on Windows. Snapshots are plain files; “is that holder alive” becomes “its `.port` answers”; boot time comes from the system uptime.
2. **Shell reports** (`pty/shell.rs`, OSC 7502): Git Bash uses the existing `rapp.bash` hook. PowerShell and pwsh get a hook given **inline on the command line** (`-NoExit -Command <text>`), not a script file, so the machine's script execution policy is neither needed nor changed. `cmd.exe` has no hook: its directory comes from Task 4's probe or the start directory.
3. **The macOS consent prompt** (`pty/consent.rs`) has no Windows counterpart; its non-macOS arm already answers “nothing to ask”.

## Global Constraints

- Phase A is merged: `rust/term/src/main.rs` dispatches to `unix_main.rs` or `stub_main.rs`; this phase replaces the stub.
- **The unix arm is not edited.** A function that needs a Windows arm is split by `#[cfg(unix)]` / `#[cfg(windows)]` at the smallest unit; the unix body moves, unchanged, at most. `cargo test -p rapp-term` on the Mac runs the same tests with the same count as before each task.
- No code is copied from hurryvc; no terminal that rApp did not open is taken over.
- The four rules for Windows processes (spec §8.2). **Terminal windows leave the service's job object** (`CREATE_BREAKAWAY_FROM_JOB`); nothing else does.
- `LOCAL_V = 2`, the request line, the token line and every message of the local channel are unchanged. Exit code 129 means “the window was closed” on every platform.
- Terminals run as the owner, in the owner's login session. No terminal before login.
- `libc` becomes a `[target.'cfg(unix)'.dependencies]` entry; nothing under `cfg(windows)` uses it.
- Never log what is typed or what the program prints.
- Branch `feat/windows-term`; merge per `CLAUDE.md`.

## Review Focus

1. **The terminal window is closed with the ✕ while a program runs:** the program is ended, `run` exits 129 within the 5 s Windows allows, the `.port` file is removed, `serve`'s list no longer shows it. → Task 3.
2. **`run` is killed hard (Task Manager):** the stale `.port` file is cleaned at the next list; a new terminal gets a fresh port; nothing connects to a recycled port and treats a stranger as a holder (the token line protects this — tested). → Task 1.
3. **Output containing bytes that are not valid UTF-8, split across reads, and a 4-byte character split across reads:** the viewer's screen equals the local window's. → Task 2.
4. **Ctrl+C typed in the window while a long command runs:** the command gets it; `run` does not exit. → Task 3.
5. **Service restart and upgrade with three terminals open:** all three keep running, stay listed and stay attachable. → Task 5.

## File map

```
rust/term/
  Cargo.toml                 libc → unix only; windows-sys for cfg(windows)
  src/main.rs                dispatcher: unix_main | win_main (stub_main.rs is deleted)
  src/win_main.rs            the same sub-commands as unix_main, Windows arms
  src/pty/local.rs           shared: token, head, status, names. Split out:
  src/pty/local_unix.rs        UnixStream / UnixListener, `<pid>.sock`      (moved code)
  src/pty/local_win.rs         TcpStream / TcpListener, `<pid>.port`
  src/pty/holder.rs          shared run loop over the seams below
  src/pty/console.rs         trait Console (raw mode, size, events) + unix impl (moved) 
  src/pty/console_win.rs     Windows console: VT in/out, size, close/logoff/shutdown events
  src/pty/conpty.rs          (only if T1 says so) own loader for the bundled conpty.dll
  src/pty/launch.rs          + Windows arm: Windows Terminal tab or console window
  src/pty/launch_win.rs      command line building (pure), CreateProcessW with breakaway
  src/pty/fg.rs              + Windows arm: newest descendant, name, directory
  src/pty/saved.rs           + Windows arm: private file, alive check, boot time
  src/pty/shell.rs           + PowerShell inline hook; Git Bash through rapp.bash
  src/serve.rs               installed_shells() uses shells.rs on Windows; kill → local `end`
  tests/win_*.rs             Windows tests (`#![cfg(windows)]`)
scripts/fetch-conpty.ps1     downloads the pinned ConPTY package, checks its SHA-256
scripts/stage-windows.ps1    stages rapp-term.exe, conpty.dll, OpenConsole.exe
```

## Component choices

| Need | Component | Notes |
|---|---|---|
| Pseudo console | NuGet package `Microsoft.Windows.Console.ConPTY`, one exact version and SHA-256 written into `scripts/fetch-conpty.ps1` (the version probe T1 passed with); files `conpty.dll` (x64) and `OpenConsole.exe` (x64) staged beside `rapp-term.exe` | MIT licence; add to the third-party notices (phase G) |
| Loading it | `portable-pty`'s `native_pty_system()`: on Windows it loads `conpty.dll` from the program's directory before falling back to the system's. `run` **refuses to start** (exit 1, `conpty.dll not found beside rapp-term.exe`) when the bundled copy is missing, rather than silently using the system's | T1 |
| If `portable-pty` cannot load it | `pty/conpty.rs`: `LoadLibraryExW(<dir>\conpty.dll, LOAD_WITH_ALTERED_SEARCH_PATH)`; `ConptyCreatePseudoConsole(size, in, out, flags, &hpc)`, `ConptyResizePseudoConsole`, `ConptyClosePseudoConsole`; child started with `CreateProcessW` + `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`. Same seam as below | T1 |
| Local channel | `tokio::net::{TcpListener, TcpStream}` on `127.0.0.1:0`; port in `pty\<pid>.port` (decimal, one line), written to a temporary name and renamed | §9.3 |
| Outer console | `SetConsoleMode`: input `ENABLE_VIRTUAL_TERMINAL_INPUT` only (no line input, echo, processed input, mouse, window input); output `ENABLE_PROCESSED_OUTPUT \| ENABLE_VIRTUAL_TERMINAL_PROCESSING \| DISABLE_NEWLINE_AUTO_RETURN`; code pages 65001 in and out; all restored on exit | T2 |
| Size changes | poll `GetConsoleScreenBufferInfo` (window rectangle) every 100 ms; no `WINDOW_BUFFER_SIZE_EVENT` (it needs window input mode, which changes what arrives on stdin) | T2 |
| Window closed, logoff, shutdown | `SetConsoleCtrlHandler`: `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT`, `CTRL_SHUTDOWN_EVENT` → end as “window closed” (129) and **block the handler thread until clean-up is done** (the process is killed when the handler returns; 5 s limit). `CTRL_C_EVENT` and `CTRL_BREAK_EVENT` cannot arrive (processed input is off): Ctrl+C is the byte 0x03 on stdin | — |
| Ending the program | close the pseudo console (it ends every attached process); wait 2 s; `TerminateProcess` on the shell if still there | — |
| Opening a window | Windows Terminal installed (`%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe` exists) → `wt.exe -w 0 new-tab --title <name> -- <rapp-term.exe> run …`; else `CreateProcessW(rapp-term.exe run …)` with `CREATE_NEW_CONSOLE`. Both with `CREATE_BREAKAWAY_FROM_JOB`, started with the owner's token in the owner's session (it is `rapp-term serve`, already the owner, that starts it) | T5 |
| Foreground program | process snapshot (`CreateToolhelp32Snapshot`): the newest (by creation time) descendant of the shell that is attached to this pseudo console; none → the shell | T4 |
| Its directory | in this order: the shell report (OSC 7502); OSC 9;9 (Windows Terminal's convention, emitted by many prompts) seen in the output; T4's process read if it passed; the start directory | T4 |
| Uptime for restore | `GetTickCount64` | — |

---

### Task 1: The local channel over loopback TCP

**Files:** Modify `rust/term/Cargo.toml`, `src/pty/local.rs`, `src/pty/mod.rs`; create `src/pty/local_unix.rs` (moved code), `src/pty/local_win.rs`, `tests/win_local.rs`.

**Interfaces — Produces** (platform-neutral names; the unix file re-exports today's types under them so callers stop naming `UnixStream`):

```rust
// local.rs
pub type Stream = /* unix: tokio::net::UnixStream; windows: tokio::net::TcpStream */;
pub type Listener = /* unix: tokio::net::UnixListener; windows: tokio::net::TcpListener */;
pub fn endpoint_path(term_dir: &Path, pid: u32) -> anyhow::Result<PathBuf>;   // unix: pty/<pid>.sock (today's socket_path); windows: pty\<pid>.port
pub async fn listen(term_dir: &Path, pid: u32) -> anyhow::Result<(Listener, PathBuf)>;   // windows: bind 127.0.0.1:0, write the port file
pub async fn connect(path: &Path, op: &str, token: &str) -> std::io::Result<Stream>;      // windows: read the port, connect 127.0.0.1:<port>
pub fn gone(e: &std::io::Error) -> bool;        // windows: ConnectionRefused, NotFound, a port file that does not parse
pub fn endpoints(term_dir: &Path) -> Vec<PathBuf>;   // what `scan_all` walks: *.sock or *.port
```

`socket_path` stays as a unix alias so no unix caller changes. `ensure_dirs` and `token` on Windows create the directory and the token through `rapp_net::private` (plan A) instead of mode bits. `name_lock` uses a lock file opened with share mode none on Windows.

- [ ] **Step 1: Tests (`tests/win_local.rs`, `#![cfg(windows)]`).** `status_round_trip_over_tcp` (a listener answering one `status`; `local::status` returns it); `wrong_token_is_refused`; `stale_port_file_is_gone` (a port file naming a closed port → `gone` → `scan_all` removes it and reports nothing); `a_stranger_on_a_recycled_port_is_not_a_holder` (a plain TCP echo server on the port in a `.port` file: `status` returns a probe error, the file is **not** deleted, nothing is listed); `garbage_port_file_is_removed`; `port_file_is_written_whole` (never observed empty: 200 concurrent reads while it is rewritten).
- [ ] **Step 2:** Windows: fails to compile. **Step 3:** Implement; the Mac's `cargo test -p rapp-term` keeps its count.
- [ ] **Step 4:** Commit `feat(term): the run–serve channel over loopback TCP on Windows`.

### Task 2: `run` — the program in a bundled ConPTY

**Files:** Modify `src/pty/holder.rs`; create `src/pty/console.rs`, `src/pty/console_win.rs`, `scripts/fetch-conpty.ps1`, `tests/win_run.rs`; (only if T1 says so) `src/pty/conpty.rs`.

**Interfaces — Produces:**

```rust
// console.rs — what `run` needs from the window it sits in
pub enum ConsoleEvent { Resized { rows: u16, cols: u16 }, Closed /* → 129 */, Stop(i32) /* unix signals other than HUP */ }
pub trait Console: Send {
    fn is_terminal() -> bool where Self: Sized;
    fn enter_raw(&mut self) -> std::io::Result<()>;        // restored on drop
    fn size(&self) -> Option<(u16, u16)>;                  // rows, cols
    fn events(&mut self) -> tokio::sync::mpsc::UnboundedReceiver<ConsoleEvent>;
    fn name(&self) -> Option<String>;                      // unix: ttyname; windows: None
}
pub fn console() -> Box<dyn Console>;                      // UnixConsole (today's code, moved) | WinConsole
pub fn kill_tree(pid: u32, hard: bool);                    // unix: today's signals; windows: TerminateProcess (hard only)
```

`holder::run` keeps its shape: the unix-only lines named in the map (`isatty`, `tcgetpgrp`, the four signal streams, `TIOCGWINSZ`, `Raw`) move behind `Console`; the select loop takes `ConsoleEvent`s. The unix behaviour — which signal ends the run, which is passed on, the settle rules and their tests — is carried by `UnixConsole` + `ConsoleEvent::Stop(sig)` and stays byte for byte.

Exit codes on Windows: the program's own; 129 for `Closed`; **0 when rApp ended the terminal** (local `end` request), so a Windows Terminal tab closes by itself (spec §9.4).

- [ ] **Step 1: Tests (`tests/win_run.rs`; they start `rapp-term.exe run` inside a ConPTY created by the test, so the test is its “window”).** `echo_reaches_the_viewer` (run `cmd /c echo hello`; `status` then the view shows `hello`; exit code 0); `exit_code_is_the_programs` (`cmd /c exit 7` → 7); `osc_7501_and_7502_pass_through` (a helper program prints both sequences; the holder's program status and shell state show them — this is T1's check kept as a regression test); `invalid_utf8_and_split_characters` (the helper prints `ff fe`, then a 4-byte character in two writes 50 ms apart; the viewer's grid equals the expected cells); `resize_follows` (the test resizes its ConPTY; within 500 ms the inner size and `status` agree); `ctrl_c_goes_to_the_program` (send 0x03 while `ping -t 127.0.0.1` runs: ping ends, `run` keeps running the shell); `closing_the_window_gives_129_and_removes_the_port_file` (the test closes its ConPTY); `end_request_gives_0`; `missing_conpty_dll_refuses_to_start` (run a copy of the exe from a directory without the dll → exit 1 and the fixed message).
- [ ] **Step 2:** fails. **Step 3:** Implement; `scripts/fetch-conpty.ps1` downloads the pinned package into `rust/target/conpty/` and a `build.rs`-free approach is used: tests and the stage script copy the two files beside the exe (a helper in `tests/common`).
- [ ] **Step 4:** Mac count unchanged; Windows green.
- [ ] **Step 5:** Commit `feat(term): run holds the program in the bundled ConPTY`.

### Task 3: The outer console — pass-through, close, real terminals

**Files:** `src/pty/console_win.rs` (complete), `tests/win_run.rs`.

- [ ] **Step 1: Tests.** `console_modes_are_restored_on_exit` (read the test ConPTY's modes before and after); `input_is_vt` (arrow up arrives as `ESC [ A`; a pasted 10 000-character line arrives whole and in order).
- [ ] **Step 2:** Implement as in “Component choices”.
- [ ] **Step 3: By hand, in a Windows Terminal tab and in a legacy console window (`conhost`), results into `tasks/todo.md`:** Claude Code (typing, Chinese, paste, mouse, resize); vim (arrows, `:q`); `cmd` line editing and history; PowerShell's PSReadLine; Ctrl+C in each; close the tab with ✕ while `ping -t` runs (Review Focus 1: listed terminals shrink by one within 2 s, no `ping.exe` left); log off with a terminal open.
- [ ] **Step 4:** Commit `feat(term): pass-through console and clean close on Windows`.

### Task 4: Foreground program, directory, shell reports, restore

**Files:** Modify `src/pty/fg.rs`, `src/pty/shell.rs`, `src/pty/saved.rs`; create `tests/win_fg.rs`.

**Interfaces.** `fg::probe`, `fg::launch_info` gain `#[cfg(windows)]` arms with today's signatures; the holder asks “who is in front” through a new `fn foreground(shell_pid: u32) -> i32` (unix: `tcgetpgrp` as today; Windows: newest descendant). `prog_name` strips `.exe` case-insensitively on Windows so titles read `claude`, not `claude.exe`. `shell::start_through_hook(shell, term_dir)` gains: `powershell.exe` / `pwsh.exe` → arguments `-NoLogo -NoExit -Command <inline hook>`; `bash.exe` under a Git directory → today's `rapp.bash` path, written with `rapp_net::private`; `cmd.exe` → no hook. The inline PowerShell hook wraps the existing `prompt` function and prints OSC 7502 with the directory before calling the original; it prints nothing else and defines one function and one variable, both prefixed `__rapp`.

`saved.rs`: file creation through `rapp_net::private::write` on Windows; `alive(pid)` → the holder's endpoint answers `status` (not a signal); boot time from `GetTickCount64`.

- [ ] **Step 1: Tests.** Portable (run on the Mac): `prog_name_strips_exe` (`C:\x\Claude.EXE` → `Claude`; unix input unchanged); `powershell_hook_is_one_line_and_quotes_safely` (no newline, no unescaped `"`; a directory containing `'`, a space and Chinese survives the encode/decode in `shell::parse`). Windows: `foreground_is_the_newest_descendant` (`cmd` → `ping`: name `ping`; after it ends: `cmd`); `directory_from_the_powershell_hook` (start PowerShell through the hook, `cd` to a temp directory, the holder's `fg` shows it within 2 s); `directory_falls_back_to_the_start_directory_for_cmd`; `snapshot_survives_and_restores` (the existing restore tests' Windows twins: a saved terminal whose holder is gone is offered; one whose holder answers is not).
- [ ] **Step 2–3:** fail, implement. If T4 passed, add the process read as the third source and its test `cmd_directory_is_read_after_cd`.
- [ ] **Step 4:** Commit `feat(term): foreground program, directory and restore on Windows`.

### Task 5: `serve` — shells, opening a window, staying alive

**Files:** Modify `src/serve.rs` (`installed_shells()`, the open path), `src/pty/launch.rs`; create `src/pty/launch_win.rs`, `tests/win_serve.rs`; modify `src/main.rs`, create `src/win_main.rs`, delete `src/stub_main.rs` and `tests/unsupported.rs`; `rust/testkit` Windows `bins()` now uses the real `rapp-term.exe` where the unix tests do.

**Interfaces — Produces:**

```rust
// launch_win.rs — pure, tested on the Mac
pub enum Host { WindowsTerminal(PathBuf), Console }
pub fn host(local_app_data: Option<&Path>, exists: &dyn Fn(&Path) -> bool) -> Host;
/// The full command line for CreateProcessW, quoted by the Windows rules (backslashes before quotes doubled).
pub fn command_line(host: &Host, rapp_term: &Path, run_args: &[String], title: &str) -> String;
pub fn quote_arg(s: &str) -> String;
// windows only
pub fn spawn_detached(command_line: &str, cwd: Option<&Path>, new_console: bool) -> std::io::Result<u32>;   // breakaway from the job
```

`launch::launchers()` on Windows returns `["Windows Terminal"]` or `["控制台窗口"]` by `host()`; `launch::open` dispatches to `launch_win`; `command_file` is not used on Windows (no script file). `NO_ANSWER` and `ASKING` never occur. `installed_shells()` on Windows returns `shells::installed()` (the existing table: default `cmd.exe`; `cmd`, `PowerShell`, `pwsh`, `Git Bash`, `Git sh`; never `System32\bash.exe`).

- [ ] **Step 1: Tests.** Portable: `quote_arg_table` (`a b` → `"a b"`; `a\"b` and `C:\dir with space\` — the trailing backslash doubled before the closing quote; empty string → `""`; Chinese untouched); `wt_command_line` (exact string for a title with a space and a run command with a quoted path); `host_picks_console_without_wt`. Windows: `shell_list_has_cmd_first_and_never_wsl_bash`; `open_starts_a_run_that_reports_within_5_s` (console-window host; the terminal appears in the list with the asked name); `opened_terminal_is_outside_the_job` (start `serve` inside a kill-on-close job made by the test, open a terminal, close the job: the `run` process is still alive and still answers `status`) — Review Focus 5 in small; `start_timeout_when_the_launcher_does_nothing`.
- [ ] **Step 2–3:** fail, implement.
- [ ] **Step 4: By hand (T5's list as acceptance):** from a Mac controller: 新建 with Windows Terminal open (a new tab in the existing window), with no window, on Server 2022 without Windows Terminal; three terminals open, then `rapp-svc ctl restart`, then kill `rapp-svc`, then (when phase G exists) an upgrade: all three stay listed and attachable; ⌘T in the same directory; 结束终端 closes the tab.
- [ ] **Step 5:** Commit `feat(term): serve opens Windows Terminal tabs and console windows`.

### Task 6: Stage, service capability, acceptance

- [ ] **Step 1:** `scripts/stage-windows.ps1` runs `fetch-conpty.ps1`, stages `rapp-term.exe`, `conpty.dll`, `OpenConsole.exe`; fails if a hash differs. The service then reports `terminal: true` with no code change (`bins::find("rapp-term")`).
- [ ] **Step 2:** `rust/hub` and the workspace now build on Windows without the stub: remove any “phase E” exclusion plan A left in `scripts/check-windows.ps1`.
- [ ] **Step 3: Acceptance:** walk the 文本终端 rows of spec §15.5 from a Mac controller against Windows, and from a Windows controller against a Mac; write pass / fail / 有限制 into `tasks/todo.md` under `## Windows 版 E 段（文本终端）`, with the by-hand lists of Tasks 3 and 5 and the known limits of the legacy console window.
- [ ] **Step 4:** `git merge main`; Mac gate (test count of `rapp-term` unchanged or larger, none removed) and Windows gate green; merge to local `main`: `merge: Windows 文本终端（feat/windows-term）`.

## Done when

The 文本终端 rows of spec §15.5 pass in both directions; three open terminals survive a service restart; the unix arm of `rapp-term` has no changed line other than moves.
