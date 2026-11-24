# 语音纠错学回词表 + 按用途整理（可行性方案与设计）

2026-11-21。依据：

- vault 文章 `sotvault/chat-insights/2026-11-20-wechat-newsoftclub-voice-input-correction-loop.md`（NewSoftClub 群关于语音输入法的讨论整理），其中「候选需求」7 条。
- 现有实现：《长语音先让 AI 整理》（`2026-11-20-rapp-voice-ai-tidy-design.md`，含 §8 流式替换、§9 提速），rapp-llm 网关（`/Users/bruce/git/rapp-llm`），note.md 勘误表插件（`/Users/bruce/git/note.md/plugins-src/conversation-dictionary`）。
- 用户 2026-11-21 的四个决定（§4）。

## 1. 为什么做

文章的核心主张：语音输入要成为一个能自我纠错的回路——一次说完一整段，ASR 给出完整转写，用个人词表和记忆做后处理，人对结果的二次编辑写回词表，下次语音就能用上这次修正。

对照现状，文章 7 条需求里已经做到的：

| 需求 | 现状 |
|---|---|
| 1 整段提交 | 已做：松手后整理；按住时停顿 0.8 秒先预取（tidy §9） |
| 2 开放的后处理 | 已做：`dictation` 带 `vocabulary, user, memory` 三份上下文；热词交给 Apple 识别 |
| 4 断线不丢稿 | 基本已做：AI 失败按原话走（D3）；会话断线时语音文字进草稿并提示「连接已断开…尚未发送」，重连后草稿随 `adoptFrom` 带过去 |
| 5 专有名词 | 部分：词表 + 热词 + 常识纠正都有，但词表全靠手工维护 |

这份方案只处理还没做的三件：

- **纠错回路**（需求 3）：人的改动没有回到词表。
- **候选修正**（需求 6）：发现错词只能整段编辑或 ⌘Z 还原整段。
- **按用途整理**（需求 7）：只有 `dictation` 一种强度，发给真人的话也被分点、精炼成「数字人」口气。

## 2. 可行性结论

| 件 | 结论 | 关键约束 / 风险 |
|---|---|---|
| A 纠错学回词表 | 可行，需改 rapp + rapp-llm，不改 note.md | 正式词表 `vocabulary.md` 由 note.md 插件生成、整份覆盖，标明只读；插件命令行只有 `propose`（建待确认候选）和 `dataset-import`（导入后仍要逐条确认），没有「确认」命令，也不允许绕过插件改 `conversation-dictionary.yml`（插件校验哈希）。所以「马上生效」只能由网关另存一份（D5）。`propose` 的输入要求（`SourceContext`、`subject_id`、`--input` 必须是 vault 内相对路径）要先用探针验证（§6.1）。 |
| B 气泡里点错词切换 | 可行，只改 rapp（Dart，三平台共用） | 「AI 改过哪些词」靠原话和 AI 文字的字符级比对；`dictation` 会删口头禅、调语序，比对出的改动可能很碎或整段都变。需要过滤规则和「改动太多就不标」的退路（§5.3）。 |
| C 按用途整理 | 可行，改 rapp + rapp-llm 加一个小 API | 桌面整屏会话（`desktop:`）里 rapp 不知道对方此刻是哪个 app，只能整屏一个设置（§5.5）。 |
| 断线自动重发 | 不做 | 已经不丢；重连后对方 app 的焦点可能变了，自动发出去风险大于收益。 |

## 3. 目标、不做的、不能出现的

**目标**

- G1 气泡里标出 AI 改过的词；点一下在「AI 的写法」和「原话的写法」之间切换（D2），点过之后不再自动发送。
- G2 用户的改动能变成一条「记住这个改法？」提示，点「记住」后下一次整理和下一次语音识别（热词）就用上（D1、D5）。
- G3 「记住」的每一条同时作为候选交给 note.md 勘误表；用户在 note.md 里确认后，网关自动从自己那份里删掉重复的（D5）。
- G4 整理分两种：「提示词」（现在的 `dictation`）和「对人」（新小 API）；按对方 app 自动选，可在气泡上切换并按 app 记住（D3）。

**不做的**

- 写作面板（原生编辑框）里选中词弹候选。
- 不经过语音的打字纠错写回词表（打字没有「错的原样」可比，iOS 内置 Rime 的用户词另说）。
- 会话断线后自动重发。
- 修改 note.md 插件。
- 自动「记住」：没有用户点「记住」，不写任何东西。

**不能出现的**

- 没点「记住」的改动进了词表。
- 「记住」提示挡住发送、或让一条原本会自动发出的话卡住不发。提示只在发送之后或气泡已经停住时出现。
- 学到的词把正式词表里已有的规则顶掉或冲突后悄悄生效：冲突时以正式词表为准（§6.3）。
- 切换「提示词 / 对人」时丢掉原话。

## 4. 做法

### 4.1 用户的决定（2026-11-21）

- **D1 在 rapp 里点一下确认**：改动出现「记住：拍森 → Python？」，点「记住」才算数；不点就不记。（另外考虑过：只把候选交给 note.md 再去那里确认——回路慢、候选容易攒着；网关不经确认自动记——没确认的错改法也会马上生效。）
- **D2 气泡里标出 AI 改过的词**：点一下切换原话写法和 AI 写法。（另外考虑过：写作面板里选中弹候选——三个平台的编辑框都要改，工作量大好几倍；这次不做——用户选了做。）
- **D3 按对方 app 自动定「提示词 / 对人」，可改并记住**。（另外考虑过：每个会话手动设——发微信前要记得先设；每次在气泡里选——经常切就要多整理一次。）
- **D5 网关先记一份，note.md 里再收编**：note.md 插件没有「确认候选」命令（见 §2）。「记住」的词先写进网关自己的「语音改正」文件，马上生效；同时 `propose` 成 note.md 候选；note.md 里确认后，网关发现正式词表已有就删掉自己那条。（另外考虑过：给插件加 `accept` 命令——要改 note.md 并发版；只提候选——不能马上生效。）

（D4 编号空着，避免和 tidy 规格 §8 的 D3、D4 混淆：本文 D3 指用途切换。）

### 4.2 整体分工

```
rapp（Dart）                         rapp-llm 网关                     note.md vault
────────────                         ─────────────                     ─────────────
气泡比对、标词、切换  ──记住──▶  POST /v1/vocabulary/learn  ──propose──▶ 待确认候选
编辑路发出后比对      ──记住──▶      写 voice-learned.md
                                     （dictation*、hotwords 都读它）
按 app 选 dictation / dictation-chat ─▶  /v1/apps/<名字>
                                     每次读时去掉 vocabulary.md
                                     已有的条目            ◀──生成── vocabulary.md
```

## 5. rapp 侧设计

### 5.1 比对：AI 改了哪些词

在 `VoiceTidy` 拿到 `LlmDone` 之后（不在流式过程中），用原话 `original` 和 AI 结果 `result` 做一次字符级比对，得到一组「改动」：`Change(at: AI 文字里的范围, before: 原话片段, after: AI 片段)`。

规则（我定的，可改）：

1. 用最长公共子序列（按 Unicode 字符）比对，相邻的「删」+「增」合成一个替换。
2. 丢掉只是标点、空白、换行、编号（`1.`）、大小写差别的改动。
3. 丢掉纯删除（口头禅、重复）和纯增加——它们不对应「某个词被改成了别的词」，切换回去也没有意义。
4. 两边都去掉空白后，`before` 和 `after` 都不超过 12 个字，才算一个可切换的改动。
5. 一个改动的 AI 一侧不足 2 个字的，向两边扩到 2 个字，好点。
6. 退路：可切换的改动超过 8 个，或公共部分不到原话的一半（整段重写了），一个都不标，气泡照旧。

比对是纯函数，单独一个文件（建议 `gui/lib/embed/tidy_diff.dart`），用表驱动测试覆盖：同音字（我门→我们）、英文名（拍森→Python、黑猫瑞→Hemory）、口头禅删除、整段重写、编号分行。

### 5.2 气泡：标词与切换

整理好之后（发送路在 1.5 秒 `settle` 等待里，编辑路在交给写作面板之前），气泡正文里每个可切换的改动下面画一道虚线。

```
┌ 整理好了 · 提示词 ⇄ ──────────────┐
│ 明天用 Python 跑一下 Hemory         │
│        ﹋﹋﹋﹋        ﹋﹋﹋﹋        │
│ 原话 · 明天用拍森跑一下黑猫瑞…      │
│           [还原] [编辑] [发送]      │
└────────────────────────────────────┘

点 Hemory 之后：

┌ 整理好了 · 提示词 ⇄ ──────────────┐
│ 明天用 Python 跑一下 黑猫瑞         │
│        ﹋﹋﹋﹋        ﹋﹋﹋         │
│ 记住：别把「黑猫瑞」改成「Hemory」？ │
│                    [忽略] [记住]    │
│ 原话 · 明天用拍森跑一下黑猫瑞…      │
│           [还原] [编辑] [发送]      │
└────────────────────────────────────┘
```

- 点一个虚线词：这个位置在 AI 写法和原话写法之间切换。和点开「原话」对比行一样，**一点就停住**：去掉倒计时条，不再自动发，等用户点 发送 / 还原 / 编辑（同 tidy §8.2）。
- 切换后，发送、编辑用的都是切换后的文字；`VoiceAi.result` 仍记 AI 原样，新增 `VoiceAi.final` 不需要——发出的 `text` 本来就是实际文字（tidy §5.4）。
- 切回原话写法 = 「AI 把这里改错了」，气泡里出现一行「记住：别把「X」改成「Y」？ [忽略] [记住]」。同一个气泡里一次只显示最近一次切换的那条；点「记住」后这一行换成「已记住」淡出。
- 不提供第三个写法（词表近音词）：这一版只在原话和 AI 之间切换。改成第三种写法走「编辑」，由 §5.4 学。
- 在 iOS 上同样实现；虚线词的点击区域至少 44pt 高。
- 系统减弱动画时，虚线和提示行不做动画。

### 5.3 什么样的改动能「记住」

两种来源，生成同一种请求（§6.2）：

| 来源 | 触发 | 生成 |
|---|---|---|
| 气泡里切回原话 | §5.2 | `preserve`：「X」不要改（插件的 `do not change: x`） |
| 编辑路发出 | 写作面板发出的那条带 `pendingAi`，并且发出的文字和 `ai.result` 不同 | 对 `ai.result` 和发出的 `text` 用 §5.1 同一套规则比对，每个替换再映射回原话（见下），成为一条 `replace`：「原话片段 → 用户写的」 |

**学到的 `observed` 必须是原话（ASR 听到的）里的片段**，不是 AI 写的：下一次整理的输入是 ASR 文字，note.md 的 propose 也要在 ASR 原文里定位 `observed`。所以编辑路要三方对齐（原话 ↔ AI ↔ 发出）：

- 用户改的那段 AI 文字，在「原话 ↔ AI」比对里没被 AI 改过（AI 原样留下了识别错的词，如「黑猫瑞」）：`observed` 就是原话里对应的那段。
- 用户改的那段正好落在 AI 的一个改动上（原话「拍森」，AI 写成「Pyson」，用户改成「Python」）：`observed` 取这个改动在原话一侧的片段（「拍森」）。
- 映射不回原话的（跨了好几处改动、落在 AI 新加的字上），丢掉，不出提示。（我定的：宁可少学，不学错。）

编辑路发出后，在舞台那一排上方（同 `voiceHint` 气泡的位置）显示提示：

```
┌──────────────────────────────┐
│ 记住这个改法？                │
│ 拍森 → Python                │
│            [忽略]  [记住]     │
└──────────────────────────────┘
```

- 一次发出比对出多条时，一条提示列出最多 3 条，每条前面一个勾选框，默认全勾；超过 3 条只列前 3 条（我定的：多了说明是重写，不是纠错）。
- 提示停留 8 秒，期间开始打字、按语音键、点别处都不关它；8 秒后淡出，等于「忽略」。
- 不经过 AI 的普通打字发出，不出提示（不做的）。
- 密码框会话（`secureFocus`）不出提示，也不发任何学习请求。

### 5.4 「记住」之后

- rapp 调 `POST /v1/vocabulary/learn`（§6.2），不等结果，失败只写日志，提示行照样显示「已记住」——网关不通时下次整理本来也用不上，没必要打扰（我定的，可改）。
- 成功后立刻让热词缓存失效（`/v1/hotwords` 的 10 分钟缓存），下一次开始听就带上新词。

### 5.5 按用途整理

两种用途：

| 用途 | 小 API | 效果 |
|---|---|---|
| 提示词 | `dictation`（现有） | 精炼、几件事分行编号、去口头禅 |
| 对人 | `dictation-chat`（新） | 只改识别错字、专有名词、去口头禅和重复；保留口气和语序；不分点、不编号、不扩写、不精炼成书面语 |

**按 app 选**（我定的默认表，可改）：

- 文本终端会话：提示词。
- app 会话，按 `SessionRecord.app` / `appName` 不分大小写包含匹配：
  - 对人：`WeChat`、`微信`、`Lark`、`Feishu`、`飞书`、`WeCom`、`企业微信`、`DingTalk`、`钉钉`、`Telegram`、`Slack`、`Mail`、`邮件`、`Messages`、`信息`、`QQ`。
  - 其余：提示词。
- 整屏会话（`desktop:`）：rapp 不知道对方前台是哪个 app，整屏一个设置，默认提示词。

**切换**：气泡标题后面显示当前用途「提示词 ⇄」或「对人 ⇄」，点一下：

- 取消当前整理（或丢掉已整理好的结果），用另一种用途对**原话**重新整理；原话不丢，倒计时、对比行照旧。
- 这个 app 以后都用新选的用途：存进 `gui.json` 的 `voice_tidy_mode`，键是 `app`（终端会话用 `term`，整屏用 `desktop:<设备 id>`），值是 `prompt` / `chat`。
- 预取（tidy §9 边说边整理）按当时的用途发；松手时用途没变才接着用。

**记录**：`VoiceAi.app` 已经记着小 API 名，`dictation-chat` 照样写进记录的 `ai.app`。

**全局设置**：语音输入一节加一行说明「发给聊天软件的话按『对人』整理（保留口气，不分点），其余按『提示词』；在整理气泡上点用途可改」，再加一个「恢复默认」按钮清空 `voice_tidy_mode`。不做逐 app 编辑列表。

### 5.6 全局设置：学到的词

语音输入一节加「语音学到的词」一行，点开列出网关 `GET /v1/vocabulary/learned` 的条目（`拍森 → Python`、`不改：黑猫瑞`），每条一个删除按钮（`DELETE`）。接入点没设置或拿不到时这一行不显示。

## 6. rapp-llm 网关侧设计

### 6.1 先做的探针：`propose` 能不能从网关调通

在写任何 rapp 代码之前，先在网关机器上手工跑通一次：

1. 在 vault 里写一份 proposal（`--input` 必须是 vault 内相对路径；建议放 `tmp/rapp-llm/`，写完即删）。
2. 字段：`schema`、`observed`、`domain_id: public`、`context.subject_id`（读 `notemd conversation-dictionary status` 的 `subject_id`，现在是 `human:me`）、`context.communication`（`kind: conversation`、`user_relation: participant`、`basis` 照插件要求）、`candidates[0]`（`output`、`kind`、`confidence`、`reason`）、`proposed_by: rapp-llm`。
3. 跑 `notemd conversation-dictionary propose --input …`，再 `pending` 看到候选。
4. 在 note.md 插件窗口里确认它，看 `vocabulary.md` 重新生成后出现这一条。

另外两点要在探针里一并看清：

- **来源字段**：`validate_proposal` 要求一个 ASR 转写类的来源（`CandidateSource`：`content_kind`、`content_sha256`、`span`、`excerpt`、`excerpt_span`），`span` 要能在 `excerpt` 里定位到 `observed`。rapp 发来的 `excerpt` 用原话（§5.3），网关据此算 span 和 sha256。
- **「不改」能不能提**：`ProposalInput` / `CandidateSuggestion` 没有 action 字段，`preserve` 只存在于已确认的规则上。试 `output == observed` 的候选是否被接受、确认后是否生成 `do not change`。不行的话，`preserve` 只写进 `voice-learned.md`、不 propose，长期留在网关那份里（§6.3 收编时 `preserve` 条目只在正式词表出现同一个 `do not change` 时才删）。

探针结果决定 §6.2 的 propose 字段怎么填。**如果 `validate_scope_claim` 一类校验要求真实的会议来源，propose 做不通**：那就只做 voice_learned 这一份（马上生效那部分不受影响），G3 降级为「全局设置里列出学到的词，用户自己去 note.md 加」，并回来跟用户确认。

**探针结果（2026-11-21）：可以做，不降级。** 在 vault 里手工跑 `notemd conversation-dictionary propose --input tmp/rapp-llm/probe.json`（cwd 必须是 vault，`--input` 是相对 vault 的路径）。替换（`拍森 → Python`）和「不改」（`黑猫瑞`，`output` 等于 `observed`）都返回 `"status":"stored"`，进了 `pending`。通过校验的写法：

- `context.communication = {kind: "voice_message", user_relation: "participant", basis: {type: "user_statement", detail: "…"}}`。
- `source = {content_kind: "asr_transcript", content_sha256: sha256(excerpt), span, excerpt, excerpt_span}`：span 按 Unicode code point 算，不带 `resource`。
- `subject_id` 取 `notemd conversation-dictionary status` 最后一行 JSON 的值（现在是 `human:me`）。

「不改」的候选，reviewer 确认时要在 note.md 窗口里选 preserve（同词「替换」会被当成 no-op），所以 `reason` 里要写明「不要改」。确认后会不会生成 `- do not change:`，留到验收 5 由用户在 note.md 里看。

另外，网关的 context 名只能用 `[a-z0-9_]+`，所以 context 叫 `voice_learned`，文件名仍是 `voice-learned.md`。

### 6.2 新接口

- `POST /v1/vocabulary/learn`，body：

  ```json
  {"action": "replace", "observed": "拍森", "output": "Python", "excerpt": "明天用拍森跑一下"}
  {"action": "preserve", "observed": "黑猫瑞", "avoid": "Hemory", "excerpt": "明天用拍森跑一下黑猫瑞"}
  ```

  1. 规范化（去首尾空白；`observed` 和 `output` 相同则 400）。
  2. 追加进 `voice-learned.md`（不分大小写去重；同一个 `observed` 的新规则覆盖旧规则）。
  3. 后台 `propose` 给 note.md（`domain_id: public`，`kind` 由网关粗判：全是拉丁字母 → `product`，其余 `other`；`excerpt` 进 `reason`）。propose 失败只记日志，不影响返回。
  4. 返回 `200 {"id": …, "object": "learned"}`。
- `GET /v1/vocabulary/learned`：列出当前条目（已去掉被正式词表收编的，§6.3）。
- `DELETE /v1/vocabulary/learned/<id>`：删一条（不撤回已经交给 note.md 的候选）。

所有接口照旧要 key；每请求一行日志，不记文字内容。

**配置与上线顺序**（我定的）：

- propose 是可选的：配置里新增 `"notemd": {"bin": "/usr/local/bin/notemd", "vault": "~/git/sotvault", "domain": "public"}`，没配（例如 Docker 部署，没有 vault 和 notemd）就只写 `voice-learned.md`，不 propose。`subject_id` 不写进配置，每次从 `notemd conversation-dictionary status` 读。
- 网关读 apps 时，`context:` 点名了配置里没有的 context 会 500 `app_invalid`，tidy 就会在所有设备上悄悄按原话走。所以上线顺序固定：先改正在运行的网关的 `config.json`（加 `voice_learned`、`notemd`），重启网关，再把带 `voice_learned` 的 `dictation.md` 和新的 `dictation-chat.md` 放进去。改 `config.json` 和重启由实现的人在用户点头后做（同 tidy §9 热词那次）。
- 正在运行的网关就在 vault 所在的这台 Mac 上（`127.0.0.1:8101`，rapp 经分享号 `localhost:28001` 访问）。

### 6.3 `voice-learned.md`：格式、读取、收编

- 位置：网关配置里新增一个 context，`"voice_learned": {"file": "~/rapp/voice-learned.md"}`（在 vault 外，避免和 vault 的 auto-sync、note.md 打架；我定的，可改）。
- 格式照 `vocabulary.md` 的写法，模型不用学新记号：

  ```
  # 语音改正（用户在 rapp 里确认过，note.md 收编前先用这里）
  - 拍森 → Python (always)
  - do not change: 黑猫瑞
  ```

  `replace` 一律写成 `(always)`：这是用户亲手确认过的改法。
- `dictation`、`dictation-chat` 的 `context:` 加上 `voice_learned`，放在 `vocabulary` 后面；提示词第 1 条改为「先按 <vocabulary> 和 <voice_learned> 改；两者冲突时按 <vocabulary>」。
- `/v1/hotwords`：`voice_learned` 里 `→` 右边的词排在最前面（它们是用户刚纠正的，最容易再错），然后是原来的顺序，总数仍最多 100。
- **收编**：每次读 `voice-learned.md`（整理请求、hotwords、learned 列表、rules）时，解析当时的 `vocabulary.md`；某条 `observed → output` 在任一场景里已有同样的规则**且那条带 `(always)`**（或 `do not change` 同一个词），就从 `voice-learned.md` 删掉它。正式词表里那条不带 `(always)` 时保留学到的这条：不带的只在上下文对得上时才改，设备本机纠词不用它，删了会让本机从「会改」变成「不改」（2026-11-25 改，见本机纠词规格 D9；rapp-llm 672e022）。正式词表里同一个 `observed` 有**不同**的 `output` 时，也删掉网关这条（以正式词表为准），日志记一行。
- 文件不存在就当空表；写文件用临时文件 + rename，防止并发请求写坏。

### 6.4 新小 API `dictation-chat`

`apps/dictation-chat.md`，`model: text-lite`、`context: vocabulary, voice_learned, user, memory`、`timeout_s` 与 `think.*` 同 `dictation`。规则在 `dictation` 的基础上：

- 保留：第 1–3 条（词表、user/memory、常识名称）、口头禅和重复的删除、改口以最后为准、全部信息保留、问题不回答。
- 改掉：不精炼、不改写成书面语、保留原来的语序和说话口气（「哈」「吧」这种带情绪的语气词保留，只删「嗯、那个、就是」这类填充词）；不分点不编号，一律一段，长了按意思分段。
- 输出照旧纯文字。

提示词的具体措辞留给实现的人，用 5 段真实口述（微信聊天口吻）对比 `dictation` 和 `dictation-chat` 的输出，用户看过再定稿。

## 7. 阶段与顺序

1. **探针**（§6.1）：半小时以内，结果写回本文 §6.1。
2. **网关**：`voice_learned` context、三个接口、收编、hotwords 排序、`dictation-chat`。rapp-llm 自己的测试；在 rapp-llm 的 worktree 里改，**不要在 `/Users/bruce/git/rapp-llm` 主目录切分支**（正在跑的网关每次请求重新读 apps/*.md）。
3. **rapp 比对 + 气泡标词切换**（§5.1、§5.2）：不依赖网关新接口，可和 2 并行。
4. **rapp 记住**（§5.3、§5.4、§5.6）：依赖 2。
5. **rapp 按用途**（§5.5）：依赖 2 的 `dictation-chat`。

每一阶段单独分支，交给 rapp-49 合并（main 只由 rapp-49 合）。

## 8. 验收（实机）

1. 说一句含「Python」的话，AI 把识别出的「拍森」改成 Python：气泡里 Python 下有虚线；点它变回「拍森」，倒计时消失，不自动发。
2. 1 里点回「拍森」后出现「记住：别把『拍森』改成『Python』？」，点「记住」→「已记住」；全局设置「语音学到的词」里出现「不改：拍森」。
3. 走编辑路，在写作面板把 AI 留下的「黑猫瑞」改成「Hemory」并发出：出现「记住：黑猫瑞 → Hemory」；点「记住」后，再说一遍同样的话，AI 直接写成 Hemory。
4. 3 之后 10 分钟内再说「Hemory」，Apple 识别直接认对或 AI 改对（热词已刷新）。
5. 3 之后 `notemd conversation-dictionary pending` 里有这条候选；在 note.md 里确认后，「语音学到的词」里这一条消失，整理仍然写成 Hemory。
6. 不点「记住」或 8 秒后提示淡出：`voice-learned.md` 不变，`pending` 不变。
7. 在微信会话里说一段带「哈」的闲聊：标题是「对人」，输出一段、不编号、口气还在。在终端会话里说三件事：标题是「提示词」，分行编号。
8. 在微信会话里点「对人 ⇄」改成提示词：重新整理一遍，原话对比行还在；下次在微信会话说话，默认就是提示词；全局设置「恢复默认」后又回到对人。
9. 网关停掉时点「记住」：提示仍显示「已记住」，整理照旧失败按原话走，没有报错弹窗。
10. 一段整段重写的口述（AI 改了一大半）：气泡里一个虚线都没有，其余照旧。
11. 密码框会话：没有任何「记住」提示，网关日志里没有 learn 请求。
12. iOS 上 1、2、7 各做一遍，虚线词点得中。

## 9. 留给实现的人

- 字符比对的具体算法（LCS 或 Myers），长文字的性能（口述一般几百字以内）。
- 虚线的样式、提示行的动画、勾选框的样式。
- 网关里 `kind` 的粗判细节、`voice-learned.md` 的解析写法、id 的生成方式。
- `dictation-chat` 的提示词措辞（按 §6.4 的要求，用户看过定稿）。
- 测试的组织：`tidy_diff` 表驱动；`VoiceTidy` 切换、停住、记住提示的状态迁移（假 `LlmApi`）；`voice_tidy_mode` 读写；网关的 learn / 收编 / hotwords 排序。

## 10. 我定的（可改）

- 比对规则 §5.1 的阈值：12 个字、最少 2 个字、超过 8 个改动或公共部分不到一半就不标。
- 气泡里只在原话和 AI 之间切换，不给第三种写法。
- 切回原话生成 `preserve`（「不改」），编辑路生成 `replace`。
- 编辑路一次最多列 3 条，默认全勾；提示 8 秒后淡出等于忽略。
- 「记住」不等网关结果，失败不提示。
- `replace` 一律写成 `(always)`；场景一律 `public`。
- `voice-learned.md` 放在 vault 外（`~/rapp/`）。
- 正式词表和网关那份冲突时以正式词表为准，并删掉网关那条。
- 按 app 的默认表（§5.5），整屏会话整屏一个设置、默认提示词。
- 用途切换存 `gui.json` 的 `voice_tidy_mode`，全局设置只给「恢复默认」，不做逐 app 列表。
- 断线自动重发不做。
- 编辑路学到的 `observed` 一律映射回原话，映射不回的丢掉。
- propose 可选（没配 `notemd` 就不提）；`preserve` 提不了就只留在网关那份。
- 上线先改网关配置并重启，再放新的 apps 文件。
