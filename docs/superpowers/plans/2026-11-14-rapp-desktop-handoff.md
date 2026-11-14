# 桌面远程控制 — 交接文档

更新：2026-11-14。分支 `feat/desktop`，工作区 `/Users/bruce/git/rapp/.claude/worktrees/desktop`。
**Task 1–7 已完成；Task 8 自动验证和文档已完成，真机 A/B 锁屏验收待用户配合。没有 push，没有安装或替换用户现有应用/服务。**

先读本文，再读计划 `2026-11-14-rapp-desktop-sessions.md` 和设计 `../specs/2026-11-14-rapp-desktop-sessions-design.md` 的 §8（最终实现差异）。

## 已提交

| commit | 内容 |
|---|---|
| `3eca43e` | core：protocol v10、`screenLocked`/`unlock`、桌面 id/屏幕排序/标题 |
| `aab0afb` | host：整屏会话、锁屏检测、密码输入 |
| `97648bb` | Rust：protocol v10、事件透传、解锁访问记录（不含密码） |
| `a4430d3` | RappSession / macOS runner：锁屏事件、解锁命令、子窗口横幅 |
| `aa990ca` | GUI：设备列表「桌面」、显示器数据、移除屏幕共享按钮 |
| `2864ed0` | Task 6：主屏舞台、副屏子窗口、轮询拔插、Linux 切换条、锁屏横幅 |
| `f471c47` | Task 7：系统密码对话框、macOS Keychain、首次连接自动输入 |
| `b05f017` | host 等待唤醒后、每段密码字符前及回车前复查锁屏，避免解锁后继续输入 |
| `b448ebf` | 所有屏共享画质/帧率/手动固定状态，新开的屏继承；禁止收藏副屏 id |
| `3e7a25a` | 锁屏按钮对比度与格式化后的 lint 修正 |

## 用户已确认的存储方案

**本轮用户明确选择：macOS Keychain（其他平台暂不记住密码）。不要再问 XOR vs Keychain。**

- 不创建 `local/unlock.json`，不做 XOR 混淆，数据目录不保存密码。
- macOS `Sources/RappSession/UnlockStore.swift` 使用通用密码项：service `com.rapp.rapp.system-password`，account = 远端设备 id。
- 密码与 `auto` 一起存入 Keychain；`kSecAttrSynchronizable = false`，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。
- `gui/macos/Runner/UnlockPlugin.swift` 的 `rapp/unlock` channel 在串行 utility queue 上读写，错误只返回固定文案，不回显密码。
- Dart `gui/lib/ui/unlock.dart` 提供异步 `read/save/forget` 与对话框。Linux 等平台仅手动输入，不出现记住/自动输入选项。
- 取消「记住密码」并提交，或点击「忘记密码」，会删除此设备的 Keychain 项。取消对话框不修改记录。
- 本次没有改变被控端知情提示行为；原有解锁访问记录保留，不含密码。

## Task 6 的实现要点

- 主屏记录 `desktop:` 出现在列表和概览，副屏 `desktop:<id>` 隐藏；主屏名称显示已打开的屏数。
- macOS：主屏连接后查询显示器，自动打开副屏；收到有普通窗口的首个窗口表后 detach 一次。空窗口表不会消耗自动 detach 机会。
- Linux：只自动开主屏，点击切换条才打开副屏；`current` 可返回隐藏记录，保证副屏在舞台正常显示。
- 结束主屏级联结束副屏，包括仍在连接中的记录；关副屏只结束自身，不出结束提示。副屏断线静默清理，不自动重连。
- 每 30 秒检查显示器：新增只提示一次，不自动开；消失静默结束。再点「桌面」补开缺失的屏。
- 轮询仅在有 live 主屏时存在；过期查询在主屏结束、重连或 dispose 后不能开新屏。
- 锁屏横幅区分 app/desktop；app 的「打开桌面」已接通；副屏横幅引导到主窗口输入密码。
- 用户选择的画质、帧率、手动固定状态同步到同设备各屏，新开的副屏继承；后台帧率仍遵循已有节流规则。

## Task 7 的实现要点

- `MainState.unlock` 只通过指定设备的 live `desktop:` 主屏发送，当前选中副屏也不会改目标。
- 未锁屏、状态未知、连接结束时不发送；UTF-8 长度超过 1024 字节不发送。
- 自动输入只在新连接第一条 `ScreenLockedEvent` 为 true 时触发一次。第一条 false 也消耗机会，之后再锁不自动解锁。
- 异步读取 Keychain 绑定连接身份和锁屏代次；等待期间断线、结束或先解锁后又锁屏都会取消旧请求。
- 发送 5 秒后仍为同一连接、同一次锁屏，提示「密码可能不对」；解锁后不显示迟到的失败提示。
- 弹密码对话框前释放画面键盘焦点，避免把密码输入发到远端普通窗口。

## 已验证

- `swift test`：146 项 RappSession + 365 项 RappCore，0 失败（1 项跳过）。含 2 项 Keychain 存储测试和 4 项输入时锁屏变化测试。
- `swift build -c release`：通过。
- `TERM=xterm-256color cargo test`：723 通过，3 忽略，0 失败。
- `flutter test`：940 通过，7 跳过，0 失败。
- `flutter analyze`：无问题。
- `flutter build macos --debug` 和 `FLUTTER_XCODE_ARCHS=arm64 flutter build macos --release`：通过。
- 本机真实 Keychain API 用临时合成密码完成保存、读取、覆盖、删除；测试记录已清理，未使用用户密码。

GUI 新测试：`gui/test/ui/desktop_test.dart`（多屏状态和组件）、`gui/test/ui/unlock_test.dart`（存储桥接、自动输入时机/取消、对话框）。既有 `main_state_test.dart`、`stage_test.dart` 回归通过。

## 剩余：真机 A/B 锁屏验收

**没有执行过本轮真机锁屏，不要把单元测试当作解锁实测通过。用户已明确选择「暂不方便；记录待验收项，先完成代码和构建」，本轮不再等待或执行真机验收。**

1. A/B 都使用本分支的 v10 程序（host、service、hub、GUI 需一致），A 保持登录并授权屏幕录制/辅助功能。
2. 用户在 A 本机锁屏；B 打开「桌面」，记录画面是锁屏界面、黑屏还是最后画面，检查主窗口/app/副屏横幅。
3. 用户在 B 的密码对话框中输入系统密码，不要在聊天或日志里提供密码；检查唤出密码框、输入、解锁。
4. 检查解锁后打字、快捷键、鼠标拖拽正常。
5. 勾选记住与自动输入，断开重连锁屏 A：只输入一次；保持连接再锁 A：不能自动解锁。验证错误密码提示和忘记密码。
6. 真多屏验证开窗、关单屏、结束主屏、拔插显示器。
7. 结果记回 spec §8；若画面黑/停留旧帧，调整横幅文字；若注入不成功，按 spec §6 处理，不宣称验收完成。

Linux 原生 GTK/Flutter 运行与多屏硬件行为未在本机测试，只验证了无 detach 平台的 Dart 分支。

## 本地验收构建

- 完整 macOS arm64 测试应用：`dist/desktop-preview/rapp.app`。
- 便于传到 A/B：`dist/desktop-preview/rapp-desktop-preview-macos-arm64.zip`。
- 包内含 release GUI、`rapp-host`、`rapp-client`、`rapp-service`、`rapp-hub`、`rapp-term`；本地 ad-hoc 签名，`codesign --verify --deep --strict` 通过，未公证、未发布、未安装。
- 后续验收时 A/B 均须切换到同一构建并重启对应服务，不能混用现有旧协议二进制。现有进程和数据未动。
- 本机 debug/release 编译仍有既存 `StreamPreset.mode` Sendable 与独立客户端不可达 return 警告；本轮没有扩展修改无关文件。

## 命令与环境

```bash
cd /Users/bruce/git/rapp/.claude/worktrees/desktop
export PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH"
swift test
swift build -c release
(cd rust && TERM=xterm-256color cargo test)
(cd gui && flutter test && flutter analyze)
(cd gui && FLUTTER_XCODE_ARCHS=arm64 flutter build macos --release)
```

- `TERM=dumb` 会使既有 4 项 tmux 实终端测试附着超时；设为 `xterm-256color` 后 37 项 live 测试和全工作区测试通过，无需改终端代码。
- Flutter 若改了 `gui/pubspec.lock`，仅还原工具造成的差异；本轮最终无 lockfile 差异。
- 不全仓 rustfmt，不 push。根工作区 `main` 上未跟踪的终端计划未动。
