# 语音纠错学回词表 + 按用途整理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 气泡里标出并可切换 AI 改过的词；用户确认的改法写进网关的 `voice-learned.md` 马上生效、同时交给 note.md 做候选；整理分「提示词 / 对人」两种，按对方 app 自动选。

**Architecture:** 两条线并行。网关线（rapp-llm，Node，单文件 + 两个新模块）：`learned.mjs` 管文件格式和收编，`notemd.mjs` 管 propose，`rapp-llm.mjs` 加三个接口、把学到的词接进 attach 和 hotwords，再加 `dictation-chat` 小 API。rapp 线（Flutter）：纯函数 `tidy_diff.dart` 做比对，`VoiceTidy` 加切换 / 记住提示 / 用途，`VoiceTidyCard` 画虚线和提示，`LlmApi` 加三个调用，`MainState` 接线，设置页加两行。

**Tech Stack:** Node ≥20（`node:test`，无依赖）；Flutter/Dart（`flutter_test`、`fake_async`）。

**Spec:** `docs/superpowers/specs/2026-11-21-rapp-voice-learn-design.md`

## Global Constraints

- 网关 context 名只能是 `[a-z0-9_]+`：方案里的 `voice-learned` 一律写作 **`voice_learned`**（文件名仍是 `~/rapp/voice-learned.md`，提示词里的标签是 `<voice_learned>`）。
- rapp-llm 的改动只在 worktree `/Users/bruce/git/rapp-llm/.worktrees/voice-learn`（分支 `feat/voice-learn`）里做；**不要在 `/Users/bruce/git/rapp-llm` 主目录切分支或改 apps/**——正在跑的网关每次请求都重新读它。
- 不读、不打印 rapp-llm `config.json` 里的 `api_key`；key 不进任何公开仓库。
- rapp 的代码不提交到 main。分支 `feat/voice-diff`（Task 5–7）→ `feat/voice-learn`（Task 8–9，叠在前一个上）→ `feat/voice-mode`（Task 10，叠在前一个上），每个分支完成后把名字交给 rapp-49 合并。
- Flutter 在 `~/development/flutter/bin/flutter`（不在 PATH）；跑完测试 `git checkout gui/pubspec.lock`。
- 日志不记文字内容（网关每请求一行；rapp 的 `voice tidy:` 行只记事件和毫秒）。
- 密码框会话（`secureFocus`）不出任何「记住」提示，不发任何 learn 请求。
- 界面文字照抄：`记住：别把「X」改成「Y」？`、`记住这个改法？`、`忽略`、`记住`、`已记住`、`提示词`、`对人`、`语音学到的词`、`不改：X`、`恢复默认`、设置说明 `发给聊天软件的话按『对人』整理（保留口气，不分点），其余按『提示词』；在整理气泡上点用途可改`。
- 阈值：改动单侧 ≤ 12 个字；AI 一侧不足 2 个字向两边扩到 2 个字；可切换的改动超过 8 个或公共部分不到原话一半就一个都不标；编辑路提示最多 3 条、停 8 秒。

## Review Focus

1. **AI 整理结果里有 emoji 或其他 BMP 外字符**：比对和气泡里的虚线位置必须按 Unicode 字符（rune）算，不能错位一格。→ Task 5 `tidyChanges keeps rune offsets past an emoji`；网关 propose 的 span 按 code point 算 → Task 3 `proposal span counts code points`。
2. **气泡只显示最后 4 行（前面是「…」）**：被截掉的改动不能画到别的字上，点击也不能切错位置。→ Task 7 `a change cut off by the 4-line tail is not marked`。
3. **网关文件被并发写 / 手工改坏**：一行看不懂就跳过那行，不能让整个 `dictation` 500。→ Task 1 `parseLearned skips lines it cannot read`；Task 2 `a broken learned file still tidies`。
4. **切换用途或切换词之后马上点 编辑**：写作面板拿到的是切换后的文字，`VoiceAi.result` 仍是 AI 原样，这样编辑路的比对不会把用户切回的词当成新改法。→ Task 6 `edit after a flip puts the flipped text in the panel, ai.result unchanged`。
5. **记住提示出现时用户直接点 发送**：没回答的提示不能悄悄丢，也不能挡住发送。→ Task 6 `sending with an open bubble offer moves it to the 8 s box`。

---

## 探针结果（2026-11-21，已做，Task 0 写回方案）

在 vault 里手工跑 `notemd conversation-dictionary propose --input tmp/rapp-llm/probe.json`，两种都 `"status":"stored"`，`pending` 里能看到：

- 替换：`observed: 拍森`，`candidates[0].output: Python`，`kind: technical_term`。
- 「不改」：`observed: 黑猫瑞`，`output: 黑猫瑞`（和 observed 相同）也被接受。插件确认时，同词「替换」会被判为 no-op（`service.rs` 约 2093 行），所以 reviewer 要在 note.md 窗口里把它选成 preserve；`reason` 要写明「不要改」。
- 通过校验的写法：`context.communication = {kind: "voice_message", user_relation: "participant", basis: {type: "user_statement", detail: "…"}}`；`source = {content_kind: "asr_transcript", content_sha256: sha256(excerpt), span: observed 在 excerpt 里的 code point 区间, excerpt, excerpt_span: {start: 0, end: excerpt 的 code point 数}}`，不带 `resource`（内联来源要求 sha256 对上 excerpt）。
- `subject_id` 在 `notemd conversation-dictionary status` 最后一行 JSON 的 `subject_id`（现在是 `human:me`）。命令要在 vault 目录下跑（cwd = vault）。
- 第 4 步（在 note.md 里确认、看 `vocabulary.md` 生成 `do not change:`）没做：这需要用户在 note.md 窗口里操作，留到验收 5。两条探针候选还在 pending 里，请用户在 note.md 里拒掉。
- 正式词表的「不改」写法（`agent_context.rs:182`）：域下面一行 `- do not change: a, b`。

结论：G3 可以做，不用降级。

---

## 网关线（rapp-llm）

worktree：`git -C /Users/bruce/git/rapp-llm worktree add .worktrees/voice-learn -b feat/voice-learn`。测试：`cd /Users/bruce/git/rapp-llm/.worktrees/voice-learn && node --test "test/*.test.mjs"`。

### Task 0: 方案写回探针结果

**Files:**
- Modify: `docs/superpowers/specs/2026-11-21-rapp-voice-learn-design.md`（rapp 的 `docs/voice-learn-spec` worktree）

- [x] **Step 1:** §6.1 末尾加「探针结果」一段（照抄上面那段的要点）；全文 `voice-learned`（context 名）改为 `voice_learned`，文件名 `voice-learned.md` 不变；§6.2 配置改为 Task 2 的 `learn` 块。
- [x] **Step 2:** Commit `docs(spec): voice learn — probe results, voice_learned context name`。

### Task 1: `learned.mjs` — 文件格式、正式词表解析、收编

**Files:**
- Create: `learned.mjs`
- Test: `test/learned.test.mjs`

**Interfaces:**
- Produces:
  - `learnedId(observed: string) -> string`：`sha256(observed.normalize('NFC').toLowerCase())` 的前 12 个十六进制字符。
  - `parseLearned(text: string) -> Entry[]`，`Entry = {id, action: 'replace'|'preserve', observed, output: string|null}`。
  - `formatLearned(entries: Entry[]) -> string`：首行 `# 语音改正（用户在 rapp 里确认过，note.md 收编前先用这里）`，然后每条一行：`- X → Y (always)` / `- do not change: X`。含 `, ; → " ( ) :` 或首尾空白的词写成 JSON 字符串（`"…"`），和 `vocabulary.md` 一样。
  - `formalRules(vocabularyText: string) -> {replace: Map<string, string>, preserve: Set<string>}`：键是 `observed.toLowerCase()`。读 `- <kind>: a, b → A (always); C; "x、y" → B` 和 `- do not change: a, b` 两种行，跨所有 `##` 域；没有 `→` 的名字不算规则。分号、逗号的切分要认得 `"…"`。
  - `prune(entries, formal) -> {kept: Entry[], dropped: {entry: Entry, why: 'same'|'conflict'}[]}`：replace 条目在 `formal.replace` 里有同一个 observed（同 output → same，不同 → conflict）或在 `formal.preserve` 里（conflict）就删；preserve 条目在 `formal.preserve` 里（same）或 `formal.replace` 里（conflict）就删。
  - `upsert(entries, entry) -> Entry[]`：同一个 observed（不分大小写）的旧条目去掉，新条目放最后。

- [ ] **Step 1: 写失败的测试**

```js
test('learned: format then parse gives the same entries', () => {
  const e = [
    { id: learnedId('拍森'), action: 'replace', observed: '拍森', output: 'Python' },
    { id: learnedId('黑猫瑞'), action: 'preserve', observed: '黑猫瑞', output: null },
    { id: learnedId('a, b'), action: 'replace', observed: 'a, b', output: 'A→B' },
  ];
  const text = formatLearned(e);
  assert.match(text, /^# 语音改正/);
  assert.match(text, /^- 拍森 → Python \(always\)$/m);
  assert.match(text, /^- do not change: 黑猫瑞$/m);
  assert.match(text, /^- "a, b" → "A→B" \(always\)$/m);
  assert.deepEqual(parseLearned(text), e);
});

test('parseLearned skips lines it cannot read', () => {
  assert.deepEqual(parseLearned('- 拍森 → Python (always)\n- 半行 →\n乱写\n- do not change:\n').map((x) => x.observed), ['拍森']);
});

test('formalRules reads every domain, quoted names and do-not-change lines', () => {
  const f = formalRules(VOCAB + '## public\n- do not change: Lovable, "a, b"\n'); // VOCAB as in hotwords.test.mjs
  assert.equal(f.replace.get('冯斌'), 'Kid');
  assert.equal(f.replace.get('校长、二宇、yuyu'), '禹宇');
  assert.equal(f.replace.get('himmary'), 'Hemory');
  assert.equal(f.replace.has('lingbo'), false);
  assert.ok(f.preserve.has('lovable') && f.preserve.has('a, b'));
});

test('prune: the formal vocabulary wins, same or not', () => {
  const f = formalRules('- person: 冯斌 → Kid\n- do not change: 易凯\n');
  const r = prune([
    { id: '1', action: 'replace', observed: '冯斌', output: 'Kid' },
    { id: '2', action: 'replace', observed: '冯斌', output: 'Kidd' },
    { id: '3', action: 'replace', observed: '易凯', output: '亿凯' },
    { id: '4', action: 'preserve', observed: '易凯', output: null },
    { id: '5', action: 'replace', observed: '拍森', output: 'Python' },
  ], f);
  assert.deepEqual(r.kept.map((e) => e.id), ['5']);
  assert.deepEqual(r.dropped.map((d) => [d.entry.id, d.why]), [['1', 'same'], ['2', 'conflict'], ['3', 'conflict'], ['4', 'same']]);
});

test('upsert: one rule per observed, ignoring case; the new one last', () => {
  const a = { id: learnedId('Pyson'), action: 'replace', observed: 'Pyson', output: 'Python' };
  const b = { id: learnedId('pyson'), action: 'preserve', observed: 'pyson', output: null };
  const c = { id: learnedId('x'), action: 'replace', observed: 'x', output: 'y' };
  assert.deepEqual(upsert([a, c], b), [c, b]);
  assert.equal(learnedId('Pyson'), learnedId('pyson'));
});
```

- [ ] **Step 2:** `node --test test/learned.test.mjs` → FAIL（模块不存在）。
- [ ] **Step 3:** 实现 `learned.mjs` 的六个导出（只用 `node:crypto`）。
- [ ] **Step 4:** `node --test test/learned.test.mjs` → PASS。
- [ ] **Step 5:** Commit `feat: learned.mjs — voice-learned file format and pruning against the vocabulary`。

### Task 2: 配置 `learn`、三个接口、attach 与 hotwords

**Files:**
- Modify: `rapp-llm.mjs`（`loadConfig` 36–86 行、`route` 106 行起、`hotwords` 148 行、`attach` 206 行）
- Modify: `README.md`（配置和接口各加一段）
- Test: `test/learn.test.mjs`（新）、`test/hotwords.test.mjs`、`test/config.test.mjs`

**Interfaces:**
- Consumes: Task 1 的全部导出；Task 3 的 `propose`（本任务先留一个调用点：`config.learn.notemd` 为 null 时不调）。
- Produces:
  - 配置：

    ```json
    "contexts": { "voice_learned": { "file": "~/rapp/voice-learned.md" } },
    "learn": { "context": "voice_learned", "vocabulary": "vocabulary",
               "notemd": { "bin": "/usr/local/bin/notemd", "vault": "~/git/sotvault", "domain": "public" } }
    ```

    `loadConfig` 校验：`learn.context`、`learn.vocabulary` 必须是 contexts 里的名字（错了报 `配置有误：learn 的 …`）；`notemd` 可省，写了就要 `bin`、`vault` 是非空字符串，`domain` 默认 `public`，`vault` 支持 `~/`。结果 `config.learn = {file, vocabularyFile, notemd: {bin, vault, domain} | null} | null`。
  - `readLearned(config) -> Entry[]`：读文件（不存在 = 空），按当时的 `vocabularyFile` `prune`；有 dropped 就用 `writeText` 写回，并 `console.error` 一行 `rapp-llm: learned <id> folded (<why>)`（不写词）。
  - `POST /v1/vocabulary/learn`，body `{action, observed, output?, avoid?, excerpt}`：
    - 400 `invalid_learn` 当：action 不是 replace/preserve；observed 去首尾空白后为空或超过 128 个字；replace 没有 output 或 output 等于 observed；excerpt 不是字符串、超过 2000 个字或不含 observed。
    - 通过就 `upsert` 写文件，`notemd` 配了就 `propose(...)` 不等它，返回 `200 {id, object: 'learned'}`。
  - `GET /v1/vocabulary/learned` → `{object: 'list', data: [{id, object: 'learned', action, observed, output}]}`（`readLearned` 之后的）。
  - `DELETE /v1/vocabulary/learned/<id>` → `200 {id, object: 'learned', deleted: true}`；没有这个 id → 404 `learned_not_found`。
  - `learn` 没配时三个接口都 404 `learn_not_configured`。
  - 三个接口 `x.logged = true`，record 只有 path 和 status。
  - `attach`：名字等于 `learn.context` 时，块内容用 `formatLearned(readLearned(config))`（空表时整块省略，和空文件一样）。
  - `hotwords`：`readLearned` 里 replace 条目的 output 排在最前，然后照旧；去重、`max` 不变。

- [ ] **Step 1: 写失败的测试**（`test/learn.test.mjs`，用 `workdir` + `gateway` + `call`）

```js
const CFG = { contexts: { vocabulary: { file: 'vocabulary.md' }, voice_learned: { file: 'learned.md' } },
              learn: { context: 'voice_learned', vocabulary: 'vocabulary' } };

test('learn: replace and preserve are written, listed and deleted', async (t) => {
  const dir = workdir(t, { 'vocabulary.md': '## public\n- person: 冯斌 → Kid\n' });
  const url = await gateway(t, CFG, { dir });
  const a = await call(url, '/v1/vocabulary/learn', { json: { action: 'replace', observed: ' 拍森 ', output: 'Python', excerpt: '明天用拍森跑' } });
  assert.equal(a.status, 200);
  const { id } = await a.json();
  await call(url, '/v1/vocabulary/learn', { json: { action: 'preserve', observed: '黑猫瑞', avoid: 'Hemory', excerpt: '跑一下黑猫瑞' } });
  assert.equal(fs.readFileSync(`${dir}/learned.md`, 'utf8').split('\n').slice(1, 3).join('\n'), '- 拍森 → Python (always)\n- do not change: 黑猫瑞');
  const list = await (await call(url, '/v1/vocabulary/learned', { method: 'GET' })).json();
  assert.deepEqual(list.data.map((e) => [e.action, e.observed, e.output]), [['replace', '拍森', 'Python'], ['preserve', '黑猫瑞', null]]);
  assert.equal((await call(url, `/v1/vocabulary/learned/${id}`, { method: 'DELETE' })).status, 200);
  assert.equal((await call(url, `/v1/vocabulary/learned/${id}`, { method: 'DELETE' })).status, 404);
});

test('learn: bad requests are 400', async (t) => {
  const url = await gateway(t, CFG, { dir: workdir(t) });
  for (const body of [
    { action: 'swap', observed: 'a', output: 'b', excerpt: 'a' },
    { action: 'replace', observed: ' ', output: 'b', excerpt: 'a' },
    { action: 'replace', observed: 'Python', output: 'Python', excerpt: 'Python' },
    { action: 'replace', observed: '拍森', output: 'Python', excerpt: '没有这个词' },
  ]) assert.equal((await call(url, '/v1/vocabulary/learn', { json: body })).status, 400);
});

test('learn: an entry the formal vocabulary now has is folded away on the next read', async (t) => {
  const dir = workdir(t, { 'vocabulary.md': '' });
  const url = await gateway(t, CFG, { dir });
  await call(url, '/v1/vocabulary/learn', { json: { action: 'replace', observed: '冯斌', output: 'Kidd', excerpt: '冯斌说' } });
  fs.writeFileSync(`${dir}/vocabulary.md`, '## team\n- person: 冯斌 → Kid\n');
  const list = await (await call(url, '/v1/vocabulary/learned', { method: 'GET' })).json();
  assert.deepEqual(list.data, []);
  assert.doesNotMatch(fs.readFileSync(`${dir}/learned.md`, 'utf8'), /冯斌/);
});

test('learn: not configured is 404', async (t) => {
  const url = await gateway(t, {});
  assert.equal((await call(url, '/v1/vocabulary/learned', { method: 'GET' })).status, 404);
});

test('a broken learned file still tidies', async (t) => { /* learned.md = '乱写\n- 拍森 → Python (always)\n'；
  dictation app 带 context: vocabulary, voice_learned；fake upstream 收到的 system 里有
  '<voice_learned>' 和 '- 拍森 → Python (always)'，没有 '乱写'；status 200 */ });
```

  `test/hotwords.test.mjs` 加：`learned replace outputs come first`——learned.md 里 `拍森 → Python`、`do not change: 易凯`，vocabulary 用现有 `VOCAB`：结果以 `'Python'` 开头，其余顺序和现有第一个测试相同。
  `test/config.test.mjs` 加：`learn.context` 不是 context 名、`notemd.bin` 为空都抛 `/learn/`。

- [ ] **Step 2:** `node --test "test/*.test.mjs"` → 新测试 FAIL。
- [ ] **Step 3:** 按 Interfaces 实现。路由放在 `/v1/hotwords` 那行后面，用 `/^\/v1\/vocabulary\/(learn|learned)(?:\/([^/]+))?$/`。
- [ ] **Step 4:** `node --test "test/*.test.mjs"` → 全部 PASS。
- [ ] **Step 5:** Commit `feat: /v1/vocabulary/learn — voice corrections the user confirmed, used at once, folded once the vocabulary has them`。

### Task 3: `notemd.mjs` — 把学到的词交给 note.md

**Files:**
- Create: `notemd.mjs`
- Modify: `rapp-llm.mjs`（Task 2 留的调用点）
- Test: `test/notemd.test.mjs`

**Interfaces:**
- Produces:
  - `proposal({subject, domain, action, observed, output, avoid, excerpt}) -> object`：纯函数，字段照「探针结果」：`schema: 'notemd.conversation-dictionary-proposal.v1'`，`proposed_by: 'rapp-llm'`，`confidence: 1`，`kind`：observed 和 output 都只含 `[A-Za-z0-9 .+#-]` → `'product'`，否则 `'other'`。`reason`：replace → `用户在 rapp 里把语音整理的结果改成了这个写法`；preserve → `不要改（preserve）：用户在 rapp 里把 AI 写的「${avoid}」切回了原话`。preserve 的 `output` 等于 observed。`basis.detail`：`用户本人口述，在 rapp 里点了「记住」`。
  - `propose(notemd: {bin, vault, domain}, request) -> Promise<void>`：`execFile(bin, ['conversation-dictionary', 'status'], {cwd: vault, timeout: 30000})` 取最后一行 JSON 的 `subject_id`；写 `<vault>/tmp/rapp-llm/<randomUUID()>.json`；`execFile(bin, ['conversation-dictionary', 'propose', '--input', 'tmp/rapp-llm/<uuid>.json'], {cwd: vault, timeout: 30000})`；`finally` 删掉文件。任何失败 `console.error('rapp-llm: notemd propose failed: <exit code 或 error.code>')`，不抛。

- [ ] **Step 1: 写失败的测试**

```js
test('proposal span counts code points', () => {
  const p = proposal({ subject: 'human:me', domain: 'public', action: 'replace', observed: '拍森', output: 'Python', excerpt: '😀用拍森跑' });
  assert.deepEqual(p.source.span, { start: 2, end: 4 });
  assert.deepEqual(p.source.excerpt_span, { start: 0, end: 6 });
  assert.equal(p.source.content_sha256, createHash('sha256').update('😀用拍森跑').digest('hex'));
  assert.equal(p.candidates[0].kind, 'other');
  assert.equal(p.context.communication.basis.type, 'user_statement');
});

test('proposal for preserve keeps the word and says so', () => {
  const p = proposal({ subject: 's', domain: 'public', action: 'preserve', observed: 'Hemory', avoid: 'Memory', excerpt: 'Hemory 上线' });
  assert.equal(p.candidates[0].output, 'Hemory');
  assert.equal(p.candidates[0].kind, 'product');
  assert.match(p.candidates[0].reason, /不要改（preserve）.*Memory/);
});

test('propose runs status then propose in the vault and removes its file', async (t) => {
  // workdir 里放一个可执行的假 notemd（#!/usr/bin/env node 脚本）：status 打一行 '[plugin_runtime] x' 再打
  // '{"subject_id":"human:me"}'；propose 把 --input 指向的文件内容追加到 calls.jsonl。
  // 断言：calls.jsonl 里一份 proposal，subject_id 'human:me'；<vault>/tmp/rapp-llm/ 下没有残留 .json。
});

test('propose failing is logged, not thrown', async (t) => { /* bin 指向不存在的路径：resolve，不 reject */ });
```

  `test/learn.test.mjs` 加：配了 `notemd`（指向上面的假脚本）时，learn 返回 200 后不久 `calls.jsonl` 出现一份 proposal（用轮询等，最多 2 秒）。

- [ ] **Step 2:** `node --test test/notemd.test.mjs` → FAIL。
- [ ] **Step 3:** 实现 `notemd.mjs`（`node:child_process` 的 `execFile` promisify、`node:crypto`），接上 Task 2 的调用点。
- [ ] **Step 4:** `node --test "test/*.test.mjs"` → 全部 PASS。
- [ ] **Step 5:** Commit `feat: learned words go to note.md as conversation-dictionary candidates`。

### Task 4: `dictation` 接上学到的词，新的 `dictation-chat`

**Files:**
- Modify: `apps/dictation.md`
- Create: `apps/dictation-chat.md`
- Modify: `test/shipped.test.mjs`（它解析 apps/ 的配置要加上 `voice_learned` context）
- Modify: `config.example.json`（如果有；没有就在 README 的配置示例里加）

- [ ] **Step 1:** `dictation.md`：`context: vocabulary, voice_learned, user, memory`；第 1 条开头改为「先按 <vocabulary> 和 <voice_learned> 改。<voice_learned> 是用户刚在 rapp 里确认过的改法，和 <vocabulary> 写法一样；两者冲突时按 <vocabulary>。」其余不动。
- [ ] **Step 2:** 新建 `dictation-chat.md`：设置块同 `dictation`（`model: text-lite`、`timeout_s: 30`、`param.temperature: 0`、两行 `think.*`），`description: 口述整理（对人）：只改错字和专有名词，保留口气，返回纯文字`。规则按方案 §6.4：保留 `dictation` 第 1–3 条和第 5 条；第 4 条改为只删填充词（嗯、啊、呃、那个、就是、然后）和重复，改口以最后为准，保留「哈、吧、呀、啦」这类带情绪的语气词和原来的语序、口气，不精炼、不改写成书面语；格式改为不分点、不编号，一律一段，长了按意思分段。
- [ ] **Step 3:** `node --test "test/*.test.mjs"` → PASS。
- [ ] **Step 4:** 用 5 段微信口吻的真实口述对比两个小 API（`POST /v1/apps/dictation-chat?debug=1`，body 里带 `draft` 为新文件内容，对着**正在跑的**网关试，不用部署），把输入输出贴给用户看，按用户意见改措辞再定稿。
- [ ] **Step 5:** Commit `apps: dictation reads voice_learned; dictation-chat keeps the speaker's tone`。

### Task 4b: 上线（等用户点头）

- [ ] **Step 1:** 停下，向用户确认：要改正在运行的网关的 `config.json` 并重启。
- [ ] **Step 2:** 用户同意后，只用 `jq` 或脚本加两处（`contexts.voice_learned`、`learn`，`notemd` 照上面的值），不打印文件；`touch ~/rapp/voice-learned.md`；查网关怎么跑的（`launchctl list | /usr/bin/grep -i rapp-llm` 或进程）并重启；`curl -s localhost:8101/healthz`。
- [ ] **Step 3:** 在 `/Users/bruce/git/rapp-llm` 主目录 `git merge --ff-only feat/voice-learn`（这一步就是把新 apps 放上线）。
- [ ] **Step 4:** 冒烟：learn 一条 `测试词 → 测试`（excerpt `说一个测试词`）→ `GET learned` 里有 → `GET /v1/hotwords` 第一个是 `测试` → `DELETE`；`pending` 里那条测试候选告诉用户去拒掉。用一段口述打 `dictation` 和 `dictation-chat` 各一次，200。

---

## rapp 线（Flutter）

worktree：`git -C /Users/bruce/git/rapp worktree add .worktrees/voice-diff -b feat/voice-diff docs/voice-learn-spec`（带上方案和计划）。测试命令：`cd gui && ~/development/flutter/bin/flutter test <文件>`，每个任务结束跑 `flutter test test/embed test/ui` 和 `flutter analyze`，然后 `git checkout gui/pubspec.lock`。

### Task 5: `tidy_diff.dart` — 比对与三方映射

**Files:**
- Create: `gui/lib/embed/tidy_diff.dart`
- Test: `gui/test/embed/tidy_diff_test.dart`

**Interfaces:**
- Produces:

  ```dart
  class TidyChange { // a span of the AI's text that can flip back to what was heard
    const TidyChange({required this.start, required this.end, required this.before, required this.after});
    final int start, end; // rune offsets in the AI's text
    final String before, after; // the heard words, the AI's words (after == result runes [start, end))
  }
  enum LearnAction { replace, preserve }
  class LearnItem {
    const LearnItem.replace({required this.observed, required String this.output, required this.excerpt}) : action = LearnAction.replace, avoid = null;
    const LearnItem.preserve({required this.observed, required String this.avoid, required this.excerpt}) : action = LearnAction.preserve, output = null;
    final LearnAction action; final String observed; final String? output, avoid; final String excerpt;
    Map<String, Object> toJson(); // {'action': 'replace'|'preserve', 'observed', 'output'|'avoid', 'excerpt'}
    String get label; // replace: '拍森 → Python'；preserve: '不改：黑猫瑞'
    // == / hashCode over all five fields (tests compare items)
  }
  List<TidyChange> tidyChanges(String original, String result);
  List<LearnItem> editLearns(String original, String result, String sent); // at most 3
  ```

- [ ] **Step 1: 写失败的测试**（表驱动）

```dart
final cases = <(String, String, String, List<(String before, String after)>)>[
  ('homophone grows to 2 chars, to the left first', '我门明天开会', '我们明天开会', [('我门', '我们')]),
  ('names', '明天用拍森跑一下黑猫瑞', '明天用Python跑一下Hemory', [('拍森', 'Python'), ('黑猫瑞', 'Hemory')]),
  ('filler deleted is no change', '嗯那个我们明天开会', '我们明天开会', []),
  ('punctuation only', '明天开会', '明天开会。', []),
  ('case and space only', '用git hub', '用GitHub', []),
  ('numbered lines', '第一买菜第二做饭', '1. 买菜\n2. 做饭', []),
  ('rewritten', '我觉得吧这个事情其实还是要再想一想比较好', '这件事需要再考虑。', []),
  ('more than 8', '一甲二乙三丙四丁五戊六己七庚八辛九壬', '一a二b三c四d五e六f七g八h九i', []),
  ('a side over 12 chars', '明天把它拿来', '明天把那个特别特别特别长名字的东西拿来', []),
];
for (final (name, o, r, want) in cases) {
  test(name, () => expect(tidyChanges(o, r).map((c) => (c.before, c.after)).toList(), want));
}

test('tidyChanges keeps rune offsets past an emoji', () {
  final c = tidyChanges('😀用拍森跑', '😀用Python跑').single;
  expect((c.start, c.end), (2, 8));
});

test('editLearns: a word the AI left, the user fixed, maps to the heard words', () {
  expect(editLearns('明天跑一下黑猫瑞', '明天跑一下黑猫瑞。', '明天跑一下Hemory。'),
      [const LearnItem.replace(observed: '黑猫瑞', output: 'Hemory', excerpt: '明天跑一下黑猫瑞')]);
});
test('editLearns: a fix on the AI\'s own change learns from the heard words', () {
  expect(editLearns('明天用拍森跑', '明天用Pyson跑', '明天用Python跑'),
      [const LearnItem.replace(observed: '拍森', output: 'Python', excerpt: '明天用拍森跑')]);
});
test('editLearns: a fix on words the AI added is dropped', () => expect(editLearns('明天开会', '明天下午开会', '明天晚上开会'), isEmpty));
test('editLearns: flipping the AI back to the heard words learns nothing', () => expect(editLearns('用拍森跑', '用Python跑', '用拍森跑'), isEmpty));
test('editLearns: at most 3', () => expect(editLearns('甲甲和你说乙乙和你说丙丙和你说丁丁和你说', '甲甲和你说乙乙和你说丙丙和你说丁丁和你说', 'AA和你说BB和你说CC和你说DD和你说').map((i) => i.observed), ['甲甲', '乙乙', '丙丙']));
```

- [ ] **Step 2:** `flutter test test/embed/tidy_diff_test.dart` → FAIL（文件不存在）。
- [ ] **Step 3:** 实现。算法（测试定不死的部分）：

  ```
  tidyChanges(o, r):
    a = o.runes, b = r.runes; if a.length * b.length > 4e6: return []
    LCS 表 → 编辑脚本；两段相等之间的所有删、增合成一个 hunk：before = a[i0,i1), after = b[j0,j1)
    lcs < a.length / 2 → return []
    对每个 hunk：
      norm(s) = s 去空白、去 \p{P}\p{S}、去 ^\d+[.、] 编号、转小写
      norm(before) == norm(after) → 丢（规则 2）
      norm(before) 或 norm(after) 为空 → 丢（规则 3；编号「1.」也算空，所以「第一」→「1. 」被丢）
      两侧都去掉首尾空白和标点（after 收缩时 [j0,j1) 跟着收），任一侧 > 12 字 → 丢（规则 4）
      after 不足 2 字：先向左、再向右并入相邻的相等字（不并空白和标点），before 同时并入同样的字（规则 5）
    扩展后重叠的相邻改动合并；结果 > 8 个 → return []（规则 6）

  editLearns(o, r, s):
    A = o↔r 的 rune 对齐（r 的每个相等字 → o 的下标）和 o↔r 的原始 hunk 列表（不过滤）
    对 tidyChanges(r, s) 的每个改动 c（r 一侧区间 [c.start, c.end)，用户写的是 c.after）：
      与 c 重叠的 A 的 hunk：0 个 → o 区间 = c 覆盖的相等字映射回去；1 个 h 且 h.before 非空 →
        把 c 在 r 上扩到盖住整个 h.after，o 区间 = h.before 的区间并上 c 其余相等字的映射；
        output = s 里对应扩展后 r 区间的文字；≥2 个，或 h.before 为空 → 丢
      o 区间必须连续；observed = o 区间文字去首尾空白；observed == output、为空、> 12 字 → 丢
    取前 3 个，excerpt = o
  ```

- [ ] **Step 4:** `flutter test test/embed/tidy_diff_test.dart` → PASS。
- [ ] **Step 5:** Commit `feat(voice): tidy_diff — which words the AI changed, and what an edit after it teaches`。

### Task 6: `VoiceTidy` — 切换词、停住、记住提示

**Files:**
- Modify: `gui/lib/embed/voice_tidy.dart`
- Test: `gui/test/embed/voice_tidy_test.dart`

**Interfaces:**
- Consumes: Task 5 `TidyChange`、`LearnItem`、`tidyChanges`。
- Produces（`VoiceTidy` 上）：
  - 构造参数 `void Function(Object sid, List<LearnItem> items)? learn`；为 null 时不产生任何提示。
  - `List<TidyChange> get changes`：`LlmDone` 时 `pick == VoicePick.send` 才算 `tidyChanges(_original, t)`，其他时候空；离开 ready 就清空。
  - `bool flipped(int i)`；`void flip(int i)`：只在 `phase == ready && !writing` 时有效；一点就停住（取消 settle、不再自动发，新字段 `bool get stopped`，和 `comparing` 一样让 `_caughtUp` 不起倒计时）。
  - `String get text`：`_result` 里被 flip 的改动换成 `before`。`_sendResult` 发 `text`；`editNow` 放 `text`；两者的 `VoiceAi.result` 仍是 AI 原样。
  - `LearnOffer? get offer`；`class LearnOffer { final List<LearnItem> items; final bool inBubble; final Set<int> picked; bool done; }`（放在 voice_tidy.dart）。
    - flip 成原话、`learn != null`：`offer = LearnOffer(items: [LearnItem.preserve(observed: c.before, avoid: c.after, excerpt: original)], inBubble: true)`，替换之前的气泡提示；把这一处 flip 回 AI：它的提示去掉。
    - `void offerLearn(List<LearnItem> items)`：`learn != null` 且 items 非空时 `offer = LearnOffer(items: items.take(3), inBubble: false, picked: 全部)`，8 秒（构造参数 `Duration offerLife = const Duration(seconds: 8)`）后清掉。`begin`、打字都不清它。
    - `void togglePick(int i)`；`void remember()`：`learn(sid, 选中的 items)`，`done = true`，1.5 秒后清掉；`void dismissOffer()`。
    - 气泡离开 ready 时（发送、还原、编辑、关闭）：没回答的气泡提示转成 `inBubble: false` 的 8 秒提示（不挡发送，也不悄悄丢）；`closed()`/`dispose()` 直接清。
- [ ] **Step 1: 写失败的测试**（沿用 `make()`，加 `learned` 列表接 `learn`；结果用 `'明天用Python跑一下Hemory'`，原话 `'明天用拍森跑一下黑猫瑞'`）

```dart
test('a done send lists the AI\'s changes', ...);          // changes.map(before) == ['拍森', '黑猫瑞']
test('flip holds the send and sends the flipped text', ...); // flip(1)；elapse 5 s：sent 为空、stopped；sendNow → sent.single.$2 == '明天用Python跑一下黑猫瑞'，$3.ai!.result == AI 原样
test('edit after a flip puts the flipped text in the panel, ai.result unchanged', ...);
test('flip before the words are out does nothing', ...);
test('flipping back to the heard words offers preserve; flipping again takes it away', ...); // offer.items.single == LearnItem.preserve(observed: '黑猫瑞', avoid: 'Hemory', excerpt: 原话)
test('remember sends the picked items once and shows done', ...);
test('no learn callback, no offer', ...);
test('sending with an open bubble offer moves it to the 8 s box', ...); // sendNow 后 offer.inBubble == false；elapse 8 s → offer == null，learned 为空
test('offerLearn: at most 3, all picked, gone after 8 s; a new begin keeps it', ...);
test('an edit pick computes no changes', ...);
```

- [ ] **Step 2:** `flutter test test/embed/voice_tidy_test.dart` → 新测试 FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** `flutter test test/embed/voice_tidy_test.dart` → PASS（旧测试也全过）。
- [ ] **Step 5:** Commit `feat(voice): flip an AI change back in the tidy bubble; offers to remember`。

### Task 7: `VoiceTidyCard` — 虚线、点击、提示

**Files:**
- Modify: `gui/lib/embed/voice_tidy_card.dart`
- Test: `gui/test/embed/voice_tidy_card_test.dart`

**Interfaces:**
- Consumes: Task 6 的 `changes`、`flipped`、`flip`、`text`、`stopped`、`offer`、`togglePick`、`remember`、`dismissOffer`。
- Produces（Key）：`tidy-body` 不变；`learn-offer`（提示框或气泡里那行）、`learn-item-<i>`（勾选框，仅独立框）、`learn-ignore`、`learn-remember`、`learn-done`。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('changes are underlined dashed once the words are out', ...); // tidy-body 的 TextSpan 里 'Python'、'Hemory' 两段 decorationStyle == TextDecorationStyle.dashed
testWidgets('tapping a marked word flips it and the drain goes', ...);   // tester.tapOnText(find.textRange.ofSubstring('Hemory'))；body 文字含 '黑猫瑞'；找不到 _Drain
testWidgets('the bubble offer reads 记住：别把「黑猫瑞」改成「Hemory」？ and 记住 shows 已记住', ...);
testWidgets('the 8 s box lists items with checkboxes and stands without a tidy', ...); // phase idle 时 offerLearn 两条：find.text('拍森 → Python')、learn-item-0/1 都已勾
testWidgets('a change cut off by the 4-line tail is not marked', ...);    // 结果超过 4 行、第一处改动在被截掉的头部：body 里只有一段 dashed
testWidgets('on iOS a tap 15 px above a marked word still flips it', ...); // debugDefaultTargetPlatformOverride = iOS
testWidgets('with reduced motion the offer appears without animation', ...);
```

- [ ] **Step 2:** `flutter test test/embed/voice_tidy_card_test.dart` → 新测试 FAIL。
- [ ] **Step 3:** 实现。`_body` 改成接收分段（普通段 / 改动段 i），在算出 `from`（4 行截尾）之后按 rune 偏移切；改动段 `TextDecoration.underline` + `TextDecorationStyle.dashed`。点击不用 `TapGestureRecognizer`：整块 body 一个 `GestureDetector`，用 `TextPainter` 取每个可见改动段的 boxes，横向各外扩 6 px、纵向外扩到至少 44 px 高（iOS；其他平台 24 px），取包含点击点且中心最近的一个调 `flip`。`ready && !tidy.writing && !(comparing || stopped)` 才显示倒计时。独立提示框在 `TidyPhase.idle`/`note` 时也要画（`AnimatedSwitcher` 的 idle 分支改为有 offer 时画提示框）；有卡片时提示框画在卡片上方。
- [ ] **Step 4:** `flutter test test/embed` → PASS；`flutter analyze` 无新告警。
- [ ] **Step 5:** Commit `feat(voice): dashed marks on the AI's changes, tap to flip, remember prompt`。
- [ ] **Step 6:** 分支 `feat/voice-diff` 推到 origin，名字交给 rapp-49（这时 `learn` 还没接线，提示不会出现；切换词已可用）。

### Task 8: `LlmApi` 三个调用 + `MainState` 接线（编辑路、记住、热词）

worktree：`git -C /Users/bruce/git/rapp worktree add .worktrees/voice-learn -b feat/voice-learn feat/voice-diff`。

**Files:**
- Modify: `gui/lib/llm_api.dart`
- Modify: `gui/lib/embed/composer_model.dart`（`submit()` 约 610–650 行）
- Modify: `gui/lib/ui/main_state.dart`（`_makeTidy` 365 行、会话创建 1993–2025 行、热词 3298 行起）
- Test: `gui/test/llm_api_test.dart`、`gui/test/embed/composer_model_test.dart`、`gui/test/embed/voice_wiring_test.dart`

**Interfaces:**
- Consumes: Task 5 `LearnItem`、`editLearns`；Task 6 `learn`、`offerLearn`。
- Produces:
  - `LlmApi.learn(LlmEndpoint e, LearnItem item) -> Future<bool>`（`POST /v1/vocabulary/learn`，200 → true，其余和异常 → false）。
  - `LlmApi.learned(LlmEndpoint e) -> Future<List<LearnedEntry>?>`（null：没配、不通、非 200）；`class LearnedEntry { final String id; final LearnAction action; final String observed; final String? output; String get label; }`（放 llm_api.dart，`label` 同 `LearnItem.label`）。
  - `LlmApi.forget(LlmEndpoint e, String id) -> Future<bool>`（`DELETE /v1/vocabulary/learned/<id>`）。超时都用 `probeTimeout`，从不抛。
  - `ComposerModel.onAiSent`：`void Function(VoiceAi ai, String text)?`，`submit()` 发出带 `pendingAi` 的那条时调一次（`o.text`），空发送不调。
  - `MainState`：`_makeTidy` 传 `learn: (s, items)`——`remote[s]?.secureFocus ?? true` 时什么都不做；否则每条 `llmApi.learn(llm, item)`，任一成功就 `_forgetHotwords()`，失败 `_log('rapp: voice learn failed')`。会话创建处 `rs.composer.onAiSent = (ai, text) { if (rs.secureFocus) return; final items = editLearns(ai.original, ai.result, text); if (items.isNotEmpty) tidyOf(rs.sid).offerLearn(items); }`。`Future<List<LearnedEntry>?> voiceLearned()`、`Future<void> forgetLearned(String id)`（成功后 `_forgetHotwords()`）。

- [ ] **Step 1: 写失败的测试**
  - `llm_api_test.dart`（照文件里已有的本地 `HttpServer` 写法）：`learn posts the item as JSON with the key`（收到的 body == `item.toJson()`，`Authorization: Bearer k`）；`learn is false on 500 and on no server`；`learned parses the list`；`learned is null on 404`；`forget sends DELETE to the id`。
  - `composer_model_test.dart`：`a panel send with pendingAi tells onAiSent the sent text`；`a send without pendingAi does not`。
  - `voice_wiring_test.dart`：`an edited AI text offers what it teaches`（假 `LlmApi`，tidy 走编辑路，面板里改字后 submit → `tidyOf(sid).offer!.items.single.label == '黑猫瑞 → Hemory'`）；`remember posts and forgets the hotwords`（之后 `voiceHotwords()` 触发一次新的 `hotwords` 调用）；`a password field gets no offer and posts nothing`。
- [ ] **Step 2:** 跑这三个文件 → FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** `flutter test test/embed test/ui test/llm_api_test.dart` → PASS；`flutter analyze`。
- [ ] **Step 5:** Commit `feat(voice): remember a correction — gateway learn, edit-path offer, hotwords refresh`。

### Task 9: 全局设置「语音学到的词」

**Files:**
- Create: `gui/lib/ui/voice_learned_row.dart`
- Modify: `gui/lib/ui/side_panel.dart`（262–265 行两个语音开关之后）
- Test: `gui/test/ui/voice_learned_row_test.dart`

**Interfaces:**
- Consumes: Task 8 `MainState.voiceLearned()`、`forgetLearned(id)`、`LearnedEntry.label`。
- Produces: `VoiceLearnedRow({required MainState state, required TextStyle style})`；Key `voice-learned`（行）、`voice-learned-<id>`（每条）、`voice-learned-delete-<id>`。

- [ ] **Step 1: 写失败的测试**：`hidden when the endpoint is not set`；`hidden when the gateway gives null`；`tapping opens the list: 拍森 → Python, 不改：黑猫瑞`；`delete removes the row and calls forgetLearned`；`an empty list says 还没有`（行展开后显示 `还没有`）。
- [ ] **Step 2:** → FAIL。
- [ ] **Step 3:** 实现：行标题 `语音学到的词`，点开时才调 `voiceLearned()`（不在设置页一打开就请求），结果为 null 时整行不显示。
- [ ] **Step 4:** `flutter test test/ui` → PASS；`flutter analyze`。
- [ ] **Step 5:** Commit `feat(settings): 语音学到的词 — list and delete what voice input learned`。
- [ ] **Step 6:** 推 `feat/voice-learn`，交给 rapp-49。需要网关已上线（Task 4b）；没上线时 learn 失败只记日志，设置行不显示，不影响别的。

### Task 10: 按用途整理（提示词 / 对人）

worktree：`git -C /Users/bruce/git/rapp worktree add .worktrees/voice-mode -b feat/voice-mode feat/voice-learn`。

**Files:**
- Create: `gui/lib/embed/tidy_mode.dart`
- Modify: `gui/lib/embed/voice_tidy.dart`、`gui/lib/embed/voice_tidy_card.dart`、`gui/lib/ui/prefs.dart`、`gui/lib/ui/main_state.dart`、`gui/lib/ui/side_panel.dart`
- Test: `gui/test/embed/tidy_mode_test.dart`、`voice_tidy_test.dart`、`voice_tidy_card_test.dart`、`gui/test/ui/prefs_test.dart`（已有就加，没有就建）

**Interfaces:**
- Produces:
  - `enum TidyMode { prompt, chat }`；`extension on TidyMode { String get app; /* 'dictation' | 'dictation-chat' */ String get label; /* '提示词' | '对人' */ String get json; /* 'prompt' | 'chat' */ }`；`TidyMode? tidyModeFromJson(Object? v)`。
  - `TidyMode defaultTidyMode(String app, String appName)`：`isTermApp(app)` 或 `isDesktopApp(app)` → prompt；`app` 或 `appName` 不分大小写包含 `WeChat 微信 Lark Feishu 飞书 WeCom 企业微信 DingTalk 钉钉 Telegram Slack Mail 邮件 Messages 信息 QQ` 之一 → chat；其余 prompt。
  - `String tidyModeKey(String app, String deviceId)`：终端 → `'term'`，整屏 → `'desktop:$deviceId'`，其余 → `app`。
  - `Prefs.voiceTidyMode`：`Map<String, TidyMode>`，JSON 键 `voice_tidy_mode`（对象；值认不得的条目丢掉）。
  - `VoiceTidy`：删掉 `const tidyApp`，新构造参数 `TidyMode Function(Object sid) mode`（默认恒为 prompt）和 `void Function(Object sid, TidyMode m)? setMode`；`TidyMode get running`（这一次用的）；`void switchMode()`（tidying 或 ready 时：取消当前调用、丢掉结果 / changes / 气泡提示，`setMode` 存新用途，对 `_original` 重新 `_run`，重起 overall 计时；comparing 保持）；`VoiceAi.app` 和日志里的名字用 `running.app`；prefetch 记下当时的用途，`begin` 时用途不同就不用它。
  - 卡片：标题后加 `· ${running.label} ⇄`（Key `tidy-mode`，`setMode` 为 null 时不显示），点它调 `switchMode`。
  - `MainState`：`mode: (s)` 找到 sid 的记录 `r` → `prefs.voiceTidyMode[tidyModeKey(r.app, r.id)] ?? defaultTidyMode(r.app, r.appName)`；`setMode` 写进 prefs 并 `_save()`；`void resetVoiceTidyModes()`。
  - 设置：`voice-ai-tidy` 开关下加说明文字（Key `voice-tidy-mode-note`，照抄 Global Constraints 里的句子）和按钮 `恢复默认`（Key `voice-tidy-mode-reset`，map 为空时禁用）。

- [ ] **Step 1: 写失败的测试**
  - `tidy_mode_test.dart`：`('com.tencent.xinWeChat', '微信') → chat`、`('com.tinyspeck.slackmacgap', 'Slack') → chat`、`('term:abc', 'zsh') → prompt`、`('desktop:', '桌面') → prompt`、`('com.apple.Terminal', '终端') → prompt`；`tidyModeKey('term:abc', 'd1') == 'term'`、`('desktop:2', 'd1') == 'desktop:d1'`、`('com.x', 'd1') == 'com.x'`。
  - `prefs_test.dart`：`voice_tidy_mode round-trips and drops bad values`（`{'a': 'chat', 'b': 'loud'}` → 只剩 a）。
  - `voice_tidy_test.dart`：`the tidy runs the session's mode`（mode 返回 chat → `api.runs.single.$1 == 'dictation-chat'`，`sent.single.$3.ai!.app == 'dictation-chat'`）；`switchMode re-tidies the original with the other mode and saves it`（ready 后 switchMode → 第二次 run 是 `('dictation', 原话)`，setMode 收到 prompt，changes 清空）；`a prefetch in the other mode is not used`。
  - `voice_tidy_card_test.dart`：`the title shows 对人 ⇄ and a tap switches`。
  - `side_panel`（现有测试文件）：`恢复默认 clears voice_tidy_mode`。
- [ ] **Step 2:** → FAIL。
- [ ] **Step 3:** 实现；全仓 grep `tidyApp` 改掉所有引用。
- [ ] **Step 4:** `flutter test` 全部 → PASS；`flutter analyze`；`git checkout gui/pubspec.lock`。
- [ ] **Step 5:** Commit `feat(voice): tidy for people or for prompts, by the app it goes to`。
- [ ] **Step 6:** 推 `feat/voice-mode`，交给 rapp-49。`tasks/todo.md` 记下实机验收 1–12（方案 §8）待做。
