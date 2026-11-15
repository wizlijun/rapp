# rapp 文本终端（Mac，P0–P3）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 被控 Mac 上由 rapp 打开一个 Terminal / iTerm 窗口，窗口里 `rapp-term run` 用伪终端跑程序并维护字符网格；主控台用现有的终端线协议看它、给它打字。主控台断线、关会话、服务重启都不让它退出。

**Architecture:** `rapp-term run` 是伪终端的持有者（portable-pty ＋ alacritty_terminal），它自己在 `$ROOT/local/term/pty/<pid>.sock` 上讲现有的会话协议（`proto.rs`，`Hello.backend = "pty"`）。`rapp-term serve` 多一个 `pty` 后端：列会话时扫这个目录问状态，看会话时把连接逐行转给那个 socket，新请求 `open` 写一个 `.command` 文件用 `open -a` 打开窗口。tmux 后端不动；会话协议的公用件从 `session.rs` 挪到 `wire.rs` 两边共用。主控台：设备面板合成“终端”一项（`terms:`），合并原来的终端组，加打开方式和“新开文本终端”。

**Tech Stack:** Rust 2021（`rust/term`、`rust/net`、`rust/service`、`rust/hub`），新依赖 `portable-pty 0.9.0`、`alacritty_terminal 0.25.1`、`libc 0.2`、`rapp-net`（workspace 内）；Flutter / Dart（`gui`）。

**Spec:** `docs/superpowers/specs/2026-11-16-rapp-text-terminal-design.md`（下称“规格”，§ 都指它）。上位：`docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md`（“终端规格”）。

**范围：** 规格 §11 的 P0–P3，只做 Mac 被控端。Windows 另起设计（§9）。

## 本计划替规格定下的事（都是我定的，可以改）

- **合成项的标识用 `terms:`，不用规格 §2.1 写的 `term:`。** GUI 的 `isTermApp` 是 `startsWith('term:')`，`term:` 会被当成一个终端会话去开；service 的工作进程表也用 `term:` 当 `serve` 的键（`rust/service/src/workers.rs:20`）。`terms:` 两处都碰不到。任务 13 把规格 §2.1 改过来。
- **socket 用 `<pid>.sock`，不用规格 §4.1 的 `<名字>.sock`**：macOS 的 unix socket 路径最多 104 字节，名字可能很长；改名、重名也不用动文件。名字放在状态里。路径超长就报错退出，写明路径。
- **后端接口切在 `serve` 这一层**：`list`、`view`、`open` 按后端分派；会话协议的公用件（读行、写消息、面板消息、历史消息、粘贴拼接）挪进 `wire.rs`。`session::run` 不改成泛型：它绑着 control mode、多面板、重排、面板归属，泛型化只会让 tmux 那边变复杂。`pty` 的会话循环在 `run` 里，`serve` 只是逐行转发。线协议一个字段不加（规格 §4.3 的约束）。
- **本机协议（`run` ⇄ `serve`）第 1 版**：连上后先写一行请求 `{"op":"status","v":1}` 或 `{"op":"view","v":1}`，再写一行 token。
  - token 不对：回 `{"error":"bad token"}`，断开。
  - 不认识的 `op`：回 `{"error":"unsupported","v":1}`，断开。两边都忽略不认识的字段。
  - `status`：回一行 `{"v":1,"name":…,"command":…,"cols":…,"rows":…,"activity":…,"viewers":…,"pid":…,"ticket":…}`，断开。`activity` 是最后一次输出的 Unix 秒；`ticket` 没有就不写。
  - `view`：之后就是现有的会话协议，`run` 先发 `Hello{v: PROTO, backend: "pty"}`。
  - 规格 §5 说的“旧版本开的窗口”那行字等真有第 2 版再做；第 1 版只要求忽略不认识的字段。
- **`open` 怎么认出自己开的那个 `run`**：`serve` 生成一个随机的 `ticket`，写进 `.command` 的 `--ticket`，然后每 100 毫秒扫一次状态，等 `ticket` 对上的那个，最多 10 秒。名字由 `run` 自己挑：拿着 `pty/.lock` 的文件锁（`std::fs::File::lock`）扫一遍现有的名字，取 `名字`、`名字-2`、`名字-3`…里第一个没人用的，绑好 socket 再放锁。这样手敲的 `run` 和 `open` 开的不会撞名。
- **命令怎么传**：主控台把整行命令作为一个字符串发（和新开 tmux 会话一样）。`.command` 文件里原样放在 `--` 后面，由 shell 去拆，引号照常用。空着就不写 `--`，`run` 起登录 shell。
- **`.command` 文件**：`#!/bin/sh` 加一行 `exec '<rapp-term>' run --dir '<pty 目录的上一层>' --ticket '<t>' [--name '<名字>'] [--cwd '<目录>'] [-- <命令>]`，路径和名字用单引号转义（`'` 写成 `'\''`）。文件权限 0700。`serve` 等完（成功或超时）就删掉它。`run` 不知道这个文件。
- **目录**：空着就是被控端的家目录。开头的 `~/` 由 `serve` 展开。目录不存在时 `serve` 直接回错 `no such directory: <目录>`，不开窗口。
- **能用哪些终端 app**：`serve` 起来时查一次：macOS 上 Terminal 总有；`open -Ra iTerm` 成功就有 iTerm。本机那一条 `HostRow` 多一个字段 `launchers: ["Terminal", "iTerm"]`，空的不写。主控台只在这个字段非空时显示“新开文本终端…”，所以旧版本被控端、Linux 被控端都不显示。下拉框只在不止一个时出现。
- **程序退出以后**：`run` 给所有观众发 `Error{error:"session ended"}`，删掉 socket，按程序的退出码退出。列表里那一行没了（`dead` 对 `pty` 总是 false）。正在看的主控台照现有的错误处理留着最后一屏。这和规格 §4.3“`dead` 是程序已退出”有出入，任务 13 改规格。
- **窗口被关掉**（`run` 收到 SIGHUP）或收到 SIGTERM：结束子进程，删掉 socket，还原 tty，退出。
- **未读**：`pty` 会话用 `Unread` 的键 `pty:<pid>`；`serve` 转发时看到 `"t":"screen"` 的一行就算看过。
- **输入次数**：`serve` 转发时数主控台发来的 `keys`、`type` 和 `more: false` 的 `text`，和 tmux 那边一样记进 `ended` 事件。
- **光标形状**：程序没改过（还是默认的方块、不闪）写空字符串，改过才写 `block` / `underline` / `bar`。
- **`Refit`**：`run` 不改尺寸，回一条 `Error{error:"the size follows the window on the host"}`，再发一整屏。**`NewWindow`**：回 `Error{error:"a text terminal has one window"}`。主控台本来就把这两项灰掉，这两条只给旧主控台。
- **面板**：`run` 只有一个面板，`Pane{id:"%0", window:"0", title:<名字>, command:<default_name(命令)>, cols, rows, dead:false, win:"@0", active:true}`。
- **“终端”一项不显示时**（`term.json` 的 `allow` 是假、终端列表还没拿到、出错）：终端 app 留在普通列表里，不会消失。
- **打开方式是“文本”但没法开文本终端时**（被控端没有 `launchers`，也没有 `pty` 会话）：按“画面”处理。
- **“终端”一项下面的组总是展开**，不做规格草图里的 ▾。
- **终端 app 的 bundle id**（规格 §2.1 要计划核对）：Terminal `com.apple.Terminal`、iTerm `com.googlecode.iterm2`、Ghostty `com.mitchellh.ghostty`、WezTerm `com.github.wez.wezterm`、kitty `net.kovidgoyal.kitty`、Alacritty `org.alacritty`、Warp `dev.warp.Warp-Stable`。任务 0 在本机 `mdls -name kMDItemCFBundleIdentifier` 核对装了的那几个，对不上就改这里和任务 11 的表。

## Global Constraints

- 线协议 `rust/term/src/proto.rs` 一个字段都不为 `pty` 加；`PROTO` 不变。`TermStage`、`TermSessionPort` 不改，只按 `backend` 灰掉两项（规格 §4.5）。
- relay 的代码里不出现“终端”。hub 不认识 `pty`：`terms` 列表和 `hosts` 原样转（`rust/hub/src/terms.rs:92`）。
- `run` 不回应程序发来的终端查询（光标位置、设备属性），由所在窗口回答（规格 §4.1 第 5 条）。仿真器的 `PtyWrite` 事件一律丢掉。
- `run` 绝不因为观众断开、`serve` 不在、socket 出错而结束（规格 §1“不能出现的结果”第 1 条）。本机键盘和窗口显示和直接跑这个程序一样。
- 远程不改伪终端尺寸（规格 §6）。
- 新目录 `$ROOT/local/term/`、`pty/`、`launch/` 权限 0700；`pty.token` 0600，第一次用到时生成（32 个十六进制字符），之后不换。
- 仿真器历史 10000 行（规格 §7）。单次 `History` 最多 `MAX_HISTORY`（2000）行，和 tmux 一样。一次粘贴最多 1 MiB（`MAX_PASTE` = 1048576 字节），超了回 `Pasted{ok:false, error:"text is too long (1 MiB at most)"}`。一行线消息最多 65536 字节。
- 日志不记屏幕内容、输入内容、命令（规格 §10）。`log_fields` 里 `open_term` 只记 `{"op":"open_term","app":…}`。
- 依赖：`portable-pty = "0.9.0"`、`alacritty_terminal = "0.25.1"`，加到 `rust/term/Cargo.toml`；任务 3 先核对许可证（MIT / Apache-2.0 才用）。除此之外只加 `libc = "0.2"` 和 workspace 内的 `rapp-net`，不加别的。
- 面向用户的文字全是中文，原文照本计划：「终端」「文本」「tmux」「画面」「只能用画面看」「新开文本终端…」「新开 tmux 会话…」「添加 SSH 主机…」「打开方式」「新开文本终端」「目录（空着就是家目录）」「命令（如 claude；空着就是 shell）」「名字（可不填）」「用哪个终端 app」「新开」「取消」「这台设备上现在没有终端会话。」「尺寸跟着被控端的窗口」「文本终端只有一个窗口」。
- 在 git worktree `.claude/worktrees/text-term`、分支 `feat/text-term` 上做；不推送。提交前按文件名 `git add`；不用 `git add -u/-A/.`、`git stash`、`git reset`。`flutter test` 改了 `gui/pubspec.lock` 就 `git checkout -- gui/pubspec.lock`（只许这一处 checkout）。不碰 `docs/archives/`；`docs/superpowers/plans/2026-11-16-port-sharing-1-5-panel.md` 是别的工作，不碰。
- Rust：新文件用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`，不跑 `cargo fmt`；改动的旧文件手工对齐。Rust 任务结束时 `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test --workspace` 全过，`cargo clippy --workspace --all-targets -- -D warnings` 无新警告。tmux 测试只用独立 socket。测试里用到伪终端、unix socket、`open` 的，沙箱里跑不了就关掉沙箱跑。
- GUI：`export PATH=$HOME/development/flutter/bin:$PATH`；GUI 任务结束时 `cd gui && flutter analyze` 无问题，`flutter test` 全过。
- 提交信息：`feat(term): …`、`feat(gui): …`、`refactor(term): …`、`docs: …`；结尾带 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

1. **被控 Mac 上没装 tmux**（很常见）：本机那条 `HostRow` 带着 tmux 的错误，但 `pty` 会话照样列出、能看能开，“终端”一项照样在。（任务 8 `pty_rows_are_listed_without_tmux`，任务 11 `the_terms_entry_shows_with_a_tmux_error`）
2. **`run` 被 `kill -9` 或机器崩溃后留下的 socket**：列表里不出现，文件被删，别的会话不受影响；还在忙的 socket（状态半秒没回）不删。（任务 5 `a_dead_socket_is_removed_and_skipped`）
3. **中日文、emoji、组合字符、行尾带底色的空格**：转成的行和 `capture-pane -e` 去掉转义后的文字一样，列不错位。（任务 3 `wide_and_combining_chars_keep_their_columns`，`text_matches_tmux_capture`）
4. **主控台正看着，被控端的人拖了窗口大小**：下一屏带新的 `cols`/`rows`，面板消息更新，主控台不发任何东西去改它。（任务 7 `a_window_resize_reaches_the_viewer`）
5. **一个观众走了、另一个还在看；`serve` 在看的中途重启**：`run` 不退，另一个观众照常收屏，重新连上的先收一整屏。（任务 7 `a_viewer_leaving_never_ends_run`）

## File Structure

| 文件 | 管什么 |
|---|---|
| `rust/term/src/wire.rs`（新） | 会话协议的公用件：`Lines`/`Got`、`put`、`panes_msg`、`history_msg`、`PasteBuf`，从 `session.rs` 挪来 |
| `rust/term/src/pty/mod.rs`（新） | `pty` 后端的公用类型：`Status`、`Shared` |
| `rust/term/src/pty/grid.rs`（新） | `Emu`：alacritty_terminal 的网格 → `Screen`、`HistoryRows`、模式 |
| `rust/term/src/pty/local.rs`（新） | 本机协议：目录、token、socket 路径、请求头、`status`、扫描、名字锁 |
| `rust/term/src/pty/view.rs`（新） | `run` 里给一个观众跑的会话循环 |
| `rust/term/src/pty/holder.rs`（新） | `rapp-term run`：伪终端、raw 模式、SIGWINCH、输出分两份、socket 服务、退出 |
| `rust/term/src/pty/launch.rs`（新） | `.command` 文件、`open -a`、`launchers` 探测 |
| `rust/term/src/keys.rs` | 加 `to_bytes`：线上键名 → 写进伪终端的字节 |
| `rust/term/src/serve.rs` | `pty` 的列出、转发、`open`；`HostRow.launchers` |
| `rust/term/src/session.rs` | 改用 `wire.rs` |
| `rust/term/src/main.rs` | `run` → `new`；新 `run` |
| `rust/net/src/msg.rs`、`rust/service/src/{peer,term}.rs`、`rust/hub/src/{lib,terms}.rs` | `Op::OpenTerm` 一路转到 `serve` 的 `open` |
| `gui/lib/hub_client.dart` | `openTerm`、`TermHost.launchers` |
| `gui/lib/ui/prefs.dart` | `term_open` |
| `gui/lib/ui/terms_entry.dart`（新） | 合成“终端”一项的纯逻辑：哪些是终端 app、排序、点了开什么 |
| `gui/lib/ui/devices_tab.dart` | 列表排序、“终端”一项和它下面的组、对话框 |
| `gui/lib/ui/main_state.dart`、`gui/lib/ui/main_window.dart` | `openOrSwitch` 拦下 `terms:`；要弹对话框时经 `newTextAsks` 交给窗口 |
| `gui/lib/embed/stream_menu.dart`、`gui/lib/ui/top_bar.dart`（及「＋」菜单的「新开窗口」所在处） | `pty` 会话灰掉两项 |

---

### Task 0: P0 探查（代码不留）

**Files:**
- Create（不提交）：`$SCRATCH/pty-probe/`（一个独立的 cargo 小程序，`$SCRATCH` 是会话的 scratchpad）
- Create（提交）：`docs/superpowers/specs/2026-11-16-rapp-text-terminal-probe.md`

**Interfaces:**
- Produces：探查结论。①、②、④ 是否成立决定任务 7、9 能不能照写；③ 给任务 3 的测试补真实样本（把 Claude Code 一屏的原始输出字节存成 `rust/term/tests/fixtures/claude-screen.bin`，任务 3 用）。

- [ ] **Step 1: 写探查程序**

`pty-probe -- <命令>`：portable-pty 0.9.0 开伪终端跑命令，输出原样写回标准输出、同时喂给 alacritty_terminal 0.25.1；raw 模式读标准输入；收到 SIGUSR1 时把当前网格按任务 3 的规则转成行写到 `/tmp/pty-probe.txt`，原始输出字节一直追加到 `/tmp/pty-probe.bin`。代码随便写，不进仓库。

- [ ] **Step 2: 本机能验的先验**

```bash
printf '#!/bin/sh\nexec sleep 600\n' > $SCRATCH/x.command && chmod 700 $SCRATCH/x.command
open -a Terminal $SCRATCH/x.command
ps -o pid,ppid,pgid,sess,command -ax | grep 'sleep 600'
```
记下 `sleep` 的父进程链（应是 Terminal → login → shell → sleep），以及它和 `rapp-service` 不在同一个进程组、会话里。再用 `open -a iTerm`（装了的话）试一遍。核对装了的终端 app 的 bundle id（上面“本计划替规格定下的事”最后一条）。

- [ ] **Step 3: 请用户在真机上验**（停下来等结果）

告诉用户：
1. 用 `open -a Terminal` 开一个跑 `pty-probe -- sleep 600` 的窗口，然后在「本机」里停掉 rapp 服务（或 `launchctl kickstart -k gui/$UID/<服务的 label>`），看窗口和 `sleep` 还在不在。
2. iTerm 能不能这样打开 `.command`，打开后是不是新窗口。
3. 在 `pty-probe -- claude` 里正常用一会儿 Claude Code（打几句中文、让它出彩色输出），`kill -USR1 <pid>`，把 `/tmp/pty-probe.txt` 交给用户对一下：中日文、颜色、光标位置和窗口里看到的一样。
4. 跑着 `pty-probe -- sleep 600` 时用新的安装包升级 rapp（替换 `.app`），看它还在不在。

- [ ] **Step 4: 写结论，提交**

每件一段：做了什么、看到了什么、对本计划的影响。②不成立就把任务 9 的 iTerm 换成 `osascript`（需要“自动化”权限，回来问用户）；①或④不成立就停下来回到规格。

```bash
git add docs/superpowers/specs/2026-11-16-rapp-text-terminal-probe.md rust/term/tests/fixtures/claude-screen.bin
git commit -m "docs: text terminal probe results"
```

---

### Task 1: 会话协议的公用件挪进 `wire.rs`

**Files:**
- Create: `rust/term/src/wire.rs`
- Modify: `rust/term/src/session.rs`（`Lines`/`Got`/`MAX_IN_LINE` 在 :200-270 一带，`put` :126，`panes_msg` :111，`cut` :102，`history_msg` :156，粘贴拼接 :416-470）、`rust/term/src/lib.rs`

**Interfaces:**
- Produces（`rapp_term::wire`）：
  - `pub struct Lines<R>`；`Lines::new(r: R, limit: usize) -> Lines<R>`；`async fn next(&mut self) -> std::io::Result<Got>`；`pub enum Got { Line(Vec<u8>), TooLong, Eof }`；`pub const MAX_IN_LINE: usize`（原值）
  - `pub async fn put<W: AsyncWrite + Unpin>(w: &mut W, m: &Out) -> std::io::Result<()>`
  - `pub fn panes_msg(panes: &[Pane]) -> Out`
  - `pub fn history_msg(pane: &str, before: u32, rows: HistoryRows) -> Out`
  - `pub const TOO_LONG: &str = "text is too long (1 MiB at most)"`
  - `pub struct PasteBuf`；`PasteBuf::default()`；`fn push(&mut self, pane: &str, data: String, more: bool) -> PasteStep`；`fn clear(&mut self)`；`pub enum PasteStep { Pending, Ready(String), TooLong, Dropped }`。`Ready` 是拼好的整段；`TooLong` 只在这一段的最后一片（`more: false`）报一次，之前的片都是 `Dropped`；换了面板就丢掉之前没拼完的。

- [ ] **Step 1: 写 `PasteBuf` 的失败测试**（在 `wire.rs` 里）

```rust
#[test]
fn chunks_are_joined_and_ready_on_the_last() {
    let mut p = PasteBuf::default();
    assert_eq!(p.push("%1", "ab".into(), true), PasteStep::Pending);
    assert_eq!(p.push("%1", "cd".into(), false), PasteStep::Ready("abcd".into()));
}

#[test]
fn over_one_mib_fails_once_on_the_last_chunk() {
    let mut p = PasteBuf::default();
    let half = "x".repeat(MAX_PASTE / 2 + 1);
    assert_eq!(p.push("%1", half.clone(), true), PasteStep::Pending);
    assert_eq!(p.push("%1", half.clone(), true), PasteStep::Dropped);
    assert_eq!(p.push("%1", "y".into(), false), PasteStep::TooLong);
    // The next paste starts afresh.
    assert_eq!(p.push("%1", "z".into(), false), PasteStep::Ready("z".into()));
}

#[test]
fn a_new_pane_drops_the_unfinished_paste() {
    let mut p = PasteBuf::default();
    p.push("%1", "ab".into(), true);
    assert_eq!(p.push("%2", "cd".into(), false), PasteStep::Ready("cd".into()));
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd rust && cargo test -p rapp-term --lib wire::`
Expected: 编译失败，`PasteBuf` 不存在。

- [ ] **Step 3: 挪代码**

把列出的函数原样搬进 `wire.rs`（连同 `session.rs` 里它们的单元测试：`no_message_is_written_over_the_line_limit`、`a_line_over_the_limit_is_dropped_and_reading_goes_on`、`a_cancelled_read_keeps_what_it_had_read`、`history_is_cut_to_the_line_limit_keeping_the_rows_nearest_the_screen`、`a_single_row_over_the_line_limit_is_stripped_then_cut`、`pane_names_are_cut_at_a_char_boundary`、`the_pane_list_fits_one_line_dropping_panes_at_the_end`）。实现 `PasteBuf`，让 `session.rs` 的 `paste_chunk`/`paste_failed`/`fail_pastes` 改用它；面板归属、发给 tmux、回 `Pasted` 的逻辑留在 `session.rs`。行为一点不变。

- [ ] **Step 4: 跑全部测试**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term && cargo clippy -p rapp-term --all-targets -- -D warnings`
Expected: 全过（含 `tests/live.rs`、`tests/serve.rs` 里的粘贴测试），无警告。

- [ ] **Step 5: Commit**

```bash
git add rust/term/src/wire.rs rust/term/src/session.rs rust/term/src/lib.rs
git commit -m "refactor(term): move the session protocol's shared parts into wire.rs"
```

---

### Task 2: `rapp-term run` 改名 `new`

**Files:**
- Modify: `rust/term/src/main.rs`（`USAGE`、命令分派、`async fn run` :267 → `async fn new`）
- Test: `rust/term/tests/cli.rs`

**Interfaces:**
- Produces：`rapp-term new [选项同原 run]`；`run` 这个词空出来给任务 7。这一步里 `rapp-term run` 报“未知命令”，和其他未知命令一样。

- [ ] **Step 1: 改 `tests/cli.rs`**

把调用 `run` 的测试改成调 `new`，再加：

```rust
#[test]
fn usage_lists_new_for_tmux_sessions() {
    let out = Command::new(BIN).output().unwrap();
    let usage = String::from_utf8_lossy(&out.stderr);
    assert!(usage.contains("rapp-term new"), "{usage}");
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd rust && cargo test -p rapp-term --test cli`
Expected: FAIL（`new` 未知）。

- [ ] **Step 3: 改名**

函数、`USAGE` 那一行、分派一起改；选项、默认 80×24 都不变。

- [ ] **Step 4: 跑**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add rust/term/src/main.rs rust/term/tests/cli.rs
git commit -m "refactor(term): rename the tmux session command to rapp-term new"
```

---

### Task 3: 仿真器网格 → `Screen`（`pty/grid.rs`）

**Files:**
- Modify: `rust/term/Cargo.toml`（加 `alacritty_terminal = "0.25.1"`、`portable-pty = "0.9.0"`、`libc = "0.2"`、`rapp-net = { path = "../net" }`）、`rust/term/src/lib.rs`（`pub mod pty;`）
- Create: `rust/term/src/pty/mod.rs`、`rust/term/src/pty/grid.rs`
- Test: `rust/term/src/pty/grid.rs`（单元）、`rust/term/tests/grid_live.rs`（和 tmux 对比）

**Interfaces:**
- Produces（`rapp_term::pty::grid`）：
  - `pub struct Emu`；`Emu::new(cols: u16, rows: u16) -> Emu`（历史 10000 行）
  - `fn feed(&mut self, bytes: &[u8])`；`fn resize(&mut self, cols: u16, rows: u16)`
  - `fn screen(&self) -> Screen`：`hist` = 网格的历史行数，`limit` = 10000，`cursor` = 显示光标模式，`alt` = 备用屏幕，`cx`/`cy` 是光标位置，`wrapped` = 最后一格带 WRAPLINE 的行号，`shape` 见“本计划替规格定下的事”
  - `fn history(&self, before: u32, lines: u32) -> HistoryRows`：语义同 `Tmux::history`（`rust/term/src/tmux/mod.rs:252`）：`lines` 行（最多 `MAX_HISTORY`，最多 `size - before`），结束在屏幕上方 `before` 行处，从上往下排；`size` = 历史行数
  - `fn modes(&self) -> Modes`；`pub struct Modes { pub app_cursor: bool, pub bracketed_paste: bool }`
  - 仿真器的事件监听器丢掉所有事件（含 `PtyWrite`）

**一行怎么写**（和 `capture-pane -e` 能被同一个 `sgr.dart` 读懂）：
- 每行从默认样式开始。样式变了就写一个 `ESC[0;…m`（先清再设全）；变回默认就写 `ESC[0m`。行尾样式不是默认就补 `ESC[0m`。
- 前景：命名色 0–7 → `30–37`，亮色 8–15 → `90–97`，索引色 16–255 → `38;5;n`，真彩色 → `38;2;r;g;b`；背景同理 `40–47`、`100–107`、`48;5;n`、`48;2;r;g;b`。暗色（Dim 系列）按基色写，再加 `2`。默认色不写。
- 属性：粗体 `1`、暗 `2`、斜体 `3`、各种下划线都写 `4`、反显 `7`、隐藏 `8`、删除线 `9`。
- 宽字符写一次，跳过它后面的占位格和行尾的“宽字符前导占位格”；组合字符跟在它的基字后面。
- 超链接：进入时写 `ESC]8;;<url>ESC\`，离开时写 `ESC]8;;ESC\`。
- 行尾连着的、样式是默认的空格去掉；带底色的空格留着。

- [ ] **Step 1: 核对许可证**

Run: `cd rust && cargo metadata --format-version 1 | python3 -c "import json,sys; [print(p['name'],p['version'],p['license']) for p in json.load(sys.stdin)['packages'] if p['name'] in ('alacritty_terminal','portable-pty','vte')]"`
Expected：都是 MIT 或 Apache-2.0（或二选一）。不是就停下来告诉用户。

- [ ] **Step 2: 写失败的单元测试**

```rust
fn lines(bytes: &[u8]) -> Vec<String> { let mut e = Emu::new(20, 3); e.feed(bytes); e.screen().lines }

#[test]
fn plain_text_drops_trailing_blanks() { assert_eq!(lines(b"hi   ")[0], "hi"); }

#[test]
fn colors_and_attributes_are_written_as_sgr() {
    assert_eq!(lines(b"\x1b[1;31mA\x1b[0mB")[0], "\x1b[0;1;31mA\x1b[0mB");
    assert_eq!(lines(b"\x1b[38;5;200mC")[0], "\x1b[0;38;5;200mC\x1b[0m");
    assert_eq!(lines(b"\x1b[48;2;1;2;3mD")[0], "\x1b[0;48;2;1;2;3mD\x1b[0m");
    assert_eq!(lines(b"\x1b[94mE")[0], "\x1b[0;94mE\x1b[0m");
}

#[test]
fn wide_and_combining_chars_keep_their_columns() {
    let mut e = Emu::new(20, 3);
    e.feed("中文😀e\u{301}x".as_bytes());
    let s = e.screen();
    assert_eq!(s.lines[0], "中文😀e\u{301}x");
    assert_eq!((s.cx, s.cy), (8, 0));
}

#[test]
fn a_space_with_a_background_is_kept() { assert_eq!(lines(b"a\x1b[41m  \x1b[0m")[0], "a\x1b[0;41m  \x1b[0m"); }

#[test]
fn hyperlinks_are_osc_8() {
    assert_eq!(lines(b"\x1b]8;;http://x\x1b\\L\x1b]8;;\x1b\\")[0], "\x1b]8;;http://x\x1b\\L\x1b]8;;\x1b\\");
}

#[test]
fn a_wrapped_row_is_listed() {
    let mut e = Emu::new(4, 3);
    e.feed(b"abcdef");
    assert_eq!(e.screen().wrapped, vec![0]);
}

#[test]
fn history_ends_before_rows_above_the_screen() {
    let mut e = Emu::new(10, 2);
    for i in 0..10 { e.feed(format!("{i}\r\n").as_bytes()); }
    let h = e.history(0, 3);
    assert_eq!((h.lines, h.size), (vec!["6".to_string(), "7".into(), "8".into()], 9));
    assert_eq!(e.history(2, 100).lines.len(), 7);
    assert!(e.history(50, 3).lines.is_empty());
}

#[test]
fn modes_follow_the_program() {
    let mut e = Emu::new(10, 2);
    e.feed(b"\x1b[?1h\x1b[?2004h");
    assert_eq!(e.modes(), Modes { app_cursor: true, bracketed_paste: true });
}

#[test]
fn alt_screen_cursor_and_shape() {
    let mut e = Emu::new(10, 2);
    e.feed(b"\x1b[?1049h\x1b[?25l\x1b[6 q");
    let s = e.screen();
    assert!(s.alt && !s.cursor);
    assert_eq!(s.shape, "bar");
    assert_eq!(Emu::new(10, 2).screen().shape, "");
}
```

（`e\u{301}` 按 alacritty 把组合符并进前一格的做法，`cx` 若与 tmux 不同，以 Step 6 的对比为准改断言。）

- [ ] **Step 3: 跑，确认失败**

Run: `cd rust && cargo test -p rapp-term --lib pty::grid`
Expected: 编译失败（`Emu` 不存在）。

- [ ] **Step 4: 实现 `Emu`**

尺寸用一个实现 `alacritty_terminal::grid::Dimensions` 的小结构；解析用 `alacritty_terminal::vte::ansi::Processor`。只读最底下（`display_offset` 永远是 0）。

- [ ] **Step 5: 跑单元测试**

Run: `cd rust && cargo test -p rapp-term --lib pty::grid`
Expected: PASS。

- [ ] **Step 6: 和 tmux 对比的活测试**（`tests/grid_live.rs`，用 `common::Server`）

`text_matches_tmux_capture`：同一串字节（中日文、emoji、组合字符、颜色、行尾带底色空格、折行，再加任务 0 存下的 `fixtures/claude-screen.bin`）分别喂给 `Emu::new(80, 24)` 和一个 80×24 的 tmux 面板（`cat` 一个临时文件进去），断言两边每行 `screen::strip_escapes` 后相等，光标位置相等。

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term --test grid_live`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add rust/term/Cargo.toml rust/Cargo.lock rust/term/src/lib.rs rust/term/src/pty/mod.rs rust/term/src/pty/grid.rs rust/term/tests/grid_live.rs
git commit -m "feat(term): emulator grid to capture-pane style lines for the pty backend"
```

---

### Task 4: 键名 → 字节（`keys::to_bytes`）

**Files:**
- Modify: `rust/term/src/keys.rs`

**Interfaces:**
- Consumes：`pty::grid::Modes`（任务 3）
- Produces：`pub fn to_bytes(wire: &str, modes: Modes) -> Option<Vec<u8>>`：和 `tmux_name` 认同一套语法（`[Ctrl-][Alt-][Shift-]<base>`，`named()` 那张表），认不得回 `None`。规则：字母数字符号原样；`Ctrl-<字母>` 是 `字母 & 0x1f`，`Ctrl-[`/`Ctrl-\`/`Ctrl-]`/`Ctrl-^`/`Ctrl-_`/`Ctrl-Space`(0) 照 xterm；`Alt-` 前面加 `ESC`；`Enter` `\r`、`Tab` `\t`、`Shift-Tab` `ESC[Z`、`Backspace` `0x7f`、`Esc` `ESC`、`Space` 空格；方向键普通 `ESC[A…D`，`app_cursor` 时 `ESCOA…D`，带修饰的写 `ESC[1;<m>A`（m = 1 + Shift 1 + Alt 2 + Ctrl 4）；`Home`/`End` 同方向键的两种写法（`H`/`F`）；`PageUp` `ESC[5~`、`PageDown` `ESC[6~`、`Delete` `ESC[3~`；F1–F4 `ESCOP…S`，F5–F12 `ESC[15~ 17~ 18~ 19~ 20~ 21~ 23~ 24~`。

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn wire_keys_become_xterm_bytes() {
    let m = Modes::default();
    assert_eq!(to_bytes("Ctrl-C", m).unwrap(), b"\x03");
    assert_eq!(to_bytes("Alt-b", m).unwrap(), b"\x1bb");
    assert_eq!(to_bytes("Enter", m).unwrap(), b"\r");
    assert_eq!(to_bytes("Shift-Tab", m).unwrap(), b"\x1b[Z");
    assert_eq!(to_bytes("Up", m).unwrap(), b"\x1b[A");
    assert_eq!(to_bytes("Shift-Up", m).unwrap(), b"\x1b[1;2A");
    assert_eq!(to_bytes("PageUp", m).unwrap(), b"\x1b[5~");
    assert_eq!(to_bytes("F5", m).unwrap(), b"\x1b[15~");
    assert!(to_bytes("Hyper-x", m).is_none());
}

#[test]
fn app_cursor_mode_changes_plain_arrows_only() {
    let m = Modes { app_cursor: true, ..Modes::default() };
    assert_eq!(to_bytes("Up", m).unwrap(), b"\x1bOA");
    assert_eq!(to_bytes("Ctrl-Up", m).unwrap(), b"\x1b[1;5A");
}

#[test]
fn every_named_key_has_bytes() {
    // Every wire name named() accepts, alone and with Ctrl-/Alt-/Shift-.
    let names = ["Esc", "Enter", "Tab", "Space", "Backspace", "Delete", "Up", "Down", "Left", "Right", "Home", "End",
        "PageUp", "PageDown", "F1", "F5", "F12"];
    for wire in names {
        for pre in ["", "Ctrl-", "Alt-", "Shift-"] {
            assert!(to_bytes(&format!("{pre}{wire}"), Modes::default()).is_some(), "{pre}{wire}");
        }
    }
}
```

- [ ] **Step 2: 跑，确认失败** — Run: `cd rust && cargo test -p rapp-term --lib keys::` Expected: 编译失败。
- [ ] **Step 3: 实现**（`Modes` 加 `#[derive(Default, Clone, Copy, PartialEq, Debug)]`）
- [ ] **Step 4: 跑** — Expected: PASS。
- [ ] **Step 5: Commit**

```bash
git add rust/term/src/keys.rs rust/term/src/pty/grid.rs
git commit -m "feat(term): wire key names to xterm bytes for the pty backend"
```

---

### Task 5: 本机协议（`pty/local.rs`）

**Files:**
- Create: `rust/term/src/pty/local.rs`
- Modify: `rust/term/src/pty/mod.rs`

**Interfaces:**
- Produces（`rapp_term::pty::local`；`term_dir` 指 `$ROOT/local/term`）：
  - `pub const LOCAL_V: u32 = 1;`
  - `pub fn default_dir() -> PathBuf`：`rapp_net::config::local(&rapp_net::config::home()).join("term")`
  - `pub fn ensure_dirs(term_dir: &Path) -> anyhow::Result<()>`：建 `term/`、`pty/`、`launch/`，都设 0700
  - `pub fn token(term_dir: &Path) -> anyhow::Result<String>`：读 `pty.token`；没有就用 `create_new` 写 32 个十六进制字符（来自 `/dev/urandom`），0600；撞上 `AlreadyExists` 就读别人刚写的（空的话等 50 毫秒重读，最多 20 次）
  - `pub fn socket_path(term_dir: &Path, pid: u32) -> anyhow::Result<PathBuf>`：`pty/<pid>.sock`，字节数 ≥ 104 报错 `the socket path is too long: <路径>`
  - `pub struct Status { v, name, command, cols, rows, activity: u64, viewers: u32, pid: u32, ticket: Option<String> }`（serde，未知字段忽略，`ticket` 为空不写）
  - `pub async fn connect(path: &Path, op: &str, token: &str) -> std::io::Result<UnixStream>`：连上并写好两行请求头
  - `pub async fn status(path: &Path, token: &str) -> Result<Status, Probe>`；`pub enum Probe { Gone, Busy, Refused(String) }`：连不上（拒绝、文件不存在）是 `Gone`；500 毫秒没回是 `Busy`；回了 `error` 是 `Refused`
  - `pub async fn scan(term_dir: &Path, token: &str) -> Vec<Status>`：问 `pty/` 下每个 `*.sock`，`Gone` 的删掉，`Busy`、`Refused` 的跳过；按 `name` 排
  - `pub struct Head { pub op: String, pub v: u32 }`；`pub async fn read_head<R: AsyncBufRead + Unpin>(r: &mut R, token: &str) -> Result<Head, &'static str>`：两行都在 `HEAD_WAIT`（5 秒）内到；token 不对是 `"bad token"`
  - `pub fn pick_name(base: &str, taken: &[String]) -> String`：`base`、`base-2`、`base-3`…第一个不在 `taken` 里的
  - `pub fn name_lock(term_dir: &Path) -> anyhow::Result<std::fs::File>`：打开 `pty/.lock` 并 `lock()`；文件丢掉就放锁

- [ ] **Step 1: 写失败测试**（`local.rs` 里，tokio 测试，`tempfile`）

```rust
#[test]
fn names_count_up_from_two() {
    assert_eq!(pick_name("claude", &[]), "claude");
    assert_eq!(pick_name("claude", &["claude".into(), "claude-2".into()]), "claude-3");
}

#[test]
fn the_token_is_made_once_and_kept() {
    let d = tempfile::tempdir().unwrap();
    ensure_dirs(d.path()).unwrap();
    let a = token(d.path()).unwrap();
    assert_eq!((a.len(), token(d.path()).unwrap()), (32, a.clone()));
    assert_eq!(mode(&d.path().join("pty.token")), 0o600);
    assert_eq!(mode(&d.path().join("pty")), 0o700);
}

#[test]
fn a_long_socket_path_is_an_error() {
    let long = Path::new("/tmp").join("x".repeat(100));
    assert!(socket_path(&long, 1).unwrap_err().to_string().contains("too long"));
}

#[tokio::test]
async fn a_dead_socket_is_removed_and_skipped() {
    // pty/1.sock: a listener bound then dropped (refuses); pty/2.sock: a live fake answering a status for "b".
    // pty/3.sock: a listener that accepts and never answers (busy).
    let got = scan(dir, &tok).await;
    assert_eq!(got.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["b"]);
    assert!(!dir.join("pty/1.sock").exists() && dir.join("pty/3.sock").exists());
}

#[tokio::test]
async fn a_bad_token_is_refused() {
    let mut r = BufReader::new(&b"{\"op\":\"status\",\"v\":1}\nnope\n"[..]);
    assert_eq!(read_head(&mut r, "good").await.unwrap_err(), "bad token");
}

#[test]
fn unknown_status_fields_are_ignored() {
    let s: Status = serde_json::from_str(r#"{"v":1,"name":"a","command":"","cols":1,"rows":1,"activity":0,"viewers":0,"pid":9,"new":1}"#).unwrap();
    assert_eq!(s.name, "a");
}
```

- [ ] **Step 2: 跑，确认失败** — Run: `cd rust && cargo test -p rapp-term --lib pty::local` Expected: 编译失败。
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑** — Expected: PASS。
- [ ] **Step 5: Commit**

```bash
git add rust/term/src/pty/local.rs rust/term/src/pty/mod.rs
git commit -m "feat(term): local protocol between rapp-term run and serve"
```

---

### Task 6: `run` 里的会话循环（`pty/view.rs`）

**Files:**
- Create: `rust/term/src/pty/view.rs`
- Modify: `rust/term/src/pty/mod.rs`（`Shared`）

**Interfaces:**
- Consumes：`wire::{Lines, Got, put, panes_msg, history_msg, PasteBuf, PasteStep, TOO_LONG, MAX_IN_LINE}`（任务 1）、`Emu`/`Modes`（任务 3）、`keys::to_bytes`（任务 4）、`Sender`、`proto::{In, Out, Pane, PROTO}`
- Produces（`rapp_term::pty`）：
  - `pub struct Shared { pub emu: Mutex<Emu>, pub rev: tokio::sync::watch::Sender<u64>, pub input: tokio::sync::mpsc::UnboundedSender<Vec<u8>>, pub meta: Meta, pub viewers: AtomicU32, pub ended: tokio::sync::watch::Sender<bool>, pub activity: AtomicU64 }`
  - `pub struct Meta { pub name: String, pub command: String, pub pid: u32, pub ticket: Option<String> }`
  - `impl Shared { pub fn status(&self) -> local::Status }`
  - `pub async fn view::serve<R: AsyncBufRead + Unpin, W: AsyncWrite + Unpin>(shared: Arc<Shared>, r: R, w: W) -> std::io::Result<()>`：一个观众，直到它断开或 `ended` 变真。进来 `viewers` 加一，走时减一。
- 行为：
  - 先发 `Hello{v: PROTO, backend:"pty"}`，再发 `Panes`（一个面板，见“本计划替规格定下的事”），收到 `View` 以后用 `Sender::new("%0")` 发第一屏（全屏）。
  - `rev` 变了（有新输出、改了尺寸）就 `offer` 一屏；`Ack` 交给 `Sender::ack`。最小间隔 50 毫秒，和 `session::Opts::min_gap` 一样。尺寸变了先发新的 `Panes`。
  - `Keys`：逐个 `to_bytes(key, emu.modes())`，有一个认不得就回 `Error{error:"unknown key: <键>"}`、整条不发；认得就拼起来送 `input`。`Type`：原样送。`Text`：经 `PasteBuf`；拼好后 `bracketed_paste` 开着就包 `ESC[200~`…`ESC[201~`，`enter` 为真再加 `\r`，送 `input`，回 `Pasted{ok:true}`；太长回 `Pasted{ok:false, error: TOO_LONG}`。`pane` 不是 `%0` 的输入一律不发，回 `Error{error:"no such pane"}`。
  - `History`：`emu.history(before, lines)` → `history_msg("%0", …)`。
  - `Refit`、`NewWindow`：见“本计划替规格定下的事”。
  - `ended` 变真：发 `Error{error:"session ended"}`，返回。

- [ ] **Step 1: 写失败测试**（`view.rs` 里；`tokio::io::duplex` 当连接，`Shared` 用 `Emu::new(20, 5)` 和一个 `mpsc` 接收端看写进伪终端的字节）

```rust
#[tokio::test]
async fn a_viewer_gets_hello_panes_then_a_full_screen() {
    let (sh, _input) = shared(20, 5);
    sh.emu.lock().unwrap().feed(b"hello");
    let mut c = viewer(&sh);
    assert_eq!(c.next().await["backend"], "pty");
    assert_eq!(c.next().await["panes"][0]["id"], "%0");
    c.send(json!({"t":"view","pane":null,"cols":20,"rows":5})).await;
    let s = c.next().await;
    assert_eq!((s["t"].as_str(), s["full"].as_bool()), (Some("screen"), Some(true)));
    assert_eq!(s["lines"][0][1], "hello");
}

#[tokio::test]
async fn keys_follow_app_cursor_mode() { /* feed ESC[?1h, send keys ["Up"], input gets b"\x1bOA" */ }

#[tokio::test]
async fn a_paste_is_bracketed_only_when_the_program_asked() {
    // mode off: text "a\nb" enter:true → input b"a\nb\r", reply pasted ok
    // after feed ESC[?2004h: text "x" enter:false → input b"\x1b[200~x\x1b[201~"
}

#[tokio::test]
async fn a_paste_over_one_mib_is_refused_and_nothing_is_written() {
    // two chunks of MAX_PASTE/2+1 with more:true, then "y" more:false → one pasted{ok:false,error:TOO_LONG}; input empty
}

#[tokio::test]
async fn new_output_sends_a_diff_after_the_ack() { /* ack rev 1, feed "!", next screen has full:false */ }

#[tokio::test]
async fn refit_is_refused_and_the_size_stays() { /* send refit 100×40 → error "the size follows the window on the host", next screen cols 20 */ }

#[tokio::test]
async fn ended_says_so_and_closes() { /* ended.send(true) → error "session ended", then EOF */ }

#[tokio::test]
async fn viewers_are_counted() { /* two viewers → status().viewers == 2; drop one → 1 */ }
```

- [ ] **Step 2: 跑，确认失败** — Run: `cd rust && cargo test -p rapp-term --lib pty::view` Expected: 编译失败。
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑** — Expected: PASS。
- [ ] **Step 5: Commit**

```bash
git add rust/term/src/pty/view.rs rust/term/src/pty/mod.rs
git commit -m "feat(term): the session loop a pty holder runs for each viewer"
```

---

### Task 7: `rapp-term run`（`pty/holder.rs`）

**Files:**
- Create: `rust/term/src/pty/holder.rs`
- Modify: `rust/term/src/main.rs`（`USAGE` 加 `rapp-term run [--name N] [--cwd DIR] [--dir DIR] [--ticket T] [-- COMMAND...]`，分派到 `pty::holder::run`）
- Test: `rust/term/tests/pty.rs`

**Interfaces:**
- Consumes：任务 3、5、6 的全部
- Produces：`pub async fn run(opts: RunOpts) -> anyhow::Result<i32>`（返回程序的退出码）；`pub struct RunOpts { pub name: Option<String>, pub cwd: Option<PathBuf>, pub dir: PathBuf, pub ticket: Option<String>, pub command: Vec<String> }`。`--dir` 没给就用 `local::default_dir()`。
- 行为（规格 §4.1）：
  1. 标准输入不是 tty：报错 `rapp-term run needs a terminal window`，退出码 2。
  2. `ensure_dirs`、`token`；`name_lock` 拿锁 → `scan` → `pick_name(名字或 default_name(命令行), …)`（经 `id::session_name` 清洗）→ 绑 `socket_path(dir, 自己的 pid)`（旧文件先删）→ 放锁。
  3. 用窗口的尺寸（标准输出的 `TIOCGWINSZ`）开伪终端；命令为空用 `CommandBuilder::new_default_prog()`；`cwd` 没给用 `$HOME`；环境照继承。
  4. 窗口切 raw 模式（`cfmakeraw`），用一个守卫在任何退出路径上还原。
  5. 一个线程读伪终端：写标准输出、`emu.feed`、`activity` 记现在、`rev` 加一。一个线程读标准输入写进伪终端；`input` 通道里的字节也写进同一个写端。
  6. SIGWINCH：读新尺寸，改伪终端和 `Emu`，`rev` 加一。
  7. `UnixListener` 接连接：`read_head`；`status` 回 `shared.status()`；`view` 进 `view::serve`；别的回 `unsupported`。一个连接出什么错都只断这一个。
  8. 程序退出：`ended` 设真，等观众收到（最多 1 秒），删 socket，还原 tty，返回退出码。SIGHUP、SIGTERM：杀子进程，然后同上。

- [ ] **Step 1: 写失败的集成测试**（`tests/pty.rs`）

测试自己用 portable-pty 开一个 100×30 的伪终端当“窗口”，在里面跑 `BIN run --dir <tmp> --name t -- /bin/cat`，读窗口那一头的输出放进一个缓冲区。帮手：`wait_status(dir, name) -> Status`、`Viewer`（`local::connect(.., "view", ..)` 加逐行 JSON 读写）。

```rust
#[tokio::test]
async fn status_reports_the_name_command_and_window_size() {
    let w = Window::start(&dir, &["--name", "t", "--", "/bin/cat"]);
    let s = wait_status(&dir, "t").await;
    assert_eq!((s.command.as_str(), s.cols, s.rows, s.viewers), ("/bin/cat", 100, 30, 0));
}

#[tokio::test]
async fn remote_typing_shows_in_both_the_window_and_the_viewer() {
    // viewer sends type "hi\r" → window output contains "hi"; a later screen's lines contain "hi" twice (echo + cat)
}

#[tokio::test]
async fn the_local_keyboard_still_works() { /* write "yo\r" into the window side → viewer screen shows "yo" */ }

#[tokio::test]
async fn a_viewer_leaving_never_ends_run() {
    // two viewers; drop the first; the second still gets a screen after type "x"; a third connects and gets full:true
    // first; run is still alive (status answers)
}

#[tokio::test]
async fn a_window_resize_reaches_the_viewer() {
    // resize the window pty to 120×40 → viewer gets panes with cols 120 then a screen with cols 120 rows 40
}

#[tokio::test]
async fn names_count_up() { /* two `run --name t` → statuses "t" and "t-2" */ }

#[tokio::test]
async fn the_program_exiting_ends_run_and_removes_its_socket() {
    // viewer sends keys ["Ctrl-D"] to cat → viewer gets error "session ended"; child exits 0; pty/<pid>.sock is gone
}

#[tokio::test]
async fn closing_the_window_ends_run() { /* drop the window pty master → run exits, socket gone, cat gone */ }

#[test]
fn without_a_terminal_it_refuses() { /* BIN run with stdin from /dev/null → exit 2, stderr says "needs a terminal window" */ }
```

- [ ] **Step 2: 跑，确认失败** — Run: `cd rust && cargo test -p rapp-term --test pty` Expected: FAIL（`run` 未知）。
- [ ] **Step 3: 实现 `holder.rs` 和 `main.rs` 的分派**
- [ ] **Step 4: 跑** — Run: `cd rust && cargo test -p rapp-term --test pty` Expected: PASS。
- [ ] **Step 5: 手试一次**：在本机 Terminal 里 `cargo run -p rapp-term -- run -- zsh`，打几条命令、开 `vim` 再退出、拖窗口大小；显示和直接跑 zsh 一样，退出后窗口回到原来的 shell 状态（没有残留的 raw 模式）。
- [ ] **Step 6: Commit**

```bash
git add rust/term/src/pty/holder.rs rust/term/src/main.rs rust/term/tests/pty.rs
git commit -m "feat(term): rapp-term run holds a pty in its own terminal window"
```

---

### Task 8: `serve` 列出和看 `pty` 会话

**Files:**
- Modify: `rust/term/src/serve.rs`（`ServeOpts` :42、`list` :225 一带、`watch`/`rewatch`/`table`、`view` :340、`HostRow`、`BACKEND` 常量改成 `TMUX`、新常量 `PTY = "pty"`）
- Test: `rust/term/tests/serve.rs`（`common::Server` 那套）

**Interfaces:**
- Consumes：`local::{scan, connect, token, Status}`（任务 5）、`rapp-term run`（任务 7）
- Produces：
  - `ServeOpts.pty_dir: PathBuf`，`ServeOpts::new` 里默认 `config.parent().join("term")`
  - `HostRow.launchers: Vec<String>`（`#[serde(skip_serializing_if = "Vec::is_empty")]`），本机那条由任务 9 填，这一步先是空
  - `fn pty_rows(&self, statuses: &[Status], now: u64) -> Vec<TermRow>`：`id` = `TermId{backend:"pty", host:None, name}`，`host` None，`panes` 1，`attached` = `viewers`，`activity`，`dead` false，`unread` = `Unread::is_unread("pty:<pid>", activity, now)`
  - `list`：本机的 tmux 行在前，`pty` 行接在后面；tmux 出错时本机 `HostRow.error` 照写，`pty` 行照列
  - `watch`：多一个和主机任务并列的扫描任务，每 `poll` 扫一次，结果变了就 `changed.notify_one()`；`table` 把它并进本机
  - `view`：`backend == "pty"` → 找名字对上的那个 socket（`scan`），找不到回 `Error{error:"no such text terminal"}`；连上以后两边逐行转发，主控台→`run` 的行数输入（`keys`、`type`、`more:false` 的 `text`），`run`→主控台的行里有 `"t":"screen"` 就 `Unread::seen("pty:<pid>", now)`；`Ended` 事件照 tmux 那样发

- [ ] **Step 1: 写失败测试**（`tests/serve.rs`；`run` 用任务 7 的 `Window` 帮手，`--dir` 指向 worker 的 `<config 所在目录>/term`）

```rust
#[tokio::test]
async fn a_pty_session_is_listed_after_tmux_ones() {
    let w = Worker::start(..); let _win = Window::start(&w.pty_dir(), &["--name", "t", "--", "/bin/cat"]);
    let rows = w.list().await["terms"].clone();
    let t = rows.as_array().unwrap().iter().find(|r| r["id"] == "term:pty:t").unwrap();
    assert_eq!((t["panes"].as_u64(), t["attached"].as_u64(), t["dead"].as_bool()), (Some(1), Some(0), Some(false)));
}

#[tokio::test]
async fn pty_rows_are_listed_without_tmux() {
    // worker started with PATH set to an empty temp dir: hosts[0].error is set, term:pty:t is still listed
}

#[tokio::test]
async fn a_watch_sees_a_pty_session_come_and_go() { /* start run → a list with it; Ctrl-D through a view → a list without it */ }

#[tokio::test]
async fn viewing_a_pty_session_goes_through_serve() {
    // view term:pty:t with a sid → hello backend "pty", a screen; type "hi\r"; close → ended event with inputs 1
}

#[tokio::test]
async fn an_unknown_text_terminal_is_an_error() { /* view term:pty:nope → error "no such text terminal" */ }

#[tokio::test]
async fn restarting_serve_finds_the_session_again() {
    // stop the worker, start a new one on the same config: list still has term:pty:t, and the run process never ended
}
```

- [ ] **Step 2: 跑，确认失败** — Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term --test serve pty` Expected: FAIL。
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑全部** — Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term` Expected: PASS（tmux 的测试一条不坏）。
- [ ] **Step 5: Commit**

```bash
git add rust/term/src/serve.rs rust/term/tests/serve.rs rust/term/tests/common/mod.rs
git commit -m "feat(term): serve lists and views pty sessions"
```

---

### Task 9: 新开文本终端：`serve` 的 `open` 和 `Op::OpenTerm`

**Files:**
- Create: `rust/term/src/pty/launch.rs`
- Modify: `rust/term/src/serve.rs`（`Req::Open`、`ServeOpts.launch_with`、本机 `HostRow.launchers`）、`rust/term/src/main.rs`（`serve` 读隐藏选项 `--launch-with <程序>`，只给测试用）
- Modify: `rust/net/src/msg.rs`（`Op::OpenTerm`）、`rust/service/src/peer.rs:194`、`rust/service/src/term.rs`（`request`、`log_fields`）、`rust/hub/src/lib.rs:326`、`rust/hub/src/terms.rs:84-105`
- Test: `rust/term/src/pty/launch.rs`（单元）、`rust/term/tests/serve.rs`、`rust/net/src/msg.rs`、`rust/service/src/term.rs`、`rust/hub/src/terms.rs` 里已有的测试块

**Interfaces:**
- Consumes：任务 5、7、8
- Produces：
  - `launch::command_file(bin: &Path, dir: &Path, ticket: &str, name: Option<&str>, cwd: Option<&Path>, command: Option<&str>) -> String`（文件内容，见“本计划替规格定下的事”）
  - `launch::quote(s: &str) -> String`（单引号转义）
  - `launch::launchers() -> Vec<String>`：macOS 上 `["Terminal"]`，`open -Ra iTerm` 成功再加 `"iTerm"`；别的系统空
  - `launch::open(app: &str, file: &Path, launch_with: Option<&Path>) -> anyhow::Result<()>`：`launch_with` 有就跑 `<它> <app> <file>`，否则 `open -a <app> <file>`
  - `serve` 请求 `{"op":"open","cwd":…?,"name":…?,"command":…?,"app":…}`，回 `{"id":"term:pty:<名字>"}` 或 `{"error":…}`。错误原文：`unknown terminal app`、`no such directory: <目录>`、`the terminal window did not start in 10 s`。`open` 请求一个接一个处理（一把 `tokio::sync::Mutex`）。
  - `Op::OpenTerm { cwd: Option<String>, name: Option<String>, command: Option<String>, app: String }`（`skip_serializing_if = "Option::is_none"`），线上名 `open_term`
  - service：`Op::OpenTerm` → `serve` 的 `{"op":"open",…}`；`log_fields` → `{"op":"open_term","app":<app>}`
  - hub：`"open_term"` 加进 `lib.rs:326` 的匹配和 `terms.rs` 的注释；回复 `Op::OpenTerm { .. } => json!({"event":"term_created","id":id,"term":r["id"]})`

- [ ] **Step 1: 写失败测试**

```rust
// launch.rs
#[test]
fn the_command_file_quotes_everything_but_the_command() {
    let f = command_file(Path::new("/A pp/rapp-term"), Path::new("/r/local/term"), "t1", Some("it's"), Some(Path::new("/w")), Some("claude --resume"));
    assert_eq!(f, "#!/bin/sh\nexec '/A pp/rapp-term' run --dir '/r/local/term' --ticket 't1' --name 'it'\\''s' --cwd '/w' -- claude --resume\n");
    assert!(!command_file(Path::new("/b"), Path::new("/d"), "t", None, None, None).contains("--"));
}

// msg.rs
#[test]
fn open_term_is_snake_case_and_drops_empty_fields() {
    let op = Op::OpenTerm { cwd: None, name: None, command: Some("claude".into()), app: "Terminal".into() };
    assert_eq!(serde_json::to_value(&op).unwrap(), json!({"op":"open_term","command":"claude","app":"Terminal"}));
}

// service term.rs
#[test]
fn open_term_logs_only_the_app() {
    let op = Op::OpenTerm { cwd: Some("/secret".into()), name: Some("n".into()), command: Some("rm".into()), app: "iTerm".into() };
    assert_eq!(log_fields(&op), json!({"op":"open_term","app":"iTerm"}));
}

// tests/serve.rs —— worker 带 `--launch-with <脚本>`，脚本是 `#!/bin/sh\nscript -q /dev/null sh "$2" >/dev/null 2>&1 &`
#[tokio::test]
async fn open_starts_a_window_and_answers_its_id() {
    let r = w.ask(json!({"op":"open","command":"/bin/cat","name":"c","app":"Terminal"})).await;
    assert_eq!(r["id"], "term:pty:c");
    assert!(std::fs::read_dir(w.pty_dir().join("launch")).unwrap().next().is_none(), "the .command file is removed");
}

#[tokio::test]
async fn open_refuses_a_missing_directory_and_an_unknown_app() {
    // cwd "/no/such" → error "no such directory: /no/such"; app "Warp" → error "unknown terminal app"
}

#[tokio::test]
async fn open_gives_up_after_ten_seconds() { /* --launch-with /usr/bin/true → error "the terminal window did not start in 10 s" */ }

#[tokio::test]
async fn this_machine_lists_its_launchers() { /* macOS: hosts[0].launchers contains "Terminal" */ }
```

（hub 那边照 `terms.rs` 现有测试的样子加一条：`open_term` 回 `term_created`。）

- [ ] **Step 2: 跑，确认失败** — Run: `cd rust && cargo test --workspace open` Expected: 编译失败。
- [ ] **Step 3: 实现**（`--launch-with` 不写进 `USAGE`；`ticket` 用 `std::collections::hash_map::RandomState` 加时间做 16 个十六进制字符）
- [ ] **Step 4: 跑全部** — Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings` Expected: PASS，无警告。
- [ ] **Step 5: 手试**：本机 `cargo build -p rapp-term`，起一个 `serve`，用 `nc -U` 或测试帮手发 `open`（`app: "Terminal"`，`command: "zsh"`），看到 Terminal 弹出新窗口，`list` 里有它。
- [ ] **Step 6: Commit**

```bash
git add rust/term/src/pty/launch.rs rust/term/src/pty/mod.rs rust/term/src/serve.rs rust/term/src/main.rs rust/term/tests/serve.rs rust/net/src/msg.rs rust/service/src/peer.rs rust/service/src/term.rs rust/hub/src/lib.rs rust/hub/src/terms.rs
git commit -m "feat(term): open a text terminal window on the host from the console"
```

---

### Task 10: 主控台的数据层：`openTerm`、`launchers`、`term_open`

**Files:**
- Modify: `gui/lib/hub_client.dart`（`TermHost` :128、`_termList` :146、`newTerm` 旁边 :288）、`gui/lib/ui/prefs.dart`
- Test: `gui/test/hub_client_test.dart`、`gui/test/ui/prefs_test.dart`

**Interfaces:**
- Produces：
  - `TermHost.launchers: List<String>`（默认 `const []`），从 `hosts[i].launchers` 读，不是字符串的项跳过
  - `Future<String> openTerm(String id, {String? cwd, String? name, String? command, required String app})`：发 `{'cmd':'open_term','id':id,'cwd':?cwd,'name':?name,'command':?command,'app':app}`，等 `term_created`，回 `term`
  - `UiPrefs.termOpen: Map<String, String>`（设备 id → `'text'` | `'pixels'`），存成 `term_open`；不认得的值读的时候丢掉；`String termOpenFor(String device)` 没写就是 `'text'`

- [ ] **Step 1: 写失败测试**

```dart
test('openTerm sends open_term and answers the new id', () async {
  // fake hub answers {"event":"term_created","id":"d1","term":"term:pty:claude"}
  expect(await hub.openTerm('d1', command: 'claude', app: 'Terminal'), 'term:pty:claude');
  expect(sent.last, {'cmd': 'open_term', 'id': 'd1', 'command': 'claude', 'app': 'Terminal', 'req': anything});
});

test('a host row reads its launchers', () { /* hosts:[{"launchers":["Terminal","iTerm",3]}] → ['Terminal','iTerm'] */ });

test('term_open round-trips and defaults to text', () {
  final p = UiPrefs()..termOpen['d1'] = 'pixels';
  p.save(dir);
  final q = UiPrefs.load(dir);
  expect((q.termOpenFor('d1'), q.termOpenFor('d2')), ('pixels', 'text'));
});

test('a bad term_open value is dropped', () { /* gui.json {"term_open":{"d1":"x","d2":"pixels"}} → only d2 kept */ });
```

（`req` 那一项照 `hub_client_test.dart` 里已有测试的写法比较。）

- [ ] **Step 2: 跑，确认失败** — Run: `cd gui && flutter test test/hub_client_test.dart test/ui/prefs_test.dart` Expected: FAIL。
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑** — Expected: PASS；`git checkout -- gui/pubspec.lock`（若有改动）。
- [ ] **Step 5: Commit**

```bash
git add gui/lib/hub_client.dart gui/lib/ui/prefs.dart gui/test/hub_client_test.dart gui/test/ui/prefs_test.dart
git commit -m "feat(gui): openTerm, host launchers and the term_open preference"
```

---

### Task 11: 设备面板：“终端”一项

**Files:**
- Create: `gui/lib/ui/terms_entry.dart`
- Modify: `gui/lib/ui/devices_tab.dart`（`_remote` :168、`_termGroup` :269、`_TermRow` :520、新 `_NewTextDialog`）、`gui/lib/ui/main_state.dart`（`openOrSwitch` :1677）、`gui/lib/ui/main_window.dart`（照 `unlockAsks` :71 的样子接 `newTextAsks`）
- Test: `gui/test/ui/terms_entry_test.dart`（新）、`gui/test/ui/devices_tab_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes：任务 10 的 `openTerm`、`TermHost.launchers`、`UiPrefs.termOpen`/`termOpenFor`
- Produces（`terms_entry.dart`）：
  - `const termsEntry = 'terms:';` `const termsEntryName = '终端';`
  - `const terminalApps = {'com.apple.Terminal', 'com.googlecode.iterm2', 'com.mitchellh.ghostty', 'com.github.wez.wezterm', 'net.kovidgoyal.kitty', 'org.alacritty', 'dev.warp.Warp-Stable'};`
  - `bool showsTermsEntry(TermList? list)`：`list != null && !list.off && list.error == null`
  - `List<HubApp> orderApps(List<HubApp> apps, {required bool entry})`：`desktop:` 第一；`entry` 为真时去掉终端 app；其余照原顺序
  - `List<HubApp> terminalAppsOf(List<HubApp> apps)`
  - `sealed class TermsTarget`：`OpenTerm(String app, String name)`、`OpenPixels(String bundle, String name)`、`AskNewText()`
  - `TermsTarget termsTarget({required String mode, required TermList list, required List<HubApp> apps})`：
    - `mode == 'text'` 且有 `pty` 会话：`activity` 最大的那个 → `OpenTerm(r.id, termDisplayName(r.name, r.host))`
    - `mode == 'text'`、没有 `pty` 会话、本机 `launchers` 非空 → `AskNewText()`
    - 其余：`terminalAppsOf(apps)` 的第一个 → `OpenPixels(它)`；一个都没有 → `OpenPixels('com.apple.Terminal', 'Terminal')`
- Produces（`MainState`）：
  - `openOrSwitch(id, 'terms:', _)` 按 `termsTarget(...)` 去开；`AskNewText` 时往 `newTextAsks` 里推 `id`
  - `Stream<String> get newTextAsks`；`Future<void> openText(String id, {String? cwd, String? name, String? command, required String app})`：`hub.openTerm` → 刷新 `terms` → `openOrSwitch(id, 新 id, 名字)`；失败把错误抛给调用者（对话框里显示）
  - `void setTermOpen(String device, String mode)`：改 prefs 并保存
- 面板（规格 §2.1 的样子）：
  - 应用列表按 `orderApps`；`showsTermsEntry` 为真时，在 `desktop:` 后面插一行 `_AppRow` 样子的“终端”（可设常用：`toggleFavorite(id, 'terms:', '终端')`；[打开] 走 `openOrSwitch(id, 'terms:', '终端')`），下面缩进 16 是合并后的组：
    - 每个会话一行：名字、类型「文本」（`parseTermId(r.id)?.backend == 'pty'`）或「tmux」、原来的状态文字、[打开]
    - `terminalAppsOf(apps)` 每个一行：名字、「只能用画面看」、按钮「画面」→ `openOrSwitch(id, a.app, a.name)`
    - SSH 主机行（和原来一样）
    - 按钮「新开文本终端…」（只在本机 `launchers` 非空时有，Key `new-text-term`）、「新开 tmux 会话…」（原来的「新开终端…」，Key `new-term` 不变）、「添加 SSH 主机…」
    - 「打开方式」两个单选「文本」「画面」（Keys `term-open-text`、`term-open-pixels`），改了立刻存
  - 一个会话都没有时写「这台设备上现在没有终端会话。」
  - `_NewTextDialog`：标题「新开文本终端」；「目录（空着就是家目录）」「命令（如 claude；空着就是 shell）」「名字（可不填）」；`launchers.length > 1` 时有「用哪个终端 app」下拉，默认第一个；按钮「新开」「取消」；空着的栏不发；失败把原文写在对话框里，不关。
  - 原来单独的 `_termGroup` 不再出现在列表末尾。

- [ ] **Step 1: 写 `terms_entry_test.dart` 的失败测试**

```dart
test('desktop first and terminal apps folded when the entry shows', () {
  final apps = [app('com.apple.Safari'), app('com.apple.Terminal'), app('desktop:'), app('com.googlecode.iterm2')];
  expect(orderApps(apps, entry: true).map((a) => a.app), ['desktop:', 'com.apple.Safari']);
  expect(orderApps(apps, entry: false).map((a) => a.app), ['desktop:', 'com.apple.Safari', 'com.apple.Terminal', 'com.googlecode.iterm2']);
});

test('text mode opens the most recently active text terminal', () {
  final list = TermList('d', terms: [pty('a', activity: 5), tmuxRow('w', activity: 9), pty('b', activity: 7)], hosts: [local(['Terminal'])]);
  expect(termsTarget(mode: 'text', list: list, apps: const []), isA<OpenTerm>().having((t) => t.app, 'app', 'term:pty:b'));
});

test('text mode with none asks for a new one, if it can open one', () {
  expect(termsTarget(mode: 'text', list: TermList('d', hosts: [local(['Terminal'])]), apps: const []), isA<AskNewText>());
  expect(termsTarget(mode: 'text', list: TermList('d', hosts: [local(const [])]), apps: const []), isA<OpenPixels>());
});

test('pixels mode opens the first terminal app, else Terminal', () {
  expect((termsTarget(mode: 'pixels', list: TermList('d'), apps: [app('com.googlecode.iterm2')]) as OpenPixels).bundle, 'com.googlecode.iterm2');
  expect((termsTarget(mode: 'pixels', list: TermList('d'), apps: const []) as OpenPixels).bundle, 'com.apple.Terminal');
});
```

- [ ] **Step 2: 跑，确认失败** — Run: `cd gui && flutter test test/ui/terms_entry_test.dart` Expected: FAIL。
- [ ] **Step 3: 实现 `terms_entry.dart`**
- [ ] **Step 4: 跑** — Expected: PASS。
- [ ] **Step 5: 写面板和状态的失败测试**（`devices_tab_test.dart`、`main_state_test.dart`，用现有的 fakes）

```dart
testWidgets('desktop, then 终端, then the other apps; Terminal only inside 终端', (t) async {
  // apps: Safari, Terminal, desktop:; term list with one pty row and launchers ['Terminal']
  // expect the vertical order of texts: 桌面 < 终端 < Safari; 'Terminal' appears once, next to 只能用画面看 and a 画面 button
});

testWidgets('the terms entry shows with a tmux error', (t) async {
  // hosts[0].error = 'tmux not found', one pty row → 终端 row and the pty row are shown
});

testWidgets('rows say 文本 or tmux', (t) async { /* pty row → 文本; tmux row → tmux */ });

testWidgets('新开文本终端 only when the host can open one; the app dropdown only with two', (t) async {
  // launchers [] → no Key('new-text-term'); ['Terminal'] → button, dialog without 用哪个终端 app; ['Terminal','iTerm'] → dropdown
});

testWidgets('the dialog sends only filled fields and keeps itself open on failure', (t) async {
  // fill 命令 'claude', tap 新开 → hub.calls has open_term {command:'claude', app:'Terminal'} and no cwd/name
  // hub fails with 'no such directory: /x' → dialog still open showing that text
});

testWidgets('打开方式 is saved per device', (t) async { /* tap term-open-pixels → prefs.termOpenFor(id) == 'pixels' */ });

test('opening terms: in text mode with none pushes a new-text ask', () async {
  // state.newTextAsks emits 'd1'; no session opened
});

test('opening terms: in pixels mode opens the terminal app', () async { /* hub.open called with com.apple.Terminal */ });

test('terms: can be a favorite', () { /* toggleFavorite(d1,'terms:','终端') → isFavorite true */ });

test('openText opens the new session right away', () async { /* openTerm answers term:pty:c → open called with term:pty:c */ });
```

- [ ] **Step 6: 跑，确认失败** — Run: `cd gui && flutter test test/ui/devices_tab_test.dart test/ui/main_state_test.dart` Expected: FAIL。
- [ ] **Step 7: 实现面板、`MainState`、`MainWindow` 的接线**（`MainWindow` 收到 `newTextAsks` 时切到设备层、选中那台设备，弹 `_NewTextDialog`；对话框挪成 `devices_tab.dart` 里一个可从外面调的 `showNewTextDialog(context, state, id)`）
- [ ] **Step 8: 跑 GUI 全部** — Run: `cd gui && flutter analyze && flutter test` Expected: 无问题，全过；`git checkout -- gui/pubspec.lock`（若有改动）。
- [ ] **Step 9: Commit**

```bash
git add gui/lib/ui/terms_entry.dart gui/lib/ui/devices_tab.dart gui/lib/ui/main_state.dart gui/lib/ui/main_window.dart gui/test/ui/terms_entry_test.dart gui/test/ui/devices_tab_test.dart gui/test/ui/main_state_test.dart
git commit -m "feat(gui): one 终端 entry with text terminals, tmux sessions and the open mode"
```

---

### Task 12: 舞台上灰掉“按我的屏幕重排”和“新开窗口”

**Files:**
- Modify: `gui/lib/embed/stream_menu.dart:410`、「＋」菜单里「新开窗口」所在处（`gui/lib/ui/top_bar.dart:251` 调 `newTermWindow`，以及输入区「＋」的那一项）
- Test: `gui/test/embed/stream_menu_test.dart`、`gui/test/term/term_composer_test.dart`（「＋」菜单已有测试所在的文件）

**Interfaces:**
- Consumes：`parseTermId(app)?.backend`（`gui/lib/term/term_id.dart`）
- Produces：`bool isPtyTerm(String app) => parseTermId(app)?.backend == 'pty';`（放在 `term_id.dart`）。`pty` 会话：「按我的屏幕重排」灰着，右边写「尺寸跟着被控端的窗口」；「新开窗口」灰着，右边写「文本终端只有一个窗口」；两样都不发消息。tmux 会话不变。

- [ ] **Step 1: 写失败测试**

```dart
testWidgets('a text terminal greys out refit with the reason', (t) async {
  // stream menu for app 'term:pty:c' → Key('term-refit') disabled, '尺寸跟着被控端的窗口' shown; tapping sends nothing
});
testWidgets('a text terminal greys out 新开窗口', (t) async { /* '文本终端只有一个窗口'; port.calls has no new_window */ });
testWidgets('a tmux session keeps both', (t) async { /* 'term:tmux:w' → both enabled */ });
```

- [ ] **Step 2: 跑，确认失败** — Run: `cd gui && flutter test test/embed/stream_menu_test.dart test/term/term_composer_test.dart` Expected: FAIL。
- [ ] **Step 3: 实现**（菜单项的“灰着加原因”照「附件…」用 `termNoAttach`（`gui/lib/term/term_session_port.dart:21`）的现成写法）
- [ ] **Step 4: 跑 GUI 全部** — Run: `cd gui && flutter analyze && flutter test` Expected: PASS。
- [ ] **Step 5: Commit**

```bash
git add gui/lib/term/term_id.dart gui/lib/embed/stream_menu.dart gui/lib/ui/top_bar.dart gui/test/embed/stream_menu_test.dart gui/test/term/term_composer_test.dart
git commit -m "feat(gui): text terminals grey out refit and new window"
```

（「＋」菜单实际所在的文件以 `grep -rn newTermWindow gui/lib` 为准，一并 `git add`。）

---

### Task 13: 文档，和交给用户的真机验收

**Files:**
- Modify: `docs/superpowers/specs/2026-11-16-rapp-text-terminal-design.md`（状态改“已确认 2026-11-16”；§2.1 `term:` → `terms:`；§4.1 socket 路径 `<pid>.sock`；§4.3 `dead`；§4.4 `.command` 的写法和 `--ticket`）
- Modify: `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md`（§1“不做”去掉“Unix 上自带的伪终端和持有进程”，§10 改成指向文本终端规格）
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（§2.4 `term_open`；§3 `$ROOT/local/term/`、`pty/`、`launch/`、`pty.token`）
- Modify: `README.md`、`README.zh-CN.md`：只在它们已经写了终端会话用法时加 `rapp-term run` / `rapp-term new`（现在没写就不加）

- [ ] **Step 1: 改文档**，每处按这个计划实际做成的样子写。
- [ ] **Step 2: 全量验证**

Run: `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cd ../gui && flutter analyze && flutter test`
Expected: 全过。

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-11-16-rapp-text-terminal-design.md docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md docs/superpowers/specs/2026-11-13-rapp-config-reference.md
git commit -m "docs: text terminal spec follow-ups"
```

- [ ] **Step 4: 把真机验收清单交给用户**（规格 §11 的 P2、P3 验收，逐条）：
  1. 被控 Mac 的 Terminal 里手敲 `rapp-term run -- claude`，主控台“终端”里出现它，标「文本」；能看，能发一段中文，按 Esc 能打断；本机窗口照常用。
  2. 关掉主控台的会话、断网、在「本机」里停掉服务再起来：窗口和程序都在，重新打开接上的是同一个。
  3. 主控台点「新开文本终端…」：被控端弹出窗口，舞台直接是它；用 iTerm 再开一个。
  4. 设备列表里「桌面」第一、「终端」第二；Terminal、iTerm 只在「终端」里面出现。
  5. 打开方式切到「画面」，点「终端」打开的是 Terminal 的画面会话；切回「文本」，打开的是最近有动静的文本终端。
  6. 被控端拖窗口大小，主控台跟着变；流量菜单里「按我的屏幕重排」灰着。
