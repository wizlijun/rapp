# Device Load (Resources and Headroom) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every rapp service samples its own CPU, memory, heat and working disks every 5 s and keeps 1 hour of samples. From those it computes the warning levels and a headroom score. The GUI shows a headroom row under each device column, with an expandable detail view. Warnings go into 需要你 and the hint queue, with one-tap actions, and `rapp load` / `rapp load pick` give the same numbers to people and agents.

**Architecture:**
- A new `rust/service/src/load/` module owns sampling (a `Sampler` trait, with a fake for tests), the 720-point ring, the §6 rules and the snapshot JSON.
- The service answers two new peer ops, `load` and `watch_load`, plus the IPC commands `load`, `load_all` and `watch_load`.
- The hub keeps one `watch_load` per online device, the same way `terms.rs` does, and turns each line into a `load` event.
- The GUI reads remote devices from those events and the local device from a `watch_load` IPC stream.

**Tech Stack:** Rust (tokio, libc, serde_json), Flutter/Dart.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-device-load-design.md`. Read §5–§10 before any task; the spec is the authority. Per U4, the framework comes first. The per-OS collectors are "first version" (§12): GPU, battery, hwmon / trip points, nvidia-smi and the process list return "not readable" (None) for now, but the data structures and the UI already show them.

## Global Constraints

- No graphics protocol bump: client-core `VERSION` stays as it is. An old device answers `unknown op`, and is then "unsupported", never an error.
- Sample every 5 s; keep 720 points (1 h); in memory only. Budget: on average < 0.5% of one core and < 5 MB resident. No sudo, no extra software, no private APIs. An item that can't be read is left out of the reply, shown as 「—」, and takes no part in headroom.
- The thresholds (spec §6, copied verbatim; they live in exactly one place, `load/rules.rs`):
  - Disk:
    - 注意: free < 10% **and** < 20 GB.
    - 危险: free < 5% **and** < 5 GB; or free < 1 GB.
    - Trend: an ETA ≤ 60 min is 注意; ≤ 15 min is 危险.
    - inode: < 10% is 注意; < 5% is 危险.
  - Memory:
    - 注意: available < 10%, or pressure is warn.
    - 危险: available < 5%, or pressure is critical.
    - Trend: if available has fallen over 10 min and the ETA to 5% is ≤ 30 min, 注意.
  - Heat: 偏热 for ≥ 5 min is 注意; 严重 or 危急 is 危险.
  - CPU or GPU ≥ 90% for 5 min is 注意.
  - Battery, unplugged: ≤ 20% is 注意; ≤ 10% is 危险.
- Trends are a least-squares fit over the last 10 min. A trend only counts when the slope is positive and at least 1 GB or 1% (of total) was used in those 10 min.
- Hysteresis: a level rises at once. It falls only after a full 1 min back inside the line.
- Headroom = min over the items that can be read, × 100, rounded. Each item's share:
  - CPU and GPU: 1 − avg over the last 1 min.
  - Memory: avail / total.
  - Disk: tightest free fraction / 0.20, capped at 1.
  - Heat: normal 1, 偏热 0.6, 严重 0.3, 危急 0.
  - Battery: 1 when plugged in, else pct / 50, capped at 1.
  - Tightest = the item with the smallest share. A tie goes to the first in the order cpu, gpu, mem, disk, heat, battery.
  - **Colour comes from the warning level, never from headroom.**
- Working disks are the disks holding:
  - the foreground cwd of every rapp text terminal,
  - `State.home`,
  - the update cache dir,
  - the home dir.
  A disk with the same `st_dev` counts once. Each disk is read on its own, with a 2 s timeout; a timeout marks that disk `unreadable` for this sample.
- Never kill processes or delete files. The actions are 看在这块盘上的终端 / 看占用最多的进程 / 到 <设备> 上新建终端 / 1小时内不再提醒.
- Copy (verbatim):
  - Rows and labels: 「余力」, 「注意」, 「危险」, 「正常」, 「偏热」, 「严重」, 「危急」, 「读不到」.
  - Actions: 「看在这块盘上的终端」, 「看占用最多的进程」, 「到 <name> 上新建终端」, 「1小时内不再提醒」.
  - CLI: 「不在线」, 「版本太旧，不支持」.
- Tests:
  - Rust: `export PATH=$HOME/.cargo/bin:$PATH; cargo test --workspace --no-fail-fast`. Protocol fields need testkit. The 2 `linux_detach_test` failures predate this work.
  - Clippy: `cargo clippy --workspace --all-targets -- -D warnings`.
  - Flutter is at `~/development/flutter/bin/flutter` (`analyze` + `test`). Run `git checkout gui/pubspec.lock` after every flutter run.
  - `grep` is ugrep: use `/usr/bin/grep` or `git grep`.
- Do not change versions, tag, push or release (CLAUDE.md). Merge into the local `main` only at the end, as CLAUDE.md says.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A device that goes offline must not keep showing its last numbers** (spec §7: no stale numbers). The hub emits `{"event":"load","id":..,"gone":true}` when it stops a watch, and the GUI drops that device's load. → Task 5 test `offline_host_load_is_gone`; Task 7 test `load_row_hidden_when_gone`.
2. **A hung network mount among the working paths must not stall the sampler.** The other items still arrive every tick, and that disk shows 读不到. → Task 3 test `hung_disk_is_unreadable_and_others_still_come`.
3. **An old peer that says `unknown op`** is unsupported. The hub must not retry it every 30 s or log it as a failure, the GUI hides the row, and the CLI says 版本太旧，不支持. → Task 5 test `old_host_is_unsupported_once`; Task 6 test `old_device_row`.
4. **A value sitting right on a threshold, flapping each sample, must not flap the level** or the 需要你 row: one rise, then no fall until a full minute inside. → Task 1 test `flapping_disk_rises_once_and_holds`.
5. **The iOS own column** (no service) shows no load row, and the iOS app must not try an IPC load stream. → Task 7 test `ios_local_column_has_no_load_row`.

Ruling recorded for the builder: spec §10 says an unsupported device is "asked again after 10 min, like `Watch::Unsupported`". But terms' `Unsupported` is never re-asked while the host stays online. Copy terms' behaviour as it is: an upgrade restarts that device's service, so it goes offline and back online, and is asked again then.

---

### Task 1: Load data model, ring and rules (pure)

**Files:**
- Create: `rust/service/src/load/mod.rs` (module root; `pub use` of the types below)
- Create: `rust/service/src/load/sample.rs` (types + `Sampler` trait + `FakeSampler`)
- Create: `rust/service/src/load/rules.rs` (ring, levels, trends, headroom, snapshot JSON)
- Modify: `rust/service/src/lib.rs` (add `pub mod load;`)

**Interfaces:**
- Produces, in `sample.rs`:
  ```rust
  #[derive(Clone, Debug, Default, PartialEq)]
  pub struct Sample { pub at: u64 /*unix s*/, pub cpu: Option<Cpu>, pub gpu: Option<f32>, pub mem: Option<Mem>,
                      pub heat: Option<Heat>, pub disks: Vec<Disk>, pub battery: Option<Battery> }
  pub struct Cpu { pub pct: f32, pub cores: u32, pub load1: Option<f32> }
  pub struct Mem { pub total: u64, pub avail: u64, pub swap_used: Option<u64>, pub pressure: Option<Pressure> }
  pub enum Pressure { Normal, Warn, Critical }               // serde "normal"|"warn"|"critical"
  pub struct Heat { pub level: HeatLevel, pub celsius: Option<f32> }
  pub enum HeatLevel { Normal, Hot, Serious, Critical }      // serde "normal"|"hot"|"serious"|"critical"
  pub struct Disk { pub dev: u64, pub mount: String, pub total: u64, pub avail: u64,
                    pub files: Option<(u64, u64)> /*total, free*/, pub paths: Vec<Covered>, pub unreadable: bool }
  pub struct Covered { pub kind: CoverKind, pub path: String, pub term: Option<String> }
  pub enum CoverKind { Term, Data, Cache, Home }             // serde "term"|"data"|"cache"|"home"
  pub struct Battery { pub pct: f32, pub plugged: bool }
  /// Blocking; called off the runtime. `disks` are filled by `load::disks`, not here.
  pub trait Sampler: Send + 'static { fn sample(&mut self) -> Sample; fn top(&mut self) -> Option<serde_json::Value> { None } }
  pub struct FakeSampler(pub std::sync::Arc<std::sync::Mutex<Sample>>); // returns a clone of what the test set
  ```
- Produces, in `rules.rs`:
  ```rust
  pub const KEEP: usize = 720;
  #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)] pub enum Level { Normal, Warn, Danger } // serde "normal"|"warn"|"danger"
  pub struct Warning { pub item: String, pub level: Level, pub text: String, pub eta_min: Option<u64> }
  pub struct History { /* VecDeque<Sample> capped at KEEP + per-item hysteresis state */ }
  impl History {
      pub fn new() -> Self;
      pub fn push(&mut self, s: Sample);                  // drops the oldest past KEEP, then re-evaluates levels
      pub fn warnings(&self) -> Vec<Warning>;             // items above Normal after hysteresis, Danger first
      pub fn headroom(&self) -> Option<(u8, &'static str)>; // (0..=100, tightest item name); None before any sample
      pub fn snapshot(&self, term: bool) -> serde_json::Value; // the `load` reply body without ok/history
      pub fn history_json(&self) -> serde_json::Value;    // array of points
      pub fn point_json(&self) -> serde_json::Value;      // the newest point
  }
  ```
- Item keys (stable, used by the GUI snooze and the 需要你 targets): `cpu`, `gpu`, `mem`, `heat`, `battery`, `disk:<mount>`, `inode:<mount>`. A disk trend raises the `disk:<mount>` item; it is not a separate key.
- Snapshot JSON (Task 4 adds `ok` and the optional fields):
  ```json
  {"at":1764100000,"headroom":58,"tightest":"disk","term":true,
   "items":{"cpu":{"pct":42.0,"cores":8,"load1":3.1},"mem":{"total":..,"avail":..,"swap_used":..,"pressure":"normal"},
            "heat":{"level":"normal"}},
   "disks":[{"mount":"/","total":..,"avail":..,"inode_free_pct":31.0,"eta_min":40,"level":"warn",
             "paths":[{"kind":"term","path":"/Users/x/git/rapp","term":"<id>"},{"kind":"home","path":"/Users/x"}]}],
   "warnings":[{"item":"disk:/","level":"warn","text":"磁盘约 40 分钟后写满（/，剩 6%，含 ~/git/rapp）","eta_min":40}]}
  ```
  - Fields for items that can't be read are left out (not `null`). A disk with `unreadable: true` has only `mount`, `paths` and `"unreadable":true`.
  - A point is `{"at","cpu"?,"gpu"?,"mem"? /*avail fraction*/,"heat"? /*0..3*/,"disk"? /*tightest free fraction*/}`.
- Warning texts, exact, without the device name (the GUI adds it):
  - Disk:
    - 「磁盘约 N 分钟后写满（<mount>，剩 P%，含 <path>）」
    - 「磁盘只剩 X GB（<mount>，剩 P%，含 <path>）」
    - `<path>`: the first `term` path on that disk, else the first other covered path, with the home prefix written `~`. Leave out 「，含 <path>」 when the disk covers no path.
    - P is the free % rounded to a whole number; X is GB with one decimal.
    - 「inode 只剩 P%（<mount>）」
  - Memory:
    - 「内存只剩 P%」
    - 「内存压力高」 (from pressure)
    - 「内存约 N 分钟后用完」
  - Heat:
    - 「偏热已持续 N 分钟」
    - 「过热，系统正在降频」
  - Load:
    - 「CPU 持续 90% 以上」
    - 「GPU 持续 90% 以上」
  - Battery: 「电池只剩 P%，没接电源」.

- [ ] **Step 1: Write the failing tests in `rules.rs` `#[cfg(test)]`.** Build each series with a helper `series(n, every_s, f: impl Fn(usize) -> Sample)`.
  - `disk_and_rule`:
    - A 2 TB disk with 9% free (180 GB) is Normal.
    - A 100 GB disk with 9% free is Warn.
    - 4% and 4 GB is Danger.
    - A 2 TB disk with 0.9 GB free is Danger.
  - `disk_trend_needs_a_real_fill`:
    - Losing 2 GB per 10 min on a disk with 10 GB free gives `eta_min == Some(50)` and Warn.
    - Losing 0.5 GB over 10 min on a 2 TB disk (< 1 GB and < 1%) gives no ETA and Normal.
    - 15 GB per 10 min with 20 GB free → Danger (ETA ≤ 15).
  - `inode_levels`: 9% free → Warn; 4% → Danger.
  - `memory_levels`:
    - avail 9% → Warn; 4% → Danger.
    - Pressure Warn with avail 50% → Warn; Critical → Danger.
    - Falling 1% per minute from 30% over 10 min gives an ETA of 25 min → Warn, with the text 「内存约 25 分钟后用完」.
  - `cpu_sustained_five_minutes`:
    - 95% for 4 min 55 s → Normal.
    - At 5 min → Warn.
    - One 50% sample in between restarts the 5 min.
  - `heat_levels`:
    - Hot for 4 min → Normal; Hot for 5 min → Warn.
    - Serious → Danger at once.
  - `battery_levels`:
    - Unplugged: 19% → Warn, 9% → Danger.
    - Plugged in at 5% → Normal.
  - `flapping_disk_rises_once_and_holds`: the free % alternates 9.9 / 10.1 (on a 100 GB disk) every sample for 3 min. It is Warn from the first 9.9 and stays Warn; it only drops to Normal after 12 straight samples (1 min) at 10.1+.
  - `danger_falls_to_warn_after_a_minute`: Danger, then back in the Warn band. It stays Danger for 1 min, then becomes Warn.
  - `headroom_min_and_tightest`:
    - cpu avg 0.42 → 0.58; mem 0.25; disk 6% → 0.3; heat Hot → 0.6. The result is `(25, "mem")`.
    - With mem None, the result is `(30, "disk")`.
    - With every item None, the result is None.
  - `ring_is_capped`: push 2000 samples; `history_json().as_array().len() == 720`.
  - `snapshot_shape`: `assert_eq!` against the whole JSON of the example above for one fixed sample. That covers left-out fields and the unreadable disk.

- [ ] **Step 2: Run and see it fail.**
  Run: `cargo test -p rapp-service load:: 2>&1 | tail -5`
  Expected: compile errors (no `load` module).

- [ ] **Step 3: Implement `sample.rs` and `rules.rs`.**
  - Hysteresis state lives per item key: `(level, back_inside_since: Option<u64>)`.
  - Raw level = max(threshold level, trend level).
  - Rises take effect at once. A fall takes effect when `at - back_inside_since >= 60`.
  - "Sustained" checks scan the ring backwards by `at`, not by count, so a test can use any interval.
  - The trend is a least-squares slope over the samples with `at >= now - 600`, and needs ≥ 2 samples spanning ≥ 300 s. ETA (min) = remaining / slope, rounded up.
  - Disk items are keyed by mount. When a disk disappears from the sample, its state is dropped.

- [ ] **Step 4: Run and see it pass.**
  Run: `cargo test -p rapp-service load::`
  Expected: all pass.

- [ ] **Step 5: Commit.** `feat(load): 采样数据结构、1 小时环形缓冲和警告规则`

### Task 2: First-version collectors (macOS and Linux)

**Files:**
- Create: `rust/service/src/load/mac.rs` (`#[cfg(target_os = "macos")]`)
- Create: `rust/service/src/load/linux.rs` (`#[cfg(target_os = "linux")]`; parsers `pub(crate)` and `cfg(any(test, target_os="linux"))` so they are tested on macOS too)
- Modify: `rust/service/Cargo.toml` (move `libc = "0.2"` to the plain `[dependencies]`)
- Modify: `rust/service/src/load/mod.rs` (`pub fn system_sampler() -> Box<dyn Sampler>`)

**Interfaces:**
- Consumes: the Task 1 types.
- Produces: `pub fn system_sampler() -> Box<dyn Sampler>`. On macOS it is `MacSampler`; on Linux, `LinuxSampler`; on any other OS, a sampler that returns `Sample { at, ..Default::default() }`.
- Pure, tested functions:
  - `linux::cpu_pct(prev: &[u64], now: &[u64]) -> Option<f32>`: from the `/proc/stat` `cpu` line fields. idle = idle + iowait.
  - `linux::parse_stat(text) -> Option<(Vec<u64>, u32 /*cores = cpuN lines*/)>`.
  - `linux::parse_loadavg(text) -> Option<f32>`.
  - `linux::parse_meminfo(text) -> Option<Mem>`: MemTotal, MemAvailable, SwapTotal − SwapFree, all in kB × 1024. `pressure: None`.
  - `linux::heat_from_zones(dir: &Path) -> Option<Heat>`: the maximum of `thermal_zone*/temp` (millidegrees). Below 80 °C is Normal, 80 is Hot, 90 is Serious, 95 is Critical. `celsius` is set.
  - `mac::pressure_from(level: i32) -> Option<Pressure>`: 1 Normal, 2 Warn, 4 Critical, anything else None.
  - `mac::heat_from_notify(state: u64) -> HeatLevel`: 0 Normal, 1 Hot, 2 Serious, 3 or more Critical.
  - `mac::cpu_pct(prev: &[[u32; 4]], now: &[[u32; 4]]) -> Option<f32>`: per-CPU ticks user/system/idle/nice.
  - `mac::avail_bytes(free, inactive, purgeable, speculative, page) -> u64`: (free + inactive + purgeable + speculative) × page.

- [ ] **Step 1: Write the failing parser tests.**
  - `linux.rs`: tests use fixed text and a tempdir `thermal_zone0/temp=45000`, `thermal_zone1/temp=91000`, which gives Serious and 91.0.
  - The first CPU sample (no prev) gives `pct` None, so `cpu` is None; the second gives a value.
  - `mac.rs`: the mapping and arithmetic tests above.

- [ ] **Step 2: Run and see them fail.**
  Run: `cargo test -p rapp-service load::`
  Expected: compile errors for the missing functions.

- [ ] **Step 3: Implement.**
  - macOS:
    - `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` with `#[allow(deprecated)] mach_host_self()`. `vm_deallocate` the returned array.
    - `host_statistics64(HOST_VM_INFO64)` gives available; `sysctlbyname("hw.memsize")` gives total; `vm.swapusage` gives swap; `kern.memorystatus_vm_pressure_level` gives pressure.
    - Heat: our own `extern "C"` for `notify_register_check` and `notify_get_state` on the key `"com.apple.system.thermalpressurelevel"`, registered once and kept in the sampler.
    - `getloadavg` gives load1.
  - Linux: read `/proc/stat`, `/proc/loadavg`, `/proc/meminfo` and `/sys/class/thermal`.
  - Both keep the previous CPU ticks in the sampler. GPU and battery stay None (spec §12).

- [ ] **Step 4: Run and see them pass, then smoke-test on this Mac.**
  Run: `cargo test -p rapp-service load::`
  Expected: pass.
  Add a test `#[ignore] system_sampler_reads_something`: the second `sample()` has `cpu` and `mem` Some, and on macOS `heat` Some.
  Run it once with `-- --ignored`. Expected: pass.

- [ ] **Step 5: Commit.** `feat(load): macOS / Linux 第一版采集（CPU、内存、热度）`

### Task 3: Working disks and the sampler task

**Files:**
- Create: `rust/service/src/load/disks.rs`
- Create: `rust/service/src/load/task.rs`
- Modify: `rust/service/src/state.rs` (`pub load: Option<crate::load::Load>`)
- Modify: `rust/service/src/lib.rs`:
  - add `pub load: Option<LoadOpts>` to `Opts`;
  - add the sampler task to `tasks`;
  - re-export `LoadOpts`.
- Modify: `rust/service/src/main.rs` (`load: Some(LoadOpts::system())`)
- Modify: every `rapp_service::Opts { .. }` in `rust/testkit/tests/{common/mod.rs, hub.rs, service.rs}`. Use `load: Some(common::fake_load())`, a new helper there. It is steady: cpu 10%, mem 50% of 16 GB, heat Normal, every 200 ms.

**Interfaces:**
- Consumes: Task 1 `History`, `Sample`, `Sampler`; Task 2 `system_sampler`.
- Produces:
  ```rust
  pub struct LoadOpts { pub every: Duration, pub sampler: Arc<dyn Fn() -> Box<dyn Sampler> + Send + Sync>, pub disk_wait: Duration }
  impl LoadOpts { pub fn system() -> Self /* 5 s, system_sampler, 2 s */ }
  pub struct Load { pub hist: Mutex<History>, pub tick: watch::Sender<u64>, /* top request channel */ }
  // disks.rs
  pub async fn read(paths: Vec<Covered>, wait: Duration) -> Vec<Disk>; // groups by st_dev, one spawn_blocking per disk, timeout → unreadable
  pub fn mount_of(path: &Path) -> Option<(u64 /*dev*/, PathBuf /*mount*/)>; // walks up parents while st_dev is the same
  pub fn statvfs(path: &Path) -> Option<(u64, u64, Option<(u64, u64)>)>;   // total, avail, (files, ffree)
  // task.rs
  pub async fn run(state: Arc<State>);  // spawned when state.load is Some
  pub(crate) async fn covered(state: &State) -> Vec<Covered>;
  ```
- `covered()` returns:
  - `Data` for `state.home`;
  - `Home` for `$HOME`;
  - `Cache` for `update_opts.cache_dir`, when set;
  - one `Term` per terminal, from `rapp_term::pty::local::{token, scan}(&state.home.join("term"))`, using `Status.cwd`, with `term` = the row id the GUI uses (`rapp_term::serve::pty_id(&status)`, already `pub`).
  The terminal scan runs at most every 30 s; the last result is cached in between. It never starts the rapp-term worker.

- [ ] **Step 1: Write the failing tests.**
  - `disks.rs`:
    - `same_disk_counts_once`: two tempdir subpaths give 1 disk with 2 `paths`.
    - `hung_disk_is_unreadable_and_others_still_come`: inject the reader. `read_with(paths, wait, f)`, where `f` sleeps 5 s for one path; with `wait` = 100 ms that disk is `unreadable` and the other is filled, all within 1 s. `read` = `read_with(.., statvfs)`.
  - `task.rs`: `sampler_pushes_every_tick`. A `State` built by the existing service test helper, or a testkit service with `fake_load()`: after 1 s, `hist.history_json()` has ≥ 3 points, and `tick` moved.

- [ ] **Step 2: Run and see them fail.**
  Run: `cargo test -p rapp-service load::`
  Expected: compile errors.

- [ ] **Step 3: Implement.**
  - Each tick:
    1. `spawn_blocking` the sampler, moving the `Box` in and back out.
    2. `disks::read(covered)`.
    3. Set `sample.disks`.
    4. `hist.lock().push`.
    5. `tick.send_modify(+1)`.
  - Use `tokio::time::interval` with `MissedTickBehavior::Skip`.
  - A sampler panic is logged once, and the task goes on.

- [ ] **Step 4: Run and see them pass.**
  Run: `cargo test --workspace --no-fail-fast 2>&1 | tail -20`
  Expected: all pass (apart from the known `linux_detach_test` pair).

- [ ] **Step 5: Commit.** `feat(load): 工作盘和采样任务`

### Task 4: `load` / `watch_load` on the wire, peer and IPC

**Files:**
- Modify: `rust/net/src/msg.rs`:
  - `Op::Load { #[serde(default, skip_serializing_if = "std::ops::Not::not")] history: bool, #[serde(default, skip_serializing_if = "std::ops::Not::not")] top: bool }`;
  - `Op::WatchLoad`.
- Create: `rust/service/src/load/serve.rs`
- Modify: `rust/service/src/peer.rs` (two match arms, allowed for exactly the connections that may `list_apps` (spec §10); with `state.load` None → `unknown op`)
- Modify: `rust/service/src/ipc.rs`:
  - `"load"` and `"load_all"` → replies;
  - `"watch_load"` takes over the connection, like `pipe`.
- Modify: `rust/service/src/ipc.rs` `in_history`: leave out `watch_load` and `load` requests, as is done for `watch_terms`.
- Test: `rust/testkit/tests/load.rs` (new)

**Interfaces:**
- Consumes: Task 3 `Load`, `History::{snapshot, history_json, point_json}`.
- Produces:
  - `serve::reply(state, history: bool, top: bool) -> Value`:
    - `{"ok":true, ..snapshot}`, plus `"history":[..]` when asked;
    - `"top":{"cpu":[..],"mem":[..]}` only when the sampler gave one (none in the first version);
    - `{"ok":false,"error":"no data"}` before the first sample.
  - `serve::follow(state, &mut s)`:
    - The first line is `reply(true, false)`.
    - Then, on each `tick`, a line `{"ok":true, ..snapshot, "point":{..}}`.
    - It ends when the other side closes (the read pattern of `term.rs` `follow`).
  - IPC `{"cmd":"load","history"?,"top"?}` is the same as `reply`.
  - IPC `{"cmd":"load_all","devices"?:[names],"top"?}`:
    - It replies `{"ok":true,"devices":[{"id","name","local":true,"load":{..}}, {"id","name","load":{..}} | {"id","name","error":"offline"|"old version"|..}]}`.
    - The local device comes first. Each one in `crate::pipe::known_hosts(&state.home)` is asked with `Op::Load{history:false,top}` at the same time, under `HOSTS_WAIT`.
    - Add `pub async fn load_of(state, name, top) -> Result<Value, PipeErr>` to `pipe.rs`, next to `shares_of`.
    - When `devices` is given, keep only those whose id or name matches, case-insensitive; the local device matches its own name or id.
  - `snapshot.term` = this device's text terminals are usable: `crate::term::allowed(state).is_ok()` (make `allowed` `pub(crate)`).

- [ ] **Step 1: Write the failing tests.**
  - `msg.rs` `load_requests`:
    - `to_value(Op::Load{history:false,top:false}) == json!({"op":"load"})`;
    - `Op::Load{history:true,top:false}` → `{"op":"load","history":true}`;
    - `WatchLoad` → `{"op":"watch_load"}`.
  - `testkit/tests/load.rs`:
    - `load_answers_a_snapshot`: a peer `load` on a `fake_load()` service. Compare the whole JSON with `at` overwritten, and `headroom == 50`, `tightest == "mem"`.
    - `load_with_history`: has `history`, an array of ≥ 1.
    - `watch_load_streams_points`: the first line has `history`; the next two lines each have `point`, and their `at` values rise.
    - `load_is_unknown_without_load_opts`: with `load: None` the reply is `{"ok":false,"error":"unknown op"}`.
    - `ipc_load_all_lists_local_first`: one service, no hosts.json. It gives `devices.len() == 1` and `devices[0].local == true`.
    - `ipc_load_all_marks_old_device`: B has `load: None` and is in A's hosts.json. Its row is `"error":"old version"`.

- [ ] **Step 2: Run and see them fail.**
  Run: `cargo test -p rapp-net load_requests; cargo test -p rapp-testkit --test load`
  Expected: fail (unknown variants, `unknown op`).

- [ ] **Step 3: Implement.** Use the peer arms' existing `reply_and_finish`. `watch_load` follows `term.rs`'s streaming shape. Neither is logged with `log_request` on success; it's polled, like `ping`.

- [ ] **Step 4: Run and see them pass.**
  Run: `cargo test --workspace --no-fail-fast 2>&1 | tail -20`
  Expected: pass. Update any whole-JSON testkit assertion that changed.

- [ ] **Step 5: Commit.** `feat(load): load / watch_load 请求（设备之间和本机 IPC）`

### Task 5: Hub watches and `load` events

**Files:**
- Create: `rust/hub/src/load.rs`
- Modify: `rust/hub/src/lib.rs`:
  - `mod load;`;
  - `Hub.load: load::Watches`;
  - dispatch `Some("load") => load::command(self, v).await?`.
- Modify: `rust/hub/src/presence.rs` (next to `terms::stop_gone`, `ensure_watch` and `stop_watch`, at lines 45/58/60)
- Modify: `rust/hub/src/watch.rs:96` (next to `terms::ensure_watch`)
- Test: `rust/testkit/tests/hub_load.rs` (new; model it on `hub_terms.rs`)

**Interfaces:**
- Consumes: `Op::WatchLoad`, `Op::Load` (Task 4); `hub.request`, `hub.emit`, `read_json`, `check`. These are the same helpers `terms.rs` uses.
- Produces:
  - `ensure_watch(hub, host)`, `stop_watch(hub, id)` and `stop_gone(hub, hosts)`, with the same retry and Unsupported state machine as `terms.rs`. Reuse `terms::{after_end, ended, due}` by making them `pub(crate)`; do not copy them.
  - Events:
    - `{"event":"load","id":<id>, ..line}` for each stream line, with `history` on the first and `point` on later ones;
    - `{"event":"load","id":<id>,"gone":true}` when a watch stops because the host went offline or was removed;
    - `{"event":"load","id":<id>,"unsupported":true}` once, when the host said `unknown op`.
  - `{"cmd":"load","id":..,"top"?:bool,"req":n}` → `{"event":"load","req":n, ..reply}`, the one-shot `Op::Load{history:false, top}`.

- [ ] **Step 1: Write the failing tests in `hub_load.rs`.**
  - `hub_streams_load_events`: a presence hub with one `fake_load()` host. The first `load` event for its id has `history`, and the next one has `point`.
  - `offline_host_load_is_gone`: stop the host's service. A `{"event":"load","gone":true}` arrives for its id within `WAIT`.
  - `old_host_is_unsupported_once`: a host with `load: None`. Exactly one `unsupported` event in 3 s, and no second `watch_load` request in the host's log over that time.
  - `load_cmd_answers_one_shot`: the `req` is echoed, and `headroom` is present.

- [ ] **Step 2: Run and see them fail.**
  Run: `cargo test -p rapp-testkit --test hub_load`
  Expected: fail.

- [ ] **Step 3: Implement**, mirroring `terms.rs` (`QUIET.scope`, RETRY_FIRST, RETRY_MAX). The events of a watch line carry no `req`; make sure `hub_client` routing in Task 7 treats them like `terms`.

- [ ] **Step 4: Run and see them pass.**
  Run: `cargo test --workspace --no-fail-fast 2>&1 | tail -20`
  Expected: pass.

- [ ] **Step 5: Commit.** `feat(hub): 每台在线设备一条 watch_load，转成 load 事件`

### Task 6: `rapp load` and `rapp load pick`

**Files:**
- Modify: `rust/cli/src/args.rs`:
  - `Cmd::Load { devices: Vec<String>, top: bool, json: bool }`;
  - `Cmd::LoadPick { json: bool }`;
  - USAGE lines, copied from spec §9.
- Create: `rust/cli/src/load.rs` (`run(cmd)`, plus the pure `table(&Value) -> String`, `pick(&Value) -> Option<Value>`, `reason(&Value) -> String`)
- Modify: `rust/cli/src/main.rs` (`mod load;`, dispatch)
- Modify: `rust/cli/src/out.rs` (`"no_device" => 4`; `"offline"` is already 4, so keep both)
- Modify: `README.md` (in 「给 agent 的说明」 add the two commands, one line each, and the `--json` field list)
- Modify: the spec, `docs/superpowers/specs/2026-11-26-rapp-device-load-design.md`: add an 附录 with the `--json` fields (spec §9 asks for it)

**Interfaces:**
- Consumes: the IPC `load_all` reply from Task 4.
- Produces:
  - `pick(reply) -> Option<Value>` = `{id, name, headroom, tightest, reason}`.
    - It chooses among devices that have a `load`, where `load.term == true` and no warning is `danger`.
    - The highest `headroom` wins; on a tie, the lower `items.cpu.pct` (missing counts as 100).
    - Then the earlier in the list.
  - `reason` reads like 「余力 72，最紧的是内存（剩 41%）」.
  - The `--json` output:
    - `rapp load --json` → `{"ok":true,"devices":[..as from the service..]}`;
    - `rapp load pick --json` → `{"ok":true,"id","name","headroom","tightest","reason"}`;
    - none suitable → `out.fail("no_device", "没有合适的设备", None)`, exit 4.

- [ ] **Step 1: Write the failing tests.**
  - `args.rs`:
    - `p("load")` → `Load{devices:[],top:false,json:false}`;
    - `p("load mini gpu1 --top --json")`;
    - `p("load pick --json")` → `LoadPick{json:true}`;
    - `p("load pick mini")` → Err 「多写了：mini」;
    - `p("load --bad")` → Err 「不认识的选项：--bad」.
  - `load.rs`:
    - `table_rows`: a reply with one local device, one offline device and one old device. The exact text has the columns 设备 / 余力 / CPU / GPU / 内存 / 热度 / 最紧的盘 / 警告; 「—」 for what can't be read; 「不在线」; 「版本太旧，不支持」.
    - `pick_skips_danger_and_no_term`, `pick_tie_goes_to_lower_cpu`, `pick_none_is_none`.
    - `old_device_row`: `{"error":"old version"}` → 「版本太旧，不支持」.
    - `codes_map_to_exits`: extend it with `("no_device", 4)`.

- [ ] **Step 2: Run and see them fail.**
  Run: `cargo test -p rapp-cli`
  Expected: fail.

- [ ] **Step 3: Implement.** Use `say.rs`'s `columns` and `plain`; make them `pub(crate)`. Everything another device sent goes through `plain`.

- [ ] **Step 4: Run and see them pass, then try it by hand.**
  Run: `cargo test -p rapp-cli`
  Expected: pass.
  Run: `cargo run -p rapp-cli -- load` against the running service on this Mac.
  Expected: either `本机的 rApp 服务没有在运行` (exit 3), or a 「版本太旧，不支持」 row for the installed old service. Both are correct before release.

- [ ] **Step 5: Commit.** `feat(cli): rapp load / rapp load pick`

### Task 7: GUI model, local stream and the headroom row with detail

**Files:**
- Create: `gui/lib/load_model.dart` (pure Dart)
- Modify: `gui/lib/hub_client.dart`:
  - `final Map<String, DeviceLoad> loads`;
  - `case 'load':` in the event switch;
  - route `load` like `terms` (no `req` → no `_take`);
  - `Future<Map> loadNow(String id, {bool top = false})`.
- Modify: `gui/lib/service_client.dart` `ServiceMonitor`: `DeviceLoad? load`. A dedicated connection sends `{"cmd":"watch_load"}`, reconnects with the others, and is not started on iOS.
- Create: `gui/lib/ui/load_row.dart` (`LoadRow`, `LoadDetail`, `Sparkline` painter)
- Modify: `gui/lib/ui/overview.dart` `_Column` (lines 296-320): add `LoadRow` under the status `Row`.
- Test: `gui/test/load_model_test.dart`, `gui/test/ui/load_row_test.dart`

**Interfaces:**
- Consumes: the hub `load` events (Task 5) and the IPC `watch_load` lines (Task 4). Both have the same shape.
- Produces:
  ```dart
  enum LoadLevel { normal, warn, danger }
  class LoadWarning { final String item; final LoadLevel level; final String text; final int? etaMin; }
  class LoadPoint { final int at; final double? cpu, gpu, mem, disk; final int? heat; }
  class DeviceLoad {
    final int at; final int? headroom; final String? tightest; final bool term;
    final Map<String, dynamic> items; final List<Map<String, dynamic>> disks;
    final List<LoadWarning> warnings; final List<LoadPoint> history; // ≤ 720, oldest first
    LoadLevel get level;                       // highest warning level, normal when none
    static DeviceLoad fromJson(Map m);
    DeviceLoad next(Map line);                 // takes the new snapshot, appends line['point'], caps 720
  }
  String tightestWord(DeviceLoad l);           // 「磁盘 剩 6%」「CPU 42%」「内存 剩 25%」「热度 偏热」; '—' when null
  String? pickDevice(Map<String, DeviceLoad> loads, Set<String> online); // same rule as Task 6 `pick`
  ```
  - `HubClient.loads[id]`: set by the first line, advanced by `next`, **removed** on `gone` or `unsupported`, and cleared on `home_set`.
- `LoadRow(load: DeviceLoad?)`:
  - It renders nothing (`SizedBox.shrink`) when `load` is null.
  - Otherwise: 「余力」, a 10-segment bar `Key('load-bar-<id>')`, and `tightestWord`.
  - Text colour: normal → `t.muted`, warn → the theme's warning orange, danger → the error red. `RappTokens` (gui/lib/ui/tokens.dart) has no warning colours yet: add `warn` (orange) and `danger` (red) to it, with light and dark values, and use only those.
  - Tap opens `LoadDetail` as a popup anchored under the row. It shows each item's line and value, plus a `Sparkline` of the history, one row per disk with its covered paths, and a 「看占用最多的进程」 section that calls `loadNow(top:true)`. It shows 「读不到」 when `top` is missing, as in the first version.
- `_Column` gets its load from:
  - `hub.loads[id]` when `id != null && !col.offline`;
  - `monitor?.load` for the local column on macOS / Linux;
  - nothing on iOS.

- [ ] **Step 1: Write the failing tests.**
  - `load_model_test.dart`:
    - `fromJson` of the Task 1 example snapshot.
    - `next` appends a point and caps at 720.
    - `level` follows the warnings.
    - `tightestWord` for disk, cpu and null.
    - `pickDevice` uses the Task 6 cases: danger skipped, `term:false` skipped, tie to lower cpu, offline excluded.
  - `hub_client_test.dart`: `load` events fill `loads`; `gone` removes; `unsupported` removes; a `load` line without `req` does not complete another pending request.
  - `ui/load_row_test.dart`:
    - `load_row_three_colours`: normal / warn / danger text colours.
    - `load_row_hidden_when_gone`: an overview with an online host and a load shows `load-bar-<id>`; after a `gone` event it is absent.
    - `load_row_hidden_offline`: the same with `col.offline`.
    - `ios_local_column_has_no_load_row`: with the iOS platform helper (`platform_helpers.dart`), the local column has no `load-bar-local`, and `ServiceMonitor` never sent `watch_load`.
    - `load_detail_opens`: a tap shows the disk mount and 「看占用最多的进程」.

- [ ] **Step 2: Run and see them fail.**
  Run: `~/development/flutter/bin/flutter test test/load_model_test.dart test/ui/load_row_test.dart test/hub_client_test.dart` (from `gui/`)
  Expected: fail.

- [ ] **Step 3: Implement.** The `Sparkline` is a `CustomPainter`, drawn in `t.muted`. A segment above its threshold uses the warning colour; the thresholds come from the warning list, not from Dart rules (spec §6: the UI does not recompute).

- [ ] **Step 4: Run and see them pass.**
  Run: `~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test; git checkout pubspec.lock`
  Expected: no issues; all pass.

- [ ] **Step 5: Commit.** `feat(gui): 设备列余力行和明细`

### Task 8: 需要你, hints, actions and snooze

**Files:**
- Modify: `gui/lib/ui/main_state.dart`:
  - `NeedKind.resource`;
  - add rows in `needs`;
  - level-rise hints;
  - `goToNeed` case;
  - `snoozeLoad(device, item, level)`.
- Modify: `gui/lib/ui/needs_you.dart`: the resource row buttons.
- Modify: `gui/lib/ui/prefs.dart` `UiPrefs`: `Map<String, String> loadSnooze` (key `"<device>\n<item>"`, value `"<untilMs> <level>"`), saved in `gui.json` as `load_snooze`.
- Test: `gui/test/ui/main_state_test.dart`, `gui/test/ui/prefs_test.dart`, `gui/test/ui/needs_you_test.dart` (create it if there is none; otherwise use the existing needs test file)

**Interfaces:**
- Consumes: `HubClient.loads`, `ServiceMonitor.load`, `pickDevice` and `DeviceLoad.warnings` (Task 7); the existing `hint` setter, `openOrSwitch(device, target, title)`, `showDevice(id)` and `openText(id)` (main_state.dart ~:2877, the path 「新建」 uses: `open_term` without `from`; its failure goes to the hint through `newTermWords`).
- Produces:
  - `NeedItem(NeedKind.resource, '<device>\n<item>', '<deviceName> <warning.text>', seq, device: id, title: item)`: one per warning that isn't snoozed, for an online device. The local device uses its own id from `ServiceMonitor.status`.
  - Snoozed means `now < until && level <= snoozedLevel`. Danger after a Warn snooze shows again.
  - Hint: `'<deviceName> <text>'` when an item's level rises (normal→warn, normal→danger, warn→danger), compared with the previous load of the same device. It is not shown while snoozed, and not on the first load after a device appears.
  - Buttons, by item:
    - `disk:*` → 「看在这块盘上的终端」. It opens a small menu of the terminals whose `paths` kind is `term` on that disk; picking one does `openOrSwitch(device, term, title)`.
    - `cpu`, `gpu`, `mem`, `heat` →
      - 「看占用最多的进程」 (opens `LoadDetail` for that device);
      - 「到 <name> 上新建终端」 → `openText(<best>)`, where `<best>` = `pickDevice` excluding this device, and the button is hidden when there is none.
    - `battery` → none.
    - Every row has 「1小时内不再提醒」 → `snoozeLoad`.
  - The row tap (`goToNeed`) goes to `showDevice(device)`.

- [ ] **Step 1: Write the failing tests.**
  - `resource_need_rows`: a host load with a warn `disk:/` gives one `NeedKind.resource` row with the text 「<name> 磁盘约 40 分钟后写满（/，剩 6%，含 ~/git/rapp）」.
  - `snooze_hides_until_danger`: snooze at warn, and the row is gone. The same item at danger brings it back. After 1 h (fake clock), a warn row returns.
  - `snooze_survives_restart`: `UiPrefs` round-trips `load_snooze` through JSON.
  - `hint_on_rise_only`: normal→warn sets `hint`; warn→warn does not; warn→danger does; the first load already in warn does not.
  - `new_term_elsewhere_uses_pick`: two hosts. The button label is 「到 <best> 上新建终端」, and a tap sends `open_term` to `<best>` without `from`.
  - `disk_action_lists_terms_on_that_disk`.
  - `offline_device_has_no_resource_rows`.

- [ ] **Step 2: Run and see them fail.**
  Run: `~/development/flutter/bin/flutter test test/ui/main_state_test.dart test/ui/prefs_test.dart test/ui/needs_you_test.dart`
  Expected: fail.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run the whole gate.**
  Run:
  `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test; git checkout pubspec.lock; cd ../rust && cargo test --workspace --no-fail-fast 2>&1 | tail -20 && cargo clippy --workspace --all-targets -- -D warnings`
  Expected: all green, apart from the known `linux_detach_test` pair.

- [ ] **Step 5: Add the real-machine checks to `tasks/todo.md` under 「设备负载」:**
  1. The local column shows 余力.
  2. A remote Mac and the Linux box show 余力.
  3. A disk filled to < 10% and < 20 GB goes orange, and 需要你 has the row.
  4. 「1小时内不再提醒」 hides it.
  5. 到 <设备> 上新建终端 opens there.
  6. `rapp load` and `rapp load pick --json`.
  7. Service CPU stays under 0.5% in Activity Monitor, and RSS growth is under 5 MB after 1 h.
  8. An old peer shows no row and nothing in the log.

  Commit the GUI work and the todo items together: `feat(gui): 资源警告进需要你，带建议动作和暂不提醒`.
