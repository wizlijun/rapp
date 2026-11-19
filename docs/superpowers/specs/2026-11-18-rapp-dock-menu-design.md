# Dock 右键菜单：切会话 + 打开常用（小改动设计）

日期：2026-11-18。对象：macOS `gui/macos/Runner/AppDelegate.swift`、`gui/lib/tray_menu.dart`、`gui/lib/main.dart` 的 `_Shell`。

## 为什么

用户的话：在 macOS Dock 上右键 rapp 图标，**能在那里切换现在所有的会话窗口**，并且**能快捷地选择启动某些主机的其他应用**。不用先把主窗口叫出来、再去会话列表或全景里找。

## 目标

1. Dock 右键菜单按主机分组列出所有打开的会话，点一项 = 切到它（和托盘点会话一样）。
2. 同一菜单里列「常用」里还没打开的应用，按主机分组，点一项 = 在那台主机上打开它。
3. 托盘菜单（菜单栏，含 Linux）同步加上「常用」；Dock 和托盘共用一份菜单内容，改一处两边都变。
4. 点一个已分离的会话，只把它的独立窗口提到最前面（Dock 和托盘都这样）。
5. Dock 的「退出」和 Cmd+Q 在还有远程窗口时先问，和托盘「退出」一样。
6. 分离的会话在 Dock 菜单里只出现一次（在会话段）。

## 非目标

- 不列每台主机的全部应用（用户选了「只列常用」；没收藏的应用仍去主窗口打开）。
- 不改「常用」的增删方式（仍在主窗口里收藏/取消）。
- 不动 Dock 菜单的系统项（选项、显示所有窗口、隐藏、退出）本身；退出只是加一道确认。
- 关机、重启、注销时不拦，照常退出。

## 反目标

- 菜单内容和 rapp 里的真实状态对不上（列着已经关掉的会话，或漏了刚打开的）。
- Dock 和托盘点同一项，结果不一样。
- 点一个离线主机的常用，什么反应都没有。

## 考虑过的做法

| | 做法 | 取舍 |
|---|---|---|
| **A（选中）** | Dart 在会话/常用/在线状态变化时把菜单模型推给原生层缓存；`applicationDockMenu` 从缓存现建 `NSMenu`；点击把 key 经 channel 回传 Dart，走托盘同一个点击处理 | 唯一可行：`applicationDockMenu` 是同步回调，不能当场异步问 Dart |
| B | 打开菜单时原生层同步问 Dart | 做不到，method channel 只有异步 |
| C | 用 `tray_manager` 之类插件 | 它不支持 Dock 菜单 |

用户的决定：
- 内容：在三种之间选了「只列常用」（另两种是「常用 + 每台主机全部应用子菜单」和「只用主机子菜单」）。
- 托盘：选「托盘也加」。
- 点分离会话：选「只提它的独立窗口」（弃「主窗口和独立窗口都提」「保持托盘现状：只显示主窗口」）。
- 退出确认：选「这次一起补」（弃「记进 todo 以后再说」）。
- 重复窗口：选「去掉系统列的」（弃「保留，接受重复」），代价是菜单栏「窗口」菜单的窗口列表里也看不到分离窗口。

## 设计

**菜单内容**（一份模型，`tray_menu.dart` 里从 `trayItems` 扩展而来）：

```
── 托盘 ──                    ── Dock ──
显示 rapp                     （无：点 Dock 图标本身就显示）
──────────
Mac mini                      Mac mini
    终端 — vim                    终端 — vim
    Safari（已断开）              Safari（已断开）
──────────                    ──────────
常用                          常用
Mac mini                      Mac mini
    Xcode                         Xcode
办公室 Linux（离线）           办公室 Linux（离线）
    终端                          终端          ← 置灰
──────────
退出                          （无：系统自带退出）
```

- 会话部分：和现在托盘完全一样（按主机分组、排序、「（已断开）」后缀、没有会话时一行置灰的「没有打开的会话」）。
- 常用部分：`state.idleFavorites`（已经打开的不再重复列，它们在会话部分里），按主机分组，组内保持收藏顺序；主机组之间的顺序和会话部分一致（按主机名排）。没有空闲常用时整段（含分隔线和「常用」标题）不出现。
- 离线主机（`state.deviceOffline(id)`）：主机标题加「（离线）」，它下面的常用项置灰不可点。
- 主机标题用 `state.deviceName(id)`，常用项用收藏时存下的 `name`。
- Dock 版本 = 同一模型去掉「显示 rapp」「退出」和它们旁边的分隔线。

**点击**：
- 会话项，未分离：同现在托盘——显示主窗口，`state.select(key)`。
- 会话项，已分离（`remote[sid].detached`）：不显示主窗口，`raiseDetached(sid)` 把它的独立窗口提到最前并激活 rapp。托盘同样改。
- 常用项：显示主窗口，`state.openOrSwitch(device, bundle, name)`（终端入口按这台主机的「打开方式」走，和主窗口里点常用一样）。
- 新的 key 前缀 `fav:`，形如 `fav:<device>/<bundle>`，和 `session:` 并列，解析函数与 `sessionKeyOf` 对称。

**原生层（macOS）**：
- `AppDelegate` 新开一个 `FlutterMethodChannel`（如 `rapp/dock`）：`setMenu(items)` 存下模型；`applicationDockMenu(_:)` 从存下的模型建 `NSMenu`（标题行 `isEnabled = false`，分隔线 `.separator()`）；点击时 `invokeMethod("click", key)`。
- 只有主 rapp 进程注册；`--cm`（连接管理器）不注册、不显示菜单。
- 推送去重和托盘一样：模型形状没变就不推。
- `DetachedWindow` 设 `isExcludedFromWindowsMenu = true`，系统不再把分离窗口列进 Dock 菜单顶部（也不进菜单栏「窗口」菜单）。主窗口不动。

**退出确认**（macOS 主进程；`--cm` 不管）：
- `AppDelegate.applicationShouldTerminate`：
  - 关机/重启/注销引起的（当前 Apple Event 的 quit reason 是 logout/shutdown/restart）→ `.terminateNow`；
  - Dart 已经确认过 → `.terminateNow`；
  - 否则 → `.terminateCancel`，并经 channel 通知 Dart「要退出」。
- Dart 收到后走托盘「退出」同一个 `_quit()`：没有远程窗口直接退，有就弹「退出 rapp？还有 N 个远程窗口……」。
- 必须保住现在 Cmd+Q 的一个副作用：`SessionPlugin` 在 `willTerminate` 时给 A 发按键释放（`releaseKeys`）。确认后的退出路径要么仍经过 `NSApp.terminate` 触发它，要么在 `exit(0)` 前显式做同样的事——实现定，但不能丢。

## 留给实现

- 菜单模型的 Dart 类型怎么定：沿用 `tray_manager` 的 `MenuItem` 再转成 channel 用的 map，或自定义一个小类型——实现定，但 Dock 和托盘必须从同一个函数出来。
- 测试：`gui/test/tray_menu_test.dart` 增加常用分组、离线置灰、无空闲常用不出现、Dock 版去掉显示/退出、`fav:` 解析用例；Swift 侧建菜单的逻辑尽量薄，能纯函数化就补一个 Swift 单测。
- Dart 侧「点会话」的分离/未分离分支，放在能单测的地方（不要只写在 `_Shell` 里）。
- 实机检查写进 `tasks/todo.md`：Dock 右键看到会话和常用；点会话切过去；点分离会话只提独立窗口；点常用在对应主机打开；离线主机置灰；托盘内容一致；分离窗口不在 Dock 顶部重复；有远程窗口时 Dock 退出 / Cmd+Q 先问、取消后不退；关机时不被拦。
