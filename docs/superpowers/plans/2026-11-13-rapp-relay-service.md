# rapp relay 服务（新写）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从零写出新的 relay 服务：只认设备密钥、只搬密文；一个 key 入网；审计日志；三层配置；只以一个 Docker 镜像发布。

**Architecture:** 两个新 crate。`rapp-wire` 放设备和 relay 都要用的东西：指纹、key、设备身份、TLS 配置、行协议、消息。`rapp-relay2` 是服务本身，按规格 §5.4 分模块，每块一个文件。测试用假设备（只用 `rapp-wire`）对着进程内的 relay 跑。

**Tech Stack:** Rust 2021，tokio，quinn 0.11，rustls 0.23（ring），rcgen 0.14，ring 0.17（HKDF、HMAC、SHA-256），x509-parser 0.18，data-encoding 2；Docker（Alpine，多阶段，buildx 多架构）。

**Spec:** `docs/superpowers/specs/2026-11-13-rapp-relay-design.md`（已确认）。下文的"§"都指它。

**这份计划的范围：** 规格里 relay 服务这一半（§5.1、§5.4、§6.2 的 relay 部分、§6.4、§6.5、§8、§9、§10.1、§10.2、§11.1、§11.3、§12）。**不在这里的**：设备的连接层和互信（§7、§10.3、§11.2）、界面、迁移（§13.2）、删掉旧的 `rust/relay`。它们各有后续计划；这份做完时，新旧 relay 的代码并存，互不引用。

## Global Constraints

- `rapp-wire`、`rapp-relay2` 不依赖 `rapp-relay`、`rapp-service`、`rapp-hub`（唯一的例外：任务 15 把旧的 `rapp-relay` 当作 dev-dependency，只用来对比开销）；不使用 `rapp_net::quic`、`rapp_net::msg`、`rapp_net::crypto::{pw_hash,random_password}`。可以用 `rapp_net::log::{Log,Lvl}` 和 `rapp_net::config::{read_json,write_json,write_private}`。
- 新包名 `rapp-relay2`，二进制名 `rapp-relay2`（旧的 `rapp-relay` 还在工作区里，不能重名）。镜像里把它装成 `/usr/local/bin/rapp-relay`。
- relay 的代码里不出现业务词：app、session、便签、文件、剪贴板。
- 永远不进任何日志、任何落盘文件的：key、"根"、入网口令（只落它的哈希）、信任口令、私钥（只在 `relay.key` 里）。
- 数据卷里的文件 0600，目录 0700；写文件用 `rapp_net::config::write_private`（先写临时文件再改名）。
- 默认值照规格的原样：监听 `0.0.0.0:21116`；ALPN `rapp-relay/2`；一行最长 8 KiB（8192 字节）；每条连接并发流 128；每个来源地址连接数 16；总连接数 4096；每台设备同时被中继的流 32；入网设备数 1024；没入网的连接 10 秒没动静就断；每个来源地址每分钟入网 10 次；失败退避 `min(2^(n-5), 300)` 秒，前 4 次不锁；审计留 180 天、256 MB；探测的界线 5 秒、8 KiB。
- 租户第一版恒为 `"default"`，但每条设备记录、每条审计记录都带 `tenant` 字段。
- 提交信息沿用仓库的写法：`feat(relay2): …`、`test(relay2): …`、`docs: …`。
- 每个任务结束时 `cd rust && cargo test -p rapp-wire -p rapp-relay2` 全过，`cargo clippy -p rapp-wire -p rapp-relay2 -- -D warnings` 无警告。

## Review Focus

规格没有明说、测试里要钉住的五种情况：

1. **数据目录不存在或不可写**：启动时报出是哪个目录、哪种错，退出码非 0；不留半个文件。（任务 5）
2. **同一台设备从新地址重连，旧连接还没断**：新的登记顶掉旧的，旧连接被关；`connect` 找到的是新的那条。（任务 9）
3. **两台设备同时抢登记同一个新 ID**：恰好一台成功，另一台得到 `id taken`，登记簿里只有一条。（任务 9）
4. **来源地址是 IPv6 或 IPv4 映射的 IPv6**：按来源地址的限额把 `::ffff:1.2.3.4` 和 `1.2.3.4` 算作同一个来源。（任务 7）
5. **登记簿写盘失败（磁盘满、只读）**：`enroll` 回错误，内存里也不记这台设备，原文件不被破坏。（任务 5、8）

---

## File Structure

```
rust/Cargo.toml                    Modify：members 加 "wire"、"relay2"；workspace.dependencies 加 ring、x509-parser、data-encoding、rapp-wire、rapp-relay2
rust/wire/Cargo.toml               Create
rust/wire/src/lib.rs               Create：pub mod fp, key, identity, tls, line, msg
rust/wire/src/fp.rs                指纹
rust/wire/src/key.rs               key 的解析、生成、推导
rust/wire/src/identity.rs          设备（或 relay）的密钥和自签证书
rust/wire/src/tls.rs               quinn 的服务端、客户端配置；取对端指纹
rust/wire/src/line.rs              一行 JSON 的读写，8 KiB 上限
rust/wire/src/msg.rs               relay 协议的消息
rust/relay2/Cargo.toml             Create
rust/relay2/src/lib.rs             Relay::start / stop；pub mod
rust/relay2/src/config.rs          配置三层
rust/relay2/src/store.rs           登记簿
rust/relay2/src/audit.rs           审计日志
rust/relay2/src/limits.rs          限速和上限
rust/relay2/src/server.rs          接入、准入、四个请求、接流
rust/relay2/src/admin.rs           管理套接字（服务端和客户端）
rust/relay2/src/metrics.rs         统计行和指标接口
rust/relay2/src/main.rs            子命令
rust/relay2/tests/common/mod.rs    TestRelay、FakeDevice
rust/relay2/tests/*.rs             每个任务一个文件
docker/relay/Dockerfile            Create
docker/relay/docker-compose.yml    Create
docker/relay/README.md             Create
scripts/build-relay-image.sh       Create
```

---

### Task 1: 工作区和指纹、设备身份

**Files:**
- Modify: `rust/Cargo.toml`
- Create: `rust/wire/Cargo.toml`、`rust/wire/src/lib.rs`、`rust/wire/src/fp.rs`、`rust/wire/src/identity.rs`

**Interfaces:**
- Produces:
  - `pub struct Fp(pub [u8; 32]);`，`impl Display`（64 位小写十六进制）、`FromStr`、`Clone + Copy + Eq + Hash + Ord`、serde 按十六进制字符串。
  - `impl Fp { pub fn of_cert(der: &[u8]) -> anyhow::Result<Fp>; pub fn short(&self) -> String /* 前 8 位十六进制 */; pub fn prefix16(&self) -> [u8; 16] }`
  - `pub struct Identity { pub cert: CertificateDer<'static>, pub key: PrivatePkcs8KeyDer<'static>, pub fp: Fp }`
  - `impl Identity { pub fn generate() -> anyhow::Result<Identity>; pub fn load_or_create(dir: &Path, stem: &str) -> anyhow::Result<Identity> }`。文件是 `<dir>/<stem>.key`（PKCS#8 DER）和 `<dir>/<stem>.crt`（证书 DER）。

- [ ] **Step 1: 写失败的测试**（`rust/wire/src/fp.rs`、`identity.rs` 里的 `#[cfg(test)]`）

```rust
#[test] fn fp_is_sha256_of_spki_not_of_whole_cert() {
    let id = Identity::generate().unwrap();
    let spki = x509_parser::parse_x509_certificate(&id.cert).unwrap().1.public_key().raw.to_vec();
    assert_eq!(id.fp.0.as_slice(), ring::digest::digest(&ring::digest::SHA256, &spki).as_ref());
    assert_eq!(Fp::of_cert(&id.cert).unwrap(), id.fp);
}
#[test] fn fp_text_roundtrip_and_short() {
    let fp = Identity::generate().unwrap().fp;
    let s = fp.to_string();
    assert_eq!(s.len(), 64); assert_eq!(s.parse::<Fp>().unwrap(), fp); assert_eq!(fp.short(), &s[..8]);
    assert!("zz".parse::<Fp>().is_err());
}
#[test] fn of_cert_rejects_garbage() { assert!(Fp::of_cert(b"not a cert").is_err()); }
#[test] fn load_or_create_is_stable_and_private() {
    let d = tempfile::tempdir().unwrap();
    let a = Identity::load_or_create(d.path(), "device").unwrap();
    let b = Identity::load_or_create(d.path(), "device").unwrap();
    assert_eq!(a.fp, b.fp);
    #[cfg(unix)] { use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(d.path().join("device.key")).unwrap().permissions().mode() & 0o777, 0o600); }
}
#[test] fn two_identities_differ() { assert_ne!(Identity::generate().unwrap().fp, Identity::generate().unwrap().fp); }
```

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-wire`，预期：编译不过（类型不存在）。
- [ ] **Step 3: 实现。** 密钥用 `rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)`；证书的名字固定为 `rapp`，有效期用 rcgen 的默认值（验证时不看）。`.key` 文件只存在一半（有 key 没 crt）时重新生成两个。
- [ ] **Step 4: 跑测试确认通过** — `cargo test -p rapp-wire`，预期 5 个通过。
- [ ] **Step 5: 提交** — `git add rust/Cargo.toml rust/Cargo.lock rust/wire && git commit -m "feat(wire): fingerprints and device identity"`

### Task 2: key

**Files:**
- Create: `rust/wire/src/key.rs`

**Interfaces:**
- Consumes: `Fp::prefix16`。
- Produces:
  - `pub struct Key { pub relay: Option<[u8; 16]>, pub root: [u8; 16] }`
  - `impl Key { pub fn new_for_relay(relay_fp: &Fp) -> Key; pub fn new_local() -> Key; pub fn join(&self) -> [u8; 32]; pub fn trust(&self) -> [u8; 32]; pub fn matches_relay(&self, fp: &Fp) -> bool }`
  - `impl Display for Key`、`impl FromStr for Key`：小写、无填充的 base32。有 relay 的是 32 字节（52 个字符），没有的是 16 字节（26 个字符）。解析时先去掉首尾空白并转小写。
  - `pub fn join_hash(join: &[u8; 32]) -> String`：SHA-256 的十六进制。
  - 推导：HKDF-SHA-256，盐为空，输入是 `root`，标签分别是 `b"rapp join/1"` 和 `b"rapp trust/1"`，各取 32 字节。
  - `Key` 不实现 `Debug`、不实现 serde（防止误打进日志）。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn text_roundtrip_both_kinds() {
    let fp = Identity::generate().unwrap().fp;
    let k = Key::new_for_relay(&fp); let s = k.to_string();
    assert_eq!(s.len(), 52); assert!(s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
    let back: Key = format!("  {}\n", s.to_uppercase()).parse().unwrap();
    assert_eq!(back.root, k.root); assert_eq!(back.relay, Some(fp.prefix16())); assert!(back.matches_relay(&fp));
    let l = Key::new_local(); assert_eq!(l.to_string().len(), 26); assert!(l.to_string().parse::<Key>().unwrap().relay.is_none());
}
#[test] fn bad_text_is_rejected() { for s in ["", "abc", "0189", &"a".repeat(51), &"a".repeat(53)] { assert!(s.parse::<Key>().is_err()); } }
#[test] fn join_and_trust_are_independent_and_deterministic() {
    let k = Key::new_local();
    assert_eq!(k.join(), k.join()); assert_ne!(k.join(), k.trust());
    assert_ne!(Key::new_local().join(), k.join());
}
#[test] fn derivation_is_pinned() {   // 固定向量：防止以后改了标签而不自知
    let k = Key { relay: None, root: [7u8; 16] };
    assert_eq!(hex(&k.join()), "<实现后填入一次算出的值>"); assert_eq!(hex(&k.trust()), "<同上>");
}
#[test] fn wrong_relay_does_not_match() { let a = Identity::generate().unwrap().fp; let b = Identity::generate().unwrap().fp; assert!(!Key::new_for_relay(&a).matches_relay(&b)); }
```

- [ ] **Step 2: 跑测试确认失败** — `cargo test -p rapp-wire key`。
- [ ] **Step 3: 实现。** `derivation_is_pinned` 里的两个十六进制值：实现后打印一次，核对两个值不同，再写进测试。随机数用 `ring::rand::SystemRandom`。
- [ ] **Step 4: 跑测试确认通过。**
- [ ] **Step 5: 提交** — `git commit -m "feat(wire): key format and derivations"`

### Task 3: TLS 配置、行协议、消息

**Files:**
- Create: `rust/wire/src/tls.rs`、`rust/wire/src/line.rs`、`rust/wire/src/msg.rs`

**Interfaces:**
- Produces（`tls.rs`）：
  - `pub const ALPN_RELAY: &[u8] = b"rapp-relay/2";`
  - `pub enum Expect { Pin([u8; 16]), Any }`（`Pin`：对端指纹的前 16 字节必须相等；`Any`：只给测试和自检用）
  - `pub fn server_config(id: &Identity, alpn: &[u8], max_streams: u32) -> anyhow::Result<quinn::ServerConfig>`：只开 TLS 1.3；**要求**客户端出示证书，证书的签名要验（证明对方有私钥），其余不看；保活 10 秒，空闲 30 秒。
  - `pub fn client_config(id: &Identity, alpn: &[u8], expect: Expect) -> anyhow::Result<quinn::ClientConfig>`：出示本机证书；按 `expect` 核对服务端。
  - `pub fn peer_fp(conn: &quinn::Connection) -> anyhow::Result<Fp>`
  - `pub const SNI: &str = "rapp";`
  - `pub type BiStream = tokio::io::Join<quinn::RecvStream, quinn::SendStream>; pub fn bi(pair: (quinn::SendStream, quinn::RecvStream)) -> BiStream`
- Produces（`line.rs`）：`pub const MAX_LINE: usize = 8192; pub async fn read_json<R: AsyncRead + Unpin>(r: &mut R) -> anyhow::Result<serde_json::Value>`（超长、不是 JSON、流在行尾之前结束：都是错误）；`pub async fn write_json<W: AsyncWrite + Unpin, T: Serialize>(w: &mut W, v: &T) -> anyhow::Result<()>`；`pub fn ok(extra: Value) -> Value`（`{"ok":true,…}`）；`pub fn err(msg: &str) -> Value`（`{"ok":false,"error":msg}`）。
- Produces（`msg.rs`）：

```rust
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Req {                       // 设备 → relay，每个请求一条双向流
    Enroll { join: String },         // 入网口令，64 位十六进制
    Register { id: String, lan: Vec<String> },
    Connect { id: String },
    Relay { id: String },
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Push {                      // relay → 设备
    Incoming { peer: String, fp: Fp },        // 双向流，设备回 {"ok":true}
    Relayed { peer: String, fp: Fp },         // 双向流，这一行之后就是对方的字节
    Revoked { fps: Vec<Fp> },                 // 单向流
    GoingAway { after_ms: u64 },              // 单向流
}
pub fn is_valid_id(id: &str) -> bool;         // 9 位数字，首位不是 0
pub const MAX_LAN: usize = 16;                // register 里 lan 最多 16 项，每项最长 64 字节
```

  错误文本（`error` 字段）的全集：`bad request`、`bad key`、`no key`、`closed`、`limit`、`not enrolled`、`bad id`、`id taken`、`unknown id`、`offline`、`locked, retry in <N>s`、`redirect`。
  连接的关闭码：`0` 正常，`2` 被吊销，`3` 撞到连接上限。

- [ ] **Step 1: 写失败的测试**

```rust
// tls.rs
#[tokio::test] async fn mutual_tls_gives_each_side_the_others_fp() { /* 起服务端端点和客户端端点；连上；assert peer_fp(客户端连接)==服务端 id.fp；assert peer_fp(服务端连接)==客户端 id.fp */ }
#[tokio::test] async fn client_rejects_a_server_whose_fp_does_not_match_the_pin() { /* Expect::Pin(别人的 prefix16) → connect 返回 Err */ }
#[tokio::test] async fn server_refuses_a_client_without_a_certificate() { /* 用 rustls 手工建一个 with_no_client_auth 的客户端配置 → 握手失败 */ }
#[tokio::test] async fn wrong_alpn_is_refused() { /* 客户端用 b"rapp-relay/1" → 握手失败 */ }
// line.rs
#[tokio::test] async fn line_longer_than_8k_is_an_error() { /* 写 8193 个字节不带换行 → read_json Err */ }
#[tokio::test] async fn truncated_line_is_an_error() { /* 写 {"a":1 然后关闭 → Err */ }
// msg.rs
#[test] fn wire_format_is_pinned() {
    assert_eq!(serde_json::to_value(Req::Connect { id: "123456789".into() }).unwrap(), json!({"op":"connect","id":"123456789"}));
    assert!(serde_json::from_value::<Req>(json!({"op":"connect","id":"1","key":"x"})).is_err());   // 多余字段拒绝
    assert!(serde_json::from_value::<Req>(json!({"op":"open","app":"x"})).is_err());
    assert!(is_valid_id("123456789") && !is_valid_id("012345678") && !is_valid_id("12345678"));
}
```

- [ ] **Step 2: 跑测试确认失败。**
- [ ] **Step 3: 实现。** 服务端用自定义的 `ClientCertVerifier`：`client_auth_mandatory()` 返回 true；`verify_client_cert` 只确认证书能被 `x509_parser` 解析；`verify_tls13_signature` 交给 `rustls::crypto::verify_tls13_signature` 和 ring 的算法表。客户端用自定义的 `ServerCertVerifier`，同样验签名，再按 `Expect` 比指纹。
- [ ] **Step 4: 跑测试确认通过。**
- [ ] **Step 5: 提交** — `git commit -m "feat(wire): mutual TLS configs, line framing, relay messages"`

### Task 4: 配置

**Files:**
- Create: `rust/relay2/Cargo.toml`、`rust/relay2/src/lib.rs`、`rust/relay2/src/config.rs`

**Interfaces:**
- Produces:

```rust
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Config { pub listen: SocketAddr, pub enroll: Enroll, pub log: LogLevel, pub audit: AuditCfg, pub metrics: Option<SocketAddr>, pub limits: Limits }
pub enum Enroll { Open, Closed }            // 文本 "open" / "closed"
pub enum LogLevel { Info, Debug }           // "info" / "debug"
pub struct AuditCfg { pub keep_days: u32, pub max_mb: u64, pub required: bool }
pub struct Limits { pub max_conns: usize, pub max_conns_per_ip: usize, pub max_streams: u32, pub max_relayed_per_device: usize,
    pub max_devices: usize, pub unenrolled_idle_secs: u64, pub enroll_per_ip_per_min: u32,
    pub relay_bps_per_stream: u64, pub relay_bps_total: u64 }            // 后两项 0 表示不限
impl Default for Config;                                                // 值见 Global Constraints
pub fn load(data: &Path, env: &dyn Fn(&str) -> Option<String>) -> anyhow::Result<Config>;
```

  文件是 `<data>/config.json`，结构和 `Config` 一样、每一项都可省略。环境变量：`RAPP_RELAY_LISTEN`、`RAPP_RELAY_ENROLL`、`RAPP_RELAY_LOG`、`RAPP_RELAY_AUDIT_KEEP_DAYS`、`RAPP_RELAY_AUDIT_MAX_MB`、`RAPP_RELAY_AUDIT_REQUIRED`、`RAPP_RELAY_METRICS`、`RAPP_RELAY_LIMIT_<项名大写>`（如 `RAPP_RELAY_LIMIT_MAX_CONNS`）。`metrics` 的地址必须是回环地址。

- [ ] **Step 1: 写失败的测试**（`config.rs` 里）

```rust
#[test] fn defaults_without_file_or_env() { let d = tempdir(); let c = load(d.path(), &|_| None).unwrap(); assert_eq!(c, Config::default());
    assert_eq!(c.listen.to_string(), "0.0.0.0:21116"); assert_eq!(c.limits.max_streams, 128); assert_eq!(c.audit.keep_days, 180); }
#[test] fn env_overrides_file_overrides_default() { /* 文件写 {"listen":"0.0.0.0:1","audit":{"keep_days":7}}；env 给 RAPP_RELAY_LISTEN=0.0.0.0:2 → listen 端口 2，keep_days 7，max_mb 256 */ }
#[test] fn unknown_key_in_file_refuses_to_start_and_names_it() { /* {"lisen":"x"} → Err，消息里含 "lisen" */ }
#[test] fn bad_value_names_the_item() { /* RAPP_RELAY_ENROLL=maybe → Err 含 "RAPP_RELAY_ENROLL" */ }
#[test] fn metrics_must_be_loopback() { /* RAPP_RELAY_METRICS=0.0.0.0:9116 → Err */ }
#[test] fn effective_config_serializes_without_secrets() { /* to_value(Config::default()) 的键集合正好是六个顶层项 */ }
```

- [ ] **Step 2–4:** 跑失败 → 实现（文件用带 `deny_unknown_fields` 的"全可省略"结构反序列化，再叠到默认值上）→ 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): layered config"`

### Task 5: 登记簿

**Files:**
- Create: `rust/relay2/src/store.rs`

**Interfaces:**
- Produces:

```rust
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
pub struct Device { pub fp: Fp, pub tenant: String, pub id: Option<String>, pub enrolled_at: String /* RFC 3339 UTC */, pub revoked: bool }
pub trait Registry: Send + Sync {
    fn get(&self, fp: &Fp) -> Option<Device>;
    fn by_id(&self, id: &str) -> Option<Device>;
    fn list(&self) -> Vec<Device>;
    fn count(&self) -> usize;                               // 不含已吊销的
    fn enroll(&self, fp: Fp, tenant: &str) -> anyhow::Result<()>;      // 已在：幂等
    fn bind_id(&self, fp: &Fp, id: &str) -> anyhow::Result<Bind>;      // Bind::{New, Same, Taken}
    fn unbind(&self, id: &str) -> anyhow::Result<bool>;
    fn revoke(&self, fp: &Fp) -> anyhow::Result<bool>;
    fn revoked(&self) -> Vec<Fp>;
    fn join_hash(&self) -> Option<String>;
    fn set_join_hash(&self, hash: &str) -> anyhow::Result<()>;
}
pub struct FileRegistry;  impl FileRegistry { pub fn open(data: &Path) -> anyhow::Result<FileRegistry> }
```

  落盘：`<data>/devices.json`（`{"version":1,"devices":[…]}`）和 `<data>/join`（一行十六进制）。每次改动先写盘成功，再改内存。`open` 时目录不存在就建（0700）；建不了、读不了、版本不认识：返回带路径的错误。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn enroll_bind_revoke_persist_across_reopen() { /* enroll → bind_id "123456789" == New → 重新 open → by_id 找得到；revoke → revoked() 含它，count() 少一 */ }
#[test] fn an_id_belongs_to_the_first_key_that_registers_it() { /* 另一台 bind 同 ID == Taken；原主再 bind == Same；unbind 后别人 bind == New */ }
#[test] fn concurrent_bind_of_one_new_id_has_exactly_one_winner() { /* 两个线程各 enroll 自己再 bind 同一 ID：一个 New 一个 Taken；list() 里该 ID 只出现一次 */ }   // Review Focus 3
#[test] fn write_failure_leaves_memory_and_file_untouched() { /* 把数据目录改成只读（unix）后 enroll → Err；get(fp) 为 None；再改回可写后 reopen，原内容还在 */ }   // Review Focus 5
#[test] fn open_reports_which_directory_failed() { /* data 指向一个普通文件 → Err，消息含那个路径 */ }   // Review Focus 1
#[test] fn files_are_private() { /* devices.json、join 的权限是 0600 */ }
```

- [ ] **Step 2–4:** 跑失败 → 实现（一把 `Mutex` 包住内存表；`bind_id` 的检查和写入在同一把锁里）→ 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): device registry"`

### Task 6: 审计日志

**Files:**
- Create: `rust/relay2/src/audit.rs`

**Interfaces:**
- Produces:

```rust
pub struct Audit;   // Clone，内部 Arc
impl Audit {
    pub fn open(data: &Path, cfg: &AuditCfg, mirror: Log) -> anyhow::Result<Audit>;
    pub fn event(&self, ev: &str, fields: serde_json::Value, urgent: bool) -> bool;   // 返回 false：没写进去
    pub fn probe(&self, from: &Fp, to: &str);                                          // 计一次在线探测
    pub fn flush(&self);
    pub fn healthy(&self) -> bool;                                                     // 上一次写入是否成功
    pub fn prune(&self, now: SystemTime);                                              // 删过期的，留一条 audit_prune
}
pub fn read(data: &Path, since: Option<SystemTime>, id: Option<&str>, event: Option<&str>) -> anyhow::Result<Vec<serde_json::Value>>;
```

  文件：`<data>/audit/YYYY-MM-DD.jsonl`（UTC 日期），只追加，0600。每行 `{"t":"2026-11-13T10:00:00.123Z","ev":"…","tenant":"default",…}`；`fields` 里的键原样并入。`urgent` 为 true 时立刻落盘，否则最多攒 1 秒。每条同时用 `mirror.event(Lvl::Info, ev, fields + {"audit":true})` 写到标准错误。探测按"发起方指纹 + 目标 ID"累计，每个整点各写一行 `{"ev":"probes","from":…,"to":…,"n":…}`。超过 `keep_days` 或总量超过 `max_mb`：从最旧的整天文件删起，今天的不删。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn event_lands_in_todays_file_with_time_tenant_and_fields() { /* event("enroll", json!({"fp":"ab","result":"ok"}), true) → 当天文件最后一行解析后 ev=="enroll"、tenant=="default"、t 以 Z 结尾、含 fp 和 result */ }
#[test] fn file_is_private_and_append_only_across_reopen() { /* 写一条 → reopen → 再写一条 → 两行都在；权限 0600 */ }
#[test] fn probes_are_merged_per_pair_per_hour() { /* probe 同一对 5 次、另一对 2 次 → flush_probes 后恰好两行，n 分别是 5 和 2 */ }
#[test] fn prune_removes_old_days_and_records_it() { /* 造三个旧日期文件，keep_days=1 → prune 后旧文件没了；今天文件里有 audit_prune，days 列出被删的日期 */ }
#[test] fn prune_by_size_keeps_today() { /* max_mb 设成 0 → 旧文件全删，今天的还在 */ }
#[test] fn unwritable_dir_reports_unhealthy_instead_of_panicking() { /* audit 目录改只读 → event 返回 false，healthy()==false */ }
#[test] fn read_filters_by_since_id_and_event() { /* 写几条不同 ev、不同 id → read 各过滤条件 */ }
```

- [ ] **Step 2–4:** 跑失败 → 实现（另加 `#[doc(hidden)] pub fn flush_probes(&self)`，把攒着的探测立刻写成 `probes` 行；整点时内部也调它，集成测试直接调它）→ 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): audit log"`

### Task 7: 限速和上限

**Files:**
- Create: `rust/relay2/src/limits.rs`

**Interfaces:**
- Produces:

```rust
pub fn source_key(ip: IpAddr) -> IpAddr;            // ::ffff:a.b.c.d → a.b.c.d；其余原样
pub struct Backoff;                                  // 失败退避，按任意字符串键
impl Backoff { pub fn locked(&self, key: &str, now: Instant) -> Option<u64>; pub fn fail(&self, key: &str, now: Instant) -> Option<u64>; pub fn reset(&self, key: &str) }
pub struct Rate;                                     // 每个键每分钟 N 次的滑动窗口
impl Rate { pub fn new(per_min: u32) -> Rate; pub fn allow(&self, key: &str, now: Instant) -> bool }
pub struct Conns;                                    // 连接计数
impl Conns { pub fn new(total: usize, per_ip: usize) -> Conns; pub fn admit(&self, ip: IpAddr) -> Option<ConnGuard> /* Drop 时减一 */ }
pub struct Bucket;                                   // 令牌桶，字节每秒；0 表示不限
impl Bucket { pub fn new(bps: u64) -> Bucket; pub async fn take(&self, n: usize) }
```

  `Backoff`：第 5 次连续失败起锁，第 n 次锁 `min(2^(n-5), 300)` 秒；`fail` 返回这次锁多久（没锁返回 `None`）；表最多 100000 个键，满了先清掉已过期的。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn v4_mapped_v6_is_the_same_source() { assert_eq!(source_key("::ffff:1.2.3.4".parse().unwrap()), "1.2.3.4".parse::<IpAddr>().unwrap()); }   // Review Focus 4
#[test] fn backoff_follows_the_formula() { /* 4 次失败不锁；第 5 次锁 1 秒；第 6 次 2 秒；第 14 次起 300 秒；reset 后清零 */ }
#[test] fn rate_allows_n_per_minute_per_key() { /* new(10)：同一键前 10 次 true，第 11 次 false；61 秒后又 true；另一个键不受影响 */ }
#[test] fn conns_enforces_per_ip_and_total_and_releases_on_drop() { /* new(3,2)：同 IP 第 3 个 None；v4 映射地址和 v4 算同一个；drop 一个后又能进；总数满时别的 IP 也 None */ }
#[tokio::test] async fn bucket_zero_is_unlimited_and_nonzero_paces() { /* new(0).take(1<<30) 立刻返回；new(1000) 取 3000 字节至少用 1.5 秒（用 tokio::time::pause） */ }
```

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): limits"`

### Task 8: 服务：接入、准入、入网

**Files:**
- Create: `rust/relay2/src/server.rs`、`rust/relay2/tests/common/mod.rs`、`rust/relay2/tests/enroll.rs`
- Modify: `rust/relay2/src/lib.rs`

**Interfaces:**
- Consumes: `Config`、`FileRegistry`、`Audit`、`limits::*`、`rapp_wire::*`。
- Produces:

```rust
pub struct Opts { pub data: PathBuf, pub config: Config, pub log: Log }
pub struct Relay { pub addr: SocketAddr, pub fp: Fp, /* … */ }
impl Relay { pub async fn start(opts: Opts) -> anyhow::Result<Relay>; pub async fn stop(self);
    pub fn registry(&self) -> Arc<dyn Registry>; pub fn audit(&self) -> &Audit }   // 后两个给测试和管理模块用
// tests/common/mod.rs
pub struct TestRelay { pub relay: Relay, pub data: TempDir, pub key: Key }
pub async fn start_relay(tweak: impl FnOnce(&mut Config)) -> TestRelay;      // 监听 127.0.0.1:0；已生成 key（直接调登记簿 set_join_hash）；日志用 Log::file(<临时目录>, "relay.log")，便于测试搜索
pub struct FakeDevice { pub id: Identity, pub conn: quinn::Connection, pub pushes: mpsc::UnboundedReceiver<(Push, Option<BiStream>)> }
impl FakeDevice {
    pub async fn dial(r: &TestRelay) -> FakeDevice;                           // 新身份，Expect::Pin(relay 指纹)
    pub async fn dial_as(r: &TestRelay, id: Identity) -> anyhow::Result<FakeDevice>;
    pub async fn req(&self, req: &Req) -> serde_json::Value;                  // 开流、发一行、读一行
    pub async fn enroll(&self, key: &Key) -> serde_json::Value;
}
pub fn audit_lines(r: &TestRelay, ev: &str) -> Vec<serde_json::Value>;
```

  行为（§6.4、§9.2）：对每个到来的连接先做 QUIC 地址验证（没验证过的回 Retry）；`Conns::admit` 不过就以关闭码 3 关掉；握手后取对端指纹，已吊销的以关闭码 2 关掉；没入网的连接只接受 `enroll`，别的请求回 `not enrolled`，10 秒内没有成功入网就关掉。`enroll`：入网关着回 `closed`；relay 还没有 key 回 `no key`；来源被 `Rate` 挡住回 `limit`；设备数到上限回 `limit`；口令的哈希和登记簿里的做常量时间比较，不对回 `bad key` 并记一次 `Backoff`（键是来源地址）；被锁着回 `locked, retry in <N>s`；成功回 `{"ok":true,"relay":{"version":…,"features":[]}}`。每次尝试记一条审计 `enroll`（`fp`、`from`、`result`，`urgent`）。启动时记 `relay_start`（版本、生效的配置），停止时记 `relay_stop`。

- [ ] **Step 1: 写失败的测试**（`tests/enroll.rs`）

```rust
#[tokio::test] async fn right_key_enrolls_and_is_audited() { /* enroll → ok==true；登记簿里有这个指纹，tenant=="default"；audit enroll 一行 result=="ok"，fp 是完整 64 位 */ }
#[tokio::test] async fn wrong_key_is_refused_audited_and_backs_off() { /* 另一个 Key → "bad key"；连错 5 次后第 6 次回 "locked, retry in …"；audit 有 lockout */ }
#[tokio::test] async fn unenrolled_device_can_do_nothing_else() { /* 没入网直接 register/connect/relay → "not enrolled" */ }
#[tokio::test] async fn unenrolled_connection_is_dropped_after_idle() { /* unenrolled_idle_secs=1 → 2 秒后 conn.closed() */ }
#[tokio::test] async fn closed_enrollment_refuses_even_the_right_key() { /* enroll=Closed → "closed" */ }
#[tokio::test] async fn relay_without_a_key_says_so() { /* 登记簿里没有 join → "no key" */ }
#[tokio::test] async fn enrollment_survives_reconnect_and_restart() { /* 入网 → 断开 → 同一身份重连 → 直接 register 不回 not enrolled；relay 停掉再用同一数据目录启动，仍然如此 */ }
#[tokio::test] async fn device_cap_and_per_ip_rate_are_enforced() { /* max_devices=1：第二台 "limit"；enroll_per_ip_per_min=2：第三次 "limit" */ }
#[tokio::test] async fn a_failed_registry_write_does_not_enroll() { /* 数据目录改只读 → enroll 回错误（ok==false）；改回后重连，仍是没入网 */ }   // Review Focus 5
#[tokio::test] async fn a_device_pinning_the_wrong_relay_fails_the_handshake() { /* Expect::Pin(别的指纹) → dial_as 返回 Err */ }
#[tokio::test] async fn connection_cap_closes_with_code_3() { /* max_conns_per_ip=1：第二条连接被关，关闭码 3 */ }
#[tokio::test] async fn oversized_and_malformed_requests_get_bad_request_not_a_crash() { /* 9000 字节的一行；不是 JSON；{"op":"nope"}：都回 "bad request" 或流被关，relay 之后仍能服务 */ }
```

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过（`cargo test -p rapp-relay2 --test enroll`）。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): transport, admission, enrollment"`

### Task 9: 登记、牵线、吊销名单

**Files:**
- Modify: `rust/relay2/src/server.rs`、`rust/relay2/tests/common/mod.rs`
- Create: `rust/relay2/tests/introduce.rs`

**Interfaces:**
- Produces（给测试用的辅助）：`impl FakeDevice { pub async fn enrolled(r: &TestRelay) -> FakeDevice; pub async fn register(&self, id: &str, lan: &[&str]) -> Value; pub async fn connect_to(&self, id: &str) -> Value }`；`FakeDevice` 的后台任务：收到 `Incoming` 自动回 `{"ok":true}` 并把它放进 `pushes`。
- 行为（§5.1、§6.3、§7.4、§8）：
  - `register`：ID 不合法回 `bad id`；`lan` 超过 16 项或某项超过 64 字节回 `bad request`；`bind_id` 得到 `Taken` 回 `id taken`；成功后在线表里 `id → (连接, lan, 指纹, 租户)`，同一个 ID 已有另一条连接时把旧连接关掉（审计结果 `replaced`）。成功后立刻给这条连接推一次 `Revoked`（名单为空也推）。
  - `connect`：目标不存在回 `unknown id`；不在线、不同租户、或者 `incoming` 2 秒内没得到 `{"ok":true}` 回 `offline`；成功回 `{"ok":true,"lan":[…],"public":"<relay 看到的目标地址>"}`。限速：发起方指纹、来源地址、目标 ID 三个键各自的 `Backoff`，对 `unknown id` 和 `offline` 计失败。
  - 连接断开：把它从在线表里拿掉（只在它还是登记的那一条时）。
  - 审计：`register`（`fp`、`id`、`from`、`result`：`new`/`ok`/`replaced`/`id taken`）、`connect`（`fp`、`from`、`to`、`result`）。

- [ ] **Step 1: 写失败的测试**

```rust
#[tokio::test] async fn connect_returns_addresses_and_notifies_the_target() { /* A register("123456789", ["192.168.1.5:21118"])；B connect_to → ok，lan 相同，public 的 IP 是 127.0.0.1；A 的 pushes 收到 Incoming，fp==B 的指纹，peer==B 的地址 */ }
#[tokio::test] async fn unknown_and_offline_are_told_apart() { /* 没人登记的 ID → "unknown id"；A 登记后断开 → "offline" */ }
#[tokio::test] async fn an_id_cannot_be_taken_by_another_key() { /* C 登记 A 的 ID → "id taken"；audit register result=="id taken" */ }
#[tokio::test] async fn a_new_registration_replaces_the_old_connection() { /* 同一身份开第二条连接并登记 → 第一条被关；B connect_to 时 Incoming 落在第二条上；audit 有 "replaced" */ }   // Review Focus 2
#[tokio::test] async fn two_devices_racing_for_one_id_have_one_winner() { /* 两台同时 register 同一新 ID → 恰好一个 ok */ }   // Review Focus 3
#[tokio::test] async fn target_that_does_not_answer_incoming_is_offline() { /* 一个不回 Incoming 的假设备 → 2 秒后 "offline" */ }
#[tokio::test] async fn revoked_list_is_pushed_on_register() { /* 先吊销 X（直接调登记簿）→ A 登记后 pushes 里有 Revoked 且含 X */ }
#[tokio::test] async fn a_revoked_device_is_cut_off_and_cannot_come_back() { /* 吊销在线的 A（Relay::revoke，下个任务的管理命令也调它）→ A 的连接以关闭码 2 关闭；A 重连同样被关；其余在线设备收到新的 Revoked */ }
#[tokio::test] async fn hammering_connect_backs_off() { /* 对不存在的 ID connect 5 次 → 第 6 次 "locked, retry in …" */ }
#[tokio::test] async fn bad_id_and_oversized_lan_are_rejected() { /* register("12", …) → "bad id"；17 项 lan → "bad request" */ }
```

  为第 8 个测试，本任务在 `Relay` 上加：`pub async fn revoke(&self, fp: &Fp) -> anyhow::Result<bool>`（登记簿吊销、断开它、向所有在线设备推新的名单、记审计 `revoke`）。

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): register, connect, revocation list"`

### Task 10: 接流

**Files:**
- Modify: `rust/relay2/src/server.rs`、`rust/relay2/tests/common/mod.rs`
- Create: `rust/relay2/tests/splice.rs`

**Interfaces:**
- Produces（测试辅助）：`impl FakeDevice { pub async fn relay_to(&self, id: &str) -> anyhow::Result<BiStream> }`；后台任务收到 `Relayed` 时把 `(Push, Some(stream))` 放进 `pushes`。
- 行为（§5.1、§8、§9.2、§11.1）：`relay`：目标不存在或不在线回 `unknown id`/`offline`（JSON 一行）；目标正在被中继的流数到了 `max_relayed_per_device` 回 `limit`；否则在目标的连接上开一条双向流，写 `Relayed{peer,fp}`，然后把两条流双向对接（64 KiB 缓冲），不再写任何 JSON。两个方向的字节都经过 `Bucket`（每条流一个，加一个全局的）。结束时：5 秒以内且两个方向合计不到 8 KiB 的算探测，调 `audit.probe`；否则记审计 `relayed`（`fp`、`to`、`secs`、`up`、`down`）。relay 不读、不记流里的任何字节。

- [ ] **Step 1: 写失败的测试**

```rust
#[tokio::test] async fn bytes_cross_unchanged_both_ways() { /* B relay_to(A) → A 收到 Relayed + 流；B 写 1 MiB 随机字节，A 原样读到；A 写 300 KiB，B 原样读到；两头正常关闭 */ }
#[tokio::test] async fn a_real_stream_is_audited_with_sizes() { /* 上一个之后：audit relayed 一行，up>=1048576，down>=307200，to 是 A 的 ID，fp 是 B 的指纹 */ }
#[tokio::test] async fn a_short_small_stream_is_a_probe_not_a_relayed_line() { /* 传 100 字节立刻关 → 没有 relayed 行；flush_probes 后有 probes 行 n==1 */ }
#[tokio::test] async fn relay_to_offline_or_unknown_answers_in_json() { /* 读到一行 {"ok":false,"error":"offline"} / "unknown id" */ }
#[tokio::test] async fn per_device_stream_cap() { /* max_relayed_per_device=1：第二条 relay_to 读到 "limit" */ }
#[tokio::test] async fn one_side_closing_closes_the_other() { /* B 断开连接 → A 那条流读到结束 */ }
#[tokio::test] async fn relayed_content_never_reaches_logs_or_disk() { /* 传一个 32 字节的随机标记 → 数据目录下所有文件和 Log 的输出里都搜不到它 */ }
#[tokio::test] async fn bandwidth_cap_paces_the_stream() { /* relay_bps_per_stream=100_000：传 300 KB 用时不少于 2 秒 */ }
```

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): stream relay with metering"`

### Task 11: 管理套接字、子命令、优雅停止

**Files:**
- Create: `rust/relay2/src/admin.rs`、`rust/relay2/src/main.rs`、`rust/relay2/tests/admin.rs`
- Modify: `rust/relay2/src/server.rs`、`rust/relay2/src/lib.rs`

**Interfaces:**
- Produces（`admin.rs`）：服务端监听 `<data>/admin.sock`（0600），一条连接一行请求一行回复：

  | 请求 | 回复 |
  |---|---|
  | `{"cmd":"info"}` | `{"ok":true,"version","fp","listen","has_key":bool,"enroll":"open"\|"closed","devices":n,"online":n}` |
  | `{"cmd":"set_join","hash":"<64 hex>","rotate":bool}` | `rotate` 为 false 且已有 key：`{"ok":false,"error":"key exists"}`；否则存下，记审计 `key` 或 `rotate_key` |
  | `{"cmd":"devices"}` | `{"ok":true,"devices":[{"fp","id","enrolled_at","revoked","online":bool}]}` |
  | `{"cmd":"revoke","target":"<ID 或指纹或指纹前缀≥8 位>"}` | `{"ok":true,"fp"}`；找不到或前缀不唯一：错误 |
  | `{"cmd":"unbind","id"}` | `{"ok":true}`；记审计 `unbind` |
  | `{"cmd":"enroll","state":"open"\|"closed"}` | `{"ok":true}`；立刻生效并写进 `config.json` 的 `enroll`；记审计 `enroll_open`/`enroll_close` |

  `pub async fn call(data: &Path, req: serde_json::Value) -> anyhow::Result<serde_json::Value>`（客户端）。
- Produces（`main.rs` 的子命令；都接受 `--data <目录>`，默认 `/data`）：无子命令 = 启动服务；`key`；`rotate-key`；`devices`；`revoke <目标>`；`unbind <ID>`；`enroll open|closed`；`audit [--since <N>d|<N>h] [--id <ID>] [--event <名字>]`（直接读文件，一行一条原样输出）；`check`；`--version`。
  - `key`：`info` → 已有 key 时打印 `key 已经显示过。到任何一台已接入的设备的设置里查看；要换新的用 rotate-key。`，退出码 1；否则在本进程里 `Key::new_for_relay(fp)`，把 `join_hash(&key.join())` 用 `set_join` 发过去，成功后把 key 打印到标准输出一次。**"根"和 key 不进服务进程。**
  - `rotate-key`：同上，`rotate:true`，总是允许。
  - `check`：用一个临时身份、`Expect::Pin(<info 里的指纹前 16 字节>)` 连 `127.0.0.1:<listen 的端口>`，握手成功退出 0，否则 1。超时 3 秒。
- 行为（§9.3）：收到 SIGTERM 或 SIGINT：停止接新连接；给每条在线连接推 `GoingAway{after_ms:3000}`；记 `relay_stop`；`audit.flush()`；最多等 2 秒后退出。

- [ ] **Step 1: 写失败的测试**

```rust
#[tokio::test] async fn info_reports_state() { /* 起 relay（无 key）→ call info：has_key==false，fp 是 relay 的指纹，devices==0 */ }
#[tokio::test] async fn key_can_be_set_once_and_rotated() { /* set_join(rotate:false) ok；再来一次 "key exists"；rotate:true ok；audit 里依次有 key、rotate_key；旧 key 入网 "bad key"，新 key 入网 ok；已入网的设备不受影响 */ }
#[tokio::test] async fn the_root_never_reaches_the_server_side() { /* 用 key 子命令的逻辑生成 key 后：数据目录的所有文件和日志里搜不到 root 的十六进制、base32，也搜不到 trust()；join 文件里是哈希不是 join 本身 */ }
#[tokio::test] async fn revoke_by_id_fp_and_unique_prefix() { /* 三种 target 都能吊销；不唯一的前缀报错；吊销后连接以码 2 关闭 */ }
#[tokio::test] async fn enroll_switch_takes_effect_and_persists() { /* enroll closed → 入网 "closed"；config.json 里 enroll=="closed"；重启后仍关着 */ }
#[tokio::test] async fn unbind_frees_the_id() { /* unbind 后另一台设备能登记这个 ID */ }
#[tokio::test] async fn admin_socket_is_private() { /* admin.sock 权限 0600 */ }
#[tokio::test] async fn stop_tells_devices_before_closing() { /* relay.stop() → 在线设备的 pushes 先收到 GoingAway{after_ms:3000}，随后连接关闭；audit 末尾是 relay_stop */ }
// 进程级（用 env!("CARGO_BIN_EXE_rapp-relay2")）
#[test] fn cli_key_prints_once_then_refuses() { /* 起服务进程（--data 临时目录，RAPP_RELAY_LISTEN=127.0.0.1:0 不行→用一个空闲端口）；`key` 输出 52 个字符、退出 0；第二次退出 1 且输出不含 key */ }
#[test] fn cli_check_exits_zero_when_serving_and_one_when_not() {}
#[test] fn cli_refuses_to_start_on_bad_config_and_names_the_item() { /* RAPP_RELAY_ENROLL=maybe → 退出码非 0，stderr 含 RAPP_RELAY_ENROLL */ }
#[test] fn cli_refuses_to_start_when_data_dir_is_unusable() { /* --data 指向普通文件 → 退出码非 0，stderr 含那个路径 */ }   // Review Focus 1
```

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): admin socket, subcommands, graceful stop"`

### Task 12: 统计行和指标接口

**Files:**
- Create: `rust/relay2/src/metrics.rs`、`rust/relay2/tests/metrics.rs`
- Modify: `rust/relay2/src/server.rs`

**Interfaces:**
- Produces：`pub struct Stats`（原子计数器：`online`、`relayed_streams`、`relayed_bytes`、`handshake_failures`、`limited`、`audit_failures`）；`impl Stats { pub fn snapshot(&self) -> serde_json::Value; pub fn prometheus(&self) -> String }`。服务每 5 分钟用 `log.event(Lvl::Info, "stats", snapshot)` 记一行。`config.metrics` 有值时，在那个回环地址上起一个 TCP 监听，对任何请求回 `200` 和 `prometheus()` 的文本。指标名固定：`rapp_relay_online_devices`、`rapp_relay_relayed_streams`、`rapp_relay_relayed_bytes_total`、`rapp_relay_handshake_failures_total`、`rapp_relay_limited_total`、`rapp_relay_audit_failures_total`。
- `audit.required` 为 true 且 `audit.healthy()` 为 false 时：`enroll` 和 `connect` 回 `{"ok":false,"error":"limit"}`，并累加 `audit_failures`。

- [ ] **Step 1: 写失败的测试**

```rust
#[tokio::test] async fn metrics_are_off_by_default() { /* 默认配置下 127.0.0.1:9116 连不上 */ }
#[tokio::test] async fn metrics_endpoint_serves_the_fixed_names() { /* metrics=127.0.0.1:<空闲端口>；一台设备登记后 GET / → 含 "rapp_relay_online_devices 1" 和其余五个名字 */ }
#[tokio::test] async fn stats_line_has_the_counters() { /* 调 Stats::snapshot：六个键都在 */ }
#[tokio::test] async fn audit_required_refuses_when_audit_cannot_be_written() { /* audit.required=true，audit 目录改只读 → enroll 和 connect 回 "limit"；required=false 时照常 ok */ }
```

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): stats line and optional metrics endpoint"`

### Task 13: 防护性测试：机密、畸形输入、久跑

**Files:**
- Create: `rust/relay2/tests/secrets.rs`、`rust/relay2/tests/abuse.rs`、`rust/relay2/tests/soak.rs`

**Interfaces:**
- Consumes: 前面所有任务的测试辅助。

- [ ] **Step 1: 写测试**

```rust
// secrets.rs
#[tokio::test] async fn nothing_secret_is_written_anywhere() { /* 完整走一遍：生成 key、三台入网、登记、牵线、接流、吊销、换 key、停止。然后在数据目录所有文件和捕获的全部日志里搜：key 文本、root 的 hex 和 base32、join 的 hex、trust 的 hex、relay.key 的字节（relay.key 文件本身除外）→ 都搜不到 */ }
// abuse.rs
#[tokio::test] async fn random_bytes_on_request_streams_never_take_the_relay_down() { /* 固定种子，2000 次：随机长度 0..12000 的随机字节或被截断/篡改的合法请求；之后一台正常设备仍能入网、登记、被牵线 */ }
#[tokio::test] async fn many_idle_unenrolled_connections_are_shed() { /* 来自同一 IP 开 40 条 → 最多 16 条活着；10 秒（配置成 1 秒）后都被关 */ }
#[tokio::test] async fn stream_flood_is_bounded() { /* 一条连接同时开 500 条流只发半行 → 并发不超过 128，relay 内存里没有无界队列；正常设备仍可用 */ }
// soak.rs
#[tokio::test] #[ignore] async fn soak() { /* 环境变量 RAPP_SOAK_SECS（默认 600）：50 台假设备，持续登记、牵线、接流、断开重连；每 30 秒读一次进程常驻内存，末尾不高于第 2 分钟时的 1.2 倍 */ }
```

- [ ] **Step 2: 跑测试** — `cargo test -p rapp-relay2 --test secrets --test abuse`，预期通过；不通过就回到对应任务修。`soak` 手动跑一次 24 小时：`RAPP_SOAK_SECS=86400 cargo test -p rapp-relay2 --release --test soak -- --ignored`，把结果记进 `tasks/todo.md`。
- [ ] **Step 3: 提交** — `git commit -m "test(relay2): secrets scan, malformed input, soak"`

### Task 14: Docker 镜像

**Files:**
- Create: `docker/relay/Dockerfile`、`docker/relay/docker-compose.yml`、`docker/relay/README.md`、`scripts/build-relay-image.sh`
- Modify: `rust/Cargo.toml`（新增 profile）

**Interfaces:**
- Produces：
  - `rust/Cargo.toml` 新增 `[profile.relay]`：`inherits = "release"`、`lto = "fat"`、`codegen-units = 1`、`panic = "abort"`、`strip = true`、`opt-level = 3`。
  - `Dockerfile`：第一阶段 `rust:<固定版本>-alpine<固定版本>`，`apk add musl-dev`，`cargo build --profile relay -p rapp-relay2 --locked`；第二阶段 `alpine:<固定小版本>@sha256:<摘要>`，只 `COPY` 二进制到 `/usr/local/bin/rapp-relay`，`USER 10001:10001`，`VOLUME /data`，`EXPOSE 21116/udp`，`HEALTHCHECK --interval=30s --timeout=5s CMD ["rapp-relay","check"]`，`ENTRYPOINT ["rapp-relay"]`。不 `apk add` 任何运行时包。
  - `docker-compose.yml`：`image: ghcr.io/wizlijun/rapp-relay:<版本>`、`network_mode: host`、`read_only: true`、`cap_drop: [ALL]`、`security_opt: [no-new-privileges:true]`、`user: "10001:10001"`、`volumes: [rapp-relay-data:/data]`、`restart: unless-stopped`、`stop_grace_period: 10s`、`logging: {driver: json-file, options: {max-size: 10m, max-file: "5"}}`。
  - `scripts/build-relay-image.sh <版本> [--push]`：`docker buildx build --platform linux/amd64,linux/arm64 -f docker/relay/Dockerfile -t ghcr.io/wizlijun/rapp-relay:<版本> -t ghcr.io/wizlijun/rapp-relay:<主.次> .`；不带 `--push` 时只构建本机架构并 `--load`。
  - `README.md`：启动；放行 `21116/udp`；`docker exec rapp-relay rapp-relay key`；备份 `/data`（最要紧的是 `relay.key`、`devices.json`）；用日志驱动把审计送到别的机器的一个例子；§6.5 的命令表。

- [ ] **Step 1: 构建本机架构的镜像** — `scripts/build-relay-image.sh 0.0.0-dev`。脚本开头先跑 `cargo audit`（在 `rust/` 下；没装就报错并提示 `cargo install cargo-audit`），有已知漏洞就停。预期：成功，`docker image ls` 能看到。
- [ ] **Step 2: 容器内的冒烟检查**（在一台 Linux 主机上；写成 `docker/relay/smoke.sh`，逐项打印 PASS/FAIL）

  1. `docker compose up -d` 后 30 秒内 `docker inspect -f '{{.State.Health.Status}}'` 是 `healthy`。
  2. `docker exec rapp-relay id -u` 是 `10001`；`docker exec rapp-relay touch /x` 失败（只读根）。
  3. `docker exec rapp-relay rapp-relay key` 输出 52 个字符；第二次退出码 1。
  4. `docker compose down && docker compose up -d` 后，`/data/audit/` 里之前的记录还在。
  5. `docker stop` 时审计最后一条是 `relay_stop`。
  6. `docker image inspect` 的大小：记下数字。压缩后的大小用 `docker save | gzip | wc -c`，要求 ≤ 10 MB；超过就把实际数字和原因写进 README，并回报。
- [ ] **Step 3: 来源地址的实测（规格 §12、§20 第 5 条）。** 在一台有公网地址的 Linux 主机上用主机网络模式跑 relay；从另一个网络的机器上跑 `cargo run -p rapp-relay2 --example probe -- <主机:端口> <key>`（本任务新增的小例子：入网后打印 relay 审计里记下的 `from`，由操作者对照自己的公网出口地址）。预期：审计 `enroll` 行里的 `from` 是那台机器的公网出口地址，不是 Docker 网桥的地址。**这一步需要用户的 VPS；做不了就停下来回报，不要跳过。**
- [ ] **Step 4: 多架构构建** — `scripts/build-relay-image.sh 0.0.0-dev` 加 `--platform` 两种架构（不推送，用 `--output type=oci`）。预期：两种都构建成功。
- [ ] **Step 5: 提交** — `git commit -m "feat(relay2): Docker image, compose example, build script"`

### Task 15: 和旧 relay 的中继开销对比

**Files:**
- Create: `rust/relay2/tests/bench.rs`

**Interfaces:**
- Consumes: `rapp-relay`（旧的，仅作为 dev-dependency 用于对比）、测试辅助。

- [ ] **Step 1: 写对比测试**

```rust
#[tokio::test(flavor = "multi_thread")] #[ignore]
async fn relaying_costs_no_more_cpu_than_the_old_relay() {
    // 各自在进程内起一个 relay；两头的假设备经它传 512 MiB（64 KiB 一块）。
    // 用 getrusage(RUSAGE_SELF) 量传输前后的用户态加内核态时间，各跑 3 次取中位数。
    // 打印：old_ms、new_ms、ratio。assert!(ratio <= 1.05)
}
```

  旧 relay 那一侧照 `rust/relay/tests/relay.rs` 的写法（登记、connect、relay）建立中继流。
- [ ] **Step 2: 跑** — `cargo test -p rapp-relay2 --release --test bench -- --ignored --nocapture`。预期：`ratio <= 1.05`（规格 §9.4"不高于基线的 105%"）。超过：先看是不是限额的 `Bucket` 在不限速时仍然每块加锁，改成不限速时完全绕过。
- [ ] **Step 3: 空闲内存** — 同一个文件里再加 `#[ignore] idle_memory_with_100_devices`：100 台假设备登记后读进程常驻内存，`assert!(rss_mb < 50.0)`（进程里还有 100 个假设备，所以这是上界）。
- [ ] **Step 4: 提交** — `git commit -m "test(relay2): relay cost vs the old relay, idle memory"`，并把三个数字记进 `tasks/todo.md`。

### Task 16: 文档

**Files:**
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（relay 的部署和配置一节）
- Modify: `docs/superpowers/specs/2026-11-11-rapp-observability-design.md`（§4.2 relay 的事件表）
- Modify: `tasks/todo.md`

- [ ] **Step 1: 配置规范总览**：把 relay 的部分改成新 relay 的（规格 §10.1、§10.2、§12 的内容，原样的表）；旧 relay 的 systemd 和 `--key` 一节标为"旧 relay，迁移结束后删除"。设备一侧的不动（那是后续计划）。
- [ ] **Step 2: 可观测性规格**：§4.2 加一小节"新 relay"：运行日志的事件（`relay_start`、`stats`）和审计日志（指向规格 §11.1 的事件表，不抄）；"绝不记"的清单加上 key 和私钥。
- [ ] **Step 3: `tasks/todo.md`**：加一节"新 relay 服务"，列出本计划的任务和提交号；"未经实机验证"里写上任务 14 第 3 步的结果或"待用户的 VPS"。
- [ ] **Step 4: 提交** — `git commit -m "docs: new relay in the config reference and observability spec"`

---

## 规格覆盖对照

| 规格 | 任务 |
|---|---|
| §5.1 三件事 | 8、9、10 |
| §5.4 模块划分 | 文件结构；4–12 |
| §6.2 key 的构成；relay 不持有 key | 2、11 |
| §6.3 设备密钥、指纹、ID 归属 | 1、5、9 |
| §6.4 准入 | 3、8 |
| §6.5 管理命令 | 11 |
| §7.4 吊销名单（relay 这一半） | 9、11 |
| §8 协议（含 `going_away`） | 3、8–11。`redirect`：第一版的 relay 不发，消息里已留错误文本；设备怎么跟着走在设备的计划里 |
| §9.1 状态 | 5、6 |
| §9.2 上限和限速 | 7、8、9、10、13 |
| §9.3 重启 | 11 |
| §9.4 性能（relay 的两行） | 15。会话的四行在设备的计划里量 |
| §10.1、§10.2 配置、数据卷 | 4、5、6、11 |
| §11.1 审计 | 6、8–11 |
| §11.3 统计、指标、健康检查 | 11、12 |
| §12 Docker | 14 |
| §22 测试要求里 relay 的部分 | 8–15 |

不在这份计划里的（后续计划）：§7.1–§7.3、§10.3、§11.2、§13、§15、§17 里设备和界面的部分。
