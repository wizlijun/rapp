# 安卓平板 P1a：共用重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把会话循环从 `rapp-session` 可执行文件挪进 `rapp-client-core` 的库模块，把 `LinuxSessionPort` 拆成和平台无关的 `WorkerSessionPort` + `SessionLink` + `SessionHost`，Linux 上的行为一个字节都不变；顺带先修掉 hub 读到超过 64 KiB 的回复就丢整条连接的毛病。

**Architecture:** Rust 侧 `client-core/src/session/` 收下 `bin/rapp-session.rs` 的全部逻辑，可执行文件只剩把标准输入输出接上去的 `main`。Dart 侧端口只认两个小接口：`SessionLinks`（开一条会话通路，Linux 是子进程）和 `SessionHost`（落盘目录、剪贴板、选文件、分离窗口通道、追踪目录），`LinuxSessionHost` 装下现在散在端口里的 Linux 专属代码。P1b 的安卓只需再写一个 `FfiSessionLinks` 和 `AndroidSessionHost`。

**Tech Stack:** Rust（tokio、anyhow）、Flutter/Dart、`flutter_test`。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md`（§6.2、§6.3、§14.2 第 1 条、§14.3）；P0 结果 `docs/superpowers/specs/2026-11-27-rapp-android-p0-findings.md`（第 4 节「会话自己断的原因」、补丁表 `link.rs` 那行）。

**拆法（和规格不同的一处，理由）：** 规格 §6.3 说这一步「单独一个分支、单独合并、纯重构」。64 KiB 那个毛病（`tasks/todo.md`「安卓平板」第一条，「P1 接会话之前要修好」）是共用 hub 的行为修复，不是重构，塞进重构分支就不「纯」了，而且它在桌面上同样会丢连接，没理由等 Linux 实机回归。所以本计划是**两个分支、两次合并**：Task 1–2 在 `fix/hub-long-reply`，只要 Mac 门禁全过就合（发版 session 会照常发出去）；Task 3–8 在 `refactor/session-port`，按 §6.3 的条件合（Mac 门禁 + Linux 实机回归）。两个分支互不依赖，可以并行，但 `refactor/session-port` 合并前要先 `git merge main`。

## Global Constraints

- Linux 上 `rapp-session` 的行为、输出格式一个字节都不变，现有测试照跑（§6.2）。
- `refactor/session-port` 是纯重构：不带任何安卓代码（§6.3）。不新增 `Platform.isAndroid`、不加 `android-ffi`、不加 `gui/android/`。
- `refactor/session-port` 合并条件：Mac 门禁全过；Linux 上实机走一遍会话（接入、打字、拖动、复制粘贴、传文件）。**Linux 实机验不了就不合并**，写进 `tasks/todo.md` 等另一台机器验（§6.3）。
- Mac 门禁（每个分支合并前在分支上跑全）：
  ```bash
  swift build -c release && swift test
  cd rust && cargo test --workspace --no-fail-fast
  cd rust && cargo clippy --workspace --all-targets -- -D warnings
  cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test
  git checkout gui/pubspec.lock   # 跑完测试还原
  ```
  Flutter 在 `~/development/flutter/bin`，不在 PATH 上。
- 已知的本机失败，不算这次弄坏的（`tasks/todo.md`「安卓平板」第二条）：`gui/test/embed/linux_detach_test.dart` 的两条（要先 `cd rust && cargo build --release -p rapp-client-core --bin rapp-session`），`gui/test/service_client_test.dart` 的「ServiceMonitor share…」时好时坏。门禁里出现这几条之外的失败就停。
- relay 地址和密钥不打印、不进日志、不提交。
- 实机回归连 Mac 时用单应用会话；桌面会话会把用户自己的会话顶掉，Mac 在最后一个计数会话结束 10 s 后自动锁屏。只有某一步确实要桌面会话才开。
- 合并照 `CLAUDE.md`：在分支上 `git merge main` 解决冲突，再在本机 main 上 `git merge --no-ff <branch>`，提交信息 `merge: <中文说明>（<branch>）`。不改版本号（`gui/pubspec.yaml`、`rust/Cargo.toml`、`Cargo.lock`），不打 tag，不 `git push`，不动 `website/releases.json`。
- 搜代码用 `/usr/bin/grep`（这台机器的 `grep` 是 ugrep，`-q -v` 的退出码不一样）。
- 不读不搜 `docs/archives/`。
- 探查分支 `probe/android-p0`（`cfd7997e`）上的这些东西不带过来：`keeps_link`（按错误文字判断）、`P0_SLOW_MS`、`p0 fps` / `p0 traffic` 日志、`rapp_p0_resolve`、`LinuxSessionPort.ffi` 和它的 `slow`、`main_p0_shell.dart`、`p0/` 页面、`p0SlowFromProperty`、`_traffic`。看探查代码只用 `git show cfd7997e:<path>`。
- 和 `origin/fix/windows-gate`（`05e54ae7`，没合）会撞：它改了 `linux_session_port_test.dart`（加了 skip「C 段做完时打开」）、`session_worker_test.dart`、`linux_detach_test.dart`、`rust/hub/src/link.rs`（`RELAY_WAIT`）、`tasks/todo.md`。它先进 main 的话，合并时留下它的 skip 和 `RELAY_WAIT`，把它对 `linux_session_port_test.dart` 的改动搬到改名后的 `worker_session_port_test.dart`。

## Review Focus

1. **Mac 服务跑了一小时以上，余力的第一行带满 720 个点**：余力照常到，连接和上面的会话都不断。→ Task 2 的 `history_of_720_widest_points_fits_half_the_history_line` 和 `watch_load_reply_reads_past_64k`。
2. **别的回复也超长（比如将来某个列表）**：那一个请求失败，同一条连接上的会话不跟着断，下一个请求还走这条连接。→ Task 2 的 `a_too_long_reply_keeps_the_cached_link`。
3. **会话通路中途死掉（子进程崩了、管道断了）**：端口恰好发一次 `disconnected`，不挂住、不重复。→ Task 4 的 `'a worker that dies mid-session ends the link once'`。
4. **帧被丢掉（会话已分离、已断开、已关）**：丢掉的帧也 ack；P1b 的进程内通路少 ack 一次会话就永远结束不了。→ Task 6 的 `'every frame packet is acked once, dropped ones too'`。
5. **内存紧张时放掉了画面，会话再回到台上**：画面马上回来（用最后一帧重画），不是黑的。→ Task 7 的 `'dropTextures forgets pictures and restoreStage brings them back'`。

---

## 分支一：`fix/hub-long-reply`

### Task 1: 读行带上限参数，超长报专门的错

**Files:**
- Modify: `rust/net/src/line.rs`（`read_line`、`read_json` 和它们的测试）

**Interfaces:**
- Consumes: 无
- Produces:
  - `pub const HISTORY_LINE: usize = 256 * 1024;`（带满 720 个点的余力首行用；实测 75,125 字节，每点 99–103 字节，留到 2 倍以上的余量）
  - `#[derive(Debug)] pub struct LineTooLong(pub usize);`，实现 `Display`（`line longer than {n} bytes`）和 `std::error::Error`；`n` 是这次的上限
  - `pub async fn read_line_max<R: AsyncRead + Unpin>(r: &mut R, max: usize) -> Result<Option<String>>`：超长时返回 `anyhow::Error::new(LineTooLong(max))`
  - `pub async fn read_json_max<R: AsyncRead + Unpin>(r: &mut R, max: usize) -> Result<Value>`
  - `read_line` / `read_json` 不改签名，转调 `*_max(r, MAX_LINE)`

- [ ] **Step 1: 建分支**

```bash
cd /Users/bruce/git/rapp && git worktree add .worktrees/hub-long-reply -b fix/hub-long-reply main
```

- [ ] **Step 2: 写失败的测试**（`line.rs` 的 `mod tests`）

```rust
#[tokio::test]
async fn read_line_max_takes_a_line_exactly_at_the_limit() {
    let mut b = vec![b'x'; 100]; b.push(b'\n');
    assert_eq!(read_line_max(&mut b.as_slice(), 100).await.unwrap().unwrap().len(), 100);
}

#[tokio::test]
async fn read_line_max_reports_line_too_long_with_its_limit() {
    let mut b = vec![b'x'; 101]; b.push(b'\n');
    let e = read_line_max(&mut b.as_slice(), 100).await.unwrap_err();
    assert_eq!(e.downcast_ref::<LineTooLong>().map(|t| t.0), Some(100));
}

#[tokio::test]
async fn read_line_still_stops_at_64k() {
    let mut b = vec![b'x'; MAX_LINE + 1]; b.push(b'\n');
    let e = read_line(&mut b.as_slice()).await.unwrap_err();
    assert_eq!(e.downcast_ref::<LineTooLong>().map(|t| t.0), Some(MAX_LINE));
}
```

- [ ] **Step 3: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-net line::tests`
Expected: 编译失败，`read_line_max`、`LineTooLong` 没定义

- [ ] **Step 4: 按上面的 Produces 实现**

`read_line` 原来 `bail!("line longer than 64 KiB")` 的地方换成 `LineTooLong(max)`。改文件头注释：64 KiB 是默认上限，个别已知很长的回复由调用方给更大的上限。

- [ ] **Step 5: 跑，看它通过**

Run: `cd rust && cargo test -p rapp-net`
Expected: PASS（含原有的 `reads_lines_without_overreading`）

- [ ] **Step 6: 提交**

```bash
git add rust/net/src/line.rs
git commit -m "fix(net): read_line_max with a typed LineTooLong error; HISTORY_LINE for long replies"
```

### Task 2: hub 给余力的回复放宽上限，超长不丢连接

**Files:**
- Modify: `rust/hub/src/link.rs:143-151`（`exchange`）、`:680-695`（`relay_hello`）、`:872-`（`request` 两处出错分支）、`mod tests`
- Modify: `rust/service/src/load/rules.rs`（`mod tests`，只加测试）
- Test: `rust/testkit/tests/hub_load.rs`

**Interfaces:**
- Consumes: Task 1 的 `read_json_max`、`LineTooLong`、`HISTORY_LINE`
- Produces（都在 `link.rs`，私有）:
  - `fn reply_limit(op: &Op) -> usize`：`Op::WatchLoad` 和 `Op::Load { history: true, .. }` 给 `HISTORY_LINE`，其余 `MAX_LINE`
  - `fn link_kept(e: &anyhow::Error) -> bool`：`e.downcast_ref::<LineTooLong>().is_some()`。按类型认，不按错误文字（探查的 `keeps_link` 按文字，不能带过来）

- [ ] **Step 1: 写失败的测试**

`link.rs` 的 `mod tests`（`use super::{reply_limit, link_kept}` 加进去）：

```rust
#[test]
fn reply_limit_widens_only_the_load_history() {
    assert_eq!(reply_limit(&Op::WatchLoad), HISTORY_LINE);
    assert_eq!(reply_limit(&Op::Load { history: true, top: false }), HISTORY_LINE);
    assert_eq!(reply_limit(&Op::Load { history: false, top: false }), MAX_LINE);
    assert_eq!(reply_limit(&Op::Ping), MAX_LINE);
}

#[test]
fn link_kept_only_for_a_too_long_line() {
    assert!(link_kept(&anyhow::Error::new(LineTooLong(MAX_LINE))));
    assert!(!link_kept(&anyhow!("line longer than 64 KiB"))); // 文字一样也不算
    assert!(!link_kept(&anyhow!("stream closed")));
}
```

`rules.rs` 的 `mod tests`：

```rust
#[test]
fn history_of_720_widest_points_fits_half_the_history_line() {
    // 每个点每一项都填到最宽：cpu、mem（含 swap、pressure）、heat（含摄氏度）、两块盘、最长的数字
    let h = series(KEEP, 5, |_| widest_sample());
    let line = serde_json::to_vec(&h.history_json()).unwrap().len();
    assert!(line < rapp_net::line::HISTORY_LINE / 2, "{line}");
}
```

`widest_sample()` 写在这个测试旁边，`Sample` 里每个 `Option` 都给 `Some`、数字取 `u64::MAX` 级别、浮点带满小数位。

`testkit/tests/hub_load.rs`：

```rust
#[tokio::test]
async fn watch_load_reply_reads_past_64k() { /* 假的 A：收到 watch_load 回一行 100 KiB 的 {"ok":true,"history":[…]}，再回一行 point */ }

#[tokio::test]
async fn a_too_long_reply_keeps_the_cached_link() { /* 假的 A：对某个普通请求回 70 KiB 的行；之后 hub 对同一主机发 ping，走的仍是同一条连接（假 A 只接受过一次连接） */ }
```

两条测试的假 A 用 `tests/common/mod.rs` 现有的起服务、起 hub 的工具；要是它们给不了「回一行任意长的字」，在 `common/mod.rs` 里加一个最小的假 A（只认 hello、ping 和一个固定的长回复），不要改真服务。断言：第一条收到 `history` 是数组的 `load` 事件；第二条长回复那次返回错误，之后 `ping` 成功并且假 A 的接受计数是 1。

- [ ] **Step 2: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-hub link::tests && cargo test -p rapp-service load::rules && cargo test -p rapp-testkit --test hub_load`
Expected: `reply_limit`、`link_kept` 没定义；两条 testkit 测试失败（`line longer than`、连接计数 2）。`rules` 那条可能直接通过——它守的是余量，通过就留着。

- [ ] **Step 3: 实现**

- `exchange`：`read_json(&mut s)` 换成 `read_json_max(&mut s, lines.last().map_or(MAX_LINE, |op| reply_limit(op)))`。
- `relay_hello`：读回复那行换成 `read_json_max(&mut pipe, reply_limit(op))`；`read_welcome` 不动。
- `hello`（直连握手，回的是 `ping`）不动。
- `request()`：缓存连接那支在现有各个 `Err(e)` 分支之前加 `Err(e) if link_kept(&e) => return Err(e)`；新连接那支在 `forget_if_dead` 之前同样先判 `link_kept`，是就直接返回错误。注释写明：回复太长是这一条回复的事，连接是好的。

- [ ] **Step 4: 跑，看它通过**

Run: `cd rust && cargo test -p rapp-hub && cargo test -p rapp-service && cargo test -p rapp-testkit --test hub_load`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add rust/hub/src/link.rs rust/service/src/load/rules.rs rust/testkit/tests/hub_load.rs rust/testkit/tests/common/mod.rs
git commit -m "fix(hub): load history replies read up to 256 KiB; a too-long reply no longer drops the link"
```

- [ ] **Step 6: 门禁、待办、合并**

1. 跑 Global Constraints 里的整套 Mac 门禁（这一支没动 `hub-ffi`，不用编 iOS 模拟器的库）。
2. 在分支上把 `tasks/todo.md`「安卓平板」第一条改成 `[x]`，后面写一句「`fix/hub-long-reply` 修了：余力回复放宽到 256 KiB，超长不丢连接」。提交 `docs(todo): 64 KiB 回复行已修`。
3. `git merge main`，在本机 main 上 `git merge --no-ff fix/hub-long-reply -m "merge: hub 读长回复不再丢连接（fix/hub-long-reply）"`。

---

## 分支二：`refactor/session-port`

### Task 3: 会话循环进库（`rapp_client_core::session`）

**Files:**
- Create: `rust/client-core/src/session/mod.rs`（`bin/rapp-session.rs` 里除 `main` 以外的全部，连同 11 条测试）
- Move: `rust/client-core/src/bin/session_output/mod.rs` → `rust/client-core/src/session/output.rs`（`git mv`）
- Move: `rust/client-core/src/bin/session_trace/mod.rs` → `rust/client-core/src/session/trace.rs`（`git mv`）
- Modify: `rust/client-core/src/lib.rs`（`pub mod session;`）
- Modify: `rust/client-core/src/bin/rapp-session.rs`（只剩 `main`）

**Interfaces:**
- Consumes: 无
- Produces:
  - `pub fn run(input: impl BufRead + Send + 'static, out: &Output) -> Result<()>`：第一行是启动参数（仍按 `take(1024 * 1024)` 读），之后一行一条命令
  - `pub fn serve(input: impl BufRead + Send + 'static, writer: impl Write + Send + 'static)`：`Output::spawn(writer)`、`run`、发 `disconnected` 事件（`reason` 是 `closed` 或 `{e:#}`）、`finish`、`join` 写线程——就是现在 `main` 的身体
  - `pub use output::Output;`（`spawn`、`event`、`frame`、`finish` 不改）
  - `pub fn trace_to(dir: PathBuf)`：设一次追踪目录（`OnceLock`，再设无效）；库里不再读环境变量
  - 可执行文件：`fn main()` 读 `RAPP_STREAM_TRACE_DIR`，非空就 `session::trace_to`，然后 `session::serve(BufReader::new(std::io::stdin()), std::io::stdout())`

- [ ] **Step 1: 建分支，记下基线**

```bash
cd /Users/bruce/git/rapp && git worktree add .worktrees/session-port -b refactor/session-port main
cd .worktrees/session-port/rust && cargo test -p rapp-client-core 2>&1 | /usr/bin/grep -E '^test result|Running'
```

Expected: 记下每个测试目标的通过数（P0 量到 lib 18、bin 11、client 44、host_wire 3、probe 5，以本次实测为准）。

- [ ] **Step 2: 写失败的测试**（新文件 `session/mod.rs` 的 `mod tests`，在搬代码之前先建空模块放它）

```rust
#[test]
fn serve_over_memory_ends_with_one_disconnected() {
    // 输入只有一行坏的启动参数；输出写进 Vec
    let out = run_serve(b"not json\n");
    let events: Vec<_> = packets(&out).filter(|p| p[0] == 0).collect();
    assert_eq!(events.len(), 1);
    assert!(std::str::from_utf8(&events[0][1..]).unwrap().contains("\"event\":\"disconnected\""));
}

#[test]
fn trace_to_is_set_once() {
    let a = tempfile::tempdir().unwrap(); let b = tempfile::tempdir().unwrap();
    trace_to(a.path().into()); trace_to(b.path().into());
    assert_eq!(trace_dir(), Some(a.path()));
}
```

`run_serve`、`packets` 是测试里的小工具（`packets` 按现有管道格式切包：长度前缀照 `output.rs` 的写法）；`trace_dir()` 是 `trace.rs` 里 `#[cfg(test)]` 的读取口。

- [ ] **Step 3: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-client-core session::`
Expected: 编译失败，`serve`、`trace_to` 没定义

- [ ] **Step 4: 搬代码**

把 `event`、`menus`、`number`、`float`、`command`、`run`、`is_input`、`Probe`、`read_loop` 和 11 条测试原样搬进 `session/mod.rs`；`run` 的输入从 `stdin().lock()` 换成参数 `input`；`main` 的身体变成 `serve`。`trace.rs` 原来 `std::env::var_os("RAPP_STREAM_TRACE_DIR")` 的地方改读 `trace_to` 设的目录。可执行文件只剩 Produces 里写的 `main`。除了这几处，函数体一个字不改。

- [ ] **Step 5: 跑，看它通过，和基线对数**

Run: `cd rust && cargo test -p rapp-client-core 2>&1 | /usr/bin/grep -E '^test result|Running' && cargo clippy -p rapp-client-core --all-targets -- -D warnings`
Expected: 总数 = 基线 + 2；bin 目标是 0 条，那 11 条出现在 lib 目标里；`host_wire` 照样起真的 `rapp-session` 并通过。

- [ ] **Step 6: 提交**

```bash
git add -A rust/client-core
git commit -m "refactor(client-core): the session loop is a library module; rapp-session only wires stdin/stdout"
```

### Task 4: `SessionLink` / `SessionLinks` 和子进程那一半

**Files:**
- Create: `gui/lib/embed/session_link.dart`
- Test: `gui/test/embed/session_link_test.dart`

**Interfaces:**
- Consumes: `gui/lib/embed/session_worker.dart` 的 `SessionWorker`（`start`、`fromProcess`、`pid`、`packets`、`send`、`closeInput`、`kill`、`exitCode`、`inputDone`，不改）
- Produces:

```dart
/// 一条会话通路：一个 rapp-session 子进程（Linux、Windows），或进程内的会话库（安卓，P1b）。
abstract class SessionLink {
  int get id;                         // 追踪日志里的编号（子进程是 pid）
  Stream<Uint8List> get packets;      // 管道格式的包：首字节 0 是事件 JSON，1 是「24 字节帧头 + BGRA」
  void send(String line);             // 一行 JSON 命令，不带换行
  void ack();                         // 一帧用完了（做成图片或丢掉）；子进程那边是空操作
  Future<void> close();               // 不再发命令（关输入）
  void kill();                        // 立刻结束
  Future<int> get exitCode;
  Future<void> get inputDone;         // 输入那头断了时带错误完成
}

abstract class SessionLinks {
  Future<void> check();               // 端口 init 时调；不可用就抛
  Future<SessionLink> open();
}

class ProcessSessionLink implements SessionLink { ProcessSessionLink(SessionWorker worker); }
class ProcessSessionLinks implements SessionLinks { ProcessSessionLinks(String executable); }
```

`ProcessSessionLinks.check()` 文件不在时抛 `StateError('rapp-session not found: $executable')`（现在 `init` 里的原话）；`open()` 是 `ProcessSessionLink(await SessionWorker.start(executable))`。`ProcessSessionLink.kill()` 发 `ProcessSignal.sigkill`，`close()` 是 `closeInput()`，`id` 是 `pid`。

- [ ] **Step 1: 写失败的测试**

```dart
test('ProcessSessionLinks.check names a missing executable', () async {
  await expectLater(ProcessSessionLinks('/nope/rapp-session').check(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('rapp-session not found'))));
});

test('ProcessSessionLink passes packets, lines and close through', () async {
  // cat 当子进程：写进去的一个管道格式的包原样回来
  final link = ProcessSessionLink(SessionWorker.fromProcess(await Process.start('cat', const [])));
  link.send(...一个能被 cat 回显成合法包的行...);
  expect(await link.packets.first, ...);
  link.ack(); // 不抛、不发东西
  await link.close();
  expect(await link.exitCode, 0);
});

test('a worker that dies mid-session ends the link once', () async {
  final link = ProcessSessionLink(SessionWorker.fromProcess(await Process.start('sh', ['-c', 'exit 3'])));
  expect(await link.packets.toList(), isEmpty);
  expect(await link.exitCode, 3);
  link.kill(); // 已经结束，再杀不抛
});
```

第二条的回显用 `session_worker_test.dart` 里现有的造包办法（`test('isolated pipe preserves large fragmented packets and exits'` 那条）。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/session_link_test.dart`
Expected: FAIL，`session_link.dart` 不存在

- [ ] **Step 3: 按 Produces 实现**

- [ ] **Step 4: 跑，看它通过**

Run: 同 Step 2
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/session_link.dart gui/test/embed/session_link_test.dart
git commit -m "refactor(gui): SessionLink/SessionLinks with the child-process implementation"
```

### Task 5: `SessionCopy` 和 `SessionHost` / `LinuxSessionHost`

**Files:**
- Move: `gui/lib/embed/linux_clipboard.dart` → `gui/lib/embed/session_copy.dart`（`git mv`，只留 `SessionCopy` 和存取函数）
- Create: `gui/lib/embed/session_host.dart`（抽象 `SessionHost`）
- Create: `gui/lib/embed/linux_session_host.dart`（`LinuxSessionHost`，收下原 `LinuxDesktop`）
- Modify: `gui/lib/embed/linux_transfer.dart`、`gui/lib/embed/linux_session_port.dart`、`gui/test/embed/linux_transfer_test.dart`、`gui/test/embed/linux_session_port_test.dart`（改名跟着走）
- Test: `gui/test/embed/linux_session_host_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class SessionCopy`（原 `LinuxCopy`，字段、`toMap`、`fromMap` 不变）；`Future<String> saveSessionCopy(...)`、`Future<SessionCopy?> loadSessionCopy(String path)`（原 `saveLinuxCopy` / `loadLinuxCopy`，参数不变）
  - ```dart
    abstract class SessionHost {
      Future<void> init();                       // 端口 init 时调一次
      String downloads();                        // 传文件落盘目录
      Future<bool> reveal(String path);          // 去看收到的文件
      Future<SessionCopy?> readClipboard();
      Future<bool> writeClipboard(SessionCopy copy);
      Future<List<String>> chooseFiles();
      String? get traceDir;                      // null：不追踪
      MethodChannel? get detachChannel;          // 分离窗口那一组；null：没有
      bool get supportsInlineNativeComposer;
      bool get supportsDetach;
    }
    ```
  - `class LinuxSessionHost implements SessionHost { LinuxSessionHost({MethodChannel channel = const MethodChannel('rapp/linux'), Map<String, String>? env}); }`：
    - `downloads()`：`env['RAPP_DOWNLOADS'] ?? '${dataRoot(env, 'linux')}/files/transfers'`（现在端口构造里的那段）
    - `reveal`：现在端口 `:488` 的 `xdg-open` 那段
    - `readClipboard` / `writeClipboard` / `chooseFiles`：原 `LinuxDesktop` 的三个方法原样
    - `traceDir`：`env['RAPP_STREAM_TRACE_DIR']`，空串算 null
    - `detachChannel`：`channel`；`supportsDetach`、`supportsInlineNativeComposer` 取端口现在给 Linux 的值
  - 文件名 `linux_transfer.dart`、`linux_text_upload.dart` 不改（它们走的是 A 的传文件协议，和平台无关，改名只会让这次的差异变大；类名 `LinuxTransfers` 也不改）

- [ ] **Step 1: 写失败的测试**

```dart
test('LinuxSessionHost reads downloads and the trace dir from the environment', () {
  final h = LinuxSessionHost(env: {'RAPP_DOWNLOADS': '/d', 'RAPP_STREAM_TRACE_DIR': '/t'});
  expect(h.downloads(), '/d');
  expect(h.traceDir, '/t');
  expect(LinuxSessionHost(env: {'RAPP_STREAM_TRACE_DIR': '', 'HOME': '/h'}).traceDir, isNull);
});

test('LinuxSessionHost falls back to Flutter text when the native clipboard is missing', () async {
  // rapp/linux 没有处理器 → MissingPluginException → Clipboard 的文字
  ...
  expect((await LinuxSessionHost().readClipboard())?.kind, 'text');
});

test('SessionCopy round-trips through save and load', () async { ... expect(loaded!.toMap(), copy.toMap()); });
```

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/linux_session_host_test.dart`
Expected: FAIL，`LinuxSessionHost` 不存在

- [ ] **Step 3: 实现**

`git mv` 后改类名，`/usr/bin/grep -rn 'LinuxCopy\|LinuxDesktop\|saveLinuxCopy\|loadLinuxCopy' gui/lib gui/test` 逐处换掉。端口里 `desktop.readClipboard` 等改成调 `host`，这一步端口仍叫 `LinuxSessionPort`，构造参数 `desktop:` 换成 `host:`（默认 `LinuxSessionHost()`），`downloads:` 去掉（由 host 给）。端口里 `desktop.channel.invokeMethod(...)` 一律改成 `host.detachChannel?.invokeMethod(...)`；顶上读 `RAPP_STREAM_TRACE_DIR` 的 `_streamTrace` 改成读 `host.traceDir`。

- [ ] **Step 4: 跑，看它通过**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test test/embed/`
Expected: analyze 无问题；`test/embed/` 除已知的 `linux_detach_test` 两条外 PASS

- [ ] **Step 5: 提交**

```bash
git add -A gui/lib/embed gui/test/embed
git commit -m "refactor(gui): SessionHost; LinuxSessionHost takes the Linux clipboard, files, reveal, trace and detach channel"
```

### Task 6: `WorkerSessionPort`、`FrameSink`、`hidMacKeyCode`，桌面入口接上

**Files:**
- Move: `gui/lib/embed/linux_session_port.dart` → `gui/lib/embed/worker_session_port.dart`（`git mv`）
- Move: `gui/test/embed/linux_session_port_test.dart` → `gui/test/embed/worker_session_port_test.dart`（`git mv`）
- Create: `gui/lib/embed/frame_sink.dart`
- Modify: `gui/lib/main.dart:95-106`、`gui/test/embed/linux_key_bar_test.dart`、`gui/test/embed/linux_detach_test.dart`、`gui/test/embed/session_worker_test.dart`

**Interfaces:**
- Consumes: Task 4 的 `SessionLinks`、`SessionLink`、`ProcessSessionLinks`、`ProcessSessionLink`；Task 5 的 `SessionHost`、`LinuxSessionHost`、`SessionCopy`
- Produces:
  - `class WorkerSessionPort extends SessionPort with WidgetsBindingObserver { WorkerSessionPort(SessionLinks links, SessionHost host, {Future<void> Function()? framePresented}); }`
  - `init()` 开头调 `await links.check()` 和 `await host.init()`，代替原来的 `File(executable).exists()`
  - 开会话调 `await links.open()`，代替 `SessionWorker.start(executable)`；`_Session` 持有 `SessionLink`（原来的 `process.pid` → `link.id`，`closeInput` → `close`，`kill(sigkill)` → `kill`；`inputDone.catchError → 'session worker stopped'` 和 2 s 的强杀计时（原 `:1456-1462`）照旧）
  - `@visibleForTesting void seedSessionForTest(Object sid, SessionLink link)`（原来收 `Process`；测试里包一层 `ProcessSessionLink(SessionWorker.fromProcess(proc))`）
  - **ack 的时机**：读循环拿到 kind 1 的包，`queueFrame(...)` 返回后立刻 `link.ack()`；会话已关、已分离、已断开而不进 `queueFrame` 的帧，丢掉时同样 `ack()`。每个帧包恰好 ack 一次。事件包不 ack。
  - ```dart
    /// 一帧画面怎么上屏。现在只有「整帧做成 ui.Image」一种（ImageFrameSink），丙落地时加第二种。
    abstract class FrameSink {
      Future<ui.Image?> decode(Uint8List bgra, int width, int height); // null：中途已不需要
      void retire(ui.Image? image);                                    // 下一帧画完后再释放
    }
    class ImageFrameSink implements FrameSink { const ImageFrameSink(); }
    ```
    `decode` 收下现在 `frame()` 里 `ImmutableBuffer.fromUint8List` → `ImageDescriptor.raw(bgra8888)` → `instantiateCodec` → `getNextFrame` 那一段；`retire` 是现在的 `_retire`。端口构造多一个可选参数 `FrameSink frames = const ImageFrameSink()`。
  - `int? hidMacKeyCode(PhysicalKeyboardKey key)`（原 `linuxMacKeyCode`，映射不变：Ctrl 仍映成 Mac 的 Command 55）
  - `main.dart`：`Platform.isLinux ? WorkerSessionPort(ProcessSessionLinks('$bin/rapp-session'), LinuxSessionHost()) : ChannelSessionPort()`

- [ ] **Step 1: 改名（不改行为）并让现有测试跟着改名**

```bash
git mv gui/lib/embed/linux_session_port.dart gui/lib/embed/worker_session_port.dart
git mv gui/test/embed/linux_session_port_test.dart gui/test/embed/worker_session_port_test.dart
```

`/usr/bin/grep -rn 'LinuxSessionPort\|linux_session_port\|linuxMacKeyCode' gui/lib gui/test` 逐处换成新名字；测试里 `LinuxSessionPort('unused', ...)` 换成 `WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), ...)`，`seedSessionForTest(3, proc)` 换成 `seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(proc)))`。此时构造函数先按 Produces 改好，内部仍可直接用 `SessionWorker`。

- [ ] **Step 2: 写失败的测试**（`worker_session_port_test.dart`）

```dart
test('every frame packet is acked once, dropped ones too', () async {
  final link = CountingLink();             // 测试里的 SessionLink：packets 由测试推，记 ack 次数
  final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {});
  port.seedSessionForTest(3, link);
  link.push(windowsEvent()); link.push(frame2x2()); link.push(frame2x2());
  await pumpEventQueue();
  expect(link.acks, 2);                    // 事件不 ack
  port.detachForTest(3);                   // 已分离：帧丢掉
  link.push(frame2x2());
  await pumpEventQueue();
  expect(link.acks, 3);
  link.end();                              // 断开后的帧也丢掉
  link.push(frame2x2());
  await pumpEventQueue();
  expect(link.acks, 4);
});

test('init asks the links and the host first', () async {
  final links = FailingLinks(StateError('rapp-session not found: x'));
  await expectLater(WorkerSessionPort(links, FakeHost()).init(), throwsStateError);
});

test('hidMacKeyCode keeps the Mac codes', () {
  expect(hidMacKeyCode(PhysicalKeyboardKey.keyA), 0);
  expect(hidMacKeyCode(PhysicalKeyboardKey.controlLeft), 55);
});
```

`frame2x2()` 是 `[1, ...u32le(2), ...u32le(2), ...f32le(0), ...f32le(0), ...f32le(2), ...f32le(2), ...16 字节 BGRA]`；`windowsEvent()` 是 kind 0 的一条 `windows` 事件。`CountingLink`、`OneLink`、`FailingLinks`、`FakeHost` 写在 `gui/test/embed/fake_session_link.dart`，P1b 的测试也用。`detachForTest` 只有现成的测试入口给不了「已分离」时才加，`@visibleForTesting`。

- [ ] **Step 3: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/worker_session_port_test.dart`
Expected: 新的三条 FAIL（`seedSessionForTest` 收的类型不对、ack 计数 0、`hidMacKeyCode` 没定义）

- [ ] **Step 4: 实现 Produces 里剩下的**

`_Session` 改持 `SessionLink`；读循环按上面的 ack 规则调 `link.ack()`；`FrameSink` 抽出来；`main.dart` 那一行换掉。

- [ ] **Step 5: 跑，看它通过**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test test/embed/`
Expected: 除已知的两条外 PASS；`/usr/bin/grep -rn 'LinuxSessionPort\|linuxMacKeyCode\|LinuxCopy\|LinuxDesktop' gui/lib gui/test` 没有输出

- [ ] **Step 6: 提交**

```bash
git add -A gui/lib gui/test
git commit -m "refactor(gui): WorkerSessionPort over SessionLinks + SessionHost; FrameSink; hidMacKeyCode"
```

### Task 7: `dropTextures` 在共用端口里实现

**Files:**
- Modify: `gui/lib/embed/worker_session_port.dart`（覆盖 `dropTextures`）
- Test: `gui/test/embed/worker_session_port_test.dart`

**Interfaces:**
- Consumes: `SessionPort.dropTextures(Object sid)`（`session_port.dart:610`，调用方 `main_state.dart:3442` 的 `memoryWarning`，只对不在台上、已断开的会话调）
- Produces: `@override void dropTextures(Object sid)`：把这个会话 `_pictures` 里每个 `RemoteWindow` 的 `ui.Image` 交给 `frames.retire`，清空 `_pictures`，发一次让画面刷新的事件（和 `crop.isEmpty` 那支丢图后发的相同）。`lastNativeFrame` 留着——它是 `restoreStage` 重画的来源，只占一份 BGRA。

- [ ] **Step 1: 写失败的测试**

```dart
test('dropTextures forgets pictures and restoreStage brings them back', () async {
  // seed 一个会话，推一帧，等出现带图的 WindowsEvent
  ...
  port.dropTextures(3);
  expect(port.picturesForTest(3), isEmpty);
  port.restoreStageForTest(3);   // 等于会话回到台上
  await pumpEventQueue();
  expect(port.picturesForTest(3), isNotEmpty);
  expect(link.acks, 1);          // 重画不是新帧，不 ack
});
```

`picturesForTest`、`restoreStageForTest` 若没有现成入口就加，`@visibleForTesting`。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/worker_session_port_test.dart --name dropTextures`
Expected: FAIL（`_pictures` 还在）

- [ ] **Step 3: 按 Produces 实现**

- [ ] **Step 4: 跑，看它通过**

Run: 同 Step 2
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/worker_session_port.dart gui/test/embed/worker_session_port_test.dart
git commit -m "feat(gui): WorkerSessionPort.dropTextures lets go of an off-stage session's pictures"
```

### Task 8: 门禁、Linux 实机回归、合并

**Files:**
- Modify: `tasks/todo.md`（Windows 一节一行；验不了时「安卓平板」一节一行）

**Interfaces:**
- Consumes: Task 3–7 的全部
- Produces: 本机 main 上的 `merge: 会话端口拆成共用的 WorkerSessionPort（refactor/session-port）`；`tasks/todo.md` Windows 一节写明接口在哪个提交

- [ ] **Step 1: 合进最新的 main，跑整套 Mac 门禁**

```bash
cd /Users/bruce/git/rapp/.worktrees/session-port && git merge main
```

然后跑 Global Constraints 里的整套命令（这一支没动 `hub-ffi`）。`origin/fix/windows-gate` 已进 main 的话按 Global Constraints 最后一条处理冲突。
Expected: 除已知的三条外全过。

- [ ] **Step 2: Linux 实机回归**

Linux 机器要拿到这个分支。功能 session 不能 `git push`（`CLAUDE.md`），所以先用 AskUserQuestion 问用户：由用户把分支推上去，还是这一次允许推这一个分支（只推分支，不推 main、不打 tag）。拿到后在 Linux 机器上：

```bash
git fetch origin && git checkout refactor/session-port
scripts/build-linux.sh            # 要 Flutter ≥ 3.50.0
cd gui && flutter test test/embed/   # Linux 上那些 skip 掉的真 worker 测试这里才跑
```

然后开打出来的包，对 Mac 开一个单应用会话（比如「文本编辑」），逐项走：

| 项 | 做法 | 过的标准 |
|---|---|---|
| 接入 | 全景里点 Mac，开单应用会话 | 画面出来，窗口表对 |
| 打字 | 外接键盘打一段中英文；Ctrl+C / Ctrl+V | Mac 上一个字不少；Ctrl 当 ⌘ |
| 拖动 | 拖窗口、选一段文字 | 跟手，画面不花 |
| 复制粘贴 | Mac 复制一段字到 Linux，Linux 复制一段字到 Mac | 两边都到 |
| 传文件 | Linux 发一个文件给 Mac；Mac 发一个给 Linux，点「在文件夹中显示」 | 都到，落在 `files/transfers`，文件管理器打开 |
| 分离窗口 | 把会话分离出去再收回 | 和改之前一样 |

- [ ] **Step 3a（Linux 验过）: 写待办、合并**

在分支上往 `tasks/todo.md` 的 Windows 一节加一行：「会话端口的小接口（`SessionLinks` / `SessionLink` / `SessionHost`，`gui/lib/embed/session_link.dart`、`session_host.dart`）已在 `<Task 6 的提交号>`，`ProcessSessionLink` 就是 Windows 那一半；Windows 接着加 `WindowsSessionHost`，不要另做一个（规格 §14.3）」。提交 `docs(todo): 会话端口接口的位置`。然后在本机 main 上：

```bash
git merge --no-ff refactor/session-port -m "merge: 会话端口拆成共用的 WorkerSessionPort（refactor/session-port）"
```

- [ ] **Step 3b（Linux 验不了）: 不合并**

分支留着。在本机 main 上往 `tasks/todo.md`「安卓平板」一节加一行：「`refactor/session-port`（`<分支头提交号>`）Mac 门禁已过，等 Linux 实机回归（接入、打字、拖动、复制粘贴、传文件、分离窗口）后合并；P1b 在这之前不能合」，提交 `docs(todo): 共用重构等 Linux 回归`。告诉用户在等什么。

## Self-review（写完后自查，已就地改过）

- 规格覆盖：§6.2 的 `run`、`Output`、追踪参数、可执行文件只剩 `main` → Task 3；`rapp-android-ffi` 归 P1b。§6.3 的改名、`SessionLink`（`send`/包流/`ack`/`close`）、`SessionHost`（落盘、`reveal`、剪贴板、追踪、分离窗口一组、两个 `supports*`）、`dropTextures`、`FrameSink`、键码改名、`main.dart` 那一行、单独分支和合并条件 → Task 4–8。差别表是「P1 动手前」给安卓用的，放在 P1b Task 1。§14.3 的 Windows 待办 → Task 8。todo 里 64 KiB 那条 → Task 1–2。
- `SessionLink` 用 `packets` 而不是规格写的 `messages`：内容是管道格式的包，叫 packets 和 `SessionWorker` 一致（§15.3 名字留给实施者）。
- 类型一致：`seedSessionForTest(Object, SessionLink)`、`WorkerSessionPort(SessionLinks, SessionHost, {framePresented, frames})`、`SessionCopy`、`hidMacKeyCode` 在 Task 5–7 和 P1b 里写法相同。
- 比例：代码块只有接口和测试断言，函数体都留给实施者。
