# rApp Windows — Phase C (Controller) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows laptop runs the rApp window, adds a Mac, opens its apps and desktop, types (Chinese included), moves files, opens text terminals and uses shared ports.

**Architecture:** The shared Dart code gets the picture the Linux way: one windowless `rapp-session.exe` per session decodes, Dart paints. `LinuxSessionPort` is kept and its few Linux ties move behind a small `DesktopShell` interface with a Linux and a Windows implementation. The C++ runner does only what Dart cannot: single instance, three method channels, tray icon format, manifest. `rapp-svc user` appears in its smallest form: it supervises `rapp-service`.

**Tech Stack:** Flutter 3.44.1 (Windows desktop), Dart, C++17 runner (Win32, no ATL/MFC), Rust (`rust/svc-windows`, `windows-sys` at the version in `rust/Cargo.lock`).

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` — §5.1, §5.2, §5.4, §7.3 (rows `status`/`start`/`stop`/`restart` only), §8.1 (rows 停止, 孤儿进程), §8.2 (the four rules), §10, §11, §15.6. Line numbers in the spec are for main `0decfe8d`; find every site by content.

**Written before its probe.** This plan was written on 2026-11-26, before probe **G2** ran. Read `docs/superpowers/specs/…-windows-probe-results.md` first:

- G2 passed → do the plan as written.
- G2 failed → the fallback is a native texture in the runner (spec §16.1). **Stop and tell the user before starting**; Tasks 4 and 5 gain a texture channel and this plan needs a revision, not improvisation.
- G1 found a plugin without a Windows implementation → its replacement is recorded in the probe results; use that in Task 5.

## Global Constraints

- Phase A is merged (`rapp-hub.exe`, `rapp-session.exe`, `rapp-service.exe`, `rapp-cli.exe` build and stage on Windows; `rapp_net::{private, proc, win}` exist).
- No `Platform.isWindows` in `gui/lib/` outside `platform_caps.dart`, `desktop_shell.dart` and `system_open.dart`. A difference is a capability bit (§10.1).
- macOS, Linux and iOS behaviour does not change. A Dart function that changes shape keeps its unix branch's output byte for byte; `flutter test` on the Mac stays green with no test weakened.
- The runner does **no decoding and no painting** (§5.4). Not done on Windows at all: `rapp/session`, `rapp/composer`, candidates bar, `rapp/dock`, `rapp/speech`, detached session windows. The shared code must tolerate `rapp/secure-input` being absent.
- The four rules for every process started on Windows (§8.2): no console window; dies with its parent; sibling programs by full path with `.exe`, never PATH; path APIs, never a hand-written `/`.
- Keys the local system takes are never grabbed with a keyboard hook (§3.2): Alt+Tab, Win combinations, Ctrl+Alt+Del, Alt+F4.
- Never log passwords, PINs, tokens, keys, typed text or clipboard contents. The unlock password never crosses IPC, a command line, the clipboard or a log.
- New Flutter plugins and crates are pinned to an exact version. No new plugin for anything the runner can do in under ~150 lines.
- Not in this phase: speech (H), IME polish beyond “it works” (H, G3), taskbar pin survival (H, G4), install/upgrade (G), `rapp-svc service` (F), the controller's wording for Windows hosts (D).
- Branch `feat/windows-controller`; merge to local `main` per `CLAUDE.md`; never push, tag or change version numbers.

## Review Focus

1. **Install path with a space or non-ASCII characters** (`C:\Users\张 三\AppData\…`): hub, session worker and service start and the picture appears. → Task 3 (path tests), Task 6 (real-machine check).
2. **`rapp-session.exe` dies or hangs mid-session:** the session ends with a reason within 2 s, no orphan process is left, a new session can start. Windows has no SIGTERM, so the “polite” path is closing stdin. → Task 4.
3. **Clipboard holds something large or unknown** (a 40 MB bitmap, an Office object, a file list with a long path): `clipboard_read` returns `null` or the supported part, never blocks the UI thread for more than 200 ms and never crashes the runner. → Task 5.
4. **Second start while the first instance is hidden in the tray or minimised on another virtual desktop:** the first window shows and comes to the front; the second process exits 0 within 1 s. → Task 5.
5. **Window dragged between two monitors with different scaling while a session is open:** the picture keeps its aspect and sharpness; pointer coordinates still land where the cursor is. → Task 6 (real-machine check) and a Dart test of the scale mapping in Task 4.

## File map

```
gui/lib/
  system_open.dart              one function for “open with the system” (Task 1)
  platform_caps.dart            new capability bits (Task 2)
  paths.dart  data_relocate.dart  service_control.dart  data_dir.dart   path and process fixes (Task 3)
  embed/desktop_shell.dart      DesktopShell interface + LinuxDesktopShell + WindowsDesktopShell (Task 4)
  embed/linux_session_port.dart uses DesktopShell; no direct Linux tie left (Task 4)
  main.dart                     wiring by capability (Task 6)
gui/windows/runner/
  single_instance.{h,cpp}       named mutex + wake message (Task 5)
  system_channel.{h,cpp}        rapp/system
  unlock_channel.{h,cpp}        rapp/unlock (Credential Manager)
  desktop_channel.{h,cpp}       rapp/windows: clipboard, file picker, file drop, hide/close
  flutter_window.cpp  main.cpp  runner.exe.manifest  Runner.rc  CMakeLists.txt (+ ../CMakeLists.txt)
gui/assets/tray_icon.ico        (Task 5)
rust/svc-windows/src/
  main.rs       argument dispatch: service | user | ctl | install | uninstall | claim-owner
  lib.rs        module list; everything not marked (windows) compiles and is tested on the Mac
  proto.rs      Request / Response of the local pipe (serde)
  backoff.rs    restart delays
  layout.rs     install directory, `current`, version directory names
  supervise.rs  (windows) start rapp-service, job object, stop through stdin
  pipe.rs       (windows) named pipe server, peer identity
  client.rs     (windows) the one pipe client: connect, check who serves, one request → one answer
  user.rs       (windows) the `user` run loop
  ctl.rs        the `ctl` client: one request, print the answer
  # later phases add: service.rs sessions.rs elevate.rs (F), update.rs install.rs (G)
scripts/stage-windows.ps1       adds rapp-svc.exe and, with -Gui, the Flutter bundle (Task 8)
```

## Order

Tasks 1–3 are plain Dart and can be done and tested on a Mac. Task 4 needs 2. Task 5 is C++ on Windows. Task 6 needs 4 and 5. Task 7 (Rust) is independent of 1–6. Task 8 closes.

---

### Task 1: One “open with the system” function

**Files:** Create `gui/lib/system_open.dart`, `gui/test/system_open_test.dart`. Modify the six call sites named in spec §10.1: `gui/lib/ui/main_window.dart` (via `openFolderCommand` in `service_control.dart`), `gui/lib/term/term_stage.dart`, `gui/lib/embed/linux_session_port.dart`, `gui/lib/pages/local_section.dart`, `gui/lib/pages/data_section.dart`.

**Interfaces — Produces:**

```dart
enum OpenKind { folder, file, url }
/// The command that opens [target]; null on iOS (the caller goes through `rapp/ios`).
ShellCommand? systemOpenCommand(String target, OpenKind kind, String os);
/// Runs it. False when the command could not start or exited non-zero.
Future<bool> openWithSystem(String target, OpenKind kind);
```

Values: macOS `open <target>`; Linux `xdg-open <target>`; Windows folder → `explorer.exe <target>`, file and url → `rundll32.exe url.dll,FileProtocolHandler <target>` (no `cmd /c start`: its quoting breaks on `&` in URLs and it flashes a console). `explorer.exe` exits 1 on success: on Windows a started process counts as success. `openFolderCommand` stays as a one-line wrapper so existing tests keep passing.

- [ ] **Step 1: Tests.** `command_per_os` (the exact argv for each of the 3 kinds × macos/linux/windows, `null` for ios); `url_with_ampersand_is_one_argument` (`https://a/?x=1&y=2` arrives as a single argv entry on windows); `path_with_space_is_one_argument`.
- [ ] **Step 2:** Run `flutter test test/system_open_test.dart` — fails (no file).
- [ ] **Step 3:** Implement; replace the six sites. The iOS branch (`caps.systemOpen`) moves inside `openWithSystem`.
- [ ] **Step 4:** `flutter analyze && flutter test` green on the Mac.
- [ ] **Step 5:** Commit `refactor(gui): one function opens files, folders and links with the system`.

### Task 2: Capability bits

**Files:** Modify `gui/lib/platform_caps.dart`, `gui/lib/ui/unlock.dart`, `gui/lib/embed/key_bar.dart`, `gui/lib/pages/data_section.dart`, the voice selection in `gui/lib/ui/main_state.dart` (the place that picks `LinuxSpeechChannel`), `gui/test/platform_caps_test.dart` (create if missing).

**Interfaces — Produces** (added to `PlatformCaps`, all `final`, defaults keep today's behaviour):

| field | type | macos | linux | windows | ios |
|---|---|---|---|---|---|
| `workerSessions` | `bool` | false | true | **true** | false |
| `unlockStore` | `UnlockBackend { none, system, memory }` | system | memory | **system** | system |
| `speechWorker` | `bool` | false | true | **true** (the button stays hidden until phase H sets `speechReady`) | false |
| `speechReady` | `bool` | true | true | **false** | true |
| `relocateData` | `bool` | true | true | **true** | false |
| `ctrlIsAppModifier` | `bool` | false | true | **true** | false |
| `desktopChannel` | `String?` | null | `'rapp/linux'` | **`'rapp/windows'`** | null |

`UnlockStore`'s defaults read `caps.unlockStore` instead of `Platform.isXxx`; `collapsesKeyBar` reads `caps.ctrlIsAppModifier`.

- [ ] **Step 1: Test** `caps_table`: one `expect` per cell of the table above, via `PlatformCaps.forOs`. Plus `unlock_store_follows_caps` and `ctrl_does_not_collapse_key_bar_on_windows`.
- [ ] **Step 2:** Run — fails. **Step 3:** Implement. **Step 4:** `flutter analyze && flutter test` green.
- [ ] **Step 5:** Commit `feat(gui): capability bits for worker sessions, unlock store, speech, data move`.

### Task 3: Paths and processes in shared Dart

**Files:** Modify `gui/lib/paths.dart`, `gui/lib/data_relocate.dart`, `gui/lib/service_control.dart`, `gui/lib/data_dir.dart`, `gui/lib/embed/linux_speech.dart`, `gui/lib/main.dart`; tests beside each.

- [ ] **Step 1: Tests.**
  - `paths_join_with_the_os_separator`: every function in `paths.dart` that builds a path takes `os` (it already does for most) and for `'windows'` returns `\`-joined paths with no `/`; for `'macos'` and `'linux'` the output equals today's string exactly (copy today's expected values into the test before changing code).
  - `home_fallback_on_windows`: no `HOME`, `USERPROFILE=C:\Users\u` → the log and data fallbacks resolve under `C:\Users\u\AppData\Local\rapp\…` (same directory `rapp_net` uses, plan A Task 3).
  - `find_binary_adds_exe_on_windows`: `findBinary('rapp-hub', r'C:\x y', 'windows')` looks for `C:\x y\rapp-hub.exe`.
  - `copy_tree_copies_without_cp`: a temp tree with a nested directory, an empty directory, a file with a non-ASCII name and a 0-byte file is copied; contents equal; modification times kept to the second. On unix, a symlink is recreated as a symlink (what `cp -Rp` did).
  - `private_dir_is_a_no_op_on_windows`: `ensurePrivateDir` creates the directory and runs no process when `os == 'windows'` (inject the process runner).
- [ ] **Step 2:** Run — fails.
- [ ] **Step 3:** Implement. `copyTree(String from, String to)` in `data_relocate.dart` replaces `cp -Rp` **on Windows only**; unix keeps `cp -Rp` (same bytes on existing platforms). `main.dart` and `linux_speech.dart` get every worker path from `findBinary`. Private directories on Windows are made by `rapp-service` (plan A), so the Dart side does nothing there (§13.2).
- [ ] **Step 4:** `flutter analyze && flutter test` green on the Mac.
- [ ] **Step 5:** Commit `fix(gui): paths, binaries and data copy work on Windows`.

### Task 4: `DesktopShell` — the session port's platform ties

**Files:** Create `gui/lib/embed/desktop_shell.dart`, `gui/test/embed/desktop_shell_test.dart`. Modify `gui/lib/embed/linux_session_port.dart`, `gui/lib/embed/linux_clipboard.dart`, `gui/lib/main.dart` (the two direct `MethodChannel('rapp/linux')` calls).

**Interfaces — Produces:**

```dart
abstract class DesktopShell {
  MethodChannel? get channel;                       // native extras (Linux detach); null when there are none
  Future<LinuxCopy?> readClipboard();
  Future<bool> writeClipboard(LinuxCopy copy);
  Future<List<String>> chooseFiles();
  Future<void> hideWindow();
  Future<void> closeWindow();
  Future<bool> reveal(String path);                 // show in the file manager
  /// Ask the worker to stop: close stdin, wait [grace], then kill. Returns the exit code.
  Future<int> stopWorker(Process p, {Duration grace = const Duration(seconds: 2)});
  Map<String, String> workerEnvironment(String locale);   // LANGUAGE on Linux; empty on Windows
  String join(String a, String b);
  static DesktopShell forCaps(PlatformCaps caps);
}
class LinuxDesktopShell implements DesktopShell { … }    // today's code, moved, not rewritten
class WindowsDesktopShell implements DesktopShell { … }  // channel `rapp/windows`, same method names
```

`LinuxCopy` and the `clipboard_read` / `clipboard_write` / `choose_files` / `drop_files` / `hide_window` / `close_window` method names and argument maps are unchanged (the Windows runner copies them, Task 5). The class name `LinuxSessionPort` is **not** renamed in this plan. `LinuxSessionPort.init()` already treats a missing `init` method as “no native extras”, which is the Windows case: `supportsDetach` is then false.

- [ ] **Step 1: Tests.** With a fake `DesktopShell` and a fake worker process: `worker_gets_stdin_closed_then_killed` (a worker that ignores stdin EOF is killed after `grace`, the session reports its end once); `worker_exit_mid_session_ends_the_session` (exit code 3 → one `SessionEvent` ended with a reason, the sid can be opened again); `drop_files_reaches_the_focused_session`; `scale_mapping_is_exact` (a 3840×2160 frame shown in a 1280×720 logical box at device pixel ratio 1.5, then at 1.0: pointer (640,360) logical maps to the same remote point in both). Existing `linux_session_port` tests pass unchanged with `LinuxDesktopShell`.
- [ ] **Step 2:** Run — fails. **Step 3:** Move the Linux ties behind the interface in one commit that changes no behaviour on Linux; add `WindowsDesktopShell` in a second.
- [ ] **Step 4:** `flutter analyze && flutter test` green on the Mac.
- [ ] **Step 5:** Commits `refactor(gui): the session port's Linux ties behind DesktopShell`, `feat(gui): WindowsDesktopShell`.

### Task 5: The runner (`gui/windows/runner/`)

**Files:** as in the file map. All C++ is new files except the listed edits; `win32_window.*` and `utils.*` from the Flutter template stay as generated.

**Decisions:**

| item | value |
|---|---|
| Program name | `BINARY_NAME` → `rapp-gui` (in `gui/windows/CMakeLists.txt`). Window title `rApp`. Icon unchanged. |
| App identity | `SetCurrentProcessExplicitAppUserModelID(L"com.rapp.gui")` first thing in `wWinMain`. |
| Single instance | Mutex `Local\com.rapp.gui.main` held for the process lifetime. A second start without `--cm`: broadcast the registered message `com.rapp.gui.show` (after `AllowSetForegroundWindow(ASFW_ANY)`), exit 0. The first instance shows, restores and foregrounds its window. With `--cm`: no mutex; if `OpenMutex` finds the main mutex **and** the main window is visible (ask through the same registered message with `wParam = 1`, `SendMessageTimeout` 500 ms, answer 1), exit 0; otherwise run. |
| `rapp/system` | `fontSize` → `double`: `15.0 * textScaleFactor` where the factor is `HKCU\Software\Microsoft\Accessibility\TextScaleFactor` / 100 (default 100). `visible` → `bool`: main window `IsWindowVisible && !IsIconic`. The Dart handler in `main.dart` that answers `visible` for the `--cm` process is unchanged. |
| `rapp/unlock` | `read {device}` → `{password, auto}` or null; `save {device, password, auto}`; `forget {device}`. Credential Manager, type generic, target `rapp/unlock/<device>`, `CRED_PERSIST_LOCAL_MACHINE` (does not roam), blob = UTF-8 JSON `{"password":…,"auto":…}`. The blob is zeroed (`SecureZeroMemory`) after use. |
| `rapp/windows` | `clipboard_read` (text `CF_UNICODETEXT`; image `CF_DIBV5`/`CF_DIB` → PNG bytes; files `CF_HDROP` → paths), `clipboard_write` (same three), `choose_files` (`IFileOpenDialog`, multi-select, returns paths), `drop_files` (the window registers `IDropTarget`; a drop calls Dart with `{paths, x, y}` in logical pixels), `hide_window`, `close_window`. Maps exactly as `gui/linux/runner/rapp_desktop.cc` produces them. Clipboard open retries 5 × 20 ms (another program may hold it). Images over 64 MB decoded are refused (`null`). |
| Close button | `WM_CLOSE` on the main window hides it (tray keeps the process); real quit comes from the tray menu through Dart. |
| Tray | `assets/tray_icon.ico` (16, 20, 24, 32 px, from the existing tray artwork); `main.dart` picks `.ico` when `Platform.isWindows` is expressed as a cap: add `trayIcon` to `PlatformCaps` (`'assets/tray_icon.png'` / `'assets/tray_icon.ico'`). |
| Manifest | add `<longPathAware>true</longPathAware>`; keep `PerMonitorV2`. |
| Bundled programs | not in CMake; the stage script assembles the version directory (Task 8). |

- [ ] **Step 1:** `gui/windows/runner/tests/` is not created (the template has no C++ test target). The runner is tested from Dart integration tests and by hand; write `gui/integration_test/windows_shell_test.dart` with: `system_font_size_is_positive`, `unlock_round_trip` (save, read, forget, read → null; device name with a space and a non-ASCII character), `clipboard_text_round_trip` (includes an emoji and a CRLF), `clipboard_image_round_trip` (a 2×2 PNG, pixels equal), `clipboard_unknown_format_reads_null`.
- [ ] **Step 2:** Implement the runner pieces, one file pair per row group.
- [ ] **Step 3:** `flutter build windows --release`, then `flutter test integration_test/windows_shell_test.dart -d windows`. Expected: all pass.
- [ ] **Step 4: By hand, and write the result into the phase notes:** second start wakes the first (hidden in tray; minimised; on another virtual desktop); `--cm` exits at once while the main window is visible and runs when it is hidden; close hides to tray; tray menu quits; a 40 MB bitmap on the clipboard does not freeze the window; dropping a file with a 300-character path arrives.
- [ ] **Step 5:** Commit `feat(gui/windows): runner — single instance, system, unlock and desktop channels`.

### Task 6: Wire it up and the keyboard

**Files:** Modify `gui/lib/main.dart`, the key mapping file that holds `linuxMacKeyCode`, `gui/lib/embed/linux_session_port.dart` (key handling only where it tests the OS), tests beside them.

- [ ] **Step 1: Tests.** `windows_gets_a_worker_port_and_terminals` (with `caps = forOs('windows')` the start-up code builds a `LinuxSessionPort` with `WindowsDesktopShell` and a non-null `termPort`). Key tests, each asserting the exact remote key code and modifier set: `ctrl_c_is_command_c`, `alt_is_option`, `win_key_is_not_sent`, `f11_is_local_fullscreen`, `ctrl_enter_goes_to_the_composer`, `altgr_e_is_not_sent_as_command_option_e` (when `altGraph` is down the key is not sent as a raw key; the character goes through the composer path).
- [ ] **Step 2:** Run — fails. **Step 3:** Implement: `main.dart` chooses the port by `caps.workerSessions`, the shell by `DesktopShell.forCaps`, the tray icon by `caps.trayIcon`; the two `rapp/linux` calls in `main.dart` go through the shell. Key handling asks `caps.ctrlIsAppModifier`, never the OS name.
- [ ] **Step 4:** `flutter analyze && flutter test` green on the Mac **and** on Windows.
- [ ] **Step 5: Real machine (Windows laptop → a Mac):** add the Mac; open an app and the desktop; type English and Chinese (Microsoft Pinyin) through the composer; copy text and an image both ways; drop a file in, receive a file and “show in folder”; open a text terminal; share a port from the Mac and open `http://localhost:28000` on the laptop; drag the window between two monitors with different scaling (Review Focus 5); run from an install path with a space and a Chinese character (Review Focus 1). Record each line in the phase notes.
- [ ] **Step 6:** Commit `feat(gui): Windows runs embedded sessions and terminals`.

### Task 7: `rapp-svc user` — supervise only

**Files:** Create the `rust/svc-windows/src/` files of the file map (the crate shell exists from phase A). Modify `rust/svc-windows/Cargo.toml`, `gui/lib/service_control.dart` (+ test).

**Interfaces — Produces** (used again by phases F and G; names are fixed here):

```rust
// proto.rs — one JSON object per line, one answer per request
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Request {
    Status, Start, Stop, Restart,
    ClaimOwner,                       // F
    Helper { pipe: String },          // F
    SpawnHost { args: Vec<String> },  // F
    Sas,                              // F
    Reattach,                         // F
    FetchUpdate { version: String },  // G
    ApplyUpdate { version: String, #[serde(default)] confirm: bool },  // G; `confirm` = the user accepted a changed signer
    Rollback,                         // G
}
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct Status { pub mode: Mode, pub owner: Option<String>, pub running: bool, pub pid: Option<u32>,
                    pub restarts: u32, pub prelogin: bool, pub version: String,
                    // phase G adds three optional fields (`update`, `previous`, `update_url`), each
                    // `#[serde(default, skip_serializing_if = "Option::is_none")]`; see plan G Task 4
                  }
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Mode { System, User }
/// One struct, not an enum: `{"ok":true}`, `{"ok":true,<status fields>}`, `{"ok":false,"error":"…"}`,
/// and (phase F) `{"ok":true,"spawned":{…}}`. Absent fields are not written.
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone, Default)]
pub struct Response {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub error: Option<String>,
    #[serde(default, flatten, skip_serializing_if = "Option::is_none")] pub status: Option<Status>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub spawned: Option<Spawned>,
}
/// Handle values are valid in the requester's process (duplicated into it by `rapp-svc`).
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct Spawned { pub pid: u32, pub process: u64, pub stdin: u64, pub stdout: u64, pub stderr: u64 }
impl Response { pub fn ok() -> Self; pub fn status(s: Status) -> Self; pub fn err(text: &str) -> Self; }

// client.rs — the one client of the pipe (used by `ctl`, and from phase F by rapp-host and rapp-service)
pub enum ClientError { NotListening, NotTrusted /* the server is not who it must be */, Io(std::io::Error), Protocol(String) }
pub fn request(pipe: &str, req: &Request, timeout: Duration) -> Result<Response, ClientError>;

// backoff.rs
pub struct Backoff { /* 1, 2, 4, … capped at 60 s; reset after the child has run 60 s */ }
impl Backoff { pub fn new() -> Self; pub fn next(&mut self) -> Duration; pub fn ran_for(&mut self, d: Duration); }

// layout.rs
pub fn version_dir_of(exe: &Path) -> Option<PathBuf>;            // the directory holding this exe
pub fn sibling(exe: &Path, name: &str) -> PathBuf;               // <version dir>\<name>.exe, never PATH
pub fn pipe_name(mode: Mode, user_sid: &str) -> String;          // user: \\.\pipe\rapp-svc.user.<sid>; system: \\.\pipe\rapp-svc
```

Requests not served in the current mode or phase answer `{"ok":false,"error":"not supported"}`.

**Behaviour (user mode):** start `<version dir>\rapp-service.exe --supervised --resident user` through `rapp_net::proc::command` (no window), stdin piped and kept; put it in a job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` so every worker dies with `rapp-svc`. Exit code 0 → restart at once; anything else → `Backoff`. `Stop` closes the child's stdin, waits 5 s, then terminates the job; `rapp-svc` keeps running and answers `Status` with `running: false` until `Start`. The pipe's security descriptor allows only the current user's SID (and SYSTEM). One instance per user: mutex `Local\com.rapp.svc.user`. Logs go through `rapp_net::log` like every other program. `rapp-svc ctl <op>` connects, sends one request, prints the answer line, exits 0 on `ok: true`, 1 otherwise, 2 when nothing listens.

`rapp-service` gains the `--resident <system|user>` argument in phase D (it only stores it there); until then `rapp-svc` does not pass it. Write the argument list in one function `service_args(mode, prelogin) -> Vec<String>` so phase D changes one place.

**`service_control.dart` (Windows branch):** `start` → `[rapp-svc.exe ctl start]`, `stop` → `ctl stop`, `restart` → `ctl restart`; when `ctl` exits 2 on `start`, start `rapp-svc.exe user` detached and retry once. The `reg add` / `taskkill` commands are deleted. `rapp-svc.exe` is found with `findBinary` beside the GUI.

- [ ] **Step 1: Tests (run on the Mac).** `proto_round_trip` (every `Request` variant ↔ its JSON line; `{"op":"fetch-update","version":"0.16.3"}`; `{"op":"spawn-host","args":["serve"]}`); `response_round_trip` (`{"ok":true}`; `{"ok":false,"error":"not supported"}`; a status answer has the status fields at the top level beside `ok`; `{"ok":true,"spawned":{"pid":7,"process":1,"stdin":2,"stdout":3,"stderr":4}}`; an answer with an unknown extra key still parses); `unknown_op_is_an_error_not_a_panic`; `backoff_sequence` (1, 2, 4, 8, 16, 32, 60, 60; after `ran_for(61 s)` back to 1); `sibling_never_uses_path` (`sibling(r"C:\p q\app-0.1.0\rapp-svc.exe", "rapp-service")` = `C:\p q\app-0.1.0\rapp-service.exe`); `pipe_names`. Dart: `windows_service_commands_use_rapp_svc_ctl`.
- [ ] **Step 2: Tests (Windows only, `#[cfg(windows)]`).** With a fake child program built in the test (`fake-service`: exits with the code given on its command line, or waits for stdin EOF): `clean_exit_restarts_at_once`; `crash_restarts_after_one_second`; `stop_closes_stdin_and_the_child_exits`; `killing_rapp_svc_kills_the_child` (job object); `pipe_refuses_another_user` is covered by reading back the pipe's DACL and asserting exactly two allow entries (user, SYSTEM).
- [ ] **Step 3:** Implement. `unsafe` only in `supervise.rs`, `pipe.rs` and `client.rs`.
- [ ] **Step 4:** Mac gate green (the crate is a shell there plus the OS-independent tests); `scripts/check-windows.ps1` green.
- [ ] **Step 5:** Commit `feat(svc-windows): user mode supervises rapp-service; ctl client`.

### Task 8: Ports, fonts, staging, acceptance

**Files:** Modify `scripts/stage-windows.ps1`, the terminal font fallback list in `gui/lib/` (the monospace list; find it by its existing Linux/macOS entries), `rust/ports/` only if N1 requires it, `tasks/todo.md`.

- [ ] **Step 1:** Stage script: add `rapp-svc.exe`; `-Gui` copies `build\windows\x64\runner\Release\*` into the version directory and writes `current`. The staged tree matches spec §5.1 for every program that exists so far.
- [ ] **Step 2:** Monospace fallback gains `Cascadia Mono`, `Consolas` before the generic `monospace` (Windows 11 and Server 2022 both ship Consolas; Cascadia only Windows 11). Test: the list contains both and the first macOS/Linux entries are unchanged.
- [ ] **Step 3: Ports (probe N1).** A bind refused because Windows reserved the range (`WSAEACCES`, 10013) is reported like “port in use” with the text `端口被系统保留`, not as a program error. Test in `rust/ports` with the error kind injected. rApp never changes the system's port reservations.
- [ ] **Step 4: Acceptance.** Walk spec §15.6 row by row except 按住说话 and 任务栏图标; for each row write pass / fail / 有限制 in `tasks/todo.md` under `## Windows 版 C 段（控制端）`, together with the real-machine checks of Tasks 5 and 6 that a person must repeat. Anything failing that is not fixed here is listed with its owner phase.
- [ ] **Step 5:** `git merge main` into the branch; Mac gate and Windows gate green; merge to local `main` with `merge: Windows 控制端（feat/windows-controller）`.

## Done when

A Windows laptop adds a Mac, opens apps and the desktop, types Chinese, moves files, opens a text terminal and uses a shared port; spec §15.6 is walked row by row except speech; the Mac gate is green and macOS/Linux/iOS behave as before.
