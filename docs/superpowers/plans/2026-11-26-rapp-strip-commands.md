# 常用语条里的命令 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 常用语条上混排常用语和「按意图」的命令；命令按文字终端前台的工具（Claude Code、Codex…）翻成各自的斜杠命令或按键发出去，管理页里可增删改排。

**Architecture:** 纯数据放两个新文件：`strip_tools.dart`（认工具）和 `strip_cmds.dart`（命令、内置对照表、按工具取写法）。`UiPrefs.phrases` 从 `List<Phrase>` 变成 `List<StripItem>`（`Phrase` 和 `StripCmd` 都实现它），旧 JSON 照读。发送复用 `phrase_send.dart` 的规则；发字走 `ComposerModel.submitText(command: true)`（不进历史），按键走 `TermSessionPort.sendKeys`。条和管理页在现有 widget 上扩展。

**Tech Stack:** Flutter / Dart（`gui/`），flutter_test。不动 Rust，不动协议。

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-strip-commands-design.md`（用户 2026-11-26 审过）。实现者两份都读。

## Global Constraints

- 工作目录 `.worktrees/strip-commands`，分支 `feat/strip-commands`。不改版本号、不打 tag、不 push（CLAUDE.md）。
- Flutter 在 `~/development/flutter/bin/flutter`，不在 PATH；测试后 `git checkout gui/pubspec.lock`（如有改动）。
- 用户可见文字全中文。键面只写意图，读屏念「命令：<键面>」。
- 内置 6 条命令、顺序、键面：`new` 新对话 · `model` 换模型 · `compact` 压缩 · `resume` 恢复 · `usage` 用量 · `search` 搜历史。
- 默认列表 = 这 6 条命令 + 精简后的 7 条常用语（命令在前）。`defaultPhrases` 改成且只含这 7 条，按此顺序：`继续`、`按你推荐来`、`进度`、`全做完别问我`、`先写方案别改代码`、`跑下测试`、`提交并推送`（去掉 `确认`、`听你的`、`总结一下改了什么`；用户 2026-11-26 定）。已存的 `phrases` 不改写。
- 前台是 shell（`TermRow.shell == true`）、认不出工具、tmux、App 会话：命令**隐藏**；认出工具但它没有这个意图：**灰掉**，点了提示 `<工具名> 没有这个命令` 2 秒（`phraseHintTime`）。
- 命令完全不进输入历史；不经 AI 整理；不动 ⌃⌥⌘ 粘滞；1 秒内不连发（`phraseRepeatWindow`）；断网 / 正在断开时不发。
- `gui.json`：命令项 `{"kind":"cmd", ...}`；没有 `kind` 的照旧当常用语；新键 `phrase_cmds_seeded`（bool）。
- 每个任务结束跑 `flutter analyze`（无 error/warning）和该任务的测试；最后一个任务跑全量 `flutter test`。

## Review Focus

1. **退回 zsh 后 `ps.app` 还写着 `claude-code`**（`done` / `error` 记录会留）：命令必须隐藏 —— Task 1 的 `toolOf` 测试钉住。
2. **前台在 zsh 和 claude 之间切换时条要跟着变**，不能停在旧状态 —— Task 4 的 widget 测试改 `termLists` 后 `pump` 再断言。
3. **老用户 `gui.json` 里已有自定义常用语**：升级插 6 条命令一次，删掉后重启不再回来；旧版写的文件照读 —— Task 2 测试。
4. **用户把内置命令某个工具的写法清空**（表示「没有」）和「没改过、跟内置表走」必须区分开，存盘再读回不能混 —— Task 2 测试。
5. **按键命令在上一条常用语还在发（composer busy）时**：按键不走 composer，照发；发字命令照常常用语规则拒绝 —— Task 3 测试。

---

### Task 0: 核对对照表、实测粘贴的斜杠命令

不写产品代码。结果写回 spec，后面的任务按它定。

**Files:**
- Modify: `docs/superpowers/specs/2026-11-26-rapp-strip-commands-design.md`（§7 表、§8）

- [ ] **Step 1: 逐格查官方文档**：Claude Code `https://code.claude.com/docs/en/slash-commands`（及 interactive-mode 页）、Codex `https://developers.openai.com/codex/cli/slash-commands`、Gemini CLI `https://geminicli.com/docs/cli/commands/`、agy（Antigravity CLI 文档）、opencode `https://opencode.ai/docs/`（commands / keybinds 页）。每格：命令原文或按键；查不到就写「无」。把 spec §7 表的「待查」「？」都换成结果，表下附出处 URL 和查询日期。
- [ ] **Step 2: 实测粘贴**：本机有 `claude` / `codex` 时，用 Python `pty` 起它们，写入 `\x1b[200~/help\x1b[201~`，等 300 ms，再写 `\r`，读 2 秒输出，看是否打开了帮助（而不是当成一句话发给模型）。再测 `/model`（应弹出选择器）。只用 `/help`、`/model` 这类本地命令，不发会花额度的话。把结论写进 spec §8：**「粘贴可行」** 或 **「要逐字按键」**，以及测的版本号。本机没有某个工具就写「未测」。
- [ ] **Step 3: 提交**

```bash
git add docs/superpowers/specs/2026-11-26-rapp-strip-commands-design.md
git commit -m "docs(spec): 核对常用语条命令对照表，实测粘贴斜杠命令"
```

Task 2 的内置表按 Step 1 的结果填；Task 3 的发字方式按 Step 2 的结论选（见 Task 3 Step 3）。

---

### Task 1: 认出前台工具

**Files:**
- Create: `gui/lib/embed/strip_tools.dart`
- Modify: `gui/lib/ui/main_state.dart`（`termFg` 旁边，约 1405 行）
- Test: `gui/test/embed/strip_tools_test.dart`

**Interfaces:**
- Produces:
  - `class AgentTool { const AgentTool(this.id, this.name, {required this.apps, required this.progs}); final String id, name; final List<String> apps, progs; }`
  - `const agentTools = <AgentTool>[...]`，顺序和 id：`claude-code`（Claude Code，apps `['claude-code']`，progs `['claude']`）、`codex`（Codex，`['codex']`，`['codex']`）、`gemini`（Gemini CLI，`['gemini', 'gemini-cli']`，`['gemini']`）、`agy`（Antigravity，`['agy', 'antigravity']`，`['agy']`）、`opencode`（opencode，`['opencode']`，`['opencode']`）。apps 值以 Task 0 / 程序状态 testdata 为准可调。
  - `AgentTool? toolOf(TermRow? row)`
  - `MainState`：`TermRow? termRowOfSid(Object sid)`；`AgentTool? stripToolOf(RemoteSession s)`（不是文字终端 → null）

- [ ] **Step 1: 写失败测试** `strip_tools_test.dart`，用 `TermRow('term:pty:w', 'w', 'zsh', null, 1, 1, 0, false, false, ps: ..., fg: ..., shell: ...)`：
  - `toolOf(null)` → null
  - `shell: true, fg: 'zsh', ps: TermPs('done', app: 'claude-code')` → null（Review Focus 1）
  - `shell: false, fg: 'node', ps: TermPs('working', app: 'claude-code')` → id `claude-code`
  - `shell: false, fg: 'codex'`，无 ps → id `codex`
  - `shell: null, fg: 'claude'`（旧设备）→ id `claude-code`
  - `shell: false, fg: 'vim'` → null
  - `ps.app: 'codex', fg: 'claude'` → `codex`（`app` 先于 `fg`）
  - `dead: true` 的行 → null
- [ ] **Step 2: 跑测试确认失败** `cd gui && ~/development/flutter/bin/flutter test test/embed/strip_tools_test.dart` → 编译失败（`toolOf` 未定义）
- [ ] **Step 3: 实现** `toolOf`：null / dead / `shell == true` → null；否则先按 `row.ps?.app` 在 `apps` 里找，再按 `row.fg` 在 `progs` 里找。`termRowOfSid`：`_recordOfSid(sid)` 得 `(id, app)`，`isTermApp(app)` 才查 `hub?.termLists[id]?.terms` 里 `r.id == app` 的那行。`stripToolOf(s)`：`toolOf(termRowOfSid(s.sid))`。
- [ ] **Step 4: 跑测试确认通过**，`flutter analyze` 干净
- [ ] **Step 5: 提交** `feat(gui): 认出文字终端前台的 AI 工具`

---

### Task 2: 命令数据、内置表、存储与升级

**Files:**
- Create: `gui/lib/embed/strip_cmds.dart`
- Modify: `gui/lib/embed/phrases.dart`（`Phrase implements StripItem`；`defaultStripItems`）
- Modify: `gui/lib/ui/prefs.dart`（`phrases` 的类型、读写、`phraseCmdsSeeded`）
- Modify: `gui/lib/ui/main_state.dart:3921-3930`（`setPhrases`、`addPhrase` 用 `whereType<Phrase>()` 判重）
- Test: `gui/test/embed/strip_cmds_test.dart`；改 `gui/test/embed/phrases_test.dart`

**Interfaces:**
- Consumes: `AgentTool`（Task 1）
- Produces:
  - `sealed class StripItem {}`（放 `phrases.dart`）；`class Phrase implements StripItem`（不变的其余部分）
  - `sealed class CmdAction`：`class CmdText(String text)`、`class CmdKey(String key)`（`key` 是 `barKeys` 的 id，如 `'cr'`）；都有 `==` / `hashCode`、`toJson()`（`{"text": ...}` / `{"key": ...}`）
  - `class StripCmd implements StripItem { const StripCmd(this.id, {this.label, this.per = const {}}); final String id; final String? label; final Map<String, CmdAction?> per; }`
    - `label` null = 用内置键面；`per[tool]` 缺 = 跟内置表；`per[tool]` 存在且为 null = 用户清空（这个工具没有）
    - `String labelOf()`：`label ?? builtinCmds[id]?.label ?? id`
    - `bool get builtin => builtinCmds.containsKey(id)`
    - `toJson()`：`{"kind":"cmd","id":..., if label "label":..., if per.isNotEmpty "per": {tool: action?.toJson()}}`；`static StripCmd? fromJson(Object?)`
  - `class BuiltinCmd { const BuiltinCmd(this.label, this.per); final String label; final Map<String, CmdAction> per; }`
  - `const builtinCmdOrder = ['new', 'model', 'compact', 'resume', 'usage', 'search'];`
  - `const builtinCmds = <String, BuiltinCmd>{...}`：键面见 Global Constraints；`per` 按 Task 0 核对后的 spec §7 表填（`search` 在支持的工具上是 `CmdKey('cr')`，其余是 `CmdText`）
  - `CmdAction? actionFor(StripCmd c, AgentTool tool)`：`c.per.containsKey(tool.id) ? c.per[tool.id] : builtinCmds[c.id]?.per[tool.id]`
  - `List<StripItem> get defaultStripItems => [for (final id in builtinCmdOrder) StripCmd(id), ...defaultPhrases];`
  - `StripItem? stripItemFromJson(Object? j)`：`kind == 'cmd'` → `StripCmd.fromJson`，否则 `Phrase.fromJson`
  - `UiPrefs.phrases` 类型 `List<StripItem>`；`UiPrefs.phraseCmdsSeeded`（`phrase_cmds_seeded`）

- [ ] **Step 1: 写失败测试** `strip_cmds_test.dart`：
  - `actionFor(StripCmd('new'), claude)` == `CmdText('/clear')`；`codex` == `CmdText('/new')`（以 Task 0 结果为准）
  - `actionFor(StripCmd('search'), claude)` == `CmdKey('cr')`
  - `actionFor(StripCmd('new', per: {'codex': CmdText('/clear')}), codex)` == `CmdText('/clear')`
  - `actionFor(StripCmd('new', per: {'codex': null}), codex)` == null（用户清空）
  - 自定义 `StripCmd('u1', label: '审查', per: {'codex': CmdText('/review')})`：codex → `/review`，claude → null
  - JSON 往返：上面三种都 `fromJson(toJson())` 相等；`per: {'codex': null}` 往返后 `containsKey('codex')` 仍为 true 且值为 null（Review Focus 4）
  - `StripCmd.fromJson({'kind':'cmd'})`（没 id）→ null；`per` 里坏的值（`3`、`{"key":"zz"}` 不在 `barKeys`）丢弃该格
- [ ] **Step 2: 改 `phrases_test.dart`**，加：
  - 没有文件：`phrases` == `defaultStripItems`，`phraseCmdsSeeded` 为 true
  - 旧文件 `{"phrases":[{"text":"a"}]}`（无 `phrase_cmds_seeded`）：读出 = 6 条命令 + `Phrase('a')`，`phraseCmdsSeeded` true
  - 读 → 删掉所有命令 → 存 → 再读：没有命令（Review Focus 3）
  - `{"phrases":[{"kind":"cmd","id":"new"},{"text":"a"}],"phrase_cmds_seeded":true}` 原样读回
  - 原有 4 个测试按新默认值调整（第一个测试的期望改成 `defaultStripItems`）
- [ ] **Step 3: 跑测试确认失败**：`flutter test test/embed/strip_cmds_test.dart test/embed/phrases_test.dart`
- [ ] **Step 4: 实现** 上面 Produces 的全部；`UiPrefs.load`：`phrases` 不是 list → `defaultStripItems`、seeded true；是 list 且 `phrase_cmds_seeded != true` → 在前面插 `builtinCmdOrder` 里列表中还没有的命令，seeded true；`save` 写 `phrase_cmds_seeded`。`addPhrase` 判重改看 `whereType<Phrase>()`。
- [ ] **Step 5: 修编译**：`flutter analyze`，凡是把 `prefs.phrases` 当 `Phrase` 用的地方（`phrase_strip.dart`、`phrases_page.dart`）先改成 `whereType<Phrase>()` 让它通过，Task 4 / 5 再正式处理命令。
- [ ] **Step 6: 跑测试确认通过**（含 `test/ui/phrases_page_test.dart`、`test/embed/key_bar_test.dart`，期望里的默认数如有变化一并调整）
- [ ] **Step 7: 提交** `feat(gui): 常用语条命令的数据、内置对照表与升级`

---

### Task 3: 发命令（不进历史）

**Files:**
- Modify: `gui/lib/embed/composer_model.dart:55-70, 780`（`Outgoing.command`；`submitText(..., command:)`）
- Modify: `gui/lib/embed/remote_session.dart:161`（命令也像常用语一样总按回车、不动面板）
- Modify: `gui/lib/history/input_recorder.dart`（`onSubmitted` 和约 399 行写 `_sentRecord` 的地方：`o.command` 直接跳过）
- Modify: `gui/lib/embed/phrase_send.dart`
- Test: `gui/test/embed/phrase_send_test.dart`、`gui/test/history/input_recorder_test.dart`

**Interfaces:**
- Consumes: `AgentTool`（Task 1）、`StripCmd` / `CmdAction` / `actionFor`（Task 2）、`barKeys`、`termWire`（`key_bar.dart`）
- Produces:
  - `Outgoing(..., {bool command = false})`，字段 `final bool command;`
  - `Submit submitText(String text, {VoiceOrigin? voice, bool phrase = false, bool command = false})`
  - `PhraseOutcome` 加 `missing`（这个工具没有这个命令）
  - `String? stripHint(PhraseOutcome o, {AgentTool? tool})`：`missing` → `'${tool!.name} 没有这个命令'`，其余同 `phraseHint`
  - `PhraseOutcome sendStripCmd({required MainState state, required RemoteSession session, required SessionPort port, required StripCmd c, required AgentTool tool, DateTime Function() now = DateTime.now})`
  - 1 秒连发窗口和常用语共用同一个 `_lastPhrase`（点完常用语马上点命令也算连发）

- [ ] **Step 1: 写失败测试**（`phrase_send_test.dart` 新 group，终端用 `FakeTermSessionPort`）：
  - Claude Code 下点 `StripCmd('new')`：一次 `composer_send`，内容含 `/clear`；`done` 后回车 1 次；草稿和面板不变
  - 点 `StripCmd('search')`：一次 `keys` 调用，`keys == ['Ctrl-R']`；没有 `composer_send`
  - composer busy 时：`search` 照发（`sent`），`new` 返回 `busy`（Review Focus 5）
  - 1 秒内先点常用语再点命令 → `tooSoon`
  - `StripCmd('new', per: {'codex': null})` 在 codex 下 → `missing`；`stripHint(missing, tool: codex) == 'Codex 没有这个命令'`
  - 断网（让 `state.sendBlocked` 为真的现有做法，照这个文件里常用语断网测试）→ `offline`，按键命令也不发
  - ⌃ 粘滞亮着时点 `search`：发的是 `Ctrl-R` 而不是叠加的组合，粘滞不被清掉
- [ ] **Step 2: 写失败测试**（`input_recorder_test.dart`）：`submitText('/clear', command: true)` 并 `done` 后，记录库里没有这条 `sent` 记录，`onSent` 也没被调用
- [ ] **Step 3: 跑测试确认失败**
- [ ] **Step 4: 实现**：
  - `CmdText`：Task 0 结论为「粘贴可行」→ `session.composer.submitText(text, command: true)`，之后照 `sendPhrase` 的发法（`prepareInput`、`composerSend`）。结论为「要逐字按键」→ 不走 composer，`(port as TermSessionPort).sendKeys(sid, [...text.split(''), 'Enter'])`（单字是合法 wire 名，见 `key_bar.dart:86`），此时 busy 不拦，Step 1 第三条的期望相应改成 `new` 也照发，Step 2 的历史测试照样成立（本来就不进 composer）。
  - `CmdKey`：`port is TermSessionPort` 时 `sendKeys(sid, [termWire(barKeys[key]!.wire!, 0)])`，不碰 `ModifierLatch`。
  - `remote_session._allSent`：`lastDone?.phrase == true || lastDone?.command == true` 走常用语那条。
- [ ] **Step 5: 跑测试确认通过**，`flutter analyze` 干净
- [ ] **Step 6: 提交** `feat(gui): 常用语条命令按工具发出，不进输入历史`

---

### Task 4: 条上显示命令

**Files:**
- Modify: `gui/lib/embed/phrase_strip.dart`
- Test: `gui/test/embed/phrase_strip_cmds_test.dart`（新建；搭法照 `key_bar_test.dart` 里常用语条那组）

**Interfaces:**
- Consumes: `stripToolOf`（Task 1）、`StripItem` / `StripCmd` / `actionFor`（Task 2）、`sendStripCmd` / `stripHint`（Task 3）

- [ ] **Step 1: 写失败测试**：
  - 文字终端、`termLists` 里这一行 `fg: 'claude', shell: false`：条上前 6 个是命令，key `phrase-0` 的文字是「新对话」，`Semantics` 标签「命令：新对话」
  - 把这一行改成 `fg: 'zsh', shell: true`，`pump`：命令全部消失，第一个是「继续」（Review Focus 2）；条高度不变（`keyBarHeightOf` 前后相等）
  - Codex 下把 `new` 在 codex 上清空：「新对话」半透明（灰），点它出 `phrase-hint` 文字「Codex 没有这个命令」
  - 长按命令：菜单只有「编辑」「移到最前」「删除」（没有 `phrase-menu-put`）
  - 「全部 ›」列表：认出工具时列命令，zsh 下不列
  - App 会话（`session.profile.phrases` 为 true 的非终端）：不出现命令
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**：`build` 里 `final tool = widget.state.stripToolOf(widget.session)`；可见项 = `tool == null` 时只要 `Phrase`，否则全部；每项保留它在 `prefs.phrases` 里的下标做 key 和 `_ticked`（`phrase-$i` 的 i 是原下标）。命令片：边框用 `t.accent`（没有就用 `t.on`），`actionFor == null` 时 `Opacity(.4)`，点了走 `_say(stripHint(missing, tool: tool)!)`。长按菜单按项的种类出不同的条目；「编辑」调 Task 5 的 `editStripCmd`（Task 5 前先留空分支）。
- [ ] **Step 4: 跑测试确认通过**；`test/embed/key_bar_test.dart` 全部通过
- [ ] **Step 5: 提交** `feat(gui): 常用语条按前台工具显示命令`

---

### Task 5: 管理页

**Files:**
- Modify: `gui/lib/pages/phrases_page.dart`
- Test: `gui/test/ui/phrases_page_test.dart`

**Interfaces:**
- Consumes: `StripCmd` / `CmdAction` / `builtinCmds` / `agentTools` / `defaultStripItems`（Task 1、2）
- Produces: `Future<StripCmd?> editStripCmd(BuildContext context, {StripCmd? c})`（null = 新增；返回 null = 取消）；Task 4 的长按「编辑」改用它

- [ ] **Step 1: 写失败测试**：
  - 列表混排，命令行有 key `phrase-cmd-tag-$i` 的小标记，副标题列出各工具写法，如 `Claude Code /clear · Codex /new`（按键显示键面 `⌃R`）
  - 拖动把「继续」拖到「新对话」前面 → `prefs.phrases` 顺序跟着变
  - 「＋ 新增命令」（key `phrase-cmd-add`）：填键面「审查」，Codex 一行填 `/review`，保存 → 列表末尾多一个 `StripCmd`，`actionFor(codex)` == `CmdText('/review')`
  - 编辑内置「新对话」：Codex 一行改成 `/clear`、保存 → `per['codex'] == CmdText('/clear')`；该行出现「恢复这一项」（key `phrase-cmd-row-reset-codex`），点了 → `per` 不再含 `codex`
  - 编辑时把 Claude Code 一行清空保存 → `per['claude-code']` 存在且为 null
  - Codex 一行选「按键」再挑 ⌃R → `per['codex'] == CmdKey('cr')`；能挑的键是 `['cr', 'co', 'ct', 'cb', 'cl', 'stab', 'tab', 'esc', 'cc']`
  - 键面为空时「保存」不可点
  - 「恢复默认」→ `prefs.phrases == defaultStripItems`
  - 页面底部有文字「命令只在文字终端里认出 Claude Code、Codex 等工具时出现。」
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**：行按种类画（常用语照旧；命令加标记和副标题，点开 `editStripCmd`）。编辑页：键面 `TextField`（内置命令预填 `labelOf()`，存时等于内置键面就存 null）；`agentTools` 每个一行：工具名、一个 `TextField`（写法）、右边「按键」切换（切到按键后显示 Task 5 Step 1 那 9 个键的选择）、内置且这一格被改过时显示「恢复这一项」。新命令的 id 用 `'u${DateTime.now().millisecondsSinceEpoch}'`。底部按钮行加 `phrase-cmd-add`；「恢复默认」改为 `defaultStripItems`；说明文字照 Step 1 加。
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: 提交** `feat(gui): 常用语管理页可编辑命令`

---

### Task 6: 收尾：全量门禁、实机检查清单

**Files:**
- Modify: `tasks/todo.md`（加「常用语条命令（feat/strip-commands，2026-11-26）实机检查」，内容抄 spec §13 的 1–12）
- Modify: spec §7（若 Task 2 的内置表和 §7 不一致，以代码为准改 §7）

- [ ] **Step 1: 全量**：`cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`，全部通过；`git checkout pubspec.lock`（如有改动）
- [ ] **Step 2: 写 todo.md 实机检查**
- [ ] **Step 3: 提交** `docs(todo): 常用语条命令的实机检查`
