# rApp Windows — Phase D (Host, User Mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac controls a Windows machine that is logged in and not locked: its apps one by one and its whole desktop, with input, clipboard, file transfer, focus pane, hints and state rules — and the Mac controller needs no change for it beyond a few sentences.

**Architecture:** `rust/host-windows` implements the platform traits `host-core` defines (plan B Task 13) and nothing else: it produces no protocol bytes. Everything that can be a pure function (key table, window classification, ids, compositing, scaling, clipboard type mapping) lives outside `cfg(windows)` and is tested on the Mac; system calls live under `src/win/`. `rapp-service` learns that a Windows worker exists.

**Tech Stack:** Rust; the `windows` crate (same minor as `windows-sys` in `rust/Cargo.lock`, pinned exactly at first build) for COM/WinRT; `png` (pure Rust, pinned); Win32, DXGI, Direct3D 11, Windows.Graphics.Capture, UI Automation, Windows.Media.Ocr.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` — §5.3 (three boundary rules), §6 (all), §7.4 (only the rows “用户方式”), §8.1 (rows 权限、启动 worker、常驻方式), §10.6 (the controller's wording), §15.3. Line numbers there are for main `0decfe8d`; find sites by content.

**Written before its probes.** Written 2026-11-26, before **H1, H3, H5** (level 1) and **H2, H4, H6, H7** (level 2) ran. Read the probe results first. Each component below names the probe that can overturn it and what replaces it:

| Probe | If it failed | What changes here |
|---|---|---|
| H1 (per-window capture) | **stop and ask the user** (product regression) | Task 6 becomes “crop the screen picture by window rectangles”, covered parts are painted out and reported `covered` |
| H2 (menus, tooltips) | no stop | Task 6: all small windows come from the screen crop; shadows dropped |
| H3 (desktop duplication) | per machine: fall back to per-monitor Windows.Graphics.Capture, then GDI at 15 fps. Process limit: add `rapp-host screen-source` (spec §6.5) | Task 5 gains the fallback chain; Task 6 takes screen frames from `screen-source` |
| H4 (desktop switches) | no stop | Task 10: report only the lock state |
| H5 (input) | per app: paste path. Foreground: report, do not force | Task 7 |
| H6 (English layout) | no stop | Task 7: log and hint |
| H7 (OCR) | no stop | Task 9: `text` is `None` |

## Global Constraints

- Phases A and B are merged: `host-core` exists with the traits of plan B Task 13 (`Platform`, `Parts`, `TargetOps`, `WindowOps`, `Capture`, `InputOps`, `InputSourceOps`, `ClipboardOps`, `ControlOps`, `TextReader`, `LockOps`). A signature may be adjusted in the same commit as the fake platform and every caller; no group is added or merged, and the platform never calls into `host-core`.
- **`host-windows` neither produces nor parses protocol bytes** (§5.3 rule 2). It depends on `rapp-host-core` for types only. `host-core` gains no `cfg(windows)`.
- The Cargo target is `rapp-host-windows`; staged as `rapp-host.exe`. On non-Windows `main` prints `rapp-host: 只支持 Windows` and exits 2; every module not under `src/win/` compiles and is tested on the Mac.
- Command line, events, exit codes and fixed strings are `host-core`'s (§6.1). Exit code 3 is never used on Windows.
- `unsafe` only under `rust/host-windows/src/win/`. Every COM/WinRT object is created and used on the thread that owns it; capture runs on its own thread (the `Capture` object is `Send` and moved there).
- The process is Per-Monitor-V2 DPI aware (set in `main` before any window call). “Point” = physical pixel ÷ (monitor DPI ÷ 96).
- The mouse pointer is never captured. No virtual display driver. No keyboard hook.
- User mode only: no helper, no unlock, no secure desktop. An elevated target window gets no input: answer `inputBlocked` with `by = "elevated"`.
- An app the host starts for the controller must survive a service restart (not in the job object, §8.1).
- Never log typed text, clipboard contents or the unlock password.
- `rust/host-linux`, `Sources/`, the unix arms of `rapp-service` are not changed. The Linux `applications` finding (§6.1) is not fixed here.
- Branch `feat/windows-host`; merge per `CLAUDE.md`.

## Review Focus

1. **The target app exits or its window closes while a capture session is open:** the per-window session is torn down without a hang, the canvas is recomposed without that window, and when no process with that exe name is left the session ends with `"<名字> quit"`. → Task 6.
2. **Display change mid-session** (resolution, scale, monitor unplugged, laptop lid): capture is rebuilt within 1 s and the session continues; only a rebuild that fails ends the session with `capture stopped: …`. → Task 5.
3. **Text whose 20-unit chunk boundary splits a surrogate pair, plus CRLF and Tab:** every character arrives once, in order; a lone surrogate is never sent alone to `SendInput` in a separate call. → Task 7 (chunking is `host-core`'s; the platform must accept a chunk starting or ending mid-pair and buffer one unit).
4. **Another program holds the clipboard open:** read and write retry (5 × 20 ms), then give up with an error string; never a crash, never a blocked session thread for more than 150 ms. → Task 8.
5. **A window that is cloaked, minimised or moved to another virtual desktop mid-session:** it leaves the window table (not a frozen picture of it); when it returns it is captured again. → Tasks 4 and 6.

## File map

```
rust/host-windows/
  Cargo.toml
  src/main.rs          windows: DPI awareness, build WindowsPlatform, host_core::run; else the one-line message
  src/lib.rs           module list
  # — portable, tested on the Mac —
  src/keymap.rs        mac virtual key code → Windows scan code (+ extended bit); modifier flags
  src/ids.rs           HWND → window id; monitor device path → display id (FNV-1a 32)
  src/appid.rs         exe path → app id; display name fallback; the UWP rule; system-surface exclusions
  src/classify.rs      WindowFacts → eligible? → WindowKind (step 1 of §6.5)
  src/compose.rs       paint window pictures back to front onto one canvas
  src/scale.rs         area-average downscale of BGRA
  src/scrollmap.rs     scroll pixels → wheel deltas, with remainder
  src/cliptypes.rs     UTI ↔ clipboard format; “HTML Format” header add/strip; DIB → BGRA
  src/roles.rs         UI Automation control type → the role names host-core's Query uses
  src/launchplan.rs    where to look for an exe by name, in order
  # — system calls —
  src/win/mod.rs  platform.rs  displays.rs  apps.rs  windows.rs
  src/win/d3d.rs  dda.rs  wgc.rs  capture.rs
  src/win/input.rs  ime.rs  clipboard.rs  uia.rs  ocr.rs  lock.rs
  tests/               portable tests (one file per portable module)
rust/service/src/workers.rs      Windows arm of permissions() and capabilities(); --resident
rust/hub/src/lib.rs              apps_event forwards `resident`, `prelogin`
gui/lib/permissions.dart         missingPermissions: Windows reasons
gui/lib/ui/…                     the controller's wording for Windows hosts (§10.6)
```

## Component choices (fixed here; each row names its probe)

| Need | Component | Notes |
|---|---|---|
| One app's windows | **Windows.Graphics.Capture**, one `GraphicsCaptureSession` per eligible top-level window (`IGraphicsCaptureItemInterop::CreateForWindow`), `Direct3D11CaptureFramePool::CreateFreeThreaded`, `IsCursorCaptureEnabled = false`, `IsBorderRequired = false` (available from build 20348, the baseline) | H1 |
| Menus, tooltips, drop-downs | cropped from the screen picture (desktop duplication of that monitor), opened only while such a window exists | H2 |
| Whole desktop | **DXGI Desktop Duplication** (`IDXGIOutput1::DuplicateOutput`, `AcquireNextFrame`); pointer shape data is ignored | H3 |
| Graphics device | D3D11 hardware device on the adapter that owns the monitor; if none, **WARP** | H1, H3 |
| Pixels to memory | copy to a staging texture, `Map`, then CPU: `scale.rs` (area average) and `compose.rs`. No GPU scaling in the first version; revisit only if H3's 40 %-of-a-core line fails | H3 |
| Mouse, keys, text | `SendInput`: mouse `MOUSEEVENTF_ABSOLUTE \| MOUSEEVENTF_VIRTUALDESK`; keys `KEYEVENTF_SCANCODE` (+ `KEYEVENTF_EXTENDEDKEY`); text `KEYEVENTF_UNICODE`, one event pair per UTF-16 unit, `\n` → VK_RETURN, `\t` → VK_TAB, `\r` dropped | H5 |
| Bring to front | `SetForegroundWindow`; on refusal attach to the foreground thread's input (`AttachThreadInput`) and retry; then a restore (`ShowWindow SW_RESTORE`) for minimised windows. No registry tweak of the foreground lock timeout | H5 |
| “Is it elevated” | compare the target process's integrity level (`TokenIntegrityLevel`) with our own; `OpenProcess` refused counts as elevated | H5 |
| English layout | pick the first installed layout whose language is English and post `WM_INPUTLANGCHANGEREQUEST` to the foreground window; none installed → close the IME's open status through the default IME window (`WM_IME_CONTROL`, `IMC_SETOPENSTATUS` 0). **Never install a layout** (that would change the user's settings) | H6 |
| Clipboard | Win32 clipboard; change count `GetClipboardSequenceNumber`; PNG through the registered `PNG` format, else `CF_DIBV5`/`CF_DIB` converted with `cliptypes.rs` + the `png` crate; “do not share” = any of `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory` = 0, `CanUploadToCloudClipboard` = 0 | — |
| Controls | **UI Automation** over COM (`IUIAutomation::GetFocusedElement`, control-view walker to the window, `CurrentBoundingRectangle`, `CurrentControlType`, `CurrentIsPassword`) | — |
| Text recognition | `Windows.Media.Ocr.OcrEngine`, languages `zh-Hans` and `en`; either missing → `Parts.text = None` | H7 |
| Lock state | `WTSQuerySessionInformationW(WTSSessionInfoEx)` → `SessionFlags`; “switched to another desktop” = `OpenInputDesktop` fails or its name is not `Default` | H4 |
| Lock, stay awake | `LockWorkStation`; `SetThreadExecutionState(ES_CONTINUOUS \| ES_DISPLAY_REQUIRED \| ES_SYSTEM_REQUIRED)` on a thread that lives as long as the session | — |
| Starting an app | through the shell of the logged-in desktop (`IShellDispatch2::ShellExecute` obtained from the desktop shell view), so the app is Explorer's child: outside our job object and never elevated by accident. If that fails: `CreateProcessW` with `CREATE_BREAKAWAY_FROM_JOB` | T5 |
| Display id | FNV-1a 32 of the lower-cased monitor device interface path (`EnumDisplayDevicesW` with `EDD_GET_DEVICE_INTERFACE_NAME`); no path → of `\\.\DISPLAYn`; a result of 0 becomes 1 | — |

## Order

Tasks 1–2 are portable and can be done on the Mac. 3 → 4 → 5 → 6 on Windows; 7, 8, 9, 10 need only 3 and 4 and are independent of each other. 11 and 12 touch shared code and can be done any time after plan B. 13 closes.

---

### Task 1: Portable tables — keys, ids, app ids, window classes

**Files:** Create `src/keymap.rs`, `src/ids.rs`, `src/appid.rs`, `src/classify.rs`, `src/launchplan.rs`, `tests/{keymap,ids,appid,classify,launchplan}.rs`; modify `Cargo.toml`, `src/lib.rs`.

**Interfaces — Produces:**

```rust
// keymap.rs
pub struct Scan { pub code: u16, pub extended: bool }
pub fn scan_for(mac_key_code: u16) -> Option<Scan>;
pub struct Mods { pub ctrl: bool, pub alt: bool, pub shift: bool }
pub fn mods_for(cg_event_flags: u64) -> Mods;            // ⌘ or ⌃ → ctrl, ⌥ → alt, ⇧ → shift; no Win key
pub fn is_secure_attention(mac_key_code: u16, flags: u64) -> bool;   // ⌃ + ⌥ + forward delete (0x75)

// ids.rs
pub fn window_id(hwnd: usize) -> u32;                    // low 32 bits; 0 never returned for a real window
pub fn display_id(device_path: &str) -> u32;             // FNV-1a 32 of the lower-cased path; 0 → 1

// appid.rs
pub fn app_id(exe_path: &str) -> String;                 // file name, lower case, with ".exe"
pub fn same_app(a: &str, b: &str) -> bool;               // ASCII case-insensitive
pub fn fallback_name(app_id: &str) -> String;            // without ".exe"
pub fn is_frame_host(app_id: &str) -> bool;              // applicationframehost.exe
pub const NEVER_CLOSE: &[&str];                          // explorer.exe, consent.exe, logonui.exe, lockapp.exe, dwm.exe, taskmgr.exe, searchhost.exe, startmenuexperiencehost.exe, shellexperiencehost.exe

// classify.rs
pub struct WindowFacts { pub class: String, pub style: u32, pub ex_style: u32, pub has_owner: bool, pub visible: bool,
                         pub cloaked: bool, pub minimized: bool, pub width: i32, pub height: i32, pub title_empty: bool }
pub fn eligible(f: &WindowFacts) -> bool;                // visible, not cloaked, not minimised, > 4×4
pub fn kind(f: &WindowFacts) -> host_core::protocol::WindowKind;
pub fn is_system_surface(class: &str) -> bool;           // Shell_TrayWnd, Shell_SecondaryTrayWnd, Progman, WorkerW, Windows.UI.Core.CoreWindow of the shell, …
pub fn explorer_window_counts(class: &str) -> bool;      // CabinetWClass only

// launchplan.rs
pub enum Source { AppPaths, StartMenu, Path }
pub fn sources() -> [Source; 3];                         // in this order (§6.4)
pub fn valid_app_id(id: &str) -> bool;                   // ends in .exe, no path separator, no "..", ≤ 260 chars
```

`kind` rules, in order (§6.5): class `#32768` → menu; class `tooltips_class32` → tooltip; `WS_EX_TOOLWINDOW` → floating; has owner and (`WS_DLGFRAME` or class `#32770`) → dialog; has owner and no `WS_CAPTION` → popup; otherwise normal. Sheet never.

- [ ] **Step 1: Tests.**
  - `anchor_keys` — exact values: A `0x00`→`0x1E`; S `0x01`→`0x1F`; Return `0x24`→`0x1C`; Tab `0x30`→`0x0F`; Space `0x31`→`0x39`; Delete `0x33`→`0x0E`; Escape `0x35`→`0x01`; ⌘ `0x37`→`0x1D`; right ⌘ `0x36`→`0xE0 0x1D` (extended); Shift `0x38`→`0x2A`; right Shift `0x3C`→`0x36`; Caps `0x39`→`0x3A`; ⌥ `0x3A`→`0x38`; right ⌥ `0x3D`→extended `0x38`; ⌃ `0x3B`→`0x1D`; F1 `0x7A`→`0x3B`; Home `0x73`→extended `0x47`; End `0x77`→extended `0x4F`; Page Up `0x74`→extended `0x49`; Page Down `0x79`→extended `0x51`; forward delete `0x75`→extended `0x53`; ← `0x7B`→extended `0x4B`; → `0x7C`→extended `0x4D`; ↓ `0x7D`→extended `0x50`; ↑ `0x7E`→extended `0x48`.
  - `every_key_the_controller_can_send_is_mapped`: every mac key code in the controller's table (`linuxMacKeyCode` in `gui/lib/`, copied into the test as a list) has a `Some`.
  - `no_two_keys_share_a_scan_code` except the pairs ⌘/⌃ (both left Ctrl) — listed explicitly.
  - `mods`: `0x100000` → ctrl; `0x40000` → ctrl; `0x80000` → alt; `0x20000` → shift; all four → all three.
  - `secure_attention_only_for_ctrl_alt_forward_delete`.
  - `display_id_known_values`: three fixed paths → three fixed u32 (compute once with a reference FNV-1a and write the numbers in); case-insensitive; a path hashing to 0 is impossible to construct by hand, so test the `0 → 1` branch through a private helper.
  - `app_id`: `C:\Program Files\Google\Chrome\Application\CHROME.EXE` → `chrome.exe`; forward slashes accepted; `same_app("Chrome.exe","chrome.EXE")`.
  - `classify_table`: one case per rule above, plus “visible but cloaked is not eligible”, “4×4 is not eligible, 5×5 is”.
  - `valid_app_id_rejects` `..\x.exe`, `a/b.exe`, `cmd`, a 300-character name.
- [ ] **Step 2:** Run `cargo test -p rapp-host-windows` — fails. **Step 3:** Implement. **Step 4:** green on the Mac.
- [ ] **Step 5:** Commit `feat(host-windows): key table, ids, app ids, window classification`.

### Task 2: Portable pixels — compose, scale, scroll, clipboard types, roles

**Files:** Create `src/compose.rs`, `src/scale.rs`, `src/scrollmap.rs`, `src/cliptypes.rs`, `src/roles.rs` and their tests.

**Interfaces — Produces:**

```rust
// compose.rs — all sizes in pixels, BGRA, 4 bytes per pixel, rows tightly packed
pub struct Layer<'a> { pub x: i32, pub y: i32, pub width: usize, pub height: usize, pub bgra: &'a [u8], pub stride: usize, pub opaque: bool }
/// Paints `layers` back to front onto a canvas of `width × height` cleared to opaque black. Layers may lie partly or
/// wholly outside. `opaque` layers copy; others blend “source over” with premultiplied alpha. The result is opaque.
pub fn compose(width: usize, height: usize, layers: &[Layer]) -> Vec<u8>;

// scale.rs
/// Area-average downscale (or exact copy when sizes match). Never upscales: a larger target returns None.
pub fn downscale(src: &[u8], src_w: usize, src_h: usize, src_stride: usize, dst_w: usize, dst_h: usize) -> Option<Vec<u8>>;

// scrollmap.rs
pub const PIXELS_PER_NOTCH: f32 = 48.0;   // starting value; tuned on a real machine (spec §6.6), change only here
pub struct ScrollAcc { /* remainders */ }
impl ScrollAcc { pub fn new() -> Self; /// wheel deltas (multiples of 1, WHEEL_DELTA = 120 per notch) for this event
                 pub fn push(&mut self, dx: f32, dy: f32) -> (i32, i32); }

// cliptypes.rs
pub enum Format { UnicodeText, Png, Dib, FileList, Html, Rtf }
pub fn format_for_uti(uti: &str) -> Option<Format>;      // the table in spec §6.7; public.tiff → Png (convert first)
pub fn uti_for_format(f: Format) -> &'static str;
pub fn html_wrap(fragment: &str) -> Vec<u8>;             // adds the “HTML Format” header with correct byte offsets
pub fn html_unwrap(bytes: &[u8]) -> Option<String>;      // the fragment between StartFragment and EndFragment
pub fn dib_to_bgra(dib: &[u8]) -> Option<(usize, usize, Vec<u8>)>;   // 24- and 32-bit, bottom-up and top-down, BI_RGB and BI_BITFIELDS

// roles.rs
pub fn role(control_type_id: i32) -> &'static str;       // UIA_*ControlTypeId → the role strings host-core's Query matches
```

- [ ] **Step 1: Tests.** `compose`: two overlapping opaque layers (front wins, pixel-exact); a layer half outside the canvas; a 50 %-alpha layer over white gives the exact premultiplied result; zero layers → all `[0,0,0,255]`; a layer with `stride > width*4`. `scale`: 4×4 → 2×2 of a checkerboard is uniform grey (exact value); 3×3 → 2×2 against hand-computed values; equal sizes return identical bytes; upscale → `None`; 1×1 source. `scrollmap`: 48 px → one notch (120); 24 + 24 → 0 then 120; sign kept; ±10000 px does not overflow. `cliptypes`: the table of spec §6.7 both ways; an unknown UTI → `None`; `html_unwrap(html_wrap(s)) == s` for ASCII, Chinese and an emoji, and the header's offsets point at the right bytes; `dib_to_bgra` for a 2×2 bottom-up 24-bit and a top-down 32-bit bitmap; a truncated DIB → `None`. `roles`: Edit, Document, Pane, Window, List, Tree, Table, Group, Tab, ToolBar map to the names `host-core::query` uses (read them from plan B Task 8's `Query`).
- [ ] **Step 2–4:** fail, implement, green on the Mac.
- [ ] **Step 5:** Commit `feat(host-windows): compositing, scaling, scroll and clipboard mapping`.

### Task 3: Platform skeleton, displays, the four reasons

**Files:** Create `src/win/{mod,platform,displays}.rs`; modify `src/main.rs`.

**Interfaces — Produces:** `pub struct WindowsPlatform; impl host_core::platform::Platform for WindowsPlatform`. `permissions()` returns `screen_recording` = “a picture can be produced”, `accessibility: true`, `platform: "windows"`, `applications: true`, and on failure `error`: `NoDisplay` (no active monitor), `SessionDisconnected` (the session is not the console session and no RDP client is attached: `WTSGetActiveConsoleSessionId` ≠ ours and our `WTSConnectState` is `WTSDisconnected`), `NotInteractive` (no interactive window station: `GetProcessWindowStation` name is not `WinSta0`). `OtherUser` is produced only by the pre-login instance (phase F). `displays()` lists active monitors once per mirror set, primary first, each with `display_id`, frame in points and scale.

- [ ] **Step 1: Tests (Windows, `#[cfg(windows)]`).** `displays_has_a_primary_with_nonzero_id`; `permissions_on_an_interactive_desktop_are_all_true`; `version_json` (run the built exe: `{"version":…,"protocol":16,"platform":"windows"}`); `list_apps_json_has_a_desktop_entry_with_displays`.
- [ ] **Step 2–3:** Implement; `main` sets `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`, initialises COM (multithreaded) and calls `host_core::run`.
- [ ] **Step 4: By hand:** on the machine without a monitor `check --json` prints `"error":"no display"` and `serve` exits 1 with that reason; in a disconnected RDP session it prints `session disconnected`.
- [ ] **Step 5:** Commit `feat(host-windows): platform skeleton, displays, permissions`.

### Task 4: Windows and apps

**Files:** Create `src/win/windows.rs`, `src/win/apps.rs`.

**Behaviour.** `WindowOps::list`: `EnumWindows` (front to back), keep windows whose process's `app_id` equals the target (for `applicationframehost.exe` windows, the target is the process of the child `Windows.UI.Core.CoreWindow`; none found → skip), not `is_system_surface`, `eligible`; rectangle = `DWMWA_EXTENDED_FRAME_BOUNDS` converted to points; `title_bar` = the system caption height in points when `WS_CAPTION` is set and the window does not extend its client area into the frame, else 0; at most 256. `screen()`: every eligible window of every process, for the click-through check. `raise` = bring to front (Task 7's helper); `close` = `PostMessage(WM_CLOSE)`; `move_to`/`resize` = `SetWindowPos` with the invisible-border difference added back. `applications()`: the running processes that own at least one eligible, non-system top-level window, name from the exe's `FileDescription` (else `fallback_name`), sorted by name. `TargetOps::alive`: at least one process with that exe name exists. Launch: `launchplan::sources()` → `App Paths` registry (HKCU then HKLM), Start-menu shortcuts whose target file name matches, `SearchPathW`; start as in “Component choices”; wait up to 10 s for an eligible window; not found → `OpenError::NotFound("<id> not found")`.

- [ ] **Step 1: Tests (Windows).** With a test helper exe built in the test (`fake-app`: opens N plain windows, an owned dialog and a tool window, titles from the command line): `lists_only_the_target_apps_windows_front_to_back`; `minimised_window_leaves_the_list_and_returns`; `move_and_resize_land_within_one_point`; `close_asks_politely` (the helper records `WM_CLOSE` and stays alive if it chooses to); `applications_lists_the_helper_once_with_its_file_description`; `explorer_taskbar_is_never_a_window`.
- [ ] **Step 2–4:** fail, implement, green.
- [ ] **Step 5: By hand:** Chrome, VS Code, Notepad, File Explorer, Calculator (a Store app), Office: each appears once in `list-apps` with a sensible name; record the table of observed window kinds in `tasks/todo.md` (spec §6.5 asks for this calibration).
- [ ] **Step 6:** Commit `feat(host-windows): window table, app list, app launch`.

### Task 5: Desktop capture

**Files:** Create `src/win/d3d.rs`, `src/win/dda.rs`, `src/win/capture.rs` (the `DesktopCapture` half).

**Interfaces — Produces:**

```rust
// d3d.rs
pub struct Device { /* ID3D11Device, context, adapter LUID, is_warp */ }
impl Device { pub fn for_monitor(display_id: u32) -> Result<Device, String>;      // hardware first, then WARP
              pub fn read(&self, tex: &ID3D11Texture2D, rect: PixelRect) -> Result<Pixels, String>; }   // staging copy + Map
pub struct Pixels { pub bgra: Vec<u8>, pub width: usize, pub height: usize, pub stride: usize }
// dda.rs
pub struct ScreenSource { /* duplication for one monitor */ }
impl ScreenSource { pub fn open(display_id: u32) -> Result<ScreenSource, String>;
                    /// The latest full picture of the monitor; Ok(None) when nothing changed within `wait`.
                    pub fn next(&mut self, wait: Duration) -> Result<Option<&Pixels>, Lost>; }
pub enum Lost { Rebuild, Gone(String) }       // DXGI_ERROR_ACCESS_LOST / mode change → Rebuild
```

`DesktopCapture::frame(region, density, wait)`: take the monitor picture, crop `region`, `downscale` to `region × min(density, monitor scale)`, force alpha to 255. On `Lost::Rebuild` reopen (up to 1 s, 5 tries); on `Gone` return `Err("capture stopped: <reason>")`. Rotated monitors: the duplication reports the rotation; the picture is rotated on the CPU to upright. HDR: the duplication is asked for 8-bit BGRA (`DuplicateOutput`, not `DuplicateOutput1`), so the system tone-maps.

- [ ] **Step 1: Tests (Windows; skipped with a printed reason when the machine has no display).** `desktop_frame_has_the_requested_size` (region 800×600 pt at density 1 and at the monitor's scale); `alpha_is_opaque`; `second_frame_without_change_is_none`; `resolution_change_recovers` (change the mode with `ChangeDisplaySettingsExW` in the test, expect a frame within 1 s, restore the mode in a guard).
- [ ] **Step 2–4:** fail, implement, green.
- [ ] **Step 5: By hand, numbers into the phase notes:** 4K at 30 fps — CPU of capture + scale (line: under 40 % of one core); a portrait monitor; an HDR monitor; a hybrid-graphics laptop; the Server 2022 cloud machine (WARP); 8 workers at once (H3's line).
- [ ] **Step 6:** Commit `feat(host-windows): desktop capture through desktop duplication`.

### Task 6: App capture — per-window sessions, composed

**Files:** Create `src/win/wgc.rs`; complete `src/win/capture.rs` (`AppCapture`).

**Behaviour.** `AppCapture` keeps one `WindowSession` per eligible normal/dialog/floating window of the target (by window id), created when the window appears in `WindowOps::list` and dropped when it leaves or its capture item raises `Closed`. Each keeps its latest picture. `frame(region, density, wait)`: wait up to `wait` for any session to deliver a new picture (or for the window set, order or rectangles to change); then build layers back to front — each window's latest picture at its rectangle (crop the invisible border: the captured picture covers the window rectangle including the border area), then every menu/tooltip/popup window of the target as a crop of the screen picture at its rectangle (the `ScreenSource` for that monitor is opened when the first such window exists and closed 2 s after the last one goes) — `compose`, crop `region`, `downscale`. Nothing changed → `Ok(None)`. A window with no picture yet is left out, not painted black. Windows on a monitor other than the session's (the one holding the centre of the largest window) are left out.

- [ ] **Step 1: Tests (Windows, with `fake-app` painting a known colour per window).** `two_overlapping_windows_compose_in_z_order` (pixel colours at three points); `a_window_covered_by_another_app_is_still_drawn` (a second helper process covers it); `closing_a_window_removes_it_within_one_frame_and_does_not_hang`; `the_last_process_exiting_ends_alive` ; `no_pointer_in_the_picture` (move the pointer over the window; the pixel under it keeps the window's colour); `a_cloaked_window_leaves_and_returns`.
- [ ] **Step 2–4:** fail, implement, green.
- [ ] **Step 5: By hand:** 1, 3 and 10 windows of one app — CPU (line: half a core at 10); a menu opened in Notepad and a drop-down in Chrome appear within 100 ms at the right place; no yellow border on Windows 11 and on Server 2022.
- [ ] **Step 6:** Commit `feat(host-windows): app capture — per-window sessions composed on one canvas`.

### Task 7: Input, foreground, input method

**Files:** Create `src/win/input.rs`, `src/win/ime.rs`.

**Behaviour.** `mouse`: points → virtual-desktop pixels → 0…65535 normalised over the virtual screen; a move precedes every button event; `click_count` needs no API (Windows counts by time and distance) but two downs for a double click are sent as they arrive. `scroll`: `ScrollAcc` → `MOUSEEVENTF_WHEEL` / `MOUSEEVENTF_HWHEEL`. `key`: `scan_for`; modifiers are taken from the event's flags: before a key-down, press the modifiers in `mods_for(flags)` that are not already held by this session and release the ones that are held but not in the flags. `is_secure_attention` → in user mode do nothing and log one line (phase F routes it to `rapp-svc`; phase F also defines how `rapp-host` learns whether the system service is there — it asks the system pipe, plan F Task 3 `win/svc.rs::resident()`. In this phase the worker always behaves as user mode). `text`: as in “Component choices”; a chunk ending on a high surrogate holds it back and sends it with the next chunk. `paste_key`: Ctrl+V by scan code. `release`: key-ups and button-ups for everything given. `blocked_by(at)`: if the top-level window at that point belongs to an elevated process → `Some("elevated")`; `host-core` then answers `inputBlocked`. Before any input to an app target the target is brought to the front (`TargetOps::activate`); a refusal is reported by `activate() == false`, input is not sent blind.

`ime.rs`: `current` (the foreground thread's layout handle as `hkl:<hex>`, name from the layout's language, `english` when the primary language is English or the IME's open status is 0), `list`, `select(id)`, `select_english` as in “Component choices”.

- [ ] **Step 1: Tests (Windows, with `fake-app` in “echo” mode: it records every `WM_CHAR`, key and mouse message into a file).** `text_arrives_exactly` (1000 mixed Chinese/English characters with an emoji, `\n` and `\t`, 20 runs; the recorded text equals the input); `chunk_split_inside_a_surrogate_pair` ; `scan_codes_reach_the_app_as_the_right_keys` (A, Return, ←, forward delete); `command_c_arrives_as_ctrl_c`; `mouse_lands_on_the_point` (three points on two monitors when present); `double_click_is_a_double_click`; `foreground_50_of_50`; `elevated_window_reports_elevated` (skipped with a printed reason unless the test runs with an elevated helper available).
- [ ] **Step 2–4:** fail, implement, green.
- [ ] **Step 5: By hand:** the app list of probe H5 (Notepad, Chrome, VS Code, Windows Terminal, Office, a Java app); the three IMEs of H6; scrolling “one screen for one screen” — tune `PIXELS_PER_NOTCH` and write the value and reason in the commit.
- [ ] **Step 6:** Commit `feat(host-windows): input, foreground and input method`.

### Task 8: Clipboard

**Files:** Create `src/win/clipboard.rs`.

**Behaviour.** `change_count` = sequence number. `read`: open with retry; `concealed` when any marker format is present (then nothing else is read); text; image (registered `PNG` bytes as they are, else DIB → BGRA → PNG); files (`CF_HDROP`; a directory in the list → the read reports the files only and `host-core` applies its “folders not supported” rule); otherwise HTML or RTF as `data` with its UTI. `write(item)`: by `format_for_uti`; an image is written as both `PNG` and `CF_DIBV5`; HTML through `html_wrap`; returns the new sequence number so `host-core` can ignore its own write. `snapshot`/`restore`: every format that can be read as a global memory block is copied and put back (delay-rendered and handle-typed formats other than the bitmap family are skipped). `source` = the foreground app's id at read time.

- [ ] **Step 1: Tests (Windows; they use the real clipboard and restore it in a guard; the test binary runs single-threaded).** `text_round_trip` (emoji, CRLF); `png_round_trip_pixels_equal`; `dib_only_reads_as_png`; `file_list_round_trip` (a path with a space and Chinese); `html_round_trip`; `concealed_is_skipped` (set `ExcludeClipboardContentFromMonitorProcessing`); `own_write_returns_the_new_count`; `snapshot_restores_text_and_image`; `held_by_another_process_gives_an_error_not_a_hang` (a helper holds it open for 1 s; the call returns within 150 ms).
- [ ] **Step 2–5:** fail, implement, green, commit `feat(host-windows): clipboard`.

### Task 9: Controls and text recognition

**Files:** Create `src/win/uia.rs`, `src/win/ocr.rs`.

**Behaviour.** UI Automation lives on one dedicated thread (COM multithreaded apartment); calls are sent to it and time out by `QueryDeadline`. `focus_chain`: focused element → parents through the control-view walker up to the element whose native window is the given window (at most 40 levels), each as a rectangle in points with `roles::role`; evaluated against `query` exactly as the fake platform does in plan B; out of time → `PanelMiss` as `host-core` defines. An elevated target → `Err` at once (the pane falls back to the whole window by protocol). `keyboard_changed`: focus-changed event counter since the last call. `secure_focus`: `CurrentIsPassword`. `cover_at(at)`: the top-level window at the point when it is not the target's: `(pid, app_id, regular)` where `regular` = it would be listed by `applications()`; a UAC or lock screen is not seen in user mode. `close_cover`: `WM_CLOSE` unless `NEVER_CLOSE`. OCR: BGRA → `SoftwareBitmap` → `RecognizeAsync` (blocking wait, on the caller's thread), lines top to bottom; `ready()` false until both engines exist.

- [ ] **Step 1: Tests (Windows).** `focus_chain_of_an_edit_in_fake_app` (rectangles nest, first is the edit, last is the window); `password_edit_is_secure`; `deadline_is_honoured` (a 1 ms deadline returns a miss, not a late answer); `cover_is_another_apps_window`; `never_close_list_is_respected`; `ocr_reads_a_rendered_line` (the test draws “Hello 你好 123” with GDI into a bitmap; skipped with a printed reason when a language pack is missing, and then `ready()` must be false).
- [ ] **Step 2–5:** fail, implement, green, commit `feat(host-windows): UI Automation and text recognition`.

### Task 10: Lock state and power

**Files:** Create `src/win/lock.rs`.

**Behaviour.** `locked()` as in “Component choices”. `lock()`: `LockWorkStation`, then poll `locked()` for 2 s; `None` on success, `Some(error)` otherwise. `can_unlock()` → `false` in user mode (so `host-core` drops a received password and keeps reporting locked). `wake`, `type_units`, `press_return` do nothing in user mode. `stay_awake(on)`. When the input desktop is not `Default` and the session is not locked (UAC, Ctrl+Alt+Del screen): the picture stays on the last frame (capture returns `Ok(None)`), and `InputOps::blocked_by` answers the cover `consent.exe` path — `ControlOps::cover_at` returns `(0, "consent.exe", false)` with the name `系统确认（UAC）` so `host-core` sends `covered` as spec §7.4 fixes.

- [ ] **Step 1: Tests (Windows).** `not_locked_on_a_normal_desktop`; `stay_awake_sets_and_clears_the_execution_state` (read back with `powercfg /requests` is manual; the test only checks the calls succeed and the off call restores `ES_CONTINUOUS`); the lock test itself is by hand.
- [ ] **Step 2: By hand:** `rapp-host lock --json` locks and prints `{"ok":true}`; again prints `"already":true`; with a session open, locking shows the lock hint on the Mac and, after unlocking locally, the picture resumes within 1 s; a UAC prompt freezes the picture and a click produces the `covered` hint.
- [ ] **Step 3:** Commit `feat(host-windows): lock state, lock, stay awake`.

### Task 11: `rapp-service` knows the Windows worker

**Files:** Modify `rust/service/src/workers.rs`, `rust/service/src/main.rs` (argument), the `list_apps` answer and local `status`, `rust/hub/src/lib.rs` (`apps_event`), `rust/testkit/tests/service.rs`, `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`; `rust/svc-windows/src/supervise.rs` (`service_args`).

**Behaviour** (each is an added arm beside “linux”; the macOS and Linux arms do not change by a character): `permissions()` with `platform == "windows"` keeps `platform`, `error`, `applications`; `capabilities()` then reports `desktop: true` and `applications` as given; the `tccutil` reset runs only on macOS. New argument `--resident <system|user>`; `list_apps` answers and the local `status` carry `"resident"` only when the argument was given (so macOS and Linux answers gain no key). `--prelogin` is parsed and stored (phase F uses it): capabilities are then fixed — graphical, desktop; no applications, terminal, ports — and `"prelogin": true` is added. `autolock` treats `resident != system` on Windows as off. The worker is `rapp-host.exe` beside the service, started through `rapp_net::proc`.

- [ ] **Step 1: Tests.** `windows_permissions_keep_applications`; `windows_capabilities_report_desktop_and_applications`; `linux_arm_is_unchanged` (the existing Linux expectations, copied before the change, still pass); `resident_appears_only_with_the_argument` (the whole-object assertion in `testkit/tests/service.rs` stays as it is for macOS; a second test passes `--resident user` and expects the extra key); `prelogin_capabilities_are_fixed`; `hub_forwards_resident_and_prelogin`; `autolock_is_off_in_user_mode_on_windows`.
- [ ] **Step 2–4:** fail, implement, Mac gate green (`cargo test --workspace --no-fail-fast`), Windows gate green.
- [ ] **Step 5:** Commit `feat(service): Windows worker, resident and prelogin fields`.

### Task 12: What the controller says about a Windows host (shared Dart)

**Files:** Modify `gui/lib/permissions.dart`, the hint and access-log texts (`inputBlockedHint` in `gui/lib/ui/main_state.dart`, `gui/lib/access_log.dart`), the unlock prompt, the device card, the desktop session menu; tests beside each. This task runs on the Mac and ships with the normal macOS/iOS releases.

**Exact copy** (spec §10.6, §6.1, §6.6, §6.9, §7.4, §7.5):

| When | Text |
|---|---|
| reason `no display` | `这台电脑没有接显示器，画面出不来；文本终端和端口共享不受影响` |
| reason `session disconnected` | `这台电脑的桌面不在本机屏幕上（远程桌面断开，或被别的用户切走了）` |
| reason `not interactive` | `这台电脑还没有登录的桌面` |
| reason `other user` | `别的用户正在使用这台电脑` |
| `inputBlocked` with `by == "elevated"` | `这个窗口以管理员身份运行，这台电脑没装系统服务，不能远程操作` |
| `covered` with `bundleID == "consent.exe"` | the existing sentence + `，请打开桌面会话处理` |
| locked and the host's `resident == "user"` | no unlock box; `这台电脑没装系统服务，要在本机解锁` |
| device card, `prelogin == true` | `未登录，只能打开桌面` |
| unlock box when the host's `os == "windows"` | field label `密码或 PIN` |
| desktop session menu when the host's `os == "windows"` | item `发送 Ctrl+Alt+Del` — sends key `0x75` with flags ⌃ + ⌥ (down, up) |

Unknown reasons are shown as received. `missingPermissions` returns nothing for `platform == "windows"` (no macOS permission guide). Sentences that hard-code “Mac” are audited in phase H, not here.

- [ ] **Step 1: Tests:** one per row (exact string), plus `unknown_reason_is_shown_verbatim`, `mac_host_texts_are_unchanged` (golden strings copied before the change), `ctrl_alt_del_item_only_for_windows_desktop_sessions`.
- [ ] **Step 2–4:** fail, implement, `flutter analyze && flutter test` green.
- [ ] **Step 5:** Commit `feat(gui): the controller's wording for Windows hosts`.

### Task 13: Staging and acceptance

- [ ] **Step 1:** `scripts/stage-windows.ps1` copies `rapp-host-windows.exe` to `rapp-host.exe` in the version directory.
- [ ] **Step 2: Boundary checks, as tests in `rust/host-windows/tests/boundary.rs`:** no file under `src/` outside `src/win/` contains `cfg(windows)`, `windows::` or `unsafe`; no file in the crate mentions `host_core::protocol::Message` encoding functions or the wire module (it never builds bytes); `rust/host-core/src` contains no `cfg(windows)` / `target_os`.
- [ ] **Step 3: Acceptance from a Mac, host logged in and unlocked:** walk spec §15.3 row by row, skipping rows marked “只有系统服务方式有”; write pass / fail / 有限制 into `tasks/todo.md` under `## Windows 版 D 段（被控端，用户方式）` with the real-machine checks of Tasks 3–10. Run the Mac controller unmodified except Task 12.
- [ ] **Step 4:** `git merge main`; Mac gate and Windows gate green; merge to local `main`: `merge: Windows 被控端（用户方式）（feat/windows-host）`.

## Done when

From a Mac, every row of spec §15.3 not marked “只有系统服务方式有” passes against a logged-in, unlocked Windows machine; the boundary tests pass; `host-linux`, `Sources/` and the unix arms are untouched.
