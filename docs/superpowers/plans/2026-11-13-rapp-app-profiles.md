# rapp app 配置（按 app 的配置）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** B 的 GUI 按 app 读一份配置（内置 `gui/assets/app_profiles.json` + 我的 `apps.json`，按字段合并），用它决定开流档位、隐藏哪些子窗口、哪些窗口不显示输入区、发完要不要补回车；入口有标签右键、「已隐藏 N 个」、串流菜单、设备页 ⋯、本机页「app 配置」一节和表单式配置页。

**Architecture:** 纯 Dart 的模型（解析、通配、按字段合并、窗口规则）放在 `gui/lib/embed/`；文件读写和修改放在 `AppProfileStore`（照 `workspace_store.dart` 的临时文件 + 改名、`.bad`）。`RemoteSession` 拿到合并后的 `ResolvedProfile`，先过窗口规则再交给 `WindowTabs`/舞台/弹层，并算出输入区能不能显示；`MainState` 在开会话时选档位、配置变化时立刻重算、把要藏的窗口 id 用新的 runner 调用 `set_hidden` 告诉 runner（分离出来的窗口由 runner 画）。A 和 A↔B 协议都不改。

**Tech Stack:** Flutter 3.44（macOS/Linux 桌面，Dart），Swift 5.9（`Sources/RappSession` 纯函数 + `gui/macos/Runner` 的 SessionPlugin）。

**Spec:** `docs/superpowers/specs/2026-11-13-rapp-app-profiles-design.md`（已确认，§9 以 commit 7230cb6 为准：第一批 16 个 + 本机 2 个）；编写规范 `docs/superpowers/specs/2026-11-13-rapp-app-profile-authoring.md`（内置行的字段顺序和取值）。

**范围外：** 独立 `rapp-client`、Omarchy GTK 客户端读配置；A 不采集被隐藏的窗口（协议 v7）；标题栏裁剪、按键映射、「在等你」（规格 §7）；导入、分享。

## 裁定（规格没写死、我定的）

| # | 裁定 | 理由 | 错了的代价 |
|---|---|---|---|
| R1 | 分离（detach）时的隐藏要改 runner：新增 Dart→runner 调用 `set_hidden {sid, windows:[id]}`，SessionPlugin 记下每个会话要藏的 id，交给 `DetachedSession` 的窗口表先过 `detachedWindows(_:hidden:)`。这是 GUI 和它自己 runner 之间的通道，不是 A↔B 协议（D1 不受影响）。Linux 端口不支持分离，`set_hidden` 走到它那里照常被忽略 | 分离出来的窗口是 runner 按它自己的窗口表开的，Dart 过滤不到；规格 D6 要求「不能分离」 | 多一个通道调用，Swift 改 3 个文件 |
| R2 | 主窗口 = 当前窗口表里、按**第一次出现**的先后排最前的、`kind == normal` 且 `parent == 0` 的窗口；同一张表里一起第一次出现的按 id 从小到大排（macOS 的窗口 id 随创建递增）。一个 id 消失后再出现算新窗口（和 `WindowTabs` 一致） | 规格 §1「最早出现」，但一张表里分不出先后 | 极少数 app 首表里多个普通窗口时主窗口认错，只影响 `child` 默认值 |
| R3 | `child: false` 的规则也能配主窗口（`hide` 和 `noComposer` 都算）；D7 兜底照旧：所有带标题栏的窗口都被藏时一条都不藏 | `child` 字段存在的意义就是放开主窗口 | 无 |
| R4 | 被藏的带标题栏窗口，它的弹层（`popupOwner` 找到的根是它）跟着一起藏，但「已隐藏 N 个」只数被规则直接对上的窗口 | `popupsFor` 会把找不到父窗口的弹层放到当前标签上，不一起藏就会漏出来 | 无 |
| R5 | D7 兜底的判定：原表里有带标题栏的窗口而过滤后一个都不剩，或者原表不空而过滤后为空 → 整张表照常显示，`hidden` 为空。runner 的 `detachedWindows` 用同一条（防 Dart 的 `set_hidden` 还没到时 runner 自己把会话放回舞台） | 规格 D7 | 无 |
| R6 | 合并：对一个 app 标识，「我的」取 `apps.json` 里第一份含这个标识的，「内置」取内置文件里第一份含它的；逐字段取 我的 ?? 内置 ?? 通用默认。`stream` 的 `mode`/`density`/`fps` 各算一个字段；`windows` 整个列表算一个字段（我的写了 `[]` 就是不要内置的规则）；`name` 没写时用有配置那一层的 `ids.first`（我的优先） | 规格 D4「按字段合并」 | 改 `resolveProfile` 一处 |
| R7 | 坏数据的粒度：顶层不是对象、`version != 1`、`apps` 不是列表 → 整个文件坏（`.bad` + 提示）。单条不是对象或没有可用的 `ids` → 这一条跳过；字段取值不认识（`mode` 不在三个里、`fps` 不在 1/5/15/30、`afterSend` 不认识、某条规则坏了）→ 只丢这个字段 / 这条规则。下次保存时被丢的部分不会写回 | 规格 §2「`ids` 必填，没有就整条不用」；手改文件写错一个字不该让整份配置没了 | 手改时写错的字段保存后消失 |
| R8 | 「隐藏这类窗口」「这个窗口不要输入区」生成的规则插在**最前**（第一条对上的生效，插在后面可能被前面的规则挡住）；标题照抄完整标题（空标题就写 `""`，只配空标题）。对主窗口：「隐藏这类窗口」灰掉；「这个窗口不要输入区」生成 `child: false` 的规则 | 规格 §4、风险 3 | 无 |
| R9 | 「撤销」= 把「我的配置」整个恢复成改之前的样子（`snapshot()`/`restore()`），用 `SnackBar` 的 action 显示（`local_section.dart` 已经用 SnackBar） | 最简单、不会撤错 | 两次修改之间撤销会连带撤掉后一次，提示 4 秒内基本不会发生 |
| R10 | 配置保存后**马上生效**的是：窗口规则、`composer`、`afterSend`。`stream` 只在开会话（新开，不含重连）时用，已开的会话不跟着变 | 规格 §3.1：串流菜单的临时选择只对这次会话有效、重连沿用；改配置不该把用户这次手选的档位冲掉 | 用户改了画面要关掉重开才看到 |
| R11 | 「已隐藏 N 个」在 N > 0 时总是显示在标签栏末尾（哪怕只剩一个标签，标签栏平时 ≥2 个才出现）；A 把焦点给了被藏的窗口时它用选中样式（`TabChip.selected`）显示 | 规格 D7、§3.5「亮起来」 | 无 |
| R12 | 内置的 `tested` 一律 `false`；我的配置写了 `tested` 就按字段合并（用户可以在文件里写 `true` 去掉「未实测」）；配置页不提供这个开关 | 规格 §2、编写规范 §4 | 无 |
| R13 | 日志：GUI 没有自己的日志文件，写 stderr（和 `rapp: embedded sessions unavailable` 同一处）。只有两种行：`rapp: app 配置「<名>」`（会话开起来、对上了配置时一次）和 `rapp: app 配置「<名>」：隐藏 <N> 个窗口`（某会话被藏的个数变了时一次）。`MainState` 收一个可注入的 `log` | 规格 D9；可测 | 无 |
| R14 | §9 文档组（WPS、Word/Excel/PowerPoint）的画面写 `duocolor / adaptive / 5`。§9 表里写的是「同上」（上一行 Edge 是高彩/15），但同一行的理由写「5 帧够」，编写规范 §3「文字，画面变得慢 → duocolor/adaptive/5」举的例子就是文档；「同上」是删掉备忘录那几行时留下的。**请用户确认后改规格 §9 的这两格** | 理由栏和编写规范一致 | 错了改 JSON 里两行 |
| R15 | 名字超过 40 字截到 40 字（按字符），空名字当没写；`ids` 去掉首尾空白和空串，比较用 `toLowerCase()` | 规格 §2 | 无 |
| R16 | 我的配置里跟内置共用标识时，配置页新建出来的「我的」只写改过的字段，`ids` 抄内置那份；内置以后升级，没改过的字段跟着内置走 | D4 的合并只有这样才有意义 | 无 |

## Global Constraints

- 命令（Flutter）：`cd gui && $HOME/development/flutter/bin/flutter analyze` 和 `$HOME/development/flutter/bin/flutter test --timeout 60s`。
- 命令（Swift，Task 6 起）：仓库根目录 `swift test`；交任务前 `./scripts/check.sh`，末行 `EXIT=0`。runner 编译：`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`（只编译，不启动）。
- Flutter 可能改 `gui/pubspec.lock`（把 matcher/meta 降级）——这个文件永远不提交，用 `git checkout -- gui/pubspec.lock` 还原（只许对这一个文件这样做）。
- 只按文件名 stage；不准 `git add -u/-A/.`；不准 `git stash`；除 `gui/pubspec.lock` 外不准 checkout/restore/reset 任何东西。
- 不碰用户的文件：`README.md`（有未提交的用户内容）、`docs/superpowers/specs/2026-11-12-rapp-design-language.md`（未提交）、`docs/archives/`、`Claude outputs/`，以及未跟踪的规格 `docs/superpowers/specs/2026-11-12-rapp-{relay-security-requirements,requirements-feedback,conversation-design,domain-candidates}.md`、`2026-11-13-rapp-{agentos-ideas,builtin-apps-research}.md`。也不改本计划依据的两份规格（app 配置设计、编写规范）；《配置规范总览》`docs/superpowers/specs/2026-11-13-rapp-config-reference.md` 只在 Task 4、Task 7 里按它 §9 的规矩改 §2.5。
- 测试只用临时目录；不碰用户真实的 GUI 配置目录、`~/Library/Application Support/rapp`、`~/Library/Logs/rapp`、`/Applications/rapp.app`、正在跑的 rapp-service、钥匙串、系统剪贴板。不用端口 47800 和 21116–21119。不启动 GUI/app 窗口，不发合成输入。不准 `pkill`/`killall`。
- 日志里不准出现窗口标题和规则的标题通配（D9）；Task 7 有一条测试钉住。
- `apps.json` 里只有标识、名字、档位、发送后、输入区开关、规则（种类、标题通配、动作）、`tested`；没有密码、token、剪贴板内容。
- 界面文字照设计语言：中文短句，按钮用动词，不出现「profile」「regex」这类词；原文见各 Task。
- 《配置规范总览》§9：改配置文件字段的提交要在**同一个提交**里改它对应的表，代码位置写到文件和行号。
- 提交尾行：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 用户同时在改仓库，`git status` 里的 `M README.md` 等不是你的。

## Review Focus

1. **被藏窗口的弹层漏到当前标签上**：`popupsFor` 把找不到父窗口的弹层放到当前标签上，被藏窗口的菜单/sheet 如果只从表里删掉父窗口就会盖在别的窗口上。测试：Task 3 `popups of a hidden window go with it`；Task 6 `testDetachedWindowsDropHiddenAndTheirPopups`。
2. **右键藏掉的正是当前标签**：舞台不能黑着、不能指向不存在的窗口，要换到最近用过的可见标签；输入区跟着新标签判断。测试：Task 5 `hiding the current tab moves to the most recent shown one`。
3. **分离中改了配置 / 只剩被藏的窗口**：分离出来的窗口要马上跟着变；runner 先拿到新窗口表、Dart 的 `set_hidden` 还没到时不能把会话放回舞台或留下空窗口。测试：Task 6 `testDetachedWindowsShowAllWhenOnlyHiddenAreLeft`；Task 7 `a profile change while detached sends set_hidden at once`。
4. **补回车补错时机**：取消、半途失败、断线（`linkDown` 的 `done(0, null)`）、只有块没有文字的一轮，都不能多按一次回车，也不能漏按。测试：Task 5 `onAllSent only after every piece went`；Task 7 `afterSend return sends key 36 after a full round only`。
5. **手改的 `apps.json` 有一处写错**：只丢那个字段或那条规则，其余照常生效；保存失败（目录只读）只提示不崩。测试：Task 1 `a bad field or rule drops only itself`；Task 4 `a save that fails keeps the change in memory and reports it`。

---

### Task 1: 配置模型、通配、按字段合并（纯 Dart）

**Files:**
- Create: `gui/lib/embed/app_profile.dart`
- Test: `gui/test/embed/app_profile_test.dart`

**Interfaces:**
- Consumes: `WindowKind`（`session_port.dart`），`StreamChoice`、`startChoice`（`stream_choice.dart`）。
- Produces:
  - `const profilesVersion = 1;` `const profileModes = {'duogray', 'duocolor', 'color16'};` `const profileDensities = {'saver1x', 'adaptive', 'original'};` `const profileFps = {1, 5, 15, 30};`
  - `enum AfterSend { none, pressReturn }`，JSON 名 `none` / `return`；`AfterSend? afterSendFromJson(Object? v)`、`String afterSendToJson(AfterSend a)`。
  - `enum RuleAction { hide, noComposer }`（JSON 名就是 `hide`/`noComposer`）。
  - `class WindowRule { const WindowRule({this.kind, this.title, this.child = true, required this.action}); final WindowKind? kind; final String? title; final bool child; final RuleAction action; Map<String, Object?> toJson(); static WindowRule? fromJson(Object? j); }`，带 `==`/`hashCode`。`toJson` 字段顺序 `kind, title, child, action`，`child` 只在 `false` 时写，没设的不写。`fromJson` 坏了返回 null。
  - `class AppProfile { AppProfile({required List<String> ids, this.name, this.mode, this.density, this.fps, this.afterSend, this.composer, this.windows, this.tested}); List<String> ids; String? name; String? mode; String? density; int? fps; AfterSend? afterSend; bool? composer; List<WindowRule>? windows; bool? tested; bool matches(String appId); bool sharesId(AppProfile other); AppProfile copy(); Map<String, Object?> toJson(); static AppProfile? fromJson(Object? j); }` —— 所有字段可空 = 「没写」。
  - `List<AppProfile> parseProfiles(Object? json)`：顶层坏抛 `FormatException`（R7）。`Map<String, Object?> profilesToJson(List<AppProfile> apps)` → `{"version": 1, "apps": [...]}`。
  - `class ResolvedProfile { const ResolvedProfile({this.name, this.stream = startChoice, this.afterSend = AfterSend.none, this.composer = true, this.windows = const [], this.tested = true}); static const generic = ResolvedProfile(); final String? name; ... }` —— `name == null` 表示没有对上任何配置。
  - `ResolvedProfile resolveProfile(String appId, {required List<AppProfile> mine, required List<AppProfile> builtin})`
  - `bool globMatch(String pattern, String text)`

- [ ] **Step 1: 写失败的测试**

```dart
test('globMatch: * is any run, the rest literal, case-insensitive', () {
  expect(globMatch('*下载*', '正在下载 3 项'), isTrue);
  expect(globMatch('下载*', '下载'), isTrue);
  expect(globMatch('Settings', 'settings'), isTrue);
  expect(globMatch('a*b*c', 'aXXbYYc'), isTrue);
  expect(globMatch('a*b*c', 'aXXbYY'), isFalse);
  expect(globMatch('(1).txt', '(1).txt'), isTrue); // brackets and dots are literal
  expect(globMatch('a.c', 'abc'), isFalse);
  expect(globMatch('', ''), isTrue);
  expect(globMatch('', 'x'), isFalse);
  expect(globMatch('*', ''), isTrue);
});

test('fromJson reads the spec example; toJson writes fields in the authoring order', () {
  final p = AppProfile.fromJson({
    'name': 'Chrome', 'ids': ['com.google.Chrome', 'chrome.exe'],
    'stream': {'mode': 'color16', 'density': 'adaptive', 'fps': 15},
    'afterSend': 'none', 'composer': true,
    'windows': [{'kind': 'floating', 'title': '*下载*', 'action': 'hide'}, {'kind': 'dialog', 'action': 'noComposer'}],
    'tested': false,
  })!;
  expect(p.windows, [const WindowRule(kind: WindowKind.floating, title: '*下载*', action: RuleAction.hide),
                     const WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer)]);
  expect(p.toJson().keys.toList(), ['name', 'ids', 'stream', 'afterSend', 'composer', 'windows', 'tested']);
  expect(AppProfile(ids: ['x']).toJson(), {'ids': ['x']}); // unset fields are not written
  expect(AppProfile(ids: ['x'], fps: 5).toJson(), {'ids': ['x'], 'stream': {'fps': 5}});
});

test('an entry without usable ids is skipped; a bad top level throws', () {
  expect(AppProfile.fromJson({'name': 'x'}), isNull);
  expect(AppProfile.fromJson({'ids': ['  ', '']}), isNull);
  expect(AppProfile.fromJson('nope'), isNull);
  expect(parseProfiles({'version': 1, 'apps': [{'ids': ['a']}, {'name': 'no ids'}, 7]}).length, 1);
  expect(() => parseProfiles({'version': 2, 'apps': []}), throwsFormatException);
  expect(() => parseProfiles({'version': 1, 'apps': {}}), throwsFormatException);
  expect(() => parseProfiles([]), throwsFormatException);
});

test('a bad field or rule drops only itself', () {
  final p = AppProfile.fromJson({
    'ids': ['a'], 'stream': {'mode': 'sepia', 'density': 'adaptive', 'fps': 7},
    'afterSend': 'twice', 'composer': 'yes',
    'windows': [{'kind': 'window', 'action': 'hide'}, {'action': 'explode'}, {'title': 'ok', 'action': 'hide'}],
  })!;
  expect(p.mode, isNull);
  expect(p.density, 'adaptive');
  expect(p.fps, isNull);
  expect(p.afterSend, isNull);
  expect(p.composer, isNull);
  expect(p.windows, [const WindowRule(title: 'ok', action: RuleAction.hide)]);
});

test('name: trimmed to one line and 40 characters; empty is unset', () {
  expect(AppProfile.fromJson({'ids': ['a'], 'name': 'x' * 50})!.name!.length, 40);
  expect(AppProfile.fromJson({'ids': ['a'], 'name': '  '})!.name, isNull);
});

test('resolve: mine over built-in field by field, then the generic default', () {
  final builtin = [AppProfile(ids: ['com.google.Chrome'], name: 'Chrome', mode: 'color16', density: 'adaptive', fps: 15, tested: false)];
  final mine = [AppProfile(ids: ['COM.GOOGLE.CHROME'], fps: 5, windows: [const WindowRule(action: RuleAction.hide)])];
  final r = resolveProfile('com.google.chrome', mine: mine, builtin: builtin);
  expect(r.name, 'Chrome');
  expect(r.stream, const StreamChoice('color16', 'adaptive', 5));
  expect(r.windows.single.action, RuleAction.hide);
  expect(r.tested, isFalse);
  expect(r.afterSend, AfterSend.none);
  expect(r.composer, isTrue);
  expect(resolveProfile('other', mine: mine, builtin: builtin), same(ResolvedProfile.generic));
  expect(ResolvedProfile.generic.stream, startChoice);
});

test('resolve: mine writing windows: [] drops the built-in rules', () {
  final b = [AppProfile(ids: ['a'], windows: [const WindowRule(action: RuleAction.hide)])];
  expect(resolveProfile('a', mine: [AppProfile(ids: ['a'], windows: [])], builtin: b).windows, isEmpty);
});

test('resolve: a duplicated id uses the earlier of my profiles; a nameless one shows its first id', () {
  final mine = [AppProfile(ids: ['x.app', 'x.exe'], fps: 30), AppProfile(ids: ['x.app'], name: 'Later', fps: 1)];
  final r = resolveProfile('x.app', mine: mine, builtin: const []);
  expect(r.stream.fps, 30);
  expect(r.name, 'x.app');
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test --timeout 60s test/embed/app_profile_test.dart`
Expected: FAIL（`app_profile.dart` 不存在）

- [ ] **Step 3: 在 `gui/lib/embed/app_profile.dart` 实现上面 Interfaces 里的类型和函数**

`fromJson` 每个字段单独校验，不合法的当没写（R7）；`name` 照 `workspace_store.dart` 的 `oneLine` 折成一行后按字符截 40（R15）。`matches` 用 `toLowerCase()` 比。通配和合并照下面写（`globMatch` 按 UTF-16 码元逐个比，`*` 回溯）：

```dart
bool globMatch(String pattern, String text) {
  final p = pattern.toLowerCase(), t = text.toLowerCase();
  var i = 0, j = 0, star = -1, mark = 0;
  while (j < t.length) {
    if (i < p.length && p[i] == '*') {
      star = i++;
      mark = j;
    } else if (i < p.length && p[i] == t[j]) {
      i++;
      j++;
    } else if (star >= 0) {
      i = star + 1;
      j = ++mark;
    } else {
      return false;
    }
  }
  while (i < p.length && p[i] == '*') {
    i++;
  }
  return i == p.length;
}

ResolvedProfile resolveProfile(String appId, {required List<AppProfile> mine, required List<AppProfile> builtin}) {
  AppProfile? first(List<AppProfile> l) => l.where((p) => p.matches(appId)).firstOrNull;
  final m = first(mine), b = first(builtin);
  if (m == null && b == null) return ResolvedProfile.generic;
  T? pick<T>(T? Function(AppProfile) f) => (m == null ? null : f(m)) ?? (b == null ? null : f(b));
  return ResolvedProfile(
    name: pick((p) => p.name) ?? (m ?? b)!.ids.first,
    stream: StreamChoice(pick((p) => p.mode) ?? startChoice.mode, pick((p) => p.density) ?? startChoice.density,
        pick((p) => p.fps) ?? startChoice.fps),
    afterSend: pick((p) => p.afterSend) ?? AfterSend.none,
    composer: pick((p) => p.composer) ?? true,
    windows: pick((p) => p.windows) ?? const [],
    tested: pick((p) => p.tested) ?? true,
  );
}
```

- [ ] **Step 4: 跑测试确认通过；`flutter analyze` 无问题**

Run: `cd gui && $HOME/development/flutter/bin/flutter test --timeout 60s test/embed/app_profile_test.dart && $HOME/development/flutter/bin/flutter analyze`
Expected: PASS，`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/app_profile.dart gui/test/embed/app_profile_test.dart
git commit -m "feat(gui): app profile model, glob and field-wise merge"
```

---

### Task 2: 内置配置文件（§9 首批）

**Files:**
- Create: `gui/assets/app_profiles.json`
- Modify: `gui/pubspec.yaml`（`flutter.assets` 加 `- assets/app_profiles.json`）
- Test: `gui/test/embed/builtin_profiles_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `parseProfiles`、`AppProfile`。
- Produces: 资源路径 `assets/app_profiles.json`（Task 7 的 `main.dart` 用 `rootBundle.loadString` 读）。

- [ ] **Step 1: 写失败的测试**（测试里直接读 `File('assets/app_profiles.json')`，`flutter test` 的工作目录是 `gui/`）

```dart
final raw = jsonDecode(File('assets/app_profiles.json').readAsStringSync()) as Map<String, Object?>;
final apps = parseProfiles(raw);

test('18 built-in profiles, the §9 names in order', () {
  expect(apps.map((p) => p.name), ['终端', 'iTerm2', 'Ghostty', 'Warp', 'ChatGPT', 'Claude', 'Cursor', 'VS Code',
      'Xcode', 'Chrome', 'Safari', 'Edge', 'WPS Office', 'Word、Excel、PowerPoint', '微信', '企业微信', 'Paseo', 'note.md']);
});

test('every row: authoring field order, none / true / [] / tested false', () {
  for (final e in (raw['apps'] as List).cast<Map>()) {
    expect(e.keys.toList(), ['name', 'ids', 'stream', 'afterSend', 'composer', 'windows', 'tested']);
    expect(e['afterSend'], 'none');
    expect(e['composer'], true);
    expect(e['windows'], isEmpty);
    expect(e['tested'], false);
  }
});

test('the §9 ids and pictures', () {
  String key(AppProfile p) => '${p.ids.join(',')} ${p.mode}/${p.density}/${p.fps}';
  expect(apps.map(key), [
    'com.apple.Terminal duogray/adaptive/15',
    'com.googlecode.iterm2 duogray/adaptive/15',
    'com.mitchellh.ghostty duogray/adaptive/15',
    'dev.warp.Warp-Stable duocolor/adaptive/15',
    'com.openai.codex,com.openai.chat duocolor/adaptive/15',
    'com.anthropic.claudefordesktop duocolor/adaptive/15',
    'com.todesktop.230313mzl4w4u92 duocolor/adaptive/15',
    'com.microsoft.VSCode duocolor/adaptive/15',
    'com.apple.dt.Xcode duocolor/adaptive/15',
    'com.google.Chrome color16/adaptive/15',
    'com.apple.Safari color16/adaptive/15',
    'com.microsoft.edgemac color16/adaptive/15',
    'com.kingsoft.wpsoffice.mac.global,com.kingsoft.wpsoffice.mac duocolor/adaptive/5',
    'com.microsoft.Word,com.microsoft.Excel,com.microsoft.Powerpoint duocolor/adaptive/5',
    'com.tencent.xinWeChat duocolor/adaptive/5',
    'com.tencent.WeWorkMac duocolor/adaptive/5',
    'sh.paseo.desktop duocolor/adaptive/15',
    'net.notemd.app duocolor/adaptive/5',
  ]);
});

test('no id appears in two built-in profiles', () {
  final all = [for (final p in apps) ...p.ids.map((i) => i.toLowerCase())];
  expect(all.toSet().length, all.length);
});

test('pubspec lists the asset', () {
  expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/app_profiles.json'));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test --timeout 60s test/embed/builtin_profiles_test.dart`
Expected: FAIL（文件不存在）

- [ ] **Step 3: 写 `gui/assets/app_profiles.json`（照抄，一条一行；WPS 和 Office 两行见 R14）并在 `pubspec.yaml` 加资源**

```json
{
  "version": 1,
  "apps": [
    {"name": "终端", "ids": ["com.apple.Terminal"], "stream": {"mode": "duogray", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "iTerm2", "ids": ["com.googlecode.iterm2"], "stream": {"mode": "duogray", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Ghostty", "ids": ["com.mitchellh.ghostty"], "stream": {"mode": "duogray", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Warp", "ids": ["dev.warp.Warp-Stable"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "ChatGPT", "ids": ["com.openai.codex", "com.openai.chat"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Claude", "ids": ["com.anthropic.claudefordesktop"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Cursor", "ids": ["com.todesktop.230313mzl4w4u92"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "VS Code", "ids": ["com.microsoft.VSCode"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Xcode", "ids": ["com.apple.dt.Xcode"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Chrome", "ids": ["com.google.Chrome"], "stream": {"mode": "color16", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Safari", "ids": ["com.apple.Safari"], "stream": {"mode": "color16", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Edge", "ids": ["com.microsoft.edgemac"], "stream": {"mode": "color16", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "WPS Office", "ids": ["com.kingsoft.wpsoffice.mac.global", "com.kingsoft.wpsoffice.mac"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 5}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Word、Excel、PowerPoint", "ids": ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 5}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "微信", "ids": ["com.tencent.xinWeChat"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 5}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "企业微信", "ids": ["com.tencent.WeWorkMac"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 5}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "Paseo", "ids": ["sh.paseo.desktop"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 15}, "afterSend": "none", "composer": true, "windows": [], "tested": false},
    {"name": "note.md", "ids": ["net.notemd.app"], "stream": {"mode": "duocolor", "density": "adaptive", "fps": 5}, "afterSend": "none", "composer": true, "windows": [], "tested": false}
  ]
}
```

- [ ] **Step 4: 跑测试确认通过；`python3 -m json.tool gui/assets/app_profiles.json > /dev/null` 退出码 0**

- [ ] **Step 5: 提交**

```bash
git add gui/assets/app_profiles.json gui/pubspec.yaml gui/test/embed/builtin_profiles_test.dart
git commit -m "feat(gui): built-in app profiles, first macOS batch"
```

---

### Task 3: 窗口规则：主窗口、第一条对上的规则、隐藏（纯 Dart）

**Files:**
- Create: `gui/lib/embed/window_rules.dart`
- Test: `gui/test/embed/window_rules_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `WindowRule`、`RuleAction`、`globMatch`；`RemoteWindow`。
- Produces:
  - `class MainWindowTracker { int? update(List<RemoteWindow> all); }` —— 按 R2：内部记当前还在的 id 的第一次出现顺序（新的按 id 升序追加，消失的去掉），返回第一个 `kind == normal && parent == 0` 的 id，没有返回 null。
  - `bool ruleMatches(WindowRule r, RemoteWindow w, {required bool isMain})` = `(!r.child || !isMain) && (r.kind == null || r.kind == w.kind) && (r.title == null || globMatch(r.title!, w.title))`。
  - `RuleAction? actionFor(List<WindowRule> rules, RemoteWindow w, {required bool isMain})` —— 第一条对上的。
  - `({List<RemoteWindow> shown, List<RemoteWindow> hidden}) applyHide(List<RemoteWindow> all, List<WindowRule> rules, {int? main, Set<int> showOnce = const {}})` —— `hidden` = 被 `hide` 直接对上且不在 `showOnce` 里的窗口（A 的顺序）；`shown` = `all` 去掉 `hidden`，再去掉根（沿 `parent` 找到的第一个带标题栏的窗口）在 `hidden` 里的弹层（R4）；最后按 R5 兜底。

- [ ] **Step 1: 写失败的测试**（`w(...)` 照 `window_tabs_test.dart` 的写法，多一个 `title` 参数）

```dart
test('the main window is the earliest plain parentless one; it outlives a newer one', () {
  final t = MainWindowTracker();
  expect(t.update([w(9, kind: WindowKind.dialog), w(7), w(5)]), 5); // same table: by id
  expect(t.update([w(3), w(7), w(5)]), 5); // 3 is newer
  expect(t.update([w(3), w(7)]), 7);
  expect(t.update([w(4, kind: WindowKind.floating)]), isNull);
});

test('first matching rule wins; child defaults to sub-windows only', () {
  final rules = [const WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer),
                 const WindowRule(action: RuleAction.hide)];
  expect(actionFor(rules, w(2, kind: WindowKind.dialog), isMain: false), RuleAction.noComposer);
  expect(actionFor(rules, w(3), isMain: false), RuleAction.hide);
  expect(actionFor(rules, w(1), isMain: true), isNull);
  expect(actionFor([const WindowRule(child: false, action: RuleAction.noComposer)], w(1), isMain: true),
      RuleAction.noComposer);
});

test('title glob matches case-insensitively; no title means any title', () {
  const r = WindowRule(kind: WindowKind.floating, title: '*下载*', action: RuleAction.hide);
  expect(ruleMatches(r, w(2, kind: WindowKind.floating, title: 'Chrome 下载'), isMain: false), isTrue);
  expect(ruleMatches(r, w(2, kind: WindowKind.dialog, title: 'Chrome 下载'), isMain: false), isFalse);
  expect(ruleMatches(r, w(2, kind: WindowKind.floating, title: '设置'), isMain: false), isFalse);
});

test('hide drops the window; the main window is never hidden by a default rule', () {
  final r = applyHide([w(1), w(2), w(3)], [const WindowRule(action: RuleAction.hide)], main: 1);
  expect(r.shown.map((e) => e.id), [1]);
  expect(r.hidden.map((e) => e.id), [2, 3]);
});

test('popups of a hidden window go with it, an orphan popup stays', () {
  final all = [w(1), w(2, kind: WindowKind.floating), w(5, kind: WindowKind.menu, parent: 2),
               w(6, kind: WindowKind.sheet, parent: 1), w(7, kind: WindowKind.popover, parent: 99)];
  final r = applyHide(all, [const WindowRule(kind: WindowKind.floating, action: RuleAction.hide)], main: 1);
  expect(r.shown.map((e) => e.id), [1, 6, 7]);
  expect(r.hidden.map((e) => e.id), [2]); // the count is of windows a rule hid (R4)
});

test('only hidden windows left: everything shows (D7)', () {
  final rules = [const WindowRule(child: false, action: RuleAction.hide)];
  final r = applyHide([w(1), w(2), w(5, kind: WindowKind.menu, parent: 1)], rules, main: 1);
  expect(r.shown.map((e) => e.id), [1, 2, 5]);
  expect(r.hidden, isEmpty);
});

test('showOnce brings one hidden window and its popups back', () {
  final all = [w(1), w(2), w(5, kind: WindowKind.menu, parent: 2), w(3)];
  final r = applyHide(all, [const WindowRule(action: RuleAction.hide)], main: 1, showOnce: {2});
  expect(r.shown.map((e) => e.id), [1, 2, 5]);
  expect(r.hidden.map((e) => e.id), [3]);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test --timeout 60s test/embed/window_rules_test.dart`
Expected: FAIL

- [ ] **Step 3: 在 `gui/lib/embed/window_rules.dart` 实现 Interfaces 里的四个**

弹层的根照 `window_tabs.dart` 里 `rootOf` 的走法（沿 `parent`，最多走 `all.length` 步防环），找不到根就留着。

- [ ] **Step 4: 跑测试确认通过；`flutter analyze` 无问题**

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/window_rules.dart gui/test/embed/window_rules_test.dart
git commit -m "feat(gui): window rules: main window, first match, hide with D7 fallback"
```

---

### Task 4: `AppProfileStore`：读写 `apps.json`、内置、修改

**Files:**
- Create: `gui/lib/ui/app_profile_store.dart`
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（只改 §2.5）
- Test: `gui/test/ui/app_profile_store_test.dart`

**Interfaces:**
- Consumes: Task 1 全部；Task 3 的 `ruleMatches`。
- Produces:
  - `const appsFile = 'apps.json';` `const appsLoadProblem = 'app 配置没有读到，已从空白开始';` `const appsSaveProblem = 'app 配置没有存上';`
  - `enum ProfileSource { builtin, mine, changed }`，`String sourceLabel(ProfileSource s)` → `内置` / `我的` / `内置 + 我改过`。
  - `class ProfileRow { final String name; final List<String> ids; final ProfileSource source; final bool tested; final String? duplicateOf; final AppProfile? mine; final AppProfile? builtin; }`
  - `class AppProfileStore extends ChangeNotifier`：
    - `AppProfileStore(this.dir, {List<AppProfile> builtin = const [], List<AppProfile>? mine, this.problem})`
    - `static AppProfileStore load(String dir, String? builtinJson)` —— 不抛；`builtinJson` 为 null 或坏 → 没有内置（不算 problem）；`apps.json` 不存在 → 空；读不出 → 改名 `apps.json.bad`，`problem = appsLoadProblem`。
    - `final String dir; final List<AppProfile> builtin; List<AppProfile> get mine; String? problem;`
    - `ResolvedProfile resolve(String appId)`；`AppProfile? builtinFor(String appId)`；`AppProfile? mineFor(String appId)`
    - `List<AppProfile> snapshot()`（深拷贝）；`void restore(List<AppProfile> snap)`
    - `void put(AppProfile p, {AppProfile? replacing})`（`replacing` 在列表里就原位替换，否则追加）；`void remove(AppProfile p)`；`void restoreBuiltin(AppProfile b)`（删掉所有和 `b` 共用标识的我的配置）
    - `void addRule(String appId, String appName, WindowRule r)` —— 对 `mineFor(appId)`，没有就新建 `AppProfile(ids: builtinFor(appId)?.ids 的拷贝 ?? [appId], name: builtinFor(appId) == null ? appName : null)`（R16）；它的 `windows` 为 null 时先从 `builtinFor(appId)?.windows ?? []` 拷一份；`r` 插在第 0 位（R8）。
    - `bool removeHideRule(String appId, RemoteWindow w, {required bool isMain})` —— 在 `resolve(appId).windows` 里找第一条 `action == hide` 且 `ruleMatches` 的，去掉后把剩下的列表写进我的配置；没找到返回 false。
    - `void rememberStream(String appId, String appName, StreamChoice c)` —— 同 `addRule` 的取 / 建法，写 `mode`/`density`/`fps`。
    - `List<ProfileRow> rows()` —— 先按内置顺序（有共用标识的我的配置 → `changed`，名字用合并后的），再按我的顺序列出不和任何内置共用标识的（`mine`）；我的配置和排在它前面的另一份我的配置共用标识时 `duplicateOf` = 前面那份的显示名（规格风险 4）。
  - 每个修改方法：改内存 → 写文件（`{dir}/apps.json.tmp` 写完改名，照 `saveWorkspace`）→ `notifyListeners()`。写失败：`problem = appsSaveProblem`，内存里的修改保留，照样 notify，不抛。

- [ ] **Step 1: 写失败的测试**（临时目录照 `workspace_store_test.dart`：`Directory.systemTemp.createTempSync('apps')`，tearDown 先 `chmod 755` 再删）

```dart
test('missing apps.json: empty, no problem; bad built-in JSON: no built-ins, no problem', () {
  final s = AppProfileStore.load(dir.path, '{not json');
  expect(s.mine, isEmpty);
  expect(s.builtin, isEmpty);
  expect(s.problem, isNull);
  expect(s.resolve('com.google.Chrome'), same(ResolvedProfile.generic));
});

test('a broken apps.json moves to apps.json.bad and reports it', () {
  put('{"version": 1, "apps": 3}');
  final s = AppProfileStore.load(dir.path, null);
  expect(s.problem, appsLoadProblem);
  expect(f('apps.json').existsSync(), isFalse);
  expect(f('apps.json.bad').readAsStringSync(), '{"version": 1, "apps": 3}');
});

test('rememberStream then load round-trips; the file has version 1 and only my fields', () {
  final s = AppProfileStore.load(dir.path, builtinJson); // builtinJson: one Chrome row, color16/adaptive/15
  s.rememberStream('com.google.Chrome', 'Google Chrome', const StreamChoice('duocolor', 'adaptive', 5));
  final raw = jsonDecode(f('apps.json').readAsStringSync());
  expect(raw, {'version': 1, 'apps': [{'ids': ['com.google.Chrome'], 'stream': {'mode': 'duocolor', 'density': 'adaptive', 'fps': 5}}]});
  expect(AppProfileStore.load(dir.path, builtinJson).resolve('com.google.chrome').stream,
      const StreamChoice('duocolor', 'adaptive', 5));
  expect(f('apps.json.tmp').existsSync(), isFalse);
});

test('addRule goes first and copies built-in rules once; a new app gets its name', () {
  final s = AppProfileStore(dir.path);
  s.addRule('com.x', 'X', const WindowRule(title: 'a', action: RuleAction.hide));
  s.addRule('com.x', 'X', const WindowRule(title: 'b', action: RuleAction.noComposer));
  expect(s.mine.single.name, 'X');
  expect(s.mine.single.windows!.map((r) => r.title), ['b', 'a']);
});

test('removeHideRule removes the first hide rule that matches, keeps the rest', () {
  final s = AppProfileStore(dir.path, mine: [AppProfile(ids: ['a'], windows: [
    const WindowRule(title: 'x*', action: RuleAction.noComposer),
    const WindowRule(title: 'x*', action: RuleAction.hide),
    const WindowRule(action: RuleAction.hide),
  ])]);
  expect(s.removeHideRule('a', w(2, title: 'x1'), isMain: false), isTrue);
  expect(s.mine.single.windows!.length, 2);
  expect(s.mine.single.windows!.last, const WindowRule(action: RuleAction.hide));
});

test('snapshot / restore undoes a change, on disk too', () {
  final s = AppProfileStore(dir.path);
  final before = s.snapshot();
  s.addRule('a', 'A', const WindowRule(action: RuleAction.hide));
  s.restore(before);
  expect(s.mine, isEmpty);
  expect(jsonDecode(f('apps.json').readAsStringSync())['apps'], isEmpty);
});

test('rows: built-in, changed, mine and a duplicate', () {
  final s = AppProfileStore(dir.path,
      builtin: [AppProfile(ids: ['b1'], name: 'B1', tested: false), AppProfile(ids: ['b2'], name: 'B2', tested: false)],
      mine: [AppProfile(ids: ['B2'], fps: 5), AppProfile(ids: ['m'], name: 'M'), AppProfile(ids: ['m'], name: 'M2')]);
  final rows = s.rows();
  expect(rows.map((r) => (r.name, r.source)), [('B1', ProfileSource.builtin), ('B2', ProfileSource.changed),
      ('M', ProfileSource.mine), ('M2', ProfileSource.mine)]);
  expect(rows[1].tested, isFalse);
  expect(rows[3].duplicateOf, 'M');
  expect(rows.map((r) => sourceLabel(r.source)).toSet(), {'内置', '内置 + 我改过', '我的'});
});

test('restoreBuiltin drops every profile of mine sharing an id', () {
  final b = AppProfile(ids: ['b', 'b.exe'], name: 'B');
  final s = AppProfileStore(dir.path, builtin: [b], mine: [AppProfile(ids: ['B.EXE'], fps: 1), AppProfile(ids: ['z'])]);
  s.restoreBuiltin(b);
  expect(s.mine.map((p) => p.ids.first), ['z']);
});

test('a save that fails keeps the change in memory and reports it', () {
  Process.runSync('chmod', ['555', dir.path]);
  final s = AppProfileStore(dir.path);
  var told = 0;
  s.addListener(() => told++);
  s.addRule('a', 'A', const WindowRule(action: RuleAction.hide));
  expect(s.problem, appsSaveProblem);
  expect(s.mine.length, 1);
  expect(told, 1);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test --timeout 60s test/ui/app_profile_store_test.dart`
Expected: FAIL

- [ ] **Step 3: 在 `gui/lib/ui/app_profile_store.dart` 实现**（文件读写照抄 `workspace_store.dart` 的 `loadWorkspace`/`saveWorkspace` 两段，换文件名和提示）

- [ ] **Step 4: 跑测试确认通过；`flutter analyze` 无问题**

- [ ] **Step 5: 改《配置规范总览》§2.5**：删掉「（状态：设计已确认，代码在 `feat/app-profiles` 上实施中；实施完成时把代码位置补进这一节。）」这一行；在格式那段后面照 §2.3 的写法补一段「谁读写」：`AppProfileStore.load`（`gui/lib/ui/app_profile_store.dart:<行>`，GUI 启动时读一次）、保存（`同文件:<行>`，临时文件 + 改名）、读不出时改名 `apps.json.bad` 并提示「app 配置没有读到，已从空白开始」；GUI 里改它的入口：标签右键、串流菜单、设备页 ⋯、本机页「app 配置」。行号用实际代码里的。

- [ ] **Step 6: 提交**（文档和代码同一个提交）

```bash
git add gui/lib/ui/app_profile_store.dart gui/test/ui/app_profile_store_test.dart docs/superpowers/specs/2026-11-13-rapp-config-reference.md
git commit -m "feat(gui): app profile store: apps.json with .bad, edits and rows"
```

---

### Task 5: 会话里生效：窗口过滤、输入区、发完补回车（Dart）

**Files:**
- Modify: `gui/lib/embed/remote_session.dart`
- Modify: `gui/lib/embed/composer_model.dart`（`onAllSent`、`returnKeyCode`）
- Modify: `gui/lib/embed/composer_bar.dart`（`composerLayer` 看 `composerAllowed`）
- Modify: `gui/lib/embed/picture.dart:303`（`popupsFor(widget.session.shown, win.id)`）
- Test: `gui/test/embed/remote_session_test.dart`、`gui/test/embed/composer_model_test.dart`、`gui/test/embed/composer_bar_test.dart`

**Interfaces:**
- Consumes: Task 1 `ResolvedProfile`、`AfterSend`、`RuleAction`；Task 3 `MainWindowTracker`、`applyHide`、`actionFor`。
- Produces:
  - `ComposerModel({this.onDrop, this.onAllSent})`，`final VoidCallback? onAllSent;` —— 在 `done(sent, failure)` 里，当有快照、`failure == null`、`sent > 0` 且 `sent == 快照块数 + (快照文字非空 ? 1 : 0)` 时调用一次（不管草稿是否改过）。`const returnKeyCode = 36;`
  - `RemoteSession(sid, appName, {..., this.appId = '', VoidCallback? onReturn})`：
    - `final String appId;` `ResolvedProfile get profile;` `void setProfile(ResolvedProfile p)`（重算 + notify）
    - `List<RemoteWindow> get shown;` `List<RemoteWindow> get hidden;` `Set<int> get hiddenIds`（`windows` 里不在 `shown` 的 id，给 runner）；`bool isMain(int id)`；`bool get hiddenFocused`（`hidden` 里有 `focused` 的）
    - `void showOnce(int id)`（加进本会话的「这次显示」集合，重算 + notify）
    - `bool get composerAllowed` = `profile.composer` 且当前标签不是 `noComposer`（`actionFor(profile.windows, 当前窗口, isMain: isMain(id))`）
    - `windows` 不变（A 的整张表）；`tabs.update(shown)`；`WindowsEvent`、`setProfile`、`showOnce` 三处都走同一个 `_refilter()`。
    - composer 的 `onAllSent`：`profile.afterSend == AfterSend.pressReturn` 时调 `onReturn`。
  - `composerLayer`：两个 `ListenableBuilder` 都监听 `session`；`!session.composerAllowed` 时都画 `SizedBox.shrink()`，不改 `composer.open`（草稿和打开状态都留着，换到允许的标签自己回来，规格 §3.3）。

- [ ] **Step 1: 写失败的测试**

`composer_model_test.dart`：

```dart
test('onAllSent only after every piece went', () {
  var n = 0;
  final m = ComposerModel(onAllSent: () => n++);
  m.text = 'hi';
  m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
  m.send();
  m.done(1, 'A 上贴不进去'); // block went, text failed
  expect(n, 0);
  m.send();
  m.done(1, ''); // cancelled
  expect(n, 0);
  m.send();
  m.done(0, null); // link down (linkDown)
  expect(n, 0);
  m.send();
  m.done(2, null);
  expect(n, 1);
  m.done(0, null); // a done without a send round
  expect(n, 1);
});

test('blocks only: one piece, one Return', () {
  var n = 0;
  final m = ComposerModel(onAllSent: () => n++);
  m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
  m.send();
  m.done(1, null);
  expect(n, 1);
});
```

`remote_session_test.dart`（`w(...)` 同 Task 3；`rs.apply(WindowsEvent(1, [...]))`）：

```dart
const hideFloating = ResolvedProfile(name: 'X', windows: [WindowRule(kind: WindowKind.floating, action: RuleAction.hide)]);

test('a hide rule keeps the window out of the tabs and counts it', () {
  final rs = RemoteSession(1, 'X', appId: 'x')..setProfile(hideFloating);
  rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.floating)]));
  expect(rs.tabs.tabs.map((e) => e.id), [1]);
  expect(rs.hidden.map((e) => e.id), [2]);
  expect(rs.hiddenIds, {2});
  expect(rs.windows.length, 2); // A's table is kept whole
});

test('hiding the current tab moves to the most recent shown one', () {
  final rs = RemoteSession(1, 'X');
  rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.floating), w(3)]));
  rs.selectWindow(3);
  rs.selectWindow(2);
  rs.setProfile(hideFloating);
  expect(rs.currentWindow, 3);
});

test('showOnce brings it back as the current tab; the count drops', () {
  final rs = RemoteSession(1, 'X')..setProfile(hideFloating);
  rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.floating)]));
  rs.showOnce(2);
  expect(rs.tabs.tabs.map((e) => e.id), [1, 2]);
  expect(rs.currentWindow, 2);
  expect(rs.hidden, isEmpty);
});

test('hiddenFocused when A focuses a hidden window', () {
  final rs = RemoteSession(1, 'X')..setProfile(hideFloating);
  rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.floating, focused: true)]));
  expect(rs.hiddenFocused, isTrue);
});

test('composer: off for the app, or for a noComposer tab, back on another tab; the draft stays', () {
  final rs = RemoteSession(1, 'X')
    ..setProfile(const ResolvedProfile(name: 'X', windows: [WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer)]));
  rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.dialog)])); // 2 is new: current
  rs.composer.text = '草稿';
  rs.composer.open = true;
  expect(rs.composerAllowed, isFalse);
  rs.selectWindow(1);
  expect(rs.composerAllowed, isTrue);
  expect(rs.composer.open, isTrue);
  expect(rs.composer.text, '草稿');
  rs.setProfile(const ResolvedProfile(name: 'X', composer: false));
  expect(rs.composerAllowed, isFalse);
});

test('afterSend return calls onReturn after a full round; none does not', () {
  var n = 0;
  final rs = RemoteSession(1, 'X', onReturn: () => n++)..setProfile(const ResolvedProfile(name: 'X', afterSend: AfterSend.pressReturn));
  rs.composer.text = 'go';
  rs.composer.send();
  rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
  expect(n, 1);
  rs.setProfile(ResolvedProfile.generic);
  rs.composer.text = 'go';
  rs.composer.send();
  rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
  expect(n, 1);
});
```

`composer_bar_test.dart`（widget 测试，舞台照该文件现有的 `composerLayer` 测试搭）：

```dart
testWidgets('no 「输入」 button and no bar while composerAllowed is false; both come back', (tester) async {
  // session with a noComposer dialog current, composer open with text
  expect(find.byKey(const Key('composer-bar')), findsNothing);
  expect(find.byKey(const Key('composer-open')), findsNothing);
  session.selectWindow(1); await tester.pump();
  expect(find.byKey(const Key('composer-bar')), findsOneWidget);
  expect(find.text('草稿'), findsOneWidget);
});
```

- [ ] **Step 2: 跑这三个测试文件确认失败**

- [ ] **Step 3: 按 Interfaces 改 `composer_model.dart`、`remote_session.dart`、`composer_bar.dart`、`picture.dart`**

- [ ] **Step 4: 跑全部 Flutter 测试确认通过（`stage_test`、`main_state_test` 等旧测试不变）；`flutter analyze` 无问题**

Run: `cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test --timeout 60s`

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/remote_session.dart gui/lib/embed/composer_model.dart gui/lib/embed/composer_bar.dart gui/lib/embed/picture.dart gui/test/embed/remote_session_test.dart gui/test/embed/composer_model_test.dart gui/test/embed/composer_bar_test.dart
git commit -m "feat(gui): sessions apply app profiles: hidden windows, composer, return after send"
```

---

### Task 6: runner 的 `set_hidden`（分离时也不显示被藏的窗口）

**Files:**
- Modify: `Sources/RappSession/Channel.swift`（`ChannelCommand.setHidden`、`known` 加 `"set_hidden"`、解析）
- Modify: `Sources/RappSession/Detach.swift`（`detachedWindows`）
- Modify: `gui/macos/Runner/SessionPlugin.swift`（`hidden` 表、三处用过滤后的表、会话结束时清掉）
- Modify: `gui/lib/embed/session_port.dart`（`setHidden`）
- Test: `Tests/RappSessionTests/DetachTests.swift`、`gui/test/embed/session_port_test.dart`

**Interfaces:**
- Produces:
  - Dart：`void setHidden(Object sid, List<int> windows) => _send('set_hidden', {'sid': sid, 'windows': windows});`
  - Swift：`case setHidden(sid: Int64, windows: [UInt32])`；`windows` 必须是非负、放得进 `UInt32` 的整数列表，否则 `ChannelError.bad("set_hidden")`。
  - Swift：`public func detachedWindows(_ windows: [SessionWindow], hidden: Set<UInt32>) -> [SessionWindow]` —— 去掉 `hidden` 里的，以及 `popupOwner(id, table:, fallback: nil)` 在 `hidden` 里的弹层；去掉后没有带标题栏的窗口而原来有 → 原样返回（R5）。
  - SessionPlugin：`private var hidden = [Int64: Set<UInt32>]()`；`.setHidden` 存下（空集合就删键）并在已分离时立刻 `detached[sid]?.update(detachedWindows(entry.windows, hidden: …))`；`detachSession` 的守卫和 `DetachedSession(windows:)`、`deliver(.windows)` 里的 `detached[sid]?.update(...)` 都用过滤后的表；`.closed` 时 `hidden[sid] = nil`。

- [ ] **Step 1: 写失败的测试**

`DetachTests.swift`（`info(id:parent:kind:)` 用该文件现有的造窗口表的帮手）：

```swift
func testSetHiddenChannelCommand() throws {
    XCTAssertEqual(try channelCommand("set_hidden", ["sid": 4, "windows": [7, 9]]), .setHidden(sid: 4, windows: [7, 9]))
    XCTAssertEqual(try channelCommand("set_hidden", ["sid": 4, "windows": []]), .setHidden(sid: 4, windows: []))
    XCTAssertThrowsError(try channelCommand("set_hidden", ["sid": 4, "windows": [-1]]))
    XCTAssertThrowsError(try channelCommand("set_hidden", ["sid": 4, "windows": "7"]))
    XCTAssertThrowsError(try channelCommand("set_hidden", ["sid": 4]))
}

func testDetachedWindowsDropHiddenAndTheirPopups() {
    let table = [win(1), win(2, kind: .floating), win(5, parent: 2, kind: .menu), win(6, parent: 1, kind: .sheet), win(7, parent: 99, kind: .popover)]
    XCTAssertEqual(detachedWindows(table, hidden: [2]).map(\.info.id), [1, 6, 7])
    XCTAssertEqual(detachedWindows(table, hidden: []).map(\.info.id), [1, 2, 5, 6, 7])
}

func testDetachedWindowsShowAllWhenOnlyHiddenAreLeft() {
    let table = [win(1), win(5, parent: 1, kind: .menu)]
    XCTAssertEqual(detachedWindows(table, hidden: [1]).map(\.info.id), [1, 5])
}
```

`session_port_test.dart`：

```dart
test('setHidden sends set_hidden with the ids', () async {
  port.setHidden(3, [7, 9]);
  await pumpEventQueue();
  expect(port.calls.last, ('set_hidden', {'sid': 3, 'windows': [7, 9]}));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DetachTests` 和 `cd gui && $HOME/development/flutter/bin/flutter test --timeout 60s test/embed/session_port_test.dart`
Expected: FAIL

- [ ] **Step 3: 按 Interfaces 改四个源文件**（`Args` 里照 `path()` 加一个读 `[UInt32]` 的 `windows()`）

- [ ] **Step 4: 验证**

Run: `swift test && ./scripts/check.sh`（末行 `EXIT=0`）；`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test --timeout 60s`；`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`（编过即可，不启动）
Expected: 全部 PASS / 编译成功

- [ ] **Step 5: 提交**

```bash
git add Sources/RappSession/Channel.swift Sources/RappSession/Detach.swift gui/macos/Runner/SessionPlugin.swift gui/lib/embed/session_port.dart Tests/RappSessionTests/DetachTests.swift gui/test/embed/session_port_test.dart
git commit -m "feat(runner): set_hidden keeps hidden windows out of detached sessions"
```

---

### Task 7: `MainState` 接线：开流档位、马上生效、`set_hidden`、日志、各个动作

**Files:**
- Modify: `gui/lib/ui/main_state.dart`
- Modify: `gui/lib/main.dart`（读内置资源，建 store，传给 `MainState`）
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（只改 §2.5）
- Test: `gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 4 `AppProfileStore`；Task 5 `RemoteSession` 新成员；Task 6 `SessionPort.setHidden`。
- Produces（`MainState`）：
  - 构造参数 `AppProfileStore? profiles, void Function(String line)? log`；`late final AppProfileStore profiles`（没给就 `AppProfileStore.load(configDir, null)`）；`profiles.problem` 非空时进 `hint`（已有 workspace 提示时用 `；` 接在后面）。
  - `_openEmbedded` 新建记录时 `fresh.choice = profiles.resolve(app).stream`（重连不动 `r.choice`，R10）。
  - `_connect`：`RemoteSession(..., appId: r.app, onReturn: () { if (_liveSid(s.sid)) port!.key(s.sid, returnKeyCode, 0); })`，建好就 `setProfile(profiles.resolve(r.app))`；对上了配置（`name != null`）就 `log('rapp: app 配置「$name」')`。
  - `void _syncHidden(RemoteSession rs)`：`hiddenIds` 排序后和上次发的不同才 `port.setHidden`（只对 `_liveSid`）；`hidden.length` 和上次记的不同才 `log('rapp: app 配置「$name」：隐藏 $n 个窗口')`。`WindowsEvent` 之后、配置变化之后、`showHiddenOnce` 之后各调一次。
  - store 的 listener：每个 `remote` 里的会话 `setProfile(profiles.resolve(rs.appId))` + `_syncHidden`；`profiles.problem` 变成 `appsSaveProblem` 时进 `hint`；notify。
  - 当前会话上的动作（没有当前嵌入会话时什么都不做、返回 null/false）：
    - `VoidCallback? hideLike(int window)` —— 主窗口返回 null（R8）；否则 `snap = profiles.snapshot()`，`addRule(appId, appName, WindowRule(kind: w.kind, title: w.title, action: RuleAction.hide))`，返回 `() => profiles.restore(snap)`。
    - `VoidCallback? noComposerLike(int window)` —— 同上，`action: noComposer`，主窗口时 `child: false`。
    - `bool isMainWindow(int window)`
    - `void showHiddenOnce(int window)`
    - `void unhide(int window)` —— `profiles.removeHideRule(...)`；hint `不再隐藏这类窗口`。
    - `void rememberStream()` —— `profiles.rememberStream(appId, appName, rs.choice)`；hint `已记为 〈profile.name ?? appName〉 的默认`。
  - `main.dart`：`String? builtin; try { builtin = await rootBundle.loadString('assets/app_profiles.json'); } catch (_) {}`，`MainState(..., profiles: AppProfileStore.load(cfg, builtin))`。

- [ ] **Step 1: 写失败的测试**（在 `main_state_test.dart` 的嵌入会话组里，照现有 `FakeSessionPort` + `FakeTransport` 的开会话写法；`profiles: AppProfileStore(tmp.path, builtin: [...])`，`log: lines.add`）

```dart
test('a new session starts with the profile stream; reconnect keeps the session choice', () async {
  // builtin: Terminal duogray/adaptive/15
  await open('com.apple.Terminal');
  expect(port.calls.firstWhere((c) => c.$1 == 'start').$2, containsPair('mode', 'duogray'));
  s.currentRemote!.setChoice(const StreamChoice('color16', 'original', 30));
  // disconnect + reconnect (existing helpers)
  expect(lastStart(), allOf(containsPair('mode', 'color16'), containsPair('fps', 30)));
});

test('no profile: the generic start choice', () async {
  await open('com.unknown');
  expect(port.calls.firstWhere((c) => c.$1 == 'start').$2, allOf(containsPair('mode', 'color16'), containsPair('fps', 15)));
});

test('hideLike hides at once, sends set_hidden, and undo brings it back', () async {
  await open('com.google.Chrome');
  port.emit(WindowsEvent(sid, [w(1), w(2, kind: WindowKind.floating, title: 'Downloads')]));
  final undo = s.hideLike(2)!;
  expect(s.currentRemote!.tabs.tabs.map((e) => e.id), [1]);
  expect(port.calls.last, ('set_hidden', {'sid': sid, 'windows': [2]}));
  expect(s.profiles.mine.single.windows!.first, const WindowRule(kind: WindowKind.floating, title: 'Downloads', action: RuleAction.hide));
  undo();
  expect(s.currentRemote!.tabs.tabs.map((e) => e.id), [1, 2]);
  expect(port.calls.last, ('set_hidden', {'sid': sid, 'windows': <int>[]}));
});

test('hideLike on the main window does nothing; noComposerLike there writes child: false', () async {
  await open('com.google.Chrome');
  port.emit(WindowsEvent(sid, [w(1), w(2)]));
  expect(s.hideLike(1), isNull);
  s.noComposerLike(1);
  expect(s.profiles.mine.single.windows!.first.child, isFalse);
});

test('a profile change while detached sends set_hidden at once', () async {
  // open, windows [1, 2 floating], detach (DetachedEvent true)
  s.profiles.addRule('com.google.Chrome', 'Chrome', const WindowRule(kind: WindowKind.floating, action: RuleAction.hide));
  expect(port.calls.last, ('set_hidden', {'sid': sid, 'windows': [2]}));
});

test('set_hidden is not sent again for the same set', () async {
  // hide rule present; emit the same table twice
  expect(port.calls.where((c) => c.$1 == 'set_hidden').length, 1);
});

test('showHiddenOnce and unhide', () async {
  // rule hides 2
  s.showHiddenOnce(2);
  expect(s.currentRemote!.hidden, isEmpty);
  s.unhide(2);
  expect(s.profiles.resolve('com.google.Chrome').windows, isEmpty);
});

test('afterSend return sends key 36 after a full round only', () async {
  // mine: afterSend pressReturn
  rs.composer.text = 'ls';
  rs.composer.send();
  port.emit(ComposerStateEvent(sid, done: const ComposerDone(1, null)));
  expect(port.calls.where((c) => c.$1 == 'key').single.$2, {'sid': sid, 'keyCode': 36, 'modifiers': 0});
  rs.composer.text = 'x';
  rs.composer.send();
  port.emit(ComposerStateEvent(sid, done: const ComposerDone(0, 'A 上贴不进去')));
  expect(port.calls.where((c) => c.$1 == 'key').length, 1);
});

test('rememberStream writes the current choice into my profile', () async {
  await open('com.apple.Terminal');
  s.currentRemote!.setChoice(const StreamChoice('duocolor', 'original', 5));
  s.rememberStream();
  expect(s.profiles.resolve('com.apple.Terminal').stream, const StreamChoice('duocolor', 'original', 5));
  expect(s.hint, '已记为 终端 的默认');
});

test('logs name the profile and the count, never a title or a pattern (D9)', () async {
  // mine: Chrome, rule {kind: floating, title: '*秘密*', action: hide}
  await open('com.google.Chrome');
  port.emit(WindowsEvent(sid, [w(1, title: '我的秘密文件.pdf'), w(2, kind: WindowKind.floating, title: '秘密 下载')]));
  expect(lines, ['rapp: app 配置「Chrome」', 'rapp: app 配置「Chrome」：隐藏 1 个窗口']);
  for (final l in lines) {
    expect(l, isNot(contains('秘密')));
    expect(l, isNot(contains('pdf')));
    expect(l, isNot(contains('*')));
  }
});

test('a broken apps.json at start shows the hint', () {
  File('${tmp.path}/apps.json').writeAsStringSync('[');
  final st = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs());
  expect(st.hint, contains(appsLoadProblem));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test --timeout 60s test/ui/main_state_test.dart`
Expected: FAIL

- [ ] **Step 3: 按 Interfaces 改 `main_state.dart` 和 `main.dart`**

- [ ] **Step 4: 跑全部 Flutter 测试确认通过；`flutter analyze` 无问题**

- [ ] **Step 5: 补《配置规范总览》§2.5**：内置文件在哪读（`gui/lib/main.dart:<行>`）；加一行「生效」：在 GUI 里改马上对已开的会话生效（窗口规则、输入区、发送后），画面只对新开的会话生效（R10）；手改文件要退出 GUI 再改、重新打开生效（同 §2.3）。核一遍 Task 4 写的行号，漂了就改。

- [ ] **Step 6: 提交**

```bash
git add gui/lib/ui/main_state.dart gui/lib/main.dart gui/test/ui/main_state_test.dart docs/superpowers/specs/2026-11-13-rapp-config-reference.md
git commit -m "feat(gui): MainState applies app profiles: start stream, live rules, set_hidden, logs"
```

---

### Task 8: 标签栏：右键两项、「已隐藏 N 个」

**Files:**
- Modify: `gui/lib/ui/tab_chip.dart`（`onSecondaryTapUp`）
- Modify: `gui/lib/ui/top_bar.dart`
- Test: `gui/test/ui/top_bar_test.dart`

**Interfaces:**
- Consumes: Task 7 的 `hideLike`、`noComposerLike`、`isMainWindow`、`showHiddenOnce`、`unhide`；`RemoteSession.hidden`、`hiddenFocused`。
- Produces:
  - `TabChip` 新增可选 `void Function(Offset globalPosition)? onSecondaryTap`（`InkWell.onSecondaryTapUp`）。
  - 标签栏显示条件改成 `tabs.length >= 2 || hidden.isNotEmpty`。每个窗口标签右键 → `showMenu`：「隐藏这类窗口」（`isMainWindow` 时 `enabled: false`）、「这个窗口不要输入区」。选了以后 `ScaffoldMessenger` 出 `SnackBar`：文字分别为「已隐藏，可在 app 配置里改」「已关掉这个窗口的输入区，可在 app 配置里改」，`SnackBarAction(label: '撤销', onPressed: undo)`。
  - 末尾 `TabChip(key: Key('hidden-tabs'), label: '已隐藏 ${n} 个', selected: rs.hiddenFocused)`；点开 → `showMenu` 每个被藏的窗口一组：一行不可点的窗口名（`title` 空就用 app 名），两项「这次显示」「不再隐藏」。

- [ ] **Step 1: 写失败的测试**（照 `top_bar_test.dart` 现有搭法：真 `MainState` + `FakeSessionPort`）

```dart
testWidgets('right-click a tab, 隐藏这类窗口: the tab goes, a snackbar offers 撤销', (tester) async {
  // windows [1 main 'Main', 2 floating 'Downloads', 3 'Other']
  await tester.tap(find.text('Downloads'), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
  await tester.tap(find.text('隐藏这类窗口'));
  await tester.pumpAndSettle();
  expect(find.text('Downloads'), findsNothing);
  expect(find.text('已隐藏 1 个'), findsOneWidget);
  expect(find.text('已隐藏，可在 app 配置里改'), findsOneWidget);
  await tester.tap(find.text('撤销'));
  await tester.pumpAndSettle();
  expect(find.text('Downloads'), findsOneWidget);
  expect(find.text('已隐藏 1 个'), findsNothing);
});

testWidgets('隐藏这类窗口 is greyed for the main window', (tester) async {
  await tester.tap(find.text('Main'), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
  final item = tester.widget<PopupMenuItem<Object?>>(find.ancestor(of: find.text('隐藏这类窗口'), matching: find.byType(PopupMenuItem<Object?>)));
  expect(item.enabled, isFalse);
});

testWidgets('已隐藏 N 个 shows with a single tab; 这次显示 and 不再隐藏 work', (tester) async {
  // rule hides 2; windows [1, 2]
  expect(find.text('已隐藏 1 个'), findsOneWidget);
  await tester.tap(find.byKey(const Key('hidden-tabs')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('这次显示'));
  await tester.pumpAndSettle();
  expect(find.text('w2'), findsOneWidget);
  // fresh table with the rule again, then 不再隐藏 removes the rule
});

testWidgets('已隐藏 N 个 is selected while A focuses a hidden window', (tester) async {
  final chip = tester.widget<TabChip>(find.byKey(const Key('hidden-tabs')));
  expect(chip.selected, isTrue);
});
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 按 Interfaces 改 `tab_chip.dart`、`top_bar.dart`**

- [ ] **Step 4: 跑全部 Flutter 测试确认通过；`flutter analyze` 无问题**

- [ ] **Step 5: 提交**

```bash
git add gui/lib/ui/tab_chip.dart gui/lib/ui/top_bar.dart gui/test/ui/top_bar_test.dart
git commit -m "feat(gui): tab right-click rules and the 已隐藏 N 个 chip"
```

---

### Task 9: 配置页（表单）

**Files:**
- Create: `gui/lib/pages/app_profile_page.dart`
- Test: `gui/test/ui/app_profile_page_test.dart`

**Interfaces:**
- Consumes: Task 1 模型和 `resolveProfile`；Task 4 store。
- Produces:
  - `class AppProfilePage extends StatefulWidget { const AppProfilePage({super.key, required this.store, this.appId, this.appName = ''}); }` —— `appId == null` 是「新建」。
  - `Future<void> openAppProfilePage(BuildContext context, AppProfileStore store, {String? appId, String appName = ''})` —— `Navigator.push(MaterialPageRoute(...))`。
  - 页面状态：`draft` = `store.mineFor(appId)?.copy()` ?? `AppProfile(ids: builtinFor(appId)?.ids 的拷贝 ?? (appId == null ? [] : [appId]))`；`base` = `resolveProfile(appId, mine: const [], builtin: store.builtin)`。每个字段显示 `draft.x ?? base.x`，`draft.x == null` 时用 `t.muted` 颜色（「灰着」），改了写进 `draft.x`。
  - 页面标题 `app 配置 · 〈名〉`（新建时 `新建 app 配置`）；有内置且 `base.tested == false` 时标题旁 `未实测`。
  - 字段（文案照抄）：
    - `名字`（`TextField`，`maxLength: 40`）；`标识（用逗号分开）`（有内置时只读）。
    - 画面：`档位` 下拉 `双色·灰度` / `双色·彩色` / `高彩`；`密度` 下拉 `省流 1x` / `自适应` / `原画`；`帧率` 下拉 `1 fps` / `5 fps` / `15 fps` / `30 fps`。
    - 发送后：两个单选 `只贴，不按回车` / `贴完按回车`。
    - 输入区：开关 `显示「输入」`。
    - 窗口规则：每条一行——种类下拉（`任意种类`、`普通窗口`、`对话框`、`浮动窗口`、`附着对话框`、`弹出框`、`菜单`、`提示条`，对应 null 和 `WindowKind` 七个），标题输入框（提示 `标题，* 配任意字；空着就不看标题`），动作下拉（`隐藏` / `不要输入区`），按钮 `上移`、`下移`、`删除`；列表下 `加一条`。种类和标题都空 → 行下提示 `这条会作用于这个 app 的所有子窗口`；动作是隐藏且种类是对话框或附着对话框 → `它可能在等你回应`。规则的 `child` 原样保留，不在页面上改。
    - 底部 `保存`、`取消`。`ids` 为空时 `保存` 不存，显示 `至少写一个标识`。`draft` 一个字段都没设、原来也没有我的配置 → 不写文件，直接关页。否则 `store.put(draft, replacing: 原来的 mine)` 后关页。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('built-in values show grey; changing one saves only that field', (tester) async {
  // store: builtin Chrome color16/adaptive/15 tested false; open page for com.google.Chrome
  expect(find.text('未实测'), findsOneWidget);
  final mode = tester.widget<Text>(find.text('高彩').first);
  expect(mode.style?.color, RappTokens.of(tester.element(find.text('高彩').first)).muted);
  // pick 帧率 → 5 fps, tap 保存
  expect(store.mine.single.toJson(), {'ids': ['com.google.Chrome'], 'stream': {'fps': 5}});
});

testWidgets('saving without changes writes nothing', (tester) async {
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
  expect(store.mine, isEmpty);
  expect(File('${dir.path}/apps.json').existsSync(), isFalse);
});

testWidgets('rules: add, warnings, move and delete', (tester) async {
  await tester.tap(find.text('加一条'));
  await tester.pumpAndSettle();
  expect(find.text('这条会作用于这个 app 的所有子窗口'), findsOneWidget);
  // set kind 对话框, action 隐藏
  expect(find.text('它可能在等你回应'), findsOneWidget);
  // add a second rule with title 'b', tap 上移 on it, save
  expect(store.mine.single.windows!.first.title, 'b');
});

testWidgets('new: no ids, no save', (tester) async {
  // openAppProfilePage(context, store) with no appId
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
  expect(find.text('至少写一个标识'), findsOneWidget);
  expect(store.mine, isEmpty);
});

testWidgets('no English words like profile or regex on the page', (tester) async {
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    expect(t.data?.toLowerCase() ?? '', isNot(anyOf(contains('profile'), contains('regex'))));
  }
});
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现 `gui/lib/pages/app_profile_page.dart`**（按钮用 `RappButton`，确认类用现有控件；颜色用 `RappTokens`）

- [ ] **Step 4: 跑全部 Flutter 测试确认通过；`flutter analyze` 无问题**

- [ ] **Step 5: 提交**

```bash
git add gui/lib/pages/app_profile_page.dart gui/test/ui/app_profile_page_test.dart
git commit -m "feat(gui): app profile form page"
```

---

### Task 10: 入口：串流菜单、设备页 ⋯、本机页「app 配置」一节

**Files:**
- Modify: `gui/lib/embed/stream_menu.dart`（`StreamMenuAnchor`/`StreamMenu` 加两个回调和两项）
- Modify: `gui/lib/ui/top_bar.dart`（把回调接上）
- Modify: `gui/lib/ui/devices_tab.dart`（`_AppRow` 加 ⋯）
- Create: `gui/lib/pages/app_profiles_section.dart`
- Modify: `gui/lib/ui/main_window.dart`（`_local()` 里在 `LocalSection` 下面放这一节）
- Test: `gui/test/embed/stream_menu_test.dart`、`gui/test/ui/devices_tab_test.dart`、`gui/test/ui/app_profiles_section_test.dart`

**Interfaces:**
- Consumes: Task 7 `rememberStream`、`profiles`；Task 9 `openAppProfilePage`；Task 4 `rows()`、`remove`、`restoreBuiltin`、`sourceLabel`；`openFolderCommand`（`service_control.dart`）。
- Produces:
  - `StreamMenuAnchor`/`StreamMenu` 新增可选 `VoidCallback? onRememberStream`、`VoidCallback? onOpenProfile`。在「帧率」组之后、「A 的剪贴板」之前：`_Item('记为这个 app 的默认', enabled: onRememberStream != null, ...)`、`_Item('app 配置…', enabled: onOpenProfile != null, ...)`；断开 / 重连中（`reduced`）不显示（和其他画面组一样）。`top_bar.dart` 传 `state.rememberStream` 和 `() => openAppProfilePage(context, state.profiles, appId: rec.app, appName: cur.appName)`。
  - `_AppRow` 新增 `VoidCallback onProfile`，在「设为常用」前放 `IconButton(key: Key('profile-$app'), icon: Icon(Icons.more_horiz), tooltip: 'app 配置', constraints: 48×48)`。
  - `class AppProfilesSection extends StatelessWidget { const AppProfilesSection({super.key, required this.store, required this.openFolder}); final AppProfileStore store; final Future<void> Function(String dir) openFolder; }` —— `SectionCard(title: 'app 配置', action: 新建 + 打开配置文件夹)`；每行：名字（粗）、标识（等宽，逗号连）、来源 `sourceLabel`、`tested == false` 时 `未实测`、`duplicateOf` 时 `和 〈名〉 重复`；按钮 `改`（`openAppProfilePage(context, store, appId: ids.first, appName: name)`），来源是 `mine` 时 `ConfirmButton(label: '删除')` → `store.remove(row.mine!)`，来源是 `changed` 时 `ConfirmButton(label: '恢复内置')` → `store.restoreBuiltin(row.builtin!)`。`store.problem` 非空时顶上一行显示它。`打开配置文件夹` → `openFolder(store.dir)`。

- [ ] **Step 1: 写失败的测试**

`stream_menu_test.dart`：

```dart
testWidgets('记为这个 app 的默认 and app 配置… call back and close the menu', (tester) async {
  await tester.tap(find.text('记为这个 app 的默认'));
  expect(remembered, 1);
  expect(closed, 1);
  await tester.tap(find.text('app 配置…'));
  expect(opened, 1);
});

testWidgets('a disconnected menu has neither item', (tester) async {
  expect(find.text('记为这个 app 的默认'), findsNothing);
  expect(find.text('app 配置…'), findsNothing);
});
```

`devices_tab_test.dart`：

```dart
testWidgets('⋯ on an app row opens its app 配置 page', (tester) async {
  await tester.tap(find.byKey(const Key('profile-com.apple.Terminal')));
  await tester.pumpAndSettle();
  expect(find.byType(AppProfilePage), findsOneWidget);
});
```

`app_profiles_section_test.dart`：

```dart
testWidgets('rows show source, 未实测 and duplicates', (tester) async {
  // store as in Task 4's rows test
  expect(find.text('内置'), findsOneWidget);
  expect(find.text('内置 + 我改过'), findsOneWidget);
  expect(find.text('我的'), findsNWidgets(2));
  expect(find.text('未实测'), findsNWidgets(2));
  expect(find.text('和 M 重复'), findsOneWidget);
});

testWidgets('恢复内置 and 删除 need a second tap', (tester) async {
  await tester.tap(find.text('恢复内置'));
  await tester.pump();
  expect(store.mine.length, 3);
  await tester.tap(find.text('再点一次确认'));
  await tester.pump();
  expect(store.mine.length, 2);
});

testWidgets('打开配置文件夹 opens the store dir', (tester) async {
  await tester.tap(find.text('打开配置文件夹'));
  expect(openedDirs, [dir.path]);
});

testWidgets('a load problem shows at the top', (tester) async {
  // store with problem: appsLoadProblem
  expect(find.text(appsLoadProblem), findsOneWidget);
});
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 按 Interfaces 改 / 建这五个源文件**（`main_window.dart` 里 `openFolder` 用文件里已有的 `_openFolder`）

- [ ] **Step 4: 跑全部 Flutter 测试确认通过；`flutter analyze` 无问题；`git checkout -- gui/pubspec.lock`（若被改）**

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/stream_menu.dart gui/lib/ui/top_bar.dart gui/lib/ui/devices_tab.dart gui/lib/pages/app_profiles_section.dart gui/lib/ui/main_window.dart gui/test/embed/stream_menu_test.dart gui/test/ui/devices_tab_test.dart gui/test/ui/app_profiles_section_test.dart
git commit -m "feat(gui): app 配置 entry points: stream menu, device row, 本机 section"
```

---

### Task 11: 实机检查（用户同意并安排后才跑；执行者不自己跑）

**前提：** 用户明确同意，并说好用哪台 A、哪台 B、装好的 rapp 版本。不动 `/Applications/rapp.app`、正在跑的 rapp-service，除非用户自己去装。

- [ ] **Step 1:** 在 B 上开 A 的 Chrome：串流菜单的档位是「高彩 / 自适应 / 15」（内置配置）；本机页「app 配置」里 Chrome 一行写「内置」「未实测」。
- [ ] **Step 2:** 在 Chrome 里打开「下载」或设置这类子窗口 → 标签右键「隐藏这类窗口」：标签消失，「已隐藏 1 个」出现，SnackBar 有「撤销」；点「已隐藏 1 个」→「这次显示」，窗口回来。
- [ ] **Step 3:** 分离（⌃⌘D）：被藏的窗口没有自己的独立窗口；放回舞台后照常。
- [ ] **Step 4:** 把某个对话框设成「这个窗口不要输入区」：切到它时「输入」按钮和输入区消失，切回主窗口时出现，草稿还在。
- [ ] **Step 5:** 配置页给终端选「贴完按回车」：在输入区发 `echo hi`，A 的终端执行了这条命令。
- [ ] **Step 6:** 看 GUI 的 stderr：只有 `rapp: app 配置「Chrome」` 和 `…：隐藏 1 个窗口` 这类行，没有窗口标题。
- [ ] **Step 7:** 把结果告诉用户；对上了的 app 由用户决定要不要在 `app_profiles.json` 里去掉 `"tested": false`（另起提交）。
