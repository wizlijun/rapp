# GUI 客户端状态规则（R1–R4 + R6）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 被控端（macOS）按操作端发来的一包规则看 app 窗口的画面，推断它在干活、做完了、在等确认，把结果报回操作端；主控台在灯上显示推断的状态（标“推断”），只有验过的“在等确认”才进“需要你”。

**Architecture:** 引擎是 `Sources/RappCore/StateRules/` 下的纯逻辑（只用 Foundation，iOS 也能编），输入一张 1 点 1 像素的 BGRA 小图 `RuleImage`，输出 `AppStateReport`。被控端 `AppStateWatcher` 每 0.5 秒把最新一帧里主窗口那块缩下来喂给引擎，结果变了才发。规则存在操作端（Flutter）：内置一份 `gui/assets/state_rules.json`，加上数据目录里的“我的”；会话连上时操作端解开继承和补丁，把一包（变体留着）发给被控端，变体由被控端按版本、主题、语言、窗口宽度和区域找没找到来挑。协议升到 v16，加两条纯 JSON 文本的消息。

**Tech Stack:** Swift 6（RappCore、rapp-host、RappSession，XCTest），macOS Vision（文字识别），Rust（`rapp-client-core`、`rapp-host-linux`），Flutter（`gui/`，flutter_test）。

**Spec:** `docs/superpowers/specs/2026-11-25-rapp-app-state-rules-design.md`（下称“规格”）；背景在 `docs/superpowers/specs/2026-11-25-rapp-app-working-state-research.md`（下称“调研”）。本计划做规格 §11 的 R1、R2、R3、R4、R6。R5（标注和互证）、R7（导入导出）另写计划。

## Global Constraints

- 只看画面，不碰 app：不读 app 的本地文件（版本号只读 app 包里的 `Contents/Info.plist`，规格 §8），不用控件树，不发任何输入（规格 §1）。
- 推断的状态不触发任何自动点击或输入（规格 §1）。
- 状态词和终端那边一样：`working`、`done`、`blocked`（可带 `kind`）、`idle`（规格 §4.4）。
- **不报**画面和识别出的文字；侧栏每一行的标题不取，只报个数（规格 §4.5）。识别出的文字也**不进日志**。
- 一包规则不超过 65536 字节；规则里没有脚本、没有图片、没有要去取的地址（规格 §9）。
- `format` 是 `"大.小"`：大版本不是 `1` 整包跳过；小版本更新照常读（规格 §5.4）。不认识的区域写法、认法、字段只让用到它的标志不作数，不丢整包（规格 §5.4）。
- 只有 `status` 是 `tested` 的标志能让会话进“需要你”，其余只改灯（规格 §6.5）。
- 自检：窗口看得见时，`require` 里的区域连着 5 轮找不到就判“对不上”（规格 §7）。
- 没有规则、`stateRules: off`、或者规则不适用时，行为和现在完全一样（规格 §7）。
- 第一阶段两层：内置 + 我的；不做规则源（规格 §9）。
- 协议 v16 五头一起升：Swift `protocolVersion`、Rust `VERSION`、Dart `sessionProtocolVersion`、`scripts/test-linux-client.py` 的 `PROTOCOL`；严格相等，不兼容 v15。
- 不提交到 `main`。在 worktree `.worktrees/app-state-rules` 的分支 `feat/app-state-rules` 上做，做完把分支名交给 rapp-49 合并。
- Swift 跑 `swift build && swift test`；Rust 改完跑 `cd rust && cargo test --workspace --no-fail-fast`（testkit 有断言）；Flutter 在 `~/development/flutter/bin/flutter`，跑完测试把 `gui/pubspec.lock` 还原（`git checkout gui/pubspec.lock`）。
- 改了 `gui/macos/Runner/SessionPlugin.swift` 或 `Sources/RappSession/` 就要编一次 iOS（`scripts/build-ios.sh` 或 `xcodebuild -scheme RappCore-iOS …`，见 `scripts/check.sh`），这两处 iOS 也在用。

## Review Focus

1. **规则先到、画面后到**：会话一连上就发规则，被控端 capture 还没 ready —— 规则要存着，ready 后用上（Task 8 `pendingRules`）。重连后新链接要再发一次（Task 11 测试“rules go out on every ready”）。
2. **窗口最小化、被遮住、换到别的桌面**：看不见的轮不算自检，不能误判“对不上”（Task 7 `testSelfCheck…` 里 `visible: false` 那段）。
3. **“我的”目录里有坏文件**：坏 JSON、更高大版本、成环的继承、超大的包，都只跳过那一个，启动和别的包照常（Task 10 “bad mine files…”）。
4. **规则不适用**（`state` 为 `null`）：灯、行、需要你都要和没有规则时一模一样（Task 11 “state null（unfit）→ 灯和没有规则时一样”）。
5. **Linux 的 `rapp-session` 收到坏命令会断会话**：操作端发之前就挡掉超限的规则，`rapp-session` 自己也校验（Task 2 超限测试、Task 11 `SessionPort.stateRules` 的大小检查）。

## Wire format（v16，本计划定的）

| 类型 | 方向 | 名字 | 载荷 |
|---|---|---|---|
| 43 | 操作端 → 被控端 | `stateRules` | 整个载荷是一包规则的 UTF-8 JSON（和类型 5 `text` 一样不带长度前缀），最多 65536 字节；空载荷表示“这个会话不用规则” |
| 44 | 被控端 → 操作端 | `appState` | 整个载荷是一份报告的 UTF-8 JSON，最多 4096 字节 |

报告（`appState`）的 JSON，键按字母排序输出：

```json
{"appVersion":"7.37095.0","by":["stop"],"caps":["pixels","text"],"counts":{"rowDot":0,"rowGray":1},
 "health":"ok","inferred":true,"kind":null,"pack":"claude-desktop","rev":1,"state":"working","sure":false,"variants":[]}
```

- `state`：`working`、`done`、`blocked`、`idle`，或者 `null`（规则不适用、还没算出来）。
- `by`：让这一条状态成立的标志名（`when` 里引用到、此刻成立的那些），按名字排序。
- `sure`：`by` 不空且其中每个标志的 `status` 都是 `tested`。主控台只在 `state == "blocked" && sure` 时进“需要你”。
- `health`：`ok`；`switched`（自检后自动换了变体）；`unfit`（换遍了也对不上，`state` 为 `null`）；`invalid`（规则读不了，带 `"error"`）。
- `variants`：此刻盖上去的变体名（变体没写 `name` 就用 `"#<下标>"`）。
- `counts`：每个 `count: true`、并且能用的标志命中了几个，最多 32 个键。

Linux 侧：`rapp-session` 收命令 `{"cmd":"state_rules","json":"…"}`，发事件 `{"event":"app_state","json":"…"}`；Linux 被控端收到 43 只记一行日志、不回报告（第一阶段只做 macOS 被控端）。macOS/iOS 的 Flutter 通道：方法 `state_rules`（参数 `sid`、`json`），事件 `app_state`（参数 `json`）。

---

## File Structure

| 文件 | 职责 |
|---|---|
| `Sources/RappCore/Protocol.swift` | v16；`stateRules`（43）、`appState`（44） |
| `Sources/RappCore/StateRules/RuleValue.swift`（新） | JSON 值、解析、补丁合并 |
| `Sources/RappCore/StateRules/RulePack.swift`（新） | 一包规则的类型和宽容的解码 |
| `Sources/RappCore/StateRules/RuleImage.swift`（新） | 1 点 1 像素的 BGRA 小图、从采集缓冲裁剪缩放、取色、HSL |
| `Sources/RappCore/StateRules/Regions.swift`（新） | `box`、`edge`、`blob`、`strip` 四种区域 |
| `Sources/RappCore/StateRules/Detectors.swift`（新） | `shape`、`color`、`motion`、`text`、`present`；标志求值和数个数 |
| `Sources/RappCore/StateRules/StateTable.swift`（新） | `when` 表达式、`hold`/`release` |
| `Sources/RappCore/StateRules/StateEngine.swift`（新） | 变体、主题、自检退回、报告 |
| `Sources/rapp-host/AppStateWatcher.swift`（新） | 取帧、缩图、定时跑引擎、发报告；读 app 版本 |
| `Sources/rapp-host/VisionText.swift`（新） | `TextReader` 的 Vision 实现 |
| `Sources/rapp-host/Server.swift` | 收 `stateRules`、建 watcher、喂帧、窗口表 |
| `Sources/RappSession/{SessionEvent,EmbeddedSession,Channel}.swift`、`gui/macos/Runner/SessionPlugin.swift` | 转发 `state_rules` 命令和 `app_state` 事件 |
| `rust/client-core/src/protocol.rs`、`src/bin/rapp-session.rs`、`rust/host-linux/src/{wire,server}.rs`、`scripts/test-linux-client.py` | Linux 两头的 v16 |
| `gui/assets/state_rules.json`（新） | 规格 §6 的四包默认规则 |
| `gui/lib/embed/state_rules.dart`（新） | 两层、继承、补丁、挑包（纯 Dart） |
| `gui/lib/embed/app_state.dart`（新） | `AppState` 报告的解析 |
| GUI 其余接线 | 见 Task 11、12 |

---

### Task 1: Swift 协议 v16 和会话转发

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`（`protocolVersion = 16`；两个 case；`encoded`、`decode`、`knownTypes`）
- Modify: `Sources/rapp-host/Server.swift:407-530`（`handle` 的两个 `switch` 认得新 case；`stateRules` 先空着，Task 8 接上；`appState` 进“unexpected message from client”那一行）
- Modify: `Sources/RappSession/SessionEvent.swift`、`EmbeddedSession.swift:315-321`、`Channel.swift`（命令 `state_rules`、事件 `app_state`）
- Modify: `gui/macos/Runner/SessionPlugin.swift:401`（`.stateRules(sid, json)` → `live[sid]?.session.send(.stateRules(json))`）
- Modify: `gui/lib/embed/session_protocol.dart`（`16`）
- Test: `Tests/RappCoreTests/ProtocolTests.swift`、`Tests/RappSessionTests/ChannelTests.swift`、`Tests/RappSessionTests/EmbeddedSessionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  case stateRules(String)   // 43, client -> host (v16), payload = UTF-8 JSON, ≤ stateRulesLimit
  case appState(String)     // 44, host -> client (v16), payload = UTF-8 JSON, ≤ appStateLimit
  public let stateRulesLimit = 65536
  public let appStateLimit = 4096
  // RappSession
  SessionEvent.appState(String)
  ChannelCommand.stateRules(sid: Int64, json: String)
  ```

- [ ] **Step 1: 写失败的测试**

```swift
func testStateRulesAndAppStateWireFormat() throws {
    XCTAssertEqual(protocolVersion, 16)
    XCTAssertEqual(Message.stateRules("{}").encoded(), [43, 2, 0, 0, 0, 0x7B, 0x7D])
    XCTAssertEqual(Message.stateRules("").encoded(), [43, 0, 0, 0, 0])
    XCTAssertEqual(Message.appState("{}").encoded(), [44, 2, 0, 0, 0, 0x7B, 0x7D])
    XCTAssertEqual(try decodeOne([43, 2, 0, 0, 0, 0x7B, 0x7D]), .stateRules("{}"))
    XCTAssertEqual(try decodeOne([44, 2, 0, 0, 0, 0x7B, 0x7D]), .appState("{}"))
    // Too large, and not UTF-8.
    var big: [UInt8] = [43] + withUnsafeBytes(of: UInt32(stateRulesLimit + 1).littleEndian, Array.init)
    big += [UInt8](repeating: 0x20, count: stateRulesLimit + 1)
    XCTAssertThrowsError(try decodeOne(big))
    XCTAssertThrowsError(try decodeOne([44, 1, 0, 0, 0, 0xFF]))
}
```
把 `testScreenLockedAndUnlockWireFormat` 里的 `XCTAssertEqual(protocolVersion, 15)` 删掉（版本号只在上面这一处断言）。

`ChannelTests`：
```swift
func testStateRulesCommandAndAppStateEvent() throws {
    XCTAssertEqual(try channelCommand("state_rules", ["sid": 2, "json": "{\"id\":\"x\"}"]), .stateRules(sid: 2, json: "{\"id\":\"x\"}"))
    XCTAssertThrowsError(try channelCommand("state_rules", ["sid": 2]))
    let e = try XCTUnwrap(eventPayload(.appState("{\"state\":\"done\"}"), sid: 4, textures: [:]))
    XCTAssertEqual(e.method, "app_state")
    XCTAssertEqual(e.args["json"] as? String, "{\"state\":\"done\"}")
    XCTAssertEqual(e.args["sid"] as? Int64, 4)
}
```
`EmbeddedSessionTests` 照 `secureFocus` 那个测试（`link.feed(.secureFocus(true))`，第 253 行附近）加一个：`link.feed(.appState("{}"))` 之后 `events` 里有 `.appState("{}")`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter 'ProtocolTests|ChannelTests|EmbeddedSessionTests' 2>&1 | tail -20`
Expected: 编译失败（没有 `stateRules`）。

- [ ] **Step 3: 实现**

`encoded`：两条都 `w.bytes += Array(json.utf8)`，`precondition` 不变；超限的 `stateRules` 由调用方保证（主控台在 Task 10 先查大小）。`decode`：`43`、`44` 读剩下全部字节，`String(validating: …, as: UTF8.self)` 失败抛 `CodecError("rules not UTF-8")` / `CodecError("state not UTF-8")`，超限抛 `CodecError("rules too large")` / `CodecError("state too large")`。两个都加进 `knownTypes`。`Protocol.swift` 顶上版本说明加一行 `v16: stateRules (43), appState (44)`。

`EmbeddedSession` 收到 `.appState(json)` → `onEvent?(.appState(json))`；`Channel.eventPayload` → `payload("app_state", ["json": json])`。`channelCommand("state_rules")` → `.stateRules(sid: try a.int("sid"), json: try a.string("json"))`。`EmbeddedSession` 自己的 `switch` 里收到 `.stateRules` 当作不该来的消息，和别的 client→host 消息放在一起。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: 全部通过，没有新警告。

- [ ] **Step 5: 编 iOS（`SessionPlugin.swift` 和 RappSession 两边都用）**

Run: `xcodebuild -scheme RappCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/RappCore/Protocol.swift Sources/rapp-host/Server.swift Sources/RappSession gui/macos/Runner/SessionPlugin.swift gui/lib/embed/session_protocol.dart Tests
git commit -m "feat(protocol): v16 stateRules (43) and appState (44)"
```

---

### Task 2: Linux 两头的 v16

**Files:**
- Modify: `rust/client-core/src/protocol.rs`（`VERSION = 16`；`Incoming::AppState(String)`；`read_message` 的允许表加 `44`；`decode` 的 `44`；`pub fn state_rules(json: &str) -> Vec<u8>`）
- Modify: `rust/client-core/src/bin/rapp-session.rs`（命令 `state_rules`、事件 `app_state`）
- Modify: `rust/host-linux/src/wire.rs`（`43 => Input::StateRules`，长度和 UTF-8 检查）、`rust/host-linux/src/server.rs`（收到只在第一次记一行 `state rules: not supported on this host`，别的不做）
- Modify: `scripts/test-linux-client.py`（`PROTOCOL = 16`，文件头注释里的 v15 改 v16）
- Test: 同文件里的 `#[cfg(test)]`、`rust/client-core/tests/client.rs`

**Interfaces:**
- Consumes: Task 1 的类型号和上限（43、44；65536、4096）。
- Produces: `pub const STATE_RULES_LIMIT: usize = 65536;`、`pub const APP_STATE_LIMIT: usize = 4096;`（`protocol.rs`）。

- [ ] **Step 1: 写失败的测试**

`protocol.rs` 测试：
```rust
#[test]
fn v16_state_messages() {
    assert_eq!(VERSION, 16);
    assert_eq!(state_rules("{}"), vec![43, 2, 0, 0, 0, b'{', b'}']);
    assert!(matches!(decode(44, b"{\"state\":\"done\"}"), Ok(Incoming::AppState(s)) if s == "{\"state\":\"done\"}"));
    assert!(decode(44, &[0xFF]).is_err());
    assert!(decode(44, &vec![b' '; APP_STATE_LIMIT + 1]).is_err());
}
```
`rapp-session.rs` 测试（照第 454 行那几条）：`command(&json!({"cmd":"state_rules","json":"{}"})).unwrap() == state_rules("{}")`；`{"cmd":"state_rules"}` 是错误；超过 `STATE_RULES_LIMIT` 的 `json` 是错误。事件：`Incoming::AppState("{}".into())` 转出 `{"event":"app_state","json":"{}"}`（照 `covered` 在第 387 行的写法）。
`wire.rs` 测试：`input(43, b"{}")` 是 `Ok(Input::StateRules)`；`input(43, &[0xFF])` 是错误；超过 65536 字节是错误。`input(43, b"")` 是 `Ok(Input::StateRules)`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-client-core -p rapp-host-linux --no-fail-fast 2>&1 | tail -20`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`Input::StateRules` 不带内容（第一阶段 Linux 不算）。`MAX_INPUT` 是 1 MB，够放 64 KB。`client-core/tests/client.rs:813` 和 `tests/host_wire.rs:256` 里取 `VERSION` 的地方不用改；有写死 `15` 的就改成 `16`（`git grep -n "15" rust/client-core/tests | grep -i version` 查一遍）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test --workspace --no-fail-fast 2>&1 | grep -E "^test result|FAILED|panicked" | sort | uniq -c`
Expected: 每行都是 `ok`，没有 `FAILED`。（`rapp-term` 的 dead-socket 测试在机器忙时偶尔失败，单独重跑一次通过就算过。）
Run: `cd rust && cargo clippy --workspace --all-targets 2>&1 | tail -3`
Expected: 没有新的警告。

- [ ] **Step 5: Commit**

```bash
git add rust/client-core rust/host-linux scripts/test-linux-client.py
git commit -m "feat(linux): protocol v16 — rapp-session forwards state rules and app state; host ignores rules"
```

---

### Task 3: 规则的 JSON 值、补丁合并和解码

**Files:**
- Create: `Sources/RappCore/StateRules/RuleValue.swift`、`Sources/RappCore/StateRules/RulePack.swift`
- Test: `Tests/RappCoreTests/RulePackTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public indirect enum RuleValue: Equatable {
      case null, bool(Bool), number(Double), string(String), array([RuleValue]), object([String: RuleValue])
      public static func parse(_ data: Data) throws -> RuleValue      // top level must be an object; RuleError.badJSON
      public func merged(with patch: RuleValue) -> RuleValue           // 规格 §5.3
      public subscript(key: String) -> RuleValue? { get }              // nil unless .object containing key
  }
  public enum RuleError: Error, Equatable { case tooLarge, badJSON, unsupportedFormat(String), notAPack(String) }
  public let ruleBytesLimit = 65536
  public enum RegionRef: Equatable { case named(String), inline(RegionSpec) }
  public indirect enum RegionSpec: Equatable {
      case box(BoxSpec), edge(EdgeSpec), blob(BlobSpec), strip(StripSpec), unknown
  }
  public enum Length: Equatable { case points(Double), percent(Double) }   // 160 or "40%"
  public struct BoxSpec: Equatable { var inside: RegionRef?; var rightOf, leftOf, above, below: String?
                                     var top, bottom, left, right, width, height: Length? }
  public struct EdgeSpec: Equatable { var inside: RegionRef?; var from: Side; var min, max: Double }
  public struct BlobSpec: Equatable { var inside: RegionRef; var round: Bool; var size: ClosedRange<Double>; var pick: Pick }
  public struct StripSpec: Equatable { var of: RegionRef; var side: Side; var width: Double }
  public enum Side: String { case left, right, top, bottom }
  public enum Pick: String { case rightmost, leftmost, topmost, bottommost, largest, all }
  public struct ColorRange: Equatable { var h: ClosedRange<Double>?; var s, l: ClosedRange<Double>? } // h 可 a>b 表示跨 0
  public enum Detect: Equatable {
      case shape(String, min: Double), color(ColorRange), motion(window: Double, min: Double), text([String]), present
  }
  public enum SignalStatus: String { case tested, seen, reported, untested }
  public struct SignalSpec: Equatable { var region: RegionRef?; var detects: [Detect]; var count: Bool
                                        var needs: Set<String>; var status: SignalStatus; var usable: Bool }
  public indirect enum Condition: Equatable { case signal(String), any([Condition]), all([Condition]), not(Condition), never }
  public struct StateRow: Equatable { var state: String; var kind: String?; var when: Condition?; var hold, release: Double }
  public struct VariantSpec: Equatable { var name: String; var when: RuleValue; var patch: RuleValue }
  public struct RulePack: Equatable {
      public var id: String, name: String, rev: Int
      public var regions: [String: RegionSpec], signals: [String: SignalSpec]
      public var states: [StateRow], require: [String], variants: [VariantSpec]
      public static func decode(_ v: RuleValue) throws -> RulePack
      public static func parse(_ data: Data) throws -> RuleValue        // size check, then RuleValue.parse
  }
  ```
  `BoxSpec.inside` 对应 JSON 的 `"in"`（`in` 是 Swift 关键字）。

- [ ] **Step 1: 写失败的测试**

```swift
final class RulePackTests: XCTestCase {
    private func v(_ s: String) throws -> RuleValue { try RuleValue.parse(Data(s.utf8)) }

    func testMergeByKeyNullDeletesArraysReplace() throws {
        let base = try v(#"{"a":{"x":1,"y":2},"b":[1,2],"c":3}"#)
        let patch = try v(#"{"a":{"y":null,"z":4},"b":[9],"d":{"e":null,"f":1}}"#)
        XCTAssertEqual(base.merged(with: patch), try v(#"{"a":{"x":1,"z":4},"b":[9],"c":3,"d":{"f":1}}"#))
    }

    func testGenericChatDecodes() throws {
        let p = try RulePack.decode(try v(genericChatJSON))   // 规格 §6.1 原文，放在测试文件里的常量
        XCTAssertEqual(p.id, "generic-chat")
        XCTAssertEqual(p.require, ["bottom"])
        XCTAssertEqual(p.states.map(\.state), ["working", "idle"])
        XCTAssertEqual(p.states[0].hold, 0.6); XCTAssertEqual(p.states[0].release, 2.0)
        XCTAssertEqual(p.signals["stop"]?.detects, [.shape("square", min: 0)])
        XCTAssertEqual(p.signals["rowBusy"]?.count, true)
        guard case .blob(let b)? = p.regions["markers"], case .inline(.strip(let s)) = b.inside else { return XCTFail() }
        XCTAssertEqual(s.of, .named("sidebar")); XCTAssertEqual(s.width, 40); XCTAssertEqual(b.pick, .all)
        XCTAssertEqual(b.size, 6...20)
    }

    func testForwardCompatibility() throws {
        // Unknown region kind, unknown detect, unknown field, newer minor format: only the affected parts drop.
        let p = try RulePack.decode(try v(#"""
        {"format":"1.7","id":"x","rev":2,"future":true,
         "regions":{"a":{"box":{"top":0}},"b":{"hexagon":{}}},
         "signals":{"s1":{"in":"a","detect":{"present":true}},"s2":{"in":"a","detect":{"smell":"rose"}},
                    "s3":{"in":"b","detect":{"present":true}}},
         "states":[{"state":"working","when":{"any":["s1"]}},{"state":"sleeping","when":{"any":["s1"]}},{"state":"idle"}]}
        """#))
        XCTAssertEqual(p.regions["b"], .unknown)
        XCTAssertEqual(p.signals["s1"]?.usable, true)
        XCTAssertEqual(p.signals["s2"]?.usable, false)
        XCTAssertEqual(p.states.map(\.state), ["working", "idle"])   // unknown state word skipped
    }

    func testRejects() throws {
        XCTAssertThrowsError(try RulePack.decode(try v(#"{"format":"2.0","id":"x"}"#))) {
            XCTAssertEqual($0 as? RuleError, .unsupportedFormat("2.0"))
        }
        XCTAssertThrowsError(try RulePack.decode(try v(#"{"format":"1.0"}"#)))           // no id
        XCTAssertThrowsError(try RulePack.parse(Data("{".utf8))) { XCTAssertEqual($0 as? RuleError, .badJSON) }
        XCTAssertThrowsError(try RulePack.parse(Data("[]".utf8))) { XCTAssertEqual($0 as? RuleError, .badJSON) }
        XCTAssertThrowsError(try RulePack.parse(Data(repeating: 0x20, count: ruleBytesLimit + 1))) {
            XCTAssertEqual($0 as? RuleError, .tooLarge)
        }
    }

    func testDetectForms() throws {
        let p = try RulePack.decode(try v(#"""
        {"format":"1.0","id":"x","regions":{"r":{"box":{"left":"10%","width":30}}},
         "signals":{"a":{"in":"r","detect":{"shape":{"is":"dot","min":0.7},"color":{"h":[340,20],"l":[35,70]}}},
                    "b":{"in":"r","detect":{"motion":{"window":0.4}},"status":"seen"},
                    "c":{"in":"r","detect":{"text":["Worked for*"]},"needs":["text"],"status":"tested"},
                    "d":{"in":"r","detect":{"color":"green"}}}}
        """#))
        XCTAssertEqual(p.signals["a"]?.detects.first, .shape("dot", min: 0.7))
        XCTAssertEqual(p.signals["b"]?.detects, [.motion(window: 0.4, min: 0.02)])
        XCTAssertEqual(p.signals["b"]?.status, .seen)
        XCTAssertEqual(p.signals["c"]?.needs, ["text"])                 // text detect also implies "text"
        XCTAssertEqual(p.signals["d"]?.detects, [.color(ColorRange.named("green")!)])
        XCTAssertEqual(p.signals["a"]?.status, .untested)               // missing status
        guard case .box(let b)? = p.regions["r"] else { return XCTFail() }
        XCTAssertEqual(b.left, .percent(10)); XCTAssertEqual(b.width, .points(30))
    }

    func testConditionForms() throws {
        let p = try RulePack.decode(try v(#"""
        {"format":"1.0","id":"x","states":[
          {"state":"blocked","kind":"permission","when":{"all":["a",{"not":"b"}]}},
          {"state":"done","when":{"weird":1}},{"state":"idle"}]}
        """#))
        XCTAssertEqual(p.states[0].when, .all([.signal("a"), .not(.signal("b"))]))
        XCTAssertEqual(p.states[0].kind, "permission")
        XCTAssertEqual(p.states[1].when, .never)
        XCTAssertNil(p.states[2].when)
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter RulePackTests 2>&1 | tail -5`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`RuleValue.parse` 用 `JSONSerialization`（`NSNumber` 是不是布尔用 `CFGetTypeID(n) == CFBooleanGetTypeID()` 分）。`merged`：两边都是对象才按键合并，补丁里值是 `null` 就删掉这个键；补丁是对象而底下不是对象时，结果是补丁去掉所有 `null` 键（递归）；其余情况补丁整个替换（数组也是）。

解码规则（规格 §4.2、§4.3、§5.4）：
- `format` 必须有，取 `.` 前的整数；不是 `1` 抛 `.unsupportedFormat(原文)`。没有 `id` 抛 `.notAPack("id")`。`rev` 缺省 `0`，`name` 缺省用 `id`。`extends`、`ids`、`updated` 引擎不用（操作端解开），读到也不报错。
- 区域：值是对象，按 `box`、`edge`、`blob`、`strip` 的顺序取第一个出现的键；都没有就是 `.unknown`。`"in"`/`"of"` 是字符串就是 `.named`，是对象就按区域解（`.inline`）。`Length`：数字是点，`"NN%"` 是百分比，别的写法让整个区域 `.unknown`。`edge` 缺 `from` 或 `min`/`max` 也是 `.unknown`。`blob.size` 是两个数的数组；`pick` 缺省 `largest`，`round` 缺省 `false`。
- 认法：`detect` 里每个键一项；有一个键不认识或者值的写法不对，这个标志 `usable = false`。`shape` 可写字符串或 `{"is":…, "min":…}`（`min` 缺省 0）；`motion` 的 `window` 缺省 `0.4`，`min` 缺省 `0.02`；`present` 只认 `true`；`color` 可写颜色名（`ColorRange.named`，下面 Task 5 定表）或 `{"h","s","l"}` 三个可选的两数数组（`s`、`l` 是百分数）。`text` 在 `detect` 里时 `needs` 自动加 `"text"`，有 `pixels` 一类的认法时加 `"pixels"`。
- `status` 缺省或不认识都是 `.untested`。
- `when`：字符串是标志名；`{"any":[…]}`、`{"all":[…]}`、`{"not":…}`；空数组和不认识的写法都是 `.never`。
- `states`：`state` 不是 `working`、`done`、`blocked`、`idle` 的行整行跳过；`hold`、`release` 缺省 `0`。
- `variants`：每项 `{"name"?, "when": {…}, "patch": {…}}`，没有 `name` 用 `"#<下标>"`；`when` 原样留着给 Task 7 判断。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter RulePackTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/RappCore/StateRules Tests/RappCoreTests/RulePackTests.swift
git commit -m "feat(rules): rule pack values, patch merge and tolerant decoding"
```

---

### Task 4: 小图和四种区域

**Files:**
- Create: `Sources/RappCore/StateRules/RuleImage.swift`、`Sources/RappCore/StateRules/Regions.swift`
- Test: `Tests/RappCoreTests/RuleRegionTests.swift`；合成图的小工具 `Canvas`（纯色底、矩形、圆、环、聊天窗口）放在 `Tests/RappCoreTests/RuleCanvas.swift`，Task 5、7 接着往里加

**Interfaces:**
- Consumes: Task 3 的 `RulePack`、`RegionSpec`、`RegionRef`。
- Produces:
  ```swift
  public struct RuleRect: Equatable, Hashable { public var x, y, w, h: Int }    // image points, y down
  public struct RuleImage {
      public let width: Int, height: Int          // points; one pixel per point
      public var pixels: [UInt8]                  // BGRA, width*4 bytes per row
      public init(width: Int, height: Int, pixels: [UInt8])
      /// Crops `crop` (pixels of the source) and scales it to one pixel per point by nearest neighbour.
      public static func sample(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                                crop: RuleRect, scale: Double) -> RuleImage?
      public func rgb(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8)
  }
  public struct HSL: Equatable { public var h, s, l: Double }   // h 0..<360, s/l 0...100
  public func hsl(r: UInt8, g: UInt8, b: UInt8) -> HSL
  public func colorDistance(_ a: (r: UInt8, g: UInt8, b: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8)) -> Int  // max channel diff
  public let regionContrast = 16      // edge: a column differs from the reference by this much
  public let blobContrast = 24        // blob / shape foreground threshold
  /// Every region the pack names, resolved; a missing region has no entry. Single regions have one rect.
  public func resolveRegions(_ pack: RulePack, in image: RuleImage) -> [String: [RuleRect]]
  ```

- [ ] **Step 1: 写失败的测试**

合成一个 800×600 的“聊天窗口”：左边 240 点宽的侧栏底色 `(240,240,240)`，主栏底色白 `(255,255,255)`，主栏底部 y 500–580 有一个输入框，输入框右边 x 740–772、y 520–552 画一个黑色实心圆，圆里画白色 12×12 方块；侧栏右侧 x 210–222 在 y 100、140、180 画三个 12 点的圆点。

```swift
func testGenericChatRegionsOnASyntheticWindow() throws {
    let img = Canvas.chatWindow()                               // 上面描述的图
    let r = resolveRegions(try genericChat(), in: img)          // 规格 §6.1 的包
    XCTAssertEqual(r["sidebar"], [RuleRect(x: 0, y: 0, w: 240, h: 600)])
    XCTAssertEqual(r["main"], [RuleRect(x: 240, y: 0, w: 560, h: 600)])
    XCTAssertEqual(r["bottom"], [RuleRect(x: 240, y: 440, w: 560, h: 160)])
    XCTAssertEqual(r["tail"], [RuleRect(x: 240, y: 200, w: 560, h: 240)])
    XCTAssertEqual(r["button"], [RuleRect(x: 740, y: 520, w: 32, h: 32)])
    XCTAssertEqual(r["markers"]?.count, 3)
    XCTAssertEqual(r["markers"]?.map(\.y), [100, 140, 180])     // top to bottom
}

func testNoSidebarMeansMainIsTheWholeWindow() throws {
    let img = Canvas.chatWindow(sidebar: false)
    let r = resolveRegions(try genericChat(), in: img)
    XCTAssertNil(r["sidebar"]); XCTAssertNil(r["markers"])
    XCTAssertEqual(r["main"], [RuleRect(x: 0, y: 0, w: 800, h: 600)])
}

func testDarkThemeAndTwoTimesNarrowerWindow() throws {
    let img = Canvas.chatWindow(width: 400, dark: true)         // sidebar (32,32,32), main (18,18,18), sidebar 240 wide
    let r = resolveRegions(try genericChat(), in: img)
    XCTAssertEqual(r["sidebar"], [RuleRect(x: 0, y: 0, w: 240, h: 600)])
    XCTAssertNotNil(r["button"])
}

func testBoxLengthsAndAnchors() throws {
    // percent widths, left+right insets, only-height anchored to an `above` neighbour
    let p = try RulePack.decode(try RuleValue.parse(Data(#"""
    {"format":"1.0","id":"t","regions":{
      "a":{"box":{"left":"25%","width":"50%"}},
      "b":{"box":{"left":10,"right":10,"top":10,"bottom":10}},
      "c":{"box":{"in":"b","bottom":0,"height":100}},
      "d":{"box":{"in":"b","above":"c","height":50}},
      "e":{"box":{"in":"nowhere"}},
      "f":{"box":{"in":"d"}},
      "loop1":{"box":{"in":"loop2"}},"loop2":{"box":{"in":"loop1"}}}}
    """#.utf8)))
    let r = resolveRegions(p, in: Canvas.solid(width: 400, height: 300))
    XCTAssertEqual(r["a"], [RuleRect(x: 100, y: 0, w: 200, h: 300)])
    XCTAssertEqual(r["b"], [RuleRect(x: 10, y: 10, w: 380, h: 280)])
    XCTAssertEqual(r["c"], [RuleRect(x: 10, y: 190, w: 380, h: 100)])
    XCTAssertEqual(r["d"], [RuleRect(x: 10, y: 140, w: 380, h: 50)])
    XCTAssertNil(r["e"]); XCTAssertEqual(r["f"], r["d"])
    XCTAssertNil(r["loop1"]); XCTAssertNil(r["loop2"])
}

func testSampleCropsAndScalesToPoints() {
    // 4x2 source pixels at scale 2 → 2x1 points; each point takes the top-left pixel of its 2x2 cell.
    let src: [UInt8] = [/* row 0 */ 1,0,0,255, 2,0,0,255, 3,0,0,255, 4,0,0,255,
                        /* row 1 */ 5,0,0,255, 6,0,0,255, 7,0,0,255, 8,0,0,255]
    let img = src.withUnsafeBytes { RuleImage.sample(bgra: $0, width: 4, height: 2, bytesPerRow: 16,
                                                     crop: RuleRect(x: 0, y: 0, w: 4, h: 2), scale: 2) }
    XCTAssertEqual(img?.width, 2); XCTAssertEqual(img?.height, 1)
    XCTAssertEqual(img?.rgb(0, 0).b, 1); XCTAssertEqual(img?.rgb(1, 0).b, 3)
    XCTAssertNil(src.withUnsafeBytes { RuleImage.sample(bgra: $0, width: 4, height: 2, bytesPerRow: 16,
                                                        crop: RuleRect(x: 3, y: 0, w: 4, h: 2), scale: 2) })
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter RuleRegionTests 2>&1 | tail -5`
Expected: 编译失败。

- [ ] **Step 3: 实现 `resolveRegions`**

按名字递归解，带“正在解”的集合防环（环上的都算找不到）；`.unknown` 找不到。
- `box`：容器是 `in` 的区域（第一个 rect；`in` 找不到则本区域找不到），没写 `in` 就是整张图。`rightOf X` 把左边界移到 X 的右边，`leftOf`、`above`、`below` 同理；**这几个指向的区域找不到时这条约束不作数**（规格 §6.1：没有侧栏时 `main` 是整个窗口）。然后横、竖各自按下表定，百分比相对容器（约束之后的）大小：

  | 写了 | 结果 |
  |---|---|
  | `left`、`right` | `[min+left, max-right]` |
  | `left`、`width` | `[min+left, min+left+width]` |
  | `right`、`width` | `[max-right-width, max-right]` |
  | 只有 `width` | 贴着关系约束那一边（`rightOf` 贴左、`leftOf` 贴右；竖向 `below` 贴上、`above` 贴下），没有关系约束就贴左/贴上 |
  | 只有 `left` / 只有 `right` | `[min+left, max]` / `[min, max-right]` |
  | 都没写 | 整个容器 |

  结果和容器求交，宽或高 ≤ 0 就找不到。
- `edge`：容器同上。`from: left` 时在 `x ∈ [min, max]`（相对容器）扫列：每列的“签名”是第 10% 到 90% 高度之间每隔 4 行取的像素的逐通道中位数；参照是 `x = min` 那一列；第一个和参照 `colorDistance ≥ regionContrast` 的列就是分界，区域是容器里从左边到这一列（不含）。`right`、`top`、`bottom` 对称。扫不到就找不到。
- `blob`：在容器里取众数色（每通道取高 4 位做直方图）当底色，和底色 `colorDistance ≥ blobContrast` 的点是前景；4 连通求块（每个区域最多看 512 块，多了就停）；留下宽、高都在 `size` 里的块，`round` 时还要 `0.75 ≤ w/h ≤ 1.33`；按 `pick` 取：最右/最左/最上/最下/面积最大的一个，`all` 按从上到下（同一行从左到右）全给。一个都没有就找不到。
- `strip`：`of` 的区域靠 `side` 那边 `width` 点宽（上下两边时是高）的一条，和 `of` 求交。

`RuleImage.sample`：`crop` 超出源图就返回 `nil`；目标大小是 `crop` 的宽高除以 `scale` 向下取整，至少 1。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter RuleRegionTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/RappCore/StateRules Tests/RappCoreTests/RuleRegionTests.swift Tests/RappCoreTests/RuleCanvas.swift
git commit -m "feat(rules): rule image sampling and the box, edge, blob and strip regions"
```

---

### Task 5: 五种认法和标志求值

**Files:**
- Create: `Sources/RappCore/StateRules/Detectors.swift`
- Test: `Tests/RappCoreTests/RuleDetectTests.swift`

**Interfaces:**
- Consumes: Task 3、4。
- Produces:
  ```swift
  public protocol TextReader: AnyObject {
      /// Lines recognised in `rect` of `image`. Runs on the engine's queue; may take tens of milliseconds.
      func lines(in image: RuleImage, rect: RuleRect) -> [String]
  }
  public enum ShapeName: String { case square, dot, ring, arrow, other, none }
  public func shape(in image: RuleImage, rect: RuleRect) -> (name: ShapeName, score: Double)
  public func foregroundColor(in image: RuleImage, rect: RuleRect) -> HSL?
  extension ColorRange { public static func named(_ name: String) -> ColorRange?; public func contains(_ c: HSL) -> Bool }
  public func textMatches(_ patterns: [String], lines: [String]) -> Bool
  public struct SignalResult: Equatable { public var holds: Bool; public var count: Int? }   // count only for count signals
  /// Evaluates every signal of `pack` for one frame. `image == nil`: no new frame since the last call,
  /// so earlier results stand except `motion`, which is false (nothing moved).
  public final class SignalEvaluator {
      public init(caps: Set<String>, text: TextReader?)
      public func evaluate(_ pack: RulePack, regions: [String: [RuleRect]], image: RuleImage?, now: TimeInterval)
          -> [String: SignalResult]
      public func reset()        // pack or variants changed
  }
  public let textEvery: TimeInterval = 2
  ```

- [ ] **Step 1: 写失败的测试**

```swift
func testShapes() {
    XCTAssertEqual(shape(in: Canvas.button(icon: .square), rect: Canvas.buttonRect).name, .square)  // 黑圆里白方块
    XCTAssertEqual(shape(in: Canvas.button(icon: .arrow), rect: Canvas.buttonRect).name, .arrow)    // 黑圆里白箭头
    XCTAssertEqual(shape(in: Canvas.button(icon: .none), rect: Canvas.buttonRect).name, .dot)       // 只有黑圆
    XCTAssertEqual(shape(in: Canvas.bareSquare(), rect: Canvas.buttonRect).name, .square)           // 白底上黑方块
    XCTAssertEqual(shape(in: Canvas.ring(), rect: Canvas.buttonRect).name, .ring)
    XCTAssertEqual(shape(in: Canvas.solid(width: 64, height: 64), rect: RuleRect(x: 8, y: 8, w: 32, h: 32)).name, .none)
}

func testNamedColors() {
    XCTAssertTrue(ColorRange.named("green")!.contains(hsl(r: 52, g: 199, b: 89)))
    XCTAssertTrue(ColorRange.named("gray")!.contains(hsl(r: 160, g: 160, b: 160)))
    XCTAssertFalse(ColorRange.named("gray")!.contains(hsl(r: 52, g: 199, b: 89)))
    XCTAssertTrue(ColorRange.named("red")!.contains(hsl(r: 230, g: 40, b: 40)))     // hue wraps past 0
    XCTAssertNil(ColorRange.named("chartreuse"))
    // A gray dot on a light-gray sidebar: the dot, not the sidebar, is the foreground.
    let img = Canvas.dot(color: (150, 150, 150), on: (240, 240, 240))
    XCTAssertTrue(ColorRange.named("gray")!.contains(foregroundColor(in: img, rect: Canvas.dotRect)!))
}

func testTextPatterns() {
    XCTAssertTrue(textMatches(["Worked for*"], lines: ["Worked for 2m 10s"]))
    XCTAssertFalse(textMatches(["Worked for*"], lines: ["I worked for you"]))      // glob is anchored to the line
    XCTAssertTrue(textMatches(["Allow"], lines: ["Allow once"]))                    // plain word anywhere
    XCTAssertFalse(textMatches(["Allow"], lines: ["Allowance"]))                    // …as a whole word
    XCTAssertTrue(textMatches(["允许"], lines: ["是否允许访问"]))                     // CJK: substring
    XCTAssertTrue(textMatches(["allow"], lines: ["ALLOW"]))                         // case-insensitive
}

func testCountsMotionNeedsAndTextThrottle() throws {
    let pack = try claudeLikePack()          // markers 区域；rowDot 绿、rowGray 灰各 count；busy=motion；ask=text
    let ev = SignalEvaluator(caps: ["pixels"], text: nil)
    var img = Canvas.chatWindow(dots: [.green, .gray, .gray])
    var r = ev.evaluate(pack, regions: resolveRegions(pack, in: img), image: img, now: 0)
    XCTAssertEqual(r["rowDot"], SignalResult(holds: true, count: 1))
    XCTAssertEqual(r["rowGray"], SignalResult(holds: true, count: 2))
    XCTAssertEqual(r["ask"], SignalResult(holds: false, count: nil))       // needs text, no text cap: skipped
    XCTAssertEqual(r["busy"]?.holds, false)                                // first frame: nothing to compare
    img = Canvas.chatWindow(dots: [.green, .gray, .gray], spinnerPhase: 1)  // only the marker area changed
    r = ev.evaluate(pack, regions: resolveRegions(pack, in: img), image: img, now: 0.5)
    XCTAssertEqual(r["busy"]?.holds, true)
    r = ev.evaluate(pack, regions: resolveRegions(pack, in: img), image: nil, now: 1.0)
    XCTAssertEqual(r["busy"]?.holds, false)                                // no new frame: nothing moved
    XCTAssertEqual(r["rowGray"]?.count, 2)                                 // others stand

    let reader = FakeReader(lines: ["Allow", "Deny"])
    let ev2 = SignalEvaluator(caps: ["pixels", "text"], text: reader)
    let a = Canvas.chatWindow(dots: [])
    _ = ev2.evaluate(pack, regions: resolveRegions(pack, in: a), image: a, now: 0)
    _ = ev2.evaluate(pack, regions: resolveRegions(pack, in: a), image: a, now: 0.5)  // same pixels: no new OCR
    let b = Canvas.chatWindow(dots: [], tailText: true)
    _ = ev2.evaluate(pack, regions: resolveRegions(pack, in: b), image: b, now: 1.0)  // changed, but < textEvery
    let r2 = ev2.evaluate(pack, regions: resolveRegions(pack, in: b), image: b, now: 2.1)
    XCTAssertEqual(reader.calls, 2)
    XCTAssertEqual(r2["ask"]?.holds, true)
}
```
`FakeReader` 是测试里的 `final class FakeReader: TextReader`，记调用次数。

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter RuleDetectTests 2>&1 | tail -5`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`shape`：
1. 底色 = rect 外面一圈 1 点宽的像素（贴图边时用 rect 里面最外一圈）逐通道中位数。
2. rect 里和底色 `colorDistance ≥ blobContrast` 的点是前景，取最大的 4 连通块 C；没有就是 `.none`（score 0）。
3. **容器**：C 的外框宽、高都至少占 rect 的 75%，就在 C 的外框往里缩 20% 的那块里，以 C 的点的中位色为底再找一次前景；新前景至少占那块面积的 4% 就改为判断里面最大的块。
4. 判断块 K（外框 w×h，填充率 `fill = 点数/(w*h)`，`aspect = w/h`）：`aspect` 不在 `[0.7, 1.43]` → `.other`；外框中心那一点不在 K 里且 `fill < 0.6` → `.ring`；`fill ≥ 0.88` → `.square`；`fill ≥ 0.6` → `.dot`；其余 → `.arrow`。score：square 取 `fill`，dot 取 `1 - |fill - 0.785| / 0.785`，ring、arrow 取 `1 - fill`，other 取 0。`detect.shape(name, min)` 成立 = 名字相同且 `score ≥ min`。

`foregroundColor`：第 1、2 步的前景点的平均 RGB 转 HSL；没有前景就用 rect 全部点的平均。

颜色名（`s`、`l` 是百分数，`h` 写成 `a > b` 表示跨 0）：

| 名字 | h | s | l |
|---|---|---|---|
| green | 90–170 | 25–100 | 20–80 |
| gray | 任意 | 0–12 | 25–85 |
| blue | 190–250 | 25–100 | 20–80 |
| red | 345–15 | 30–100 | 20–80 |
| orange | 15–45 | 40–100 | 25–80 |

`motion(window, min)`：每个（标志名，第几个 rect）留一串缩略图（rect 缩成最多 16×16 的灰度，带时间，留最近 3 秒）；有新帧时拿当前缩略图和“至少 `window` 秒前”的那张里最新的一张比（没有那么旧的就和最旧的一张比；只有当前一张就不成立），变化（灰度差 ≥ 16）的点占比 ≥ `min` 就成立。rect 大小变了清掉那一串。

`text(patterns)`：模式里有 `*` 就当通配、整行匹配；没有 `*` 时，模式全是 ASCII 就要求在行里作为一个完整的词出现（前后不是字母或数字），否则（中文等）按子串。不分大小写，行先去掉首尾空白。每个标志留一份（缩略图摘要、上次识别的行、上次识别的时间）：缩略图摘要变了**并且**离上次识别 ≥ `textEvery` 才再跑 `TextReader`，否则用上次的行。识别出的行只在这个类里，不往外给。

标志求值：`usable == false`、`needs` 不是 `caps` 的子集、或者用到的区域找不到 → `holds: false`（`count` 标志的 `count` 为 `nil`，不报）。一个标志里的几项认法都成立才算这一个 rect 命中；`count` 标志的 `count` = 命中的 rect 个数，`holds = count ≥ 1`；不数个数的标志任一 rect 命中就成立。`present` 只看区域找没找到。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter RuleDetectTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/RappCore/StateRules/Detectors.swift Tests/RappCoreTests/RuleDetectTests.swift Tests/RappCoreTests/RuleCanvas.swift
git commit -m "feat(rules): shape, color, motion, text and present detectors with counts"
```

---

### Task 6: 状态表和 hold / release

**Files:**
- Create: `Sources/RappCore/StateRules/StateTable.swift`
- Test: `Tests/RappCoreTests/StateTableTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `StateRow`、`Condition`。
- Produces:
  ```swift
  public func holds(_ c: Condition, _ on: Set<String>) -> Bool
  public func signalsIn(_ c: Condition) -> Set<String>
  public struct StateTable {
      public init(_ rows: [StateRow])
      /// The row in force at `now`, given the signals that hold; nil only when the table has no rows.
      public mutating func step(on: Set<String>, now: TimeInterval) -> StateRow?
  }
  ```

- [ ] **Step 1: 写失败的测试**

```swift
private let rows = [
    StateRow(state: "blocked", kind: "permission", when: .any([.signal("ask")]), hold: 0, release: 0),
    StateRow(state: "working", kind: nil, when: .any([.signal("stop"), .signal("busy")]), hold: 0.6, release: 2.0),
    StateRow(state: "done", kind: nil, when: .any([.signal("dot")]), hold: 0, release: 0),
    StateRow(state: "idle", kind: nil, when: nil, hold: 0, release: 0),
]

func testHoldDelaysEnteringAndReleaseDelaysLeaving() {
    var t = StateTable(rows)
    XCTAssertEqual(t.step(on: ["stop"], now: 0)?.state, "idle")
    XCTAssertEqual(t.step(on: ["stop"], now: 0.5)?.state, "idle")
    XCTAssertEqual(t.step(on: ["stop"], now: 0.6)?.state, "working")
    XCTAssertEqual(t.step(on: [], now: 1.0)?.state, "working")       // released at 1.0, holds until 3.0
    XCTAssertEqual(t.step(on: ["dot"], now: 2.9)?.state, "working")  // lower row cannot cut a release short
    XCTAssertEqual(t.step(on: ["dot"], now: 3.0)?.state, "done")
}

func testAFlickerNeverEnters() {
    var t = StateTable(rows)
    _ = t.step(on: ["stop"], now: 0)
    _ = t.step(on: [], now: 0.3)
    XCTAssertEqual(t.step(on: ["stop"], now: 0.5)?.state, "idle")    // hold restarted at 0.5
    XCTAssertEqual(t.step(on: ["stop"], now: 1.1)?.state, "working")
}

func testAHigherRowPreemptsAtOnce() {
    var t = StateTable(rows)
    _ = t.step(on: ["stop"], now: 0); _ = t.step(on: ["stop"], now: 1)
    XCTAssertEqual(t.step(on: ["stop", "ask"], now: 1.1)?.state, "blocked")
}

func testConditions() {
    XCTAssertTrue(holds(.all([.signal("a"), .not(.signal("b"))]), ["a"]))
    XCTAssertFalse(holds(.all([.signal("a"), .not(.signal("b"))]), ["a", "b"]))
    XCTAssertFalse(holds(.never, ["a"]))
    XCTAssertEqual(signalsIn(.any([.signal("a"), .not(.signal("b"))])), ["a", "b"])
    var empty = StateTable([])
    XCTAssertNil(empty.step(on: [], now: 0))
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter StateTableTests 2>&1 | tail -5`
Expected: 编译失败。

- [ ] **Step 3: 实现 `step`**

每行记“条件从什么时候起一直成立”（`trueSince`）和“从什么时候起一直不成立”（`falseSince`）。没有 `when` 的行永远成立。`ready(i)` = 条件成立且 `now - trueSince ≥ hold`；当前行 `stillOn` = 条件成立，或者 `now - falseSince < release`。结果是从上往下第一个满足“是当前行就看 `stillOn`，不是就看 `ready`”的行。表里没有兜底行、也没有行满足时，结果是 `StateRow(state: "idle", kind: nil, when: nil, hold: 0, release: 0)`；只有表是空的才返回 `nil`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter StateTableTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/RappCore/StateRules/StateTable.swift Tests/RappCoreTests/StateTableTests.swift
git commit -m "feat(rules): ordered state table with hold and release"
```

---

### Task 7: 引擎：变体、主题、自检退回、报告

**Files:**
- Create: `Sources/RappCore/StateRules/StateEngine.swift`
- Test: `Tests/RappCoreTests/StateEngineTests.swift`

**Interfaces:**
- Consumes: Task 3–6。
- Produces:
  ```swift
  public struct RuleEnv {
      public var appVersion: String?
      public var os: String               // "macos"
      public var locale: String           // Locale.preferredLanguages.first
      public var caps: Set<String>        // "pixels", "text"
      public var rereadVersion: () -> String?
      public init(appVersion: String?, os: String, locale: String, caps: Set<String>, rereadVersion: @escaping () -> String?)
  }
  public struct AppStateReport: Equatable {
      public var pack: String?, rev: Int?, state: String?, kind: String?
      public var by: [String], sure: Bool, counts: [String: Int]
      public var health: String          // "ok" | "switched" | "unfit" | "invalid"
      public var variants: [String], appVersion: String?, caps: [String], error: String?
      public func json() -> String       // 见上面的 Wire format；sortedKeys；超过 appStateLimit 时丢掉 counts 再试
      public static func invalid(_ error: RuleError, caps: [String], appVersion: String?) -> AppStateReport
  }
  public let healthRounds = 5
  public func compareVersions(_ a: String, _ b: String) -> Int   // 按点分的数逐段比，缺的段当 0，非数字段按字符串比
  public final class StateEngine {
      public init(rules: Data, env: RuleEnv, text: TextReader?) throws    // RuleError
      /// One round. `image`: the main window at one pixel per point, or nil when no new frame came.
      /// `visible`: the window is on screen (only visible rounds count for the self-check).
      /// Returns the report when it differs from the last one returned.
      public func tick(image: RuleImage?, visible: Bool, now: TimeInterval) -> AppStateReport?
      public private(set) var report: AppStateReport
  }
  ```

- [ ] **Step 1: 写失败的测试**

```swift
func testClaudeWorkingThenDone() throws {
    let e = try StateEngine(rules: Data(claudeDesktopResolvedJSON.utf8),   // 规格 §6.3 盖在 §6.1 上（测试常量）
                            env: env(version: "7.37095.0"), text: nil)
    XCTAssertEqual(e.tick(image: Canvas.chatWindow(button: .square), visible: true, now: 0)?.state, "idle")
    XCTAssertNil(e.tick(image: nil, visible: true, now: 0.5))
    let w = try XCTUnwrap(e.tick(image: nil, visible: true, now: 0.7))
    XCTAssertEqual(w.state, "working"); XCTAssertEqual(w.by, ["stop"]); XCTAssertFalse(w.sure)
    _ = e.tick(image: Canvas.chatWindow(button: .arrow, dots: [.green]), visible: true, now: 1)
    XCTAssertEqual(e.report.state, "working")                                // release 2 s
    let d = try XCTUnwrap(e.tick(image: nil, visible: true, now: 3.1))
    XCTAssertEqual(d.state, "done"); XCTAssertEqual(d.counts["rowDot"], 1)
    XCTAssertEqual(d.json().contains("\"inferred\":true"), true)
}

func testVariantsByVersionThemeLocaleWidthAndFound() throws {
    let rules = pack(variants: #"""
    [{"name":"old","when":{"appVersion":{"max":"1.9"}},"patch":{"signals":{"stop":{"detect":{"shape":"dot"}}}}},
     {"name":"new","when":{"appVersion":{"min":"2.0"}},"patch":{}},
     {"name":"dark","when":{"theme":"dark"},"patch":{}},
     {"name":"zh","when":{"locale":"zh"},"patch":{}},
     {"name":"narrow","when":{"windowWidth":{"max":500}},"patch":{}},
     {"name":"noSide","when":{"missing":["sidebar"]},"patch":{}},
     {"name":"mac","when":{"os":"windows"},"patch":{}},
     {"name":"odd","when":{"moon":"full"},"patch":{}}]
    """#)
    let e = try StateEngine(rules: rules, env: env(version: "2.3", locale: "zh-Hans"), text: nil)
    let r = try XCTUnwrap(e.tick(image: Canvas.chatWindow(width: 400, dark: true, sidebar: false), visible: true, now: 0))
    XCTAssertEqual(r.variants, ["new", "dark", "zh", "narrow", "noSide"])
    // No version: of the appVersion variants only the newest applies.
    let e2 = try StateEngine(rules: rules, env: env(version: nil), text: nil)
    XCTAssertEqual(e2.tick(image: Canvas.chatWindow(), visible: true, now: 0)?.variants, ["new"])
}

func testSelfCheckSwitchesVariantThenRereadsThenGivesUp() throws {
    // "new" moves `bottom` somewhere it is never found; "old" keeps it findable.
    let rules = pack(require: ["bottom"], variants: #"""
    [{"name":"old","when":{"appVersion":{"max":"1.9"}},"patch":{}},
     {"name":"new","when":{"appVersion":{"min":"2.0"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}}]
    """#)
    var rereads = 0
    let e = try StateEngine(rules: rules, env: env(version: "2.0", reread: { rereads += 1; return "2.0" }), text: nil)
    let img = Canvas.chatWindow()
    for i in 0..<4 { _ = e.tick(image: img, visible: true, now: Double(i)) }
    XCTAssertEqual(e.report.health, "ok")
    _ = e.tick(image: img, visible: true, now: 4)                              // 5th miss
    XCTAssertEqual(e.report.health, "switched"); XCTAssertEqual(e.report.variants, ["old"])
    XCTAssertNotNil(e.report.state)

    // A pack whose only variant never fits: reread once, then unfit (no state), recovers when found again.
    let bad = pack(require: ["bottom"], variants: #"[{"name":"v","when":{"appVersion":{"min":"1"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}}]"#)
    rereads = 0
    let e2 = try StateEngine(rules: bad, env: env(version: "2.0", reread: { rereads += 1; return "2.0" }), text: nil)
    for i in 0..<10 { _ = e2.tick(image: img, visible: true, now: Double(i)) }
    XCTAssertEqual(rereads, 1)
    XCTAssertEqual(e2.report.health, "unfit"); XCTAssertNil(e2.report.state)
    // Invisible rounds never count.
    let e3 = try StateEngine(rules: bad, env: env(version: "2.0"), text: nil)
    for i in 0..<20 { _ = e3.tick(image: img, visible: false, now: Double(i)) }
    XCTAssertEqual(e3.report.health, "ok")
}

func testSureOnlyForTestedSignals() throws {
    let rules = pack(signals: #"{"ask":{"in":"tail","detect":{"present":true},"status":"tested"}}"#,
                     states: #"[{"state":"blocked","kind":"permission","when":{"any":["ask"]}},{"state":"idle"}]"#)
    let e = try StateEngine(rules: rules, env: env(version: nil), text: nil)
    let r = try XCTUnwrap(e.tick(image: Canvas.chatWindow(), visible: true, now: 0))
    XCTAssertEqual(r.state, "blocked"); XCTAssertEqual(r.kind, "permission"); XCTAssertTrue(r.sure)
}

func testBadRulesAndReportLimits() {
    XCTAssertThrowsError(try StateEngine(rules: Data("{".utf8), env: env(version: nil), text: nil))
    let inv = AppStateReport.invalid(.badJSON, caps: ["pixels"], appVersion: nil)
    XCTAssertEqual(inv.health, "invalid"); XCTAssertNil(inv.state)
    XCTAssertLessThanOrEqual(inv.json().utf8.count, appStateLimit)
    XCTAssertEqual(compareVersions("7.37095.0", "7.4"), 1)
    XCTAssertEqual(compareVersions("2.0", "2"), 0)
    XCTAssertEqual(compareVersions("1.9", "1.10"), -1)
}
```
`pack(require:signals:states:variants:)` 和 `env(version:locale:reread:)` 是测试里的小工具：在 §6.1 的包上换掉对应的键。

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter StateEngineTests 2>&1 | tail -5`
Expected: 编译失败。

- [ ] **Step 3: 实现**

- 构造：`RulePack.parse` 后留着原始的 `RuleValue`；先 `RulePack.decode` 一次，失败就抛（被控端拿到错误后发 `invalid` 报告，Task 8）。
- 每轮有新图时定变体（没新图沿用上一轮的）：
  1. 主题：图上 8×8 格点（10% 到 90%）取亮度 `(0.299r+0.587g+0.114b)/255` 的中位数，`< 0.5` 是 `dark`。
  2. 条件：`appVersion {min,max}` 用 `compareVersions`，两端都含；`os` 相等；`theme` 相等；`locale` 是 `env.locale` 的前缀（`zh` 匹配 `zh-Hans`）；`windowWidth {min,max}` 用图宽；`found`/`missing` 是区域名数组。一个变体的 `when` 里有不认识的键就**不**盖。
  3. 版本：`env.appVersion` 为 `nil` 时，带 `appVersion` 的变体里只取“最新”的一个（各自 `max`，没有 `max` 用 `min`，用 `compareVersions` 比）；自检强制了某个版本变体时，带 `appVersion` 的变体里只取它。
  4. 两遍：先盖不含 `found`/`missing` 的变体，解区域；再加上 `found`/`missing` 成立的变体；第二遍多盖了才重解。按书写顺序盖（`RuleValue.merged`）。
  5. 同一组变体名只 `decode` 一次（按名字串做缓存）；变体变了 `SignalEvaluator.reset()`，状态表重建。
- 自检（规格 §7）：只数 `visible && image != nil` 的轮。`require` 里有区域找不到，`misses += 1`，否则清零。`misses == healthRounds` 时按顺序走：(a) 带 `appVersion` 的变体里还没试过的，按书写顺序强制下一个，`health = "switched"`，清零；(b) 都试过了且还没重读：调 `env.rereadVersion()`，版本变了就换上、清掉强制和“试过”，清零；(c) 否则 `health = "unfit"`，`state = nil`，不再走 (a)(b)。`unfit` 时 `require` 连续 `healthRounds` 轮都找到就回到 `switched`（有强制）或 `ok`。
- 求值：`SignalEvaluator.evaluate` → 成立的标志名集合 → `StateTable.step`。`by` = 选中那一行 `signalsIn(when)` 里此刻成立的，排序。`sure` = `by` 不空且每个都是 `.tested`。`counts` = 所有 `count` 标志里 `count != nil` 的（名字排序取前 32 个）。
- 报告和上一份返回的不一样才返回。`json()` 键排序、`inferred` 恒为 `true`、`nil` 写成 JSON `null`；`error` 只在 `invalid` 时写。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter 'StateEngineTests|StateTableTests|RuleDetectTests|RuleRegionTests|RulePackTests' 2>&1 | tail -5`
Expected: 0 failures。

- [ ] **Step 5: 性能检查（规格优先性能）**

加 `testTickCostOnA1600x1000Window`：`Canvas.chatWindow(width: 1600, height: 1000)`，跑 20 轮新图，`measure` 或手动计时，断言平均每轮 < 15 ms（release 编译下跑：`swift test -c release --filter StateEngineTests/testTickCost`）。超了先看 `blob` 的连通块和 `edge` 的扫描有没有对整张图做。

- [ ] **Step 6: Commit**

```bash
git add Sources/RappCore/StateRules/StateEngine.swift Tests/RappCoreTests/StateEngineTests.swift Tests/RappCoreTests/RuleCanvas.swift
git commit -m "feat(rules): state engine — variants, theme, self-check fallback and reports"
```

---

### Task 8: 被控端接上引擎（R2、R4 的被控端部分）

**Files:**
- Create: `Sources/rapp-host/AppStateWatcher.swift`
- Modify: `Sources/rapp-host/Server.swift`（`Session`：`stateRules` 存下或交给 watcher；`captureReady` 建 watcher；`frameArrived` 喂帧；`tableChanged` 给主窗口；`end` 停掉）
- Test: `Tests/RappCoreTests/StateEngineTests.swift` 不动；被控端这层靠 Step 4 的回环实测

**Interfaces:**
- Consumes: Task 1 的 `Message.stateRules`/`.appState`，Task 7 的 `StateEngine`、`RuleEnv`、`AppStateReport`，Task 4 的 `RuleImage.sample`。
- Produces:
  ```swift
  final class AppStateWatcher {
      init(app: NSRunningApplication, text: TextReader?, send: @escaping (Message) -> Void, log: @escaping (String) -> Void)
      func setRules(_ json: String)                 // "" stops; bad rules send one invalid report
      func setWindow(_ rect: CanvasRect?)           // the app's largest normal window, canvas points
      func offer(_ buffer: CVPixelBuffer, region: CanvasRect)   // capture queue; cheap when idle
      func stop()
  }
  func appVersion(bundleURL: URL?) -> String?       // Contents/Info.plist, read fresh each call
  ```

- [ ] **Step 1: 不写单元测试**

被控端这层依赖 ScreenCaptureKit 和运行中的 app，`appVersion` 只有十几行；都在 Step 4 用真 app 实测。

- [ ] **Step 2: 实现 `AppStateWatcher`**

- 自己一条队列 `DispatchQueue(label: "rapp.state", qos: .utility)`，一个 0.5 秒的定时器；`setRules("")` 或没有规则时定时器停着，`offer` 先看一个加锁的 `active` 标志，没规则立刻返回。
- `offer`（采集队列）：离上次取图不到 0.5 秒就返回；把主窗口和帧区域求交，换成缓冲里的像素（`scale = 缓冲宽 / region.w`），调 `RuleImage.sample` 拿 1 点 1 像素的图，放进 `pending`（加锁，只留最新一张）。
- 定时器：取走 `pending`，`engine.tick(image:visible:now:)`；`visible = 主窗口不为 nil`；有新报告就 `send(.appState(report.json()))`。
- `setRules`：在自己的队列上建 `StateEngine(rules:env:text:)`；`env.appVersion = appVersion(bundleURL: app.bundleURL)`，`rereadVersion` 也调它；`os = "macos"`；`locale = Locale.preferredLanguages.first ?? "en"`；`caps = ["pixels"]`，`text != nil` 再加 `"text"`。抛错就发一次 `AppStateReport.invalid(...)`，`log("state rules: invalid (\(error))")`。成功 `log("state rules: \(pack) rev \(rev), app \(version ?? "-")")`。**不记**报告里的 `by`、`counts` 以外的东西，识别出的文字永远不记。
- `appVersion`：`NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))`（不用 `Bundle`，它会缓存），取 `CFBundleShortVersionString`，没有取 `CFBundleVersion`。
- `Session` 里：`case let .stateRules(json)`（不过 `admit`，它不是输入）：桌面会话直接忽略；watcher 还没建（capture 没 ready）就存进 `pendingRules`；建好时先用 `pendingRules`。`captureReady` 里建 watcher（`text` 先传 `nil`，Task 9 换成 Vision）。`frameArrived` 里在 `quantizeAndSubmit` 之前调 `appState?.offer(pixelBuffer, region: region)`。`tableChanged` 里 `appState?.setWindow(next.filter { $0.kind == .normal }.max(by: 面积)?.rect)`。`end` 里 `stop()`。`send` 走 `Session.send`（要回到会话队列：`queue.async { self.send(m) }`）。

- [ ] **Step 3: 编译**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: 本机回环实测**

用 `rapp-host serve` 和 `rapp-client`（或 `scripts/e2e-local.py` 的做法）连本机的 ChatGPT（`com.openai.codex`）或 Claude（`com.anthropic.claudefordesktop`），发 `generic-chat` 和对应包解开后的 JSON（用 Task 10 之前，手拼一份：§6.1 盖 §6.3）。看 host 的日志里有 `state rules: claude-desktop rev 1, app 7.37095.0`；客户端收到 `appState`。发一个坏 JSON，收到 `health: invalid`。发 `""`，之后不再有 `appState`。记录结果写进 `tasks/todo.md` 的实机检查（Task 13）。这一步做不了（没装 app、权限不够）就写明“未实测”，不挡后面。

- [ ] **Step 5: Commit**

```bash
git add Sources/rapp-host/AppStateWatcher.swift Sources/rapp-host/Server.swift
git commit -m "feat(host): run the state rules on the main window and report inferred state"
```

---

### Task 9: 文字识别（R6）

**Files:**
- Create: `Sources/rapp-host/VisionText.swift`
- Modify: `Sources/rapp-host/Server.swift`（建 watcher 时传 `VisionText()`）

**Interfaces:**
- Consumes: Task 5 的 `TextReader`。
- Produces: `final class VisionText: TextReader`。

- [ ] **Step 1: 实现**

`lines(in:rect:)`：把 `rect` 那块 BGRA 拷成 `CGImage`（`CGDataProvider` + `CGImage(width:…bitsPerPixel: 32, bitmapInfo: byteOrder32Little | premultipliedFirst)`），`VNRecognizeTextRequest`，`recognitionLevel = .accurate`，`recognitionLanguages = ["zh-Hans", "en-US"]`，`usesLanguageCorrection = false`，同步 `VNImageRequestHandler(cgImage:).perform`；结果取每个 observation 的 `topCandidates(1).first?.string`。出错返回 `[]`。只在本机跑，不联网（Vision 本来就不联网）。

- [ ] **Step 2: 编译**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`（Vision 不另加单元测试，Step 3 实测）

- [ ] **Step 3: 实测**

Task 8 Step 4 的回环里，让 ChatGPT 显示一条有“Worked for …”的回复，确认 `done` 的 `by` 里出现 `workedFor`。另外用 `log stream` 确认 rapp-host 的日志里没有识别出的文字。做不了就写“未实测”。

- [ ] **Step 4: Commit**

```bash
git add Sources/rapp-host/VisionText.swift Sources/rapp-host/Server.swift
git commit -m "feat(host): on-device text recognition for text signals (R6)"
```

### Task 10: 操作端的规则库（R3：两层、继承、补丁、挑包）

**Files:**
- Create: `gui/assets/state_rules.json`（规格 §6.1–§6.4 的四包原文，外面包一层 `{"version":1,"packs":[…]}`）
- Create: `gui/lib/embed/state_rules.dart`（纯 Dart，不碰 Flutter）
- Modify: `gui/pubspec.yaml:28-31`（加 `assets/state_rules.json`）
- Modify: `gui/lib/data_dir.dart:66`（`prepareDataDir` 建 `shared/state_rules/`）、`gui/lib/paths.dart:60`（`DataDir.stateRulesDir` = `<sharedDir>/state_rules`）
- Modify: `gui/lib/main.dart:99-110`、`gui/lib/main_ios.dart:81-91`（和 app 配置一样读资源、建库，交给 `MainState`；relocate 时 `main_state.dart:246` 一起重读）
- Test: `gui/test/embed/state_rules_test.dart`、`gui/test/embed/builtin_state_rules_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum RulesLayer { builtin, mine }
  class SignalTally { final int tested, seen, reported, untested; }
  class ChosenRules {
    final String id; final int rev; final RulesLayer layer; final bool patched;
    final String json;        // resolved pack, extends and mine patches applied, variants kept; ≤ stateRulesLimit bytes
    final SignalTally tally;
  }
  const stateRulesLimit = 65536;
  Object? mergeRules(Object? base, Object? patch);           // 和 Swift RuleValue.merged 同一规则
  class StateRulesLibrary {
    static StateRulesLibrary parse(String? builtinJson, Map<String, String> mineFiles); // 文件名 → 内容
    static Future<StateRulesLibrary> load(DataDir data, String? builtinJson);
    /// [setting] 是 app 配置的 stateRules：null（按 ids 找）、'off'、或包名。
    ChosenRules? choose(String appId, String? setting);
    List<String> get errors;  // 读不了的“我的”文件：'<文件名>: <原因>'，只给页面显示
  }
  ```

- [ ] **Step 1: 写失败的测试**

```dart
test('merge: objects by key, null deletes, arrays replace', () {
  expect(mergeRules({'a': {'x': 1, 'y': 2}, 'b': [1, 2]}, {'a': {'y': null, 'z': 4}, 'b': [9]}),
      {'a': {'x': 1, 'z': 4}, 'b': [9]});
});

test('choose: by ids, off, by name, and nothing for an unknown app', () {
  final lib = StateRulesLibrary.parse(builtin, {});
  expect(lib.choose('com.openai.codex', null)!.id, 'chatgpt-desktop');
  expect(lib.choose('com.openai.codex', 'off'), isNull);
  expect(lib.choose('com.example.chat', null), isNull);            // generic-chat has empty ids
  expect(lib.choose('com.example.chat', 'generic-chat')!.id, 'generic-chat');
  expect(lib.choose('com.example.chat', 'nope'), isNull);
  expect(lib.choose('COM.OPENAI.CODEX', null)!.id, 'chatgpt-desktop');  // ids compare like app profiles
});

test('extends resolves; the child wins; variants stay', () {
  final c = lib.choose('com.anthropic.claudefordesktop', null)!;
  final m = jsonDecode(c.json) as Map;
  expect(m.containsKey('extends'), isFalse);
  expect(m['regions']['sidebar'], isNotNull);                      // from generic-chat
  expect(m['signals']['rowDot']['detect']['color'], 'green');      // claude's own
});

test('three layers stack: extends, then a variant (on the host), then a mine patch', () {
  final lib = StateRulesLibrary.parse(builtin, {
    'fix.json': '{"format":"1.0","patchOf":"chatgpt-desktop","rev":3,"patch":{"states":[{"state":"idle"}]}}'});
  final c = lib.choose('com.openai.codex', null)!;
  expect(c.layer, RulesLayer.mine); expect(c.patched, isTrue); expect(c.rev, 1);
  expect((jsonDecode(c.json) as Map)['states'], [{'state': 'idle'}]);
});

test('a newer rev wins whatever its layer; a tie goes to mine', () {
  final newer = jsonEncode({...packOf(builtin, 'chatgpt-desktop'), 'rev': 2, 'name': 'mine'});
  expect(StateRulesLibrary.parse(builtin, {'a.json': newer}).choose('com.openai.codex', null)!.layer, RulesLayer.mine);
  final older = jsonEncode({...packOf(builtin, 'chatgpt-desktop'), 'rev': 0});
  expect(StateRulesLibrary.parse(builtin, {'a.json': older}).choose('com.openai.codex', null)!.layer, RulesLayer.builtin);
});

test('bad mine files are listed and skipped; cycles and oversize packs are not chosen', () {
  final lib = StateRulesLibrary.parse(builtin, {
    'bad.json': '{', 'future.json': '{"format":"2.0","id":"x"}',
    'a.json': '{"format":"1.0","id":"a","ids":["com.a"],"extends":"b"}',
    'b.json': '{"format":"1.0","id":"b","extends":"a"}',
    'big.json': jsonEncode({'format': '1.0', 'id': 'big', 'ids': ['com.big'], 'pad': 'x' * stateRulesLimit})});
  expect(lib.errors, hasLength(2));
  expect(lib.choose('com.a', null), isNull);
  expect(lib.choose('com.big', null), isNull);
  expect(lib.choose('com.openai.codex', null), isNotNull);           // the rest still work
});

test('tally counts signal statuses of the resolved pack', () {
  final t = lib.choose('com.openai.codex', null)!.tally;
  expect(t.tested + t.seen + t.reported + t.untested, greaterThan(0));
});
```
`builtin_state_rules_test.dart`：读 `assets/state_rules.json`，四包的 `id` 依次是 `generic-chat`、`chatgpt-desktop`、`claude-desktop`、`antigravity-app`；每包 `format` 是 `1.0`；`chatgpt-desktop` 的 `ids` 是 `['com.openai.codex']`，`claude-desktop` 的是 `['com.anthropic.claudefordesktop']`，`antigravity-app` 的是 `['com.google.antigravity']`；每包解开后不超过 `stateRulesLimit`；每个 `tested` 的标志都在规格 §6.5 的“验过”名单里（写成测试里的常量）。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/state_rules_test.dart test/embed/builtin_state_rules_test.dart 2>&1 | tail -5`
Expected: 编译失败。

- [ ] **Step 3: 实现**

- 资源坏了：`parse` 当作没有内置包，不抛。
- “我的”文件：顶层是对象。有 `patchOf` 是补丁（要 `format` 大版本 1、`patch` 是对象）；否则是整包（要 `format` 大版本 1 和 `id`）。别的情况进 `errors`。`load` 读 `stateRulesDir` 下的 `*.json`（不递归，单个文件超过 1 MB 进 `errors` 不读）。
- 同一 `id`：`rev` 大的赢，一样大时“我的”赢（规格 §9“导入一包 rev 更大的就生效”）。
- `extends`：先把底包按同样规则选出来、解开，再 `mergeRules(底包, 本包去掉 extends)`；找不到底包或成环，这一包不能用。
- 补丁：“我的”里所有 `patchOf == id` 的按文件名顺序依次盖在解开后的包上；有补丁时 `layer = mine`、`patched = true`，`rev` 仍是底包的。
- `choose`：`setting == 'off'` → `null`；`setting` 是包名就用那一包（不看 `ids`）；否则在所有能用的包里找 `ids` 含 `appId` 的（不分大小写），多个时取 `rev` 大的，再一样取“我的”。解开后的 JSON（`jsonEncode`）超过 `stateRulesLimit` 字节 → `null`。
- `tally`：解开后的包里每个标志的 `status`（缺省 `untested`）各数一次。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/state_rules_test.dart test/embed/builtin_state_rules_test.dart 2>&1 | tail -3; git checkout pubspec.lock`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add gui/assets/state_rules.json gui/lib/embed/state_rules.dart gui/pubspec.yaml gui/lib/data_dir.dart gui/lib/paths.dart gui/lib/main.dart gui/lib/main_ios.dart gui/lib/ui/main_state.dart gui/test/embed
git commit -m "feat(gui): state rules library — built-in packs, mine dir, extends, patches, choice"
```

---

### Task 11: 操作端收发、灯、推断、需要你、状态队列（R3、R4 的操作端部分）

**Files:**
- Create: `gui/lib/embed/app_state.dart`
- Modify: `gui/lib/embed/session_port.dart`（`AppStateEvent`；`parseSessionEvent` 的 `'app_state'`；`SessionPort.stateRules(sid, json)` 发 `'state_rules'`）
- Modify: `gui/lib/embed/linux_session_port.dart:661-674`（`'state_rules'` 和 `dismiss_cover` 一样原样转给 `rapp-session`）
- Modify: `gui/lib/embed/remote_session.dart`（`appState` 字段；`apply(AppStateEvent)`；`linkDown()` 清掉）
- Modify: `gui/lib/ui/main_state.dart`（`ReadyEvent` 时发规则；记每个 sid 用的 `ChosenRules`；`_entryOf`；`needs`；状态队列）
- Modify: `gui/lib/ui/lifecycle.dart:185`（`recordLamp`）、`gui/lib/ui/session_model.dart`（`SessionEntry.inferred`）、`gui/lib/ui/needs_you.dart:43-47,170-200`、`gui/lib/ui/session_row.dart:76-85`、`gui/lib/ui/overview.dart:458-471`、`gui/lib/ui/stream_menu.dart:542-573`
- Test: `gui/test/embed/app_state_test.dart`、`gui/test/embed/session_port_test.dart`、`gui/test/embed/remote_session_test.dart`、`gui/test/embed/linux_session_port_test.dart`、`gui/test/ui/main_state_test.dart`、`gui/test/ui/lamp_test.dart` 或 `lifecycle` 的测试、`gui/test/ui/overview_test.dart`

**Interfaces:**
- Consumes: Task 1/2 的通道名（命令 `state_rules` {sid, json}，事件 `app_state` {json}）；Task 7 的报告字段；Task 10 的 `StateRulesLibrary`、`ChosenRules`。
- Produces:
  ```dart
  class AppState {
    final String? state, kind, pack, appVersion, error;
    final int? rev;
    final List<String> by, variants;
    final bool sure;
    final String health;                 // ok | switched | unfit | invalid; unknown → 'ok'
    final Map<String, int> counts;
    static AppState? parse(String json); // bad JSON or not an object → null; unknown state word → state null
    TermPs? get ps;                      // state != null → TermPs(state, kind: kind), else null
    bool get stale;                      // health == 'unfit' || health == 'switched' || health == 'invalid'
  }
  class AppStateEvent extends SessionEvent { final String json; }
  // RemoteSession
  AppState? appState;                    // this link's latest; cleared on linkDown
  // SessionEntry
  final bool inferred;                   // ps came from an app's screen, not the program
  // MainState
  ChosenRules? rulesOf(Object sid);      // what was sent on this link
  enum NeedKind { session, device, terminal, app }
  ```

- [ ] **Step 1: 写失败的测试**

```dart
// app_state_test.dart
test('parse', () {
  final a = AppState.parse('{"state":"blocked","kind":"permission","by":["ask"],"sure":true,"health":"ok",'
      '"pack":"claude-desktop","rev":1,"variants":[],"counts":{"rowDot":1},"inferred":true}')!;
  expect(a.ps!.state, 'blocked'); expect(a.ps!.kind, 'permission'); expect(a.sure, isTrue);
  expect(AppState.parse('{"state":"sleeping"}')!.state, isNull);
  expect(AppState.parse('{"state":"sleeping"}')!.ps, isNull);
  expect(AppState.parse('nope'), isNull);
  expect(AppState.parse('[]'), isNull);
  expect(AppState.parse('{"health":"unfit"}')!.stale, isTrue);
});

// session_port_test.dart
test('app_state parses', () {
  expect(parseSessionEvent('app_state', {'sid': 3, 'json': '{}'}), isA<AppStateEvent>().having((e) => e.json, 'json', '{}'));
});

// main_state_test.dart（照现有 FakeSessionPort 的写法）
test('rules go out on every ready of an app session, not for terminals or the desktop', () async {
  // codex 会话 ready → port.calls 里有 ('state_rules', {sid, json: chatgpt-desktop 解开后的 JSON})
  // 重连后新 sid 再 ready → 又发一次
  // 文字终端、整个桌面的 ready → 不发
  // app 配置 stateRules: off → 不发，lamp 和现在一样
});

test('inferred state drives the lamp, the row word and the overview, marked 推断', () {
  // emit AppStateEvent working → entry.lamp == Lamp.active, entry.ps.state == 'working', entry.inferred
  // done → Lamp.idle；blocked（sure 或不 sure）→ Lamp.waiting
  // state null（unfit）→ 灯和没有规则时一样（rs.idle ? idle : active）
});

test('only a sure block is a need', () {
  // blocked, sure:false → needs 里没有 NeedKind.app
  // blocked, sure:true  → needs 里有一条 NeedKind.app，text '<appName> @ <设备名>：等确认'，target 是记录的 key
  // 再报 working → 那一条消失
});

test('inferred changes enter the status queue with inferred: true', () {
  // working → done：hintHistory.first.inferred == true，text 以 '：完成' 结尾
  // 同一状态再报一次（只是 counts 变了）不进队列
});

test('linkDown clears the inferred state', () { /* remote_session_test：apply(AppStateEvent) 后 linkDown() → appState == null */ });
```
`overview_test`：`SessionEntry(…, ps: TermPs('working'), inferred: true)` 的块里有 `在干活` 和 `推断`。`linux_session_port_test`：`invoke('state_rules', {'sid':…, 'json':'{}'})` 写出 `{"cmd":"state_rules","json":"{}"}`（照 `dismiss_cover` 那条测试）。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed test/ui/main_state_test.dart test/ui/overview_test.dart 2>&1 | tail -5`
Expected: 编译失败。

- [ ] **Step 3: 实现**

- 发规则：`MainState._onPortEvent` 里 `e is ReadyEvent`、走正常分支（不是 `_reroutes` 那条）、记录不是文字终端（`isTermApp`）也不是整个桌面（`isDesktopApp`）时：`setting = rs.profile?.stateRules`；`chosen = stateRules.choose(r.app, setting)`；有就 `portOf(sid)?.stateRules(sid, chosen.json)`，记进 `_rulesBySid[sid]`。会话关掉或换 sid 时删掉旧的。
- `recordLamp`：`Phase.live` 且 `rs.appState?.ps` 不为空时按 `programLamp`（working → active，blocked → waiting，其余 → idle）；否则维持现在的判断。还没出画面（`!rs.sawFrame`）时仍是 connecting。
- `_entryOf` / `_mapEntries`：app 会话的 `ps: rs.appState?.ps`、`inferred: rs.appState?.ps != null`。
- `SessionRow._status` 和 `overview._Block._program`：`entry.ps != null && entry.inferred` 时显示 `programWord(ps)`，后面跟一个 muted 的 `推断`（和 `hint_history.dart:134-136` 一样的样式和语义 `，推断`）。
- `needs`：加 `NeedKind.app`，条件 `r.phase == Phase.live && rs.appState?.state == 'blocked' && rs.appState!.sure`，文字 `'${r.appName} @ ${deviceName(r.id)}：${termAskWord(ps)}'`，`seq` 用和终端一样的稳定表（键 `app\n<record key>`）。`needs_you.dart` 的按钮灯：有 app 条目时按 waiting；行按钮 `看看`，`goToNeed` 对 `NeedKind.app` 走到这个会话（和点会话行一样）。
- 状态队列：`AppStateEvent` 应用后，`(state, kind)` 和上一次不同（`null` 不算一次变化，不进队列）就 `_queue(HintRecord('${r.appName} @ ${deviceName(r.id)}：${programWord(ps)}', _now(), device: r.id, app: r.app, title: r.appName, lamp: programLamp(ps), inferred: true))`。每个链接第一次报的状态不进队列（和终端“第一次看到的列表不算新闻”一样）。
- 会话菜单（`stream_menu.dart` 的 `_localGroups`，`app 配置…` 前面）：`rs.appState?.stale` 时加一条不能点的 `_Item('状态规则可能过期', enabled: false)`；`health == 'switched'` 时文字是 `状态规则自动换了变体`。不弹窗、不抢焦点。
- `SessionPort.stateRules`：`json` 的 UTF-8 字节超过 `stateRulesLimit` 就不发（Task 10 已经挡了，这里再挡一次，Linux 的 `rapp-session` 收到坏命令会断会话）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test 2>&1 | tail -3 && ~/development/flutter/bin/flutter analyze 2>&1 | tail -3; git checkout pubspec.lock`
Expected: `All tests passed!`；`No issues found!`

- [ ] **Step 5: Commit**

```bash
git add gui/lib gui/test
git commit -m "feat(gui): send state rules, show the inferred state (推断), sure blocks in 需要你"
```

---

### Task 12: app 配置的 `stateRules` 和配置页里的状态规则

**Files:**
- Modify: `gui/lib/embed/app_profile.dart`（`AppProfile.stateRules`：构造、`copy`、`toJson`（放在 `tested` 前面）、`fromJson`；`ResolvedProfile.stateRules`；`resolveProfile` 的 `pick`）
- Modify: `gui/lib/ui/app_profile_store.dart`（`setStateRules(appId, appName, String? v)`，照 `setRime` 的写法）
- Modify: `gui/lib/pages/app_profile_page.dart`（`_untouched` 加字段；`窗口规则` 前加一节 `状态规则`；新参数 `rules`）
- Modify: `gui/lib/ui/top_bar.dart:272`（当前会话的 `rulesOf(sid)` 和 `appState` 传给页面）、`gui/lib/pages/devices_tab.dart:350`、`gui/lib/ui/app_profiles_section.dart:26,61`（不传，页面只显示“会话没开”）
- Modify: `gui/assets/app_profiles.json` **不改**（内置配置不写 `stateRules`，按 `ids` 找）
- Test: `gui/test/embed/app_profile_test.dart`、`gui/test/ui/app_profile_store_test.dart`、`gui/test/ui/app_profile_page_test.dart`

**Interfaces:**
- Consumes: Task 10 的 `ChosenRules`、`SignalTally`、`StateRulesLibrary.errors`；Task 11 的 `AppState`。
- Produces:
  ```dart
  class RulesView { final ChosenRules? chosen; final AppState? state; final List<String> errors; }
  openAppProfilePage(context, store, appId, appName, {RulesView? rules});
  ```

- [ ] **Step 1: 写失败的测试**

```dart
test('stateRules round-trips and resolves mine over built-in', () {
  final p = AppProfile.fromJson({'name': 'X', 'ids': ['com.x'], 'stateRules': 'generic-chat'})!;
  expect(p.stateRules, 'generic-chat');
  expect(p.toJson().keys.toList(), ['name', 'ids', 'stateRules']);
  expect(AppProfile.fromJson({'name': 'X', 'ids': ['com.x'], 'stateRules': 3})!.stateRules, isNull);
});

testWidgets('the page shows which pack, its rev and layer, how tested, and its health', (t) async {
  // rules: RulesView(chosen: claude-desktop rev 1 builtin tally(tested 1, seen 2, untested 3), state: health 'ok')
  // → 文字里有 'claude-desktop'、'修订 1'、'内置'、'验过 1 · 见过 2 · 未验 3'、'正常'
  // health 'unfit' → 有 '状态规则可能过期'；'switched' → '自动换了变体'
  // rules == null → '会话没开，看不到用的是哪一包'
  // 选“关”后保存 → store.mineFor(appId).stateRules == 'off'；选“自动”→ null；填包名 → 包名
});
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/app_profile_test.dart test/ui/app_profile_store_test.dart test/ui/app_profile_page_test.dart 2>&1 | tail -5`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`状态规则` 一节（`_label(t, '状态规则')`，放在 `窗口规则` 之前，样式照输入点那几行 `:374-388`）：
1. 一行三选一：`自动`（`null`）、`关`（`'off'`）、`指定`（后面一个文字框填包名）。
2. 只读几行：`用的包：<id> · 修订 <rev> · <内置|我的>`（`patched` 时加 `（有补丁）`）；`验到：验过 n · 见过 n · 有人报过 n · 未验 n`；`情况：正常 | 自动换了变体 | 对不上 | 规则读不了`，后两种下面再一行 muted 的 `状态规则可能过期`；有 `appVersion` 时一行 `app 版本：…`。
3. `errors` 不空时一行 muted 的 `“我的”里有 n 个文件读不了`。
4. 都是安静的文字，不弹窗。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test 2>&1 | tail -3 && ~/development/flutter/bin/flutter analyze 2>&1 | tail -3; git checkout pubspec.lock`
Expected: `All tests passed!`；`No issues found!`

- [ ] **Step 5: 编 macOS GUI 和 iOS**

Run: `cd gui && ~/development/flutter/bin/flutter build macos --debug 2>&1 | tail -3; git checkout pubspec.lock`
Expected: `✓ Built build/macos/Build/Products/Debug/rapp.app`
Run: `scripts/build-ios.sh 2>&1 | tail -3`（或照 `scripts/check.sh` 的 `xcodebuild`）
Expected: 成功。

- [ ] **Step 6: Commit**

```bash
git add gui/lib gui/test
git commit -m "feat(gui): stateRules in app profiles; the profile page shows the pack, rev, verification and health"
```

---

### Task 13: 文档和实机检查

**Files:**
- Modify: 规格 §14 表里的七份文档（用 `git grep -l` 按标题找：app 配置设计、app 配置编写规范、沟通机制设计 §2.3、平台规格、配置规范总览、调研、产品决策和规格路线图），都在 `docs/` 下、**不在** `docs/archives/`
- Modify: `tasks/todo.md`（加“状态规则 实机检查”一节）
- Modify: 规格的状态行（第 3 稿 → 加“已实现 R1–R4、R6，见计划”）

- [ ] **Step 1: 改文档**

逐条照规格 §14 的表改，每份只加或改对应的几行，并指向规格。平台规格写清 v16 两条消息的类型号、方向、载荷、上限和报告字段（照本计划的 Wire format 一节）。配置规范总览写“我的”规则在 `<数据目录>/shared/state_rules/*.json`。调研那一句改成“被控端现在没有文字识别，R6 加上（Vision，本机）”。

- [ ] **Step 2: 实机检查清单（`tasks/todo.md`）**

1. ChatGPT 做完一轮：灯从在干活变成完成，行上有 `推断`。
2. Claude 桌面端：在干活时灰点、做完绿点，灯跟着变。
3. Claude 要你确认时：灯变“等你”；`ask` 没验过时**不**进“需要你”。
4. 关掉 `stateRules`（配置页选“关”）：重连后灯和以前一样。
5. 在“我的”里放一个只改一个数的补丁：配置页显示“我的（有补丁）”。
6. 放一个故意对不上的包：大约 5 轮后配置页和会话菜单出现“状态规则可能过期”，不弹窗。
7. 最小化 app 窗口一会儿：不会被判成对不上。
8. 被控端日志里没有识别出的文字；报告里没有标题。
9. 规则开着时 CPU：活动监视器里 rapp-host 比关掉规则时多不到 5%。
10. Linux 操作端连 macOS 被控端：灯一样会变（Linux 也发规则）。

- [ ] **Step 3: Commit**

```bash
git add docs tasks/todo.md
git commit -m "docs: state rules — platform messages, profile field, rules dir, real-machine checks"
```

