# Linux 写作面板的 Sumi 候选适配

## 目标与依据

用户要求修改本地 fcitx5 源码，使 Rapp 的输入法体验与 Sumi 一致。实际源码为 `/home/bruce/git/fcitx5`（`~/git/fc` 不存在），基线 `b07f55ca`；Rapp 集成基线 `d64a827`。参考本地 note.md 的 Linux 适配和 Rapp macOS 的 `ComposerNative.m`、`Sumi/`。

Rapp macOS 使用一行候选、局部分页、编辑器字体字号、透明背景、选中候选下划线。候选首次出现后保留行高，直到草稿为空或编辑器失焦。保留 Flutter / GTK 的输入法组字与提交路径，候选点击只发送输入法选择操作，不直接插入文本。已有 fcitx 下划线输出过滤保持原样。

## 并行边界

1. **fcitx5**：在独立 worktree 修改候选桥接的未绑定租约交接，保持现有 `org.fcitx.Fcitx.SumiCandidates1` 接口兼容。私有 D-Bus 已复现：一个应用的未绑定申请会无限阻挡另一个已聚焦应用。仅当旧申请未绑定且新请求匹配当前已聚焦输入上下文时允许交接；不可抢占已绑定租约或其他组件的自定义回调。
2. **Flutter / GTK3**：共享原生 GDBus 管理器，内嵌 Flutter 使用独立 MethodChannel 和候选行，拆分窗口按各自 GtkTextView 管理。保留草稿队列和拆窗交接。
3. **GTK4**：按每个 TextView 管理候选，由进程协调当前焦点展示者。共享 TextBuffer 不共享输入法租约。
4. **集成**：复核生命周期、布局和提交边界，运行隔离测试与构建，记录已验证及需要真实设备验证的部分。

## 生命周期约定

- 使用实际程序名、专用 D-Bus 连接、每次焦点周期的新 token 与本地 epoch。旧回包、旧 token 和旧 serial 不可作用于新编辑器。
- 编辑器已挂载、可见、可编辑、处于活动窗口且有候选行容量后申请。切换字段、失焦、隐藏、关闭或空间不足均释放。
- 候选保留输入法的真实 index；本地翻页耗尽后才请求引擎翻页。点击候选不能夺走编辑焦点。
- 注册失败、撤销、服务消失和渲染失效时释放并回到系统候选。仅在仍聚焦且组字结束后退避重试。
- 同程序新编辑器可能在原生 FocusIn 之前绑定旧上下文；不能认为一次 idle 延迟足以避免。依靠 epoch、主动释放、撤销及有条件重试处理。
- 现有 Linux 协议没有 macOS 的 prepared/present 原子切换；先预建 renderer，Flutter 以渲染确认和有界 watchdog 保证失败释放，不宣称零空白帧。
- 不接入打字音效，不增加全局按键钩子，不向远端发送组合输入按键，不记录候选文本。

## 验证与交付

- fcitx：私有 D-Bus、临时 XDG 目录、真实拼音引擎，覆盖既有回归、跨应用 pending 交接、已绑定不可抢、旧拥有者不可撤销新申请、旧序列不可操作。
- Flutter：候选分页与长 Unicode、缩放、预留高度、异步过期回复、隐藏/销毁、缺少插件与渲染失败回退；保留原草稿及快捷键回归。
- 原生：GTK3 / GTK4 编译与适当静态检查，纯布局和状态测试；能够隔离验证的显示测试使用私有会话，不操作用户桌面。
- 真实桌面验收另列：拼音 Enter/Space/数字和鼠标提交恰好一次，应用/字段/窗口切换，拆窗、主题缩放、服务重启与原生回退。
- 构建在隔离目录进行，不覆盖用户源码中的未跟踪 `tasks/`，不在开发过程中重启正在使用的 fcitx5。

## 实现与验收记录

- fcitx 修复提交 `b4fc5f217badff31131fd0f075d6a0fbfc1a1727`，已快进合回 `/home/bruce/git/fcitx5` 的 `typewriter-candidate-theme`，未跟踪 `tasks/` 保持原样。源码及可安装包内实际 addon 各通过 14 条真实拼音/私有 D-Bus 回归；原代码可重现跨应用 pending 交接失败。
- 插件包 `fcitx5-sumi-candidates-5.1.23.r5.gb4fc5f21-1-x86_64.pkg.tar.zst` 和源码、校验和、验证记录保存在 `dist/fcitx5-candidates-r5/`。仅包含 addon、addon 声明和许可证，不修改系统输入法配置。尚未安装。
- 原生 C++ 候选连接增加 12 组私有总线检查，覆盖错误、超时、提前信号、过期请求、最大 uint64 序列、跨编辑器协调和实际总线关闭。动作失败后释放，不重试可能已经提交的选词。
- GTK3 使用 `gui/linux/runner/tests/test-candidates-gtk.py` 启动独立 Broadway、临时 Chromium profile 和私有 D-Bus。真实窗口回归覆盖透明字形绘制、原始 index/serial 选择、草稿不变且不夺焦点、24px 字体缩放、长 Unicode 局部分页、共享草稿多视图交接、普通输入框隔离及销毁。纯布局测试另覆盖 1/1.2222/1.5/2 倍测量。
- GTK4 使用 `rust/client-gtk/tests/test-candidates.py` 验证实际绘制和 GestureClick 选择、空候选行高与滚动区域保留、失焦后 D-Bus owner 消失、旧信号无效、重新聚焦新 token、服务消失回退。常规单测 7 条通过，原客户端 6 场景回归通过。
- 自动测试没有操作用户桌面或重启输入法。真实 Wayland/fcitx 连续输入、输入法切换及跨设备提交仍需实际验收。Linux 协议无输入法端心跳：Flutter 渲染线程失联可由原生 watchdog 释放，但整个原生客户端主线程冻结时，不能承诺立即恢复系统候选。
