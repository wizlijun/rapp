# rapp-center G1（改名 + 入口）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `rapp-state` 改名成 `rapp-center`（只改本机看得见的名字），并把它改成「入口 + 内置能力」的结构：`/v1/health` v2、`/v1/routes`、`/state/v1/…` 别名，状态搬成第一块内置能力，行为不变。

**Architecture:** `services/center/src/entry.rs` 是入口：接连接、分派路径、`health`/`routes`/`watch`、通用存盘。每块内置能力实现 `builtin.rs` 里的 `Builtin` trait，在 `builtin::table` 里登记一行；状态的代码搬进 `src/state/`，成为第一块。`rapp-service` 一侧只改随行程序名、`services.json` 的键和数据目录（都兼容旧的）。

**Tech Stack:** Rust（hyper 1.x、tokio、serde_json），Dart/Flutter（只改文字和一个测试），bash/python 打包脚本。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-center-design.md`（§5、§6、§7、§12、§13 G1、§14、§17）

## Global Constraints

- 线上的名字一个都不改：`/v1/health` 的 `name` 仍是 `"rapp-state"`；分享 `kind:"state"`、`StateSink`、`SetService`/IPC 的 `name:"state"`、IPC `{"cmd":"state"}`、发件箱的 `Host: rapp-state` 都不变。`outbox/send.rs` 和 `state_link.dart` 的健康检查**不改**（`name` 不变，它们照样认）。
- 本机名字：程序 `rapp-center`、目录 `services/center/`、crate `rapp-center`、库 `rapp_center`、命令 `rapp center`（`rapp state` 留作别名）、界面「中心服务」、签名标识 `com.rapp.center`。安装包里只带 `rapp-center`。
- `services.json` 的键是 `center`；读到旧键 `state` 当成 `center`；写的时候写 `center`、去掉 `state`。
- 数据目录 `local/center/`：启动时它不存在而 `local/state/` 存在，就 `rename` 过去；改名失败就继续用 `local/state/`，记一行日志。里面的 `state.json` 文件名和内容不动。
- 能力前缀：小写字母、数字、`-`，不能是 `v1`。状态这块的前缀是 `state`，版本 `1`。
- `/state/v1/watch` 不开；watch 只有入口那一条。根下旧路径 `/v1/events|state|queue|seen|desk/<fp>` 永久保留，和 `/state/v1/…` 走同一段代码。
- 不加新依赖（`Builtin::handle` 返回手写的 `Pin<Box<dyn Future…>>`，不用 async-trait）。
- 不改版本号（`gui/pubspec.yaml`、workspace version）。crate 改名会让 `Cargo.lock` 里那一项换名字，这是改名带来的，不是改版本，允许。
- 日志只记数量和种类，不记内容（照今天）。状态这块今天的日志行（`saved`、`save_failed`、`load_failed`、`rejected`、`desk`、`watch_*` 等）字段不变。
- `cargo test` 在 `rust/` 下跑；改了协议字段或服务行为就跑 `cargo test --workspace`（testkit 的集成测试只有这样才跑到）。Flutter 在 `~/development/flutter/bin`，跑完测试把 `gui/pubspec.lock` 还原。grep 用 `/usr/bin/grep`。

## Review Focus

1. **两个数据目录都在**（升级过一次又回滚、或手动拷过）：用 `local/center/`，`local/state/` 原样不动，不合并、不覆盖。→ Task 2 `both_dirs_keep_center`。
2. **`services.json` 里新旧键同时在**：`center` 说了算；下次写时 `state` 被去掉、`center` 里别的字段原样保留。→ Task 2 `center_key_wins_and_old_key_goes_on_write`。
3. **旧键 `state` 的条目是坏的**（`{"state":{"on":"x"}}`）：和今天一样整份当坏文件（`services_json_invalid`），不是悄悄当成关。→ Task 2 `a_bad_old_key_is_still_invalid`。
4. **别名路径带查询串、带 fp**：`/state/v1/queue?limit=1`、`PUT /state/v1/desk/aa` 和根下的回一样的东西。→ Task 4 `aliased_paths_answer_like_the_root`。
5. **奇怪的路径**：`/state`、`/state/`、`/state/v1/watch`、`/STATE/v1/state`、`/nope/v1/x`、`//v1/state` 都是 404 `{"error":"not found"}`，不 panic、不落到状态那块；`POST /v1/routes` 是 405。→ Task 4 `odd_paths_are_404`。

---

### Task 1: 改名 rapp-state → rapp-center（纯改名，行为不变）

**Files:**
- Move: `services/state/` → `services/center/`（`git mv`）
- Modify: `services/center/Cargo.toml`（package `rapp-center`，`[lib] name = "rapp_center"`，`[[bin]] name = "rapp-center"`）
- Modify: `services/center/src/lib.rs`（模块文档、`cli` 的错误文字 `rapp-center 起不来：{e}`）、`src/main.rs`、`tests/http.rs`、`tests/memory.rs`（`use rapp_center::…`）
- Modify: `rust/Cargo.toml` 的 `members`：`"../services/state"` → `"../services/center"`
- Move: `rust/testkit/src/bin/test-rapp-state.rs` → `test-rapp-center.rs`；Modify `rust/testkit/Cargo.toml`（bin `test-rapp-center`，依赖 `rapp-center = { path = "../../services/center" }`）、`rust/testkit/tests/common/mod.rs:45`（`("rapp-center", env!("CARGO_BIN_EXE_test-rapp-center"))`）、`rust/testkit/tests/state_p1.rs:649-670`（`rapp_center::`）
- Modify: `rust/service/src/companion.rs:44`（`program: "rapp-center"`，`note: "中心服务"`；`name: "state"` 不动）
- Modify: `scripts/package-macos.sh`、`scripts/lib/sign-check.sh`（`rapp-center:com.rapp.center`）、`scripts/test-package.sh:56`、`scripts/build-linux.sh`、`scripts/package-linux.sh`、`scripts/test-linux-build.py`、`scripts/test-linux-bundle.py`
- Modify: 只说程序名的注释：`rust/service/src/sink.rs:1`、`shares.rs:109`、`state.rs:109`、`gui/lib/**` 里写着 `rapp-state` 的注释（`rapp.bash` 里的 `_rapp_state` 是别的东西，不动）

**Interfaces:**
- Produces: crate `rapp-center`，库 `rapp_center`（`serve`、`serve_with_log`、`Config`、`Log`、`cli` 签名不变），程序 `rapp-center`；testkit 把它链接成 `<bin_dir>/rapp-center`。

- [ ] **Step 1: 改名并改上面列的所有引用**

`git mv services/state services/center`，`git mv rust/testkit/src/bin/test-rapp-state.rs rust/testkit/src/bin/test-rapp-center.rs`，然后逐个改。

- [ ] **Step 2: 确认没有漏下的旧程序名**

Run: `/usr/bin/grep -rn "rapp-state\|rapp_state\|com\.rapp\.state" --exclude-dir=target --exclude-dir=.dart_tool --exclude-dir=build --exclude-dir=archives rust services scripts gui/lib gui/test`
Expected: 只剩线上名字的出现：`outbox/send.rs` 的 `name == "rapp-state"` 和 `Host: rapp-state`、`state_link.dart` 的 `'rapp-state'`、`services/center/src/http.rs` 健康回复里的 `"rapp-state"`、测试里对它们的断言。别的都没了。

- [ ] **Step 3: 跑测试**

Run: `cd rust && cargo test -p rapp-center && cargo test -p rapp-service companion && cargo test -p rapp-testkit --test state_p1 --test set_service && cd .. && bash scripts/test-package.sh`
Expected: 全过。

- [ ] **Step 4: Commit**

```bash
git add -A services rust scripts gui/lib
git commit -m "refactor(center): rapp-state 改名 rapp-center（线上名字不变）"
```

---

### Task 2: `services.json` 的 `center` 键和 `local/center/` 数据目录

**Files:**
- Modify: `rust/service/src/companion.rs`（`Companion`、`TABLE`、`read_file`、`cfg_in`、`turned`、`args`、`run_once`）
- Test: `rust/service/src/companion.rs` 的 `mod tests`；`rust/testkit/tests/state_p1.rs:201,241,329`、`rust/testkit/tests/set_service.rs:42`

**Interfaces:**
- Consumes: Task 1 的 `TABLE[0].program == "rapp-center"`。
- Produces:
  - `Companion` 加两个字段：`key: &'static str`（`services.json` 的键，`"center"`）和 `old_key: Option<&'static str>`（`Some("state")`）。`name` 仍是 IPC 和分享用的 `"state"`。
  - `fn cfg_in(map: &Map<String, Value>, c: &Companion) -> ServiceCfg`：先找 `c.key`，没有再找 `c.old_key`。
  - `fn turned(map: Map<String, Value>, c: &Companion, on: bool) -> Map<String, Value>`：改的是 `c.key` 那一项（没有就从 `old_key` 那项拿过来再改），然后删掉 `old_key`。
  - `pub fn data_dir(home: &Path) -> Result<PathBuf, (PathBuf, String)>`：返回 `home/center`；需要搬而搬不成时 `Err((home/state, 原因的 ErrorKind))`。
  - `pub fn args(c: &ServiceCfg, data: &Path) -> Vec<String>`：第二个参数从 `home` 改成数据目录本身。

- [ ] **Step 1: 写失败的测试（companion.rs `mod tests`）**

```rust
#[test]
fn the_old_key_reads_as_center() {
    let map = json!({"state": {"on": true, "port": 9000}}).as_object().unwrap().clone();
    assert_eq!(cfg_in(&map, &TABLE[0]), ServiceCfg { on: true, port: Some(9000), ..Default::default() });
}

#[test]
fn center_key_wins_and_old_key_goes_on_write() {
    let map = json!({"state": {"on": false}, "center": {"on": false, "port": 9001, "x": 1}, "llm": {"on": true}});
    let map = map.as_object().unwrap().clone();
    assert_eq!(cfg_in(&map, &TABLE[0]).port, Some(9001));
    assert_eq!(Value::Object(turned(map, &TABLE[0], true)), json!({"center": {"on": true, "port": 9001, "x": 1}, "llm": {"on": true}}));
}

#[test]
fn turning_an_old_file_moves_its_fields_to_center() {
    let map = json!({"state": {"on": false, "port": 9002}}).as_object().unwrap().clone();
    assert_eq!(Value::Object(turned(map, &TABLE[0], true)), json!({"center": {"on": true, "port": 9002}}));
}

#[test]
fn a_bad_old_key_is_still_invalid() {
    let dir = tempfile::tempdir().unwrap();
    for bad in [r#"{"state":{"on":"x"}}"#, r#"{"center":{"on":true,"port":"x"}}"#] {
        std::fs::write(dir.path().join(FILE), bad).unwrap();
        assert!(read_file(dir.path()).is_err(), "{bad}");
    }
}

#[test]
fn the_state_dir_moves_to_center() {
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir(home.path().join("state")).unwrap();
    std::fs::write(home.path().join("state/state.json"), b"{}").unwrap();
    assert_eq!(data_dir(home.path()), Ok(home.path().join("center")));
    assert!(home.path().join("center/state.json").exists());
    assert!(!home.path().join("state").exists());
}

#[test]
fn both_dirs_keep_center() {
    let home = tempfile::tempdir().unwrap();
    for d in ["state", "center"] {
        std::fs::create_dir(home.path().join(d)).unwrap();
        std::fs::write(home.path().join(d).join("state.json"), d).unwrap();
    }
    assert_eq!(data_dir(home.path()), Ok(home.path().join("center")));
    assert_eq!(std::fs::read(home.path().join("state/state.json")).unwrap(), b"state");
    assert_eq!(std::fs::read(home.path().join("center/state.json")).unwrap(), b"center");
}

#[test]
fn neither_dir_is_center() {
    let home = tempfile::tempdir().unwrap();
    assert_eq!(data_dir(home.path()), Ok(home.path().join("center")));
}
```

现有的 `args` 测试（`companion.rs:697-703`）改成传 `&home.join("center")`，期望 `--data` 后面是 `home/center`；现有 `turned` 测试（709-718）改成用 `&TABLE[0]`，期望键是 `center`。

- [ ] **Step 2: 跑，确认失败**

Run: `cd rust && cargo test -p rapp-service companion`
Expected: 编译失败（`data_dir` 没定义，`turned` 签名不对）。

- [ ] **Step 3: 实现**

- `TABLE[0]` 加 `key: "center", old_key: Some("state")`。
- `read_file` 的校验对 `c.key` 和 `c.old_key` 两项都做（哪项坏了都返回 `Err`，`name` 字段写坏的那个键）。
- `set`（`companion.rs:501` 起）里调 `turned(map, c, on)`；`cfg_in` 的其他调用点不变。
- `data_dir`：`center` 在就用它；不在而 `state` 在就 `std::fs::rename`；都不在就返回 `home/center`（目录由 `rapp-center` 自己建，照今天）。
- `run_once`（`companion.rs:331`）在拼参数前算数据目录：只在 `store != "memory"` 时调 `data_dir`；`Err((dir, kind))` 时用 `dir`，并 `state.log.event(Lvl::Warn, "center_dir_move_failed", json!({"error": kind}))`。

- [ ] **Step 4: 跑，确认通过**

Run: `cd rust && cargo test -p rapp-service companion`
Expected: PASS。

- [ ] **Step 5: 改 testkit 里看本机文件布局的断言，跑集成测试**

- `state_p1.rs:201`：`json!({"center": {"on": true, "port": p, "store": "memory"}})`（测试准备时写的是旧键 `state`，正好测了旧文件升级）。
- `state_p1.rs:241`：`file["center"]["on"]`。
- `state_p1.rs:329`：`a.home.path().join("center").join("state.json")`。
- `set_service.rs:42` 的 `file_on`：`v["center"]["on"]`。
- 在 `state_p1.rs` 加一个 `an_old_state_dir_is_kept_after_upgrade`：准备时在 `home/state/state.json` 放一份含一条队列的文件（用 `rapp_center` 现有存盘格式，可以先起一个 `store:"disk"` 的服务存出来再把目录改名回 `state`），开服务后 `GET /v1/queue` 有那一条，且 `home/center/state.json` 存在。

Run: `cd rust && cargo test -p rapp-testkit --test state_p1 --test set_service`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add rust/service/src/companion.rs rust/testkit/tests
git commit -m "feat(center): services.json 用 center 键、数据搬到 local/center（兼容旧的）"
```

---

### Task 3: `Builtin` trait，把状态搬成第一块（行为不变）

**Files:**
- Create: `services/center/src/builtin.rs`（trait、`Fut`、`table`）
- Create: `services/center/src/entry.rs`（从 `http.rs` 拿过来：`Body`、`reply`、`Ctx`、`Dirty`、`Ends`、通用 `saver`、加载、`accept_loop`、`route`、`get_watch`/`watcher`、`serve`、`serve_with_log`，以及 `a_watcher_that_falls_behind_is_hung_up_on` 单元测试）
- Create: `services/center/src/state/mod.rs`（`StateBlock` 和状态的处理函数：`post_events`、`get_queue`、`put_seen`、`put_desk`、过期清扫）
- Move: `src/store.rs` → `src/state/store.rs`，`src/event.rs` → `src/state/event.rs`
- Modify: `src/disk.rs`（按文件名读写，见下）、`src/lib.rs`（`mod entry; mod builtin; pub mod state; pub mod disk; pub use entry::{serve, serve_with_log};`）
- Delete: `src/http.rs`
- Test: `services/center/tests/http.rs`、`tests/memory.rs` **一行不改**

**Interfaces:**
- Produces（`builtin.rs`）:

```rust
pub(crate) type Fut<'a> = Pin<Box<dyn Future<Output = Response<Body>> + Send + 'a>>;

pub(crate) trait Builtin: Send + Sync + 'static {
    /// 前缀，也是 `/v1/routes` 里的 name。
    fn name(&self) -> &'static str;
    /// 接口版本，出现在 `/v1/routes`。
    fn version(&self) -> u32;
    /// 数据目录下自己的文件名，如 "state.json"。
    fn file(&self) -> &'static str;
    /// `rest` 以 "/v1/" 开头：`/state/v1/queue` 来的是 "/v1/queue"，根下旧路径原样。
    fn handle<'a>(&'a self, cx: &'a Ctx, req: Request<Incoming>, rest: &'a str) -> Fut<'a>;
    /// 整块存盘的字节（在自己的锁里序列化）。
    fn save(&self) -> serde_json::Result<Vec<u8>>;
    /// 读回 `file()` 的内容。Err 是原因（种类，绝不是内容）。
    fn load(&self, bytes: &[u8]) -> Result<(), String>;
    /// 自己的后台活（状态：每 10 分钟过期一次）。默认没有。
    fn spawn(self: Arc<Self>, _cx: Ctx) -> Option<JoinHandle<()>> { None }
}

/// 登记表：加一块能力就是在这里加一行。
pub(crate) fn table(cfg: &Config) -> Vec<Arc<dyn Builtin>>;   // G1: vec![Arc::new(StateBlock::new(cfg.keep_days, cfg.keep_events))]
```

- Produces（`entry.rs`）:

```rust
/// 每块能力拿到自己的一份：log、changes、watching 共用，dirty 是它自己的（内存模式为 None）。
#[derive(Clone)]
pub(crate) struct Ctx { pub log: Log, changes: broadcast::Sender<String>, watching: Arc<AtomicUsize>, dirty: Dirty }
impl Ctx {
    /// 把变化推给所有 watcher。调用者在自己的锁里调（保持顺序，见今天 `publish` 的注释）。
    pub fn publish(&self, changes: impl IntoIterator<Item = Value>);
    /// 该存盘了。
    pub fn mark(&self);
}
pub(crate) type Body = BoxBody<Bytes, Infallible>;
pub(crate) fn reply(status: StatusCode, body: Value) -> Response<Body>;
```

- Produces（`disk.rs`，取代今天的 `load`/`save`/`write_bytes`）:
  - `pub fn read(dir: &Path, file: &str) -> Result<Option<Vec<u8>>, String>`：没有文件 `Ok(None)`；读不了 `Err(ErrorKind)`。
  - `pub fn move_aside(dir: &Path, file: &str)`：改名成 `<file>.bad`。
  - `pub fn write(dir: &Path, file: &str, bytes: &[u8]) -> std::io::Result<u64>`：今天 `write_bytes` 的做法（`<file>.tmp` 再改名，文件 0600，目录 0700）。
- `StateBlock`（`state/mod.rs`）持有 `Arc<Mutex<Store>>`。`load` 里做今天 `make_store` 做的事：解析、`set_limits`、`expire(now)`、`take_changes()`（扔掉）。解析失败返回 `Err("parse")`。

- [ ] **Step 1: 把 `disk.rs` 的单元测试改成新函数（先写，会编译失败）**

`saved_and_loaded_are_the_same`、`files_are_private`、`loose_modes_are_made_private`、`a_broken_file_is_moved_aside` 改成对 `read`/`write`/`move_aside` 和文件名 `"state.json"`；`an_old_file_without_desks_loads` 挪到 `state/mod.rs` 的测试里，改成 `StateBlock::load` 读那份旧文件返回 `Ok`。加一个：

```rust
#[test]
fn each_file_is_its_own() {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), "a.json", b"1").unwrap();
    write(dir.path(), "b.json", b"2").unwrap();
    move_aside(dir.path(), "a.json");
    assert_eq!(read(dir.path(), "a.json"), Ok(None));
    assert_eq!(read(dir.path(), "b.json"), Ok(Some(b"2".to_vec())));
}
```

- [ ] **Step 2: 拆文件、实现 trait 和入口**

入口加载每一块：有数据目录时 `disk::read` → `Ok(Some(b))` 就 `b.load(&b)`；`read` 报错或 `load` 报错都 `disk::move_aside` 并 `log.emit("load_failed", json!({"kind": why}))`（和今天同一行）。然后对每块：有数据目录就起一个 `saver`（今天的逻辑，序列化用 `b.save()`，写用 `disk::write(dir, b.file(), …)`，日志 `saved {"bytes"}` / `save_failed {"kind"}` 不变）并先 `mark()` 一次；再 `b.clone().spawn(cx)`。所有任务都包进 `Ends`，`serve` 被 drop 时一起停。

G1 的 `route` 先只做今天的事：`/v1/health` 和 `/v1/watch` 入口自己答，其他路径都交给 `state` 那块（`rest` = 整条路径），状态那块里是今天的方法检查和 `match`。

- [ ] **Step 3: 跑，确认今天的测试不改就全过**

Run: `cd rust && cargo test -p rapp-center && git diff --stat HEAD -- ../services/center/tests`
Expected: 测试全过；`tests/` 下没有改动（diff 为空）。

- [ ] **Step 4: 跑 testkit**

Run: `cd rust && cargo test -p rapp-testkit --test state_p1 --test set_service`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add -A services/center
git commit -m "refactor(center): Builtin trait，状态成为第一块内置能力"
```

---

### Task 4: 入口接口：health v2、`/v1/routes`、`/state/v1/…`

**Files:**
- Modify: `services/center/src/entry.rs`（`route`、`health`、`routes`）
- Modify: `services/center/tests/http.rs:50`（health 的期望值，规格把 `v` 改成 2，这是唯一要改的旧断言）
- Create: `services/center/tests/entry.rs`
- Modify: `services/center/api/http.md`；Create: `services/center/api/routes.md`

**Interfaces:**
- Consumes: Task 3 的 `builtin::table`、`Builtin::{name, version, handle}`。
- Produces: 线上接口（规格 §6）：
  - `GET /v1/health` → `{"name":"rapp-state","service":"rapp-center","v":2,"routes":true}`
  - `GET /v1/routes` → `{"routes":[{"name":"state","kind":"builtin","v":1}]}`（从 `table` 生成；G2/G3 往里加）

路径分派（按顺序，第一条对上的就是）：

| 路径 | 交给 |
|---|---|
| `/v1/health`、`/v1/routes`、`/v1/watch` | 入口自己；方法不是 GET → 405 `{"error":"method not allowed"}` |
| 以 `/v1/` 开头的其他路径 | `state` 那块，`rest` = 整条路径（根下旧路径） |
| `/<name>/v1/…`，`<name>` 是登记过的能力 | 那一块，`rest` = `/v1/…` |
| 其他 | 404 `{"error":"not found"}` |

`state` 那块对 `rest` 不认识的（包括 `/v1/watch`、`/v1/health`）回 404 `{"error":"not found"}`。

- [ ] **Step 1: 写失败的测试（`tests/entry.rs`，照 `tests/http.rs` 的 `start`/`get`/`request` 写法，内存模式）**

```rust
#[tokio::test]
async fn health_is_v2_and_says_it_has_routes() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/health").await, (200, json!({"name":"rapp-state","service":"rapp-center","v":2,"routes":true})));
}

#[tokio::test]
async fn routes_lists_the_state_builtin() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/routes").await, (200, json!({"routes":[{"name":"state","kind":"builtin","v":1}]})));
    assert_eq!(request(addr, "POST", "/v1/routes", "").await.0, 405);
}

#[tokio::test]
async fn aliased_paths_answer_like_the_root() {
    let addr = start(Config::default()).await;
    post_sample(addr).await;                       // 同 tests/http.rs
    assert_eq!(get(addr, "/state/v1/state").await, get(addr, "/v1/state").await);
    assert_eq!(get(addr, "/state/v1/queue?limit=1").await, get(addr, "/v1/queue?limit=1").await);
    assert_eq!(put(addr, "/state/v1/desk/aa", r#"{"sessions":[]}"#).await.0, 204);
    assert_eq!(get(addr, "/v1/state").await.1["desks"][0]["fp"], "aa");
    assert_eq!(put(addr, "/state/v1/seen", r#"{"eid":"nope"}"#).await.0, put(addr, "/v1/seen", r#"{"eid":"nope"}"#).await.0);
    assert_eq!(request(addr, "POST", "/state/v1/events", "not json\n").await.0, request(addr, "POST", "/v1/events", "not json\n").await.0);
}

#[tokio::test]
async fn odd_paths_are_404() {
    let addr = start(Config::default()).await;
    for p in ["/state", "/state/", "/state/v1/watch", "/state/v1/health", "/STATE/v1/state", "/nope/v1/x", "//v1/state", "/v1/nope"] {
        assert_eq!(get(addr, p).await, (404, json!({"error":"not found"})), "{p}");
    }
}
```

（`post_sample`、`put` 等助手从 `tests/http.rs` 复制过来。）

把 `tests/http.rs:50` 的期望改成 v2 那一行。

- [ ] **Step 2: 跑，确认失败**

Run: `cd rust && cargo test -p rapp-center --test entry --test http`
Expected: FAIL（health 还是 v1、`/v1/routes` 和 `/state/v1/…` 是 404）。

- [ ] **Step 3: 实现上表的分派、`health`、`routes`**

前缀只按 `/` 切第一段、原样比较（大小写敏感），不做路径规范化。

- [ ] **Step 4: 跑，确认通过**

Run: `cd rust && cargo test -p rapp-center && cargo test -p rapp-service outbox && cargo test -p rapp-testkit --test state_p1 --test set_service`
Expected: 全过（发件箱认的 `name` 没变）。

- [ ] **Step 5: 写接口文档**

- `api/http.md`：标题改成 `rapp-center HTTP API`；health 改成 v2 那一行；加一段「每条状态接口也能用 `/state` 前缀访问，如 `/state/v1/queue`；根下的旧路径永久保留」；写明 watch 只有 `/v1/watch`。
- `api/routes.md`：`GET /v1/routes` 的形状、`kind`（G1 只有 `builtin`）、`v`，前缀的规则（小写字母、数字、`-`，不能是 `v1`），以及「加一块内置能力 = 新模块 + `builtin::table` 一行 + `api/` 里的文档」。

- [ ] **Step 6: Commit**

```bash
git add services/center
git commit -m "feat(center): health v2、/v1/routes、/state/v1 别名"
```

---

### Task 5: 命令 `rapp center` 和界面「中心服务」

**Files:**
- Modify: `rust/cli/src/args.rs`（`Cmd::State` → `Cmd::Center`，帮助文字，解析，测试 210-212）
- Modify: `rust/cli/src/main.rs:136-151`（变体名、输出文字；IPC 仍发 `{"cmd":"state"}`）
- Modify: `rust/cli/src/say.rs:278-313` 和它的测试 550-563（「状态服务」→「中心服务」）
- Modify: `gui/lib/ui/main_state.dart`、`gui/lib/ui/state_service_row.dart`、`gui/lib/ui/devices_tab.dart`、`gui/lib/pages/global_sections.dart`、`gui/lib/pages/state_section.dart` 和对应测试 `gui/test/ui/devices_tab_test.dart`、`main_state_test.dart`、`state_service_row_test.dart`、`gui/test/pages/state_section_test.dart`
- Test: `gui/test/state/state_sync_test.dart`（加一个）

**Interfaces:**
- Consumes: 无（IPC 不变）。
- Produces: `Cmd::Center { on: Option<bool> }`。

- [ ] **Step 1: 写失败的测试**

`args.rs` 测试：

```rust
assert_eq!(p("center"), Ok(Cmd::Center { on: None }));
assert_eq!(p("center on"), Ok(Cmd::Center { on: Some(true) }));
assert_eq!(p("state off"), Ok(Cmd::Center { on: Some(false) }));   // 别名
assert_eq!(p("center x"), Err("不认识的命令：center x".into()));
assert_eq!(p("state x"), Err("不认识的命令：state x".into()));
```

`say.rs` 测试里的期望文字全部换成「中心服务」（如 `"中心服务：没开\n发件箱：没在发（网里没有中心服务）\n"`、`"网里的中心服务：…"`）。

`state_sync_test.dart` 加（照 `'pushed changes update rows, sessions, needs and seen'` 的写法推送）：

```dart
test('pushes it does not know (prefs.phrases, routes) are ignored and the watch stays open', () async {
  // 连上后推 {'what':'prefs.phrases','rev':1,'items':[]} 和 {'what':'routes','routes':[]}，
  // 再推一条 queue：
  // expect: 没有异常，status 仍是连上的，那条 queue 行出现在 rows 里，watch 没有重开（links 的数量不变）。
});
```

这是规格 §14 要的检查：今天的解析（`state_sync.dart` 的 `_apply` 对不认识的 `what` 返回 false）应该已经忽略它们，所以这个测试预期一写就过；如果不过，停下来报告（G2/G3 就得改用 `/v1/watch?all=1`）。

- [ ] **Step 2: 跑 Rust 测试，确认失败**

Run: `cd rust && cargo test -p rapp-cli`
Expected: FAIL（`Cmd::Center` 没定义）。

- [ ] **Step 3: 实现**

- `args.rs`：`"center" | "state" =>` 同一段解析，错误文字用用户打的那个词；帮助里写 `rapp center` / `rapp center on|off`（看中心服务 / 在这台上开、关中心服务），不列 `state`。
- `main.rs`：`已打开中心服务`、`已关掉中心服务`、`中心服务没有起来`。
- Dart：用户看得见的「状态服务」全换成「中心服务」；测试里找文字的地方跟着换。

- [ ] **Step 4: 跑，确认通过**

Run: `cd rust && cargo test -p rapp-cli && cd ../gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test test/state test/ui test/pages; git checkout pubspec.lock`
Expected: 全过；`/usr/bin/grep -rn "状态服务" rust/cli gui/lib gui/test` 没有输出。

- [ ] **Step 5: Commit**

```bash
git add rust/cli gui/lib gui/test
git commit -m "feat(center): rapp center 命令（state 留作别名），界面叫「中心服务」"
```

---

### Task 6: 文档和全量门禁

**Files:**
- Modify: `services/README.md`、`services/center/README.md`（标题 `rapp-center`，`cargo run -p rapp-center -- --data ./data`，一段说明入口和内置能力）
- Modify: `docs/superpowers/specs/2026-11-26-rapp-state-design.md` §8.3（health 改 v2，加 `/v1/routes` 和 `/state` 前缀一句，指向 `services/center/api/`）、§12（`llm/` 那行改成“经中心服务转发挂上，见《rapp-center 设计》§9”，目录 `services/state/` → `services/center/`）
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`：56-59 行和 §2.12、§2.14：`rapp center on|off`、键 `center`（旧键 `state` 仍认、写时改掉）、`local/center/state.json`（从 `local/state/` 自动搬来）、「中心服务」
- Modify: `tasks/todo.md`：加「中心服务 G1」一项，列实机检查：① 从 0.15.x 升级后中心服务仍开着、队列还在（`local/state/` 已变成 `local/center/`）；② `rapp center` 和 `rapp state` 输出一样；③ 设置里叫「中心服务」；④ 另一台旧版 app 连这台照常显示状态；⑤ 回滚到旧版后中心服务是关的、队列是空的（已知，见下）

- [ ] **Step 1: 改上面的文档**

- [ ] **Step 2: 全量门禁**

Run: `cd rust && cargo test --workspace --no-fail-fast 2>&1 | tail -5 && cargo clippy --workspace --all-targets -- -D warnings && cd ../gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test; git checkout pubspec.lock`
Expected: 全过，clippy 没有警告。

- [ ] **Step 3: Commit**

```bash
git add services docs tasks
git commit -m "docs(center): G1 的文档和待办"
```

---

## 已知后果（不在 G1 处理）

- 回滚到 0.15.x：旧版找 `services.json` 的 `state` 键和 `local/state/`。如果升级后改过开关（键已改成 `center`），旧版会当成关；数据目录已搬走，旧版从空的开始。状态是 7 天内的临时数据，按规格接受；写进 `tasks/todo.md` 的实机检查 ⑤。
