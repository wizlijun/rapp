# 长语音先让 AI 整理（设计）

2026-11-20。依据：用户需求原话（下文 §1），两件用户决定（§4），已有的《语音输入》《输入记录》规格和代码。上游能力：全局设置的「LLM 接入点」（`local/llm.json`，`gui/lib/llm_api.dart`，提交 ec7c2729）指向虚拟网里的 rapp-llm 网关，用它的小 API `dictation`。

## 1. 为什么做

用户原话：已有的两个短语音输入，生成了大段的 ASR 文本时（文字数 > 10 开启）不立即发送，而是执行语音输入法的智能调整能力；用户可以选择跳过直接发送；API 不可用则提示故障；任何时候用户都可以点击直接发送。异步调用优化后，结果正常则替换输入的文本，直接发送或进入用户选择的编辑。交互体验要友好。用户原始语音文本和结果文本都要写入输入历史，标记哪个是 AI。

长一点的口述，识别出来的字常有错字、口头禅（嗯、那个）、没有标点。现在松手就原样打进对方的 app。`dictation` 能在一两秒内把它理顺成可以直接发的文字。

「两个语音输入」指的是：iOS 舞台上的语音按钮（`_IosStage`，`gui/lib/embed/composer_panel.dart`），和桌面（macOS、Linux）的「按住说话」按钮加快捷键（`DesktopVoice`，`gui/lib/embed/voice_desktop.dart`）。两者共用 `VoiceHold`（`gui/lib/embed/voice_button.dart`）和 `sendVoice`，app 画面和文本终端都有。

## 2. 目标、不做的、不能出现的

**目标**

- G1 松手时转写结果超过 10 个字，并且 LLM 接入点已设置、开关打开：先整理，整理结果到手后按松手时的去向走（发送 → 直接发 AI 文字；编辑 → AI 文字进写作面板）。
- G2 整理期间一直显示一张卡片，上面有「直接发送」（发原话）和「编辑」（原话进写作面板）。用户随时可以点，点了就取消整理。
- G3 整理失败（接入点不通、超时、中途断开、非 200）：卡片显示故障原因，停在那里等用户点，不自动发。
- G4 输入历史：AI 整理后发出的那条记录里标明是 AI，并附上原话；历史列表这一行显示「AI」标记，⋮ 菜单里能用原话。
- G5 不是 AI 整理过的语音发送，记录的 `source` 从现在的 `typed` 改成 `voice`（《输入记录》§4 本来就留给语音）。

**不做的**

- 卡片上的键盘快捷键（回车 = 直接发送之类）。桌面上画面有焦点时，按键由原生转给对方的 app，要改原生按键闸门，留到以后。现在只能点击或触摸。
- `correct`、`polish` 两个小 API，按 app 分别开关，iOS 内置输入法打字的纠错。
- 历史列表里显示原话全文（只在 ⋮ 菜单里用）。

**不能出现的**

- 半句 AI 结果被当成完整结果发出去。只有 `LlmDone` 才替换（网关保证没说完时不给 200 完整流；`LlmApi.run` 把中途断开算 `LlmFailed`）。
- 用户的话丢了：任何失败、取消、会话不能发，最后都要么发原话，要么原话留在写作面板或草稿里。
- 用户被卡住：整理中、失败后，「直接发送」都始终能点。

## 3. 现在是怎么做的（要改到的地方）

- `VoiceHold._release()`：`await voice.stop()` 拿到转写文字，然后选「发送」就调 `send(text)`（即 `sendVoice`），选「编辑」就调 `edit(text)`（`composer.keep(text)` 再打开面板）。随后调 `_end(pick)`。桌面上 `onEnd` 会通知原生 `voice_end`，焦点回到画面。
- `sendVoice`：空 → 提示「没听清」；会话被挡或正在分离 → `keep` 进草稿并提示；composer `busy` → `keep` 并提示；否则 `composer.submitText(t)` 再调 `port.composerSend`。
- 松手到发出之间没有任何界面；之后只有一个小提示气泡（`voiceHint`）。
- 输入记录：`InputRecorder` 从 composer 的 `onSubmitted` / `onFinished` 拿到 `Outgoing`，在 `_sentRecord` 里写 `source: 'typed'`。语音发送的 `Outgoing` 只有 `draftless: true` 这一个标记。
- 历史列表（`gui/lib/history/history_list.dart`）一行显示时间、第一行文字、草稿标记和发到哪里；⋮ 菜单有「放进输入框 / 复制到本机 / 从记录里去掉」。

## 4. 做法

### 4.1 选的做法（用户同意）

在共用的语音状态机里加一个「整理中」阶段，两边共用一张整理卡片，全部在 Dart 里实现。

另外考虑过的两种：

- 松手后一律打开写作面板，让 AI 在面板里改：每次都要多按一次发送，和「整理好就直接发」相反。不采用。
- 卡片用原生代码分别写（Swift + Linux）：两套实现，而语音界面本来全在 Dart。不采用。

### 4.2 用户的两个决定

- **D1 失败时停住等用户点**，不自动发原话。卡片显示「AI 整理失败：<原因>」，留着原话，按钮「编辑」「直接发送」。
- **D2 一条记录，原话附在里面**：只记发出去的那条，带 AI 标记，原话存在这条记录的字段里，在 ⋮ 菜单看或用。↑ 翻到的是发出去的 AI 文字。

## 5. 设计

### 5.1 何时整理

在 `VoiceHold._release()` 拿到转写文字之后、调 `send` / `edit` 之前判断。同时满足以下条件才整理：

1. 去掉空白后的字符数（按 Unicode 字符数，`runes`）**大于 10**；
2. LLM 接入点已设置（`state.llm.configured`）；
3. 全局设置新开关「长语音先让 AI 整理」打开（`gui.json` 的 `voice_ai_tidy`，缺省为开）；
4. 这个会话此刻不是密码框（`rs.secureFocus` 为假）。对着密码框说的话不发给 LLM。

有一条不满足就照旧：发送走 `sendVoice`，编辑走 `edit`。

接入点没设置时不提示任何东西。只有设置了却调不通，才算故障（G3）。

### 5.2 整理这件事挂在哪里

新建 `VoiceTidy`（`ChangeNotifier`，建议放在 `gui/lib/embed/voice_tidy.dart`），**每个会话一个，挂在 `RemoteSession` 上**，不挂在 `VoiceHold` 上。这样整理中切到别的会话再切回来，卡片还在，结果也只会发回原来那个会话。终端会话本来就有 `RemoteSession`（`term/term_stage.dart:85`），同样处理。

`VoiceTidy` 不靠 widget 闭包去发送：建的时候注入 `MainState`，发送时用 `state.portOf(sid)` 现取 port（widget 可能已经销毁）。发不出、放回草稿这类结果提示，显示在卡片自己的位置上（卡片换成一行提示，1.5 到 2 秒后淡出），不借用某个 `VoiceHold` 的提示气泡。

状态：

| 状态 | 卡片显示 | 进入方式 |
|---|---|---|
| `idle` | 不显示 | 初始；送出、编辑、取消之后 |
| `tidying` | 标题「AI 整理中…」；正文先是原话（淡色），收到第一段后换成 AI 文字并逐段变长；按钮「编辑」「直接发送」 | 松手后满足 §5.1 |
| `failed` | 标题「AI 整理失败」，下一行写原因（`LlmFailed.reason`）；正文是原话；按钮「编辑」「直接发送」 | `LlmFailed` |

`VoiceTidy` 记住：原话 `original`、松手时的去向 `pick`（发送或编辑）、正在跑的 `LlmCall`、到目前为止的 AI 文字。

结束的几种方式：

- **`LlmDone`，去向是发送**：用 AI 文字走 `sendVoice` 那一套（重新检查会话被挡、分离、`busy`；不能发就 `keep` AI 文字进草稿并给出原来的提示），`Outgoing` 带上 AI 标记（§5.4）。之后回到 `idle`。
- **`LlmDone`，去向是编辑**：AI 文字 `keep` 进草稿、打开面板，并在 composer 上记一笔「待发的 AI 来源」（§5.4）。之后回到 `idle`。
- **`LlmDone` 但结果去掉空白后是空的**：当作失败，原因写「AI 没有给出结果」。
- **点「直接发送」**：取消 `LlmCall`，用原话走 `sendVoice`，`Outgoing` 只带语音标记，不带 AI 标记。
- **点「编辑」**：取消 `LlmCall`，原话 `keep` 进草稿并打开面板，不记 AI 来源。
- **同一会话又按下语音**（开始新一次录音），不管是整理中还是失败：取消 `LlmCall`，原话 `keep` 进草稿，卡片关掉。新的录音照常开始，结束后新的录音自己再判断要不要整理。原话不自动发出（D1），也不会丢。
- **重连换了会话对象**：`MainState._dropOld` 在 `to.composer.adoptFrom(gone.composer)` 时，把旧会话的 `VoiceTidy` 交给新会话（`adoptFrom` 一类的接管）。整理继续跑，结果发到新会话；失败状态也原样带过去。旧会话 dispose 时不再取消已经交出去的整理。
- **会话真的关掉**（没有接管的会话）：取消 `LlmCall`，原话 `keep` 进它的草稿（关掉的会话草稿照旧由输入记录存成 `draft` 记录）。
- **分离（detach）**：sid 和 `RemoteSession` 都不变，整理照常。结果到手时 `sendVoice` 会因为 `isDetaching` 把文字 `keep` 进草稿，这是现有行为。
- **超时**：`LlmApi.run` 等响应头最多 `firstByte + 5s`（缺省 15 秒）。拿到第一段以后不再单独计时，由 `VoiceTidy` 的整体上限 30 秒兜底，从开始整理算起，到了就取消 `LlmCall` 并算失败，原因写「LLM 没有及时回应」。

`_end(pick)` 和 `onEnd` 的时机不变：松手处理完就调。桌面上焦点照旧回到画面，原生照旧收到 `voice_end`。整理在后台进行，卡片靠点击操作，不需要键盘焦点。

### 5.3 卡片

一个共用组件 `VoiceTidyCard`，监听当前会话的 `VoiceTidy`，状态是 `idle` 时不占位置。

- 卡片是 `composerLayer` 里单独的一层，**不借用 `DesktopVoice` 的按住说话淡出逻辑**：卡片挂着时，舞台那一排其余按钮（输入、还原、传输取消、按住说话）照常显示、照常能点。
- **桌面**：卡片右边缘对齐舞台那一排的右端，贴在那一排的上方。写作面板打开时（面板一开 `DesktopVoice` 就不建了，`composer_panel.dart:707`），卡片贴在面板上方，右边缘对齐面板。松手到卡片出现之间不留空白：语音列退出动画和卡片淡入同时进行，正文先放松手时的那段文字。
- **iOS**：放在语音按钮旁边、舞台按钮排的上方；写作面板开着时放在面板上方（同 `_VoiceAbovePanel`）。遮罩照旧在松手时退出，卡片不加遮罩，舞台其余部分照常能点。

```
┌ AI 整理中… ───────────────────────┐
│ 我们明天下午三点开会，要讨论一下端│
│ 口分享。▍                          │
│                 [编辑]  [直接发送]  │
└────────────────────────────────────┘

┌ AI 整理失败 ───────────────────────┐
│ 连不上 LLM 接入点                   │
│ 嗯那个我门明天下午三点开会然后要讨…│
│                 [编辑]  [直接发送]  │
└────────────────────────────────────┘
```

- 正文最多显示 4 行，超出时显示最后 4 行（同 `voice_overlay.dart` 的 `_tailOf`）。
- 「直接发送」是主按钮，「编辑」是次按钮，都用 `RappButton`。去向是编辑时，「编辑」做主按钮。
- `LlmDone` 自动发出后，卡片淡出（约 160 ms，同桌面语音列的退出），并用已有的提示气泡显示「已用 AI 整理」1.5 秒。
- 失败原因用 `LlmFailed.reason`，它已经是给用户看的中文短句；网关原始的 `message` 和状态只写日志（`state` 的 `_log`，一行：接口、状态、耗时，不记文字内容）。

### 5.4 输入记录

**`Outgoing` 加一个可选字段 `voice`**（类型 `VoiceOrigin`）：

```
VoiceOrigin(ai: null)                                           // 普通语音发送
VoiceOrigin(ai: VoiceAi(app: 'dictation', original: <原话>, result: <AI 文字>))
```

`ComposerModel.submitText(text, {VoiceOrigin? voice})` 把它放进 `Outgoing`。`sendVoice` 多一个参数 `voice`，所有语音发送都带上（不带 AI 时 `VoiceOrigin()`）。

**写记录**（`InputRecorder._sentRecord`）：

- `o.voice != null` 时 `source` 写 `voice`，否则仍写 `typed`。
- `o.voice?.ai != null` 时多一个字段：

```json
"ai": {"app": "dictation", "original": "嗯那个我门明天下午三点开会…", "result": "我们明天下午三点开会，…"}
```

`result` 是网关给的原样结果。直接发出时它和 `text` 相同，经过编辑再发时 `text` 是实际发出的文字。

**编辑这条路**：去向是编辑、AI 文字进了写作面板时，composer 记下 `pendingAi = VoiceAi(...)`。之后这个 composer 从面板发出的下一条（不是 `draftless` 的那种），`Outgoing.voice = VoiceOrigin(ai: pendingAi)`，记录就带上 `source: voice` 和 `ai`。规则：

- 清掉 `pendingAi`：发出过一次；草稿被清空（变成空字符串）而没发；↑ / ↓ 召回把草稿换成了别的内容。
- 连续两次编辑路：后一次覆盖前一次（`original`、`result` 只记最近一次口述）。
- 草稿里原来就有字，AI 文字接在后面：整条仍标 AI。`ai` 的含义是「这条里有 AI 整理过的话」，`ai.result` 说明是哪一段。
- 重连时 `adoptFrom` 把 `pendingAi` 一起带到新 composer。

**`Outgoing` 的其他来源**：`adoptFrom` 重新造行（`composer_model.dart:740` 一带）和 `retry` 复用行时，`voice` 字段都要原样带过去。

**《输入记录》规格要改的**（`docs/superpowers/specs/2026-11-14-rapp-input-history-design.md` §4）：`source` 改为 `typed` | `voice`；新增可选字段 `ai`，含义如上。读的人照旧跳过不认识的字段，老记录不受影响。

### 5.5 历史列表

- `InputEntry` 加 `aiOriginal`（从 `raw['ai']['original']` 读，没有或不是字符串就是 null）。
- 有 `aiOriginal` 的行，在第一行文字后面显示一个小的「AI」标记，样式和「没发出」草稿标记一致。
- ⋮ 菜单在「放进输入框」下面多两项：「原话放进输入框」「复制原话」。
- ↑ / ↓ 召回的仍是 `text`（发出去的 AI 文字），按 D2 不单独召回原话。

### 5.6 全局设置

在「LLM 接入点」那一块上方加开关「长语音先让 AI 整理」，说明文字写「超过 10 个字时，先用 LLM 接入点整理再发」。缺省为开，存在 `gui.json` 的 `voice_ai_tidy`。接入点没设置时开关照常显示，但不起作用（§5.1 第 2 条）。iOS、macOS、Linux 都显示。

## 6. 留给实现的人

- 卡片的确切尺寸、间距、动画曲线。
- 卡片正文在 AI 文字逐段变长时的滚动、换行细节。
- 整体 30 秒上限的计时方式。
- 日志行的具体格式（不得包含文字内容）。
- 测试的组织方式：`VoiceTidy` 的状态迁移（用假 `LlmApi`）、`sendVoice` 带 `voice`、记录里的 `source` 和 `ai`、历史列表的标记和菜单、开关的读写。

## 7. 我定的（可改）

- 阈值按去掉空白后的 Unicode 字符数算，标点也算字。
- 新开关「长语音先让 AI 整理」，缺省开。
- 对着密码框说的话不送去整理。
- 整理中或失败时又开始新录音：上一次的原话放进草稿，不自动发。
- 重连时整理和卡片跟着搬到新会话。
- 卡片挂着时舞台其他按钮照常可用；桌面面板打开时卡片贴在面板上方。
- 草稿里原来就有字时，带 AI 文字发出的整条都标 AI。
- 文本终端里的语音同样整理（终端里常用来给 Claude Code 之类口述长句）。
- 自动发出后显示 1.5 秒「已用 AI 整理」。
- 失败时也显示原话，方便判断要不要直接发。
- 编辑这条路发出的记录带 `ai`，哪怕用户改过文字；`ai.result` 保留 AI 给的原样。
