# Linux v15 对齐与 0.15.13 发布

基线：main `de975180`，macOS 0.15.12 / 协议 v15。用户要求补齐 Linux 并发布 Linux 版。

## 实现

- 复用共享 Flutter 的常用语管理、输入历史及 v15 舞台暂停策略；iOS 专属常用语条按原规格保留平台范围。
- Linux GTK 主窗口通过 `rapp/system` 上报映射、隐藏及最小化状态，关闭到托盘和从启动器重新打开均走实际窗口状态。
- 分离窗口聚合所有正常窗口的可见性，全部不可见才暂停，恢复任一窗口立即继续。弹出菜单不计作独立可见窗口，失去键盘焦点不暂停。
- 处理原生窗口创建期间的可见性通知，避免 detach 完成把已最小化状态重置为可见。
- Linux host 保留暂停期间未确认帧的 ACK 顺序，将暂停时间从超时和弱网采样中扣除；恢复后仍检查真正的网络停顿。
- Flutter 锁文件按 Linux 要求的 Flutter 3.50.0 SDK 解析。协议仍为 v15，与 macOS 0.15.12 相同。

## 验证

- Flutter 全量 2773 项通过，3 项既有跳过；analyze 无 error/warning，137 项为已有 SDK 弃用 info。
- `host-linux` / `client-core` 的全 target Clippy `-D warnings` 通过。
- GTK 原生窗口 smoke、Xvfb 与 labwc 隔离主机测试通过；Linux GUI release 构建通过（第三方 tray 插件有既有弃用警告）。
- 完整 Rust 工作区及最终包/上传校验结果在发布记录中补充。

原生测试在私有 Broadway、Xvfb、labwc 环境运行，不读取用户剪贴板，不操作真实锁屏。新增主机回归覆盖：未 ACK 的帧跨越 16 秒暂停、静止时无活动、变化时只发 changed、恢复差分与原生截图逐像素一致、恢复同时更改密度。

## 平台边界

Wayland 不提供通用遮挡状态，也不保证提供最小化通知；只能根据 GTK 实际收到的映射和最小化状态暂停。不能声称与 macOS 的全遮挡/其他 Space 检测完全等价。原有 Hyprland/X11、AT-SPI 和锁屏能力边界不变，详见 2026-11-21 的 Linux 非语音对齐记录。

Linux-only 发布使用 `--latest=false`，macOS Latest 保持 0.15.12。发布 Arch/Omarchy x86_64 安装包、便携包和 SHA256SUMS；不自动安装到用户系统。
