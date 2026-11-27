# 快捷区第一行：两个菜单、打星、按次数排、自定义布局、多端同步 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 常用语条末尾换成「按键▾」「常用语▾」两个菜单（可打星、进各自设置页），前面显示打星的项或按 30 天次数排；新增带名字的按键动作和可编辑的两行键盘布局；这五样存成 `quick.json`，网里有 rapp-state 时经新的 `/v1/prefs` 多端同步。

**Architecture:** 纯数据放新目录 `gui/lib/quick/`：`key_actions.dart`（Chord、KeyAction）、`key_layout.dart`（布局）、`quick_usage.dart` + `quick_row.dart`（次数和第一行排序）、`quick_prefs.dart`（五份文档、读写、迁移，ChangeNotifier）、`quick_merge.dart`（§10.3 的纯函数）、`quick_sync.dart`（接 StateLink，照 `StateOut` 的 attach/detach）。`MainState` 持有 `QuickPrefs`，原来读 `prefs.phrases` 的地方都改读它。Rust 侧在 `services/state` 加 `prefs.rs` 一个模块和四条路由，`prefs.json` 与 `state.json` 并排。

**Tech Stack:** Flutter / Dart（`gui/`，flutter_test）；Rust（`services/state`，tokio + hyper，tests 用现有 `tests/http.rs` 的辅助函数）。不动 `rust/` 下的协议 crate。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-quick-row-design.md`（第 2 稿，用户 2026-11-27 确认，选“两期一起写计划”）。实现者两份都读；冲突以 spec 为准。

## Global Constraints

- 工作目录 `.worktrees/quick-row`，分支 `feat/quick-row`。不改版本号、不打 tag、不 push、不动 `website/`（CLAUDE.md）。不读 `docs/archives/`。
- Flutter：`~/development/flutter/bin/flutter`（不在 PATH）；测试后 `git checkout gui/pubspec.lock`（如有改动）。cargo 在 `$HOME/.cargo/bin`。
- 用户可见文字全中文。菜单按钮文字 `按键▾` `常用语▾`；菜单末行 `设置…`；长按项 `打星` / `取消星标` / `移到最前`；设置页侧栏行 `按键`；同步行三句原文：`已和 <设备名> 上的状态服务同步` / `只存在本机（没有状态服务）` / `连不上状态服务，改动会在连上后同步`。
- 内置按键动作（顺序即菜单顺序）：`search` 搜历史 ⌃R · `mode` 切模式 ⇧Tab · `expand` 展开输出 ⌃O · `bg` 转后台 ⌃B · `clear` 清屏 ⌃L · `newtab` 新标签 ⌘T。
- 默认布局 = 今天的两行去掉 `more`：第 1 行 `tab stab esc cc bksp enter up`，第 2 行 `copy paste cmdt cmd ctrl pgup pgdn left down right`。每行 ≤10 格；第 2 行非空时第 1 行 ≤9 格，`more` 自动接在第 1 行末尾。
- 次数只留最近 30 天（本地日期 `yyyy-mm-dd`）；服务端某设备 `usage` 90 天没更新清掉；单份 `data` ≤256 KB（413）；本机改动 1 秒合并后交；次数最多 1 分钟交一次。
- `at` 一律毫秒；本机写 `at = max(现在, 已知服务 at + 1)`；迁移出来的五份 `at = 0`。
- `phrase_strip`、`key_bar_more`、`phrase_cmds_seeded` 留在 `gui.json`，不同步；`gui.json` 的 `phrases` 照原样读写、不再被改（旧版本还读它）。
- 没有设备 id（`DataDir.prefsDir()` 为 null）时 `quick.json` 不落盘，只在内存（同 `_save` 的 R22）。
- 每个任务结束：`flutter analyze` 无 error/warning + 本任务测试；Rust 任务再跑 `cargo clippy -p rapp-state --all-targets -- -D warnings`。最后一个任务跑全量门禁。

### 本计划替 spec 定下的细节（Ruling，实现时照此）

1. **项的引用**带前缀：常用语和命令（常用语文档里的）是 `p:<id>`，按键动作是 `k:<id>`。星标、次数、布局里的按键动作格都用它；布局里的键盘键仍是裸 `barKeys` id。原因：`StripCmd('search')` 和 `KeyAction('search')` 可能并存。
2. **Chord 的 JSON** 是字符串：修饰键按 `ctrl alt shift cmd` 的顺序，最后是键，用 `+` 连，如 `ctrl+r`、`shift+tab`、`ctrl+alt+x`、`cmd+t`。键：`a`–`z`、`0`–`9`，或命名键 `esc tab enter bksp left up down right pgup pgdn`。键面写 `⌃⌥⇧⌘` 顺序 + 字母大写 / 数字 / `barKeys` 的 label（`⇧Tab`、`⌃←`）。
3. **数字键码**另开 `macDigitCodes`（`1:18 2:19 3:20 4:21 5:23 6:22 7:26 8:28 9:25 0:29`），不并进 `macLetterCodes`（`sendLatchedLetter` 用它，并进去会悄悄改 sticky 修饰加数字的行为）。
4. **终端上的 ⌘**：只有恰好 `cmd+<字母>` 且字母在 `termCommandLetters = {'c','v','t','w'}`（`term_stage.dart` `_command`）里才能发，走 `session.termCommand`；其余带 ⌘ 的在终端上灰掉。
5. **服务身份**用服务自己的 store id（health 的 `store`，随机生成、存在 `prefs.json` 里），不用 URL（iOS 走 `localhost:<local>` 端口映射）、不用设备 id；store id 变了 = 换了服务 / 重装 / 只放内存，按“第一次接上”处理。设备名用 `stateHost()`（Mac 是 monitor，iOS 是 hub）拿到设备 id，再 `MainState.deviceName`；拿不到写 `已和状态服务同步`。
6. **`usage` 90 天**按服务收到它的时间算（服务的秒钟），不按客户端的 `at`。
7. **布局里同一个 id 只留第一个**（否则 `Key('bar-$id')` 重复）；指向已删按键动作的格在显示时丢掉，`setKeyActions` 删动作时顺手从布局里删它的格。
8. **拖动只在同一行内**；跨行 = 选中删掉 + 另一行「＋」。
9. **第一行的顺序缓存**：键是（会话 sid、`stars`、常用语文档 `at`、按键文档 `at`）；次数变了不重算，其余变了重算。
10. **`Phrase.id`** 是可空字段、不参与 `==`；`QuickPrefs` 读进来时给没 id 的补上随机 8 位（`[a-z0-9]`，`Random.secure`）。条上的小块 key 仍用常用语文档里的下标 `phrase-$i`，按键动作用 `keyact-<id>`。
11. **`quick.json` 整个读不出**：改名 `quick.json.bad`，按迁移重建；单份文档坏了只这一份回到默认（`at = 0`）。
12. **StateLink 的 health**：`health()` 照旧返回 bool，顺便把 `prefs:1` 时的 store id 记在 `link.prefsStore`；测试里覆写 `health()` 的假 link 自然没有 prefs，不同步。

## Review Focus

1. **同步来的布局指向这台没有的按键动作、或一行 11 格、或同一个 id 两次**：快捷键盘照常画，不崩、不重 key —— Task 2 和 Task 7 的测试钉住。
2. **本机刚改、还在 1 秒合并里，watch 推来一份服务上更旧的**：本机这次改动不被盖掉（反目标）—— Task 14 测试。
3. **两台钟差：服务上的 `at` 比本机“现在”还晚**：本机新改动仍然赢、交得上去 —— Task 13 测试（`at = 服务 + 1`）。
4. **打了星的项被另一台删了**：第一行不显示它、不空指针；星标只剩这一个时回到按次数排 —— Task 3 测试。
5. **老用户升级**：第一行内容和顺序不变，「搜历史」移到最前面那批按键动作里、接在常用语后面；改过 `search` 写法成文字的留在常用语 —— Task 4 测试。

---

## P1 本机

### Task 1: Chord 和 KeyAction

**Files:**
- Create: `gui/lib/quick/key_actions.dart`
- Modify: `gui/lib/embed/key_bar_keys.dart`（加 `macDigitCodes`）
- Test: `gui/test/quick/key_actions_test.dart`

**Interfaces:**
- Produces:
  - `const chordNamedKeys = ['esc','tab','enter','bksp','left','up','down','right','pgup','pgdn'];`
  - `const termCommandLetters = {'c','v','t','w'};`
  - `class Chord { const Chord(this.key, {this.ctrl=false, this.alt=false, this.shift=false, this.cmd=false}); static Chord? parse(Object? j); String toJson(); String get label; String? get termWire; String? get termCommand; ({int code, int mods}) get macKey; }` —— `termWire` 在带 ⌘ 时为 null；`termCommand` 只在 Ruling 4 的情况下是那个字母；`macKey.mods` 用 `modifier_latch.dart` 的 `latchCtrl/latchOpt/latchShift/latchCmd`。
  - `class KeyAction { const KeyAction(this.id, {required this.label, required this.chord, this.per = const {}}); final Map<String, Chord?> per; Map<String,Object?> toJson(); static KeyAction? fromJson(Object? j); String get ref => 'k:$id'; }`，`==` 比较全部字段。
  - `Chord? chordFor(KeyAction a, AgentTool? tool)`：没工具或 `per` 里没这个工具 → `a.chord`；有 → `per[tool.id]`（可能 null）。
  - `const builtinKeyActions = <KeyAction>[...]`（6 个，见 Global Constraints；`search` 的 `per` 照 `builtinCmds['search']`：表里没有的工具 `agy`、`opencode` 记 null）。
  - `String quickId()`：随机 8 位 `[a-z0-9]`。

- [ ] **Step 1: 写失败的测试**

```dart
test('chord parses, prints and labels', () {
  final c = Chord.parse('ctrl+alt+x')!;
  expect(c.toJson(), 'ctrl+alt+x');
  expect(c.label, '⌃⌥X');
  expect(Chord.parse('shift+tab')!.label, '⇧Tab');
  expect(Chord.parse('cmd+t')!.label, '⌘T');
  for (final bad in ['', 'ctrl+', 'hyper+a', 'ctrl+ab', 'ctrl+more', 7, null]) expect(Chord.parse(bad), isNull);
});
test('chord wire names for the terminal', () {
  expect(Chord.parse('ctrl+r')!.termWire, 'Ctrl-R');
  expect(Chord.parse('shift+tab')!.termWire, 'Shift-Tab');
  expect(Chord.parse('alt+x')!.termWire, 'Alt-x');
  expect(Chord.parse('shift+x')!.termWire, 'X');
  expect(Chord.parse('ctrl+shift+r')!.termWire, 'Ctrl-Shift-R');
  expect(Chord.parse('ctrl+pgup')!.termWire, 'Ctrl-PageUp');
  expect(Chord.parse('cmd+t')!.termWire, isNull);
  expect(Chord.parse('cmd+t')!.termCommand, 't');
  expect(Chord.parse('cmd+k')!.termCommand, isNull);
  expect(Chord.parse('cmd+shift+t')!.termCommand, isNull);
});
test('chord mac key codes', () {
  expect(Chord.parse('ctrl+r')!.macKey, (code: 15, mods: latchCtrl));
  expect(Chord.parse('cmd+5')!.macKey, (code: 23, mods: latchCmd));
  expect(Chord.parse('shift+tab')!.macKey, (code: 48, mods: latchShift));
});
test('builtin actions and per-tool chords', () {
  expect(builtinKeyActions.map((a) => a.id), ['search','mode','expand','bg','clear','newtab']);
  final search = builtinKeyActions.first;
  expect(chordFor(search, null)!.toJson(), 'ctrl+r');
  expect(chordFor(search, agentTools.firstWhere((t) => t.id == 'opencode')), isNull);
  expect(KeyAction.fromJson(search.toJson()), search);
  expect(KeyAction.fromJson({'id': 'x', 'label': ' ', 'chord': 'ctrl+r'}), isNull);
  expect(KeyAction.fromJson({'id': 'x', 'label': 'a', 'chord': 'ctrl+r', 'per': {'codex': 'bad', 'gemini': null}})!.per,
      {'gemini': null});
  expect(quickId(), matches(RegExp(r'^[a-z0-9]{8}$')));
});
```

- [ ] **Step 2: 跑，确认因为文件不存在而失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/quick/key_actions_test.dart`
Expected: FAIL（`key_actions.dart` 不存在）

- [ ] **Step 3: 实现**。键面里命名键取 `barKeys[key]!.label`，字母大写；wire 的规则见 Ruling 2 和测试。再照 Claude Code、Codex 的按键文档核一遍 `mode expand bg clear` 四个在各工具上的含义；会做坏事（不是“没反应”）的那个工具在 `per` 里记 null，结果和出处 URL 写进 spec §6.2 表下。

- [ ] **Step 4: 跑测试通过 + `flutter analyze`**

Expected: PASS；analyze `No issues found!`

- [ ] **Step 5: 提交** `git commit -m "feat(gui): 按键动作的 Chord 和 KeyAction"`

### Task 2: 键盘布局

**Files:**
- Create: `gui/lib/quick/key_layout.dart`
- Modify: `gui/lib/embed/key_bar_keys.dart`（`keyBarRows` 改成由布局算）
- Test: `gui/test/quick/key_layout_test.dart`；`gui/test/embed/key_bar_keys_test.dart` 跟着改

**Interfaces:**
- Consumes: `KeyAction`（Task 1）。
- Produces:
  - `class KeyLayout { const KeyLayout(this.rows); final List<List<String>> rows; static const fallback = KeyLayout([[...7],[...10]]); Map<String,Object?> toJson(); static KeyLayout fromJson(Object? j); KeyLayout cleaned(Set<String> actionIds); bool get isDefault; }` —— 格是 `barKeys` id（不含 `more`）或 `k:<id>`。
  - `List<List<String>> keyBarRows({required KeyLayout layout, required bool more, Set<String> actionIds = const {}})`：先 `cleaned`，第 2 行非空时第 1 行末尾加 `more`；`more == false` 只返回第 1 行。旧签名 `keyBarRows({app, more})` 删掉，调用处改过来。

- [ ] **Step 1: 写失败的测试**

```dart
test('default layout gives today’s rows', () {
  expect(keyBarRows(layout: KeyLayout.fallback, more: true), [
    ['tab','stab','esc','cc','bksp','enter','up','more'],
    ['copy','paste','cmdt','cmd','ctrl','pgup','pgdn','left','down','right'],
  ]);
  expect(keyBarRows(layout: KeyLayout.fallback, more: false), [['tab','stab','esc','cc','bksp','enter','up','more']]);
});
test('cleaning drops unknown, duplicate and missing-action cells and caps the rows', () {
  final l = KeyLayout([['esc','nope','esc','k:gone','k:mine','more'], List.filled(12, 'tab')]).cleaned({'mine'});
  expect(l.rows[0], ['esc','k:mine']);
  expect(l.rows[1], ['tab']);
  final wide = KeyLayout([List.generate(10, (i) => ['esc','tab','stab','cc','cr','co','ct','cb','cl','bksp'][i]), ['up']]).cleaned({});
  expect(wide.rows[0].length, 9);
  expect(KeyLayout([[], []]).cleaned({}).rows, KeyLayout.fallback.rows);
  expect(KeyLayout.fromJson('junk').rows, KeyLayout.fallback.rows);
});
test('empty second row: no ⋯', () {
  expect(keyBarRows(layout: const KeyLayout([['esc','up'], []]), more: true), [['esc','up']]);
});
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/quick/key_layout_test.dart test/embed/key_bar_keys_test.dart`
Expected: FAIL（`KeyLayout` 未定义）

- [ ] **Step 3: 实现**，`keyBarTail` 不动；`key_bar.dart` 里 `_rowsOf` 暂时传 `KeyLayout.fallback`（Task 7 接真布局）。

- [ ] **Step 4: 跑这两个文件和 `test/embed/` 全部，通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/ test/quick/`
Expected: PASS

- [ ] **Step 5: 提交** `git commit -m "feat(gui): 键盘布局数据，快捷键盘按布局排"`

### Task 3: 次数和第一行顺序

**Files:**
- Create: `gui/lib/quick/quick_usage.dart`、`gui/lib/quick/quick_row.dart`
- Test: `gui/test/quick/quick_usage_test.dart`、`gui/test/quick/quick_row_test.dart`

**Interfaces:**
- Produces:
  - `typedef Usage = Map<String, Map<String, int>>;`（ref → 日期 → 次数）
  - `String usageDay(DateTime local)` → `yyyy-mm-dd`
  - `Usage recordUsage(Usage u, String ref, DateTime now)`（返回新表，顺带丢掉 30 天前的日子）
  - `Usage pruneUsage(Usage u, DateTime now)`；`Usage usageFromJson(Object? j)`（坏格丢掉）
  - `Map<String, int> usageTotals(Iterable<Usage> all, DateTime now)`（只算 30 天内）
  - `List<String> quickRowOrder({required List<String> phraseRefs, required List<String> keyRefs, required List<String> stars, required Map<String,int> totals})`：有星（且至少一颗指向现存项）→ 按星标顺序、只要现存的；否则全部按次数降序，平手按 `[...phraseRefs, ...keyRefs]` 里的先后。“能不能在这个会话用”不在这里判（Task 6 过滤）。

- [ ] **Step 1: 写失败的测试**

```dart
final now = DateTime(2026, 11, 27, 10);
test('usage keeps 30 days', () {
  var u = recordUsage({}, 'p:a', now);
  u = recordUsage(u, 'p:a', now);
  expect(u, {'p:a': {'2026-11-27': 2}});
  final old = {'p:a': {'2026-10-27': 5, '2026-10-29': 1}};
  expect(pruneUsage(old, now), {'p:a': {'2026-10-29': 1}});
  expect(usageTotals([old, {'p:a': {'2026-11-27': 2}, 'k:x': {'2026-11-26': 1}}], now), {'p:a': 3, 'k:x': 1});
});
test('no stars: by count, ties by menu order, phrases before keys', () {
  expect(quickRowOrder(phraseRefs: ['p:a','p:b'], keyRefs: ['k:x','k:y'], stars: [], totals: {'k:y': 3, 'p:b': 1}),
      ['k:y','p:b','p:a','k:x']);
});
test('stars: only the starred, in star order; dangling stars ignored', () {
  expect(quickRowOrder(phraseRefs: ['p:a','p:b'], keyRefs: ['k:x'], stars: ['k:x','p:gone','p:a'], totals: {'p:b': 9}),
      ['k:x','p:a']);
  expect(quickRowOrder(phraseRefs: ['p:a'], keyRefs: [], stars: ['p:gone'], totals: {}), ['p:a']);
});
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/quick/quick_usage_test.dart test/quick/quick_row_test.dart`
Expected: FAIL（文件不存在）

- [ ] **Step 3: 实现**（30 天：日期 ≥ `now` 当天往前数 29 天）

- [ ] **Step 4: 跑，通过**

- [ ] **Step 5: 提交** `git commit -m "feat(gui): 快捷区使用次数和第一行排序"`

### Task 4: QuickPrefs（quick.json、迁移）和 MainState 接入

**Files:**
- Create: `gui/lib/quick/quick_prefs.dart`
- Modify: `gui/lib/embed/phrases.dart`（`Phrase.id`）、`gui/lib/ui/main_state.dart`（`setStripItems` `addPhrase` 和新 setter）、`gui/lib/main.dart:92` 附近、`gui/lib/main_ios.dart`（同样加载）、所有读 `prefs.phrases` 的地方（`phrase_strip.dart`、`phrases_page.dart`、`side_panel.dart:275`）改读 `state.quick.phrases`
- Test: `gui/test/quick/quick_prefs_test.dart`

**Interfaces:**
- Consumes: Task 1–3。
- Produces:
  - `Phrase(text, {put = false, id})`，`String? id`，`Phrase withId(String id)`，`toJson` 有 id 才写；`String refOf(StripItem it)` → `'p:${id}'`（`StripCmd` 用它的 `id`）。
  - `class QuickDoc { const QuickDoc(this.at, this.data); final int at; final Object? data; }`
  - `const quickDocNames = ['phrases','keys','layout','stars'];`（`usage` 另算）
  - `class QuickPrefs extends ChangeNotifier`：
    - `static QuickPrefs load(String? dir, {required List<StripItem> legacy, DateTime Function() clock = DateTime.now})`；`factory QuickPrefs.migrate(List<StripItem> legacy, {String? dir, DateTime Function() clock})`
    - 读：`List<StripItem> phrases`、`List<KeyAction> keys`、`KeyLayout layout`（已 `cleaned`）、`List<String> stars`、`Usage usage`（本机）、`Map<String, Usage> others`（P2 填）、`int atOf(String name)`、`QuickDoc docOf(String name)`
    - 本机改：`setPhrases(List<StripItem>)`、`setKeys(List<KeyAction>)`、`setLayout(KeyLayout)`、`setStars(List<String>)`、`toggleStar(String ref)`（没有就加到末尾，有就去掉）、`starFirst(String ref)`、`recordUse(String ref)`。每个都：`at = max(clock 毫秒, floor[name])`、存盘、`notifyListeners()`、调 `onLocal?.call(name)`。`setPhrases`/`setKeys` 顺带删掉已不存在项的星（`stars` 也算一次本机改）；`setKeys` 删动作时从布局删它的格。
    - 同步用：`void adopt(String name, QuickDoc d)`（换内容和 `at`，不调 `onLocal`；坏数据当默认）、`final Map<String,int> floor`（服务 at + 1）、`void Function(String name)? onLocal`、`void setOthers(Map<String, Usage>)`。
  - 文件 `<dir>/quick.json`：`{"v":1,"phrases":{"at":…,"data":[…]},"keys":…,"layout":…,"stars":…,"usage":…}`，写法照 `UiPrefs.save`（先 `.tmp` 再改名）。
  - `MainState({..., QuickPrefs? quick})`，`final QuickPrefs quick`（缺省 `QuickPrefs.migrate(prefs.phrases)`），构造时 `quick.addListener(notifyListeners)`；`setStripItems(v)` → `quick.setPhrases(v)`；新增 `setKeyActions` `setKeyLayout` `toggleStar` `starFirst` `recordUse`（都转给 `quick`）。

- [ ] **Step 1: 写失败的测试**

```dart
test('migration: search moves to the keys, order kept, ids added, at 0', () {
  final q = QuickPrefs.migrate(defaultStripItems);
  expect(q.phrases.whereType<StripCmd>().map((c) => c.id), isNot(contains('search')));
  expect(q.phrases.length, defaultStripItems.length - 1);
  expect(q.keys.map((a) => a.id), ['search','mode','expand','bg','clear','newtab']);
  expect(q.phrases.whereType<Phrase>().every((p) => p.id != null), isTrue);
  for (final n in [...quickDocNames, 'usage']) expect(q.atOf(n), 0);
  expect(q.layout.rows, KeyLayout.fallback.rows);
});
test('migration: a search changed to text stays a command', () {
  final custom = StripCmd('search', per: {'codex': const CmdText('/history')});
  final q = QuickPrefs.migrate([custom, Phrase('继续')]);
  expect(q.phrases.first, custom);
  expect(q.keys.where((a) => a.id == 'search').length, 1);
});
test('migration: a search with only keys becomes the action with those keys', () {
  final q = QuickPrefs.migrate([StripCmd('search', per: {'codex': const CmdKey('co')})]);
  expect(q.phrases, isEmpty);
  expect(chordFor(q.keys.first, agentTools.firstWhere((t) => t.id == 'codex'))!.toJson(), 'ctrl+o');
});
test('round trip through quick.json, at from the clock and never below the floor', () async {
  final dir = Directory.systemTemp.createTempSync().path;
  var t = DateTime.fromMillisecondsSinceEpoch(1000);
  final q = QuickPrefs.load(dir, legacy: defaultStripItems, clock: () => t);
  q.floor['stars'] = 5000;
  q.toggleStar('k:search');
  expect(q.atOf('stars'), 5000);
  final back = QuickPrefs.load(dir, legacy: const [], clock: () => t);
  expect(back.stars, ['k:search']);
  expect(back.phrases.map(refOf), q.phrases.map(refOf));
});
test('deleting an action drops its star and its layout cell', () {
  final q = QuickPrefs.migrate(const [])
    ..setKeys([...builtinKeyActions, KeyAction('u1', label: 'X', chord: Chord.parse('ctrl+x')!)])
    ..setLayout(const KeyLayout([['esc','k:u1'], []]))
    ..toggleStar('k:u1');
  q.setKeys(builtinKeyActions);
  expect(q.stars, isEmpty);
  expect(q.layout.rows[0], ['esc']);
});
test('a broken quick.json is set aside and rebuilt', () {
  final dir = Directory.systemTemp.createTempSync().path;
  File('$dir/quick.json').writeAsStringSync('{nope');
  final q = QuickPrefs.load(dir, legacy: [Phrase('继续')]);
  expect(q.phrases.single, Phrase('继续'));
  expect(File('$dir/quick.json.bad').existsSync(), isTrue);
});
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/quick/quick_prefs_test.dart`
Expected: FAIL（`QuickPrefs` 未定义）

- [ ] **Step 3: 实现 `quick_prefs.dart`，再改 `MainState`、`main.dart`、`main_ios.dart`、各读 `prefs.phrases` 的地方**。迁移在有 `dir` 时当场写一次 `quick.json`（让补上的 id 固定下来）。

- [ ] **Step 4: 跑本文件和全量 `flutter test`**

Run: `cd gui && ~/development/flutter/bin/flutter test`
Expected: 本文件 PASS；`phrase_strip_cmds_test` 里点「搜历史」的用例此时会失败（它已不在常用语里），记下名字，Task 6 改；其余 PASS。

- [ ] **Step 5: 提交** `git commit -m "feat(gui): quick.json 存五样快捷区设置，从 gui.json 迁移"`

### Task 5: 发出按键动作

**Files:**
- Modify: `gui/lib/embed/phrase_send.dart`
- Test: `gui/test/embed/phrase_send_test.dart`

**Interfaces:**
- Consumes: `Chord`、`KeyAction`、`chordFor`（Task 1）。
- Produces:
  - `bool keyActionUsable(KeyAction a, {required bool term, AgentTool? tool})`：`chordFor` 为 null → false；终端上 `termWire == null && termCommand == null` → false；App 上总是 true。
  - `PhraseOutcome sendKeyAction({required MainState state, required RemoteSession session, required SessionPort port, required KeyAction a, AgentTool? tool, DateTime Function() now})`：共用 `_lastPhrase` 的 1 秒窗口和 `phraseBlock` 的 offline（`busy` 不挡：按键不走 composer）；终端发 `port.sendKeys(sid, [termWire(wire, 0)])` 或 `session.termCommand?.call(letter)`；App 发 `port.key(sid, code, mods)`；不读也不清 latch；不可用 → `missing`。

- [ ] **Step 1: 写失败的测试**（用 `phrase_send_test.dart` 已有的假 port / 假 term port）

```dart
test('key action on a terminal sends the wire name', ...);   // ctrl+r → sendKeys([termWire('Ctrl-R', 0)])
test('cmd+t on a terminal runs rApp’s own ⌘T', ...);          // termCommand 收到 't'，sendKeys 没调
test('cmd+k on a terminal is missing', ...);                   // 返回 PhraseOutcome.missing，什么都没发
test('key action in an app sends the mac code', ...);          // ctrl+r → key(sid, 15, latchCtrl)
test('key action ignores and keeps the sticky latch', ...);    // latch 有 ⌥：发出的 mods 不含 ⌥，发后 latch 还在
test('key action goes while a round is busy, not when offline', ...);
test('per-tool null is missing', ...);                          // search + opencode
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/phrase_send_test.dart`
Expected: FAIL（`sendKeyAction` 未定义）

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑，通过**

- [ ] **Step 5: 提交** `git commit -m "feat(gui): 发出按键动作（终端 wire 名 / rApp ⌘ / App 键码）"`

### Task 6: 第一行：两个菜单、星、顺序

**Files:**
- Modify: `gui/lib/embed/phrase_strip.dart`、`gui/lib/embed/key_bar.dart:56`（`phraseStripShown` 不再要求有项）
- Test: `gui/test/quick/quick_row_widget_test.dart`；改 `gui/test/embed/phrase_strip_cmds_test.dart` 里依赖「全部 ›」和「搜历史」在常用语里的用例

**Interfaces:**
- Consumes: `quickRowOrder`、`usageTotals`（Task 3）；`state.quick.*`、`state.toggleStar/starFirst/recordUse`（Task 4）；`sendKeyAction`、`keyActionUsable`（Task 5）。
- Produces（测试和后面任务用的 key）：
  - 菜单按钮 `Key('quick-menu-keys')`「按键▾」、`Key('quick-menu-phrases')`「常用语▾」，固定在右端，高 `phraseStripChip`。
  - 弹出层行：常用语 `Key('menu-p-$i')`（i = 常用语文档下标）、按键 `Key('menu-k-$id')`；星 `Key('menu-star-p-$i')` / `Key('menu-star-k-$id')`，图标 `Icons.star` / `Icons.star_border`；末行 `Key('menu-settings')`「设置…」。按键行右侧写 `chord.label`。
  - 条上小块：常用语和命令 `Key('phrase-$i')`，按键动作 `Key('keyact-$id')`。
  - 长按菜单：`phrase-menu-star`（打星 / 取消星标）、已打星才有 `phrase-menu-first`（移到最前，改星标顺序）；按键动作长按：`keyact-menu-edit` / `phrase-menu-star` / `keyact-menu-delete`。
  - `openKeysPage(context, state)` 的占位（Task 8 实现；本任务先放一个空页 `KeysPage` 让「设置…」能进）。

- [ ] **Step 1: 写失败的组件测试**

```dart
testWidgets('no stars: the row is phrases by count then key actions; menus at the end', ...);
  // 断言：从左到右的 key 顺序 = quickRowOrder 的结果；右端有 quick-menu-keys / quick-menu-phrases；不再有 phrases-all
testWidgets('starring in a menu: row shows only the starred, sheet stays, nothing sent', ...);
testWidgets('tapping a menu row sends and closes; grey row explains and stays', ...);
testWidgets('设置… opens the right page', ...);   // 常用语▾ → PhrasesPage；按键▾ → KeysPage
testWidgets('the order does not change while in use, but does when stars change', ...);
  // 点第 3 项 3 次（recordUse 增加），断言顺序不变；再打一颗星，断言立刻变
testWidgets('the row shows with only the two menus when nothing fits', ...);  // App 会话、常用语空、按键动作全不可用
testWidgets('key action chip on a terminal sends its keys and counts a use', ...);
testWidgets('long press: 打星 / 取消星标, and 移到最前 only on a starred item', ...);
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/quick/quick_row_widget_test.dart`
Expected: FAIL（找不到 `quick-menu-keys`）

- [ ] **Step 3: 实现**。弹出层沿用 `_all` 的外形，改成 `_sheet(kind)`；点星用 `StatefulBuilder` 或 `ListenableBuilder(state)` 刷新弹出层。顺序缓存按 Ruling 9，存在 `_PhraseStripState`，`didUpdateWidget` 换 session 时清掉。过滤：命令没工具隐藏（同今天），按键动作 `keyActionUsable` 为 false 的灰掉。`sent`/`put` 时 `state.recordUse(ref)`。

- [ ] **Step 4: 跑 `test/quick/` 和 `test/embed/`，通过**（改掉的老用例在提交信息里点名）

- [ ] **Step 5: 提交** `git commit -m "feat(gui): 第一行末尾两个菜单，打星，按次数排"`

### Task 7: 快捷键盘画用户的布局

**Files:**
- Modify: `gui/lib/embed/key_bar.dart`（`_rowsOf`、`_rowOf`、`_fire`）
- Test: `gui/test/embed/key_bar_test.dart`

**Interfaces:**
- Consumes: `keyBarRows(layout:, more:, actionIds:)`（Task 2）；`state.quick.layout/keys`（Task 4）；`sendKeyAction`（Task 5）。
- Produces: 按键动作格 `Key('bar-k-$id')`，键面 `a.label`（一行，超长省略号），点一下 = `sendKeyAction`（不记次数，§9）。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('the bar follows a custom layout, ⋯ and the inverted T included', ...);
  // setKeyLayout([['pgup','esc','up'], ['left','down','right']]) → bar-pgup 在第 1 行、bar-more 在第 1 行末尾；↑ 和 ← ↓ → 同列
testWidgets('a key action cell sends its chord', ...);   // k:search 在终端发 Ctrl-R
testWidgets('a layout naming a missing action or a key twice still draws', ...);  // adopt 一份坏布局，无异常
testWidgets('empty second row hides ⋯', ...);
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/key_bar_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**；`keyBarHeightOf` 照布局实际行数算。

- [ ] **Step 4: 跑 `test/embed/` 全部，通过**（`linux_key_bar_test`、`quick_toggle_test` 也要过）

- [ ] **Step 5: 提交** `git commit -m "feat(gui): 快捷键盘按用户布局画，格里可放按键动作"`

### Task 8: 按键设置页（按键动作 + 编辑）和侧栏「按键」

**Files:**
- Create: `gui/lib/pages/keys_page.dart`
- Modify: `gui/lib/ui/side_panel.dart:267` 附近（加一行）
- Test: `gui/test/pages/keys_page_test.dart`

**Interfaces:**
- Consumes: `state.quick.keys/stars`、`state.setKeyActions/toggleStar`（Task 4）。
- Produces:
  - `Future<void> openKeysPage(BuildContext context, MainState state)`（替换 Task 6 的占位；推页方式同 `openPhrasesPage`）。
  - `Future<KeyAction?> editKeyAction(BuildContext context, {KeyAction? start})`：名字 `Key('keyact-name')`；修饰开关 `keyact-mod-ctrl|alt|shift|cmd`；键选择 `keyact-key-<k>`（a–z、0–9、`chordNamedKeys`）；保存 `keyact-save`（名字空或没选键时禁用）。新加的 id = `quickId()`；编辑保留 id 和 `per`。
  - 页上：行 `Key('keys-row-$id')`（`ReorderableListView` 拖动、`Dismissible` 左滑删、点开编辑）、星 `keys-star-$id`、`Key('keys-add')`「＋ 新增按键动作」、`Key('keys-restore-actions')`「恢复默认按键动作」（确认方式同常用语页的恢复默认）。
  - 侧栏 `Key('keys-settings')`「按键」，右边 `${n} 个` 和 chevron，样式照 `phrases-settings` 那行。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('add ⌃⌥X and it is saved', ...);       // keys-add → 名字 + ctrl + alt + x → keyact-save；quick.keys.last.chord 是 ctrl+alt+x
testWidgets('save is off without a name or a key', ...);
testWidgets('edit keeps the id; swipe deletes; drag reorders', ...);
testWidgets('restore brings back the six built-ins', ...);
testWidgets('side panel 按键 row opens the page', ...);
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/pages/keys_page_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑，通过**

- [ ] **Step 5: 提交** `git commit -m "feat(gui): 按键设置页和侧栏「按键」"`

### Task 9: 键盘布局编辑

**Files:**
- Modify: `gui/lib/pages/keys_page.dart`（加「键盘布局」一节）
- Test: `gui/test/pages/keys_layout_test.dart`

**Interfaces:**
- Consumes: `state.quick.layout`、`state.setKeyLayout`（Task 4）；`keyBarTail`、`barKeys`。
- Produces: 格 `Key('layout-cell-$row-$i')`（点选中，选中时边框 `t.accent`）；每行末 `Key('layout-add-$row')`；选中后 `Key('layout-delete')`；候选 `Key('layout-pick-<cell id>')`（`barKeys` 全部除 `more`，再加所有 `k:<id>`）。有选中格时点候选 = 替换；有「＋」激活时 = 加到那行末尾。行满（Global Constraints 的上限）时「＋」禁用。行内拖动换位（Ruling 8）。`Key('keys-restore-layout')`「恢复默认布局」。改了立刻 `setKeyLayout`。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('move PgUp to row 1, drop ⌘T, add an action: the bar follows', ...);  // spec §14 第 7 条
testWidgets('replacing with a key already in the layout moves it, never duplicates', ...);
testWidgets('add is off when the row is full', ...);   // 第 2 行非空时第 1 行 9 格
testWidgets('restore layout gives the default', ...);
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/pages/keys_layout_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**（画法复用 `key_bar.dart` 的键面组件，宽度和真的一样）

- [ ] **Step 4: 跑，通过**

- [ ] **Step 5: 提交** `git commit -m "feat(gui): 设置页里编辑键盘布局"`

### Task 10: 常用语页加星，P1 收尾

**Files:**
- Modify: `gui/lib/pages/phrases_page.dart`（每行右边星 `Key('phrases-star-$i')`）
- Test: `gui/test/embed/phrases_test.dart` 或 `gui/test/pages/phrases_page_test.dart`（已有哪个用哪个）

- [ ] **Step 1: 写失败的测试** `testWidgets('star on the phrases page stars the item', ...)`：点 `phrases-star-0` → `state.quick.stars == [refOf(state.quick.phrases[0])]`；再点取消。
- [ ] **Step 2: 跑，确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: P1 全量**：`cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`，Expected: `No issues found!`，全部 PASS；`git checkout gui/pubspec.lock`
- [ ] **Step 5: 提交** `git commit -m "feat(gui): 常用语页每行可打星"`

## P2 同步

### Task 11: rapp-state 的 `/v1/prefs`

**Files:**
- Create: `services/state/src/prefs.rs`
- Modify: `services/state/src/lib.rs`（`pub mod prefs`）、`services/state/src/disk.rs`（按文件名读写）、`services/state/src/http.rs`（路由、health、watch、存盘、清理）、`services/state/api/http.md`、`services/state/api/samples/prefs.ndjson`（新）
- Test: `services/state/tests/prefs.rs`（新）；`services/state/tests/http.rs` 的 `health_says_who_it_is` 改

**Interfaces:**
- Produces（HTTP，见 spec §10.2）：
  - `GET /v1/health` → `{"name":"rapp-state","v":1,"prefs":1,"store":"<16 位十六进制>"}`；store id 首次生成后存进 `prefs.json`，内存模式每次启动新生成。
  - `GET /v1/prefs` → `{"phrases":{"at":…,"data":…},…,"usage":{"<device>":{"at":…,"data":…}}}`，没有的不带。
  - `PUT /v1/prefs/<phrases|keys|layout|stars>` 体 `{at:u64, base:u64, data:any}` → 204；服务上 at ≠ base → 409 体是服务上那份（没有时 `{"at":0,"data":null}`）；体不对 → 400；`data` 序列化后 >256 KB → 413（这条路由读体上限 `MAX_BODY + 4096`）；别的名字 → 404。
  - `PUT /v1/prefs/usage/<device>` 体 `{at, data}` → 204，总是收下，记服务收到的秒钟 `put_at`。
  - watch 推 `{"what":"prefs","name":"<名字>","doc":{at,data}}`；usage 的再带 `"device"`。
  - Rust 内部：`pub struct Prefs`，`fn put(&mut self, name:&str, at:u64, base:u64, data:Value) -> Result<(), Option<Doc>>`、`fn put_usage(&mut self, device:&str, at:u64, data:Value, now_secs:u64)`、`fn expire(&mut self, now_secs:u64)`（90 天 = `90*86400`）、`fn to_json`/`from_json`；`disk::load_named(dir, file)`、`disk::write_named(dir, file, bytes)`（`state.json` 的旧函数改成调它们）。`prefs.json` 和 `state.json` 同一个 saver 循环里各自脏了才写。store id 用 `RandomState` 哈希时间和 pid 得到（不加依赖）。

- [ ] **Step 1: 写失败的测试**（`tests/prefs.rs`，用 `tests/http.rs` 那套 `start/get/put` 辅助，必要时挪进 `tests/common/mod.rs`）

```rust
#[tokio::test] async fn health_says_prefs_and_store() { /* prefs == 1, store 16 hex */ }
#[tokio::test] async fn put_with_right_base_is_204_then_get_returns_it() {}
#[tokio::test] async fn put_with_stale_base_is_409_with_current_doc() {}
#[tokio::test] async fn put_on_missing_with_nonzero_base_is_409_at_zero() {}
#[tokio::test] async fn unknown_name_is_404_and_bad_body_400() {}
#[tokio::test] async fn data_over_256k_is_413() {}
#[tokio::test] async fn usage_replaces_per_device() {}
#[tokio::test] async fn watch_pushes_prefs_and_usage() {}
#[tokio::test] async fn prefs_and_store_survive_restart_with_data_dir() {}
#[tokio::test] async fn memory_mode_writes_no_prefs_file() {}
#[test] fn usage_older_than_90_days_by_receive_time_is_dropped() {}
#[test] fn bad_prefs_file_is_moved_to_bad() {}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd rust && cargo test -p rapp-state --test prefs`
Expected: FAIL（404 / 编译错 `rapp_state::prefs`）

- [ ] **Step 3: 实现**；`http.md` 加一节 `/v1/prefs`（照 spec §10.2 和上面的状态码），样本写一条 watch 推送和一条 GET 回复。

- [ ] **Step 4: 跑全 crate 和 clippy**

Run: `cd rust && cargo test -p rapp-state && cargo clippy -p rapp-state --all-targets -- -D warnings`
Expected: 全 PASS，clippy 无输出警告

- [ ] **Step 5: 提交** `git commit -m "feat(state): /v1/prefs 存快捷区设置，watch 推送，prefs.json 落盘"`

### Task 12: StateLink 的 prefs 调用

**Files:**
- Modify: `gui/lib/state/state_link.dart`
- Test: `gui/test/state/state_link_test.dart`

**Interfaces:**
- Consumes: Task 11 的 HTTP。
- Produces:
  - `String? prefsStore`：`health()` 成功且 `prefs == 1` 时记下 `store`，否则 null（Ruling 12）。
  - `Future<Map<String, Object?>> prefs()`（`GET /v1/prefs`）
  - `Future<QuickDoc?> putPref(String name, {required int at, required int base, required Object? data})`：204 → null；409 → 读体返回 `QuickDoc`；其他 → `StateLinkError(status)`。
  - `Future<void> putUsage(String device, {required int at, required Object? data})`
  - `QuickDoc` 从 `quick_prefs.dart` 引入（不另定义）。

- [ ] **Step 1: 写失败的测试**（照 `state_link_test.dart` 现有的本地 `HttpServer` 假服务）：health 带 prefs 时 `prefsStore == 'abc'`、不带时 null；`putPref` 204 → null、409 → 返回 doc 的 at/data、500 → 抛 `StateLinkError(500)`；`prefs()` 解析；`putUsage` 路径里的设备 id 有 URL 编码。
- [ ] **Step 2: 跑，确认失败**：`cd gui && ~/development/flutter/bin/flutter test test/state/state_link_test.dart` → FAIL
- [ ] **Step 3: 实现**（409 读体：给 `_send` 加一个返回状态码和体的内部变体，别复制整段）
- [ ] **Step 4: 跑，通过**
- [ ] **Step 5: 提交** `git commit -m "feat(gui): StateLink 读写 /v1/prefs"`

### Task 13: 合并规则（纯函数）

**Files:**
- Create: `gui/lib/quick/quick_merge.dart`
- Test: `gui/test/quick/quick_merge_test.dart`

**Interfaces:**
- Consumes: `QuickDoc`、`KeyAction`、`StripItem`、`KeyLayout`（前面任务）。
- Produces:
  - `sealed class MergeStep`；`class Adopt(QuickDoc doc)`；`class Push(QuickDoc doc, int base)`；`class Keep()`。
  - `MergeStep decide({required QuickDoc local, required int synced, required QuickDoc? server, required int nowMs, void Function(String)? log})`：只管“不是第一次接上”的三行表（spec §10.3）；推送时 `at = max(local.at, server.at + 1)`。
  - `bool isFirstJoin({required String? knownStore, required String store, required int synced, required QuickDoc? server})`：store 变了、`synced == 0`、服务那份比 `synced` 旧、或 `synced > 0` 而服务上没了。
  - `Map<String, MergeStep> firstJoin({required Map<String, QuickDoc> local, required Map<String, QuickDoc> server, required int nowMs})`：四份一起算。服务上没有的 → `Push(local, 0)`；本机 `at == 0` → `Adopt(server)`；否则 phrases、keys 合并（服务的在前，本机独有的接后面；常用语按文字认、命令按 id、按键动作按 id，id 不同时用户加的按 `label + chord` 认），记下“本机 id → 服务 id”的换名；stars 先按换名改、再取并集（服务的在前）；layout 用服务的，除非服务那份 `isDefault` 而本机不是；合并出来的 → `Push(merged, server.at)`，`at = max(nowMs, server.at + 1)`。

- [ ] **Step 1: 写失败的测试**——spec §10.3 每一行一个：

```dart
test('unchanged here, newer there: adopt', ...);
test('changed here, same there: push with base synced', ...);
test('both changed, here later: push with base = server at', ...);
test('both changed, there later: adopt and log', ...);
test('clock skew: server at ahead of now still lets a newer local change win', ...);   // Review Focus 3
test('first join: local at 0 adopts the server', ...);
test('first join: both edited → phrases and keys merged, nothing lost, stars remapped and united', ...);  // §14 第 11 条
test('first join: server default layout yields to a custom local one', ...);
test('first join: missing on the server → push', ...);
test('isFirstJoin: new store / synced 0 / server older / server gone', ...);
```

- [ ] **Step 2: 跑，确认失败**：`cd gui && ~/development/flutter/bin/flutter test test/quick/quick_merge_test.dart` → FAIL
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑，通过**
- [ ] **Step 5: 提交** `git commit -m "feat(gui): 快捷区设置的合并规则"`

### Task 14: QuickSync

**Files:**
- Create: `gui/lib/quick/quick_sync.dart`
- Test: `gui/test/quick/quick_sync_test.dart`

**Interfaces:**
- Consumes: `QuickPrefs`（`adopt`、`floor`、`onLocal`、`setOthers`、`docOf`、`usage`）、`decide`/`firstJoin`/`isFirstJoin`（Task 13）、`StateLink.prefs/putPref/putUsage/prefsStore`（Task 12）。
- Produces:
  - `enum QuickSyncStatus { local, synced, waiting }`
  - `class QuickSync extends ChangeNotifier { QuickSync({required QuickPrefs prefs, required String localDir, required String? device, Future<String?> Function()? host, DateTime Function() clock = DateTime.now, Duration debounce = const Duration(seconds: 1), Duration usageEvery = const Duration(minutes: 1)}); QuickSyncStatus status; String? hostId; Future<void> attach(StateLink link, String store); void detach({required bool reachable}); void onPush(Map<String, Object?> e); }`
  - 记账文件 `<localDir>/quick-sync.json`：`{"store":"…","synced":{"phrases":…,…},"others":{"<device>":{"at":…,"data":…}}}`。
  - 行为：`attach` → `GET /v1/prefs` → 第一次接上走 `firstJoin`，否则每份 `decide`；`Adopt` → `prefs.adopt`、`synced = at`、`floor = at + 1`；`Push` → `putPref`，204 → `synced = doc.at`，409 → 用回来的 doc 再走一遍（最多 3 回，之后等下次推送）；别的设备的 usage → `prefs.setOthers`。`onLocal(name)` 合并 `debounce` 后交；本机 usage 变了最多每 `usageEvery` 交一次；`device == null` 不交 usage。watch 来的 doc 当“服务上的”走 `decide`；`at <= synced` 的忽略。`detach(reachable: false)` → `waiting`，`detach(reachable: true)`（服务不支持 prefs、或没服务）→ `local`；计时器全停。

- [ ] **Step 1: 写失败的测试**（用 Task 12 测试里那种本地 `HttpServer` 假服务，或一个实现同样三个方法的假 `StateLink` 子类）

```dart
test('attach adopts newer docs and pushes changed ones', ...);
test('a local change is pushed once after the debounce', ...);          // 0.5 s 内改两次 → 一次 PUT
test('a 409 retries with the returned doc', ...);
test('a watch push older than a pending local edit does not overwrite it', ...);  // Review Focus 2
test('usage is pushed at most once a minute, others are summed in', ...);
test('a new store id is a first join', ...);
test('quick-sync.json survives a restart', ...);
test('detach: waiting when unreachable, local when no prefs', ...);
```

- [ ] **Step 2: 跑，确认失败**：`cd gui && ~/development/flutter/bin/flutter test test/quick/quick_sync_test.dart` → FAIL
- [ ] **Step 3: 实现**（用 `fake_async` 测计时，项目里已有的话；没有就把 `debounce` 设成几毫秒）
- [ ] **Step 4: 跑，通过**
- [ ] **Step 5: 提交** `git commit -m "feat(gui): QuickSync 和状态服务同步快捷区设置"`

### Task 15: 接进 StateSync、两个入口和设置页的同步行

**Files:**
- Modify: `gui/lib/state/state_sync.dart`（构造参数 `QuickSync? quick`；连上后 `link.prefsStore != null` 就 `quick.attach(link, store)`，否则 `quick.detach(reachable: true)`；`_fail` 里 `detach(reachable: false)`；off/none 时 `detach(reachable: true)`；`_onPush` 的 `'prefs'` 转给 `quick.onPush`）
- Modify: `gui/lib/main.dart:113`（`host: monitor.stateHost`）、`gui/lib/main_ios.dart:98`（`host: hub.stateHost`）：建 `QuickSync`，传给 `StateSync` 和 `MainState`（`MainState({QuickSync? quickSync})`）
- Create: `gui/lib/pages/quick_sync_line.dart`：`QuickSyncLine(state)`，按 `status` 出三句之一；`synced` 时设备名 = `state.deviceName(hostId)`，`hostId` null 写 `已和状态服务同步`。`QuickSync == null` 当 `local`。
- Modify: `keys_page.dart`、`phrases_page.dart` 底部放 `QuickSyncLine`
- Test: `gui/test/state/state_sync_test.dart`（加用例）、`gui/test/pages/quick_sync_line_test.dart`

- [ ] **Step 1: 写失败的测试**：StateSync 连上带 prefs 的服务 → `quick.status == synced`；不带 → `local`；断开 → `waiting`；watch 推 `prefs` → 本机 `QuickPrefs` 内容变；`QuickSyncLine` 三种文字原文（Global Constraints）。回到前台不用另写：`MainState` 回前台已调 `stateSync.refresh()`，重连就会再 `attach` 一次 —— 写一个用例钉住 refresh 后又 `GET /v1/prefs` 了一次。
- [ ] **Step 2: 跑，确认失败**：`cd gui && ~/development/flutter/bin/flutter test test/state/state_sync_test.dart test/pages/quick_sync_line_test.dart` → FAIL
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量门禁**

Run:
```
cd rust && cargo test --workspace --no-fail-fast && cargo clippy --workspace --all-targets -- -D warnings
cd ../gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test
git checkout pubspec.lock
```
Expected: 全 PASS；analyze `No issues found!`；clippy 无警告。（testkit 的 linux_detach 先要 `cargo build --release --bin rapp-session`。）

- [ ] **Step 5: 实机检查写进待办**：把 spec §14 的 1–11 条写成 `tasks/todo.md` 新一节「快捷区第一行（计划 `docs/superpowers/plans/2026-11-27-rapp-quick-row.md`，分支 `feat/quick-row`）」，并注明“状态服务要升到带 `/v1/prefs` 的版本，旧服务不同步、不报错”。

- [ ] **Step 6: 提交** `git commit -m "feat(gui): 快捷区设置接进状态服务同步，设置页显示同步状态"`
