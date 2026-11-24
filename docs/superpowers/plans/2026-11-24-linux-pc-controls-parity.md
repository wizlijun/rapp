# Linux：PC 按键区、常用语与应用名称对齐

基线 `a8eea50c`（远端 `02db2d43`，保留本地 Linux 0.15.16 语音热词修复）。本轮补齐刚合入的 PC 按键区、常用语和名称/图标更新。

## 差异与处理

- 按键区、常用语条、键盘输入后收起、设置入口和底部布局已由共享 Dart 实现提供。补充 Linux 平台的布局及键盘收起回归，保持 Ctrl/Super 快捷键不收起、常用语条在窄条状态仍显示。
- LinuxSessionPort 原先没有处理 `key_event` 与 `latch`：共享 AppKeySender 发出的修饰键边沿被忽略，实体键盘也未合并粘滞修饰键。现在将边沿转换为 worker 已支持的 `key` + `down`，将粘滞位带入实体按键，并发出 `LatchUsedEvent` 供共享状态清除单次修饰键或重新启用锁定位。
- 单次修饰键对同一按键的重复和释放保持一致；仅实体修饰键或本地保留键不消耗它。带粘滞快捷键的字母直接发往远端，不误入写作框。失焦清除实体按键和待用状态，防止下一会话继承。
- 独立 GTK 客户端的可见窗口标题、菜单及包内说明统一为 `rApp`。二进制名、命令、应用 ID、日志前缀和数据路径保持兼容。
- 新图标已由 Linux 打包脚本引用更新后的 macOS PNG，启动器名称也已随上游更新，无须复制另一套图标。

## 验证

- 新增 Linux 按键链路测试先复现失败，再修复通过；使用真实子进程检查传给 worker 的命令和共享 AppKeySender 的状态变化。
- 相关 Flutter 回归 298 项通过；随后增加一项保留键/修饰键用例，单独重跑该文件 4 项通过，合计覆盖 299 项不同用例。
- Rust rapp-session 10 项测试通过，GTK 客户端 `cargo check --locked` 通过。
- Flutter analyze 无 error/warning，139 项现有弃用提示；Flutter 3.50.0 Linux release GUI 构建通过。
- Linux 构建路径、worker 暂存与旧引擎拒绝检查通过，`git diff --check` 通过。

本轮不发布、不安装系统包。实体键盘、触屏长按/上滑和安装后启动器图标的实际体验仍待实机验收。

## 后续 Linux 发布

用户随后要求发布 Linux 版。整合远端 `ab1393ea`（macOS 0.15.17，只有版本与网站快照更新），Linux 发布号使用 0.15.18（Flutter 0.15.18+74），协议保持 v15。发布 Arch/Omarchy x86_64 包、便携包及 SHA256SUMS，以 `--latest=false` 保留 macOS 的自动更新清单。本次发布不自动安装。

### 发布包验收

- 构建源码 `d1ce9a1a39bfbaf0a39e03ddccb169a73c5c8222`；Flutter 3.50.0。Arch 安装包与便携包包含相同的 40 个文件，14 个 ELF 的动态依赖均可解析，源码/引擎版本和协议 v15 已核对。
- 隔离 Wayland 与网络环境中，包内 hub → service → desktop QUIC 捕获、CLI、端口共享及监听器回收检查通过；新图标和启动器 rApp 名称正确。
- 包内 Whisper 使用公开音频与真实模型的 8 项检查全部通过：短音频、热词、静音、五分钟边界、截断，以及停止/取消/崩溃后的采集进程清理。没有使用用户麦克风或录音。
- 验证日志：`.build-logs/linux-01518-package.log`、`.build-logs/linux-01518-artifacts.log`、`.build-logs/linux-01518-speech.log`。物理触屏、实体快捷键和实际账号解锁仍待设备验收。

### 发布结果

- Linux [v0.15.18](https://github.com/wizlijun/rapp/releases/tag/v0.15.18) 已公开发布，源码标签指向 `d1ce9a1a`；三个远端资产的大小与 SHA256 均和本地一致，匿名下载的校验清单一致。
- 便携包上传前改用 gzip 最高压缩率；已确认解压后的 tar 字节完全一致，并重新生成校验清单及重跑发布包验收。安装包没有改变。上传连接超时后通过当前请求绑定 Wi-Fi 接口完成；没有修改系统网络配置或创建临时 Actions 分支。
- 上传期间另一端发布了 macOS v0.15.19，Latest 保留该版本；macOS v0.15.17 既有资产 ID、大小和 SHA256 均未改变。Linux 本次构建仍基于 macOS 0.15.17 的图标与功能基线。
- 仓库网站下载快照已刷新至 Linux 0.15.18 / macOS 0.15.19；网站发布选择的 8 项测试、语法检查和静态构建通过。本轮未重新部署网站，也未自动升级本机。
