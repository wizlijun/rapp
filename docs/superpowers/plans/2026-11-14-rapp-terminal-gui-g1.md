# rapp 终端会话界面（G1 看）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在主控台上打开另一台设备（或它代管的 SSH 主机）上的 tmux 会话来看：一张对得齐的字符网格，一个面板一个标签，本机往上翻、选中复制、点网址；设备面板里多一组“终端”，能添加 SSH 主机。

**Architecture:** 被控端在线协议里补几样界面要用的（历史行数、光标形状、每行是不是折行、面板的窗口编号和当前面板），字段都可缺省，旧设备照样能看。主控台新加 `gui/lib/term/`：`TermSessionPort` 是 `SessionPort` 的一个纯 Dart 子类，连 hub 给的本机端口、说线协议、发现有的 `SessionEvent`（窗口表、流量、断开）；每个会话一份 `TermModel`（当前屏、取到的历史、往上翻的位置）；`TermStage` 按格子画、管滚动和选区。`MainState` 按 sid 选端口（`portOf`），舞台按会话选 `TermStage`，其余（记录、灯、重连、会话列表、顶栏）沿用 app 会话的那一套。

**Tech Stack:** Rust 2021（`rust/term`）；Flutter / Dart（`gui`），`dart:io` 的 `Socket`、`dart:ui` 画布。不加新依赖。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-terminal-gui-design.md`（下称“设计”，§ 都指它）。上位规格 `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md`（下称“规格”）。线协议现状见 `rust/term/src/proto.rs`。

**这份计划的范围：** 设计 §8 的 G1：端口、网格模型、`TermStage`（D1–D6、Z1、H1–H3、C1–C5、L1–L2）、标签（T1、T2、T4）、顶栏、设备面板的“终端”一组、会话列表、添加 SSH 主机；外加 G1 用到的 §6 协议补充。**不在这里：** G2（键盘直通 K、写作面板 W、按键排、多行粘贴、新开终端、「＋」新开窗口——写作面板 S1 还没做，G2 依赖它），G3（查找 F、位置标记 H4、备用屏幕滚动 H5、字号 Z3–Z5、响铃和“等你” N2、全景缩略），Windows 主控台（规格 R10：第二版）。

## 本计划替设计定下的事

- 设计 §8 把 Z2 列进 G1，但它说的是写作面板、按键排出现时画面上移，这两样 G2 才有，所以 Z2 跟 G2 一起做；L1 的触屏「打开 · 复制」同理（G1 只在 macOS/Linux 主控台上）。L2：路径不做成链接，`linksIn` 只认 `https?://`。
- 设计 §10 的五件先按设计的默认做，G1 只碰到第 4 件：**终端按原色画**，MATRIX 下不压成单色。其余四件在 G2、G3 才用到。
- G0 已探查（tmux 3.8，独立 socket）：`capture-pane -J` 把折行接回一行；`#{cursor_shape}` 有（`default`/`block`/`underline`/`bar`）；`#{history_size}`、`#{history_limit}` 有；`capture-pane -e` 每一行都从默认样式开始、行尾复位，所以每行可以单独解析。“200×60 一屏滚动掉不掉帧”没探，放进任务 11 的验收。
- 协议补充一律加在现有消息上，`PROTO` 仍是 1；新字段在 Rust 里 `#[serde(default)]`，GUI 里缺了就用默认值。
- 往上翻：每次向那边取 500 行；看到的最上一屏离已取到的最旧一行不到一屏时取下一批；同时只有一个请求在途。
- 舞台尺寸变了：第一次立刻发 `view`，之后停手 0.3 秒再发（Z4 的停手规则，G1 先用上；尺寸提示和字号是 G3）。
- 那边的面板比舞台放得下的大（别的终端接着、尺寸被按住）：等比缩小、左上对齐，底下居中一行小字（原型原文）“另有 N 个终端也接着这个会话。为了不改它看到的尺寸，这里按 <列>×<行> 原样缩小显示。”N = 设备面板会话表里这一行的 `attached − 1`（rapp 自己的控制客户端也算一个），至少 1；查不到时去掉“ N 个”写“另有终端也接着这个会话。…”。比舞台小时不放大。
- 流量标签菜单在终端会话里 G1 只有「按我的屏幕重排」和“会话”一组（规格 §13；字号那两项是 G3）。
- 设备面板的终端行：灯 = 未读 → `Lamp.waiting`，10 秒内有输出 → `Lamp.active`，已退出 → `Lamp.disconnected`，其他 `Lamp.idle`；状态字 = 已退出 →「已退出」，未读 →「未读」，10 秒内 →「刚刚有输出」，不到 1 分钟 →「不到 1 分钟没动静」，不到 1 小时 →「N 分钟没动静」，否则「N 小时没动静」。
- 标签文字：`<窗口序号> <命令>`，一个窗口有几个面板时 `<窗口序号>.<面板序号> <命令>`，序号从 1 起、按那边的顺序；已退出的后面加「 · 已退出」。新冒出来的 tmux 窗口不抢当前标签（app 会话里新窗口会成为当前，终端不这样）。第一次打开时停在那边的当前面板。

## Global Constraints

- rapp 对用户的 tmux 只发计划一定下的那十个动词，只在 `rust/term/src/tmux/cmd.rs` 里拼；这份计划新加的命令只用 `capture-pane`、`display-message`、`list-panes`。绝不 `set-option`、`kill-*`，不改别人的尺寸（规格 §1）。
- `term:` 标识在 GUI 里只在 `gui/lib/term/term_id.dart` 里解析（规格 §5“只在一个函数里解析”），别处只用 `isTermApp` 判断前缀、其余当不透明字符串。
- 一行线消息（含换行）不超过 65536 字节（`MAX_LINE`）；超长的行 GUI 丢掉不解析。
- 每个 `screen` 更新的最后一片（`more:false`）都要回 `ack`，哪怕这一屏 GUI 不用（比如属于刚切走的面板）；不回，被控端就不再发（`sender.rs`）。
- 画面规则照设计 D1–D6：按格子画，宽字符两格，框线和方块自己画；默认前景、背景取 `RappTokens.text`、`RappTokens.bg`；16 个基本色每套主题一组，1–14 号在该主题底色上对比度 ≥ 4.5:1；256 色、真彩色原样；粗体、暗淡、斜体、下划线、删除线、反显都画；不加 `textGlow`；不开连字（`FontFeature.disable('liga')`、`disable('calt')`）；光标舞台有焦点时实心、否则空心框，不闪。
- 字体：`RappTokens.mono` + `monoFallback`，14 号（Z3 的默认档）。
- 面向用户的文字全是中文，原文照设计和原型：「正在看历史 · 回到最新」「有新输出 · 回到最新」「选中了 N 个字 · 复制到本机」「终端」「添加 SSH 主机…」「这台设备的 tmux 里现在没有会话。」「按我的屏幕重排」。
- 快捷键：复制 macOS ⌘C、其他 Ctrl+Shift+C；打开网址 macOS ⌘+点击、其他 Ctrl+点击。G1 不截别的键，也不往终端发键。
- 不加第三方依赖（Dart、Rust 都是）；打开网址用 `Process.start('open', [url])`（macOS）/`Process.start('xdg-open', [url])`（Linux）。
- 不碰 `SessionPort` 已有方法的签名；`RemoteSession`、`WindowTabs` 只加任务里写明的参数，默认值保持 app 会话的现有行为。
- 在单独的 git worktree、分支 `feat/term-gui` 上做（执行时用 superpowers:using-git-worktrees）；不推送。每次提交前按文件名 `git add`；不用 `git add -u/-A/.`、`git stash`、`git reset`。`flutter test` 改了 `gui/pubspec.lock` 就 `git checkout -- gui/pubspec.lock`（只许这一处 checkout）。不碰 `README.md`、`docs/archives/`、用户未提交的文档改动和未跟踪文件。
- Rust：新文件用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`，不跑 `cargo fmt`；改动的旧文件手工对齐。每个 Rust 任务结束时 `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term` 全过，`cargo clippy -p rapp-term --all-targets -- -D warnings` 无警告。
- GUI：`export PATH=$HOME/development/flutter/bin:$PATH`；每个 GUI 任务结束时 `cd gui && flutter analyze` 无问题，`flutter test` 全过。新测试放 `gui/test/term/`。
- 提交信息：`feat(term): …`（Rust）、`feat(gui): …`、`test(…): …`；结尾带 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

设计没明说、最可能伤到用户的五种情况，按可能性排。每条在负责的任务里有测试：

1. **在历史里看东西时，那边的历史已满（`hist == limit`）还在出字**：行数不再涨，但内容整体上移；画面不能动、选区不能丢或错位。用前后两屏的重合判断移了几行。（任务 7）
2. **一个更新拆成几片时切了面板**，或某一片解析失败：最后一片照样回 `ack`，否则那边永远不再发新屏，用户看到的是“卡住”。（任务 7、9）
3. **TCP 读到的数据在一个中文字中间、或一行中间断开**；以及一行超过 64 KiB：拼回来照常解析，超长的丢掉、连接不断。（任务 9）
4. **对着还没升级的设备**（没有 `hist`、`wrapped`、`win`、`active`）：能看、能翻、能复制；折行按换行复制，标签按窗口名分组。（任务 4、7）
5. **当前标签的那个面板被关掉了**（那边 `exit`）：换到另一个面板并重新 `view`，不停在空白；面板只是退出（`dead`）时画面留着，标签写「已退出」。（任务 12）

## File Structure

```
rust/term/src/
  proto.rs        改：Pane 加 win、active；Screen 加 hist、limit、shape、wrapped；History 加 hist、wrapped
  screen.rs       改：Screen 加四个字段；from_capture 读新的 meta；wrapped_rows；strip_escapes 挪来
  tmux/cmd.rs     改：PANE_FORMAT 加两项；meta 加三项；capture_joined、history_joined
  tmux/parse.rs   改：16 个字段
  tmux/mod.rs     改：PaneInfo.active；capture 多取一次 -J；history 返回 HistoryRows
  session.rs      改：panes_of 填 win、active；history_msg 收 HistoryRows
rust/term/tests/live.rs  改：折行、光标形状、历史里的折行
gui/lib/term/
  term_id.dart          新：isTermApp、parseTermId、termDisplayName
  term_wire.dart        新：线消息的类型、解析、编码；tabLabels
  char_width.dart       新：cellWidth
  sgr.dart              新：TermStyle、TermCell、TermLine、parseRow
  term_palette.dart     新：每套主题的 16 色、256 色表、contrastRatio
  term_model.dart       新：TermModel（屏、历史、滚动位置、移入历史的行数）
  term_select.dart      新：TermPoint、TermSelection、取文字、选词、网址
  term_link.dart        新：TermLink（Socket、口令、按行收发）
  term_session_port.dart 新：TermSessionPort extends SessionPort
  term_layout.dart      新：TermMetrics、layoutRow、drawBoxChar
  term_painter.dart     新：一行一张 Picture 的缓存、光标、选区、网址下划线
  term_stage.dart       新：TermStage（尺寸、缩小、滚动、横幅、选区、复制、网址）
gui/lib/embed/window_tabs.dart   改：followNew
gui/lib/embed/remote_session.dart 改：followNewTabs 传给 WindowTabs
gui/lib/embed/stream_menu.dart   改：终端会话的菜单
gui/lib/hub_client.dart          改：TermRow、TermHost、TermList、terms、addTermTarget、removeTermTarget
gui/lib/ui/main_state.dart       改：termPort、portOf、_connect 分支、_movable、probe 取终端表
gui/lib/ui/stage.dart            改：终端会话用 TermStage
gui/lib/ui/top_bar.dart          改：终端会话的标题、副标题、标签
gui/lib/ui/session_model.dart    改：SessionEntry.paneTitle
gui/lib/ui/sessions_tab.dart     改：第二行带面板标题
gui/lib/ui/devices_tab.dart      改：“终端”一组、SSH 主机、添加对话框
gui/lib/main.dart                改：建 TermSessionPort
gui/test/fakes.dart              改：FakeTermSessionPort
```

---

### Task 1: 协议：面板的窗口编号和当前面板

**Files:**
- Modify: `rust/term/src/proto.rs`（`Pane`）、`rust/term/src/tmux/cmd.rs`（`PANE_FORMAT`）、`rust/term/src/tmux/parse.rs`、`rust/term/src/tmux/mod.rs`（`PaneInfo`）、`rust/term/src/session.rs`（`panes_of`）
- Test: 同文件里的 `#[cfg(test)]`

**Interfaces:**
- Produces: `Pane { …, #[serde(default)] win: String, #[serde(default)] active: bool }`；`win` 是 tmux 的窗口编号（`@7`），`active` = 窗口是会话的当前窗口且面板是窗口的当前面板。`PaneInfo.active: bool`。

- [ ] **Step 1: 写失败的测试**
  - `parse.rs` 的 `parses_pane_rows_and_skips_broken_ones`：样例行在 `58` 和 `title with spaces` 之间插入 `1\t1`，断言 `v[0].active == true`；再加一行 `…\t1\t0\t…` 断言 `active == false`。
  - `session.rs` 的 `panes_of_keeps_one_session_in_window_then_pane_order`：期望的 `Pane` 加 `win: <info 的 window_id>`、`active: <info 的 active>`。
  - `proto.rs` 加 `pane_without_new_fields_still_parses`：`{"id":"%1","window":"w","title":"","command":"sh","cols":80,"rows":24,"dead":false}` 解析成 `win == ""`、`active == false`。
- [ ] **Step 2: 跑，确认失败**：`cd rust && cargo test -p rapp-term pane` → 编译失败（字段不存在）。
- [ ] **Step 3: 实现**：`PANE_FORMAT` 在 `#{pane_height}\t` 和 `#{pane_title}` 之间加 `#{window_active}\t#{pane_active}\t`（标题留在最后，它可能含制表符）；`parse::pane` 改成 `splitn(16, '\t')`、`f.len() != 16` 跳过；`active = f[13] == "1" && f[14] == "1"`，标题是 `f[15]`。`panes_of` 填 `win: p.window_id.clone()`、`active: p.active`。
- [ ] **Step 4: 跑，确认通过**：`cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term` 全过；clippy 无警告。
- [ ] **Step 5: 提交** `feat(term): panes carry their window id and which one is current`

### Task 2: 协议：屏幕带历史行数、光标形状、折行标记

**Files:**
- Modify: `rust/term/src/screen.rs`、`rust/term/src/tmux/cmd.rs`（`meta`、新 `capture_joined`）、`rust/term/src/tmux/mod.rs`（`capture`）、`rust/term/src/proto.rs`（`Out::Screen`、`screen_msgs`、`strip_escapes` 挪走）
- Test: `screen.rs`、`proto.rs`、`sender.rs` 的单元测试；`rust/term/tests/live.rs`

**Interfaces:**
- Produces（Rust）：`Screen { …, hist: u32, limit: u32, shape: String, wrapped: Vec<u16> }`；`pub(crate) fn strip_escapes(s: &str) -> String`（在 `screen.rs`）；`pub fn wrapped_rows(rows: &[String], joined: &[String]) -> Vec<u16>`；`cmd::capture_joined(pane) = capture-pane -p -J -t <pane>`。
- Produces（线上）：`screen` 消息多四个字段：`hist`、`limit`（数字，总是发）、`shape`（`"block"|"underline"|"bar"`，空就不发）、`wrapped`（这一屏里“下一行是我折下来的”的行号，空就不发）。拆片时每一片都带这四个字段，`wrapped` 是整屏的，不只是这一片的。

- [ ] **Step 1: 写失败的测试**（`screen.rs`）

```rust
#[test]
fn meta_reads_history_and_cursor_shape() {
    let s = Screen::from_capture("a\n", "1 0 1 0 80 2 120 2000 bar").unwrap();
    assert_eq!((s.hist, s.limit, s.shape.as_str()), (120, 2000, "bar"));
    // tmux older than cursor_shape prints nothing for it; "default" means the terminal's own: both are "".
    assert_eq!(Screen::from_capture("", "0 0 1 0 80 2 0 2000").unwrap().shape, "");
    assert_eq!(Screen::from_capture("", "0 0 1 0 80 2 0 2000 default").unwrap().shape, "");
    assert!(Screen::from_capture("", "0 0 1 0 80 2").is_err());
}
#[test]
fn wrapped_rows_match_the_joined_capture() {
    let rows = ["abcdefghijklmnopqrst", "uvwxyz0123", "next", ""].map(String::from);
    let joined = ["abcdefghijklmnopqrstuvwxyz0123", "next", ""].map(String::from);
    assert_eq!(wrapped_rows(&rows, &joined), vec![0]);
    // a wrapped row ending in spaces: plain capture trims them, -J keeps them
    let rows = ["ab", "cd"].map(String::from);
    assert_eq!(wrapped_rows(&rows, &["ab   cd".to_string()]), vec![0]);
    // the two captures disagree (the screen changed between them): no flags from there on, no panic
    let rows = ["x", "y", "z"].map(String::from);
    assert_eq!(wrapped_rows(&rows, &["other".to_string()]), Vec::<u16>::new());
}
```

  `proto.rs` 加 `screen_parts_all_carry_hist_shape_and_wrapped`：用一屏能拆成两片以上的大行调用 `screen_msgs`，断言每一片的 `hist`、`limit`、`shape`、`wrapped` 都和 `Screen` 的相同；再断言 `shape` 为空、`wrapped` 为空时编码出来的 JSON 里没有这两个键。`sender.rs` 加 `a_cursor_shape_change_alone_is_sent`：只改 `shape` 的一屏 `offer` 之后出一条消息。

  `live.rs` 加两个（照 `captures_cjk_truecolor_and_cursor` 的写法）：`capture_marks_wrapped_rows`（20×6 的会话里 `printf 'abcdefghijklmnopqrstuvwxyz0123\n'`，断言 `sc.wrapped == vec![0]`）、`capture_reads_cursor_shape`（`printf '\033[5 q'`，断言 `sc.shape == "bar"`）。
- [ ] **Step 2: 跑，确认失败**：`cd rust && cargo test -p rapp-term` → 编译失败。
- [ ] **Step 3: 实现**
  - `cmd::meta` 的格式串末尾加 ` #{history_size} #{history_limit} #{cursor_shape}`。`from_capture` 接受 8 或 9 个字段；`shape` 只留 `block`/`underline`/`bar`，别的都是 `""`。
  - `wrapped_rows`：两边都先去掉所有空格再比；逐个取 `joined` 的一行 J，从当前行 i 开始累加 `rows[i]`，累加结果是 J 的真前缀时把 i 记为折行、i 往下走，等于 J 时这一行结束；累加结果不是 J 的前缀就停下，返回已记下的。行号用 `u16`。
  - `Tmux::capture`：`-e` 取屏、meta 之后再跑 `capture_joined`，用 `strip_escapes` 后的行算 `wrapped`。`strip_escapes` 从 `proto.rs` 挪到 `screen.rs`，`proto.rs` 改用它。
  - `Out::Screen` 加 `#[serde(default)] hist: u32`、`#[serde(default)] limit: u32`、`#[serde(default, skip_serializing_if = "String::is_empty")] shape: String`、`#[serde(default, skip_serializing_if = "Vec::is_empty")] wrapped: Vec<u16>`；`screen_msgs` 的 `make` 填上；算 `overhead` 时这四个字段已在里面，预算照旧。
- [ ] **Step 4: 跑，确认通过**：`cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term` 全过；clippy 无警告。
- [ ] **Step 5: 提交** `feat(term): screens carry history size, cursor shape and wrapped rows`

### Task 3: 协议：历史带当时的行数和折行标记

**Files:**
- Modify: `rust/term/src/tmux/mod.rs`（`history`）、`rust/term/src/tmux/cmd.rs`（新 `history_joined`）、`rust/term/src/session.rs`（`history_msg`、`In::History` 的处理）、`rust/term/src/proto.rs`（`Out::History`）
- Test: `session.rs` 单元测试、`rust/term/tests/live.rs`

**Interfaces:**
- Consumes: 任务 2 的 `wrapped_rows`、`strip_escapes`。
- Produces（Rust）：`pub struct HistoryRows { pub lines: Vec<String>, pub wrapped: Vec<u32>, pub size: u32 }`（在 `tmux/mod.rs`）；`Tmux::history(&self, pane, before, lines) -> anyhow::Result<HistoryRows>`；`fn history_msg(pane: &str, before: u32, rows: HistoryRows) -> Out`。
- Produces（线上）：`history` 消息多 `hist`（回答时那边的历史总行数，总是发）和 `wrapped`（`lines` 里的下标，空就不发）。`lines` 的最后一行离屏幕最近，就是“屏幕上面第 `before` 行”（下标从 0 起）。

- [ ] **Step 1: 写失败的测试**
  - `session.rs` 改 `history_is_cut_to_the_line_limit_keeping_the_rows_nearest_the_screen`：输入 `HistoryRows { lines: rows, wrapped: vec![0, 3, <最后一行的下标 − 1>], size: 9000 }`，被裁掉前面 `cut` 行以后，断言输出的 `wrapped` 只剩落在保留部分里的、并且都减了 `cut`，`hist == 9000`。
  - `live.rs` 加 `history_marks_wrapped_rows`：80×5 的会话里先 `printf` 一行 200 个 `x`，再 `seq 1 20`，取 `history(&pane, 0, 200)`，断言 `lines` 里那三行 `x` 的头两行下标在 `wrapped` 里、第三行不在，`size > 0`；`before >= size` 时返回空的 `lines` 和正确的 `size`。
- [ ] **Step 2: 跑，确认失败**：`cd rust && cargo test -p rapp-term history` → 编译失败。
- [ ] **Step 3: 实现**：`cmd::history_joined(pane, before, lines)` 和 `cmd::history` 同一个范围，只是 `-p -J`、不带 `-e`；`Tmux::history` 取完 `-e` 的再取 `-J` 的，用 `wrapped_rows` 算标记（转成 `u32`），`size` 就是已经读到的 `history_size`。`Out::History` 加 `#[serde(default)] hist: u32` 和 `#[serde(default, skip_serializing_if = "Vec::is_empty")] wrapped: Vec<u32>`。`history_msg` 裁行规则不变，`wrapped` 跟着裁、重新编号。
- [ ] **Step 4: 跑，确认通过**：`cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term` 全过；clippy 无警告。
- [ ] **Step 5: 提交** `feat(term): history replies carry the history size and wrapped rows`

### Task 4: GUI：终端标识、线消息、标签文字

**Files:**
- Create: `gui/lib/term/term_id.dart`、`gui/lib/term/term_wire.dart`
- Test: `gui/test/term/term_wire_test.dart`

**Interfaces:**
- Produces（`term_id.dart`）：`bool isTermApp(String app)`（前缀 `term:`）；`({String backend, String? host, String name})? parseTermId(String id)`（照 `rust/term/src/id.rs` 的格式 `term:<后端>[@<主机>]:<会话名>`，会话名里可以有冒号）；`String termDisplayName(String name, String? host)` → `host == null ? name : '$name @$host'`。
- Produces（`term_wire.dart`）：
  - `class TermPane { final String id, win, window, title, command; final int cols, rows; final bool dead, active; int get number /* id 去掉 '%' 的整数 */; }`
  - `sealed class TermOut`；`TermHello(int v, String backend)`、`TermPanes(List<TermPane> panes)`、`TermScreen({pane, rev, cols, rows, cx, cy, cursor, alt, full, more, List<(int, String)> lines, int? hist, int? limit, String shape, Set<int> wrapped})`、`TermHistory({pane, before, List<String> lines, int? hist, Set<int> wrapped})`、`TermPasted(bool ok, String? error)`、`TermError(String error)`。
  - `TermOut? parseTermOut(Object? json)`：不认识的 `t`、缺必需字段、类型不对都返回 null；`hist`、`limit` 缺了是 null，`shape` 缺了是 `''`，`wrapped`、`win` 缺了是空，`active` 缺了是 false。
  - 编码：`Map<String, Object?> viewMsg(String? pane, int cols, int rows)`、`ackMsg(int rev)`、`historyReq(String pane, int before, int lines)`、`refitMsg(String pane, int cols, int rows)`（字段名照 `proto.rs` 的 `In`）。
  - `Map<String, String> tabLabels(List<TermPane> panes)`：面板 id → 标签文字（规则见上文“本计划替设计定下的事”）；按 `win` 分窗口，`win` 为空（旧设备）时按 `window` 名分。

- [ ] **Step 1: 写失败的测试**

```dart
test('term ids parse once, names with colons kept', () {
  expect(parseTermId('term:tmux@gpu1:a:b'), (backend: 'tmux', host: 'gpu1', name: 'a:b'));
  expect(parseTermId('term:tmux:work')?.host, isNull);
  expect(parseTermId('com.apple.Terminal'), isNull);
  expect(isTermApp('term:tmux:work'), isTrue);
  expect(termDisplayName('train', 'gpu1'), 'train @gpu1');
});
test('a screen from an old device parses with defaults', () {
  final m = parseTermOut({'t': 'screen', 'pane': '%1', 'rev': 3, 'cols': 80, 'rows': 2, 'cx': 0, 'cy': 0,
      'cursor': true, 'alt': false, 'full': true, 'more': false, 'lines': [[0, 'a'], [1, 'b']]}) as TermScreen;
  expect((m.hist, m.limit, m.shape, m.wrapped), (null, null, '', <int>{}));
  expect(m.lines, [(0, 'a'), (1, 'b')]);
});
test('bad messages are null, not exceptions', () {
  expect(parseTermOut({'t': 'screen', 'pane': '%1'}), isNull);
  expect(parseTermOut({'t': 'nope'}), isNull);
  expect(parseTermOut('x'), isNull);
});
test('tab labels number windows and panes from 1', () {
  TermPane p(String id, String win, String cmd, {bool dead = false}) => TermPane(id: id, win: win, window: 'w',
      title: '', command: cmd, cols: 80, rows: 24, dead: dead, active: false);
  expect(tabLabels([p('%1', '@1', 'claude'), p('%2', '@2', 'nvim'), p('%3', '@2', 'logs', dead: true)]),
      {'%1': '1 claude', '%2': '2.1 nvim', '%3': '2.2 logs · 已退出'});
});
test('messages to the worker use the wire names', () {
  expect(viewMsg('%1', 120, 40), {'t': 'view', 'pane': '%1', 'cols': 120, 'rows': 40});
  expect(historyReq('%1', 500, 500), {'t': 'history', 'pane': '%1', 'before': 500, 'lines': 500});
});
```

  另加一条：`history`、`panes`（含 `win`、`active`）、`pasted`、`error`、`hello` 各解析一次，字段都对。
- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/term_wire_test.dart` → 找不到文件。
- [ ] **Step 3: 实现** 两个文件。
- [ ] **Step 4: 跑，确认通过**：同上命令全过；`flutter analyze` 无问题。
- [ ] **Step 5: 提交** `feat(gui): terminal ids and wire messages`

### Task 5: GUI：字宽和颜色转义

**Files:**
- Create: `gui/lib/term/char_width.dart`、`gui/lib/term/sgr.dart`
- Test: `gui/test/term/sgr_test.dart`

**Interfaces:**
- Produces（`char_width.dart`）：`int cellWidth(int rune)`：组合用的字符（U+0300–036F、U+1AB0–1AFF、U+1DC0–1DFF、U+20D0–20FF、U+FE20–FE2F、U+200B–200F、U+FE00–FE0F）是 0；东亚宽字和全角（U+1100–115F、U+2E80–303E、U+3041–33FF、U+3400–4DBF、U+4E00–9FFF、U+A000–A4CF、U+AC00–D7A3、U+F900–FAFF、U+FE30–FE4F、U+FF00–FF60、U+FFE0–FFE6、U+1F300–1F64F、U+1F900–1F9FF、U+20000–2FFFD、U+30000–3FFFD）是 2；其余（含框线、模糊宽度的字符）是 1。用排好序的区间表二分查找。
- Produces（`sgr.dart`）：
  - `class TermStyle { const TermStyle({this.fg = -1, this.bg = -1, this.flags = 0}); final int fg, bg, flags; }`，颜色编码：`-1` 默认，`0–255` 调色板，`0x1000000 | rgb` 真彩色；`flags` 位：`bold=1, dim=2, italic=4, underline=8, reverse=16, strike=32`（常量放在同文件）。`==`、`hashCode` 按三个字段。
  - `class TermCell { final String ch; final int width; final TermStyle style; }`（宽字符一格存一个 `width == 2` 的 cell，后一列不另存；组合字符并进前一个 cell 的 `ch`）。
  - `class TermLine { final List<TermCell> cells; final String text; int get columns; }`，`text` 是去掉转义的纯文字。
  - `TermLine parseRow(String row)`：每行从默认样式开始（G0 实测）。认：`0`、`1`、`2`、`3`、`4`（含 `4:x`，`4:0` 是关）、`7`、`9`、`22`、`23`、`24`、`27`、`29`、`30–37`、`38;5;n`、`38;2;r;g;b`（及冒号写法 `38:2::r:g:b`、`38:5:n`）、`39`、`40–47`、`48;…`、`49`、`90–97`、`100–107`；别的 CSI、OSC（含 OSC 8 超链接）跳过不报错。

- [ ] **Step 1: 写失败的测试**

```dart
test('wide characters take two cells, box drawing one', () {
  final l = parseRow('中文ab│x');
  expect(l.cells.map((c) => (c.ch, c.width)).toList(),
      [('中', 2), ('文', 2), ('a', 1), ('b', 1), ('│', 1), ('x', 1)]);
  expect(l.columns, 8);
  expect(cellWidth(0x1F600), 2);
  expect(cellWidth(0x0301), 0);
});
test('a combining mark joins the cell before it', () {
  expect(parseRow('éx').cells.map((c) => c.ch).toList(), ['é', 'x']);
});
test('colours: 16, 256, truecolor, and reset', () {
  final l = parseRow('\x1b[31ma\x1b[38;5;196mb\x1b[38;2;1;2;3mc\x1b[39md\x1b[44;1me\x1b[0mf');
  expect(l.cells.map((c) => c.style.fg).toList(), [1, 196, 0x1000000 | 0x010203, -1, -1, -1]);
  expect(l.cells[4].style, const TermStyle(bg: 4, flags: bold));
  expect(l.cells[5].style, const TermStyle());
  expect(l.text, 'abcdef');
});
test('attributes switch on and off', () {
  final l = parseRow('\x1b[1;2;3;4;7;9ma\x1b[22;23;24;27;29mb\x1b[4:3mc\x1b[4:0md\x1b[94;103me');
  expect(l.cells[0].style.flags, bold | dim | italic | underline | reverse | strike);
  expect(l.cells[1].style.flags, 0);
  expect((l.cells[2].style.flags & underline, l.cells[3].style.flags & underline), (underline, 0));
  expect((l.cells[4].style.fg, l.cells[4].style.bg), (12, 11));
});
test('other escapes are skipped', () {
  expect(parseRow('\x1b]8;;http://x\x1b\\ln\x1b]8;;\x1b\\\x1b[?25lk').text, 'lnk');
});
```

- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/sgr_test.dart`。
- [ ] **Step 3: 实现** 两个文件。
- [ ] **Step 4: 跑，确认通过**；`flutter analyze` 无问题。
- [ ] **Step 5: 提交** `feat(gui): terminal row parser with cell widths`

### Task 6: GUI：终端配色

**Files:**
- Create: `gui/lib/term/term_palette.dart`
- Test: `gui/test/term/term_palette_test.dart`

**Interfaces:**
- Consumes: `RappTheme`、`RappTokens`（`gui/lib/ui/tokens.dart`）；任务 5 的颜色编码。
- Produces：`double contrastRatio(Color a, Color b)`（WCAG 相对亮度）；`class TermPalette { final Color fg, bg; final List<Color> base16; Color index(int n); Color resolve(int code, {required bool foreground}); }`（`code == -1` 时前景用 `fg`、背景用 `bg`）；`TermPalette termPaletteFor(RappTheme theme, RappTokens t)`（`fg = t.text`、`bg = t.bg`，16 色每套主题一组，具体值由实现定）。256 色：16–231 是 6×6×6 立方，分量 `[0, 95, 135, 175, 215, 255]`；232–255 是灰 `8 + 10 * i`。

- [ ] **Step 1: 写失败的测试**

```dart
for (final theme in RappTheme.values) {
  test('base colours 1–14 read on the $theme background', () {
    final t = tokensFor(theme); // gui/lib/ui/tokens.dart:169
    final p = termPaletteFor(theme, t);
    for (var i = 1; i <= 14; i++) {
      expect(contrastRatio(p.base16[i], t.bg), greaterThanOrEqualTo(4.5), reason: 'colour $i');
    }
    expect((p.resolve(-1, foreground: true), p.resolve(-1, foreground: false)), (t.text, t.bg));
  });
}
test('the 256 table', () {
  final p = termPaletteFor(RappTheme.matrix, tokensFor(RappTheme.matrix));
  expect(p.index(196), const Color(0xFFFF0000));
  expect(p.index(232), const Color(0xFF080808));
  expect(p.resolve(0x1000000 | 0x102030, foreground: true), const Color(0xFF102030));
});
```

- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/term_palette_test.dart`。
- [ ] **Step 3: 实现**；16 色在每套主题上先按原型 Tweaks 里那组示例取，不够 4.5:1 的调亮（深底）或调暗（浅底）到够为止。
- [ ] **Step 4: 跑，确认通过**；`flutter analyze`。
- [ ] **Step 5: 提交** `feat(gui): terminal palettes per theme`

### Task 7: GUI：网格模型（屏、历史、往上翻）

**Files:**
- Create: `gui/lib/term/term_model.dart`
- Test: `gui/test/term/term_model_test.dart`

**Interfaces:**
- Consumes: 任务 4 的 `TermScreen`、`TermHistory`；任务 5 的 `TermLine`、`parseRow`。
- Produces：

```dart
/// 统一的行坐标 y：y >= 0 是屏幕第 y 行；y < 0 是历史，-1 是紧挨屏幕上面那一行。
class TermModel extends ChangeNotifier {
  String? pane;                 // 当前看的面板；别的面板的屏只回 ack，不用
  int cols, rows, cx, cy; bool cursor, alt; String shape;
  int? hist, limit;             // 最近一屏里那边的历史总行数、上限；旧设备是 null
  List<TermLine> get screen;
  double offset;                // 从底部往上翻了几行，0 = 最新
  bool newOutput;               // 翻在历史里时又有了输出
  bool historyTop;              // 已经取到最旧的一行
  String? note;                 // 那边最近一条 error 的原文（舞台上显示 3 秒）
  void expect(String pane);     // 舞台发了 view：之后这个面板的屏才用；换了面板就清历史、offset 归 0
  int? apply(TermScreen m);     // 一片屏幕消息；是最后一片（more == false）时返回要回 ack 的 rev，否则 null
  void applyHistory(TermHistory m);
  ({int before, int lines})? wantHistory(); // 下一批要取的；没有或已有一个在途时 null；调用即记为在途
  TermLine? lineAt(int y);      // 没取到的历史行是 null
  bool wrappedAt(int y);        // 这一行的下一行是不是它折下来的
  int get scrollMax;            // 能往上翻的行数：hist（旧设备：已知的历史行数，没到顶再加 1）
  void scrollBy(double rows);   // 夹在 [0, scrollMax]
  void toBottom();              // offset = 0、newOutput = false
  void Function(int d)? onShift; // 有 d 行移进了历史（选区跟着移，任务 8）
}
```

  规则（照设计 H1、H2）：
  - 一个更新的几片攒在一起，最后一片到了才换屏：`full` 时从空白屏开始，否则在上一屏上替换这些行。尺寸（`cols`/`rows`）变了：清历史、`offset` 归 0。
  - 移进历史的行数 d：新旧任一屏是备用屏幕、或没有旧屏、或尺寸变了，d = 0；`hist` 涨了，d = 新 − 旧；新旧 `hist` 都等于 `limit`（历史满了），d = 最小的 k（1 ≤ k < rows），使新屏的第 0…rows−k−1 行和旧屏的第 k…rows−1 行文字一样、且其中至少一行不是空的；找不到就是 0。
  - 移进的 d 行放到历史最前面：新屏和旧屏按 d 对得上时，用旧屏最上面 d 行填，否则是 null（看到时再取）；历史满时同时去掉最旧的 d 行。d > 0 时调 `onShift(d)`。
  - `offset > 0` 时：`offset += d`（画面不动，H2）；这一屏有任何一行变了就 `newOutput = true`。
  - `wantHistory`：看到的最上一行（`-(offset + rows)`）离已取到的最旧一行不到 `rows` 行、且没到顶 → `(before: 已取行数, lines: 500)`；看到的范围里有 null 行 → 从最靠近屏幕的那个 null 起取那一段（最多 500）。
  - `applyHistory`：`lines[k]` 放到历史下标 `before + adj + (len − 1 − k)`，`adj = (model.hist − m.hist)`（两边都有时，否则 0），下标 < 0 的丢掉；`lines` 为空或放完后已取行数 ≥ `hist` → `historyTop = true`。不是当前面板的回答丢掉。回答到了清“在途”。

- [ ] **Step 1: 写失败的测试**（用一个小工具 `TermScreen scr(List<String> rows, {int rev, int? hist, int? limit, bool full = true, bool more = false, String pane = '%1'})`）

```dart
test('parts are put together and only the last one is acked', () {
  final m = TermModel()..expect('%1');
  expect(m.apply(scr(['a', 'b'], rev: 1, more: true)), isNull);
  expect(m.screen.map((l) => l.text), isEmpty); // 还没换屏
  expect(m.apply(scrRows({1: 'B'}, rev: 1, full: false)), 1);
  expect(m.screen.map((l) => l.text), ['a', 'B']);
});
test('a screen of another pane is acked and ignored', () {
  final m = TermModel()..expect('%2');
  expect(m.apply(scr(['x'], rev: 4, pane: '%1')), 4);
  expect(m.screen, isEmpty);
});
test('new output does not move the view while reading history', () {
  final m = TermModel()..expect('%1');
  m.apply(scr(['1', '2', '3'], rev: 1, hist: 10, limit: 2000));
  m.scrollBy(5);
  m.apply(scr(['2', '3', '4'], rev: 2, hist: 11, limit: 2000));
  expect((m.offset, m.newOutput), (6.0, true));
  expect(m.lineAt(-1)?.text, '1'); // 移进历史的那一行从旧屏来
});
test('a full history still shifts by the overlap', () {
  final m = TermModel()..expect('%1');
  final shifts = <int>[];
  m.onShift = shifts.add;
  m.apply(scr(['a', 'b', 'c', 'd'], rev: 1, hist: 2000, limit: 2000));
  m.scrollBy(10);
  m.apply(scr(['c', 'd', 'e', 'f'], rev: 2, hist: 2000, limit: 2000));
  expect((shifts, m.offset), ([2], 12.0));
  expect([m.lineAt(-2)?.text, m.lineAt(-1)?.text], ['a', 'b']);
});
test('history is asked for in batches and placed above the screen', () {
  final m = TermModel()..expect('%1');
  m.apply(scr(['s'], rev: 1, hist: 600, limit: 2000));
  m.scrollBy(1);
  expect(m.wantHistory(), (before: 0, lines: 500));
  expect(m.wantHistory(), isNull); // 一个在途
  m.applyHistory(TermHistory(pane: '%1', before: 0, lines: ['h2', 'h1'], hist: 600, wrapped: {}));
  expect([m.lineAt(-1)?.text, m.lineAt(-2)?.text], ['h1', 'h2']);
});
test('an old device without hist still scrolls until the top', () {
  final m = TermModel()..expect('%1');
  m.apply(scr(['s'], rev: 1));
  expect(m.scrollMax, 1);
  m.scrollBy(1);
  m.applyHistory(TermHistory(pane: '%1', before: 0, lines: ['h'], hist: null, wrapped: {}));
  m.applyHistory(TermHistory(pane: '%1', before: 1, lines: [], hist: null, wrapped: {}));
  expect((m.historyTop, m.scrollMax), (true, 1));
});
test('a size change clears history and returns to the bottom', () { … 断言 offset == 0、lineAt(-1) == null });
test('alternate screen: nothing moves into history', () { … alt: true 的两屏之间 hist 涨了，onShift 没被调 });
```

- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/term_model_test.dart`。
- [ ] **Step 3: 实现** `TermModel`。每行用 `parseRow` 解析一次，行没变（字符串相同）就沿用原来的 `TermLine` 对象——任务 11 的画面缓存靠对象是否相同判断要不要重画（D6）。
- [ ] **Step 4: 跑，确认通过**；`flutter analyze`。
- [ ] **Step 5: 提交** `feat(gui): terminal grid model with local scrollback`

### Task 8: GUI：选区、取文字、选词、网址

**Files:**
- Create: `gui/lib/term/term_select.dart`
- Test: `gui/test/term/term_select_test.dart`

**Interfaces:**
- Consumes: 任务 7 的统一行坐标、`lineAt`、`wrappedAt`；任务 5 的 `TermLine`。
- Produces：

```dart
class TermPoint { const TermPoint(this.y, this.x); final int y, x; } // x 是列
class TermSelection {
  TermSelection(this.anchor, this.head, {this.block = false, required this.snapshot});
  final TermPoint anchor; TermPoint head; final bool block; // block：⌥ 拖的矩形
  final Map<int, String> snapshot; // 选区里每一行当时的纯文字
}
typedef LineAt = TermLine? Function(int y);
typedef WrappedAt = bool Function(int y);
TermSelection select(TermPoint a, TermPoint b, LineAt line, {bool block = false});
TermSelection? shifted(TermSelection s, int d, LineAt line); // y 都减 d；有一行文字和 snapshot 不同就返回 null（C4）
String selectionText(TermSelection s, LineAt line, WrappedAt wrapped);
int selectedChars(String text);                 // 去掉换行后的字数（按 rune）
(int, int) wordAt(TermLine line, int x);        // [起, 止) 列
(TermPoint, TermPoint) lineAtPoint(int y, WrappedAt wrapped, LineAt line); // 三击：连同折行的整行
class LinkSpan { final int y, x0, x1; final String url; }
List<LinkSpan> linksIn(int fromY, int toY, LineAt line, WrappedAt wrapped);
```

  规则：取文字时宽字符按它的起始列算进不进选区；折行（`wrapped(y)`）接着下一行、不加换行；不是折行的行尾去掉空格后加 `\n`，最后一行不加；矩形选区每行都换行、不接折行。词的字符 = 不是空白、也不是 `"'\`()[]{}<>|│┃` 之一，所以路径和网址算一个词。网址 = `https?://` 起、到空白或 `<>"'\`` 止，在接起来的整行上找（跨折行的网址整个算一条，分到各行各出一个 `LinkSpan`），末尾的 `.,;:!?` 去掉，末尾的 `)` 不配对时去掉。

- [ ] **Step 1: 写失败的测试**（用 `Map<int, String>` 和 `Set<int>` 造 `LineAt`、`WrappedAt`）

```dart
test('a wrapped long command copies as one line, trailing spaces trimmed', () {
  final rows = {-1: 'cargo build --rel', 0: 'ease   ', 1: 'done  '};
  final s = select(const TermPoint(-1, 0), const TermPoint(1, 5), at(rows));
  expect(selectionText(s, at(rows), (y) => y == -1), 'cargo build --release\ndone');
});
test('wide characters count by their first column', () {
  final rows = {0: '中文ab'};
  expect(selectionText(select(const TermPoint(0, 1), const TermPoint(0, 4), at(rows)), at(rows), (_) => false), '中文a');
});
test('a block selection takes the same columns of every row', () { … '0123' / 'abcd' 选列 1–2 → '12\nbc' });
test('the selection follows a shift and drops when its text changed', () {
  final before = {0: 'keep', 1: 'x'};
  final s = select(const TermPoint(0, 0), const TermPoint(0, 3), at(before));
  expect(shifted(s, 1, at({-1: 'keep'}))?.anchor.y, -1);
  expect(shifted(s, 1, at({-1: 'other'})), isNull);
});
test('paths and urls are one word', () {
  final l = parseRow('see /usr/local/bin/tmux now');
  expect(wordAt(l, 8), (4, 23));
});
test('a url across a wrap is one link, trailing dot dropped', () {
  final rows = {0: 'go https://example.com/a', 1: 'b/c. ok'};
  final links = linksIn(0, 1, at(rows), (y) => y == 0);
  expect(links.map((l) => (l.y, l.x0, l.x1, l.url)).toList(),
      [(0, 3, 24, 'https://example.com/ab/c'), (1, 0, 3, 'https://example.com/ab/c')]);
});
test('selected characters exclude newlines', () => expect(selectedChars('中文\nab'), 4));
```

- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/term_select_test.dart`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑，确认通过**；`flutter analyze`。
- [ ] **Step 5: 提交** `feat(gui): terminal selection, words and links`

### Task 9: GUI：`TermLink` 和 `TermSessionPort`

**Files:**
- Create: `gui/lib/term/term_link.dart`、`gui/lib/term/term_session_port.dart`
- Modify: `gui/test/fakes.dart`（加 `FakeTermSessionPort`）
- Test: `gui/test/term/term_session_port_test.dart`

**Interfaces:**
- Consumes: 任务 4、7；`SessionPort`、`SessionEvent`、`StartArgs`、`RemoteWindow`（`gui/lib/embed/session_port.dart`）。
- Produces（`term_link.dart`）：

```dart
typedef Dial = Future<Socket> Function(String host, int port);
class TermLink {
  static Future<TermLink> connect(int port, String token, {Dial? dial}); // 连 127.0.0.1:port，先写 token + '\n'
  Stream<TermOut> get messages;   // 按行 UTF-8 解码；超过 65536 字节的行、解析不了的行丢掉
  void send(Map<String, Object?> m); // jsonEncode + '\n'
  int takeBytes();                // 上次调用以来收到的字节数
  Future<void> get done;          // 连接结束（含出错）
  void close();
}
```

- Produces（`term_session_port.dart`）：

```dart
class TermSessionPort extends SessionPort {
  TermSessionPort({Dial? dial, Duration trafficEvery = const Duration(seconds: 1)});
  bool owns(Object sid);          // invoke('start') 一进来就为 true，直到 close
  TermModel? model(Object sid);
  List<TermPane> panes(Object sid);
  TermPane? pane(Object sid, int window); // window = TermPane.number
  void view(Object sid, int window, int cols, int rows); // 发 view、model.expect；同样的参数不重发
  void refit(Object sid);         // 用最近一次 view 的参数发 refit
  void fetchHistory(Object sid);  // model.wantHistory() 有就发 history 请求
  @override Stream<SessionEvent> get events; // 一个 broadcast StreamController
  @protected void emit(SessionEvent e);
  @override bool get supportsDetach => false;
}
```

  `invoke` 只认：`start`（参数照 `StartArgs` 的 `sid`、`port`、`token`；连不上抛异常，`_connect` 照现有的失败处理）、`close`（关连接，发 `ClosedEvent(sid, 'closed')`，和 `LinuxSessionPort` 一样）；别的方法名返回 null、什么也不做。收到的消息：
  - `panes` → `WindowsEvent`：每个面板一个 `RemoteWindow(id: number, parent: 0, kind: WindowKind.normal, title: tabLabels(...)[id], rect: Rect.zero, titleBar: 0, resizable: false, focused: active, texture: null, visible: Rect.zero)`；第一次收到后再发 `ReadyEvent(sid, <当前面板的命令>)`。
  - `screen` → `model.apply`，返回 rev 就发 `ackMsg`；数屏数。
  - `history` → `model.applyHistory`，然后 `fetchHistory`。
  - `error`：`session ended` → 按断开处理（reason `session ended`）；别的写进 `model.note`。
  - `pasted`、`hello` G1 不用。
  - 每 `trafficEvery` 发一次 `TrafficEvent(sid, link.takeBytes(), 屏数)`。
  - 连接结束且不是 `close` 引起的 → `DisconnectedEvent(sid, 'connection lost')`，只发一次，模型留着（画面停在最后一屏）。
- Produces（`fakes.dart`）：`class FakeTermSessionPort extends TermSessionPort`：`invoke` 记下 `(method, args)` 到 `calls`，`start` 时 `owns` 为 true、不连网；`view`、`refit`、`fetchHistory` 也记进 `calls`；外加 `TermModel` 可由测试直接摆数据。

- [ ] **Step 1: 写失败的测试**（真的本机 `ServerSocket` 当假 worker，用 `test()` 不用 `testWidgets`）

```dart
test('start sends the token, answers screens with acks, and reports panes and traffic', () async {
  final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final got = <String>[];
  srv.listen((s) {
    s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(got.add);
    s.write('${jsonEncode({'t': 'hello', 'v': 1, 'backend': 'tmux'})}\n');
    s.write('${jsonEncode({'t': 'panes', 'panes': [pane('%3', '@1', 'claude', active: true)]})}\n');
    s.write('${jsonEncode(screenJson('%3', rev: 7))}\n');
  });
  final port = TermSessionPort(trafficEvery: const Duration(milliseconds: 50));
  final events = <SessionEvent>[];
  port.events.listen(events.add);
  await port.start(StartArgs(1, srv.port, 'tk', 'x', 0, 'x'));
  expect(port.owns(1), isTrue);
  port.view(1, 3, 80, 24);
  await pumpUntil(() => got.contains(jsonEncode({'t': 'ack', 'rev': 7})));
  expect(got.first, 'tk');
  final w = events.whereType<WindowsEvent>().single.windows.single;
  expect((w.id, w.title, w.focused), (3, '1 claude', true));
  expect(events.whereType<ReadyEvent>().single.appName, 'claude');
  await pumpUntil(() => events.whereType<TrafficEvent>().any((e) => e.bytes > 0));
});
test('a line split in the middle of a Chinese character is put back together', () async {
  … 假 worker 把一条含「中文」的 screen 行按字节切成两半分两次写，中间 flush；断言 model.screen 第一行 text 含「中文」
});
test('a line over 64 KiB is dropped and the link stays up', () async {
  … 先写一行 70000 字节的垃圾，再写一条正常的 screen；断言收到那条 screen 的 ack，没有 DisconnectedEvent
});
test('the worker going away is one DisconnectedEvent; close is one ClosedEvent', () async { … });
test('a screen for the pane switched away from is still acked', () async {
  … view(1, 3, …) 之后 view(1, 4, …)，假 worker 再发一条 %3 的 screen rev 9；断言收到 ack 9
});
test('calls for app sessions are ignored', () async {
  … port.resize(1, 3, 10, 10); port.selectInput(1, 'x'); 不抛、什么也不发
});
```

- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/term_session_port_test.dart`。
- [ ] **Step 3: 实现** 两个文件和 `FakeTermSessionPort`。
- [ ] **Step 4: 跑，确认通过**；`flutter analyze`。
- [ ] **Step 5: 提交** `feat(gui): TermSessionPort speaks the terminal wire protocol`

### Task 10: GUI：按格子排一行、框线

**Files:**
- Create: `gui/lib/term/term_layout.dart`
- Test: `gui/test/term/term_layout_test.dart`

**Interfaces:**
- Consumes: 任务 5 的 `TermLine`、`TermCell`。
- Produces：

```dart
class TermMetrics {
  static TermMetrics measure(TextStyle style); // cellW = 'M' 的宽（不取整），cellH = 'M' 一行的高向上取整
  final double cellW, cellH; final TextStyle style;
}
enum GlyphKind { run, single, box }
class GlyphRun { final int col, cols; final String text; final TermStyle style; final GlyphKind kind; }
List<GlyphRun> layoutRow(TermLine line);  // 同样式、宽 1、码位 < U+2500 且非框线的连续字合成一个 run；宽 2 和其他非 ASCII 字一个 single；U+2500–257F、U+2580–259F 是 box
bool drawBoxChar(Canvas c, int rune, Rect cell, Color color); // 画出来返回 true；不认识的返回 false，调用方回落到字体
```

  `drawBoxChar` 认：细、粗、双线的横竖、四角、T 形、十字（`─│┌┐└┘├┤┬┴┼` 及粗、双线的同类），圆角 `╭╮╯╰` 当直角画，虚线 `┄┆┈┊` 当实线画，`▀▄█▌▐` 和 `░▒▓`（用 25%、50%、75% 透明度的块）。线宽：细 = `max(1, cellW / 8)` 取整到设备像素，粗 = 2 倍；线居中，横线贯穿整个 cell 宽、竖线贯穿整个 cell 高，这样上下左右接得上（D1）。

- [ ] **Step 1: 写失败的测试**

```dart
test('a mixed row is laid out by column', () {
  final runs = layoutRow(parseRow('中文ab│x'));
  expect(runs.map((r) => (r.col, r.cols, r.text, r.kind)).toList(), [
    (0, 2, '中', GlyphKind.single), (2, 2, '文', GlyphKind.single),
    (4, 2, 'ab', GlyphKind.run), (6, 1, '│', GlyphKind.box), (7, 1, 'x', GlyphKind.run),
  ]);
});
test('a style change splits a run', () {
  expect(layoutRow(parseRow('ab\x1b[31mcd')).map((r) => r.text).toList(), ['ab', 'cd']);
});
test('box lines reach the cell edges', () async {
  // 在 10×20 的 cell 里画 '─' 和 '│'，转成图片取像素：横线最左、最右一列的中间那一行是线的颜色；竖线顶行、底行的中间一列是
});
test('unknown box runes fall back to the font', () {
  expect(drawBoxChar(Canvas(PictureRecorder()), 0x2571 /* ╱ */, const Rect.fromLTWH(0, 0, 10, 20), Colors.white), isFalse);
});
```

- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/term_layout_test.dart`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑，确认通过**；`flutter analyze`。
- [ ] **Step 5: 提交** `feat(gui): cell layout and drawn box characters`

### Task 11: GUI：`TermStage`

**Files:**
- Create: `gui/lib/term/term_painter.dart`、`gui/lib/term/term_stage.dart`
- Test: `gui/test/term/term_stage_test.dart`

**Interfaces:**
- Consumes: 任务 6、7、8、9、10；`MainState`（只用 `blurPicture()`、`prefs.theme`）、`RemoteSession`（`sid`、`currentWindow`、`addListener`）。
- Produces：`TermStage({Key? key, required MainState state, required RemoteSession session, required TermSessionPort port, int? attached})`；`attached` 是设备面板会话表里这一行的 `attached`，不知道时 null。键：横幅 `Key('term-latest')`，复制条 `Key('term-copy')`，缩小提示 `Key('term-scaled')`，画布 `Key('term-grid')`。`TermPainter`（`CustomPainter`）：每行一张 `ui.Picture`，按 `(TermLine 对象, cellW, 调色板)` 缓存，`shouldRepaint` 只看模型的版本号；光标、选区、网址下划线画在行之上、不进缓存。

  行为：
  - **尺寸**（Z1）：`LayoutBuilder` 里 `cols = max(2, floor(w / cellW))`、`rows = max(2, floor(h / cellH))`；`(session.currentWindow, cols, rows)` 和上次发的不同就 `port.view`——第一次立刻，之后停手 0.3 秒。`currentWindow` 为 null（还没有面板表）时不发。
  - **缩小**：模型的 `cols × rows` 超出舞台时等比缩小、左上对齐，并显示 `term-scaled` 那行字（文字见上文“本计划替设计定下的事”；N 由 `attached` 参数算）。
  - **画**：照 Global Constraints 里的画面规则；`offset` 不是整数时按小数行偏移画（平滑滚动）；最上面露出的历史行是 null 时画空行。光标：`cursor` 为真、且光标那一行在视野内才画；焦点在舞台时按 `shape` 画实心块（`""`/`block`）、2 像素竖线（`bar`）或 2 像素下划线（`underline`），否则 1 像素空心框。
  - **滚动**（H1、H2）：`PointerScrollEvent` 的 `dy / cellH` 行；触控板 `PointerPanZoomUpdateEvent` 的 `panDelta.dy / cellH` 行，抬手时按速度用 `FrictionSimulation(0.135, offset, v)` 接着滚（`Ticker` 驱动）；备用屏幕时不滚（H5 是 G3）。`offset` 变了、模型更新了都调 `port.fetchHistory(sid)`。
  - **横幅**（H2）：`offset > 0` 时底部居中显示「正在看历史 · 回到最新」，`newOutput` 时「有新输出 · 回到最新」；点它 `model.toBottom()`。H3 的“发键回到底部”G1 没有发键，留给 G2。
  - **选区**（C1–C5）：左键按下定锚点、拖动定头；两次点击在 500 ms、4 像素内算双击（选词）、三次算三击（选行）；Shift+点击把头移到点击处；按住 ⌥（Alt）拖是矩形选区；拖到舞台上、下边外时每 50 ms 滚一行。模型的 `onShift` → `shifted`，返回 null 就清选区；模型别的更新也用 `shifted(s, 0, …)` 校一次。
  - **复制**（C2、C3）：舞台有焦点时 macOS ⌘C、其他 Ctrl+Shift+C → `Clipboard.setData(selectionText(...))`；有选区时左上角显示「选中了 N 个字 · 复制到本机」（N = `selectedChars`），点它同样复制，之后这条显示「已复制」1 秒。Esc 清选区。别的键 `KeyEventResult.ignored`。
  - **网址**（L1）：`linksIn` 给视野里的网址画下划线；macOS ⌘+点击、其他 Ctrl+点击 → `openUrl(url)`（同文件的顶层函数，`Process.start`）；按着这个修饰键悬停在网址上时鼠标是手形，平时是文字光标。
  - **焦点**：点一下舞台 → 自己的 `FocusNode.requestFocus()` 并 `state.blurPicture()`。
  - `model.note` 有值时在底部左边显示 3 秒。

- [ ] **Step 1: 写失败的测试**（`testWidgets`，用 `FakeTermSessionPort`，给它的模型直接 `apply` 屏幕；`wrap()` 来自 `test/ui/helpers.dart`）

```dart
testWidgets('the stage asks for the size it can show, once, then after a 0.3 s pause', (t) async {
  // 800×480 的舞台；期望 view(1, 3, floor(800/cellW), floor(480/cellH))；改成 900 宽，0.2 s 时还没发新的，0.35 s 时发了
});
testWidgets('new output while reading history keeps the view and changes the banner', (t) async {
  // 摆一屏 + hist；滚轮往上 3 行 → 出现「正在看历史 · 回到最新」；再 apply 一屏 hist + 1 → 文字变成「有新输出 · 回到最新」，
  // 屏上最上一行的文字不变；点横幅 → 横幅消失，model.offset == 0
});
testWidgets('drag selects, the chip counts characters, ⌘C copies one joined line', (t) async {
  // 第 0 行折行到第 1 行；从 (0,0) 拖到 (1,3)；出现「选中了 N 个字 · 复制到本机」；
  // 用 TestDefaultBinaryMessenger 截 Clipboard.setData，按 ⌘C（非 macOS 测试平台用 Ctrl+Shift+C），断言剪贴板是接起来的一行
});
testWidgets('a selection survives a refresh that does not touch its rows', (t) async { … 改别的行，选区还在；改选中的行，选区没了 });
testWidgets('a pane larger than the stage is scaled down with the note', (t) async {
  // 模型 200×60，舞台小；找到 Key('term-scaled')，文字含「原样缩小显示」和「200×60」
});
testWidgets('a scroll in the alternate screen does nothing', (t) async { … offset 仍是 0，没有横幅 });
```

  另：一个不进 CI 的性能检查（`@Tags(['perf'])`，计划里只跑一次）：200×60 的满屏、每帧换 5 行、连续 120 帧，记录 `TermPainter.paint` 的平均耗时；结论写进最后一个任务的提交信息。
- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/term_stage_test.dart`。
- [ ] **Step 3: 实现** `TermPainter`、`TermStage`。
- [ ] **Step 4: 跑，确认通过**；`flutter analyze`。
- [ ] **Step 5: 提交** `feat(gui): TermStage draws the grid, scrolls, selects and copies`

### Task 12: GUI：接进主界面（端口、舞台、顶栏、标签、会话列表、菜单）

**Files:**
- Modify: `gui/lib/main.dart`、`gui/lib/ui/main_state.dart`、`gui/lib/embed/window_tabs.dart`、`gui/lib/embed/remote_session.dart`、`gui/lib/ui/stage.dart`、`gui/lib/ui/top_bar.dart`、`gui/lib/ui/session_model.dart`、`gui/lib/ui/sessions_tab.dart`、`gui/lib/embed/stream_menu.dart`
- Test: `gui/test/term/term_main_test.dart`；`gui/test/embed/window_tabs_test.dart` 加一条

**Interfaces:**
- Consumes: 任务 4 `isTermApp`；任务 9 `TermSessionPort`、`FakeTermSessionPort`；任务 11 `TermStage`。
- Produces：
  - `MainState({…, TermSessionPort? termPort})`、`final TermSessionPort? termPort`；`SessionPort? portOf(Object sid) => termPort?.owns(sid) == true ? termPort : port`。`main.dart` 在有原生 `port` 时建 `TermSessionPort()` 传进去（没有原生端口的平台不开终端，Windows 是第二版）。
  - `WindowTabs({this.followNew = true})`：`followNew == false` 时新冒出的窗口不成为当前；第一次有表、或当前的没了时，取 `focused` 的那个，没有就取最近用过的、再没有取第一个。
  - `RemoteSession(…, {bool followNewTabs = true})` 传给 `WindowTabs`。
  - `SessionEntry` 加 `final String? paneTitle`。

  改动：
  - `main_state.dart` 里所有带 sid 的 `port!.` / `port?.` 调用改走 `portOf(sid)`（`init`、`handleKeyEvent` 这类不带 sid 的不动）；构造时 `termPort?.events.listen(_onPortEvent)`，`dispose` 一并取消。
  - `_connect`：`isTermApp(r.app)` 时建 `RemoteSession(…, followNewTabs: false)`，`start` 走 `termPort!.start(...)`；`termPort` 为 null 时按“打开失败”处理，原因写「这台主控台还不能看终端会话」。
  - `_movable(r)` 对终端记录返回 false（换路时不搬，`_swapIfReady` 等的是带画面的窗口，终端没有）；`_openEmbedded` 里已连着的终端记录不调 `raiseDetached`。
  - `stage.dart`：在 `Picture` 那一支之前加一支：`rs != null && state.termPort?.owns(rs.sid) == true && rec.phase == Phase.live && rec.lastSid == null` → `TermStage(state: state, session: rs, port: state.termPort!)`；这一支不叠 `composerLayer`（输入区是 G2）。断开时照旧走 `DisconnectedStage`。
  - `top_bar.dart`：终端会话的标题写 `'<当前面板的命令> · <cur.appName>'`，副标题在原来的后面加 `' · <面板标题>'`（标题为空不加）（T2）；标签芯片 `onClose`、`onSecondaryTap` 都是 null，不显示“已隐藏”芯片；角菜单的 `port` 用 `state.portOf(rs.sid)`。
  - `_entryOf`：终端记录的 `paneTitle` = 当前面板的 `title`；`sessions_tab.dart` 第二行在原文后面加 `' · $paneTitle'`（为空不加）。
  - `stream_menu.dart`：`port is TermSessionPort` 时：流量那一组换成一项「按我的屏幕重排」（`Key('term-refit')`，点了 `port.refit(sid)`）；“会话”一组去掉分离和「放左上角」；本机那几组（剪贴板、远端输入法、输入区、app 配置）和远端菜单都不出现。

- [ ] **Step 1: 写失败的测试**（照 `test/ui/stage_test.dart` 的 `openEmbedded` 写法：`FakeTransport` 回 `opened` 带 `port`、`token`）

```dart
testWidgets('opening a terminal goes through the terminal port and shows TermStage', (t) async {
  // openOrSwitch('111', 'term:tmux:work', 'work') → hub 收到 open embed:true；
  // termPort.calls 里有 start，原生 FakeSessionPort.calls 里没有 start；
  // termPort.emit(WindowsEvent(1, [两个面板])) 之后舞台上是 TermStage，顶栏有「1 claude」「2 logs」两个芯片且没有关闭按钮
});
testWidgets('app-session calls for a terminal sid never reach the native port', (t) async {
  // selectWindow、focus、close 之后原生 port 的 calls 里没有 sid 1
});
testWidgets('the top bar and the session list carry the pane title', (t) async { … 标题「claude · work」，副标题含面板标题 });
testWidgets('the traffic menu of a terminal has refit and no stream presets', (t) async { … 点 term-refit → termPort.calls 有 refit });
testWidgets('the current pane closing moves to another pane and views it', (t) async {
  // WindowsEvent 先有 %3、%4，当前 %3；再来只有 %4 的表 → currentWindow == 4，termPort.calls 里有 view(…, 4, …)
});
testWidgets('a dead pane keeps its screen and says so on the tab', (t) async { … 芯片文字含「已退出」，TermStage 还在 });
```

  `window_tabs_test.dart` 加 `without followNew a new window does not take over, the focused one starts`。
- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/term/term_main_test.dart test/embed/window_tabs_test.dart`。
- [ ] **Step 3: 实现** 上面的改动。
- [ ] **Step 4: 跑，确认通过**：`cd gui && flutter test` 全部（现有的 app 会话测试一条都不能坏）；`flutter analyze`。
- [ ] **Step 5: 提交** `feat(gui): terminal sessions on the main window`

### Task 13: GUI：hub 的终端命令，设备面板的“终端”一组，添加 SSH 主机

**Files:**
- Modify: `gui/lib/hub_client.dart`、`gui/lib/ui/main_state.dart`（`probe`）、`gui/lib/ui/devices_tab.dart`、`gui/lib/ui/stage.dart`（`attached`）
- Test: `gui/test/hub_client_test.dart`（已有就加，没有就建）、`gui/test/ui/devices_tab_test.dart`

**Interfaces:**
- Consumes: 任务 4 `termDisplayName`；hub 的事件（`rust/hub/src/terms.rs`）：`{"event":"terms","id","path","terms":[TermRow],"hosts":[HostRow]}`、`{"event":"terms","id","off":true}`、`{"event":"terms","id","error":"…"}`、`{"event":"term_targets","id","targets":[…]}`；`TermRow` = `{id, host, name, command, panes, attached, activity /*unix 秒*/, dead, unread}`，`HostRow` = `{host /*本机是 null*/, target?, tmux?, error?}`。
- Produces（`hub_client.dart`）：

```dart
class TermRow { final String id, name, command; final String? host; final int panes, attached, activity; final bool dead, unread; }
class TermHost { final String? host, target, tmux, error; }
class TermList { final String id; final String? path, error; final bool off; final List<TermRow> terms; final List<TermHost> hosts; }
final Map<String, TermList> termLists;  // 按设备 id；每个 terms 事件（带不带 req 都）覆盖并 notifyListeners
Future<TermList> terms(String id);       // {'cmd':'terms','id':id} → 'terms'
Future<void> addTermTarget(String id, String name, String target, {String? tmux}); // → 'term_targets'，之后再 terms(id)
Future<void> removeTermTarget(String id, String name);                             // 同上
```

  不带 `req` 的 `terms` 事件（监视流）只更新 `termLists`，**不**拿去兑现在途的请求（现在的 `_take` 会按事件名兑现最早的一个，这里要绕开，不然甲设备的监视事件会被当成乙设备 `terms` 的回答）。
- Produces（`devices_tab.dart`）：在 `_remote` 的 app 列表后面：
  - `termLists[id]` 为 null 或 `off` → 什么都不加（规格 §4：关着就没有这一组）。
  - `error` → 一行「终端：<error>」。
  - 否则标题「终端」，每个 `TermRow` 一行 `_TermRow`：灯和状态字照上文“本计划替设计定下的事”；名字 `termDisplayName(name, host)`；命令；「N 个面板」；按钮 `openVerb(_session(id, row.id)?.lamp, …)`，点了 `state.openOrSwitch(id, row.id, termDisplayName(row.name, row.host))`，`state.hubUsable && state.embeds` 才可点。键：`term-<row.id>`、`open-<row.id>`。
  - `terms` 为空：「这台设备的 tmux 里现在没有会话。」
  - 每个 `host != null` 的 `TermHost` 一行：`<host> · <target>`，有 `error` 时后面写「连不上：<error>」，右边「移除」（`Key('remove-host-<host>')`，点了 `removeTermTarget`）。
  - 最后一个按钮「添加 SSH 主机…」（`Key('add-ssh-host')`），弹对话框：三个输入框「名字」「目标（如 me@gpu1）」「tmux 的路径（可不填）」，按钮「添加」「取消」；添加失败时把 hub 回的错误原文写在对话框里，不关。
- `stage.dart`：给任务 12 加的 `TermStage` 传 `attached:`，从 `state.hub?.termLists[rec.id]?.terms` 里按 `id == rec.app` 找；`devices_tab_test` 之外在 `term_main_test.dart` 加一条：摆了 `termLists`（`attached: 3`）、模型比舞台大时缩小提示写「另有 2 个终端」。
- `MainState.probe`：`apps` 之后 `unawaited(hub!.terms(id).then((_) {}, onError: (_) {}))`。

- [ ] **Step 1: 写失败的测试**
  - `hub_client_test.dart`：`a watch event without req updates the list and does not answer a pending request`（先发 `terms('A')` 不回，再 `emit` 一个不带 req 的 `{'event':'terms','id':'B',…}`，断言 `termLists['B']` 有了、`terms('A')` 的 future 还没完成；再 `emit` 带 req 的 A 的回答，future 完成）；`off and error lists parse`。
  - `devices_tab_test.dart`：`the terminal group lists sessions and opens one`（摆一个 `termLists`，断言出现「终端」、`train @gpu1`、「3 个面板」、「刚刚有输出」/「未读」；点 `open-term:tmux:work` → hub 收到 `open`，`app` 是 `term:tmux:work`）；`no group when terminal sessions are off`；`adding an SSH host sends add_term_target and refreshes`（填三个框点「添加」→ 收到 `{'cmd':'add_term_target','id':…,'name':'gpu1','target':'me@gpu1'}`，`tmux` 空着时不带这个键，然后收到 `terms`）；`a host that cannot be reached says why and can be removed`。
- [ ] **Step 2: 跑，确认失败**：`cd gui && flutter test test/hub_client_test.dart test/ui/devices_tab_test.dart`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑，确认通过**：`cd gui && flutter test` 全部；`flutter analyze`。
- [ ] **Step 5: 提交** `feat(gui): terminal group on the devices panel, SSH hosts`

### Task 14: 收尾和验收

**Files:**
- 不新建代码文件。

- [ ] **Step 1: 全部测试**：`cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test --workspace` 全过、`cargo clippy --workspace --all-targets -- -D warnings` 无警告；`cd gui && flutter analyze` 无问题、`flutter test` 全过；跑一次任务 11 的 `perf` 检查（`flutter test --tags perf test/term/term_stage_test.dart`），记下平均耗时。
- [ ] **Step 2: 本机冒烟**（不动用户正在跑的服务：用 `rust/target` 里新编的 `rapp-term`，对一个独立 socket 的 tmux 起 `rapp-term serve`，按 `rust/term/tests/serve.rs` 的做法连上，看 `screen` 消息里有 `hist`、`wrapped`，`panes` 里有 `win`、`active`）。
- [ ] **Step 3: 列出要用户在真机上验的**（写进交给用户的总结，不自己去停用户的服务）：设计 §8 G1 的三条（中日英混排带框线的表对得齐；滚到历史里时新输出不拽画面；选中一段折行的长命令，复制出来是一行）和规格 §16 T1 里属于“看”的几条（Claude Code 的颜色和光标对；另一个终端同时接着时它的尺寸不变；SSH 主机上的会话出现并能看）。
- [ ] **Step 4: 提交**（只有 Step 1 里因收尾改了东西时才有）`chore: terminal GUI G1 wrap-up`，提交信息里写上 perf 检查的结论。
