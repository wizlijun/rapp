# 总览设备列系统图标 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 总览每一列「● 在线」那一行最前面画出这台设备的系统图标（macOS / Windows / Omarchy / Linux / iPad / iPhone / Android 手机 / Android 平板 / 未知）。

**Architecture:** 服务端在 `list_apps` 回复里报 `os`；hub 把它存进 `hosts.json` 并在 `hosts`/`apps` 事件里带出；GUI 取「这次探测到的 `os`，没有就用 hub 存的」，本机列由 GUI 自己判断；图标用 `CustomPainter` 自己画，颜色取主题 `muted`。

**Tech Stack:** Rust（rapp-service、rapp-hub、testkit）、Flutter/Dart（gui）、Swift（iOS 原生通道一处）。

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-device-os-marks-design.md`

## Global Constraints

- 字段名 `os`，取值只有：`macos` `windows` `omarchy` `linux` `ipados` `ios` `android-tablet` `android`；缺失或其他值 = 未知。
- 提示文字（逐字）：macOS、Windows、Omarchy、Linux、iPad、iPhone、Android 平板、Android 手机、系统未知。
- Omarchy 判断：路径 `/usr/share/omarchy/shell` 存在（服务端和 GUI 同一条规则）。
- 协议不升版本，只加字段；旧版本照样能连。
- hub 不做取值白名单，只拒绝非字符串、空串和超过 32 字节的值。
- 图标尺寸跟 `StatusLamp`：参数 `size` 默认 10，画布 `size * 1.3` 见方；线宽按 `k = size / 10` 缩放，描边约 `1.6 * k`。单色、静止、颜色 `RappTokens.muted`；不加 SVG/位图依赖。
- 「正在被接入」卡片不加图标，握手不改。
- Flutter 在 `~/development/flutter/bin/flutter`（不在 PATH）；跑完 Flutter 测试后把 `gui/pubspec.lock` 还原。
- Rust 测试一律 `cargo test --workspace --no-fail-fast`（testkit 对回复字段有整体断言）。
- 在 worktree `.worktrees/device-os-marks`、分支 `feat/device-os-marks` 上做；不合进 main（合并等用户看完图标截图）。

## Review Focus

1. 旧版本设备（回复没有 `os`）显示「未知」；设备降级后不再报 `os` 时，hub 存的旧值继续显示，不会突然变成未知。→ Task 3 `deviceColumns` 测试。
2. 将来出现不认识的取值（如 `freebsd`），GUI 显示「未知」，不抛异常。→ Task 3 `parseOs` 测试。
3. 对端报来坏值（数字、对象、1 KB 长串），hub 不存进 `hosts.json`，apps 事件也不带出，GUI 照常。→ Task 2 测试。
4. 探测进行中设备被删掉：`set_os` 不会把已删的设备写回 `hosts.json`。→ Task 2 测试。
5. 新 hub 写的带 `os` 的 `hosts.json` 被旧 hub 读，不报错（serde 忽略未知字段）。→ Task 2 测试。

---

### Task 1: 服务端在 `list_apps` 回复里报 `os`

**Files:**
- Modify: `rust/service/src/workers.rs`（`capabilities` 旁边）
- Modify: `rust/service/src/peer.rs:183-190`（`list_apps_reply`）及其测试 `list_apps_tests`
- Modify: `rust/testkit/tests/service.rs:378`

**Interfaces:**
- Produces: `pub fn os_name() -> &'static str`（`workers.rs`）；`pub(crate) fn os_from(target: &str, omarchy: bool) -> &'static str`；`list_apps` 回复多一个 `"os"` 字符串字段。

- [ ] **Step 1: 写失败测试**（`workers.rs` 里新 `#[cfg(test)] mod os_tests`）

```rust
#[test]
fn os_from_maps_targets() {
    assert_eq!(os_from("macos", false), "macos");
    assert_eq!(os_from("windows", false), "windows");
    assert_eq!(os_from("linux", false), "linux");
    assert_eq!(os_from("linux", true), "omarchy");
    assert_eq!(os_from("freebsd", false), "unknown");
}
```

再给 `list_apps_reply_carries_version` 加：`assert_eq!(r["os"], crate::workers::os_name());`

- [ ] **Step 2: 跑测试确认失败**

Run: `cd rust && cargo test -p rapp-service os_ list_apps_reply`
Expected: 编译失败，提示 `os_from` / `os_name` 未定义

- [ ] **Step 3: 实现**
`os_from`：按上面的映射写，`omarchy` 只在 `target == "linux"` 时起作用，其他 target 报 `"unknown"`。`os_name()` = `os_from(std::env::consts::OS, Path::new("/usr/share/omarchy/shell").exists())`，用 `std::sync::OnceLock` 缓存。`list_apps_reply` 的 `json!` 里加 `"os": crate::workers::os_name()`。

- [ ] **Step 4: 改 testkit 断言**
`rust/testkit/tests/service.rs:378`：先 `let os = r["os"].as_str().unwrap().to_owned();`，断言 `["macos","windows","linux","omarchy"].contains(&os.as_str())`，再把 `"os": os` 加进期望的 `json!` 里整体比较（开发机可能是 Omarchy，所以不写死）。

- [ ] **Step 5: 跑测试**

Run: `cd rust && cargo test --workspace --no-fail-fast 2>&1 | tail -30`
Expected: 除了 `rust/testkit/tests/hub.rs:71`（Task 2 会改）以外全部通过；如果 hub.rs:71 失败，原因必须只是多了 `os` 字段

- [ ] **Step 6: Commit**

```bash
git add rust/service/src/workers.rs rust/service/src/peer.rs rust/testkit/tests/service.rs
git commit -m "feat(service): list_apps reports the device's os"
```

---

### Task 2: hub 存下并转发 `os`

**Files:**
- Modify: `rust/hub/src/hosts.rs`（`Host`、`summary`、新 `set_os`、测试）
- Modify: `rust/hub/src/lib.rs:338-342`（`"apps"` 命令）、`:460-473`（`apps_event`）、`apps_event_tests`
- Modify: 所有字面构造 `Host { .. }` 的地方补 `os: None`：`hosts.rs:135,144,218`、`link.rs:610,635,644`、`upgrade.rs:323`
- Modify: `rust/testkit/tests/hub.rs:71`

**Interfaces:**
- Consumes: Task 1 回复里的 `"os"`。
- Produces: `Host.os: Option<String>`（serde default，`None` 不写）；`Hosts::set_os(&self, id: &str, os: &str) -> Result<bool>`；`hosts` 事件每行有 `os` 时带 `"os"`；`apps` 事件在回复的 `os` 合格时带 `"os"`。合格 = 字符串、非空、≤ 32 字节，写成 `fn valid_os(v: &Value) -> Option<&str>`（`lib.rs`），存储和事件共用。

- [ ] **Step 1: 写失败测试**（`hosts.rs` tests）

```rust
#[test]
fn os_is_listed_saved_and_set_only_on_a_saved_host() {
    let dir = tempfile::tempdir().unwrap();
    let hosts = Hosts::load(dir.path()).unwrap();
    hosts.upsert(host("a")).unwrap();
    assert!(hosts.set_os("1", "macos").unwrap());
    assert!(!hosts.set_os("1", "macos").unwrap());
    assert!(!hosts.set_os("gone", "macos").unwrap());
    assert!(hosts.get("gone").is_none());
    assert_eq!(hosts.summary(), json!([{"id": "1", "name": "a", "os": "macos"}]));
    assert_eq!(Hosts::load(dir.path()).unwrap().get("1").unwrap().os.as_deref(), Some("macos"));
    let h: Host = serde_json::from_str(r#"{"id":"2","name":"b"}"#).unwrap();
    assert_eq!(h.os, None);
}
```

在 `old_versions_ignore_route` 里（或照它新写一个 `old_versions_ignore_os`）：用测试里那个旧版 `Host` 结构去读带 `"os":"macos"` 的 JSON，能读出来。

`apps_event_tests` 加：

```rust
let ev = apps_event("m1", "lan", &json!({"apps": [], "os": "omarchy"}));
assert_eq!(ev["os"], "omarchy");
for bad in [json!(""), json!(7), json!({"x":1}), json!("x".repeat(33))] {
    let ev = apps_event("m1", "lan", &json!({"apps": [], "os": bad}));
    assert!(ev.get("os").is_none(), "{bad}");
}
assert!(valid_os(&json!("x".repeat(32))).is_some());
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd rust && cargo test -p rapp-hub os`
Expected: 编译失败（`set_os` / `os` 字段 / `valid_os` 不存在）

- [ ] **Step 3: 实现**
`Host` 加字段；`summary` 照 `fp` 的写法带出；`set_os` 照 `set_fp`（主机不在或值相同返回 `Ok(false)`，不写盘）。`apps_event` 里 `if let Some(os) = valid_os(&r["os"]) { ev["os"] = os.into(); }`。`"apps"` 命令拿到 `r` 后：`if let Some(os) = valid_os(&r["os"])` 就 `self.hosts.set_os(id, os)`，出错只记一条 warn 日志（照 `link.rs` `remember_fp` 的写法），不影响返回的事件。补齐所有 `Host { .. }` 字面量。

- [ ] **Step 4: 改 testkit 断言**
`rust/testkit/tests/hub.rs:71`：和 Task 1 一样先取出 `r["os"]`，断言在四个值之内，再放进期望的 `json!` 整体比较。之后再发一次 `{"cmd":"hosts"}`，断言 `r["hosts"][0]["os"]` 等于同一个值（证明存下来了）。

- [ ] **Step 5: 跑测试**

Run: `cd rust && cargo test --workspace --no-fail-fast 2>&1 | tail -30 && cargo clippy --workspace --all-targets -- -D warnings 2>&1 | tail -5`
Expected: 全部通过，clippy 无警告

- [ ] **Step 6: Commit**

```bash
git add rust/hub rust/testkit/tests/hub.rs
git commit -m "feat(hub): remember each host's os in hosts.json and pass it on"
```

---

### Task 3: GUI 数据：`DeviceOs`、解析、设备列

**Files:**
- Create: `gui/lib/ui/device_os.dart`
- Modify: `gui/lib/hub_client.dart`（`HubHost`、`AppList`、`hosts` 与 `host_added` 解析、`apps()`）
- Modify: `gui/lib/ui/overview_model.dart`（`DeviceColumn.os`、`deviceColumns` 新参数）
- Modify: `gui/lib/ui/main_state.dart`（构造参数 + 字段 `localOs`）
- Modify: `gui/lib/ui/overview.dart:48-54`（把 `state.localOs` 传给 `deviceColumns`）
- Test: `gui/test/ui/device_os_test.dart`（新建）、`gui/test/hub_client_test.dart`、`gui/test/ui/overview_model_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `hosts[].os`、`apps` 事件的 `os`。
- Produces:
  - `enum DeviceOs { macos, windows, omarchy, linux, ipad, iphone, androidTablet, androidPhone, unknown }`
  - `DeviceOs parseOs(String? wire)`：线上取值 → 枚举（`ipados`→`ipad`，`ios`→`iphone`，`android-tablet`→`androidTablet`，`android`→`androidPhone`），其他 → `unknown`
  - `String osWord(DeviceOs os)`：Global Constraints 里的提示文字
  - `DeviceOs localDeviceOs({String? os, bool Function(String path)? exists, double? shortestSide, String? iosIdiom})`：默认值分别取 `Platform.operatingSystem`、`FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound`、`PlatformDispatcher.instance.views.first` 的逻辑最短边、`null`。规则：`macos`/`windows` 直接对应；`linux` + 存在 `/usr/share/omarchy/shell` → `omarchy`，否则 `linux`；`ios` + idiom `'pad'` → `ipad`，`'phone'` → `iphone`，其他 → `unknown`；`android` + 最短边 ≥ 600 → `androidTablet`，否则 `androidPhone`；其他 → `unknown`。
  - `HubHost.os: String?`（具名可选参数 `os`）；`AppList.os: String?`
  - `DeviceColumn.os: DeviceOs`（必填）；`deviceColumns(..., DeviceOs localOs = DeviceOs.unknown)`
  - `MainState({..., DeviceOs? localOs})`，字段 `final DeviceOs localOs`（默认 `localDeviceOs()`）

- [ ] **Step 1: 写失败测试**

`device_os_test.dart`：

```dart
test('wire values map, anything else is unknown', () {
  expect(parseOs('macos'), DeviceOs.macos);
  expect(parseOs('windows'), DeviceOs.windows);
  expect(parseOs('omarchy'), DeviceOs.omarchy);
  expect(parseOs('linux'), DeviceOs.linux);
  expect(parseOs('ipados'), DeviceOs.ipad);
  expect(parseOs('ios'), DeviceOs.iphone);
  expect(parseOs('android-tablet'), DeviceOs.androidTablet);
  expect(parseOs('android'), DeviceOs.androidPhone);
  for (final w in [null, '', 'freebsd', 'MACOS']) expect(parseOs(w), DeviceOs.unknown, reason: '$w');
});

test('words', () {
  expect(DeviceOs.values.map(osWord),
      ['macOS', 'Windows', 'Omarchy', 'Linux', 'iPad', 'iPhone', 'Android 平板', 'Android 手机', '系统未知']);
});

test('this device', () {
  bool none(String _) => false;
  expect(localDeviceOs(os: 'macos', exists: none), DeviceOs.macos);
  expect(localDeviceOs(os: 'windows', exists: none), DeviceOs.windows);
  expect(localDeviceOs(os: 'linux', exists: none), DeviceOs.linux);
  expect(localDeviceOs(os: 'linux', exists: (p) => p == '/usr/share/omarchy/shell'), DeviceOs.omarchy);
  expect(localDeviceOs(os: 'ios', exists: none, iosIdiom: 'pad'), DeviceOs.ipad);
  expect(localDeviceOs(os: 'ios', exists: none, iosIdiom: 'phone'), DeviceOs.iphone);
  expect(localDeviceOs(os: 'ios', exists: none), DeviceOs.unknown);
  expect(localDeviceOs(os: 'android', exists: none, shortestSide: 800), DeviceOs.androidTablet);
  expect(localDeviceOs(os: 'android', exists: none, shortestSide: 400), DeviceOs.androidPhone);
  expect(localDeviceOs(os: 'fuchsia', exists: none), DeviceOs.unknown);
});
```

`hub_client_test.dart`：`hosts` 事件 `[{"id":"m1","name":"A","os":"macos"},{"id":"m2","name":"B"},{"id":"m3","name":"C","os":7}]` → `hosts.map((h) => h.os)` 为 `['macos', null, null]`；之后来一个不带 `os` 的 `host_added` `m1` → `os` 仍是 `'macos'`；`apps('m1')` 回复带 `"os":"windows"` → `AppList.os == 'windows'`，不带 → `null`。（照文件里已有的 hosts / apps 测试的 FakeTransport 写法。）

`overview_model_test.dart`：

```dart
test('os: fresh probe first, then what the hub kept, else unknown', () {
  final cols = deviceColumns(
    hosts: const [HubHost('m1', 'A', os: 'macos'), HubHost('m2', 'B', os: 'linux'), HubHost('m3', 'C')],
    probes: {
      'm1': DeviceProbe(Lamp.active, '在线', apps: const AppList('m1', 'lan', [], os: 'omarchy')),
      'm2': DeviceProbe(Lamp.active, '在线', apps: const AppList('m2', 'lan', [])), // downgraded: no os
    },
    entries: [se('gone', Lamp.disconnected)],
    name: (id) => id,
    localOs: DeviceOs.ipad,
  );
  expect(cols.map((c) => c.os),
      [DeviceOs.ipad, DeviceOs.omarchy, DeviceOs.linux, DeviceOs.unknown, DeviceOs.unknown]);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/device_os_test.dart test/hub_client_test.dart test/ui/overview_model_test.dart`
Expected: 编译失败（`DeviceOs` / `os` 未定义）

- [ ] **Step 3: 实现**
照 Interfaces 写。`hub_client.dart` 里 `os` 用已有的 `_version` 同样规则读（非空字符串，否则 null），可以把 `_version` 改个通用名复用。`host_added` 照 `lan`/`route` 保留 `was?.os`。`deviceColumns` 远端列 `os: parseOs(p?.apps?.os ?? h.os)`，只有会话知道的设备 `DeviceOs.unknown`，本机列 `localOs`。`MainState` 加构造参数，不传就是 `localDeviceOs()`。`overview.dart` 传 `localOs: state.localOs`。

- [ ] **Step 4: 跑测试**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/device_os_test.dart test/hub_client_test.dart test/ui/overview_model_test.dart test/ui/overview_test.dart test/ui/main_state_test.dart`
Expected: 全部通过

- [ ] **Step 5: Commit**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui/lib gui/test
git commit -m "feat(gui): read each device's os and work out this device's own"
```

---

### Task 4: iOS 本机分出 iPad 和 iPhone

**Files:**
- Modify: `gui/ios/Runner/IosPlugin.swift:48-51`（`handle` 里加 `"idiom"`）
- Modify: `gui/lib/ios_channel.dart`（加 `idiom()`）
- Modify: `gui/lib/main_ios.dart:52-56,88`（拿 idiom，传 `localOs`）
- Test: `gui/test/ios_channel_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `localDeviceOs`、`MainState(localOs:)`。
- Produces: 通道方法 `"idiom"` 返回 `"pad"` 或 `"phone"`；`Future<String> IosChannel.idiom()`（失败或空返回 `''`）。

- [ ] **Step 1: 写失败测试**（照 `ios_channel_test.dart` 里 `deviceName` 的模拟通道写法）
模拟通道对 `idiom` 回 `'pad'` → `await iosChannel.idiom()` 是 `'pad'`；回 `null` → `''`。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ios_channel_test.dart`
Expected: 编译失败（`idiom` 未定义）

- [ ] **Step 3: 实现**
Swift：`case "idiom": result(UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone")`。Dart：`Future<String> idiom() async => await _channel.invokeMethod<String>('idiom') ?? '';`。`main_ios.dart`：在取 `deviceName` 旁边 `try { idiom = await iosChannel.idiom(); } catch (_) {}`，构造 `MainState` 时传 `localOs: localDeviceOs(iosIdiom: idiom)`。

- [ ] **Step 4: 跑测试并编 iOS**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ios_channel_test.dart && ~/development/flutter/bin/flutter build ios --no-codesign --debug -t lib/main_ios.dart 2>&1 | tail -5`
Expected: 测试通过；iOS 编译成功（照记忆里「fresh worktree 编 iOS」的步骤，必要时先跑 rapp_rime 的 `fetch.sh`）

- [ ] **Step 5: Commit**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui/ios/Runner/IosPlugin.swift gui/lib/ios_channel.dart gui/lib/main_ios.dart gui/test/ios_channel_test.dart
git commit -m "feat(ios): tell iPad from iPhone for this device's column"
```

---

### Task 5: 画图标，放进总览的设备列

**Files:**
- Create: `gui/lib/ui/os_mark.dart`
- Modify: `gui/lib/ui/overview.dart:307-318`（`_Column` 的状态行）
- Test: `gui/test/ui/os_mark_test.dart`（新建）、`gui/test/ui/overview_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `DeviceOs`、`osWord`、`DeviceColumn.os`。
- Produces: `class OsMark extends StatelessWidget { const OsMark(this.os, {super.key, this.size = 10}); }`；`class OsMarkPainter extends CustomPainter { OsMarkPainter(this.os, this.color, this.size); final DeviceOs os; final Color color; final double size; }`。`OsMark` 里面：`Tooltip(message: osWord(os))` 包 `Semantics(label: osWord(os), excludeSemantics: true)` 包 `CustomPaint(key: const Key('os-mark-paint'), size: Size.square(size * 1.3), painter: OsMarkPainter(os, RappTokens.of(context).muted, size))`。

- [ ] **Step 1: 写失败测试**

`os_mark_test.dart`：

```dart
testWidgets('every mark paints at the lamp box size in the muted colour, words on hover', (tester) async {
  for (final theme in RappTheme.values) {
    for (final os in DeviceOs.values) {
      await tester.pumpWidget(wrap(OsMark(os), theme: theme));
      expect(tester.takeException(), isNull, reason: '$theme $os');
      final paint = tester.widget<CustomPaint>(find.byKey(const Key('os-mark-paint')));
      final p = paint.painter! as OsMarkPainter;
      expect((p.os, p.color), (os, tokensFor(theme).muted), reason: '$theme $os');
      expect(tester.getSize(find.byKey(const Key('os-mark-paint'))), const Size.square(13));
      expect(find.byTooltip(osWord(os)), findsOneWidget);
    }
  }
});
```

再写一个看样子用的测试 `'sheet'`：只在环境变量 `RAPP_OS_SHEET` 指向一个目录时运行（否则 `skip`）。把 9 个图标按 `size: 40` 排成一行，三套主题各一行，每行底色用该主题的背景色，用 `RepaintBoundary` + `tester.runAsync(() => boundary.toImage(pixelRatio: 2))` 存成 `$RAPP_OS_SHEET/os-marks.png`。再按 `size: 10` 存一张同样的 `os-marks-actual.png`，看实际大小的效果。

`overview_test.dart`（照文件里已有的总览测试搭法）：hosts 是 `HubHost('m1','A', os: 'windows')`，探测为离线，`MainState(localOs: DeviceOs.macos)` → `find.byKey(Key('os-mark-local'))` 和 `find.byKey(Key('os-mark-m1'))` 都存在；两者的 `OsMark.os` 分别是 `macos`、`windows`（离线也在）；`os-mark-m1` 在屏幕上位于该列 `StatusLamp` 的左边（`getTopLeft` 的 dx 比较）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/os_mark_test.dart test/ui/overview_test.dart`
Expected: 编译失败（`OsMark` 未定义）

- [ ] **Step 3: 实现 `OsMarkPainter.paint`**
按 spec 第 5 节画：`k = size / 10`，画布 `size * 1.3`。苹果、四格窗、Omarchy（参照它官方标志的轮廓简化）、企鹅画成实心剪影；平板（竖放，约 3:4）和手机（约 1:2）画成描边圆角矩形（线宽 `1.6 * k`），里面居中放约外形宽度 55% 的实心苹果或机器人头（半圆头、两根触角、眼睛挖空）；未知画成点线圆环（照 `lamp.dart` 的点线写法）加中间的问号。用 `Path`，不画文字（问号也用 Path 画）。`shouldRepaint` 比较 `os`/`color`/`size`。

- [ ] **Step 4: 放进总览**
`_Column` 状态行：`Row(children: [OsMark(col.os, key: Key('os-mark-${id ?? 'local'}')), const SizedBox(width: 6), StatusLamp(col.lamp), ...])`。

- [ ] **Step 5: 跑测试、出样张**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/os_mark_test.dart test/ui/overview_test.dart && mkdir -p /private/tmp/claude-501/-Users-bruce-git-rapp/af5b1656-1dfa-4012-9147-73794b836c82/scratchpad/os-sheet && RAPP_OS_SHEET=/private/tmp/claude-501/-Users-bruce-git-rapp/af5b1656-1dfa-4012-9147-73794b836c82/scratchpad/os-sheet ~/development/flutter/bin/flutter test test/ui/os_mark_test.dart --plain-name sheet`
Expected: 全部通过；两张 PNG 已生成。用 Read 打开看，每个图标在三套主题下都认得出、没有被裁边；不行就改路径再出图。

- [ ] **Step 6: Commit**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui/lib/ui/os_mark.dart gui/lib/ui/overview.dart gui/test/ui/os_mark_test.dart gui/test/ui/overview_test.dart
git commit -m "feat(gui): system marks beside each device's lamp on the overview"
```

---

### Task 6: 整体验证和交付

**Files:**
- Modify: `tasks/todo.md`（加实机检查项）

- [ ] **Step 1: 全量门禁**

Run: `cd rust && cargo test --workspace --no-fail-fast 2>&1 | tail -15 && cargo clippy --workspace --all-targets -- -D warnings 2>&1 | tail -3; cd ../gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test 2>&1 | tail -5; git checkout pubspec.lock`
Expected: Rust 全部通过（已知的 rapp-term 负载抖动测试单独重跑能过即可）、clippy 无警告、analyze 无问题、Flutter 测试全过

- [ ] **Step 2: 写实机检查项**
在 `tasks/todo.md` 加「设备系统图标」一节：① Mac 本机列显示苹果；② 已升级的另一台 Mac / Omarchy / Linux 列显示对的图标；③ 未升级的设备显示「未知」，升级后变对；④ 设备离线后图标还在；⑤ iPad、iPhone 本机列是平板/手机外形加苹果；⑥ 三套主题下都看得清；⑦ 悬停显示系统名。

- [ ] **Step 3: Commit 并交付**

```bash
git add tasks/todo.md
git commit -m "docs(todo): real-machine checks for device os marks"
```

把 `os-marks.png`、`os-marks-actual.png` 的完整路径和分支名交给用户；合并等用户看完图点头。
