# 输入记录 H1 + H2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 写作面板发出去的每一段都按设备记进 `devices/<id>/inputs/YYYY-MM-DD.jsonl`，草稿存在 `local/drafts/` 里，崩溃和断线都找得回来（H1）；编辑区空着按 ↑ 取上一条，「输入历史」列表可以搜、放回、复制、删除（H2）。

**Architecture:** 全在 GUI（Dart）里，唯一的原生改动是块的元数据随 chip 一起报给 Dart（Task 2）。`ComposerModel` 只多出三个钩子（草稿变了、交出去一段、一轮结束），不认识文件。`InputRecorder`（MainState 持有一个）把钩子接到两个存储上：`InputLog`（只追加的 JSONL）和 `DraftStore`（每个会话一个 0600 文件）。H2 的 `InputHistory` 在内存里按时间排好所有设备的记录，↑ 和列表都从它读。git 提交和推拉照旧只由 rapp-service 做。

**Tech Stack:** Flutter / Dart（`gui/`），`flutter_test`、`fake_async`；Swift（`Sources/RappSession`，只在 Task 2）。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-input-history-design.md`（下称「规格」）。写作面板规格 W17 指向它。代码现状的勘查在 `.superpowers/sdd/input-history-survey.md`（不进 git，没有也不影响执行）。

## Global Constraints

- Flutter 不在 PATH 上：用 `~/development/flutter/bin/flutter`，在 `gui/` 下跑。跑完测试后 `git checkout gui/pubspec.lock` 还原。
- 全部验证：`cd gui && ~/development/flutter/bin/flutter analyze` 没有问题，`~/development/flutter/bin/flutter test` 全过。Task 2 另跑 `swift test`（相关的 filter）。
- 一条记录一行 JSON，字段和含义照规格 §4，`v` 是 1；`kind` 是 `sent` 或 `draft`；`draft` 没有 `result`、`after`。`result` 是 `sent`、`partial`（带 `sentPieces`）、`failed`；`after` 是 `return` 或 `none`；`source` 一律 `typed`。
- 已发送的：`$ROOT/devices/<这台设备 id>/inputs/<本机日期 YYYY-MM-DD>.jsonl`，只在末尾加行，新记录马上写进去（规格决策 3）。
- 草稿：`$ROOT/local/drafts/<编码过的会话键>.json`，权限 0600，先写临时文件再改名；停笔 1 秒后存（就是现有的 1 秒空闲拷贝）；**发送时不马上删**，这一段的记录写进文件之后才删（A6）；草稿空了删文件。
- 会话「结束」（`_endRecord`）时还有草稿 → 一条 `kind: "draft"` 记录，文件删掉；只是「断开」时草稿留着。启动时 7 天以上没动的草稿文件同样变成 `draft` 记录。
- 写不进去不挡发送：写作面板提示行说「输入记录没写进去：<原因>」，一直失败也只说一次，直到下一次写成功。
- 日志一个字的正文都不记：只记步骤和次数。
- 开关：`gui.json` 的 `input_history`（默认 `true`）；app 配置 `recordInput`（默认 `true`）。关着时草稿照样在本机存和恢复，只是不产生任何记录（`sent` 和 `draft` 都不产生），会话结束和 7 天清理都不把草稿变成记录、也不删草稿文件。
- 只记写作面板里的内容；直接敲进画面的键、按键排上的键、空 Enter 发的回车都不记。
- 删除的说法：按钮 `从记录里去掉`，旁边注明 `git 历史里还在`。别的设备写的记录不能删。
- 面向用户的文字一律中文，照规格原样：草稿标 `没发出`；灰字 `写给 <app 名> · ↑ 上一条`（这个会话有记录时）；列表标题 `输入历史`；三个范围 `这个会话`、`这台主机`、`全部`；三个动作 `放进输入框`、`复制到本机`、`从记录里去掉`。

### 计划定的（规格 §12 留给实现的，以及规格没说的）

- `id`：26 个字符，Crockford base32；前 10 个是毫秒时间，后 16 个随机；同一毫秒内后 16 个在上一个的基础上加一，保证不重复且按时间排。
- `run`：`SessionRecord` 建立时生成一个（用同一个 `id` 生成法），重连不变，结束后再打开是新的。
- 文件名：会话键 UTF-8 后 `base64Url`、去掉 `=`，加 `.json`。
- 一轮发送（发送或重试）在它的 `done` 时写一条；重试会再写一条。窗口 id 和标题、项目取「交出去」那一刻的。
- `projects` 写项目名。
- `from.name`：读 `devices/<id>/device.json` 的 `name`，读不到用 id。
- 草稿文件里除了 `text` 还有 `pending`：交出去了、记录还没写成的那几段原文。重新打开时 `pending` 和 `text` 用换行接起来放回输入框。
- ↑ 的列表：这个会话键的记录（所有设备写的），新的在前，挨着的相同文字只算一条。

## Review Focus

1. **发送途中 rapp 被强杀**：重开、重新打开这个会话，刚才那段在输入框里。→ Task 5 的 `a send cut off by a crash comes back on the next open`。
2. **发送后马上空闲拷贝出 `''`**：草稿文件不能在记录写成之前被删。→ Task 3 的 `submit reports the piece before the draft clears`，Task 5 的 `the draft file outlives the send until its record is written`。
3. **重连**（旧会话还活着，`adoptFrom` 搬过来）：草稿只出现一次，不从文件再叠一份。→ Task 5 的 `a reconnect does not restore the draft twice`。
4. **几台主控台的记录同一天都在**：列表和 ↑ 合在一起按时间排，别的设备的不能删。→ Task 8 的 `records from another device show but cannot be removed`。
5. **一行坏掉的 JSON**（同步冲突、写了一半）：跳过这一行，其余照读，不崩。→ Task 7 的 `a broken line is skipped`。

---

### Task 1: 两个存储：`InputLog` 和 `DraftStore`

**Files:**
- Create: `gui/lib/history/record_id.dart`、`gui/lib/history/input_log.dart`、`gui/lib/history/draft_store.dart`
- Modify: `gui/lib/paths.dart`（`DataDir` 加 `draftsDir`、`inputsDir(id)`、`devicesDir`）
- Test: `gui/test/history/record_id_test.dart`、`gui/test/history/input_log_test.dart`、`gui/test/history/draft_store_test.dart`

**Interfaces:**
- Produces:
  - `String newRecordId([DateTime? now])`（monotonic，见上）；`String isoWithOffset(DateTime t)` → `2026-11-14T21:37:05+09:00`（本机时区，秒精度）。
  - `DataDir.draftsDir` = `'$localDir/drafts'`；`DataDir.devicesDir` = `'$root/devices'`；`DataDir.inputsDir(String id)` = `'${deviceDir(id)}/inputs'`。
  - `class InputLog { InputLog(String Function() dir); Future<void> append(Map<String, Object?> record, DateTime at); }`：写进 `<dir>/<at 的本机日期>.jsonl`，一行 `jsonEncode` + `\n`，`FileMode.append`，`flush: true`；需要时建目录；同一个 `InputLog` 的追加按调用顺序串行；失败时 future 带着 `FileSystemException` 完成。
  - `class DraftFile { String key; String text; List<String> pending; Map<String, Object?> meta; }`，`toJson`/`fromJson`（`v: 1`）。
  - `class DraftStore { DraftStore(String Function() dir); String pathFor(String key); DraftFile? load(String key); Future<void> save(DraftFile d); Future<void> delete(String key); List<(DraftFile, DateTime modified)> scan(); }`：`save` 在 `text` 为空且 `pending` 为空时等于 `delete`；同一个键的写按顺序串行；`load`/`scan` 遇到坏文件跳过（不删）。

- [ ] **Step 1: 写失败的测试**

```dart
test('ids sort by time and never repeat within one millisecond', ...);  // 同一个 now 连取 1000 个：全不同、字典序递增、长度 26
test('isoWithOffset carries the zone', ...);  // 匹配 ^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$，偏移等于 t.timeZoneOffset
test('append writes one line per record into the day file', ...);  // 两条 → 2026-11-14.jsonl 两行，各自 jsonDecode 回原样；中文原样（不转 \u）
test('appends keep their order', ...);  // 不 await 连发 20 条，读回顺序一致
test('a write that cannot happen fails the future', ...);  // dir 指向一个普通文件 → throwsA(isA<FileSystemException>())
test('a draft round-trips with mode 0600', ...);  // save → load 相同；stat().mode & 0x1ff == 0x180（只在 macOS/Linux 上断言）；目录里没有 .tmp
test('a key with / and : makes one flat file name', ...);  // 'h1/term:tmux:dev' → drafts 下一个文件，pathFor 不含第二个 /
test('an empty draft with nothing pending deletes the file', ...);
test('scan skips a broken file', ...);  // 一个 '{' 文件 + 一个好文件 → scan 只有好的那个，坏文件还在
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/history/`
Expected: FAIL（文件不存在）

- [ ] **Step 3: 实现**，照上面的 Interfaces。`chmod 600` 的做法照 `lib/data_dir.dart` 的 `_writePrivate`（可以把它提成公共函数复用）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/history/ test/paths_test.dart`
Expected: PASS

- [ ] **Step 5: Commit** — `feat(gui): append-only input log and private draft files`

---

### Task 2: 块的种类、大小和长文字原文报给 Dart

规格 §4：`blocks` 带种类、标签、大小、文件名；粘贴成块的长文字带全文（用户决策 2）；图片和文件不带内容。Dart 现在只知道 `n` 和 `label`。

**Files:**
- Modify: `Sources/RappSession/Channel.swift:~368`（chip 的字典）、`Sources/RappSession/SessionEvent.swift:28`（`BlockChip`）、`Sources/RappSession/EmbeddedComposer.swift:~124`（`add`）
- Modify: `gui/lib/embed/session_port.dart:112-116, ~327`
- Test: `Tests/RappSessionTests/` 里测 Channel 编码的那个文件；`gui/test/embed/session_port_test.dart`（或解析 `composer_state`/paste 结果的现有测试文件）

**Interfaces:**
- Produces: Swift `BlockChip(n:label:kind:bytes:text:)`，`kind` ∈ `text`/`image`/`data`/`file`；`bytes`：内容的字节数（文件取 `bytes`，文字取 UTF-8 长度）；`text` 只在 `kind == text` 时有；`file` 另有 `name`（文件名，不带路径）。chip 字典多出这几个键。
- Produces: Dart `class BlockChip { const BlockChip(this.n, this.label, {this.kind, this.bytes, this.text, this.name}); final String? kind; final int? bytes; final String? text; final String? name; }`，解析时缺的键就是 null。

- [ ] **Step 1: 写失败的测试**：Swift 一个 `.text("长文字")` 和一个 `.file(url, bytes: 9)` 的 chip 编码出 `kind`/`bytes`/`text`/`name`，图片的没有 `text`；Dart 解析带这些键的和不带的（旧格式）都对。
- [ ] **Step 2: 跑测试，确认失败** — `swift test --filter <那个测试类>`；`cd gui && ~/development/flutter/bin/flutter test test/embed/session_port_test.dart`
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试，确认通过**（同上，加 `flutter test` 全部）
- [ ] **Step 5: Commit** — `feat: block chips carry kind, size and pasted text for the input record`

---

### Task 3: `ComposerModel` 的三个钩子

**Files:**
- Modify: `gui/lib/embed/composer_model.dart`
- Test: `gui/test/embed/composer_model_test.dart`

**Interfaces:**
- Produces（都是可赋值的字段，由 Task 5 设）：
  - `ValueChanged<String>? onDraftChanged`：`draft` 改成一个不同的值时调用（`draft` 改成私有字段加 getter/setter；空闲拷贝、`detach`、`setDraft`、没有编辑区时的 `insert`、`adoptFrom` 都走 setter）。
  - `void Function(Outgoing o)? onSubmitted`：`submit` 交出一段（返回 `SubmitPieces` 时）；**在 `draft` 变成 `''` 之前**调用。`retry` 也调用（同一个 `Outgoing`）。
  - `void Function(Outgoing o, {required bool all})? onFinished`：`done` 里每一轮结束调用一次，`o.sent` 已经更新；`all` 是这一轮之后全部发完。
- `Outgoing` 加 `DateTime? at`（交出去的那一刻，`submit`/`retry` 时用 `_clock()` 填）。

- [ ] **Step 1: 写失败的测试**

```dart
test('submit reports the piece before the draft clears', ...);
  // onSubmitted 里读 m.draft 仍是原文；之后 onDraftChanged('') 才来；顺序用一个 List<String> 记
test('done reports the round once with what went', ...);  // done(1, 'x') 对两块的 Outgoing → onFinished(o, all: false)，o.sent == 1
test('retry reports again with the same piece', ...);
test('a late take that goes back reports nothing', ...);  // I1 的那条路径（并发重试后才完成的 take）：onSubmitted 0 次
test('onDraftChanged fires on idle copy, detach and setDraft, not for the same text', ...);  // fake_async
```

- [ ] **Step 2: 跑测试，确认失败** — `cd gui && ~/development/flutter/bin/flutter test test/embed/composer_model_test.dart`
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试，确认通过**（全部 `flutter test`）
- [ ] **Step 5: Commit** — `feat(gui): the composer reports drafts, sends and their results`

---

### Task 4: 两个开关

**Files:**
- Modify: `gui/lib/ui/prefs.dart`（`UiPrefs.inputHistory`，键 `input_history`）、`gui/lib/ui/main_state.dart:~1595`（`setInputHistory`）、`gui/lib/ui/side_panel.dart:~186`（开关，紧挨「启动时全屏」那一个）
- Modify: `gui/lib/embed/app_profile.dart`（`AppProfile.recordInput`，`ResolvedProfile.recordInput` 默认 `true`，`resolveProfile`）、`gui/lib/pages/app_profile_page.dart`（`:103` 的空判断，`:~338` 旁边一个开关）
- Test: `gui/test/ui/prefs_test.dart`、`gui/test/ui/side_panel_test.dart`、`gui/test/embed/app_profile_test.dart`、`gui/test/pages/app_profile_page_test.dart`（以现有文件名为准）

**Interfaces:**
- Produces: `bool UiPrefs.inputHistory`（默认 `true`）；`void MainState.setInputHistory(bool v)`；`bool ResolvedProfile.recordInput`；`bool RemoteSession.recordsInput => profile.recordInput`。
- 文字：侧栏开关 `记下写作面板发出去的话`，副标题 `存在数据目录的 inputs/ 里，会随 git 同步`；app 配置页开关 `记下发给这个 app 的话`，副标题 `关掉后草稿只存在本机`。Key：`Key('input-history')`、`Key('record-input-switch')`。

- [ ] **Step 1: 写失败的测试**：`UiPrefs` 默认 `true`、保存读回 `false`、坏值回到 `true`；侧栏开关切换后 `gui.json` 里是 `false`；`recordInput` 缺省 `true`、我的配置覆盖内置的、`toJson` 只在非 null 时写；配置页开关切换写进 `apps.json`。
- [ ] **Step 2: 跑测试，确认失败**
- [ ] **Step 3: 实现**，照 `startFullscreen` 和 `composer` 现有的样子。
- [ ] **Step 4: 跑测试，确认通过**（全部 `flutter test`）
- [ ] **Step 5: Commit** — `feat(gui): switches for the input record, overall and per app`

---

### Task 5: `InputRecorder`：记录、草稿、恢复、结束、清理

**Files:**
- Create: `gui/lib/history/input_recorder.dart`
- Modify: `gui/lib/ui/lifecycle.dart:16`（`SessionRecord` 加 `final String run = newRecordId();`）
- Modify: `gui/lib/ui/main_state.dart`（构造里建 `InputRecorder`；`_connect` 建好 `RemoteSession` 之后接上；`_endRecord` 里在 `dispose` 之前交出草稿；启动时清理一次）
- Test: `gui/test/history/input_recorder_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `InputLog`、`DraftStore`、`newRecordId`、`isoWithOffset`；Task 2 的 `BlockChip.kind/bytes/text/name`；Task 3 的三个钩子和 `Outgoing.at`；Task 4 的 `UiPrefs.inputHistory`、`RemoteSession.recordsInput`。
- Produces:
  - `class SessionMeta { String key; String hostId, hostName; String appId, appName; String run; int? windowId; String? windowTitle; List<String> projects; Map<String, Object?> toJson(); }`
  - `class InputRecorder { InputRecorder({required DataDir Function() data, required bool Function() enabled, void Function(String)? log, DateTime Function()? clock}); void attach(RemoteSession rs, SessionMeta Function() meta, {required bool restore}); Future<void> sessionEnded(RemoteSession rs, SessionMeta meta); Future<void> sweep({Duration age = const Duration(days: 7)}); Stream<Map<String, Object?>> get written; }`
    - `written`：每写成一条就发出来（H2 的 `InputHistory` 订阅它）。
  - 记录字段的拼法：`from` = `{id: deviceId, name: device.json 的 name ?? id}`；`host`/`app`/`session`/`run`/`window`/`projects` 取 `meta()`；`text` = `o.text`；`blocks` = 每块 `{kind, label, bytes}`，文字块加 `text`，文件块加 `name`（null 的键不写）；`result` = 全发完 `sent`，`0 < o.sent < 总块数` `partial` 加 `sentPieces: o.sent`，`o.sent == 0` `failed`；`after` = `all && rs.profile.afterSend == AfterSend.pressReturn ? 'return' : 'none'`；`ts` = `isoWithOffset(o.at)`；`id` = `newRecordId(o.at)`。
  - `MainState` 里 `meta()` 现取：`hostName: deviceName(r.id)`、`appName: r.appName`、窗口是 `rs.currentWindow` 和它在 `rs.windows` 里的 `title`、`projects: projectsOf(r.key).map((p) => p.name)`。`restore` = 建这个 `RemoteSession` 时 `r.lastSid == null`（没有旧会话会经 `adoptFrom` 把文字搬过来）。

行为：

- `attach`：`restore` 为真且有草稿文件 → `composer.setDraft([...pending, text].where(非空).join('\n'))`，文件重写成 `pending: []`。之后：`onDraftChanged` → 存 `text`（meta 一并存进文件，供结束和清理时用）；`onSubmitted` → `pending` 加上 `o.text`（空的不加）并存；`onFinished` → 记录开着（`enabled() && rs.recordsInput`）就追加一条，**写成之后**从 `pending` 去掉这段并存；关着就直接去掉。
- 写失败：`rs.composer.note('输入记录没写进去：${原因}')`，`原因` 取 `FileSystemException.osError?.message ?? message`；同一个 `InputRecorder` 连续失败只说一次，写成一次后复位。`pending` 留着这段（重开还能找回）。没有设备 id 时原因是 `还不知道这台设备的 id`。
- `sessionEnded`：记录开着且 `draft` 或 `pending` 有字 → 一条 `kind: "draft"` 记录（`text` 是 `pending` 和 `draft` 用换行接起来，`ts`/`id` 取现在），写成后删文件；关着就不动文件。
- `sweep`：`DraftStore.scan()` 里修改时间早于 `age` 的；记录开着 → 用文件里存的 meta 写 `draft` 记录，写成后删；记录关着、或文件里的 meta 表明那个 app 不记（存 meta 时一并存 `record: false`）→ 不动。`MainState` 启动后调一次（不 await，不挡启动）。
- `log`：只写 `rapp: 输入记录 写入失败`、`rapp: 输入记录 清理 N 份草稿` 这一类，不带正文、不带窗口标题。

- [ ] **Step 1: 写失败的测试**（用临时数据目录，`local/service.json` 是 `{"id":"dev1"}`，`devices/dev1/device.json` 是 `{"name":"bruce-tablet"}`；port 用 `test/fakes.dart` 里的假的）

```dart
test('three sends to two sessions make three lines with every field', ...);
  // 会话 h1/com.a 发两段、h2/com.b 发一段，done 都 (all) → 当天文件 3 行；逐字段对：v、id 长 26、ts 带偏移、kind sent、
  // from {id dev1, name bruce-tablet}、host {id, name}、app {id, name}、session、run（同一会话两行相同）、window、projects、
  // text、blocks、result sent、after none/return、source typed
test('a partial and a failed round are recorded as such', ...);  // done(1,'x') 两块 → partial, sentPieces 1；linkDown → failed
test('the draft file outlives the send until its record is written', ...);
  // submit 后、done 前：文件 pending 里有原文；done 写成后：文件没了（草稿空）
test('a send cut off by a crash comes back on the next open', ...);
  // submit 后不 done，直接丢掉 MainState（模拟强杀）；新 MainState 打开同一会话 → composer.draft 是那段原文
test('a reconnect does not restore the draft twice', ...);  // 有草稿文件 + 旧会话在 → 新会话 draft 只有一份
test('ending a session turns its draft into a draft record; disconnecting does not', ...);
test('drafts older than 7 days become draft records at start', ...);  // 文件 mtime 设成 8 天前
test('with either switch off nothing is recorded but drafts still come back', ...);
  // inputHistory=false：发送后没有 inputs 目录，草稿文件照存照恢复；recordInput=false 同样；结束时草稿文件还在
test('a failed write does not stop the send and is said once', ...);
  // inputs 路径被一个普通文件占着：发送两次 → composerSend 照发 2 次，note 只出现 1 次；pending 还有两段
test('the log never carries the text', ...);  // log 收集的每一行都不含任何一段正文和窗口标题
```

- [ ] **Step 2: 跑测试，确认失败** — `cd gui && ~/development/flutter/bin/flutter test test/history/input_recorder_test.dart test/ui/main_state_test.dart`
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试，确认通过**（全部 `flutter test`）
- [ ] **Step 5: Commit** — `feat(gui): every sent piece and unsent draft goes into the input record`

---

### Task 6: H1 的文档

**Files:**
- Modify: `rust/net/src/datadir/README.md` 和 `gui/lib/data_dir.dart:5-35` 的 `dataReadme`（两份要一样）：`devices/<设备id>/` 那一条加 `inputs/`（写作面板发出去的话，一天一个 JSONL，格式见规格 §4，进 git）；`local/` 那一条加 `drafts/`（没发出去的草稿，不进 git）。
- Modify: 数据目录规格（`docs/` 下讲数据目录的那份）、《配置规范总览》（`inputHistory`、`recordInput`、「`devices/` 里不写口令、key、secret」改写成规格 §8 的说法）、app 配置规格和编写规范（`recordInput`）、可观测性规格（「绝不记键入的文字」注明说的是日志）、输入记录规格的状态行（`H1 已实现`）。
- Modify: `tasks/todo.md` 的输入记录一节：H1 做完；待实机：真机上发送中强杀 rapp 再开、两台主控台同步后看对方的文件。

- [ ] **Step 1:** 改上面这些，每处引用规格的节号。
- [ ] **Step 2:** `cargo test -p <rust/net 的包名> datadir`（README 的标记测试）和 `flutter test test/data_dir_test.dart` 通过。
- [ ] **Step 3: Commit** — `docs: input record in the data dir README, config overview and the specs`

---

### Task 7: `InputHistory` 和 ↑ 取上一条（R2、R3）

**Files:**
- Create: `gui/lib/history/input_history.dart`
- Modify: `gui/lib/embed/composer_editor.dart`（`EditorHandlers.onArrow`）、`gui/lib/embed/flutter_editor.dart`、`gui/test/fakes.dart`（`FakeEditor`）、`gui/lib/embed/composer_panel.dart`（规则和灰字）、`gui/lib/ui/main_state.dart`（持有 `InputHistory`，订阅 `recorder.written`）
- Test: `gui/test/history/input_history_test.dart`、`gui/test/embed/flutter_editor_test.dart`、`gui/test/embed/composer_panel_test.dart`

**Interfaces:**
- Produces:
  - `class InputEntry { String id; DateTime ts; String kind; String deviceId; String session; String hostId, hostName, appName; String? windowTitle; String text; String day; Map<String, Object?> raw; bool get mine; }`
  - `class InputHistory extends ChangeNotifier { InputHistory({required DataDir Function() data}); Future<void> refresh(); void add(Map<String, Object?> record); List<InputEntry> forSession(String key); List<InputEntry> search(String q, {String? session, String? host}); Future<void> remove(InputEntry e); }`
    - `refresh`：读 `devicesDir/*/inputs/*.jsonl`，只重读长度或修改时间变了的文件；按 `id` 去重，按 `ts` 新的在前。坏行跳过。
    - `forSession`：这个会话键的，挨着的相同 `text` 只留新的那条。
  - `EditorHandlers` 加 `required bool Function(bool up) onArrow`：不在组字、光标在第一行按 ↑（`up: true`）或在最后一行按 ↓ 时调用；返回 `true` 就吃掉这个键，`false` 照常移动光标。
- 规则（在 `ComposerPanel` 里，两种编辑区共用）：编辑区空着按 ↑ → 放入 `forSession` 的第 0 条，记下「正在翻第 i 条、放进去的原文」；之后编辑区内容还等于放进去的原文时，↑ → 第 i+1 条（到头就不动，返回 `true`），↓ → 第 i-1 条，从第 0 条再 ↓ → 清空；内容一改过就退出翻看，↑↓ 照常。没有记录时 ↑ 不吃。
- 灰字：这个会话有记录时 `写给 <app 名> · ↑ 上一条`，否则照旧 `写给 <app 名>`。
- `MainState` 启动时 `refresh()` 一次（不挡启动）；`recorder.written` 的每一条 `add` 进来；打开列表时再 `refresh()`。

- [ ] **Step 1: 写失败的测试**

```dart
test('records from every device merge newest first', ...);  // dev1、dev2 各一个文件 → 交错排序
test('a broken line is skipped', ...);  // 中间一行 '{"v":1,' → 其余几行都在
test('only changed files are read again', ...);  // 第二次 refresh 不碰没变的文件（用读文件计数或修改时间断言）
test('the same text twice in a row counts once for a session', ...);
testWidgets('up on an empty editor brings the last one, again the one before, down goes back to empty', ...);
  // 记录（新→旧）c、b、a：↑ → c，↑ → b，↓ → c，↓ → 空
testWidgets('once edited, up and down move the caret', ...);  // ↑ 得 c，打一个字，再 ↑：onArrow 返回 false，内容不变
testWidgets('up with no history is not taken', ...);
testWidgets('the hint says ↑ when there is history', ...);
testWidgets('FlutterEditor reports up only on the first line and never while composing', ...);
```

- [ ] **Step 2: 跑测试，确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试，确认通过**（全部 `flutter test`）
- [ ] **Step 5: Commit** — `feat(gui): up on an empty writing panel brings back the last input`

---

### Task 8: 「输入历史」列表和删除（R4、R5）

**Files:**
- Create: `gui/lib/history/history_list.dart`（`InputHistoryList` 部件）
- Modify: `gui/lib/embed/composer_plus.dart`（「＋」里加 `输入历史`，打开一个对话框装着列表）、`gui/lib/ui/resources_tab.dart`（剪贴板和文件之后加第三节 `输入历史`）
- Test: `gui/test/history/history_list_test.dart`、`gui/test/history/input_history_test.dart`（`remove`）

**Interfaces:**
- Consumes: Task 7 的 `InputHistory`、`InputEntry`。
- Produces: `InputHistoryList({required InputHistory history, String? session, String? host, void Function(String text)? onPut})`：顶上搜索框和三个范围（`这个会话` 要有 `session`，`这台主机` 要有 `host`，否则那个范围不可选，默认选能选的最窄的）；每条：时间（今天只写 `HH:mm`，否则 `M月d日 HH:mm`）、`主机 · app · 窗口标题`、正文第一行（一行、省略号）、草稿标 `没发出`；三个动作 `放进输入框`（`onPut` 为 null 时不可点）、`复制到本机`（`Clipboard.setData`）、`从记录里去掉`（旁边小字 `git 历史里还在`；`!e.mine` 时不显示）。一次显示最新的 200 条匹配，底下 `再显示 200 条`。
- `InputHistory.remove(e)`：只对 `e.mine`；把 `e.day` 那个文件去掉 `id == e.id` 的那一行重写（临时文件再改名，其他行原样不动），再从内存里去掉。
- `放进输入框`：当前会话的 `composer.open = true`、`insert(text)`、`wantFocus()`；从「＋」打开的对话框随即关上。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('search finds a three-day-old entry and puts it into the editor', ...);
  // 三天前的文件里一条「部署脚本」；搜「部署」→ 一行；点「放进输入框」→ onPut('…部署脚本…')
testWidgets('scopes narrow to this session and this host', ...);
testWidgets('records from another device show but cannot be removed', ...);
test('removing rewrites the day file without that line only', ...);  // 三行去掉中间一行 → 剩两行逐字节相同
testWidgets('drafts are marked 没发出', ...);
testWidgets('the ＋ menu opens the history and 放进输入框 closes it', ...);
testWidgets('the resources tab shows the history after files', ...);
```

- [ ] **Step 2: 跑测试，确认失败**
- [ ] **Step 3: 实现**，行和空状态照 `resources_tab.dart` 的 `_ClipRow`、`_Empty` 的样子，颜色用 `RappTokens.of(context)`。
- [ ] **Step 4: 跑测试，确认通过**（全部 `flutter test`）
- [ ] **Step 5: Commit** — `feat(gui): the input history list with search, put back, copy and remove`

---

### Task 9: H2 的文档

**Files:**
- Modify: 主界面规格 §3.7 资源面板（加「输入历史」一节）、写作面板规格 W17 和状态行、输入记录规格状态行（`H1、H2 已实现`）和 §12（写上本计划「计划定的」那几条）、`tasks/todo.md`（H2 做完；待实机：触屏上「＋」→ 输入历史的点按大小）。

- [ ] **Step 1:** 改上面这些。
- [ ] **Step 2:** `flutter analyze` 没有问题。
- [ ] **Step 3: Commit** — `docs: input history recall in the main window and writing panel specs`
