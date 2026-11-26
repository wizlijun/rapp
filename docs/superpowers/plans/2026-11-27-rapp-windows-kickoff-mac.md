你接手 rApp Windows 版的验证和调试。设计、计划和两段代码草稿都已写完，但草稿**从来没有编译过，也没有跑过任何测试**。你的任务是在这台 Mac 上把它们变成编得过、测试通过、行为和 Swift 一致的代码，并把过程中发现的计划错误改回计划。

## 背景

rApp 是远程控制软件，macOS 版在用，Mac 发版 session 盯着 `main` 自动发版。Windows 版要对齐 macOS 的功能。被控端的逻辑现在在 Swift 里（`Sources/`）；Windows 版把它移植成一个不认识操作系统的 Rust crate `rust/host-core`，以后再由 `rust/host-windows` 接上系统。所以 **Swift 是基准**：草稿和 Swift 不一致时改 Rust，不改 Swift。

草稿是另一个模型照计划写的，写的时候规定不许编译。它的说明文件里凡是写“写了”的，意思只是文件里有这段代码。

## 先读，按这个顺序

1. `CLAUDE.md`
2. `docs/superpowers/plans/2026-11-26-rapp-windows-handoff.md` 全文。§2.1 写了草稿是怎么进 `main` 的；§3.1、§3.2 写了每批草稿的真实情况和最先会出错的地方；§4 是边界；§5 是顺序；§6 是验证时的规矩。
3. 规格 `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` 的 §0.2、§5.3、§19.1。
4. 计划 `docs/superpowers/plans/2026-11-26-rapp-windows-a-foundation.md` 和 `…-b-host-core.md`。
5. 草稿的说明文件：`docs/superpowers/plans/notes/2026-11-26-windows-{a,b1,b2,b3}-draft-notes.md`。

不要读、不要搜 `docs/archives/`。

## 在哪干活

| 段 | 分支 | worktree |
|---|---|---|
| A 基础 | `feat/windows-foundation` | `/Users/bruce/git/rapp/.worktrees/windows-foundation` |
| B 主机核心 | `feat/windows-host-core` | `/Users/bruce/git/rapp/.worktrees/windows-host-core` |

草稿已经合进 `main`，但 `main` 的文件里只有 Mac 不编译的部分：三个新 crate 的目录（没进 workspace 的成员表）、两个 PowerShell 脚本、文档。**接线只在这两个分支上**：对已有 crate 的改动、成员表、testkit 里的假平台和会话测试、Swift 样本生成器。每个分支等于 `main` 加上这一段的接线，所以编译和测试都在分支上做，在 `main` 上编不到这些代码。原因和细节见交接文档 §2.1。

开工第一步是在各自的 worktree 里 `git merge main`。

## 做什么

两段互不依赖。先做 A，它动的是共用 crate，对 macOS 的风险更大。

**A 段**：交接文档 §5 第 3 步的 1–3。

1. 让 `Cargo.lock` 自己更新，不要手改，不要动版本号那几行。
2. 跑完整的 Mac 门禁，修到全绿：`cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`、`swift test`、`flutter analyze`、`flutter test`。
3. 修的时候守住一条：unix 那一支的行为不能变。拿不准就和 `main` 上同一条测试的结果对。
4. 第 4–6 步要 Windows 机器，不归你做。

**B 段**：交接文档 §5 第 4 步，细节在 §3.2 末尾“B 段整体先验的顺序”。

1. 先确认 `rustc --version` 不低于 1.89，草稿用了这个版本才有的接口。
2. `cargo check -p rapp-host-core --all-targets`，再 `-p rapp-testkit --all-targets`，把编译错误改完。
3. 生成 Swift 样本：`RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`。生成器在 `Tests/` 下，只调用 `Sources/RappCore/` 的代码；符号看不到时照计划 B 任务 2 的办法绕，不改 Swift 的访问级别。
4. `cargo test -p rapp-host-core --no-fail-fast`。先看边界测试和压缩。压缩结果和 Swift 是否逐字节相同决定走不走计划 B 写好的退路。
5. `cargo test -p rapp-testkit --test host_session`，再 `--test host_service`。
6. 补上或认下 §3.2“草稿和 Swift 不一样”剩下的四条，每条的处理写进 `PORTING.md`。
7. 最后跑完整的 Mac 门禁。`host-core` 的测试加会话测试要在 60 秒以内。

样本测试第一次就全绿时，故意改坏一处再跑一次，确认它真的在比东西。

## 规矩

- **不改**：`Sources/`、`rust/host-linux/`、`rust/client-gtk/`、`rust/hub-ffi/`。
- **中继 `rust/relay/` 只许两处改动**，草稿里已经做了：`audit.rs` 的三处 `#[cfg(unix)]`，`admin.rs` 的 unix 代码放到 `#[cfg(unix)]` 后面加同名替身。再多要先问用户。
- **三条模块边界**（规格 §5.3）不能破：`host-core` 里没有任何操作系统相关的代码；`host-windows` 不产生也不解析协议字节；只有 `rapp-svc` 跨登录会话启动进程。
- 不升协议号，不为 Windows 加消息。
- 不改版本号、不打 tag、不推送、不建 release，这些归发版 session。
- 草稿和计划不一致时，看 Swift 和规格谁对。计划错了就改计划，和代码改动放在同一个提交里，并在那一段说明文件的“计划错误”一节记一行。
- 草稿提交留在历史里不改写。你的提交用平常的标题（`fix(...)`、`test(...)`），不带“草稿”字样。
- 日志里绝不出现密码、PIN、token、密钥、打的字、剪贴板内容。
- 这台机器上：`grep` 是 ugrep，要用 `/usr/bin/grep`；没有 `timeout` 命令；flutter 在 `~/development/flutter/bin`，跑完测试把 `pubspec.lock` 还原；按路径提交，不用 `git add -A`，不用 `git stash`，不跑 `cargo fmt --all`。
- 偶发失败先单独重跑，分清是负载还是逻辑。会话测试用 20 倍速的时钟，几处时间窗很紧。

## 这些事停下来问用户，不要自己定

- 要升级 Rust 工具链。发版 session 用的是同一套。
- 要改规格 §19.1 第二张单子上的事，或者上面“不改”“边界”里的任何一条。
- **把接线合并进 `main` 之前**。A 段要等 Windows 门禁也绿了才能合；B 段是共用代码，一合并就会触发一次 macOS 发版，由用户决定什么时候合。两段的接线都改 `rust/Cargo.toml` 的成员表和 `rust/testkit/tests/common/mod.rs`，后合的一方解冲突。
- 计划 B 任务 19 步骤 4：要用真的 Mac 控制端连 `fake-host-core` 走一遍，只能用户手工做。你把怎么启动、看什么写清楚，交给用户。

规格 §19.1 第一张单子上的事是留给实现的人定的，你自己定，写进计划。

## 交回什么

两段各一份，写清楚：

1. 现在的状态：每条门禁命令和它的结果。没跑的要说没跑。
2. 草稿里错了什么，各是怎么改的，按文件列。
3. 计划里错了什么，改在哪个提交。
4. 压缩结果和 Swift 是否逐字节相同。走了退路的话写明走的是哪一条。
5. “草稿和 Swift 不一样”剩下的四条，每条是补上了还是认下来了。
6. `Cargo.lock` 里新增的依赖：名字、版本、许可证。
7. 还没做的和原因，以及留给 Windows 机器的事。
