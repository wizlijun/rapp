# 语音本机纠词（L1）+ 无 AI 学习 + 识别计时 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 松手后、发送前在 Dart 里按用户确认过的词表做精确替换（毫秒级、不靠网络），没有 AI 也能学，按下到第一个字的时间有日志。

**Architecture:** 网关 `GET /v1/vocabulary/rules` 已上线（rapp-llm 672e022，live）。客户端把规则存成 `local/voice-rules.json`，编译成 `VoiceRules`，`VoiceHold` 在按住和松手时都过一遍 `fix`；`VoiceTidy` 区分「原话」（识别器原样，只用于对照和学习）和改后的字（其余所有路径）；composer 记 `pendingHeard`，发出时用 `editLearns` 学。Swift 缓存语言/资源/格式查询并回报计时。

**Tech Stack:** Flutter/Dart（gui/），Swift（gui/macos/Runner/SpeechPlugin.swift，iOS 共用）。

**Spec:** `docs/superpowers/specs/2026-11-24-rapp-voice-local-fix-design.md`（D1–D10、D14 第一步、D18–D20；L2、D12、D13、D14 第二步不在本计划）。

## Global Constraints

- flutter 在 `~/development/flutter/bin`，不在 PATH：`export PATH=$HOME/development/flutter/bin:$PATH`。测试在 `gui/` 里跑 `flutter test` 和 `flutter analyze lib test`；跑完 `git checkout gui/pubspec.lock`。
- 本机这里的 `grep` 是 ugrep；需要 `-c`/`-v` 时用 `/usr/bin/grep`。
- 只在分支 `feat/voice-fix`（worktree `.worktrees/voice-fix`）上提交，不碰 main。提交信息英文，结尾 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- L1 耗时预算：1000 条规则、500 字，`fix` 不超过 5 毫秒。
- `observed` 去掉空白后少于 2 个字的规则丢掉（网关已过滤，`compile` 再挡一次）。
- 规则文件 `local/voice-rules.json` 权限 0600，用 `writePrivate`（同 `llm.json`），不进同步目录。
- 日志只记数量和毫秒，不记任何文字（D20）。
- 不改协议、A 端、relay；不加设置开关；`VoiceInput.text` 保持识别器原样。
- 来自正式词表（`source: vocabulary`）的改动被点回原话时的提示文案固定为：`这条在正式词表里，要改请去 note.md`。
- 碰了 SpeechPlugin.swift 就要编 macOS 和 iOS（iOS 工程直接引用这个文件）。

## Review Focus

1. 网关不通、整理开着的长句：整理失败后发出的是**改后**的字，不是原话（D6 `_goOriginal`/`sendNow`/`restore`/`editNow`/`closed`/`held` 都用 `_original`）。→ Task 5 测试 `tidy failure sends the fixed text`。
2. 「拍森 → Python」让字数跨过 10 字阈值：`wouldTidy` 和 `tidy` 必须拿同一份改后的字，否则交接时气泡闪。→ Task 4 测试 `wouldTidy and tidy see the same fixed text`。
3. 副本的接入点和当前接入点不同：当空表，不沿用别的网关的规则。→ Task 2 测试 `a copy from another endpoint is not used`。
4. 密码框：不纠词、不出任何记住提示。→ Task 2 测试 `voiceFix leaves secure focus alone`，Task 6 测试 `no learn offer under secure focus`。
5. 编辑路把来自正式词表的改动改回原话：不出 preserve（发了也会被网关删）。→ Task 6 测试 `reverting a vocabulary fix offers nothing`。

---

### Task 1: `voice_fix.dart` 纯函数

**Files:**
- Create: `gui/lib/embed/voice_fix.dart`
- Test: `gui/test/embed/voice_fix_test.dart`

**Interfaces:**
- Produces（规格 7.1 原样，外加以下）：
  - `enum FixAction { replace, preserve }`，`enum FixSource { vocabulary, learned }`
  - `class FixRule { const FixRule.replace(observed, String output, source); const FixRule.preserve(observed, source); action; observed; output; source; factory FixRule.fromJson(Map<String, Object?>) ; Map<String, Object?> toJson(); }` —— JSON 形如网关 `{"action","observed","output"?,"source"}`；不认识的 action/source 或缺字段时 `fromJson` 抛 `FormatException`（调用方跳过那一条）。
  - `class FixChange { start, end（改后文字里的 rune 偏移）, before, after, source }`
  - `class FixResult { text, changes; bool get changed => changes.isNotEmpty; }`
  - `class VoiceRules { factory VoiceRules.compile(List<FixRule>); static final empty; bool get isEmpty; final List<FixRule> rules（编译后留下的）; FixResult fix(String text); bool fromVocabulary(String observed, String avoid); }` —— `fromVocabulary`：有一条 `source == vocabulary` 的 replace，其 `observed`（按匹配规则比较）出现在 `observed` 里、`output` 出现在 `avoid` 里时为真（Task 5、6 用它决定「点回原话」能不能学）。
  - `class VoiceHeard { const VoiceHeard({required String heard, required String fixed}); bool get changed => heard != fixed; }` —— 识别器原样和 L1 结果，Task 3–5 传递用。

- [ ] **Step 1: 写表驱动测试** `voice_fix_test.dart`，每行 `(rules, input, expectedText, expectedChanges)`，至少：
  - 最长匹配：`[徐逊→徐迅, 徐逊说→X]`，`徐逊说了` → `X了`。
  - 重叠从左到右：`[ab→1, bc→2]`（拉丁要词边界，这条用中文：`[甲乙→1, 乙丙→2]`），`甲乙丙` → `1丙`。
  - 词边界：`[cloud→Cloud]`，`cloudflare` 不变；`用cloud跑` → `用Cloud跑`；`my cloud.` → `my Cloud.`。
  - 大小写：`[himory→Hemory]`，`打开 HIMORY` → `打开 Hemory`；output 原样写入。
  - preserve 挡住更短的替换：`[preserve 黑猫瑞, 猫瑞→Hemory]`，`黑猫瑞` 不变。
  - 替换起点在 preserve 前面又和它重叠：`[preserve 猫瑞, 黑猫→X]`，`黑猫瑞` 不变。
  - 单字规则被丢掉：`compile([在→再, 王 →汪])` 之后 `rules` 为空。
  - 空表：`VoiceRules.empty.fix('x')` 返回原样、无改动。
  - 中英混排多处：`[拍森→Python, 徐逊→徐迅]`，`徐逊用拍森跑` → `徐迅用Python跑`，changes 的 `start/end` 是改后文字里的 rune 偏移：`徐迅` 为 (0,2)，`Python` 为 (3,9)，source 正确。
  - `FixRule.fromJson`/`toJson` 往返；`fromVocabulary('徐逊', '徐迅')` 为真、对 learned 来源为假。
  - 性能：1000 条随机 2–6 字中文 replace 规则 + 500 字文本，`fix` 跑 20 次取中位数 < 5 ms（`Stopwatch`）。
- [ ] **Step 2:** `flutter test test/embed/voice_fix_test.dart` → FAIL（文件不存在）。
- [ ] **Step 3: 实现。** 匹配规则照规格 7.1 第 1–7 条。结构：按首字符（拉丁类规则用小写首字符）分桶，桶内按 `observed` 长度降序；先扫 preserve 占位，再扫 replace。拉丁类 = `observed` 只含 `[A-Za-z0-9 ]`；词边界 = 前后不是 `[A-Za-z0-9]`。同一 `observed`（NFC+小写）只留后出现的一条。
- [ ] **Step 4:** 测试通过；`flutter analyze lib test` 无新问题。
- [ ] **Step 5: Commit** `feat(gui): voice_fix — exact on-device fixing from confirmed rules`。

### Task 2: 规则同步、`voiceFix`、学到后立刻生效（D4、D7、D10、D18）

**Files:**
- Modify: `gui/lib/llm_api.dart`（`rules` 方法 + `VoiceRulesCopy`）
- Modify: `gui/lib/ui/main_state.dart`（热词块 `:3389–3445` 旁，构造 `:165`，`relocate` `:225`，`setLlm` `:3377`，`_learnItems` `:3402`）
- Test: `gui/test/ui/voice_rules_sync_test.dart`（新），以及给现有 `LlmApi` 假实现补 `rules`（若它们是 `extends LlmApi` 则默认实现即可，不用改）

**Interfaces:**
- Consumes: Task 1 的 `FixRule`、`VoiceRules`、`FixResult`。
- Produces:
  - `const voiceRulesFile = 'voice-rules.json';`
  - `class RulesReply { final bool unchanged; final String etag; final List<FixRule> rules; }`
  - `Future<RulesReply?> LlmApi.rules(LlmEndpoint e, {String? etag})` —— `GET {base}/v1/vocabulary/rules`，Bearer，带 `If-None-Match: "<etag>"`；200 → `RulesReply(unchanged: false, …)`（坏条目跳过）；304 → `RulesReply(unchanged: true, etag: etag, rules: const [])`；其余（404、超时、坏 JSON）→ `null`；不抛异常。照 `hotwords` 的写法。
  - `class VoiceRulesCopy { endpoint, DateTime fetchedAt, etag, List<FixRule> rules; static Future<VoiceRulesCopy?> load(String localDir); Future<void> save(String localDir); }` —— 文件内容 `{"endpoint","fetchedAt"(ISO),"etag","rules":[…]}`；读不出或格式不对返回 null。
  - `MainState.voiceRules`（`VoiceRules`，当前生效的）
  - `FixResult MainState.voiceFix(Object sid, String text)` —— `remote[sid]?.secureFocus ?? true` 为真时原样返回、无改动（D7）；否则 `voiceRules.fix(text)`。
  - `void MainState.voiceLog(String line)` —— 转给 `_log`（Task 3 用）。

- [ ] **Step 1: 写测试**（用临时 `localDir` 和假 `LlmApi`，照 `test/ui/voice_tidy_wiring_test.dart` 的搭法）：
  - `rules 200 writes the copy and fixes at once`：假 API 回 `[徐逊→徐迅 vocabulary]` → `voiceFix(sid, '徐逊来了').text == '徐迅来了'`，文件存在且权限 0600，内容含 endpoint。
  - `304 keeps the rules and moves fetchedAt`。
  - `a failure keeps the copy`：先 200，再让 API 回 null 并触发刷新 → 规则还在。
  - `a copy from another endpoint is not used`：磁盘上放一份 endpoint 为别的地址的副本，启动后 API 回 null → `voiceRules.isEmpty`。
  - `a copy is used at start before the gateway answers`：同一 endpoint 的副本，API 永不返回 → 仍能改。
  - `voiceFix leaves secure focus alone`：`secureFocus = true` 时原样返回。
  - `learning writes the rule locally first`：`_learnItems` 成功一条 `replace 拍森→Python` 后（API 的 `rules` 还没回），`voiceFix` 立刻把「拍森」改成 Python；同一 `observed` 的旧 vocabulary 条被盖掉；随后发起一次 `rules` 拉取。
  - `forget refetches`：`forgetLearned` 成功后发起一次 `rules` 拉取，本机不自行删除。
- [ ] **Step 2:** 跑测试 → FAIL。
- [ ] **Step 3: 实现。** 刷新时机同热词：构造时先 `load` 副本（endpoint 等于 `llm.url` 才用），再 `_refreshRules()`；`relocate`/`setLlm` 换接入点时清空并重拉；`_forgetHotwords` 里一起把 `_rulesAt` 置空并重拉；`voiceHotwords()`（每次录音开始调用）里副本超过 `_hotwordsAge` 就重拉。同一时间只有一个请求在飞（照 `_hotwordsAsking`）。200 写文件并重编译；304 只更新并保存 `fetchedAt`；null 不动。接入点未设置时规则为空。`_learnItems` 成功的条目按 `FixRule(…, FixSource.learned)` 先 upsert（NFC+小写同 `observed` 盖旧条）进副本、重编译、保存，再走 `_forgetHotwords`。
- [ ] **Step 4:** 测试通过；全量 `flutter test` 通过；analyze 干净。
- [ ] **Step 5: Commit** `feat(gui): sync the device voice rules from the gateway; learned rules apply at once`。

### Task 3: Swift 缓存 + `timing` 事件（D14 第一步）

**Files:**
- Modify: `gui/macos/Runner/SpeechPlugin.swift`（`start` `:103`、`final` `:160`、`startAnalyzer` `:322`）
- Modify: `gui/lib/embed/voice_input.dart`（`handle` 认 `timing`）
- Test: `gui/test/embed/voice_input_test.dart`（加用例）

**Interfaces:**
- Produces:
  - 原生 → Dart 事件 `timing {first_partial_ms: int?, final_ms: int?}`：在 `final` 事件**之前**发；`first_partial_ms` = `start` 调用到第一个 `partial`，`final_ms` = `stop` 到 `final`；没有的为 null。
  - `class VoiceTiming { final int? firstPartialMs, finalMs; }`；`VoiceTiming? VoiceInput.lastTiming` —— 每次 `start` 清空；收到 `timing` 时设置（listening/finishing 时接受，idle 时丢弃）。
- [ ] **Step 1: Dart 测试** `timing arrives before final and is kept`：模拟 start ok → `timing {first_partial_ms: 420, final_ms: 310}` → `final` → `stop()` 返回后 `lastTiming.firstPartialMs == 420`；`a new start clears lastTiming`。
- [ ] **Step 2:** 跑 → FAIL。
- [ ] **Step 3: 实现 Dart**，再实现 Swift：`Run` 记 `startedAt`（取自 `start()` 入口）、`firstPartialAt`、`stoppedAt`；`final(run,text)` 里先 `invokeMethod("timing", …)` 再 `final`。两条路径（analyzer、旧 recognizer）都记。缓存（仅 analyzer 路径，`@available(iOS 26, macOS 26, *)`）：按 `Self.locale.identifier` 缓存 `supportedLocale` 结果、「资源已装」、`bestAvailableAudioFormat`；语言变了、或 `assetInstallationRequest` 抛错/返回需要安装时清掉缓存。缓存命中时跳过这三次 await。
- [ ] **Step 4:** `flutter test` 通过；编 macOS：`cd gui && flutter build macos --debug`；编 iOS：`flutter build ios --debug --no-codesign`（若需 rime 依赖见 memory，先 `gui/ios/.../fetch.sh`；编不过且与本改动无关时记下原因）。
- [ ] **Step 5: Commit** `feat(speech): cache locale/asset/format lookups; report first-partial and final timing`。

### Task 4: `VoiceHold` 过 `fix`，气泡所见即所发，计时日志（D5、D20）

**Files:**
- Modify: `gui/lib/embed/voice_button.dart`（`sendVoice` `:65–80`、`VoiceHold` `:108–`、`_release`、`_onWords`）
- Modify: `gui/lib/embed/voice_overlay.dart:279`、`gui/lib/embed/voice_desktop.dart:90,416`、`gui/lib/embed/composer_panel.dart:832`
- Modify: `gui/lib/embed/composer_model.dart:44`（`VoiceOrigin({this.ai, this.heard})`，`final VoiceHeard? heard`）
- Test: `gui/test/embed/voice_button_test.dart`、`gui/test/embed/voice_desktop_test.dart`

**Interfaces:**
- Consumes: `VoiceHeard`、`FixResult`（Task 1）；`MainState.voiceFix`、`voiceLog`（Task 2）；`VoiceInput.lastTiming`（Task 3）。
- Produces（`VoiceHold` 新签名）：
  - `FixResult Function(String text)? fix`；`void Function(String line)? log`
  - `String get fixedText` —— `fix(voice.text).text`（按输入字符串记忆上一次结果）；没有 `fix` 时就是 `voice.text`。
  - `send: void Function(String text, VoiceHeard heard)`；`edit: void Function(String text, VoiceHeard heard)`；`tidy: bool Function(String text, VoicePick pick, Rect? at, VoiceHeard heard)`；`wouldTidy`、`prefetch` 签名不变但拿改后的字。
  - `sendVoice(..., VoiceOrigin voice)` 留进草稿的 `keep()` 里：`voice.ai == null && voice.heard != null` 时 `c.pendingHeard = voice.heard`（字段由 Task 6 加；本任务先在 `ComposerModel` 上加 `VoiceHeard? pendingHeard;` 空字段，清除规则留给 Task 6）。
- [ ] **Step 1: 测试**：
  - `the bubble shows the fixed words while holding`（iOS overlay 和桌面各一）：`fix` 把「拍森」→「Python」，partial `打开拍森` 时气泡文字含 `Python`、不含 `拍森`。
  - `release sends the fixed text with what was heard`：`send` 收到 `打开Python` 和 `VoiceHeard(heard: '打开拍森', fixed: '打开Python')`。
  - `wouldTidy and tidy see the same fixed text`：10 字边界例子（原话 9 字，改后 12 字），`wouldTidy` 和 `tidy` 收到同一个字符串。
  - `edit and draft.keep get the fixed text`。
  - `one timing line per release, counts and ms only`：`log` 收到一行，匹配 `^voice: first (\d+|-)ms, final (\d+|-)ms, fix \d+ in [\d.]+ms, out \d+ms$`，且不含识别文字。
- [ ] **Step 2:** 跑 → FAIL。
- [ ] **Step 3: 实现。** `_release()`：`final heard = await voice.stop();` 计时 `fix`，得到 `r`；之后 `wouldTidy/prefetch/tidy/send/edit/draft.keep` 一律用 `r.text`，并传 `VoiceHeard(heard: heard, fixed: r.text)`。松手前用到 `voice.text` 的地方（prefetch、wouldTidy、`_onWords`）改用 `fixedText`。日志 `out` = 松手到交出（send/edit/tidy 调用）的毫秒。两处创建点接 `fix: (t) => widget.state.voiceFix(widget.session.sid, t)`、`log: widget.state.voiceLog`；`send` → `sendVoice(…, voice: VoiceOrigin(heard: heard))`；`edit` → `keep(text)` 后 `c.pendingHeard = heard`；`tidy` → `begin(text, pick, at: at, heard: heard.heard)`（`heard` 参数由 Task 5 加；本任务先给 `begin` 加上可选参数并存着不用）。
- [ ] **Step 4:** 全量 `flutter test` 通过（现有测试按新签名改调用，不改断言含义）；analyze 干净。
- [ ] **Step 5: Commit** `feat(gui): voice holds apply the device fix — bubble, send, edit and tidy see the fixed words`。

### Task 5: `VoiceTidy` 拆 `_heard` / `_original`，来源决定能不能学（D6、D9、D19 的整理那半）

**Files:**
- Modify: `gui/lib/embed/voice_tidy.dart`（`begin`、`_ended`、`_ai`、`flip` `:206`、`_goOriginal` `:550`、`sendNow` `:579` 等）
- Modify: `gui/lib/embed/voice_tidy_card.dart`（`_offerLine` 旁加提示行）
- Modify: `gui/lib/ui/main_state.dart` `_makeTidy` `:375`（传 `fromVocabulary`）
- Test: `gui/test/embed/voice_tidy_test.dart`、`gui/test/embed/voice_tidy_card_test.dart`

**Interfaces:**
- Consumes: `VoiceRules.fromVocabulary`（Task 1）、`VoiceHeard`、`VoiceOrigin.heard`（Task 4）。
- Produces:
  - `VoiceTidy.begin(String text, VoicePick pick, {Rect? at, String? heard})`；内部 `_heard = (heard ?? text).trim()`，`_original = text.trim()`。
  - `VoiceTidy({…, bool Function(String observed, String avoid)? fromVocabulary})`
  - `String? VoiceTidy.flipHint` —— 点回来自正式词表的虚线词时为 `这条在正式词表里，要改请去 note.md`，点回去或清掉 offer 时置空。卡片在 offer 行的位置画它，`Key('flip-hint')`，没有「记住」「忽略」。
- `_heard` 只用于：`tidyChanges(_heard, 结果)`、`VoiceAi.original`、气泡「原话」行、`learnExcerpt` 的 excerpt。其余（LLM 输入、`_takeAhead`、`_goOriginal`、`sendNow`、「还原」、`editNow`、`closed`/`end` 留草稿、`held`）用 `_original`。
- 不经 AI 发出 `_original` 的路径（`_goOriginal`、`sendNow`、「还原」）用 `VoiceOrigin(heard: VoiceHeard(heard: _heard, fixed: _original))`。
- [ ] **Step 1: 测试**：
  - `the heard words are the original line and the diff base`：`begin('打开Python跑一下这个测试脚本吧', send, heard: '打开拍森跑一下这个测试脚本吧')`，AI 回原样 → `changes` 有一处 `拍森→Python`，`VoiceAi.original` 是原话。
  - `tidy failure sends the fixed text`：AI 失败/超时 → `send` 收到改后的字，`VoiceOrigin.heard.heard` 是原话。
  - `sendNow and restore send the fixed text`。
  - `prefetch keyed by the fixed text hits`：先 `prefetch(改后)`，再 `begin(改后, heard: 原话)` → 不再发第二次请求。
  - `flipping a learned fix offers preserve`：`fromVocabulary` 回 false → offer 为 `preserve(observed: 拍森, avoid: Python)`。
  - `flipping a vocabulary fix only hints`：`fromVocabulary` 回 true → `offer == null`，`flipHint` 为固定文案；翻回去 `flipHint == null`；卡片测试里看到 `Key('flip-hint')`、看不到 `Key('learn-remember')`。
- [ ] **Step 2:** 跑 → FAIL。
- [ ] **Step 3: 实现**，`_makeTidy` 传 `fromVocabulary: voiceRules.fromVocabulary`（取调用时的当前规则）。
- [ ] **Step 4:** 全量测试 + analyze。
- [ ] **Step 5: Commit** `feat(gui): tidy diffs against the heard words but sends the fixed ones; vocabulary fixes point to note.md`。

### Task 6: 无 AI 的编辑路学习 + 改回原话出 preserve + 记录（D8、D19）

**Files:**
- Modify: `gui/lib/embed/tidy_diff.dart:246`（`editLearns`）
- Modify: `gui/lib/embed/composer_model.dart`（`pendingHeard` 清除/带走/发出，`onHeardSent`）
- Modify: `gui/lib/ui/main_state.dart`（`onAiSent` `:2061` 旁接 `onHeardSent`；两处都过滤 vocabulary 来源的 preserve）
- Modify: `gui/lib/history/input_recorder.dart:536`
- Test: `gui/test/embed/tidy_diff_test.dart`、`gui/test/embed/composer_model_test.dart`、`gui/test/history/input_recorder_test.dart`、`gui/test/ui/voice_tidy_wiring_test.dart`

**Interfaces:**
- Consumes: `VoiceHeard`、`ComposerModel.pendingHeard`、`VoiceOrigin.heard`（Task 4）；`VoiceRules.fromVocabulary`（Task 1）。
- Produces:
  - `editLearns(original, result, sent)`：某段在 original↔result 上恰好是一处改动（`overlapping.length == 1`）、且发出的字把它改回了 original 那一侧（`observed == output`）时，产出 `LearnItem.preserve(observed: observed, avoid: result 里那一处的字（trim）, excerpt: learnExcerpt(original, observed))`；`avoid` 为空或等于 `observed` 时跳过。其余不变（含 `_maxSide`、`_maxLearns`）。
  - `ComposerModel.pendingHeard`：清除时机同 `pendingAi`（草稿清空 `:132`、历史回看 `:633`、提交 `:699`）；设置 `pendingAi` 的地方（`:410`、`:423`、`voice_button.dart:76`）同时把 `pendingHeard` 清掉；`adoptFrom` 里 `pendingHeard ??= old.pendingHeard`（同 `pendingAi` 条件）。
  - `void Function(VoiceHeard heard, String sent)? ComposerModel.onHeardSent` —— `submit()` 里没有 `pendingAi`、有 `pendingHeard` 时：`Outgoing(…, voice: VoiceOrigin(heard: heard))`，在调 `onAiSent` 的同一位置调它。
  - main_state：`onHeardSent` → 密码框跳过；`editLearns(h.heard, h.fixed, sent)` → 去掉 `action == preserve && voiceRules.fromVocabulary(observed, avoid)` 的条目 → `tidyOf(sid).offerLearn(items)`。`onAiSent` 的结果也过同一过滤。
  - 记录：`o.voice?.ai == null && o.voice?.heard case final h? when h.heard != o.text` → `'fix': {'heard': h.heard}`。
- [ ] **Step 1: 测试**：
  - tidy_diff `reverting a fix teaches preserve`：`editLearns('打开拍森', '打开Python', '打开拍森')` → `[preserve(observed: 拍森, avoid: Python)]`。
  - tidy_diff `no fix, an edit teaches replace`：`editLearns('打开黑猫瑞', '打开黑猫瑞', '打开Hemory')` → `[replace(黑猫瑞 → Hemory)]`。
  - 现有 `editLearns` 测试全部不变地通过。
  - composer `pendingHeard is sent and cleared like pendingAi`：设 `pendingHeard`、`submit` → `onHeardSent` 收到 heard 和发出的字，之后为 null；草稿清空时被清掉；`adoptFrom` 带走。
  - wiring `editing without AI offers to remember`：关掉整理开关，`edit` 路发出改过的字 → `offerLearn` 收到 replace。
  - wiring `reverting a vocabulary fix offers nothing`：规则里 `徐逊→徐迅 vocabulary`，编辑路改回「徐逊」发出 → 没有 offer。
  - wiring `no learn offer under secure focus`。
  - recorder `fix.heard only without ai and when it differs`：三种情况（有 heard 且不同 → 有；相同 → 无；有 ai → 无）。
- [ ] **Step 2:** 跑 → FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** 全量测试 + analyze。
- [ ] **Step 5: Commit** `feat(gui): learn from edits without AI; reverting a fix teaches preserve; record what was heard`。

### Task 7: 收尾

**Files:**
- Modify: `tasks/todo.md`（实机验收：规格 §10 第 1–13、16 条，标注第 14、15 条属于探针/L2，未做）
- Modify: `docs/superpowers/specs/2026-11-24-rapp-voice-local-fix-design.md` 状态行：第 2–5 阶段（D14 第一步）已实现的提交号；D12/D13/D14 第二步等探针。
- [ ] **Step 1:** 全量 `flutter test`、`flutter analyze lib test`、macOS debug 构建、iOS 构建；`git checkout gui/pubspec.lock`。
- [ ] **Step 2: Commit** `docs: voice local fix — acceptance checks and status`。
