# 不锁屏（设计）

日期：2026-11-28。状态：用户已确认（2026-11-28）。已过一遍 builder check，标「（我的决定）」的是我替用户定的，用户可改。

## 1. 为什么做

很多开发任务（终端里的 claude / codex、长时间的构建和测试）跑在一台没人看着的电脑上。这台电脑一旦锁屏或睡着：

- rApp 自己的自动锁屏：最后一个远程 app 或桌面关掉 10 秒后锁屏（`rust/service/src/autolock.rs`）。只有那台电脑本机的「远程 app 都关闭后自动锁屏」开关能关它，别的设备够不着。
- 系统自己的空闲：rApp 只在有会话开着时让电脑别熄屏（`Sources/rapp-host/PowerHold.swift`，Linux 是 `systemd-inhibit`）。没人连着时，系统照常熄屏、进屏保、锁屏、睡眠。

锁上以后，再连进去要输密码；睡着了，任务就停了。用户要一个「不锁屏」：打开后，这台电脑就一直不锁，直到有人关掉。

## 2. 用户已定的

| # | 决定 | 内容 |
|---|---|---|
| N1 | 范围：**两样都挡** | 打开后 rApp 不再自动锁屏；同时让这台电脑一直亮着、不睡、不进系统锁屏，像一直有人在用。代价（常亮、耗电、旁边的人能直接用）用户接受。 |
| N2 | 位置：**每台电脑一个开关** | 总览里每台电脑那一栏（本机和连着的远端电脑都有），在「余力」行下面加一张「不锁屏」卡片。打开后一直不锁，直到有人关掉，重启后也保持。连着它的每台设备都看得到、都能开关。 |
| N3 | 做法：**A**，本轮只做 macOS 和 Linux | 开关记在那台电脑的 rApp 服务里；服务跳过自动锁屏，并挂一个常驻的保持唤醒进程。Windows 电脑本轮不显示这张卡片。 |
| D1 | Linux 先只做 Hyprland（我的决定） | 只靠 logind 的 idle 抑制，Hyprland 的 hypridle 认，X11 的屏保 / DPMS 大多不认；做不到就不显示卡片，免得「开着却锁了」。X11、其他 Wayland 桌面以后再加。 |

## 3. 目标、非目标、反目标

**目标**
- 每台跑 rApp 服务的 macOS、Linux 电脑都有「不锁屏」开关，存在服务配置里，重启服务、重启电脑后照旧。
- 开着时：自动锁屏不触发；电脑不熄屏、不进屏保、不空闲睡眠。
- 总览每台电脑一栏（本机栏和远端栏）、手机「设备」页每台设备，都显示这张卡片，能直接开关。
- 别的设备改了，所有看着的设备几秒内跟着变。

**非目标**
- Windows（留给 Windows session，后面单独做）。
- Linux 上 Hyprland 以外的桌面（D1）。
- 挡住手动锁屏（⌃⌘Q、触发角、MDM 屏保策略）。不检测「现在是不是锁着」，不加锁屏状态的轮询（我的决定）；卡片的话只说「不会自动锁屏」，不打包票。
- 合上笔记本盖子也不睡（系统不让 app 拦；卡片上写一句提醒）。
- 打开时帮你解锁已经锁上的电脑（解锁照旧走「桌面」里的解锁）。
- 定时关闭、只在某个终端跑着时不锁（用户选了「每台电脑一个开关」）。
- `rapp` 命令行开关（以后要再加）。

**反目标**（技术上做了也算失败）
- 开关显示「开」，电脑却照样锁了，而且没有任何提示。保持唤醒失败必须在卡片上说出来（§6）。
- 老版本的电脑上显示一张点了没用的卡片。不支持的电脑不显示（§5）。
- 没有这台电脑钥匙的设备也能改它。

## 4. 方案比较

- **A（选定）服务持有开关 + 常驻保持唤醒进程**：服务存配置、跳过自动锁屏，开着时挂一个子进程：macOS 是 `rapp-host stay-awake`（复用 `PowerHold`：显示器断言 + 每 30 秒报一次用户活动，屏保计时被清零，也就不会因屏保而锁），Linux 是 `systemd-inhibit --what=idle:sleep --mode=block … cat`（和 host-linux 会话时一样）。状态随「余力」快照发给各设备，改动走一个新的 Op，只认有钥匙的设备。复用现成的保持唤醒代码。注意：`PowerHold` 只在会话期间（一直有远程输入）实机用过，「没人连、没输入」时能不能挡住屏保，实机检查 1 要专门验。
- B 服务里直接调 IOKit：省一个子进程，但要在 Rust 里重写 `PowerHold`，Linux 还得再写一遍。
- C 服务跑系统的 `caffeinate`：最快，但 `caffeinate` 不会一直清零屏保计时，屏保带密码时照样锁，达不到 N1。

## 5. 数据：开关存哪、怎么传

**配置**：`rust/service/src/config.rs` 加 `no_lock: Option<bool>`，`no_lock()` 默认 `false`。

**本机 IPC**：
- `{"cmd":"set_no_lock","on":bool}`：改配置，回 `ok`（同 `set_auto_lock`，走 `update`）。
- `status` 回复里加 `no_lock`、`no_lock_held`（见下），GUI 的 `ServiceStatus` 读它们。

**状态怎么到别的设备**：放进「余力」快照。`load/serve.rs` 的 `reply` 和每一行 `line` 已经带 `term`（终端能不能用），照这个加：
- `no_lock`：开关的值。
- `no_lock_held`：开着时，保持唤醒进程现在是不是活着。
- 只有支持的服务带这两个键：macOS 一律带；Linux 只在服务所在的图形会话是 Hyprland 时带（D1，`HYPRLAND_INSTANCE_SIGNATURE` 或 `XDG_CURRENT_DESKTOP` 含 `Hyprland`；判断放一个函数里，以后加桌面只改这里）；Windows 不带。GUI 只在快照里**有** `no_lock` 键时显示卡片：老版本、Windows 的电脑都没有这个键，就不显示。
- hub 现成的 `watch_load` 每台在线设备一条流，GUI 的 `DeviceLoad` 读出来即可，不加新的轮询。本机栏读本机服务的 load（`ServiceMonitor.load`），一样有这两个键。

**远端改**：`rapp_net::msg::Op` 加
```
/// 「不锁屏」（no-lock spec §5）：带 `on` 就改，不带只问。只认有钥匙的设备，同 `SetService`。老设备回 "unknown op"。
NoLock { #[serde(default, skip_serializing_if = "Option::is_none")] on: Option<bool> },
```
- 被控端：`peer.rs` 转给新的处理函数（同 `SetService` 转给 `companion::serve`），准入规则用 `SetService` 那条（`companion.rs` 的 `admit(.., true)`），拒绝记 `no_lock_refused`；改成功记 `no_lock_set`，字段带来源设备（`By::Remote`）和 `on`。回 `{"ok":true,"no_lock":..,"no_lock_held":..}`。
- hub：`{"cmd":"no_lock","id":..,"on"?:bool}` 转成 `Op::NoLock` 发过去，回对方的回复（同 `services.rs` 转 `SetService`）。
- 本机 IPC 改也记 `no_lock_set`（来源是本机），这样访问日志里能看出是谁、从哪台设备开关的。`ipc.rs` 第 229 行那张「算事件」的表加上 `no_lock_set`、`no_lock_refused`。

## 6. 服务里的行为

新模块 `rust/service/src/no_lock.rs`，服务启动时 spawn，订阅 `state.changed`：

- **开着**：
  - `autolock.rs` 的两处 `auto_lock()` 判断改成「`auto_lock() && !no_lock()`」：开着时不起定时，已经起的定时到了也不锁。
  - 保持唤醒子进程没在跑就起一个：
    - macOS：`rapp-host stay-awake`，环境同 `workers::run_json`（`desktop_environment`），`kill_on_drop(true)`，stdin 用管道，服务退出、管道一断它就退出。
    - Linux：直接 `systemd-inhibit --what=idle:sleep --mode=block --who=rapp --why="不锁屏" cat`，stdin 用管道。
  - 子进程意外退出：记 `no_lock_hold_failed`（带退出码和 stderr 末尾一行），按 1 s、2 s、4 s…封顶 60 s 退避重起；退出期间 `no_lock_held = false`。
- **关了**：杀掉子进程（关 stdin，再 kill），`no_lock_held = false`。自动锁屏回到原来的规则，**关掉本身不触发锁屏**（我的决定）：原来的规则只在「会话数从大于 0 变成 0」时起定时，关掉时没有会话就不锁，下一次远程会话结束时照常 10 秒后锁；系统自己的熄屏、锁屏从此照常。这样人坐在电脑前关掉，屏幕不会 10 秒后突然锁上。
- 每次开、关、子进程起落都 `state.changed` 通知一下，让 `watch_load` 的下一行和 `status` 带上新值。如果 `watch_load` 只在采样时出行（每几秒一次），GUI 最多晚一个采样周期看到，可以接受；能立刻多推一行更好，留给实现。

`rapp-host stay-awake`（`Sources/rapp-host/main.swift` 加子命令，走共用的 `parseHostArguments`（`Sources/RappCore/WorkerCLI.swift`））。按 CLAUDE.md，**同一个提交里改 host-core**（我的决定）：`rust/host-core/src/run.rs` 的 `USAGE_TEXT`、`cli-args.json` 样本（`tests/cli.rs` 的 `host_arguments_match_swift`）、`PORTING.md` 对照表的行号和摘要；host-core（Windows）对 `stay-awake` 回不支持的错误。子命令的行为：调 `PowerHold.stayAwake(...).hold`，打一行 `{"ok":true}`（`--json` 时），然后阻塞到 stdin 读到 EOF 或收到 SIGTERM，再 `release` 退出。断言建失败就打 `{"ok":false,"error":..}` 并以非 0 退出，服务按「意外退出」处理。

## 7. 界面

**卡片**（一个共享组件，例如 `gui/lib/ui/no_lock_card.dart`；总览栏和手机设备页都用它，同 [one-card-implementation] 的规则）：

```
┌───────────────────────┐
│ 不锁屏          [●━]   │
│ 一直亮着，不会锁屏       │
└───────────────────────┘
```

- 标题「不锁屏」+ 开关（`RappSwitchRow`，key `no-lock-switch-<id|local>`）。
- 说明一行，按状态：
  - 关：「没人连着时，会按系统设置熄屏、锁屏」
  - 开、在保持：「一直亮着，不会自动锁屏」；macOS 再加一句「合上笔记本盖子仍会睡眠」
  - 开、没保持住（`no_lock_held == false`）：「没能保持唤醒，正在重试」（警告色）
- 点开关：开关先停在原值并显示忙，请求成功后等快照带回新值再变；失败用 `state.say('失败：…')`，开关回原样。拒绝（没钥匙）时被控端回的错误文字是 `not supported`（`rust/service/src/forward.rs` 里 `admit` 拒绝的说法），GUI 认这个字符串，说「这台设备不能改它的设置」。
- 电脑离线时卡片变灰、不能点（和余力行一样，离线不显示快照，所以自然不显示；离线栏里不出卡片即可）。

**放在哪**：
- 总览 `overview.dart` 每一栏头部，`LoadRow` 下面。本机栏走本机 IPC，远端栏走 hub 的 `no_lock` 命令。iPad 用的是同一个总览。
- 手机 `gui/lib/phone/devices_page.dart` 每台设备的标题下面，同一个卡片，走 hub。
- iOS 设备本身不是被控端，没有本机栏，不显示自己的卡片。
- **本机栏折起来时**（没人接入时 iPad / Duo / PC 本机栏默认折成 56px 竖条）卡片看不到。开着时竖条上加一个小标记（开锁图标，tooltip / 语义标签「不锁屏开着」），点竖条照常展开（我的决定）。这样离开电脑前开了、回来忘了，也看得到。

**本机设置页**：「远程 app 都关闭后自动锁屏」那行下面，在 `no_lock` 开着时加一行灰字：「『不锁屏』开着，暂不自动锁屏」。开关本身不动。

## 8. 兼容

- 老电脑：快照里没有 `no_lock` 键，卡片不出现；也就不会给它发 `Op::NoLock`。万一发了，回 `unknown op`，按失败提示。
- 新 GUI 连老 hub、老 GUI 连新服务：多出来的键被忽略，没有影响。
- Windows 服务不带这两个键（§5），卡片不出现。本轮不改任何 `cfg(windows)` 代码。

## 9. 测试

- `config.rs`：`no_lock` 默认关、存取往返。
- `autolock.rs`：`no_lock` 开着时定时到了不锁；关掉后重新计 10 秒。
- `no_lock.rs`：用一个假的保持唤醒命令（可注入的命令路径，比如 `sleep 3600` / 立刻退出的 `false`），测起、关、意外退出退避重起、`held` 跟着变。
- `msg.rs`：`Op::NoLock` 的 JSON 形状（带 / 不带 `on`）。
- testkit：两台设备，B 通过 hub 开 A 的「不锁屏」，A 的配置和快照变；没钥匙的设备被拒并记日志。「有快照但没有 `no_lock` 键」（老版本、不支持的桌面）`Opts.load: None` 模拟不了（它让整个余力回 `unknown op`），所以用 service 的单测测「不支持时快照不带键」（判断函数可注入），GUI 的单测测「没键不出卡片」。
- Flutter：卡片三种说明；有键才显示；点开关的忙 / 失败回原样；总览本机栏、远端栏、手机设备页都出现。
- Swift：`stay-awake` 子命令的参数解析；断言本身在实机上验。

**实机检查**（写进 `tasks/todo.md`）：
1. Mac A 打开「不锁屏」，所有设备断开，等过系统设置的熄屏时间 + 屏保时间：A 不熄屏、不锁；`pmset -g assertions` 里看得到 rapp 的断言。
2. 关掉后：不会马上锁；系统按自己的设置熄屏、锁屏；再连一次远程 app 并关掉，10 秒后自动锁屏（自动锁屏开着的话）。
3. 从 iPhone 开关 Mac A 的「不锁屏」，Mac 本机总览几秒内跟着变；反过来也一样。
4. 重启 A：开关还开着，开机登录后马上保持。
5. Hyprland（Omarchy）电脑同 1–3：hypridle 不熄屏、不进 hyprlock。
6. 老版本电脑、Windows 电脑、Hyprland 以外的 Linux：没有这张卡片。
7. 本机栏折着时，竖条上看得到「不锁屏开着」的标记。

## 10. 留给实现的

- `no_lock_held` 是不是直接放进 `State`，还是放在 `no_lock` 模块里由快照去读。
- 开关变化时让 `watch_load` 立刻多推一行，还是等下一个采样。
- hub 的命令名、GUI `HubClient` / `ServiceClient` 方法名，照现有命名习惯。
- 这次加 Op 要不要动协议版本号，按仓库现在加 Op（如 `SetService`、`Load`）时的做法。
