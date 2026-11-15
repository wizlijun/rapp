# 远程 app 全部关闭后自动锁屏 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A locks itself 10 s after the last app/desktop session from any B ends (switch in A's 「本机」, default on); when B opens an app on a locked A it types the remembered password once per device or asks for it, and the app's picture comes up after the unlock.

**Architecture:** `rapp-service` gets an `autolock` task that watches `State.changed`, counts the sessions that can see A's screen, and on 1→0 arms a grace timer that runs the new `rapp-host lock` subcommand. `rapp-host serve` learns to start an app session while A is locked (send `ready` first, wait for the unlock, then find the window) and serialises password typing across processes with `flock`. On B, `MainState` triggers unlock from the first `screenLocked(true)` of any app or desktop session, with one unlock in flight per device and a per-device manual-lock flag; ops 34/35 and protocol v11 are unchanged.

**Tech Stack:** Swift (RappCore, rapp-host, XCTest), Rust (rapp-service, testkit integration tests with the fake rapp-host), Flutter/Dart (gui/, flutter_test, fake_async).

**Spec:** `docs/superpowers/specs/2026-11-15-rapp-auto-lock-design.md`

## Global Constraints

- No protocol bump: no new op codes, `PROTOCOL_VERSION` stays 11.
- Counted session (A side): `side == false` and app does not start with `term:`. Every desktop screen counts.
- Grace: 10 s (`autolock::GRACE`), from the 1→0 transition; a new counted session cancels it; at the deadline lock only if still 0, the switch is on, and A is not already locked. No lock at service start.
- Config key `auto_lock` in `service.json`, absent = on (`unwrap_or(true)`). IPC `{"cmd":"set_auto_lock","on":bool}`; `status` carries `"auto_lock": bool`. B cannot change it (no peer op).
- Log events (and 访问记录): `auto_lock` → `远程 app 都已关闭，已自动锁屏`; `auto_lock_failed` with `error` → `自动锁屏失败：<error>` (warn colour).
- 本机 switch label `远程 app 都关闭后自动锁屏`, grey note `锁屏后，B 打开 app 时需要输入这台 Mac 的登录密码。`; macOS only.
- B copy: banner `远程电脑已锁屏；输入系统密码解锁` with button `输入系统密码` for every live locked session; no session to unlock through: `请先打开这台电脑上的 app 或桌面`; failure: `密码可能不对` after 5 s.
- Linux B: in-memory store; checkbox `本次运行期间记住密码` (macOS keeps `记住密码`); `连上时自动输入` on both.
- Passwords never appear in logs, hints, or test failure output; existing 1024-byte limit stays.
- Swift: `swift build` / `swift test` at repo root. Rust: from `rust/`, `TERM=xterm-256color cargo test`. Flutter: `~/development/flutter/bin/flutter test` from `gui/`, then `git checkout pubspec.lock`.
- Git in this worktree: one plain git command per call (no `-C`, `&&`, `;`, pipes). Never push. Commit messages English, ending with the `Co-Authored-By` line.
- Never run `rapp-host lock` or lock this Mac from a task: every real lock is a user step.

## Review Focus

1. B reconnects, takes over, or closes one app and opens another within 10 s → A does not lock (Task 2 `reopen_within_grace_does_not_lock`).
2. Three apps opened at once on a locked A → exactly one password typed, at most one dialog (Task 5 `one unlock per device across sessions`).
3. The person at A presses ⌃⌘Q mid-session, then B's network blips and it reconnects → B shows the banner only (Task 5 `manual lock survives reconnect`).
4. The remembered password is wrong → one attempt, auto-input turned off, password kept, dialog asked again; reopening apps never retries it (Task 5 `auto failure turns auto off and asks once`).
5. `SACLockScreenImmediate` is missing or does nothing on some macOS → a `自动锁屏失败：…` row in 访问记录, never silence (Task 2 `lock_failure_is_recorded`, Task 3 history row).

---

### Task 0: Real-machine gate (user runs it)

**Files:** Modify: spec §9 (record results).

- [ ] **Step 1: Ask the user to run, on the current build with a real A (macOS 14/15) and B:**
  1. On A press ⌃⌘Q. On B open 桌面, click `输入系统密码` on the banner, type A's password. Does A unlock?
  2. With A locked again, open any app from B. Does B get an error, or a picture after unlocking via 桌面?
  3. After the unlock in 1, does an already open app session's picture come back by itself?
- [ ] **Step 2: Write the answers into spec §9 with the date.** If 1 fails: stop, report to the user, do not start Task 1. (2 only informs: Task 4 is done either way, see Task 4 note.)
- [ ] **Step 3: Commit** `docs(spec): auto-lock real-machine gate results`.

---

### Task 1: `rapp-host lock`

**Files:**
- Modify: `Sources/RappCore/WorkerCLI.swift` (add `case lock(json: Bool)` to `HostCommand`; parse `"lock"` like `"version"`)
- Create: `Sources/RappCore/ScreenLock.swift`
- Create: `Sources/rapp-host/ScreenLocker.swift`
- Modify: `Sources/rapp-host/main.swift` (new `case .lock`)
- Test: `Tests/RappCoreTests/WorkerCLITests.swift`, `Tests/RappCoreTests/ScreenLockTests.swift`

**Interfaces:**
- Produces: CLI `rapp-host lock --json` prints one JSON line and exits: `{"ok":true}` (locked now, exit 0), `{"ok":true,"already":true}` (was locked, exit 0, nothing called), `{"ok":false,"error":"<text>"}` (exit non-zero). Task 2 relies on exactly these three shapes.
- Produces (RappCore): `public enum LockOutcome: Equatable { case locked, already, failed(String) }` and `public func lockScreen(isLocked: () -> Bool, call: () -> String?, sleep: (TimeInterval) -> Void, timeout: TimeInterval = 2, step: TimeInterval = 0.1) -> LockOutcome` — `call` returns nil on success or the reason it could not call.

- [ ] **Step 1: Write the failing tests**

```swift
// WorkerCLITests
XCTAssertEqual(try parseHostArguments(["lock", "--json"]), .lock(json: true))
XCTAssertEqual(try parseHostArguments(["lock"]), .lock(json: false))
XCTAssertThrowsError(try parseHostArguments(["lock", "extra"]))

// ScreenLockTests
func testAlreadyLockedCallsNothing() {
    var calls = 0
    XCTAssertEqual(lockScreen(isLocked: { true }, call: { calls += 1; return nil }, sleep: { _ in }), .already)
    XCTAssertEqual(calls, 0)
}
func testLockedOnceStateFlips() {
    var n = 0
    XCTAssertEqual(lockScreen(isLocked: { n += 1; return n > 3 }, call: { nil }, sleep: { _ in }), .locked)
}
func testNeverLockedFailsAfterTimeout() {
    var slept = 0.0
    let r = lockScreen(isLocked: { false }, call: { nil }, sleep: { slept += $0 })
    XCTAssertEqual(r, .failed("调用后 2 秒内没有锁上"))
    XCTAssertGreaterThanOrEqual(slept, 2)
}
func testMissingSymbolFails() {
    XCTAssertEqual(lockScreen(isLocked: { false }, call: { "找不到 SACLockScreenImmediate" }, sleep: { _ in }),
                   .failed("找不到 SACLockScreenImmediate"))
}
```

- [ ] **Step 2: Run** `swift test --filter 'WorkerCLITests|ScreenLockTests'` → FAIL (no `.lock`, no `lockScreen`).
- [ ] **Step 3: Implement** the parser case, `lockScreen` (check `isLocked` first → `.already`; `call()`; poll `isLocked` every `step` until `timeout`), and `ScreenLocker.lock() -> LockOutcome` in rapp-host: `dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)`, `dlsym("SACLockScreenImmediate")` cast to `@convention(c) () -> Int32`, `isLocked` = `screenLocked(CGSessionCopyCurrentDictionary() as? [String: Any])`, `sleep` = `Thread.sleep`. `main.swift` maps the outcome to the three JSON shapes, output the same way `.check` does.
- [ ] **Step 4: Run** `swift test --filter 'WorkerCLITests|ScreenLockTests'` → PASS; `swift build` → ok.
- [ ] **Step 5: Commit** `feat(host): rapp-host lock`.
- [ ] **Step 6 (user, before release; does not block Task 2):** ask the user to run `.build/debug/rapp-host lock --json` on A from a Terminal: A locks and it prints `{"ok":true}`; run again while locked → `{"ok":true,"already":true}`. Record in spec §9.

---

### Task 2: Service: count, grace timer, lock, switch, history

**Files:**
- Modify: `rust/service/src/config.rs` (field + `auto_lock()` + unit test)
- Create: `rust/service/src/autolock.rs`
- Modify: `rust/service/src/lib.rs` (`mod autolock;`, `Opts.lock_grace: Duration`, spawn), `rust/service/src/main.rs` (`lock_grace: autolock::GRACE`)
- Modify: `rust/service/src/state.rs` (`counted_sessions()`, `"auto_lock"` in `status()`)
- Modify: `rust/service/src/workers.rs` (`lock`)
- Modify: `rust/service/src/ipc.rs` (`set_auto_lock`, `in_history`)
- Modify: `rust/testkit/src/bin/fake-rapp-host.rs` (`"lock"` branch)
- Modify: `rust/testkit/tests/common/mod.rs` (every `rapp_service::Opts {…}`: `lock_grace: Duration::from_secs(1)`)
- Test: `rust/testkit/tests/service.rs`
- Docs: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md` (`auto_lock`, default true, set from 本机, IPC `set_auto_lock`)

**Interfaces:**
- Consumes: Task 1's three JSON shapes.
- Produces: `pub fn counted(app: &str, side: bool) -> bool`; `pub const GRACE: Duration` (10 s); `pub fn spawn(state: Arc<State>, grace: Duration) -> tokio::task::JoinHandle<()>`; `State::counted_sessions(&self) -> usize`; `Config::auto_lock(&self) -> bool`; `workers::lock(state: &State) -> anyhow::Result<bool>` (`Ok(true)` locked now, `Ok(false)` already locked, `Err` with the host's `error`); IPC/status as in Global Constraints (Task 3 consumes them).
- Fake rapp-host `lock`: appends `lock\n` to `lock.log` next to `argv[0]` (not host.log, so existing host.log assertions are untouched); if a file `lock-fail` sits next to `argv[0]` prints `{"ok":false,"error":"forced"}` and exits 1; if `already-locked` sits there prints `{"ok":true,"already":true}`; else `{"ok":true}`.

- [ ] **Step 1: Write the failing tests**

Unit (config.rs): `auto_lock_defaults_on_and_saves_off` — `Config::default().auto_lock() == true`; save `auto_lock: Some(false)`, reload → `false`.
Unit (autolock.rs): `counted("com.apple.TextEdit", false)`, `counted("desktop:", false)`, `counted("desktop:2", false)` are true; `counted("term:abc", false)` and `counted("com.apple.TextEdit", true)` are false.

Integration (service.rs, grace 1 s; "no lock" = `lock.log` absent after 2.5 s):
- `auto_lock_after_last_app_closes`: open an app, close it → `wait_log(home, "auto_lock", …)`; `lock.log` has exactly one line; `ipc_once(…, {"cmd":"history"})` contains an `auto_lock` event.
- `reopen_within_grace_does_not_lock`: open, close, open again at once; no lock; close the second → lock.
- `two_devices_lock_only_when_both_closed`: B1 and B2 (`b_named`) each open an app; B2 closes → no lock; B1 closes → lock.
- `switch_off_and_toggle_during_grace`: `status` has `"auto_lock": true`; open, close, immediately `set_auto_lock {on:false}` → no lock; `status` now `false`; open, close → no lock; `set_auto_lock {}` → error `on required`.
- `no_lock_at_start`: start the service, wait 2.5 s → no lock.
- `lock_failure_is_recorded`: create `lock-fail` in bins; open, close → `wait_log(home, "auto_lock_failed", |v| v["error"] == "forced")`; history contains it. Then remove `lock-fail`, create `already-locked`; open, close → `lock.log` gains a line and no `auto_lock` event follows within 2.5 s.

- [ ] **Step 2: Run** `TERM=xterm-256color cargo test -p rapp-service auto_lock counted` and `TERM=xterm-256color cargo test -p rapp-testkit --test service lock` → FAIL to compile.
- [ ] **Step 3: Implement.**
  - `Config.auto_lock: Option<bool>` with `#[serde(default, skip_serializing_if = "Option::is_none")]`, doc comment `/// Lock A when the last remote app or desktop closes (default true).`
  - `spawn`: subscribe to `state.changed`; `prev = state.counted_sessions()`; `deadline: Option<Instant>`. `select!` on `rx.changed()` and `sleep_until(deadline)` (only when `Some`). On change: `n = counted`; `n > 0` or switch off → `deadline = None`; `prev > 0 && n == 0 && on` → `deadline = Some(now + grace)`; `prev = n`. On deadline: clear it; if `counted == 0 && on` → `workers::lock`: `Ok(true)` → `log.event(Info, "auto_lock", json!({}))`; `Ok(false)` → `log.msg(Info, "auto-lock: already locked")`; `Err(e)` → `log.event(Warn, "auto_lock_failed", json!({"error": format!("{e:#}")}))`. A closed channel ends the task.
  - `workers::lock`: `run_json(state, &["lock"])`, map the three shapes; a non-`ok` reply without `error` → `Err("rapp-host lock failed")`.
  - `ipc.rs`: `"set_auto_lock" => match cmd["on"].as_bool() { Some(on) => update(state, |c| c.auto_lock = Some(on)), None => err("on required") }`; add `"auto_lock" | "auto_lock_failed"` to `in_history`.
  - `lib.rs`: push `autolock::spawn(state.clone(), opts.lock_grace)` next to `update::spawn`.
- [ ] **Step 4: Run** the Step 2 commands → PASS; then the whole `TERM=xterm-256color cargo test` from `rust/` → PASS.
- [ ] **Step 5: Commit** `feat(service): lock A after the last remote app closes`.

---

### Task 3: A-side GUI: switch and history rows

**Files:**
- Modify: `gui/lib/service_client.dart` (`ServiceStatus.autoLock`, `setAutoLock` at both the client and the monitor wrapper, next to `setUpdate`)
- Modify: `gui/lib/pages/local_section.dart` (switch inside the `_platform == TargetPlatform.macOS` branch, after 权限)
- Modify: `gui/lib/access_log.dart` (two rows)
- Test: `gui/test/service_client_test.dart`, `gui/test/local_section_test.dart`, `gui/test/access_log_test.dart`

**Interfaces:**
- Consumes: Task 2 IPC/status.
- Produces: `bool ServiceStatus.autoLock` (missing in JSON → `true`); `Future<Map<String, Object?>> setAutoLock(bool on)` sending `{'cmd': 'set_auto_lock', 'on': on}`.

- [ ] **Step 1: Write the failing tests**
  - service_client_test: `ServiceStatus.fromJson({...})` without `auto_lock` → `autoLock == true`; with `false` → `false`; `setAutoLock(false)` sends `{'cmd':'set_auto_lock','on':false}`.
  - local_section_test (`platform: TargetPlatform.macOS`): `find.text('远程 app 都关闭后自动锁屏')` and `find.text('锁屏后，B 打开 app 时需要输入这台 Mac 的登录密码。')` found once; the switch is on for `auto_lock: true`; tapping it calls `setAutoLock(false)`. With `TargetPlatform.linux` the label is absent.
  - access_log_test: `historyRow({'ev':'auto_lock', …}).result == '远程 app 都已关闭，已自动锁屏'`, `warn == false`; `historyRow({'ev':'auto_lock_failed','error':'forced', …})` → `'自动锁屏失败：forced'`, `warn == true`.
- [ ] **Step 2: Run** `flutter test test/service_client_test.dart test/local_section_test.dart test/access_log_test.dart` → FAIL.
- [ ] **Step 3: Implement**; the switch row follows `UpdateSection`'s auto-update switch style; it reflects `st.autoLock` and errors from `setAutoLock` surface the way the update switch's do.
- [ ] **Step 4: Run** the same command → PASS; `git checkout pubspec.lock`.
- [ ] **Step 5: Commit** `feat(gui): auto-lock switch in 本机 and history rows`.

---

### Task 4: rapp-host: app session that starts while A is locked; cross-process unlock lock

Done whatever Task 0 step 2 showed (my call, deviating from spec §6.4's "only if needed"): a plan cannot branch on a manual result, and the path only runs when A is locked at start.

**Files:**
- Create: `Sources/RappCore/FileLock.swift`
- Modify: `Sources/RappCore/DataPaths.swift` (`unlockLockFile(home:)`)
- Modify: `Sources/rapp-host/Server.swift` (`startCapture`, `captureReady`, `unlock`)
- Test: `Tests/RappCoreTests/FileLockTests.swift`, `Tests/RappCoreTests/DataPathsTests.swift`

**Interfaces:**
- Produces: `public enum FileLock { public static func exclusive<T>(at url: URL, _ body: () throws -> T) throws -> T }` — creates the file and its directory if missing, `flock(LOCK_EX)` (blocking), runs `body`, unlocks and closes even when `body` throws. `public static func unlockLockFile(home: URL) -> URL` = `<home>/Library/Application Support/rapp/unlock.lock` (machine-local, next to the `data-root` pointer, never in the synced data dir).

- [ ] **Step 1: Write the failing tests**
  - `testSecondHolderWaits`: thread 1 takes the lock and sleeps 0.3 s appending "1-in","1-out"; thread 2 starts 0.05 s later and appends "2-in","2-out"; order is `["1-in","1-out","2-in","2-out"]`.
  - `testReleasedOnThrow`: body throws; a second `exclusive` on the same URL returns at once.
  - `testCreatesMissingDirectory`: URL under a fresh temp dir's `a/b/` works.
  - DataPathsTests: `unlockLockFile(home: URL(fileURLWithPath: "/Users/x")).path == "/Users/x/Library/Application Support/rapp/unlock.lock"`.
- [ ] **Step 2: Run** `swift test --filter 'FileLockTests|DataPathsTests'` → FAIL.
- [ ] **Step 3: Implement `FileLock` and the path**; run → PASS.
- [ ] **Step 4: Server.swift, locked start.** In `startCapture(bundleID:)`, before `WindowCapture.find`: if `screenLocked(…)` is true and `ready` has not been sent:
  - announce: `send(.ready(appName: windowTitle("", appName: <name>), width:, height:))` with name = `NSRunningApplication.runningApplications(withBundleIdentifier:).first?.localizedName`, else the bundle's display name via `NSWorkspace.urlForApplication(withBundleIdentifier:)`, else the bundle ID; size = `CGDisplayBounds(CGMainDisplayID()).size` rounded like `captureReady`; remember it as `announced: CGSize?`;
  - `sendLocked()` (sends `screenLocked(true)`), then a 1 s timer on `queue` that calls `sendLocked()` and, once A reports unlocked, cancels itself and runs the normal `startCapture` path;
  - `captureReady`: when `announced != nil`, do not send `ready` again; if `capture.displayFrame.size` differs from `announced`, `fail("解锁后，应用窗口在另一块屏幕上；请重新打开")` (documented limitation);
  - `ended` cancels the wait timer.
- [ ] **Step 5: Server.swift, unlock.** `unlock(_:)` guard becomes `injector != nil || announced != nil && capture == nil`; the typing block becomes `try? FileLock.exclusive(at: DataPaths.unlockLockFile(home: FileManager.default.homeDirectoryForCurrentUser)) { UnlockTyper.type(password, display: main) }` (`typeUnlockPassword` already re-checks `isLocked` first, so a second holder types nothing and the following `sendLocked()` tells B "unlocked"). If the lock cannot be opened, log `unlock lock unavailable` and type without it.
- [ ] **Step 6: Run** `swift build` and `swift test` → PASS (Server paths are covered by manual acceptance in Task 7).
- [ ] **Step 7: Commit** `feat(host): open app sessions on a locked A; one unlock typist at a time`.

---

### Task 5: B: unlock on open (MainState)

**Files:**
- Modify: `gui/lib/ui/main_state.dart` (event handler near the `ScreenLockedEvent` branch, `_canUnlock`, `_autoUnlock`, `unlock`, `_sendUnlock`, `lockBanner`, `dispose`)
- Test: `gui/test/ui/unlock_test.dart`

**Interfaces:**
- Produces: `Stream<String> get unlockAsks` (broadcast; device id; closed in `dispose`) — Task 6 listens. `lockBanner` returns `LockBanner(desktopLockText, '输入系统密码')` for every live locked session.
- Internal (names fixed so the tests read the same): `bool _countsForUnlock(String app) => !isTermApp(app) && !isDesktopScreen(app)` (secondary screens share the main desktop's lock state; terminals never report it); `final Set<String> _manualLock` (devices); `final Map<String, Timer> _unlockBusy` (device → 5 s check, replaces the per-sid `_unlockTimers`).

Rules (spec §6.6):
- First `ScreenLockedEvent` of a sid (`_unlockSeen`), `_countsForUnlock(r.app)`, `e.locked`, device not in `_manualLock`, device not in `_unlockBusy` → read the store: saved with `auto` → `_sendUnlock(…, auto: true)`; otherwise (none, `auto` false, unsupported, read error) → `unlockAsks.add(device)` if `r.key == currentKey`, else nothing (banner shows).
- Any live session of the device going `false → true` → add to `_manualLock`; any going `true → false` → remove from `_manualLock`, cancel and remove `_unlockBusy[device]`.
- `_sendUnlock` sets `_unlockBusy[device]`; after 5 s still locked → hint `密码可能不对`; if it was an auto attempt: `unlockStore.save(device, password, auto: false)` and `unlockAsks.add(device)` when the device's record is current. Never re-sent automatically.
- `unlock(device, …)` target: the current record if it is this device, `_countsForUnlock`, live, not ending; else the first live, not-ending, `_countsForUnlock` record of the device whose `screenLocked == true`; else hint `请先打开这台电脑上的 app 或桌面`. The rest of `unlock` is unchanged; a manual `unlock` is allowed while busy (it restarts the 5 s check).

- [ ] **Step 1: Write the failing tests** (in `env`, `credential = ('secret', auto: true)`; open an app with `e.state.openOrSwitch('111', 'app', 'App')`; asks collected via `e.state.unlockAsks.listen(asks.add)`):
  - `one unlock per device across sessions`: open app; first locked on `e.sid('app')`, then first locked on `e.sid('desktop:')` → `calls('unlock').single == {'sid': appSid, 'password': 'secret'}`; then `ScreenLockedEvent(appSid, false)`; a second app (`openOrSwitch('111','app2','App2')`) first-locked → a second unlock (busy cleared, no manual flag because `true → false` cleared it).
  - `no saved password asks only for the current session`: `credential = null`; first locked on the current session → `asks == ['111']`; first locked on a non-current session → `asks` unchanged, `calls('unlock')` empty.
  - `manual lock survives reconnect` (replaces the reconnect half of the existing first test, whose expectation becomes `hasLength(1)`): unlocked → locked mid-session; disconnect + `reconnect('111/desktop:')` + first locked → no new unlock, no ask; `false` on any session clears it, and the next reconnect with first locked unlocks.
  - `reconnect without a manual lock unlocks again`: first locked → unlock; disconnect, reconnect, first locked → second unlock.
  - `auto failure turns auto off and asks once`: first locked → unlock; elapse 5 s → hint `密码可能不对`, `store.credential` is `('secret', auto: false)`, `asks == ['111']`; reopen app first-locked → still one unlock call, ask from the current session only.
  - `terminals and secondary screens never trigger`: first locked on `e.sid('desktop:22')` → nothing; a term record (`isTermApp`) never reaches the trigger.
  - `unlock picks the session by device`: current app session locked → `unlock('111', 'x', …)` targets its sid; with every session of `111` ended → hint `请先打开这台电脑上的 app 或桌面`.
  - `lock banner asks for the password on app sessions`: current app session locked → `lockBanner` is `('远程电脑已锁屏；输入系统密码解锁', '输入系统密码')`.
  - The existing `manual unlock targets main…` test keeps passing unchanged (current `desktop:22` is not a target, so the main desktop is used).
- [ ] **Step 2: Run** `flutter test test/ui/unlock_test.dart test/ui/desktop_test.dart` → FAIL.
- [ ] **Step 3: Implement** the rules above.
- [ ] **Step 4: Run** `flutter test test/ui` → PASS; `git checkout pubspec.lock`.
- [ ] **Step 5: Commit** `feat(gui): unlock on open for every app session, once per device`.

---

### Task 6: B: dialog on ask, banner button, Linux memory store

**Files:**
- Modify: `gui/lib/ui/stage.dart` (`_requestUnlock` → top-level `Future<void> requestUnlock(BuildContext context, MainState state, String device)`; banner button always calls it)
- Modify: `gui/lib/ui/main_window.dart` (`_MainWindowState` subscribes to `state.unlockAsks` in `initState`, cancels in `dispose`; ignores asks while its own dialog is open)
- Modify: `gui/lib/ui/unlock.dart` (memory backend, label)
- Test: `gui/test/ui/unlock_test.dart`, `gui/test/ui/main_window_test.dart`

**Interfaces:**
- Consumes: Task 5 `unlockAsks`.
- Produces: `UnlockStore({bool? supported, MethodChannel? channel, bool? memory})` — `memory` defaults to `Platform.isLinux`; `supported` defaults to `Platform.isMacOS || memory`; with `memory` true, `read`/`save`/`forget` use a per-instance `Map<String, UnlockCredential>` and never touch the channel. `bool get memory`. `MemoryUnlockStore` in tests passes `memory: false`.

- [ ] **Step 1: Write the failing tests**
  - `memory store round trips without the channel`: `UnlockStore(memory: true)`: save `('A','pw', auto: true)` → read gives it; forget → null; a mock handler on `rapp/unlock` records no calls.
  - `memory store dialog says this run only`: `UnlockDialog(store: UnlockStore(memory: true), device: 'A')` shows `本次运行期间记住密码` and `连上时自动输入`, not `记住密码`.
  - `app banner opens the dialog`: like the existing desktop banner test but on `openOrSwitch('111','app','App')`; tapping `输入系统密码` opens the dialog and submits to the app's sid.
  - `ask opens one dialog`: pump `MainWindow`; emit two asks for `111` → one `UnlockDialog` on screen; submit → `unlock` sent.
- [ ] **Step 2: Run** `flutter test test/ui/unlock_test.dart test/ui/main_window_test.dart` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test` (whole suite) → PASS; `git checkout pubspec.lock`.
- [ ] **Step 5: Commit** `feat(gui): unlock dialog on open, app banner button, Linux in-memory password`.

---

### Task 7: Docs, full run, acceptance hand-off

**Files:** Modify: `README.md:19`, `README.zh-CN.md:19`, spec (status line, §9 pointer).

- [ ] **Step 1: README wording.** zh: `并保持不睡眠。远程 app 全部关闭后，A 会自动锁屏，下次打开 app 时在 B 上输入 A 的系统密码解锁（可在「本机」里关掉）；开机后的登录窗口和睡眠仍不支持。` en: `keep it awake. When the last remote app closes, A locks itself; the next time you open an app, B asks for (or types the remembered) system password of A. Turn this off under 本机 (This Mac). The login window after a restart and sleep are still not supported.`
- [ ] **Step 2: Spec status line** → `状态：已批准（2026-11-15），实施中。`; note in §6.4 that the plan does it unconditionally.
- [ ] **Step 3: Full run:** `swift test`; from `rust/` `TERM=xterm-256color cargo test`; from `gui/` `flutter test` then `git checkout pubspec.lock`. All PASS.
- [ ] **Step 4: Commit** `docs: auto-lock in README and spec status`.
- [ ] **Step 5: Hand the §8 acceptance table to the user** (real A and B; Task 1 step 6 too). Nothing is merged to main or released by this plan; that goes through the release coordinator.

---

## Self-review

- Spec coverage: §6.1/6.2/6.3 → Task 2–3 (lock via `workers::run_json` like `check`, instead of spec §6.2's "runner + spawn_blocking"; same effect, existing pattern); §6.4/6.5 → Task 4; §6.6 → Task 5–6; §6.7 → Task 6; §6.9 → Task 2 (config reference), Task 7 (README); §7 step 1 → Task 0 + Task 1 step 6; §8 → Task 7 step 5.
- Deviations to flag to the user: §6.4 unconditional; lock file in `~/Library/Application Support/rapp/` (machine-local) as the "本机私有部分".
