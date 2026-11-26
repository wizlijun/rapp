# rApp Windows — Phase H (Finishing and First Release) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Voice input, input-method and taskbar polish land; every row of the alignment table (spec §15) is checked on real machines; the whole audit (spec §18) is repeated; the first Windows release is published (not Latest) and one installed machine upgrades online to the release after it.

**Architecture:** No new module. `rapp-speech` gains a Windows recorder beside the Linux one; everything else in this phase is checking, wording, documents and the release procedure of spec §14.4.

**Tech Stack:** Rust (`windows-sys` `waveIn*`; pinned `whisper-rs`), the Flutter Windows runner (C++), PowerShell, `gh`.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` — §10.4, §10.5, §10.3 (taskbar row), §14.4–14.6, §15 (all), §18 (all), §19.2.

**Written before its probes.** Written 2026-11-26, before **V1**, **G3**, **G4** (all level 2) ran.

| Probe | If its result differs | What changes here |
|---|---|---|
| V1 (whisper builds with the Windows toolchain; 10 s of speech in ≤ 5 s) | too slow | Task 1 turns on AVX2 for the whisper build and the package self-check gains “the CPU has AVX2” as an install pre-check with its sentence (`这台电脑的处理器太老，语音输入用不了` — voice is hidden, the rest installs). The minimum CPU goes into both READMEs |
| V1 | does not build | Task 1 is dropped: `PlatformCaps.voice` is false on Windows, the button is hidden, the package ships without `rapp-speech.exe` (remove it from `winpkg::REQUIRED` and the self-check in the same commit), §15.9 gains one line. First release goes ahead |
| G3 (Flutter text field with Microsoft Pinyin, Sogou, WeChat input) | one of the three behaviours is wrong for one input method | Task 2 fixes it in the runner (candidate-window position through `ImmSetCandidateWindow`/`ImmSetCompositionWindow`); what cannot be fixed goes to the known limits in `tasks/todo.md` and README. No native text field is built |
| G4 (pinned taskbar icon survives a version switch) | the pin breaks with the app id alone | Task 3: the shortcut and the pin point at a fixed-path windowless launcher `<install>\bin\rapp-open.exe` (a second copy of the CLI's “start the GUI” path, built from `rapp-cli` with the `windows` subsystem). Plan G's `REQUIRED` list and `align` gain that file |

## Decisions made in this plan

1. **Recorder: the `waveIn*` functions** (`winmm`), format 16 kHz, mono, 16-bit PCM, device `WAVE_MAPPER`. The system converts from the device's own format; no COM, no resampler of ours, no new dependency. The first Windows release uses the default recording device only (no device picker; neither has Linux).
2. **“Microphone is off” is told two ways:** before opening, the three privacy switches are read (`HKLM` and `HKCU` `…\CapabilityAccessManager\ConsentStore\microphone` `Value`, and `HKCU …\microphone\NonPackaged` `Value`; any `Deny` → off); after opening, a failure of `waveInOpen` / `waveInStart`. Both give `{"event":"error","code":"microphone"}`; no device at all gives `{"event":"error","code":"no-microphone"}`.
3. **Model location and name are the Linux ones with the Windows root:** `%LOCALAPPDATA%\rapp\speech\ggml-base.bin`, same size and SHA-256 constants (`linuxSpeechModelBytes`, `linuxSpeechModelSha256`). The Dart class keeps its name (`LinuxSpeechModel`): renaming touches Linux-maintained files for no gain (the same reason as spec §5.3 for `speech-linux`).
4. **The first release's version number** is taken by the ordinary rule of spec §14.4 on the day (`max(all v* tags, pubspec) + 1`). No special number.
5. **“Mac” wording audit rule:** a sentence that names the *remote* machine uses the peer's platform (`PeerOs` from the device list, already there for the OS marks): `这台 Mac` / `那台 Mac` → `这台电脑` / `那台电脑` when the peer is not macOS; sentences about macOS-only things (TCC consent boxes, 「终端」) stay as they are and are only shown for macOS peers. Sentences about the *local* machine go through `PlatformCaps`.

## Global Constraints

- Phases A–G are merged and the Windows gate is green on `origin/main`.
- Protocol number unchanged; no new protocol message; `Sources/`, `rust/host-linux/`, `rust/client-gtk/`, `rust/hub-ffi/` untouched.
- `rapp-speech` on Linux: its code path and its tests do not change (the recorder is chosen by `cfg`; shared code is moved, not edited). `whisper-rs` stays `=0.16.0`.
- Audio stays in memory: no file, no pipe to another process, no log line with recognised text.
- `CLAUDE.md` texts (spec §14.5 items 5–6) are shown to the user and need a yes before they are committed.
- Deploying the website, `--latest` and macOS/Linux assets belong to the Mac release session; this phase's sessions do not do them.
- Branches: `feat/windows-voice` (Task 1), `feat/windows-polish` (Tasks 2–4), `docs/windows-first-release` (Tasks 5–6, 8). Task 7 is run by the Windows session itself.

## Review Focus

1. **The recorder outlives its parent or leaves the microphone light on:** kill `rapp-gui.exe` while recording → `rapp-speech.exe` is gone within 2 s (it is in the GUI's job, spec §8.1) and the system's microphone indicator goes off. → Task 1.
2. **Right Alt held on a German (AltGr) layout:** no stuck modifier on the remote side after release; documented as a known limit, the button works. → Task 1.
3. **A Windows release takes Latest away from macOS:** after publishing, `gh release view --json isLatest` of the macOS release is still true and `releases/latest/download/latest.json` is the macOS manifest. → Task 7.
4. **Machines on the old Windows version start upgrading before the assets are checked:** the manifest on `update-windows` is replaced only after every asset's size and SHA-256 were compared on GitHub. → Task 7.
5. **A 【未验证】 survives in the spec, or a row of §15 is ticked without having been tried.** → Tasks 5, 6.

## File map

```
rust/speech-linux/
  Cargo.toml            + [target.'cfg(windows)'.dependencies] (anyhow, serde_json, whisper-rs =0.16.0, windows-sys)
  src/main.rs           cfg(any(linux, windows)) → speech::run()
  src/speech.rs         shared: start message, events, decode loop  (recorder calls move out)
  src/rec_linux.rs      (linux) parec — today's code, moved
  src/rec_windows.rs    (windows) waveIn recorder + privacy check
gui/lib/embed/linux_speech.dart     model path per platform; program through findBinary
gui/lib/platform_caps.dart          voice: true on Windows; shortcut row hidden (as Linux)
gui/windows/runner/                 IME position fix (only if G3 needs it); app id (already set in phase C)
rust/svc-windows/src/shortcut.rs    app id on the shortcut
website/app.js, website/releases.test.mjs, website/lib (selectDownloads)   Windows asset
README.md, README.zh-CN.md
CLAUDE.md                           spec §14.5 items 5–6 (after the user's yes)
tasks/todo.md                       ## Windows 版 H 段；验收总表
docs/superpowers/specs/…-windows-design.md     probe results in place of 【未验证】
```

## Component choices

| Need | Component | Notes |
|---|---|---|
| Recording | `waveInOpen(WAVE_MAPPER, WAVEFORMATEX{PCM, 1 ch, 16000 Hz, 16 bit}, CALLBACK_EVENT)`, 8 buffers of 20 ms (`CHUNK` samples) recycled with `waveInAddBuffer`; stop = `waveInReset` + `waveInUnprepareHeader` + `waveInClose` | features `Win32_Media_Audio`, `Win32_Media`, `Win32_System_Threading` |
| Recognition | `whisper-rs =0.16.0` (the Linux pin), built with MSVC + CMake | V1 |
| Parent gone | the GUI's job object (spec §8.1) plus: stdin end-of-file ends the worker, as on Linux | no `prctl` equivalent needed |
| Model download and check | the existing Dart class | decision 3 |
| Taskbar identity | `System.AppUserModel.ID` = `com.rapp.gui` on the shortcut through `IPropertyStore` (the `windows` crate, in `shortcut.rs`); the process sets the same id (plan C) | G4 |
| IME position | Flutter's own text input plugin; fix only what G3 shows | G3 |
| Release | `gh release create --draft`, `gh release upload`, `gh release edit --draft=false --latest=false`, `gh release upload update-windows latest.json --clobber` | uploads follow the proxy note in `tasks/todo.md` if the machine sits behind one |

---

### Task 1: Voice input

**Files:** Modify `rust/speech-linux/Cargo.toml`, `src/main.rs`, `src/speech.rs`; create `src/rec_linux.rs`, `src/rec_windows.rs`; modify `gui/lib/embed/linux_speech.dart`, `gui/lib/platform_caps.dart`, the side panel's shortcut row.

**Interfaces — Produces:**

```rust
// speech.rs (shared) — the recorder seam; both recorders feed the existing channel
pub(crate) trait Recorder: Send { }                      // dropping it stops recording and releases the device
pub(crate) enum RecError { Off /* privacy switch */, NoDevice, Other(String) }
// rec_linux.rs / rec_windows.rs
pub(crate) fn start(tx: SyncSender<Event>) -> Result<Box<dyn Recorder>, RecError>;   // sends Event::Audio(Vec<f32>) of CHUNK samples, then Event::End
// rec_windows.rs, pure and tested on Windows only by cfg, but written without system calls
pub(crate) fn mic_allowed(values: [Option<&str>; 3]) -> bool;         // any "Deny" → false; all absent → true
pub(crate) fn to_f32(pcm: &[u8]) -> Vec<f32>;                         // i16 LE → f32, same arithmetic as read_audio
```

`speech.rs::run` keeps everything except the `parec` block, which becomes `rec::start(tx.clone())`; `RecError::Off` → `{"event":"error","code":"microphone"}`, `NoDevice` → `{"event":"error","code":"no-microphone"}`. The fixture mode (`pcm_path`) is shared and unchanged. Dart: the model file is `%LOCALAPPDATA%\rapp\speech\ggml-base.bin` on Windows; the two new codes get their sentences (`麦克风被系统设置关掉了：设置 → 隐私和安全性 → 麦克风 → 允许桌面应用访问` / `没有找到麦克风`); the worker is found with `findBinary('rapp-speech')` and started through the no-window process helper; the shortcut row is hidden as on Linux.

- [ ] **Step 1: Tests.** Mac/Linux: the existing `speech.rs` tests pass unedited after the move. Windows: `mic_allowed_table`; `to_f32_matches_read_audio` (same bytes through both → same samples); `fixture_pcm_decodes` (the existing fixture test, now also built on Windows — proves V1's “builds and decodes”); `recorder_start_stop_100_times` (ignored by default; run by hand: no handle growth in Task Manager). Dart: `speech_model_path_windows`, `speech_error_codes_have_sentences`.
- [ ] **Step 2: Implement.** The recorder thread waits on the event, copies each finished buffer through `to_f32`, sends it, re-queues the buffer; `Drop` resets, unprepares, closes, joins.
- [ ] **Step 3: By hand, Windows 11 and Server 2022:** hold right Alt 0.3 s → recording; release → text sent; Esc cancels; Tab edits; only while rApp is the foreground window; 10 s of speech gives its text within 5 s (V1's line — write the measured time into `tasks/todo.md`); microphone privacy switch off → the sentence, not silence; no microphone (a server) → the other sentence; kill the GUI while recording (Review Focus 1); AltGr layout (Review Focus 2); first use downloads the model with progress and a wrong digest is refused (rename a random file to the model name).
- [ ] **Step 4:** `speech-linux` licences directory gains nothing new (same dependency); `BUILD-INFO.json` records the whisper version. Commit `feat(speech): Windows recorder`. Merge `merge: Windows 语音输入（feat/windows-voice）` after both gates.

### Task 2: Input methods (G3)

**Files:** `gui/windows/runner/` (only if needed), `tasks/todo.md`.

- [ ] **Step 1:** With Microsoft Pinyin, Sogou and WeChat input, on Windows 11, in the input block, the writing board and “type on the picture”: (a) the candidate window follows the caret, also at 125 % and 150 % scaling and on a second monitor; (b) Enter during composition commits the text and does not send; (c) the first key of “type on the picture” is not lost and arrives in the composition; (d) switching Chinese/English with Shift does not reach the remote side as a Shift tap; (e) input history ↑/↓ does not fire while candidates are open. Write the 3 × 5 table into `tasks/todo.md`.
- [ ] **Step 2:** Fix every failing cell that can be fixed in the runner or in shared Dart (a shared-Dart fix must not change macOS/Linux behaviour: add the test that pins the old behaviour first). What cannot be fixed: one line each under known limits.
- [ ] **Step 3:** Commit `fix(gui): Windows input method …` per fix.

### Task 3: Taskbar (G4)

**Files:** `rust/svc-windows/src/shortcut.rs`, `rust/svc-windows/src/install.rs` (the `System::shortcut_set` call gains the app id).

- [ ] **Step 1: Test (VM):** install, pin the running rApp to the taskbar, `apply-update` to the next test version, click the pin → the new version starts, one taskbar button (no second icon beside the pin); the Start-menu entry likewise; `--cm` small window groups under the same button. Repeat after `rollback`.
- [ ] **Step 2:** Implement (app id on the shortcut). If the pin still breaks → the fallback row of the table above.
- [ ] **Step 3:** Commit `feat(svc-windows): app id on the shortcut`.

### Task 4: Wording audit

**Files:** `gui/lib/**` strings; tests beside them.

- [ ] **Step 1:** List every user-visible string in `gui/lib/` containing `Mac`, `macOS`, `访达`, `终端`, `⌘`, `⌥`, `系统设置`, `钥匙串`, `菜单栏`, `Dock`, `launchd`, `.app`, `pkg` (known today: `main_state.dart:3567`, `:3570`, `pages/local_section.dart:196`, and more). For each: local or remote machine; shown on Windows or to a controller of a Windows host; verdict keep / reword / hide. The list goes into the commit message.
- [ ] **Step 2:** Apply decision 5. Shortcut hints shown on a Windows controller use `Ctrl`/`Alt` names through the existing key-label function (add the Windows arm there, not at call sites — audit §18.1 #4: the count of `Platform.isWindows` does not grow).
- [ ] **Step 3: Tests:** one widget test per reworded sentence with a Windows peer and with a macOS peer (the macOS text is byte-identical to before). `flutter test` on the Mac. Commit `fix(gui): wording for Windows peers and Windows controllers`. Merge `merge: Windows 输入法、任务栏和措辞收尾（feat/windows-polish）`.

### Task 5: The alignment walk (spec §15)

**Files:** `tasks/todo.md` (`## Windows 版验收总表`).

- [ ] **Step 1:** Copy every row of spec §15.1–§15.7 into the table: row, spec section, **tried on** (Windows 11 / Server 2022 / both), **with** (Mac, Linux, iPad, Windows controller), result, note. A row counts only when someone did it on a real machine with the installed package (not a debug build) and wrote the date.
- [ ] **Step 2:** Matrix to cover (spec §17.3): Windows host × {macOS, Linux, iOS, Windows} controllers; Windows controller × {macOS, Linux, Windows} hosts; system mode and user mode; a laptop with the lid closed, a server with no monitor, a remote-desktop session connected and disconnected; Chinese system with the three input methods; two monitors with different scaling; an old controller (0.15.41 Mac) against the Windows host. One row that has no automated test on Windows and must be walked here: **key change** — on the real relay (with the user's OK, spec D8) or a relay started on the Mac for the purpose, rotate the key while a Windows machine is online as host and as controller: it is disconnected and says the key changed, stops dialling, reconnects with the same device id once the new key is entered, and says “bad key” for a wrong one (the eight tests of `rust/conn/tests/relay.rs` and `rust/testkit/tests/key_change.rs` that are unix-only since phase A).
- [ ] **Step 3:** Every failing row: fix (own branch, both gates) or — only for rows the spec already lists as limits (§15.9) — write the limit. A failing row that is not in §15.9 and cannot be fixed is **asked to the user** before release; it is not silently added to the limits.
- [ ] **Step 4:** §15.9's ten items appear, in the spec's words, in both READMEs and on the installer's mode page where they concern the choice of mode.

### Task 6: The full audit (spec §18) and the documents

**Files:** `tasks/todo.md` (`## Windows 版首发审计`), the spec, the files of spec §19.2.

- [ ] **Step 1:** Every row of §18.1–§18.6 again, by someone who did not write the code of that row where the spec says so (§18.2): holds / does not hold, with the command run or the file and line read. Rows with an automatic test name the test. §18.4 #6 (network capture after a fresh install) and §18.4 #3 (search of all logs after unlock, paste, typing, pairing) are done on the release candidate package.
- [ ] **Step 2:** §18.3 #6: `cargo test --workspace` time on the Mac before phase A (from `tasks/todo.md` of phase A) and now; more than 20 % slower → find out why before release.
- [ ] **Step 3:** The spec: each 【未验证，探针 X】 replaced by the result (`已验证（日期，机器）` or `已知限制：…`), §16's table gains a result column; `/usr/bin/grep -c 未验证` on the spec prints 0 (§18.6 #3).
- [ ] **Step 4:** §19.2: every listed sentence in the old documents is corrected or marked superseded with a pointer to the Windows spec; README protocol number corrected. `config-reference` holds every Windows path, registry value, environment variable and file added in phases A–H (compare against `rg -n "HKLM|HKCU|RAPP_[A-Z_]+|ProgramData|LOCALAPPDATA" rust/ gui/lib scripts`).
- [ ] **Step 5:** `rust/svc-windows/` line count written down (§18.2 #10). Licences: every dependency added in A–H with its licence in one list in `tasks/todo.md`; ConPTY's MIT text and whisper.cpp's MIT text in the package (§18.5 #8).
- [ ] **Step 6:** Commit by path, merge `merge: Windows 首发前的验收和审计记录（docs/windows-first-release）`.

### Task 7: The first release

Run by the Windows integration session, which becomes the release session with this task.

- [ ] **Step 1: Before anything is published — ask the user (one question each):** (a) the `CLAUDE.md` text of spec §14.5 items 5–6, shown in full; (b) “publish the first Windows release now?” with the audit summary and the list of known limits. No release without both answers.
- [ ] **Step 2: Website and READMEs** (feature branch, Mac gate): `selectDownloads` picks the newest release that has `rapp-*-windows-x64-setup.exe`; `website/releases.test.mjs:30` becomes two tests (no Windows asset → `null`; with one → that asset, and macOS still picks its own release); `app.js` shows the Windows button with `x64` and, while unsigned, the note `未签名：首次运行时 Windows 会提示，选“仍要运行”` (en/ja/zh). READMEs: install table row (Windows 11 / Server 2022, x64; the two modes; the unsigned note; silent install switches), the §15.9 list, the five costs of §7.7, credits (ConPTY, MIT, Microsoft). Merge to main; **deployment is the Mac release session's** — tell it through `tasks/todo.md`.
- [ ] **Step 3: Create the fixed release once:** tag `update-windows` on the first commit that has the Windows gate (not a version tag), `gh release create update-windows --title "Windows update manifest" --notes "Holds latest.json for installed Windows machines. Not a version." --latest=false`. Check that the macOS release is still Latest.
- [ ] **Step 4: Release, by spec §14.4, in this order:** dedicated worktree at the commit → Windows gate with `-Build` (stop on a real failure) → `git fetch`, merge `origin/main`, pick the number → commit `release: x.y.z` (pubspec version and build number, `rust/Cargo.toml`, `Cargo.lock`), tag `vx.y.z`, **push main and the tag at once**; rejected → fetch, merge, pick again → `scripts\package-windows.ps1 -Version x.y.z` → `scripts\test-windows-package.ps1` → install the produced `setup.exe` on the clean VM and run the short path of `test-windows-install.ps1` → `gh release create vx.y.z --draft --latest=false`, upload `setup.exe`, the zip, `SHA256SUMS` → compare each asset's size and digest on GitHub with the local files → publish with `--latest=false` → **check Latest is still the macOS release and `releases/latest/download/latest.json` is the macOS manifest** (Review Focus 3) → only now upload `latest.json` to `update-windows` with `--clobber`, then download it anonymously and compare (Review Focus 4) → commit `docs(release): record Windows x.y.z verification and downloads` (`tasks/todo.md` entry: source commit, sizes, digests, signed or not; refresh `website/releases.json`), push.
- [ ] **Step 5: `CLAUDE.md`** items 5–6 committed (text as approved in Step 1) in the same push as Step 4's record.
- [ ] **Step 6: The online upgrade.** A machine with the first release installed (system mode) and a second one (user mode) stay on. The next Windows-affecting merge produces release n+1 by the same steps; both machines move to it on their own within the check interval (or `rapp update` by hand on one of them), with a text terminal open across the upgrade; then `rapp update rollback` on one and back. A machine that nobody logs into (system mode, cold boot) upgrades too. Results into `tasks/todo.md`.

### Task 8: Hand-over to steady state

- [ ] **Step 1:** `tasks/todo.md`: the Windows sections of phases A–H collapsed to what is still open (real-machine checks not done, known limits, the follow-ups of spec §15.8 and “after first release” items: `host-linux` on `host-core` (U9), code signing certificate (U4), virtual display (U3), arm64).
- [ ] **Step 2:** The integration session's notes (machine name, checkout path, VM snapshots, where the Inno Setup and ConPTY pins live, how the gate log is read) into `docs/windows-release-session.md`, linked from `CLAUDE.md`'s new section.
- [ ] **Step 3:** Remove finished worktrees and branches of phases A–H on both machines.

## Done when

The first Windows release exists and is not Latest; the website (after the Mac session's deploy) and both READMEs show it; a system-mode machine and a user-mode machine went from it to the next release online; the spec holds no 【未验证】; `CLAUDE.md` describes the Windows release session.
