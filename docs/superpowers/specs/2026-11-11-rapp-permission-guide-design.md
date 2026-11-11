# rapp 权限引导设计

日期：2026-11-11。依据：用户要求"连接时的警告信息，如果是没设置权限的，请跳到对应设置权限的地方"，并认可按 Apple HIG 思路做的加强版。
平台规格见 `2026-11-11-rapp-platform-design.md`，本文只写改动。

## 0 原则

- 授权只能由坐在 A 前面的人在 A 的系统设置里完成。B 只说明情况，不在 A 上弹任何东西。
- 先预防：A 第一次打开 GUI 时引导授权；B 在点开 app 之前就能看到 A 缺权限。连接失败时的提示只是兜底。
- 按钮写「打开系统设置」，不写「允许」。每一项都说明用途。
- 授权后自动变成 ✓，不用手动刷新，也不反复催。
- 兼容：新增字段，旧版不认识就忽略；Windows、Omarchy 主机不报权限，B 就什么都不显示。

## 1 rapp-host（Swift）

- 新增 `rapp-host check --prompt [--json]`：屏幕录制缺失时调用 `CGRequestScreenCaptureAccess()`，辅助功能缺失时调用 `AXIsProcessTrustedWithOptions(prompt: true)`；结果和 `check` 一样。这一步由 rapp-service 拉起，所以系统设置里登记的是 rapp。解析放进 RappCore：`HostCommand.check(json:prompt:)`。
- `list-apps --json` 的结果多一个 `"permissions":{"screen_recording":…,"accessibility":…}`，只做 preflight，不弹窗。
- `serve` 缺权限时，第一行仍是 `missing permission: Screen Recording, Accessibility`（GUI 按这一行解析）；第二行改成 `Allow rapp (or the terminal running rapp-host) under System Settings > Privacy & Security, then connect again.`。

## 2 rapp-service（Rust）

- `State.permissions` 改成 `Mutex<Value>`。`set_permissions(v)` 只在值变化时 `notify()`，订阅者会收到 `changed`。
- 新 IPC 命令 `{"cmd":"permissions","prompt":<bool>}`：运行 `rapp-host check [--prompt] --json`，存下结果，回复 `{"ok":true,"permissions":{…}}`。check 本身失败（超时、没有输出）时保留上次的结果，不当成"全部缺失"。
- `list_apps`：从 `list-apps` 的结果里取 `permissions`，有就存下，并放进给 B 的回复：`{"ok":true,"apps":[…],"permissions":{…}}`。
- `open` 失败，并且错误里有 `missing permission` 时：重新 check 一次并存下。
- service 自己不开定时器。轮询由 GUI 在显示缺权限的时候做（§4）。

## 3 rapp-hub（Rust）

- `apps` 事件在 A 的回复带了 `permissions` 时原样转发：`{"event":"apps","id","path","apps","permissions"}`。

## 4 GUI（Flutter）

- 纯函数，放在 `gui/lib/permissions.dart`，配测试：
  - `Permissions.fromJson(Map?)`，以及 `missing`（中文名列表：屏幕录制、辅助功能）。
  - `missingFromError(String) -> List<String>?`：从 `missing permission: Screen Recording, Accessibility` 解析出中文名；不是权限错误就返回 null。
  - 用途文案：屏幕录制是"把这台电脑上 app 窗口的画面传给另一台电脑"；辅助功能是"让另一台电脑的鼠标键盘操作这里的 app，并移动窗口、使用菜单"。
  - `remoteHint(host, missing)`："「host」缺少 屏幕录制、辅助功能 权限。请在那台电脑上打开 rapp，在 本机 › 权限 里点「打开系统设置」。"
  - 深链：屏幕录制是 `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`，辅助功能是 `…?Privacy_Accessibility`。
- `PermissionsPanel` 组件：每项一行，写名称、用途，右边是 ✓ 或「打开系统设置」按钮。按钮先发 IPC `permissions` + `prompt:true`，最多等 2 秒，再用 `open <深链>` 打开设置页（只在 macOS 上）。底部一行小字："授权后这里会自动变成 ✓；如果一直不变，点「重启」。"（引导对话框里写「重启服务」，对应对话框自己的按钮。）
- 本机 › 权限：用 `PermissionsPanel` 代替原来的 ✓/✗ 文本。
- 轮询：本机区块显示着、并且有缺失项时，每 3 秒发一次 IPC `permissions`（`prompt:false`）；全部 ✓ 后停止。
- 首次引导：只在 macOS 上。第一次拿到 status 且有缺失项、并且 `<configDir>/permission-guide-shown` 不存在时，弹一个对话框，内容是 `PermissionsPanel`，按钮是「稍后」、「重启服务」（有缺失项时）和「完成」（全部 ✓ 才能点「完成」）。弹出时写入这个标记文件，以后不再自动弹出。
- 主机 › app 列表：A 报告了缺失项时，列表上方显示一行橙色 `remoteHint`。
- 打开 app 失败：如果 `missingFromError` 能解析，就显示 `remoteHint`，不显示原始英文错误。

## 5 测试

- Swift：解析 `check --prompt`；`appsJSON` 带 permissions。
- Rust：假 rapp-host 读 bin 目录下的 `perms` 文件（没有就当全部已授权），把 `check --prompt` 记进 `host.log`，`serve` 在缺权限时按退出码 3 和真实文案退出。测试覆盖：IPC `permissions`（带不带 prompt）、`list_apps` 回复带 permissions 并更新 status、权限改变时订阅者收到 changed、open 因缺权限失败后 status 更新、hub 的 apps 事件转发 permissions。
- Dart：纯函数测试；hosts_section 组件测试（缺权限的错误显示中文提示，app 列表的警告行）。
- 实机：这台 Mac 已经授权，看不到缺权限的分支；只验证 `check --prompt --json` 在已授权时不弹窗，以及两个深链能打开对应的设置页（会在你的屏幕上打开系统设置）。

## 6 未验证的假设

- 屏幕录制授权后，由同一个 rapp-service 新拉起的 rapp-host 能否马上看到授权，还是要重启 rapp-service。这台 Mac 已授权，测不了。所以面板里留了"一直不变就点重启"这一句兜底。
