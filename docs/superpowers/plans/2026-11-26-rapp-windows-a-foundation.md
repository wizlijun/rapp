# rApp Windows — Phase A (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Rust workspace and the Flutter app compile, test and build on Windows without changing one behaviour on macOS, Linux or iOS, and put the two-machine rules and the Windows gate in place.

**Architecture:** Every change is a `cfg(windows)` arm added beside an untouched unix arm. All Windows system calls this phase needs live in one file, `rust/net/src/win.rs`; the other crates call small `rapp-net` functions that exist on every system. Two new crates enter the workspace as shells. What Windows cannot do yet (text terminals, capture, update) answers “不支持” or is simply absent from the staged directory; nothing is half-wired.

**Tech Stack:** Rust stable, target `x86_64-pc-windows-msvc`; `windows-sys` and `socket2` (both already in `rust/Cargo.lock`) as `cfg(windows)` dependencies of `rapp-net` only; Flutter (the version the Mac uses, 3.44.1 on 2026-11-26); Windows PowerShell 5.1 for scripts.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` — §17.2 row A is this plan's scope and done line; §8 lists the seams; §13.1–13.2 the paths and “设成私有”; §14.3–14.5 the gates and the `CLAUDE.md` rules; §5.1 and §5.3 the layout and the crates; §19.2 the old-doc fixes. Line numbers in the spec are for main `0decfe8d`; find the code by content when they have moved.

## Global Constraints

- **Needs probe G1** (plan P, Task 3) to have passed, except Task 1, which needs nothing and is done first (plan P needs it).
- **“unix 那一支一个字不动”** (spec §8): a seam adds a `#[cfg(windows)]` arm, or widens a `cfg` attribute to include Windows. It does not rewrite, move or reformat the code macOS and Linux run. Where this plan replaces `Command::new(x)` by `rapp_net::proc::command(x)`, the function is the identity on unix; that is the only kind of edit to unix lines allowed here.
- macOS, Linux and iOS behaviour is unchanged. The Mac gate commands are unchanged: `swift test`, `cargo test --workspace --no-fail-fast`, `cargo clippy` `-D warnings`, `flutter analyze`, `flutter test`.
- **Not touched:** `Sources/` (U10), `rust/host-linux/` (U9), `rust/client-gtk/`, `rust/hub-ffi/`. `rust/relay/` only what Task 7 Step 1 names — the three `#[cfg(unix)]` attributes in `src/audit.rs` and the unix-only gating of `src/admin.rs` — both approved by the user on 2026-11-26 (the relay is the only gate; anything more needs a new OK).
- **Not in this phase** (do not start them here): `resident` / `prelogin` fields and `--prelogin` (phase F); Windows `permissions` / `capabilities` arm (§6.1, phase D); job objects and “detach from the job” (phases C, E, F); `rapp-update` on Windows (phase G); terminals on Windows (phase E); the runner rename to `rapp-gui.exe` and the Dart “设成私有” choice (§10.3, §13.2, phase C).
- Four rules for every Windows process (spec §8.2): no console window; die with the parent (terminals excepted); sibling programs by full path with `.exe`, never through `PATH`; paths through path APIs, never a hand-written `/`.
- `unsafe` added by this plan appears only in `rust/net/src/win.rs`.
- No new field on the wire, in IPC answers or in config files. `VERSION` (picture protocol 16) does not change.
- Never log passwords, tokens, keys, typed text or clipboard contents. A test that needs a secret uses a made-up one.
- Work on branch `feat/windows-foundation`. Tasks 2–8 are written and tested **on the Windows machine** (the Mac cannot compile `cfg(windows)` code). Before the branch merges, the same commit passes the Mac gate on a Mac: push the branch (not `main`), fetch it on the Mac into a worktree, run the gate, report. Both green → merge on the Windows machine → the integration session pushes (Task 1).
- This plan changes shared crates, so by `CLAUDE.md` it counts as a macOS change and the Mac release session will cut a patch release from it. That is expected.
- Feature sessions do not change version numbers, tag, or create releases (`CLAUDE.md`).
- Scripts under `scripts/` for Windows are ASCII only (Windows PowerShell 5.1 reads a BOM-less UTF-8 file as the system code page) and must run under Windows PowerShell 5.1, which is what Server 2022 ships.
- User-facing text is Chinese, in the wording this plan gives. On the Mac: `grep` is ugrep, use `/usr/bin/grep`; Flutter is `~/development/flutter/bin/flutter`. Never read `docs/archives/`.
- Commit by path. No `git stash`, no `cargo fmt --all`.

## Review Focus

Things a Windows user will meet that the happy-path tests of a "make it compile" phase would never touch. Each is pinned to a task.

1. **The user name is not ASCII or has a space** (`C:\Users\张 三`): every path this phase handles stays an `OsString` / `Path`; nothing goes through a lossy string. → Task 3 (`private`, `bins::find`, log directory tests run in a directory named `张 三`), Task 6 (`current` lookup).
2. **The data root is on a drive whose folders inherit access for `Users` or `Everyone`** (`D:\rapp`): after `prepare`, `local` is readable by this user, SYSTEM and Administrators only. → Task 3.
3. **Another program holds a secret file open for a moment** (antivirus, indexer) while it is being replaced: `write_private` retries the rename, the old file stays whole until it succeeds, and the temporary file is never broader than the final one. → Task 3.
4. **`current` is missing, empty, has a BOM, CRLF or spaces, or points outside the install directory** (`..\x`, `C:\x`): `rapp.exe` says it cannot find the interface and exits 1; it never starts a program outside the install directory. → Task 6.
5. **Standard input is not what `rapp-service` expects**: started by hand from a launcher with no stdin, it must keep running; started with `--supervised`, stray bytes on stdin are ignored and only end-of-input stops it. → Task 4.

---

## File Map

| File | What it is for | Task |
|---|---|---|
| `CLAUDE.md` | §14.5 items 1–4 | 1 |
| `.gitattributes` | no line-ending conversion on any machine | 1 |
| `rust/Cargo.toml` | two new members; `windows-sys`, `socket2` as workspace dependencies | 2, 3 |
| `rust/host-windows/` | shell crate; Cargo bin target `rapp-host-windows` | 2 |
| `rust/svc-windows/` | shell crate; bin `rapp-svc` | 2 |
| `rust/net/src/win.rs` | **new**, `cfg(windows)`: every Windows system call of this phase | 3 |
| `rust/net/src/private.rs` | **new**: “设成私有” for a directory and a file | 3 |
| `rust/net/src/proc.rs` | **new**: start a program without a console window | 3 |
| `rust/net/src/{datadir,config,log,bins,quic}.rs` | Windows arms | 3 |
| `rust/service/src/{main,lib,instance,cm,workers,data}.rs`, `supervise.rs` (**new**) | Windows arms | 4 |
| `rust/hub/src/session.rs`, `rust/update/src/runner.rs` | quiet process start | 4 |
| `rust/term/src/{lib,main}.rs`, `pty/mod.rs`, `unix_main.rs` (**moved**), `stub_main.rs` (**new**) | wrap the unix-only parts | 5 |
| `rust/cli/src/{main,gui}.rs` (`gui.rs` **new**) | start the interface, UTF-8 console | 6 |
| `rust/testkit/tests/common/mod.rs`, `rust/relay/src/audit.rs`, tests across the workspace | make the tests build and pass on Windows | 7 |
| `rust/.cargo/config.toml` | static C runtime for the Windows target | 8 |
| `scripts/check-windows.ps1`, `scripts/stage-windows.ps1` | the Windows gate; a version directory for development | 8 |
| `tasks/todo.md`, the documents listed in spec §19.2 | checks, findings, stale sentences | 9 |

---

### Task 1: Rules, line endings, the Windows machine, the integration session

No probe needed. Done first; plan P's Windows probes depend on it.

**Files:**
- Modify: `CLAUDE.md:15`, `CLAUDE.md:22` (after it), `CLAUDE.md:30`, end of file
- Create: `.gitattributes`
- Modify: `docs/superpowers/specs/2026-11-26-rapp-windows-probe-results.md` (machine inventory; created by plan P Task 1 — create it with that task's skeleton if it does not exist yet)

**Interfaces:**
- Produces: a Windows checkout whose path is written in `CLAUDE.md`; a running integration session on that machine; branch `feat/windows-foundation`.

- [x] **Step 1 (done 2026-11-27: the user approved the text and it is on main; only the Windows checkout path is still to fill in, Step 5): Ask the user to approve the four `CLAUDE.md` changes** (one question, showing the text below). `CLAUDE.md` is not edited without that OK. The wording is spec §14.5 (the last sentence of item 1 is that section's own explanation, moved into the rule so the release session reads it); `<Windows checkout>` is filled in at Step 4.

  1. After the sentence ending “也不发 macOS 版。” on line 30, add:
     > 只影响 Windows 的改动（`rust/host-windows/`、`rust/svc-windows/`、`gui/windows/`、`scripts/` 里 Windows 的脚本、`cfg(windows)` 里的代码）也不发 macOS 版，但要过门禁并立刻推到 `origin/main`，Windows 机器等着用。只改文档的合并同样立刻推。改到共用代码（`rust/host-core/`、`rapp-service` 这些 crate 里不带 `cfg(windows)` 的部分、共用的 Dart）照常算 macOS 的改动。
  2. Line 15 becomes:
     > 2. 完成且自测通过后，**合并到自己这台机器的本机 `main` 即可**（Mac 上是 `/Users/bruce/git/rapp`，Windows 机器上是 `<Windows checkout>`）：
  3. New item 5 under “其他 session（做功能的）”, after line 22:
     > 5. Windows 相关：改了 `cfg(windows)` 里的代码，要在 Windows 机器上过了 Windows 的门禁（`scripts/check-windows.ps1`）再合并；给协议加被控端行为时，`host-core` 和它的样本在同一个提交里改；改了 `Sources/rapp-host/` 里被 `host-core` 对照表引用的文件，同一个提交里看 `host-core` 要不要跟着改，并更新对照表里的摘要。
  4. New subsection at the end of the file:
     > ### Windows 集成 session（首发前）
     >
     > - Windows 机器上常开一个 session：本机 `main` 有新合并，就 `git fetch origin`、合并 `origin/main`、跑 Windows 的门禁、推到 `origin/main`；推被拒就再 fetch、合并、重跑。
     > - 首发前它只是**集成** session：不改版本号、不打 tag、不建 release、不动 `website/releases.json`。要给自己人装，就按需打内部 zip。
     > - 冲突由后推的一方解决；不强推。

- [ ] **Step 2: Apply the approved text and add `.gitattributes`** with exactly:

```
* -text
```

  Reason to write in the commit message: the index has no CRLF file today and macOS / Linux convert nothing; Git for Windows defaults to `core.autocrlf=true`, which would rewrite every file on checkout and make byte-exact fixtures (plan B) differ. `* -text` makes the repository behave the same on every machine whatever its Git settings.

- [ ] **Step 3: Verify on the Mac.** `git status --short` after `git add --renormalize .` lists nothing but `.gitattributes` and `CLAUDE.md`. Commit both by path: `docs: Windows 的协作规则和换行规则`. Merge into the local `main` per `CLAUDE.md` (docs only, no release).

- [ ] **Step 4: Prepare the Windows machine** (the developer desktop of spec §17.3). Install: Git for Windows; Visual Studio 2022 Build Tools with “Desktop development with C++”; Rust via rustup (stable, host `x86_64-pc-windows-msvc`, the same `rustc` minor version as the Mac: run `rustc --version` on both); Flutter at the Mac's version (`flutter --version` on the Mac), `flutter config --enable-windows-desktop`, `flutter doctor` clean for Windows. Then:

```
git config --global core.autocrlf false
git config --global core.longpaths true
git clone <origin> <Windows checkout>
```

  Expected: `git status` clean right after the clone; `git ls-files --eol` shows no `w/crlf`.

- [ ] **Step 5: Record the machine** in the probe-results page's machine inventory: Windows edition and build, CPU, GPU, checkout path, the four tool versions. Put the checkout path into `CLAUDE.md` item 2 (same docs branch or a follow-up docs commit).

- [ ] **Step 6: Open the integration session** on the Windows machine with the subsection from Step 1.4 as its standing instruction. Until Task 8 lands, its “Windows gate” is: `git fetch`, merge, `cargo metadata --manifest-path rust/Cargo.toml --format-version 1` succeeds. Prove the loop once: a docs-only merge made on the Windows machine reaches `origin/main`, and the Mac's `git fetch` sees it.

---

### Task 2: The two Windows crates enter the workspace

**Files:**
- Modify: `rust/Cargo.toml` (`members`)
- Create: `rust/host-windows/Cargo.toml`, `rust/host-windows/src/main.rs`, `rust/host-windows/src/lib.rs`
- Create: `rust/svc-windows/Cargo.toml`, `rust/svc-windows/src/main.rs`
- Create: `rust/host-windows/tests/shell.rs`, `rust/svc-windows/tests/shell.rs`

**Interfaces:**
- Produces: package `rapp-host-windows` with `[[bin]] name = "rapp-host-windows"` and an empty `[lib] name = "rapp_host_windows"`; package `rapp-svc-windows` with `[[bin]] name = "rapp-svc"`. Later phases fill them.
- `rust/host-core` is plan B, Task 1. If it has not merged when this task starts, do that task's crate-creation steps here (they are the same steps) and tell plan B's executor.

**The bin target is named `rapp-host-windows`, not `rapp-host`.** `rust/host-linux` already declares `[[bin]] name = "rapp-host"`; a second target with that name in one workspace makes `cargo test --workspace` on the Mac warn about an output filename collision and leaves `target/*/rapp-host` to whichever built last. `host-linux` is not edited (U9), so the new crate takes the other name and `scripts/stage-windows.ps1` (Task 8) copies it to `rapp-host.exe`. `rapp-svc` has no such clash.

- [ ] **Step 1: Write the failing tests.** Both files are whole-file `#![cfg(not(windows))]`:

```rust
// rust/host-windows/tests/shell.rs
#[test]
fn says_windows_only_elsewhere() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_rapp-host-windows")).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(String::from_utf8_lossy(&out.stderr).trim(), "rapp-host: 只支持 Windows");
    assert!(out.stdout.is_empty());
}
// rust/svc-windows/tests/shell.rs: the same with `rapp-svc` and "rapp-svc: 只支持 Windows"
```

- [ ] **Step 2: Run them.** `cargo test -p rapp-host-windows -p rapp-svc-windows` → fails: packages do not exist.

- [ ] **Step 3: Create the crates.** `version`, `edition`, `publish` from the workspace, like `rust/testkit/Cargo.toml`. No dependencies yet. `main` on non-Windows prints the line above to stderr and exits 2. `main` on Windows prints `rapp-host: 这一版还不能当被控端` (for `rapp-svc`: `rapp-svc: 这一版还没有监督程序`) to stderr and exits 1; phases D and C replace these. Add `"host-windows", "svc-windows"` to `members` after `"speech-linux"`.

- [ ] **Step 4: Run.** `cargo test -p rapp-host-windows -p rapp-svc-windows` → 2 passed. `cargo build --workspace 2>&1 | /usr/bin/grep -c "output filename collision"` → `0`. `cargo clippy --workspace --all-targets -- -D warnings` → clean.

- [ ] **Step 5: Commit** by path: `feat(windows): host-windows 和 svc-windows 的空壳进 workspace`.

---

### Task 3: `rapp-net` — Windows system calls, private files, quiet processes, sibling lookup, dual stack, log directory

**Files:**
- Modify: `rust/Cargo.toml` (`[workspace.dependencies]`), `rust/net/Cargo.toml`, `rust/net/src/lib.rs`
- Create: `rust/net/src/win.rs`, `rust/net/src/private.rs`, `rust/net/src/proc.rs`
- Modify: `rust/net/src/datadir.rs:22-26`; `rust/net/src/config.rs:95-111`, `:129-138`; `rust/net/src/log.rs:213-228`, `:276-290`; `rust/net/src/bins.rs`; `rust/net/src/quic.rs:348-356`

**Interfaces:**
- Produces (used by Tasks 4, 5, 6 and by phases C–G):

```rust
// rust/net/src/private.rs — every system
pub const SID_SYSTEM: &str = "S-1-5-18";
pub const SID_ADMINS: &str = "S-1-5-32-544";
/// unix: mode 0700. Windows: inheritance off; full control for this user, SYSTEM, Administrators,
/// inherited by everything created inside.
pub fn dir(path: &Path) -> std::io::Result<()>;
/// unix: mode 0600. Windows: inheritance off; full control for the same three.
pub fn file(path: &Path) -> std::io::Result<()>;
#[cfg(windows)] pub struct Acl { pub protected: bool, pub sids: Vec<String> } // sorted, no duplicates
#[cfg(windows)] pub fn acl(path: &Path) -> std::io::Result<Acl>;
#[cfg(windows)] pub fn current_user_sid() -> std::io::Result<String>;

// rust/net/src/proc.rs — every system
/// `Command::new(program)`; on Windows also "no console window" (CREATE_NO_WINDOW, 0x0800_0000).
pub fn command(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command;
pub fn tokio_command(program: impl AsRef<std::ffi::OsStr>) -> tokio::process::Command;

// rust/net/src/win.rs — #[cfg(windows)] pub mod win
pub fn session_id() -> u32;                       // the login session this process is in
pub struct NamedMutex(/* handle */);              // closed on drop; the system closes it if the process dies
impl NamedMutex { pub fn acquire(name: &str) -> std::io::Result<Option<NamedMutex>>; } // None: it already exists
pub fn console_utf8();                            // output code page 65001; nothing when there is no console
pub fn has_console() -> bool;                     // GetConsoleWindow is not null
```

- Dependencies (my call): `windows-sys` at the newest version already in `rust/Cargo.lock` (0.61 on 2026-11-26) and `socket2 = "0.6"`, declared once in `[workspace.dependencies]`, used under `[target.'cfg(windows)'.dependencies]` of `rapp-net` only. `windows-sys` features: whatever the calls below need, no more (expected: `Win32_Foundation`, `Win32_Security`, `Win32_Security_Authorization`, `Win32_System_Threading`, `Win32_System_RemoteDesktop`, `Win32_System_Console`). `host-windows` and `svc-windows` pick their own binding (`windows`, for COM and WinRT) in their phases; that does not go through `rapp-net`.
- `libc` stays in the manifest as it is; it builds on Windows. Only its *use* is unix-only, and it already sits inside `#[cfg(unix)] mod sys`.

- [ ] **Step 1: Write the failing tests.** Tests that touch a directory create it as `tempdir().path().join("张 三")` (Review Focus 1).

```rust
// private.rs — every system
#[test] fn dir_and_file_are_private() {
    // unix: metadata mode & 0o777 == 0o700 / 0o600.
    // windows: acl(p) == Acl { protected: true, sids: sorted_dedup([current_user_sid()?, SID_SYSTEM, SID_ADMINS]) }
}
#[cfg(windows)] #[test] fn dir_drops_what_it_inherited() {
    // Review Focus 2. Grant Users explicitly first:
    //   %SystemRoot%\System32\icacls.exe <dir> /grant *S-1-5-32-545:(OI)(CI)F   (through proc::command)
    // then private::dir(&d); acl(&d).sids has no "S-1-5-32-545" and no "S-1-1-0"; protected == true.
}
#[cfg(windows)] #[test] fn files_made_inside_a_private_dir_are_private() {
    // private::dir(&d); fs::write(d.join("k"), b"x"); acl(&d.join("k")).sids == the same three.
}

// config.rs
#[test] fn write_private_replaces_and_stays_private() {
    // write twice to <dir>/k.json; content is the second; no k.tmp left;
    // unix 0o600; windows acl(..) == the three, protected.
}
#[cfg(windows)] #[test] fn write_private_waits_out_a_short_lock() {
    // Review Focus 3. Open the destination WITHOUT delete sharing
    //   (OpenOptions::new().read(true).share_mode(1 /* FILE_SHARE_READ */)), release it from another
    //   thread after 60 ms; write_private succeeds; content is new.
}
#[cfg(windows)] #[test] fn write_private_keeps_the_old_file_when_the_lock_stays() {
    // Same lock held for the whole call: Err; destination still holds the old bytes; the .tmp is gone.
}
#[cfg(windows)] #[test] fn hostname_comes_from_the_environment() {
    // hostname() == std::env::var("COMPUTERNAME").unwrap(); non-empty.
}

// proc.rs
#[cfg(windows)] #[test] fn child_has_no_console() {
    // The test binary runs itself: command(current_exe()).args(["--exact", "proc::tests::probe", "--nocapture"])
    //   .env("RAPP_PROC_PROBE", "1"); stdout contains "console=false".
    // Falsify once by hand: with std::process::Command::new instead, it prints "console=true"
    //   when the tests are run from a terminal. Write that in the commit message.
}
#[cfg(windows)] #[test] fn probe() { if std::env::var_os("RAPP_PROC_PROBE").is_some() { println!("console={}", win::has_console()); } }

// bins.rs
#[cfg(windows)] #[test] fn never_looks_in_path() {
    assert!(find("cmd", None).is_none());                    // cmd.exe is on every PATH
    // a dir holding "x.exe": find("x", Some(dir)) == Some(dir.join("x.exe"))
}

// log.rs — log_dir_from takes the environment as a function, so these need no real variables
#[cfg(windows)] #[test] fn log_dir_on_windows() {
    // LOCALAPPDATA=C:\L                      -> C:\L\rapp\logs
    // only USERPROFILE=C:\Users\张 三        -> C:\Users\张 三\AppData\Local\rapp\logs
    // RAPP_HOME=D:\r                         -> D:\r\local\logs      (unchanged rule)
}

// win.rs
#[test] fn named_mutex_is_exclusive_and_released() {
    // name = format!(r"Local\rapp-test-{}", std::process::id());
    // a = acquire(name) is Some; acquire(name) is None; drop(a); acquire(name) is Some.
}

// quic.rs
#[cfg(windows)] #[tokio::test] async fn dual_stack_takes_v4_and_v6() {
    // s = sys::bind_dual()?; port = s.local_addr().port(); send one datagram from 127.0.0.1 and one from ::1
    // to that port; both arrive.
}
```

- [ ] **Step 2: Run on Windows.** `cargo test -p rapp-net` → does not compile (`private`, `proc`, `win` missing).

- [ ] **Step 3: Implement `win.rs`, `private.rs`, `proc.rs`.**
  - `private` on Windows: build one ACL with three entries (current user from the process token, `SID_SYSTEM`, `SID_ADMINS`; `GENERIC_ALL`; for `dir`, object-inherit + container-inherit) and set it with the DACL marked protected (`SetEntriesInAclW`, then `SetNamedSecurityInfoW` with `DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION`). When the process itself is SYSTEM the user and SYSTEM entries are the same; that is fine. `acl` reads it back (`GetNamedSecurityInfoW`, `ConvertSidToStringSidW`). Paths are converted with `OsStrExt::encode_wide`, never through `to_str`.
  - `proc::command` on Windows: `std::os::windows::process::CommandExt::creation_flags(0x0800_0000)`; tokio's `Command` has its own `creation_flags`.

- [ ] **Step 4: Add the Windows arms at the existing sites.** In each, the `#[cfg(unix)]` block stays as it is and a `#[cfg(windows)]` block is added next to it.
  - `datadir.rs:22-26`: `crate::private::dir(&loc)` with the same error context style (`"设成私有 {}"` is not user-visible; keep English like its neighbour: `"make private {}"`).
  - `config.rs` `write_private`: on Windows, after opening the temporary file and **before** `write_all`, call `private::file(&tmp)`. The rename is retried on `PermissionDenied`: 10 tries, 20 ms apart; on final failure remove the temporary file and return the error.
  - `log.rs` `open_private`: `private::dir(dir)` after creating it, result ignored like the unix `set_permissions`.
  - `log.rs` `log_dir_from`, Windows arm: `LOCALAPPDATA`, else `USERPROFILE` joined with `AppData`, `Local`, else `.`; then `rapp`, `logs`. (Today the fallback is `HOME`, which Windows does not set, and it would land inside the data root.)
  - `config.rs` `hostname`: on Windows read `COMPUTERNAME` (no child process, so no console window); empty or missing → `"rapp"`, like unix.
  - `bins.rs` `find`: on Windows return after the `bin_dir` and own-directory steps; the `PATH` step is unix-only.
  - `quic.rs`: change `#[cfg(not(unix))] mod sys` into `#[cfg(windows)] mod sys` with a real `bind_dual` (`socket2`: IPv6 datagram socket, `set_only_v6(false)`, bind `[::]:0`, convert to `std::net::UdpSocket`, non-blocking as the unix one leaves it) and `getaddrinfo_v6` (`ToSocketAddrs` on `(host, port)`, first IPv6 address that is not IPv4-mapped); keep the old stub under `#[cfg(not(any(unix, windows)))]`.

- [ ] **Step 5: Run.** Windows: `cargo test -p rapp-net` → all pass. Mac: `cargo test -p rapp-net` → every test that ran before still runs and passes, plus the two new ones without a `cfg` (`dir_and_file_are_private`, `write_private_replaces_and_stays_private`). `cargo clippy -p rapp-net --all-targets -- -D warnings` clean on both.

- [ ] **Step 6: Commit** by path: `feat(net): Windows 的私有文件、不弹窗口的进程、双栈和日志目录`.

---

### Task 4: `rapp-service` — single instance, `--supervised`, update options, interface path, quiet workers

**Files:**
- Modify: `rust/service/src/main.rs` (lines 1–3 doc comment, 8–9 and 19–30 `cfg`, 13–16 arguments, `stopped()`), `rust/service/src/instance.rs`, `rust/service/src/lib.rs:112-128`, `rust/service/src/cm.rs:9-12`, `rust/service/src/workers.rs:128`, `:183-202`, `:284…`, `rust/service/src/data.rs:129`, `:250`
- Create: `rust/service/src/supervise.rs`
- Modify: `rust/hub/src/session.rs:58`, `rust/update/src/runner.rs:50`
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md` (called `config-reference` below): `--supervised`, the Windows update cache directories, the Windows log fallback from Task 3

**Interfaces:**
- Consumes: `rapp_net::win::{NamedMutex, session_id}`, `rapp_net::proc::{command, tokio_command}`.
- Produces:

```rust
// rust/service/src/supervise.rs — no cfg; tested on the Mac
pub struct Args { pub supervised: bool }
/// `windows` is `cfg!(windows)` at the call site. Off Windows any argument is a usage error, as today.
pub fn parse_args(args: &[String], windows: bool) -> Result<Args, String>;   // Err = the usage line
/// Resolves when `r` reaches end of input or fails. Bytes read are thrown away.
pub async fn closed<R: tokio::io::AsyncRead + Unpin>(r: R);
/// The single-instance name. `prelogin` is always false in this phase (phase F passes true).
pub fn mutex_name(session: u32, prelogin: bool) -> String;
/// Where downloaded updates wait. `system_mode`: installed with the system service.
pub fn update_cache_dir_from(env: &dyn Fn(&str) -> Option<std::path::PathBuf>, system_mode: bool) -> std::path::PathBuf;

// rust/service/src/instance.rs
#[cfg(windows)] pub fn acquire() -> std::io::Result<Option<rapp_net::win::NamedMutex>>;

// rust/service/src/lib.rs
#[cfg(windows)] impl UpdateOpts { pub fn windows(version_dir: PathBuf, supervised: bool, system_mode: bool) -> Self; }
```

- [ ] **Step 1: Write the failing tests** (`supervise.rs`, run on every system unless marked):

```rust
#[test] fn arguments() {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    assert!(!parse_args(&s(&[]), false).unwrap().supervised);
    assert!(parse_args(&s(&["--supervised"]), false).is_err());          // macOS, Linux: unchanged
    assert_eq!(parse_args(&s(&["x"]), false).unwrap_err(),
        "usage: rapp-service   (data root: $RAPP_HOME, data-root pointer or ~/rapp)");
    assert!(!parse_args(&s(&[]), true).unwrap().supervised);
    assert!(parse_args(&s(&["--supervised"]), true).unwrap().supervised);
    assert!(parse_args(&s(&["--prelogin"]), true).is_err());             // phase F
    assert!(parse_args(&s(&["--supervised", "--supervised"]), true).is_err());
    assert_eq!(parse_args(&s(&["x"]), true).unwrap_err(),
        r"usage: rapp-service [--supervised]   (data root: %RAPP_HOME%, data-root pointer or %USERPROFILE%\rapp)");
}
#[tokio::test] async fn closed_waits_for_end_of_input() {
    // Review Focus 5. let (mut w, r) = tokio::io::duplex(64); let c = tokio::spawn(closed(r));
    // w.write_all(b"junk\n") -> after 100 ms c is not finished;
    // drop(w) -> c finishes within 1 s.
}
#[test] fn names() {
    assert_eq!(mutex_name(3, false), r"Local\com.rapp.service.3");
    assert_eq!(mutex_name(0, true), r"Local\com.rapp.service.0.prelogin");
}
#[test] fn cache_dirs() {
    // env ProgramData=P, LOCALAPPDATA=L, USERPROFILE=U (PathBufs):
    // (system_mode = true)  -> P/rapp/update;  without ProgramData -> C:\ProgramData/rapp/update
    // (system_mode = false) -> L/rapp/update;  without LOCALAPPDATA -> U/AppData/Local/rapp/update
    // Build the expected values with Path::join so the test passes on any separator.
}
// instance.rs
#[cfg(windows)] #[test] fn ownership_is_exclusive_and_released_on_drop() {
    // the Linux test of the same name, with acquire() returning the mutex
}
// data.rs
#[cfg(windows)] #[tokio::test] async fn a_new_sync_repository_does_not_convert_line_endings() {
    // Let the service initialise the sync repository in a temp data root (the path the test at
    // data.rs:491 takes, but through the real init at :129). Then `git config --local --get core.autocrlf`
    // prints "false". No git on the machine -> eprintln!("git not available; skipping") and return,
    // as datadir.rs's git test does.
}
```

- [ ] **Step 2: Run.** `cargo test -p rapp-service supervise` → does not compile.

- [ ] **Step 3: Implement `supervise.rs`** and wire `main.rs`:
  - Argument handling uses `parse_args(&args, cfg!(windows))`; a usage error prints the line and exits 2 as today.
  - `mod instance` and the guard widen from `#[cfg(target_os = "linux")]` to `#[cfg(any(target_os = "linux", windows))]`. A second instance prints `rapp-service: already running for this user` and returns, as on Linux. The Windows `acquire` is `NamedMutex::acquire(&mutex_name(session_id(), false))`.
  - `stopped()` gets a `#[cfg(windows)]` arm: Ctrl+C, or — only when `args.supervised` — `supervise::closed(tokio::io::stdin())`. Without the flag stdin is never read (Review Focus 5: a service started by hand from a launcher has a closed stdin and must keep running).
  - Update: `UpdateOpts::system` becomes `#[cfg(unix)]`, body untouched. `UpdateOpts::windows` fills `bundle: version_dir`, `launchd: supervised`, `cache_dir: update_cache_dir_from(&|k| std::env::var_os(k).map(Into::into), system_mode)`, `install_level: None`, the same durations. In `main.rs` the Windows arm sets `update: None` with a comment `// phase G turns this on (spec §12.3)`. On Windows `rapp_update::bundle_of` already returns `None`; do not touch `rapp-update`.

- [ ] **Step 4: The other seams.**
  - `cm.rs` `gui_path`: Windows arm → the directory of `current_exe` joined with `rapp-gui.exe`. (`RAPP_GUI` still wins, as on unix.)
  - `workers.rs` `reset_permissions`: the `tccutil` branch runs only on macOS; on Windows the function returns the same success value the Linux branch returns, doing nothing. Add the Windows case to the existing tests of this function in the style they already use.
  - Data sync (spec §8.1): right after the `init` at `data.rs:129`, a `#[cfg(windows)]` line runs `config core.autocrlf false` in the new repository, through the same `self.run`. An existing repository is not touched. “No `git.exe`” needs no code: the existing “git missing → say so, do not sync” path already covers it; check that it does on a Windows machine without Git and write the result in the commit message.
  - Every place in product code that starts a program: `rapp_net::proc::command` / `tokio_command` instead of `Command::new` — `workers.rs:128`, the worker spawn at `:284…`, `data.rs:250` (`git` is not a sibling program, so it is still found through `PATH`; it must not flash a window; `data.rs:323` only ever runs on macOS and stays), `hub/src/session.rs:58`, `update/src/runner.rs:50`. Sites inside `#[cfg(test)]` modules are left alone. `data.rs:250` also passes `-c core.hooksPath=/dev/null`, and the tests set `GIT_CONFIG_GLOBAL=/dev/null`: Git for Windows is expected to accept both; confirm with the new test below and, if it does not, add a Windows arm using `NUL` (Task 7, rule 4). `cm.rs:48` starts the interface, which is not a console program; leave it. Afterwards `/usr/bin/grep -rn "Command::new" rust/service/src rust/hub/src rust/update/src rust/net/src rust/cli/src | /usr/bin/grep -v "proc.rs"` lists only `cm.rs` (the interface), `data.rs`'s macOS-only `xcode-select` line, `net/src/config.rs`'s `hostname` (the `cfg(not(windows))` arm; Windows reads `COMPUTERNAME`), `cli/src/main.rs`'s start of the interface (inside `cfg(windows)`, not a console program), and lines inside `#[cfg(test)]` modules; paste the list into the commit message.
  - `main.rs` doc comment: add one line for `--supervised`.
  - `config-reference`: the three entries named under Files, in the same commit (spec §13.4).

- [ ] **Step 5: Run.** `cargo test -p rapp-service -p rapp-hub -p rapp-update` on both systems → pass. Mac: `cargo test --workspace --no-fail-fast` → same result as `main`.

- [ ] **Step 6: Commit** by path: `feat(service): Windows 的单实例、--supervised 和不弹窗口的 worker`.

---

### Task 5: `rapp-term` — wrap the unix-only parts, answer “不支持” on Windows

**Files:**
- Modify: `rust/term/src/lib.rs` (`serve`), `rust/term/src/pty/mod.rs` (`holder`, `local`, `launch`), `rust/term/src/pty/fg.rs:166` (test)
- Move: `rust/term/src/main.rs` → `rust/term/src/unix_main.rs` (`git mv`; `fn main` becomes `pub fn main`, nothing else changes)
- Create: `rust/term/src/main.rs` (dispatcher), `rust/term/src/stub_main.rs`
- Create: `rust/term/tests/unsupported.rs`
- Modify: `rust/term/tests/cli.rs`, `pty.rs`, `serve.rs` (first line `#![cfg(unix)]`)

**Interfaces:**
- Produces: on Windows, `rapp_term::{config, id, keys, list, proto, screen, sender, shells, unread, wire}` and `rapp_term::pty::{fg, fit, grid, ps, sweep, title, view, wintitle}` compile; `serve`, `pty::holder`, `pty::local`, `pty::launch` do not exist there until phase E. `rapp-hub` and `rapp-service` use only `config` and `id` on Windows (`pty::launch::desktop_env` is Linux-only at both call sites), so they compile.
- `rapp-term.exe` in this phase: any arguments → stderr `rapp-term: Windows 上还不支持文本终端`, exit 1, nothing on stdout. It is not staged (Task 8), so the service reports `terminal: false` without any code change (`workers.rs` asks `bins::find("rapp-term")`).

- [ ] **Step 1: Write the failing test.**

```rust
// rust/term/tests/unsupported.rs
#![cfg(windows)]
#[test]
fn every_subcommand_says_not_supported() {
    for args in [&["version"][..], &["version", "--json"], &["run"], &["serve", "--token-env", "T", "--config", "c"], &[]] {
        let out = std::process::Command::new(env!("CARGO_BIN_EXE_rapp-term")).args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(1), "{args:?}");
        assert_eq!(String::from_utf8(out.stderr).unwrap().trim(), "rapp-term: Windows 上还不支持文本终端");
        assert!(out.stdout.is_empty());
    }
}
```

- [ ] **Step 2: Run on Windows.** `cargo test -p rapp-term` → does not compile (`std::os::unix`, `libc::kill`, …).

- [ ] **Step 3: Gate.** `#[cfg(unix)]` on `pub mod serve;` and on `pub mod holder; pub mod local; pub mod launch;`. If another module then fails on Windows because it names one of the four, gate that *item* (function, `impl`, test), not its module, and list each one in the commit message. `fg.rs`'s test that deserialises `pty::local::Status` gets `#[cfg(unix)]`. The new `main.rs`:

```rust
#[cfg(unix)] mod unix_main;
#[cfg(not(unix))] mod stub_main;
fn main() {
    #[cfg(unix)] unix_main::main();
    #[cfg(not(unix))] stub_main::main();
}
```

  Keep the module doc comment of the old `main.rs` at the top of `unix_main.rs`.

- [ ] **Step 4: Run.** Windows: `cargo test -p rapp-term` → `unsupported` passes, the library's unit tests of the listed modules pass. Mac: `cargo test -p rapp-term` → the same tests and count as on `main` (`main.rs` stays as the dispatcher, so git shows `unix_main.rs` as a new file, not a rename; compare the contents instead: `git diff main:rust/term/src/main.rs HEAD:rust/term/src/unix_main.rs` → the only difference is `fn main` → `pub fn main`).

- [ ] **Step 5: Commit** by path: `feat(term): unix 专用的部分包起来，Windows 上先报不支持`.

---

### Task 6: `rapp-cli` — start the interface, UTF-8 console

**Files:**
- Create: `rust/cli/src/gui.rs`
- Modify: `rust/cli/src/main.rs` (start of `main`)

**Interfaces:**
- Consumes: `rapp_net::win::console_utf8`.
- Produces (`gui.rs`, no `cfg`, tested on the Mac; only called on Windows):

```rust
/// `Some(args for the interface)` when `argv` is empty or its first word is `--cm` or `--background`.
pub fn launch_args(argv: &[String]) -> Option<Vec<String>>;
/// The version directory name written in `current`, or None when the text is not exactly one
/// directory name starting with `app-`.
pub fn version_dir_name(current_text: &str) -> Option<&str>;
/// Where `rapp-gui.exe` is: beside `own_exe` if it exists there, else `<own dir>\..\<current>\rapp-gui.exe`.
/// `exists` and `read` are the file system, passed in for tests.
pub fn gui_exe(own_exe: &Path, exists: &dyn Fn(&Path) -> bool, read: &dyn Fn(&Path) -> Option<String>) -> Result<PathBuf, PathBuf>; // Err = the path that was looked for
```

- [ ] **Step 1: Write the failing tests** (`gui.rs`):

```rust
#[test] fn which_arguments_start_the_interface() {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    assert_eq!(launch_args(&s(&[])), Some(vec![]));
    assert_eq!(launch_args(&s(&["--cm"])), Some(s(&["--cm"])));
    assert_eq!(launch_args(&s(&["--background"])), Some(s(&["--background"])));
    assert_eq!(launch_args(&s(&["share", "3000"])), None);
    assert_eq!(launch_args(&s(&["--version"])), None);
    assert_eq!(launch_args(&s(&["--help"])), None);
}
#[test] fn current_is_one_directory_name() {            // Review Focus 4
    assert_eq!(version_dir_name("app-0.16.3"), Some("app-0.16.3"));
    assert_eq!(version_dir_name("\u{feff}app-0.16.3 \r\n"), Some("app-0.16.3"));
    for bad in ["", "\r\n", "0.16.3", r"app-1\..\..\x", "app-1/x", r"C:\x", r"..\app-1", "app-", "app-1\napp-2"] {
        assert_eq!(version_dir_name(bad), None, "{bad:?}");
    }
}
#[test] fn finds_the_interface() {
    // Build paths with Path::join. inst = <tmp>/张 三/rapp   (Review Focus 1)
    // own = inst/app-1/rapp-cli.exe, inst/app-1/rapp-gui.exe exists      -> Ok(inst/app-1/rapp-gui.exe)
    // own = inst/bin/rapp.exe, current = "app-2\r\n", inst/app-2/rapp-gui.exe exists -> Ok(inst/app-2/rapp-gui.exe)
    // own = inst/bin/rapp.exe, current missing                            -> Err(inst/current)
    // own = inst/bin/rapp.exe, current = "..\\x"                          -> Err(inst/current)
    // own = inst/bin/rapp.exe, current = "app-3", no such file            -> Err(inst/app-3/rapp-gui.exe)
}
```

- [ ] **Step 2: Run.** `cargo test -p rapp-cli gui` → does not compile.

- [ ] **Step 3: Implement `gui.rs`**, then in `main.rs`, as the first statements of `main` under `#[cfg(windows)]`: call `rapp_net::win::console_utf8()`; if `launch_args(&argv)` is `Some(a)`, resolve `gui_exe`, start it with `a` (plain `std::process::Command`, all three standard streams null, not waited for) and exit 0; on `Err(p)` print `找不到 rApp 的界面程序（<p>）` to stderr and exit 1. Off Windows nothing changes: no arguments still prints the usage text.

- [ ] **Step 4: Run.** `cargo test -p rapp-cli` on both systems → pass; on the Mac the existing tests are unchanged.

- [ ] **Step 5: Commit** by path: `feat(cli): Windows 上不带子命令时启动界面，控制台输出 UTF-8`.

---

### Task 7: The tests build and pass on Windows

Windows machine only.

**Files:**
- Modify: `rust/testkit/tests/common/mod.rs:33-41` (`bins()`)
- Modify: `rust/relay/src/audit.rs:11`, `:74`, `:123` — three `#[cfg(unix)]` attributes, approved by the user (Step 1)
- Modify: `rust/relay/src/admin.rs` — the unix code behind `#[cfg(unix)]`, a stand-in elsewhere, approved by the user (Step 1); `rust/conn/tests/relay.rs` (three tests) and `rust/testkit/tests/key_change.rs` (five tests) — `#[cfg(unix)]` on the eight key-change tests, which rotate the key through the admin interface
- Modify: `services/state/src/disk.rs`, `rust/service/src/load/disks.rs` — unix-only code that entered `main` after this plan was first written (Step 2)
- Modify: tests that fail on Windows, per the rule in Step 4. Known candidates: `rust/testkit/tests/term.rs:337`, `service.rs:286,292,324,573-576`; `rust/update/src/lib.rs:354`, `apply.rs:533`; `rust/service/src/shares.rs:361`, `data.rs:403,543,613,798,817,822`; `rust/net/src/bins.rs:35`; `rust/net/src/datadir.rs:267`; `rust/testkit/tests/hub_terms.rs:121`
- Modify: `tasks/todo.md`

**Interfaces:**
- Consumes: everything from Tasks 2–6.
- Produces: `cargo test --workspace --no-fail-fast --exclude rapp-relay --exclude rapp-host-linux --exclude rapp-client-gtk --exclude rapp-hub-ffi` green on Windows; the list of tests switched off there, each with the phase that switches it back on.

- [ ] **Step 1: The relay library compiles on Windows.** `--exclude rapp-relay` only skips that package's own tests. `rapp-conn` and `rapp-testkit` have it as a dev-dependency (`rust/conn/Cargo.toml:25`, `rust/testkit/Cargo.toml:52`) and start a relay inside their tests, so its *library* is compiled on Windows whatever is excluded, and `rust/relay/src/audit.rs` uses `std::os::unix` without a `cfg` in three places. **The user approved this on 2026-11-26** (the relay is the only gate, so it was asked): put `#[cfg(unix)]` on the import at `:11` and on the two `.mode(…)` calls at `:74` and `:123` (split the builder chains into statements to do it). **Second file, approved by the user on 2026-11-26** after the code draft showed the three attributes are not enough: `rust/relay/src/admin.rs` is built on Unix sockets throughout (`:12` `PermissionsExt`, `:25` `tokio::net::{UnixListener, UnixStream}`, used at `:69`, `:157`–`:200`, permission bits at `:174`, `:373`, `:384`), and `server.rs` binds it at every start. Its unix code goes behind `#[cfg(unix)]` unchanged — no reordering, no rewriting; on other systems the module offers a stand-in with the same public names and signatures (`Server::bind` opens nothing, `serve` does nothing, `call` and `issue_key` return an error): there is no admin interface on Windows. The tests that rotate the relay's key do it through the admin interface, so the whole key-change group — eight tests: three in `rust/conn/tests/relay.rs` (`:208`, `:225`, `:267`) and five in `rust/testkit/tests/key_change.rs` — gets `#[cfg(unix)]` on each test (helpers only they use too) and goes on the list of Step 4 with the reason “中继的管理接口只在 unix 上有”. The user accepted this on 2026-11-26: the key-change logic is the same code on every system and stays tested on the Mac and Linux; on Windows it is checked once by hand in phase H (plan H Task 5 Step 2). The other tests through a relay (connect, netmon, forward) run on Windows. Nothing else in `rust/relay/` changes — not `server.rs`, not `store.rs`; if the library still does not compile on Windows, stop and ask the user; `src/main.rs` is not touched (the binary is not built on Windows: a dev-dependency builds only the library); the relay is still never built for or shipped on Windows. Verify on Linux or the Mac: `cargo test -p rapp-relay` → the same tests pass as on `main`, and the audit file a test writes still has mode `0600` (the existing audit tests assert it; if none does, add that assertion under `#[cfg(unix)]`). Anything beyond these three attributes needs a new question to the user.

- [ ] **Step 2: `bins()` on Windows.** The unix arm (symlinks) stays. Windows arm: copy `CARGO_BIN_EXE_fake-rapp-host`, `…-fake-rapp-client`, `…-fake-rapp-term` and `CARGO_BIN_EXE_test-rapp-state` into the temporary `RAPP_BIN_DIR` as `rapp-host.exe`, `rapp-client.exe`, `rapp-term.exe`, `rapp-state.exe` (four programs since 0.15.48). In the same step, the two places that became unix-only after this plan was first written, without which `rapp-service` and `rapp-testkit` do not compile on Windows: `services/state/src/disk.rs` (permission bits only under `cfg(unix)`; on Windows the private-file call of Task 3) and `rust/service/src/load/disks.rs` (the working disk read by drive letter with `GetDiskFreeSpaceExW`, behind `cfg(windows)`; the unix arm unchanged).

- [ ] **Step 3: First full run.** In `rust/`: the command under Produces. Save the output to `.build-logs/windows-sweep-1.log`. Expected: failures; that list is the work of this task.

- [ ] **Step 4: Go through every failure with this rule** (no `#[ignore]`, no deleting a test):
  1. It asserts unix permission bits → `#[cfg(unix)]` on that assertion, and beside it the Windows assertion with `rapp_net::private::acl` where Task 3 made the thing private.
  2. It needs something Windows does not have until a later phase (terminals → E; applying an update → G; a real `rapp-host` → D) → `#[cfg(unix)]` on the test, and one line in `tasks/todo.md` under a new heading `## Windows 版：现在在 Windows 上关着的测试`, format `- [ ] <file>::<test> —— <段> 做完时打开`.
  3. It is the test's own unix habit (`sh`, `#!/bin/sh` scripts, `/tmp`, a hand-written `/`, symlinks, `chmod`) and the behaviour under test exists on Windows → fix the test so it runs on both, keeping what it proves. A fake program written as a shell script becomes a `cfg(windows)` `.cmd` twin only if the test is about the *caller*; otherwise rule 2.
  4. It is a real bug in shared code on Windows (a path joined by hand, a `HOME` lookup, a port that Windows reserves) → fix the code with a `cfg(windows)` arm or a path API, add or keep the test, and say so in the commit message. A reserved port in 28000–28999 is spec §8.2's N1: report the failure as “端口被占”, do not special-case it here.
  5. It fails one run in several → run it alone three times; if it passes alone, note it in the commit message as load-dependent and move on; if not, it is rule 3 or 4.

- [ ] **Step 5: Run until green.** The command from Step 3 → `test result: ok` for every package, 0 failed. Then `cargo clippy --workspace --all-targets --exclude rapp-relay --exclude rapp-host-linux --exclude rapp-client-gtk --exclude rapp-hub-ffi -- -D warnings` → clean. Dead-code warnings that appear only on Windows are fixed by gating the unused item, not by `#[allow]`.

- [ ] **Step 6: Mac check.** Push the branch, fetch it on a Mac, `cargo test --workspace --no-fail-fast` and clippy `-D warnings` → the same results as `main`; the number of tests run on the Mac has not dropped (compare the `test result:` lines per package against `main`; a `#[cfg(unix)]` never removes a Mac test).

- [ ] **Step 7: Commit** by path, one commit per crate where practical: `test(windows): <crate> 的测试在 Windows 上能编能过`.

---

### Task 8: The Windows gate, the staged directory, the Flutter build

Windows machine only.

**Files:**
- Create: `rust/.cargo/config.toml`
- Create: `scripts/check-windows.ps1`, `scripts/stage-windows.ps1`
- Modify: Dart files and tests only as far as G1's result and Step 4 require
- Modify: `CLAUDE.md` is **not** touched here (it already names `scripts/check-windows.ps1`, Task 1)

**Interfaces:**
- Produces:
  - `scripts/check-windows.ps1 [-Build]` — the Windows gate, steps 1–3 of spec §14.3; with `-Build` also `flutter build windows --release` and `stage-windows.ps1 -Release -Gui`. Runs every step even after a failure, prints one line per step (`ok` / `FAILED`), writes everything to `.build-logs/check-windows.log` whose last line is `EXIT=<0|1>`, and exits with that status.
  - `scripts/stage-windows.ps1 [-Release] [-Gui] [-Out <dir>]` — builds and lays out `<Out>\` (default `.build\windows-stage`) as spec §5.1: `current` (one line, `app-<workspace version>`), `bin\rapp.exe`, `app-<version>\…`. Phase G's packaging starts from this script.

- [ ] **Step 1: Static C runtime** (spec §12.6: Rust programs carry the C runtime inside them). cargo looks for this file from the current directory upward and ignores `--manifest-path`, so every Windows script must `cd rust` before it calls cargo (the two scripts of this task do; the packaging script of phase G must too). `rust/.cargo/config.toml`:

```toml
[target.x86_64-pc-windows-msvc]
rustflags = ["-C", "target-feature=+crt-static"]
```

  It affects that target only. Verify: after `cargo build -p rapp-cli`, `dumpbin /dependents target\debug\rapp-cli.exe` lists no `VCRUNTIME140.dll`. Mac: `cargo build -p rapp-cli` still up to date apart from this crate's own changes.

- [ ] **Step 2: `stage-windows.ps1`.** Programs staged in this phase, by `cargo build -p` (explicit packages, like `scripts/build-linux.sh:27`):

| Package → built file | Staged as | Staged now |
|---|---|---|
| `rapp-service` → `rapp-service.exe` | same | yes |
| `rapp-hub` → `rapp-hub.exe` | same | yes |
| `rapp-client-core` → `rapp-session.exe` | same | yes |
| `rapp-cli` → `rapp-cli.exe` | same, and copied to `bin\rapp.exe` | yes |
| Flutter `build\windows\x64\runner\Release\*` | the whole folder; `rapp.exe` renamed `rapp-gui.exe` | with `-Gui` |
| `rapp-svc-windows` → `rapp-svc.exe` | same | **no** — phase C |
| `rapp-host-windows` → `rapp-host-windows.exe` | `rapp-host.exe` | **no** — phase D |
| `rapp-term` → `rapp-term.exe` | same, plus ConPTY files | **no** — phase E |
| `rapp-speech-linux` → `rapp-speech.exe` | same | **no** — phase H |

  The “no” rows are in the script as a commented table with the phase, so the next phase flips one line. A program that is not staged is not found by `bins::find`, so the service reports the matching capability as absent — that is how a phase-A Windows machine is honestly “控制端 only”. The script ends with a self-check: every staged `.exe` exists; `app-<v>\rapp-cli.exe --version` prints `rapp <workspace version>`; `current` holds exactly the directory name.

- [ ] **Step 3: `check-windows.ps1`.** Steps, each from the right directory:
  1. `cargo test --workspace --no-fail-fast --exclude rapp-relay --exclude rapp-host-linux --exclude rapp-client-gtk --exclude rapp-hub-ffi` (`rust\`)
  2. `cargo clippy --workspace --all-targets` with the same four `--exclude`s, `-- -D warnings` (`rust\`)
  3. `flutter analyze`, then `flutter test` (`gui\`)
  4. only with `-Build`: `flutter build windows --release` (`gui\`), then `stage-windows.ps1 -Release -Gui`

- [ ] **Step 4: Flutter on Windows.** Apply to the product tree exactly the build fixes recorded under G1 in the probe-results page (nothing G1 did not need). Then `flutter analyze` → no issues; `flutter test` → all pass. A Dart test that fails only on Windows goes through Task 7's rule (rule 2 uses `skip: Platform.isWindows ? '<段> 做完时打开' : null` and the same `tasks/todo.md` list). `gui/pubspec.lock` is restored if a tool rewrote it without a dependency change. The runner keeps `BINARY_NAME "rapp"` (phase C renames it); the two Dart `chmod` sites already skip Windows and stay as they are.

- [ ] **Step 5: Prove the gate.** `scripts\check-windows.ps1 -Build` → every line `ok`, log ends `EXIT=0`, `.build\windows-stage\app-<v>\rapp-gui.exe` exists. Then prove it can fail: break one assertion in `rust/cli/src/gui.rs`'s tests, run without `-Build` → step 1 `FAILED`, steps 2–3 still ran, `EXIT=1`; restore.

- [ ] **Step 6: Look at it once by hand** (this is the phase's only by-eye check; write the result in the commit message): from a `cmd` window, `.build\windows-stage\bin\rapp.exe --help` shows the Chinese usage text unbroken; `.build\windows-stage\bin\rapp.exe` opens the interface window and returns to the prompt; double-clicking `app-<v>\rapp-service.exe` twice leaves one `rapp-service.exe` in Task Manager.

- [ ] **Step 7: Commit** by path: `build(windows): Windows 的门禁脚本和开发用的版本目录`. The integration session (Task 1) switches its gate to `scripts\check-windows.ps1` from this commit on.

---

### Task 9: Old sentences, findings, checks, close the phase

Either machine; docs only except the merge.

**Files:**
- Modify: every document in spec §19.2's list
- Modify: `tasks/todo.md`
- Modify: `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` (§17.2: mark A done with the merge commit)

- [ ] **Step 1: Spec §19.2.** Apply every row of the list there except the README row “安装表、致谢” (that one is done with the first release, phase H, spec §14.6) (README protocol number, `host-client-spec`, `native-rust-design`, `platform-design`, `requirements-feedback`, `s2-embedded-stage`, `text-terminal-design`, `port-sharing-design`, the port panel spec and handoff, `focus-pane-rules`, `term-fit`, `term-entry`, `desktop-sessions`, the iPad capability table, `config-reference`, `tasks/todo.md`). The line numbers there are for main `0decfe8d`: find each sentence by its content; if a sentence is already gone, tick the row and say so. Each fix is the smallest edit that makes the sentence true (a version number, “macOS only” → “macOS、Linux；Windows 见 Windows 设计”). Do not restructure those documents. Never open `docs/archives/`.

- [ ] **Step 2: `tasks/todo.md`, a new heading `## Windows 版 A 段（地基）`** with:
  - what merged (commit), what a phase-A Windows machine can do (builds, tests, starts the interface) and cannot (no host, no terminal, no update, no supervisor);
  - **给 Linux session 的发现**（规格 §6.1、§19.3 第 14 条）：`rust/service/src/workers.rs` 的 `permissions()` 没有把 `applications` 留下，`capabilities()` 读到的永远是“没有”，所以 Linux 被控端一直对外报不能开单个 app，控制端不显示它的 app 入口（`gui/lib/ui/device_apps.dart:16` 等四处）。有意还是漏了，由 Linux 的 session 判断；Windows 这次没有改它。
  - **要在实机上看的**（未验证）：
    1. 中文用户名（带空格）的账户下：`<数据根>\local` 的访问权限只有本人、SYSTEM、Administrators；数据根搬到 D 盘以后还是这样（规格 §13.2 的验收）。
    2. `cmd`、Windows PowerShell 5.1、Windows Terminal 里 `rapp --help` 的中文都不乱码（规格 §8.2【未验证】）。
    3. 从没有窗口的上级启动 `rapp-service` 再连一次：全程没有黑窗口闪过。
    4. `rapp-service --supervised`：上级关掉它的标准输入后 5 秒内退出，退出码 0；上级被强行结束也一样。
    5. 同一个登录会话里启动第二个 `rapp-service`：立刻退出，第一个不受影响；远程桌面的会话里另起一个不算“第二个”。
    6. Server 2022 云主机（没有显卡）上 `scripts\check-windows.ps1 -Build` 也是绿的。
  - the list from Task 7 (`## Windows 版：现在在 Windows 上关着的测试`) stays as its own heading.

- [ ] **Step 3: Done line** (spec §17.2 row A) — check each and paste the evidence into the merge commit message:
  - Windows: `scripts\check-windows.ps1` → `EXIT=0` (§14.3 steps 1–3); with `-Build`, `flutter build windows` passes.
  - Mac: `swift test`; `cargo test --workspace --no-fail-fast`; clippy `-D warnings`; `flutter analyze`; `flutter test` → green on the commit being merged.
  - `git diff main --stat -- Sources rust/host-linux rust/client-gtk rust/hub-ffi` → empty. `rust/relay` → only `src/audit.rs` (three attributes) and `src/admin.rs` (unix code gated, stand-in added); on the Mac `cargo test -p rapp-relay` passes with the same count as on `main`.
  - `/usr/bin/grep -rn "unsafe" rust --include='*.rs'` shows no new `unsafe` outside `rust/net/src/win.rs` compared with `main`.

- [ ] **Step 4: Merge** per `CLAUDE.md`: `git merge main` into `feat/windows-foundation`, re-run the gate of the machine you are on, then on that machine's `main`: `git merge --no-ff feat/windows-foundation` with message `merge: Windows 版地基（feat/windows-foundation）`. The integration session pushes. Tell the user that plans C, D and E can now be written as soon as their probes (G2; H1, H3, H5; T1, T5) have results.
