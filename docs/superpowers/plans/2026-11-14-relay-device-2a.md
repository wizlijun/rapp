# 设备连新 relay（2a）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 设备有自己的设备密钥，填接入点和 key 就接入 relay；B 只填 A 的纯数字 ID 就能经 relay 连上 A；设备之间凭同一个 key 互信，relay 看不到内容。

**Architecture:** 新 crate `rust/conn`（`rapp-conn`）放设备侧的连接层：端到端 TLS、互信证明、relay 客户端。`rapp-wire` 补上设备之间用的 TLS 配置。A（service）在 22028 上同时收 `rapp/1`（老的密码认证，原样保留）和 `rapp/2`（双向证书 + 互信），并常驻一条到 relay 的连接；被 relay 接进来的流上再做一次 TLS（`rapp-e2e/1`）。B（hub）有 key 时：先在局域网地址上试 `rapp/2`，不通就经 relay，每个请求一条 relay 流、一次握手（relay 规格 §3 甲）。

**Tech Stack:** Rust（quinn 0.11、rustls 0.23 ring、新加 tokio-rustls 0.26、ring 的 HMAC）；Flutter GUI。

**Spec:** `docs/superpowers/specs/2026-11-13-rapp-relay-design.md`（§5–§8、§10.3、§11.2、§22，下称"relay 规格"），`docs/superpowers/specs/2026-11-14-relay-connect-ux-design.md`（下称"UX 规格"；本计划只做它的前提，正文在 2b）。

**分三份计划：** 2a（本文）接入和互信；2b 选路、自动切局域网、强制中继、路径显示、ID 折叠（UX 规格）；2c 吊销名单、换 key 传播、"接受新设备"开关、§11.2 的其余审计事件、`redirect`、打洞。

## Global Constraints

- 基于分支 `feat/drop-relay1` 做完以后的代码：新 relay 在 `rust/relay`，包名 `rapp-relay`，库名 `rapp_relay`；`rapp-net` 只剩 `ALPN_PEER = "rapp/1"` 和 `Op::{Auth{password,name}, ListApps, Ping, Open}`。
- ALPN：设备直连 `rapp/2`，流内端到端 `rapp-e2e/1`，到 relay `rapp-relay/2`（已有）。SNI 一律 `rapp`。只用 TLS 1.3。
- 设备密钥：`<home>/device.key`、`<home>/device.crt`（`home` 就是现在 service 和 hub 的 `opts.home`，即数据根下的 `local/`），用 `rapp_wire::Identity::load_or_create(home, "device")`。service 和 hub 共用这一对。
- 指纹 `Fp` = 证书公钥部分的 SHA-256；验证只看指纹，不看有效期、名字。
- key 的文本、解析、推导全部用 `rapp_wire::Key`（`FromStr`、`join()`、`trust()`、`relay`）。key 和 `trust()` 的值**不得**出现在任何日志、状态回复（`show_key` 除外）、错误文本里。
- 互信证明（relay 规格 §7.2，§21 留给计划的精确算法，本计划定下）：
  - 握手导出值：TLS exporter，label `EXPORTER-rapp-proof/1`，context 为空（quinn 传 `b""`，rustls 传 `Some(b"")`），32 字节。
  - 证明 = HMAC-SHA-256(`key.trust()`, `b"rapp proof/1"` ‖ 导出值[32] ‖ 客户端指纹[32] ‖ 服务端指纹[32] ‖ 角色)，角色是 `b"client"` 或 `b"server"`；文本是 64 位小写十六进制。用 `ring::hmac::verify` 比较。
- L4 第一条消息（`rapp/2` 连接的第一条流；经中继时 TLS 握手后的第一行）：
  - B 发 `{"op":"hello","name":"<B 的名字>","proof":"<hex>"}`；B 没有 key 时不带 `proof`。
  - A 回 `{"ok":true,"id":"<A 的 ID>","name":"<A 的名字>","proof":"<hex>"}`（A 没有 key 时不带 `proof`），或 `{"ok":false,"error":"not trusted"}`。
  - A 收下的条件：B 的指纹在 `paired.json` 里，**或者** A 有 key 且 B 的证明对。证明对而指纹不在列表里：加进去。
  - B 收下的条件：A 的指纹等于 `hosts.json` 里这台主机存的 `fp`，**或者** B 有 key 且 A 的证明对；并且回复里的 `id` 等于要连的 ID。证明对、指纹和存的不同：换成新的，记一行 `host_key_changed`。两样都不满足：存过 `fp` 的报 `host key mismatch`，没存过的报 `not trusted`。
  - B 把 hello 和后面的请求一起发出去，不等回复（不多一个来回）；A 验过 hello 才读后面的请求。
- `paired.json`（A 的"认识的设备"）：`<home>/paired.json`，0600，`[{"fp":"<64 hex>","name":"<自报的名字>","since":"<RFC 3339 UTC>"}]`。
- `service.json` 新字段：`relay`（`主机:端口`，可无）、`key`（key 文本，可无）。两样都有才连 relay。
- `hosts.json` 每台主机新字段 `fp`（可无）。`password` 字段照旧总是写出（经 relay 加的主机写 `""`），老版本读得了。
- 选路（2a）：B 有 key 时，局域网地址（`hosts.json` 存的，加上 relay `connect` 回复里的）各等 500 ms 一起试 `rapp/2`，先通的用；都不通而 B 设了 relay 就经 relay。B 没有 key 时照旧只走 `rapp/1` + 密码。
- 不退回旧路：存过 `fp` 的主机**只**走 `rapp/2`，不再用密码。没存过 `fp` 的主机，`rapp/2` 失败而有密码时，才退回 `rapp/1`。
- 错误文本（hub 发出、GUI 映射）：`relay not set: add the host as id@ip`、`relay unreachable: <原因>`、`relay identity mismatch`、`not trusted`、`host key mismatch`；relay 原样转来的 `bad key`、`closed`、`unknown id`、`offline`、`limit`、`locked, retry in <N>s`。
- 路径：`lan`、`direct`、`relay`。GUI 标签 `局域网`、`直连`、`中继`。
- 在线探测：主机现在的连接是经 relay 的，探测用 relay 的 `connect`（回 ok 就是在线），不开 relay 流。
- 用户同时在改仓库：在新分支上做；不碰 `README.md`、`docs/archives/`、`tasks/`。按文件名 `git add`，不用 `git add -u/-A/.`、`git stash/checkout/restore/reset`。不跑 `cargo fmt`；只对改过的文件跑 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`。
- `flutter test` 会改 `gui/pubspec.lock`：不要提交它。Flutter 在 `~/development/flutter/bin/flutter`，cargo 在 `~/.cargo/bin`。
- 每个 Rust 任务结束：`cd rust && cargo test --workspace` 全过，`cargo clippy --workspace --all-targets -- -D warnings` 无警告。GUI 任务结束：`flutter test` 全过、`flutter analyze` 无问题。
- 不发版，不改版本号。提交信息 `feat(wire): …`、`feat(conn): …`、`feat(service): …`、`feat(hub): …`、`feat(gui): …`，结尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

1. 升级前加的主机（`hosts.json` 有 `password` 和 `lan`、没有 `fp`）：B 填了 key 以后照样连得上——A 也有同一个 key 时走 `rapp/2` 并记下 `fp`；A 没 key 或是老版本时退回密码。（任务 6）
2. 存过 `fp` 的主机，局域网上回应的是另一台设备（或 A 重装、换了 key）：不退回密码，报 `host key mismatch`；B 和 A 有同一个 key 时自动重新认识并记 `host_key_changed`。（任务 6）
3. relay 重启或网断：A 在 5 秒内重新登记（relay 规格 §22），经中继的新请求接着能用；`going_away` 之后按 `after_ms` 加随机量重连，不狂连。（任务 5）
4. key 填错：文本解析不了，`set_relay` 当场回 `bad key`、不保存；前一半错，状态里 `relay_error` 是 `relay identity mismatch`；后一半错，是 `bad key`。三种情况下局域网照常可用，service 不崩。（任务 4、5）
5. 第一次启动时 service 和 hub 同时起来：两边拿到的设备密钥是同一把。（任务 1）

---

### Task 1: rapp-wire：设备密钥不怕并发创建；设备之间的 TLS 配置

**Files:**
- Modify: `rust/wire/src/identity.rs`（`load_or_create` 并发安全）
- Modify: `rust/wire/src/tls.rs`（新常量和配置；把现有两个 verifier 参数化，不复制）
- Test: `rust/wire/src/identity.rs`、`rust/wire/tests/peer_tls.rs`（新）

**Interfaces:**
- Produces:
  - `rapp_wire::tls::ALPN_DEVICE: &[u8] = b"rapp/2"`，`ALPN_E2E: &[u8] = b"rapp-e2e/1"`。
  - `pub fn device_server_config(id: &Identity, alpns: &[&[u8]]) -> Result<quinn::ServerConfig>`：客户端证书**可选**（`rapp/1` 的老 B 不出示），出示了就必须签名对；传输参数用设备的：bidi 1024、keep-alive 10 s、idle 30 s，不用 relay 的小窗口。
  - `pub fn device_client_config(id: &Identity, alpn: &[u8]) -> Result<quinn::ClientConfig>`：出示本机证书，服务端用 `Expect::Any`（调用方握手后自己比指纹）。
  - `pub fn e2e_server(id: &Identity) -> Result<Arc<rustls::ServerConfig>>`（客户端证书**必须**，ALPN `rapp-e2e/1`）、`pub fn e2e_client(id: &Identity) -> Result<Arc<rustls::ClientConfig>>`（ALPN `rapp-e2e/1`，`Expect::Any`）。
  - `pub fn alpn(conn: &quinn::Connection) -> Option<Vec<u8>>`：协商出来的 ALPN。
  - `peer_fp` 照旧。

- [ ] **Step 1: 写测试**
  - `identity.rs`：`concurrent_load_or_create_agrees`：8 个线程同时 `load_or_create(dir, "device")`，全部 `fp` 相同，且等于之后再读一次的 `fp`。
  - `tests/peer_tls.rs`：
    - `device_quic_mutual`：服务端 `device_server_config(&a, &[ALPN_DEVICE, b"rapp/1"])`，客户端 `device_client_config(&b, ALPN_DEVICE)`；连上后两边 `peer_fp` 分别是 `b.fp`、`a.fp`，`alpn(&conn) == Some(b"rapp/2".to_vec())`。
    - `device_quic_old_client_without_cert`：客户端用 `rapp_net::quic::client_config(b"rapp/1")`（不出示证书）也能连上，服务端 `peer_fp` 返回错误、`alpn` 是 `rapp/1`。
    - `e2e_over_duplex`：`tokio::io::duplex` 两端，`tokio_rustls` 的 acceptor/connector 用 `e2e_server(&a)`/`e2e_client(&b)` 握手成功，两边各自看到对方的指纹；客户端不出示证书时服务端握手失败。

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-wire`：编译失败（新函数不存在）。

- [ ] **Step 3: 实现**
  - `load_or_create`：两个文件都在就读。不在：用 `OpenOptions::create_new` 建 `<stem>.lock` 抢创建权；抢到的生成密钥，key 和 crt 各自写临时文件再 `rename` 到位（先 crt 后 key），然后删锁；没抢到的每 50 ms 看一次，两个文件都在就读，最多等 2 秒；锁文件超过 10 秒还在当作上次崩溃留下的，删掉重抢。
  - `tls.rs`：`ClientVerifier` 加字段 `mandatory: bool`（relay 的 `server_config` 传 `true`，行为不变）；`ServerVerifier` 照旧。workspace 依赖加 `tokio-rustls = { version = "0.26", default-features = false, features = ["ring"] }`，wire 只在 dev-dependencies 里用它（e2e 配置本身只依赖 rustls）。

- [ ] **Step 4: 跑测试确认通过** — `cd rust && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`。

- [ ] **Step 5: 提交** `feat(wire): device-to-device TLS configs; identity safe to create from two processes`（连同 `rust/Cargo.toml`、`rust/Cargo.lock`）

---

### Task 2: rapp-conn：互信证明和 hello

**Files:**
- Create: `rust/conn/Cargo.toml`（`rapp-conn`；依赖 rapp-wire、rapp-net、quinn、rustls、tokio、tokio-rustls、ring、serde、serde_json、anyhow）、`rust/conn/src/lib.rs`
- Create: `rust/conn/src/proof.rs`（证明的计算和核对）、`rust/conn/src/hello.rs`（两边的 hello 规则）、`rust/conn/src/e2e.rs`（在一条字节流上做 TLS，拿导出值和指纹）、`rust/conn/src/paired.rs`（`paired.json`）
- Modify: `rust/Cargo.toml`（members、workspace 依赖加 `rapp-conn`）
- Test: 各文件的单元测试，`rust/conn/tests/trust.rs`（新）

**Interfaces:**
- Consumes: 任务 1 的 `e2e_server`、`e2e_client`、`ALPN_E2E`。
- Produces:
  - `pub trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}`（对所有满足的类型实现），`pub type Pipe = Box<dyn Stream>`。
  - `pub enum Role { Client, Server }`；`pub struct Facts { pub ekm: [u8; 32], pub me: Fp, pub peer: Fp, pub role: Role }`。
  - `pub fn quic_facts(conn: &quinn::Connection, me: &Fp, role: Role) -> Result<Facts>`。
  - `pub async fn e2e_accept<S: Stream + 'static>(io: S, id: &Identity) -> Result<(Pipe, Facts)>`，`pub async fn e2e_connect<S: Stream + 'static>(io: S, id: &Identity) -> Result<(Pipe, Facts)>`。
  - `pub fn proof(trust: &[u8; 32], f: &Facts) -> String`（本方的证明）；`pub fn check(trust: &[u8; 32], f: &Facts, theirs: &str) -> bool`（对方的证明）。
  - `pub struct Me<'a> { pub id: &'a str, pub name: &'a str, pub key: Option<&'a Key> }`。
  - B 一侧拆成写和读两步，好让调用方在中间写请求：`pub async fn send_hello(s: &mut Pipe, f: &Facts, me: &Me<'_>) -> Result<()>`；`pub async fn read_welcome(s: &mut Pipe, f: &Facts, key: Option<&Key>, want_id: &str, known: Option<&Fp>) -> Result<Accepted>`；`pub struct Accepted { pub id: String, pub name: String, pub fp: Fp, pub changed: bool /* 指纹和存的不同 */ }`。
  - `pub async fn hello_server(s: &mut Pipe, f: &Facts, me: &Me<'_>, paired: &Paired) -> Result<Greeted>`；`pub struct Greeted { pub name: String, pub fp: Fp, pub newly: bool }`。失败时已经回了 `not trusted`，返回 `Err`，错误文本 `not trusted`。
  - `pub struct Paired`：`load(home: &Path) -> Paired`（坏文件当空并记一行警告由调用方做：返回 `Result`），`contains(&Fp) -> bool`，`add(&Fp, name: &str) -> Result<()>`（写盘，0600；已存在只更新 name）。内部 `Mutex`，可在多个任务间共享（`Arc<Paired>`）。
  - 读写行用 `rapp_net::line`（和现有 Op 同一套）。

- [ ] **Step 1: 写测试**
  - `proof.rs`：`proof_is_pinned`：`trust=[7;32]`、`ekm=[1;32]`、`client fp=[2;32]`、`server fp=[3;32]`，角色 client 的证明等于一个写死的十六进制串（实现时算出来贴进测试，之后它就是格式的钉子）；角色换成 server、任一字段改一个字节，结果都变。
  - `tests/trust.rs`（用 `tokio::io::duplex` 和 `e2e_accept`/`e2e_connect`，`tempfile` 做 home）：
    - `same_key_trusts_and_pairs`：两边同一个 `Key::new_local()`；B `send_hello` 后紧接着写一行 `{"op":"ping"}`；A `hello_server` 成功，`newly == true`，然后读到 `ping`；B `read_welcome` 成功、`id` 对、`changed == false`（`known` 为 `None`）；`paired.json` 里有 B 的指纹和名字。
    - `different_keys_refuse`：两把不同的 key：A 回 `not trusted`，B 的 `read_welcome` 返回错误 `not trusted`；`paired.json` 不存在或为空。
    - `known_fp_needs_no_key`：A 的 `paired` 里先放 B 的指纹，两边都没有 key：成功；B 传 `known = Some(&a.fp)`。
    - `mitm_cannot_forward_proofs`：中间人用自己的设备密钥，分别和 B、A 做 TLS，把每一行原样转发；两边同一个 key：A 回 `not trusted`（或 B 判 A 的证明不对），`paired.json` 里没有中间人也没有 B。
    - `wrong_id_is_refused`：`want_id` 和 A 回的 `id` 不同：B 返回错误 `not trusted`。
    - `changed_fp_with_good_proof`：B 传 `known = Some(&某个别的 fp)`，同一个 key：成功且 `changed == true`；没有 key：错误 `host key mismatch`。
  - `paired.rs`：`add_then_load`、`file_is_private`（0600）、`add_twice_keeps_one_entry`。

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-conn`：编译失败。

- [ ] **Step 3: 实现**（见 Interfaces）。`e2e_*` 里导出值从 `tokio_rustls` 流的 `get_ref().1.export_keying_material` 拿；指纹从 `peer_certificates()` 的第一张算。

- [ ] **Step 4: 跑测试确认通过** — `cd rust && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`。

- [ ] **Step 5: 提交** `feat(conn): end-to-end TLS, the trust proof and hello`

---

### Task 3: rapp-conn：relay 客户端

**Files:**
- Create: `rust/conn/src/relay.rs`
- Test: `rust/conn/tests/relay.rs`（新；dev-dependency `rapp-relay`，测试辅助照 `rust/relay/tests/common/mod.rs` 里的 `start_relay` 写一个最小的进程内 relay）

**Interfaces:**
- Consumes: `rapp_wire::{tls::{client_config, ALPN_RELAY, SNI, Expect}, msg::{Req, Push}, line, Key, Identity}`。
- Produces:
  - `pub struct RelayConn`（内部一个 `quinn::Connection`，可 `Clone`）。
  - `pub async fn RelayConn::dial(ep: &quinn::Endpoint, addr: &str, key: &Key, id: &Identity) -> Result<RelayConn>`：解析地址（`rapp_net::quic::resolve`），`Expect::Pin(key.relay)`（key 没有前一半：错误 `relay not set: add the host as id@ip`——没有 relay 的 key 不能连 relay）；握手因为指纹对不上失败：错误 `relay identity mismatch`；其他连不上：`relay unreachable: <原因>`。连上后**不**主动入网。
  - `pub async fn register(&self, id: &str, lan: &[String]) -> Result<()>`、`pub async fn connect_to(&self, id: &str) -> Result<Found>`（`pub struct Found { pub lan: Vec<String>, pub public: String }`）、`pub async fn relay_to(&self, id: &str) -> Result<Pipe>`：这三个遇到 relay 回 `not enrolled` 时，先 `enroll`（`hex(key.join())`）再重试一次；enroll 失败把 relay 的错误原样返回（`bad key`、`closed`、`limit`…）。其余 relay 错误原样作为错误文本返回。
  - `pub async fn next_push(&self) -> Result<Pushed>`；`pub enum Pushed { Incoming { peer: String, reply: Pipe /* 调用方写 {"ok":true} */ }, Relayed { peer: String, stream: Pipe /* 已读掉那一行，剩下的字节一个不少 */ }, Revoked(Vec<Fp>), GoingAway { after_ms: u64 }, Closed { code: u32, reason: String } }`。`accept_bi` 和 `accept_uni` 两边一起等。`relayed` 那一行要逐字节读（或用不丢余量的读法），后面紧跟的 TLS 字节不能被吃掉。
  - `pub fn close(&self)`。
  - relay 推来的行（`revoked` 是一整行的全量名单）读的上限是 **1 MiB**，不用 `MAX_LINE`（8 KiB）：8 KiB 大约 120 个吊销就截断，设备会继续信被吊销的设备。
  - `relayed` 之后流立刻结束（relay 那边超时晚到）：丢掉，不算错误，`next_push` 接着等下一个。
  - enroll 失败后 relay 会用 code 3 关连接：先读回复那一行拿原因（`bad key`、`closed`…）作为错误文本，不要把 code 3 当成"满了"。

- [ ] **Step 1: 写测试**（进程内 relay，入网开着，join hash 设成测试 key 的）
  - `register_then_connect`：A `dial` + `register("123456789", ["10.0.0.5:22028"])`（第一次会走 enroll）；B `dial` + `connect_to("123456789")`：A 收到 `Pushed::Incoming`，回 `{"ok":true}`；B 拿到的 `lan == ["10.0.0.5:22028"]`、`public` 非空。
  - `relay_bytes_both_ways`：B `relay_to` 后写 `b"hello"`；A `next_push` 得到 `Relayed`，读到 `hello`，回 `b"world"`；B 读到 `world`。再用 `e2e_connect`/`e2e_accept` 在这条流上握手成功（证明 relayed 那一行没有吃掉 TLS 字节）。
  - `wrong_relay_half`：key 的前一半换成别的：`dial` 错误是 `relay identity mismatch`。
  - `wrong_root_half`：前一半对、后一半错：`register` 错误是 `bad key`。
  - `unknown_and_offline`：`connect_to("987654321")` 错误 `unknown id`；A 登记后断开，再 `connect_to` 错误 `offline`。
  - `going_away_is_pushed`：relay `stop()`：A 的 `next_push` 先得到 `GoingAway`。
  - `big_revoked_line_is_read`：relay 吊销 300 个指纹（推来的行超过 8 KiB）：`next_push` 得到 `Revoked`，里面 300 个。

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-conn --test relay`。

- [ ] **Step 3: 实现**（见 Interfaces）。

- [ ] **Step 4: 跑测试确认通过** — 全量 test + clippy。

- [ ] **Step 5: 提交** `feat(conn): relay client — enroll, register, connect, relay, pushes`

---

### Task 4: service：设置 relay 和 key；`rapp/2` 直连

**Files:**
- Modify: `rust/service/Cargo.toml`（加 `rapp-wire`、`rapp-conn`）、`rust/service/src/config.rs`（`relay: Option<String>`、`key: Option<String>`，空串当没有）、`rust/service/src/lib.rs`（启动时 `Identity::load_or_create(home, "device")`、`Paired::load`；端点改成 `device_server_config(&identity, &[ALPN_DEVICE, ALPN_PEER])`）、`rust/service/src/state.rs`（`identity`、`paired`、relay 状态；`Peer` 加 `fp: Option<Fp>`；`status()` 加字段）、`rust/service/src/peer.rs`（按 ALPN 分流；`serve_request` 改收 `Pipe`）、`rust/service/src/ipc.rs`（`set_relay`、`show_key`）
- Test: `rust/testkit/tests/service.rs`、`rust/testkit/tests/common/mod.rs`（加 `rapp/2` 的 B 客户端辅助）

**Interfaces:**
- Consumes: 任务 1 的 `device_server_config`、`alpn`、`peer_fp`；任务 2 的 `Pipe`、`quic_facts`、`hello_server`、`Paired`、`Me`。
- Produces:
  - IPC `{"cmd":"set_relay","relay":"vps:22026","key":"rapp…"}`：两样都空 → 清掉；`key` 解析不了 → `{"ok":false,"error":"bad key"}` 不保存；`relay` 不是 `主机:端口` → `bad address`；成功保存 `service.json` 并让 relay 连接（任务 5）重来。
  - IPC `{"cmd":"show_key"}` → `{"ok":true,"key":"rapp…"}`（没有就 `"key":null`）。
  - `status` 新字段：`relay_addr`（字符串或 null）、`has_key`（bool）、`relay`（`"off"|"connecting"|"connected"|"error"`）、`relay_error`（字符串或 null）、`fp`（本机指纹 64 hex）。任务 5 之前 `relay` 恒为 `"off"`。
  - `pub async fn serve_request(state: &Arc<State>, s: Pipe, peer: Peer) -> Result<()>`（任务 5 在经中继的流上调用它）。
  - service 日志事件 `trust`：`{peer, path, fp, name, result: "paired"|"known"|"refused"}`，`refused` 时带 `reason`。

- [ ] **Step 1: 写测试**（testkit）
  - `set_relay_saves_and_masks`：`set_relay` 后 `status` 里 `relay_addr` 对、`has_key == true`，`status` 的整个 JSON 文本里找不到 key 文本；`show_key` 回原文；`service.json` 里有 `relay`、`key`。
  - `set_relay_rejects_bad_key`：`key:"rappxyz"` → `bad key`，`service.json` 不变。（RF4）
  - `rapp2_same_key_pairs`：A、B 同一个 key（B 是测试里的客户端：`device_client_config` + `send_hello` + `{"op":"list_apps"}`）：拿到 app 列表；`paired.json` 有 B；日志有 `trust{result:"paired"}`；`status.sessions` 之外的 `Peer.path` 由后续 open 断言——这里开一个 `open` 会话，`status.sessions[0].path == "lan"`。
  - `rapp2_without_cert_is_refused`：`rapp/2` 但不出示证书：连接被关，日志 `trust{result:"refused"}`。
  - `rapp2_different_key_refused`：回 `not trusted`，后面的请求不被处理。
  - `rapp1_password_still_works`：老 B（`rapp_net::quic::client_config(ALPN_PEER)` + `Op::Auth{password}`）照旧能列 app。
  - `secrets_not_logged`：上面这些跑完，`service.log` 里搜不到 key 文本和 `hex(key.trust())`。

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-testkit --test service`。

- [ ] **Step 3: 实现**（见 Files、Interfaces）。`serve_conn`：协商出 `rapp/2` → 必须有客户端证书，第一条流做 `hello_server`，通过后照旧循环 `accept_bi` → `serve_request`；`rapp/1` → 现有密码流程不变。`hello_server` 失败按现有 `auth_fail` 的方式关连接（code 1）。`splice_session` 等改成收 `Pipe`/泛型。

- [ ] **Step 4: 跑测试确认通过** — 全量 test + clippy。

- [ ] **Step 5: 提交** `feat(service): relay and key settings; rapp/2 with key trust`

---

### Task 5: service：常驻的 relay 连接

**Files:**
- Create: `rust/service/src/relay_link.rs`（名字沿用，内容全新）
- Modify: `rust/service/src/lib.rs`（spawn；`Opts` 加 `advertise_lan: Option<Vec<String>>`，测试用来指定登记的局域网地址，`None` 时用 `rapp_net::addr::lan_addrs(port)`）、`state.rs`（relay 状态的读写、`notify()`）、`ipc.rs`（`set_relay` 成功后通知 relay_link 重来）
- Test: `rust/testkit/tests/service.rs`、`rust/testkit/tests/common/mod.rs`（进程内 relay 辅助，与任务 3 的同一份逻辑，放 testkit 里）

**Interfaces:**
- Consumes: 任务 3 的 `RelayConn`、`Pushed`；任务 2 的 `e2e_accept`、`hello_server`；任务 4 的 `serve_request`、relay 状态字段。
- Produces: A 在 relay 上以自己的 ID 在线；经中继接进来的每条流：`e2e_accept` → `hello_server` → 读一条请求 → `serve_request(state, pipe, Peer{path:"relay", fp:Some(..), ..})`。`status.relay` 有真实值。

行为：
- 用 service 自己的 22028 端点去连 relay（以后打洞用同一个端口）。
- 连上 → `register(id, lan)` → `relay = "connected"`；循环 `next_push`：`Incoming` 回 `{"ok":true}`（打洞留给 2c）；`Relayed` 另开任务处理；`Revoked` 本计划只记一行日志；`GoingAway` 等 `after_ms` 加 0–1000 ms 随机量后重连；`Closed` code 2 → `relay = "error"`、`relay_error = "revoked"`，不再重连，直到 `set_relay`；code 3 或连不上 → 退避 1 s、2 s、4 s … 最多 30 s（每次加 0–20% 随机量），`relay = "connecting"`，`relay_error` 是最近一次的错误文本（`relay identity mismatch`、`bad key`、`relay unreachable: …`、`id taken`…）。
- `set_relay` 改了设置：关掉现在的连接，按新设置重来；清掉了：`relay = "off"`。
- 状态每变一次 `notify()`。日志事件 `relay{state, error?}`，只在变化时写。

- [ ] **Step 1: 写测试**（testkit，进程内 relay）
  - `registers_on_the_relay`：service 启动时 `service.json` 带 relay 和 key：5 秒内 `status.relay == "connected"`；另一个 `RelayConn` `connect_to(A 的 id)` 成功。
  - `relayed_request_reaches_the_service`：`advertise_lan = Some(vec!["127.0.0.1:1".into()])`；测试里的 B：`relay_to` → `e2e_connect` → `send_hello` + `{"op":"list_apps"}` → 读到 app 列表；`paired.json` 有 B；再 `open` 一个会话，`status.sessions[0].path == "relay"`。
  - `relay_restart_reregisters_within_5s`：relay `stop()` 后在同一个端口、同一个数据目录重新 `start`：5 秒内 `status.relay == "connected"`，`connect_to` 又能成功。（RF3）
  - `wrong_relay_half_reports_mismatch`、`wrong_root_half_reports_bad_key`：`status.relay_error` 分别是 `relay identity mismatch`、`bad key`；同时用 `rapp/1` 密码照样能列 app。（RF4）
  - `set_relay_reconnects`：先没设，`relay == "off"`；`set_relay` 后变成 `connected`；清掉后回到 `off`。
  - `secrets_not_logged`（扩展任务 4 的）：`service.log` 里搜不到 key 文本、`hex(key.trust())`、`hex(key.join())`。

- [ ] **Step 2: 跑测试确认失败**。

- [ ] **Step 3: 实现**（见行为）。

- [ ] **Step 4: 跑测试确认通过** — 全量 test + clippy。

- [ ] **Step 5: 提交** `feat(service): stay registered on the relay; serve relayed streams`

---

### Task 6: hub：设备密钥、`rapp/2` 直连、记下主机指纹

**Files:**
- Modify: `rust/hub/Cargo.toml`（加 `rapp-wire`、`rapp-conn`）、`rust/hub/src/hosts.rs`（`Host.fp: Option<Fp>`、`password` 可缺省为 `""` 但总写出；`summary()` 带 `fp`）、`rust/hub/src/link.rs`（`Link` 带路径和 `Pipe` 请求；`establish` 按 Global Constraints 的选路和"不退回旧路"）、`rust/hub/src/lib.rs`（启动时加载设备密钥；`add_host` 新规则；`request` 返回 `Pipe`）、`rust/hub/src/session.rs`（收 `Pipe`）
- Create: `rust/conn/src/settings.rs`：`pub struct Settings { pub relay: Option<String>, pub key: Option<Key> }`，`pub fn load(home: &Path) -> Settings`（读 `service.json` 的 `relay`、`key`，读不了或解析不了当没有）。hub 每次 `establish` 时读一次，不缓存。
- Test: `rust/testkit/tests/hub.rs`

**Interfaces:**
- Consumes: 任务 1 的 `device_client_config`、`ALPN_DEVICE`；任务 2 的 `quic_facts`、`send_hello`、`read_welcome`、`Pipe`；任务 4 的 A。
- Produces:
  - `Hub::request(&self, host: &Host, op: &Op) -> Result<(Pipe, Value, &'static str)>`（路径 `"lan"|"direct"|"relay"`）。
  - `add_host{id, password?}`：
    - `id` 是 `ID@IP`：B 有 key → 先 `rapp/2`；没成功、没存过 fp（新加的当然没有）且给了密码 → `rapp/1`。B 没 key → 必须有密码，走 `rapp/1`（现状）。
    - `id` 是纯 ID：B 没设 relay → 错误 `relay not set: add the host as id@ip`（任务 7 才接通经 relay 的路，本任务先返回这个错误）。
    - 成功经 `rapp/2` 时把 A 的 `fp` 写进 `hosts.json`。
  - hub 日志事件 `host_key_changed{id, old, new}`。

- [ ] **Step 1: 写测试**（testkit，A 是真 service，B 是 hub 驱动）
  - `same_key_host_is_added_over_rapp2`：A、B 同一个 key，`add_host{id:"<A>@127.0.0.1:<port>"}`（不带密码）成功；`hosts.json` 里这台有 `fp` == A 的 `status.fp`、`password == ""`；`apps` 的 `path == "lan"`。
  - `old_host_upgrades_to_rapp2`：`hosts.json` 预置 `{id, name, password, lan}`（没有 fp），A、B 同一个 key：`apps` 成功，之后 `hosts.json` 里有了 `fp`。（RF1）
  - `old_host_falls_back_to_password`：同上但 A 没有 key：`apps` 成功（走密码），`hosts.json` 仍没有 `fp`。（RF1）
  - `known_host_never_falls_back`：`hosts.json` 里这台有 `fp`（随便一个别的指纹）和对的密码，B 没 key：`apps` 失败，错误 `host key mismatch`；A 的日志里没有 `auth`（密码）请求。（RF2）
  - `changed_host_key_relearned_with_key`：同上但 A、B 同一个 key：`apps` 成功，`hosts.json` 的 `fp` 换成 A 的，hub 日志有 `host_key_changed`。（RF2）
  - `bare_id_without_relay`：B 没设 relay，`add_host{id:"<A>"}`：错误 `relay not set: add the host as id@ip`。
  - `old_hub_reads_new_hosts_json`：带 `fp` 的 `hosts.json` 能被**改动前**的 `Host` 结构解析（在测试里用一个和旧结构一样的 `struct OldHost{id,name,password,#[serde(default)] lan}` 反序列化）。
  - `same_identity_as_service`：同一个 home 下 service 和 hub 用的设备指纹相同（`status.fp` 等于 hub 发给 A 的指纹，可从 A 的 `paired.json` 读到）。（RF5 的端到端一半）

- [ ] **Step 2: 跑测试确认失败**。

- [ ] **Step 3: 实现**（见 Interfaces）。`rapp/2` 连接：`ep.connect_with(device_client_config(&identity, ALPN_DEVICE), addr, SNI)`，第一条流 `send_hello` → `read_welcome(known = host.fp)`；通过后 `Link` 缓存这条连接，路径按 `is_private` 定 `lan`/`direct`。

- [ ] **Step 4: 跑测试确认通过** — 全量 test + clippy。

- [ ] **Step 5: 提交** `feat(hub): device key, rapp/2 to hosts, remember host fingerprints`

---

### Task 7: hub：经 relay 连主机

**Files:**
- Modify: `rust/hub/src/link.rs`（`Link` 变成 `enum Link { Quic { conn, path }, Relay }`；经 relay 时每个请求 `relay_to` → `e2e_connect` → `send_hello` + 请求 → `read_welcome` → 读回复）、`rust/hub/src/lib.rs`（`Hub` 缓存一条 `RelayConn`，设置变了或断了就重连；纯 ID 的 `add_host`）、`rust/hub/src/presence.rs`（经 relay 的主机用 `connect_to` 探测）
- Test: `rust/testkit/tests/hub.rs`

**Interfaces:**
- Consumes: 任务 3 的 `RelayConn`；任务 5 的 A（`advertise_lan` 用来挡住局域网）；任务 6 的 `establish`、`request`。
- Produces: B 有 key 和 relay 时，`establish`：先 `connect_to(id)`（同时让 A 知道有人来），把回复的 `lan` 和存的 `lan` 合起来按 500 ms 一起试 `rapp/2`；都不通 → `Link::Relay`，路径 `relay`。`connect_to` 失败（`offline`、`unknown id`…）且局域网也不通 → 把 relay 的错误返回。`add_host{id:"<纯 ID>"}` 经同样的路成功后存 `{id, name, password:"", lan: connect 回复里的, fp}`。

- [ ] **Step 1: 写测试**（testkit：进程内 relay + 真 service + hub 驱动）
  - `bare_id_over_relay`：A 设了 relay、`advertise_lan = ["127.0.0.1:1"]`；B 同一个 key 和 relay；`add_host{id:"<A 的 ID>"}` 成功；`apps` 的 `path == "relay"`；`open` 一个 fake-rapp-host 会话，数据双向通，A 的 `status.sessions[0].path == "relay"`。
  - `bare_id_prefers_lan`：A 正常登记局域网地址（127.0.0.1）：`add_host` 纯 ID 后 `apps` 的 `path == "lan"`，进程内 relay 上没有接过流（用 relay 的 registry/计数或审计日志里没有 `relay` 事件判断）。
  - `relay_errors_pass_through`：`add_host{id:"987654321"}` → `unknown id`；A 停掉后 `apps` → `offline`；B 的 key 后一半错 → `bad key`；前一半错 → `relay identity mismatch`。
  - `presence_over_relay_uses_connect`：经 relay 的主机，在线探测报 `online:true`；A 停掉后报 `online:false`；探测期间 relay 上 `relay` 流计数不涨。
  - `secrets_not_logged`：所有上面的用例跑完，`hub.log`、`service.log`、relay 的数据目录和审计文件里搜不到 key 文本和 `hex(key.trust())`。（relay 规格 §22 机密全量检查的设备一半）

- [ ] **Step 2: 跑测试确认失败**。

- [ ] **Step 3: 实现**（见 Interfaces）。

- [ ] **Step 4: 跑测试确认通过** — 全量 test + clippy。

- [ ] **Step 5: 提交** `feat(hub): reach a host by bare ID through the relay`

---

### Task 8: GUI：接入点和 key；中继路径；只填 ID 加设备

**Files:**
- Modify: `gui/lib/service_client.dart`（`ServiceStatus` 加 `relay`、`relayAddr`、`relayError`、`hasKey`、`fp`；`setRelay(relay, key)`、`showKey()`；`shownIds`：设了 relay（`relayAddr != null`）时 `[id, ...lanIds]`，否则照旧）
- Modify: `gui/lib/pages/local_section.dart`（"中继"一行：接入点 + 状态（`已连接`/`连接中`/`未设置`/`出错：<错误>`）+ "修改"按钮，key `edit-relay`；修改对话框两个输入框"接入点"、"key"；"key"一行默认显示 `••••••`，按钮"显示"调 `showKey` 后显示原文，旁边复制按钮 `copy-key`）
- Modify: `gui/lib/ui/add_device_form.dart`（本机设了 relay 时标签 `对方的 ID`、密码框可空并提示"有 key 时不用填"；没设时照旧 `对方的 ID@IP`）
- Modify: `gui/lib/ui/lifecycle.dart`（映射：`relay not set` → `没设中继，请用 ID@IP 添加`；`relay unreachable` → `中继连不上`；`relay identity mismatch` → `中继的身份对不上，检查接入点和 key`；`bad key` → `key 不对`；`not trusted` → `对方不认这台设备（key 不同？）`；`host key mismatch` → `对方的设备密钥变了`；`unknown id` → `没有这个 ID`；`offline` → 照旧 `对方离线`）
- Modify: `gui/lib/ui/session_model.dart`（路径标签加回 `relay: 中继`）
- Test: `gui/test/service_client_test.dart`、`gui/test/local_section_test.dart`、`gui/test/ui/lifecycle_test.dart`、`gui/test/ui/add_device_form_test.dart`（若没有就建）

**Interfaces:**
- Consumes: 任务 4 的 IPC `set_relay`、`show_key`、`status` 字段；任务 6、7 的错误文本。

- [ ] **Step 1: 写测试**
  - `local_section_test.dart`：`relay row shows address and state`（`relayAddr:'vps:22026'`、`relay:'connected'` → 看到 `vps:22026` 和 `已连接`）；`key is masked until shown`（先看不到 key 原文，点"显示"后看到，`copy-key` 存在）；`editing relay calls set_relay`（FakeService 收到 `{"cmd":"set_relay","relay":…,"key":…}`）；`bad key error is shown`（FakeService 回 `bad key` → 对话框里显示 `key 不对`）；`ids with relay: bare id first`（`relayAddr` 有值时第一行是纯 ID，后面是 `ID@IP`）。
  - `lifecycle_test.dart`：上面每条映射一个断言。
  - `add_device_form_test.dart`：设了 relay 时标签 `对方的 ID`、空密码可以提交；没设时 `对方的 ID@IP`。
  - `service_client_test.dart`：`fromJson` 读新字段；缺字段时默认 `relay:'off'`、`hasKey:false`。

- [ ] **Step 2: 跑测试确认失败** — `cd gui && ~/development/flutter/bin/flutter test`。

- [ ] **Step 3: 实现**（见 Files）。

- [ ] **Step 4: 跑测试确认通过** — `flutter test` 全过，`flutter analyze` 无问题。

- [ ] **Step 5: 提交** `feat(gui): relay and key settings; add a device by ID`
