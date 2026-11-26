# rApp Windows — Phase G (Install and Upgrade) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One `setup.exe` installs rApp in either mode on a clean machine; installed machines upgrade themselves, go back one version, survive a bad version, and uninstall without leaving anything of spec §12.2 behind.

**Architecture:** Every change to the system is made by one Rust function, `rapp-svc install`, and undone by `rapp-svc uninstall`; the Inno Setup script only unpacks a version directory and calls it. Each version lives in its own directory; install, online upgrade and rollback are the same **switch**: a `take-over` process of the target version stops the old supervisor, repoints the start entry, starts the new one, and goes back if it does not come up in 30 s. `rapp-svc` downloads and unpacks upgrades itself; `rapp-service` keeps the schedule, the idle rule and the user-facing state.

**Tech Stack:** Rust (`windows-sys`; the `windows` crate in one file for the shortcut); Inno Setup (pinned); PowerShell scripts; system `curl.exe`, `tar.exe`, `netsh.exe` by full System32 path.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` — §12 (all), §5.1, §13.1–13.2, §14.3 (steps 4–5), §18.5; §7.7 (the five costs shown in the installer).

**Written before its probes.** Written 2026-11-26, before **S4** (level 1), **I1** and **N2** (level 2) ran.

| Probe | If its result differs | What changes here |
|---|---|---|
| S4 (switching by repointing the start entry; 30 s health; going back) | S4 picked the fixed-path launcher instead | Tasks 4–5: the start entry is written once and points at `<install>\rapp-launch.exe`, which reads `current` and starts that version's `rapp-svc`; “repoint” becomes “write `current`” (atomic replace); everything else stays. Plan A's layout is changed in the same commit |
| I1 (who started the install; silent install; PATH; uninstall leaves nothing) | the original user cannot be told when a standard user elevates with another account | Task 3: the installer does not claim; the first interactive start of the GUI claims (plan F decision 1's window becomes “until the first claim”, and a claim when an owner exists needs an administrator). **Ask the user before switching to this**: it changes who may become the owner |
| N2 (firewall prompt in user mode) | the prompt returns after every upgrade | Task 2 adds one line to the user-mode “本机” page (shared Dart): `升级后系统可能再问一次防火墙` |

## Decisions made in this plan (spec §19.1 leaves them to the implementer)

1. **Uninstaller.** Inno Setup's own uninstaller stays (it knows how to delete itself). It first runs `rapp-svc uninstall`, which undoes every system change and removes every version directory; Inno then removes what is left of its own files. The uninstall registry entry is Inno's built-in one; `rapp-svc` keeps its `DisplayVersion` current after online upgrades. The script has no `[Registry]`, `[Icons]`, `[Run]` beyond the two calls below, and no service, firewall or PATH code.
2. **Shortcut target is `<install>\bin\rapp.exe`** (a path that never changes, so taskbar pins survive upgrades); its icon comes from the current version's `rapp-gui.exe`.
3. **Firewall rule through `%SystemRoot%\System32\netsh.exe advfirewall`**, rule name `rapp`, deleted by name before being added.
4. **Manifest address override lives in the registry in both modes** (`HKLM\Software\rapp\UpdateUrl` in system mode, `HKCU\Software\rapp\UpdateUrl` in user mode). `service.json`'s `update_url` is not read on Windows; `rapp-svc` reports the effective address in `status` and `rapp-service` uses that for its own check. One rule for both modes; the config reference says so in the same commit.
5. **Silent install in system mode always needs `/OWNER=<account>`**; without it the installer fails with `静默安装带系统服务时要用 /OWNER=<账户> 指定机主` and exit code 2, having changed nothing.
6. **Where switch state is kept:** `<install>\switch.json` (`previous`, `failed`), written only by `rapp-svc`. `current` stays the one-line file of spec §5.1. The start entry is the truth; both files are aligned to it.
7. **`rapp-svc` reads one value of the owner's configuration before login:** `auto_update` from the owner's `service.json` (read-only, at most 64 KiB, parsed as JSON, only that boolean taken; unreadable → default on). Nothing else of the data root is read by `rapp-svc`.
8. **Package integrity inside the zip:** the zip carries `VERSION` (one line) and `FILES.sha256`; after unpacking, both are checked before the directory gets its “complete” mark.

## Global Constraints

- Phases C and F are merged. `Request::{FetchUpdate, ApplyUpdate, Rollback}` exist in `rust/svc-windows/src/proto.rs` and answer `not supported` until this phase.
- **Nothing in a request is trusted.** `fetch-update` and `apply-update` carry a version (digits and dots only, checked by `switch::version_ok`); `rapp-svc` builds every path and address itself. The package address must start with `https://github.com/wizlijun/rapp/releases/download/`, or, when an override is set, with the override's `scheme://host/`.
- Programs are run by full path only: `%SystemRoot%\System32\{curl,tar,netsh}.exe` (the directory from `GetSystemDirectoryW`, never `PATH`, never an environment variable), and programs in `rapp-svc`'s install directory.
- Installing, upgrading, going back and uninstalling never end a text terminal and never ask for a reboot.
- Not changed by any step: power settings, Defender exclusions, input method settings, the default terminal, Windows Terminal's configuration, shell profiles, file associations, protocol registration (spec §12.2).
- Uninstall keeps: the data root, the pointer `%APPDATA%\rapp`, logs, passwords in Credential Manager. It deletes the update cache and the speech models.
- macOS and Linux behaviour of `rapp-update` and `rapp-service`'s updater does not change: every existing test of both crates passes unmodified; new behaviour sits behind `UpdateOpts::switcher` (None outside Windows).
- This phase does not publish anything: no tag, no release, no upload. Packaging output stays in `.build\windows-dist\` (first release is phase H).
- Branch `feat/windows-install`. Install tests run on a clean VM snapshot through `scripts/test-windows-install.ps1`, never on a person's daily machine.

## Review Focus

1. **The machine loses power or the process is killed at any point of a switch:** at the next boot one version runs, `current`, `bin\rapp.exe`, the shortcut and the firewall rule agree with it, and a half-unpacked directory is gone. → Tasks 4, 5.
2. **A new version whose `rapp-service` cannot start:** within about 30 s the old version runs again, the version is remembered as failed and is not installed automatically again; the controller can connect. → Task 5.
3. **A program running as the owner asks `fetch-update` for a version that is not the manifest's, or tries to point the update at its own server (`service.json`, an environment variable, a crafted version string such as `1.0.0\..\x`):** refused; nothing downloaded, nothing run. → Tasks 4, 6.
4. **`PATH` holds another program's entries, a quoted entry, a trailing `;`, mixed case, and is a `REG_EXPAND_SZ` with `%SystemRoot%` in it:** after install and uninstall every other entry is byte-for-byte what it was and the value type is unchanged. → Task 2.
5. **Uninstall while a text terminal runs, or while a remote session is open:** the terminals are listed and the user chooses (end them or cancel); a cancelled uninstall has changed nothing. → Task 3.

## File map

```
rust/update/src/
  lib.rs          PLATFORM and DEFAULT_URL per target; parse_manifest_for(bytes, platform)
  runner.rs       curl()/tar() program paths per target; Windows free space
  winpkg.rs       pure: package naming, address rule, unpack-and-check steps (through Runner)
rust/svc-windows/src/
  install.rs      the Items of spec §12.2: apply / undo / check, over a `System` trait
  system.rs       (windows) the real `System`: registry, service manager, PATH, firewall, uninstall entry
  shortcut.rs     (windows) the Start-menu shortcut — the only file using the `windows` crate
  switch.rs       pure: versions on disk, the switch as a list of steps, align, clean-up; (windows) runs them
  update.rs       fetch-update / apply-update / rollback; the before-login check
  main.rs         + install | uninstall | take-over
rust/service/src/
  update.rs       Windows path through `Switcher`
  update_win.rs   (windows) Switcher over the pipe client; idle time; process list
installer/windows/rapp.iss                 unpack + two pages + two calls
scripts/package-windows.ps1                sign (if a certificate is there), zip, installer, sums, manifest, BUILD-INFO
scripts/test-windows-package.ps1           the package self-check (gate step 4)
scripts/test-windows-install.ps1           install / upgrade / back / uninstall on a VM, with the before/after export
scripts/export-windows-state.ps1           writes everything of spec §12.2 to one text file
scripts/fetch-innosetup.ps1                pinned version + SHA-256
scripts/lib/release.sh                     write_manifest takes the platform key
docs/superpowers/specs/2026-11-13-rapp-config-reference.md   the Windows rows (`config-reference`)
```

## Component choices

| Need | Component | Notes |
|---|---|---|
| Installer | Inno Setup, version pinned in `scripts/fetch-innosetup.ps1` with its SHA-256; `PrivilegesRequired=admin`, `PrivilegesRequiredOverridesAllowed=dialog commandline`; `ArchitecturesAllowed=x64compatible`; `MinVersion=10.0.20348`; `CloseApplications=no`; `Uninstallable=yes` | the mode page is Inno's own “for all users / for me” choice with our texts |
| The installing user | Inno `ExecAsOriginalUser` for `rapp-svc claim-owner` | I1 |
| Service registration | `CreateServiceW` (`SERVICE_WIN32_OWN_PROCESS`, `SERVICE_AUTO_START`, LocalSystem, binary path quoted + ` service`), `ChangeServiceConfig2W` for failure actions (restart after 5 s, 5 s, 60 s; reset after 1 day) and description; `ChangeServiceConfigW` to repoint | service name `rapp` |
| User-mode start | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value `rapp` = `"<version dir>\rapp-svc.exe" user` | |
| PATH | system: `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`; user: `HKCU\Environment`; then `SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, "Environment")` | value type kept |
| Shortcut | `IShellLinkW` + `IPersistFile` through the `windows` crate; all users: `%ProgramData%\Microsoft\Windows\Start Menu\Programs\rApp.lnk`; user: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\rApp.lnk` | decision 2 |
| Firewall | `netsh advfirewall firewall add rule name=rapp dir=in action=allow protocol=UDP localport=22028 program="<version dir>\rapp-service.exe" profile=any` | system mode only; rewritten at every switch |
| SAS policy | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SoftwareSASGeneration` = 1 (3 if it was 2); the old state saved in `Settings::sas_policy_before` | system mode only |
| Install directory security | plan F's `guard::align`, called by install | |
| Download | `curl.exe --fail --location --proto =https --tlsv1.2 --max-redirs 5 --connect-timeout 20 -o <part>` (+ the resume and speed-limit arguments `rapp_update::fetch::download` already uses) | |
| Unpack | `tar.exe -xf <zip> -C <install>\.incoming-<version>` | the zip is made by the same `tar.exe -a -cf` in packaging, so the pair is tested together |
| Replace a file in one step | `MoveFileExW(MOVEFILE_REPLACE_EXISTING \| MOVEFILE_WRITE_THROUGH)` from a temp name in the same directory | `current`, `switch.json` |
| A file in use | rename it to `<name>.old-<n>` in the same directory, place the new one, delete the old ones at the next start | `bin\rapp.exe` |
| Signing | `signtool sign /fd SHA256 /tr <timestamp URL> /td SHA256 /sha1 <thumbprint>`, only when `RAPP_SIGN_THUMBPRINT` is set | otherwise skipped and recorded |
| Signer of a file | `WinVerifyTrust` + the leaf certificate's subject from `CryptQueryObject` | used only once both versions are signed |

---

### Task 1: `rapp-update` knows platforms

**Files:** Modify `rust/update/src/lib.rs`, `runner.rs`, `fetch.rs`; create `rust/update/src/winpkg.rs`; modify `scripts/lib/release.sh`, `scripts/package-macos.sh` (one argument).

**Interfaces — Produces:**

```rust
// lib.rs
pub const MACOS_PLATFORM: &str = "macos-arm64";
pub const WINDOWS_PLATFORM: &str = "windows-x64";
pub const WINDOWS_URL: &str = "https://github.com/wizlijun/rapp/releases/download/update-windows/latest.json";
pub const PLATFORM: &str = /* cfg(windows): WINDOWS_PLATFORM; else: MACOS_PLATFORM (Linux keeps today's value) */;
pub const DEFAULT_URL: &str = /* cfg(windows): WINDOWS_URL; else today's */;
pub fn parse_manifest_for(bytes: &[u8], platform: &str) -> Result<Option<Manifest>, String>;
pub fn parse_manifest(bytes: &[u8]) -> Result<Option<Manifest>, String>;   // = parse_manifest_for(bytes, PLATFORM)
// runner.rs
pub fn curl() -> String;   // unix: "/usr/bin/curl"; windows: <System32>\curl.exe
pub fn tar() -> String;    // windows only
// winpkg.rs (compiled everywhere, tested on the Mac)
pub const RELEASE_PREFIX: &str = "https://github.com/wizlijun/rapp/releases/download/";
pub const COMPLETE_MARK: &str = ".complete";
pub fn package_name(version: &str) -> String;                          // rapp-<v>-windows-x64.zip
pub fn site_of(url: &str) -> Option<&str>;                             // "https://host/" of an https URL
pub fn address_allowed(asset_url: &str, override_url: Option<&str>) -> bool;
pub const REQUIRED: [&str; 12] = ["rapp-gui.exe", "rapp-svc.exe", "rapp-service.exe", "rapp-hub.exe", "rapp-host.exe",
    "rapp-session.exe", "rapp-term.exe", "rapp-speech.exe", "rapp-cli.exe", "conpty.dll", "OpenConsole.exe", "VERSION"];
/// tar into `<install>\.incoming-<v>`, check VERSION, REQUIRED and FILES.sha256, write COMPLETE_MARK, rename to `app-<v>`.
pub fn unpack(r: &dyn Runner, zip: &Path, install: &Path, version: &str) -> Result<PathBuf, Failure>;
```

`fetch.rs` calls `runner::curl()` instead of the constant; `free_bytes` gets a Windows arm (`GetDiskFreeSpaceExW`). `write_manifest` in `release.sh` takes the platform key as a new second-to-last argument; `package-macos.sh` passes `macos-arm64` and its output is byte-identical to before.

- [ ] **Step 1: Tests (Mac).** `windows_manifest_parses` (`parse_manifest_for(…, "windows-x64")` on a manifest with only that key → Some; with only `macos-arm64` → None); `existing_parse_manifest_tests_unchanged`; `address_allowed_table` (release prefix ok; `https://github.com/wizlijun/rapp-evil/…` refused; `http://…` refused; override `https://mirror.example/x/latest.json` allows `https://mirror.example/y.zip` and refuses the GitHub address and `https://mirror.example.evil/…`); `unpack_checks` with the fake runner (tar succeeds but `VERSION` says another version → Verify failure and the incoming directory is removed; a required file missing → failure; a hash in `FILES.sha256` wrong → failure; good → directory renamed and marked); `unpack_refuses_existing_complete_version` (returns the existing path without running tar); `macos_manifest_bytes_unchanged` (shell test: `write_manifest` with `macos-arm64` equals a stored copy of today's output).
- [ ] **Step 2:** Implement. **Step 3:** `cargo test -p rapp-update -p rapp-service` on the Mac → all pass, none edited. **Step 4:** Commit `feat(update): platform key, Windows package checks`.

### Task 2: `rapp-svc install` / `uninstall` — the items

**Files:** Create `rust/svc-windows/src/install.rs`, `system.rs`, `shortcut.rs`; modify `main.rs`, `settings.rs`; create `scripts/export-windows-state.ps1`.

**Interfaces — Produces:**

```rust
// install.rs
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Item { InstallDir, Service, RunValue, Settings, Path, Shortcut, UninstallVersion, Firewall, SasPolicy, DataDirs }
pub fn items(mode: Mode) -> &'static [Item];
//   System: InstallDir, Settings, Service, Firewall, SasPolicy, Path, Shortcut, UninstallVersion, DataDirs
//   User:   InstallDir, RunValue, Path, Shortcut, UninstallVersion, DataDirs
pub struct Plan { pub mode: Mode, pub install: PathBuf, pub version: String, pub owner: Option<String> /* SID, silent installs */ }
pub trait System {            // everything install touches; `system.rs` is the real one, tests use `FakeSystem`
    fn reg_get(&self, key: &str, value: &str) -> Option<RegValue>;
    fn reg_set(&mut self, key: &str, value: &str, v: RegValue) -> io::Result<()>;
    fn reg_delete(&mut self, key: &str, value: Option<&str>) -> io::Result<()>;
    fn service(&self) -> Option<ServiceInfo>;                       // binary path, start type, state
    fn service_create(&mut self, command: &str) -> io::Result<()>;
    fn service_repoint(&mut self, command: &str) -> io::Result<()>;
    fn service_stop(&mut self, wait: Duration) -> io::Result<()>;
    fn service_start(&mut self) -> io::Result<()>;
    fn service_delete(&mut self) -> io::Result<()>;
    fn firewall_set(&mut self, program: &Path) -> io::Result<()>;
    fn firewall_remove(&mut self) -> io::Result<()>;
    fn shortcut_set(&mut self, all_users: bool, target: &Path, icon: &Path) -> io::Result<()>;
    fn shortcut_remove(&mut self, all_users: bool) -> io::Result<()>;
    fn broadcast_environment(&mut self);
    fn secure_dir(&mut self, dir: &Path, mode: Mode) -> io::Result<()>;
    fn remove_dir(&mut self, dir: &Path) -> io::Result<()>;
}
pub enum RegValue { Sz(String), ExpandSz(String), Dword(u32) }
pub fn apply(sys: &mut dyn System, plan: &Plan, item: Item) -> io::Result<()>;     // idempotent
pub fn undo(sys: &mut dyn System, mode: Mode, install: &Path, item: Item) -> io::Result<()>;   // idempotent; missing = ok
pub fn check(sys: &dyn System, plan: &Plan, item: Item) -> bool;
pub fn install(sys: &mut dyn System, plan: &Plan) -> Result<(), InstallError>;
pub fn uninstall(sys: &mut dyn System, mode: Mode, install: &Path) -> Vec<(Item, io::Error)>;   // goes on after a failure, reports all
// PATH, pure
pub fn path_with(current: &str, dir: &str) -> Option<String>;      // None: already there
pub fn path_without(current: &str, dir: &str) -> Option<String>;   // None: not there
pub fn same_dir(a: &str, b: &str) -> bool;                         // case, quotes, trailing backslash ignored; no variable expansion
```

**`install`:** (1) the other mode's leftovers first: `undo` each of the other mode's items that `check`s as present (a system-mode install removes the installing user's `Run` value and user PATH entry; a user-mode install refuses with `这台电脑已经装了带系统服务的 rApp，请先卸载它` when the service exists — an ordinary user cannot remove it); (2) `apply` each item of `items(mode)` in order; (3) on a failure, `undo` the ones applied in this run, in reverse, and return the error — unless a previous version was installed (then nothing is undone: the old one keeps running). `Settings` writes `Mode`, the owner when given, else `ClaimUntil = now + 600`. `SasPolicy` saves the old state once (never overwrites a saved one) and `undo` restores exactly it (value or absence). `Path` adds `<install>\bin`. `DataDirs` creates `%ProgramData%\rapp\{logs,update}` (system) with the rights of spec §13.2. The start entry (`Service` / `RunValue`) is **created** here pointing at this version; starting it is Task 5's switch.

`rapp-svc install --mode system|user [--owner <account>]` and `rapp-svc uninstall [--end-terminals]` print one line per item (`ok` / `FAILED: …`) and exit 0 / 1. `rapp-svc uninstall --list-terminals` changes nothing: it prints one line per running text terminal — every process whose image is `rapp-term.exe` under the install directory (process snapshot, all sessions in system mode), as `<pid>\t<user>\t<window title or empty>` — and exits 0. `uninstall` without `--end-terminals` refuses with exit 3 when that list is not empty; with it, those processes are ended first (the terminal's own close path of plan E, then `TerminateProcess` after 5 s). `--owner` is resolved with `LookupAccountNameW`; an unknown account is an error before anything changes.

`export-windows-state.ps1 -Out <file>`: one sorted text file with every item of spec §12.2 as the system shows it (service configuration, the three registry places, both PATH values with their types, both shortcut files, firewall rules whose name or program mentions rapp, the policy value, directory listings and ACLs of the install and data directories).

- [ ] **Step 1: Tests (Mac, `FakeSystem`).** `path_table` (Review Focus 4: `C:\a;"C:\b c";%SystemRoot%\x;` + ours → appended once, the rest untouched; mixed case and a trailing backslash count as present; removal restores the exact original string including the trailing `;`; `ExpandSz` stays `ExpandSz`); `install_then_uninstall_leaves_fake_system_equal` (both modes: snapshot before == snapshot after); `install_twice_is_the_same_as_once`; `sas_policy_restores_absence_and_value` (absent → absent; 0 → 0; 2 → set 3 → back to 2); `system_install_removes_user_mode_leftovers`; `user_install_refuses_when_service_exists`; `failed_item_undoes_this_runs_items_on_a_fresh_install_only`; `silent_owner_is_written_and_no_claim_window`; `uninstall_goes_on_after_a_failing_item`; `uninstall_refuses_with_terminals_unless_told` (fake process list: exit 3 and the fake system untouched; with `--end-terminals` they are ended first).
- [ ] **Step 2: Tests (Windows VM, in `test-windows-install.ps1`).** `export` before; `rapp-svc install --mode system --owner <test user>`; every `check` true and `sc qc rapp` shows auto start, LocalSystem, the failure actions; a new `cmd.exe` finds `rapp` on PATH without a reboot; `uninstall`; `export` after; **the two exports are equal** (audit §18.5 #1). Same for `--mode user` as a standard user.
- [ ] **Step 3:** Implement. `shortcut.rs` is the only user of the `windows` crate; name the crate and its features in the commit message. **Step 4:** Commit `feat(svc-windows): install and uninstall`.

### Task 3: The installer

**Files:** Create `installer/windows/rapp.iss`, `scripts/fetch-innosetup.ps1`; texts in `installer/windows/texts.zh.isl` (or inline).

**Behaviour.** Files: the staged `app-<version>\` only, into `{app}\app-<version>` (never into a directory that is in use). Pages: welcome (with `未签名` when `BUILD-INFO.json` says so); mode — `带系统服务（推荐）` / `只为我安装` — with the five costs of spec §7.7 under the first choice, in the spec's words; progress; finish (`打开 rApp`). Pre-checks in `InitializeSetup`, each with its sentence: build < 20348 → `需要 Windows 11 或 Windows Server 2022 及以上`; Server Core (no `explorer.exe`) → `这台服务器没有桌面，rApp 不支持`; not x64-compatible → refused. Location is fixed: `{commonpf64}\rapp` / `{localappdata}\Programs\rapp`; no directory page. After the files: `Exec` `{app}\app-<version>\rapp-svc.exe install --mode <m> [--owner <a>]` (elevated in system mode) — non-zero → show its output, roll back the files of this run, stop; then, in system mode with no `/OWNER`, `ExecAsOriginalUser` `rapp-svc.exe claim-owner`; then `rapp-svc.exe take-over --install` (Task 5). Command line: `/MODE=system|user`, `/OWNER=<account>`, the usual `/VERYSILENT`; decision 5. Uninstall: `[UninstallRun]`-equivalent in code — ask `rapp-svc.exe uninstall --list-terminals`; if it prints any, show them and ask `结束这些终端并卸载` / `取消`; then `rapp-svc.exe uninstall [--end-terminals]`; the finish page says what was kept (data, logs, saved passwords) and where.

The script contains no `[Registry]`, no `[Icons]`, no service, firewall or PATH code (audit §18.1; Task 7 checks it by a test).

- [ ] **Step 1: Tests (VM, `test-windows-install.ps1`, each from a clean snapshot):** interactive system install by an administrator → owner is that account; a standard user elevating with another account's password → owner is the **standard user** (I1); `/VERYSILENT /MODE=system /OWNER=<a>` run as SYSTEM → owner `<a>`; `/VERYSILENT /MODE=system` → exit 2, export unchanged; `/VERYSILENT /MODE=user` as a standard user → works, no elevation prompt; install on a build below 20348 is refused (run the check function with a faked build number through a `/TESTBUILD=` switch compiled only into a test installer); uninstall with a terminal running → the list appears, cancel changes nothing (export equal), accept ends them (Review Focus 5); after uninstall the data root, pointer, logs and Credential Manager entries are still there, the update cache and speech models are not.
- [ ] **Step 2:** Implement. **Step 3:** Commit `feat(installer): Inno Setup script`.

### Task 4: Fetching an upgrade in `rapp-svc`

**Files:** Create `rust/svc-windows/src/update.rs`, `switch.rs` (the pure part); modify `proto.rs`, `favours.rs`/request dispatch, `Cargo.toml` (+ `rapp-update`).

**Interfaces — Produces:**

```rust
// proto.rs — additions; all optional so older answers still parse
pub struct Status { /* … */ #[serde(default, skip_serializing_if = "Option::is_none")] pub update: Option<Update>,
                    #[serde(default, skip_serializing_if = "Option::is_none")] pub previous: Option<String>,
                    #[serde(default, skip_serializing_if = "Option::is_none")] pub update_url: Option<String> }
pub struct Update { pub version: String, pub phase: Phase, pub progress: u8, #[serde(default)] pub error: Option<String>,
                    #[serde(default)] pub needs_confirm: bool }
pub enum Phase { Fetching, Ready, Switching, Failed }          // lowercase on the wire
// Request::ApplyUpdate gains `#[serde(default)] confirm: bool` (plan C's block is updated with this plan)

// switch.rs (pure part)
pub fn version_ok(v: &str) -> bool;                              // 1–4 dot-separated groups of 1–6 digits, nothing else
pub struct Layout { pub install: PathBuf }
impl Layout { pub fn version_dir(&self, v: &str) -> PathBuf; pub fn current_file(&self) -> PathBuf; pub fn bin_rapp(&self) -> PathBuf;
              pub fn switch_file(&self) -> PathBuf; pub fn of_exe(exe: &Path) -> Option<(Layout, String /* own version */)>; }
pub fn complete_versions(install: &Path) -> Vec<String>;          // have COMPLETE_MARK; sorted oldest → newest
#[derive(Serialize, Deserialize, Default, PartialEq, Debug)]
pub struct SwitchState { pub previous: Option<String>, #[serde(default)] pub failed: Vec<String> }
/// Directories to delete: incomplete ones, `.incoming-*`, and complete ones that are neither `own` nor `previous`.
pub fn removable(entries: &[(String /* dir name */, bool /* complete */)], own: &str, previous: Option<&str>) -> Vec<String>;

// update.rs
pub fn fetch(peer_ok: bool, st: &UpdateShared, version: &str) -> Response;     // starts a thread; one at a time
pub enum SignerDecision { Go, NeedConfirm, Refuse }
pub fn signer_decision(current: Option<&str>, new: Option<&str>, automatic: bool) -> SignerDecision;
```

**`fetch-update`** (requester: the owner or SYSTEM in system mode; the user in user mode): `version_ok`; already complete on disk → `Ready` at once; else on a thread: manifest from the effective address (`rapp_update::fetch_manifest`) → its canonical version must equal the request, else `Failed` `not the current version`; `address_allowed`; `rapp_update::download` into the cache directory (size and sha256 are checked there) → `winpkg::unpack` into the install directory → in system mode `guard::align` → signer check → `Ready` (or `needs_confirm`). Progress = bytes of the part file / size, published through `status`. The cache directory is `%ProgramData%\rapp\update` / `%LOCALAPPDATA%\rapp\update`; the zip is deleted after a successful unpack. A second `fetch-update` while one runs answers `busy`.

`signer_decision`: none → none `Go`; none → signed `Go`; same signer `Go`; signer changed or signature gone → `Refuse` when automatic, `NeedConfirm` otherwise.

- [ ] **Step 1: Tests (Mac).** `version_ok_table` (`0.16.3` ok; `1`, `1.2.3.4` ok; empty, `1.0.0\..\x`, `1.0.0 `, `v1.0.0`, `1..2`, 40 digits → refused — Review Focus 3); `removable_table` (own and previous kept; an incomplete `app-9.9.9` and `.incoming-1.0.0` removed; other files and directories never listed); `switch_state_round_trip` and `unknown_keys_are_kept_out_without_error`; `signer_decision_table`; `fetch_refuses_a_version_that_is_not_the_manifests` and `fetch_refuses_a_foreign_package_address` (fake runner returning a manifest); `fetch_is_one_at_a_time`; `status_carries_update_progress`; `apply_update_json_without_confirm_still_parses`.
- [ ] **Step 2: Tests (Windows, ordinary user, user mode in a scratch install directory).** `fetch_from_a_local_https_fixture_unpacks_and_marks` (override address pointing at a test HTTPS server with a test package made by Task 7's script); `corrupted_zip_fails_and_leaves_no_directory`; `override_in_service_json_is_ignored` (Review Focus 3).
- [ ] **Step 3:** Implement. **Step 4:** Commit `feat(svc-windows): fetch-update`.

### Task 5: The switch

**Files:** Modify `rust/svc-windows/src/switch.rs` (Windows part), `update.rs`, `main.rs` (`take-over`), `service.rs`, `user.rs` (align at start).

**Interfaces — Produces:**

```rust
/// The steps of one switch, in order; `run` executes them and each is a no-op when already true.
#[derive(Debug, PartialEq)]
pub enum Step { StopOld, Repoint { to: String }, StartNew, AwaitHealthy { secs: u32 }, Commit { previous: String } }
pub fn plan(from: Option<&str>, to: &str) -> Vec<Step>;                      // from None = fresh install
pub fn undo_plan(from: &str, failed: &str) -> Vec<Step>;                     // StopNew(=StopOld), Repoint{from}, StartNew, MarkFailed
pub enum Outcome { Switched, WentBack { why: String }, Stuck { why: String } }
pub fn take_over(sys: &mut dyn System, layout: &Layout, mode: Mode, from: Option<&str>, to: &str, healthy: &dyn Fn(Duration) -> bool) -> Outcome;
/// Run by every rapp-svc at start (service and user): make everything agree with the directory this exe runs from.
pub fn align(sys: &mut dyn System, layout: &Layout, mode: Mode, own: &str) -> Vec<String /* what was changed, for the log */>;
```

**`apply-update { version, confirm }`:** version complete on disk; not `needs_confirm` unless `confirm`; then start `<install>\app-<version>\rapp-svc.exe take-over --from <own version> --mode <m> --wait-pid <own pid>` — detached, outside every job (`CREATE_BREAKAWAY_FROM_JOB`), as SYSTEM in session 0 in system mode — and answer `ok`. In user mode the old `rapp-svc` then stops its instance and exits by itself. **`rollback`:** the same with `previous`; no `previous` or its directory incomplete → `error: "no previous version"`.

**`take-over`:** `StopOld` — system: `service_stop(20 s)`, then end the process if it still runs; user: wait for `--wait-pid` to exit (20 s), then end it. Text terminals are not children of the supervisor's job (plan E) and stay. `Repoint` — `service_repoint` or the `Run` value. `StartNew` — `service_start`, or start `rapp-svc.exe user` detached. `AwaitHealthy` — poll the new pipe's `status` for `running == true && version == to`, up to 30 s. `Commit` — write `switch.json` (`previous = from`; drop `to` from `failed`). Not healthy → `undo_plan`: stop the new one, repoint to `from`, start it, add `to` to `failed`; outcome `WentBack`. If going back fails too → `Stuck`, logged with every step's error; the start entry is left pointing at `from`.

**`align`** (start of every `rapp-svc service` / `user`): `current` ← `app-<own>`; `bin\rapp.exe` ← copy of own `rapp-cli.exe` when the bytes differ (in-use file renamed away first); shortcut icon; firewall rule program (system); the uninstall entry's `DisplayVersion`; delete `removable(…)` directories and `*.old-*` files — a directory that cannot be deleted stays for next time, one log line. `failed` versions are never offered by the automatic path (Task 6) and can be applied by hand.

`take-over --install` (called by the installer): `from` = the version the start entry points at now, if any and different; same steps. A fresh install has only `StartNew`, `AwaitHealthy`, `Commit`.

- [ ] **Step 1: Tests (Mac, `FakeSystem`, fake health).** `plan_for_fresh_install_and_for_upgrade`; `healthy_switch_commits_previous`; `unhealthy_switch_goes_back_and_marks_failed` (Review Focus 2); `going_back_failing_reports_stuck_and_points_at_from`; **`interrupted_at_every_step`** (Review Focus 1: for each prefix of the step list, stop there, then run `align` as whichever version the start entry points at: `current`, `bin`, firewall, shortcut all agree with that version and `removable` drops the leftovers); `align_twice_changes_nothing_the_second_time`; `align_renames_a_busy_bin_away`; `rollback_without_previous_is_an_error`.
- [ ] **Step 2: Tests (VM, `test-windows-install.ps1`).** Build three test packages from one tree with versions `90.0.1`, `90.0.2` and `90.0.3-bad` (its `rapp-service.exe` replaced by a program that exits 1; version string `90.0.3`): install 90.0.1 → `apply` 90.0.2 → running version is 90.0.2 within 30 s, a text terminal opened before is still alive and usable, the firewall rule names the new path; `rollback` → 90.0.1; `apply` 90.0.3 → back on the previous version within about 60 s, `failed` holds 90.0.3, the controller still connects; **power-cut**: hard-reset the VM 2 s after `apply-update` returns, ten times → every boot ends with one running version and aligned files. Both modes. This test stays in the Windows gate's manual list (audit §18.5 #2).
- [ ] **Step 3:** Implement. **Step 4:** Commit `feat(svc-windows): switch, take-over, going back`.

### Task 6: `rapp-service` on Windows; the before-login check

**Files:** Modify `rust/service/src/update.rs`, `lib.rs` (`UpdateOpts`), `main.rs` (Windows arm turns the updater on); create `rust/service/src/update_win.rs`; modify `rust/svc-windows/src/update.rs`, `service.rs`.

**Interfaces — Produces:**

```rust
// rust/service/src/lib.rs
pub trait Switcher: Send + Sync {
    fn status(&self) -> Option<SvcUpdate>;                       // None: rapp-svc does not answer
    fn fetch(&self, version: &str) -> Result<(), String>;
    fn apply(&self, version: &str, confirm: bool) -> Result<(), String>;
    fn rollback(&self) -> Result<(), String>;
}
pub struct SvcUpdate { pub update: Option<(String, &'static str /* phase */, u8, Option<String>, bool)>, pub previous: Option<String>, pub update_url: Option<String>, pub version: String }
pub struct UpdateOpts { /* … */ pub switcher: Option<Arc<dyn Switcher>> }     // None on macOS: nothing changes there
// update_win.rs (windows)
pub struct PipeSwitcher { /* pipe name by mode */ }
pub fn idle() -> Option<Duration>;                                                  // GetLastInputInfo
pub fn read_procs_win(list: &[(u32, u32, String)], me: u32, install: &str) -> Option<Procs>;   // pure; same meaning as read_procs
```

With a `switcher`: **check** — manifest from `status().update_url` or the built-in address (the config's `update_url` is not read); the 20 h schedule, cache file, `offer`, `dismiss` are the existing code. **download** — `fetch(version)`, then poll `status()` each second into `progress`; `Ready` → state `ready`; `Failed` → the existing `fail(Stage::Download | Verify, text)`. **install** — the existing gates (idle rule for automatic; manual does not wait for remote sessions; GUI asked to quit; marker written), then `apply(version, confirm)`; the service is stopped by the switch, so nothing else is done after the call. **rollback** — `rollback()`; offered when `previous` is Some. **after a start** — the existing marker logic; additionally, `status().update` with phase `failed` for the marker's version → state `failed`, stage install, text `新版本没能启动，已回到上一版`, and that version is not installed automatically again (manual stays possible). `needs_admin` and the install level are never set. `procs()` uses a process snapshot (`CreateToolhelp32Snapshot` + image paths) through `read_procs_win`: the GUI is `rapp-gui.exe` under the install directory; `rapp-term`, `rapp-cli`, `rapp` (the `bin` copy) and `rapp-svc` never block. Reopening the GUI starts the own version directory's `rapp-gui.exe` through `rapp_net::proc`.

**Before login (`rapp-svc service`, system mode):** while `Want::Prelogin`, a timer with `rapp_update::should_check` / `CHECK_EVERY_SECS` and its own cache file in `%ProgramData%\rapp\update`; skipped when the owner's `auto_update` is false (decision 7), when a `rapp-host` it started is alive, or when the manifest's version is in `failed`. Otherwise: fetch as in Task 4 with `automatic = true`, then the switch. The same code path as a request, entered from the timer.

- [ ] **Step 1: Tests (Mac, fake `Switcher`, the service's existing test harness).** `macos_paths_untouched` (the whole existing updater suite passes unedited); `windows_download_goes_through_fetch_and_polls_progress`; `windows_auto_install_waits_for_the_idle_rule_then_applies`; `manual_install_ignores_remote_sessions`; `failed_take_over_is_shown_and_not_retried_automatically`; `rollback_offered_only_with_previous`; `config_update_url_is_ignored_with_a_switcher`; `read_procs_win_table` (GUI open → `gui`; only `rapp-term.exe` and `bin\rapp.exe` → nothing blocking; a `rapp-hub.exe` not under a GUI → `stray`; a process outside the install directory ignored). `svc-windows`: `prelogin_check_decisions` (pure function over: owner's `auto_update`, live hosts, due or not, failed list).
- [ ] **Step 2: By hand on the VM:** `rapp update`, `rapp update check`, `rapp update status`, `rapp update rollback` behave as on macOS; the GUI closes and reopens on the new version; with a remote desktop session open, an automatic install waits and a manual one goes ahead; cold boot with nobody logged in and a newer test package published on the fixture server → the machine is on the new version before anyone logs in, and a login screen session started from a controller postpones it.
- [ ] **Step 3:** Update the config reference (spec §13.4): `update_url` not read on Windows and the registry override; `auto_update` also governs the before-login upgrade. Same commit as the code.
- [ ] **Step 4:** Commit `feat(service): Windows upgrade through rapp-svc; before-login upgrade`.

### Task 7: Packaging, the self-check, acceptance, merge

**Files:** Create `scripts/package-windows.ps1`, `scripts/test-windows-package.ps1`, `scripts/test-windows-install.ps1`; modify `scripts/check-windows.ps1` (step 4 = package self-check with `-Build`).

**`package-windows.ps1 -Version <v> [-Notes <text>] [-Out .build\windows-dist]`:** `stage-windows.ps1 -Release -Gui` → write `VERSION`, `FILES.sha256` into the version directory → sign every exe and dll of ours and later the installer when `RAPP_SIGN_THUMBPRINT` is set, else record `signed: false` → `rapp-<v>-windows-x64.zip` (the version directory's contents at the root, made with System32 `tar.exe -a -cf`) → `rapp-<v>-windows-x64-setup.exe` (pinned `ISCC.exe`) → `SHA256SUMS` → `latest.json` (`write_manifest` with key `windows-x64`, address `…/releases/download/v<v>/rapp-<v>-windows-x64.zip`) → `BUILD-INFO.json` (version, commit, protocol number, rustc, Flutter, ConPTY package version, Inno Setup version, `signed`). It never tags, pushes or uploads.

**`test-windows-package.ps1 <dist dir>`** (spec §12.6): every name of `winpkg::REQUIRED` and the three VC++ runtime dlls present; every rApp exe reports the same version; `rapp-host.exe version --json` protocol equals the number in `rust/` (read from source by the script); no `.pdb`, `.ilk`, `.exp`, `.lib`; the zip unpacks with System32 `tar.exe` and matches `FILES.sha256`; `SHA256SUMS` matches; `latest.json` parses with `parse_manifest_for(…, "windows-x64")` (a small `cargo run --example`); licences present (`conpty` MIT text). One line per check, exit 0 / 1.

- [ ] **Step 1: Boundary tests (Mac, workspace):** `inno_script_changes_no_system_setting` (the `.iss` has no `[Registry]`, `[Icons]`, `[INI]` section and none of the words `sc.exe`, `netsh`, `reg add`, `setx`, `RegWrite`); `only_system32_tools_are_run` (source scan of `rust/svc-windows` and `rust/update` Windows arms: the program of every process start is `runner::curl()`, `runner::tar()`, the netsh helper, or `layout::sibling`); `update_requests_carry_only_a_version` (JSON of `FetchUpdate`, `ApplyUpdate`, `Rollback`: keys ⊆ {`op`, `version`, `confirm`}).
- [ ] **Step 2:** `scripts\check-windows.ps1 -Build` runs the self-check as step 4 → `EXIT=0`. Prove it can fail: delete `conpty.dll` from the stage, rerun → step 4 `FAILED`; restore.
- [ ] **Step 3: Full VM run, both systems (Windows 11, Server 2022), both modes:** install, upgrade, go back, bad version goes back by itself, uninstall, export diff empty. Results and the Inno Setup / ConPTY versions into `tasks/todo.md` under `## Windows 版 G 段（安装和升级）`, with the acceptance rows of spec §15.7.
- [ ] **Step 4: Audit §18.5** rows 1–2, 5–6 (rows 3–4 belong to the first release, phase H) and §18.2 row 8 (the owner cannot change the system-mode update address): write holds / does not hold with file and line.
- [ ] **Step 5:** `git merge main`; Mac gate and Windows gate green; merge to local `main`: `merge: Windows 安装和升级（feat/windows-install）`. The merge message names the `windows` crate (one file) and `rapp-update` as new dependencies of `rapp-svc`.

## Done when

On clean machines both modes install, upgrade, go back and uninstall with an empty before/after diff; a bad version goes back on its own; a machine nobody logs into upgrades itself; the package self-check is part of the Windows gate.
