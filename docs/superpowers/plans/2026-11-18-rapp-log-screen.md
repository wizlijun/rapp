# 日志界面 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A full-stage 日志 screen (problems first, merged service+hub timeline, rows that open in place) for this device or any other online device, reached from 访问记录's 更多.

**Architecture:** One read-only query in a new Rust module `rapp_net::logq` (reverse-read `service.log`/`hub.log`, merge, fold `repeat`, classify, page by cursor, 24 h counts, `launchd.log` tail). The hub answers `{"cmd":"logs"}` from its own log dir (no `id`) or forwards `Op::Logs` to the device's service (with `id`). Dart only parses `raw`, words rows in Chinese and draws the screen.

**Tech Stack:** Rust (serde_json, tokio `spawn_blocking`), Flutter/Dart.

**Spec:** `docs/superpowers/specs/2026-11-18-rapp-log-screen-design.md` (read it first; section numbers below refer to it).

**Worktree / branch:** `/Users/bruce/git/rapp-panel-half`, branch `feat/panel-half-width`. Never commit to main. Flutter: `export PATH=~/development/flutter/bin:$PATH`; run `git checkout gui/pubspec.lock` before every commit. `grep` on this machine is ugrep — use `/usr/bin/grep` in scripts.

## Global Constraints

- Reply must be smaller than `rapp_net::line::MAX_LINE` (64 KiB): stop adding events at 56 KiB (`BUDGET = 56 * 1024`), set `more: true`.
- A `raw` longer than 4096 bytes: every string value over 1024 bytes cut to 1024 (char boundary), re-serialized, `"truncated": true`.
- `limit` default 200, max 500. `around` window ±60 s. Counts window 24 h. `launchd.log` tail 100 lines, each cut to 1024 bytes.
- Event entry shape (events and `latest`): `{"src":"service"|"hub","at":<cursor>,"kind"?:"unreachable"|"refused"|"fault","repeat"?:N,"truncated"?:true,"raw":<line>}`.
- Order: newest first by (`ts`, src rank `service`=0 `hub`=1, logical offset) — `around` oldest first.
- No secrets in any reply (the logs never contain them; tests check the reply too).
- iPad: every tappable control ≥ 48 tall (`Theme.of(context).platform == TargetPlatform.iOS`).
- All UI copy in Chinese exactly as the spec writes it: 「‹ 返回」「日志」「连不上」「被拒绝」「服务出错」「24 小时内没有」「只看问题」「全部」「启动输出」「加载更早的」「没有更早的了」「有 N 条新的」「复制」「看前后 ±1 分钟」「前后 1 分钟」「对方版本太旧，看不到它的日志」「（又重复 N 次）」「打开文件夹」.
- Tests use temp dirs and temp ports only; never `~/Library/Logs/rapp`.

## Review Focus

1. A log dir where `service.log` is missing or empty and only `hub.log` exists (iPad, a fresh install) → query returns hub rows, no error; UI hides the 来源 toggles. Test: Task 2 `only_hub_log`, Task 6 `ipad has no source toggles`.
2. A line in the middle of the file that is half-written or not JSON (crash mid-write) → skipped, neighbours still returned, cursors still advance. Test: Task 1 `bad_lines_are_skipped_in_reverse`.
3. Polling while the user has scrolled down, then a rotation (`.log` → `.log.1`) between polls → no crash, no lost rows; duplicates removed by `at`. Test: Task 2 `rotation_between_queries`, Task 6 `poll does not jump when scrolled`.
4. Picking a device that is offline, or is old (`unknown op`), or switching device while a query is in flight → the right message, and a late reply for the old device is dropped. Test: Task 6 `late reply for previous device is ignored`, `old device message`.
5. A huge single line (a worker dumping 4 KB stderr, a 60 KB event) → it still fits under the byte budget, `raw` stays valid JSON. Test: Task 2 `oversized_event_is_truncated_valid_json`.

---

### Task 1: `rapp_net::logq` — reverse reader and classifier

**Files:**
- Create: `rust/net/src/logq.rs`
- Modify: `rust/net/src/lib.rs` (add `pub mod logq;`), `rust/net/src/log.rs` (make `old_path` `pub(crate)`)

**Interfaces:**
- Produces:
  - `pub enum Src { Service, Hub }` with `fn name(self) -> &'static str` (`"service"`/`"hub"`), `fn file(self) -> &'static str` (`"service.log"`/`"hub.log"`), `fn rank(self) -> u8` (0/1).
  - `pub enum Kind { Unreachable, Refused, Fault }` with `fn as_str(self) -> &'static str` (`"unreachable"`/`"refused"`/`"fault"`) and `fn parse(&str) -> Option<Kind>`.
  - `pub fn classify(src: Src, ev: &Value) -> Option<Kind>` — the table in spec §3.2, exactly.
  - `pub(crate) struct Line { pub text: String, pub offset: u64 }` and `pub(crate) fn lines_rev(dir: &Path, src: Src) -> impl Iterator<Item = Line>` — lines of `<file>.1` then `<file>` read **backwards in 64 KiB chunks** (never the whole file), newest first; `offset` is the logical byte offset (`len(.1)` + offset in the current file). Empty lines skipped; non-UTF-8 lines lossily decoded.

- [ ] **Step 1: Write failing tests** (in `logq.rs` `#[cfg(test)] mod tests`, temp dir):
  - `lines_rev_spans_both_files_newest_first`: `.1` = `a\nb\n`, current = `c\nd\n` → texts `["d","c","b","a"]`, offsets strictly decreasing.
  - `lines_rev_reads_across_chunk_boundaries`: 3 lines each ~40 KiB → all three back intact, newest first.
  - `bad_lines_are_skipped_in_reverse` lives in Task 2 (query level); here: `lines_rev_missing_files_are_empty` → zero lines, no panic.
  - `classify_table`: one assertion per row of spec §3.2, including:
    - `(Hub, {"ev":"route","lvl":"warn"})` → Unreachable; `(Hub, {"ev":"route","lvl":"info"})` → None
    - `(Hub, {"ev":"log","lvl":"warn","msg":"x via relay: …; reconnecting"})` → Unreachable
    - `(Service, {"ev":"relay","lvl":"info","state":"connecting","error":"timeout"})` → Unreachable; `(Service, {"ev":"relay","lvl":"info","state":"connecting"})` → None; `(Service, {"ev":"relay","lvl":"warn","state":"error"})` → Unreachable
    - `(Service, {"ev":"trust","lvl":"warn","result":"refused"})` → Refused; `(Service, {"ev":"trust","lvl":"warn","result":"other"})` → Fault
    - `(Service, {"ev":"relay_revoked","lvl":"info"})` → Refused; `auth_fail`, `rejected`, `map_refused`, `forward_refused` → Refused
    - `(Service, {"ev":"request","result":"busy","op":"open"})` → Refused; `result:"ok"` → None; `op:"watch_terms"` failing → None
    - `(Hub, {"ev":"presence","lvl":"info","online":false})` → None
    - `(Service, {"ev":"log","lvl":"info","src":"host","msg":"thread 'main' panicked"})` → Fault; same with `msg:"hello"` → None; `src:"client"` in hub with `"Fatal error"` → Fault
    - `(Service, {"ev":"update_failed","lvl":"warn"})` → Fault; `(Service, {"ev":"session_start","lvl":"info"})` → None

- [ ] **Step 2: Run** `cd rust && cargo test -p rapp-net logq` — Expected: FAIL (module missing).

- [ ] **Step 3: Implement** `Src`, `Kind`, `classify`, `Line`, `lines_rev` in `rust/net/src/logq.rs`. Rule order in `classify`: refused rows first, then unreachable rows, then fault (any `lvl` warn/error, or `from`-stderr panic/fatal/error, case-insensitive).

- [ ] **Step 4: Run** `cargo test -p rapp-net logq` — Expected: PASS. `cargo clippy -p rapp-net --all-targets -- -D warnings` clean.

- [ ] **Step 5: Commit** `git commit -m "feat(net): logq reverse reader and problem classifier"`

### Task 2: `rapp_net::logq::query`

**Files:**
- Modify: `rust/net/src/logq.rs`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  ```rust
  #[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
  pub struct LogQuery {
      #[serde(default, skip_serializing_if = "Option::is_none")] pub before: Option<String>,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub after: Option<String>,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub around: Option<String>,
      #[serde(default, skip_serializing_if = "std::ops::Not::not")] pub problems: bool,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub kind: Option<String>,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub src: Option<Vec<String>>,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub q: Option<String>,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub limit: Option<u32>,
      #[serde(default, skip_serializing_if = "std::ops::Not::not")] pub tail_launchd: bool,
  }
  pub fn query(dir: &Path, q: &LogQuery, now: SystemTime) -> Value
  ```
  `query` returns the reply **without** `ok` (callers wrap it): `{"events":[…],"more":bool,"older"?:cursor,"newer"?:cursor,"counts"?:{…},"latest"?:{…},"launchd"?:[…]}`. `older`/`newer` omitted when `events` is empty. `counts` has all three keys (0 when none); `latest` only has keys with a match.
- Cursor (`at`, `older`, `newer`, `before`, `after`, `around`) is `"{ts}~{rank}~{offset}"`; parse failure → treat as bare `ts` (spec §3.4 fallback). Compare as the tuple (ts string, rank, offset).

- [ ] **Step 1: Write failing tests** (helper writes JSON lines with given `ts` into `service.log`/`hub.log`/`.1`):
  - `merges_newest_first_stable_on_same_ms`: service + hub lines, several sharing one `ts` → order by (ts desc, rank, offset desc); all `at` distinct.
  - `paging_with_cursor_no_gaps_no_dups`: 30 lines all with the same `ts`, `limit: 7`, page via `before = older` until `more == false` → union is exactly the 30, no duplicates.
  - `after_returns_only_newer`: query, append 3 lines, query with `after = newer` → exactly the 3.
  - `rotation_between_queries`: query, rename `service.log`→`service.log.1`, write 2 new lines, query `after = newer` → contains the 2 new lines (duplicates allowed, missing not).
  - `repeat_folds_into_previous`: lines `A`, `{"ev":"repeat","repeat":4}`, `B` → events `[B, A{repeat:4}]`, no repeat entry; when `A` is the last line of `.1` and repeat the first line of the current file, still folded. `counts` counts a classified `A` as 5.
  - `problems_kind_src_q_filters`: `problems:true` only classified; `kind:"refused"` only refused; `src:["hub"]` only hub; `q:"MiNi"` case-insensitive substring of the raw line.
  - `counts_and_latest_24h_ignore_filters`: classified lines at now-1h and now-25h → counts only the first; `latest.refused.raw` is the newest refused line; present with `src:["hub"]` + `q` too; absent when `before`, `after` or `around` is set.
  - `around_is_pm_60s_oldest_first_all_levels`: lines at t-90s, t-30s, t, t+30s, t+90s (mixed levels), `problems:true` given → returns t-30s, t, t+30s oldest first.
  - `budget_keeps_reply_under_56k`: 2000 lines of ~200 bytes, `limit:500` → `serde_json::to_string(&reply).len() < 56*1024 + 2048`, `more == true`.
  - `oversized_event_is_truncated_valid_json`: one line with a 60 KB `msg` → its `raw` parses as JSON, `truncated == true`, msg ≤ 1024 bytes.
  - `bad_lines_are_skipped_in_reverse`: a non-JSON line between two good ones → both good returned.
  - `only_hub_log`: dir with just `hub.log` → hub rows; `launchd` absent when `tail_launchd` but file missing.
  - `launchd_tail_last_100_cut_1k`: 150 lines, one 3 KB → `launchd.len() == 100`, newest last, every entry ≤ 1024 bytes.
  - `limit_default_200_max_500`.

- [ ] **Step 2: Run** `cargo test -p rapp-net logq` — Expected: new tests FAIL.

- [ ] **Step 3: Implement `query`.** Merge the two `lines_rev` streams newest-first with a two-way merge on (ts, rank, offset) — not a sort of everything. Fold `repeat` per stream before merging (hold one pending line; a `repeat` line attaches to the next older line read). Stop when `limit` reached, the budget is hit, or (for `around`) ts < window start; `around` collects then reverses. Counts: a separate pass per stream backwards until ts < now−24h. Run everything synchronously (callers put it on a blocking thread). Use `crate::log::timestamp` to format the 24 h / ±60 s bounds; add `pub fn parse_ts(&str) -> Option<SystemTime>` for the `YYYY-MM-DDTHH:MM:SS.mmmZ` format with its own test.

- [ ] **Step 4: Run** `cargo test -p rapp-net` and `cargo clippy -p rapp-net --all-targets -- -D warnings` — Expected: PASS, clean.

- [ ] **Step 5: Commit** `git commit -m "feat(net): logq query — merged, folded, paged by cursor, 24h counts, launchd tail"`

### Task 3: `Op::Logs` on the service

**Files:**
- Modify: `rust/net/src/msg.rs` (variant + wire test), `rust/service/src/peer.rs` (serve it)
- Test: `rust/testkit/tests/service.rs` (or a new `rust/testkit/tests/logs.rs` using `common`)

**Interfaces:**
- Consumes: `LogQuery`, `query` (Task 2).
- Produces: `Op::Logs(rapp_net::logq::LogQuery)` — wire `{"op":"logs", …query fields}`; an empty query serializes as exactly `{"op":"logs"}`.

- [ ] **Step 1: Write failing tests**
  - `msg.rs`: `logs_op_wire` — `Op::Logs(LogQuery::default())` ↔ `{"op":"logs"}`; with `limit:5, problems:true` ↔ `{"op":"logs","limit":5,"problems":true}`.
  - testkit `logs_over_the_peer_link`: start `service()`, write two known lines into `a.home/logs/service.log`, add the host to a hub, `hub.call({"cmd":"logs","id":a.id,"req":1})` → `event == "logs"`, `id == a.id`, the two raws present, `req == 1`. (Needs Task 4's hub command — put this test in Task 4; in this task test the service directly through the same helper the existing peer tests use to send a raw op after auth, asserting `ok == true` and `events` non-empty.)
  - `logs_needs_auth`: `{"op":"logs"}` as the first stream (no auth) → `auth required`.

- [ ] **Step 2: Run** `cargo test -p rapp-net logs_op_wire` and the testkit test — Expected: FAIL.

- [ ] **Step 3: Implement.** Add the variant (doc comment: "Read this device's logs (log screen spec §3); answered from `State::log_dir`"). In `serve_value`: `Ok(Op::Logs(q))` → `tokio::task::spawn_blocking(move || rapp_net::logq::query(&dir, &q, SystemTime::now()))`, reply `ok(result)` (merge the object's fields into the ok reply), `log_request(state, &peer, json!({"op":"logs"}), &r)`.

- [ ] **Step 4: Run** `cd rust && cargo test -p rapp-service -p rapp-net && cargo test -p rapp-testkit --test service` — Expected: PASS. Clippy clean.

- [ ] **Step 5: Commit** `git commit -m "feat(service): answer Op::Logs from the service's own log dir"`

### Task 4: hub `logs` command (this device and forwarded)

**Files:**
- Modify: `rust/hub/src/lib.rs` (`Opts.log_dir`, dispatch), `rust/hub/src/main.rs`, `rust/hub-ffi/src/lib.rs`, every `rapp_hub::Opts { … }` literal in `rust/testkit/tests/common/mod.rs` and other tests (`rg -n "rapp_hub::Opts \{" rust`)
- Test: new `rust/testkit/tests/logs.rs`

**Interfaces:**
- Consumes: `Op::Logs`, `LogQuery`, `query`.
- Produces: hub command `{"cmd":"logs","id"?:<host id>, …LogQuery fields, "req"?}` → event `{"event":"logs","id"?:<id>, …query reply fields, "req"?}`. Errors use the existing `{"event":"error","error":…,"req":…}`; an old device gives `error: "unknown op"`.
- `Opts` gains `pub log_dir: Option<PathBuf>` (None: `logs` without `id` → error `no log dir`). `main.rs` passes `Some(rapp_net::log::log_dir())`; hub-ffi passes `Some(PathBuf::from(&log_dir))`.

- [ ] **Step 1: Write failing tests** in `rust/testkit/tests/logs.rs`:
  - `local_logs_without_a_service`: a hub whose `log_dir` is a temp dir containing a `hub.log` with 3 lines and **no service started** → `{"cmd":"logs","req":"l"}` returns the 3 raws, `src == "hub"`, `counts` present, no `id` key.
  - `remote_logs_forwarded`: as sketched in Task 3 (`id` echoed, A's lines back).
  - `old_device_unknown_op`: a service built without the op is not available — instead send `{"cmd":"logs","id":a.id,"limit":"bad"}`… no: use the fake host route used by existing compatibility tests if one exists; if none, assert at the hub level that an `err("unknown op")` reply from the peer is surfaced as `{"event":"error","error":"unknown op"}` with a unit test on the hub's reply mapping. (Builder: pick whichever the codebase supports; the assertion is the GUI-visible string `unknown op`.)
  - `no_secrets_in_logs_reply`: after `hub_with_host` + one open/close, the `logs` replies (local and remote, `limit:500`) contain neither `PASSWORD` nor the relay key string.

- [ ] **Step 2: Run** `cargo test -p rapp-testkit --test logs` — Expected: FAIL.

- [ ] **Step 3: Implement** in `dispatch`: `Some("logs")` → parse the rest of `v` into `LogQuery` (`serde_json::from_value(v.clone())`, unknown keys ignored). With `id`: `self.request(&self.host(id)?, &Op::Logs(q)).await?`, build `{"event":"logs","id":id}` plus the reply's fields minus `ok`. Without: `spawn_blocking` `query(log_dir, …)`, `{"event":"logs"}` plus its fields.

- [ ] **Step 4: Run** `cd rust && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings` — Expected: PASS (the load-flaky pty tests may need a rerun; note any rerun in the report).

- [ ] **Step 5: Commit** `git commit -m "feat(hub): logs — this device from the hub's own log dir, another forwarded as Op::Logs"`

### Task 5: Dart data layer — `HubClient.logs` and row wording

**Files:**
- Create: `gui/lib/log_view.dart`
- Modify: `gui/lib/hub_client.dart`, `gui/lib/access_log.dart` (export the reused phrases if `logLine` calls them)
- Test: `gui/test/log_view_test.dart`, `gui/test/hub_client_test.dart` (existing file; follow its FakeTransport pattern)

**Interfaces:**
- Produces (in `log_view.dart`):
  ```dart
  enum LogKind { unreachable, refused, fault }            // .wire: 'unreachable' | 'refused' | 'fault'
  class LogEntry { final String src, at, raw; final LogKind? kind; final int repeat; final bool truncated;
                   final Map<String, dynamic> fields;     // jsonDecode(raw), {} if it does not parse
                   factory LogEntry.fromJson(Map<String, dynamic>); }
  class LogPage { final List<LogEntry> events; final bool more; final String? older, newer;
                  final Map<LogKind, int>? counts; final Map<LogKind, LogEntry>? latest; final List<String>? launchd;
                  factory LogPage.fromJson(Map<String, dynamic>); }
  class LogQuery { final String? before, after, around, q; final bool problems, tailLaunchd; final LogKind? kind;
                   final Set<String>? src; final int? limit; Map<String, dynamic> toJson(); }  // omits null/false
  class LogLine { final String time, summary; final bool warn; final List<(String, String)> fields; }
  LogLine logLine(LogEntry e, {DateTime? now, String? Function(String id)? nameOf});
  ```
- `HubClient`: `Future<LogPage> logs({String? id, required LogQuery query})` → `_request({'cmd':'logs', 'id': ?id, ...query.toJson()}, 'logs')`.

- [ ] **Step 1: Write failing tests**
  - `hub_client_test`: `logs` sends `{"cmd":"logs","limit":200,"problems":true,"req":…}` (no `id` key) and parses a reply into `LogPage` (counts map, `latest[refused].fields['reason']`, `launchd`); with `id: '111'` the line carries `"id":"111"`; a `{"event":"error","error":"unknown op"}` reply throws `HubException` whose message contains `unknown op`.
  - `log_view_test`:
    - time: an event today → `HH:mm:ss`; yesterday → `MM-dd HH:mm:ss` (local time).
    - `rejected` with `peer` + `reason:"wrong password"` → summary `拒绝 5.6.7.8:51022 · wrong password`, `warn` true (kind refused).
    - `route` warn `{id:"111", path:"relay", result:"timeout"}` with `nameOf: (id) => 'mini'` → `路由失败 mini · 中继 · timeout`.
    - `session_end` reuses the access-log wording (`historyRow`) for the result part.
    - unknown `ev:"zzz"`, `msg:"hi"` → `zzz · hi`; unknown without msg → `zzz`.
    - `repeat: 4` → summary ends with `（又重复 4 次）`.
    - fields: `peer` → `('来源地址', …)`, `path` → `('路径', '直连')`, `reason` → `('原因', …)`, `sid` → `('会话', …)`, `secs` → `('时长', '989 秒')`, `app` → `('app', …)`, an unknown key `foo` → `('foo', …)`; `ts`, `ev`, `lvl` not listed.
    - `raw` that does not parse → `fields` empty, summary is the raw text.

- [ ] **Step 2: Run** `cd gui && flutter test test/log_view_test.dart test/hub_client_test.dart` — Expected: FAIL.

- [ ] **Step 3: Implement** `log_view.dart` and `HubClient.logs`. Summaries for every event in spec §3.2's table plus `session_start/end`, `term_inputs`, `unlock`, `auto_lock`, `service_start/stop`, `update_*`, `presence` (`<name> 上线` / `<name> 离线`), `opened`/`closed`; everything else falls back to `ev · msg`.

- [ ] **Step 4: Run** the two test files, then `flutter analyze` — Expected: PASS, no issues.

- [ ] **Step 5: Commit** (revert `gui/pubspec.lock` first) `git commit -m "feat(gui): HubClient.logs and the log rows' Chinese wording"`

### Task 6: `LogScreen` and its model

**Files:**
- Create: `gui/lib/ui/log_screen.dart` (widget), `gui/lib/ui/log_model.dart` (state)
- Test: `gui/test/ui/log_screen_test.dart`

**Interfaces:**
- Consumes: Task 5.
- Produces:
  ```dart
  typedef LogFetch = Future<LogPage> Function(String? id, LogQuery q);
  class LogModel extends ChangeNotifier {
    LogModel({required LogFetch fetch, Duration poll = const Duration(seconds: 5)});
    String? device;                 // null = 本机
    bool problemsOnly = true; LogKind? kind; Set<String> sources = {'service', 'hub'}; String search = '';
    List<LogEntry> rows; bool more; Map<LogKind, int>? counts; Map<LogKind, LogEntry>? latest; List<String>? launchd;
    String? error;                  // '对方版本太旧，看不到它的日志' for unknown op, else the hub error text
    int pendingNew;                 // rows held back while scrolled down
    LogEntry? aroundOf;             // non-null while showing 前后 1 分钟
    Future<void> open(String? device);   Future<void> refresh();   Future<void> loadOlder();
    Future<void> poll();            // after: newer; dedupe by `at`
    void setAtTop(bool atTop);      // false holds new rows in pendingNew
    void showPending();             Future<void> around(LogEntry e);   void leaveAround();
    void setProblemsOnly(bool v);   void toggleKind(LogKind k);   void toggleSource(String s);   void setSearch(String q); // 300 ms debounce
    void dispose();                 // cancels the poll timer
  }
  class LogScreen extends StatefulWidget {
    const LogScreen({super.key, required this.model, required this.devices, required this.onBack, this.openFolder, this.logDir});
    final LogModel model; final List<(String id, String label, LampState lamp)> devices; // other devices, as the devices tab lists them
    final VoidCallback onBack; final Future<void> Function(String dir)? openFolder; final String? logDir;
  }
  ```
  (Use the lamp type the devices tab already uses for its picker; match its name.)
- Keys: `log-back`, `log-device-picker`, `log-device-<id>` / `log-device-local`, `log-search`, `log-refresh`, `log-open-folder`, `log-card-<kind>`, `log-problems`, `log-all`, `log-src-service`, `log-src-hub`, `log-launchd-toggle`, `log-launchd-text`, `log-row-<at>`, `log-copy-<at>`, `log-around-<at>`, `log-around-bar`, `log-around-close`, `log-pending`, `log-load-older`, `log-end`.
- Every query the model sends carries `tailLaunchd: true` only on the first page (no `before`/`after`/`around`). A reply whose request was for a different `device` than the current one, or older than the latest request, is dropped (generation counter).

- [ ] **Step 1: Write failing tests** (`LogModel` with a scripted fake `LogFetch`; widget pumped in a `MaterialApp` with `RappTokens` the way `devices_tab_test.dart` does):
  - `opens on 本机 with problems only`: first query `{problems:true, limit:200, tailLaunchd:true}`, id null; three cards show counts `12`/`3`/`1` and the latest summaries; a zero card shows `24 小时内没有` and is greyed.
  - `tapping a card filters to that kind and again clears it`.
  - `全部 drops problems; source toggles send src`.
  - `search debounces 300 ms then sends q`.
  - `scrolling to the end loads older with before = older; 没有更早的了 when more is false`.
  - `poll every 5 s adds new rows on top, deduped by at`.
  - `poll does not jump when scrolled`: scrolled down → `有 2 条新的` banner, rows unchanged until tapped, then at top.
  - `row opens in place with fields, raw, 复制 copies raw` (check `Clipboard` via `SystemChannels.platform` mock).
  - `看前后 shows the ±1 min view with the row highlighted; × returns to the list and scroll position`.
  - `old device message`: fetch throws `HubException('unknown op')` for id `111` → `对方版本太旧，看不到它的日志` next to the picker.
  - `late reply for previous device is ignored`: device A's reply completes after switching to B → B's rows shown.
  - `启动输出 toggles the launchd tail; hidden when launchd is null`.
  - `ipad has no source toggles when only hub rows exist` and `ipad controls are at least 48 tall` (`debugDefaultTargetPlatformOverride = TargetPlatform.iOS`).
  - `打开文件夹 only for 本机`.
  - `narrow window: cards scroll sideways, no overflow` (600 px wide surface).

- [ ] **Step 2: Run** `flutter test test/ui/log_screen_test.dart` — Expected: FAIL.

- [ ] **Step 3: Implement** the model, then the widget, following spec §4.2–4.3 and the sketch there. Colours from `RappTokens`; the device picker reuses `showMenu` + `menuAt` as `devices_tab.dart` does.

- [ ] **Step 4: Run** the test file and `flutter analyze` — Expected: PASS, no issues.

- [ ] **Step 5: Commit** `git commit -m "feat(gui): the log screen — cards, merged timeline, rows that open in place"`

### Task 7: Wire it into the main window

**Files:**
- Modify: `gui/lib/ui/main_state.dart` (`logs` flag), `gui/lib/ui/main_window.dart` (stage switch, Esc, 更多 on desktop and iPad), `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md` §3.7 (one line: 「更多」进日志界面，见《日志界面设计》), `docs/superpowers/specs/2026-11-11-rapp-observability-design.md` §6 (one line pointing to the log-screen spec)
- Test: `gui/test/ui/main_window_test.dart`, `gui/test/ui/main_state_test.dart` (existing)

**Interfaces:**
- Consumes: `LogScreen`, `LogModel`, `HubClient.logs`.
- Produces: `MainState.logs` (bool), `void openLogs()` (sets `logs = true`, `panel = null`, `_blur()` like the overview, notifies), `void closeLogs()`. `select(key)` and `toggleOverview()` also clear `logs`. `stageLive` and the off-stage frame-rate choice treat `logs` like `overview` (no session on stage).

- [ ] **Step 1: Write failing tests**
  - `main_state_test`: `openLogs closes the panel and takes the stage off`; `select clears logs`; `stageLive is false while logs is open`.
  - `main_window_test`: tapping `access-log-more` on 本机 shows `LogScreen` in the stage area with the top bar still present; `log-back` returns to the previous stage; Esc order — with the panel open Esc closes the panel first, then Esc closes the log screen, then (if overview was on underneath) the overview; iPad (`_iosLocal`) also has `access-log-more`.

- [ ] **Step 2: Run** those tests — Expected: FAIL.

- [ ] **Step 3: Implement.** Stage child: `logs ? LogScreen(…) : overview ? Overview : Stage`. Build the `LogModel` once per opening (dispose on close) with `fetch: (id, q) => state.hub!.logs(id: id, query: q)`; `devices` from the same host list and lamps the devices tab uses; `openFolder: _openFolder`, `logDir: m?.status?.logDir ?? '${state.data.root}/logs'`. `_esc`: corner → panel → logs → overview → fullscreen. Pass `onMore: state.openLogs` to both `AccessLogSection`s.

- [ ] **Step 4: Run** `cd gui && flutter analyze && flutter test` — Expected: all pass except the two known `test/embed/linux_detach_test.dart` failures (pre-existing on main). Then `cd ../rust && cargo test --workspace` once more.

- [ ] **Step 5: Commit** (revert `gui/pubspec.lock`) `git commit -m "feat(gui): 更多 opens the log screen; Esc and the stage know about it"`
