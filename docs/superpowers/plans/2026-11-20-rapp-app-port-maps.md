# 没有后台服务的 app 里的端口映射：实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS app（以后 Android）里访问 `localhost:<共享号>` 能连到别的设备共享的端口，号和 Mac 上一样。

**Architecture:** 把后台服务的端口表、放置规则、接入转发和「问设备」挪进新 crate `rust/ports`（`rapp-ports`）。后台服务改用它，行为不变。hub 新加 `Opts.map_ports`：只有 `rapp-hub-ffi` 打开，hub 就用同一份代码在回环地址上开端口，经自己的 `Outbound` 转发。

**Tech Stack:** Rust（tokio、quinn）、`rapp-conn::dial::Outbound`、testkit 集成测试。

**Spec:** `docs/superpowers/specs/2026-11-20-rapp-app-port-maps-design.md`

## Global Constraints

- 端口段：`FIRST = 28000`、`COUNT = 1000`，只开 `127.0.0.1` 和 `::1`（spec §5.1）。
- 只有 `rapp-hub-ffi` 开端口。桌面 hub 进程和 testkit 默认 hub 都不开（spec G3）。PC 上的后台服务行为一点不改（G3a）。
- 放行规则不改：由共享方的 `forward.rs` `authorize` 判断（spec §5.4）。
- 失败事件名沿用 `map_refused`，字段 `{"id","port","local","reason"}`；没有映射时是 `{"local","reason":"gone"}`。
- hub 事件格式：`{"event":"ports","maps":[{"id","port","local"}]}`（spec §5.3）。
- 重新问一遍的周期：60 s（spec §5.3）。
- 协议不变（不加 Op、不加字段）。testkit 断言要用 `cargo test --workspace` 跑。
- 提交结尾：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。不提交 `gui/pubspec.lock`。

## 实现时的决定（spec §6 留给实现的）

- R1 用 trait `Carrier` 表示「怎么把连接带过去」，方法返回 `impl Future + Send`（edition 2021，RPITIT 可用）。后台服务给 `State` 实现，hub 给 `HubPorts` 实现。
- R2 hub 的开关叫 `map_ports: Option<(u16, u16)>`，不叫 `own_ports`。原因：后台服务的 `Opts.own_ports` 已经是另一个意思（本机自己的共享号开不开）。None 表示不开，Some 表示从哪个号开始、开几个。测试可以给自己的号段。
- R3 回到前台时**不加** Dart 命令 `ports_relisten`。Dart 的 `enterForeground` 本来就会发 `net_changed`（`gui/lib/ui/main_state.dart:2213`），hub 收到 `net_changed` 时顺带重开监听，再问一遍。效果和 spec §5.3 一样，少一条命令，也不用改 Dart。
- R4 定时任务单独起一个 tokio 任务（`ports::run`），不放进 presence。presence 只在 `presence_every` 为 Some 时跑。
- R5 hub 的端口表始终用启动时的 home。`set_home` 只在桌面「改数据目录」时用，而桌面 hub 不开端口。

## Review Focus

1. iOS 挂起回来以后，监听 socket 已经失效，`accept` 一直报错：循环不能空转吃 CPU。要关掉重开（Task 3 的 `accept_error_relistens` 测试）。
2. 网络断着时问不到设备：不能把已有的映射收回。只有问到了、对方确实不再共享时才 `keep`（Task 3 的 `an_offline_device_keeps_its_maps`）。
3. 手机上 key 没设、或 `service.json` 不存在：不开新端口，也不报错刷屏。maps.json 里已有的照样开（Task 3 的 `no_key_still_listens_from_the_file`）。
4. 桌面 hub（`map_ports` 为 None）完全不碰 28000 段，不写 `maps.json`（Task 3 的 `a_desktop_hub_opens_no_ports`）。
5. 共享方定的号在手机上恰好被占（app 内一般不会有）：要让开到别的号，不能失败（沿用 `Maps::ensure` 已有的单元测试，Task 1 移过去后照样跑）。

---

### Task 1: 新 crate `rapp-ports`：端口表、放置规则、接入转发

**Files:**
- Create: `rust/ports/Cargo.toml`、`rust/ports/src/lib.rs`、`rust/ports/src/maps.rs`（从 `rust/service/src/maps.rs` 挪来）、`rust/ports/src/carry.rs`
- Modify: `rust/Cargo.toml`（members 加 `"ports"`，workspace.dependencies 加 `rapp-ports = { path = "ports" }`）
- Modify: `rust/service/Cargo.toml`（加 `rapp-ports.workspace = true`）
- Modify: `rust/service/src/maps.rs`：只剩 service 专用的部分：`impl Carrier for State`、`ensure_all(state, id, wants)` 包装、`serve(state)` 包装
- Modify: `rust/service/src/own.rs`、`numbers.rs`、`lib.rs`、`state.rs`：`use rapp_ports::...` 替换 `crate::maps::{listen, free, Maps, FIRST, COUNT}`
- Test: `rust/ports/src/maps.rs` 里挪来的 `mod tests`；`rust/ports/src/carry.rs` 新测试；testkit `maps.rs`、`share_numbers.rs`

**Interfaces:**
- Produces（`rapp_ports`）：
  - `pub const FIRST: u16 = 28000; pub const COUNT: u16 = 1000;`
  - `pub struct Map { pub id: String, pub port: u16, pub local: u16 }`（原样，含 serde）
  - `pub struct Maps`：`load(home, first, count) -> (Maps, Option<String>)`、`range`、`honoured`、`list`、`start(known, serve) -> Vec<Map>`、`ensure(id, port, wanted, avoid, mine, serve) -> Option<u16>`、`target(local) -> Option<Map>`、`closed().await -> bool`、`keep`、`keep_devices`、`stop`，签名原样
  - `pub type Serve<'a> = &'a dyn Fn(TcpListener, u16) -> JoinHandle<()>;`
  - `pub fn free(local: u16) -> bool;` `pub fn listen(local: u16) -> Option<Vec<TcpListener>>;`（从 `pub(crate)` 改成 `pub`）
  - `pub trait Carrier: Send + Sync + 'static { fn maps(&self) -> &Maps; fn log(&self) -> &rapp_net::log::Log; fn open(&self, id: &str, port: u16) -> impl Future<Output = Result<rapp_conn::Pipe, String>> + Send; }`
  - `pub fn serve<C: Carrier>(c: Arc<C>) -> impl Fn(TcpListener, u16) -> JoinHandle<()> + Send + Sync + 'static`
  - `pub async fn ensure_all(maps: &Maps, id: &str, wants: &[(u16, Option<u16>)], avoid: &[u16], mine: &[u16], serve: Serve<'_>) -> Vec<Option<u16>>`（原 service 的规则：先 ensure 一遍，有让开的、且 `maps.closed()` 为 true 时再 ensure 一遍）
  - `pub fn number(item: &Value) -> Option<u16>`、`pub fn numbers(items: &[Value]) -> Vec<u16>`、`pub fn wants(items: &[Value]) -> Vec<(u16, Option<u16>)>`（`wants` 等于 `reached` 里那行 `filter_map`：`port` 是非 0 的 u16，加上 `number`）
- Consumes：无

- [ ] **Step 1: 建 crate，把 `Map`、`Maps`、`Entry`、`free`、`listen`、`put`、`spawn`、`bind`、常量和整个 `mod tests` 从 `rust/service/src/maps.rs` 原样挪到 `rust/ports/src/maps.rs`。** 依赖：`rapp-net`、`rapp-conn`、`serde`、`serde_json`、`tokio`；dev 加 `tempfile`、`tokio` 的 `test-util`。
- [ ] **Step 2: 跑挪过去的测试**

Run: `cd rust && cargo test -p rapp-ports`
Expected: 挪过去的测试全部通过，个数和原来 service 里 `maps::tests` 的一样（先用 `cargo test -p rapp-service maps::tests -- --list` 在 BASE 上数出来）。

- [ ] **Step 3: 写 `carry.rs` 的失败测试**

```rust
// 假 Carrier：open 返回 tokio::io::duplex 的一端，另一端做回显；记录被要过的 (id, port)。
#[tokio::test]
async fn a_connection_is_carried_to_the_maps_device_port() {
    // Maps::load 到临时目录，range (29510, 10)；ensure("123456789", 8101, Some(29510), &[], &[], &serve(c))
    // 连 127.0.0.1:29510，写 "hi"，shutdown，读回 "hi"
    // 断言假 Carrier 记录到 [("123456789", 8101)]
}

#[tokio::test]
async fn a_refused_open_closes_the_connection_and_logs_map_refused() {
    // 假 Carrier 的 open 返回 Err("not allowed")；Log::file(临时目录, "t.log")
    // 连上后读到 EOF（0 字节）
    // 日志里有 event "map_refused"，字段 {"id":"123456789","port":8101,"local":29511,"reason":"not allowed"}
}
```

- [ ] **Step 4: 跑，确认失败**

Run: `cd rust && cargo test -p rapp-ports carry`
Expected: 编译失败，`serve` / `Carrier` 还不存在。

- [ ] **Step 5: 写 `Carrier`、`serve`、`carry`、`ensure_all`、`number`/`numbers`/`wants`。** `serve` 和 `carry` 照搬 service 里的 accept 循环和 splice，把 `state.maps` 换成 `c.maps()`，`state.log` 换成 `c.log()`，`pipe::open` 换成 `c.open`。accept 出错时仍然等 100 ms 再继续，这一步不改行为。
- [ ] **Step 6: 跑，确认通过**

Run: `cd rust && cargo test -p rapp-ports`
Expected: 全部 PASS。

- [ ] **Step 7: 后台服务改用 `rapp-ports`。** `impl rapp_ports::Carrier for State`：`open` 调 `crate::pipe::open(self, id, port)`，把 `PipeErr` 转成 `e.as_str().to_string()`，丢掉 path。service 的 `maps::ensure_all(state, id, wants)` 保留签名，内部算出 `mine`、`avoid`（`numbers.seen()` 加上 `mine`），再调 `rapp_ports::ensure_all`。`share_cmds::number`/`numbers` 改成转调 `rapp_ports`。`ipc.rs` 的 `reached` 和 `share_cmds.rs:150` 用 `rapp_ports::wants`。
- [ ] **Step 8: 跑整个工作区**

Run: `cd rust && cargo test --workspace 2>&1 | tail -40 && cargo clippy --workspace --all-targets -- -D warnings`
Expected: 0 失败（`linux_detach_test` 那 2 个是已知的环境问题，只在 Linux 上），clippy 无警告。

- [ ] **Step 9: 提交**

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/ports rust/service
git commit -m "refactor(ports): 端口表和放置规则挪进共用的 rapp-ports"
```

### Task 2: 「问设备」也放进 `rapp-ports`

**Files:**
- Create: `rust/ports/src/ask.rs`
- Modify: `rust/service/src/pipe.rs`：`PipeErr`、`KnownHost`、`known_hosts`、`known_ids`、`reply_err`、`answer` 挪走（用 `pub use rapp_ports::{PipeErr, KnownHost, known_hosts, known_ids}` 保住原路径）；`ask` 改成读 cfg 后调 `rapp_ports::request`
- Test: `rust/ports/src/ask.rs` 单元测试；testkit `forward.rs`、`maps.rs`、`share_set.rs`

**Interfaces:**
- Consumes：Task 1 的 crate
- Produces：
  - `pub struct Way<'a> { pub out: &'a Outbound, pub home: &'a Path, pub relay: Option<&'a str>, pub key: Option<&'a Key> }`
  - `pub async fn request(way: &Way<'_>, id: &str, op: &Op) -> Result<(Pipe, Value, &'static str, Fp), PipeErr>`：没有 key 时是 `PipeErr::NoKey`；`Target` 的 lan 和 fp 从 `known_hosts(home)` 找；`NotReached` 转成 `Offline`
  - `pub async fn open(way, id, port) -> Result<(Pipe, &'static str), PipeErr>`
  - `pub async fn shares_of(way, id) -> Result<Value, PipeErr>`
  - `pub fn reply_err(reply: &Value) -> PipeErr`（service 的 `set` 还要用）

- [ ] **Step 1: 失败测试**

```rust
#[tokio::test]
async fn no_key_is_no_key_without_dialing() {
    // Outbound::new(client_endpoint(127.0.0.1:0), Identity 临时, "t")
    // request(&Way{key: None, relay: None, home: 临时目录, ..}, "123456789", &Op::ListShares)
    // 断言 Err(PipeErr::NoKey)
}
```

- [ ] **Step 2: 跑，确认失败**（`Way` 不存在）。Run: `cd rust && cargo test -p rapp-ports ask`
- [ ] **Step 3: 挪代码，写 `Way`/`request`/`open`/`shares_of`；service 的 `pipe::ask` 改成先做 `target_id`，再取 cfg 里的 relay/key，然后调 `request`。**
- [ ] **Step 4: 跑**

Run: `cd rust && cargo test --workspace 2>&1 | tail -40 && cargo clippy --workspace --all-targets -- -D warnings`
Expected: 0 失败，clippy 无警告。

- [ ] **Step 5: 提交** `refactor(ports): 向设备要共享表、要端口也放进 rapp-ports`

### Task 3: 内嵌 hub 开端口

**Files:**
- Create: `rust/hub/src/ports.rs`
- Modify: `rust/hub/Cargo.toml`（加 `rapp-ports`）
- Modify: `rust/hub/src/lib.rs`：`Opts.map_ports`；`Hub` 加 `ports: Option<Arc<ports::HubPorts>>`；`run` 里启动；`add_host`/`remove_host` 之后调 `poke`
- Modify: `rust/hub/src/netmon.rs`：`net_changed` 里调 `ports.relisten()`
- Modify: `rust/hub/src/main.rs`、`rust/hub-ffi/src/lib.rs`、testkit `common/mod.rs` `Hub::start_full`：补上 `map_ports`。只有 hub-ffi 给 `Some((rapp_ports::FIRST, rapp_ports::COUNT))`，其他都给 `None`
- Modify: `rust/ports/src/carry.rs`：accept 出错时通知调用方重开（见 Step 5）
- Test: 新文件 `rust/testkit/tests/hub_ports.rs`；testkit `Hub` 加 `start_with_ports(home, bins, (u16,u16)) -> Hub`，以及 `wait_event(&mut self, ev: &str, within: Duration, pred) -> Value`（如果已有通用的等事件函数，就用已有的）

**Interfaces:**
- Consumes：`rapp_ports::{Maps, Carrier, serve, ensure_all, wants, numbers, Way, open, shares_of, known_hosts, known_ids}`
- Produces：
  - `rapp_hub::Opts.map_ports: Option<(u16, u16)>`
  - `pub(crate) struct HubPorts`，以及 `fn start(hub: &Arc<Hub>, range) -> Arc<HubPorts>`、`fn poke(&self)`、`fn relisten(&self)`
  - 事件 `{"event":"ports","maps":[{"id","port","local"}]}`：启动按文件开好之后发一次，之后每次 `list()` 有变化时发一次。同样内容写进 hub 日志，事件名 `ports`

**问一遍（`ask_all`）的做法：** 对 `known_hosts(home)` 里的每台设备并发调用 `shares_of`，单台超时 5 s。
- 问到了：记下这台设备的号（`seen[id] = numbers(list)`），先 `maps.keep(id, ports)`，再 `ensure_all(maps, id, wants, avoid = 别的设备的号, mine = [], serve)`。
- 没问到：这台设备的映射不动（Review Focus 2）。
- 问之前，hosts.json 读得到时先做 `keep_devices(known_ids)`。
- `HubPorts.seen: Mutex<HashMap<String, Vec<u16>>>`，算 `avoid` 时去掉正在处理的这台。

**什么时候问：** `ports::run` 任务里用 `select!` 等三件事中任一件：`interval(60 s)`（第一下马上触发）、`poke: Notify`、`hub.net.wake.subscribe().changed()`。

**Carrier：** `open` 每次现读 `rapp_conn::settings::load(home)` 拿 relay 和 key，然后调 `rapp_ports::open(&Way{..}, id, port)`。`Outbound` 在启动时用 `hub.ep.clone()`、启动时的 identity 和 hub 的名字建一次。rebind 换的是同一个 endpoint 的 socket，所以 `Outbound` 跟着换。

- [ ] **Step 1: 写失败的 testkit 测试（`hub_ports.rs`）**

```rust
// A：start_sharing_opts(|h| share_file(h, json!([{"port": echo_port}])), (29410, 10), false, None)
//   —— own_ports=false，A 自己不占 29410
// B：hub 的 home 写 hosts.json（A 的 id 和 LAN 地址，同 maps.rs 的 knows）
//   + service.json（relay ""，A 的 key）；Hub::start_with_ports(home, bins, (29410, 10))

#[tokio::test]
async fn a_hub_with_map_ports_reaches_a_share_on_its_number() {
    // 等到 ports 事件 maps == [{"id":A,"port":echo_port,"local":29410}]（10 s 内）
    // through(29410, b"hello") == b"hello"
    // B 的 maps.json == 同一条
}

#[tokio::test]
async fn a_desktop_hub_opens_no_ports() {
    // 同样的 A；B 用 Hub::start（map_ports None），发 {"cmd":"hosts"}，等 3 s
    // 29420 上没人监听（TcpStream::connect 失败）；B 的 home 里没有 maps.json；没有 ports 事件
}

#[tokio::test]
async fn net_changed_relistens_and_still_carries() {
    // 第一个测试走到能通；send {"cmd":"net_changed"}；等下一个 ports 事件（或 300 ms）
    // through(29410, b"again") == b"again"
}

#[tokio::test]
async fn the_file_listens_before_anyone_is_asked() {
    // B 的 home 先写 maps.json [{"id":A,"port":echo_port,"local":29430}]，A 不启动（离线）
    // Hub::start_with_ports(.., (29430, 10))；第一个 ports 事件就带这条
    // 29430 能连上（accept），对方离线，所以读到 EOF；hub.log 里有 map_refused
}

#[tokio::test]
async fn an_offline_device_keeps_its_maps() {
    // 同上：A 不在线，等 60 s 周期以外的一次问（发 net_changed 触发）之后 maps.json 仍有这条
}

#[tokio::test]
async fn no_key_still_listens_from_the_file() {
    // 同 the_file_listens…，但不写 service.json：端口照样开，hub 不退出，hub.log 没有 error 级的 ports 记录
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd rust && cargo test -p rapp-testkit --test hub_ports`
Expected: 编译失败，`start_with_ports` 或 `Opts.map_ports` 还不存在。

- [ ] **Step 3: 写 `Opts.map_ports`、`ports.rs`（HubPorts、Carrier、`ask_all`、`run`、事件）和 `lib.rs`、`netmon.rs` 的接线；给所有建 `Opts` 的地方补上字段。**
- [ ] **Step 4: 跑，确认通过**

Run: `cd rust && cargo test -p rapp-testkit --test hub_ports`
Expected: 6 个 PASS。

- [ ] **Step 5: accept 出错时重开监听（Review Focus 1）。** 先在 `rust/ports/src/carry.rs` 写失败测试 `accept_error_relistens`：用一个注入的 accept 函数连续返回错误，断言 `serve` 的循环在错误次数达到 `RELISTEN_AFTER = 5` 之前就结束，并调用 `on_dead(local)`。然后实现：`serve` 多收一个 `on_dead: Arc<dyn Fn(u16) + Send + Sync>`。service 传一个空函数（行为不变：继续等 100 ms 重试）。hub 传 `relisten_one(local)`：关掉这个号的监听，再用 `Maps::start` 的同一套逻辑开起来。这个测试怎么注入 accept 由实现决定；如果注入的代价太大，就改成在 ports 里测「accept 连续出错 5 次后任务结束」。

Run: `cd rust && cargo test -p rapp-ports && cargo test -p rapp-testkit --test hub_ports`
Expected: 全部 PASS。

- [ ] **Step 6: 全量门禁**

Run: `cd rust && cargo test --workspace 2>&1 | tail -40 && cargo clippy --workspace --all-targets -- -D warnings`
Expected: 0 失败，clippy 无警告。

- [ ] **Step 7: 提交** `feat(hub): 没有后台服务的 app 自己开 28000 段端口（iOS）`

### Task 4: iOS 编译、装到 Duo、文档

**Files:**
- Modify: `tasks/todo.md`（加「app 端口映射」实机检查：设 `localhost:28001` 后点「测试」能通；长语音能整理；切到后台再回来还能用；在日志页能看到 `ports` 事件）
- Modify: `docs/superpowers/specs/2026-11-20-rapp-app-port-maps-design.md` §6：记下 R2、R3，以及两处与 spec 原文的不同：开关叫 `map_ports`，回前台时不加 `ports_relisten` 命令

- [ ] **Step 1: Flutter 门禁（这次没改 Dart，只确认没被牵连）**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test 2>&1 | tail -5; git checkout gui/pubspec.lock`
Expected: analyze 干净，测试除已知的 2 个 `linux_detach` 外全部通过。

- [ ] **Step 2: 编 iOS 并装到 Duo（在沙盒外跑）**

Run: `gui/packages/rapp_rime/scripts/fetch.sh && scripts/build-ios.sh device --install 00008160-000924982EC00036 && xcrun devicectl device info apps --device 00008160-000924982EC00036 | /usr/bin/grep rapp`
Expected: 装上，版本号是当前 main 的版本。

- [ ] **Step 3: 提交** `docs: app 端口映射的实机检查和实现决定`
