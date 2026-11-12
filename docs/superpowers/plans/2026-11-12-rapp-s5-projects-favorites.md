# rapp S5（项目与常用）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 常用 app 在会话列表末尾一点就开；「项目」把几台设备上的 app 编成一组、每个成员带一行 Agent 任务，「全部打开」「全部结束」一次处理整组；会话列表可以按项目分组，顶栏第二行写出项目和任务；这些都存在本机 `workspace.json`，重启还在。

**Architecture:** 只改 Dart。新文件 `workspace_store.dart`（纯 Dart：`AppRef`/`Member`/`Project`/`Workspace` 和读写 `workspace.json`，照 `prefs.dart` 的样子），`projects.dart`（纯函数：全部打开的计划、提示文字、顶栏副标题）。`MainState` 构造时读入工作区，改动后立刻原子写回；全部打开/结束复用现有的打开、重连、结束路径（嵌入的 `SessionRecord` 路径和 S1 的 `_pending` 路径都支持）。UI：设备面板 app 行加「设为常用」，会话列表加「常用」组和「按项目」分组，左侧面板加第三个标签「项目」（新文件 `projects_tab.dart`、`inline_edit.dart`），顶栏副标题改用 `projectSubtitle`。

**Tech Stack:** Flutter 3.44（Dart，macOS 桌面为主）。Rust（rapp-hub）和 Swift（runner）不改。

**Spec:** `docs/superpowers/specs/2026-11-12-rapp-s5-projects-favorites-design.md`（全文，§6 五条假设全部按默认）；上位 `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md` §2、§3.1（顶栏第二行）、§3.7（面板标签和宽度、app 行动作）、§5 第 3、4 条（选了就收、不可撤销点两次）、§7 S5 一行、§8 第 3 条（不做多选）；`docs/superpowers/specs/2026-11-12-rapp-design-language.md`（§0 三条检查、§2 状态灯（未打开）、§6 尺寸、§8 组件、§9 词表；**只读，不改、不暂存这个文件**）；S2、S3 计划 `docs/superpowers/plans/2026-11-12-rapp-s2-embedded-stage.md`、`docs/superpowers/plans/2026-11-12-rapp-s3-lifecycle.md`（S5 建在 S3 的 `SessionRecord`、`_quiet`、`ConfirmButton` 上）。

## 规格冲突

- **C1**：规格 §2.2 说「项目」标签"S1 里是占位"，但代码里没有：S1 计划 R2 只做了会话、设备两个标签，`PanelTab` 只有 `sessions`、`devices`。本计划在 Task 4 新加 `PanelTab.projects` 和第三个标签，宽 720。

## S5 计划决定（规格没写死、我定的）

| # | 计划决定 | 理由 | 错了的代价 |
|---|---|---|---|
| K1 | 计划决定：数据模型和读写放一个文件 `gui/lib/ui/workspace_store.dart`，照 `prefs.dart`：`loadWorkspace` 不抛异常，`saveWorkspace` 抛 `FileSystemException` | 规格 §3 只点名这个文件；现有偏好也是这个分法 | 无 |
| K2 | 计划决定：文件不存在（`File.existsSync()` 为假）→ 空白、无提示。其余任何读不出的情况（JSON 坏、`version` 不是 `1`、任何字段类型不对、读文件出错）都当坏文件：整份从空白开始，提示 `项目和常用没有读到，已从空白开始`，尽力把文件改名为 `workspace.json.bad`（已有的 `.bad` 被覆盖；改名失败也不报）。不做"能读多少读多少" | 规格 §2.4；半份数据比空白更难懂 | 一条坏记录让整份重来；`.bad` 里还在，可以手修 |
| K3 | 计划决定：缺 `name` 用 `bundle`，缺 `task` 用 `''`；`device`、`bundle`、项目 `id` 必须是非空字符串；收藏和同一项目里的成员按 `'$device/$bundle'` 去重，重复的项目 `id` 只留第一个 | 宽进：手改文件少写字段也能读 | 无 |
| K4 | 计划决定：写法是 `JsonEncoder.withIndent('  ')` 写到 `workspace.json.tmp`（`flush: true`），再 `rename` 成 `workspace.json`；失败时尽力删掉 tmp 文件、重新抛出。从不写 `.bad` | 规格 §5 "写失败不留半个文件" | 无 |
| K5 | 计划决定：项目 id 用 `Random.secure()` 生成 UUID v4 字符串（`xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx`），不加依赖 | 规格 §2.4 写 `<uuid>`；`pubspec.yaml` 里没有 uuid 包 | 无 |
| K6 | 计划决定：项目名、任务标签都过 `oneLine()`（`\r`、`\n` 换成空格再 trim）。新建时名字为空不建；改名为空保持原名；任务可以为空（= 清掉） | 规格 §2.2 "只占一行"、§6 第 4 条纯文本 | 无 |
| K7 | 计划决定：同一项目里同一个（设备, app）只有一个成员，重复添加什么都不做；「添加 app」列表不列已经在这个项目里的成员，点一项后列表不收起（可以连着加几个），再点「添加 app」收起 | 规格 §6 第 1 条只说可以在多个项目里；一个项目里两份同样的成员没有意义 | 无 |
| K8 | 计划决定：收藏记下设为常用那一刻的显示名，以后不跟着改；设为常用、取消常用、新建项目、改名、加减成员、改任务都不出提示（界面本身就变了） | 设计语言 §0 第 2 条 | 无 |
| K9 | 计划决定：「常用」组不进 `groups` 和 `stepKey`（顶栏上一个/下一个只走会话）；三种分组下都显示在列表最后；没有会话时，空状态那句话下面照样列「常用」 | 规格 §2.1 "会话列表的最后一组"；它们不是会话 | 无 |
| K10 | 计划决定：一个共用的 `openVerb(Lamp?)`：`null` 或 `Lamp.notOpened` → 打开，`Lamp.disconnected` → 重连，其余 → 切到。项目成员行用它，设备面板 app 行也改用它（S3 起已断开的会话点这里本来就是重连，原来却写"切到"） | 规格 §2.2「打开 / 切到 / 重连」；设计语言 §9 "断开"和"结束"不混用 | 设备面板一个词变了 |
| K11 | 计划决定：全部打开按成员顺序**一次发出**所有需要的打开，不等前一个完成（hub 每条命令单独起任务，可以并发）。已经连接中或活动的成员算已打开；需要打开的成员所在设备离线（探测结果是离线，或设备已经不在 hub 的设备表里）就跳过。停在第一个没被跳过的成员上（它可以是本来就开着的），有这样的成员才收起面板；每个打开都不出「已打开」提示，失败的提示照常出 | 规格 §2.2；连接中算已打开，连点两下不会发第二次 open | 一次发出多个 open，A 端同时起几个流；改成串行只动 `openAll` |
| K12 | 计划决定：提示文字。全部打开：`<项目名>：` + 各段用 `；` 连起来，段依次是 `打开 N 个`（N > 0 时，重连也算）、每台跳过的设备一段 `<设备> 离线，跳过 N 个`；没有段时是 `<项目名>：已经全部打开`；项目没有成员时 `<项目名>：没有成员`。全部结束：`<项目名>：结束 N 个会话`，有 M > 0 个也在别的项目里时再加 `，其中 M 个也属于别的项目`；没有可结束的是 `<项目名>：没有要结束的会话` | 规格 §2.2 给了"<设备> 离线，跳过 N 个"和"提示里写出结束了几个"，其余措辞按 §9 词表补齐 | 改两个纯函数 |
| K13 | 计划决定：全部结束时，异步结束的会话（嵌入活动的、S1 有 sid 的）的 key 记进 `_batchEnded`；它们之后到来的 `ClosedEvent`／hub 会话消失不再出「已结束 X」，免得盖掉汇总提示。打开一个 key 时把它从 `_batchEnded` 里删掉。S1 里还没拿到 sid 的（正在打开）不能结束，不计数 | Review Focus 5 | 无 |
| K14 | 计划决定：成员行状态文字：有会话时是灯的词（`lampWord`），已断开时是 `已断开：<原因>`；没有会话时 `未打开`，设备离线时 `未打开，设备离线`。没有会话的成员灯总是"未打开"（规格写的），不换成离线灯 | 规格 §2.2 "状态（灯和文字）" | 无 |
| K15 | 计划决定：按项目分组：组的顺序是项目的创建顺序，组里按成员顺序；没有打开会话的项目不出组；「其他」放最后，组内照按设备排序；一个会话在几个项目里就在几个组里各出现一次。`stepKey` 先按出现顺序去重再走，同一个会话只走一次 | 规格 §2.3；不去重时上一个/下一个会在重复的会话上原地踏步 | 无 |
| K16 | 计划决定：顶栏第二行：当前会话属于至少一个项目时写 `<设备> · <第一个项目名>`，属于多个时项目名后加 `等`，再按项目顺序找第一个非空的任务标签，有就加 ` · <标签>`；这时不写路径和"连接中"（灯已经在转）。不属于任何项目时和 S3 一样 | 规格 §2.3 | 想同时看路径，再加一段 |
| K17 | 计划决定：项目标签的文字：空状态 `还没有项目。在上面输入名字，回车新建。`；新建输入框提示 `新建项目`；任务占位 `添加 Agent 任务`；添加列表为空时 `没有可加的 app：先在「设备」里连上一台设备，或设一个常用`。名字、任务的行内编辑按回车或失去焦点时提交 | 规格 §2.2 只定了按钮名 | 改文字 |
| K18 | 计划决定：「全部打开」在 hub 不可用或项目没有成员时灰掉；「全部结束」在没有成员有会话时灰掉；「设为常用」不需要 hub；「移出」一次点击就生效（可以再加回来，不算不可撤销；任务标签跟着丢） | 设计语言 §8 只把结束类列为不可撤销 | 想要两次点击就换成 `ConfirmButton` |
| K19 | 计划决定：删除设备时只删它的常用（规格 §2.1），**不**删项目里的成员；全部打开把这些成员当离线跳过（设备不在设备表里） | 规格只写了常用；项目是用户自己编的，设备再加回来就能用 | 留着几个打不开的成员，用户可以「移出」 |
| K20 | 计划决定：`MainState` 构造时自己 `loadWorkspace(configDir)`，读出问题就把提示设成 `problem`；`main.dart` 不用改。现有测试的临时目录里没有 `workspace.json`，行为不变 | 少一个参数；测试里换一个 `MainState` 就是"重启" | 无 |
| K21 | 计划决定：会话行在「按项目」分组下显示设备名（`byDevice: false`），和「按 App」一样 | 一个组里可能有几台设备 | 无 |

## Global Constraints

**安全规则（每个实现者都受约束，原文照录自 `.superpowers/sdd/2026-11-12-rapp-s3-lifecycle/constraints.md`）：**
- Only start/stop processes you launched, by PID. Never killall/pkill or address processes by name in AppleScript/System Events.
- Never touch /Applications/rapp.app, the running rapp-service, ~/Library/Logs/rapp, the user's real config dir, the keychain, or the system clipboard. Tests use temp dirs and ephemeral ports; never ports 47800 or 21116–21119.
- Do NOT launch any GUI/app window or send synthetic input. The user is actively using this Mac. (Task 7 live check is parked until the user agrees; no other task needs it.) `flutter build macos --debug` is a compile check only — never run the built app.
- Don't modify text in the user's documents; never touch the user's apps.
- No push, no merge, no branch switch (stay on `feat/main-window-s2-s6`), no subagents.

**Git 规则（原文照录；用户会同时在这棵树里改文件）：**
- Stage files BY NAME only (`git add <paths>`). Never `git add -u`, `-A` or `.`.
- Never `git stash`, `checkout`, `restore`, `reset` anything. For a baseline, skip it or use `git worktree add` under the scratchpad.
- Hands-off user files — never add, commit, edit, move, restore or delete:
  - README.md (uncommitted edit)
  - docs/superpowers/specs/2026-11-12-rapp-design-language.md (uncommitted edit; read-only reference — its §0 three checks apply to UI work)
  - docs/archives/
  - docs/superpowers/specs/2026-11-12-rapp-relay-security-requirements.md
  - docs/superpowers/specs/2026-11-12-rapp-requirements-feedback.md
  - docs/superpowers/specs/2026-11-12-rapp-conversation-design.md
  - `Claude outputs/` (if it appears)
- Commit message ends with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

**数据规则（原文照录）：**
- Never log passwords, tokens, secrets, relay keys, typed text or clipboard content.
- Swift tests never use `NSPasteboard.general` (named `rapp.test.<uuid>` boards, `releaseGlobally()` in tearDown). Dart tests use FakeSessionPort / FakeTransport.
- Security posture (user's decision): the self-hosted relay is the only gate; do not add crypto layers, approval steps or confirm dialogs.

**S5 另加：**
- 实机检查（Task 7）只在用户明确同意把这台 Mac 让出来一段时间之后做；那时点击一律先 `topatp X Y <pid>`（scratchpad `s2live/topatp`，按 PID 判断）确认点到的是自己的 GUI，不用按名字的 `topat`；发键前确认最前的 app 是自己的 GUI（按 PID）；截图只截自己的窗口（`screencapture -l <id>`）。
- `workspace.json` 不存密码、令牌、会话内容（规格 §2.4）：只有设备 id、bundle id、显示名、项目 id 和名字、任务标签。任务标签是用户打的字：不写进任何日志、提示以外的地方。
- 测试只读写临时目录里的 `workspace.json`；从不碰 `~/Library/Application Support/rapp`。
- 「全部结束」「删除项目」点两次是设计语言的不可撤销规则，不算审批；不加其他确认弹窗。

**测试与命令：**
- Flutter：`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test`（起点：S3 结束时 395 过，`analyze` 干净）。长输出重定向到工作区里的文件再看末尾。
- Rust、Swift 本次不改，只在 Task 7 全量验证时跑：`export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`（不跑 `cargo fmt`）；仓库根目录 `swift test`，然后 `./scripts/check.sh`，`.build-logs/check.log` 末行 `EXIT=0`。
- runner 编译检查：`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`（只编译，不运行）。
- 每个 Task 一个提交；**只** `git add <路径>`；不 push、不 merge、不换分支。

**代码规则：**
- 组件只用 `RappTokens`；可点控件高度 ≥ 48px；会话行和常用行 60px，app 行和成员行 68px（设计语言 §6）。
- 词只用设计语言 §9：打开、切到、重连、结束会话、全部打开、全部结束、设为常用；未打开；在线、离线；连接中、活动、空闲、已断开。「取消常用」「移出」「新建项目」「删除项目」「添加 app」是规格 §2 定的按钮名。
- 灯：没有会话的常用和成员用 `Lamp.notOpened`（8px 方块），所在行边框改虚线（`DashedOutline`）。灯旁边总有文字或可访问名称；装饰灯 `ExcludeSemantics`。
- 主按钮 `RappButton.primary`（全部打开）；不可撤销 `ConfirmButton`（全部结束、删除项目，3 秒复原）；其余 `RappButton.secondary`。
- 浮层只盖不挤；选了就收（打开/切到/重连/点常用/全部打开停到某个会话后收起面板）；不靠悬停和右键。
- 设计语言 §0 三条检查，每个 UI 任务交付前对一遍：① 常用、项目在左侧面板（浮层），项目和任务在顶栏第二行（边缘），不进舞台；② 全部打开/结束只出一行提示，不弹窗、不抢焦点，跳过的离线设备只写在提示里，不变成"需要你"；③ 会话结束后常用自己回到「常用」组，成员行自己回到未打开，不留要再清一次的东西。

## Review Focus

1. **坏的或未知版本的 `workspace.json`**：不崩、整份从空白开始、原文件改名成 `.bad`；之后第一次保存只写新的 `workspace.json`，`.bad` 原样不动。测试：Task 1 `a corrupt file starts empty and keeps .bad`、`a save after a bad load leaves .bad alone`。
2. **写失败**：目录不可写或 tmp 路径被占时，内存里的数据照样能用、提示 `项目和常用没有保存：<原因>`，旧文件完整、没有半个文件。测试：Task 1 `a failed write leaves the old file whole`、`an unwritable dir keeps the data in memory and says why`。
3. **同一会话在两个项目里**：按项目分组时出现两次；顶栏上一个/下一个不卡在它上面也不跳过别的会话。测试：Task 6 `stepKey visits a session listed twice once`、`step walks project groups without sticking`。
4. **全部打开连点两次、成员状态混杂**：不发第二次 open；离线跳过、已断开的重连、活动的不动；停在第一个成员上。测试：Task 5 `open all twice sends each open once`、`open all mixes open, reconnect, skip and stop`（嵌入）和 `open all on the S1 path opens pending entries once`。
5. **全部结束的汇总提示被迟到的结束事件盖掉，或者共享的会话没算进去**：测试：Task 5 `end all hint survives late closed events`、`end all counts sessions shared with another project`。

---

### Task 1: `workspace.json` 读写和常用的数据

**Files:**
- Create: `gui/lib/ui/workspace_store.dart`
- Modify: `gui/lib/ui/main_state.dart`（构造时读工作区；常用；`removeDevice` 删常用；`_save` 的原因提取抽成 `_fsReason`）
- Test: `gui/test/ui/workspace_store_test.dart`（新）、`gui/test/ui/main_state_test.dart`（新 `group('workspace')`）

**Interfaces:**
- Consumes: 现有 `MainState`（`configDir`、`hint`、`removeDevice`、`_entries`）。
- Produces（`workspace_store.dart`，纯 Dart，只 import `dart:convert`、`dart:io`、`dart:math`）：
  - `const workspaceVersion = 1;` `const workspaceFile = 'workspace.json';` `const loadProblem = '项目和常用没有读到，已从空白开始';`
  - `class AppRef { const AppRef(this.device, this.bundle, this.name); final String device, bundle, name; String get key => '$device/$bundle'; }`
  - `class Member { Member(this.app, [this.task = '']); final AppRef app; String task; String get key => app.key; }`
  - `class Project { Project(this.id, this.name, [List<Member>? members]) : members = members ?? []; final String id; String name; final List<Member> members; }`
  - `class Workspace { Workspace({List<AppRef>? favorites, List<Project>? projects}); final List<AppRef> favorites; final List<Project> projects; Map<String, Object?> toJson(); static Workspace fromJson(Object? json); }`——`fromJson` 结构不对抛 `FormatException`（K2、K3）；`toJson` 的形状正是规格 §2.4：`{"version":1,"favorites":[{"device","bundle","name"}],"projects":[{"id","name","members":[{"device","bundle","name","task"}]}]}`。
  - `({Workspace workspace, String? problem}) loadWorkspace(String dir)`——从不抛（K2）。
  - `void saveWorkspace(String dir, Workspace w)`——`Directory(dir).createSync(recursive: true)` 后按 K4 写；抛 `FileSystemException`。
  - `String newProjectId([Random? rng])`（K5）；`String oneLine(String s)`（K6）。
- Produces（`MainState`）：
  - `late final Workspace workspace;`（构造时 `loadWorkspace(configDir)`，`problem != null` 时 `hint = problem`，K20）
  - `List<AppRef> get favorites`；`bool isFavorite(String device, String bundle)`；`void toggleFavorite(String device, String bundle, String name)`（加到末尾或删掉，然后 `_saveWorkspace()`）
  - `List<AppRef> get idleFavorites`——`favorites` 里 key 不在 `_entries` 里的（S1 的 `_pending` 和嵌入的记录都在 `_entries` 里），保持收藏顺序。
  - `void _saveWorkspace()`：`saveWorkspace(configDir, workspace)`，失败 `hint = '项目和常用没有保存：${_fsReason(e)}'`，然后 `notifyListeners()`；`String _fsReason(Object e)` 即现在 `_save` 里那一行，`_save` 改用它。
  - `removeDevice(id)` 成功后删掉 `device == id` 的常用并 `_saveWorkspace()`（K19：项目成员不动）。

- [ ] **Step 1: 写失败的测试**

`workspace_store_test.dart`（每个测试 `Directory.systemTemp.createTempSync('ws')`，tearDown `chmod 755` 后删除）：
```dart
test('a missing file is empty with no problem', () {
  final r = loadWorkspace(dir.path);
  expect(r.problem, isNull);
  expect(r.workspace.favorites, isEmpty);
  expect(r.workspace.projects, isEmpty);
});
test('save then load round-trips the spec shape', () {
  final w = Workspace(
    favorites: [const AppRef('111', 'com.apple.calculator', 'Calculator')],
    projects: [Project('p1', '写周报', [Member(const AppRef('222', 'com.apple.Notes', 'Notes'), '整理 PR')])],
  );
  saveWorkspace(dir.path, w);
  final raw = jsonDecode(File('${dir.path}/workspace.json').readAsStringSync()) as Map;
  expect(raw.keys.toSet(), {'version', 'favorites', 'projects'});
  expect(raw['version'], 1);
  expect((raw['favorites'] as List).single, {'device': '111', 'bundle': 'com.apple.calculator', 'name': 'Calculator'});
  expect((raw['projects'] as List).single, {
    'id': 'p1', 'name': '写周报',
    'members': [{'device': '222', 'bundle': 'com.apple.Notes', 'name': 'Notes', 'task': '整理 PR'}],
  });
  final back = loadWorkspace(dir.path).workspace;
  expect(back.projects.single.members.single.task, '整理 PR');
  expect(File('${dir.path}/workspace.json.tmp').existsSync(), false);
});
```
其余测试（名字 + 断言）：
- `a corrupt file starts empty and keeps .bad`（Review Focus 1）：写 `'{not json'` → `problem == loadProblem`，两个列表都空；`workspace.json` 不存在；`workspace.json.bad` 内容 == `'{not json'`。
- `an unknown version is treated as corrupt`：`{"version":2,"favorites":[],"projects":[]}` → `problem == loadProblem`，`.bad` 存在。
- `wrong shapes are corrupt`：分别是 `[]`、`{"version":1,"favorites":{}}`、`{"version":1,"projects":[{"name":"x","members":[]}]}`（缺 id）、`{"version":1,"favorites":[{"device":"111"}]}`（缺 bundle）→ 每个都 `problem == loadProblem`。
- `missing name and task get defaults`：成员只有 `device`、`bundle` → `name == bundle`、`task == ''`；缺 `favorites` 或 `projects` 键 → 空列表、无 problem。
- `duplicates load once`：两个一样的常用、同一项目里两个一样的成员、两个同 id 的项目 → 各剩一个（第一个）。
- `names and tasks load as one line`：`"name":"a\nb "` → `'a b'`。
- `an existing .bad is replaced`：先放 `workspace.json.bad` = `'old'`，再放坏的 `workspace.json` = `'new'` → 读后 `.bad` == `'new'`。
- `a failed write leaves the old file whole`（Review Focus 2）：先 `saveWorkspace` 一份 A；`Directory('${dir.path}/workspace.json.tmp').createSync()`；`saveWorkspace` 一份 B → `throwsA(isA<FileSystemException>())`；`workspace.json` 读回仍是 A。
- `a save after a bad load leaves .bad alone`（Review Focus 1）：坏文件 `'{x'` → 读；`saveWorkspace(dir.path, Workspace())` → `.bad` 仍是 `'{x'`，`workspace.json` 是合法的空工作区。
- `project ids are uuid v4 and differ`：`newProjectId()` 匹配 `RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')`；100 个互不相同。
- `oneLine folds newlines`：`oneLine(' a\r\nb\n ') == 'a  b'`（两个换行字符各换一个空格，再 trim）。

`main_state_test.dart` 新 `group('workspace')`（用文件顶部的 `t`、`hub`、`tmp`；"重启"= 用同一个 `tmp.path` 再建一个 `MainState`）：
- `a bad workspace file shows the load problem as the hint`：先写坏的 `${tmp.path}/workspace.json`，再 `MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs())` → `hint == '项目和常用没有读到，已从空白开始'`，`favorites` 空。
- `toggleFavorite saves and survives a restart`：`s.toggleFavorite('111', 'com.apple.calculator', 'Calculator')` → `isFavorite` 真；新的 `MainState` 的 `favorites.single.name == 'Calculator'`；再 toggle 一次 → 假，重启后空。`hint` 一直是 `''`（K8）。
- `idle favorites leave out open and pending sessions`：设两个常用（`111/com.apple.Safari`、`111/com.apple.Notes`）；`s.openOrSwitch('111', 'com.apple.Safari', 'Safari')`（还在 pending）→ `idleFavorites` 只剩 Notes；`t.emit({...opened(1, '111', 'com.apple.Safari'), 'req': ...})` 后仍只剩 Notes；`t.emit({'event':'closed','sid':1})`（会话没了；hub 没有 `sessions` 事件，会话靠 `closed` 消失）后两个都在。
- `removing a device drops only its favorites`：常用 `111/x`、`222/y`；`t.onSend` 对 `remove_host` 照 `devices_tab_test` 的 fake 回 `{'event':'hosts','req':…,'hosts':[222]}`；`await s.removeDevice('111')` → `favorites` 只剩 `222/y`，重启后也是。
- `an unwritable dir keeps the data in memory and says why`（Review Focus 2）：`chmod 555 tmp.path`；`toggleFavorite(...)` → `isFavorite` 真，`hint` 以 `'项目和常用没有保存：'` 开头；`${tmp.path}/workspace.json` 不存在。

- [ ] **Step 2: 跑测试确认失败** — `cd gui && $HOME/development/flutter/bin/flutter test test/ui/workspace_store_test.dart test/ui/main_state_test.dart` → 编译失败（`loadWorkspace`、`toggleFavorite` 未定义）。
- [ ] **Step 3: 实现** 上面 Interfaces 里的类型和函数。`removeDevice` 里 hub 发什么命令、回什么照现有 `devices_tab_test` 的写法（测试里先 grep `remove` 找到现有的 fake 回答）。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿（395 + 新增）。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/workspace_store.dart gui/lib/ui/main_state.dart gui/test/ui/workspace_store_test.dart gui/test/ui/main_state_test.dart`，`feat(gui): workspace.json store and favourites`

---

### Task 2: 常用的界面：设备面板「设为常用」、会话列表「常用」组

**Files:**
- Modify: `gui/lib/ui/session_model.dart`（`openVerb`）、`gui/lib/ui/devices_tab.dart`（`_AppRow`）、`gui/lib/ui/sessions_tab.dart`（「常用」组、`_FavoriteRow`、空状态）
- Test: `gui/test/ui/session_model_test.dart`、`gui/test/ui/devices_tab_test.dart`、`gui/test/ui/side_panel_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `AppRef`、`MainState.favorites`/`isFavorite`/`toggleFavorite`/`idleFavorites`；现有 `openOrSwitch`、`DashedOutline`、`StatusLamp`、`RappButton.secondary`。
- Produces:
  - `session_model.dart`：`String openVerb(Lamp? lamp)`（K10）。
  - `_AppRow` 多一个按钮 `Key('fav-$app')`，`RappButton.secondary`，文字 `设为常用` / `取消常用`，点了 `state.toggleFavorite(id, app, name)`；不看 hub 状态（K18）。打开按钮的文字改成 `openVerb(session?.lamp)`，禁用规则不变（连接中、hub 不可用）。
  - `sessions_tab.dart`：`idleFavorites` 不空时，在所有会话组之后加一组，标题 `常用`，标题文字 `Key('group-favorites')`；每行 `_FavoriteRow`（`Key('favorite-${f.key}')`，60px，`DashedOutline` 边框，`StatusLamp(Lamp.notOpened)`，第一行 app 名，第二行设备名 `state.deviceName(f.device)`，`Semantics(button: true, label: '${f.name} @ <设备>，未打开')`），点一下 `state.openOrSwitch(f.device, f.bundle, f.name)`（会收起面板），hub 不可用时不响应。没有会话时 ListView 里先放原来的空状态那句话，再放「常用」组（K9）。

- [ ] **Step 1: 写失败的测试**
- `session_model_test.dart` `open verbs by lamp`：`openVerb(null) == '打开'`、`openVerb(Lamp.notOpened) == '打开'`、`openVerb(Lamp.disconnected) == '重连'`、`openVerb(Lamp.active) == '切到'`、`openVerb(Lamp.idle) == '切到'`、`openVerb(Lamp.connecting) == '切到'`。
- `devices_tab_test.dart`：
  - `设为常用 toggles and the label follows`：`selectMini` 后点 `fav-<app>` → `s.isFavorite('111', app)` 真，按钮里 `find.text('取消常用')`；再点 → 假，`find.text('设为常用')`。
  - `设为常用 works without the hub`：hub 退出（照 `hub gone` 那个测试的做法）后点 `fav-<app>` → `isFavorite` 真。
  - `fav button is at least 48 tall`：`tester.getSize(find.byKey(Key('fav-<app>'))).height >= 48`。
- `side_panel_test.dart`：
  - `idle favorites list last with a not-opened lamp`：`s.toggleFavorite('111', 'com.apple.Notes', 'Notes')`；先 `open(tester, 1, 'com.apple.Safari')`；`find.byKey(Key('group-favorites'))` 找到一个；`find.byKey(Key('favorite-111/com.apple.Notes'))` 的 dy 大于 `session-111/com.apple.Safari` 的；行里有 `StatusLamp` 且 `lamp == Lamp.notOpened`；行高 60；`find.text('mini')` 在行里。
  - `favorites show under the empty state`：没有会话、一个常用 → `find.text('没有打开的会话。到「设备」里打开一个 app。')` 和 `favorite-…` 都在，后者在下面。
  - `tapping a favorite opens it and closes the panel`：`s.togglePanel()`，点 `favorite-111/com.apple.Notes` → `t.sent.last` 是 `{'cmd':'open','id':'111','app':'com.apple.Notes',…}`，`s.panel == null`。
  - `an open favorite leaves the 常用 group and comes back when it ends`：常用 Notes，`open(tester, 1, 'com.apple.Notes')` → `favorite-…` 找不到；`t.emit({'event':'closed','sid':1})` → 又找到了。
  - `step skips favorites`：一个会话 + 一个常用，`s.step(1)` → `currentKey` 是那个会话的 key（常用不进 `stepKey`）。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/session_model_test.dart test/ui/devices_tab_test.dart test/ui/side_panel_test.dart` → `openVerb` 未定义、找不到 `fav-…`。
- [ ] **Step 3: 实现** 上面 Interfaces 的改动。`_AppRow` 现在一行里放得下两个按钮（720 宽面板）；在 400 宽窗口下用 `Flexible` 让 app 名省略，不溢出。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿；现有的 `app rows show 打开 / 切到 by session state`、`no overflow on a 400x500 window` 仍过。对一遍 §0 三条检查。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/session_model.dart gui/lib/ui/devices_tab.dart gui/lib/ui/sessions_tab.dart gui/test/ui/session_model_test.dart gui/test/ui/devices_tab_test.dart gui/test/ui/side_panel_test.dart`，`feat(gui): favourites in the device panel and the sessions list`

---

### Task 3: 项目的数据操作（`MainState`）

**Files:**
- Modify: `gui/lib/ui/main_state.dart`
- Test: `gui/test/ui/main_state_test.dart`（新 `group('projects')`）

**Interfaces:**
- Consumes: Task 1 的 `Workspace`、`Project`、`Member`、`AppRef`、`newProjectId`、`oneLine`、`_saveWorkspace`；现有 `_entries`、`probes`、`hub.hosts`。
- Produces（每个改数据的方法最后都 `_saveWorkspace()`，它会 `notifyListeners()`；都不出提示，K8）：
  - `List<Project> get projects => workspace.projects;`
  - `Project? createProject(String name)`——`oneLine` 后为空返回 `null`、什么都不做；否则 `Project(newProjectId(), name)` 加到末尾并返回。
  - `void renameProject(String id, String name)`（空名保持原名，K6）；`void deleteProject(String id)`（不结束任何会话，规格 §6 第 3 条）。
  - `bool addMember(String projectId, AppRef app)`——同一项目已有同 key 返回 `false`（K7）。
  - `void removeMember(String projectId, String key)`；`void setTask(String projectId, String key, String task)`（`oneLine`）。
  - `SessionEntry? entryFor(String key)`——`_entries` 里 key 相同的那条。
  - `bool deviceOffline(String id)`——设备不在 `hub?.hosts` 里，或 `probes[id]?.lamp == Lamp.offline`（K11、K19）。
  - `Lamp memberLamp(Member m)` = `entryFor(m.key)?.lamp ?? Lamp.notOpened`；`String memberStatus(Member m)`（K14）。
  - `List<AppRef> addableApps(String projectId)`——先按 `hub.hosts` 顺序列出在线设备（`probes[id]?.lamp == Lamp.active`）的 `probes[id]!.apps!.apps`（`AppRef(id, a.app, a.name)`），再接上 key 没出现过的常用；去掉这个项目已有的成员（K7）。
  - `List<Project> projectsOf(String key)`——含这个 key 成员的项目，按项目顺序。

- [ ] **Step 1: 写失败的测试**（`group('projects')`，用文件顶部的 `s`、`t`、`tmp`）
- `create, rename and delete a project`：`createProject('  ')` → `null`、`projects` 空；`createProject('写\n周报')!.name == '写 周报'`；`renameProject(id, '')` 后名字不变；`renameProject(id, '周报')` → `'周报'`；`deleteProject(id)` → 空。`hint` 一直 `''`。
- `members are unique within a project but shared across projects`：两个项目 A、B；`addMember(A, Notes@111)` 真，再来一次假；`addMember(B, Notes@111)` 真；`projectsOf('111/com.apple.Notes').map((p) => p.name)` == `['A', 'B']`。
- `tasks are one line and can be cleared`：`setTask(A, key, '整理\nPR')` → `'整理 PR'`；`setTask(A, key, '')` → `''`。
- `projects survive a restart`：建项目、加两个成员、设一个任务；新 `MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs())` → 名字、成员顺序、任务都一样。
- `deleting a project ends no session`：`t.emit` 一个 `opened` 让 Notes 会话开着，它是 A 的成员；`deleteProject(A)` → `t.sent` 里没有 `close`，`s.current`/`entryFor` 仍在。
- `member lamp and status`：没会话 → `Lamp.notOpened`、`'未打开'`；`s.probes['222'] = DeviceProbe(Lamp.offline, '离线')` 后 222 上的成员 → `'未打开，设备离线'`；会话开着 → `Lamp.active`、`'活动'`。（已断开的状态文字在 Task 5 的嵌入测试里断言：`'已断开：<原因>'`。）
- `addable apps list online devices then favorites, minus members`：`s.probes['111'] = DeviceProbe(Lamp.active, '在线', apps: AppList(...Safari, Notes...))`（照 `AppList` 现有构造）；常用 `222/com.apple.Chess`（222 不在线）和 `111/com.apple.Notes`（已在设备列表里）；项目成员已有 Safari → `addableApps(A).map((a) => a.key)` == `['111/com.apple.Notes', '222/com.apple.Chess']`。
- `removing a device keeps project members`：项目成员在 222；`removeDevice('222')` 后成员还在，`deviceOffline('222')` 真。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/main_state_test.dart` → 编译失败（`createProject` 未定义）。
- [ ] **Step 3: 实现** 上面的方法。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/main_state.dart gui/test/ui/main_state_test.dart`，`feat(gui): project model in MainState`

---

### Task 4: 「项目」标签

**Files:**
- Create: `gui/lib/ui/inline_edit.dart`、`gui/lib/ui/projects_tab.dart`
- Modify: `gui/lib/ui/main_state.dart`（`enum PanelTab { sessions, devices, projects }`）、`gui/lib/ui/side_panel.dart`（第三个标签、宽度、内容）
- Test: `gui/test/ui/inline_edit_test.dart`（新）、`gui/test/ui/projects_tab_test.dart`（新）、`gui/test/ui/side_panel_test.dart`

**Interfaces:**
- Consumes: Task 3 的全部项目操作、`memberLamp`、`memberStatus`、`addableApps`、`entryFor`；Task 2 的 `openVerb`；`StatusLamp`、`DashedOutline`、`RappButton`、`ConfirmButton`、`TabChip`。
- Produces:
  - `class InlineEdit extends StatefulWidget { const InlineEdit({super.key, required this.text, required this.onCommit, this.placeholder = '', this.style, this.semanticLabel}); final String text; final ValueChanged<String> onCommit; final String placeholder; final TextStyle? style; final String? semanticLabel; }`——平时是一个 ≥ 48px 高的按钮样文字（`text` 为空时显示 `placeholder`，`--muted`），点一下变成单行 `TextField`（自动聚焦、全选）；回车或失去焦点时调用一次 `onCommit(当前文字)` 并回到文字；Esc 放弃。外面的 `text` 变了而没在编辑时跟着变。
  - `class ProjectsTab extends StatelessWidget { const ProjectsTab({super.key, required this.state}); }`，`ListenableBuilder` 听 `state`。布局（K17）：
    - 最上面 `TextField`，`Key('new-project')`，提示 `新建项目`，回车 `createProject` 后清空；没有项目时下面一句 `还没有项目。在上面输入名字，回车新建。`。
    - 每个项目一张卡 `Key('project-<id>')`：标题行 = `InlineEdit`（`Key('project-name-<id>')`，600 字重，`onCommit: renameProject`）+ 成员灯 `Key('project-lamps-<id>')`（每个成员一个 `StatusLamp(memberLamp(m))`，`ExcludeSemantics`）；按钮行 = `RappButton.primary('全部打开')`（`Key('open-all-<id>')`）、`ConfirmButton('全部结束')`（`Key('end-all-<id>')`）、`ConfirmButton('删除项目')`（`Key('delete-project-<id>')`），三个按钮的回调在 Task 5 接上全部打开/结束，本任务先接 `deleteProject`，另两个 `onPressed: null`。
    - 成员行 `Key('member-<id>-<key>')`，68px：灯、`<app> @ <设备>`、任务 `InlineEdit`（`Key('task-<id>-<key>')`，占位 `添加 Agent 任务`，`onCommit: setTask`）、状态文字 `memberStatus(m)`、`RappButton.secondary(openVerb(entryFor(key)?.lamp))`（`Key('member-open-<id>-<key>')`，点了 `openOrSwitch` 并收起面板；连接中或 hub 不可用时灰掉）、`RappButton.secondary('移出')`（`Key('member-remove-<id>-<key>')`）。没有会话的成员行边框 `DashedOutline`。行的 `Semantics` 标签 `<app> @ <设备>，<状态文字>`。
    - 卡底 `RappButton.secondary('添加 app')`（`Key('add-member-<id>')`），点一下展开/收起列表；列表每项 `Key('add-<id>-<key>')`，文字 `<app> @ <设备>`，点了 `addMember`（列表不收，K7）；列表为空时显示 K17 那句话。
  - `SidePanel`：`TabChip` `Key('tab-projects')`，文字 `项目`，96 宽，排在「设备」后面；`devices || projects` 时宽 720；内容 `PanelTab.projects` → `ProjectsTab(state: state)`。

- [ ] **Step 1: 写失败的测试**
- `inline_edit_test.dart`：
  - `tap edits, enter commits once`：`InlineEdit(text: 'a', onCommit: commits.add)`；点文字 → 出现 `TextField`；输入 `'b'`、`testTextInput.receiveAction(TextInputAction.done)` → `commits == ['b']`，`TextField` 不见了。
  - `losing focus commits`：编辑中把焦点移到另一个 `FocusNode` → `commits` 有一次。
  - `escape cancels`：编辑中输入后按 Esc（`tester.sendKeyEvent(LogicalKeyboardKey.escape)`）→ `commits` 空，显示原文字。
  - `empty text shows the placeholder` 和 `is at least 48 tall`。
- `projects_tab_test.dart`（setUp 同 `devices_tab_test`：临时目录、`FakeTransport` 发 hosts 111 `mini`、222；`wrap(ProjectsTab(state: s))`，窗口 1194×834）：
  - `enter on 新建项目 creates a card and clears the field`：`enterText(find.byKey(Key('new-project')), '写周报')`、`receiveAction(done)` → `s.projects.single.name == '写周报'`，`find.byKey(Key('project-${id}'))` 找到，输入框文字为空。
  - `empty state text`：`find.text('还没有项目。在上面输入名字，回车新建。')`。
  - `tap the name to rename`：点 `project-name-<id>`，输入 `'周报'`，done → `s.projects.single.name == '周报'`。
  - `add app lists online apps and favorites and stays open`：探测结果放好 111 的 Safari、Notes，常用 222/Chess；点 `add-member-<id>` → 三项 `add-<id>-111/com.apple.Safari` 等都在；点 Safari → 成员行 `member-<id>-111/com.apple.Safari` 出现，`add-<id>-111/com.apple.Safari` 不见了，Notes 那项还在。
  - `empty add list explains`：没有在线设备、没有常用 → `find.text('没有可加的 app：先在「设备」里连上一台设备，或设一个常用')`。
  - `member row shows app @ device, task placeholder and status`：`find.text('Safari @ mini')`、`find.text('添加 Agent 任务')`、`find.text('未打开')`；`member-open-…` 里 `find.text('打开')`；行高 68。
  - `editing a task saves it`：点 `task-<id>-<key>`，输入 `'整理 PR'`，done → `s.projects.single.members.single.task == '整理 PR'`，`find.text('整理 PR')`。
  - `移出 removes the member`、`删除项目 needs two taps`（点一次还在、显示 `再点一次确认`，再点一次没了；3 秒后复原的测试 `ConfirmButton` 已有，不重复）。
  - `title lamps show one lamp per member`：两个成员 → `find.descendant(of: project-lamps-<id>, matching: find.byType(StatusLamp))` 两个。
  - `member open button follows the session`：会话开着后 → `切到`；点它 → `s.panel == null`、`t.sent.last['cmd'] == 'focus'`（S1 `openOrSwitch` 对已开会话发 `focus`）。
- `side_panel_test.dart`：
  - `projects tab is 720 wide on a big window`：`s.togglePanel(PanelTab.projects)` → 面板宽 720，`find.byType(ProjectsTab)` 找到。
  - 现有 `tabs switch panel and close button closes` 加一步：点 `tab-projects` → `s.panel == PanelTab.projects`。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/inline_edit_test.dart test/ui/projects_tab_test.dart test/ui/side_panel_test.dart` → 编译失败（`InlineEdit`、`ProjectsTab`、`PanelTab.projects` 未定义）。
- [ ] **Step 3: 实现** 上面的组件。`switch (PanelTab)` 的地方（`main_window.dart`、`side_panel.dart`）补 `projects` 分支，`flutter analyze` 会指出漏的。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿；`no overflow on a 400x500 window` 再加一个打开项目标签的变体也不溢出。对一遍 §0 三条检查。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/inline_edit.dart gui/lib/ui/projects_tab.dart gui/lib/ui/main_state.dart gui/lib/ui/side_panel.dart gui/test/ui/inline_edit_test.dart gui/test/ui/projects_tab_test.dart gui/test/ui/side_panel_test.dart`（改了 `main_window.dart` 再加上），`feat(gui): projects tab`

---

### Task 5: 全部打开、全部结束

**Files:**
- Create: `gui/lib/ui/projects.dart`
- Modify: `gui/lib/ui/main_state.dart`、`gui/lib/ui/projects_tab.dart`（接上两个按钮）
- Test: `gui/test/ui/projects_test.dart`（新）、`gui/test/ui/main_state_test.dart`、`gui/test/ui/projects_tab_test.dart`

**Interfaces:**
- Consumes: Task 1、3 的模型和 `entryFor`、`deviceOffline`、`projectsOf`、`deviceName`；现有 `_openEmbedded`、`openOrSwitch` 的 S1 部分、`_connect`、`reconnect`、`_endCurrentEmbedded`、`endCurrent`、`_onHub`、`_onPortEvent`。
- Produces（`projects.dart`，纯 Dart，import `lamp.dart`、`workspace_store.dart`）：
  - `class OpenPlan { const OpenPlan(this.open, this.first, this.skipped); final List<Member> open; final String? first; final Map<String, int> skipped; }`——`open`：要打开或重连的成员（按成员顺序）；`first`：第一个没被跳过的成员的 key；`skipped`：设备 id → 跳过个数，按第一次出现的顺序。
  - `OpenPlan planOpenAll(Project p, {required Lamp? Function(String key) lampOf, required bool Function(String device) offline})`——每个成员：`lampOf` 不是 `null`/`Lamp.disconnected` → 已打开（只可能成为 `first`）；否则设备 `offline` → 跳过；否则进 `open`（K11）。
  - `String openAllHint(Project p, OpenPlan plan, String Function(String id) deviceName)`、`String endAllHint(String name, int ended, int shared)`（K12 的原样文字）。
- Produces（`MainState`）：
  - `Future<void> _open(String id, String app, String appName, {bool select = true, bool quiet = false})`——现在 `openOrSwitch` 的两条路径搬进来：`select` 为假时不改 `currentKey`、不收面板；`quiet` 为真时不出「已打开」提示。`openOrSwitch(id, app, appName)` = `_open(id, app, appName)`。`_openEmbedded` 多带这两个参数；`_connect(r, {bool reconnect = false, bool quiet = false})`，`quiet` 时最后不写「已打开」。S1 路径 `select` 为假时打开失败：`currentKey == key` 才改回 `null`（全部打开停的那个失败了，不猜别的）。两条路径进来都先 `_batchEnded.remove(key)`（K13）。
  - `bool endSession(String key, {bool quiet = false})`——结束一个会话，返回是否真的结束了（或开始结束）。嵌入：现在 `_endCurrentEmbedded` 的三种 phase 规则，作用在 `_records[key]` 上；S1：`entryFor(key)?.sid` 为 `null`（还在打开）返回 `false`，否则照现在 `endCurrent` 的 `port.close`/`hub.close`（S1 要求 `hubUsable`）。`quiet` 为真时不写「正在结束」「已结束」提示。`endCurrent()` 改成 `if (currentKey != null) endSession(currentKey!)`，行为不变。
  - `final Set<String> _batchEnded = {};`——`endAll` 里嵌入活动的、S1 有 sid 的 key 放进去；`_onPortEvent` 的 `ClosedEvent` 分支和 `_onHub` 的 S1 循环（`closeReasons.remove` 之后）遇到 `_batchEnded.remove(key)` 为真时不写 `endedHint`（K13）。
  - `void openAll(String projectId)`——`!hubUsable` 或找不到项目时返回；`plan = planOpenAll(p, lampOf: (k) => entryFor(k)?.lamp, offline: deviceOffline)`；对 `plan.open` 每个成员 `_open(m.app.device, m.app.bundle, m.app.name, select: false, quiet: true)`，**不 await**（K11；两条路径在第一个 `await` 之前就已经把记录/`_pending` 放好，所以紧接着第二次 `openAll` 看到的是连接中）；`hint = openAllHint(...)`；`plan.first != null` 时 `currentKey = plan.first; panel = null`；`notifyListeners()`。
  - `void endAll(String projectId)`——对每个 `entryFor(m.key) != null` 的成员 `endSession(m.key, quiet: true)`；`ended` = 返回真的个数，`shared` = 其中 `projectsOf(key).length > 1` 的个数；`hint = endAllHint(p.name, ended, shared)`；`notifyListeners()`。全部结束不改面板。
  - `projects_tab.dart`：`open-all-<id>` → `openAll(id)`，在 `!hubUsable || members.isEmpty` 时灰掉；`end-all-<id>` → `endAll(id)`，在没有成员 `entryFor` 不为 `null` 时灰掉（K18）。

- [ ] **Step 1: 写失败的测试**

`projects_test.dart`（纯函数）：
```dart
final p = Project('p', '写周报', [
  Member(const AppRef('111', 'a', 'Calculator')),   // open already
  Member(const AppRef('111', 'b', 'Notes')),        // disconnected → reconnect
  Member(const AppRef('222', 'c', 'Chess')),        // offline → skip
  Member(const AppRef('222', 'd', 'Mail')),         // offline → skip
  Member(const AppRef('111', 'e', 'Safari')),       // not open → open
]);
final lamps = {'111/a': Lamp.active, '111/b': Lamp.disconnected};
test('plan: open, reconnect, skip and stop', () {
  final plan = planOpenAll(p, lampOf: (k) => lamps[k], offline: (d) => d == '222');
  expect(plan.open.map((m) => m.key), ['111/b', '111/e']);
  expect(plan.first, '111/a');
  expect(plan.skipped, {'222': 2});
  expect(openAllHint(p, plan, (id) => id == '222' ? 'studio' : 'mini'), '写周报：打开 2 个；studio 离线，跳过 2 个');
});
```
其余：
- `plan: a connecting member counts as open`：`lampOf` 给 `Lamp.connecting` → 不进 `open`，可以是 `first`。
- `plan: all offline has no first`：所有成员都在离线设备上 → `first == null`，提示 `写周报：mini 离线，跳过 N 个`。
- `hint: nothing to do`：全开着 → `'写周报：已经全部打开'`；没成员 → `'写周报：没有成员'`。
- `end all hints`：`endAllHint('写周报', 3, 1) == '写周报：结束 3 个会话，其中 1 个也属于别的项目'`；`(…, 2, 0) == '写周报：结束 2 个会话'`；`(…, 0, 0) == '写周报：没有要结束的会话'`。

`main_state_test.dart`，嵌入（放进 `group('embedded sessions')`，用 `env(…, sessions: 0)`（`env` 不发 hosts，`deviceName` 会是 id）；body 一开头 `t.emit({'event':'hosts','hosts':[{'id':'111','name':'mini'},{'id':'222','name':'studio'}]}); a.flushMicrotasks();`，离线用 `st.probes['222'] = DeviceProbe(Lamp.offline, '离线')`；opener 给 sid = app 长度）：
- `open all mixes open, reconnect, skip and stop`（Review Focus 4）：项目成员 `111/a`、`111/aa`、`222/aaa`、`111/aaaa`；先 `openOrSwitch('111','a',…)`、`openOrSwitch('111','aa',…)`，再让 `aa` 断开（`port.emit(DisconnectedEvent(2, 'connection closed'))`）；`st.togglePanel(PanelTab.projects)`；记下 `opens` 数；`st.openAll(id); a.flushMicrotasks();` → 新发的 open 正好 2 条：`aa` 带 `reconnect: true`、`aaaa` 不带；没有 `aaa` 的 open；`st.currentKey == '111/a'`；`st.panel == null`；`hints.last == '<名>：打开 2 个；studio 离线，跳过 1 个'`；之后没有「已打开」提示（`hints` 里没有以 `已打开` 开头的）。
- `open all twice sends each open once`（Review Focus 4）：opener 不回答（`t.onSend` 换成只记录）；两个没开的成员；`openAll` 两次 → open 命令一共 2 条；第二次的提示是 `<名>：已经全部打开`。
- `open all stops on the first member even when its open fails`：opener 对第一个成员回 `error`；→ `currentKey` 是第一个成员，它的记录是已断开（S3 R9），出失败提示。
- `a disconnected member shows its reason`：Task 3 留下的状态断言：断开后 `memberStatus(m) == '已断开：网络断了'`。
- `end all hint survives late closed events`（Review Focus 5）：两个成员都活动；`endAll` → `port.calls` 里两条 `close`；`hints.last == '<名>：结束 2 个会话'`；`port.emit(ClosedEvent(1, 'stdin closed')); port.emit(ClosedEvent(2, 'stdin closed')); a.flushMicrotasks();` → `st.hint` 不变，`entryFor` 两个都 `null`。
- `end all counts sessions shared with another project`（Review Focus 5）：成员 `111/a` 同时在项目 A、B；A 还有 `111/aa`；`endAll(A)` → `'A：结束 2 个会话，其中 1 个也属于别的项目'`；B 的成员 `111/a` 也没了会话。
- `end all ends connecting and disconnected members at once`：一个连接中（opener 不回答）、一个已断开 → 两个记录立刻没了，提示 `结束 2 个会话`；之后那个 open 回来时被安静 `close`（S3 R14），提示不变。
- `reopening after end all hints normally`：`endAll` 后 `ClosedEvent` 到了；再 `openOrSwitch` 同一个 → 出 `已打开 …`；再 `endCurrent` → 收到 `ClosedEvent` 后出 `已结束 …`（`_batchEnded` 已经清掉）。

`main_state_test.dart`，S1 路径（文件顶层，用 `s`、`t`）：
- `open all on the S1 path opens pending entries once`：两个成员都没开、`t.onSend` 不回答；`openAll` → 两条 open，`entryFor` 两个都是 `Lamp.connecting`，`currentKey` 是第一个；再 `openAll` → 仍是两条。
- `end all on the S1 path closes by sid and stays quiet`：两个会话开着（`opened` 1、2）；`endAll` → `t.sent` 里 `close` sid 1、2；`hint == '<名>：结束 2 个会话'`；`t.emit({'event':'closed','sid':1})`、`t.emit({'event':'closed','sid':2})` 之后 `hint` 不变。
- `end all skips an S1 entry still opening`：一个成员 pending → 不发 close，提示 `<名>：没有要结束的会话`。
- `endCurrent still hints as before`：`opened` 1 后 `select`，`endCurrent()` → `hint == '正在结束 Safari'`（现有行为回归）。

`projects_tab_test.dart`：
- `全部打开 is primary and disabled without members`：没成员时 `tester.widget<…>(find.byKey(Key('open-all-<id>')))` 的 `onPressed == null`；按钮是 `RappButton` 的 primary 样式（照 `controls_test` 现有的判断方式）。
- `全部结束 needs two taps and is disabled with no sessions`：没会话时灰掉；有一个会话时点一次 → `find.text('再点一次确认')`、`t.sent` 里没有 `close`；再点 → 有 `close`。
- `全部打开 closes the panel`：`s.togglePanel(PanelTab.projects)`，一个没开的成员，点 `open-all-<id>` → `s.panel == null`。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/projects_test.dart test/ui/main_state_test.dart test/ui/projects_tab_test.dart` → `planOpenAll`、`openAll` 未定义。
- [ ] **Step 3: 实现** 上面的函数和改动。先把 `openOrSwitch`、`endCurrent` 改成走 `_open`、`endSession`，跑一次全量测试确认没有回归，再加 `openAll`/`endAll`/`_batchEnded`。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。对一遍 §0 三条检查（只出一行提示；跳过的设备不进「需要你」）。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/projects.dart gui/lib/ui/main_state.dart gui/lib/ui/projects_tab.dart gui/test/ui/projects_test.dart gui/test/ui/main_state_test.dart gui/test/ui/projects_tab_test.dart`，`feat(gui): open all and end all for a project`

---

### Task 6: 按项目分组、顶栏第二行

**Files:**
- Modify: `gui/lib/ui/session_model.dart`（`Grouping.project`、`groupSessions`、`stepKey`）、`gui/lib/ui/projects.dart`（`projectSubtitle`）、`gui/lib/ui/main_state.dart`（`groups` 传项目；`setGrouping`）、`gui/lib/ui/sessions_tab.dart`（`byDevice`）、`gui/lib/ui/top_bar.dart`（`_sub`）
- Test: `gui/test/ui/session_model_test.dart`、`gui/test/ui/projects_test.dart`、`gui/test/ui/side_panel_test.dart`、`gui/test/ui/top_bar_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `Project`/`Member`；Task 3 的 `projects`、`projectsOf`。
- Produces:
  - `enum Grouping { device, app, project }`；`groupingLabel(Grouping.project) == '按项目'`。分组标签栏自动多一个 `Key('group-project')`。
  - `List<SessionGroup> groupSessions(List<SessionEntry> all, Grouping g, {List<Project> projects = const []})`——`project`：每个项目一组（标题 = 项目名，组内按成员顺序，只列 `all` 里有的；空组不出），然后 `其他` 一组放不在任何项目里的会话（组内按设备、app 名排序，和按设备时一样）；没有就不出（K15）。另两种分组不变。
  - `stepKey`：先 `LinkedHashSet` 去重 key 再走（K15）。
  - `MainState.groups => groupSessions(_entries, grouping, projects: projects)`。`_endRecord`、`_onHub` 里用到 `groups`/`stepKey` 的地方自动跟着。
  - `sessions_tab.dart`：`byDevice: state.grouping == Grouping.device` 不变（按项目时也显示设备名，K21）。
  - `String? projectSubtitle(SessionEntry e, List<Project> projects)`（`projects.dart`）——`e.key` 不在任何项目里返回 `null`；否则 K16 的文字。
  - `top_bar.dart` `_sub(e)`：先 `projectSubtitle(e, state.projects) ?? <现在的规则>`；可访问标签用同一个结果。

- [ ] **Step 1: 写失败的测试**
- `session_model_test.dart`：
  - `project grouping follows project and member order, 其他 last`：`e('mini','Notes')`、`e('mini','Safari')`、`e('studio','Chess')`；项目 `P1` 成员 [Safari, Notes]，项目 `P2` 成员 [Notes]，项目 `P3` 成员 [不在列表里的 app] → 组标题 `['P1', 'P2', '其他']`；`P1` 的 key 顺序 Safari、Notes；`P2` 只有 Notes；`其他` 只有 Chess。（成员 `AppRef` 的 `device`/`bundle` 要和 `e()` 生成的 `id`/`app` 对上，测试里照 helper 写。）
  - `project grouping with no projects puts everything in 其他`。
  - `stepKey visits a session listed twice once`（Review Focus 3）：上面的分组，从 Safari 起 `stepKey(groups, k, 1)` 依次 → Notes → Chess → Safari（回绕）；从 Chess `-1` → Notes。
  - `grouping labels`：`groupingLabel(Grouping.project) == '按项目'`。
- `projects_test.dart` `project subtitle`：不在项目里 → `null`；在 `写周报` 里、无任务 → `'mini · 写周报'`；在 `写周报`（无任务）和 `发版`（任务 `跑测试`）里 → `'mini · 写周报等 · 跑测试'`；第一个项目有任务 `整理 PR` → `'mini · 写周报等 · 整理 PR'`。
- `side_panel_test.dart`：
  - `a session in two projects shows in both groups`：两个项目都含 `111/com.apple.Safari`，`open(tester, 1, 'com.apple.Safari')`，点 `group-project` → `find.byKey(Key('session-111/com.apple.Safari'))` `findsNWidgets(2)`；两行都带选中描边时一样（点其中一行 → `s.currentKey` 是它，面板收起）。
  - `three grouping chips fit a 400 wide window`：400×500 下打开会话标签不溢出（扩展现有 `no overflow on a 400x500 window`）。
- `top_bar_test.dart`：
  - `second line shows device, project and task`：会话 `111/com.apple.Safari` 开着并是当前，项目 `写周报` 含它、任务 `整理 PR` → `find.text('mini · 写周报 · 整理 PR')`；可访问标签里也有。
  - 现有 `mini · 局域网` 的测试不变（不在项目里）。
- `main_state_test.dart` `step walks project groups without sticking`（Review Focus 3）：三个会话开着，其中一个在两个项目里；`setGrouping(Grouping.project)`；连续 `step(1)` 四次 → `currentKey` 依次经过三个不同的 key 再回到起点，中间没有相邻两次相同。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/session_model_test.dart test/ui/projects_test.dart test/ui/side_panel_test.dart test/ui/top_bar_test.dart test/ui/main_state_test.dart` → `Grouping.project`、`projectSubtitle` 未定义。
- [ ] **Step 3: 实现** 上面的改动。`session_model.dart` import `workspace_store.dart`（纯 Dart，没有循环依赖）。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿；跑 runner 编译检查 `cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`（只编译）。对一遍 §0 三条检查。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/session_model.dart gui/lib/ui/projects.dart gui/lib/ui/main_state.dart gui/lib/ui/sessions_tab.dart gui/lib/ui/top_bar.dart gui/test/ui/session_model_test.dart gui/test/ui/projects_test.dart gui/test/ui/side_panel_test.dart gui/test/ui/top_bar_test.dart gui/test/ui/main_state_test.dart`，`feat(gui): group sessions by project and show it in the top bar`

---

### Task 7: 实机检查、打包、记录

**前提：只在用户明确同意后做（用户同意把这台 Mac 让出来一段时间）。** 用户中途在用（焦点被抢、GUI 被关）就停下，把没做的条目记"待实机"，不反复把自己的窗口提到前面。全程守 Global Constraints 的安全规则。

**Files:**
- Modify: `tasks/todo.md`（S5 一行改成完成，下面按规格 §5 每条一行，写验证方式和结果）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-s5-projects-favorites-design.md` 状态行后加"S5 已实现（计划 `docs/superpowers/plans/2026-11-12-rapp-s5-projects-favorites.md`）"
- Modify: `tasks/lessons.md`（只在这次真学到东西时加）

- [ ] **Step 1: 全量验证** — `flutter analyze`、`flutter test`；`cargo test --workspace`、`cargo clippy --workspace --all-targets`（Rust 没改，应和 S3 结束时一样：117 过、0 警告）；`swift test`、`./scripts/check.sh` 末行 `EXIT=0`。
- [ ] **Step 2: 搭环境（只用自己起的进程，每个都记 PID 文件）** — 复用 scratchpad `s2live/` 的布局（`A`、`B`、`bin`，临时端口，不用 47800、21116–21119），换上 `flutter build macos --release`（`FLUTTER_XCODE_ARCHS=arm64`）的 GUI，`RAPP_HOME` 指向 scratchpad 里的配置目录（**不是**用户真的配置目录），写 `gui.pid`。点击一律先 `s2live/topatp X Y $(cat gui.pid)`，返回的 PID 等于 `gui.pid` 才点；发键前确认最前 app 的 unix id 等于 `gui.pid`；截图只截自己的窗口。目标 app：`pgrep -x Calculator` 为空才 `open -g -a Calculator`，紧接着记新 PID 到 `calc.pid`；已在跑就跳过需要它的条目并记下来。第二个成员用另一台自己起的 host 上的 app，或同一台上的另一个自己拉起的 app（同样先 `pgrep -x` 确认没在跑）。
- [ ] **Step 3: 逐条对规格 §5 检查**（每条截一张自己窗口的图存 `s2live/s5-*.png`）：
  1. 设备面板给 Calculator「设为常用」→ 会话列表最后出现「常用」组，一行未打开（虚线框）；点它 → 打开、面板收起；「结束会话」点两次 → 它回到「常用」组。
  2. 建项目、加两个成员、给一个成员写任务；「全部打开」→ 两个都打开，停在第一个，面板收起；顶栏第二行 `<设备> · <项目名> · <任务>`；「全部结束」点两次 → 两个都结束，提示写 `结束 2 个会话`。
  3. 一个会话放进两个项目 → 「按项目」时在两组里各出现一次；顶栏上一个/下一个不卡住。
  4. 停掉第二个成员所在的自己起的 host（按 PID），等它变离线 → 「全部打开」提示 `<设备> 离线，跳过 1 个`。
  5. 退出 GUI（按 PID）再起 → 常用、项目、任务都还在。
  6. 退出 GUI，把 scratchpad 配置目录里的 `workspace.json` 写成 `{x`，再起 → 提示 `项目和常用没有读到，已从空白开始`，目录里有 `workspace.json.bad`，GUI 正常可用。
  7. 不点剪贴板条目、不按「复制」「插入」、不 ⌘V。
- [ ] **Step 4: 收尾** — 按 PID 文件逐个 `kill` 自己起的 GUI、Calculator（还在的话）、hub、host/service、relay；`ps -p` 确认都没了。
- [ ] **Step 5: 打包** — `scripts/package-macos.sh`；不替换 `/Applications/rapp.app`，不重启已装的 rapp-service。
- [ ] **Step 6: Commit** — `git add tasks/todo.md docs/superpowers/specs/2026-11-12-rapp-s5-projects-favorites-design.md`（改了 lessons 再加 `tasks/lessons.md`），`docs: S5 done — live check, todo, spec status`

---

## Self-review

- **规格覆盖**：§2.1 设为常用/取消常用（Task 2）、「常用」组在最后、未打开灯 + 虚线框 + app 名 + 设备名、点一下打开（Task 2，K9）、打开后到所在设备组、结束后回来（Task 2 测试，`idleFavorites` 由 `_entries` 算）、删设备删常用（Task 1，K19）。§2.2 第三个标签 720（Task 4，C1）、卡片标题行名字点击改名 + 成员灯（Task 4）、全部打开/全部结束（Task 5）、成员行 `<app> @ <设备>`、任务单行可编辑、状态、打开/切到/重连、移出（Task 4，K10、K14）、新建项目回车（Task 4）、添加 app 列出在线设备的 app + 常用、可以进多个项目（Task 3、4，K7）、删除项目点两次只删项目（Task 3、4）、全部打开的四条规则和跳过提示（Task 5，K11、K12）、全部结束含共享会话 + 计数（Task 5，K12、K13）。§2.3 第三种分组、「其他」、一个会话多组出现（Task 6，K15）、顶栏第二行（Task 6，K16）。§2.4 文件位置、格式、坏文件 `.bad` + 提示、写失败提示 + 内存保留（Task 1，K2–K4）。§3 只改 Dart、新文件 `workspace_store.dart`、hub 不变（Architecture；另加 `projects.dart`、`projects_tab.dart`、`inline_edit.dart`）。§4 拆分 1–4 → Task 1/2、3/4、5、6。§5 验收 → Task 7 第 3 步逐条（6 条全有）。§6 五条：多项目（K7）、全部结束含共享（Task 5 测试）、删项目不结束会话（Task 3 测试）、纯文本（K6）、本机不同步（只有本地文件）。
- **占位扫描**：没有 TBD。测试里"照现有写法"的地方都点了现有测试名（`hub gone`、`devices_tab_test` 的 `remove` 回答、`controls_test` 的按钮样式判断），实现者 grep 一下即可。
- **类型一致**：`AppRef.key`、`Member.key`、`SessionEntry.key`、`SessionRecord.key` 都是 `'$device/$bundle'` = `'$id/$app'`；`planOpenAll` 的 `lampOf` 返回 `Lamp?`，和 `entryFor(k)?.lamp` 一致；`openVerb(Lamp?)` 在 Task 2 定义、Task 4 使用；`OpenPlan.skipped` 的 key 是设备 id，`openAllHint` 用 `deviceName` 翻成名字；`projectSubtitle` 在 Task 6 定义，只有 `top_bar.dart` 用；`PanelTab.projects` 在 Task 4 定义，Task 5 的测试用它；`_open`、`endSession` 在 Task 5 定义，`openOrSwitch`、`endCurrent` 改成调它们。
- **Review Focus**：五条的测试名都写在 Task 1（1、2）、Task 6（3）、Task 5（4、5）的 Step 1 里。
- **比例**：只给签名、规则、测试名和断言、精确文字；代码块只有两段测试骨架。
