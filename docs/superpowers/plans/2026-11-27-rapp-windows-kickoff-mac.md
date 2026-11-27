你在这台 Mac 上，接手 rApp Windows 版里只能在 Mac 上做的两件事，一头一尾。中间的编译和修错在 Windows 机器上做，由另一个 agent 负责，它的提示词是 `docs/superpowers/plans/2026-11-27-rapp-windows-kickoff-windows.md`。

- **开头**：用现有的 Swift 代码生成样本，把两个分支推到 origin，Windows 那边才能开工。
- **收尾**：Windows 那边把草稿修到 Windows 门禁全绿以后，在 Mac 上跑完整的 Mac 门禁，再把接线合进 `main`。

## 背景

rApp 是远程控制软件，macOS 版在用，Mac 发版 session 盯着 `main` 自动发版。Windows 版要对齐 macOS 的功能。被控端的逻辑现在在 Swift 里（`Sources/`）；Windows 版把它移植成一个不认识操作系统的 Rust crate `rust/host-core`，以后再由 `rust/host-windows` 接上系统。所以 **Swift 是基准**：草稿和 Swift 不一致时改 Rust，不改 Swift。

设计、计划和 A、B 两段代码草稿都已写完，但草稿**从来没有编译过，也没有跑过任何测试**。草稿是另一个模型照计划写的，写的时候规定不许编译。它的说明文件里凡是写“写了”的，意思只是文件里有这段代码。

用户定的顺序是以 Windows 为主（2026-11-27）。这两件事留在 Mac 上的原因：

- 样本是让 Swift 对一批固定输入算出结果，给 Rust 当标准答案，只能用 Mac 上的 Swift 代码生成。
- A 段改的是 macOS 和 iOS 也编译的共用 crate。接线进 `main` 之前不过 Mac 门禁，就可能卡住 macOS 和 iOS 发版。

## 先读，按这个顺序

1. `CLAUDE.md`
2. `docs/superpowers/plans/2026-11-26-rapp-windows-handoff.md` 全文。§2.1 写了草稿是怎么进 `main` 的；§3.1、§3.2 写了每批草稿的真实情况和最先会出错的地方；§4 是边界；§5 是顺序；§6 是验证时的规矩。
3. 规格 `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` 的 §0.2、§5.3、§19.1。
4. 开头要读的：计划 `docs/superpowers/plans/2026-11-26-rapp-windows-b-host-core.md` 的“Fixture rules”和任务 2、3；计划 `…-windows-p-probes.md` 的任务 2（探针 C1）。收尾时再读计划 A 和计划 B 的其余部分。
5. 草稿的说明文件：`docs/superpowers/plans/notes/2026-11-26-windows-{a,b1,b2,b3}-draft-notes.md`。

不要读、不要搜 `docs/archives/`。

## 在哪干活

| 段 | 分支 | worktree |
|---|---|---|
| A 基础 | `feat/windows-foundation` | `/Users/bruce/git/rapp/.worktrees/windows-foundation` |
| B 主机核心 | `feat/windows-host-core` | `/Users/bruce/git/rapp/.worktrees/windows-host-core` |

草稿已经合进 `main`，但 `main` 的文件里只有 Mac 不编译的部分：三个新 crate 的目录（没进 workspace 的成员表）、两个 PowerShell 脚本、文档。**接线只在这两个分支上**：对已有 crate 的改动、成员表、testkit 里的假平台和会话测试、Swift 样本生成器。每个分支等于 `main` 加上这一段的接线，所以编译和测试都在分支上做，在 `main` 上编不到这些代码。原因和细节见交接文档 §2.1。

## 开头：生成样本，把分支送出去

这一段只修 Swift 的样本生成器，**不修 Rust 草稿**，Rust 留给 Windows 那边。

1. 在两个 worktree 里各 `git merge main`。
2. 做探针 C1（计划 P 任务 2）：Rust 的压缩结果能不能和 Swift 逐字节相同。计划 B 任务 3 要用它的结论。结果写进 `docs/superpowers/specs/2026-11-26-rapp-windows-probe-results.md`。探针的规矩照计划 P：代码只放在分支 `probe/windows-c1` 上，不合进 `main`。
3. 在 `feat/windows-host-core` 上生成样本：`RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`。
   - 生成器在 `Tests/RappCoreTests/HostCoreFixtures/` 下，是没编译过的草稿，先修到编得过。
   - 生成器只调用 `Sources/RappCore/` 的代码。符号在测试里看不到时照计划 B 任务 2 的办法绕，**不改 Swift 的访问级别**，不改 `Sources/`。
   - 样本写到 `rust/host-core/tests/fixtures/`。
4. 不带那个环境变量再跑一遍 `swift test --filter 'Fixtures/'`（比对方式），确认同样的输入每次生成同样的样本。
5. 跑一次完整的 `swift test`，确认生成器没有碰坏原有的 Swift 测试。
6. 按路径提交样本和你对生成器的改动。
7. 把两个分支推到 origin：`git push origin feat/windows-foundation feat/windows-host-core`。这是这条线的固定步骤，不用另外问。**只推这两个分支**，不推 `main`，不推 tag，不强推。
8. 告诉用户：两个分支已经在 origin 上，各是哪个提交，Windows 那边可以开工了。

Windows 那边发现某个样本本身是错的（生成器的错，不是 Rust 的错）时，会回来找你。重新生成只能在这里做：修生成器，重新生成，提交，推分支。

## 收尾：Mac 门禁，接线进 main

等 Windows 那边把某个分支修到 Windows 门禁全绿并推上来，用户会告诉你。A 先做，B 后做：Windows 那边为了编 testkit，会把 A 的分支合进 B 的分支，所以 B 排在 A 后面进 `main`。

每个分支：

1. `git fetch origin`，把 origin 上的这个分支合到本机的同名分支，再 `git merge main`。
2. 跑完整的 Mac 门禁，修到全绿：`cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`、`swift test`、`flutter analyze`、`flutter test`。
3. 守住一条：unix 那一支的行为不能变。拿不准就和 `main` 上同一条测试的结果对。Windows 那边会交回一张“改到了 unix 也编译的代码”的清单，逐条核对。
4. 你的修改如果落在 Windows 也编译的代码里，把分支推回 origin，请用户让 Windows 那边再跑一次 Windows 门禁。两边在同一个提交上都绿才算数。
5. B 段另外要看：`host-core` 的测试加会话测试在 60 秒以内；`Cargo.lock` 里新增的依赖列出名字、版本、许可证。
6. B 段：计划 B 任务 19 步骤 4，用真的 Mac 控制端连 `fake-host-core` 走一遍。这只能用户手工做，你把怎么启动、看什么写清楚交给用户。
7. 问过用户再合并：先 `git merge main` 到分支，再在 `main` 上 `git merge --no-ff`，提交信息 `merge: <中文说明>（<branch>）`。这次合并改的是共用代码，会触发一次 macOS 发版。

样本测试在 Mac 上第一次就全绿时，故意改坏一处再跑一次，确认它真的在比东西。

## 规矩

- **不改**：`Sources/`、`rust/host-linux/`、`rust/client-gtk/`、`rust/hub-ffi/`。
- **中继 `rust/relay/` 只许两处改动**，草稿里已经做了：`audit.rs` 的三处 `#[cfg(unix)]`，`admin.rs` 的 unix 代码放到 `#[cfg(unix)]` 后面加同名替身。再多要先问用户。
- **三条模块边界**（规格 §5.3）不能破：`host-core` 里没有任何操作系统相关的代码；`host-windows` 不产生也不解析协议字节；只有 `rapp-svc` 跨登录会话启动进程。
- 不升协议号，不为 Windows 加消息。
- 不改版本号、不打 tag、不推 `main`、不建 release，这些归发版 session。你能推的只有上面那两个分支。
- 草稿和计划不一致时，看 Swift 和规格谁对。计划错了就改计划，和代码改动放在同一个提交里，并在那一段说明文件的“计划错误”一节记一行。
- 草稿提交留在历史里不改写。你的提交用平常的标题（`fix(...)`、`test(...)`），不带“草稿”字样。
- 日志里绝不出现密码、PIN、token、密钥、打的字、剪贴板内容。
- 这台机器上：`grep` 是 ugrep，要用 `/usr/bin/grep`；没有 `timeout` 命令；flutter 在 `~/development/flutter/bin`，跑完测试把 `pubspec.lock` 还原；按路径提交，不用 `git add -A`，不用 `git stash`，不跑 `cargo fmt --all`。
- 偶发失败先单独重跑，分清是负载还是逻辑。会话测试用 20 倍速的时钟，几处时间窗很紧。

## 这些事停下来问用户，不要自己定

- 要升级 Rust 工具链。发版 session 用的是同一套，Windows 机器也要跟着一样。
- 探针 C1 没过。计划 B 任务 3 写了退路，走哪一条先告诉用户。
- 要改规格 §19.1 第二张单子上的事，或者上面“不改”“边界”里的任何一条。
- **把接线合并进 `main` 之前**。A 段要 Windows 门禁和 Mac 门禁都绿；B 段要 Mac 门禁绿。两段都是共用代码，一合并就会触发一次 macOS 发版，由用户决定什么时候合。
- 计划 B 任务 19 步骤 4 的真机走查。

规格 §19.1 第一张单子上的事是留给实现的人定的，你自己定，写进计划。

## 交回什么

开头做完交一次：

1. 样本：生成了哪几组，各多少个文件；比对方式那一遍的结果。
2. 生成器里错了什么，各是怎么改的，按文件列。
3. 探针 C1 的结论，以及计划 B 任务 3 因此走哪条路。
4. 推上去的两个分支各是哪个提交。

收尾每个分支交一次：

1. 每条门禁命令和它的结果。没跑的要说没跑。
2. 你在 Mac 上又改了什么，哪些要 Windows 那边重跑。
3. Windows 那边那张清单逐条核对的结果。
4. 计划里错了什么，改在哪个提交。
5. B 段：`Cargo.lock` 里新增的依赖；测试用时；真机走查交给用户的那份说明。
6. 还没做的和原因。
