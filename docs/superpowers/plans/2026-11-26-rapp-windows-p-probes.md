# rApp Windows — Phase P (Probes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every 【未验证】 in the Windows design with a measured result on real machines, so that the plans for phases C–H can be written from facts instead of guesses.

**Architecture:** Each probe is a small throwaway program on its own branch `probe/windows-<id>` under `probes/windows/<id>/`. It never merges into `main`. What merges into `main` is one results page: for every probe, what was run, on which machine, what was measured, pass or fail, and the exact recipe that worked (API calls, flags, crate versions). Level-1 probes gate the design; level-2 probes only pick between a feature and its written fallback.

**Tech Stack:** Rust (stable, `x86_64-pc-windows-msvc`) with the `windows` crate for system calls; Flutter for the G probes; Swift + Rust on the Mac for C1; Inno Setup for I1.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` — §16 is the source of every row here (what to answer, pass line, fallback); §17.3 lists the machines. Read §16 in full before starting. This plan adds what §16 leaves out: files, the candidate system calls to try, the test matrix, and what to write down.

## Global Constraints

- **No product code.** Nothing under `rust/` (except reading it), `gui/lib/`, `Sources/` changes in this phase. `Sources/` never changes for Windows work at all (spec U10).
- Probe code lives only on `probe/windows-<id>` branches, in `probes/windows/<id>/`. A Rust probe is a standalone Cargo project with an empty `[workspace]` table in its `Cargo.toml`, so it does not join `rust/`'s workspace or touch `rust/Cargo.lock`.
- Probe branches stay on the machine that ran them. Do not push them unless the user asks. **The results page is the deliverable**, so it must carry the recipe in words: someone who never sees the probe code must be able to write the product code from it.
- Results page: `docs/superpowers/specs/2026-11-26-rapp-windows-probe-results.md`. It is edited on a docs branch (`docs/windows-probe-results`) and merged into the local `main` of the machine doing the work, following `CLAUDE.md`. Docs-only merges do not trigger a release.
- Baseline systems: Windows 11 (build ≥ 22000) and Windows Server 2022 with Desktop Experience (build ≥ 20348). x64 only. Windows 10 is not tested and not supported.
- A probe does not install drivers, does not inject DLLs, does not install hooks, and changes no system setting outside what its row in §16 says (S1 turns on the software-SAS policy and must turn it back off; I1 installs and uninstalls). Each probe lists what it changed and restores it.
- Never record passwords, tokens or typed text in the results page or in probe logs. The lock-screen and login probes read the password from an environment variable set for that run only.
- **Level 1 fails → stop that line of work, do not improvise.** Write the result, then tell the user (spec §16: "一级…没过就不能照本文做，要回来改设计，改之前先告诉用户"). Rows whose fallback says "回来问用户" (H1, S1, S2) or "回来告诉用户" (G1 on the cloud server, T1) always go to the user.
- **Level 2 fails → take the fallback written in §16**, change that feature's row in spec §15 to “有限制”, no need to ask.
- Pass-line numbers are starting points (spec §16, §19.3 #33). If a measured number shows a line is wrong, change it in the spec together with the reason; do not silently pass or fail.
- Windows-side probes need a Windows machine with a checkout and a way to get the results page back. That is plan A, Task 1 (`2026-11-26-rapp-windows-a-foundation.md`); it has no dependency on any probe and is done first. C1 runs on the Mac and needs nothing.
- On the Mac: `grep` is ugrep, use `/usr/bin/grep`; Flutter is `~/development/flutter/bin/flutter`, not on `PATH`. Never read `docs/archives/`.
- Pin every version the probe depends on and write it in the results page: Rust toolchain, `windows` crate, `flate2` and its backend, `portable-pty`, ConPTY package, Flutter, Inno Setup, `whisper-rs` (`=0.16.0`, the version `rust/speech-linux/Cargo.toml` already pins).

## Review Focus

These are the ways a probe gives a wrong "pass". Each line names the task that guards against it.

1. A probe passes on the developer desktop and nobody runs it on the Server 2022 cloud machine with no GPU → every capture, UI and service probe has the cloud machine as a required row of its matrix (Tasks 3, 4, 5, 7, 8, 10, 11).
2. Capture looks right by eye but pixels are off (colour space, premultiplied alpha, one-pixel border) → H1 and H3 compare against a generated test pattern numerically, not by looking (Tasks 4, 5).
3. Input "works" on Notepad only → H5's matrix is six named apps and the count is exact: 20 runs × 1000 characters, zero lost (Task 6).
4. A service probe passes while a user is logged in and the screen is on, and the real case (cold boot, nobody at the machine) was never run → S2 is run from a cold boot with no local input, and says so in the result (Task 8).
5. An "A/B switch" probe passes 40 times in a row but was never interrupted → S4 includes a bad version and a power cut in the middle (Task 9).

---

## Order

From spec §16.6:

1. **Task 1 (results page)**, then **Task 2 (C1, Mac)** and **Task 3 (G1)**. Cheapest, and they gate plans B and A.
2. Three lines in parallel: **Tasks 4–6** (H1, H3, H5), **Tasks 7–9** (S1, S2, S4), **Tasks 10–11** (T1, T5).
3. **Task 12 (G2)** after plan A is done (`rapp-session` must build on Windows).
4. **Tasks 13–18** (level 2) at the start of the phase that owns them, before that phase's plan is written.

What each result unlocks:

| Result | Unlocks |
|---|---|
| C1 | plan B (host-core) |
| G1 | plan A (foundation) |
| G2 | plan C (controller) |
| H1, H3, H5 | plan D (host, user mode) |
| T1, T5 | plan E (text terminal) |
| S1, S2 | plan F (system service) |
| S4, I1 | plan G (install and update) |

---

### Task 1: Results page and machine inventory

**Files:**
- Create: `docs/superpowers/specs/2026-11-26-rapp-windows-probe-results.md`

- [ ] **Step 1: Create the results page with this skeleton**

```markdown
# rApp Windows 探针结果

规格：`2026-11-26-rapp-windows-design.md` §16。每个探针一节，做完一个填一个。

## 机器

| 代号 | 机器 | 系统和内部版本 | 处理器 / 显卡 | 屏幕和缩放 | 备注 |
|---|---|---|---|---|---|

## 工具版本

| 工具 | 版本 |
|---|---|

## 总表

| 号 | 级 | 结论（过 / 没过 / 部分） | 走的是原方案还是退路 | 日期 | 做的人 |
|---|---|---|---|---|---|

## <号>：<标题>

- **分支和提交**：`probe/windows-<id>` @ `<hash>`（在哪台机器上）
- **做了什么**：
- **量到什么**（表格，每台机器一行，带数字）：
- **过关线**：<从规格抄>　**结论**：
- **能用的做法**（系统调用、标志、crate 和版本，写到没看过探针代码的人能照着写）：
- **不能用的做法和原因**：
- **改了系统的什么，还原了没有**：
- **带进哪一段计划的结论**：
```

- [ ] **Step 2: Fill the machine table** with every machine from spec §17.3 that is available: Windows 11 desktop with a discrete GPU and two screens at different scaling (code `W11-D`); Windows 11 laptop with integrated graphics (`W11-L`); Windows Server 2022 cloud machine without a GPU (`S22-C`); a machine or VM with no display attached (`NODISP`); a standard (non-admin) account on one of them; a Chinese system with Microsoft Pinyin, Sogou and WeChat input methods. For each: `winver` build number, `dxdiag` adapter, scaling per screen. A machine that is not available is written as “没有”, and every probe row that needs it says so instead of passing.

- [ ] **Step 3: Fill the tool table** after installing on the Windows machines: Git for Windows (`git config --global core.autocrlf false`), Visual Studio 2022 Build Tools with the C++ workload and the Windows 11 SDK, `rustup` stable with `x86_64-pc-windows-msvc`, Flutter at the version the Mac release session builds with (3.44.1 on 2026-11-26; confirm with `flutter --version` on the Mac).

- [ ] **Step 4: Commit** on `docs/windows-probe-results`: `docs(spec): Windows 探针结果页骨架和机器清单`.

---

### Task 2: C1 — does a Rust deflate produce the same bytes as Swift (level 1, on the Mac)

**Files (branch `probe/windows-c1`):**
- Create: `Tests/RappCoreTests/DeflateProbeTests.swift` (probe branch only)
- Create: `probes/windows/c1/Cargo.toml`, `probes/windows/c1/src/main.rs`
- Output: `probes/windows/c1/corpus/<n>.in`, `<n>.out`

- [ ] **Step 1: Read `Sources/RappCore/Deflate.swift`** and write down in the results page exactly what it calls: which library (zlib `deflate` or the Compression framework), level, window bits, memory level, strategy, and at which points it flushes and with which flush mode. Spec §16 says “系统 zlib，6 级，同步刷新”; confirm it from the code.

- [ ] **Step 2: Write `DeflateProbeTests.swift`**: one test that builds a corpus and writes, for each input, `<n>.in` (raw bytes) and `<n>.out` (what `Deflate` produces, using the same stream lifetime the encoder uses: if the encoder keeps one stream across frames and sync-flushes per frame, the corpus is a sequence fed to one stream, and `<n>.out` is the bytes emitted for that item). The corpus: empty input; 1 byte; 64 KiB of zeros; 64 KiB of random bytes (fixed seed); 200 real tile payloads taken from the existing scroll fixture generator (`Tests/RappCoreTests/CrossFixtureTests.swift`, `ScrollScenes.swift`); the same 200 as one continuous stream; one 4 MiB input.

Run: `swift test --filter DeflateProbeTests`
Expected: corpus files written.

- [ ] **Step 3: Write the Rust probe.** `flate2` with the level, window bits and flush points from Step 1, built once per backend through Cargo features: `rust_backend` (miniz_oxide), `zlib` (libz-sys, stock zlib built from source with the `static` feature — Windows has no system zlib, so the bundled build is what would ship), `zlib-ng`, `zlib-rs`. For each backend and each corpus item: compress, compare with `<n>.out`, print the first differing offset. Also inflate every `<n>.out` and check it equals `<n>.in`.

Run: `cargo run --release --no-default-features --features <backend>` for each of the four.
Expected: a table of backend × item → identical / differs at offset N.

- [ ] **Step 4: Verdict.** Pass = one backend is identical on every item. Record which, with exact crate versions and features. If none: the standard for the deflate layer becomes “Swift's decoder inflates host-core's output to identical bytes” (spec §14.2, §16 C1), every other layer stays byte-exact; record which backend is closest and smallest to build. Either way also record, for the chosen backend, that its C-style interface crate (`libz-sys`, `libz-ng-sys` or `libz-rs-sys`) provides `deflateCopy`, and run the corpus once more through that interface directly (not through `flate2`) to confirm the same bytes: `host-core` links the backend that way, because it has to copy a stream and must not change the workspace's `flate2` features (plan B, Task 3).

- [ ] **Step 5: Record and commit.** Probe branch: `probe(windows-c1): deflate byte-identity`. Results page section C1 on the docs branch.

---

### Task 3: G1 — does the Flutter app start on Windows (level 1)

**Files (branch `probe/windows-g1`):**
- Use: `gui/windows/` as it is in the repository (`CMakeLists.txt`, `flutter/`, `runner/` are already there; it has never been built). Only if it fails to configure with the current Flutter, regenerate it on the probe branch with `flutter create --platforms=windows .` inside `gui/` and write down what differed — plan A applies exactly those differences to the product tree
- Create: `probes/windows/g1/NOTES.md` (per-plugin table)

- [ ] **Step 1: Plugin table.** For every dependency in `gui/pubspec.yaml`, write whether it is a plugin, and whether its `pubspec.yaml` declares `flutter: plugin: platforms: windows`. List the ones that do not.

- [ ] **Step 2: Build.** `flutter build windows --release`. Fix only what blocks the build (stub a plugin without a Windows implementation behind a `Platform.isWindows` check on the probe branch); write each blocker down.

- [ ] **Step 3: Run without a service** and check, on `W11-D`: the main window appears; text renders (Chinese included); the tray icon shows with an `.ico` and its menu opens and reacts; closing the window hides it to the tray and the tray brings it back; starting a second copy brings the first to the front and exits (try a named mutex in `gui/windows/runner/main.cpp` plus `FindWindow`/`SetForegroundWindow`).

- [ ] **Step 4: Run on `S22-C`** (no GPU; Flutter should fall back to software rendering). Same checks, over the console session, not only over RDP. Note the frame time of scrolling the overview.

- [ ] **Step 5: Verdict.** Pass = all of Step 3 on both machines. Plugins without Windows support: decide per plugin “replace” or “do it in the runner”, write it into the results page (this list becomes tasks in plan C). Fails on the cloud machine → tell the user (the fallback narrows the server to host-only use).

- [ ] **Step 6: Record and commit.**

---

### Task 4: H1 — per-window capture, then compose (level 1)

**Files (branch `probe/windows-h1`):**
- Create: `probes/windows/h1/Cargo.toml`, `src/main.rs`, `src/pattern.rs` (a test-pattern window the probe draws itself)

- [ ] **Step 1: Write the probe.** It opens N test windows of its own (each fills its client area with a known pattern: per-window solid colour plus a 1-pixel checker in one corner and a frame counter), then captures every top-level window of a target process with the per-window capture API: `Windows.Graphics.Capture` — `IGraphicsCaptureItemInterop::CreateForWindow`, `Direct3D11CaptureFramePool::CreateFreeThreaded`, `GraphicsCaptureSession` with `IsBorderRequired = false` and `IsCursorCaptureEnabled = false`. It reads frames back to BGRA in memory and reports, per window: frames per second, time from a pattern change to the frame that shows it, and the maximum per-channel difference against the known pattern.

- [ ] **Step 2: Run the matrix.** N = 1, 3, 10 windows; targets: the probe's own pattern windows, Notepad, Chrome (with a menu open), VS Code. Cases: a window fully covered by another app; a window partly off-screen; minimised; moved and resized during capture; on a second screen with different scaling. Machines: `W11-D`, `W11-L`, `S22-C` (no GPU — does a WARP device work?). Measure CPU with 10 windows at 30 fps.

- [ ] **Step 3: Also record three loose facts** the spec marks 【未验证】 with no probe of their own: (a) for every `HWND` seen, whether the upper 32 bits are zero (spec §6.3 uses the low 32 bits as the window id); (b) whether the yellow border can be turned off on build 20348 and on 22000 (spec §3.1); (c) for two Store apps (Calculator, Settings), whether the real process can be found from the `ApplicationFrameHost.exe` window (child window of class `Windows.UI.Core.CoreWindow`, its process id) (spec §6.4).

- [ ] **Step 4: Verdict.** Pass (spec §16 H1) = no border and no pointer in any frame; a fully covered window's content is exact; 10 windows use no more than half a core; the no-GPU machine produces frames. **Fail → stop and ask the user**: the fallback (crop from the whole screen) is a product regression.

- [ ] **Step 5: Record and commit.** The recipe section must say how the device was created (hardware or WARP), the pixel format, how frames were read back, and how resize was handled (`Recreate` of the frame pool).

---

### Task 5: H3 — whole-screen capture with desktop duplication (level 1)

**Files (branch `probe/windows-h3`):**
- Create: `probes/windows/h3/Cargo.toml`, `src/main.rs`

- [ ] **Step 1: Write the probe.** One process duplicates one output with DXGI Desktop Duplication (`IDXGIOutput1::DuplicateOutput`, also try `IDXGIOutput5::DuplicateOutput1` with a BGRA format list for HDR screens), acquires frames at 30 fps, scales to a target density (try both: on the GPU, and in memory after readback), reads back BGRA, and reports CPU, GPU, frame times and colour difference against a full-screen test pattern it shows itself. A `--count N` mode starts N such processes in the same login session against the same output.

- [ ] **Step 2: Run the matrix.** 4K at 30 fps on `W11-D`; `W11-L` (integrated plus discrete: which adapter owns the output); an HDR screen if there is one; a portrait-rotated screen; a Hyper-V VM; `S22-C`. `--count 8` on `W11-D` and `S22-C`: does every one of the 8 get frames, at what rate.

- [ ] **Step 3: Verdict.** Pass = 4K 30 fps capture plus scaling ≤ 40% of one core; every machine produces frames with correct colour; **8 processes all get frames**. If only the 8-process line fails, that is not a failure of the probe: record it and the design switches to one capture process per login session (spec §6.5, already written; no need to ask). If single machines fail, record which fallback worked there (per-screen `Windows.Graphics.Capture` item via `CreateForMonitor`, then GDI `BitBlt` at 15 fps). General failure → back to the design.

- [ ] **Step 4: Record and commit.** The recipe must say where scaling is done and what it costs each way (this is a builder's choice in spec §19.1, and plan D needs the number).

---

### Task 6: H5 — input (level 1)

**Files (branch `probe/windows-h5`):**
- Create: `probes/windows/h5/Cargo.toml`, `src/main.rs`, `src/text.rs`, `src/fg.rs`, `src/elevated.rs`

- [ ] **Step 1: Text.** Send a fixed 1000-character sample (Chinese, English, digits, punctuation, emoji outside the BMP, `\n`, `\t`) with `SendInput` and `KEYEVENTF_UNICODE` (surrogate pairs as two events; try `\n` as `VK_RETURN` versus as a Unicode event), 20 times, into each of: Notepad, Chrome (a `<textarea>`), VS Code, Windows Terminal (running `more`), Word or another Office app, one Java (Swing) program. Read the text back (save file, or copy all via the clipboard) and compare exactly. Record characters lost or reordered, and the batch size and delay that gave zero loss.

- [ ] **Step 2: Keys.** Send scan-code keys (`KEYEVENTF_SCANCODE`, with `KEYEVENTF_EXTENDEDKEY` where needed) for a row of letters, digits, arrows, Home/End, Delete, and the modifiers, under a US layout, a UK layout and a German layout. Record what each produces; the expectation is "the key at that physical position".

- [ ] **Step 3: Foreground.** Bring a background window to the front 50 times with each of these, counting successes: plain `SetForegroundWindow`; `AttachThreadInput` to the foreground thread first; a synthetic Alt key press before the call; `SwitchToThisWindow`; `SetWindowPos` topmost then not topmost. Run it from a process with no window of its own (that is what `rapp-host` is).

- [ ] **Step 4: Elevated windows.** Start Notepad as administrator. From a normal-user process, try each of the six operations and record success, or the exact failure (return value, `GetLastError`): capture it (Task 4's API); bring it to the front; move it; resize it; ask it to close (`WM_CLOSE`); read its controls (UI Automation). Then send input to it and record how the block shows up (`SendInput` return value and last error), and whether "is the target elevated" can be known before sending (`OpenProcess` + `OpenProcessToken` + `TokenElevation` / integrity level).

- [ ] **Step 5: Clipboard marker** (loose fact, spec §6.7): copy a password from a password manager (KeePassXC or 1Password) and list the clipboard formats present; record whether `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory`, `CanUploadToCloudClipboard` appear and with what values.

- [ ] **Step 6: Verdict.** Pass = 20 × 1000 characters with nothing lost or reordered in all six apps; 50 of 50 foreground attempts with at least one method; a definite failure signal when blocked; a definite answer for each of the six elevated-window operations. Apps where text fails use the paste path (fallback, no need to ask). No reliable block signal → the rule becomes "check elevation before sending".

- [ ] **Step 7: Record and commit.** The recipe names the one foreground method plan D will use.

---

### Task 7: S1 — the secure-desktop helper (level 1)

**Files (branch `probe/windows-s1`):**
- Create: `probes/windows/s1/Cargo.toml`, `src/main.rs` (three modes: `service`, `helper`, `ctl`)

- [ ] **Step 1: Write the probe.** `service`: a Windows service running as SYSTEM that, on a command from `ctl` over a named pipe, starts `helper` inside the interactive user's session with a SYSTEM token (`WTSGetActiveConsoleSessionId`, duplicate its own token, `SetTokenInformation(TokenSessionId)`, `CreateProcessAsUserW` with `lpDesktop = "winsta0\\default"`). `helper`: a loop that follows the input desktop (`OpenInputDesktop` + `SetThreadDesktop`, re-done whenever capture or input fails with access denied), captures with desktop duplication, sends input with `SendInput`, and streams frames back two ways for timing: over the pipe, and through a shared-memory section with an event.

- [ ] **Step 2: Lock screen.** Lock the machine. From `ctl`: get frames of the lock screen; type the password (read from an environment variable of the `ctl` run; never logged) and Enter. 20 times on Windows 11, 20 times on Server 2022. On Server 2022 the lock screen asks for Ctrl+Alt+Del first: turn on the policy `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SoftwareSASGeneration` (value 1 = services), call `SendSAS(FALSE)` from the service, wait until the password box is on screen (how to know: record what worked), then type.

- [ ] **Step 3: UAC and the Ctrl+Alt+Del screen.** Trigger a UAC prompt; check that the helper's frames show it and that a click on “是” lands. Send the software SAS; check that the security screen appears in the frames and that Esc leaves it.

- [ ] **Step 4: Elevated windows from the helper.** Against an administrator Notepad: bring to front, move, resize, `WM_CLOSE`. All four must work from the helper.

- [ ] **Step 5: Latency.** Per-frame added delay of the helper path versus capturing in-process, pipe versus shared memory, at 1080p and 4K.

- [ ] **Step 6: Verdict.** Pass = 20/20 unlocks on both systems; UAC visible and clickable; the security screen appears; four window operations work; added delay ≤ 5 ms per frame. Any item impossible → **stop and ask the user** whether the system service is still worth it.

- [ ] **Step 7: Restore and record.** Turn the SAS policy back to what it was; remove the probe service (`sc delete`). The recipe names the transport (pipe or shared memory) with numbers. Commit.

---

### Task 8: S2 — connect before anyone has logged in (level 1)

**Files (branch `probe/windows-s2`):**
- Extend: `probes/windows/s1/` (same service; add a `prelogin` mode that listens on a TCP port instead of a local `ctl`)

- [ ] **Step 1: Write the mode.** The service starts at boot (session 0), starts the helper in the console session while that session shows the login screen (`winsta0\winlogon` via following the input desktop), and relays frames and input to a TCP client on another machine. Standard input and output of the child must be connected across sessions (inheritable pipe handles in `STARTUPINFO`); this is how `rapp-service --prelogin` will talk to `rapp-host`.

- [ ] **Step 2: Cold boot, hands off.** Power the machine on; do not touch it. From the other machine: see the login screen; type the password; log in. Then the service must notice the logon (`SERVICE_CONTROL_SESSIONCHANGE` with `WTS_SESSION_LOGON`) and start a second helper in the owner's session; measure the time from Enter to the first frame of the owner's desktop.

- [ ] **Step 3: Variants.** A machine with auto-logon turned on. Server 2022 (SAS first, then the password). **Another user at the console**, in two cases: the owner has never logged in since boot; the owner is logged in but switched to the background. In both, the probe must report "other user", must not send a single frame of that user's desktop, and must not lock or disconnect that user.

- [ ] **Step 4: Verdict.** Pass = login screen visible and login succeeds from the controller; reconnection to the owner's session within 10 s with no manual step; the other-user cases behave as in Step 3. Login screen cannot be captured → **stop and ask the user**. Slow reconnection is only tuning.

- [ ] **Step 5: Record and commit.** The recipe states exactly how the owner's session was told apart from another user's (the account SID of the session, `WTSQuerySessionInformation` with `WTSUserName`/`WTSDomainName`, or the session token's user SID).

---

### Task 9: S4 — switching versions and falling back (level 1)

**Files (branch `probe/windows-s4`):**
- Create: `probes/windows/s4/Cargo.toml`, `src/main.rs` (a fake supervisor and a fake payload), `switch.ps1` (driver)

- [ ] **Step 1: Write the probe.** Lay out the install tree from spec §5.1 with two fake versions `app-A`, `app-B`: a `current` file, `bin\`, one directory per version. Fake `rapp-svc` in each version; a switch = unpack is already done, rewrite `current` atomically (`ReplaceFileW` / `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`), repoint the start entry (system mode: `ChangeServiceConfigW` binary path; user mode: the `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value), stop the old supervisor, start the new one. The new one must report "healthy" within 30 s or the old one is put back and the bad version is marked "do not auto-install".

- [ ] **Step 2: Run.** System mode and user mode, 20 round trips each, unattended. One version that exits at once (must fall back after 30 s and must not be tried again automatically). A text terminal stand-in (a process started from the old version directory, outside the job object) must survive every switch. Cut the power (VM hard reset) at three points: after the unpack, between `current` and the start entry, during the service restart; after each, the machine must come up on A or on B, and be reachable.

- [ ] **Step 3: The other structure.** Build the alternative from §16 S4: the system registers a tiny launcher at a fixed path which reads `current` and starts that version. Run the same tests. Compare: number of system changes per upgrade, behaviour on power cut, whether antivirus reacts to a changing service path.

- [ ] **Step 4: Verdict.** Pass = 40 switches unattended; the bad version rolls back by itself after 30 s and is not installed again; the stand-in terminal never dies; after every power cut the machine is on A or B and reachable. Pick one of the two structures and write why. Whichever is picked becomes fixed in plan A (the install tree) and plan G.

- [ ] **Step 5: Record and commit.**

---

### Task 10: T1 — the bundled ConPTY (level 1)

**Files (branch `probe/windows-t1`):**
- Create: `probes/windows/t1/Cargo.toml`, `src/main.rs`
- Uses: the OSC 7501 recordings already in the repository (find them with `/usr/bin/grep -rl "7501" rust/term/tests rust/term/src`), fed through a child process

- [ ] **Step 1: Get a ConPTY build.** Take `conpty.dll` and `OpenConsole.exe` (x64) from the `Microsoft.Windows.Console.ConPTY` NuGet package; record the exact version and file hashes.

- [ ] **Step 2: Write the probe.** A child program that writes a given byte file to its standard output and exits. The probe runs it under a pseudo-console three ways and saves what comes out of the PTY: (a) `portable-pty` (the version `rust/term/Cargo.toml` pins) with the bundled `conpty.dll` next to the executable; (b) the system `CreatePseudoConsole` from `kernel32`; (c) calling the bundled DLL's `ConptyCreatePseudoConsole` directly. Flags to try: `PSEUDOCONSOLE_PASSTHROUGH_MODE` if the bundled version has it.

- [ ] **Step 3: Feed it.** Every OSC 7501 recording; title changes (`OSC 0`, `OSC 2`); directory reports (`OSC 7`, `OSC 9;9`); a 1 MiB burst. Then run the existing scanner (`rust/term`'s program-status scanner, compiled into the probe as a path dependency, read-only) over the output and compare its result with the same input on the Mac.

- [ ] **Step 4: Verdict.** Pass = the sequences arrive unchanged and the scanner's result equals the unix result, on Windows 11 and on Server 2022 (where the system ConPTY is older). Record which of (a)/(b)/(c) passes. (a) fails but (c) passes → the product calls the DLL directly. Neither → system ConPTY, program status unavailable on a Windows host; **tell the user**.

- [ ] **Step 5: Record and commit**, including the pinned ConPTY version.

---

### Task 11: T5 — terminals open and stay (level 1)

**Files (branch `probe/windows-t5`):**
- Create: `probes/windows/t5/Cargo.toml`, `src/main.rs` (`supervisor`, `service`, `serve`, `run` stand-ins)

- [ ] **Step 1: Write the probe.** `supervisor` creates a job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK`, starts `service` in it, which starts `serve`, which opens a terminal window running `run` (a loop printing a counter and holding a loopback TCP connection to `serve`). The window is started with `CREATE_BREAKAWAY_FROM_JOB`. Three ways to open: `wt.exe -w 0 new-tab -- <run>` (Windows Terminal is a Store app; `wt.exe` is an app execution alias under `%LOCALAPPDATA%\Microsoft\WindowsApps`); `wt.exe` when no Windows Terminal window exists; a plain console window (`CREATE_NEW_CONSOLE`) when Windows Terminal is not installed.

- [ ] **Step 2: Run** from an interactive session and from a process started by a SYSTEM service into the user's session (Task 7's launcher). Then, with terminals open: kill and restart `service`; kill and restart `supervisor`; simulate an upgrade (start everything again from a second directory). After each: is the terminal window still there, is `run` still counting, can the new `serve` find it again (the `run` side reconnects to a port written in a file under the data directory).

- [ ] **Step 3: Other things that must survive.** With the same three restarts: Notepad and Chrome started by a worker inside the job with `CREATE_BREAKAWAY_FROM_JOB`; a GUI stand-in started the same way. All must still be running.

- [ ] **Step 4: Verdict.** Pass = terminals open in all three situations; after all three restarts the terminals, the opened apps and the GUI are still there and usable. `wt.exe` cannot be started from a service-launched process → always a plain console window. Breakaway refused → terminals are not put in the job at all.

- [ ] **Step 5: Record and commit.**

---

### Task 12: G2 — is "decode in a process, paint in Dart" fast enough (level 1; after plan A)

**Files (branch `probe/windows-g2`):**
- Uses: `rapp-session.exe` built by plan A; the Flutter build from Task 3 with the session view wired to it

- [ ] **Step 1:** Connect to a Mac host from `W11-D` on a 4K screen at 150% scaling. Full-screen a browser and an editor on the Mac; scroll continuously for 60 s each.
- [ ] **Step 2:** Measure: frames per second painted; share of UI-thread frames over 16 ms (Flutter's performance overlay or `--profile` timeline); the same on `W11-L`; the same scene on a Linux controller of similar hardware for comparison.
- [ ] **Step 3: Verdict.** Pass = 30 fps held; under 5% of UI-thread frames over 16 ms; not worse than the comparable Linux controller. Fail → plan C gains the native-texture work (decoded frames go straight to a GPU texture in the runner; Dart only positions it). No need to ask; record the numbers.
- [ ] **Step 4: Record and commit.**

---

### Task 13: Level-2 probes for plan D — H2, H4, H6, H7

Run at the start of phase D, on the branches `probe/windows-h2`, `-h4`, `-h6`, `-h7`, reusing Task 4–6 code.

- [ ] **H2 (menus, tooltips, drop-downs).** Try capturing these small windows on their own with Task 4's API; try cropping them out of the whole-screen frame by rectangle (how many frames behind the main window, what to do with the shadow). Pass = a menu appears in the picture within 100 ms of opening, in the right place. Fallback: crop everything from the whole screen, drop shadows.
- [ ] **H4 (desktop switches).** Normal desktop ↔ UAC, lock screen, the Ctrl+Alt+Del screen; resolution change; monitor unplug and replug; a full-screen game. Does capture come back by itself (`DXGI_ERROR_ACCESS_LOST` → re-duplicate). Separately, as a normal-user process: is there a clear signal that the secure desktop appeared and went away (`WTSRegisterSessionNotification` lock/unlock; `OpenInputDesktop` failing; `SwitchDesktop` events), and can "locked" be told from "not locked but switched away". Pass = picture back within 1 s, session survives; user-level process knows within 1 s and can tell locked from not locked. Fallbacks as in §16.
- [ ] **H6 (keep the host in English).** With an English layout installed: switch layout (`WM_INPUTLANGCHANGEREQUEST`, `ActivateKeyboardLayout`). With only a Chinese input method: switch its conversion mode to alphanumeric (`ImmSetConversionStatus` / `ImmSetOpenStatus` on the focus window, or the TSF compartment `GUID_COMPARTMENT_KEYBOARD_OPENCLOSE`). Microsoft Pinyin, Sogou, WeChat input. Pass = after session start, raw keys produce English letters. Fallback: log it and show the controller hint.
- [ ] **H7 (text recognition).** `Windows.Media.Ocr`: `OcrEngine::AvailableRecognizerLanguages`; behaviour without the Chinese language pack; whether it exists on Server 2022; time for an 800×200 image. Pass = Simplified Chinese and English recognised, ≤ 200 ms. Fallback: do not report the `text` capability.
- [ ] **Record each in the results page and commit.**

### Task 14: Level-2 probes for plan E — T2, T3, T4

- [ ] **T2 (pass-through of the outer console).** In a Windows Terminal tab and in a classic console window: keys, paste, mouse and resize arrive as escape sequences (`ENABLE_VIRTUAL_TERMINAL_INPUT`, `ENABLE_VIRTUAL_TERMINAL_PROCESSING`); Ctrl+C arrives as byte 0x03 (`ENABLE_PROCESSED_INPUT` off); there is time to clean up when the window is closed (`CTRL_CLOSE_EVENT`); the tab closes by itself after `run` exits 0. Pass = Claude Code, vim and `cmd` line editing work in both; a terminal ended on purpose closes its tab.
- [ ] **T3 (window follows the controller's size).** Send `ESC[8;<rows>;<cols>t` to both terminal kinds; for the classic console also try resizing the window directly. Pass = at least one terminal follows.
- [ ] **T4 (foreground program and directory).** Walk from the shell to its newest descendant (`CreateToolhelp32Snapshot`); the directory-report sequences each shell emits (`cmd`, PowerShell, Git Bash); reading another process's current directory. Pass = program name right under all three shells; directory right for shells that report it.
- [ ] **Record each and commit.**

### Task 15: Level-2 probe for plan F — S3 (Remote Desktop)

- [ ] With RDP connected: what does the capture show. After RDP disconnects: reattach the session to the console (`tscon <id> /dest:console` from SYSTEM) and lock at once (`LockWorkStation` in that session); then unlock from the probe. On `S22-C` (no physical output): is there a picture after reattaching. With the owner inside an RDP session: where does `SendSAS` land.
- [ ] Pass = the RDP desktop is captured while connected; reattach, lock and unlock work; where the SAS lands is known and written down. Fallbacks as in §16.
- [ ] Record and commit.

### Task 16: Level-2 probes for plan G — I1, G4

- [ ] **I1 (installer details).** A minimal Inno Setup script on `probe/windows-i1` that calls a stand-in `rapp-svc install --mode system`. A standard user elevates with another account's admin password: who is "the user who started the install" (`{userinfoname}`, the original user's SID through the `runasoriginaluser` flag, `WTSQueryUserToken` of the active session). Silent install as SYSTEM with `/OWNER=<account>` and without. Does a `PATH` change take effect without a reboot (`WM_SETTINGCHANGE`). What the unsigned-installer prompt looks like (screenshot). After uninstall, check every item of spec §12.2.
- [ ] Pass = the owner is that standard user; silent install with `/OWNER` gets the named account, without it fails with a clear reason; nothing left after uninstall.
- [ ] **G4 (taskbar pin across version directories).** Same `AppUserModelID` on the process (`SetCurrentProcessExplicitAppUserModelID`) and on the shortcut; pin; switch version directory; click. Pass = the pin stays and starts the new version. Fallback: the pin points at a tiny windowless launcher at a fixed path under `bin\`.
- [ ] Record each and commit.

### Task 17: Level-2 probes for plans C and D — N1, N2, G3

- [ ] **N1 (reserved port ranges).** On a machine with Hyper-V, WSL2 and Docker Desktop: `netsh int ipv4 show excludedportrange protocol=tcp` and `protocol=udp`; do the ranges touch 22028, 22029 or 28000–28999; bind a reserved port and record the error (`WSAEACCES` 10013 versus `WSAEADDRINUSE` 10048). Pass = defaults do not collide; a collision can be reported as "reserved by the system". Never change the system's reservations.
- [ ] **N2 (firewall in user mode).** As a standard user: does the first UDP 22028 listen show the firewall prompt; what direct and relay connections do when it is not allowed; does the prompt come back after the version directory changes. Pass = behaviour known and written down; relay works without clicking allow.
- [ ] **G3 (input methods in the Flutter text field).** Microsoft Pinyin, Sogou, WeChat input: does the candidate window follow the caret; does Enter during composition only commit; is the first key lost when typing straight onto the picture. Pass = all three correct under all three.
- [ ] Record each and commit.

### Task 18: Level-2 probe for plan H — V1 (voice)

- [ ] Build `whisper-rs =0.16.0` with the MSVC toolchain; run the same 10 s clip as on Linux; compare time. Pass = builds; 10 s of speech in under 5 s. Fallback: turn on newer CPU instruction sets (then a minimum CPU must be fixed), or ship the first Windows controller without voice and hide the button.
- [ ] Record and commit.

---

### Task 19: Close the loop with the design

- [ ] **Step 1:** For every probe, fill the summary table at the top of the results page.
- [ ] **Step 2:** For every level-2 fallback taken, edit the matching row of spec §15 to “有限制” and add the limit to §15.9.
- [ ] **Step 3:** For every pass-line number that was changed, edit spec §16 with the measured value and the reason.
- [ ] **Step 4:** Remove each 【未验证】 in the spec that now has an answer (replace with “见探针结果 <号>”). The two that no available machine can answer (x64 emulation on ARM laptops, spec §2.2 and §12.1) stay marked and are listed in the results page as "not tested".
- [ ] **Step 5:** Tell the user, in one message: which level-1 probes passed, which failed and what that changes, and which level-2 fallbacks were taken. Level-1 failures are told as soon as they are known, not saved for this step.
- [ ] **Step 6:** Commit the spec and results-page edits on the docs branch; merge into the local `main` per `CLAUDE.md`.
