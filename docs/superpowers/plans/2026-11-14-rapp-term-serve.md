# rapp 终端层（二）：`rapp-term serve`，接进 rapp-service 和 rapp-hub，`local/term.json` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让一台主控台经现有的设备连接列出、监视、新开、打开另一台设备上（或它代管的 SSH 主机上）的 tmux 会话：`rapp-term` 多一个常驻的 `serve`，`rapp-service` 多五个设备请求并把 `term:` 开头的 `open` 接到它，`rapp-hub` 多几个命令和每台在线设备一条监视流。

**Architecture:** 一台设备一个 `rapp-term serve`，由 `rapp-service` 照现有的 worker 管法拉起和收掉（在 worker 表里占一个固定的键 `term:`）。service 和 worker 之间每件事一条本机 TCP 连接：service 先写一行请求，再写（或由主控台经它写）一行口令；worker 回 JSON 行，打开会话时直接跑计划一的会话泵。`term.json` 的结构定义在 `rapp-term` 的库里，service 写、worker 读，每次用时现读。hub 照 `apps` 的样子加命令，监视流挂在在线探测上。

**Tech Stack:** Rust 2021，tokio，serde / serde_json，anyhow；系统里的 tmux（3.2 以上）、OpenSSH 客户端，Linux 上可选的 `systemd-run`。不新增第三方依赖。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md`（第 2 稿，用户已同意）。下文的“§”都指它；“平台规格”指 `docs/superpowers/specs/2026-11-11-rapp-platform-design.md`。计划一（已在 main 上）：`docs/superpowers/plans/2026-11-14-rapp-term-core.md`，这份计划用到它的 `session::run`、`Tmux`、`Runner`、`Unread`、`TermId`。

**这份计划的范围：** §16 T1、T2 里属于 worker、service、hub 的部分：§6 的接线（除 GUI 那一行），§7 的设备级监视流（除“最后几行文字”），§8.5 的新开（含 Linux 的 `systemd-run`），§9 的目标名单和每个目标的 tmux 路径（评审 R9 已实测：不交互的 ssh 到 Mac 找不到 Homebrew 的 tmux），§12 的未读放在 worker 内存里、几个主控台共用，§14 的 `term.json` 和访问记录，§15 的开关，§21 的“接线”。**不在这里的**：GUI 的 `TermSessionPort`、`TermStage`、设备面板（下一份）；监视流里给全景用的“最后几行文字”（和全景一起做，T3）；弱网代理上的“延迟不随时间增长”（弱网代理在未合并的 `feat/smooth-step1` 上）；对真实远程主机的验收（§17 第 3 项，等有主机）；Windows。

## Global Constraints

- 计划一的约束继续有效：rapp 对用户的 tmux 只发 `list-panes`、`capture-pane`、`display-message`、`send-keys`、`load-buffer`、`paste-buffer`、`delete-buffer`、`new-session`、`refresh-client`、`attach-session`，只在 `term/src/tmux/cmd.rs` 里拼；不出现 `set-option`、`bind-key`、`kill-*`、`source-file`。`term:` 标识只在 `term/src/id.rs` 里解析和拼（别处只用那里的 `is_term` 判断前缀）。
- 依赖方向：`rapp-term` 仍不依赖 `rapp-net`、`rapp-service`、`rapp-hub`、`rapp-relay`。`rapp-service` 和 `rapp-hub` 依赖 `rapp-term` 的库，只用 `rapp_term::config` 和 `rapp_term::id`。
- worker 的命令行守平台规格 §5：加 `--json` 时 stdout 只有 JSON 行事件，最后一行是 `{"event":"exit","code":N,"reason":"…"}`；stdin EOF 正常退出，退出码 0；退出码 0 正常、1 运行时错误、2 参数错误。service 拉起它的命令行固定为 `rapp-term serve --bind 127.0.0.1 --port 0 --token-env RAPP_TOKEN --config <state.home>/term.json --json`（§6）。
- 一台设备一个 `rapp-term serve`（§6），在 service 的 worker 表里的键是 `rapp_service::workers::TERM`（值 `"term:"`，任何合法的 term 标识都比它长，撞不上）。
- `term.json` 在 `$ROOT/local/term.json`（即 `state.home.join("term.json")`），权限 0600，由 `rapp_net::config::write_json` 写（§14）。字段：`allow`（布尔，没写时 `true`）、`tmux`（本机 tmux 的路径，没写时 `"tmux"`）、`targets`（`[{name, target, tmux?}]`）。rapp 不存 SSH 凭据，只存目标字符串（§9）。
- “允许终端会话”关着时：不起 `rapp-term` 进程；`list_terms`、`watch_terms`、`new_term`、`add_term_target`、`remove_term_target`、`open term:…` 一律回 `rapp_term::config::OFF`（`"terminal sessions are off"`）（§4、§15）。这个开关只能经本机 IPC 改，不做成设备请求。
- 不限制谁能加 SSH 目标（§15）：加、删目标是设备请求。
- 日志和错误里不出现屏幕内容、输入内容和新开会话的命令行（§14）。访问记录：打开终端会话照 app 会话记 `session_start` / `session_end`（`app` 是 term 标识）；输入次数记成一行 `term_inputs {sid, term, inputs}`。
- 数值：监视流每 2 秒问一次列表、只在变了时发（§8.2、§7）；连不上的 SSH 目标重试间隔 1 秒起翻倍、15 秒封顶（§9）；worker 读请求行和口令行合计最多等 30 秒；一行（含换行符）不超过 65536 字节（§7）；目标最多 32 个，名字不超过 64 字节，目标字符串不超过 255 字节，tmux 路径不超过 1024 字节。
- 和未合并的 `feat/relay-device` 分支少打架：新代码放新文件（`service/src/term.rs`、`hub/src/terms.rs`）；`service/src/peer.rs`、`service/src/ipc.rs`、`service/src/lib.rs`、`hub/src/lib.rs`、`hub/src/presence.rs` 只改任务里写明的那几行；新函数里的流一律写成泛型 `S: AsyncRead + AsyncWrite + Unpin + Send`，不写 `BiStream`（那个分支把它换成了 `Pipe`）。收尾用 `shutdown()`，不用 `writer_mut().finish()`（`BiStream` 的 `shutdown` 就是 QUIC 的 finish）。
- 测试只用独立的 tmux 服务（计划一的 `term/tests/common`），绝不碰默认的那个。机器上没有 tmux 时这些测试跳过；`RAPP_TERM_REQUIRE_TMUX=1` 时没有 tmux 算失败。service、hub 的集成测试用假的 `rapp-term`，不要求 tmux。
- 提交信息：`feat(term): …`、`feat(service): …`、`feat(hub): …`、`test(…): …`、`docs: …`、`build: …`。每次提交前按文件名 `git add`；不用 `git add -u/-A/.`，不用 `git stash/checkout/restore/reset`。
- 用户和别的会话同时在改仓库。在单独的 git worktree 里、分支 `feat/term-serve` 上做（执行时用 superpowers:using-git-worktrees）。不碰 `README.md`、`docs/archives/` 和未跟踪的文件。
- 不跑 `cargo fmt`；新建的 Rust 文件只用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`；改动的旧文件手工对齐周围的格式。
- 每个任务结束时 `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p <这个任务动过的 crate>` 全过，`cargo clippy -p <同上> --all-targets -- -D warnings` 无警告。最后一个任务跑整个 workspace。

## Review Focus

规格没有明说、最可能伤到用户的五种情况，按可能性排。每条都在负责的任务里有测试：

1. **`term.json` 被手改坏了**（不是 JSON、名字重复、目标以 `-` 开头）：service 不能当成默认值放行，也不能在“加目标”时把它覆盖掉；回 `"term.json is invalid"`，文件一个字节都不动。（任务 1、6）
2. **一个 SSH 目标连不上**（DNS 错、要密码、超时）：本机和别的目标照常列出，这个目标带原因；监视流不每 2 秒重拨，按 1→15 秒退避。（任务 1、3、4）
3. **两台主机上的 tmux 会话编号相同**（都有 `$0`）：未读各算各的，看过一台的不清另一台的。（任务 4）
4. **worker 被收掉时有人正看着**（stdin 关了、开关关了、service 退出）：tmux 里不能留下 rapp 的控制模式客户端，否则它还挂在用户的会话上。（任务 3、7）
5. **开关关掉的那一刻**：正看着的终端会话结束、监视流断开、`rapp-term` 进程退出；同一台设备上的 app 会话不受影响。（任务 7）

## File Structure

```
rust/term/src/
  config.rs      新：TermConfig、Target、OFF；读（没有文件 = 默认）和校验
  list.rs        新：TermRow；一台主机的会话表（从 main.rs 挪来）；Backoff
  serve.rs       新：worker 的连接：请求行、口令、list / watch / new / view
  id.rs          改：加 is_term、valid_host、session_name（后两个从 main.rs 挪来）
  session.rs     改：Opts 加输入计数
  tmux/mod.rs    改：new_session 在 Linux 本机经 systemd-run --user --scope
  main.rs        改：serve 子命令；list 用 list.rs
  lib.rs         改：模块声明
rust/term/tests/serve.rs   新：对着真的 rapp-term serve 和独立 tmux 服务
rust/net/src/msg.rs        改：五个新的 Op
rust/service/
  Cargo.toml     改：依赖 rapp-term
  src/term.rs    新：term.json 的读写、终端的设备请求、打开终端会话、IPC 的 term / set_term
  src/workers.rs 改：TERM 这个 worker 的程序和参数；ended 事件；stop()
  src/peer.rs    改：两个分支；log_request 改成 pub(crate)
  src/ipc.rs     改：两个命令；in_history 加 term_inputs
  src/lib.rs     改：mod term
rust/hub/
  Cargo.toml     改：依赖 rapp-term
  src/terms.rs   新：terms 等四个命令；每台主机一条监视流
  src/lib.rs     改：mod、Hub 的一个字段、dispatch 的一个分支、open 的一行检查
  src/presence.rs 改：上线时挂监视流，下线或移除时停
rust/testkit/
  Cargo.toml                 改：[[bin]] fake-rapp-term；[dependencies] serde_json
  src/bin/fake-rapp-term.rs  新
  tests/common/mod.rs        改：bins() 多链一个 rapp-term
  tests/term.rs              新：service 侧
  tests/hub_terms.rs         新：hub 侧
scripts/ package-macos.sh、build-linux.sh、package-linux.sh、lib/sign-check.sh、test-package.sh   改：带上 rapp-term
docs/superpowers/specs/2026-11-11-rapp-platform-design.md   改：§2.3、§5
docs/superpowers/specs/2026-11-13-rapp-config-reference.md  改：term.json
```

## worker 的连接（任务 3、4 实现，任务 5、6、7 依赖）

service 连 worker 的端口，先写一行请求，再写一行口令（worker 的 `RAPP_TOKEN`），都以 `\n` 结尾：

| 请求行 | 谁写口令行 | worker 回 |
|---|---|---|
| `{"op":"list"}` | service | 一行 `TermList`，然后关 |
| `{"op":"watch"}` | service | 马上一行 `TermList`，之后每次变了再一行；对方关了才停 |
| `{"op":"new","host":null\|"gpu1","name":"x"?,"command":["claude"],"cols":120,"rows":40}` | service | `{"ok":true,"id":"term:tmux:x"}` 或 `{"error":"…"}`，然后关 |
| `{"op":"view","term":"term:tmux:work","sid":7}` | 主控台（经 hub、service 原样转过来的第一行） | 计划一的线协议（`Hello` 起头）；开泵前的错误是一条 `Out::Error`（`{"t":"error","error":"…"}`） |

- `TermList` = `{"terms":[TermRow…],"hosts":[{"host":null},{"host":"gpu1","target":"me@gpu1","tmux":"/opt/homebrew/bin/tmux"?,"error":"…"?}]}`；`hosts` 第一项永远是本机（`host` 为 null），之后按 `term.json` 的顺序。
- `TermRow` = `{"id","host":null|"gpu1","name","command","panes","attached","activity","dead","unread"}`。
- 口令不对：回 `{"error":"bad token"}` 后关；请求行不是这几种：`{"error":"bad request"}`；`term.json` 读不出：`{"error":"term.json is invalid"}`；`allow` 为 false：`{"error":"terminal sessions are off"}`。
- worker 的 stdout 事件：`{"event":"listening","port":N}`；每个带 `sid` 的 view 结束时 `{"event":"ended","sid":N,"term":"…","inputs":N}`；最后 `{"event":"exit",…}`。

---

### Task 1: `term.json`、标识、会话表进库

**Files:**
- Create: `rust/term/src/config.rs`、`rust/term/src/list.rs`
- Modify: `rust/term/src/id.rs`、`rust/term/src/main.rs`（`sessions`、`SessionRow`、`check_host` 里的判定、`session_name`、`default_name` 挪走）、`rust/term/src/lib.rs`

**Interfaces:**
- Produces:
  - `config::OFF: &str = "terminal sessions are off"`，`config::INVALID: &str = "term.json is invalid"`，`config::MAX_TARGETS: usize = 32`
  - `#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)] #[serde(default)] pub struct TermConfig { pub allow: bool, #[serde(skip_serializing_if = "Option::is_none")] pub tmux: Option<String>, pub targets: Vec<Target> }`，`Default` 里 `allow: true`；不认识的字段忽略
  - `pub struct Target { pub name: String, pub target: String, #[serde(default, skip_serializing_if = "Option::is_none")] pub tmux: Option<String> }`（同样的 derive）
  - `pub fn load(path: &Path) -> Result<TermConfig, String>`：没有文件 → 默认；读不出、不是 JSON、`check` 不过 → `Err(原因)`，原因不含文件内容
  - `impl TermConfig { pub fn check(&self) -> Result<(), String>; pub fn target(&self, name: &str) -> Option<&Target>; pub fn tmux_bin(&self) -> &str }`
  - `pub fn check_target(t: &Target) -> Result<(), String>`
  - `id::is_term(s: &str) -> bool`，`id::valid_host(name: &str) -> bool`，`id::session_name(s: &str) -> Option<String>`，`id::default_name(program: &str) -> &str`
  - `#[derive(Serialize, Clone, Debug, PartialEq)] pub struct TermRow { pub id: String, pub host: Option<String>, pub name: String, pub command: String, pub panes: usize, pub attached: u32, pub activity: u64, pub dead: bool, pub unread: bool }`
  - `list::rows(list: &[PaneInfo], current: &HashSet<String>, host: Option<&str>, unread: &Unread, now: u64) -> Vec<TermRow>`
  - `list::host_rows(tmux: &Tmux, host: Option<&str>, unread: &Mutex<Unread>, now: u64) -> anyhow::Result<Vec<TermRow>>`
  - `pub struct Backoff`，`Backoff::new()`，`fn failed(&mut self) -> Duration`，`fn reset(&mut self)`；`BACKOFF_FIRST = 1s`，`BACKOFF_MAX = 15s`

- [ ] **Step 1: 写失败的测试（`config.rs`、`list.rs`、`id.rs` 里的 `#[cfg(test)]`）**

```rust
#[test]
fn a_missing_file_is_the_default_and_the_default_allows() {
    let d = tempfile::tempdir().unwrap();
    let c = load(&d.path().join("term.json")).unwrap();
    assert_eq!(c, TermConfig { allow: true, tmux: None, targets: vec![] });
    assert_eq!(c.tmux_bin(), "tmux");
}

#[test]
fn a_file_round_trips_and_unknown_fields_are_ignored() {
    // {"allow":false,"tmux":"/usr/local/bin/tmux","targets":[{"name":"gpu1","target":"me@gpu1","tmux":"/opt/homebrew/bin/tmux"}],"later":1}
    // → 读出 allow false、tmux_bin "/usr/local/bin/tmux"、target("gpu1") 的 tmux 是 Homebrew 那个；序列化回去没有 "later"
}

#[test]
fn bad_files_and_targets_are_refused() {
    // 每一种都 load 失败（或 check_target 失败），且错误里不含文件原文：
    // "{not json"；名字重复；name ""、"a:b"、"a b"、65 字节；target ""、"-oProxyCommand=x"、"a b"、"a\tb"、256 字节；
    // tmux ""、"-x"、带 '\n'、1025 字节；33 个目标（错误是 "too many targets"）
}

#[test]
fn term_prefix_and_host_names() {
    assert!(is_term("term:tmux:work") && !is_term("com.apple.Safari") && !is_term("term"));
    assert!(valid_host("gpu1") && valid_host("gpu-1.lab"));
    assert!(!valid_host("") && !valid_host("a:b") && !valid_host("a b") && !valid_host("a@b"));
}

#[test]
fn rows_carry_the_host_and_unread() {
    // 两个会话的 PaneInfo；Unread 里一个有动静后安静了 3 秒以上 → 那个 unread true，另一个 false；
    // host Some("gpu1") 时 id 是 "term:tmux@gpu1:<name>"，host 字段是 "gpu1"
}

#[test]
fn backoff_doubles_to_fifteen_seconds_and_resets() {
    let mut b = Backoff::new();
    let s: Vec<u64> = (0..6).map(|_| b.failed().as_secs()).collect();
    assert_eq!(s, [1, 2, 4, 8, 15, 15]);
    b.reset();
    assert_eq!(b.failed().as_secs(), 1);
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-term --lib`
Expected: 编译失败，`config`、`list`、`is_term` 等未定义

- [ ] **Step 3: 实现**

`check_target` 的目标字符串规则和 `Runner::ssh` 一致（非空、不以 `-` 开头、没有空白和控制字符），另加长度上限；名字用 `valid_host`（能从 term 标识原样读回）加 64 字节上限。`main.rs` 的 `list` 改用 `list::rows`（`Unread::new(now)`，所以都是 false），`--json` 的输出多了 `host`、`unread` 两个字段，其余不变；`main.rs` 原有的测试跟着挪到新位置，一个不删。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term && cargo clippy -p rapp-term --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add rust/term/src/config.rs rust/term/src/list.rs rust/term/src/id.rs rust/term/src/main.rs rust/term/src/lib.rs
git commit -m "feat(term): term.json, host names and the session table move into the library"
```

---

### Task 2: 输入计数，Linux 上新开不进服务的控制组

**Files:**
- Modify: `rust/term/src/session.rs`（`Opts`）、`rust/term/src/tmux/mod.rs`（`new_session`）
- Test: `rust/term/src/session.rs`、`rust/term/src/tmux/mod.rs` 的单元测试，`rust/term/tests/live.rs`

**Interfaces:**
- Produces:
  - `Opts { pub poll, pub min_gap, pub inputs: Arc<AtomicU64> }`，`Default` 给一个新的计数器
  - 一次输入 = 一条 `Keys`、一条 `Type`、或一段 `Text` 的最后一条（`more` 为 false 的那条，不管贴没贴成）
  - `tmux::scoped(argv: Vec<String>, linux: bool, has_systemd_run: bool) -> Vec<String>`：两者都真时返回 `["systemd-run","--user","--scope","--quiet","--", argv…]`，否则原样
  - `Tmux::new_session` 只在 `Runner::Local` 上用 `scoped`；`systemd-run` 起不来（非零退出）时不经它再试一次，并往 stderr 写一行 `new session started without systemd-run: it may stop with the service`

- [ ] **Step 1: 写失败的测试**

```rust
#[test]
fn new_sessions_go_through_systemd_run_only_on_linux_when_it_is_there() {
    let a = vec!["tmux".to_string(), "new-session".into(), "-d".into()];
    assert_eq!(scoped(a.clone(), true, true)[..5], ["systemd-run", "--user", "--scope", "--quiet", "--"]);
    assert_eq!(scoped(a.clone(), true, true)[5..], a[..]);
    assert_eq!(scoped(a.clone(), false, true), a);
    assert_eq!(scoped(a.clone(), true, false), a);
}
```

`live.rs` 加 `inputs_are_counted_not_recorded`：经内存 duplex 跑 `session::run`，依次发 `Keys`、`Keys`、`Type`、`Text{more:true}`、`Text{more:false}`，关掉输入后 `opts.inputs` 读到 4。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-term -- scoped inputs_are_counted`
Expected: 编译失败，`scoped`、`Opts::inputs` 未定义

- [ ] **Step 3: 实现**

`has_systemd_run` 用一个小函数在 `PATH` 里找可执行的 `systemd-run`；`linux` 是 `cfg!(target_os = "linux")`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term && cargo clippy -p rapp-term --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add rust/term/src/session.rs rust/term/src/tmux/mod.rs rust/term/tests/live.rs
git commit -m "feat(term): count inputs; new sessions on Linux start outside the service's cgroup"
```

---

### Task 3: `rapp-term serve`：口令、list、new、view

**Files:**
- Create: `rust/term/src/serve.rs`、`rust/term/tests/serve.rs`
- Modify: `rust/term/src/main.rs`（`serve` 子命令、`USAGE`）、`rust/term/src/lib.rs`

**Interfaces:**
- Consumes: 任务 1 的 `config::load`、`list::host_rows`、`id::*`；任务 2 的 `Opts::inputs`；计划一的 `session::run`、`Runner::ssh`、`Tmux`、`Unread`
- Produces:
  - `pub struct ServeOpts { pub config: PathBuf, pub socket: Option<String>, pub ctl_dir: PathBuf, pub poll: Duration }`（`poll` 默认 2 秒；`socket` 只给本机用，测试用）
  - `pub async fn serve(listener: TcpListener, token: String, opts: ServeOpts, events: UnboundedSender<serde_json::Value>, stop: impl Future<Output = ()>)`：`stop` 完成时不再接新连接，结束所有连接（`JoinSet::shutdown().await`，泵被丢掉时控制模式客户端随之退出），然后返回
  - 请求行：`#[serde(tag = "op", rename_all = "snake_case")] enum Req { List, Watch, New { host: Option<String>, name: Option<String>, command: Vec<String>, cols: u16, rows: u16 }, View { term: String, sid: Option<u64> } }`
  - 命令行：`rapp-term serve --token-env <VAR> --config <path> [--bind 127.0.0.1] [--port 0] [--json]`（隐藏的 `--socket`）。环境变量没设或为空 → 退出码 2；绑不上 → 1
  - 上面“worker 的连接”一节的全部回复和事件（`watch` 在任务 4）

- [ ] **Step 1: 写失败的测试（`tests/serve.rs`，起真的 `env!("CARGO_BIN_EXE_rapp-term")`，带 `--socket <独立服务>` 和临时的 `--config`）**

```rust
#[tokio::test] async fn serve_says_listening_and_exits_on_stdin_eof()
// 第一行 {"event":"listening","port":N}，N > 0；关 stdin → 最后一行 {"event":"exit","code":0,…}，退出码 0

#[tokio::test] async fn serve_without_its_token_is_an_argument_error()
// 不设 RAPP_TOKEN → 退出码 2

#[tokio::test] async fn a_bad_token_gets_one_error_line()
// 写 {"op":"list"} 和 "nope" → 恰好一行 {"error":"bad token"}，然后 EOF

#[tokio::test] async fn list_shows_the_sessions_and_the_local_host()
// 独立服务里建会话 "a b" → terms 里有 {"id":"term:tmux:a b","host":null,"name":"a b","unread":false,…}；hosts[0] == {"host":null}

#[tokio::test] async fn a_target_that_cannot_connect_is_reported_and_local_is_still_listed()
// term.json 加 {"name":"gone","target":"nohost.invalid"} → 15 秒内回；hosts[1] 的 host "gone"、target "nohost.invalid"、error 非空；本机会话照样在 terms 里

#[tokio::test] async fn view_pumps_the_session_and_reports_inputs_without_content()
// {"op":"view","term":"term:tmux:w","sid":7} + 口令 → 第一行是 hello；发一条 Type "secret-word-1" 和一条 Keys；关连接
// → stdout 有 {"event":"ended","sid":7,"term":"term:tmux:w","inputs":2}；stdout 和 stderr 里都没有 "secret-word-1"

#[tokio::test] async fn view_of_an_unknown_host_or_a_bad_id_is_an_error()
// "term:tmux@nope:x" → {"t":"error","error":"unknown host"}；"term:x" → {"t":"error","error":"invalid term id"}

#[tokio::test] async fn new_makes_a_session_and_refuses_a_taken_name()
// {"op":"new","host":null,"name":"n1","command":["sh"],"cols":100,"rows":30} → {"ok":true,"id":"term:tmux:n1"}，独立服务里有 n1；
// 再来一次 → {"error":"a session with that name already exists"}；command 为空 → {"error":"command required"}

#[tokio::test] async fn stopping_leaves_no_control_client()
// 开一个 view，读到 hello；关 stdin → 2 秒内独立服务的 list-clients 为空

#[tokio::test] async fn terminals_off_in_the_config_refuse_everything()
// {"allow":false} → list、new 回 {"error":"terminal sessions are off"}，view 回 {"t":"error","error":"terminal sessions are off"}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term --test serve`
Expected: FAIL（`serve` 不是已知的子命令）

- [ ] **Step 3: 实现 `serve.rs` 和 `main.rs` 的 `serve`**

- 每条连接一个任务：30 秒内读到请求行和口令行（各自不超过 `MAX_LINE`），口令用常数时间比较（自己写一个小函数，不引依赖）；每个请求都现读 `term.json`。
- 一台主机怎么跑：本机 `Tmux { runner: Local, bin: cfg.tmux_bin(), socket: opts.socket }`；目标 `Tmux { runner: Runner::ssh(&t.target, &opts.ctl_dir), bin: t.tmux.or("tmux"), socket: None }`；名字不在名单里 → `"unknown host"`。
- `list`：本机和各个目标并发地 `host_rows`，失败的那个只在 `hosts` 里带 `error`（`RunFail` 的说法，不含命令和输出）。
- 未读：`Worker` 里一张 `HashMap<Option<String>, Arc<Mutex<Unread>>>`，每台主机一份，`Unread::new(worker 启动时刻)`；`view` 把那台主机的那份交给 `session::run`。
- `main.rs`：打印 `listening`；一个任务把 `events` 收到的事件逐行打到 stdout；stdin 读到 EOF 就让 `stop` 完成，`serve` 返回后打印 `exit`。`ctl_dir` 用计划一的 `ctl_dir()`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term && cargo clippy -p rapp-term --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add rust/term/src/serve.rs rust/term/src/main.rs rust/term/src/lib.rs rust/term/tests/serve.rs
git commit -m "feat(term): rapp-term serve: one worker per device for list, new and view"
```

---

### Task 4: 设备级的监视流

**Files:**
- Modify: `rust/term/src/serve.rs`
- Test: `rust/term/src/serve.rs` 的单元测试，`rust/term/tests/serve.rs`

**Interfaces:**
- Consumes: 任务 1 的 `Backoff`、`host_rows`；任务 3 的 `Worker`、`ServeOpts::poll`
- Produces: `Req::Watch` 的行为（见“worker 的连接”）；`Worker::unread_for(&self, host: Option<&str>) -> Arc<Mutex<Unread>>`

- [ ] **Step 1: 写失败的测试**

```rust
#[test]
fn unread_is_kept_per_host() {
    // 同一个 Worker：unread_for(None) 和 unread_for(Some("gpu1")) 不是同一个 Arc（Arc::ptr_eq 为假）；
    // 两次 unread_for(Some("gpu1")) 是同一个；在 gpu1 那份上 seen("$0") 后，本机那份对 "$0" 的判定不变
}
```

`tests/serve.rs` 加：

```rust
#[tokio::test] async fn watch_sends_a_list_now_then_only_changes()
// 连上就有一行；建会话 "w2" → 5 秒内来一行含 term:tmux:w2；等到它 unread 变 true 的那一行之后，3 秒内没有新行

#[tokio::test] async fn a_session_goes_unread_after_output_and_quiet_and_clears_when_viewed()
// 往会话里 send-keys "echo hi" Enter（经测试服务的 raw）→ 等到 unread true；另开一条 view 读到第一屏 → 监视流下一行它的 unread 为 false

#[tokio::test] async fn a_target_added_while_watching_shows_up()
// 监视中把 {"name":"gone","target":"nohost.invalid"} 写进 term.json → 5 秒内来一行，hosts 里有 gone 且带 error

#[tokio::test] async fn the_watch_ends_when_the_worker_stops()
// 关 worker 的 stdin → 2 秒内监视连接读到 EOF
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term -- watch unread_is_kept a_target_added`
Expected: FAIL

- [ ] **Step 3: 实现**

每台主机一个任务，各自 `host_rows` 后把结果放进共享的表，失败时带原因并按自己的 `Backoff` 等下一次，成功后 `reset`；发送的循环每 `poll` 现读一次 `term.json`，按名单增删主机任务，把整张表拼成 `TermList`，和上一次发出去的不一样才发。一个慢的目标不拖慢本机那一行的更新。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term && cargo clippy -p rapp-term --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add rust/term/src/serve.rs rust/term/tests/serve.rs
git commit -m "feat(term): the device watch stream, with unread kept per host"
```

---

### Task 5: 设备请求的消息，假的 `rapp-term`

**Files:**
- Modify: `rust/net/src/msg.rs`、`rust/testkit/Cargo.toml`、`rust/testkit/tests/common/mod.rs`（`bins()`）
- Create: `rust/testkit/src/bin/fake-rapp-term.rs`

**Interfaces:**
- Produces:
  - `Op::ListTerms`（`list_terms`）、`Op::WatchTerms`（`watch_terms`）、`Op::NewTerm { host: Option<String>, name: Option<String>, command: Vec<String>, cols: u16, rows: u16 }`（`new_term`；两个 `Option` 为 None 时不写出）、`Op::AddTermTarget { name: String, target: String, tmux: Option<String> }`（`add_term_target`；`tmux` 为 None 时不写出）、`Op::RemoveTermTarget { name: String }`（`remove_term_target`）
  - 假 worker，`bins()` 把它链成 `rapp-term`。它守“worker 的连接”一节，只是数据是假的：
    - 每次启动往 `<bin 目录>/term.log` 写一行 `argv <空格隔开的参数>`；每个 view 结束写一行 `view <term> <收到的行数>`（不写内容）；每条 watch 连接关掉时写一行 `watch closed`
    - `list` / `watch` 的 `terms`：一条 `term:tmux:work`（本机），每个目标一条 `term:tmux@<name>:main`；名字叫 `down` 的目标在 `hosts` 里带 `"error":"unreachable"`、没有会话；`allow` 为 false 时回 OFF；`watch` 在 `term.json` 内容变了的 100 毫秒内再发一行
    - `new`：`{"ok":true,"id":"term:tmux:<name 或 command[0]>"}`
    - `view`：口令对了先发 `{"t":"hello","fake":true,"term":<term>}`，之后把收到的每一行原样发回；对方关了就在 stdout 打 `ended`，`inputs` 为收到的行数
    - stdin EOF：关掉所有连接，打 `exit`，退出码 0

- [ ] **Step 1: 写失败的测试（`msg.rs` 的 tests）**

```rust
assert_eq!(serde_json::to_value(Op::ListTerms).unwrap(), json!({"op":"list_terms"}));
assert_eq!(serde_json::to_value(Op::WatchTerms).unwrap(), json!({"op":"watch_terms"}));
assert_eq!(
    serde_json::to_value(Op::NewTerm { host: None, name: None, command: vec!["claude".into()], cols: 120, rows: 40 }).unwrap(),
    json!({"op":"new_term","command":["claude"],"cols":120,"rows":40})
);
assert_eq!(
    serde_json::from_value::<Op>(json!({"op":"add_term_target","name":"gpu1","target":"me@gpu1"})).unwrap(),
    Op::AddTermTarget { name: "gpu1".into(), target: "me@gpu1".into(), tmux: None }
);
assert_eq!(serde_json::to_value(Op::RemoveTermTarget { name: "gpu1".into() }).unwrap(), json!({"op":"remove_term_target","name":"gpu1"}));
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-net msg`
Expected: 编译失败，`Op::ListTerms` 未定义

- [ ] **Step 3: 实现 `Op` 的五个变体和假 worker**

假 worker 照 `fake-rapp-host` 的写法（同步的 std 网络和线程），解析 JSON 用 `serde_json`（`testkit/Cargo.toml` 的 `[dependencies]` 加 `serde_json.workspace = true`，`[[bin]]` 加 `fake-rapp-term`）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-net && cargo build -p rapp-testkit --bins && cargo clippy -p rapp-net -p rapp-testkit --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add rust/net/src/msg.rs rust/testkit/Cargo.toml rust/testkit/src/bin/fake-rapp-term.rs rust/testkit/tests/common/mod.rs
git commit -m "feat(net): device requests for terminal sessions; testkit gets a fake rapp-term"
```

---

### Task 6: service：`term.json`，列出、监视、新开、加删目标

**Files:**
- Create: `rust/service/src/term.rs`、`rust/testkit/tests/term.rs`
- Modify: `rust/service/Cargo.toml`（`rapp-term.workspace = true`）、`rust/service/src/workers.rs`、`rust/service/src/peer.rs`、`rust/service/src/lib.rs`

**Interfaces:**
- Consumes: 任务 1 的 `rapp_term::config::*`；任务 5 的 `Op`；“worker 的连接”一节
- Produces:
  - `workers::TERM: &str = "term:"`；`workers::start_session(state, TERM)` 拉起的是 `rapp-term`（参数见 Global Constraints），stderr 的标签是 `{"src":"term"}`，报错的字样里写真正的程序名
  - `workers::stop(state: &State, app: &str)`：关掉这个 worker 的 stdin（任务 7 用）
  - `term::request<S: AsyncRead + AsyncWrite + Unpin + Send>(state: &Arc<State>, s: &mut S, peer: &Peer, op: Op) -> Result<()>`
  - `term::config(state: &State) -> Result<TermConfig, String>`（读不出时 `Err(INVALID)`）
  - `peer.rs` 只改两处：`log_request` 改成 `pub(crate)`；`serve_request` 在 `Ok(Op::Open …)` 之前加一个分支 `Ok(op @ (Op::ListTerms | Op::WatchTerms | Op::NewTerm { .. } | Op::AddTermTarget { .. } | Op::RemoveTermTarget { .. })) => crate::term::request(state, &mut s, &peer, op).await`
  - 设备请求的回复：`list_terms` → `{"ok":true,"terms","hosts"}`；`watch_terms` → worker 的每一行加上 `"ok":true` 原样转给 B，B 关了或 worker 关了就停；`new_term` → `{"ok":true,"id"}`；`add_term_target`、`remove_term_target` → `{"ok":true,"targets":[…]}`
  - 访问记录：每个请求一行 `request`，`op` 分别是 `list_terms`、`watch_terms`、`new_term`（另记 `host`，不记命令）、`add_term_target`、`remove_term_target`（另记 `name`）

- [ ] **Step 1: 写失败的测试（`testkit/tests/term.rs`，用 `common::service()` 和 B 端的 `direct`、`req`）**

```rust
#[tokio::test] async fn list_terms_goes_to_one_rapp_term_worker()
// 两次 list_terms 都是 ok，terms[0].id == "term:tmux:work"，hosts[0] == {"host":null}；
// term.log 恰好一行 argv，且等于 "argv serve --bind 127.0.0.1 --port 0 --token-env RAPP_TOKEN --config <home>/term.json --json"

#[tokio::test] async fn with_terminals_off_nothing_starts()
// home/term.json 写 {"allow":false} → list_terms、watch_terms、new_term、add_term_target、remove_term_target
// 都回 error "terminal sessions are off"；term.log 不存在；list_apps 照常 ok（open term:… 的同一检查在任务 7）

#[tokio::test] async fn a_broken_term_json_is_reported_and_left_alone()
// 写 "{not json" → list_terms 和 add_term_target 都回 "term.json is invalid"；文件字节不变

#[tokio::test] async fn targets_are_added_checked_and_removed()
// add {name:"gpu1",target:"me@gpu1",tmux:"/opt/homebrew/bin/tmux"} → ok，targets 里有它；term.json 权限 0600 且能读回；
// 同名再加 → "name is taken"；target "-oProxyCommand=x" → 错误且没写进去；第 33 个 → "too many targets"；
// remove gpu1 → ok；再 remove → "unknown target"；service.log 有 op add_term_target、name gpu1 的 request 行

#[tokio::test] async fn watch_terms_pushes_changes()
// 开一条 watch_terms 不关，第一行 ok 且有 term:tmux:work；另一条流 add_term_target gpu1 → WAIT 内监视流来一行含 term:tmux@gpu1:main

#[tokio::test] async fn new_term_returns_the_id_and_logs_no_command()
// new_term {command:["secret-cmd-1"],cols:80,rows:24,name:"n1"} → {"ok":true,"id":"term:tmux:n1"}；
// service.log 有 op new_term 的 request 行；service.log 和 term.log 里都没有 "secret-cmd-1"
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-testkit --test term`
Expected: FAIL（`unknown op`）

- [ ] **Step 3: 实现**

- `term.rs` 里一把 `static` 的 `std::sync::Mutex<()>`，所有对 `term.json` 的读改写都在它里面做；写之前先 `config()`，读不出就报错、不写。
- 每个请求先过开关：读不出 → `INVALID`，`allow` 为 false → `OFF`，都不碰 worker。
- 问 worker：`start_session(state, TERM)` 拿到端口和口令，连上写请求行和口令行，读回复；无论结果如何都 `end_session(state, TERM)`（监视流在流结束时才 `end_session`，所以有监视流时 worker 不会因闲置被收掉）。
- 回给 B 的收尾：`write_json` 后 `shutdown()`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-service -p rapp-testkit && cargo clippy -p rapp-service -p rapp-testkit --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add rust/service/Cargo.toml rust/service/src/term.rs rust/service/src/workers.rs rust/service/src/peer.rs rust/service/src/lib.rs rust/testkit/tests/term.rs
git commit -m "feat(service): list, watch and start terminal sessions; SSH targets in local/term.json"
```

---

### Task 7: service：打开终端会话，访问记录，本机的开关

**Files:**
- Modify: `rust/service/src/term.rs`、`rust/service/src/workers.rs`（`ended` 事件）、`rust/service/src/peer.rs`（一个分支）、`rust/service/src/ipc.rs`
- Test: `rust/testkit/tests/term.rs`

**Interfaces:**
- Consumes: 任务 6 的 `TERM`、`stop`、`config`；`state.add_session`、`state.end_session`、`update::begin_open`、`rapp_net::quic::splice_metered`
- Produces:
  - `term::open<S: AsyncRead + AsyncWrite + Unpin + Send>(state: &Arc<State>, s: &mut S, app: &str, peer: Peer) -> Result<()>`
  - `peer.rs` 在 `Ok(Op::Open { app, side })` 之前加 `Ok(Op::Open { app, .. }) if rapp_term::id::is_term(&app) => crate::term::open(state, &mut s, &app, peer).await`（终端会话没有旁路连接，`side` 不看）
  - worker 的 `{"event":"ended","sid","term","inputs"}` → 访问记录一行 `term_inputs {sid, term, inputs}`
  - IPC：`{"cmd":"term"}` → `{"ok":true,"allow","tmux","targets"}`；`{"cmd":"set_term","allow"?:bool,"tmux"?:string|null}` → `{"ok":true}`。`allow` 改成 false 时 `workers::stop(state, TERM)` 并 `state.notify()`。`term.json` 读不出时两个都回 `INVALID`，不写
  - `in_history` 多收 `term_inputs`

- [ ] **Step 1: 写失败的测试**

```rust
#[tokio::test] async fn open_term_splices_to_the_worker_and_logs_no_content()
// open {app:"term:tmux:work"} → ok 和 token；同一条流上写 token 行，再写 "hello-secret-1"、"hello-secret-2"；
// 读到 {"t":"hello","fake":true,"term":"term:tmux:work"} 和两行回显；关流 →
// session_end 的 app 是 term:tmux:work、up 和 down 都 > 0；term_inputs 的 sid 和 session_start 的相同、inputs == 2；
// IPC history 里有这三行；service.log 里没有 "hello-secret"；host.log 是空的（没去找 rapp-host）

#[tokio::test] async fn terminal_sessions_share_one_worker_and_can_be_kicked()
// 同时开两个 term 会话 → term.log 只有一行 argv；IPC kick 其中一个的 sid → 它的 session_end reason == "kicked"，另一个还在回显

#[tokio::test] async fn turning_terminals_off_ends_terminal_sessions_only()
// 开一个 term 会话和一个 app 会话（fake-rapp-host）；IPC set_term {allow:false} →
// term 会话的流读到 EOF，service.log 有 worker_exit app "term:"；app 会话照样回显；
// list_terms 和 open term:tmux:work 都回 "terminal sessions are off"，term.log 里 argv 行没有变多；term.json 里 allow false、权限 0600；IPC term → allow false；
// set_term {allow:true} → list_terms 又能用

#[tokio::test] async fn ipc_term_refuses_a_broken_file()
// "{not json" → IPC term、set_term 都回 "term.json is invalid"，文件不变
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-testkit --test term -- open_term terminal_sessions turning ipc_term`
Expected: FAIL

- [ ] **Step 3: 实现 `term::open`**

顺序：过开关 → `update::begin_open`（终端会话也算“在用”，更新不会把它掐断）→ `start_session(state, TERM)` → 连 worker → `state.add_session(&peer, app, false)` 拿到 sid → 往 worker 写 `{"op":"view","term":app,"sid":sid}`（口令行留给主控台）→ 记 `request` 和 `session_start` → 回 B `ok {token}` → `select!` 里 `splice_metered` 和 kick → 记 `session_end {secs, up, down, reason}`（`state.end_session(sid)` 为 false 时不写：service 正在停，结束行已经写过，同 `splice_session`）→ `end_session(state, TERM)`。字段和 `peer::splice_session` 的一样，用 `peer.session_fields(app, false, sid)`；没有“接管”这回事（§15：几个主控台同时看，不接管）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-service -p rapp-testkit && cargo clippy -p rapp-service -p rapp-testkit --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add rust/service/src/term.rs rust/service/src/workers.rs rust/service/src/peer.rs rust/service/src/ipc.rs rust/testkit/tests/term.rs
git commit -m "feat(service): open terminal sessions; access log and the per-device switch"
```

---

### Task 8: hub：终端的命令，只嵌入打开，监视流

**Files:**
- Create: `rust/hub/src/terms.rs`、`rust/testkit/tests/hub_terms.rs`
- Modify: `rust/hub/Cargo.toml`（`rapp-term.workspace = true`）、`rust/hub/src/lib.rs`、`rust/hub/src/presence.rs`

**Interfaces:**
- Consumes: 任务 5 的 `Op`；任务 6、7 的设备请求；`Hub::request`、`Hub::emit`、`Hub::host`
- Produces:
  - 命令和事件：
    - `{"cmd":"terms","id"}` → `{"event":"terms","id","path","terms","hosts"}`；A 回 OFF 时 `{"event":"terms","id","off":true}`
    - `{"cmd":"add_term_target","id","name","target","tmux"?}`、`{"cmd":"remove_term_target","id","name"}` → `{"event":"term_targets","id","targets"}`
    - `{"cmd":"new_term","id","host"?,"name"?,"command":[…],"cols","rows"}` → `{"event":"term_created","id","term"}`
    - 监视流推来的每一行 → `{"event":"terms","id","terms","hosts"}`（不带 `req`）；流因错误结束 → `{"event":"terms","id","error"}`；A 回 OFF → `{"event":"terms","id","off":true}`
  - `pub(crate) struct Watches`；`terms::command(hub: &Arc<Hub>, cmd: &str, v: &Value) -> Result<Value>`；`terms::ensure_watch(hub: &Arc<Hub>, host: &Host)`；`terms::stop_watch(hub: &Hub, id: &str)`；`terms::after_end(error: &str) -> Next`，`enum Next { Retry, Off, Unsupported }`
  - `lib.rs` 只改：`mod terms;`；`Hub` 加字段 `terms: terms::Watches` 和它的初始化；`dispatch` 加 `Some(c @ ("terms" | "add_term_target" | "remove_term_target" | "new_term")) => terms::command(self, c, v).await?`；`open` 分支里 `if rapp_term::id::is_term(app) && !embed { bail!("terminal sessions open embedded only") }`
  - `presence.rs`：在线 → `ensure_watch`；离线 → `stop_watch`；每一轮把已不在 `hosts.all()` 里的主机的监视流停掉

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn what_a_watch_does_after_it_ends()  // hub/src/terms.rs 的单元测试
// after_end("terminal sessions are off") == Next::Off；after_end("unknown op") == Next::Unsupported；after_end("timed out") == Next::Retry
```

`testkit/tests/hub_terms.rs`（`Hub::start` 和 `Hub::start_with_presence`，主机照 `hub.rs` 的 `hub_with_host` 加）：

```rust
#[tokio::test] async fn terms_lists_a_hosts_terminal_sessions()
// {"cmd":"terms","id":<A>} → event terms、id 是 A、terms[0].id == "term:tmux:work"、hosts[0].host 为 null

#[tokio::test] async fn terms_on_a_host_with_terminals_off_says_off()
// A 的 term.json 写 {"allow":false} → {"event":"terms","id":<A>,"off":true}

#[tokio::test] async fn targets_and_new_sessions_go_through_the_hub()
// add_term_target gpu1 → term_targets 里有 gpu1；new_term {command:["sh"],name:"n1"} → term_created term "term:tmux:n1"；remove → targets 为空

#[tokio::test] async fn a_terminal_session_opens_embedded_only()
// open {id, app:"term:tmux:work"} → error "terminal sessions open embedded only"；
// open {…, embed:true} → opened 带 port、token；连上 port 写 token 行再写 "x" → 读到 fake 的 hello 和 "x"

#[tokio::test] async fn an_online_host_gets_one_watch()
// start_with_presence(200 ms) → 收到不带 req 的 terms 事件；经另一条命令 add_term_target gpu1 → 之后有一条 terms 事件含 term:tmux@gpu1:main；
// 再过 5 轮探测，A 的 service.log 里 op watch_terms 的 request 行仍只有 1 行

#[tokio::test] async fn removing_a_host_stops_its_watch()
// 收到第一条不带 req 的 terms 事件后 remove_host → 2 秒内 A 那边 fake 的 term.log 出现一行 "watch closed"；之后 3 轮探测里不再有不带 req 的 terms 事件
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-hub terms && cargo test -p rapp-testkit --test hub_terms`
Expected: FAIL

- [ ] **Step 3: 实现**

- `Watches` 是 `Mutex<HashMap<String, WatchState>>`，`WatchState` 是运行中（`JoinHandle`）或 `Unsupported`。`ensure_watch` 在没有、或上一条已经结束且不是 `Unsupported` 时才开新的；`Unsupported` 一直留到主机被移除，所以老版本的 A 不会每 30 秒收到一个失败请求。
- 监视任务：`hub.request(&host, &Op::WatchTerms)` 的第一个回复发一条 `terms`，之后在同一条流上 `read_json` 循环，每行发一条；结束时按 `after_end` 决定发 `off`、`error`，或什么也不发（`Unsupported`）。
- 假 worker 的 hello 是 `{"t":"hello",…}`：hub 不看内容，嵌入打开那条路原样复用。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-hub -p rapp-testkit && cargo clippy -p rapp-hub -p rapp-testkit --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add rust/hub/Cargo.toml rust/hub/src/terms.rs rust/hub/src/lib.rs rust/hub/src/presence.rs rust/testkit/tests/hub_terms.rs
git commit -m "feat(hub): terminal commands, embedded opens and one watch stream per online device"
```

---

### Task 9: 打包，文档，收尾

**Files:**
- Modify: `scripts/package-macos.sh`、`scripts/build-linux.sh`、`scripts/package-linux.sh`、`scripts/lib/sign-check.sh`、`scripts/test-package.sh`
- Modify: `docs/superpowers/specs/2026-11-11-rapp-platform-design.md`（§2.3、§5）、`docs/superpowers/specs/2026-11-13-rapp-config-reference.md`

**Interfaces:**
- Consumes: 前面所有任务定下的命令行、请求、事件、字段

- [ ] **Step 1: 打包带上 `rapp-term`**

照 `rapp-hub` 的写法：macOS 的 `cargo build` 加 `-p rapp-term`、拷进 `Contents/MacOS/`、签名标识 `com.rapp.term`（`sign-check.sh` 的 `EXPECTED_IDS` 和 `test-package.sh` 里的同一串都加 `rapp-term:com.rapp.term`）；Linux 两个脚本的二进制名单加 `rapp-term`。service 用 `rapp_net::bins::find("rapp-term", …)` 找它，和找 `rapp-host` 是同一个目录。

- [ ] **Step 2: 检查脚本**

Run: `bash -n scripts/package-macos.sh scripts/build-linux.sh scripts/package-linux.sh scripts/lib/sign-check.sh scripts/test-package.sh && grep -c rapp-term scripts/package-macos.sh scripts/build-linux.sh scripts/package-linux.sh scripts/lib/sign-check.sh scripts/test-package.sh`
Expected: 没有语法错误；每个文件的计数至少为 1

- [ ] **Step 3: 改文档（§19 里属于这份计划的两份）**

- 平台规格 §2.3：请求加 `list_terms`、`watch_terms`、`new_term`、`add_term_target`、`remove_term_target`，各一行请求和回复；`open` 的 `app` 以 `term:` 开头时走 `rapp-term`，之后的流是终端规格 §7 的 JSON 行，第一行是 worker 口令。§5：加 `rapp-term` 一节：`serve` 的参数和事件（`listening`、`ended`、`exit`）、“worker 的连接”那张表、`list`、`watch`、`run`、`version`。
- 配置规范总览：§1 的表加一行 `$ROOT/local/term.json`（A，GUI 经 IPC 改开关和 tmux 路径，目标经设备请求改，可手改，无机密）；§2 加一节，字段表（`allow`、`tmux`、`targets[].name`、`targets[].target`、`targets[].tmux`，各自的类型、没写时、取值规则、谁改），生效方式：每次用时现读，不用重启；坏了的文件 rapp 不改，终端会话都报“term.json is invalid”。

- [ ] **Step 4: 整个 workspace 跑一遍**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`
Expected: 全过，无警告

- [ ] **Step 5: 提交**

```bash
git add scripts/package-macos.sh scripts/build-linux.sh scripts/package-linux.sh scripts/lib/sign-check.sh scripts/test-package.sh docs/superpowers/specs/2026-11-11-rapp-platform-design.md docs/superpowers/specs/2026-11-13-rapp-config-reference.md
git commit -m "build: ship rapp-term; docs: terminal requests, the rapp-term CLI and local/term.json"
```
