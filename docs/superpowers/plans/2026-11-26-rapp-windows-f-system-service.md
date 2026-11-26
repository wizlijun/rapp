# rApp Windows — Phase F (System Service) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With the system service installed, a Windows machine is reachable from boot: the controller sees and operates the login screen, the lock screen, UAC prompts and administrator windows, unlocks remotely, sends Ctrl+Alt+Del, and gets a disconnected Remote Desktop session back.

**Architecture:** `rapp-svc service` is a small Windows service (SYSTEM). It follows login sessions, starts `rapp-service` as the owner in the owner's session, and does four privileged favours over one named pipe: start the secure-desktop helper, start the prelogin worker, send the secure attention sequence, reattach a session. The helper is `rapp-host secure-helper`: the same capture and input code as the user-mode worker behind a pipe shell. Nothing here adds a protocol message.

**Tech Stack:** Rust; `windows-sys` (the version already in `rust/Cargo.lock`) — no service framework crate; serde_json for the pipe.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` — §7 (all), §5.2, §5.3 (boundary 3), §6.6, §6.9, §8.1, §13.2–13.3, §18.2, §18.4.

**Written before its probes.** Written 2026-11-26, before **S1, S2** (level 1) and **S3** (level 2) ran. Read the results first.

| Probe | If it failed | What changes here |
|---|---|---|
| S1 (helper captures and types on the lock screen, UAC; four window operations) | any item impossible → **stop and ask the user** whether the system service is still worth it | whole plan |
| S1 latency | nothing: this plan uses a shared section for pixels whatever the numbers say (one design, not two) | Task 4 |
| S2 (login screen before anyone logs in; other user at the console) | login screen cannot be captured → **stop and ask the user**. The recipe's way of telling the owner's session apart replaces the one in Task 2 if it differs | Tasks 2, 7 |
| S3 (Remote Desktop: reattach, where the SAS lands) | reattach gives no picture on a machine without a display → `reattach` answers `no display` and the controller shows that reason. SAS cannot land in a Remote Desktop session → Task 6's refusal text | Task 6 |

## Decisions made in this plan (the spec leaves them to the implementer, §19.1)

1. **Claim window.** `claim-owner` is served only while no owner is recorded **and** within 10 minutes of `rapp-svc install` (value `ClaimUntil`); the first claim from an interactive login session wins. Afterwards the owner changes only by reinstalling. Silent installs write the owner directly (`/OWNER`), no window.
2. **Helper pixels travel in a shared section**, everything else on the pipe; the helper writes the next frame only after the previous one was acknowledged.
3. **Lock after reattach is done by the requester**, verified by `rapp-svc`: if the session is not locked 2 s after reattaching, `rapp-svc` disconnects it again and answers an error. `rapp-svc` starts no extra program for it.
4. **“Another user is at the console”** reaches the prelogin instance as a start argument (`--occupied`): `rapp-svc` restarts the instance when that changes.
5. **The Ctrl+Alt+Del menu is not greyed in advance** (the protocol carries no such state): when the SAS cannot be sent, the host answers `inputBlocked` with `by = "sas"` and the controller shows one fixed sentence. The user agreed to this on 2026-11-26 and spec §7.5 now says the same.
6. `rapp-host` learns the mode by asking the system pipe for `status`, not from an argument or the environment.

## Global Constraints

- Phases C and D are merged: `rust/svc-windows` has `proto.rs`, `client.rs`, `backoff.rs`, `layout.rs`, `supervise.rs`, `pipe.rs`, `user.rs`, `ctl.rs` (plan C Task 7); `rust/host-windows` has local capture, input, lock and window code (plan D).
- **Boundary 3:** creating a process in another login session or with another identity happens only in `rust/svc-windows/src/elevate.rs`. Searching `rust/` for `CreateProcessAsUserW`, `WTSQueryUserToken`, `SetTokenInformation`, `DuplicateTokenEx`, `LogonUser` finds only that file.
- **SYSTEM code is only:** `rapp-svc`, `rapp-host secure-helper`, `rapp-service --prelogin` and the `rapp-host` it asks for.
- **Nothing in a request is trusted.** Identity, login session and process come from the pipe's peer. Requests carry no user, SID, session number or program path. Programs are started only from `rapp-svc`'s own version directory by full path: `rapp-host.exe`, `rapp-service.exe`, `rapp-svc.exe`.
- Passwords exist only in memory on the path controller → protocol → `rapp-host` → helper pipe → `SendInput`. Never a command line, environment variable, file or log line. Input events are logged without content.
- Every pipe request is logged in one line: peer SID, login session, request kind, result (spec §13.3). Logs of SYSTEM processes go to `%ProgramData%\rapp\logs\` through `rapp_net::log`.
- `rust/svc-windows` stays small: no HTTP, no JSON beyond the pipe and settings, no dependency added without a line in the merge message (audit §18.2 #10).
- Branch `feat/windows-service`. Tests that need SYSTEM run through `scripts/test-windows-system.ps1` (Task 2) on a test machine or VM, never on a person's daily machine without telling them: it registers and removes a service and changes the SAS policy, and restores both.

## Review Focus

1. **A process of another local user connects to `\\.\pipe\rapp-svc`, and a process of the owner asks `spawn-host`:** both refused, both logged; no process started. → Tasks 1, 7.
2. **The owner's `rapp-host` asks for a helper with a pipe name it does not own (another session's, another pid's, or `\\.\pipe\something-else`):** refused. → Task 3.
3. **Another user is logged in at the console and the owner connects:** not one frame of that user's desktop leaves the machine; that user is not locked out or disconnected; the controller reads “other user”. → Tasks 2, 6, 7.
4. **The helper or `rapp-svc` dies in the middle of an unlock:** the password is not replayed, not logged; the host reports locked again; the next attempt works. → Task 5.
5. **The owner's data root is changed to point at another program or an unreadable place before a reboot:** the prelogin instance starts nothing from it and writes nothing into it; it reports why it cannot serve. → Task 7.

## File map

```
rust/svc-windows/src/
  main.rs        + `service` dispatch; `claim-owner` command
  settings.rs    HKLM\Software\rapp: Owner, Mode, ClaimUntil, SasPolicyBefore, UpdateUrl   (pure model + windows registry I/O)
  peer.rs        (windows) who is at the other end of a pipe: SID, login session, pid, image path
  sessions.rs    pure: facts about login sessions → what should run; (windows) reading the facts
  elevate.rs     (windows) THE place that starts processes as the owner or as SYSTEM in a session
  service.rs     (windows) service entry, control handler, the main loop
  favours.rs     (windows) helper, spawn-host, sas, reattach — each one function, checks first
  guard.rs       (windows) install-directory permissions: check and repair
rust/host-windows/src/
  helper/proto.rs    pure: messages of the helper pipe, frame header
  helper/server.rs   (windows) `secure-helper`: pipe shell around local capture/input/window ops
  helper/client.rs   (windows) the worker's side: start, trust checks, send, receive frames
  win/svc.rs         (windows) asks rapp-svc: status, helper, sas, reattach
  win/capture.rs, win/input.rs, win/windows.rs, win/lock.rs   + “via helper” arms
rust/service/src/
  prelogin.rs    what `--prelogin` turns off; the read-only config view
  workers.rs     prelogin: the worker comes from `spawn-host`
scripts/test-windows-system.ps1    registers a test service, runs the SYSTEM tests, restores
```

## Component choices

| Need | Component | Notes |
|---|---|---|
| Service plumbing | `StartServiceCtrlDispatcherW`, `RegisterServiceCtrlHandlerExW`, `SetServiceStatus`; accepts `STOP`, `SHUTDOWN`, `SESSIONCHANGE` | service name `rapp`, own process, start type automatic |
| Login sessions | `WTSEnumerateSessionsW`, `WTSQuerySessionInformationW` (`WTSConnectState`, `WTSClientProtocolType`), `WTSGetActiveConsoleSessionId`; the session's user = SID of `WTSQueryUserToken(session)`'s `TokenUser` | names are never compared, only SIDs |
| Start as the owner | `WTSQueryUserToken` → `DuplicateTokenEx(TokenPrimary)` → `CreateEnvironmentBlock` → `CreateProcessAsUserW`, desktop `winsta0\default`, `CREATE_UNICODE_ENVIRONMENT \| CREATE_NO_WINDOW \| CREATE_SUSPENDED`, handles limited by `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`; assign to the job, then resume | the token is the user's normal (not elevated) one |
| Start as SYSTEM in a session | own token → `DuplicateTokenEx` → `SetTokenInformation(TokenSessionId)` → `CreateProcessAsUserW`, desktop `winsta0\default`; the child follows the input desktop itself | S1's recipe |
| Peer of a pipe | `GetNamedPipeClientProcessId`, `GetNamedPipeClientSessionId`, `ImpersonateNamedPipeClient` + `OpenThreadToken` + `RevertToSelf` for the SID, `QueryFullProcessImageNameW` | clients connect with `SECURITY_SQOS_PRESENT \| SECURITY_IDENTIFICATION` |
| Pipe security | explicit DACL through `SetSecurityDescriptorDacl`: system pipe = SYSTEM + owner (+ interactive users while the claim window is open); `PIPE_REJECT_REMOTE_CLIENTS`; `FILE_FLAG_FIRST_PIPE_INSTANCE` | a second process cannot take the name |
| Following the input desktop | `OpenInputDesktop` + `SetThreadDesktop` on the capture and input threads, redone when a call fails with access denied or the duplication reports access lost | S1 |
| Helper pixels | section from `CreateFileMappingW` (page file backed) created by the helper, handle duplicated read-only into the worker with `DuplicateHandle`; one section per display, resized on mode change | decision 2 |
| Secure attention | `SendSAS(FALSE)` from `%SystemRoot%\System32\sas.dll` (loaded by full path), called in `rapp-svc`; needs policy `SoftwareSASGeneration` ≥ 1 (set by install, phase G; by the test script here) | S1, S3 |
| Reattach | `WTSConnectSessionW(session, console session, "", TRUE)` | S3 |
| Install directory check | `GetNamedSecurityInfoW` / `SetNamedSecurityInfoW`: owner Administrators; write access only for SYSTEM, Administrators, TrustedInstaller; inheritance on for children | §5.1 |

---

### Task 1: Owner, settings, and who is asking

**Files:** Create `rust/svc-windows/src/settings.rs`, `peer.rs`; modify `pipe.rs`, `main.rs`; tests in `rust/svc-windows/tests/`.

**Interfaces — Produces:**

```rust
// settings.rs
pub struct Settings { pub owner: Option<String> /* SID */, pub mode: Option<Mode>, pub claim_until: Option<u64> /* unix s */,
                      pub sas_policy_before: Option<Option<u32>> /* Some(None) = value did not exist */, pub update_url: Option<String> }
pub trait Store { fn load(&self) -> Settings; fn save(&self, s: &Settings) -> std::io::Result<()>; }
pub struct Registry;                 // (windows) HKLM\Software\rapp, 64-bit view; key writable by SYSTEM and Administrators only
pub struct MemoryStore(/* tests */);
pub fn valid_sid(s: &str) -> bool;   // S-1-…, digits and dashes only, ≤ 184 chars
/// May this claim be accepted now?
pub fn may_claim(s: &Settings, now: u64, peer_interactive: bool) -> Result<(), &'static str>;   // "owner already set" | "no claim window" | "not interactive"

// peer.rs (windows)
pub struct Peer { pub sid: String, pub session: u32, pub pid: u32, pub image: PathBuf, pub is_system: bool, pub interactive: bool }
pub fn peer_of(pipe: HANDLE) -> std::io::Result<Peer>;
// pipe.rs
pub enum Access { OwnerAndSystem(String /* owner SID */), SystemAndInteractive /* claim window */, SystemOnly, User(String) }
pub fn serve(name: &str, access: Access, handle: impl Fn(&Peer, Request) -> Response + Send + Sync + 'static) -> std::io::Result<Server>;
```

The handler receives `Peer`, never fields from the message. `claim-owner` (the command `rapp-svc claim-owner`) sends `Request::ClaimOwner`; the service records `peer.sid` if `may_claim`, then **reopens the pipe** with `OwnerAndSystem`. While no owner is recorded and the window is closed the pipe is `SystemOnly`.

- [ ] **Step 1: Tests (portable).** `may_claim_table` (owner set → refused; window passed → refused; not interactive → refused; inside the window → ok); `valid_sid_table` (`S-1-5-21-1-2-3-1001` ok; `S-1-5-21-…;rm`, empty, 200 chars refused); `settings_round_trip` through `MemoryStore`.
- [ ] **Step 2: Tests (Windows, ordinary user).** `peer_reports_my_sid_session_and_image` (a pipe served and connected inside the test); `user_pipe_dacl_has_exactly_user_and_system`; `first_instance_flag_refuses_a_second_server`; `remote_clients_are_rejected_by_flag` (assert the flag on the handle state).
- [ ] **Step 3: Tests (SYSTEM, via Task 2's script; listed here, run there).** `another_user_cannot_connect` (the script creates a temporary local user, runs a client as it: access denied) — Review Focus 1; `claim_records_the_peer_not_the_message` (send a hand-written line `{"op":"claim-owner","sid":"S-1-5-18"}`: the recorded owner is the caller); `second_claim_is_refused`.
- [ ] **Step 4:** Implement. **Step 5:** Commit `feat(svc-windows): settings, pipe peer identity, claim-owner`.

### Task 2: The service: follow login sessions, start `rapp-service` as the owner

**Files:** Create `rust/svc-windows/src/sessions.rs`, `elevate.rs`, `service.rs`, `guard.rs`, `scripts/test-windows-system.ps1`; modify `supervise.rs`, `main.rs`.

**Interfaces — Produces:**

```rust
// sessions.rs (pure part)
#[derive(Clone, Debug, PartialEq)]
pub struct SessionFact { pub id: u32, pub user: Option<String> /* SID; None = nobody logged in */, pub connected: bool /* Active or Connected */, pub console: bool, pub remote: bool }
#[derive(Clone, Debug, PartialEq)]
pub enum Want { Idle /* no owner yet */, Owner { session: u32 }, Prelogin { occupied: bool } }
pub fn want(owner: Option<&str>, sessions: &[SessionFact]) -> Want;
/// Is somebody other than the owner logged in at the console? (Remote Desktop logins of others do not count.)
pub fn other_user_at_console(owner: &str, sessions: &[SessionFact]) -> bool;
// (windows) pub fn read() -> Vec<SessionFact>;

// elevate.rs (windows) — the only file allowed to do this
pub struct Started { pub pid: u32, pub process: OwnedHandle, pub stdin: Option<OwnedHandle>, pub stdout: Option<OwnedHandle>, pub stderr: Option<OwnedHandle> }
pub enum Stdio { None, StdinOnly, All }
pub fn start_as_user(session: u32, expect_sid: &str, exe: &Path, args: &[String], stdio: Stdio) -> std::io::Result<Started>;   // fails if the session's user is not expect_sid
pub fn start_as_system(session: u32, exe: &Path, args: &[String], env: &[(String, String)], stdio: Stdio) -> std::io::Result<Started>;
/// Both refuse an exe that is not `layout::sibling(current_exe, name)` for name in {rapp-host, rapp-service, rapp-svc}.

// supervise.rs
pub trait Launcher: Send + Sync { fn launch(&self) -> std::io::Result<Started>; }   // user mode: plain child (plan C); system mode: through elevate
```

**`want` rules** (spec §7.2): no owner → `Idle`. The owner has a login session (in any state) → `Owner { session }`; with several, prefer the console one, then a connected one, then the lowest id. Otherwise → `Prelogin { occupied: other_user_at_console }`.

**Main loop.** At start and on every `SESSIONCHANGE` (logon, logoff, console connect/disconnect, remote connect/disconnect): `read()` → `want()`; when it differs from what runs, stop the current instance (close stdin, 5 s, then the job) and start the wanted one: `Owner` → `rapp-service.exe --supervised --resident system` as the owner in that session; `Prelogin` → Task 7. Supervision (backoff, clean exit → at once), `status`/`start`/`stop`/`restart` as in plan C, now for owner or SYSTEM peers. `SERVICE_CONTROL_STOP`/`SHUTDOWN`: stop the instance, the helpers, answer stopped within 20 s. At every start `guard::align(install_dir)`: check and repair the permissions, one log line if anything was changed.

`scripts/test-windows-system.ps1`: must run elevated; builds; registers a service `rapp-test` running the test build from a scratch version directory under `%ProgramFiles%\rapp-test\`; saves and sets the SAS policy; creates a temporary standard user; runs the `--ignored` tests named in this plan through a small SYSTEM runner (`rapp-svc ctl` plus test binaries started by the test service); always restores (service removed, policy back, user deleted, directory deleted) in a `finally`.

- [ ] **Step 1: Tests (portable), `want_table`:** no owner → `Idle`; owner at the console → `Owner`; owner only in a disconnected session, nobody at the console → `Owner` (that session); owner disconnected and another user at the console → `Owner` (and `other_user_at_console` true); nobody logged in → `Prelogin{occupied:false}`; another user at the console, owner absent → `Prelogin{occupied:true}`; another user only over Remote Desktop → `Prelogin{occupied:false}`; owner in two sessions → the console one.
- [ ] **Step 2: Tests (SYSTEM).** `owner_logon_starts_rapp_service_as_owner_in_their_session` (the child's token user and session are read back; it is not elevated); `logoff_stops_it`; `crash_is_restarted_with_backoff`; `stop_request_from_owner_works_and_from_other_user_is_refused`; `start_refuses_a_path_outside_the_version_directory` (unit test of the check in `elevate`); `guard_repairs_a_loosened_install_directory` (grant Users write on the scratch directory, restart the test service: the grant is gone and one log line says so).
- [ ] **Step 3:** Implement. `unsafe` in `svc-windows` stays inside `peer.rs`, `pipe.rs`, `elevate.rs`, `service.rs`, `supervise.rs`, `guard.rs`, `settings.rs` (registry), `favours.rs`.
- [ ] **Step 4:** Commit `feat(svc-windows): the service follows login sessions`.

### Task 3: `helper` — starting the secure-desktop helper

**Files:** Create `rust/svc-windows/src/favours.rs`; `rust/host-windows/src/win/svc.rs`, `helper/client.rs` (start and trust part).

**Interfaces — Produces:**

```rust
// favours.rs
pub fn helper_pipe_ok(name: &str, peer_session: u32, peer_pid: u32) -> bool;   // pure; exact form below
pub fn helper(peer: &Peer, owner: &str, pipe: &str) -> Response;
// host-windows win/svc.rs
pub enum Resident { System, User, None }
pub fn resident() -> Resident;      // asks \\.\pipe\rapp-svc for status; trusted only if the server process is SYSTEM and its image is a `rapp-svc.exe`; cached for the worker's life
pub fn ask(req: &Request) -> Result<Response, ClientError>;
```

Helper pipe name, exactly: `\\.\pipe\rapp-helper.<session>.<pid>.<32 lowercase hex>` with the requester's own session and pid. `helper()` checks, in this order, and refuses on the first failure: peer SID is the owner; peer image is `sibling("rapp-host")`; `helper_pipe_ok`; then ends any helper it started earlier for that login session and starts `rapp-host.exe secure-helper --pipe <name>` with `start_as_system(peer.session, …, Stdio::None)` in a kill-on-close job. The helper is not restarted by `rapp-svc`; the worker asks again.

Worker side (`helper/client.rs`): create the pipe first (DACL: SYSTEM and the own user; first instance; reject remote), then ask; after the helper connects, verify the client process is SYSTEM and its image is the sibling `rapp-host.exe`; otherwise close and treat the helper as unavailable.

- [ ] **Step 1: Tests (portable).** `helper_pipe_name_table`: right form ok; wrong session, wrong pid, 31 hex, upper-case hex, another prefix, a path with `..` or `/` → refused (Review Focus 2).
- [ ] **Step 2: Tests (SYSTEM).** `helper_starts_as_system_in_the_requesters_session`; `helper_request_from_a_non_owner_is_refused`; `helper_request_from_another_program_of_the_owner_is_refused` (the test binary is not `rapp-host.exe`); `second_request_replaces_the_first_helper`; `secure_helper_run_by_an_ordinary_user_exits_2`.
- [ ] **Step 3:** Implement. **Step 4:** Commit `feat(svc-windows): helper favour; host asks for it`.

### Task 4: The helper itself

**Files:** Create `rust/host-windows/src/helper/proto.rs`, `helper/server.rs`; finish `helper/client.rs`; `rust/host-windows/src/main.rs` (`secure-helper` sub-command).

**Interfaces — Produces** (`proto.rs`, pure; tested on the Mac):

```rust
pub const HELPER_V: u32 = 1;
/// Wire: [kind u8][len u32 LE][payload]. Payload is JSON for every kind (≤ 64 KiB; longer → close).
#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ToHelper {
    Hello { v: u32 },
    Capture { display: u32, on: bool },
    Ack { display: u32, seq: u64 },
    Mouse { kind: u8, x: f64, y: f64, button: u8, flags: u64, clicks: u8 },
    Scroll { x: f64, y: f64, dx: f64, dy: f64, flags: u64 },
    Key { code: u16, down: bool, flags: u64 },
    Text { units: Vec<u16> },
    Release { keys: Vec<u16>, buttons: Vec<u8> },
    Wake,
    Window { hwnd: u64, op: WindowOp },
}
#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum WindowOp { Raise, Move { x: i32, y: i32 }, Resize { w: i32, h: i32 }, Close }
#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum FromHelper {
    Ready { v: u32, desktop: String },
    Desktop { name: String },                      // "Default", "Winlogon", "Screen-saver", …
    Surface { display: u32, handle: u64, bytes: u64, width: u32, height: u32, stride: u32 },   // handle valid in the worker
    Frame { display: u32, seq: u64, dirty: Vec<[u32; 4]> },    // pixels are in the surface
    Gone { display: u32 },
    Error { text: String },
}
pub fn encode<T: Serialize>(kind: u8, msg: &T) -> Vec<u8>;
pub fn decode_head(buf: &[u8]) -> Option<(u8, usize)>;
```

The field meanings of `Mouse`, `Scroll`, `Key` are those of `host-core`'s `InputOps` (plan B Task 13): `ToHelper` is that trait, serialised. `Text` in the log is its length only.

**`server.rs`** = pipe shell around **the same** `win::dda::ScreenSource`, `win::input`, `win::windows` functions the worker uses locally (no second capture or input code): connect to `--pipe`; verify the server process is in the own login session and is the sibling `rapp-host.exe`; require SYSTEM (else exit 2); follow the input desktop; `Capture on` → create the surface, send `Surface`, then for each new frame copy the dirty rectangles into the surface and send `Frame`, and **do not touch the surface again until `Ack`**; input kinds call the local input functions; `Window` calls the four local functions and nothing else. Pipe closed → exit 0. The helper opens no file except its log, no socket, starts no process, ends no process.

- [ ] **Step 1: Tests (portable).** `proto_round_trip` (every variant); `oversized_payload_is_refused`; `unknown_kind_closes`; `text_debug_output_has_no_content` (the `Debug` used for logging prints `Text { units: <5> }`).
- [ ] **Step 2: Tests (Windows, ordinary user — the shell is testable without SYSTEM by passing a hidden test flag that skips the SYSTEM check in **test builds only** (`cfg(test)`/feature `helper-test`, not compiled into release).** `frames_arrive_and_wait_for_ack` (no second `Frame` for a display before the `Ack`); `a_dirty_rectangle_changes_only_those_pixels`; `input_reaches_fake_app` (plan D's `fake-app` echo mode); `window_ops_move_and_close_fake_app`; `closing_the_pipe_ends_the_helper`.
- [ ] **Step 3: Tests (SYSTEM, interactive test machine).** `lock_screen_frame_is_not_black` (lock, capture one frame through the helper: more than two distinct colours); `uac_prompt_is_visible_and_clickable` (S1 steps kept as a regression test, run by hand through the script when capture or input code changes).
- [ ] **Step 4:** Implement. **Step 5:** Commit `feat(host-windows): secure-desktop helper`.

### Task 5: The worker in system mode

**Files:** Modify `rust/host-windows/src/win/{capture,input,windows,lock,platform}.rs`.

**Behaviour** (when `svc::resident() == System`; in every other case plan D's behaviour stays):

- **Input:** every `InputOps` call goes to the helper. Helper unavailable → ask once more; still unavailable → local input (plan D), and `blocked_by` reports `elevated` as in user mode. With the helper, `blocked_by` never reports `elevated`.
- **Windows:** `raise`/`move_to`/`resize`/`close` on a window of an elevated process go to the helper; others stay local. Reading controls of elevated windows stays impossible (`TextReader` returns nothing).
- **Picture:** local capture while the input desktop is `Default`. On `Desktop { name ≠ Default }`: desktop targets switch to the helper's frames (`Capture on` for the displays in use; `off` when back); app targets freeze (plan D) and report `screenLocked(true)` when the session is locked, else `covered` / `consent.exe`, at most once per 5 s.
- **Lock:** `can_unlock()` → true while the helper is connected. `wake()` → `ToHelper::Wake`; on Windows Server (the lock screen asks for Ctrl+Alt+Del first — S1's recipe says how to tell) `svc::ask(Sas)` first and wait up to 3 s for the helper's frame to change. `type_units` → `Text`; `press_return` → `Key`. The password buffer is zeroed after sending. If the helper pipe breaks between `type_units` and the lock check, report “still locked” to `host-core` (which answers the controller as for a wrong password) — nothing is retried by the platform.

- [ ] **Step 1: Tests (Windows, helper in test mode, fake helper where noted).** `input_goes_through_the_helper_in_system_mode` (a fake helper records `ToHelper`); `falls_back_to_local_input_when_the_helper_is_gone`; `desktop_target_switches_to_helper_frames_and_back` (the fake helper sends `Desktop{Winlogon}`, frames, `Desktop{Default}`); `app_target_freezes_and_reports_once_per_5_s`; `helper_dying_mid_unlock_reports_locked_and_logs_no_text` (Review Focus 4: scan the log directory for the test password).
- [ ] **Step 2: By hand from a Mac controller (results into `tasks/todo.md`):** unlock 10 × on Windows 11 and on Server 2022; wrong password; UAC prompt in a desktop session (see it, click 是); UAC during an app session (the cover text); an administrator PowerShell window as app target: type, move, resize, close.
- [ ] **Step 3:** Commit `feat(host-windows): system mode — input, secure desktop, unlock through the helper`.

### Task 6: Ctrl+Alt+Del and reattach

**Files:** Modify `rust/svc-windows/src/favours.rs`; `rust/host-windows/src/win/{input,platform}.rs`; `gui/lib/` hint text (shared Dart, one string) + test.

**Interfaces — Produces:**

```rust
pub fn sas(peer: &Peer, owner: &str, sessions: &[SessionFact], policy: Option<u32>) -> Response;
pub fn reattach(peer: &Peer, owner: &str, sessions: &[SessionFact]) -> Response;
```

`sas`: peer is the owner or the prelogin instance `rapp-svc` started; policy value is 1 or 3, else `error: "sas policy off"`; the peer's session is the console session (or S3 showed it lands elsewhere), else `error: "sas not in this session"`; then `SendSAS(FALSE)`. The worker maps any error to `inputBlocked` with `by = "sas"`; controller text: `这台电脑现在收不到 Ctrl+Alt+Del`.

`reattach`: peer is the owner; peer's session is disconnected; `other_user_at_console` → `error: "other user"` (never reattach); console session has nobody → connect the peer's session to the console; poll up to 2 s for the session to be locked (`WTSSessionInfoEx`), not locked → `WTSDisconnectSession` it and `error: "lock failed"`. The worker's order on `OpenError::SessionDisconnected` in system mode: ask `reattach` → on ok call `LockWorkStation` **before anything else** → open; on `other user` → `OpenError::OtherUser`.

- [ ] **Step 1: Tests (portable — the decisions are pure functions over `Peer`-like facts; give them a small `Facts` struct).** `sas_table` (policy off; non-owner; owner in a remote session; ok); `reattach_table` (other user at console → `other user`; session not disconnected → error; ok path).
- [ ] **Step 2: Tests (SYSTEM, by hand through the script, two accounts and an RDP client needed):** owner connects by Remote Desktop, disconnects; a Mac controller opens the desktop: the picture arrives **locked**; unlock works. Same with another user logged in at the console: the controller reads the other-user sentence, that user's screen does not change (Review Focus 3). Ctrl+Alt+Del from the menu on Windows 11 and Server 2022.
- [ ] **Step 3:** Commit `feat(svc-windows): secure attention and reattach`.

### Task 7: Before login

**Files:** Create `rust/service/src/prelogin.rs`; modify `rust/service/src/{main,workers,config}.rs`; `rust/svc-windows/src/{service,favours}.rs`.

**Interfaces — Produces:**

```rust
// favours.rs
pub fn spawn_host(peer: &Peer, prelogin_pid: Option<u32>, occupied: bool, args: &[String]) -> Response;   // → Response.spawned
// rust/service/src/prelogin.rs
pub struct Prelogin { pub occupied: bool }
pub fn allowed_config(full: &Config) -> Config;      // keeps relay, device identity, known devices; clears everything naming a program, a path to run, a hook, update_url
pub const REASON_OCCUPIED: &str = "other user";
```

**`rapp-svc`:** for `Want::Prelogin` start `rapp-service.exe --supervised --resident system --prelogin` (+ `--occupied`) with `start_as_system(0, …)`. Environment built by `rapp-svc`, not inherited from anyone: the system block plus `USERPROFILE` and `APPDATA` of the owner (from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<owner SID>\ProfileImagePath`), `LOCALAPPDATA=%ProgramData%\rapp\prelogin`, `RAPP_LOG_DIR=%ProgramData%\rapp\logs`. Profile missing (the owner never logged in) → do not start; `status` says `prelogin: false`.

`spawn_host`: refuse unless `peer.is_system` **and** `peer.pid == prelogin_pid` **and** not `occupied` (→ `error: "other user"`) **and** `args[0] != "secure-helper"`; start `rapp-host.exe <args>` with `start_as_system(console session, …, Stdio::All)`, duplicate the process handle and the three pipe ends into the requester (`DuplicateHandle` into `peer.pid`), answer `spawned`. At most 4 live at once.

**`rapp-service --prelogin`:** uses `allowed_config`; opens every file read-only; no local IPC listener, no data sync, no autolock, no `--cm`, no outbox, no terminal, no ports, no update check of its own (phase G gives that to `rapp-svc`); capabilities as plan D Task 11; `--occupied` → `screen_recording: false`, `error: "other user"`, all capabilities off, sessions refused with that reason. Workers come from `svc_client` `spawn-host`; the returned handles are wrapped as the worker's stdin/stdout/stderr and process; stop = close stdin, then `TerminateProcess` on the handle after 2 s. Programs are found only beside its own exe (`RAPP_BIN_DIR` and config are ignored).

- [ ] **Step 1: Tests (portable).** `allowed_config_drops_everything_runnable` (a config with every optional field set: the result keeps exactly the listed fields — the test enumerates the struct's fields so a field added later fails the test until someone decides); `prelogin_capabilities` and `occupied_answers_other_user` (service level, with `fake-rapp-host`); `prelogin_writes_nothing` (run a prelogin instance with a fake `spawn-host` against a copy of a data root; every file's bytes and modification time are unchanged, no file added) — Review Focus 5; `prelogin_ignores_bin_dir_and_config_paths`.
- [ ] **Step 2: Tests (SYSTEM).** `spawn_host_from_the_owner_is_refused` (Review Focus 1); `spawn_host_from_a_system_process_that_is_not_the_instance_is_refused`; `spawned_host_is_system_in_the_console_session_and_its_stdout_reaches_the_requester`; `occupied_refuses_spawn`.
- [ ] **Step 3: By hand (S2's list as acceptance):** cold boot, hands off: the device shows on a Mac controller with `未登录，只能打开桌面`; open the desktop, see the login screen, (Server: Ctrl+Alt+Del), type the password, log in; within 10 s the device is the normal instance and the desktop opens again. Auto-logon machine. Another user at the console in both cases of S2 Step 3. Data root moved to another drive (works) and to a network drive (the reason is shown).
- [ ] **Step 4:** Commit `feat(svc-windows): prelogin instance and spawn-host`.

### Task 8: Audit, acceptance, merge

- [ ] **Step 1: The §18.2 audit, by someone who did not write this phase.** Give them spec §7, §18.2 and the diff. For each of the eleven rows they write: holds / does not hold, the file and line that shows it. Rows 4, 5, 7 point at the tests above. Row 10: record `rust/svc-windows/` line count in `tasks/todo.md`. Row 11 belongs to phases G and H — note it as open. Every “does not hold” is fixed before merging.
- [ ] **Step 2: Boundary checks as tests** (in the workspace, run on the Mac): `only_elevate_rs_starts_processes_across_sessions` (source scan for the five API names of “Global Constraints”); `helper_server_has_no_file_network_or_process_calls` (source scan of `helper/server.rs` for `std::fs`, `std::net`, `tokio::net`, `Command`, `CreateProcess`, `TerminateProcess`); `requests_carry_no_identity` (the `Request` JSON of every variant has no key named `sid`, `user`, `session`, `path`, `exe`).
- [ ] **Step 3: Log check (audit §18.4 #3).** After Task 5–7's by-hand runs, search `%ProgramData%\rapp\logs\` and `%LOCALAPPDATA%\rapp\logs\` for the test password and the typed text: nothing.
- [ ] **Step 4: Acceptance:** the rows of spec §15.3 and §15.5 that phase D marked “needs the system service” (unlock, autolock, lock screen, login screen, UAC, administrator windows, Ctrl+Alt+Del, Remote Desktop) into `tasks/todo.md` under `## Windows 版 F 段（系统服务）`.
- [ ] **Step 5:** `git merge main`; Mac gate and Windows gate green; SYSTEM tests green on the test machine; merge to local `main`: `merge: Windows 系统服务（feat/windows-service）`.

## Done when

From a cold boot with nobody at the machine, a Mac controller logs in, works, locks, unlocks and handles a UAC prompt; the §18.2 audit has no open row except #11; another user at the console is never shown and never disturbed.
