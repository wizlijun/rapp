# iOS / iPadOS 内置输入法（Rime）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iPhone / iPad 接实体键盘时，输入板的编辑区可以用 app 内置的 Rime（雾凇拼音）打字：组字在光标处，候选固定在文字下一行。整个输入法放在本地 Flutter 插件 `gui/packages/rapp_rime/` 里。

**Architecture:** 插件分三层。
- 原生（Swift，SwiftPM）：一个纯 Swift 的按键换算 target `RappRimeKeys`，加一个插件 target `rapp_rime`。后者负责引擎、按键接管、连发和 `rapp/rime` 通道。
- Dart：模型、`RappRime` 控制器、候选行组件。
- app 一侧只接线：`RappViewController` 把 SessionPlugin 不要的按键交给插件；SessionPlugin 补发暂存按键时先问插件；`FlutterEditor` 显示组字、插入上屏文字，并在 iOS 上把候选行放在文字下面；`UiPrefs` 和设置页加开关。

**Tech Stack:** librime 1.16.1（LibrimeKit-iOS v0.2.2 预编译 xcframework）、雾凇拼音（固定提交）、Swift / SwiftPM、Flutter 3.44 插件（SwiftPM 通道）、Dart。

**Spec:** `docs/superpowers/specs/2026-11-20-rapp-ios-rime-ime-design.md`。执行的人两份都要读。参照代码在分支 `probe/ios-rime-panel`（worktree `/Users/bruce/git/rapp/.claude/worktrees/rime-panel`），主要看 `gui/ios/Runner/RimeProbe.swift`、`gui/lib/probe/rime_probe.dart`、`probe/rime-panel/fetch.sh` 和 `probe/rime-panel/uitest/`。只能参照，不要整段拷：探查里有调试日志、`sendEvent` 方法替换和测量面板，这些都不能进正式版。

## Global Constraints

- 只在 iOS 上：插件 `pubspec.yaml` 只声明 `ios` 平台。macOS、Linux、Windows 构建不链接它；Dart 一侧在别的平台上不调用它。
- 总开关关着时，行为和现在完全一样：type-to-compose、语音、chips、远端按键、软键盘都一样。
- 没接实体键盘时一切照旧。
- 引擎没就绪时，按键照常交给系统输入法。
- 不改协议，不改 A 侧，只用公开 API。不做方法替换（swizzle）。
- `gui/macos/Runner/SessionPlugin.swift` 是 macOS 和 iOS 共用的。改动只能放在 `#if os(iOS)` 里，并且不能 `import rapp_rime`。
- 引擎包：`https://github.com/thomfang/LibrimeKit-iOS/releases/download/v0.2.2/Frameworks.tgz`，sha256 `43a0921538827fedb2679e5d26bb389dec3759d44ccdcfd439e8ec21a7f93223`。
- 雾凇：仓库 `iDvel/rime-ice` 的提交 `927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6`（2026-11-11）。从 codeload 下载源码 tarball；sha256 第一次下载时算出来，写进脚本。不要用滚动更新的 `nightly`。
- OpenCC 表：`https://github.com/rime/librime/releases/download/latest/rime-deps-bb56876-macOS-universal.tar.bz2`，sha256 `1fb4b34d4cca688306ca02cb76655350a5c6bd92cc17e51a673bd8cc451889d3`。
- 下载的东西都不进仓库，放在插件里 gitignore 掉的目录下。
- 界面文字用中文，按设计文档原样写：「实体键盘用内置输入法」「内」「系」「中」「英」「部署中…」「就绪」「重新部署」「自带雾凇」「我的目录」。
- flutter 在 `~/development/flutter/bin/flutter`，不在 PATH 上。
- 跑完测试后，`git checkout gui/pubspec.lock` 撤掉 flutter 顺手做的无关改动。唯一例外是 Task 1：那里新增 `rapp_rime` 依赖带来的 lock 改动要提交。
- 不要提交到 main。分支是 `feat/ios-rime`，worktree 在 `/Users/bruce/git/rapp/.claude/worktrees/ios-rime`。
- 协议字段的测试要跑 `cargo test --workspace`。这一轮不动 Rust，所以只在最后跑一遍。
- 不要读 `docs/archives/`。

## Review Focus

1. **按键成对**：引擎吞了按下，就必须也吞掉抬起；引擎没吞按下，抬起也不能吞。否则 Flutter 会以为某个键一直按着，比如 ⌘ 卡住以后 ⌘+字母失灵。测试见 Task 3 Step 1（`PressLedger`）。
2. **按键以外的东西碰到文字时，组字先按原文上屏**（语音结果、chips、`take`、`setText`、交接、失焦、进后台），一个字母都不能丢，也不能出现两份。测试见 Task 6 Step 1。
3. **引擎没就绪或已释放时**（加载中、部署中、出错、总开关刚关），按键必须照常交给系统输入法；`flush` 没有回音时，待办的编辑也不能永远挂着。测试见 Task 6 Step 1 的 `flush 失败` 那条，以及 Task 3 Step 1。
4. **切到「系」或关掉总开关时**：组字清掉、不上屏，候选行跟着消失，之后按键回到系统输入法。测试见 Task 4 Step 1、Task 6 Step 1。
5. **用户目录不完整**（没有 `default.yaml`、方案编不过）：显示「出错：…」，不崩溃，也不卡住打字。测试见 Task 4 Step 1 的状态解析，真机检查第 10 条。

---

### Task 0: 真机补量（用户在场，可以和 Task 1–6 同时进行）

Duo 上现在装的还是探查版。这一步只量数字，不写代码。

**Files:**
- Modify: `docs/superpowers/specs/2026-11-20-rapp-ios-rime-ime-design.md`：在 §6.6 末尾加一行「真机实测：…」。

- [ ] **Step 1: 请用户在 Duo 上操作**：打开探查版，等 10 s 让 Flutter 稳定；点「大词库」，等它显示「就绪」；再点「重新部署」（冷部署）；等「就绪」后截图，或者把面板上的数字念出来。
- [ ] **Step 2: 记下三个数**：`deployMs`（冷部署用时）、`footprintLoaded − footprintBefore`（引擎带来的内存）、按住一个字母时的 `systemRepeats` 和 `ownRepeats`。
- [ ] **Step 3: 写进设计文档 §6.6 并提交**

```bash
git add docs/superpowers/specs/2026-11-20-rapp-ios-rime-ime-design.md
git commit -m "docs(spec): Rime device numbers (deploy time, memory, key repeat)"
```

结论怎么用：
- `deployMs > 5000`：Task 9 要做（构建时预编译词库）；否则跳过 Task 9。
- `systemRepeats > 0`：说明系统自己会连发，Task 3 的 `RepeatPolicy` 会自动停掉自己的连发，不用另外改代码。
- 内存超过 100 MB：记下来交给用户定，不挡后面的任务。

---

### Task 1: 插件骨架、取包脚本、引擎能链接上

**Files:**
- Create: `gui/packages/rapp_rime/pubspec.yaml`
  - `name: rapp_rime`，`publish_to: none`；
  - `flutter: plugin: platforms: ios: pluginClass: RappRimePlugin`；
  - environment 照 `gui/pubspec.yaml`。
- Create: `gui/packages/rapp_rime/.gitignore`：忽略 `vendor/`、`ios/rapp_rime/Frameworks/`、`ios/rapp_rime/Sources/CRime/include/`（`.keep` 除外）、`ios/rapp_rime/Sources/rapp_rime/RimeData/`。
- Create: `gui/packages/rapp_rime/scripts/fetch.sh`
- Create: `gui/packages/rapp_rime/ios/rapp_rime/Package.swift`
- Create: `gui/packages/rapp_rime/ios/rapp_rime/Sources/CRime/shim.c`：空的 C 文件，只为了让 SwiftPM 认这个 C target。
- Create: `gui/packages/rapp_rime/ios/rapp_rime/Sources/rapp_rime/RappRimePlugin.swift`：这一步只放注册和一个 `version` 方法。
- Create: `gui/packages/rapp_rime/lib/rapp_rime.dart`：先只导出一个空库。
- Create: `gui/packages/rapp_rime/README.md`
- Modify: `gui/pubspec.yaml`：加 `rapp_rime: {path: packages/rapp_rime}`。
- Modify: `scripts/build-ios.sh`：在 `hub` 之后、flutter 构建之前跑 `"$repo/gui/packages/rapp_rime/scripts/fetch.sh"`。

**Interfaces:**
- Produces，`fetch.sh` 跑完后的目录：
  - `ios/rapp_rime/Frameworks/<10 个>.xcframework`：librime、boost_filesystem、boost_regex、boost_system、boost_thread、libglog、libleveldb、libmarisa、libopencc、libyaml-cpp。
  - `ios/rapp_rime/Sources/CRime/include/`：从 `librime.xcframework/ios-arm64/Headers` 拷来的 `rime_api.h`、`rime_api_deprecated.h`、`rime_api_stdbool.h`、`rime_levers_api.h`。
  - `ios/rapp_rime/Sources/rapp_rime/RimeData/`：雾凇共享数据。
- Produces：`Package.swift` 里有三个 target：`CRime`（C，只有头文件）、`RappRimeKeys`（纯 Swift，Task 2 填内容）、`rapp_rime`（插件，依赖 `FlutterFramework`、`CRime`、`RappRimeKeys` 和 10 个 `.binaryTarget(path: "Frameworks/<名>.xcframework")`）。
  - 链接设置：`.linkedLibrary("c++")`。
  - 资源：`.copy("RimeData")`。
- Produces：Swift `public final class RappRimePlugin: NSObject, FlutterPlugin`，带 `public static private(set) var shared: RappRimePlugin?`。

- [ ] **Step 1: 写 `fetch.sh`**

  做法照探查的 `probe/rime-panel/fetch.sh`，改这几处：
  - 只要雾凇，不要朙月那套小词库。
  - 雾凇改从 `https://codeload.github.com/iDvel/rime-ice/tar.gz/927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6` 下载。只拷这些：`*.yaml`、`*.txt`、`LICENSE`、`cn_dicts/`、`en_dicts/`、`lua/`、`opencc/`；不要 `squirrel.yaml`、`weasel.yaml`。
  - OpenCC 的处理照探查：拷 4 个 `.ocd2`，写两份简化的 `t2s.json`、`s2t.json`，再叠上雾凇自己的 `opencc/`。
  - 写 `default.custom.yaml`：

    ```yaml
    patch:
      schema_list:
        - schema: rime_ice
      menu/page_size: 9
    ```
  - 每个下载都核对 sha256，不对就 `exit 1`，并打印「删掉 vendor/dl/<文件> 重跑 fetch.sh」。
  - 已经展开、并且记录的校验和对得上时，直接退出（几毫秒），不重复展开。
  - 往 `RimeData/` 写一个 `rapp_rime_data_version` 文件，内容是雾凇提交号的前 7 位加脚本里的 `DATA_REV=1`。Task 3 用它当 `distribution_version`。

- [ ] **Step 2: 跑两遍**

  Run: `gui/packages/rapp_rime/scripts/fetch.sh && gui/packages/rapp_rime/scripts/fetch.sh`

  Expected:
  - 第一遍下载并展开，打印各目录大小（RimeData 约 49M）。
  - 第二遍不到 1 s 就退出。
  - `ls gui/packages/rapp_rime/ios/rapp_rime/Frameworks | wc -l` 输出 10。

- [ ] **Step 3: 写 `Package.swift`**

  - `swift-tools-version: 5.9`，`platforms: [.iOS("17.0")]`；
  - FlutterFramework 依赖照 Flutter 模板：`.package(name: "FlutterFramework", path: "../FlutterFramework")`。

  如果静态库 xcframework 用 binaryTarget 链不上，退路是：去掉 binaryTarget，在 `rapp_rime` target 上用 `linkerSettings: [.unsafeFlags(["-L…", "-lrime", …])]`，路径按 slice 分开。本地路径依赖允许 unsafeFlags。用了哪条路，写进 README 的「升级」一节。

- [ ] **Step 4: 写 `RappRimePlugin.register(with:)`**
  - 在 `rapp/rime` 通道上处理 `version`，返回 `String(cString: rime_get_api().pointee.get_version())`。
  - 注册时打一行 `NSLog("rapp_rime: librime %@", version)`。这是唯一常驻的日志。

- [ ] **Step 5: 模拟器构建**

  Run: `scripts/build-ios.sh sim --install EE6D588C-B90B-43B6-A38C-22E4C1A07196`，然后 `xcrun simctl launch --console-pty --terminate-running-process EE6D588C-B90B-43B6-A38C-22E4C1A07196 com.rapphub.rapp 2>&1 | grep -m1 rapp_rime`

  Expected: 输出 `rapp_rime: librime 1.16.1`。`gui/ios/Runner/GeneratedPluginRegistrant.m` 里有 `RappRimePlugin`。

- [ ] **Step 6: macOS 不受影响**

  Run: `cd gui && ~/development/flutter/bin/flutter build macos --debug`

  Expected: 构建成功；`gui/macos/Flutter/GeneratedPluginRegistrant.swift` 里没有 rapp_rime。

- [ ] **Step 7: 写 README 并提交**

  README 的小节：
  - 这是什么；
  - 目录；
  - 怎么升级 librime（改 URL 和 sha256）；
  - 怎么升级雾凇（改提交号、sha256，`DATA_REV` 加一）；
  - 版本和许可证表：librime BSD-3、boost BSL-1.0、glog BSD-3、leveldb BSD-3、marisa BSD-2/LGPL-2.1、OpenCC Apache-2.0、yaml-cpp MIT、雾凇 GPL-3.0；
  - 一段话说明雾凇和公开分发的冲突，链接设计文档 §3。

  ```bash
  git add gui/packages/rapp_rime gui/pubspec.yaml gui/pubspec.lock scripts/build-ios.sh
  git commit -m "feat(rime): rapp_rime plugin skeleton, fetch script, librime linked on iOS"
  ```

  `gui/pubspec.lock` 里的 rapp_rime 条目要提交；lock 里别的改动先撤掉。

---

### Task 2: 按键换算和连发规则（纯 Swift，有测试）

**Files:**
- Create: `gui/packages/rapp_rime/ios/rapp_rime/Sources/RappRimeKeys/RimeKeyMap.swift`
- Create: `gui/packages/rapp_rime/ios/rapp_rime/Sources/RappRimeKeys/RepeatPolicy.swift`
- Create: `gui/packages/rapp_rime/ios/rapp_rime/Tests/RappRimeKeysTests/RimeKeyMapTests.swift`
- Modify: `gui/packages/rapp_rime/ios/rapp_rime/Package.swift`
  - 加 `.testTarget(name: "RappRimeKeysTests", dependencies: ["RappRimeKeys"])`。
  - 环境变量 `RAPP_RIME_KEYS_ONLY` 有值时，manifest 只声明 `RappRimeKeys` 和它的测试，平台加上 `.macOS(.v13)`，不声明 FlutterFramework 和二进制库。这样 `swift test` 能在 Mac 上跑。

**Interfaces:**
- Produces（`RappRimeKeys` 模块，不 import UIKit；修饰键用 `UIKeyModifierFlags` 的原始值）：

```swift
public struct RimeKey: Equatable { public let keysym: Int32; public let mask: Int32 }
public enum RimeKeyMap {
  public static let shift: Int32 = 1 << 0, lock: Int32 = 1 << 1, control: Int32 = 1 << 2, alt: Int32 = 1 << 3
  public static let superMask: Int32 = 1 << 26, release: Int32 = 1 << 30
  /// UIKey 的 HID 用法码、characters、charactersIgnoringModifiers、modifierFlags.rawValue → Rime 的键；不认识的返回 nil。
  public static func map(hid: Int, characters: String, ignoringModifiers: String, modifiers: Int) -> RimeKey?
  public static func isModifier(hid: Int) -> Bool
  /// 引擎不要时由编辑区插入的文字：单个可打印 ASCII，并且没按 ⌃⌥⌘；否则 nil。
  public static func typedText(characters: String, modifiers: Int) -> String?
}
public struct RepeatPolicy {
  public static let delay: Double = 0.4, interval: Double = 0.04
  public init()
  /// 系统对同一个键又送了一次按下（这个键还按着）：从此不再自己连发。返回这次按下是不是系统连发。
  public mutating func began(hid: Int) -> Bool
  public mutating func ended(hid: Int)
  public var ownRepeat: Bool { get }
}
```

UIKeyModifierFlags 原始值：
- alphaShift `0x10000`
- shift `0x20000`
- control `0x40000`
- alternate `0x80000`
- command `0x100000`

特殊键的 HID 和 keysym 对照，照探查的 `rimeKey`：

| 键 | HID | keysym |
|---|---|---|
| 退格 | 0x2A | 0xff08 |
| Tab | 0x2B | 0xff09 |
| 回车 | 0x28 | 0xff0d |
| 小键盘回车 | 0x58 | 0xff8d |
| Esc | 0x29 | 0xff1b |
| 向前删除 | 0x4C | 0xffff |
| Home | 0x4A | 0xff50 |
| ← | 0x50 | 0xff51 |
| ↑ | 0x52 | 0xff52 |
| → | 0x4F | 0xff53 |
| ↓ | 0x51 | 0xff54 |
| PageUp | 0x4B | 0xff55 |
| PageDown | 0x4E | 0xff56 |
| End | 0x4D | 0xff57 |
| 左 Shift | 0xE1 | 0xffe1 |
| 右 Shift | 0xE5 | 0xffe2 |
| 左 Ctrl | 0xE0 | 0xffe3 |
| 右 Ctrl | 0xE4 | 0xffe4 |
| CapsLock | 0x39 | 0xffe5 |
| 左 Alt | 0xE2 | 0xffe9 |
| 右 Alt | 0xE6 | 0xffea |
| 左 ⌘ | 0xE3 | 0xffeb |
| 右 ⌘ | 0xE7 | 0xffec |
| 空格 | 0x2C | 0x20 |

可打印 ASCII 的规则：没按 ⌃⌥⌘ 时用 `characters`（所以 Shift+1 是 `!`）；按了的话用 `ignoringModifiers`。

- [ ] **Step 1: 写测试**

```swift
func testLetters() { XCTAssertEqual(RimeKeyMap.map(hid: 0x04, characters: "a", ignoringModifiers: "a", modifiers: 0), RimeKey(keysym: 0x61, mask: 0)) }
func testShiftedDigitIsItsSymbol() { XCTAssertEqual(RimeKeyMap.map(hid: 0x1E, characters: "!", ignoringModifiers: "1", modifiers: 0x20000), RimeKey(keysym: 0x21, mask: 1)) }
func testCommandUsesUnmodified() { XCTAssertEqual(RimeKeyMap.map(hid: 0x04, characters: "å", ignoringModifiers: "a", modifiers: 0x100000), RimeKey(keysym: 0x61, mask: 1 << 26)) }
func testSpecials() {
  for (hid, sym) in [(0x2A, 0xff08), (0x28, 0xff0d), (0x29, 0xff1b), (0x50, 0xff51), (0x51, 0xff54), (0x4B, 0xff55), (0x4E, 0xff56), (0x2C, 0x20)] {
    XCTAssertEqual(RimeKeyMap.map(hid: hid, characters: "", ignoringModifiers: "", modifiers: 0)?.keysym, Int32(sym))
  }
}
func testShiftKeyItself() { XCTAssertEqual(RimeKeyMap.map(hid: 0xE1, characters: "", ignoringModifiers: "", modifiers: 0x20000), RimeKey(keysym: 0xffe1, mask: 1)) }
func testUnknown() {
  XCTAssertNil(RimeKeyMap.map(hid: 0x3A, characters: "UIKeyInputF1", ignoringModifiers: "UIKeyInputF1", modifiers: 0)) // F1
  XCTAssertNil(RimeKeyMap.map(hid: 0x08, characters: "é", ignoringModifiers: "é", modifiers: 0))
}
func testTypedText() {
  XCTAssertEqual(RimeKeyMap.typedText(characters: "A", modifiers: 0x20000), "A")
  XCTAssertNil(RimeKeyMap.typedText(characters: "a", modifiers: 0x100000))
  XCTAssertNil(RimeKeyMap.typedText(characters: "\r", modifiers: 0))
}
func testModifiers() { XCTAssertTrue(RimeKeyMap.isModifier(hid: 0xE1)); XCTAssertTrue(RimeKeyMap.isModifier(hid: 0x39)); XCTAssertFalse(RimeKeyMap.isModifier(hid: 0x04)) }
func testRepeatPolicy() {
  var p = RepeatPolicy()
  XCTAssertFalse(p.began(hid: 4)); XCTAssertTrue(p.ownRepeat)
  XCTAssertTrue(p.began(hid: 4)); XCTAssertFalse(p.ownRepeat)
  p.ended(hid: 4); XCTAssertFalse(p.began(hid: 4)); XCTAssertFalse(p.ownRepeat)  // once seen, stays off
}
```

- [ ] **Step 2: 跑，确认失败**

  Run: `RAPP_RIME_KEYS_ONLY=1 swift test --package-path gui/packages/rapp_rime/ios/rapp_rime`

  Expected: 编译失败，提示 `RimeKeyMap` 未定义。

- [ ] **Step 3: 实现 `RimeKeyMap` 和 `RepeatPolicy`**

- [ ] **Step 4: 跑，确认通过**

  Run: 同 Step 2。Expected: 全部通过。

  再跑一遍 Task 1 Step 5 的模拟器构建，确认不设环境变量时插件照样能编。

- [ ] **Step 5: 提交**

```bash
git add gui/packages/rapp_rime/ios
git commit -m "feat(rime): UIKey → Rime key map and repeat policy, with tests"
```

---

### Task 3: 原生引擎、按键接管和通道

**Files:**
- Create: `gui/packages/rapp_rime/ios/rapp_rime/Sources/RappRimeKeys/PressLedger.swift`：纯逻辑，记录被吞的按下，保证按下和抬起成对。
- Create: `gui/packages/rapp_rime/ios/rapp_rime/Sources/rapp_rime/RimeEngine.swift`：librime 的封装。
- Modify: `gui/packages/rapp_rime/ios/rapp_rime/Sources/rapp_rime/RappRimePlugin.swift`：通道、按键、连发、键盘检测、进后台。
- Test: `gui/packages/rapp_rime/ios/rapp_rime/Tests/RappRimeKeysTests/PressLedgerTests.swift`

**Interfaces:**
- Produces（`RappRimeKeys`）：

```swift
public struct PressLedger {
  public init()
  public mutating func took(hid: Int)                 // 按下被吞了
  /// 这个键的抬起要不要吞：只有它的按下被吞过才吞，吞过一次就清掉。
  public mutating func release(hid: Int) -> Bool
  public mutating func forgetAll() -> [Int]           // 失活时：还没抬起的那些键
}
```

- Produces（`rapp_rime`，给 Runner 用）：

```swift
public final class RappRimePlugin: NSObject, FlutterPlugin {
  public static private(set) var shared: RappRimePlugin?
  /// SessionPlugin 留在本地的一次按下或抬起（began=false 表示抬起或取消）。true 表示被吞了，不要再给 Flutter。
  public func handlePress(_ press: UIPress, began: Bool) -> Bool
  /// type-to-compose 暂存后补发的一次按下。true 表示进了引擎（包括引擎不要、由 Dart 插入的可打印字符），调用方不要再 insertText。
  public func replay(hid: Int, characters: String, modifiers: Int) -> Bool
}
```

- Produces，通道 `rapp/rime` 的约定（Task 4 的 Dart 一侧照这个写）：

  Dart → 原生：

  | 方法 | 参数 | 返回 | 做什么 |
  |---|---|---|---|
  | `configure` | `{enabled: bool, dictionary: 'bundled'\|'user'}` | null | `enabled=false` 时释放引擎（`finalize`）；已经加载时换了词库，就重新加载 |
  | `active` | `{on: bool}` | null | Dart 那边编辑区有焦点、总开关开着、选的是「内」。第一次 `on=true`、并且接着实体键盘时才加载引擎。`on=false` 时停掉连发 |
  | `select` | `{index: int}` | null | 选当前页第 index 个候选 |
  | `page` | `{next: bool}` | null | 翻页 |
  | `flush` | — | null | 把原始输入（`get_input`）当作上屏文字，清掉组字，推一次 `update` |
  | `clear` | — | null | 清掉组字，不上屏，推一次 `update` |
  | `redeploy` | — | null | 删掉用户目录下的 `build/`，重新加载 |
  | `userFolder` | — | `{path: String, ready: bool}` | `ready` 的意思是 `Documents/Rime/default.yaml` 存在 |
  | `version` | — | String | 保留 Task 1 的 |

  原生 → Dart：

  | 方法 | 参数 |
  |---|---|
  | `status` | `{state: 'off'\|'starting'\|'ready'\|'error', message: String, keyboard: bool}` |
  | `update` | `{commit: String, preedit: String, caret: int, input: String, ascii: bool, menu: {rows: [{index: int, label: String, text: String}], cursor: int, previous: bool, next: bool}}` |

  `caret` 按 UTF-16 计数。

- [ ] **Step 1: 写 `PressLedgerTests`**

```swift
func testReleaseOnlyAfterTakenPress() {
  var l = PressLedger()
  XCTAssertFalse(l.release(hid: 4))              // never taken → Flutter gets the up
  l.took(hid: 4); XCTAssertTrue(l.release(hid: 4)); XCTAssertFalse(l.release(hid: 4))
}
func testForgetAll() { var l = PressLedger(); l.took(hid: 4); l.took(hid: 5); XCTAssertEqual(Set(l.forgetAll()), [4, 5]); XCTAssertFalse(l.release(hid: 4)) }
```

- [ ] **Step 2: 跑，确认失败**

  Run: `RAPP_RIME_KEYS_ONLY=1 swift test --package-path gui/packages/rapp_rime/ios/rapp_rime --filter PressLedger`

  Expected: 编译失败。

- [ ] **Step 3: 实现 `PressLedger`，跑 Step 2 的命令确认通过**

- [ ] **Step 4: 实现 `RimeEngine`**

  做法照探查的 `start` / `push` / `chars`。要定下来的值：
  - **目录**：
    - 「自带雾凇」：共享目录用 `Bundle.module` 里的 `RimeData`，用户目录用 `Application Support/Rime`。
    - 「我的目录」：`Documents/Rime` 同时当共享目录和用户目录。
    - `log_dir` 放在用户目录下的 `logs`。
  - **traits**：
    - `app_name` 用 `rime.rapp`；
    - `distribution_code_name` 用 `rapp`；
    - `distribution_version` 读 `RimeData/rapp_rime_data_version`（我的目录时用 `"user"`）；
    - `min_log_level` 设 2（只记错误）。
  - **加载**：`setup` 只调一次；`initialize`、`start_maintenance(1)` 在主线程；`join_maintenance_thread` 在后台队列；完成后回主线程 `create_session`。
    - 期间推 `status starting`，成功推 `ready`。
    - 开会话失败，或者 librime 发来 `deploy`/`failure` 通知，推 `error`，`message` 写 librime 给的原文。
  - **释放**：`finalize` 之前销毁会话，然后推 `status off`。
  - 去掉的：测量计数、`keyLog`、`msSinceLaunch`、`footprint`、方法替换。

- [ ] **Step 5: 在 `RappRimePlugin` 里实现按键**

  `handlePress` 的规则（按顺序）：
  1. 没有 `press.key`：返回 false。
  2. 抬起：`RepeatPolicy.ended`；停掉这个键的连发；引擎 ready 并且 active 时，把带 `release` 位的键发给引擎（Shift 抬起切中英要靠它）；返回 `ledger.release(hid)`。
  3. 按下，但没 active 或没 ready：返回 false。
  4. `RepeatPolicy.began`。
  5. 修饰键：发给引擎，但返回 false，让 Flutter 的修饰键状态保持对。
  6. `RimeKeyMap.map` 返回 nil：返回 false。
  7. 引擎收了，或者 `typedText` 不是 nil（这时推 `update`，`commit` 就是这段文字）：`ledger.took`；如果 `RepeatPolicy.ownRepeat` 为真，按 `delay` / `interval` 开始自己连发；返回 true。
  8. 其他情况：返回 false，交给 Flutter（方向键、组字为空时的退格、回车、⌘ 组合键等）。

  `replay` 走第 3、6、7 步，不连发，不进 ledger。

  其他事件：
  - `active` 变成 false：`ledger.forgetAll()`，停掉连发。被吞过的键，它们的抬起也照样会被吞（`forgetAll` 之后就不吞了，这样 Flutter 不会收到只有抬起的半个键）。
  - 键盘检测：`GCKeyboard.coalesced != nil`，监听 `GCKeyboardDidConnect` 和 `GCKeyboardDidDisconnect`，变化时推 `status`。
  - 进后台：`UIApplication.willResignActiveNotification` 时，有组字就做一次 `flush`。

- [ ] **Step 6: 模拟器构建**

  Run: `scripts/build-ios.sh sim`

  Expected: 构建成功。真正的按键行为到 Task 7 端到端再测。

- [ ] **Step 7: 提交**

```bash
git add gui/packages/rapp_rime/ios
git commit -m "feat(rime): native engine, key takeover with paired releases, rapp/rime channel"
```

---

### Task 4: Dart 一侧（模型、控制器、候选行）

**Files:**
- Create: `gui/packages/rapp_rime/lib/src/models.dart`
- Create: `gui/packages/rapp_rime/lib/src/rapp_rime.dart`
- Create: `gui/packages/rapp_rime/lib/src/candidate_row.dart`
- Modify: `gui/packages/rapp_rime/lib/rapp_rime.dart`：导出上面三个文件。
- Test: `gui/packages/rapp_rime/test/models_test.dart`
- Test: `gui/packages/rapp_rime/test/rapp_rime_test.dart`
- Test: `gui/packages/rapp_rime/test/candidate_row_test.dart`

**Interfaces:**
- Consumes：Task 3 的通道约定。
- Produces：

```dart
enum RimeState { off, starting, ready, error }
enum RimeDictionary { bundled, user }

class RimeStatus {
  const RimeStatus({this.state = RimeState.off, this.message = '', this.keyboard = false});
  final RimeState state; final String message; final bool keyboard;
  static RimeStatus parse(Object? args); // 坏的或缺的字段：state=off、message=''、keyboard=false
}
class RimeCandidate { const RimeCandidate(this.index, this.label, this.text); final int index; final String label, text; }
class RimeMenu {
  const RimeMenu({this.rows = const [], this.cursor = -1, this.previous = false, this.next = false});
  static const empty = RimeMenu();
  final List<RimeCandidate> rows; final int cursor; final bool previous, next;
}
class RimeUpdate {
  const RimeUpdate({this.commit = '', this.preedit = '', this.caret = 0, this.input = '', this.ascii = false, this.menu = RimeMenu.empty});
  final String commit, preedit, input; final int caret; final bool ascii; final RimeMenu menu;
  static RimeUpdate? parse(Object? args); // 不是 Map、或者 rows 里有坏行：返回 null；caret 截到 [0, preedit.length]
}

/// FlutterEditor 只通过这个接口用输入法；测试用假的实现。
abstract class RimeLink implements Listenable {
  bool get enabled;          // 总开关
  bool get builtin;          // 「内」为 true，「系」为 false
  RimeStatus get status;
  bool get ascii;            // 最近一次 update 的 ascii
  /// 这个编辑器成为接收 update 的那一个（上一个被替换掉）。
  void attach(Object owner, void Function(RimeUpdate) onUpdate);
  void detach(Object owner);
  Future<void> setActive(Object owner, bool on); // 只有当前 owner 的调用算数
  Future<void> select(int index);
  Future<void> page(bool next);
  Future<bool> flush();      // 通道失败（没有插件、引擎没加载）返回 false
  Future<void> clear();
  void toggleBuiltin();      // 切「内/系」：切到「系」时先 clear()；然后通知监听者，并回调 onBuiltin
}

class RappRime extends ChangeNotifier implements RimeLink {
  static final RappRime instance = RappRime(const MethodChannel('rapp/rime'));
  RappRime(MethodChannel channel);  // 测试直接 new 一个
  void configure({required bool enabled, required bool builtin, required RimeDictionary dictionary, required void Function(bool builtin) onBuiltin});
  Future<void> redeploy();
  Future<({String path, bool ready})> userFolder(); // 失败时返回 (path: '', ready: false)
}

class RimeCandidateRow extends StatelessWidget {
  const RimeCandidateRow({super.key, required this.link, required this.menu, required this.style});
  final RimeLink link; final RimeMenu menu; final TextStyle style;
  /// 一行的高度：style 下「字Mg」的行高加 13。
  static double heightFor(BuildContext context, TextStyle style);
}
```

`RappRime` 的规则：
- 所有 `invokeMethod` 都 catch `MissingPluginException` 和 `PlatformException`：`flush` 返回 false，其余的不做事。
- 非 iOS（`defaultTargetPlatform != TargetPlatform.iOS`）时，`configure` 只记下状态，不调通道。
- 只有 `configure` 的参数真有变化时，才发 `configure`。
- `setActive(owner, on)` 发出去的值是 `on && enabled && builtin`；`enabled` 或 `builtin` 变了，就对当前 owner 重新发一次。

候选行的布局，从左到右：
- 有候选时：候选（照 `gui/lib/embed/linux_candidates.dart` `_row` 的画法拷一份精简版，包括序号变灰、高亮下划线、按宽度本地分页、‹ ›）。
- 没候选、状态是 `starting` 时：「部署中…」。
- 状态是 `error` 时：「出错：<message>」，一行，截断。
- 右端：
  - 「中」或「英」标记，key `Key('rime-ascii')`。
  - 「内」或「系」按钮，key `Key('rime-toggle')`，点了调 `toggleBuiltin()`，Semantics 标签为「切换内置输入法」。
- 点候选调 `select(index)`；点 ‹ ›：本地还有页就翻本地页，否则调 `page(next)`。

- [ ] **Step 1: 写测试**

  `models_test.dart`：
  - `RimeUpdate.parse` 读得出完整的 update；
  - rows 里有一行 index 不是 int 时返回 null；
  - caret 超过 preedit 长度时被截断；
  - `RimeStatus.parse({'state': 'error', 'message': 'x', 'keyboard': true})` 得到 error、'x'、true；
  - `RimeStatus.parse(null)` 得到 off。

  `rapp_rime_test.dart`：用 `TestDefaultBinaryMessengerBinding` 给 `rapp/rime` 装一个假的处理器，记下收到的调用；用 `debugDefaultTargetPlatformOverride = TargetPlatform.iOS`。
  - `configure(enabled: true, builtin: true, dictionary: bundled)`：只发一次 `configure {enabled: true, dictionary: 'bundled'}`；同样的参数再调一次，不再发。
  - `setActive(a, true)` 发 `active {on: true}`。
  - `toggleBuiltin()`：先发 `clear`，再发 `active {on: false}`；`builtin` 变成 false，`onBuiltin(false)` 被回调。
  - 原生推一个 `update`，只有当前 owner 的回调收到。
  - 没有处理器时（`MissingPluginException`），`flush()` 返回 false。
  - `enabled=false` 时，`setActive(a, true)` 发出去的是 `active {on: false}`。

  `candidate_row_test.dart`：
  - 有两个候选时，画出「1 你好」「2 拟好」；
  - 点第二个，`select(1)` 被调；
  - 没候选、状态 `starting` 时，显示「部署中…」；
  - ascii=true 时，标记是「英」；
  - 点 `rime-toggle` 会调 `toggleBuiltin`。

- [ ] **Step 2: 跑，确认失败**

  Run: `cd gui/packages/rapp_rime && ~/development/flutter/bin/flutter test`

  Expected: 编译失败。

- [ ] **Step 3: 实现三个文件**

- [ ] **Step 4: 跑，确认通过**

  Run: 同 Step 2，Expected: 全部通过。再跑 `~/development/flutter/bin/flutter analyze`，Expected: 没有问题。

- [ ] **Step 5: 提交**

```bash
git add gui/packages/rapp_rime/lib gui/packages/rapp_rime/test gui/packages/rapp_rime/pubspec.yaml
git commit -m "feat(rime): Dart models, RappRime controller and the candidate row"
```

---

### Task 5: 偏好设置和设置页

**Files:**
- Modify: `gui/lib/ui/prefs.dart`，加三个字段：
  - `rimeEnabled`（`rime_enabled`）：bool，缺了或坏了按 false；
  - `rimeBuiltin`（`rime_builtin`）：bool，缺了或坏了按 true；
  - `rimeDictionary`（`rime_dictionary`）：String，只认 `'bundled'` 和 `'user'`，其他按 `'bundled'`。
- Modify: `gui/lib/pages/ios_local_section.dart`
- Modify: `gui/lib/main_ios.dart`：prefs 载入后调一次 `RappRime.instance.configure(...)`。`onBuiltin` 写 `prefs.rimeBuiltin` 并保存（用 app state 现有的保存方法，`main_window.dart` 传给设置页的就是 `state.savePrefs`）。
- Test: `gui/test/ui/prefs_test.dart`（已有）
- Test: `gui/test/local_section_test.dart`（已有的 iOS 本机一节测试；照里面的做法加用例）

**Interfaces:**
- Consumes：Task 4 的 `RappRime.instance`、`RimeDictionary`、`RimeState`。
- Produces：设置页的 key：
  - `Key('rime-switch')`：总开关；
  - `Key('rime-dictionary')`：词库选择；
  - `Key('rime-redeploy')`：重新部署按钮；
  - `Key('rime-status')`：状态行。

设置页的内容。都放在「屏幕常亮」那一行后面，样式和约束和它一样：
- `RappSwitchRow`：label「实体键盘用内置输入法」，note「Rime 雾凇拼音，候选在文字下一行」。
- 开关开着时，再显示下面三项：
  - 词库：用 `RappChoice`（`gui/lib/ui/controls.dart`），两项「自带雾凇」「我的目录」。
    - 「我的目录」只在 `userFolder().ready` 为真时可选。
    - 不可选时，下面一行小字：「把 Rime 目录放进「文件」→ rapp → Rime 后可选」。
  - 按钮「重新部署」，调 `RappRime.instance.redeploy()`。
  - 状态行：`off` 时为空；`starting` 时「部署中…」；`ready` 时「就绪」；`error` 时「出错：<message>」。
- 每次开关或词库变化：改 prefs，调保存，再调 `configure`。

- [ ] **Step 1: 写测试**
  - prefs：三个字段的 JSON 存取来回一致；缺字段时是 `false` / `true` / `'bundled'`；`rime_dictionary: 'x'` 读成 `'bundled'`。
  - 设置页：
    - 开关默认关，看不到 `rime-redeploy`；
    - 点开关后，`prefs.rimeEnabled` 为 true，`onPrefs` 被调，出现 `rime-redeploy` 和 `rime-dictionary`；
    - 用 Task 4 那种假通道处理器，让 `userFolder` 返回 `ready: false`，「我的目录」不可选，并显示提示那行字。

- [ ] **Step 2: 跑，确认失败**

  Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/prefs_test.dart test/local_section_test.dart`

  Expected: 新用例失败。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑，确认通过**

  Run: 同 Step 2。Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/ui/prefs.dart gui/lib/pages/ios_local_section.dart gui/lib/main_ios.dart gui/test
git checkout gui/pubspec.lock 2>/dev/null; git commit -m "feat(rime): the built-in IME switch, dictionary choice and status in iOS settings"
```

---

### Task 6: FlutterEditor 接上 Rime

**Files:**
- Modify: `gui/lib/embed/flutter_editor.dart`
- Test: `gui/test/embed/flutter_editor_test.dart`：加一组 `group('rime', ...)`，里面用 `FakeRimeLink`。
- Create: `gui/test/embed/fake_rime_link.dart`：`class FakeRimeLink extends ChangeNotifier implements RimeLink`。
  - 记下 `calls`；
  - `push(RimeUpdate u)` 把 update 交给当前 owner；
  - `flushOk` 控制 `flush()` 返回什么；
  - `flush()` 在 `flushOk` 为真时自动推一个 `RimeUpdate(commit: input)`，`input` 是最近一次推过的 update 的原始输入。

**Interfaces:**
- Consumes：Task 4 的 `RimeLink`、`RimeUpdate`、`RimeCandidateRow`。
- Produces：`FlutterEditor({RimeLink? rime})`。
  - 不传时：iOS（`defaultTargetPlatform == TargetPlatform.iOS && !kIsWeb`）用 `RappRime.instance`，其他平台用 null。
  - `composer_panel.dart` 里 `FlutterEditor()` 的调用不改。

规则（总开关关着，或 `rime == null` 时，全部不生效，代码路径和现在一样）：
1. 构造时调 `rime.attach(this, _onRime)`，dispose 时调 `detach`。
2. 焦点变化时，调 `setActive(this, hasFocus)`。失去焦点时，如果有组字，再调一次 `flush()`。
3. `_onRime(u)`：
   - `u.commit` 不为空时，按现在 `_insertNow` 的方式插在光标处；
   - 然后记下 `u.preedit`、`u.caret`、`u.menu`；
   - 组字变空、并且系统也没在组字时，跑完 `_pending`。
4. `_composing` 变成「系统在组字 || Rime 组字不为空」。这样 `AbsorbPointer`、`setText`、`insert`、`take`、交接时的 `read` 自动排进 `_pending`。
   - 排进去的时候，如果是因为 Rime 在组字，就调一次 `flush()`。
   - `flush()` 返回 false 时，本地清掉组字，马上跑完 `_pending`（Review Focus 第 3 条）。
5. `_ChipController` 加 `rimePreedit`（String）。`buildTextSpan` 把它插在光标位置（`selection.start`，无效时插在文末），带下划线；有 chips 和没 chips 两条路径都要处理。
6. 候选行：`rime.enabled && rime.status.keyboard` 时，`view` 返回一个 Column：
   - 上面是现有的 field，maxHeight 减去 `RimeCandidateRow.heightFor`；
   - 下面是 `RimeCandidateRow`，menu 为空时也占着这一行。
   - 整体包在 `ListenableBuilder(listenable: rime)` 里。
   - Linux 的 `LinuxCandidatesSurface` 分支不动。
7. `builtin` 从 true 变成 false 时，本地清掉组字（`RappRime.toggleBuiltin` 已经发了 `clear`），跑完 `_pending`。

- [ ] **Step 1: 写测试**（都在 `debugDefaultTargetPlatformOverride = TargetPlatform.iOS` 下，用 `FakeRimeLink`，`enabled=true`）

```dart
testWidgets('rime preedit shows inline, underlined, not in the text', ...);
// push(RimeUpdate(preedit: 'ni hao', input: 'nihao')) → find.text 不含；controller.text == ''；
// 渲染出来的 span 的 plain text == 'ni hao'，带 TextDecoration.underline

testWidgets('rime commit lands at the caret', ...);
// 文本 'ab'，光标在 1，push(RimeUpdate(commit: '你好')) → text == 'a你好b'

testWidgets('insert while composing commits the raw input first', ...);
// push(preedit 'ni hao', input 'nihao')；ed.insert('[语音]') → calls 里有 flush；text == 'nihao[语音]'

testWidgets('take while composing returns the raw input', ...);
// push(preedit 'ni', input 'ni')；await ed.take() == 'ni'；之后 text == ''

testWidgets('blur commits the composition', ...);
// push(preedit 'wo', input 'wo')；ed.unfocus() → calls 里有 flush；text == 'wo'

testWidgets('flush failing still runs pending edits', ...);
// flushOk=false；push(preedit 'ni', input 'ni')；ed.setText('x') → text == 'x'，组字已清

testWidgets('switching to 系 drops the composition', ...);
// push(preedit 'ni')；把 fake 的 builtin 设成 false 并 notify → 组字为空，text == ''

testWidgets('candidate row is reserved while the keyboard is there', ...);
// status.keyboard=true → find.byType(RimeCandidateRow) 有一个；keyboard=false → 没有

testWidgets('master switch off: no row, no attach side effects', ...);
// enabled=false → 没有 RimeCandidateRow；focus 后 calls 里只有 setActive(false) 或者什么都没有
```

  现有的 `flutter_editor_test.dart` 用例全部不改，照样要过（这对应规格 §7「开关关着时现有测试全部照过」）。

- [ ] **Step 2: 跑，确认失败**

  Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/flutter_editor_test.dart`

  Expected: 新用例失败，旧用例通过。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑全部 Dart 测试**

  Run:
  - `cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
  - `cd gui/packages/rapp_rime && ~/development/flutter/bin/flutter test`

  Expected: 全部通过，analyze 没有问题。

- [ ] **Step 5: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null
git add gui/lib/embed/flutter_editor.dart gui/test/embed
git commit -m "feat(rime): the writing panel shows Rime's composition and candidate row on iOS"
```

---

### Task 7: 按键接线和补发

**Files:**
- Modify: `gui/ios/Runner/RappViewController.swift`：`pressHandler` 改成：

  ```swift
  { presses, began in
    if SessionPlugin.shared?.handlePresses(presses, began: began) == true { return true }
    guard let press = presses.first else { return false }
    return RappRimePlugin.shared?.handlePress(press, began: began) ?? false
  }
  ```

  文件顶部加 `import rapp_rime`。
- Modify: `gui/macos/Runner/SessionPlugin.swift`：只在 `#if os(iOS)` 里改。
  - 加 `static var replayHook: ((HeldPress) -> Bool)?`。
  - `replay(_:)` 的循环里，在退格和 `insertText` 判断之前加一句 `if Self.replayHook?(p) == true { continue }`。
- Modify: `gui/ios/Runner/AppDelegate.swift`：`import rapp_rime`；注册完插件后设置：

  ```swift
  SessionPlugin.replayHook = { p in RappRimePlugin.shared?.replay(hid: p.hid, characters: p.characters, modifiers: p.modifiers) ?? false }
  ```

- Create: `gui/packages/rapp_rime/tools/sim/`：从探查分支拷 `uitest/simkey.m` 和 `uitest/hwkb.m`，以及它们的编译命令（探查的 `uitest` 里怎么编，就怎么编）。再写一个精简的 `sim.sh`，只有 `builtin`、`repeat`、`compose` 三个场景。
  - 怎么打开设置里的开关：给 app 加一个启动参数 `-rimeTestEnable YES`。它只在 debug 构建里生效，`main_ios.dart` 读到后把 `rimeEnabled` 设为 true。用 `kDebugMode` 加 `IosPlugin` 现有的读启动参数的办法；如果没有现成的办法，就改成让用户在模拟器上手动打开一次开关，把这一步写进 README。

- [ ] **Step 1: 构建两个平台**

  Run: `scripts/build-ios.sh sim --install EE6D588C-B90B-43B6-A38C-22E4C1A07196 && (cd gui && ~/development/flutter/bin/flutter build macos --debug)`

  Expected: 两个都构建成功。

- [ ] **Step 2: 模拟器端到端**

  Run: `gui/packages/rapp_rime/tools/sim/sim.sh EE6D588C-B90B-43B6-A38C-22E4C1A07196 t7 builtin repeat compose`，然后看 `gui/packages/rapp_rime/tools/sim/out/t7/` 里的截图。

  Expected：
  - `builtin`：输入 `n i h a o` 后，组字带下划线，候选行出现「你好」；按 `1` 后，上屏「你好」。
  - `repeat`：按住退格 1.5 s，删掉多个字；按住 `a`，组字里出现多个 a。
  - `compose`：在会话画面上（输入板关着）打 `n i`，输入板打开后，`ni` 在 Rime 的组字里，而不是英文 `ni` 已经上屏。这一条要模拟器上连着一个会话；如果连不上 A，把它记为「待真机」，不算失败。
  - 任何一张截图里都不能出现系统的候选条。

- [ ] **Step 3: 提交**

```bash
git add gui/ios/Runner gui/macos/Runner/SessionPlugin.swift gui/packages/rapp_rime/tools gui/lib/main_ios.dart
git commit -m "feat(rime): route local presses and type-to-compose replays through the built-in IME"
```

---

### Task 8: 收尾、真机检查清单、交给 rapp-49 前的验证

**Files:**
- Modify: `tasks/todo.md`：加一节「iOS 内置输入法 实机检查」，内容是规格 §7 的 1–12 条原文，每条前面放 `- [ ]`。
- Modify: `gui/packages/rapp_rime/README.md`：补「模拟器脚本」一节。

- [ ] **Step 1: 全量验证**

  Run: `cargo test --workspace --manifest-path rust/Cargo.toml && (cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze) && (cd gui/packages/rapp_rime && ~/development/flutter/bin/flutter test) && RAPP_RIME_KEYS_ONLY=1 swift test --package-path gui/packages/rapp_rime/ios/rapp_rime && swift test && scripts/build-ios.sh sim && (cd gui && ~/development/flutter/bin/flutter build macos --debug)`

  Expected: 全部通过。`swift test` 是根目录 `Package.swift` 的那一套，确认 SessionPlugin 的改动没碰到它。

- [ ] **Step 2: 装到 Duo**（替换掉探查版；用户要在场，并且手机已解锁）

  Run: `scripts/build-ios.sh device --install 00008160-000924982EC00036`

- [ ] **Step 3: 请用户按 `tasks/todo.md` 的清单在 Duo 和 iPad 上各走一遍**，把结果记在清单里。
- [ ] **Step 4: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null
git add tasks/todo.md gui/packages/rapp_rime/README.md
git commit -m "docs(rime): real-device checklist and simulator script notes"
```

- [ ] **Step 5: 真机检查过了之后，把分支名 `feat/ios-rime` 交给 rapp-49 合并。** 合并到 main 就会自动发版，所以检查没过不要交。

---

### Task 9（只有 Task 0 测出冷部署超过 5 s 时才做）：构建时预编译词库

**Files:**
- Modify: `gui/packages/rapp_rime/scripts/fetch.sh`：加一步，在 Mac 上用 `rime_deployer --build`（从 rime-deps 包里取，或者用 Homebrew 的 librime）编出 `build/`，放进 `RimeData/build/`。
- Modify: `RimeEngine.swift`：第一次用自带雾凇时，把 `RimeData/build` 拷进用户目录的 `build/`（目标已存在、并且 `rapp_rime_data_version` 相同就不拷）。

- [ ] **Step 1**: 改 `fetch.sh`，记下 `RimeData/build` 有多大。
- [ ] **Step 2**: 改 `RimeEngine`，模拟器冷启动，记下从 `starting` 到 `ready` 的时间（目标 < 1 s）。
- [ ] **Step 3**: Duo 上重测冷部署，把数字写进规格 §6.6。
- [ ] **Step 4**: 提交 `feat(rime): ship prebuilt Rime tables`。
