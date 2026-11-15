# macOS ComposerPanel 与 Sumi 候选适配

用户要求写作画板原生组件与 Sumi 一致，颜色和字体保持与编辑区一致。

- macOS 的 `ComposerPanel` 选择 `NativeEditor`，其余平台保留 `FlutterEditor`。
- 原生编辑区使用 NSTextView，文字、选区、撤销和组字由 AppKit 管理。
- 复用 Sumi 的候选消息协议和绘制代码。候选占编辑区下面最多四行；空间不足时保留输入法默认候选窗。选词、数字键和翻页仍由输入法执行。
- 正文、预编辑和候选共用 EditorStyle：主题字体及中文回退、15 px、22 px 行高、主题文字颜色，不加文字光晕。预编辑和选中候选使用细下划线。
- 发送/读取/插入在组字结束后按顺序执行；收起保留可见组字；重新打开等待旧编辑器的草稿读取，避免恢复旧草稿。
- Ctrl+Enter 切换焦点；Enter 发送；Shift+Enter 换行；组字时 Enter/Esc 留给输入法；历史箭头和粘贴沿用 ComposerModel。
- 文字不随每个按键传给 Dart。候选不进入正文、草稿或撤销记录。

原设计 S2 拟自行叠加原生子视图。本次使用当前 SDK 提供的 AppKitView 接入 NSTextView，让平台视图随 Flutter 的布局、裁剪和浮层合成变化，避免另一套窗口坐标同步。仍需对真实窗口的菜单遮挡、拖动、缩放和全屏做实机验收。

## 验证

原生回归可独立运行，不需注册输入法或连接远端：

```sh
clang -Werror -fobjc-arc -fmodules -Wno-nullability-completeness \
  gui/macos/RunnerTests/composer-native-probe.m \
  -framework AppKit -framework CoreText -framework QuartzCore \
  -o /tmp/rapp-composer-native-probe
/tmp/rapp-composer-native-probe
```

覆盖组字样式归一、FIFO、主题一致性、布局确认后接管、原始索引、重复选择、旧租约、超时和收起草稿。Flutter 的 `native_editor_test.dart` 验证通道顺序、样式参数、焦点就绪和最终读取后释放。协议探针使用测试消息，不等于真实 InputMethodKit 键盘验收。


## 本轮结果

- Flutter 3.44.1 / Dart 3.12.1；`dart analyze` 无问题。
- 写作面板、原生通道、模型、Flutter 编辑器、浮动面板、终端写作面板、主窗口和 MainState 共 456 项测试通过。
- 原生探针通过，并以 runner 的严格警告选项编译通过；覆盖最多四行、窄宽度本地分页和空间不足回退。
- `flutter build macos --debug --no-pub` 成功，最终增量构建无警告；产物为 `gui/build/macos/Build/Products/Debug/rapp.app`。
- 依赖锁文件保留原版本；未安装、发布或提交。实际 Fcitx5 InputMethodKit 物理键盘、真实窗口浮层/拖动/全屏仍未验收，不将协议探针等同于这类验收。
