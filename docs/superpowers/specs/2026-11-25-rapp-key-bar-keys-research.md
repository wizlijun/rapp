# 快捷区按键梳理：AI coding 工具最常用、虚拟键盘打不出的键（调研）

日期：2026-11-25　状态：调研 + 用户当天确认并已实现的排法（见「定下来的排法」）。

## 起因

用户原话：「我对现在快捷键栏的那几个常用键不满意。请根据各种 ai coding 工具最常见的快捷键（虚拟键盘点不到或需要组合的）做一次梳理。我举例子，例如上下键常用，但左右键少用。backspace 没有出现在默认栏等。」

## 改之前（`gui/lib/embed/key_bar_keys.dart` 的 `keyBarRows`）

- 第一排（10 颗）：`Esc ⇧Tab Tab ⌃C ← ↑ ↓ → ⏎ ⋯`
- 第二排（点 ⋯ 才有）：`⌃ ⌥ (⌘) ⌃R ⌃O ⌃T ⌃B (⌃D) ⌫ 复制 粘贴`
- ↑↓ 上滑是 PgUp / PgDn，←→ 上滑是 Home / End；方向键和 ⌫ 长按连发；⌃⌥⌘ 粘滞。
- 软键盘上的 ⌫ 只删本地草稿，不发给远端；要删远端提示符里的字只能用第二排的 ⌫。
- `keyBarRows` 只有这一种排法：2026-11-21 规格里写的「宽屏一排分组」没有实现，iPad / PC 上也是这 10 颗拉宽。

## 调研范围

2026-11-25 查的官方快捷键页：Claude Code、Codex CLI（官方页不全，部分来自第三方速查表）、Gemini CLI、opencode（V2）、xAI 的终端 agent（docs.x.ai/build）。只看「虚拟键盘打不出或要组合」的键；`/ @ ! ?`、数字、字母这些软键盘能打的不算。

## 按「几家都这么用」排的频度

### 一档：每一轮都要用，各家含义一致

| 键 | 用途 | 现在 |
|---|---|---|
| Esc | 打断当前回合、关对话框、拒绝权限请求；连按两次是回退 / 清空草稿（Claude Code、Codex、Gemini、opencode 都如此；xAI 那款 Esc 不打断，要 ⌃C） | 第一排 |
| ↑ ↓ | 权限框和菜单选项、历史、列表 | 第一排 |
| ⏎ | 确认 | 第一排 |
| ⇧Tab | 切模式（Claude Code 权限模式、Gemini 审批模式、opencode 切 agent、xAI 切模式） | 第一排 |
| ⌃C | 打断 / 清空输入 / 连按退出；普通 shell 里停进程 | 第一排 |
| Tab | 接受补全；Codex、Gemini 里是「排队到下一轮」；Claude Code 权限框里是加备注 | 第一排 |
| ⌫ | 删远端提示符里的字（↑ 调出的历史、误触、退出 `!` 模式） | **第二排** |

### 二档：一次会话几次，含义大体一致

| 键 | 用途 | 现在 |
|---|---|---|
| ⌃O | Claude Code 详细记录 / 展开折叠；Gemini 展开内容块。但 Codex 是复制上一条输出，xAI 是开关「总是批准」，opencode 是打开菜单——**含义不一致** | 第二排 |
| ⌃R | 搜历史（Claude Code、Codex、Gemini）；opencode 是改会话名，xAI 是打开会话列表 | 第二排 |
| ⌃T | 待办 / 任务清单（Claude Code、Gemini、xAI）；Codex 是记录浮层；opencode 是切模型变体 | 第二排 |
| ⌃B | 把正在跑的命令放到后台（Claude Code、xAI、opencode）；Gemini 是显示 / 隐藏后台 shell | 第二排 |
| ⌃L | 重画 / 清屏（Claude Code、Codex、Gemini、opencode mini）。远程画面花掉时的救急键 | 没有 |
| PgUp PgDn | 翻记录（全屏界面的工具都用） | ↑↓ 上滑 |

### 三档：偶尔用

| 键 | 用途 | 现在 |
|---|---|---|
| ← → | Claude Code 对话框里切标签页；远端提示符里挪光标；opencode 切子会话 | **第一排，占两格** |
| ⌃D | 退出（各家一致），有字时删光标后一个字 | 第二排（终端） |
| ⌥ + 字母 | Claude Code：⌥P 换模型、⌥T 思考、⌥O 快速模式；⌥B / ⌥F 按词移动 | ⌥ 粘滞 |
| ⌃X + … | opencode 的前导键（⌃X 再按字母）；Claude Code 的 ⌃X ⌃K 停后台子代理 | ⌃ 粘滞 + 打字母 |
| ⌃U ⌃W ⌃A ⌃E ⌃K | 行编辑（各家都是 readline 那套） | ⌃ 粘滞 + 打字母 |
| Home End | 行首行尾 | ←→ 上滑 |

### 不给键位

- 换行（⌃J、⇧⏎、⌥⏎）：多行在写作框里写好再发，不需要往远端发换行键。
- ⌃G 外部编辑器、⌃V 贴图、⌃Z 挂起、F 键（Gemini F12、opencode F2）：手机上遥控时用不上或极少用。
- 数字键选选项、`y / n`：软键盘能打，↑↓⏎ 也能代替。

## 改之前这一排的问题

1. ← → 是三档键，却占了第一排 9 个实位里的 2 个。
2. ⌫ 是一档键，却在第二排，而且软键盘的 ⌫ 到不了远端。
3. 第一排够不到任何 ⌃ 组合（除了 ⌃C）：要 ⌃O、⌃R、⌃T 得先点 ⋯，第二排又把常用语条和画面再顶高一排。

## 定下来的排法（用户 2026-11-25 确认，已实现）

用户原话，按先后：

1. 「按你建议来」——第 9 格放粘滞 ⌃；⌫ 上第一排；← → 下第二排；加 ⌃L；拿掉 ⌃D。
2. 「第一排的顺序，可否按意图做一下分组排序。」
3. 「复制粘贴放第二排前面 用对应的快捷键表示，不要用名字」
4. 「第一排的回车放倒数第一个，删除放倒数第二个。Tab 放第一个 ShiftTab 放第二个，第三是 Esc ^C」

第一排（10 颗，同日又改成 11 颗，见下面「同日补改」）：`Tab ⇧Tab` · `Esc ⌃C` · `⌃ ⋯` · `↑ ↓` · `⌫ ⏎`

| 组 | 键 | 意图 |
|---|---|---|
| 切 | Tab ⇧Tab | 补全 / 排队，切模式 |
| 停 | Esc ⌃C | 打断、拒绝、清空 |
| 扩展 | ⌃ ⋯ | 粘滞 ⌃ 加一个字母打出任意 ⌃ 组合；⋯ 开第二排 |
| 选 | ↑ ↓ | 选选项、翻历史（上滑 PgUp / PgDn） |
| 改、定 | ⌫ ⏎ | 删远端的字，确认 |

- 两头四颗的位置是用户定的（4）。中间四颗 `⌃ ⋯ ↑ ↓` 的先后是实现者定的：↑ ↓ 挨着 ⌫ ⏎，右手拇指一块儿够得着；最少用的 ⌃ ⋯ 放在最难够的中间；↑ 不挨着 ⌃C，选选项时按偏了不会打断回合。
- 只调了顺序，组与组之间没有加宽空隙：375 宽的手机上 `⇧Tab` 的字已经快顶满键宽。

**同日补改（用户原话：「是不是还却一个隐藏键的位置」，问怎么办时答「把... 和折叠 放在第一行的末尾」）**：第一排改成 11 颗——`Tab ⇧Tab` · `Esc ⌃C` · `⌃` · `↑ ↓` · `⌫ ⏎` · `⋯ ⌄`。

- 行尾两颗是按键区自己的键：⋯ 开第二排，⌄ 收起快捷区（`BarKind.hide`，读屏念「收起快捷区」），和框里的快捷区开关做的是同一件事，框里那颗照留。
- ⌄ 是点了就收：⌃ 亮着、或者「打字后自动收起」关着，也照收（不走 `foldKeyBar` 那几条拦法）。只收这一类会话（终端 / App 各记各的）。
- 键面用 `⌄` 不用 0.15.20 以前的 `⊙`：用户嫌圆圈难看。这个字形是实现者定的。
- 0.15.20 第一排也是 11 颗，所以 375 宽的手机放得下；`⇧Tab` 会更挤一点，要实机看（todo 实机检查 1）。

第二排（点 ⋯）：`⌘C ⌘V` · `⌥ (⌘)` · `← →` · `⌃O ⌃R ⌃T ⌃B ⌃L`

- 复制、粘贴排最前，键面写 `⌘C` `⌘V`（3）；读屏仍念「复制」「粘贴」。做的事不变：终端里 ⌘C 复制画面上选中的字，⌘V 把本机剪贴板贴过去；App 会话里 ⌘C 发 ⌘C。
- `⌘` 只在 App 会话有，所以 App 会话第二排 11 颗，终端 10 颗。
- ← → 上滑仍是 Home / End。
- ⌃ 组合按频度排，新加 ⌃L（终端发 `Ctrl-L`，App 发键码 37 + ⌃）。
- ⌃D 不在按键区了，`barKeys` 里也删了；要用就点 ⌃ 再打 d。

没做：2026-11-21 规格里的「宽屏一排分组」仍然没有，iPad / PC 上还是这两排拉宽。

改动：`gui/lib/embed/key_bar_keys.dart`（`barKeys`、`keyBarRows`），测试 `gui/test/embed/key_bar_keys_test.dart`、`key_bar_test.dart`。实机检查在 `tasks/todo.md`「快捷区按键重排」。

## 来源

- Claude Code：https://code.claude.com/docs/en/interactive-mode
- Gemini CLI：https://geminicli.com/docs/reference/keyboard-shortcuts/
- opencode：https://opencode.ai/docs/cli/keybinds
- xAI：https://docs.x.ai/build/keyboard-shortcuts
- Codex CLI：https://developers.openai.com/codex/cli/features ；默认键位表来自第三方整理 https://codex.danielvaughan.com/2026/05/06/codex-cli-configurable-tui-keymaps-custom-keyboard-shortcuts/ 、https://linuru.com/codex-cli/ （官方没有完整默认键位页，Codex 一栏可信度低于其他几家）
