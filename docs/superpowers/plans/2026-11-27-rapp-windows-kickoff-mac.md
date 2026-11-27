你在这台 Mac 上，接手 rApp Windows 版里只能在 Mac 上做的事。主要的活在 Windows 机器上，由另一个 agent 负责，它的提示词是 `docs/superpowers/plans/2026-11-27-rapp-windows-kickoff-windows.md`。

## 已经做完的（2026-11-27），不用再做

- 探针 C1：Rust 用 `libz-sys` 静态编的原版 zlib，压缩结果和 Swift 逐字节相同。只在 Mac arm64 上量过。
- Swift 样本 47 个文件，在 `rust/host-core/tests/fixtures/`。
- A、B 两段的代码在 Mac 上修到 Mac 门禁全绿，**接线已经合进 `main`**（A `5e39bb91`，B `a401ab19`）。用户定的是 Mac 绿了就合，不等 Windows 机器。数字和没验过的东西见交接文档 `docs/superpowers/plans/2026-11-26-rapp-windows-handoff.md` §2.2。

所以 `main` 里现在有 A、B 两段的全部代码，三个新 crate 都在 workspace 的成员表里。分支 `feat/windows-foundation`、`feat/windows-host-core` 不再用。

## 背景

rApp 是远程控制软件，macOS 版在用，Mac 发版 session 盯着 `main` 自动发版。被控端的逻辑在 Swift 里（`Sources/`）；`rust/host-core` 是它的不认识操作系统的 Rust 移植，以后由 `rust/host-windows` 接上系统。**Swift 是基准**：两边不一致时改 Rust，不改 Swift，不改样本。

`cfg(windows)` 里的代码 Mac 编不到，从来没编过。它第一次编是在 Windows 机器上。

## 先读

1. `CLAUDE.md`
2. 交接文档的 §2.2、§4、§5、§6。
3. 用到哪一段再读哪一段的计划：`…-windows-a-foundation.md`、`…-windows-b-host-core.md`。

不要读、不要搜 `docs/archives/`。

## Mac 上还剩的三件事

**1. Windows 那边推上来的分支过 Mac 门禁。** Windows 上的修改如果落在 unix 也编译的代码里（`rust/host-core/`、testkit、已有 crate 里不带 `cfg(windows)` 的部分），那边不直接合进 `main`，而是把分支推到 origin，由用户转给你：

1. `git fetch origin`，在 `.worktrees/` 下给这个分支开一个 worktree，`git merge main`。
2. 跑完整的 Mac 门禁：`cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`、`swift test`、`flutter analyze`、`flutter test`。
3. 守住一条：unix 那一支的行为不能变。逐条核对那边交来的“改到了 unix 也编译的代码”的清单，拿不准就和 `main` 上同一条测试的结果对。
4. `host-core` 的测试加两组会话测试要在 60 秒以内（现在约 30 秒）。
5. 绿了照 `CLAUDE.md` 合进本机 `main`：先 `git merge main` 到分支，再在 `main` 上 `git merge --no-ff`，提交信息 `merge: <中文说明>（<branch>）`。这是共用代码，会触发一次 macOS 发版。你在 Mac 上又改了 Windows 也编译的代码时，把分支推回去，请用户让 Windows 那边再跑一次 Windows 门禁，两边在同一个提交上都绿再合。

**2. 重新生成样本。** Windows 那边认定某个样本本身错了（生成器的错，不是 Rust 的错）时，先用 Swift 源码证明。成立的话修 `Tests/RappCoreTests/HostCoreFixtures/` 里的生成器，`RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'` 重新生成，不带变量再跑一遍（比对方式），再跑 `cargo test -p rapp-host-core`，和 Rust 的改动放在同一个提交里。生成器只调用 `Sources/RappCore/` 的代码，**不改 Swift 的访问级别**，不改 `Sources/`。

样本还有一个已知的缺口，补不补由用户定：把 `tile` 的 `MAX_CANDIDATES` 改成 1 或 2，样本测试照样过。

**3. 计划 B 任务 19 步骤 4。** 用真的 Mac 控制端连 `fake-host-core` 走一遍。这只能用户手工做，你把怎么启动、看什么写清楚交给用户。

## 规矩

- **不改**：`Sources/`、`rust/host-linux/`、`rust/client-gtk/`、`rust/hub-ffi/`。
- **中继 `rust/relay/` 只许两处改动**，已经做了：`audit.rs` 的三处 `#[cfg(unix)]`，`admin.rs` 的 unix 代码放到 `#[cfg(unix)]` 后面加同名替身。再多要先问用户。
- **三条模块边界**（规格 §5.3）不能破：`host-core` 里没有任何操作系统相关的代码；`host-windows` 不产生也不解析协议字节；只有 `rapp-svc` 跨登录会话启动进程。
- 不升协议号，不为 Windows 加消息。
- 不改版本号、不打 tag、不推 `main`、不建 release，这些归发版 session。
- 代码和计划不一致时，看 Swift 和规格谁对。计划错了就改计划，和代码改动放在同一个提交里。
- 日志里绝不出现密码、PIN、token、密钥、打的字、剪贴板内容。
- 这台机器上：`grep` 是 ugrep，要用 `/usr/bin/grep`；没有 `timeout` 命令；flutter 在 `~/development/flutter/bin`，跑完测试把 `pubspec.lock` 还原；按路径提交，不用 `git add -A`，不用 `git stash`，不跑 `cargo fmt --all`。
- 两处和 Windows 版无关的环境问题：`rapp-ports` 的 `every_map_stays_when_the_device_list_cannot_be_read` 用固定端口，负载下偶发失败，单独重跑；`gui/test/embed/linux_detach_test.dart` 要先 `cargo build --release -p rapp-client-core --bin rapp-session`。
- 偶发失败先单独重跑，分清是负载还是逻辑。会话测试用 20 倍速的时钟，几处时间窗很紧。

## 这些事停下来问用户，不要自己定

- 要升级 Rust 工具链。发版 session 用的是同一套，Windows 机器也要跟着一样。
- 压缩在 Windows 上和样本对不上，要走计划 B 任务 3 的退路。
- 要改规格 §19.1 第二张单子上的事，或者上面“不改”“边界”里的任何一条。
- 计划 B 任务 19 步骤 4 的真机走查。

## 交回什么

1. 每条门禁命令和它的结果。没跑的要说没跑。
2. 你在 Mac 上又改了什么，哪些要 Windows 那边重跑。
3. Windows 那边那张清单逐条核对的结果。
4. 重新生成过的样本和生成器，各自的 Swift 依据。
5. 还没做的和原因。
