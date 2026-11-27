# 手机 V1c 回复和评审 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 不进会话也能在手机卡片上回答 agent（允许、拒绝、选第 N 项、说一句），看懂计划后点头或按住说哪里要改。会话里改成阅读视图加回复条。首页的按住说话先存进「助理」。

**Architecture:** 回复走探查 4 的新通路：手机 hub 的 `reply_term` → 设备间 `Op::ReplyTerm` → A 的 service → `rapp-term serve` → holder → 程序的输入。这条路不开视图，也不碰「窗口跟谁」。按什么键由手机查自己的对照表决定（代定 4-2）。卡片的按钮、按住手势和评审要点都放在 `gui/lib/phone/` 里新写的几个文件。Pad 和 macOS 用的共享代码只做「加可选参数、默认值等于今天」这一类改动。评审要点来自 rapp-state P4 的 `rapp emit`，和它在终端里自动带上的 `RAPP_TERM`；按代定 2-4，P4 先在自己的分支上单独做、单独合并。

**Tech Stack:** Rust（rapp-net、rapp-term、rapp-service、rapp-hub、rapp-cli、testkit），Flutter/Dart（`gui/lib/phone/`、少量 `gui/lib/embed/`、`gui/lib/term/`、`gui/lib/ui/main_state.dart`、`gui/lib/hub_client.dart`），Python 3（Claude Code 的 hook 样本）。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-iphone-v1-requirements.md`（§17 V1c：I2、I3、I7、C2、C4–C16、C18–C24、V1–V10、S1–S8；验收 3、4、9）。

还要一起读：
- 本期规则：`docs/superpowers/plans/2026-11-27-rapp-phone-v1-kickoff.md`。
- 稿子：`docs/superpowers/specs/2026-11-27-rapp-phone-mocks/preview/` 下的 V1Allow、V1Risky、V1Ask、V1Plan、V1PlanRule、V1DoneCard、V1Session、V1Voice、V1Assistant、V1Sheet。
- 探查结论：`docs/superpowers/measurements/2026-11-27-rapp-phone-v1a-2-cli.md`（键、`msg`、计划状态）、`…-v1a-3-reading.md`（阅读视图）、`…-v1a-4-reply.md`（回复通路）。
- `tasks/todo.md`「手机第一版」一节里 V1a 和 V1b 的「代定的」。
- rapp-state 规格 §11 和 P4 那一行：`docs/superpowers/specs/2026-11-26-rapp-state-design.md`。

## Global Constraints

- **回复不开视图：** 不改 A 上终端的大小，不改「窗口跟谁的尺寸」（S4、V4，验收 3）。手机发回复不调用 `TermSessionPort.view`，也不调用 `paste`、`sendKeys`、`type`。
- **按下不发，松手才发；** 手指滑出按钮再松手就是取消。按下要有明显的按下样子，滑出时恢复。不等 3 秒（C5）。
- **撤不回的两次确认（C10）：** 第一次在按钮上松手不发，按钮变成强调色（`t.accent`）的「再点一次确认」。3 秒不点就复原。第二次松手立即发出。
- **手指按着时卡片换了内容（C6）：** 这一下作废，不发。
- **发之前核对（C12）：** 会话还在等，`seq` 也没变；不对就不发，卡片上写「它已经不在等这一问了」。发的时候带上 `seq`。
- **发之后 3 秒（`replySettle = Duration(seconds: 3)`）：** 状态离开等待（或者 `seq` 变了）才算成功。没离开：卡片留着，写「没成功，进去看看」，不重试（C13）。
- **没有自动回复（C14）：** 也没有合并回复、没有「全部允许」。不提供「总是允许」那一类选项，也不发要看光标位置的键。
- **界面上不出现「安全」这类字（C11）。**
- **尺寸：** 可点处高 ≥56（`phoneTap`），卡片上的按钮和主按钮 ≥64（`phonePrimaryTap`），相邻两个可点处至少隔 12（Q2）。
- **颜色只取 `gui/lib/ui/tokens.dart` 的 `RappTokens`**（`bg line text muted on accent accentInk tint warn danger panel raise float`）。`no_hard_colors_test.dart` 要继续过。
- **Pad 形态和 macOS 一点都不变。** 老测试一个都不改。共享文件只加东西：可选参数、新的 getter、新的方法。默认值等于今天的行为。
- **不涨协议号。** 本机套接字 `LOCAL_V` 不变，macOS host 的 `protocolVersion` 不变。
- **日志里不记回复的内容和会话 id。** 只记「有没有 seq、有没有字、几个键」。文档和测试样本里也不放用户说的话和密码。
- **碰 `gui/lib/ui/main_state.dart`、`gui/lib/history/`、`gui/lib/ui/projects.dart` 的任务，合并前先 `git merge main`：** 项目范围重构正在改这些文件。只加，不改已有的签名。
- **不改版本号，不打 tag，不 push，不碰 `website/`**（CLAUDE.md 合并与发版）。
- **工具：** `grep` 是 ugrep，计数用 `/usr/bin/grep`；没有 `timeout`；flutter 在 `~/development/flutter/bin/flutter`，跑完测试把 `gui/pubspec.lock` 还原。

## Review Focus

1. **按着的时候卡片换了（C6）。** 按下时记住卡片的 `gotItKey`，松手时再比一次。不一样、或者按钮已经卸掉（卡片离开了），都不发。→ Task 9 `voids when the card changes under the finger`，Task 11 `card swap mid-press sends nothing`。
2. **按下和松手之间，A 断开了。** 松手时 A 已经离线（在 `offline` 里，或者 hub 不可用）就不发，卡片写「连不上 A，没发」。请求发出去以后 hub 报错，就当不知道到没到，写「没成功，进去看看」，绝不重发（`repeatable` 里排除了 `ReplyTerm`）。→ Task 4 `reply_term_is_not_repeatable`，Task 10 `offline at release sends nothing`、`hub error after send shows go-look and never resends`。
3. **A 上是老版本，没有回复能力。** 设备的 `capabilities.reply` 不是 `true`，或者这个会话的 `reply` 位是假（升级前开的会话，代定 4-4）：卡片上没有回复按钮，只有「进去看」。A 回「老版本」的拒绝也当作这种情况。→ Task 7 `old device shows go-look only`、`session from old holder shows go-look only`，Task 10 `old-run refusal shows go-look`。
4. **Mac 和手机同时办同一件事。** Mac 先答了：手机卡片照新状态离开（C15）。手机松手时状态已经变了：C12 本地核对后不发；本地没看出来，A 回 `changed` 或 `typed`，就写「它已经不在等这一问了」。→ Task 3 `reply_refuses_changed_seq`、`reply_refuses_after_typing`，Task 10 `changed refusal shows not-waiting`、`local seq check skips send`。
5. **`msg` 是空的。** 不知道要允许什么，就没有允许/拒绝按钮（没法判断撤不回），只有「进去看」，卡片上照旧写 `goLookLine`。提问解析不出选项、计划没有要点，也一样。→ Task 7 `empty msg shows go-look only`。
6. **`git push` 和撤不回的双击。** 第一次松手不发，变成「再点一次确认」。3 秒内第二次松手才发。第一次之后卡片换了内容，确认作废。确认状态下滑出按钮再松手，也是取消。命令写在 `&&`、`;`、`|` 后面也要认出来。→ Task 6 `risky matches inside a chain`，Task 9 `risky needs two releases within 3 s`、`risky arm resets after 3 s`。
7. **回复还没回来就合上或展开了。** 发出去的回复和 3 秒的核对放在 `PhoneNav.replies` 上，形态切换时它还在（PhoneNav 在 `main_ios.dart` 里只建一次）。回到手机形态时，卡片显示的是那次回复的结果。→ Task 10 `outcome survives a form switch`。

---

## 文件

**Part A：rapp-state P4（分支 `feat/state-emit`，单独合并，排在 Task 8 前面）**

| 文件 | 新/改 | 做什么 |
|---|---|---|
| `rust/term/src/pty/holder.rs` | 改 | 子进程的环境里加 `RAPP_TERM=<会话 id>` |
| `rust/term/tests/holder_env.rs` | 新 | 子进程看得到 `RAPP_TERM` |
| `rust/service/src/outbox/mod.rs` | 改 | `Outbox::emit`：把 emit 交给发送任务；没有中心服务时返回 false |
| `rust/service/src/outbox/pump.rs` | 改 | 取出待发的 emit，放进 `Cache` |
| `rust/service/src/ipc.rs` | 改 | IPC 加 `"emit"` 命令 |
| `rust/cli/src/args.rs`、`rust/cli/src/main.rs`（或新的 `rust/cli/src/emit.rs`） | 改/新 | `rapp emit done\|ask\|info\|clear "text" [--key k] [--json]` |

**Part B：协议（分支 `feat/phone-v1c`）**

| 文件 | 新/改 | 做什么 |
|---|---|---|
| `rust/net/src/msg.rs` | 改 | `Op::ReplyTerm` 和往返测试 |
| `rust/term/src/pty/reply.rs` | 新 | 从探查分支摘 `apply`：核对 seq、`typed`，拼字节 |
| `rust/term/src/pty/{mod,local,holder}.rs` | 改 | 本机 op `reply`，`Head.reply`，`Status.reply = true` |
| `rust/term/src/list.rs` | 改 | `TermRow.reply: bool`（serde 默认 false，为 false 时不写） |
| `rust/term/src/serve.rs` | 改 | `Req::Reply`，`Worker::reply`，`status_rows` 填 `reply` |
| `rust/term/tests/{reply,serve}.rs` | 新/改 | 探查的测试，加 `reply` 位 |
| `rust/service/src/term.rs`、`rust/service/src/peer.rs` | 改 | 接 `ReplyTerm`、放行；只记次数 |
| `rust/service/src/workers.rs` | 改 | `capabilities()` 加 `"reply"` |
| `rust/hub/src/{lib,link,terms}.rs` | 改 | cmd `reply_term`，`repeatable` 排除它，事件 `term_replied` |
| `rust/testkit/tests/reply_term.rs` | 新 | 端到端，用真的 `rapp-term`（照 `probe_reply.rs`） |

**Part C：GUI 和附带的说明（分支 `feat/phone-v1c`）**

| 文件 | 新/改 | 做什么 |
|---|---|---|
| `gui/lib/hub_client.dart` | 改 | `TermRow.reply`，`HubClient.replyTerm` |
| `gui/lib/phone/reply_table.dart` | 新 | 各家的键（I3）、`msg` 解析、人话表（C7）、撤不回清单（C9）、做完的一句（C8） |
| `gui/lib/phone/reply_model.dart` | 新 | 一张卡片该有哪些按钮（纯函数） |
| `gui/lib/phone/home_model.dart` | 改 | 评审要点挂到卡片上（I7），过时的要点不显示 |
| `gui/lib/phone/hold_button.dart` | 新 | `PhoneHoldButton`：松手才发、滑出取消、卡片换了作废、撤不回两次 |
| `gui/lib/phone/replies.dart` | 新 | `PhoneReplies`：发、核对、3 秒、结果的话、输入历史 |
| `gui/lib/phone/phone_nav.dart` | 改 | `replies` 字段，`PhoneView.assistant` |
| `gui/lib/phone/reply_card.dart` | 新 | 卡片的回复区：放行、提问、评审、做完 |
| `gui/lib/phone/widgets.dart` | 改 | `PhoneCard` 加可选的 `actions`，`PhonePage` 加可选的 `trailing` |
| `gui/lib/phone/home_screen.dart` | 改 | 接上回复区，底下加 H12 的按住说话 |
| `gui/lib/phone/phone_voice.dart` | 新 | 卡片和首页用的 `VoiceHold`（说一句、要改、助理） |
| `gui/lib/embed/voice_button.dart` | 改 | 公开 `voiceHoldArea`；`sendVoice` 先看 `voiceSends` |
| `gui/lib/ui/main_state.dart` | 改 | `voiceSends`；`tidyOf`/`_makeTidy` 认它；`replyMeta` |
| `gui/lib/history/input_recorder.dart` | 改 | `replied(...)`：记一条发出的话 |
| `gui/lib/term/reflow.dart` | 新 | 从探查 3 摘，加 `reflowLines` |
| `gui/lib/term/term_model.dart` | 改 | 公开 `wrapped` getter |
| `gui/lib/phone/reading_view.dart` | 新 | `PhoneReadingView` |
| `gui/lib/phone/session_view.dart` | 改 | 阅读视图/看原样、底部钉住的卡片、回复条、边缘右滑 |
| `gui/lib/phone/reply_bar.dart` | 新 | S6 回复条 |
| `gui/lib/embed/composer_panel.dart`、`gui/lib/ui/stage.dart` | 改 | `composerLayer`/`stageOverlays` 加可选的 `phoneStack` |
| `gui/lib/embed/input_metrics.dart` | 新 | `InputMetrics`：快捷区和输入板的高度（R36） |
| `gui/lib/embed/{key_bar,phrase_strip,input_dock,composer_panel}.dart` | 改 | 从 `InputMetrics.of` 取高度，默认等于今天的常量 |
| `gui/lib/phone/assistant_store.dart`、`gui/lib/phone/assistant_page.dart` | 新 | V7–V10 |
| `gui/lib/phone/sheet.dart`、`gui/lib/phone/phone_shell.dart` | 改 | 「去别处」加「助理」，路由到助理页 |
| `integrations/claude-code/rapp-plan-points/SKILL.md` | 新 | 可选的 skill（C21） |
| `integrations/claude-code/hooks/emit_plan.py`、`…/hooks/settings.example.json`、`…/hooks/emit_plan_test.py` | 新 | 取计划原文前三条的 hook（代定 2-5） |
| `integrations/AGENTS-plan-points.md` | 新 | 给 Codex、agy 的一段说明（效果待试） |
| `gui/test/phone/*_test.dart`、`gui/test/term/reflow_test.dart`、`gui/test/term/reflow_samples/` | 新 | 见各任务 |
| `gui/test/phone/matrix_test.dart` | 改 | 加 V1c 的用例（只加，不改已有的） |
| `tasks/todo.md` | 改 | 真机检查、用户任务、留着的小问题 |

---

## 协议改动

- **新的设备间消息 `Op::ReplyTerm { term: String, seq: Option<u64>, text: Option<String>, enter: bool, keys: Vec<String> }`**（代定 4-1）。
  - hub cmd：`{"cmd":"reply_term","id","term","seq"?,"text"?,"enter"?,"keys"?,"req"}`。
  - 成功：`{"event":"term_replied","id","term","req"}`。
  - 失败：`{"event":"error","error":…,"req"}`，`error` 取 `changed`、`typed`、`too long`、`unknown key`、`empty`、`ended`、`OLD_RUN_REPLY`、`NO_TEXT_TERMINAL` 或 `TERM_BUSY`（文字都照探查分支）。
  - 字节的顺序照探查：先是字（程序开了 bracketed paste 就包起来），再是回车 `\r`（在 paste 外面），最后是键。键名和视图用同一张表（`term/src/keys.rs`），比如是 `Esc`，不是 `Escape`。`MAX_TEXT = 3000` 字节。
  - **我定的：** 拒绝时不把当前的 seq 和 state 带回来。手机照下一次 terms 推送重画卡片，用不着它们。
- **能力位：** 设备的 `capabilities.reply = true`。只在「有 rapp-term」并且 `cfg!(unix)` 时给。Windows 上的 `pty::local` 只在 unix 有，所以那边是 false。
- **会话的能力位：** `TermRow.reply`。新 holder 开的会话是 true。升级前开的会话（老 holder）没有这个字段，也就是 false：事先就不出按钮（代定 4-4）。
- **协议号不涨。** `LOCAL_V` 不变，Swift host 不改。老的对端收到 `ReplyTerm` 会拒绝，不会断连；手机在发之前已经看过能力位，所以碰不到这种情况。
- **CLAUDE.md Windows 第 5 条：** 这一期不给被控端的 host 加行为。文本终端走的是 rapp-term，不是 `host-core`。`Sources/rapp-host/` 和 `host-core` 都不碰，所以「`host-core` 和它的样本在同一个提交里改」这一条不会被触发。`workers.rs` 里只加了一个 `cfg!(unix)` 表达式，没有改任何 `cfg(windows)` 代码块，不需要跑 Windows 门禁。以后要是给 Windows 的 svc 加回复，就要照第 5 条，在 Windows 机器上过 `scripts/check-windows.ps1`。
- **`rapp emit`（Part A）：** 本机 IPC 加 `{"cmd":"emit","level","text","key"?,"session"?}`，发到中心服务的事件和 `services/center/api/events.md` 里已有的 `emit` 一样（`src:"emit"`）。中心服务那边不用改。

---

## 验收对照

| 验收 | 保证它的任务 | 真机（用户做，不挡别的任务） |
|---|---|---|
| 3 允许：滑出不发；在按钮上松手就发，卡片离开；A 的大小不变 | 3、4（通路，不碰 fit 的测试）、7、9（滑出取消）、10（发、3 秒、离开）、11（放行卡片）、18（矩阵） | U1 |
| 4 `git push`：撤不回；点一次变「再点一次确认」，3 秒复原；点两次才发 | 6（清单）、9（两次和 3 秒）、11（条纹行）、18 | U2 |
| 9 计划：没装 skill 是取自原文的三条，标「取自计划原文」；装了是它自己的三行，标「它自己写的要点」；同意就开始干；按住要改说一句，它收到 | 1、2（P4）、8（挂到卡片）、10（同意和要改的发法）、11（评审卡片）、12（要改的语音）、17（skill 和 hook） | U3 |

U1–U3 写在 Task 19 里，记进 `tasks/todo.md`。合并不等它们。

---

## Part A：rapp-state P4（分支 `feat/state-emit`）

这一部分在 `.worktrees/state-emit` 上做，单独合并到本机 main。Task 8 开工前，`feat/phone-v1c` 先 `git merge main`，把它带进来。

### Task 1：终端里有 `RAPP_TERM`

**Files:**
- Modify: `rust/term/src/pty/holder.rs`（建 `CommandBuilder` 的地方，约 218 行）
- Test: `rust/term/tests/holder_env.rs`

**Interfaces:**
- Produces: rapp-term 开的每个子进程，环境里都有 `RAPP_TERM=term:pty:<key>`。这个值就是 hub 在 `TermRow.id` 里报的那个 id。

- [ ] **Step 1：写失败的测试** `child_sees_rapp_term`：开一个跑 `/bin/sh -c 'printf %s "$RAPP_TERM" > <tmp>/out'` 的会话，等它退出，断言 `<tmp>/out` 的内容等于这个会话在 `rapp-term serve` 列表里的 `id`。
- [ ] **Step 2：** `cargo test -p rapp-term --test holder_env`，应该 FAIL（文件是空的）。
- [ ] **Step 3：** 在 `holder.rs` 里，建子进程之前 `c.env("RAPP_TERM", format!("term:pty:{key}"))`。如果代码里已经有拼 id 的函数，就用它，不要另写一份。
- [ ] **Step 4：** 再跑，应该 PASS。再跑 `cargo test -p rapp-term`，全过。
- [ ] **Step 5：提交** `git add rust/term/src/pty/holder.rs rust/term/tests/holder_env.rs && git commit -m "feat(term): rapp 终端里有 RAPP_TERM"`。

### Task 2：`rapp emit`

**Files:**
- Modify: `rust/service/src/outbox/mod.rs`、`rust/service/src/outbox/pump.rs`、`rust/service/src/ipc.rs`
- Modify/Create: `rust/cli/src/args.rs`、`rust/cli/src/main.rs`、`rust/cli/src/emit.rs`
- Test: 同文件里的 `#[cfg(test)]`，加 `rust/cli/src/args.rs` 里已有的解析测试那一组

**Interfaces:**
- Produces:
  - `Outbox::emit(&self, body: serde_json::Value) -> bool`。有中心服务（`dest` 是 Some）时，把它排进队列并唤醒 pump，返回 true；没有时返回 false，什么都不留。
  - pump 每一轮先把排着的 emit 用 `Cache::push(body, now)` 放进缓存。`body` 里的 `src:"emit"` 会盖掉信封上的 `src:"term"`。
  - IPC `{"cmd":"emit","level","text","key"?,"session"?}` → `{"ok":true,"sink":<bool>}`。`level` 不是 `done|ask|info|clear` 就报错 `bad level`。
  - CLI：`Cmd::Emit { level: String, text: String, key: Option<String>, json: bool }`。环境里有 `RAPP_TERM` 时，自动带上 `session`。
  - 退出码：service 没在跑或者 `sink:false`，都返回 0 且不输出；加了 `--json` 时输出 `{"sink":false}`。

- [ ] **Step 1：写失败的测试。**
  - `outbox::tests::emit_without_dest_is_dropped`：`emit` 返回 false，缓存是空的。
  - `outbox::tests::emit_reaches_cache_with_src_emit`：有 dest 时，pump 跑一轮以后 `head(1)[0]["src"] == "emit"`，`["t"] == "emit"`，并且带着 `level`、`text`、`key`、`session`。
  - `ipc::tests::emit_rejects_bad_level`。
  - `args::tests::emit_parses`：`["emit","ask","要你看一下","--key","k1","--json"]` → `Cmd::Emit{level:"ask",text:"要你看一下",key:Some("k1"),json:true}`；少了 text 时报错。
- [ ] **Step 2：** `cargo test -p rapp-service outbox:: ipc::` 和 `cargo test -p rapp-cli args::`，应该 FAIL。
- [ ] **Step 3：实现。**
  - `Outbox` 加 `emits: Mutex<VecDeque<Value>>`，上限 50 条，满了丢最老的。pump 的循环里先 drain 它，再走已有的 diff。
  - CLI 照 `rapp load` 的样子走 IPC。用户的话只进 IPC，不进日志。
- [ ] **Step 4：** 再跑上面的命令，PASS。再跑 `cargo test --workspace --no-fail-fast` 和 `cargo clippy --workspace --all-targets -- -D warnings`。
- [ ] **Step 5：提交并合并。**
  - `git add` 上面列的文件，提交 `feat(state): rapp emit，带上 RAPP_TERM 的会话`。
  - 照 CLAUDE.md 合并：先在分支上 `git merge main`，再在 main 上 `git merge --no-ff feat/state-emit -m "merge: rapp emit 和 RAPP_TERM（feat/state-emit）"`。合并的输出写到文件里，不要接 tail。

---

## Part B：协议（分支 `feat/phone-v1c`，worktree `.worktrees/phone-v1c`）

### Task 3：rapp-term 接收回复

**Files:**
- Create: `rust/term/src/pty/reply.rs`（从 `git show probe/phone-v1a-4:rust/term/src/pty/reply.rs` 摘）
- Modify: `rust/term/src/pty/{mod,local,holder}.rs`、`rust/term/src/serve.rs`、`rust/term/src/list.rs`
- Test: `rust/term/tests/reply.rs`（从探查摘），`rust/term/tests/serve.rs`（加用例，不改已有的）

**Interfaces:**
- Produces:
  - `pty::reply::apply(shared: &Shared, r: &Reply) -> Result<(), Value>`；
  - `Reply { seq: Option<u64>, text: Option<String>, enter: bool, keys: Vec<String> }`；
  - `local::reply(path, token, r) -> anyhow::Result<Value>`；
  - `serve` 的 `Req::Reply { term, seq, text, enter, keys }`；
  - `Status.reply: bool`；
  - `TermRow.reply: bool`（`#[serde(default, skip_serializing_if = "std::ops::Not::not")]`）。

- [ ] **Step 1：把探查的测试摘过来，加新的。**
  - 摘过来的：`reply_writes_text_then_enter_then_keys`、`reply_refuses_changed_seq`、`reply_refuses_after_typing`、`reply_too_long`、`reply_unknown_key`、`reply_empty`、`old_holder_says_old_run`。用探查分支上的名字；名字不一样时，照这里的意思改名。
  - 新加的：
    - `reply_keeps_window_size`：回复前后，pty 的 cols/rows 一样，`fit` 的 actor 一样，viewers 的数量一样；
    - `status_rows_carry_reply_bit`：新 holder 是 true，模拟的老 holder 是 false，而且 JSON 里没有这个键；
    - `reply_text_not_logged`：日志里没有发出去的字，也没有会话 id。
- [ ] **Step 2：** `cargo test -p rapp-term --test reply --test serve`，FAIL。
- [ ] **Step 3：实现。** 照探查的分层：serve `Req::Reply` → `Worker::reply` → `local::reply` → holder 的 op `"reply"` → `reply::apply`。`apply` 在 ps 锁里核对 seq：
  - seq 不对 → `{"error":"changed"}`；
  - `input_at >= p.since` → `{"error":"typed"}`；
  - 回复也刷新 `input_at`；
  - 回复不进 serve 的 `inputs` 计数，不发 activity 事件（S4）。
  - `status_rows` 从 holder 的 `Status.reply` 填 `TermRow.reply`。
- [ ] **Step 4：** 再跑，PASS。然后 `cargo test -p rapp-term`。
- [ ] **Step 5：提交** `feat(term): 不开视图的回复（reply）和会话的 reply 位`。

### Task 4：设备间的 `ReplyTerm`，service 和 hub

**Files:**
- Modify: `rust/net/src/msg.rs`、`rust/service/src/{term,peer,workers}.rs`、`rust/hub/src/{lib,link,terms}.rs`
- Create: `rust/testkit/tests/reply_term.rs`（照 `probe/phone-v1a-4:rust/testkit/tests/probe_reply.rs`，用真的 `rapp-term`）

**Interfaces:**
- Consumes: Task 3 的 `Req::Reply`。
- Produces:
  - `Op::ReplyTerm { term, seq: Option<u64>, text: Option<String>, enter: bool, keys: Vec<String> }`，serde 规则照探查：None、false、空数组都不写；
  - hub cmd `reply_term` 和事件 `term_replied`；
  - `capabilities()["reply"]`。

- [ ] **Step 1：写失败的测试。**
  - `msg::tests::reply_term_roundtrip`：全字段和最少字段各一个。
  - `link::tests::reply_term_is_not_repeatable`：`repeatable(&Op::ReplyTerm{..}) == false`。
  - `workers::tests::capabilities_has_reply_when_terminal`：有 rapp-term 并且是 unix，结果为 true；没有 rapp-term，结果为 false。
  - `term::tests::reply_log_fields_count_only`：日志字段只有 `seq`（是否有）、`text`（是否有）、`keys`（个数）。
  - testkit 里的 `reply_term_end_to_end`：hub → relay → service → `rapp-term`，程序收到字和回车，`term_replied` 回来，A 的窗口大小没变；seq 不对时回 `changed`。
- [ ] **Step 2：** `cargo test -p rapp-net -p rapp-service -p rapp-hub` 和 `cargo test -p testkit --test reply_term`，FAIL。
- [ ] **Step 3：实现。** 照探查摘代码：
  - hub `lib.rs` 的 terms 分支收 `reply_term`；
  - `link.rs` 的 `repeatable` 排除 `ReplyTerm`；
  - `terms.rs` 发 `term_replied`；
  - service `peer.rs` 的放行清单加 `ReplyTerm`；
  - `term.rs` 转成 `{"op":"reply",…}`，带 `log_fields`；
  - `workers.rs` 的 `capabilities()` 在 `"terminal"` 为 true 且 `cfg!(unix)` 时加 `"reply": true`。
- [ ] **Step 4：** 再跑 Step 2 的命令，PASS。然后 `cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`。
- [ ] **Step 5：提交** `feat(net,service,hub): reply_term 通路和 reply 能力位`。

---

## Part C：GUI

### Task 5：Dart 这一侧的通路

**Files:**
- Modify: `gui/lib/hub_client.dart`（`TermRow` 约 142 行，`termListFromJson` 约 256 行，加一个请求方法）
- Test: `gui/test/hub_reply_test.dart`

**Interfaces:**
- Produces:
  - `TermRow` 多一个命名参数 `{bool reply = false}`，字段 `final bool reply`；
  - `Future<void> HubClient.replyTerm(String id, String term, {int? seq, String? text, bool enter = false, List<String> keys = const []})`，等 `'term_replied'`；失败抛 `HubException(error)`；
  - `bool deviceCanReply(Map<String, DeviceProbe> probes, String id)`，即 `probes[id]?.apps?.capabilities?['reply'] == true`，放在 `gui/lib/phone/reply_model.dart` 里。

- [ ] **Step 1：写失败的测试。**
  - `termListFromJson reads reply`：有 `"reply":true` 时为 true，没有这个键时为 false。
  - `replyTerm sends one cmd and resolves on term_replied`：FakeTransport 收到的 cmd 正好是 `{"cmd":"reply_term","id":"m1","term":"term:pty:a","seq":7,"keys":["1"],"req":…}`，没有 `text`，也没有 `enter`。
  - `replyTerm throws the error word`：回 `{"event":"error","error":"changed"}` 时，抛出的 `HubException.message == 'changed'`。
- [ ] **Step 2：** `~/development/flutter/bin/flutter test test/hub_reply_test.dart`，FAIL。
- [ ] **Step 3：** 用已有的 `_request` 实现。只在有值的时候写 `seq`、`text`、`enter`、`keys`。
- [ ] **Step 4：** 再跑，PASS。然后 `flutter test test/hub_client_test.dart`，老测试照旧全过。
- [ ] **Step 5：提交** `feat(gui): HubClient.replyTerm 和会话的 reply 位`。

### Task 6：对照表（I3、C7、C8、C9）

**Files:**
- Create: `gui/lib/phone/reply_table.dart`
- Test: `gui/test/phone/reply_table_test.dart`

**Interfaces:**
- Produces（都是纯函数和常量）：
  - `class ToolKeys { final List<String>? allow, deny; final bool options; final List<String>? planOk, planRevise; }`；
  - `ToolKeys? toolKeysOf(AgentTool? tool)`；
  - `ToolKeys` 的三家：
    - `claude-code`：allow `["1"]`、deny `["Esc"]`、options true、planOk `["2"]`、planRevise `["3"]`；
    - `codex`：全是 null（代定 2-2）；
    - `agy`：allow `["1"]`、deny 用 `denyKeysFor(msg)`、options false、plan null（代定 2-6）；
  - `List<String> denyKeysFor(AgentTool tool, String msg)`：agy 的 `msg` 以 `Approve Edit:` 开头时返回 `["2"]`，否则返回 `["Esc"]`；
  - `sealed class ParsedAsk`，有三种：
    - `AskApprove(String tool, String target)`；
    - `AskOptions(String question, List<String> options)`；
    - `AskPlan()`；
  - `ParsedAsk? parseAsk(AgentTool tool, String? kind, String msg)`；
  - `String? plainWords(String command)`；
  - `({String word, String why})? riskOf(String command)`；
  - `String doneLine(String? msg)`。

- [ ] **Step 1：写失败的测试。** 值都照探查 2 和规格。
  - **parseAsk：**
    - CC 的 `'approve Bash: touch a101.txt'` → `AskApprove('Bash','touch a101.txt')`；
    - CC 的 `'approve plan'`，kind 是 permission → `AskPlan()`；
    - CC 的 `'answer: 迁移脚本用哪种写法？ (SQL · Rust · 先不迁)'` → `AskOptions('迁移脚本用哪种写法？', ['SQL','Rust','先不迁'])`。用最后一对括号来分；
    - 五个选项、括号不配对、`·` 两边没有空格，都返回 null；
    - CC 的 `msg` 含 `trust this folder`，agy 的 `msg` 含 `Trust this folder?`，都返回 null（代定 2-7）；
    - agy 的 `'Approve Edit: Write: /a/b.txt'` → `AskApprove('Edit','Write: /a/b.txt')`；
    - agy 的 `'Approve plan'` → null（代定 2-6）；
    - codex 的任何 `msg` → null（代定 2-2）；
    - 空的 `msg` → null。
  - **riskOf：**
    - `'git push origin main'` → `why == '推上去以后收不回来'`；
    - `'cargo test && git push'` → 命中（`&&`、`;`、`|` 之后的每一段都要看）；
    - `'rm -rf build'` → `'删掉的找不回来'`；
    - `'git reset --hard HEAD~1'` → 命中；
    - `'git reset --soft HEAD~1'` → null；
    - `'curl -X POST …'` 和 `'curl -d x …'` → 命中，`'curl https://x'` → null；
    - `'psql -c "DROP TABLE t"'` → 命中，不分大小写；
    - `'echo dropped'` → null（按词来认，`dropped` 不算 `drop`）。
  - **plainWords：**
    - `'cargo test -p x'` → `'想跑测试'`；
    - `'git push origin main'` → `'想把改动推到远端'`；
    - `'ls'` → null。
  - **doneLine：**
    - null 或空 → `'做完了'`；
    - `'改好了 [a.dart](file:///x/a.dart)'` → `'改好了 a.dart'`。
  - **文字：** 表里所有的字都不含「安全」两个字。
- [ ] **Step 2：** `flutter test test/phone/reply_table_test.dart`，FAIL。
- [ ] **Step 3：实现。**
  - 撤不回清单第一版（C9），每条都带原因：
    - `rm`、`git clean`、`git reset --hard`：「删掉的找不回来」；
    - `git push`：「推上去以后收不回来」；
    - `npm publish`、`cargo publish`：「发布出去就收不回来」；
    - `curl` 带 `-X POST|PUT|PATCH|DELETE`、`-d`、`--data*`、`-F`：「请求发出去就收不回来」；
    - `gh pr merge`：「合并以后要另做一次才能撤」；
    - `gh release`：「发布了别人马上能看到」；
    - `drop`、`delete`、`truncate`（整词，不分大小写）：「数据删了找不回来」。
  - 人话表第一版（C7）：
    - `cargo test`、`flutter test`、`npm test`、`pytest`、`go test`：「想跑测试」；
    - `cargo build`、`flutter build`、`npm run build`：「想编译」；
    - `git commit`：「想提交改动」；
    - `git push`：「想把改动推到远端」；
    - `rm`：「想删文件」；
    - `npm install`、`pip install`、`cargo add`：「想装依赖」；
    - 工具名是 `Write`、`Edit`：「想改文件」；`Read`：「想读文件」。
  - **我定的：** 这两张表放在 Dart 代码里，不放 `app_profiles.json`。见「规格要跟着改的」。
- [ ] **Step 4：** 再跑，PASS。
- [ ] **Step 5：提交** `feat(phone): 各家的键、人话表和撤不回清单`。

### Task 7：一张卡片有哪些按钮

**Files:**
- Create: `gui/lib/phone/reply_model.dart`
- Test: `gui/test/phone/reply_model_test.dart`

**Interfaces:**
- Consumes: Task 6；`HomeItem`（Task 8 加的 `points` 和 `pointsBy`）；`TermRow`；`toolOf`（`gui/lib/embed/strip_tools.dart`）。
- Produces:
  - `enum ReplyKind { approve, options, review, done, none }`；
  - `class ReplyTarget { final String device, term; }`，带 `==` 和 `hashCode`；
  - `class CardReply { ReplyKind kind; ReplyTarget? target; int? seq; List<String>? allow, deny; List<String> options; List<String>? planOk, planRevise; String? plain; ({String word, String why})? risk; String? quote; bool voice; }`；
  - `CardReply replyOf(HomeItem item, {required TermRow? row, required bool deviceReply})`。

- [ ] **Step 1：写失败的测试。**
  - `cc permission gives allow and deny`：`row.reply == true`，`deviceReply == true`，`msg` 是 `'approve Bash: cargo test'`。期望 kind 是 approve，`allow == ['1']`，`deny == ['Esc']`，`plain == '想跑测试'`，`quote == 'cargo test'`，`risk == null`，`seq` 等于 row 的 seq。
  - `git push is risky`：`risk.word == '撤不回'`，`risk.why == '推上去以后收不回来'`。
  - `old device shows go-look only`：`deviceReply == false` → none。
  - `session from old holder shows go-look only`：`row.reply == false` → none。
  - `center-only item shows go-look only`：`row == null` → none。
  - `empty msg shows go-look only`。
  - `codex permission is go-look only`。
  - `cc question gives numbered options`：`options` 有 3 个，回复的键是 `['<N>']`，N 从 1 开始。
  - `cc plan with points gives review`：`item.points` 有 3 行 → review，`planOk == ['2']`，`planRevise == ['3']`。
  - `cc plan without points is go-look only`（代定 2-3）。
  - `done gives voice`：done 的卡片，`row.reply` 为 true → kind 是 done，`voice == true`。
- [ ] **Step 2：** `flutter test test/phone/reply_model_test.dart`，FAIL。
- [ ] **Step 3：实现。** 只有 `item.kind` 是 waiting 或 done、`item.id` 以 `term\n` 开头时才可能有按钮。`target` 从 `item.id` 的 `term\n<dev>\n<term>` 里取。
- [ ] **Step 4：** PASS。
- [ ] **Step 5：提交** `feat(phone): 卡片的回复按钮由什么决定`。

### Task 8：评审要点挂到卡片上（I7、C19、C24）

开工前 `feat/phone-v1c` 先 `git merge main`，把 Part A 带进来。

**Files:**
- Modify: `gui/lib/phone/home_model.dart`（`HomeItem` 和 `buildHome` 的第 3 段）
- Test: `gui/test/phone/home_review_test.dart`（新文件；`home_model_test.dart` 一个字不改）

**Interfaces:**
- Produces:
  - `HomeItem` 加可选字段 `final List<String>? points`、`final PointsBy? pointsBy`，还有 `final String? pointsEid`；
  - `enum PointsBy { agent, rule }`；
  - `const planKeyPrefix = 'plan:'`，`const planRuleKeyPrefix = 'plan-rule:'`；
  - `List<String> pointLines(String text)`。

**规则：**
- emit 的 `key` 是 `plan:<会话>` 或 `plan-rule:<会话>`，并且带着 `session` 时，算作评审要点。
- 这个会话现在在等你点头（CC 的 `msg == 'approve plan'`），并且 emit 的 `at` ≥ 等待的 `since` − 120 s：挂到那张卡片上，不单独出行。`plan:` 优先，没有它才用 `plan-rule:`。挂上去以后 `line` 改成「出了计划，等你点头」。
- 会话不在等你点头了，并且 emit 的 `at` 早于会话现在状态的 `since`：这条要点已经过时，不显示。
- 其他情况：照今天的样子，当普通消息显示（I7）。
- `pointLines`：
  - 按换行分；
  - 去掉每行开头的 `- `、`* `、`1.`、`1)`；
  - 丢掉空行；
  - 最多取 3 行（C23）。

- [ ] **Step 1：写失败的测试。**
  - `agent points attach to the plan card`：卡片带 3 行要点，`pointsBy == PointsBy.agent`，消息区没有这一行。
  - `rule points used only without agent points`。
  - `stale plan points are hidden`。
  - `plan points of a session not waiting show as a message`：emit 比会话的 `since` 晚，会话没在等 → 普通消息。
  - `pointLines keeps three`：5 行进去，出来 3 行，序号和 `- ` 都去掉了。
  - `bare approve plan reads 出了计划，等你点头`。
- [ ] **Step 2：** `flutter test test/phone/home_review_test.dart`，FAIL。
- [ ] **Step 3：** 在 `buildHome` 第 3 段之前，先扫一遍 emit，按会话把要点收起来，再在第 1 段建等待卡片的时候用上。`buildHome` 的参数不改。
- [ ] **Step 4：** PASS。然后 `flutter test test/phone/`，老测试照旧全过。
- [ ] **Step 5：提交** `feat(phone): 评审要点挂到等你点头的卡片上`。

### Task 9：`PhoneHoldButton`（C5、C6、C10）

**Files:**
- Create: `gui/lib/phone/hold_button.dart`
- Test: `gui/test/phone/hold_button_test.dart`

**Interfaces:**
- Produces:
  - `PhoneHoldButton({required String label, required Object armKey, required VoidCallback? onSend, bool primary = false, bool risky = false, Widget? leading, Duration confirmFor = const Duration(seconds: 3)})`；
  - 高 `phonePrimaryTap`（64）；
  - `onSend == null` 时显示成不能点的样子。

- [ ] **Step 1：写失败的测试。**
  - `sends on release over the button`。
  - `press shows pressed look`：按下时背景是 `t.accent`，前景是 `t.accentInk`，松手后恢复。
  - `slide off cancels`：按下，移到按钮外面再松手 → `onSend` 没被调用，样子复原。
  - `voids when the card changes under the finger`：按着的时候用新的 `armKey` 重建，再松手 → 没发。
  - `voids when removed mid-press`：按着的时候把按钮拿掉 → 没发，也没有异常。
  - `risky needs two releases within 3 s`：第一次松手没发，字变成「再点一次确认」，颜色是 `t.accent`；第二次松手发了一次。
  - `risky arm resets after 3 s`：`tester.pump(3 s)` 以后字变回原样，这时再松手仍然不发。
  - `risky arm cancelled by slide off`。
  - `size is 64`。
- [ ] **Step 2：** `flutter test test/phone/hold_button_test.dart`，FAIL。
- [ ] **Step 3：实现。**
  - 用 `Listener` 收 down、move、up、cancel。用按钮自己的 `RenderBox` 判断手指在不在里面。
  - 按下时记住 `armKey`。`didUpdateWidget` 看到 `armKey` 变了，就作废这一下，也清掉撤不回的确认。
  - 确认的计时用 `Timer`，`dispose` 时取消。
  - `Semantics(button: true, label: …)` 的 `onTap` 直接发。撤不回的也一样，要两次。
- [ ] **Step 4：** PASS。
- [ ] **Step 5：提交** `feat(phone): 松手才发的按钮，撤不回要点两次`。

### Task 10：`PhoneReplies`（C12、C13、C15、V5）

碰 `main_state.dart` 和 `history/`：合并前先 `git merge main`。

**Files:**
- Create: `gui/lib/phone/replies.dart`
- Modify: `gui/lib/phone/phone_nav.dart`（加 `late final PhoneReplies replies = PhoneReplies(state);`）、`gui/lib/ui/main_state.dart`（只加 `SessionMeta replyMeta(String device, TermRow row)`）、`gui/lib/history/input_recorder.dart`（只加 `Future<void> replied(SessionMeta m, String text, DateTime at)`）
- Test: `gui/test/phone/replies_test.dart`

**Interfaces:**
- Consumes:
  - Task 5 的 `replyTerm`；
  - Task 7 的 `ReplyTarget` 和 `CardReply`；
  - `MainState.hub`、`hub.termLists`、`offline`。
- Produces:
  - `PhoneReplies extends ChangeNotifier`，构造：`PhoneReplies(MainState state, {ReplySender? send, Duration settle = replySettle, Duration reviseGap = const Duration(milliseconds: 400)})`；
  - `typedef ReplySender = Future<void> Function(ReplyTarget t, {int? seq, String? text, bool enter, List<String> keys})`；
  - `Future<void> keys(String itemId, ReplyTarget t, int? seq, List<String> keys, {required String doneWord})`；
  - `Future<void> say(String itemId, ReplyTarget t, String text)`：字加回车，不带 seq；
  - `Future<void> revise(String itemId, ReplyTarget t, int seq, List<String> keys, String text)`：先发带 seq 的键，等 `reviseGap`，再发字加回车；
  - `ReplyOutcome? outcomeOf(String itemId)`，`ReplyOutcome { String word; bool pending; bool failed; }`；
  - `void markEid(String eid)`：同意或要改发出以后，经 `stateSync.markHandled` 标掉挂着的要点；
  - 常量 `const replySettle = Duration(seconds: 3);`。

**结果的话：**

| 情况 | 卡片上写 |
|---|---|
| 发出去了，在等 | `doneWord`（「已允许」「已拒绝」「已回复 N」「已同意」「已发出」） |
| 状态离开了等待，或者 seq 变了 | 卡片照新状态离开（C15）；还在的卡片（做完的）清掉结果 |
| 发之前本地看到 seq 或状态变了，或者 A 回 `changed`、`typed` | 「它已经不在等这一问了」 |
| 3 秒内没离开等待，或者 hub 报了别的错 | 「没成功，进去看看」 |
| A 回 `OLD_RUN_REPLY` | 「这个会话是升级前开的，进去看看」 |
| 松手时 A 离线，或者 hub 不可用 | 「连不上 A，没发」 |

- [ ] **Step 1：写失败的测试。** 用假的 `ReplySender` 和 `fakeAsync`。
  - `sends seq and keys once`。
  - `local seq check skips send`：`hub.termLists` 里的 seq 已经变了 → 没调用 sender，写「它已经不在等这一问了」。
  - `leaves wait within settle is success`。
  - `stays waiting past settle shows go-look and never resends`：sender 只被调用了一次。
  - `changed refusal shows not-waiting`。
  - `old-run refusal shows go-look`。
  - `offline at release sends nothing`。
  - `hub error after send shows go-look and never resends`。
  - `revise sends key then text with enter`：调用了两次，第一次 `keys:['3']` 带 seq，第二次是 `text`、`enter:true`、没有 seq，两次之间隔 ≥ `reviseGap`。
  - `say records input history`：`recorder.replied` 被调用了一次，带 device、session、projects；`keys` 不记。
  - `outcome survives a form switch`：发出以后，用同一个 `PhoneNav` 拆掉再重建 `phoneFormSwitch` 的手机树，结果还在，3 秒的核对照常结束。
- [ ] **Step 2：** `flutter test test/phone/replies_test.dart`，FAIL。
- [ ] **Step 3：实现。**
  - 默认的 sender 调 `state.hub!.replyTerm(t.device, t.term, …)`。
  - 成功与否听 `hub` 的 terms 推送来判断（`hub.termLists[device]` 里那一行的 `ps.state`、`ps.seq`），不另外去问。
  - `replied` 写一条 `sent` 记录，只有一段 text，形状照 `_sentRecord`，然后调 `onSent`。
- [ ] **Step 4：** PASS。然后 `flutter test`，全过。
- [ ] **Step 5：提交** `feat(phone): 回复的核对、3 秒和结果`。

### Task 11：卡片上的回复区（C2、C4、C7–C9、C16、C18–C20、C23、C24）

**Files:**
- Create: `gui/lib/phone/reply_card.dart`
- Modify: `gui/lib/phone/widgets.dart`（`PhoneCard` 加可选的 `Widget? actions`；有它时代替那一个按钮；没有时和今天一样）、`gui/lib/phone/home_screen.dart`（建 `CardReply` 和回复区）
- Test: `gui/test/phone/reply_card_test.dart`

**Interfaces:**
- Consumes: Task 7、9、10；Task 12 的 `PhoneVoiceButton`（Task 12 做完之前，先放一个 `voice: null` 的占位）。
- Produces: `ReplyActions({required HomeItem item, required CardReply reply, required PhoneReplies replies, Widget Function(String label, ReplyVoiceUse use)? voice})`。

**样子（照稿子 V1Allow、V1Risky、V1Ask、V1Plan、V1PlanRule、V1DoneCard）：**
- **放行：**
  - 有 `plain` 时，先是一行 `plain` 的标题；
  - 然后是等宽字的 `quote`；
  - 有 `risk` 时加一条带条纹的行。条纹用 `t.warn` 的两种透明度画，边框是 `t.warn`，内容是三角、「撤不回」加 `why`；
  - 最底下一行：左「拒绝」，右「允许」（主按钮）。两个都是 `PhoneHoldButton`，中间隔 12。
- **提问：** 选项竖着排，每个都是一整行的 `PhoneHoldButton`，最前面是等宽的序号，行与行隔 12。下面一行灰字「选项都不合适？按住说话，回一句。」
- **评审：**
  - 1–3 行要点，每行前面是等宽的序号。每行最多两行，再长就加省略号。用普通的 `Text`，不认链接；
  - 来源一行：「它自己写的要点 · 点上面的字看全文」或「取自计划原文 · 点上面的字看全文」；
  - 按钮：左「要改」（按住说话），右「同意」（主按钮）。
- **做完：** 左「说一句」（按住说话），右「知道了」（主按钮，用已有的 `_gotIt`，不往终端里发任何东西）。
- **没有麦克风或识别器（V6）：** 不出「说一句」和「要改」。
  - 评审卡片只剩「同意」，外加卡片上的字可以点进去。
  - 做完卡片只剩「知道了」。
- **结果：** `replies.outcomeOf(item.id)` 有值时，按钮那一行换成结果的话（至少 64 高）。失败的结果在旁边加一个「进去看」。

- [ ] **Step 1：写失败的测试**，三套主题各跑一遍。
  - `approve card has deny left allow right at 64`：「拒绝」在「允许」左边，两个都高 64，中间隔 ≥12。
  - `risky stripe says why`：`git push` 的卡片有「撤不回」和「推上去以后收不回来」，颜色来自 `t.warn`。
  - `options numbered and vertical`。
  - `review shows source label`：agent 的写「它自己写的要点」，rule 的写「取自计划原文」。
  - `points are plain text`：要点里有 `[x](http://y)`，就照原样显示，没有可以点的链接。
  - `card swap mid-press sends nothing`：按着「允许」的时候，`buildHome` 换出一张新卡片 → sender 没被调用。
  - `done card gotIt sends nothing to the terminal`。
  - `go-look only when reply is none`：和今天的 `PhoneCard` 一样。
  - `no 安全 anywhere`：找遍所有的 `Text`，都没有这两个字。
- [ ] **Step 2：** `flutter test test/phone/reply_card_test.dart`，FAIL。
- [ ] **Step 3：实现。**
  - `home_screen.dart` 建 `replyOf(item, row: <hub.termLists 里那一行>, deviceReply: deviceCanReply(...))`。只有焦点卡片（`card`）放回复区，下面的行照旧。
  - 允许、拒绝、选项、同意都调 `replies.keys(...)`。同意发出以后调 `replies.markEid(item.pointsEid)`。
- [ ] **Step 4：** PASS。然后 `flutter test test/phone/`，老测试全过。
- [ ] **Step 5：提交** `feat(phone): 卡片上的允许、拒绝、选项、评审和做完`。

### Task 12：卡片和首页的按住说话（V1、V2、V4、V6）

碰 `main_state.dart`：合并前先 `git merge main`。

**Files:**
- Modify: `gui/lib/embed/voice_button.dart`
  - 加 `Widget voiceHoldArea(VoiceHold hold, {required Widget child})`，就是 `voiceButton` 里那个 `Listener`，原样拿出来；
  - `voiceButton` 改成用它，行为一点不变；
  - `sendVoice` 开头加一句：`state.voiceSends[session.sid]` 有值时交给它。
- Modify: `gui/lib/ui/main_state.dart`
  - 加 `typedef VoiceSend = String? Function(String text, VoiceOrigin voice);` 和 `final Map<Object, VoiceSend> voiceSends = {};`；
  - `tidyOf` 的保留条件改成 `remote.containsKey(sid) || voiceSends.containsKey(sid)`；
  - `_makeTidy` 的 `allowed` 和 `send`：`voiceSends[s]` 有值时用它，不看 `secureFocus`。
- Create: `gui/lib/phone/phone_voice.dart`
- Test: `gui/test/phone/phone_voice_test.dart`，再加 `gui/test/embed/voice_sends_test.dart`（新文件；`voice_button` 和 `voice_tidy` 的老测试不改）

**Interfaces:**
- Produces:
  - `enum ReplyVoiceUse { say, revise, assistant }`；
  - `class PhoneVoice extends StatefulWidget { PhoneVoice({required MainState state, required Object key2, required VoiceSend send, required void Function(String text) edit, required Widget Function(BuildContext, VoiceHold) builder}) }`。它管一个 `VoiceHold` 的生命周期，在 `initState` 里把 `key2` 注册进 `state.voiceSends`，在 `dispose` 里拿掉。`VoiceOverlay` 和 `VoiceTidyCard` 由它放进一个 `Stack`；
  - `Widget phoneVoiceButton(VoiceHold hold, String label)`：宽，高 64，左边是麦克风图标。

**接法：**
- 说一句：`send` = `replies.say(item.id, target, text)`，返回 null。
- 要改：`send` = `replies.revise(item.id, target, seq, planRevise, text)`。
- 编辑（V1 的「编辑」）：
  - 说一句：进那个会话，字放进它的草稿（`session.composer.keep(text)`，`open = true`）；
  - 要改：先发 `planRevise` 的键（带 seq），再进会话，放进草稿。
- AI 整理：照现有的 `tidyOf(key2)`。超过 10 个字、配了模型接入点时出整理卡片。
- `state.voice == null`（V6）：不建 `VoiceHold`，`builder` 不出按住说话。

- [ ] **Step 1：写失败的测试。**
  - `voiceSends routes sendVoice`：注册了以后，`sendVoice` 调的是它，没有走 `port.composerSend`。
  - `no voiceSends keeps today's path`：和今天的结果一样。
  - `tidy kept for a voiceSends key`：`tidyOf(key)` 两次拿到的是同一个对象。
  - `say sends text with enter via replies`：假的 `VoiceService` 识别出「再加一个测试」，松手 → `replies.say` 收到这句。
  - `revise edit sends 3 then opens session with draft`。
  - `no recognizer hides voice buttons`。
  - `voice button is 64 high`。
- [ ] **Step 2：** `flutter test test/phone/phone_voice_test.dart test/embed/voice_sends_test.dart`，FAIL。
- [ ] **Step 3：** 实现，然后把 Task 11 的占位接上。
- [ ] **Step 4：** PASS。然后跑完整的 `flutter test`，`voice_*` 的老测试全过。
- [ ] **Step 5：提交** `feat(phone): 说一句、要改用现有的按住说话，走回复通路`。

### Task 13：阅读视图的数据（S1、S2、S8）

**Files:**
- Create: `gui/lib/term/reflow.dart`（`git show probe/phone-v1a-3:gui/lib/term/reflow.dart`）、`gui/test/term/reflow_test.dart`、`gui/test/term/reflow_samples/`（17 个样本，照探查原样）
- Modify: `gui/lib/term/term_model.dart`（加 `Set<int> get wrapped => Set.unmodifiable(_wrapped);`）
- Create: `gui/lib/phone/reading_view.dart`
- Test: `gui/test/phone/reading_view_test.dart`

**Interfaces:**
- Produces:
  - 探查里的 `reflow(...)`、`ReadBlock`、`ReadKind`、`Speaker`；
  - 新加的 `List<ReadBlock> reflowLines(List<TermLine> lines, {Set<int>? wrapped, required int cols, int? screenFrom})`。要先把 `_parse` 改成吃 cells，`reflow` 和 `reflowLines` 共用它；
  - `PhoneReadingView({required TermModel model})`。

- [ ] **Step 1：写失败的测试。**
  - 探查的 12 个测试原样带过来。
  - 新加：
    - `reflowLines equals reflow on samples`：每个样本先转成 `TermLine`，两种算法结果一样；
    - `reading view anchors at the bottom`：最后一块紧贴视图底部；
    - `raw block scrolls sideways`：宽表格所在的那一块有横向的 `Scrollable`，整页没有横向滚动；
    - `only the current screen`：历史里的行不显示（代定 3-1）；
    - `one column, no speaker sides`：所有块的左边距都一样（S8、代定 3-3）。
- [ ] **Step 2：** `flutter test test/term/reflow_test.dart test/phone/reading_view_test.dart`，FAIL。
- [ ] **Step 3：实现。**
  - `PhoneReadingView` 监听 `model`。每次变化，只对当前屏幕 `reflowLines`，这一步 <1 ms，不用缓存。
  - 用 `ListView(reverse: true)`，从底下往上读，可以往上滚。
  - `raw` 和 `tool` 两种块用等宽字，横向滚。其余的用正文字，按手机的宽度换行。
  - 颜色只取 token。
- [ ] **Step 4：** PASS。
- [ ] **Step 5：提交** `feat(phone): 阅读视图（只看当前屏幕）`。

### Task 14：会话里面（S1–S7、V3、V4、V6）

碰 `stage.dart` 和 `composer_panel.dart`（共享）：只加可选参数。

**Files:**
- Modify: `gui/lib/phone/session_view.dart`（改成 StatefulWidget）、`gui/lib/phone/widgets.dart`（`PhonePage` 加 `Widget? trailing`，放在「返回」的同一行右边）
- Modify:
  - `gui/lib/embed/composer_panel.dart`：`composerLayer` 加 `Widget Function(BuildContext, VoiceHold? hold, double bottom)? phoneStack`。不为 null 时代替 `_iosStack`；
  - `gui/lib/ui/stage.dart`：`stageOverlays` 加 `phoneStack`，往下传。
- Create: `gui/lib/phone/reply_bar.dart`
- Test: `gui/test/phone/session_reading_test.dart`（新文件；`session_view_test.dart` 不改）

**Interfaces:**
- Consumes: Task 11 的 `ReplyActions`，Task 12 的 `PhoneVoice` 和 `phoneVoiceButton`，Task 13 的 `PhoneReadingView`。
- Produces: `PhoneReplyBar({required VoiceHold? hold, required VoidCallback onType})`：宽的「按住说话，回一句」（64 高），旁边一个 64×64 的「打字」方块（`Semantics label: '打字输入'`）。

**规则：**
- **文本终端默认是阅读视图。** `TermStage(fit: false)` 照样挂着，外面包一层 `Offstage(offstage: reading)` 再包 `ExcludeFocus(excluding: reading)`，所以视图和 `TermModel` 一直在走。右上角是「看原样」；切过去以后，字变成「看阅读视图」。
- 图形 app 和桌面会话照旧是远程画面，没有「看原样」（S5）。
- **这个会话有卡片在等你**（`buildHome` 里 `sessionKey` 等于当前会话的那张）：卡片钉在底部，回复条上面，用的是同一个 `ReplyActions`（S3）。
- **回复条：**
  - 按住说话：会话有 reply 能力时，在 `voiceSends[sid]` 注册 `replies.say`（V4，不开新视图，不改大小）；没有能力时走今天的 `sendVoice`（视图是 `fit:false`，不改大小）。
  - 打字：`session.composer.open = true`，升起现有的输入板（V3）。
- **边缘右滑返回（S7）：** 只在阅读视图里有效。左边 20 px 宽的区域，右滑超过 80 px 就调 `nav.home()`。远程画面和「看原样」里都没有。
- **S4：** 这一页不调用 `stageSize`，也不发 `fit:true` 的 view。

- [ ] **Step 1：写失败的测试。**
  - `term opens in reading view`。
  - `看原样 toggles to the stage`：TermStage 一直挂着，切换前后 `FakeTermSessionPort` 记下的 view 调用都是 `fit:false`，没有改大小的调用。
  - `pinned card at the bottom`。
  - `reply bar hold routes to replies.say`。
  - `type square opens the composer`。
  - `edge swipe returns only in reading view`。
  - `picture has no 看原样 and no edge swipe`。
  - `no recognizer shows only the type square`。
- [ ] **Step 2：** `flutter test test/phone/session_reading_test.dart`，FAIL。
- [ ] **Step 3：** 实现。
- [ ] **Step 4：** PASS。然后跑完整的 `flutter test`。`session_view_test.dart` 和 Pad 的 `stage`、`composer` 测试都不改，照旧全过。
- [ ] **Step 5：提交** `feat(phone): 会话里面是阅读视图和回复条`。

### Task 15：手机上的输入控件到 56（R36）

**Files:**
- Create: `gui/lib/embed/input_metrics.dart`
- Modify: `gui/lib/embed/key_bar.dart`、`gui/lib/embed/key_bar_keys.dart`（常量 `keyBarKeyHeight`、`keyBarGap` 不改，加读 `InputMetrics` 的函数）、`gui/lib/embed/phrase_strip.dart`（`phraseStripChip` 在 `phrases.dart`，常量不改）、`gui/lib/embed/input_dock.dart`、`gui/lib/embed/composer_panel.dart`（输入板的 ＋ 和「发送」）
- Modify: `gui/lib/phone/session_view.dart`：把会话那一层包进 `InputMetrics.phone`
- Test: `gui/test/embed/input_metrics_test.dart`

**Interfaces:**
- Produces:
  - `class InputMetrics extends InheritedWidget { final double key, gap, chip, panelButton; }`；
  - `static InputMetrics of(BuildContext)`：上面没有包它的时候，返回 `InputMetrics.standard`，也就是今天的 `keyBarKeyHeight = 42`、`keyBarGap = 4`、`phraseStripChip = 30`、输入板按钮 40；
  - `InputMetrics.phone`：`key: 56, gap: 12, chip: 56, panelButton: 56`；
  - `double keyBarHeightFor(InputMetrics m, int rows)`。

- [ ] **Step 1：写失败的测试。**
  - `standard equals today's constants`：用 `standard` 算出来的 key bar 高度，等于 `keyBarHeight(rows)`。
  - `phone metrics give 56 taps`：在 `InputMetrics.phone` 下面建 KeyBar、PhraseStrip、快捷区第一行（命令▾、常用语▾）和 ComposerPanel，每个可点处都 ≥56，相邻的至少隔 12。
  - `pad unchanged`：不包 `InputMetrics` 时，几个高度都和今天一样。
- [ ] **Step 2：** `flutter test test/embed/input_metrics_test.dart`，FAIL。
- [ ] **Step 3：** 写死的高度都改成从 `InputMetrics.of(context)` 取。键的宽度照旧按 `keyBarColumns` 平分。
- [ ] **Step 4：** PASS。然后跑完整的 `flutter test`，key bar、phrase、input_dock、composer 的老测试全过。
- [ ] **Step 5：提交** `feat(phone): 手机上的快捷区和输入板到 56`。

**还剩的：** 输入板里的文本框本身不是可点的按钮，不算。V1c 以后，手机上要是还有别的输入控件不到 56，记进 todo，在「V1 收尾」里做。V1d 不管这一块。

### Task 16：助理（V7–V10、H12）

**Files:**
- Create: `gui/lib/phone/assistant_store.dart`、`gui/lib/phone/assistant_page.dart`
- Modify:
  - `gui/lib/phone/phone_nav.dart`：`PhoneView` 加 `assistant`；
  - `gui/lib/phone/phone_shell.dart`：路由；
  - `gui/lib/phone/sheet.dart`：「去别处」第一行加「助理」，后面是「设备」「设置」，行间隔 12；
  - `gui/lib/phone/home_screen.dart`：底下加一个大的「按住说话，跟助理说」（H12）。
- Test: `gui/test/phone/assistant_test.dart`

**Interfaces:**
- Produces:
  - `class AssistantNote { final String id; final String text; final int at; final String? project; }`；
  - `class AssistantStore extends ChangeNotifier { AssistantStore(String dir); List<AssistantNote> get notes; Future<void> add(String text, {String? project}); Future<void> remove(String id); }`；
  - 存在 `<DataDir.localDir>/assistant.json`，只在这台手机上，不上传（V9）；
  - `AssistantPage({required AssistantStore store, required PhoneNav nav})`。

**规则：**
- 首页按住说话用 `PhoneVoice`，`key2` 是 `'assistant'`。`send` 存进 store 后返回 null，不发给任何终端（V7）。不出 AI 整理。「编辑」进助理页，字放进页面底部的输入框，「存下」以后才进列表。
- 页面最上面写「助理还不会回答，先替你记着。」（V8）。
- 列表按时间排，每条带时间和当时的项目（有的话）。
- 每条右边一个「删」，56 高。长按复制，复制后提示「已复制」。
- 页面上没有任何「发给终端」的按钮（V10）。

- [ ] **Step 1：写失败的测试。**
  - `store keeps notes on disk only`：建一个新的 store，读同一个目录，能读回来；store 没有用到 hub 或网络。
  - `home voice goes to the assistant`：没有调用 `replies` 或 `hub`。
  - `assistant page copy`。
  - `delete and long-press copy`。
  - `sheet lists 助理 first`。
  - `no send button on the page`。
- [ ] **Step 2：** `flutter test test/phone/assistant_test.dart`，FAIL。
- [ ] **Step 3：** 实现。写文件用「临时文件加改名」。
- [ ] **Step 4：** PASS。然后 `flutter test test/phone/`。
- [ ] **Step 5：提交** `feat(phone): 助理先替你记着`。

### Task 17：可选的 skill 和 hook（C21、C22、C24）

**Files:**
- Create:
  - `integrations/claude-code/rapp-plan-points/SKILL.md`；
  - `integrations/claude-code/hooks/emit_plan.py`（照 `probe/phone-v1a-2:probes/phone-v1a-2/hooks/emit_plan.py` 改，不再自己发 HTTP，改调 `rapp emit`）；
  - `integrations/claude-code/hooks/settings.example.json`；
  - `integrations/claude-code/hooks/emit_plan_test.py`；
  - `integrations/AGENTS-plan-points.md`。

**内容：**
- **skill：** 出计划、调 ExitPlanMode 之前，先跑：

  ```
  rapp emit info "<三行，每行一句>" --key "plan:$RAPP_TERM"
  ```

  - 只在 `RAPP_TERM` 有值时跑；
  - 跑失败了也不影响出计划；
  - 不写密码和 token；
  - 不写命令和链接。
- **hook：** PreToolUse 匹配 `ExitPlanMode`。
  - 从 `tool_input.plan` 里用 `(?m)^\s*\d+[.)]\s+(.+)$` 取前三条，去掉 `*` 和反引号；
  - 调 `rapp emit info "<三行>" --key "plan-rule:$RAPP_TERM"`；
  - 永远返回 0，不挡 Claude Code。
- **Codex 和 agy 那段说明：** 和 skill 的意思一样。文件开头写明「效果待试：这两家没有 skill，计划卡片目前只有进去看（代定 2-1、2-6）」。
- **rapp 不替用户装这些（C22）。** 安装步骤只写在这几个文件里。

- [ ] **Step 1：写失败的测试** `emit_plan_test.py`。
  - `test_three_numbered_lines`：5 条的计划，取出前三条，没有 `*` 和反引号。
  - `test_no_rapp_term_does_nothing`。
  - `test_always_exits_zero`：把 `rapp` 换成一个返回 1 的假命令，脚本照样返回 0。
- [ ] **Step 2：** `/usr/bin/python3 -I integrations/claude-code/hooks/emit_plan_test.py`，FAIL。
- [ ] **Step 3：** 实现 hook，写 skill、示例 settings 和那段说明。
- [ ] **Step 4：** PASS。
- [ ] **Step 5：提交** `feat(integrations): 计划要点的 skill 和 hook（可选，不替用户装）`。

### Task 18：矩阵（只加用例）

**Files:**
- Modify: `gui/test/phone/matrix_test.dart`

**改法：**
- `boot()` 的 FakeTransport 里，加 `reply` 能力和下面几行。只加新的 id，老的 `term:pty:a`/`b`/`c`/`w1–w3` 不动：
  - `term:pty:r1`：CC，`approve Bash: git push origin main`，`reply: true`；
  - `term:pty:r2`：CC，提问，3 个选项；
  - `term:pty:r3`：CC，`approve plan`，再加一条 `plan:` 的 emit；
  - `term:pty:r4`：做完，`reply: true`。
- 新的用例跑在已有的 `_phones` × 三套主题上，Pad 尺寸只跑 `pad unchanged`：
  - `v1c risky card`；
  - `v1c options card`；
  - `v1c review card`；
  - `v1c done card`；
  - `v1c reading view with pinned card and reply bar`；
  - `v1c composer open (R36)`：用 `sharedComposer: false`，输入区的可点处也要量；
  - `v1c assistant page`；
  - `pad unchanged`：600×800、669×951、951×669、615×1183 上，Pad 形态里找不到 `ReplyActions`、`PhoneReplyBar` 和 `InputMetrics.phone`。
- 每个用例都过 `checkTaps`、`checkContrast`，没有溢出。`cardButtons` 的计数要包括新的 64 按钮。
- 尺寸：
  - 已有的 `_phones` 里有 390×844、844×390、375×667、430×932、599×800、466×678、678×466，还有 iPad 分屏的两个；
  - 已有的 `_pads` 里有 600×800、669×951、951×669、615×1183。

- [ ] **Step 1：** 先加用例，跑 `flutter test test/phone/matrix_test.dart`。新用例在哪里不过，就回到对应的任务去修。不要在矩阵里加豁免。
- [ ] **Step 2：** 全部 PASS。老用例的数量和名字都不变。
- [ ] **Step 3：提交** `test(phone): 矩阵加上 V1c 的卡片、阅读视图和输入区`。

### Task 19：门禁、todo 和合并

**Files:**
- Modify: `tasks/todo.md`（「手机第一版」一节里，加「V1c 真机检查」「V1c 留着的」）

- [ ] **Step 1：** 跑完整门禁：
  - `swift test`（照 CLAUDE.md；这一期不改 Swift，只确认还是绿的）；
  - `cargo test --workspace --no-fail-fast`；
  - `cargo clippy --workspace --all-targets -- -D warnings`；
  - `flutter analyze`、`flutter test`；
  - `/usr/bin/python3 -I integrations/claude-code/hooks/emit_plan_test.py`；
  - iOS 编译：`scripts/build-ios.sh` 只编译，不装。

  跑完把 `gui/pubspec.lock` 还原。
- [ ] **Step 2：** 写 todo。
  - **U1（验收 3）：** A 上的真 Claude Code 弹一个普通命令的确认，B 开着终端舞台。手机上按住「允许」滑出再松手，A 没有收到输入；再按一次在按钮上松手，A 接着跑，卡片离开。全程看 A 的日志，大小没变。
  - **U2（验收 4）：** 让 Claude Code 要 `git push`。看撤不回那一条；点一次变「再点一次确认」；等 3 秒复原；点两次才发。
  - **U3（验收 9）：**
    - 不装 skill 和 hook：卡片上是 `msg` 那一行加「进去看」；
    - 只装 hook：三条，标「取自计划原文」；
    - 装 skill：三行，标「它自己写的要点」；
    - 点「同意」，它开始干；按住「要改」说一句，它收到这句话（要量一下 `reviseGap` 400 ms 够不够）。
  - **U4：** Duo 上回复还没回来就展开再合上，卡片的结果对。
  - **留着的：**
    - 只经中心服务看到的会话，没有回复按钮；
    - 升级前开的会话，没有回复按钮；
    - Codex 和 agy 的评审说明，效果待试；
    - 375×667 上，key bar 到 56 以后会占掉更多高度。
- [ ] **Step 3：** 提交 `docs(todo): V1c 的真机检查和留着的`。
- [ ] **Step 4：合并。**
  - 先在分支上 `git merge main`，重跑 Step 1；
  - 再在 main 上 `git merge --no-ff feat/phone-v1c -m "merge: 手机 V1c：卡片上直接回复、评审要点、阅读视图和助理（feat/phone-v1c）"`；
  - 合并的输出写到文件里，看退出码，不要接 tail。

---

## 规格要跟着改的

照代定的做，规格里下面这些地方要跟着改。这一期不改规格。

1. **验收 9、C19 ②、C24，还有稿子 V1PlanRule（代定 2-3、2-5）。**
   - 「没装 skill 时是取自原文的前三条」要改成：
     - 没装 skill，也没装 hook：只有 `msg` 那一行和「进去看」；
     - 用户自己装了 hook：才有「取自计划原文」的三条。
   - 手机不读计划文件。
2. **§6.2 Codex 的放行和稿子 V1Thin（代定 2-2）：** Codex 的放行只有「进去看」，没有允许和拒绝。
3. **C18–C20（代定 2-1）：** 不适用于 Codex。Codex 只出做完卡片。
4. **agy（代定 2-6）：** 计划和提问只有「进去看」。
5. **信任目录的那一问（代定 2-7）：** 两家都只有「进去看」。
6. **I2 和程序状态规格 §7.4.8（代定 4-2）：** 按键由手机照它的对照表换好再发，不是由跑 CLI 的那一端换。I3 的「写在 app 配置里」也一样，改成写在手机的表里。
7. **I6（代定 4-4）：** 除了「对端版本旧」，还有「会话是升级前开的」。这两种都在事先就不出按钮。
8. **S1「可以往上滚」（代定 3-1）：** 改成只能在当前屏幕里往上滚，看不到更早的历史。
9. **S8（代定 3-3）：** 理由改成探查 3 的结论，结论本身不变。
10. **C20：** Claude Code 的「同意」发 `2`（不是 `1`，`1` 是自动模式），「要改」发 `3`，再发那句话加回车。
11. **C21 和 I7：**
    - 约定 `key` 是 `plan:<会话>` 和 `plan-rule:<会话>`；
    - 会话不在等你点头、要点又早于现在的状态时，要点已经过时，不显示（规格原文是「只是一条普通的通知」）。
12. **C7、C9 的「放在 app 配置里」：** 第一版放在 app 的代码里，跟着 app 升级。

## 不在这一期

- I4、P1–P6、D1–D5（V1d）。助理和输入历史里的「当时的项目」，第一版用现有的项目成员关系。等项目范围重构做完，V1d 再换成重构那一层。
- 「已处理」页（V1d）。
- 读计划全文的协议请求（代定 2-3）。
- Windows 被控端的回复。
- 从中心服务那条路发回复。
- 规格文件本身的修改。
