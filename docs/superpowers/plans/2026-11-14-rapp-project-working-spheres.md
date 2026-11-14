# 项目：切换、回来、排列 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有的项目功能（S5）上补齐：从现状一步建成项目、切到项目并停在上次的会话、回来的线索、固定、回到上一个项目、排列的偏好、删后可撤销。

**Architecture:** 只动 GUI（Dart）。项目本身的数据（含"固定"）在同步的 `shared/workspace.json`；排列偏好在每台设备自己的 `gui.json`；每个项目上次停在哪、何时离开，在不进 git 的 `local/project_positions.json`（它每次切换都会变，放进 git 会让数据目录每分钟提交一次）。判断逻辑写成 `lib/ui/projects.dart` 里的纯函数，`MainState` 只负责状态和存盘，界面只读状态。

**Tech Stack:** Flutter 3.44（Dart），现有的 `MainState`（ChangeNotifier）、`workspace_store.dart`、`prefs.dart`；测试用 `flutter_test`，不引入新包。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-project-design.md`（已确认）。下文的"§""G""W""P"都指它。现有功能见 `docs/superpowers/specs/2026-11-12-rapp-s5-projects-favorites-design.md`。

**范围：** 规格 §4–§6、§8、§9、§11 的 G1–G12。**不在这里的**：§7 专注时的打扰规则（rapp 还没有专注模式，等专注的规格）；外部小屏显示固定的项目。

## Global Constraints

- 项目是可选的：没有任何项目、没有任何偏好文件时，所有现有测试照常通过，界面上不多出任何提示或引导（P4）。
- rapp 不提议分组：不新增任何"建议""推荐"字样或逻辑（P2）。
- 项目里只存四样：名字、成员、每个成员一行备注、是否固定（§4）。不加别的字段。
- `workspace.json` 的 `version` 仍是 1；`pinned` 是可省略的字段，缺了当 false。成员备注在文件里的键仍是 `task`，只改界面上的叫法。
- 界面上的词只用这些，不换说法：`存成项目`、`切到`、`固定`、`取消固定`、`加入项目`、`撤销`、`备注`、`未归项目的`、`设备在前`、`项目在前`、`上一个项目`。
- 回来的线索不用强调色、不闪，5 秒后消失（§6.2；设计语言"只有等你会闪"）。
- 可点的控件高度不小于 48px（设计语言 §6）。
- 写文件沿用现有做法（`saveWorkspace`、`UiPrefs.save`）；写失败时内存里的照常用，并给出现有格式的提示。
- 每个任务结束时：`cd gui && $HOME/development/flutter/bin/flutter analyze` 无问题，`$HOME/development/flutter/bin/flutter test` 全过。
- 提交信息沿用仓库的写法：`feat(gui): …`、`test(gui): …`、`docs: …`。

## Review Focus

规格没有明说、测试里要钉住的五种情况：

1. **位置记录里的项目已经不存在**（在别的设备上删了，同步过来）：启动时丢掉这条位置记录；它是当前项目时退回到"没有当前项目"，不报错。（任务 2、4）
2. **停在的那个会话已经结束**：切到项目时退到第一个开着的成员；一个都没开就不选任何会话，仍然算切到了这个项目。（任务 3、4）
3. **时钟往回走，或者记下的离开时间在将来**：不显示线索，不显示负数。（任务 3）
4. **什么都没开着时点"存成项目"**：按钮不可用；状态里的函数返回 null，不建空项目。（任务 5、6）
5. **连删两个项目再撤销**：只恢复最后删的那个，放回原来的位置；5 秒后不能撤销；撤销后已经存盘。（任务 5）

---

## File Structure

```
gui/lib/ui/workspace_store.dart   Modify：Project 加 pinned；读写
gui/lib/ui/prefs.dart             Modify：UiPrefs 加 first；读写
gui/lib/ui/project_positions.dart Create：每个项目上次停在哪、何时离开；读写 local/project_positions.json
gui/lib/ui/projects.dart          Modify：resumeKey、returnCue、orderedProjects、projectKeys
gui/lib/ui/session_model.dart     Modify：未归项目的；当前项目排在最前；项目内步进
gui/lib/ui/main_state.dart        Modify：当前项目、上一个项目、线索、存成项目、固定、撤销
gui/lib/ui/projects_tab.dart      Modify：存成项目、切到、固定、删后撤销、备注、空状态
gui/lib/ui/top_bar.dart           Modify：项目名、线索、上一个项目
gui/lib/embed/stream_menu.dart    Modify：会话一组里加"加入项目"
gui/lib/ui/sessions_tab.dart      Modify：当前项目那一组在最前；点组名切到
gui/lib/ui/side_panel.dart        Modify：排列的选择；标签顺序
gui/lib/ui/overview_model.dart    Modify：项目格的顺序
gui/lib/ui/overview.dart          Modify：两排的顺序
gui/test/ui/*_test.dart           各任务对应的测试文件（都已存在，往里加）
```

---

### Task 1: 项目加"固定"

**Files:**
- Modify: `gui/lib/ui/workspace_store.dart`
- Test: `gui/test/ui/workspace_store_test.dart`

**Interfaces:**
- Produces: `class Project { Project(this.id, this.name, [List<Member>? members, this.pinned = false]); bool pinned; … }`。`toJson` 里每个项目多一个 `'pinned': p.pinned`；`fromJson` 里 `pinned` 缺了当 false，不是布尔值时抛 `FormatException`（和别的坏字段一样处理）。

- [ ] **Step 1: 写失败的测试**

```dart
test('pinned round-trips and defaults to false', () {
  final w = Workspace(projects: [Project('p', '写周报', [], true), Project('q', '发版')]);
  final back = Workspace.fromJson(jsonDecode(jsonEncode(w.toJson())));
  expect(back.projects.map((p) => p.pinned), [true, false]);
  final old = Workspace.fromJson({'version': 1, 'projects': [{'id': 'p', 'name': 'x', 'members': []}]});
  expect(old.projects.single.pinned, isFalse);
});
test('a pinned that is not a bool is a bad file', () {
  expect(() => Workspace.fromJson({'version': 1, 'projects': [{'id': 'p', 'name': 'x', 'pinned': 'yes'}]}), throwsFormatException);
});
```

- [ ] **Step 2: 跑测试确认失败** — `cd gui && $HOME/development/flutter/bin/flutter test test/ui/workspace_store_test.dart`
- [ ] **Step 3: 实现。**
- [ ] **Step 4: 跑测试确认通过**（同一条命令）。
- [ ] **Step 5: 提交** — `git add gui/lib/ui/workspace_store.dart gui/test/ui/workspace_store_test.dart && git commit -m "feat(gui): projects can be pinned"`

### Task 2: 偏好：排列；位置

**Files:**
- Modify: `gui/lib/ui/prefs.dart`
- Create: `gui/lib/ui/project_positions.dart`
- Test: `gui/test/ui/prefs_test.dart`；Create: `gui/test/ui/project_positions_test.dart`

**Interfaces:**
- Produces（`prefs.dart`）：`enum FirstLayer { device, project }`；`UiPrefs({…, this.first = FirstLayer.device})`，字段 `FirstLayer first`。`gui.json` 新增 `"first": "device"` 或 `"project"`；不认识的值当 `device`。`save` 要把现有的 `theme`、`start_fullscreen` 一起写出。
- Produces（`project_positions.dart`）：

```dart
const positionsFile = 'project_positions.json';
class ProjectPosition { ProjectPosition({this.last, this.leftAt}); String? last; DateTime? leftAt; }   // last 是会话的 key（"<设备>/<bundle>"）
class ProjectPositions {
  ProjectPositions([Map<String, ProjectPosition>? byProject]);
  final Map<String, ProjectPosition> byProject;              // 键是项目 id
  ProjectPosition of(String projectId);                       // 没有就建一个空的放进去
  void dropExcept(Set<String> projectIds);
  static ProjectPositions load(String dir);                   // 从不抛错：文件没有或坏了就是空的
  void save(String dir);                                      // 先写临时文件再改名；抛 FileSystemException
}
```

  文件内容：`{"version":1,"projects":{"<项目 id>":{"last":"111/com.apple.Safari","left_at":"2026-11-14T01:02:03.000Z"}}}`，`left_at` 是 UTC 的 ISO 8601。读的时候，某一项格式不对就跳过这一项，其余照常。`dir` 是数据目录的 `local/`（`DataDir.localDir`）。

- [ ] **Step 1: 写失败的测试**

```dart
// prefs_test.dart
test('first round-trips, defaults to device, and keeps the old fields', () {
  final dir = Directory.systemTemp.createTempSync();
  final p = UiPrefs(first: FirstLayer.project)..save(dir.path);
  final back = UiPrefs.load(dir.path);
  expect(back.first, FirstLayer.project); expect(back.theme, p.theme); expect(UiPrefs().first, FirstLayer.device);
});
test('an unknown first is device', () { /* 写 {"first":"sideways"} → device */ });
// project_positions_test.dart
test('round-trip', () {
  final dir = Directory.systemTemp.createTempSync();
  final a = ProjectPositions();
  a.of('p')..last = '111/a'..leftAt = DateTime.utc(2026, 11, 14, 1, 2, 3);
  a.save(dir.path);
  final b = ProjectPositions.load(dir.path);
  expect(b.byProject['p']!.last, '111/a'); expect(b.byProject['p']!.leftAt, DateTime.utc(2026, 11, 14, 1, 2, 3));
});
test('missing or corrupt file is empty; a malformed entry is skipped', () {
  /* 目录里没有文件 → 空；写 "{" → 空；写 {"version":1,"projects":{"p":{"last":7},"q":{"last":"1/a","left_at":"nope"},"r":{"last":"2/b"}}}
     → 只有 q（last "1/a"，leftAt null）和 r（last "2/b"） */
});
test('dropExcept forgets deleted projects', () {            // Review Focus 1
  final p = ProjectPositions({'p': ProjectPosition(last: 'x'), 'gone': ProjectPosition(last: 'y')});
  p.dropExcept({'p'});
  expect(p.byProject.keys, ['p']);
});
```

- [ ] **Step 2–4:** 跑失败（`flutter test test/ui/prefs_test.dart test/ui/project_positions_test.dart`）→ 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(gui): layer order in gui.json, per-project position in local/"`

### Task 3: 纯函数：从哪里接着、线索、顺序

**Files:**
- Modify: `gui/lib/ui/projects.dart`、`gui/lib/ui/session_model.dart`
- Test: `gui/test/ui/projects_test.dart`、`gui/test/ui/session_model_test.dart`

**Interfaces:**
- Produces（`projects.dart`）：

```dart
/// 切到项目时停在哪个会话：last 还是成员且开着就用它；否则第一个开着的成员；都没开是 null。
String? resumeKey(Project p, String? last, bool Function(String key) isOpen);

/// 回来的线索；不该显示时是 null。
String? returnCue({required DateTime? leftAt, required DateTime now, required int needs, required int disconnected});

/// 固定的在前，其余在后；各自保持原来的顺序。
List<Project> orderedProjects(List<Project> all);

/// 这个项目的成员的 key，按成员顺序。
List<String> projectKeys(Project p);
```

  `returnCue` 的规则：`leftAt` 为 null、在 `now` 之后、或离 `now` 不到 60 秒 → null。时间部分：不到 60 分钟写 `N 分钟前离开`；不到 24 小时写 `N 小时前离开`；否则 `N 天前离开`（都向下取整）。`needs`、`disconnected` 都是 0 时只有时间部分；否则接 ` · 这期间 `，再接 `A 个等你`、`B 个已断开` 中不为 0 的，两个都有时用顿号隔开。
- Produces（`session_model.dart`）：
  - `const otherGroupTitle = '未归项目的';`（原来是 `'其他'`）
  - `groupSessions(all, g, {projects, String? first})`：按项目分组时，`first` 指的那个项目排在最前，其余按 `orderedProjects` 的顺序；`未归项目的` 仍在最后。
  - `String? stepKey(groups, current, delta, {List<String>? within})`：`within` 不为 null 时只在这些 key 里（并且是开着的）循环；`current` 不在其中时，`delta` 为正从第一个开始、为负从最后一个开始。

- [ ] **Step 1: 写失败的测试**

```dart
group('resumeKey', () {
  final p = Project('p', 'x', [Member(const AppRef('1', 'a', 'A')), Member(const AppRef('1', 'b', 'B')), Member(const AppRef('2', 'c', 'C'))]);
  test('last if still a member and open', () => expect(resumeKey(p, '1/b', (k) => true), '1/b'));
  test('first open member when last is closed', () => expect(resumeKey(p, '1/b', (k) => k == '2/c'), '2/c'));   // Review Focus 2
  test('first open member when last left the project', () => expect(resumeKey(p, '9/z', (k) => true), '1/a'));
  test('null when nothing is open', () => expect(resumeKey(p, '1/b', (k) => false), isNull));                    // Review Focus 2
});
group('returnCue', () {
  final now = DateTime.utc(2026, 11, 14, 12);
  String? cue(Duration ago, [int n = 0, int d = 0]) => returnCue(leftAt: now.subtract(ago), now: now, needs: n, disconnected: d);
  test('minutes, hours, days', () {
    expect(cue(const Duration(minutes: 25)), '25 分钟前离开');
    expect(cue(const Duration(minutes: 119)), '1 小时前离开');
    expect(cue(const Duration(hours: 49)), '2 天前离开');
  });
  test('what changed', () {
    expect(cue(const Duration(minutes: 25), 1), '25 分钟前离开 · 这期间 1 个等你');
    expect(cue(const Duration(minutes: 25), 0, 2), '25 分钟前离开 · 这期间 2 个已断开');
    expect(cue(const Duration(minutes: 25), 1, 2), '25 分钟前离开 · 这期间 1 个等你、2 个已断开');
  });
  test('nothing under a minute, without a time, or with a time in the future', () {                              // Review Focus 3
    expect(cue(const Duration(seconds: 59)), isNull);
    expect(returnCue(leftAt: null, now: now, needs: 3, disconnected: 0), isNull);
    expect(returnCue(leftAt: now.add(const Duration(hours: 1)), now: now, needs: 0, disconnected: 0), isNull);
  });
});
test('orderedProjects: pinned first, order kept', () {
  final ps = [Project('a', 'A'), Project('b', 'B', [], true), Project('c', 'C'), Project('d', 'D', [], true)];
  expect(orderedProjects(ps).map((p) => p.id), ['b', 'd', 'a', 'c']);
});
// session_model_test.dart
test('by project: the current project first, then pinned, then the rest, 未归项目的 last', () { /* 三个项目（第二个固定）+ 一个不属于任何项目的会话；first 指第三个 → 组名顺序 [第三个, 第二个, 第一个, '未归项目的'] */ });
test('by project without a current project: pinned first', () {});
test('stepKey within a project wraps and ignores sessions outside it', () { /* within ['1/a','2/c']：从 '1/a' +1 → '2/c'，再 +1 → '1/a'；current 是项目外的 '9/z' 时 +1 → '1/a'，-1 → '2/c' */ });
```

- [ ] **Step 2–4:** 跑失败（`flutter test test/ui/projects_test.dart test/ui/session_model_test.dart`）→ 实现 → 跑通过。现有测试里断言 `'其他'` 的地方改成 `otherGroupTitle`。
- [ ] **Step 5: 提交** — `git commit -m "feat(gui): resume point, return cue and project order as pure functions"`

### Task 4: 状态：当前项目、上一个项目、线索

**Files:**
- Modify: `gui/lib/ui/main_state.dart`
- Test: `gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: 任务 2、3 的全部。
- Produces（`MainState`）：

```dart
String? currentProject;                 // 项目 id；null 是没有当前项目
String? previousProject;
String cue = '';                        // 回来的线索；空串是不显示
static const cueFor = Duration(seconds: 5);

void switchProject(String id);          // 切到项目
void backToPreviousProject();           // 没有上一个时什么都不做
void leaveProject();                    // 回到没有当前项目
```

  - 新字段 `final ProjectPositions positions`，构造时 `ProjectPositions.load(data.localDir)`。下文的 `positions[id]` 都指 `positions.of(id)`；"存位置"指 `positions.save(data.localDir)`，写失败时只记日志，不提示。
  - 构造函数里把现有的 `clock` 参数存成字段 `_now`（缺省 `DateTime.now`）；启动后 `positions.dropExcept(<现有项目 id>)`；`grouping` 的初值在 `prefs.first == FirstLayer.project` 时是 `Grouping.project`。
  - `switchProject(id)`：项目不存在就返回。若已有当前项目且不是它：给旧项目记 `leftAt = _now()`、`last = currentKey`（`currentKey` 是它的成员时才记 `last`），旧项目成为 `previousProject`。然后 `currentProject = id`，`grouping = Grouping.project`，`currentKey = resumeKey(p, positions[id]?.last, 开着的)`，`panel = null`，`overview = false`。线索：`cue = returnCue(leftAt: positions[id]?.leftAt, now: _now(), needs: …, disconnected: …) ?? ''`；`cue` 不为空时起一个 `cueFor` 的定时器把它清空。最后存位置、`notifyListeners()`。
  - 线索里的两个数：这个项目的成员里，现在的灯是"等你"/"已断开"、并且是在 `leftAt` 之后变成这样的。为此 `MainState` 维护 `Map<String, DateTime> _attentionSince`：一个会话的灯变成等你或已断开的那一刻记 `_now()`，变回别的就删掉（放在现有计算 `_entries` 的地方）。
  - `leaveProject()`：给当前项目记位置，`previousProject = currentProject`，`currentProject = null`，存位置。
  - `select(key)`（已有）：`key` 不是当前项目的成员时，先 `leaveProject()`。是成员时只更新 `positions[当前项目].last`（不立刻存盘，下次离开时存）。
  - `step(delta)`（已有）：有当前项目时用 `stepKey(groups, currentKey, delta, within: projectKeys(p))`。
  - `groups`（已有）：把 `first: currentProject` 传给 `groupSessions`。
  - `deleteProject`（已有）：删的是当前项目或上一个项目时把对应的字段清成 null；并 `positions.byProject.remove(id)`。
  - 当前会话结束（已有的收尾逻辑）之后，有当前项目时不改 `currentProject`。

- [ ] **Step 1: 写失败的测试**（用假时钟：`MainState(…, clock: () => now)`，`now` 是测试里的变量）

```dart
test('switching lands on the session last used in that project', () { /* 项目 P 有 a、b 两个开着的成员；切到 P（停在 a）；select(b)；切到 Q；再切回 P → currentKey == b 的 key */ });
test('switching away records when and where, and it survives a restart', () { /* 切到 P，now 前进 25 分钟后切到 Q → 用同一个 DataDir 新建 MainState，positions.byProject['P'] 的 last 和 leftAt 都在 */ });
test('coming back shows the cue for five seconds', () { /* fakeAsync：切到 P；切到 Q；时钟 +25 分钟；切回 P → cue == '25 分钟前离开'；elapse(cueFor) 后 cue == '' */ });
test('the cue counts members that started waiting while away', () { /* 离开 P 之后，P 的一个成员变成等你 → 回来时 cue 以 ' · 这期间 1 个等你' 结尾；离开之前就在等你的不算 */ });
test('first switch to a project has no cue', () {});
test('back to the previous project and back again', () { /* P → Q → backToPreviousProject → currentProject == P，previousProject == Q；再调一次回到 Q */ });
test('backToPreviousProject without one does nothing', () {});
test('selecting a session outside the current project leaves the project', () { /* currentProject 变 null，previousProject 是它，位置已记 */ });
test('stepping stays inside the current project', () { /* P 有 a、c 开着，另有项目外的 z 开着 → step(1) 在 a、c 之间循环，不到 z */ });
test('a project with nothing open can still be switched to', () { /* currentKey == null，currentProject == P */ });          // Review Focus 2
test('positions of projects that no longer exist are dropped at start', () { /* local/project_positions.json 里有 gone 的位置，workspace.json 里没有这个项目 → 启动后 positions.byProject 不含 gone */ });   // Review Focus 1
test('deleting the current project clears it', () { /* currentProject == null；不抛错 */ });                                // Review Focus 1
test('project-first preference starts grouped by project', () { /* UiPrefs(first: FirstLayer.project) → s.grouping == Grouping.project */ });
test('with no projects nothing changes', () { /* 默认状态：currentProject、previousProject 为 null，cue 为空，grouping == device */ });
```

- [ ] **Step 2–4:** 跑失败（`flutter test test/ui/main_state_test.dart`）→ 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(gui): current project, previous project and the return cue"`

### Task 5: 状态：存成项目、固定、删后撤销

**Files:**
- Modify: `gui/lib/ui/main_state.dart`
- Test: `gui/test/ui/main_state_test.dart`

**Interfaces:**
- Produces（`MainState`）：

```dart
bool get canSaveOpenAsProject;                   // 至少有一个会话开着
Project? saveOpenAsProject(String name);         // 名字为空或没有开着的会话 → null，什么都不变
void togglePinned(String projectId);
static const undoFor = Duration(seconds: 5);
String? get undoableDelete;                      // 可撤销时是那个项目的名字，否则 null
void undoDelete();
```

  - `saveOpenAsProject`：成员是 `entries` 里的全部会话（现在列表里的顺序），每个成员的 `AppRef` 取会话的设备 id、bundle、app 名，备注为空。建好后 `switchProject` 到它。
  - `deleteProject`（已有）改成：记下被删的项目和它在列表里的位置，起一个 `undoFor` 的定时器；到时清掉。再删一个时，前一个的撤销机会作废。`undoDelete` 把它插回原位置（位置超出当前长度就放最后）、存盘、清掉记录。
  - `togglePinned`：翻转 `pinned`，存盘。

- [ ] **Step 1: 写失败的测试**

```dart
test('save what is open as a project and switch to it', () { /* 开着 a、b → saveOpenAsProject('写周报') 返回的项目成员 key 是 [a, b]；currentProject 是它；workspace.json 里有它 */ });
test('nothing open: cannot save, returns null, creates nothing', () { /* canSaveOpenAsProject == false；返回 null；projects 仍为空 */ });   // Review Focus 4
test('an empty name creates nothing', () {});
test('togglePinned persists', () { /* 新建 MainState 后 pinned 仍为 true */ });
test('a deleted project can be undone for five seconds and goes back where it was', () { /* 三个项目 A B C，删 B → undoableDelete == 'B'；undoDelete → 顺序仍是 A B C，成员和备注都在，文件里也在 */ });
test('after five seconds it is gone for good', () { /* fakeAsync：elapse(undoFor) → undoableDelete == null；undoDelete 什么都不做 */ });
test('deleting a second project forfeits the first undo', () { /* 删 A 再删 B → undoDelete 只恢复 B；A 不回来 */ });                         // Review Focus 5
test('undo saves', () { /* 撤销后新建 MainState，项目在 */ });                                                                              // Review Focus 5
```

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(gui): save open sessions as a project, pin, undoable delete"`

### Task 6: 项目页

**Files:**
- Modify: `gui/lib/ui/projects_tab.dart`
- Test: `gui/test/ui/projects_tab_test.dart`

**Interfaces:**
- Consumes: 任务 4、5 的状态。
- 行为（给控件的 `Key` 写在括号里，测试靠它找）：
  - 顶部一行：「新建项目」（已有）和「存成项目」（`Key('save-open')`）。后者在 `canSaveOpenAsProject` 为 false 时不可点。点了以后出现一个输入框（沿用新建项目的那个），回车调 `saveOpenAsProject`。
  - 没有任何项目时，页面上只有这一行，没有说明文字（G12）。
  - 卡片按 `orderedProjects` 的顺序。当前项目的卡片边框用选中样式（设计语言 §2："当前选中的行，边框用 `--text` 并加 1px 内描边"）。
  - 每张卡的标题行多两个按钮：「切到」（`Key('switch-<id>')`，调 `switchProject`）和「固定」/「取消固定」（`Key('pin-<id>')`）。
  - 「删除项目」改成点一次就删（不再是 `ConfirmButton`）。删后页面顶部出现一行：`已删除「<名字>」` 和「撤销」（`Key('undo-delete')`），`undoableDelete` 变 null 时消失。
  - 成员行的「移出」保持点一次（确认它现在不是 `ConfirmButton`；是的话改掉）。
  - 成员那一行文字的占位从"Agent 任务"相关的文案改成 `备注`（G11）。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('no projects: only the two buttons, no guidance', (t) async { /* 找得到「新建项目」「存成项目」；页面上没有其他 Text */ });
testWidgets('存成项目 is disabled with nothing open and creates a project when something is', (t) async {});   // Review Focus 4
testWidgets('pinned projects come first; the pin button toggles its label', (t) async {});
testWidgets('切到 switches and marks the card as current', (t) async {});
testWidgets('delete is one tap, shows 撤销, and 撤销 brings the card back', (t) async {});
testWidgets('the undo row disappears after five seconds', (t) async {});
testWidgets('the member note placeholder says 备注', (t) async {});
testWidgets('every new control is at least 48 high', (t) async { /* 对上面几个 Key 取 getSize，height >= 48 */ });
```

- [ ] **Step 2–4:** 跑失败（`flutter test test/ui/projects_tab_test.dart`）→ 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(gui): projects tab: save open, switch, pin, undoable delete"`

### Task 7: 顶栏、会话列表、流量菜单

**Files:**
- Modify: `gui/lib/ui/top_bar.dart`、`gui/lib/ui/sessions_tab.dart`、`gui/lib/embed/stream_menu.dart`
- Test: `gui/test/ui/top_bar_test.dart`、`gui/test/ui/main_window_test.dart`（会话列表和菜单的测试所在的文件；没有对应文件时在 `main_window_test.dart` 里加）

**Interfaces:**
- 行为：
  - **顶栏**：有当前项目时，当前会话的第二行开头是项目名（现有的 `projectSubtitle` 给出的是"设备 · 项目名"，保持）；`cue` 不为空时，第二行在这 5 秒里换成 `cue`（`Key('return-cue')`），文字用 `--muted`，不加粗、不闪。有 `previousProject` 时，在前后切换按钮旁边多一个按钮「上一个项目」（`Key('prev-project')`，可访问名称是 `上一个项目：<名字>`），调 `backToPreviousProject`。没有当前会话但有当前项目时，顶栏当前会话的位置显示项目名。
  - **会话列表**：按项目分组时，组名可以点（`Key('group-<项目 id>')`），点了 `switchProject`。`未归项目的` 那一组的组名不可点，不带数字。
  - **流量菜单**的"会话"一组，在「结束会话」上面加「加入项目」（`Key('add-to-project')`）：展开一个列表，列出所有项目（已经包含当前会话的不列），点一个调现有的 `addMember`；列表最后一项是「存成项目」。没有任何项目时，展开的列表里只有「存成项目」。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('the cue replaces the second line for five seconds, without accent or blink', (t) async { /* 取 Key('return-cue') 的 Text 的颜色 == tokens.muted；pump(cueFor) 后找不到 */ });
testWidgets('上一个项目 appears only when there is one and goes back', (t) async {});
testWidgets('with a current project and no session the bar names the project', (t) async {});
testWidgets('tapping a project group switches to it; 未归项目的 is not tappable and has no count', (t) async {});
testWidgets('加入项目 lists projects that do not have the session yet and adds on tap', (t) async {});
testWidgets('加入项目 with no projects offers only 存成项目', (t) async {});
```

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(gui): project in the top bar, tappable groups, add to project from the stream menu"`

### Task 8: 排列的偏好和全景

**Files:**
- Modify: `gui/lib/ui/side_panel.dart`、`gui/lib/ui/overview_model.dart`、`gui/lib/ui/overview.dart`、`gui/lib/ui/main_state.dart`
- Test: `gui/test/ui/side_panel_test.dart`、`gui/test/ui/overview_model_test.dart`、`gui/test/ui/overview_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Produces：`MainState.setFirst(FirstLayer f)`：改 `prefs.first`、存偏好、`notifyListeners()`；**不改**当前的 `grouping`（§8：临时切换分组不受影响，偏好只决定启动时的默认）。
- Produces：`List<PanelTab> tabOrder(FirstLayer f)`（放在 `side_panel.dart`）：`device` → `[sessions, devices, projects, resources]`；`project` → `[sessions, projects, devices, resources]`。
- 行为：
  - 左侧面板底部，主题下拉旁边加一个下拉（`Key('first-dropdown')`），两项：`设备在前`、`项目在前`。
  - 面板标签按 `tabOrder(prefs.first)` 排。
  - 全景：`prefs.first == project` 时，项目那一排在设备墙上面；否则照现在。项目格按 `orderedProjects` 的顺序。

- [ ] **Step 1: 写失败的测试**

```dart
test('tabOrder', () { expect(tabOrder(FirstLayer.device), [PanelTab.sessions, PanelTab.devices, PanelTab.projects, PanelTab.resources]);
                      expect(tabOrder(FirstLayer.project), [PanelTab.sessions, PanelTab.projects, PanelTab.devices, PanelTab.resources]); });
test('setFirst persists and leaves the current grouping alone', () { /* grouping 先设成 app；setFirst(project) → grouping 仍是 app；新建 MainState 后 prefs.first == project 且 grouping == project */ });
testWidgets('the dropdown shows 设备在前 by default and switches the tab order', (t) async {});
testWidgets('overview: projects row above the device wall when projects come first', (t) async { /* 比较两个区域的 getTopLeft().dy */ });
testWidgets('overview: pinned projects come first in the row', (t) async {});
```

- [ ] **Step 2–4:** 跑失败 → 实现 → 跑通过。
- [ ] **Step 5: 提交** — `git commit -m "feat(gui): choose which layer comes first; pinned projects first in the overview"`

### Task 9: 文档和整体检查

**Files:**
- Modify: `docs/superpowers/specs/2026-11-12-rapp-s5-projects-favorites-design.md`、`docs/superpowers/specs/2026-11-12-rapp-main-window-design.md`、`docs/superpowers/specs/2026-11-12-rapp-design-language.md`、`docs/superpowers/specs/2026-11-13-rapp-spec-roadmap.md`、`docs/superpowers/specs/2026-11-13-rapp-config-reference.md`、`tasks/todo.md`

- [ ] **Step 1: S5 规格**：文首加一行修订，指向 `2026-11-14-rapp-project-design.md` §11，列出 G1–G12 各改了 S5 的哪一条（"其他"改名、删除不再点两次、任务标签改叫备注……）。正文不重写。
- [ ] **Step 2: 主界面规格**：§3 左侧面板的表里，标签顺序写明"由排列偏好决定"；全景一节写明两排的顺序由排列偏好决定、固定的项目在前；顶栏一行补上线索和「上一个项目」。
- [ ] **Step 3: 设计语言 §0**：依据里加一段，工作域研究（González 和 Mark 2004；Mark 等 2005）：Calm Technology 讲信息待在边缘还是中心，工作域讲人以什么为单位切换。指向项目规格 §1。
- [ ] **Step 4: 路线图**：C2 专注那一节加一句：不能依赖项目，没有项目时退回到当前会话；专注时的打扰规则以项目规格 §7 为准。
- [ ] **Step 5: 配置规范总览**：`gui.json` 加 `first`；`workspace.json` 的项目加 `pinned`；程序自管的状态里加 `local/project_positions.json`。
- [ ] **Step 6: 整体检查** — `cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test`，全过。在 `tasks/todo.md` 加一节，列出本计划的任务和提交号，以及"未经实机验证"的一条：平板上各新控件的触控大小、线索的位置是否挡住别的东西。
- [ ] **Step 7: 提交** — `git commit -m "docs: project design in the S5 spec, main window spec, design language and config reference"`

---

## 规格覆盖对照

| 规格 | 任务 |
|---|---|
| §4 项目里只存四样；备注 | 1、6 |
| §5 存成项目、加入项目、移出、删后可撤销、没有项目时不引导、未归项目的 | 3、5、6、7 |
| §6.1 切到项目，停在上次的会话，不自动打开 | 3、4、6、7 |
| §6.2 回来的线索 | 3、4、7 |
| §6.3 固定 | 1、3、5、6、8 |
| §6.4 回到上一个项目 | 4、7 |
| §6.5 记住上次停在哪 | 2、4 |
| §8 排列的偏好 | 2、4、8 |
| §9 跨设备：项目同步，排列偏好每台设备各存，位置不同步 | 1（`workspace.json`）、2（`gui.json`、`local/project_positions.json`） |
| §11 G1–G12 | G1：5、6、7；G2：7；G3：4、6；G4：3、4、7；G5：1、5、6、8；G6：4、7；G7：2、8；G8：5、6；G9：6；G10：3、7；G11：6；G12：6 |
| §12 对其他文档的影响 | 9 |

不在这份计划里的：§7（等专注的规格）；外部小屏。
