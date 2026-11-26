# rapp update CLI and relaxed auto-update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `rapp update` installs a new version in one command (agent-friendly: JSON, exit codes, timeouts), and the auto-update really installs when nobody has touched the Mac or its remote sessions for 10 minutes, without ending text terminals.

**Architecture:** The service keeps one "last remote activity" time (remote input, session start, pipe/forward/map traffic), a per-IPC-connection count of the GUI's non-terminal remote windows, and reads `HIDIdleTime` through the updater's `Runner`. Every install path (auto, CLI, GUI, rollback) raises `quit_gui` in `update_status`, the GUI quits itself, the service waits for the bundle processes that matter (not `rapp-term`, not `rapp-cli`), swaps, restarts and reopens the GUI. The CLI is a polling client of the existing IPC.

**Tech Stack:** Rust (tokio) workspace in `rust/`, Flutter GUI in `gui/`.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-cli-update-design.md`

## Global Constraints

- All user-facing text is Chinese; `error` codes are English and fixed: `failed busy still_open nothing_to_install no_previous usage not_running offline timeout needs_confirm needs_admin not_launchd needs_reinstall`.
- Exit codes: 0 ok (incl. 已是最新) · 1 failed/busy/still_open/nothing_to_install/no_previous · 2 usage · 3 not_running · 4 offline · 5 timeout · 6 needs_confirm · 7 needs_admin/not_launchd/needs_reinstall. Old commands: not running exits 3 (was 1).
- `--json`: exactly one JSON object on **stdout**, success or failure; errors are `{"ok":false,"error":<code>,"message":<中文>,"page":<url|null>}`. Without `--json`: progress on stderr, result on stdout, error line on stderr.
- The CLI never reads stdin (except `pipe`), never prints the key or password, never hangs (every wait has a deadline).
- Quiet window: 10 minutes (`UpdateOpts.quiet`, default `Duration::from_secs(600)`); still evaluated every `idle_poll` (60 s).
- Default timeouts: `update` 900 s, `update check` 300 s, `update rollback` 120 s; poll every 500 ms; re-read `ipc.token` and `service.json` on every connect.
- Service reply fields are additive only (old GUIs ignore them).
- Tests: `cd rust && cargo test --workspace --no-fail-fast`; `cargo clippy --workspace --all-targets -- -D warnings`. Flutter is `~/development/flutter/bin/flutter` (not on PATH); revert `gui/pubspec.lock` after running it.
- `grep` here is ugrep: use `/usr/bin/grep` in scripts. There is no `timeout` command.
- Work only on branch `feat/cli-update` in `.worktrees/cli-update`; never commit to main.

## Review Focus

1. GUI-initiated 立即升级 where the GUI has already exited when the service looks at ps → `gui_was_open` must still be true so the GUI comes back (Task 2, `gui_apply_reopens_even_if_gone_before_ps`).
2. The service restarts during `rapp update` (connection refused for seconds, new token, new port) → the CLI keeps retrying until its deadline and reports success, not `not_running` (Task 5, `update_survives_restart_with_new_token`).
3. An auto attempt whose blocker never exits → the GUI must not quit and reopen every minute (Task 3, `auto_gives_up_reopens_gui_and_backs_off`).
4. `rapp update --json` with no service → stdout is one JSON object with `not_running`, exit 3 (Task 5, `json_not_running`).
5. A stale `up_to_date`/`failed` read right after `update_check` (the check has not started yet) → the CLI must see the result of *this* check (Task 2 `update_check_wait_replies_after_the_check`; Task 5 uses `"wait":true`).

---

### Task 1: Activity signals

**Files:**
- Create: `rust/service/src/activity.rs`
- Modify: `rust/service/src/lib.rs` (mod), `rust/service/src/state.rs` (field + `add_session` touch; construct where `State` is built), `rust/service/src/workers.rs:~320` (events), `rust/service/src/ipc.rs` (pipe splice, `gui_windows`), `rust/service/src/forward.rs:~190`, `rust/service/src/own.rs:~112`, `rust/service/src/maps.rs` (impl `traffic`), `rust/net/src/quic.rs`, `rust/ports/src/carry.rs:~100` (+ `Carrier` trait), `rust/term/src/serve.rs:~570`
- Test: unit tests in `activity.rs`, `net/src/quic.rs`, `term/src/serve.rs`; `rust/testkit/tests/update.rs` (gui_windows reply)

**Interfaces:**
- Produces:
  - `pub struct Activity` (Default) with `pub fn touch(&self)`, `pub fn quiet_for(&self, d: Duration) -> bool` (true when never touched or last touch ≥ d ago; `std::time::Instant`), `pub fn set_windows(&self, conn: u64, n: usize)`, `pub fn drop_conn(&self, conn: u64)`, `pub fn windows(&self) -> usize` (sum over connections).
  - `State.activity: crate::activity::Activity`.
  - `rapp_net::quic::splice_watched(a, b, meter: &Meter, every: Duration, on_traffic: impl FnMut()) -> io::Result<()>`: calls `on_traffic` once at start, then on every `every` tick at which the meter's totals changed. `pub const TRAFFIC_TICK: Duration = 5 s`.
  - `rapp_ports::Carrier::traffic(&self) {}` (default no-op); `State` implements it as `self.activity.touch()`.
  - IPC `{"cmd":"gui_windows","count":N}` → `{"ok":true}`; count stored under a per-connection id (a `static AtomicU64` in ipc.rs), removed by a drop guard when the connection ends. Bad/missing count → `err("count")`.
  - Worker event `{"event":"activity"}` → `state.activity.touch()` only. `{"event":"input"}` → `tell_others` as now **and** `touch()`.
  - `rapp-term serve`: `to_run` gets `events: &UnboundedSender<Value>` and sends `{"event":"activity"}` on a counted input, at most once per `ACTIVITY_EVERY = 5 s`.
  - `add_session` touches.

- [ ] **Step 1: Write failing tests**
  - `activity.rs`: `never_touched_is_quiet` (`quiet_for(1 ms)` true); `touch_then_not_quiet` (`quiet_for(10 s)` false right after `touch`); `windows_sum_and_drop` (set 1→2, 2→3 ⇒ 5; drop 2 ⇒ 2; set 1→0 ⇒ 0).
  - `quic.rs`: `splice_watched_reports_traffic`: duplex pair, `every = 20 ms`, write bytes on one side; counter of `on_traffic` calls ≥ 2 (start + a tick); with no bytes after start over 100 ms, the count stays at 1.
  - `serve.rs`: `inputs_send_activity_throttled`: feed `to_run` two `Keys` lines back to back; the events receiver gets exactly one `{"event":"activity"}`.
  - testkit `update.rs`: `gui_windows_is_acknowledged`: `Ipc::open`, `call({"cmd":"gui_windows","count":2})` == `{"ok":true}`; `call({"cmd":"gui_windows"})["ok"]` == false.
- [ ] **Step 2:** `cd rust && cargo test -p rapp-service -p rapp-net -p rapp-term activity splice_watched inputs_send_activity --no-fail-fast` → FAIL (missing items).
- [ ] **Step 3: Implement** as in Interfaces. Replace `splice`/`splice_metered`/`copy_bidirectional` at ipc pipe, `forward.rs`, `own.rs`, `ports/src/carry.rs` with `splice_watched`, `on_traffic` = `state.activity.touch()` / `c.traffic()`. Forward keeps its existing `meter`.
- [ ] **Step 4:** `cargo test --workspace --no-fail-fast` → PASS.
- [ ] **Step 5: Commit** `feat(service): remember the last remote activity and the GUI's remote windows`

### Task 2: In-use rules, quit_gui and the manual paths

**Files:**
- Modify: `rust/service/src/update.rs`, `rust/service/src/ipc.rs:66-74`, `rust/service/src/peer.rs:256`, `rust/service/src/term.rs:229`, `rust/update/src/apply.rs:224` (Marker)
- Test: `update.rs` unit tests; `rust/testkit/tests/update.rs`

**Interfaces:**
- Consumes: Task 1 `State.activity`.
- Produces:
  - `fn read_procs(ps: &str, me: u32, bundle: &str) -> Option<Procs>`; `struct Procs { blocking: bool, gui: bool }`. None when the output does not show `me` under `<bundle>/Contents/`. `blocking`: a process under `<bundle>/Contents/` with pid≠me, ppid≠me, whose file name is not `rapp-term` or `rapp-cli`. `gui`: a process `<bundle>/Contents/MacOS/rapp` with ppid≠me. `/usr/local/bin/rapp` never counts.
  - `UpdState.quit_gui: bool`; `status_json` adds `"quit_gui"`, `"launchd"` (`update_opts.launchd`, false when off) and `"error_code"` (`error` == STILL_OPEN → `still_open`, NEEDS_ADMIN → `needs_admin`, NOT_LAUNCHD → `not_launchd`, other Some → `failed`, None → null).
  - `enum By { Gui, Cli, Auto }` + `as_str`; ipc passes `By::Cli` when `cmd["by"] == "cli"`, else `By::Gui`.
  - `pub async fn apply(state, confirm: bool, by: By, closed) -> Value`, `pub async fn rollback(state, by: By, closed) -> Value`.
  - `async fn quit_gui_and_wait(state: &Arc<State>, o: &UpdateOpts, closed: Option<watch::Receiver<()>>, by: By) -> Result<bool, bool>` replaces `wait_for_nobody`: sets `quit_gui` + notify; reads ps once for `gui` (`by == Gui` ⇒ true regardless); waits `closed` up to `gui_wait`; polls `read_procs(..).blocking` every `MANUAL_POLL` up to `gui_wait` (unreadable ps counts as blocking). Ok(gui_was_open) when clear. On timeout: clear `quit_gui`, `reopen_gui` if gui_was_open, return Err(gui_was_open). The caller of a manual path then `fail(Stage::Install, STILL_OPEN)`.
  - `put_in_place(state, busy, mode: Mode, by: By, gui_was_open: bool)`: always sets `installing` before the last gate; last gate for Manual/Rollback = procs; for Auto = procs + Task 3's `auto_busy`. Every failure path clears `quit_gui` and reopens the GUI iff `gui_was_open`. Marker gets `gui_was_open` as given and `by`.
  - `Marker.by: String` with `#[serde(default)]`; `on_start` logs `update_applied {from,to,mode,by}` (`by` omitted when empty).
  - Remove `UpdState.opening`, `sessions_in_use`, `Opening`; `pub fn begin_open(state: &Arc<State>) -> Result<(), &'static str>` refuses while installing, else `state.activity.touch()`.
  - `fn code_err(code: &str, msg: &str) -> Value` = `{"ok":false,"error":msg,"code":code}`; `page_err(code, msg, page)` adds `code`. Codes: NOTHING_TO_INSTALL→`nothing_to_install`, 需要确认→`needs_confirm`, NEEDS_ADMIN→`needs_admin`, NOT_LAUNCHD→`not_launchd`, LEFTOVER→`failed`, BUSY→`busy`, NO_PREVIOUS→`no_previous`.
  - IPC `update_check` with `"wait":true` awaits `check_now` before replying `ok`; without it, unchanged (spawn).

- [ ] **Step 1: Write failing tests**
  - unit `procs_rules` with a ps fixture (me=100, bundle `/A/rapp.app`): only `rapp-term` (ppid 1) + `rapp-cli` (bundle path) + `/usr/local/bin/rapp` ⇒ `Some(Procs{blocking:false,gui:false})`; + `/A/rapp.app/Contents/MacOS/rapp` ppid 1 ⇒ `{blocking:true,gui:true}`; + `rapp-host` ppid 100 only ⇒ not blocking; + `rapp-hub` ppid 555 ⇒ blocking, gui false; output without pid 100 ⇒ None.
  - testkit (replace `a_pipe_through_the_rapp_link_blocks_auto_install` and the `opening_session_blocks_auto_install` test, which no longer holds):
    - `terminals_and_cli_never_block_manual_install`: ps_extra has `rapp-term` (ppid 776), `{bundle}/Contents/MacOS/rapp-cli`, `/usr/local/bin/rapp`; `call({"cmd":"update_apply","by":"cli"})` ok ⇒ restart, marker `new`, `applied()["by"] == "cli"`, `gui_was_open == false`.
    - `cli_apply_raises_quit_gui_and_reopens`: GUI line in ps_extra; after apply via a one-shot `call`, `update()["quit_gui"] == true`; clear ps_extra ⇒ restart; `applied()["gui_was_open"] == true`.
    - `quit_gui_drops_when_gui_stays`: GUI line stays ⇒ `wait_state("failed")`, `error == "rApp 还开着"`, `error_code == "still_open"`, `quit_gui == false`, OPEN called with the bundle.
    - `gui_apply_reopens_even_if_gone_before_ps`: no GUI line, apply from `Ipc::open` without `by`, drop ⇒ `applied()["gui_was_open"] == true`, `["by"] == "gui"`.
    - `rollback_by_cli_logs_by`: previous present ⇒ `call({"cmd":"update_rollback","by":"cli"})` ⇒ `applied()["mode"] == "rollback"`, `["by"] == "cli"`.
    - `error_replies_carry_codes`: `signature_change_waits_for_confirm` now expects `{"ok":false,"error":"需要确认","code":"needs_confirm"}`; `not_launchd_never_installs` expects `r["code"] == "not_launchd"`; nothing ready ⇒ `code == "nothing_to_install"`.
    - `status_has_launchd_and_quit_gui`: `update()["launchd"] == true`, `["quit_gui"] == false`; with `launchd: false` ⇒ false.
    - `update_check_wait_replies_after_the_check`: `check_updates:false`, `Knobs.split = Some(300 ms)`; `call({"cmd":"update_check","wait":true})` ⇒ `update()["state"] == "ready"` immediately after the reply.
    - `manual_apply_goes_in_over_open_sessions` and `rollback_goes_in_over_open_sessions` stay green.
- [ ] **Step 2:** `cargo test -p rapp-testkit --test update --no-fail-fast` → the new tests FAIL.
- [ ] **Step 3: Implement** per Interfaces. `try_auto` keeps working for now by calling `quit_gui_and_wait(.., None, By::Auto)` (Task 3 adds its conditions).
- [ ] **Step 4:** `cargo test --workspace --no-fail-fast` → PASS.
- [ ] **Step 5: Commit** `feat(service): installs ask the GUI to quit; terminals and the CLI no longer block them`

### Task 3: Auto-install when nobody has touched anything for 10 minutes

**Files:**
- Modify: `rust/update/src/runner.rs` (`IOREG`), `rust/update/src/lib.rs` (parser), `rust/service/src/lib.rs:~110` (UpdateOpts), `rust/service/src/update.rs` (`try_auto`, `auto_busy`)
- Test: `rust/update/src/lib.rs` unit; `rust/testkit/tests/update.rs` (fake `IOREG`, knobs)

**Interfaces:**
- Consumes: Task 1 `Activity`, Task 2 `quit_gui_and_wait`, `put_in_place(.., By::Auto, gui_was_open)`.
- Produces:
  - `pub const IOREG: &str = "/usr/sbin/ioreg";` run with `["-c","IOHIDSystem","-d","4","-k","HIDIdleTime"]`.
  - `pub fn parse_hid_idle(out: &str) -> Option<Duration>`: the first `"HIDIdleTime" = <u64>` (nanoseconds).
  - `UpdateOpts.quiet: Duration` (default 600 s) and `UpdateOpts.auto_backoff: Duration` (default 30 min【我定的】: after an auto attempt whose processes would not exit, no auto attempt for this long, so the GUI does not quit and reopen every minute).
  - `async fn auto_busy(state: &State, o: &UpdateOpts) -> Option<String>`, in this order: `!activity.quiet_for(quiet)` → "最近 10 分钟有远程操作"; `activity.windows() > 0` → "本机开着远程窗口"; ioreg fails / unparsable → "读不到本机空闲时间"; idle < quiet → "最近 10 分钟本机有人操作".
  - `try_auto`: `auto_allowed` → backoff over → `auto_busy` none → `Busy::begin` → `quit_gui_and_wait(None, By::Auto)`; Err ⇒ log `update_auto_skipped {"reason": STILL_OPEN}`, set backoff deadline, return; Ok(g) ⇒ `put_in_place(Mode::Auto, By::Auto, g)`. No `failed` state on a skipped round.
  - testkit `Env`: `hid_idle_ns: Arc<AtomicU64>` (default 10^12 = idle), `ioreg_code: Arc<AtomicI32>`; `Knobs.quiet` (default 0 so old auto tests keep their timing) and `Knobs.auto_backoff` (default ZERO).

- [ ] **Step 1: Write failing tests**
  - unit `hid_idle_parses`: `"    | |     \"HIDIdleTime\" = 103471775250\n"` ⇒ `Some(Duration::from_nanos(103471775250))`; `""` and `"\"HIDIdleTime\" = x"` ⇒ None.
  - testkit:
    - `idle_session_does_not_block_auto_install` (replaces `sessions_block_auto_install`): open a session, ready ⇒ restart within `WAIT` while the session stays open; `applied()["by"] == "auto"`.
    - `recent_session_blocks_auto_install`: `Knobs.quiet = 1500 ms`; ready first, then open a session (add_session touches) ⇒ no restart for 800 ms; the session stays open ⇒ restart once the quiet time has passed. (Remote input and traffic touch the same `Activity`; Task 1 tests each touch point's wiring by unit test.)
    - `local_input_blocks_auto_install`: `hid_idle_ns = 1_000_000` ⇒ no restart for `POLL*6`; set back to 10^12 ⇒ restart.
    - `unreadable_idle_blocks_auto_install`: `ioreg_code = 1` ⇒ no restart for `POLL*6`.
    - `remote_window_blocks_auto_install`: a held `Ipc` sends `gui_windows 1` ⇒ no restart; send `0` (or drop the connection) ⇒ restart.
    - `auto_quits_gui_and_reopens_after_install` (replaces `gui_process_blocks_auto_install`): GUI line in ps_extra; ready ⇒ `quit_gui == true`; clear ps_extra ⇒ restart; `applied()["gui_was_open"] == true`, `mode == "auto"`.
    - `auto_gives_up_reopens_gui_and_backs_off`: `auto_backoff = 10 s`, `gui_wait = 100 ms`, GUI line stays ⇒ after `POLL*8`: state still `ready` (not failed), `quit_gui == false`, OPEN called exactly once with the bundle.
- [ ] **Step 2:** `cargo test -p rapp-update hid_idle; cargo test -p rapp-testkit --test update --no-fail-fast` → FAIL.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4:** `cargo test --workspace --no-fail-fast` → PASS.
- [ ] **Step 5: Commit** `feat(service): auto-update installs after 10 quiet minutes, quitting and reopening the GUI`

### Task 4: CLI arguments, output and exit codes

**Files:**
- Create: `rust/cli/src/out.rs`, `rust/cli/src/ipc.rs`
- Modify: `rust/cli/src/args.rs`, `rust/cli/src/main.rs`
- Test: unit tests in `args.rs`, `out.rs`

**Interfaces:**
- Produces:
  - `Cmd::Update { what: Upd, yes: bool, timeout: Option<u64>, json: bool }`, `enum Upd { Install, Check, Status, Rollback }`. Grammar: `update [check|status|rollback] [--yes] [--timeout 秒] [--json]`; `--yes` only with Install (else "只有 rapp update 能用 --yes"); `--timeout` not with Status; seconds = integer ≥ 1 (else "--timeout 后面要写秒数"); unknown word/flag → usage (exit 2). USAGE gains the four lines.
  - `out.rs`: `pub fn exit_code(error: &str) -> i32` (table in Global Constraints; unknown → 1); `pub struct Out { pub json: bool }` with `progress(&self, line: &str)` (stderr, only when !json), `ok(&self, v: Value, line: &str) -> !` (json: `{"ok":true,..v}` on stdout; else `line` on stdout; exit 0), `fail(&self, code: &str, message: &str, page: Option<&str>) -> !` (json: error object on stdout; else message (+ "\n" + page) on stderr; exit `exit_code(code)`).
  - `ipc.rs`: `pub async fn call(cmd: Value, wait: Duration) -> Result<Value, Gone>` — one connection per call (reads `ipc.token` and `service.json` each time), `Gone` when it cannot connect or the reply does not arrive within `wait`; `pub async fn open(cmd) -> Result<(Value, reader, writer), Gone>` for `pipe`. Moves `local_dir`/`ipc_port`/`connect` out of main.rs.
  - Old commands: not running ⇒ `eprintln!(NOT_RUNNING)`, exit 3.

- [ ] **Step 1: Write failing tests**
  - `args.rs` `update_commands`: `p("update")` ⇒ `Update{Install,false,None,false}`; `p("update --yes --timeout 30 --json")` ⇒ `{Install,true,Some(30),true}`; `p("update check --json")`, `p("update status")`, `p("update rollback --timeout 5")`. Errors: `p("update status --timeout 3")`, `p("update check --yes")` ⇒ "只有 rapp update 能用 --yes", `p("update --timeout 0")` / `p("update --timeout x")` / `p("update --timeout")` ⇒ "--timeout 后面要写秒数", `p("update now")` ⇒ "不认识的命令：update now".
  - `out.rs` `codes_map_to_exits`: each code in the table maps to its number; `"whatever"` ⇒ 1.
- [ ] **Step 2:** `cargo test -p rapp-cli` → FAIL.
- [ ] **Step 3: Implement**; Tasks 4 and 5 are committed together if done in one sitting, so `main` dispatches `Cmd::Update` straight to `update::run`.
- [ ] **Step 4:** `cargo test -p rapp-cli && cargo test -p rapp-testkit --test share_set --no-fail-fast` → PASS (old commands unchanged apart from exit 3).
- [ ] **Step 5: Commit** `feat(cli): update arguments, JSON output and fixed exit codes`

### Task 5: `rapp update`, `check`, `status`, `rollback`

**Files:**
- Create: `rust/cli/src/update.rs`, `rust/cli/tests/update.rs` (fake IPC service)
- Modify: `rust/cli/Cargo.toml` (`[dev-dependencies] tempfile, tokio, serde_json`), `rust/cli/src/main.rs`

**Interfaces:**
- Consumes: Task 4 `Out`, `ipc::call`; service fields from Tasks 2–3 (`launchd`, `error_code`, `quit_gui`, `code`, `update_check wait`, `by`).
- Produces: `pub async fn run(what: Upd, yes: bool, timeout: Option<u64>, out: Out) -> !`.
  - Common: deadline = now + timeout (defaults 900/300/120 s); every `call` bounded by `min(10 s, time left)`; `Gone` before anything was sent ⇒ `not_running`; deadline passed ⇒ `timeout` "等了 N 秒还没好".
  - Preflight (Install, Check, Rollback): `status` ⇒ `update.state == "off"` ⇒ `failed` "这个 rApp 不是从安装包装的，不能在线升级"; `launchd == false` ⇒ `not_launchd` (page = `page` or `reinstall_page`); `needs_reinstall` ⇒ `needs_reinstall` (page `reinstall_page`).
  - Check (Install, Check): `{"cmd":"update_check","wait":true}` with a progress poller printing 检查中… / 下载中 N% (only when changed); then poll until state ∉ {checking, downloading}. `up_to_date` ⇒ ok `{"result":"up_to_date","current"}` "已是最新（X）"; `failed` ⇒ `failed` with `error`; `ready` + Check ⇒ ok `{"result":"ready","current","latest","needs_confirm"}` "有新版本 X，已下载好（当前 Y）".
  - Install: `needs_confirm && !yes` ⇒ `needs_confirm` "新版本换了签名，确认后加 --yes 再运行"; `needs_admin` ⇒ `needs_admin` "这次需要管理员密码，请从页面下载安装包" + page; then `{"cmd":"update_apply","confirm_signature_change":yes,"by":"cli"}` on its own connection, closed right after the reply; a reply with `ok:false` ⇒ `fail(reply.code or "failed", reply.error, reply.page)`.
  - Rollback: `can_rollback == false` ⇒ `no_previous` "没有上一版"; `{"cmd":"update_rollback","by":"cli"}`.
  - Wait (Install, Rollback): progress "安装中…" then "等新版本起来…"; every 500 ms `status` (Gone = still restarting, keep going); done when `current` ≠ from (Rollback) / `current` == target (Install) and `state != "installing"` ⇒ ok `{"result":"updated"|"rolled_back","from","to"}` "已升级到 X（原来 Y）" / "已回到 X（原来 Y）"; `state == "failed"` ⇒ `fail(error_code or "failed", error)`.
  - Status: one `status` ⇒ ok `{"state","current","latest","progress","auto_update","can_rollback","error","error_code"}`; text: one line each 当前版本 / 最新版本 / 状态 / 自动升级 开·关 / 可以回滚 能·不能 / 错误 (only when set).
  - Fake service in `tests/update.rs`: `struct Fake` binds `127.0.0.1:0`, writes `<tmp>/service.json` `{"ipc_port":p}` and `ipc.token`; scripted by a closure `Fn(&Value, &mut Script) -> Value`; `restart(new_token)` drops the listener, rebinds on a new port and rewrites both files. The CLI runs as `env!("CARGO_BIN_EXE_rapp-cli")` with `RAPP_LOCAL=<tmp>`, stdin null.

- [ ] **Step 1: Write failing tests** (`tests/update.rs`):
  - `update_installs_and_reports`: status idle 0.15.35 → check ⇒ ready 0.15.36 → apply (assert it carried `"by":"cli"` and that the connection is closed by the CLI: fake reads EOF after the reply) → fake restarts with a new token, then status current 0.15.36 idle ⇒ exit 0, stdout `{"ok":true,"result":"updated","from":"0.15.35","to":"0.15.36"}` with `--json`.
  - `update_survives_restart_with_new_token`: like above, the fake is down for 1.5 s between apply and the new status; exit 0.
  - `up_to_date_exits_0`: text stdout "已是最新（0.15.35）".
  - `needs_confirm_without_yes_exits_6` and `with_yes_sends_confirm` (apply carries `confirm_signature_change: true`).
  - `needs_admin_exits_7_with_page`, `needs_reinstall_exits_7`, `not_launchd_exits_7`.
  - `failed_install_exits_1`: after apply status `failed` + `error_code: "still_open"` ⇒ exit 1, json error `still_open`.
  - `timeout_exits_5`: status stays `checking`; `--timeout 1` ⇒ exit 5 within 3 s, json error `timeout`.
  - `json_not_running`: no service files ⇒ exit 3, stdout parses as `{"ok":false,"error":"not_running",..}`.
  - `check_reports_ready_without_installing`: no `update_apply` received.
  - `status_json_has_no_secrets`: fake status carries `password` and `key`-like fields; stdout contains neither value.
  - `rollback_reports_previous`: `can_rollback:true` → rollback → current 0.15.34 ⇒ `{"result":"rolled_back","from":"0.15.35","to":"0.15.34"}`; `can_rollback:false` ⇒ exit 1 `no_previous`.
- [ ] **Step 2:** `cargo test -p rapp-cli --test update` → FAIL.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4:** `cargo test --workspace --no-fail-fast` → PASS.
- [ ] **Step 5: Commit** `feat(cli): rapp update, update check, update status, update rollback`

### Task 6: GUI

**Files:**
- Modify: `gui/lib/update.dart` (`quitGui`, wording), `gui/lib/service_client.dart` (`guiWindows`), `gui/lib/main.dart` (main-window wiring only, never `--cm`)
- Test: `gui/test/update_test.dart`, `gui/test/service_client_test.dart`

**Interfaces:**
- Produces:
  - `UpdateInfo.quitGui` (`j['quit_gui'] == true`).
  - `ServiceConnection.guiWindows(int n)` → `{'cmd':'gui_windows','count':n}`; `ServiceMonitor.setGuiWindows(int n)`: remembers `n`, sends it when it changed and after every (re)connect.
  - `int remoteWindows(Iterable<HubSession> s) => s.where((x) => !isTermApp(x.app)).length` (in `update.dart` or next to `isTermApp`).
  - In `main.dart` (main window): hub listener → `monitor.setGuiWindows(remoteWindows(hub.sessions))`; monitor listener → `quitGui` true ⇒ `shell._quitNow()` once (guard flag), no dialog.
  - Wording: `'$v 已下载，10 分钟没人操作时会自动装好'`.

- [ ] **Step 1: Write failing tests**: `UpdateInfo.fromJson({'quit_gui': true,...}).quitGui` true, missing ⇒ false; `updateView` ready + autoUpdate line == `'0.5.0 已下载，10 分钟没人操作时会自动装好'` (update the existing expectation); `remoteWindows` counts `term:` apps out; service_client fake server receives `{"cmd":"gui_windows","count":2}` after `setGuiWindows(2)` and again after the server drops and the monitor reconnects.
- [ ] **Step 2:** `cd gui && ~/development/flutter/bin/flutter test test/update_test.dart test/service_client_test.dart` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test` → PASS; `git checkout gui/pubspec.lock`.
- [ ] **Step 5: Commit** `feat(gui): quit when the service installs, report remote windows`

### Task 7: Gates, todo, hand-off

**Files:**
- Modify: `tasks/todo.md` (real-machine checks §5.8 1–7 incl. 5a, under a 「rapp update / 自动升级」 heading), the spec §5.1 (one line: 30-minute auto backoff 【我定的】; `update_check` `wait`; status `launchd`/`error_code`)

- [ ] **Step 1:** `cd rust && cargo test --workspace --no-fail-fast && cargo clippy --workspace --all-targets -- -D warnings` → both clean (paste the summary lines).
- [ ] **Step 2:** whole-branch review (fresh reviewer), fix what it finds.
- [ ] **Step 3:** Commit `docs: rapp update checks and the calls made while building`; tell the user the branch name and that the first upgrade to this version still needs one manual click.
