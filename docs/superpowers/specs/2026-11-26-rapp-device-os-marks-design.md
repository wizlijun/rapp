# 总览设备列的系统图标（设计）

日期：2026-11-26

## 为什么做

总览（全景）的设备墙里，每一列只有设备名和「● 在线」，看不出这台是 Mac、Windows、Omarchy 还是别的。
用户要在「在线」那一行加上对应的系统图标，风格跟现有状态灯一致；不知道系统的设备也要有一个图标。

## 目标

- 每一列设备名下面那一行（`overview.dart` `_Column` 里 `StatusLamp(col.lamp)` 所在的 Row）最前面加一个系统图标，顺序：`[系统图标] 6px [状态灯] 6px 在线 · 路径`。
- 覆盖：macOS、Windows、Omarchy、其他 Linux、iPad、iPhone、Android 手机、Android 平板、未知。
- 设备离线时图标还在（记住上一次听到的系统）。
- 旧版本设备（回复里没有系统字段）显示「未知」图标。

## 非目标

- 「正在被接入」卡片（`InboundGroup`）这次**不加**图标（用户决定，以后再说）；所以握手不改。
- 侧边栏设备页、顶栏、Dock 菜单等别处不加。
- 不显示系统版本号（如 macOS 15.2）。

## 反目标

- 不用彩色品牌 logo、不用位图/SVG 素材：要和几何状态灯放在一起不突兀，跟主题颜色走。
- 不因此提升协议版本、不让旧版本连不上。

## 用户已定的

1. **图标风格**：各系统的记号，简化为单色。
2. **苹果设备**：Mac 用苹果记号；iPad、iPhone 画平板/手机外形，屏幕里放苹果记号。Android 手机/平板用同样的外形，屏幕里放 Android 机器人头——这样苹果和安卓的手机、平板能分开。
3. **范围**：这次只做设备列。
4. **数据来源**：方案 A（下）。

## 方案

- **A. 连接层（hub）记住（选中）**：对方在 `list_apps` 回复里报 `os`；hub 存进 `hosts.json`（变了才写），在 `hosts` 事件里带出。离线也有图标；iOS 的 GUI 用同一个 hub，自动就有。代价是 Rust 改服务回复和 hub 存储两处。
- **B. GUI 自己记住**：字段一样走 `list_apps`，GUI 在偏好里另存「设备 → 系统」。Rust 少改一处，但 GUI 多一份要同步的存储，删了再加、换数据目录时容易对不上。
- **没考虑**：走中继的设备登记——要重发 VPS 镜像，和这件事不成比例。

用户选 A。

## 设计

### 1. 字段取值

一个字符串 `os`，取值：

| 值 | 图标 | 提示文字 |
|---|---|---|
| `macos` | 苹果 | macOS |
| `windows` | 四格窗 | Windows |
| `omarchy` | Omarchy 记号 | Omarchy |
| `linux` | 企鹅 | Linux |
| `ipados` | 平板外形 + 苹果 | iPad |
| `ios` | 手机外形 + 苹果 | iPhone |
| `android-tablet` | 平板外形 + 机器人头 | Android 平板 |
| `android` | 手机外形 + 机器人头 | Android 手机 |
| 缺失 / 其他任何值 | 未知 | 系统未知 |

GUI 和 hub 都要把不认识的值当成「未知」，不报错（以后加系统时旧 GUI 不坏）。

### 2. 服务端（`rust/service`）

- `peer.rs` `list_apps_reply` 加 `"os": <值>`，和 `version` 一样每次都带。
- 识别放在一个小函数里（如 `workers::os_name()` 或 `rapp_net` 里的共用函数），结果可以缓存（进程里只算一次）：
  - `cfg!(target_os = "macos")` → `macos`；`windows` → `windows`。
  - Linux：`/usr/share/omarchy/shell` 存在 → `omarchy`（`rust/host-linux/src/desktop/omarchy_lock.rs` 已用这个路径认 Omarchy，是系统路径，不管服务以谁的身份跑都看得到），否则 `linux`。
- 协议**不升版本**：只加字段。

### 3. 连接层（`rust/hub`）

- `hosts.rs` `Host` 加 `#[serde(default, skip_serializing_if = "Option::is_none")] os: Option<String>`。
- 加 `set_os(id, os) -> Result<bool>`，照 `set_fp` 的写法：主机还在且值变了才写盘，返回是否变了。
- `summary()` 的每一行在有 `os` 时带出 `"os"`。
- `lib.rs` 的 `"apps"` 命令：拿到回复后，回复里有非空字符串 `os` 就 `set_os`（写盘失败只记一条 warn 日志，不影响 apps 事件）；`apps_event` 也带出 `os`（和 `version` 同样规则），GUI 不用等下一次 `hosts` 事件就能更新。
- hub 原样存对方报的字符串，不做白名单（判断「认不认识」是 GUI 的事）。只限长度（如超过 32 字节就不存），免得坏数据把 `hosts.json` 撑大。

### 4. GUI（`gui/lib`）

- `hub_client.dart`：`HubHost` 加 `final String? os`；解析 `hosts` 事件时读 `h['os']`；`host_added` 时保留旧的 `os`（和 `lan`/`route` 一样）；收到 `apps` 事件且带 `os` 时，把对应 `HubHost` 换成带新 `os` 的（写在内存里，hub 已经存盘了）。
- 新增 `lib/ui/os_mark.dart`：
  - `enum DeviceOs { macos, windows, omarchy, linux, ipad, iphone, androidTablet, androidPhone, unknown }`，加 `DeviceOs parseOs(String?)` 和 `String osWord(DeviceOs)`（提示文字，见上表）。
  - `OsMark(DeviceOs os, {double size = 10})` 组件：用 `CustomPainter` 和 `Path` 自己画，不加依赖。颜色取 `RappTokens.of(context).muted`（和旁边的状态文字同色，离线不变色）。外面包一层 `Tooltip(message: osWord(os))`，读屏文字也用 `osWord`。Key 为 `os-mark-<id 或 local>`。
- `overview_model.dart`：`DeviceColumn` 加 `final DeviceOs os`。
  - 远端列：`parseOs(host.os)`；只有会话知道的设备（不在 hosts 里）→ `unknown`。
  - 本机列：由 GUI 自己判断，传进 `deviceColumns`（如新参数 `localOs`）：
    - macOS → `macos`；Windows → `windows`。
    - Linux → `/usr/share/omarchy/shell` 存在就是 `omarchy`，否则 `linux`（和服务端同一条规则）。启动时判断一次即可。
    - iOS → 原生通道新加一个方法（如 `IosPlugin` 的 `"idiom"`，返回 `UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"`）→ `ipad` / `iphone`。拿到之前先当 `unknown`。
    - Android → 用屏幕最短边 ≥ 600 判断平板/手机（现在没有 Android 客户端，先按这条规则写，能编过就行）。
- `overview.dart` `_Column`：在状态行最前面放 `OsMark(col.os)` + `SizedBox(width: 6)`；整列的读屏文字里加上系统名。

### 5. 图标画法（风格约束）

- 尺寸跟状态灯走：`OsMark` 和 `StatusLamp` 一样接 `size`（默认 10），画布 `size * 1.3` 见方（默认 13px），和旁边的灯一样大。线宽也按 `lamp.dart` 的写法随 `size` 缩放（`k = size / 10`，描边约 `1.6 * k`）。三套主题都只用单色。
- 系统记号用**实心剪影**（苹果、四格窗、Omarchy、企鹅），简化到 14px 还认得出：苹果是一个带咬口和叶子的外形；四格窗是 2×2 方块、留缝；Omarchy 参照它官方标志的轮廓简化；企鹅是头和身体的剪影，不画细节。
- 平板、手机用**描边圆角矩形**（线宽同上）：平板竖放、比例约 3:4；手机更窄更高，约 1:2。屏幕里居中放实心的小苹果或小机器人头（半圆头加两根触角，眼睛挖空），约占外形宽度的 55%。
- 未知：用离线灯那样的**点线圆环**，中间一个问号，和「离线」的视觉语言一致，又能看出这是图标不是状态。
- 不加动画（状态灯会转、会闪；系统图标始终静止）。

### 6. 测试

- Rust：`list_apps_reply` 带 `os`；`apps_event` 有 `os` 就带出、空串或缺失就不带；`Hosts::set_os` 只在变化时写盘、主机不在时返回 false；`summary` 带出 `os`；`Host` 读没有 `os` 的旧 `hosts.json` 不报错。
- 跑 `cargo test --workspace --no-fail-fast`（testkit 里有对回复字段的整体断言，加字段曾经碰坏过 6 条）。
- Dart：`hub_client` 解析 `hosts`/`apps` 事件里的 `os`，`host_added` 保留 `os`；`parseOs` 对所有取值、缺失和未知值的结果；`deviceColumns` 远端/本机/只有会话知道的设备三种情况；总览组件测试能找到 `os-mark-local` 和 `os-mark-<id>`，提示文字对。
- 写一个组件测试，把 9 个图标在三套主题下排开、放大渲染成 PNG，给用户看样子（golden 文件可选）。**不卡中间步骤**：一次做完，截图和分支一起交给用户；合进 main 之前由用户看图点头（照常的合并流程）。

### 7. 发布注意

- 只有对方升级到这个版本之后才会报 `os`，在那之前它的列都显示「未知」——这是预期行为。
- iOS 改了 `gui/ios/`，要编一次 iOS。

## 留给实现者

- 识别函数放在哪个 crate，服务端和 GUI 的 Omarchy 判断的具体写法。
- 每个图标的具体路径坐标（照第 5 节的约束来）。
- 本机 iOS 的 idiom 是在启动时拿，还是第一次画总览时拿。
- 只有会话知道的设备（不在 hosts 里）显示「未知」；设备降级到不报 `os` 的版本时，hub 里存的旧值保留。
- 图标测试用 golden 还是截图。
