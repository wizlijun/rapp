# rapp 多窗口（RAIL 式）· 协议 v4

日期：2026-11-11
范围：这一轮只改 macOS 的 host 和 client（`Sources/`）。Windows、Omarchy 上的 host/client 以后再升级；v4 允许"只有一个窗口"的 host（§2.6），升级量很小。
参照：RDP RemoteApp 的 RAIL 窗口协议（窗口表 + 弹出窗口跟着父窗口 + 客户端发 Activate/SysCommand/Move）。

---

## 0. 目标

### 0.1 你说的

- RAIL 的窗口协议"可以抄，尤其是弹出窗口的处理上，毕竟 gui app 不只是一个窗口"。
- 范围四类都要：菜单类弹出（右键菜单、弹出按钮、下拉列表、提示条）、附着型（sheet、popover）、独立窗口（提示框、偏好设置、检查器、第二个文档窗口）、A 的顶部菜单栏镜像到 B 的菜单栏。
- 这一轮只做 macOS；v4 要让单窗口 host 合法。
- 架构选"A 整个 app 一条流"。
- "你先做吧，错了再改"。

### 0.2 本文的假设（请核对）

- 仍是独占模式：动的是 A 上真实的鼠标和焦点。
- 只处理一块屏：会话开始时 app 最大的普通窗口所在的那块。别的屏上的窗口不显示。
- B 上每个 A 窗口一个 B 窗口；B 上挪窗口，A 上的窗口也跟着挪（这是对 §1 口头方案的修改，原来说"只在 B 本地挪"，理由见 §1.3）。
- 缩放改为整个 client 一个值（菜单里选），不再有 v3 那种"拖角只缩 B、拖边 A 跟随"的三种行为：多窗口时每个窗口各缩各的，弹出窗口就对不上父窗口了。
- v3 的 client 和 v4 的 host 互不兼容，反过来也一样（握手时报版本不一致）。Windows、Omarchy 上的 host/client 升到 v4 之前，和新 Mac 端连不上。

### 0.3 用语

| 词 | 含义 |
|---|---|
| 画布 | A 那块屏，原点在左上角，单位是 A 的点（point），y 向下 |
| 区域 | 这一帧画面覆盖的画布矩形 |
| 窗口表 | host 发给 client 的 app 所有窗口的列表，从前到后排 |
| 有框窗口 | 种类是 normal、dialog、floating 的窗口：B 给它配自己的标题栏 |
| 弹出窗口 | 种类是 sheet、popover、menu、tooltip 的窗口：B 上是无边框面板，挂在父窗口上 |

---

## 1. 整体结构

### 1.1 一条流

- host 用 `SCContentFilter(display:including:exceptingWindows:)`，抓这块屏上目标 app 的所有窗口，菜单、提示条、sheet 也是这个 app 的窗口，一并在画面里。
- 抓的区域（`sourceRect`）是窗口表里所有窗口的并集，裁到屏内，向外取整到 8 点的倍数。区域变了就 `updateConfiguration`，不重启流，编码器重置（下一帧是全帧）。
- 每帧带上它的区域。B 按窗口表从这一帧里把每个窗口的那块裁出来，贴到对应的 B 窗口里。
- 瓦片编码、模式、清晰度、帧率全都不变。

### 1.2 窗口表

- host 每秒查 10 次 A 的窗口，窗口表有变化就整张重发（RAIL 是增量，这里窗口少，整张发更简单）。
- 每项：ID、父窗口 ID、种类、画布上的矩形、标题、A 标题行高度、可否改大小、是否是焦点窗口。顺序就是 A 上的前后顺序。

### 1.3 B 上的窗口跟 A 一一对应

- A 一个窗口，B 一个窗口。有框窗口在 B 上有 B 的标题栏，A 的标题行裁掉不显示（v3 的做法）。
- 一条流的代价是：A 上两个窗口叠在一起时，被盖住的那块在画面里就是上面那个窗口的像素。所以 B 和 A 的相对位置必须一致：B 上挪一个窗口，就让 A 上的那个窗口也挪到对应位置（RAIL 的 ClientWindowMove 也是这样）。前后顺序同理：B 上点一个窗口，A 上也把它提到前面。
- 弹出窗口不靠全局换算定位，而是挂在父窗口上：位置 = 父窗口在 B 上的内容区左上角 + 缩放 × （弹出窗口在 A 上相对父窗口内容区的偏移）。A 拒绝挪窗口时，菜单也不会飘走。

### 1.4 菜单栏

- host 用辅助功能（AX）读 app 的菜单栏（跳过苹果菜单），整棵树发给 B。
- B 把它接在自己的应用菜单后面。B 上选了某项，就把这一项的路径发回去，host 用 AX 按下它。
- 镜像的菜单项不设快捷键（只显示），⌘ 组合键照旧当按键发给 A，由 A 自己的菜单处理。

---

## 2. 协议 v4

线上格式不变：1 字节类型、4 字节小端长度、负载；字符串是 u16 长度 + UTF-8。坐标一律 f32，单位是点；不是有限数就当坏数据。

### 2.1 消息表

| 类型 | 名字 | 方向 | 负载 | 和 v3 比 |
|---|---|---|---|---|
| 1 | hello | B→A | version u8 = 4，token，bundleID，mode u8，fps u8，density f32 | 版本号变了 |
| 2 | ready | A→B | 应用名，画布宽 u16，画布高 u16 | 原来是窗口标题和窗口大小 |
| 3 | error | A→B | 文本 | 同 |
| 4 | frame | A→B | mode u8，区域 x、y、w、h（4×f32），像素宽 u16，像素高 u16，isFull u8，瓦片数据 | 加了区域 |
| 5 | text | B→A | UTF-8 | 同 |
| 6 | key | B→A | keyCode u16，modifiers u64，down u8 | 同 |
| 7 | mouse | B→A | kind u8，button u8，窗口 ID u32，x f32，y f32，clickCount u8 | 加了窗口 ID；x、y 从 0…1 改成相对该窗口左上角的点；kind 加 move = 3 |
| 8 | scroll | B→A | 窗口 ID u32，x，y，dx，dy | 加了窗口 ID，坐标同 mouse |
| 9 | resize | B→A | 窗口 ID u32，内容宽 u16，内容高 u16 | 加了窗口 ID |
| 10 | — | | | v3 的 title，v4 不用（标题在窗口表里），收到算未知类型 |
| 11 | setStream | B→A | mode，fps，density | 同 |
| 12 | — | | | v3 的 size，v4 不用（大小在窗口表里） |
| 13 | windows | A→B | 个数 u16，每项见 §2.2 | 新 |
| 14 | focus | B→A | 窗口 ID u32 | 新，RAIL Activate |
| 15 | close | B→A | 窗口 ID u32 | 新，RAIL SysCommand SC_CLOSE |
| 16 | move | B→A | 窗口 ID u32，x f32，y f32（窗口左上角，画布坐标） | 新，RAIL WindowMove |
| 17 | menuBar | A→B | 顶层项个数 u16，每项见 §2.3 | 新 |
| 18 | menuPick | B→A | 层数 u8（1…8），每层下标 u16 | 新 |

### 2.2 窗口表的一项

```
id u32           A 的 CGWindowID，非 0
parent u32       父窗口 ID；0 表示没有。有框窗口为 0
kind u8          0 normal，1 dialog，2 floating，3 sheet，4 popover，5 menu，6 tooltip
flags u8         bit0 可改大小，bit1 焦点窗口；其他位必须为 0
x, y, w, h f32   画布上的矩形（整个窗口，含 A 的标题行）；w、h > 0
titleBar f32     A 标题行高度，0 ≤ titleBar < h；弹出窗口为 0
title string     最多 200 个字符（v3 的 windowTitle 规则）
```

- 最多 256 项，ID 不能重复，parent 必须是表里另一项的 ID 或 0，否则当坏数据。
- 顺序：从前到后。

### 2.3 菜单项

```
title string
flags u8          bit0 可用，bit1 打勾，bit2 分隔线；其他位必须为 0
key string        快捷键字符（AXMenuItemCmdChar），没有为空
modifiers u8      bit0 shift，bit1 control，bit2 option，bit3 command；其他位必须为 0
count u16         子项个数，后面紧跟子项
```

- 最多 6 层，总共最多 5000 项，否则当坏数据。
- 路径的第一层下标是顶层菜单的下标（苹果菜单不算，app 菜单是 0）。

### 2.4 握手与结束

- 和 v3 一样：hello → ready，然后 windows、menuBar、frame 陆续到。版本不是 4 的 hello 回 `protocol version mismatch` 后断开（v3 的现有逻辑）。
- 会话结束：app 退出（`<app> quit`）、抓屏停了、连接断了、host 踢人。窗口全关了不结束：用菜单栏还能新建窗口。

### 2.5 对坏输入的处理

- B 发来的窗口 ID 不在当前窗口表里：丢掉这条，不断开（窗口刚关掉时很常见）。
- menuPick 的路径对不上（菜单刚变过）：丢掉，记一行日志。

### 2.6 单窗口 host

只有一个窗口的 host 也合法，最少要做：

- 窗口表永远一项，kind normal，titleBar 0，区域就是这个窗口；
- 不发 menuBar；
- 收到 focus、close、move、menuPick 可以不理。

B 上挪窗口而 A 不跟，B 不会把窗口拽回去：B 只在 A 那边的矩形变了时才重新摆窗口（§4.2）。

---

## 3. host（macOS）

### 3.1 开始会话

1. 找 app、找窗口、10 秒超时：照 v3 的 `WindowCapture.find`。
2. 最大的普通窗口所在的屏就是画布（按窗口中心点判断）。
3. 过滤器：这块屏，包含目标 app（和 §3.6 的存取面板服务）。
4. 发 `ready(应用名, 屏宽, 屏高)`，然后开始查窗口、读菜单栏、抓屏。

### 3.2 查窗口（每秒 10 次）

- 用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`：属于目标 app 的 pid（和 §3.6）、和画布有交集、alpha > 0、宽高都至少 4 点、不在菜单栏层或状态栏层。
- 种类：新出现的窗口按"窗口层级 + AX role/subrole"分一次类并缓存（§3.3），之后只更新矩形。
- 标题、焦点：标题照 v3 每秒用 AX 读一次；焦点窗口是 app 的 `AXFocusedWindow`。
- 有框窗口的 A 标题行高度照 v3 用关闭按钮量（全屏时为 0）。
- 父窗口（纯函数，§5）：弹出窗口的父窗口，是和它重叠面积最大的有框窗口；都不重叠就取最前面的有框窗口；一个有框窗口都没有就是 0。
- 和上次发的不一样才发 `windows`。
- 区域 = 表里所有窗口的并集（纯函数，§5）。区域变了：`updateConfiguration`（`sourceRect` 用屏内坐标，像素宽高 = 区域 × min(density, 屏的像素密度)），编码器重置。表空了区域保持不变。
- 每帧的区域取它被抓下来时的配置。具体做法由 Task 1 的探查决定：优先用帧附带的 `SCStreamFrameInfo.screenRect`；不可靠就给每次配置编号，`updateConfiguration` 返回以后到的帧算新区域。

### 3.3 分类（纯函数，以 Task 1 探查结果为准）

| 窗口层级 | AX | 种类 |
|---|---|---|
| normal（0） | role AXSheet | sheet |
| normal | role AXPopover | popover |
| normal | subrole AXDialog、AXSystemDialog | dialog |
| normal | subrole AXFloatingWindow、AXSystemFloatingWindow | floating |
| normal | 其他、或 AX 里找不到 | normal |
| floating、utility | | floating |
| modalPanel | | dialog |
| popUpMenu | | menu |
| 更高（提示条等） | | tooltip |

层级数值用 `CGWindowLevelForKey` 取，不写死。

### 3.4 输入

- mouse、scroll：窗口 ID 必须在当前表里。A 上的点 = 屏原点 + 窗口左上角 + (x, y)，限制在屏内。
- 按下（down）之前做顶层检查：A 上这一点最上面的窗口不是目标 app 的，就先激活 app、AX raise 那个窗口（有框窗口才 raise），等 50 毫秒再查一次；还不是就丢掉这次按下，日志写 `click dropped: covered by <owner>`。拖动、松开、移动、滚动跟着前一个按下走，不查。
- move（kind 3）：只挪指针，B 每秒最多发 30 次，只在指针位于远程窗口上时发。菜单的悬停高亮、子菜单展开、提示条都靠它。
- text、key：照 v3（app 不在前台先激活）。
- focus：激活 app，AX raise 这个窗口，设 `AXMain`。
- close：按 AX 关闭按钮；没有就什么也不做。
- move（消息 16）：AX 设位置。
- resize：AX 设大小 = 内容大小 + 标题行，照 v3 限制在屏内、至少 100×100。

### 3.5 菜单栏

- 在后台队列读：开始时读一次；焦点窗口变了 0.5 秒后读；每次 menuPick 1 秒后读。和上次不一样才发。
- 每项一次 `AXUIElementCopyMultipleAttributeValues`（标题、可用、打勾、快捷键字符、修饰键、子菜单）。
- menuPick：按路径走同一棵 AX 树（同样跳过苹果菜单），对最后一项 `AXPress`。

### 3.6 存取面板

沙盒 app（如 TextEdit）的打开/存储面板可能由 `com.apple.appkit.xpc.openAndSavePanelService` 进程画。Task 1 确认归属；如果是它，目标 app 在前台时，把它的窗口也算进过滤器和窗口表（按 sheet 或 dialog 分类，父窗口同 §3.2）。

### 3.7 不再做的

v3 的"窗口关了就结束会话"、`title`、`size` 消息。

---

## 4. client（macOS）

### 4.1 B 上的窗口

- 有框窗口：带标题栏、可关闭、可最小化；可否改大小看 flags。内容区 = 画面 + 底下的输入条（v3 的 InputBar）。标题栏右边是流量标签。
  - 关闭按钮：发 `close(id)`，B 窗口自己不关，等 A 的窗口表里没了它再关。
  - 最小化：只在 B 上。
- 弹出窗口：无边框、不抢焦点的 NSPanel，层级 popUpMenu，作为父窗口的子窗口（`addChildWindow`），用户不能挪。没有输入条。
- 窗口表里没有有框窗口时，显示一个占位窗口：标题是应用名，正文"没有打开的窗口，可以用菜单栏新建"，带流量标签。关掉它就退出 client。

### 4.2 摆放与缩放

- 缩放：整个 client 一个值，应用菜单里选 50%、75%、100%、125%、150%、200%，默认 100%。
- 全局换算：B 点 = 原点 + 缩放 × 画布点。原点在第一张窗口表到达时定：让焦点窗口（没有就取第一个有框窗口）的内容区居中在 B 的主屏上。
- 有框窗口：新出现时，或 A 那边它的矩形变了时，按全局换算摆到 B 上（内容区对齐，B 标题栏在上面，输入条在下面）。别的时候不动它。
- 弹出窗口：每次窗口表到达都按 §1.3 相对父窗口重新摆。父窗口在 B 上被挪动时，子窗口跟着走（AppKit 子窗口的行为）。
- 改缩放：保持焦点窗口内容区左上角不动，重算原点，所有窗口重摆。
- 清晰度照 v3：`captureDensity(zoom, backingScale, choice)`，变了就发 setStream。

### 4.3 B 发给 A 的

- B 上用户挪了有框窗口（不是程序摆的）：发 `move(id, x, y)`，x、y = (B 内容区左上角 − 原点) / 缩放 − (0, titleBar)。
- B 上改了大小：松手后（不是拖动的改变则 0.3 秒防抖）发 `resize(id, 内容宽 / 缩放, 内容高 / 缩放)`；左上角也变了就再发 move。
- B 上用户让一个有框窗口成为焦点：发 `focus(id)`。A 报来的焦点窗口变了而 client 在前台：把对应 B 窗口设为焦点，这时不回发 focus。
- 前后顺序：窗口表里有框窗口的顺序变了，B 按它重排。
- 鼠标：画面上的点 / 缩放 + (0, titleBar) 就是窗口内坐标（有框窗口），弹出窗口没有 titleBar。按下、拖动、松开的规则照 v3（按下必须在画面上，之后的拖动和松开一定跟着发）。

### 4.4 画面

- 解码照 v3。每帧到了，对每个窗口算它在这帧像素里的那块（纯函数，§5）：窗口矩形去掉 A 标题行，和区域求交，减区域原点，乘像素密度（帧像素宽 / 区域宽）。用 `CGImage.cropping(to:)` 贴到那个窗口的画面里。不在区域里的窗口先空着，等下一帧。

### 4.5 菜单栏与流量

- B 的菜单栏 = client 的应用菜单 + 镜像来的 A 的菜单。
- 应用菜单：退出（⌘Q）、缩放、v3 右键菜单里的那套（两个预设、模式、清晰度、帧率）。流量标签的右键菜单还是同一套。
- v3 的编辑菜单（剪切、复制、粘贴、全选、撤销）改成隐藏但快捷键仍有效的项，给输入条用。
- 镜像的菜单项：不可用的灰掉，打勾的打勾，快捷键只作为标题右侧的文字显示，不设 keyEquivalent。选中就发 menuPick。
- ⌘ 键照 v3：⌘Q 退出 client；输入条空着时其他 ⌘ 组合键发给 A。

### 4.6 JSON 输出

`ready` 事件的 width、height 是画布大小，title 是应用名；多一个事件 `{"event":"windows","count":N}`，窗口表每次变化时发。hub 不解析这些字段。

---

## 5. 纯函数（RappCore，单元测试）

| 函数 | 用途 |
|---|---|
| `classifyWindow(level:role:subrole:) -> WindowKind` | §3.3 |
| `assignParents([WindowInfo]) -> [WindowInfo]` | §3.2 父窗口 |
| `captureRegion(windows:display:) -> CGRect?` | §1.1 并集、裁到屏内、取整到 8 点 |
| `cropRect(window:region:pixelSize:) -> CGRect?` | §4.4 |
| `WindowPlacement`（原点、缩放；画布↔B 互换；弹出窗口相对父窗口） | §4.2 |
| `menuItem(at path:in:)` | §3.5、§4.5 路径查找 |
| 消息编解码 | §2 的每条消息、每条上限 |

---

## 6. 测试与验收

- 单元测试：§5 每个函数；§2 每条消息编码再解码相等；上限和坏数据（窗口超过 256、ID 重复、parent 不在表里、flags 有多余位、菜单超过 6 层或 5000 项、路径 0 层或 9 层、kind 未知）各一条；v3 的 hello 报版本不一致。
- Task 1 探查（一次性，结果写进本文附录）：在 TextEdit 新建的空文档上，用 AX 打开右键菜单（`AXShowMenu`）、格式菜单、"存储…"面板、字体面板、关于窗口，再把指针停在工具栏按钮上等提示条；每一种记下 CGWindowList 的层级、alpha、归属进程，AX 的 role/subrole，并确认按屏 + app 过滤的流里看得到它；确认 `SCStreamFrameInfo.screenRect` 在改 `sourceRect` 之后是否跟着变；量 Safari 读整个菜单栏要多久。点击前做顶层检查，不碰其他 app 的窗口；文档不存，最后关掉时选不存储。
- e2e：`scripts/e2e-local.py` 三轮照旧通过，并断言 client 至少报过一次 `windows` 且 count ≥ 1。
- 实机验收（截图）：TextEdit 的右键菜单、格式菜单、存储 sheet、字体面板在 B 上各自是独立的 B 窗口且位置对；从 B 的菜单栏选"新建"在 A 上开出第二个窗口，B 上也出现；B 上挪窗口，A 跟着挪。

---

## 7. 不做的（这一轮）

- 别的屏上的窗口、调度中心空间、A 上的全屏窗口切换。
- 每个窗口单独一条流（叠窗问题靠位置同步解决）。
- 拖放、剪贴板。
- 增量窗口表（RAIL 的逐项更新）。
- Windows、Omarchy 的 host/client（以后按 §2.6 升级）。

## 附录：Task 1 探查结果

（实现时填）
