# 手机外壳和只读首页（V1b）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal：** iOS 上 rapp 窗口短边小于 600 时，换成手机外壳：一个只读首页（等你的事一张卡片、其余一行），能进现有的终端视图和远程画面去看，有“设备”“设置”两页。开合、旋转、分屏来回切，会话状态一点不丢，A 的窗口和终端大小不变。

**Architecture：** 同一个 `MainState`，iOS 根上加一个 `FormSwitch`：Pad 形态挂现有的 `MainWindow`，手机形态挂 `PhoneShell`，两个外壳都只是 `MainState` 的视图。会话状态（草稿、终端内容、连接、画面纹理）本来就全在 `MainState` 和各个 port 里，不在组件里，所以拆掉一个外壳、装上另一个，什么都不重建（见“为什么这样切”）。手机形态下 `MainState` 多两个只加不改的开关：拦住改尺寸、让不在看的会话停收帧。首页的事从现有的 `needs` 加上终端列表 / 中心服务的会话行算出来，是一个纯函数。

**Tech Stack：** Flutter 3.44（`~/development/flutter/bin/flutter`），Dart，现有的 `RappTokens`、`StatusLamp`、`SessionBlock`、`TermStage`、`Picture`、`AccessSetup`、`IosLocalSection`、`StateSection`。

**Spec：** `docs/superpowers/specs/2026-11-27-rapp-iphone-v1-requirements.md`（V1b 的范围在 §17 那张表）。稿：`docs/superpowers/specs/2026-11-27-rapp-phone-mocks/`（`build_v1.py` 里是文案，`preview/index.html` 上半页）。方案：`docs/superpowers/specs/2026-11-27-rapp-phone-product-plan.md`。开工总览：`docs/superpowers/plans/2026-11-27-rapp-phone-v1b-kickoff.md`。

## 用户定的（2026-11-27）

- **只在 iOS 上按短边切。** 规格 F5 说“分档对所有平台生效”，和 Q8“桌面三个平台现有的行为不变”对不上；用户定：V1b 只在 iPhone / iPad / Duo 上切，macOS、Linux、Windows 一点不变。Mac 上开发时设环境变量 `RAPP_PHONE_FORM=1` 才挂 `FormSwitch`（Task 10）。widget 测试直接装 `FormSwitch`，不需要 F5。

## 为什么这样切（规格 §21 第一条）

考虑过三种：

1. **同一棵树里拆装外壳（选这个）。** `FormSwitch` 按尺寸只挂一个外壳。`MainWindow` 被拆掉时 `dispose` 只是摘监听（`main_window.dart:156`），装回来 `initState` 从 `MainState` 重新读；`Stage` 本来就会被 `Overview`、`LogScreen` 换下去，拆装是日常。草稿在 `RemoteSession.composer`，终端内容在 `TermSessionPort._terms[sid].model`，连接在 hub，全不在组件里。
2. 两个外壳都挂着，一个 `Offstage`。不行：`Offstage` 照样布局，`Stage` 的 `LayoutBuilder` 会拿手机尺寸调 `stageSize`，A 的窗口就被改了（违反 F11、S4）；两个外壳还会同时抢键盘焦点、同时开着 `TermStage`。
3. 用 `GlobalKey` 把 `Stage` 搬到手机外壳里。不需要：手机形态不挂 `Stage`（它是唯一会调 `stageSize` 的地方），“进去看”直接用 `TermStage` / `Picture`。

钉住它的测试：Task 4 的 `shell switch keeps session state`。

## Global Constraints

- F1：只看 rapp 自己窗口的大小。**短边小于 600 是手机形态，否则是 Pad 形态。** 常量就是 `ui/fullscreen.dart` 里已有的 `foldedShortSide = 600.0`，不另立一个。
- 只在 iOS（`main_ios.dart`）挂 `FormSwitch`；macOS 只在 `RAPP_PHONE_FORM=1` 时挂（用户定的）。
- Pad 形态的界面、行为一点不变；`gui/test/` 下已有的测试一条不改（Task 11 用 diff 核对）。
- F4：手机形态按竖排设计。窗口比 480 宽时，内容居中，最宽 480，两边留空，不拉伸。
- F11：进手机形态不发改尺寸；回 Pad 形态时，舞台大小连续 400 毫秒不变以后最多发一次，尺寸和 A 现在的一样就不发。
- F13：进手机形态时，Pad 形态开着的面板、菜单、全景都收起；回来时不恢复它们，只恢复 F8 说的位置。
- T1：手机外壳的每个组件只引用主题 token，代码里不写死颜色、圆角、字体。`gui/lib/phone/` 里不出现 `Color(`、`Colors.`、`BorderRadius.circular(<数字>)`、`fontFamily:`（Task 11 有一条测试扫这个目录）。
- T2 的对照表（照抄）：页面底 `bg`；卡片、列表的底 `panel`；普通按钮的底 `raise`，边 `line`；主按钮底 `text`，字 `bg`；在等你的卡片边 `accent`，底 `tint`；等你的件数、等你的灯 `accent`，上面的字 `accentInk`；命令原文 `mono`，字 `on`；次要的字、空心的灯 `muted`；在干活的灯、进度线 `on`，灯带 `glow`；底部升起的面板 `float`（不透明），上边 `line`；行与行之间的线 `line` 减淡；圆角 `r`。
- T3：强调色只表示“要你处理”。做完、出错、在干活都不用 `accent`。
- T5：MATRIX 下正文用 `monoBody`，卡片上的一句人话允许折成两行，不截断；按钮上的字不超过 6 个汉字。
- T8：`warn`、`danger` 卡片不用。T11：手机形态不用 `overviewArt`。
- Q2：所有可点的地方高不低于 56，主按钮 64；相邻两个可点处隔开至少 12。
- Q3 文案：断网时顶上一行 `连不上，通了自动恢复`。
- C3：一行里不放两个以上的按钮；卡片上不放“打开”按钮，点卡片上的字进“会话里面”。
- 这一期卡片上没有回复的按钮（允许、拒绝、选项、说一句都是 V1c）。没有项目过滤（V1d），H1 的标题固定写 `rapp`，H8 不做。
- 首页的文案（取自稿 `build_v1.py`，照抄）：`N 件等你`、`没有等你的。`、`M 个在干活 · 做完 K 件`、`刚才在：X`（稿上是 `刚才在 Chrome · mac2`，规格 F7 写的是“刚才在：X”，用规格的冒号）、`在干活的`、`其余 N 个`、`做完没看的`、`还有 N 件`、`我的设备`、`添加设备`、`它没说要做什么。点上面的字进去看。`、按钮 `进去看` / `重连` / `知道了`。
- 碰 `ui/main_state.dart`、`state/state_sync.dart`、`term/term_stage.dart`、`main_ios.dart`、`main.dart` 的任务：**合并前先 `git merge main`**，只加不改（每处都在任务里写明加在哪）。项目范围重构正在改 `main_state` 和项目相关文件。
- 机器上的规矩：`grep` 是 ugrep，用 `/usr/bin/grep`；flutter 在 `~/development/flutter/bin`；跑完测试 `git checkout gui/pubspec.lock`；提交按路径 `git add`，不用 `-A`、不用 `stash`；重的构建一个一个来。

## Review Focus

1. **窗口在 600 上下来回拖**（iPad 分屏拖分隔条、台前调度拉窗口）：形态不来回跳，停稳 `phoneFormSettle` 以后才换；整个过程 A 一次改尺寸都没有，停在 Pad 一侧时最多一次。测试：Task 4 `drag across 600 flips once after settle`、Task 1 `no resize while phone form`。
2. **开合到一半**（Duo 的过渡帧、短暂的中间尺寸）：中间尺寸不触发换外壳，也不触发 `stageSize`。测试：Task 4 `transitional sizes inside settle do nothing`。
3. **没有中心服务**：首页照样出等你的、出错、做完没看的；没有要中心服务才有的行（消息卡片）、没有空格子（N3、N4、验收 6）。测试：Task 3 `no service: local lists only`、Task 6 `home without service has no empty slots`。
4. **一个设备都没有的新用户**：没 key 走接入引导（N1）；有 key 没设备时首页是“我的设备”空着加“添加设备”（N2），不出现 `0 件等你` 这样的字。测试：Task 7 `new user sees access setup`、Task 6 `no devices shows add device`。
5. **`msg` 为空的卡片**（Codex 等确认、提问）：卡片照样有来源一行和“哪一种”，下面是 `它没说要做什么。点上面的字进去看。`，不留空行。测试：Task 3 `empty msg gets the go-look line`、Task 5 `card with empty msg lays out`。
6. **连不上**（hub 断网、中心服务连不上）：首页停在最后的内容，顶上一行 `连不上，通了自动恢复`，`重连`、`知道了` 这些要发东西出去的按钮变灰不能点；恢复后自动刷新（Q3）。测试：Task 6 `offline keeps last content and greys buttons`。

---

## 文件清单

新建（手机外壳都在 `gui/lib/phone/`，测试在 `gui/test/phone/`）：

| 文件 | 管什么 |
|---|---|
| `gui/lib/phone/form.dart` | `UiForm`、`formOf(Size)`、`phoneFormSettle`、`FormSwitch` 组件（防抖、开合时调落点） |
| `gui/lib/phone/landing.dart` | 开合的落点：`PadSpot`、`foldLanding`、`unfoldLanding` 纯函数（F6–F8、F13） |
| `gui/lib/phone/home_model.dart` | 首页的事：`HomeItem`、`HomeModel`、`buildHome` 纯函数（H2–H10、C17、I1/N3） |
| `gui/lib/phone/phone_nav.dart` | 手机外壳里在哪一页：`PhoneNav`（首页 / 会话里面 / 设备 / 设置），“刚才在”那一行，本次运行里点过“知道了”的集合 |
| `gui/lib/phone/widgets.dart` | 手机外壳的共用件：`PhonePage`（底色、最宽 480、安全区、断网一行）、`PhoneButton`（56 / 主按钮 64）、`PhoneRow`、`PhoneCard` |
| `gui/lib/phone/home_screen.dart` | 首页（H1–H11、F7、N2、N4、N5） |
| `gui/lib/phone/sheet.dart` | 点“rapp ▾”升起的面板，第一版只有“设备”“设置”两行 |
| `gui/lib/phone/devices_page.dart` | “设备”一页（P8），首页 N2 也用它的列表部分 |
| `gui/lib/phone/settings_page.dart` | “设置”一页（P7、T10、N5） |
| `gui/lib/phone/session_view.dart` | 会话里面（V1b 版）：文本终端用 `TermStage` 且 fit 恒为 false，图形用 `Picture`，断开用 `DisconnectedStage`；左上“返回” |
| `gui/lib/phone/phone_shell.dart` | `PhoneShell`：没 key 时 `AccessSetup`，否则按 `PhoneNav` 显示上面几页 |
| `gui/test/phone/*.dart` | 每个任务一份，外加 `matrix_test.dart`（尺寸 × 主题） |

修改（都只加不改）：

| 文件 | 加什么 |
|---|---|
| `gui/lib/ui/main_state.dart` | `phoneForm`、`phoneInSession`、`setPhone(...)`；`needsFromService`；三处判断各加一个条件（Task 1） |
| `gui/lib/state/state_sync.dart` | `sessionRows`、`markHandled(eid)`（Task 2） |
| `gui/lib/term/term_stage.dart` | 可选参数 `fit`（Task 8） |
| `gui/lib/main_ios.dart` | `home:` 换成 `FormSwitch`（Task 10） |
| `gui/lib/main.dart` | `RAPP_PHONE_FORM=1` 时挂 `FormSwitch`（Task 10） |
| `docs/superpowers/measurements/2026-11-27-rapp-phone-v1b-check.md` | 模拟器上的验收记录（Task 13） |

---

### Task 1: `MainState` 的手机形态开关

**Files:**
- Modify: `gui/lib/ui/main_state.dart`（只加）
- Test: `gui/test/phone/phone_flags_test.dart`

**Interfaces:**
- Produces:
  - `bool get phoneForm`、`bool get phoneInSession`（默认都 false）
  - `void setPhone({required bool form, bool inSession = false})`：值变了才 `notifyListeners()`。`form` 从 false 变 true 时，对 `remote.values` 每个调 `policy.cancel()`，并且 `closePanel()`、`closeCorner()`、`overview = false`、`logs = false`（F13；落点由 Task 4 先记下）。
  - `bool get needsFromService => _fromService;`
- 三处只加条件：
  - `_applyFps`（约 1479 行）的 `onStage`：再加上 `phoneForm && !phoneInSession` 时为 null（F15，用离屏暂停的现有办法）。
  - `_shownTerm`（约 752 行）：`phoneForm && !phoneInSession` 时返回 null（在首页上不算“看过”，不误标中心服务的 seen）。
  - `RemoteSession` 的 `onResize`（约 3160 行）：`if (_liveSid(s.sid) && !phoneForm)`。这是 A 改尺寸的唯一出口；`_syncPolicy` 在手机形态里换会话时照常喂旧的舞台大小（Pad 的），在这里被拦下。

- [ ] **Step 1: 合并前先 `git merge main`，再写测试**

照 `test/ui/main_window_test.dart` 的 `FakeTransport` + `HubClient` + `MainState` 的搭法，在 `onSend` 里记下所有 `cmd == 'resize'` 的命令（`resize` 走的是 hub 的哪个 cmd，照 `HubClient.resize` 的实现写）。测试：
- `no resize while phone form`：开一个图形会话、给它一个窗口（宽 1194 高 834），`stageSize(Size(1194, 834))`；`setPhone(form: true)`；`select` 另一个图形会话、等 1 秒：`resize` 一条都没有。
- `pad after phone resizes at most once`：接上，`setPhone(form: false)`，`stageSize(Size(1000, 700))`，等 1 秒：`resize` 正好 1 条；再 `stageSize(Size(1000, 700))` 等 1 秒：还是 1 条。
- `home pauses pictures`：`setPhone(form: true)` 后，`_sentFps` 发出去的帧率对当前会话是 0（看 `set_stream` / fps 命令，照 `test/ui/main_state_test.dart` 里离屏暂停那组测试的断言写）；`setPhone(form: true, inSession: true)` 后恢复成选的帧率。
- `phone home does not mark seen`：有 `FakeStateSync`（`test/fakes.dart:274`），当前是一个终端，`setPhone(form: true)`：`markSeen` 没被调；`setPhone(form: true, inSession: true)`：调了一次。
- `entering phone form closes panel and overview`：先 `showPanel(...)`、`overview = true`，`setPhone(form: true)`：`panel == null`、`overview == false`、`logs == false`。

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/phone/phone_flags_test.dart`
Expected: 编不过（`setPhone` 没有定义）。

- [ ] **Step 3: 照 Interfaces 加上**

- [ ] **Step 4: 跑这份和原来的 `main_state_test.dart`、`stage_test.dart`**

Run: `cd gui && ~/development/flutter/bin/flutter test test/phone/phone_flags_test.dart test/ui/main_state_test.dart test/ui/stage_test.dart && git checkout pubspec.lock`
Expected: 全过。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/ui/main_state.dart gui/test/phone/phone_flags_test.dart
git commit -m "feat(phone): MainState 加手机形态开关，拦住改尺寸、首页停收帧"
```

### Task 2: `StateSync` 给出会话行和“知道了”

**Files:**
- Modify: `gui/lib/state/state_sync.dart`（只加）
- Test: `gui/test/phone/state_sync_rows_test.dart`

**Interfaces:**
- Produces:
  - `Iterable<(String id, Row session)> get sessionRows`：`_devices` 里每台设备的 `_sessions(d)`，`id` 是设备的 9 位 id（`d['id']`），没有 id 的设备跳过。行里有 `session`、`state`、`seq`、`since`、`at`、`msg?`、`title?`、`name?`、`seen?`（见 `services/center/api/http.md`）。
  - `Future<void> markHandled(String eid)`：调 `_link?.seen(eid: eid, handled: true)`，没连上时什么都不做（不排队，Q4 不偷偷补发）。

- [ ] **Step 1: 合并前先 `git merge main`；写测试**

用 `FakeStateSync` 或直接喂一份 `/v1/state` 快照（照 `test/ui/state_p3_test.dart` 的写法）：两台设备、各两个会话，`sessionRows` 给出 4 条，id 对得上；`markHandled('fp:e1:3')` 让假 link 收到 `seen(eid: 'fp:e1:3', handled: true)`；断开时调 `markHandled` 不抛、link 没收到。

- [ ] **Step 2: 跑，确认失败** — `flutter test test/phone/state_sync_rows_test.dart`，Expected: 编不过。
- [ ] **Step 3: 加上两个成员**
- [ ] **Step 4: 跑这份和 `test/ui/state_*_test.dart`**，Expected: 全过；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `git add gui/lib/state/state_sync.dart gui/test/phone/state_sync_rows_test.dart`，`feat(phone): StateSync 给出会话行和 markHandled`

### Task 3: 首页的事（纯函数）

**Files:**
- Create: `gui/lib/phone/home_model.dart`
- Test: `gui/test/phone/home_model_test.dart`

**Interfaces:**
- Consumes: `NeedItem`、`NeedKind`（`main_state.dart`）；`TermList`、`TermRow`、`TermPs`（`hub_client.dart`）；`termPs`、`termAskWord`、`programWord`、`termLamp`（`ui/term_status.dart`）；`Lamp`；Task 2 的 `sessionRows` 的行格式。
- Produces:

```dart
enum HomeKind { waiting, error, done, disconnected, device, resource, message }

class HomeItem {
  final HomeKind kind;
  final String id;          // 一件事一个，C17：终端是 'term\n<设备 id>\n<终端 id>'，状态变了 id 不变
  final Lamp lamp;
  final String what;        // 哪一种：在等确认 / 在问你 / 出错了 / 做完了 / 断开了 / 离线 / 资源 / 消息
  final String program;     // 程序名或 app 名，没有时 ''
  final String device;      // 设备名
  final String line;        // 一句话；msg 为空时是 '它没说要做什么。点上面的字进去看。'（等你的）或 '做完了'（C8）
  final int since;          // 秒，排序用
  final String? sessionKey; // 进去看去哪：MainState 的 entry key；没有就点不进去
  final NeedItem? need;     // 来自 needs 的那件，“进去看”调 goToNeed 用
  final HomeButton button;  // goLook / reconnect / gotIt
  final String? eid;        // 消息卡片的队列行，“知道了”用
}
enum HomeButton { goLook, reconnect, gotIt }

class WorkRow { final String id, program, device; final int since; final double? progress; final String? sessionKey; }
class DoneRow { final String id, program, device, line; final int at; final String? sessionKey; }

class HomeModel {
  final List<HomeItem> items;   // H5 的先后
  final int waiting;            // H2 的 N：kind == waiting 的件数
  final List<WorkRow> working;  // H3 的 M、H7
  final int doneUnseen;         // H3 的 K
  final List<DoneRow> recentDone; // H7，最多 3 条，新的在前
}

HomeModel buildHome({
  required List<NeedItem> needs,                     // state.needs，本来就合了本机和中心服务
  required Map<String, TermList> lists,              // hub.termLists
  required Iterable<(String id, Map<String, Object?> row)> serviceSessions, // 没连中心服务时传空
  required Iterable<Map<String, Object?>> serviceRows, // stateSync.rows，没连传空
  required bool fromService,                         // state.needsFromService
  required Set<String> offline,                      // 离线的设备 id
  required Set<String> gotIt,                        // 这次运行里点过“知道了”的 HomeItem.id + 状态 seq
  required String Function(String id) deviceName,
  required String? Function(String device, String term) sessionKeyOf, // 找得到会话条目就给 key
});
```

**合并的规则（I1、N3，写进文件头注释）：**
- 等你的、会话断开、设备离线、资源提醒：只从 `needs` 来。`needs` 已经是“本机能算的本机算，中心服务只补本机没有终端列表的设备”（`_serviceNeeds`，`main_state.dart:1640`），手机不另合一遍。
- 出错、做完没看：同一条规则。设备在 `lists` 里（本机拿得到它的终端列表）就用 `TermRow`：`ps.state` 是 `error`，或 `done` 且 `unread`。不在 `lists` 里、`fromService` 为真，才看 `serviceSessions`：`state` 是 `error` / `done`，且 `seen` 没有或比 `at` 早。
- 消息：只在 `fromService` 时，从 `serviceRows` 里取 `t == 'emit'`、`level` 是 `ask` / `info` / `done`、没有 `handled` 的行；同一个 `key` 后来有 `clear` 的不出。
- 一个终端只出一件（C17）：同一个 `id` 已经有等你的，就不再出它的出错 / 做完。
- `gotIt` 里有的（id + seq）不出：本机没有中心服务时“知道了”清不掉 rapp-term 的 unread（那要进终端看），所以手机自己记住这一次运行里点过的；状态的 seq 变了就重新出。

**先后（H5）：** 等你的（`since` 小的在前，即等得最久的在前）→ 出错 → 做完没看 → 会话断开 → 消息 → 设备离线、资源提醒。同一组里 `since` 小的在前。

**按钮：** 等你的、出错、消息里 `level == ask`：`goLook`；会话断开：`reconnect`；做完、设备离线、资源、其余消息：`gotIt`。

- [ ] **Step 1: 写测试**（每条一个 `test`，数据直接构造 `NeedItem` / `TermList`）
  - `order follows H5`：一件做完（since 10）、一件出错（since 20）、两件等你（since 30、5）、一台离线：`items.map((i) => i.kind)` 是 `[waiting(5), waiting(30), error, done, device]`。
  - `one terminal one item`：同一个终端既 `blocked` 又 `unread`：只出一件 `waiting`。
  - `no service: local lists only`：`fromService: false`，`serviceSessions` 里有一条 `done`：不出；`serviceRows` 里有 emit：不出。
  - `service fills devices without a list`：设备 B 不在 `lists`、`serviceSessions` 有它一条 `error`，`fromService: true`：出一件 `error`，`device == deviceName('B')`；设备 A 在 `lists` 里，`serviceSessions` 也有它一条 `done`：不出（用本机的）。
  - `empty msg gets the go-look line`：`blocked`、`kind == 'permission'`、`msg == ''`：`line == '它没说要做什么。点上面的字进去看。'`，`what == '在等确认'`；`done`、`msg` 为空：`line == '做完了'`。
  - `got it hides until seq changes`：`gotIt` 里有它（seq 3）：不出；同一终端 seq 4：又出。
  - `counts`：3 件等你、5 个 `working`、2 件做完没看：`waiting == 3`、`working.length == 5`、`doneUnseen == 2`；`recentDone` 最多 3 条、新的在前。
- [ ] **Step 2: 跑，确认失败**：`flutter test test/phone/home_model_test.dart`，编不过。
- [ ] **Step 3: 写 `buildHome`**。`what` 的字：`termAskWord` 给的是现有的说法，这里照稿只要“在等确认 / 在问你 / 出错了 / 做完了”，用 `ps.kind`（`permission` → 在等确认，`question` → 在问你，`auth` → 要登录，其余 → 在等你）。
- [ ] **Step 4: 跑，确认通过**；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `git add gui/lib/phone/home_model.dart gui/test/phone/home_model_test.dart`，`feat(phone): 首页的事，本机和中心服务合成一张表`

### Task 4: 形态切换和开合的落点

**Files:**
- Create: `gui/lib/phone/form.dart`、`gui/lib/phone/landing.dart`
- Test: `gui/test/phone/form_test.dart`、`gui/test/phone/landing_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `setPhone`；Task 3 的 `HomeModel.waiting`；`foldedShortSide`（`ui/fullscreen.dart`）。
- Produces:

```dart
// form.dart
enum UiForm { pad, phone }
UiForm formOf(Size s) => s.shortestSide < foldedShortSide ? UiForm.phone : UiForm.pad;

/// 暂定 250 ms。探查 1 的 Duo 开合序列出来以后由 Task 12 改；不低于 100 ms
/// （回 Pad 时它加上 ResizePolicy 的 300 ms 才够 F11 的 400 ms）。
const phoneFormSettle = Duration(milliseconds: 250);

class FormSwitch extends StatefulWidget {
  const FormSwitch({super.key, required this.state, required this.pad, required this.phone,
      this.settle = phoneFormSettle});
  final MainState state;
  final WidgetBuilder pad, phone;
  final Duration settle;
}

// landing.dart
class PadSpot { const PadSpot({required this.overview, required this.key}); final bool overview; final String? key; }
enum PhoneScreen { home, session }
({PhoneScreen screen, String? cameFrom}) foldLanding({required PadSpot spot, required bool padInSession,
    required int waiting, required bool cameFromIsWaiting});
({bool overview, String? key}) unfoldLanding({required PadSpot spot, required String? phoneEntered});
```

`FormSwitch` 的规则：
- 第一帧照当前尺寸直接定形态，不等（启动时不闪）。
- 之后尺寸变了，形态跟着变的话，起一个 `settle` 的计时；计时里尺寸又变了就重新计；计时到了、形态和现在不同才换。计时里尺寸回到原来形态那一侧就取消。
- 换到手机前：记下 `PadSpot(overview: state.overview, key: state.currentKey)` 和 Pad 是不是在会话里（`!overview && current != null`），调 `state.setPhone(form: true, inSession: …)`，再用 `foldLanding` 定手机落点交给 `PhoneNav`（Task 6）。
- 换回 Pad 前：用 `unfoldLanding` 得到位置，先 `setPhone(form: false)`，再设 `overview` / `select(key)`，然后同一帧挂上 `pad`。顺序是为了让 `_syncPolicy` 先拿旧舞台大小判一次（和 A 一样就不发），新舞台大小再走 300 ms 的计时，合起来最多一次。

`foldLanding`（F6、F7）：`waiting > 0` → 首页，`cameFrom` = Pad 在会话里时是那个会话的 key，那个会话自己就是等你的（`cameFromIsWaiting`）时为 null；`waiting == 0` 且 Pad 在会话里 → `session`；Pad 在全景 → 首页。

`unfoldLanding`（F8）：手机上进过别的会话（`phoneEntered != null`）→ `(overview: false, key: phoneEntered)`；否则回 `spot`。

- [ ] **Step 1: 写 `landing_test.dart`**：F6 的三种、F7 两种（X 自己等你 / 不等你）、F8 两种，各一个 `test`，断言返回值。
- [ ] **Step 2: 写 `form_test.dart`**（`tester.view.physicalSize`，`devicePixelRatio = 1`，`pad` / `phone` 各放一个带 `Key('pad')` / `Key('phone')` 的 `Text`）：
  - `first frame picks form at once`：599×800 一开始就是 `phone`；600×800 一开始就是 `pad`。
  - `drag across 600 flips once after settle`：从 700×800 开始，每 16 ms 一帧在 590 / 610 之间来回换 20 次、停在 590；停之前 `pad` 一直在；停后 `settle` 内还是 `pad`，过了是 `phone`；`setPhone` 一共只被调过一次 `form: true`（拿一个 `MainState` 的子类数次数，或者数 `phoneForm` 的变化）。
  - `transitional sizes inside settle do nothing`：Pad 1194×834 → 中间 500×834 停 100 ms → 回到 1194×834：一直是 `pad`，`setPhone` 没被调。
  - `shell switch keeps session state`（F9、F10、F14 钉在这里）：用 main_window_test 的搭法开一个终端会话、往 `RemoteSession.composer` 里写 `半句话` 并把光标放在第 2 个字后；`pad` 挂真的 `MainWindow`，`phone` 挂一个空的 `SizedBox`；1194×834 → 390×844 → 等过 `settle` → 1194×834 → 等过：同一个 `MainState` 实例；`composer` 的文字是 `半句话`、选区没变；`termPort.model(sid)` 是同一个对象（`identical`）；hub 的 `FakeTransport` 没有收到 `close` / `open`；`resize` 不超过 1 条。
- [ ] **Step 3: 跑，确认失败**。
- [ ] **Step 4: 写 `form.dart`、`landing.dart`**。
- [ ] **Step 5: 跑两份，确认通过**；`git checkout gui/pubspec.lock`。
- [ ] **Step 6: 提交** `git add gui/lib/phone/form.dart gui/lib/phone/landing.dart gui/test/phone/form_test.dart gui/test/phone/landing_test.dart`，`feat(phone): 按短边切外壳，防抖，开合落点`

### Task 5: 手机外壳的共用件

**Files:**
- Create: `gui/lib/phone/widgets.dart`
- Test: `gui/test/phone/widgets_test.dart`

**Interfaces:**
- Consumes: `RappTokens.of(context)`、`StatusLamp(Lamp, size:)`（`ui/lamp.dart`，形状已经照 T4：等你菱形、断开三角、在干活实心、空闲做完空心、离线点线圆）、`OfflineBar` 不用（它的样子是 Pad 的），Task 3 的 `HomeItem`。
- Produces:
  - `PhonePage({required Widget child, String? title, VoidCallback? onBack, bool offline = false})`：`ColoredBox(t.bg)`、`SafeArea`、`Center` + `ConstrainedBox(maxWidth: 480)`；`offline` 时顶上一行 `连不上，通了自动恢复`（字 `muted`）；`onBack` 不为空时左上一个 `返回`（56 高）。
  - `PhoneButton({required String label, VoidCallback? onPressed, bool primary = false})`：高 56，`primary` 时 64；普通底 `raise[0]`（AVATAR 的两色渐变照 T6 画 `raise`）、边 `line`；主按钮底 `text`、字 `bg`；`onPressed == null` 时整个 0.4 不透明、不响应。字不截断（T5、T12）。
  - `PhoneRow({required HomeItem item, required VoidCallback onTap})`：高不低于 56；灯 + `what · program · device` 一行，`line` 在右或下（照稿 1.1 的行）。
  - `PhoneCard({required HomeItem item, required VoidCallback? onOpen, required VoidCallback? onButton})`：第一行来源（C1：灯、哪一种、程序名、设备名）；下面 `line`；一个按钮（C3：最多一个）；等你的卡片边 `accent`、底 `tint`，其余底 `panel`；点 `line` 和来源一行调 `onOpen`（`sessionKey == null` 时不可点）。`Semantics(label: …)` 读成一句话（Q7）：`'${item.what}，${item.program} 在 ${item.device}，${item.line}'`，灯 `ExcludeSemantics`。

- [ ] **Step 1: 写测试**（三套主题各一遍，用 `themeDataFor(theme)` 包，390×844）：
  - `buttons are tall enough`：`PhoneButton` 高 56，`primary` 64。
  - `card with empty msg lays out`：Task 3 给出的 `msg` 为空的等你项，渲染出来有来源一行、`它没说要做什么。点上面的字进去看。`、`进去看` 按钮，没有空 `Text('')`。
  - `waiting card uses accent edge`：等你的卡片 `BoxDecoration.border` 的颜色等于 `t.accent`、底色等于 `t.tint`；做完的卡片底色等于 `t.panel` 的第一个、边不是 `accent`（T3）。
  - `card reads as one sentence`：`tester.getSemantics(find.byType(PhoneCard))` 的 label 等于上面那句。
  - `page centers at 480`：844×390 下 `PhonePage` 的子组件宽 480，左右各 182。
  - `matrix wraps not truncates`：MATRIX、`textScaler: TextScaler.linear(1.5)`、375×667，一句 40 个汉字的 `line`：没有溢出，`Text` 的 `overflow` 不是 `ellipsis`。
- [ ] **Step 2: 跑，确认失败**。
- [ ] **Step 3: 写 `widgets.dart`**。
- [ ] **Step 4: 跑，确认通过**；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `git add gui/lib/phone/widgets.dart gui/test/phone/widgets_test.dart`，`feat(phone): 页面、按钮、行、卡片`

### Task 6: 首页和手机里的导航

**Files:**
- Create: `gui/lib/phone/phone_nav.dart`、`gui/lib/phone/home_screen.dart`
- Test: `gui/test/phone/home_screen_test.dart`

**Interfaces:**
- Consumes: Task 3 `buildHome`、Task 4 落点、Task 5 共用件、Task 7 的 `DeviceList`（N2。**执行顺序：Task 7 先于 Task 6**；Task 7 测试里要的 `PhoneNav` 先用 Task 6 Interfaces 里的签名建一个最小版，Task 6 再补全）、`state.goToNeed(NeedItem)`、`state.select(key)`、`state.reconnect…`（断开会话的重连，照 `NeedsYouAnchor` 里 `NeedKind.session` 的那一下写，`ui/needs_you.dart`）、`state.snoozeLoad…`（资源的“知道了”，照 `needs_you.dart` 里 `NeedKind.resource` 的那一下）。
- Produces:

```dart
enum PhoneView { home, session, devices, settings }
class PhoneNav extends ChangeNotifier {
  PhoneView get now;                // 现在哪一页；落点的 PhoneScreen.home/session 对应 PhoneView.home/session
  String? cameFrom;                 // F7 那一行
  String? entered;                  // 手机上进过的会话 key（给 unfoldLanding）
  final Set<String> gotIt;          // Task 3 的 gotIt
  void enter(String key);           // 进会话里面：state.select(key)、setPhone(form: true, inSession: true)、entered = key
  void home();                      // 回首页：setPhone(form: true, inSession: false)；cameFrom = null
  void open(PhoneView v);           // 设备、设置
}
class HomeScreen extends StatelessWidget { const HomeScreen({super.key, required this.state, required this.nav}); }
```

首页从上到下（H1–H11，稿 1.1–1.5）：
1. 顶上 `rapp ▾`（H1，56 高，点了 `showModalBottomSheet` 出 Task 7 的面板）。没有右上角按钮（H11）。
2. 断网一行（Q3，`PhonePage(offline: state.netDown || !state.hubUsable)`）。
3. 大字：`N 件等你`（N 用 `accent`）或 `没有等你的。`（H2）。
4. 小字：`M 个在干活 · 做完 K 件`；M 或 K 为 0 的那一半不写，两个都是 0 整行不出；点了滚到 H7 的列表（H3）。
5. `刚才在：X`（F7，`nav.cameFrom` 不为空时，点了 `nav.enter`）。点了任何一件事的按钮或离开首页，`cameFrom = null`。
6. 一张展开的卡片（`items.first`，或用户点开的那一件），其余每件一行，最多 5 行，多的收成 `还有 N 件`（点了展开全部）（H4、H6、H10）。点一行：它变成卡片，原来的卡片收回成行，不换页。
7. 没有等你的事时（H7）：`在干活的`，最多 3 行（名字、设备、干了多久；有进度就写百分比和一条 `on` 色的细线），多的 `其余 N 个`；`做完没看的` 列 `recentDone`。
8. 一件事都没有、也没有在干活的（N2）：`我的设备` 和 Task 7 的设备列表，最下面 `添加设备`。
9. 卡片离开（办完、被别的设备办了，C15 的显示部分）用 `AnimatedSwitcher` 往右滑走；`MediaQuery.disableAnimationsOf(context)` 时直接消失（H9）。
10. 没有底部标签栏（H11）；H12 的“按住说话”是 V1c，这一期不放（不留空位）。

按钮做的事：`goLook` → `state.goToNeed(item.need!)` 有 need 时，否则 `nav.enter(item.sessionKey!)`；然后 `nav.enter(state.currentKey!)`。`reconnect` → 照 `needs_you.dart` 的重连。`gotIt` → 加进 `nav.gotIt`；有 `eid` 时 `stateSync.markHandled(eid)`；终端做完且 `fromService` 时再 `stateSync.markSeen(device, term)`；资源 → 现有的暂缓。断网时 `reconnect`、`gotIt` 里要发东西出去的那几种 `onPressed` 为 null（Q3）。

- [ ] **Step 1: 写测试**（390×844，MATRIX；用 Task 3 的数据直接灌给 `HomeScreen` 背后的 `MainState`：照 `test/ui/needs_you_test.dart` 怎么造等你的事）
  - `count line`：3 件等你 → `3 件等你`；0 件 → `没有等你的。`。
  - `second line halves`：M=2、K=0 → `2 个在干活`，没有 `做完`；都是 0 → 这一行不在。
  - `one card rest rows`：4 件 → 1 张 `PhoneCard`、3 个 `PhoneRow`；点第 3 行 → 它成了卡片，原来的第 1 件成了行。
  - `at most eight taps`：12 件 → 1 张卡片、5 行、`还有 6 件`；首页上 `find.byWidgetPredicate` 数可点的（`InkWell`、`PhoneButton` 里有 `onPressed` 的）不超过 8（H10）。
  - `came from row`：`nav.cameFrom = 'X 的 key'` → 有 `刚才在：<X 的名字>`；点卡片的按钮以后它没了。
  - `home without service has no empty slots`：`stateSync == null`：没有 `消息` 字样、没有空的 `PhoneCard`、没有 `0 个`。
  - `no devices shows add device`：有 key、`hosts` 为空：有 `我的设备`、`添加设备`，没有 `件等你`。
  - `offline keeps last content and greys buttons`：先有 2 件等你，然后 `hub.net` 降到 down：卡片还在，顶上 `连不上，通了自动恢复`，`重连` 按钮的 `onPressed` 为 null；恢复后这一行没了。
  - `reduce motion removes at once`：`disableAnimations: true`，一件办完：下一帧就没了。
- [ ] **Step 2: 跑，确认失败**。
- [ ] **Step 3: 写 `phone_nav.dart`、`home_screen.dart`**。
- [ ] **Step 4: 跑，确认通过**；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `git add gui/lib/phone/phone_nav.dart gui/lib/phone/home_screen.dart gui/test/phone/home_screen_test.dart`，`feat(phone): 只读首页`

### Task 7: 面板、设备页、设置页、接入引导

**Files:**
- Create: `gui/lib/phone/sheet.dart`、`gui/lib/phone/devices_page.dart`、`gui/lib/phone/settings_page.dart`、`gui/lib/phone/phone_nav.dart`（最小版：Task 6 Interfaces 里的 `PhoneView`、`now`、`enter`、`home`、`open`）
- Test: `gui/test/phone/pages_test.dart`
- `new user sees access setup` 用到 `PhoneShell`，放到 Task 9 的测试里。

**Interfaces:**
- Consumes: `deviceColumns(...)`（`ui/overview_model.dart:57`，参数照 `overview.dart:51` 那样传）、`SessionBlock(state:, entry:, onTap:)`、`FavoriteBlock`、`AddDeviceForm(hub:, onAdded:)`、`IosLocalSection(hub:, prefs:, onPrefs:, data:, version:)`、`StateSection`（照 `main_window.dart` 的 `_iosLocal()` 传参）、`state.setTheme(RappTheme)`、`themeOrder`、`themeLabel`（`side_panel.dart:253` 用的那两个）、`AccessSetup(hub:, onDone:)`。
- Produces:
  - `showPhoneSheet(BuildContext, PhoneNav)`：底部升起，底 `float`（不透明），上边 `line`；两行 `设备`、`设置`，各 56 高。没有项目一段（P5：拿不到项目表时没有那一段；V1b 一律没有）。
  - `DeviceList({required MainState state, required PhoneNav nav})`：每台设备一个小标题（灯、名字、系统标记），下面它的 `SessionBlock` 和 `FavoriteBlock`，一列；每个用 `ConstrainedBox(minHeight: 56)` 包，**不改 `SessionBlock` 本身**（同一张卡只有一份实现）。点了 `SessionBlock` 自己会 `select` / `openStandby`，`onTap` 里再 `nav.enter(entry.key)`。最下面 `添加设备`，点了在下面展开 `AddDeviceForm`。
  - `DevicesPage({state, nav})`：`PhonePage(title: '设备', onBack: nav.home, child: DeviceList)`（P8）。
  - `SettingsPage({state, nav, data})`：`PhonePage(title: '设置')`，一列：主题（三个 56 高的选项 `AVATAR` / `MATRIX` / `WESTWORLD`，点了 `state.setTheme`）、`IosLocalSection`（接入点和 key、这台设备的名字、版本）、`StateSection`（中心服务连没连上，和它的说明，N5）、最后一行小字 `手机和展开后的 Pad 界面用同一个主题。`（T10）。
- 打开图形会话时不把 A 的窗口开成手机大小（S5a）：Task 1 已经在出口拦住，这里不另写。

- [ ] **Step 1: 写测试**（390×844，三套主题）
  - `sheet has two rows`：直接调 `showPhoneSheet` → 有 `设备`、`设置`，各高 ≥ 56，没有 `项目`、`助理`、`已处理`。
  - `device rows are 56`：两台设备各两个会话：每个 `SessionBlock` 外面那层高 ≥ 56；点一个 → `nav.now` 是会话里面、`state.currentKey` 是它。
  - `settings switches theme`：点 `WESTWORLD` → `state.prefs.theme == RappTheme.westworld`；有 `手机和展开后的 Pad 界面用同一个主题。`。
- [ ] **Step 2: 跑，确认失败**。
- [ ] **Step 3: 写这几个文件**。
- [ ] **Step 4: 跑，确认通过**；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `git add gui/lib/phone/sheet.dart gui/lib/phone/devices_page.dart gui/lib/phone/settings_page.dart gui/lib/phone/phone_nav.dart gui/test/phone/pages_test.dart`，`feat(phone): 面板、设备、设置、接入引导`

### Task 8: 会话里面（V1b 版）

**Files:**
- Create: `gui/lib/phone/session_view.dart`
- Modify: `gui/lib/term/term_stage.dart`（只加一个参数）
- Test: `gui/test/phone/session_view_test.dart`

**Interfaces:**
- Consumes: `TermStage(state:, session:, port:, frozen:, keyboard:)`、`Picture(state:, session:, window:, frozen:, keyboard:)`、`DisconnectedStage(...)`（选哪个照 `ui/stage.dart:90–130` 的判断写，**不挂 `Stage`**）、`PhoneNav.home`。
- Produces:
  - `TermStage` 加 `final bool? fit;`（默认 null）。`_sendView` 里原来用 `state.prefs.termFit` 的地方改成 `widget.fit ?? state.prefs.termFit`。Pad 不传，行为不变。
  - `PhoneSessionView({required MainState state, required PhoneNav nav})`：`PhonePage(onBack: nav.home)`；文本终端 `TermStage(fit: false, …)`：fit 为 false 的视图从不要求改尺寸（`rust/term/src/pty/fit.rs` 的 `a_fit_false_view_never_requests`），A 上的终端行列不变（S4、F11）；图形 `Picture`；断开 `DisconnectedStage`。`Scaffold(resizeToAvoidBottomInset: false)`，键盘盖在上面不挤（F12）。
  - 回 Pad 时 `Stage` 新挂的 `TermStage` 第一次发视图带 `prefs.termFit`（通常为 true），由 rapp-term 的“窗口跟谁”规则决定要不要改，和今天从全景回到会话一样。

- [ ] **Step 1: 合并前先 `git merge main`；写测试**
  - `phone terminal view never asks to fit`：用 `FakeTermSessionPort`（`test/fakes.dart:202`）记下 `view(...)` 的参数；390×844 挂 `PhoneSessionView`，当前是一个终端：所有 `view` 调用的 `fit` 都是 false；再改成 844×390：还是 false。
  - `pad terminal still follows pref`：照 `test/ui/stage_test.dart` 现有终端那条，`prefs.termFit = true`：`fit` 是 true（证明默认没变）。
  - `phone picture does not call stageSize`：当前是图形会话，挂 `PhoneSessionView`，过 1 秒：`FakeTransport` 没有 `resize`。
  - `back goes home`：点 `返回` → `nav.now` 是首页、`state.phoneInSession == false`。
- [ ] **Step 2: 跑，确认失败**。
- [ ] **Step 3: 加参数，写 `session_view.dart`**。
- [ ] **Step 4: 跑这份和 `test/ui/stage_test.dart`、`test/term/` 下的测试**，Expected: 全过；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `git add gui/lib/term/term_stage.dart gui/lib/phone/session_view.dart gui/test/phone/session_view_test.dart`，`feat(phone): 会话里面先用现有的终端和画面，不改 A 的尺寸`

### Task 9: `PhoneShell` 把几页接起来

**Files:**
- Create: `gui/lib/phone/phone_shell.dart`
- Test: `gui/test/phone/phone_shell_test.dart`

**Interfaces:**
- Consumes: Task 4–8 的全部。
- Produces: `PhoneShell({required MainState state, required PhoneNav nav, required DataDir data})`：没 key（照 `main_window.dart` 的 `_needsAccess`：`caps.hubInProcess && access.hasKey == false`）→ `AccessSetup`；否则按 `nav.now` 显示首页 / 会话里面 / 设备 / 设置。`PhoneNav` 由 `FormSwitch` 的持有者建（Task 10），活得和 app 一样长，换外壳不丢。

- [ ] **Step 1: 写测试**：`fold to home when something waits`（F6）：`FormSwitch(pad: MainWindow, phone: PhoneShell)`，Pad 在终端 X、另一个终端等你 → 1194×834 换到 390×844 → 首页，有 `刚才在：X`；`fold stays in session when nothing waits`：没有等你的 → 在 X 的会话里面；`unfold goes to entered`（F8）：手机上进了 Y → 换回 1194×834 → `state.currentKey == Y`、`overview == false`；`new user sees access setup`（N1）：`hub.access` 报没有 key → `PhoneShell` 里是 `AccessSetup`，排成一列，宽不超过 480，没有溢出。
- [ ] **Step 2: 跑，确认失败**。 **Step 3: 写 `phone_shell.dart`**。 **Step 4: 跑，确认通过**；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `git add gui/lib/phone/phone_shell.dart gui/test/phone/phone_shell_test.dart`，`feat(phone): 手机外壳接起来`

### Task 10: 接进 iOS 和 Mac 开发开关

**Files:**
- Modify: `gui/lib/main_ios.dart`（`runApp` 的 `home:`）、`gui/lib/main.dart`（主窗口那段的 `home:`，约 168 行）
- Test: `gui/test/phone/wiring_test.dart`

**Interfaces:**
- `main_ios.dart`：`home: FormSwitch(state: state, pad: (_) => MainWindow(…原样…), phone: (_) => PhoneShell(state: state, nav: nav, data: data))`，`nav` 在 `runApp` 前建一次。`FoldFullscreen`、`_WindowSize`、`BackgroundWatch` 都不动（F16）。
- `main.dart`：`Platform.environment['RAPP_PHONE_FORM'] == '1'` 时同样包一层，否则一个字节都不变（用户定的：只在 iOS 上切）。
- 切换器里盖住画面（Q5）是原生那层盖整个窗口，手机形态下盖的就是整个首页，不用改。

- [ ] **Step 1: 合并前先 `git merge main`；写测试** `desktop without the flag has no switch`：把 `main.dart` 里决定要不要包的那一句抽成 `bool phoneFormWanted(Map<String, String> env)`（放在 `phone/form.dart`），测 `{}` → false、`{'RAPP_PHONE_FORM': '1'}` → true、`{'RAPP_PHONE_FORM': '0'}` → false。
- [ ] **Step 2: 跑，确认失败**。 **Step 3: 改两个入口**。
- [ ] **Step 4: 编 iOS 模拟器包确认能起**（重的构建，拿锁）：`scripts/build-ios.sh` 的模拟器用法（看脚本头注释），Expected: 编过。
- [ ] **Step 5: 提交** `git add gui/lib/main_ios.dart gui/lib/main.dart gui/lib/phone/form.dart gui/test/phone/wiring_test.dart`，`feat(phone): iOS 上按短边切外壳，Mac 上 RAPP_PHONE_FORM=1 才切`

### Task 11: 尺寸 × 主题矩阵和回归

**Files:**
- Test: `gui/test/phone/matrix_test.dart`、`gui/test/phone/no_hard_colors_test.dart`

- [ ] **Step 1: 写 `matrix_test.dart`**：尺寸 `[Size(390, 844), Size(844, 390), Size(375, 667), Size(430, 932), Size(599, 800)]`（手机）和 `Size(600, 800)`（Pad），每个 × `RappTheme.values`，各挂 `FormSwitch`，造同一份数据（2 件等你、其中一件 `msg` 为空，1 件做完，1 台离线，3 个在干活），对首页、面板、设备、设置、会话里面各截一次：
  - `tester.takeException()` 为 null（没有溢出）；
  - 手机尺寸下 `find.byType(PhonePage)` 在，600×800 下 `find.byType(MainWindow)` 在；
  - 每个可点的（`InkWell`、`GestureDetector` 带 `onTap`、`PhoneButton`）`tester.getSize(...).height >= 56`；主按钮 ≥ 64；竖着相邻两个可点的间距 ≥ 12（Q2）；
  - T9 对比度：用 tokens 算 `text` / `muted` 对 `bg`、`panel[0]`、`tint` 的对比度都 ≥ 4.5（WCAG 公式写在测试里），主按钮的 `bg` 对 `text` 同样；
  - T12：再用 `TextScaler.linear(2.0)` 跑 375×667 一遍，没有溢出。
  - 留一个空位 `// Duo 外屏、内屏：Task 12 补`，不编数字。
- [ ] **Step 2: 写 `no_hard_colors_test.dart`**：读 `lib/phone/` 下所有 `.dart`，断言不含 `Color(`、`Colors.`、`fontFamily:`、`BorderRadius.circular(` 后面直接跟数字（T1）。
- [ ] **Step 3: 跑两份**；不过的回到对应任务改。
- [ ] **Step 4: 回归**：
  - `cd gui && ~/development/flutter/bin/flutter analyze` → No issues。
  - `cd gui && ~/development/flutter/bin/flutter test` → 全过。
  - `git diff main --stat -- gui/test ':!gui/test/phone'` → 空（原来的测试一条没改）。
  - `git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `git add gui/test/phone/matrix_test.dart gui/test/phone/no_hard_colors_test.dart`，`test(phone): 尺寸和主题矩阵，不写死颜色`

### Task 12: 补上 Duo 的尺寸和防抖（等探查 1）

**前提：** `docs/superpowers/measurements/2026-11-27-rapp-phone-v1a-1-duo.md` 里真机的数字已经填好（不是“待用户实机”）。没填就跳过这个任务，在 `tasks/todo.md` 记一条。

- [ ] **Step 1:** 从结论文档抄 Duo 外屏、内屏两个方向的逻辑尺寸，加进 `matrix_test.dart` 的尺寸表（外屏两种标成手机、内屏两种标成 Pad）。结论文档说 600 要改，**停下来问用户**（规格 F3 允许调，但改它会动 Pad 的分档）。
- [ ] **Step 2:** 按文档里“给 V1b 的常量”改 `phoneFormSettle`（保持 ≥ 100 ms），`form_test.dart` 的过渡帧测试照真机的序列（中间尺寸、帧数、毫秒）再加一条 `duo fold sequence flips once`。
- [ ] **Step 3:** 跑 `test/phone/`，全过；`git checkout gui/pubspec.lock`。
- [ ] **Step 4: 提交** `git add gui/lib/phone/form.dart gui/test/phone/matrix_test.dart gui/test/phone/form_test.dart`，`test(phone): 加上 Duo 内外屏尺寸，防抖照真机`

### Task 13: 模拟器上走一遍，记下来

**Files:**
- Create: `docs/superpowers/measurements/2026-11-27-rapp-phone-v1b-check.md`

- [ ] **Step 1:** iPhone 模拟器（390×844）竖、横各一次；iPad 模拟器全屏 → 拖到最窄的分屏 → 拖回来（验收 2）。每一步截图存进探查分支以外的地方（不进仓库），文档里写看到了什么。
- [ ] **Step 2:** 三套主题各看首页、面板、设置、会话里面（验收 5），系统设置里开“灰度”看等你、在干活、做完、断开分得清。
- [ ] **Step 3:** 关掉中心服务（`设置` 里关，或不配）看首页（验收 6）。
- [ ] **Step 4:** 验收 1（Duo 开合）、Q1（1 秒出卡片）写“待用户实机”，附一张五分钟内做得完的操作单。
- [ ] **Step 5: 提交** `git add docs/superpowers/measurements/2026-11-27-rapp-phone-v1b-check.md`，`docs(phone): V1b 模拟器验收记录`

---

## 验收对应（规格 §17）

| 验收 | 内容 | 由哪几个任务保证 |
|---|---|---|
| 1 | Duo 开合：到首页 / 停在会话里面、`刚才在：X`、草稿还在、A 不改尺寸、展开最多一次 | Task 1（拦改尺寸）、4（落点、防抖、`shell switch keeps session state`）、8（终端 fit=false）、9（开合整条路）、12（真机序列）、13（实机操作单） |
| 2 | iPhone 竖横都是手机；iPad 全屏是 Pad，最窄分屏变手机、拖回去变回 | Task 4（`formOf`、防抖）、10（接进 iOS）、11（尺寸矩阵）、13（模拟器） |
| 5 | 三套主题、没有写死的颜色、灰度分得清、对比度 T9 | Task 5（token、灯的形状）、11（矩阵、对比度、扫写死颜色）、13（灰度实看） |
| 6 | 关掉中心服务首页照样有卡片、没有空格子 | Task 2、3（合并规则、`no service: local lists only`）、6（`home without service has no empty slots`）、11、13 |

## 不在这一期

回复按钮、阅读视图、语音（V1c，等探查 2、3、4）；项目范围、已处理（V1d）；H8、H12；F5 在桌面上生效（用户定的：先只在 iOS 上切）。
