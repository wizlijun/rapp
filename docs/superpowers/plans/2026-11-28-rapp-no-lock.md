# 不锁屏 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each macOS or Linux (Hyprland) computer a 「不锁屏」 switch. It is kept in that computer's rApp service, and while it is on, that computer neither auto-locks nor idles into display sleep, screen saver or lock. Every connected device sees the switch and can flip it.

**Architecture:** The service stores `no_lock` in `service.json`. While it is on, the service skips auto-lock and supervises a keep-awake child: `rapp-host stay-awake` on macOS, `systemd-inhibit … cat` on Linux. The value travels to other devices in the 余力 snapshot (`no_lock`, `no_lock_held`). A new `Op::NoLock` carries changes, and only key-trusted devices may send it. The hub exposes it as `{"cmd":"no_lock"}`. The GUI has one shared `NoLockCard` widget, used under 余力 in every overview column and on the phone 「设备」 page.

**Tech Stack:** Rust (tokio, serde), Swift (IOKit, via existing `PowerHold`), Flutter/Dart.

**Spec:** `docs/superpowers/specs/2026-11-28-rapp-no-lock-design.md`

## Global Constraints

- Platforms this round: macOS. On Linux, the card shows only when the service's session is Hyprland. Windows shows no card. Don't touch any `#[cfg(windows)]` / `cfg(windows)` code. Use runtime `cfg!(target_os = …)` checks in shared code.
- Config: `no_lock: Option<bool>` in `rust/service/src/config.rs`; `no_lock()` defaults to `false`.
- The snapshot carries the keys `no_lock` and `no_lock_held` **only** when `no_lock::supported()`. The GUI shows the card **only** when the key is present.
- Turning the switch off never triggers a lock by itself. The existing auto-lock rule stays: a 10 s timer starts only when counted sessions go from more than 0 to 0.
- Log events: `no_lock_set` (fields: `by`/peer fields, `on`), `no_lock_refused` (`reason`), `no_lock_hold_failed` (`code`, `stderr`). All three go in the `ipc.rs` `in_history` table.
- Remote refusal text is the existing `admit` deny string `not supported`. The GUI maps it to 「这台设备不能改它的设置」. Other failures are shown as `失败：<error>`.
- Card copy, verbatim:
  - title: 「不锁屏」
  - off: 「没人连着时，会按系统设置熄屏、锁屏」
  - on and held: 「一直亮着，不会自动锁屏」, plus on macOS a second line 「合上笔记本盖子仍会睡眠」
  - on but not held: 「没能保持唤醒，正在重试」, in the warn colour
- Local settings note under 「远程 app 都关闭后自动锁屏」, shown when `no_lock` is on: 「「不锁屏」开着，暂不自动锁屏」 (muted).
- Folded 本机 strip marker: an `Icons.lock_open` icon, key `column-local-no-lock`. The strip's semantics label becomes `展开 <name>，不锁屏开着`.
- Widget keys: `no-lock-card-<id|local>`, `no-lock-switch-<id|local>`.
- No protocol version bump. A new Op is answered `unknown op` by older devices, same as `SetService` and `Load`.
- `rapp-host stay-awake` changes `Sources/rapp-host/main.swift` and `Sources/RappCore/WorkerCLI.swift`. The same commit must update host-core: `USAGE_TEXT`, the `cli-args.json` fixture, `tests/cli.rs`, and the `PORTING.md` rows and digests. CLAUDE.md requires this.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Flutter: `~/development/flutter/bin/flutter`. If `flutter pub get` rewrites `pubspec.lock`, revert it.

## Review Focus

1. **The service starts with `no_lock` already on** (after a reboot). The child must start at launch, not only after a change. Test: `no_lock_on_at_start_holds` (Task 2).
2. **Fast on → off → on.** There must be exactly one live child, with no orphan left from the first "on". Test: `no_lock_flip_flop_keeps_one_child` (Task 2).
3. **The service stops while holding.** The child exits, because its stdin closes and it is killed on drop. Test: `no_lock_child_exits_with_service` (Task 2).
4. **A remote change shows on the next look, not after the next sample.** `load` replies read the live config. Test: `b_turns_a_no_lock_on_and_off` asserts the `load` reply right after the set (Task 3).
5. **A device without the key flips the card.** The card snaps back and says 「这台设备不能改它的设置」. Test: `no_lock_card_refusal_reverts` (Task 5).

---

### Task 1: `rapp-host stay-awake` (Swift + host-core + fake worker)

**Files:**
- Modify: `Sources/RappCore/WorkerCLI.swift` (add `case stayAwake(json: Bool)` to `HostCommand`; parse `"stay-awake"` in the `"list-apps", "check", "version", "lock"` branch, which takes no flags)
- Modify: `Sources/rapp-host/main.swift` (usage line `rapp-host stay-awake [--json]` after `lock`; a `case let .stayAwake(json)` handler)
- Modify: `Sources/rapp-host/PowerHold.swift` (`stayAwake(reason: String = "rapp: a remote session is open", log:)`)
- Modify: `Tests/RappCoreTests/HostCoreFixtures/CLIFixtures.swift` (command map `.stayAwake` → `["cmd":"stay_awake","json":json]`; arg cases `["stay-awake","--json"]`, `["stay-awake"]`, `["stay-awake","extra"]`)
- Regenerate: `rust/host-core/tests/fixtures/cli-args.json`
- Modify: `rust/host-core/src/cli.rs` (`HostCommand::StayAwake { json: bool }`, parsed with `lock`)
- Modify: `rust/host-core/src/run.rs` (`USAGE_TEXT` line; the `StayAwake` arm prints `{"ok":false,"error":"not supported"}` with `--json`, or `stay-awake: not supported` without it, and returns exit code 1)
- Modify: `rust/host-core/tests/cli.rs` (`JCommand::StayAwake { json }`, `same_command` arm)
- Modify: `rust/host-core/PORTING.md` (row numbers for `main.swift`; a new row for `stay-awake` → `run::run`, Windows answers not supported; digests for the three changed Swift files)
- Modify: `rust/testkit/src/bin/fake-rapp-host.rs` (`stay-awake`)

**Interfaces:**
- Produces: `rapp-host stay-awake --json`.
  - It prints one line, `{"ok":true}`, holds a `PowerHold` with reason `rapp: 不锁屏`, and blocks until stdin hits EOF or a SIGTERM arrives.
  - Then it releases the hold and exits 0.
  - If the hold fails, it prints `{"ok":false,"error":"could not keep this Mac awake"}` and exits 1.
- Produces (fake worker), next to argv[0]:
  - It appends `start` to `stay-awake.log`, prints `{"ok":true}`, and reads stdin to EOF.
  - It then appends `exit` and exits 0.
  - If a `stay-awake-fail` file exists, it prints `{"ok":false,"error":"forced"}` and exits 1.

- [ ] **Step 1:** Add the CLIFixtures cases and the `.stayAwake` mapping. Run `swift test --filter 'Fixtures/'`. Expected: FAIL (compile error: no `.stayAwake`).
- [ ] **Step 2:** Implement the parse case and the `main.swift` handler.
  - Read stdin to EOF on a background thread, and use `DispatchSource.makeSignalSource(SIGTERM)` with `signal(SIGTERM, SIG_IGN)`. Whichever fires first releases the hold and calls `exit(0)`.
  - Run `RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`, then `swift test`. Expected: PASS.
- [ ] **Step 3:** Update host-core: `cli.rs`, `run.rs`, `tests/cli.rs`, and `PORTING.md`. Compute digests with `shasum -a 256`. Run `cd rust && cargo test -p rapp-host-core` (check the package name in `rust/host-core/Cargo.toml`). Expected: PASS, including `host_arguments_match_swift` and the porting digest test.
- [ ] **Step 4:** Add the fake-worker `stay-awake` handler. Run `cd rust && cargo build -p rapp-testkit --bins`. Expected: builds.
- [ ] **Step 5:** Smoke-test the real thing:
  ```
  swift build -c release --product rapp-host
  (.build/release/rapp-host stay-awake --json & P=$!; sleep 1; pmset -g assertions | grep -c '不锁屏'; kill $P)
  ```
  Expected: prints `{"ok":true}` and a count ≥ 1.
- [ ] **Step 6:** Commit: `feat(host): rapp-host stay-awake keeps the Mac awake until stdin closes`.

### Task 2: Service: config, keep-awake supervisor, auto-lock skip, local IPC

**Files:**
- Modify: `rust/service/src/config.rs` (field and getter, next to `auto_lock`)
- Create: `rust/service/src/no_lock.rs`
- Modify: `rust/service/src/state.rs` (field `pub no_lock: crate::no_lock::NoLock`; `status()` adds `"no_lock": cfg.no_lock(), "no_lock_held": self.no_lock.held()`)
- Modify: `rust/service/src/lib.rs` (`mod no_lock;`, construct `NoLock::default()`, spawn `no_lock::spawn(state.clone())` beside `autolock::spawn`)
- Modify: `rust/service/src/autolock.rs` (both `auto_lock()` checks become `auto_lock() && !no_lock()`)
- Modify: `rust/service/src/workers.rs` (expose `pub(crate) async fn host_command(state: &State) -> Result<tokio::process::Command>`: `tokio_command(host_bin)` + `desktop_environment`; `run_json` uses it)
- Modify: `rust/service/src/ipc.rs` (`set_no_lock`; `in_history` gets the three events)
- Test: `rust/testkit/tests/service.rs`

**Interfaces:**
- Produces:
  - `pub struct NoLock { held: AtomicBool }` (Default); `pub fn held(&self) -> bool`.
  - `pub fn supported() -> bool` and `fn supported_in(os: &str, env: impl Fn(&str) -> Option<String>, hypr_dir: bool) -> bool`:
    - macos → true;
    - linux → `HYPRLAND_INSTANCE_SIGNATURE` non-empty, **or** `XDG_CURRENT_DESKTOP` contains `hyprland` (case-insensitive), **or** `hypr_dir` (`$XDG_RUNTIME_DIR/hypr` is a directory). The service may run outside the Hyprland env (systemd user unit), hence the last check;
    - anything else → false.
  - `pub fn set(state: &State, on: bool, by: Value) -> Result<(), String>`: saves the config, calls `state.notify()`, and logs `no_lock_set` with `by` merged and `on`.
  - `pub fn spawn(state: Arc<State>) -> JoinHandle<()>`.
  - `async fn supervise<F, Fut, R>(mut want: watch::Receiver<bool>, make: F, base: Duration, report: R)` where `F: Fn() -> Fut`, `Fut: Future<Output = Option<tokio::process::Command>>`, `R: Fn(Report)`, and `enum Report { Held(bool), Failed { code: Option<i32>, stderr: String } }`. This is the testable core: `spawn` feeds it a `watch` derived from `state.changed` + `cfg.no_lock()`, `make` = the platform command, and `base` = 1 s.
  - `fn backoff(base: Duration, failures: u32) -> Duration`: `base * 2^(failures-1)`, capped at 60 s.
- Supervisor rules:
  - Spawn with stdin piped, stdout to null, stderr piped, and `kill_on_drop(true)`. Report `Held(true)` once spawned.
  - When the child exits while still wanted, report `Failed` (exit code, last non-empty stderr line), then `Held(false)`. Sleep `backoff`, but still react to `want` while asleep. The failure count resets once a child has run ≥ 60 s.
  - When `want` goes false: drop stdin, wait up to 2 s, `kill()`, then report `Held(false)`.
  - `make()` returning `None` (Windows / no binary) means: report nothing and hold nothing.
- Platform command:
  - macOS: `host_command(state)` + `["stay-awake","--json"]`.
  - Linux: `systemd-inhibit --what=idle:sleep --mode=block --who=rapp --why=不锁屏 cat`.
  - Otherwise: `None`.
- In `spawn`, the report handler stores `held` and calls `state.notify()` **only when held changes**, and logs `no_lock_hold_failed` at Warn.
- IPC: `{"cmd":"set_no_lock","on":bool}` → `no_lock::set(state, on, json!({"by":"local"}))` → `ok({})`. Missing `on` → `err("on required")`.

- [ ] **Step 1: Unit tests in `no_lock.rs` / `config.rs`:**
  - `config_no_lock_defaults_off_and_round_trips`: `Config::default().no_lock() == false`; after setting `Some(true)`, save + load gives `true`.
  - `supported_cases`: `supported_in("macos", none, false)`; `!supported_in("linux", none, false)`; `supported_in("linux", HYPRLAND_INSTANCE_SIGNATURE="x", false)`; `supported_in("linux", XDG_CURRENT_DESKTOP="Hyprland", false)`; `supported_in("linux", none, true)`; `!supported_in("windows", none, true)`.
  - `backoff_doubles_to_60s`: base 1 s → 1, 2, 4, …, 32, 60, 60.
  - `supervise_holds_and_releases`: `make` = `sh -c 'cat >/dev/null'`; want true → `Held(true)` within 1 s; want false → `Held(false)` within 3 s.
  - `supervise_restarts_a_failing_child`: `make` = `sh -c 'echo boom >&2; exit 3'`, base 10 ms → `Failed { code: Some(3), stderr: "boom" }` at least twice within 1 s.
  - `supervise_none_reports_nothing`: `make` returns `None`; nothing is reported within 200 ms.
- [ ] **Step 2:** Run `cd rust && cargo test -p rapp-service no_lock`. Expected: FAIL (module missing).
- [ ] **Step 3:** Implement `no_lock.rs`, the config field, `workers::host_command`, the State field, the `lib.rs` spawn, the `autolock` change, and IPC `set_no_lock` + `status` + `in_history`.
- [ ] **Step 4:** Run `cargo test -p rapp-service`. Expected: PASS.
- [ ] **Step 5: testkit tests in `rust/testkit/tests/service.rs`** (near `auto_lock_after_last_app_closes`; reuse its helpers and `lock.log` counting). On non-macOS, skip the `held` and `stay-awake.log` assertions with `if cfg!(target_os = "macos")`; there the real command is `systemd-inhibit`.
  - `set_no_lock_holds_and_releases`:
    - `set_no_lock on` → `ok`; `service.json` has `"no_lock":true`; `status.no_lock == true`; `status.no_lock_held` becomes true; `stay-awake.log` has `start`;
    - `off` → `no_lock_held` false and `stay-awake.log` gets `exit`;
    - the `history` IPC lists `no_lock_set` twice.
  - `no_lock_skips_auto_lock`: with no_lock on, open and close an app, wait grace + 1 s → `lock.log` count 0.
  - `turning_no_lock_off_does_not_lock`: open/close an app with no_lock on, then turn it off, wait grace + 1 s → count 0; open/close again → `auto_lock` is logged.
  - `no_lock_on_at_start_holds`: write `service.json` with `no_lock: true` before start → `no_lock_held` becomes true.
  - `no_lock_flip_flop_keeps_one_child`: on, off, on with no waits → after 2 s, `stay-awake.log` has as many `exit` lines as `start` lines minus 1.
  - `no_lock_child_exits_with_service`: on, wait for held, stop the service → `stay-awake.log` ends with `exit` within 3 s.
  - `stay_awake_failure_is_logged`: create `stay-awake-fail` in bins → `no_lock_hold_failed` is logged; `no_lock_held` stays false.
- [ ] **Step 6:** Run `cd rust && cargo test -p rapp-testkit --test service no_lock` and `--test service lock`. Expected: PASS.
- [ ] **Step 7:** Run `cargo clippy --workspace --all-targets -- -D warnings`. Expected: clean. Commit: `feat(service): 不锁屏 switch: keeps a stay-awake child and skips auto-lock`.

### Task 3: Remote: `Op::NoLock`, snapshot keys, hub command

**Files:**
- Modify: `rust/net/src/msg.rs` (variant after `WatchLoad`, doc comment from spec §5; shape tests)
- Modify: `rust/service/src/peer.rs` (`Ok(op @ Op::NoLock { .. }) => crate::no_lock::serve(state, s, op, peer).await`, beside `SetService`)
- Modify: `rust/service/src/no_lock.rs` (`serve` / `answer`, modelled on `companion::serve` / `answer`)
- Modify: `rust/service/src/load/serve.rs` (`reply` and `line` add the keys via a helper)
- Modify: `rust/hub/src/services.rs` (`pub(crate) async fn no_lock(hub, v)`) and `rust/hub/src/lib.rs` (route `"no_lock"`)
- Create: `rust/testkit/tests/no_lock.rs` (helpers copied from `set_service.rs`)

**Interfaces:**
- Consumes: `no_lock::set`, `NoLock::held`, `supported()` (Task 2).
- Produces:
  - `Op::NoLock { on: Option<bool> }`. JSON is `{"op":"no_lock"}` / `{"op":"no_lock","on":true}`.
  - Device reply: `{"ok":true,"no_lock":bool,"no_lock_held":bool}`.
  - Refusal: `{"ok":false,"error":"not supported"}`, logged as `no_lock_refused` with `By::Remote(peer).fields(json!({"reason":..,"on":..}))`.
  - Remote set is logged as `no_lock_set` with `By::Remote(peer).fields(json!({"on":..}))`. Use `admit(&Caller{fp: peer.fp.as_ref(), server:false}, true)`.
  - `fn add_no_lock_keys(o: &mut Map<String, Value>, supported: bool, on: bool, held: bool)`: inserts `no_lock` and `no_lock_held` only when `supported`.
  - Hub: `{"cmd":"no_lock","id","on"?}` → `{"event":"no_lock","id","reply":<device reply>}`. A bad `on` → `bail!("bad on")`.

- [ ] **Step 1: Tests:**
  - `msg.rs` `no_lock_shapes`: the two JSON forms both ways.
  - `serve.rs` `no_lock_keys_only_when_supported`: `add_no_lock_keys(&mut m, false, true, true)` leaves `m` empty; with `true` gives `{"no_lock":true,"no_lock_held":true}`.
  - `testkit/tests/no_lock.rs`:
    - `b_turns_a_no_lock_on_and_off`: keyed visitor sends `{"op":"no_lock","on":true}` → `ok` and `no_lock: true`. A's status has `no_lock` true. A `{"op":"load"}` asked right away has `no_lock == true` on macOS, or no key when `!supported()`. `no_lock_set` is logged with `on: true`. Asking without `on` → `no_lock: true`. Off → false.
    - `a_password_connection_cannot_set_no_lock`: password auth, then `{"op":"no_lock","on":true}` → exactly `{"ok":false,"error":"not supported"}`; `no_lock_refused` is logged; config is unchanged.
    - `hub_no_lock_says_the_reply`: the `set_service_says_the_reply` pattern with `{"cmd":"no_lock","id":a.id,"on":true}` → `event == "no_lock"`, `reply.ok == true`, `reply.no_lock == true`.
- [ ] **Step 2:** Run `cd rust && cargo test -p rapp-net no_lock && cargo test -p rapp-testkit --test no_lock`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cargo test --workspace --no-fail-fast` and clippy `-D warnings`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: 不锁屏 travels: Op::NoLock, load snapshot keys, hub no_lock`.

### Task 4: GUI data and clients

**Files:**
- Modify: `gui/lib/load_model.dart` (`DeviceLoad.noLock`, `bool?`, null when the key is absent; `noLockHeld`, `bool`)
- Modify: `gui/lib/service_client.dart`:
  - `ServiceStatus.noLock` / `noLockHeld`;
  - `ServiceConnection.setNoLock(bool on)` → `{'cmd':'set_no_lock','on':on}`;
  - `ServiceMonitor.setNoLock` via `_then`.
- Modify: `gui/lib/hub_client.dart` (`Future<Map<String, Object?>> noLock(String id, {bool? on})`, which sends `{'cmd':'no_lock','id':id,'on':?on}` and waits for event `no_lock`. If `reply['ok'] != true`, throw `HubException('${reply['error']}')`; otherwise return the reply.)
- Modify: `gui/lib/ui/main_state.dart` (`Future<void> setNoLock(String? id, bool on)`: null id → `monitor!.setNoLock(on)`, else `hub!.noLock(id, on: on)`)
- Tests: `gui/test/load_model_test.dart`, `gui/test/hub_client_test.dart`, `gui/test/service_client_test.dart`

**Interfaces:**
- Produces: `DeviceLoad.noLock` (`bool?`), `DeviceLoad.noLockHeld` (`bool`), `ServiceStatus.noLock` (`bool`), `MainState.setNoLock(String? id, bool on)`, and `HubException.message` carrying the device's error text.

- [ ] **Step 1: Tests:**
  - `no_lock_keys_parse`: `{'no_lock':true,'no_lock_held':false,…}` → `(true,false)`; with no key → `noLock == null`.
  - Hub `no_lock_request_and_refusal`: the fake transport answers `{"event":"no_lock","reply":{"ok":false,"error":"not supported"}}` → throws `HubException` whose text contains `not supported`. Also check the sent line has `cmd == 'no_lock'` and `on == true`.
  - Service `status_reads_no_lock` and `setNoLock` sends `set_no_lock`.
- [ ] **Step 2:** Run `cd gui && ~/development/flutter/bin/flutter test test/load_model_test.dart test/hub_client_test.dart test/service_client_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement. Run the same tests. Expected: PASS.
- [ ] **Step 4:** Commit: `feat(gui): 不锁屏 in the load model, service and hub clients`.

### Task 5: GUI: `NoLockCard` and where it goes

**Files:**
- Create: `gui/lib/ui/no_lock_card.dart`
- Modify: `gui/lib/ui/overview.dart`:
  - `_Column`: the card right under `LoadRow`;
  - `_FoldedColumn`: `noLock` param + marker;
  - `_LocalFold`: passes `state.columnLoad(null, local: monitor)?.noLock == true`.
- Modify: `gui/lib/phone/devices_page.dart` (the card under each device's title row)
- Modify: `gui/lib/pages/local_section.dart` (the muted note under `_autoLockRow` when `st.noLock`)
- Create: `gui/test/ui/no_lock_card_test.dart`; extend `gui/test/ui/overview_test.dart`, `gui/test/local_section_test.dart`, and a phone devices-page test (`gui/test/phone/pages_test.dart`)

**Interfaces:**
- Consumes: Task 4 names.
- Produces: `NoLockCard({required String id, required DeviceLoad? load, required bool mac, required Future<void> Function(bool on) onSet, required void Function(String words) say})`.
  - It renders `SizedBox.shrink()` when `load?.noLock == null`.
  - `mac` is that column's `os == DeviceOs.macos`.
  - Callers pass `onSet: (on) => state.setNoLock(id, on)` and `say: state.say`.
  - Rows use `RappSwitchRow(switchKey: Key('no-lock-switch-$id'), label: '不锁屏', note: <line>, …)`, inside a `Container(key: Key('no-lock-card-$id'), decoration: t.panelBox(border: t.line))`.
  - The not-held note uses the `t.warn` colour, so use `style` or a separate `Text`, whichever `RappSwitchRow` allows.
- Switch behaviour:
  - While the request is in flight, `onChanged` is null and the value stays as it was.
  - On success, show the requested value until `load.noLock` equals it; drop that pending value when a new load disagrees for more than 15 s.
  - On error: if the error text contains `not supported`, `say('这台设备不能改它的设置')`; otherwise `say('失败：$e')`. Then revert.

- [ ] **Step 1: Tests (`no_lock_card_test.dart`):**
  - `no_lock_card_texts`:
    - off → 「没人连着时，会按系统设置熄屏、锁屏」;
    - on + held + mac → both 「一直亮着，不会自动锁屏」 and 「合上笔记本盖子仍会睡眠」;
    - on + held + not mac → no lid line;
    - on + not held → 「没能保持唤醒，正在重试」 in `t.warn`.
  - `no_lock_card_absent_without_key`: load without the key → no `no-lock-card-m1`; `load: null` → nothing.
  - `no_lock_card_busy_then_follows`: `onSet` completes from a `Completer`; tap → switch disabled and still off; complete → switch shows on before the new load arrives.
  - `no_lock_card_refusal_reverts`: `onSet` throws `HubException('not supported')` → `say` got 「这台设备不能改它的设置」 and the switch is off again.
  - Overview: `no_lock_card_in_local_and_remote_columns` (both columns' cards found under `load-row-*`); `folded_local_strip_shows_no_lock` (marker present when on, absent when off).
  - Phone: `devices_page_shows_no_lock_card`.
  - Local section: `auto_lock_row_says_no_lock_is_on`.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`. Expected: no issues; all pass.
- [ ] **Step 5:** Commit: `feat(gui): 不锁屏 card under 余力, on the phone 设备 page and the folded strip`.

### Task 6: Checks list and spec touch-up

**Files:**
- Modify: `tasks/todo.md` (new section 「不锁屏 实机检查」 with the spec's §9 real-machine checks 1–7, verbatim)
- Modify: `docs/superpowers/specs/2026-11-28-rapp-no-lock-design.md` §9. Change the autolock test line to: 「`no_lock` 开着时定时到了不锁；关掉时不触发锁屏，下一次会话结束照常 10 秒后锁」.

- [ ] **Step 1:** Edit both files and commit: `docs: 不锁屏 checks + spec test line`.
- [ ] **Step 2: Full gate on the branch:**
  - `swift test`
  - `cd rust && cargo test --workspace --no-fail-fast && cargo clippy --workspace --all-targets -- -D warnings`
  - `cd gui && flutter analyze && flutter test`

  Expected: all green.
