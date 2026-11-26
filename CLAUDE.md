# CLAUDE.md

## 文档目录

- `docs/archives/` 是**归档**：旧草稿、已过时的设计稿和一次性文稿。**不要读取、不要搜索、不要据此判断现状**；只有用户明确点名某个归档文件时才打开它。
- 当前有效的规格在 `docs/superpowers/specs/`，计划在 `docs/superpowers/plans/`，待办在 `tasks/todo.md`。判断"现在是怎么做的"要看代码和这几处，不要看归档。

## 合并与发版（多 session 协作）

有一个专门的**发版 session** 持续监控 `main`，一有新合并就自动发版。其他 session 只管做功能、合并，不碰发版。

### 其他 session（做功能的）

1. 在分支上开发，最好用 `.worktrees/` 下的 worktree；不要把任务直接提交到 main。
2. 完成且自测通过后，**合并到本机 checkout（`/Users/bruce/git/rapp`）的 `main` 即可**：
   - 先 `git merge main` 到自己的分支解决冲突，再在 main 上 `git merge --no-ff <branch>`；
   - 提交信息用 `merge: <中文说明>（<branch>）`。
3. **不要**做这些事，它们归发版 session：
   - 改版本号：`gui/pubspec.yaml` 的 `version`、`rust/Cargo.toml` 的 workspace version、`Cargo.lock`；
   - 打 tag、`git push`、建 GitHub release；
   - 改 `website/releases.json`、部署网站、给 iPhone 装包。
4. 合并后可以删掉自己的 worktree 和分支。如果合并的东西暂时不能发，在 main 上留言写进 `tasks/todo.md`，或者别合并。

### 发版 session

- 每 60 秒检查本机 `main` 和 `origin/main`。出现新的代码合并就发下一个补丁版本，不用先问。跳过以下提交，避免自己触发自己：
  - `release: x.y.z`
  - `docs(website): snapshot …`
  - 发版时合并 origin/main 产生的 `merge:` 提交
- 只改文档（`*.md`、`docs/`、`tasks/`）不发版，攒到下一次代码改动。只影响 Linux 的改动（`cfg(target_os = "linux")` 等）也不发 macOS 版。
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
