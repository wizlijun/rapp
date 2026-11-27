# CLAUDE.md

## 文档目录

- `docs/archives/` 是**归档**：旧草稿、已过时的设计稿和一次性文稿。**不要读取、不要搜索、不要据此判断现状**；只有用户明确点名某个归档文件时才打开它。
- 当前有效的规格在 `docs/superpowers/specs/`，计划在 `docs/superpowers/plans/`，待办在 `tasks/todo.md`。判断"现在是怎么做的"要看代码和这几处，不要看归档。

## 写给用户看的文字

changelog、发版说明（`RAPP_RELEASE_NOTES`，会进 GitHub Release、`latest.json` 和 app 里的更新提示）、README、网站文案，都按这一条写。

把自己当成资深产品经理：站在用户这边，先讲用户得到什么。

- **先说价值，再说用法。** 第一行讲用户能多做什么、少麻烦什么。不讲实现：不写分支名、文件名、函数、协议字段。
- **短句。** 一句只说一件事。能删的字都删。
- **结构化。** 一句话标题，然后是要点列表。每条要点用用户的动作或结果开头。一屏扫得完。
- **重要的放前面。** 用户通常只读前两三条。同类的合并，一般不超过 5 条。
- **用界面上的词。** 写用户在屏幕上看到的名字，比如「常用语▾」「全局设置」。不用内部代号。
- **需要用户动手的，单独一条。** 比如要先升级中心服务、要重新授权，就放在显眼的位置，写清楚做什么。
- **前后对比，只在会让人困惑时用。** 东西挪了位置、去掉了，用「以前…，现在…」一句讲清楚。
- **兼容性放最后，只写一句。**

发版说明的样子：

```
命令和常用语分开了，找起来更快
- 快捷区第一行有两个菜单：「命令▾」「常用语▾」
- 键盘布局挪到「全局设置」，单独一页
- 按键动作去掉了；以前打的星标和用过的次数自动带过来
- 和 0.15.35 以后的版本互通
```

只给开发者看的文档（`docs/superpowers/` 下的规格和计划、`tasks/todo.md`、提交信息）不受这一条约束，照常写清楚就行。

## 合并与发版（多 session 协作）

有一个专门的**发版 session** 持续监控 `main`，一有新合并就自动发版。其他 session 只管做功能、合并，不碰发版。

### 其他 session（做功能的）

1. 在分支上开发，最好用 `.worktrees/` 下的 worktree；不要把任务直接提交到 main。
2. 完成且自测通过后，**合并到自己这台机器的本机 `main` 即可**（Mac 上是 `/Users/bruce/git/rapp`；Windows 机器上的路径等机器装好后填在这里）：
   - 先 `git merge main` 到自己的分支解决冲突，再在 main 上 `git merge --no-ff <branch>`；
   - 提交信息用 `merge: <中文说明>（<branch>）`。
3. **不要**做这些事，它们归发版 session：
   - 改版本号：`gui/pubspec.yaml` 的 `version`、`rust/Cargo.toml` 的 workspace version、`Cargo.lock`；
   - 打 tag、`git push`、建 GitHub release；
   - 改 `website/releases.json`、部署网站、给 iPhone 装包。
4. 合并后可以删掉自己的 worktree 和分支。如果合并的东西暂时不能发，在 main 上留言写进 `tasks/todo.md`，或者别合并。
5. Windows 相关：改了 `cfg(windows)` 里的代码，要在 Windows 机器上过了 Windows 的门禁（`scripts/check-windows.ps1`）再合并；给协议加被控端行为时，`host-core` 和它的样本在同一个提交里改；改了 `Sources/rapp-host/` 里被 `host-core` 对照表引用的文件，同一个提交里看 `host-core` 要不要跟着改，并更新对照表里的摘要。

### 发版 session

- 每 60 秒检查本机 `main` 和 `origin/main`。出现新的代码合并就发下一个补丁版本，不用先问。跳过以下提交，避免自己触发自己：
  - `release: x.y.z`
  - `docs(website): snapshot …`
  - 发版时合并 origin/main 产生的 `merge:` 提交
- 只改文档（`*.md`、`docs/`、`tasks/`）不发版，攒到下一次代码改动。只影响 Linux 的改动（`cfg(target_os = "linux")` 等）也不发 macOS 版。
- 只影响 Windows 的改动（`rust/host-windows/`、`rust/svc-windows/`、`gui/windows/`、`scripts/` 里 Windows 的脚本、`cfg(windows)` 里的代码）也不发 macOS 版，但要过门禁并立刻推到 `origin/main`，Windows 机器等着用。只改文档的合并同样立刻推。改到共用代码（`rust/host-core/`、`rapp-service` 这些 crate 里不带 `cfg(windows)` 的部分、共用的 Dart）照常算 macOS 的改动。
- **版本号协调**：另一台机器的 Linux 也往 `origin/main` 推送，也会占用补丁号。选版本号之前先 `git fetch origin`、合并 origin/main，取 `max(本地 tag, 远端 tag, pubspec)` + 1。pubspec 的 build 号（`+N`）每次加 1。
- gate 和打包都在专用的 detached worktree `.worktrees/release` 里做，先切到要发的那个提交。不要在主 checkout 里做：别的 session 随时会往里合并，测试跑到一半代码就变了。
- 发版步骤：
  1. 在合并后的 main 上跑完整门禁：swift、`cargo test --workspace --no-fail-fast`、clippy `-D warnings`、`flutter analyze` + `flutter test`。真失败就停下来报告用户。负载导致的偶发失败先单独重跑，并在 release 提交里注明。
  2. 提交 `release: x.y.z`（改 pubspec / Cargo.toml / Cargo.lock），打 tag。
  3. 用 `scripts/package-macos.sh` 打 macOS Apple 芯片包（zip + pkg + latest.json）。
  4. 建 draft release，上传资源（走 en0 绕开代理），核对 digest，再 undraft `--latest`。
  5. 更新 `website/releases.json`，部署网站：`node website/build.mjs && npx --yes wrangler@4.135.0 deploy --config website/wrangler.jsonc`。
  6. 推送：先 fetch，先推 main，再推 tag。
  7. iOS：iPhone Duo 能连上时，用 `scripts/build-ios.sh device --install <udid>` 装上同版本。连不上就记下来，等它能连上再装。

### Windows 集成 session（首发前）

- Windows 机器上常开一个 session：本机 `main` 有新合并，就 `git fetch origin`、合并 `origin/main`、跑 Windows 的门禁、推到 `origin/main`；推被拒就再 fetch、合并、重跑。
- 首发前它只是**集成** session：不改版本号、不打 tag、不建 release、不动 `website/releases.json`。要给自己人装，就按需打内部 zip。
- 冲突由后推的一方解决；不强推。
