# rapp 终端会话界面（G2 介入）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在主控台上不光看、还能介入终端会话：点一下舞台就能打字，键都到那边；写作面板接进终端会话，和 app 会话一样写一段发过去；可开关的按键排；在舞台上粘贴；从设备面板新开终端；标签右边「＋」在会话里新开一个窗口。

**Architecture:** 被控端补键名（Alt、Shift+方向、Ctrl+符号）、`new_window` 一条消息和“空命令就是默认 shell”，`PROTO` 升到 2。主控台：`term_keys.dart` 把本机按键事件译成线上的键名或文字（纯函数）；`TermSessionPort` 补发送（按键、逐字、分片粘贴并等 `pasted`），并实现写作面板用的 `SessionPort` 方法（`composerSend`、`composerPaste`、`key`……），这样 `ComposerPanel`、`RemoteSession` 原样复用；`TermStage` 接键盘；舞台给终端也叠写作面板和按键排。

**Tech Stack:** Rust 2021（`rust/term`、`rust/hub`）；Flutter / Dart（`gui`）。不加新依赖。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-terminal-gui-design.md`（下称“设计”，§ 都指它）。上位规格 `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md`（下称“规格”）。写作面板 `docs/superpowers/specs/2026-11-14-rapp-composer-writing-panel-design.md`（下称“写作面板”）。

**范围：** 设计 §8 的 G2：键盘直通（K1–K4、K6）、写作面板接进来（W1、W2）、按键排（W3–W5）、画面上移（Z2）、在舞台上粘贴（K4）、新开终端、「＋」新开窗口（T3）。**不在这里：** G3（查找 F、位置标记 H4、备用屏幕滚动 H5、字号 Z3–Z5、响铃 N2、全景缩略），触屏。

## 本计划替设计定下的事

用户 2026-11-15 的话：“全部自动完成，按你的推荐想法”。设计 §10 要确认的几件，G2 用到的按设计的推荐：

- **按键排默认关**（W3），记在这台主控台上（`gui.json` 的 `term_key_row`）。
- **「＋」新开窗口**（T3）照做。命令是 `new-window -d -a -t <当前面板> -c '#{pane_current_path}' -P -F '#{pane_id}'`：`-d` 不改那边其他客户端的当前窗口，`-a` 插在当前窗口后面（不占已有编号）。这是规格 §8.1 第 3 类“新开”的扩展，任务 10 改规格的这一条。
- 打开写作面板、焦点在舞台和面板之间来回：用写作面板已经定下的 **Ctrl+Enter**（所有平台；写作面板决定 5–6），不另设 ⌃⌘I。Ctrl+Enter 在 tmux 里本来就和回车分不开，不送到终端。
- **Shift+回车**发 `type` 文字 `"\u001b\r"`（ESC 回车）。tmux 不开扩展键时 `S-Enter` 就是普通回车，在 Claude Code 里会直接提交；ESC 回车在 Claude Code 里是换行。规格不许设 `extended-keys`。
- **Option 当 Meta**（K3）：macOS 上 Option+字母不出特殊字符，发 `Alt-<字母>`；字母取物理键（US 布局），按着 Shift 是大写。
- rapp 自己占的快捷键（K2）在 G2 里：复制、粘贴两组；查找、字号（⌘F、⌘＋、⌘－ / Ctrl+Shift+F、Ctrl+Shift+＋、Ctrl+Shift+－）先**留着不发**给终端，G3 接。macOS 上其他 ⌘ 组合不发（交给窗口，如 ⌘Q、⌘W）。Linux 上窗口级的 Esc、Ctrl+[、Ctrl+]、Ctrl+O、F11 在舞台有焦点时都给终端。
- PageUp、PageDown 舞台有焦点时发给终端（K1）；本机往上翻用滚动（H1 的 PageUp 留给 G3 的焦点规则）。
- K5：舞台上没有输入法连接，输入法本来就不起作用；“检测到组字就提示”不做（Flutter 在没有文字输入连接时拿不到组字状态）。
- K6 的省略号：发出按键或文字后 0.3 秒内没收到新的一屏，光标后面画一个「…」，下一屏到了就去掉。
- 按键排：开关打开就显示，不管写作面板开没开（G5：没有键盘也能打断）。宽（舞台 ≥ 1100）：左下 Esc、⌃C、Tab，右下 ↑、↓、⏎，各 52×48，和写作面板同一行；写作面板没开时「输入」按钮挨在右边那组的左边。窄（< 1100）且写作面板开着：按键排是写作面板正上方的一行（左右两组分在两头），画面再上移 56（共 120）。
- 画面上移：写作面板开着或按键排开着，终端画面上移 `pictureLift`（64），窄且两样都开着再加 56。上移用 `Transform.translate`，**不改 `TermStage` 拿到的尺寸**，所以那边的行列数不变（Z2）。
- 终端会话「＋」菜单（W1 的表）：「附件…」灰着、右边写「终端会话不支持」；没有「在远端复制」；没有 ⌘、⌥ 两个粘滞键；按键一组换成 15 个：Esc、Tab、⇧Tab、删除、回车、←、↓、↑、→、⌃C、⌃D、⌃L、⌃R、PgUp、PgDn，分别发 `Esc`、`Tab`、`Shift-Tab`、`Backspace`、`Enter`、`Left`、`Down`、`Up`、`Right`、`Ctrl-C`、`Ctrl-D`、`Ctrl-L`、`Ctrl-R`、`PageUp`、`PageDown`（“删除”是退格）。输入历史照常。
- 写作面板的灰字：`写给 <当前面板的命令>`，命令为空时用会话名。
- 粘贴规则照写作面板 W14：不到 800 字且不到 10 行直接进文字，否则成块。块的内容存在 `TermSessionPort` 里，发送时按顺序拼成一段。
- 在舞台上粘贴（K4）：剪贴板文字没有换行 → 直接作为一次粘贴发给当前面板（不补回车）；有换行 → 打开写作面板，走写作面板自己的粘贴（同上的 W14 规则），焦点到面板。
- 一次粘贴（含写作面板发送）拼起来超过 1 MiB（1048576 字节，UTF-8）：不发，写作面板照失败处理（草稿留着），原因「太长了：终端一次最多贴 1 MiB」。
- 新开终端：设备面板“终端”一组最后、「添加 SSH 主机…」前面一个按钮「新开终端…」。对话框：「在哪」（本机，和每台 SSH 主机的名字）、「命令（如 claude；空着就是 shell）」、「名字（可不填）」，按钮「新开」「取消」；失败把 hub 回的原文写在对话框里，不关。命令整行作为**一个**参数发（tmux 拿一个参数时交给 shell 去解析，引号照常用）；空着发空列表，被控端起 tmux 的默认 shell。行列数用这台主控台上一次给终端舞台算出的行列数，没有就 120×40。新开成功后直接打开它。
- 对着旧设备（`hello` 的 `v` < 2）：「＋」不显示；新键名那边会回 `unknown key`，照现有的错误提示处理，不另做。
- 面板已退出（T4）或会话断开（N4）：键、文字都不发，也不排队。

## Global Constraints

- rapp 对用户的 tmux 只多一个动词 `new-window`，只在 `rust/term/src/tmux/cmd.rs` 里拼，只在用户点了「＋」时发，总带 `-d`。绝不 `set-option`、`kill-*`，不改别人的尺寸（规格 §1、§8.1）。
- 开合写作面板、开关按键排、切标签，都不能让 GUI 发出新的 `view` 行列数（设计 §1“不能出现的”第 3 条）。
- 一行线消息（含换行）不超过 65536 字节；一次粘贴拼起来最多 1 MiB；分片时除最后一片外 `more: true`，最后一片 `more: false`；每次粘贴那边只回一条 `pasted`，按发出的顺序。
- `term:` 标识在 GUI 里只在 `gui/lib/term/term_id.dart` 里解析。
- 面向用户的文字全是中文，原文照本计划：「按键排」「新开终端…」「新开终端」「在哪」「本机」「命令（如 claude；空着就是 shell）」「名字（可不填）」「新开」「取消」「新开一个窗口」「新开窗口失败：<原文>」「终端会话不支持」「太长了：终端一次最多贴 1 MiB」「写给 <命令>」。
- 不加第三方依赖。不碰 `SessionPort` 已有方法的签名；`ComposerPanel`、`ComposerPlus`、`RemoteSession` 只加任务里写明的参数，默认值保持 app 会话的现有行为——app 会话的测试一条都不能坏。
- 在 git worktree `.claude/worktrees/term-g2`、分支 `feat/term-g2` 上做；不推送。每次提交前按文件名 `git add`；不用 `git add -u/-A/.`、`git stash`、`git reset`。`flutter test` 改了 `gui/pubspec.lock` 就 `git checkout -- gui/pubspec.lock`（只许这一处 checkout）。不碰 `README.md`、`docs/archives/`。
- Rust：新文件用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`，不跑 `cargo fmt`；改动的旧文件手工对齐。Rust 任务结束时 `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test --workspace` 全过，`cargo clippy --workspace --all-targets -- -D warnings` 无新警告（`rust/testkit/tests/common/mod.rs:318` 的 `double_ended_iterator_last` 是 main 上原有的，任务 1 顺手改成 `.next_back()`）。tmux 测试只用独立 socket。
- GUI：`export PATH=$HOME/development/flutter/bin:$PATH`；GUI 任务结束时 `cd gui && flutter analyze` 无问题，`flutter test` 全过。新测试放 `gui/test/term/`。
- 提交信息：`feat(term): …`、`feat(gui): …`、`fix(…)`、`docs: …`；结尾带 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

1. **舞台有焦点时按了窗口级快捷键**（Esc、Linux 的 Ctrl+[、Ctrl+]、Ctrl+O、F11）：要到终端，不触发 rapp 的窗口动作；只有 Ctrl+Enter 往上走。（任务 5）
2. **粘贴正在途中切了标签**：这一段贴进写的时候的那个面板，`pasted` 应答对上这一段；不贴进新标签。（任务 3）
3. **粘贴超过 64 KiB**（多片）和**超过 1 MiB**：多片拼对、只等一条 `pasted`；超了不发、草稿留着、写原因。（任务 3、6）
4. **断开时、面板已退出时按键**：不发、不排队，重连后不会冒出一串旧键。（任务 5）
5. **开合写作面板、开关按键排、窗口变窄**：`FakeTermSessionPort.calls` 里没有新的 `view`。（任务 6、7）

## File Structure

```
rust/term/src/
  keys.rs          改：键名语法加 Ctrl-/Alt-/Shift- 前缀
  proto.rs         改：PROTO = 2；In::NewWindow；Out::WindowOpened
  session.rs       改：处理 NewWindow
  tmux/cmd.rs      改：VERBS 加 new-window；new_window()；new_session 空命令
  serve.rs         改：空命令不再拒
rust/hub/src/terms.rs  改（如需要）：new_term 允许空 command
gui/lib/term/
  term_keys.dart   新：KeyEvent → TermInput
  term_wire.dart   改：keysMsg、typeMsg、textMsgs、newWindowMsg；WindowOpened 解析
  term_session_port.dart  改：发送、粘贴队列、composer 方法、newWindow
  term_stage.dart  改：键盘、粘贴、省略号、焦点
  term_key_row.dart 新：按键排
gui/lib/embed/composer_panel.dart, composer_plus.dart  改：终端变体
gui/lib/ui/stage.dart, main_state.dart, top_bar.dart, prefs.dart, devices_tab.dart  改
gui/lib/embed/stream_menu.dart  改：终端的「本机」一组只有「按键排」
gui/lib/hub_client.dart  改：newTerm
```

---

### Task 1: 被控端：键名语法

**Files:** Modify `rust/term/src/keys.rs`（含它的测试）、`rust/testkit/tests/common/mod.rs:318`（`.last()` → `.next_back()`）。

**Interfaces:** Produces 线上键名语法（GUI 任务 4 照它发）：`[Ctrl-][Alt-][Shift-]<base>`，前缀按这个顺序，各至多一次。`<base>` 是：

- 具名键：`Esc Enter Tab Backspace Delete Up Down Left Right Home End PageUp PageDown F1`…`F12`、`Space`；
- 或一个字符：`Ctrl-` 后面只许 `a`–`z`（大写转小写）、`[ ] \ @ _`；`Alt-` 后面许任何可见 ASCII（0x21–0x7E）；单独一个字符（不带前缀）不是合法键名（文字走 `type`）。
- `Shift-` 只许跟 `Up Down Left Right Home End PageUp PageDown Delete F1`…`F12`；单独的 `Shift-Tab` 照旧映射为 `BTab`（带别的前缀时不许 `Tab`）。
- `Space` 只许带 `Ctrl-` 或 `Alt-`。

映射：`Ctrl-`→`C-`，`Alt-`→`M-`，`Shift-`→`S-`，具名键照现有表（`Esc`→`Escape`，`Backspace`→`BSpace`，`Delete`→`DC`，`PageUp`→`PPage`，`PageDown`→`NPage`，`Space`→`Space`）。现有的键名映射不变。

- [ ] **Step 1: 测试**（`keys.rs` 里）：`Alt-x`→`M-x`；`Alt-X`→`M-X`；`Alt-;`→`M-;`；`Alt-Left`→`M-Left`；`Alt-Backspace`→`M-BSpace`；`Alt-Enter`→`M-Enter`；`Shift-Up`→`S-Up`；`Ctrl-Left`→`C-Left`；`Ctrl-Shift-Right`→`C-S-Right`；`Ctrl-Alt-x`→`C-M-x`；`Ctrl-[`→`C-[`；`Ctrl-\`→`C-\`；`Ctrl-Space`→`C-Space`；`Ctrl-C`→`C-c`（现有）；拒绝：`x`、`Shift-x`、`Shift-Enter`、`Ctrl-1`、`Space`、`Alt-`、`Alt- `、`Alt-é`、`Shift-Ctrl-x`（顺序错）、`Ctrl-Ctrl-x`。再在现有的 tmux 集成测试里加一条：独立 socket 的会话里跑 `cat -v`，发 `Alt-x` 和 `Shift-Up`，取屏看到 `^[x` 和 `^[[1;2A`。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: 跑全部 Rust 测试和 clippy。**
- [ ] **Step 5: 提交** `feat(term): Alt, Shift and Ctrl modifiers in key names`

### Task 2: 被控端：新开窗口、空命令、PROTO 2

**Files:** Modify `rust/term/src/proto.rs`、`session.rs`、`tmux/cmd.rs`（及调用它的 `tmux/mod.rs`）、`serve.rs`、必要时 `rust/hub/src/terms.rs`；测试照这些文件现有的测试位置。

**Interfaces:**
- `PROTO: u32 = 2`。
- `In::NewWindow { pane: String }`（`{"t":"new_window","pane":"%3"}`），照 `Keys` 一样先查 `own_pane`。执行 `new-window -d -a -t <pane> -c '#{pane_current_path}' -P -F '#{pane_id}'`（`-c` 的格式由 tmux 按目标展开；实现时在测试里确认目录对）。成功回 `Out::WindowOpened { pane: String }`（`{"t":"window_opened","pane":"%7"}`），失败回现有的错误消息，原文 `could not open a window`。日志照 `new_term` 记一行（谁、哪个会话），不记内容。
- `new-window` 加进 `VERBS`。
- `Req::New` 的 `command` 为空：起 `new-session -d -s <name> -x <cols> -y <rows>`，不带命令（tmux 的默认 shell）；hub 的 `new_term` 若也拒空命令，一并放开。Linux 上 `systemd-run` 那一层照旧。

- [ ] **Step 1: 测试**（独立 socket）：在目录 `$TMP/a` 里起的会话，`new_window` 之后 `list-panes -a` 多一个面板，它的 `pane_current_path` 是 `$TMP/a`，回的 `window_opened.pane` 就是它；那边原来的当前窗口没变（`#{window_active}` 还是原来那个）；对不属于这个视图的面板发 `new_window` 被拒；`New` 空命令起出一个会话，面板的当前命令是 shell；`hello` 的 `v` 是 2。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: 跑全部 Rust 测试和 clippy。**
- [ ] **Step 5: 提交** `feat(term): new_window, empty command opens the shell, protocol 2`

### Task 3: GUI：终端端口能发

**Files:** Modify `gui/lib/term/term_wire.dart`、`gui/lib/term/term_session_port.dart`、`gui/test/fakes.dart`（`FakeTermSessionPort` 记录新方法）；Test `gui/test/term/term_wire_test.dart`、`gui/test/term/term_port_send_test.dart`（照 `term_main_test.dart` 里真端口那一组，连本机假服务器）。

**Interfaces:**
- `term_wire.dart`：`String keysMsg(String pane, List<String> keys)`、`String typeMsg(String pane, String text)`、`List<String> textMsgs(String pane, String data, {bool enter = false})`（按 UTF-8 切片、不切断字符，每行编码后 ≤ 65536 字节，用 16384 字节一片；除最后一片 `more:true`）、`String newWindowMsg(String pane)`；解析 `window_opened` → `TermWindowOpened(String pane)`；`TermHello.v` 已有。
- `TermSessionPort`：
  - `void sendKeys(Object sid, List<String> keys)`、`void type(Object sid, String text)`：发给这个 sid **当前看着的面板**；面板已退出或连接不在时什么都不做。
  - `Future<String?> paste(Object sid, String data, {bool enter = false})`：面板在调用时定下；超过 1048576 字节直接返回「太长了：终端一次最多贴 1 MiB」不发；同一连接上的粘贴排队、一次一段，`pasted` 按顺序兑现最早的一段（`ok` → null，否则 `error` 原文，没有原文用「没有贴进去」）；连接断了，在途的都以「连接断了」结束。
  - `bool canNewWindow(Object sid)`（`hello.v >= 2`）；`Future<String?> newWindow(Object sid)`：成功回 null，失败回原文；`window_opened` 到了以后，等它出现在面板表里，发 `TermOpenedPaneEvent(Object sid, int window)`（新的 `SessionEvent` 子类，放在 `term_session_port.dart`）。
  - `int? lastCols, lastRows`：最近一次 `view` 发出的行列数（任务 9 用）。
  - 覆盖 `key(Object sid, int keyCode, int modifiers)`：只认写作面板会用到的 macOS 键码：36→`Enter`，53→`Esc`，48→`Tab`，51→`Backspace`，123→`Left`，124→`Right`，125→`Down`，126→`Up`，116→`PageUp`，121→`PageDown`；其余丢掉。
- `FakeTermSessionPort` 记 `('keys',{sid,keys})`、`('type',{sid,text})`、`('paste',{sid,data,enter})`（`pasteReply` 可设，默认 null）、`('newWindow',{sid})`。

- [ ] **Step 1: 写失败的测试**：`textMsgs` 70000 字节的中文切成几片、每片 ≤ 65536、拼回来等于原文、只有最后一片 `more:false`；一段粘贴发出去后切了当前面板，第二段贴的是新面板、第一段的 `pasted` 兑现第一段（Review Focus 2）；1 MiB+1 字节不发、返回原因；断开时在途粘贴以「连接断了」结束；面板 `dead` 时 `sendKeys` 不发；`key(sid,36,0)` 发 `["Enter"]`；`window_opened` 之后面板表里出现那个面板才发 `TermOpenedPaneEvent`；`v:1` 时 `canNewWindow` 为 false。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: `flutter analyze`、`flutter test` 全过。**
- [ ] **Step 5: 提交** `feat(gui): the terminal port sends keys, text and pastes`

### Task 4: GUI：本机按键 → 线上的键

**Files:** Create `gui/lib/term/term_keys.dart`；Test `gui/test/term/term_keys_test.dart`。

**Interfaces:**

```dart
sealed class TermInput {}
class TermKeys extends TermInput { TermKeys(this.keys); final List<String> keys; }   // 任务 1 的语法
class TermText extends TermInput { TermText(this.text); final String text; }
enum TermShortcut { copy, paste }
class TermAction extends TermInput { TermAction(this.action); final TermShortcut action; }
class TermReserved extends TermInput {}   // rapp 留着的（查找、字号）：吞掉，不发
/// null = 不归终端（让它往上走：Ctrl+Enter、macOS 其他 ⌘ 组合、KeyUp）。
TermInput? termInputOf(KeyEvent e, {required bool mac, required Set<LogicalKeyboardKey> pressed});
```

规则（本计划“替设计定下的事”里的键盘几条）：KeyDown 和 KeyRepeat 才算；Ctrl+Enter → null；复制 / 粘贴 / 留着的按 K2 两列；macOS 其他 ⌘ → null；Shift+Enter → `TermText("\u001b\r")`；具名键加修饰前缀；Ctrl+字母 → `Ctrl-<小写>`；Ctrl+`[ ] \ @ _` 和 Ctrl+Space；Alt/Option+可见字符 → `Alt-<物理键在 US 布局下的字符，按 Shift 取上档>`；其余有 `character` 且没有 Ctrl/Alt/Meta 的 → `TermText(character)`；其他 → null。

- [ ] **Step 1: 测试**（逐条，mac 和非 mac 两套）：`a`→`TermText('a')`；Shift+a→`'A'`；中文 `character`→原样；Enter→`['Enter']`；Shift+Enter→`TermText('\u001b\r')`；Ctrl+Enter→null；Esc→`['Esc']`；Shift+Tab→`['Shift-Tab']`；Ctrl+R→`['Ctrl-r']`；Ctrl+L→`['Ctrl-l']`；Ctrl+[→`['Ctrl-[']`；Ctrl+Space→`['Ctrl-Space']`；Shift+Up→`['Shift-Up']`；Ctrl+Shift+Right→`['Ctrl-Shift-Right']`；mac Option+f（character 'ƒ'）→`['Alt-f']`；Option+Backspace→`['Alt-Backspace']`；mac ⌘C→copy、⌘V→paste、⌘Q→null、⌘F→Reserved；非 mac Ctrl+Shift+C→copy、Ctrl+Shift+V→paste、Ctrl+Shift+F→Reserved、Ctrl+C→`['Ctrl-c']`；F11→`['F11']`；PageUp→`['PageUp']`；KeyUp→null；KeyRepeat 的 a→`'a'`。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: 跑这个测试文件和 `flutter analyze`。**
- [ ] **Step 5: 提交** `feat(gui): local key events to terminal key names`

### Task 5: GUI：舞台接键盘、粘贴、省略号、焦点

**Files:** Modify `gui/lib/term/term_stage.dart`、`gui/lib/ui/main_state.dart`；Test `gui/test/term/term_stage_keys_test.dart`。

**Interfaces:**
- `TermStage._onKey`：先保留现有的复制、Esc 清选区（有选区时 Esc 只清选区、不发）；然后 `termInputOf(...)`：`TermKeys`→`port.sendKeys`，`TermText`→`port.type`，copy→现有 `_copy`，paste→`state.termPaste(session)`，Reserved→吞掉；这几种都返回 `handled`，null 返回 `ignored`。发了键或文字就回到最新（H3）。
- `MainState.termPaste(RemoteSession rs)`：读剪贴板文字；没有换行 → `termPort.paste(rs.sid, text)`；有换行 → `rs.composer.open = true`，让写作面板跑它自己的粘贴（给 `ComposerModel` 加 `requestPaste()` / `pasteTick`，`ComposerPanel` 看到就调它现有的 `_paste()`）并 `wantFocus()`。
- 焦点：`MainState.focusPicture(sid)` 对终端 sid 改成递增 `termFocusTick`（`int`，`notifyListeners`），`TermStage` 看到就 `_focus.requestFocus()`；打开一个终端会话、切到它时也要一次（照 app 会话打开后焦点到画面的做法）。
- K6：发出键或文字时记下时间和当时的屏幕版本；0.3 秒后版本还没变，在光标后面一格画「…」（`term_painter.dart` 加参数），新一屏到了去掉。

- [ ] **Step 1: 写失败的测试**：舞台有焦点时 Ctrl+R、Ctrl+L、Shift+Tab、↑ 都进 `FakeTermSessionPort.calls`（设计 §8 G2 的验收）；Linux（`debugDefaultTargetPlatformOverride`）上 Esc、Ctrl+[、F11 进终端、窗口级动作没触发（把舞台包在 `main_window.dart` 同样的 `CallbackShortcuts` 下验证，Review Focus 1）；Ctrl+Enter 不进终端、打开写作面板；断开时、面板已退出时按键什么都不记（Review Focus 4）；在历史里按一个字母 → 回到最新；⌘V 一行 → `paste`，没有打开面板；⌘V 三行 → 面板开了、`paste` 没被调；发键后 0.3 秒没新屏出现「…」、来了一屏消失；`focusPicture` 后舞台有焦点。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: `flutter analyze`、`flutter test` 全过。**
- [ ] **Step 5: 提交** `feat(gui): keys go to the terminal when its stage has focus`

### Task 6: GUI：写作面板接进终端会话

**Files:** Modify `gui/lib/ui/stage.dart`、`gui/lib/embed/composer_panel.dart`、`gui/lib/embed/composer_plus.dart`、`gui/lib/term/term_session_port.dart`；Test `gui/test/term/term_composer_test.dart`。

**Interfaces:**
- `TermSessionPort` 实现写作面板用的：`composerPaste(sid)` → 读剪贴板，按 W14（< 800 字且 < 10 行）返回 `PasteResult(text:…)` 或 `PasteResult(blocks:[一个 BlockChip])`，块的文字存在端口里按块号取；`composerDropBlock(sid, n)` 删块；`composerAttach(sid)` → `PasteResult(status: '终端会话不支持')`；`composerSend(sid, pieces)`：按顺序把文字和块拼成一段，`paste(sid, data)`，先发 `ComposerStateEvent` 的 sending，应答到了发 done：成功 `ComposerDone(pieces.length, null)`、失败 `ComposerDone(0, 原因)`（与原生 runner 的约定一致，实现时读 `session_port.dart` 的 `ComposerStateEvent` 和 `RemoteSession.apply`）。`afterSend` 沿用 `RemoteSession._allSent → onReturn → key(sid,36,0)`，任务 3 已把它译成 `Enter`。
- `stage.dart`：终端那一支不再跳过写作面板：`Stack([stage, ...composerLayer(state, session, port: state.portOf(sid)!)])`；画面上移规则照“替设计定下的事”，套在终端那一支外面，150 ms（关动画时 0）。
- `ComposerPanel`：灰字终端时写 `写给 <state.termPaneOf(rs)?.command，空用 appName>`（有上一条时仍加「 · ↑ 上一条」）。
- `ComposerPlus({…, bool terminal = false})`：`terminal` 时照“替设计定下的事”里的「＋」菜单那条；按键发 `TermSessionPort.sendKeys`。

- [ ] **Step 1: 写失败的测试**：终端舞台上有「输入」按钮，点开出现写作面板、灰字「写给 claude」；写「你好\n世界」点发送 → `paste` 收到一段 `你好\n世界`、`enter:false`；应答成功后框清空；配置 `afterSend: pressReturn` 时之后再发 `['Enter']`；应答失败草稿留着、显示原因；空着按回车 → `['Enter']`；「＋」里有 15 个键、点 ⌃C → `['Ctrl-C']`，「附件…」灰着写「终端会话不支持」，没有「在远端复制」；W14：粘贴 12 行成块、发送时块的文字拼在原位置；开合写作面板 `calls` 里没有新的 `view`（Review Focus 5），`TermStage` 的尺寸不变、画面上移 64。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: `flutter analyze`、`flutter test` 全过（app 会话的写作面板测试都不能坏）。**
- [ ] **Step 5: 提交** `feat(gui): the writing panel on terminal sessions`

### Task 7: GUI：按键排

**Files:** Create `gui/lib/term/term_key_row.dart`；Modify `gui/lib/ui/prefs.dart`、`gui/lib/ui/main_state.dart`、`gui/lib/embed/stream_menu.dart`、`gui/lib/ui/stage.dart`、`gui/lib/embed/composer_panel.dart`（「输入」按钮的位置）；Test `gui/test/term/term_key_row_test.dart`、`gui/test/ui/prefs_test.dart`（有就加）。

**Interfaces:**
- `UiPrefs.termKeyRow`（`term_key_row`，默认 false），`MainState.setTermKeyRow(bool)`（存盘、通知）。
- 流量标签菜单：终端会话出现一组「本机」，只有一项「按键排」（`Key('term-key-row')`，打勾跟着开关）。
- `TermKeyRow({required TermSessionPort port, required Object sid, required bool split})`：六个键 `Key('keyrow-Esc')`、`keyrow-Ctrl-C`、`keyrow-Tab`、`keyrow-Up`、`keyrow-Down`、`keyrow-Enter`，各 52×48，点了 `sendKeys`；布局和画面上移照“替设计定下的事”。

- [ ] **Step 1: 写失败的测试**：默认没有按键排；菜单里点「按键排」→ 出现六个键、`gui.json` 里 `term_key_row: true`；点 Esc → `['Esc']`，点 ⏎ → `['Enter']`；写作面板没开时「输入」按钮和右边那组不重叠；舞台 1000 宽且写作面板开着时按键排在写作面板上方、画面上移 120；开关按键排、改窗口宽度跨过 1100，`calls` 里没有新的 `view`（Review Focus 5）；app 会话的菜单没有「按键排」。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: `flutter analyze`、`flutter test` 全过。**
- [ ] **Step 5: 提交** `feat(gui): the terminal key row`

### Task 8: GUI：「＋」新开窗口

**Files:** Modify `gui/lib/ui/top_bar.dart`、`gui/lib/ui/main_state.dart`；Test `gui/test/term/term_main_test.dart` 加几条。

**Interfaces:**
- 终端会话的标签一行在只有一个面板时也显示（app 会话照旧要 ≥ 2）；最后一个芯片「＋」（`Key('term-new-window')`，提示「新开一个窗口」），`canNewWindow` 为 false 时不显示。
- `MainState.newTermWindow()`：`termPort.newWindow(sid)`；失败在舞台的提示里写「新开窗口失败：<原文>」（照 G1 的 `model.note` 那条路）；`TermOpenedPaneEvent` 到了 → `selectWindow(window)`。

- [ ] **Step 1: 写失败的测试**：一个面板时有标签一行和「＋」；点「＋」→ `calls` 有 `newWindow`；端口发 `TermOpenedPaneEvent(sid, 7)` 且面板表里有 7 → 当前标签是 7；`newWindow` 回失败 → 提示有原文；`hello.v == 1`（`canNewWindow` false）→ 没有「＋」。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: `flutter analyze`、`flutter test` 全过。**
- [ ] **Step 5: 提交** `feat(gui): open a tmux window from the tab row`

### Task 9: GUI：新开终端

**Files:** Modify `gui/lib/hub_client.dart`、`gui/lib/ui/devices_tab.dart`、`gui/lib/ui/main_state.dart`；Test `gui/test/hub_client_test.dart`、`gui/test/ui/devices_tab_test.dart`。

**Interfaces:**
- `Future<String> HubClient.newTerm(String id, {String? host, String? name, required List<String> command, required int cols, required int rows})`：发 `{'cmd':'new_term','id':id,'host'?:…,'name'?:…,'command':command,'cols':…,'rows':…}`（`host`、`name` 为 null 时不带这个键），等 `term_created`，返回 `term`；hub 回错误时抛出带原文的异常（照 `addTermTarget` 的做法），之后 `terms(id)` 刷新。
- 设备面板：照“替设计定下的事”里的新开终端那条；按钮 `Key('new-term')`，对话框里三个控件 `Key('new-term-where')`、`Key('new-term-command')`、`Key('new-term-name')`。新开成功 → `state.openOrSwitch(id, term, termDisplayName(...))`。行列数：`state.termPort?.lastCols/lastRows`，没有就 120×40。

- [ ] **Step 1: 写失败的测试**：点「新开终端…」，命令填 `claude --resume`，点「新开」→ hub 收到 `command: ['claude --resume']`、没有 `name`、`host` 键；回 `term_created` 后 hub 收到 `open`；命令空着 → `command: []`；选了 SSH 主机 `gpu1` → 带 `host: 'gpu1'`；hub 回错误 → 对话框还在、写着原文；终端关着（`off`）时没有这个按钮。
- [ ] **Step 2: 跑，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: `flutter analyze`、`flutter test` 全过。**
- [ ] **Step 5: 提交** `feat(gui): open a new terminal from the devices panel`

### Task 10: 收尾、文档、验收

**Files:** Modify 设计（状态、§10 第 1、3 件写“已定：照推荐”）、规格 §8.1（第 3 类加“新开窗口，用户点了才做，带 `-d`”）、§13（按键排照设计 W3–W5）、写作面板 §10（加一句：终端里 Ctrl+I 是 Tab，打开写作面板仍是 Ctrl+Enter）。

- [ ] **Step 1: 全部测试**：`cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings`；`cd gui && flutter analyze`、`flutter test`。
- [ ] **Step 2: 本机冒烟**（不动用户正在跑的服务）：新编的 `rapp-term`，独立 socket 的 tmux，照 `rust/term/tests/serve.rs` 的做法连上：`keys` 发 `Alt-x`、`type` 发中文、`text` 发一段 70000 字节的多片粘贴，各自在屏幕上看到；`new_window` 回 `window_opened`、那边当前窗口没变；`hello.v == 2`。
- [ ] **Step 3: 列出要用户真机验的**（写进交给用户的总结）：规格 T2：输入区写一段带换行的中文发进 Claude Code，是一段；按 Esc 打断正在跑的任务；从 rapp 新开一个会话，重启 rapp 的服务，它还活着。设计 G2：舞台有焦点时 Ctrl+R、Ctrl+L、Shift+Tab、方向键都到那边；开合写作面板和按键排时那边的尺寸不变（被控端日志没有改尺寸）；多行内容在舞台上粘贴，进的是写作面板。另加：Shift+回车在 Claude Code 里是换行；Option+B/F 在 shell 里按词移动；「＋」开的窗口目录对、另一个接着的终端当前窗口没变。
- [ ] **Step 4: 提交** `docs: terminal G2 decisions in the specs`
