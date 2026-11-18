# 全部界面控件统一（设计）

## 为什么

用户反馈「自动升级」的开关太大，要求检查全部界面控件，保持统一。

审查了 `gui/lib` 下的全部界面，同一种控件有好几种画法：

- **开关**：侧栏缩到 38×24，其余 6 处是 Material 默认的 52×32。开关的位置也不同，有的紧挨文字，有的靠右。
- **勾选框**：一处在左，一处在右。
- **单选**：三种画法，其中两种只有约 32 高。
- **下拉**：两种写法，共 7 处，边框、箭头和高度各不相同。
- **按钮**：约 40 处直接用了 Material 按钮，没有经过 `RappButton`。
- **输入框**：四种样式，高度从 36 到 56。
- **小目标**：好几处 × 和链接只有 20–28 大。

## 目标

- 每种控件只有一种画法，由 `gui/lib/ui/controls.dart` 里的一个组件或主题里的一个子主题负责。以后新写的界面直接用它们，自然就一致。
- 高度统一。鼠标设备（macOS、Linux、Windows）上可点控件约 40 高，触屏设备（iOS、Android）上 48（用户选定）。
- 新组件在 iPad 和 Mac 上看起来一样，只是高度不同。

## 不做的

- 不改配色、字号和主题的取值。
- 不改布局结构，例如面板宽度、列数、顶栏高 56、会话条 60、app 行 68。
- 不动嵌入区（远程画面）本身，不动终端画面本身。
- 不加新功能。

## 不能出现的

- Mac 上界面整体变高、变松。用户选的就是保持 40。
- iPad 上有可点的东西低于 48。

## 改法（用户选定：统一组件 + 主题）

考虑过的三种改法：

| 改法 | 好处 | 坏处 |
|---|---|---|
| **统一组件 + 主题**（选定） | 每种控件只有一个出处，以后的界面自动一致 | 改动最大，要分几步 |
| 只改主题 | 改的地方少 | 开关摆在哪、下拉用哪种写法、按钮描边，主题都管不到，仍会剩下不一致 |
| 只修列出的异类 | 最快 | 以后的界面还会走样 |

## 规则

### 1. 高度

- `tokens.dart` 增加一个控件高度：鼠标设备 40，触屏设备 48。以后统一用它，不再到处写 48。
  - 用 `defaultTargetPlatform` 判断：iOS 和 Android 算触屏，其余算鼠标。
  - 它是一个全局取值，进程里不变，不做成每个组件可注入（我的判断）。测试用 `debugDefaultTargetPlatformOverride` 切换平台。
  - Windows 触屏本、接了触控板的 iPad 都按平台算，这是有意的。
- `themeDataFor` 在主题这一层明确设置 `visualDensity` 和 `materialTapTargetSize`：鼠标设备 `compact` 和 `shrinkWrap`，触屏设备 `standard` 和 `padded`。
  - 现在主题这一层没写，只有 `listTileTheme` 写了 `compact`。所以是 Flutter 桌面默认值在起作用，测试平台上却按 48 算，测的不是 Mac 上的真实高度。
- 只靠主题和 Rapp 组件达到控件高度，不在各处另外包 `SizedBox`（我的判断）。对话框的默认按钮行这类 Material 自己的东西，跟着主题走就行。
- 按钮的 `minimumSize`、`listTileTheme.minTileHeight`、自绘的 `InkWell` 行，都改用控件高度。
- 测试补上在 macOS 平台下量高度的检查，保证 Mac 上确实是 40。
  - 量的是每个新组件，再加两个页面（`update_section`、`side_panel`）。
  - 现有测试跑在默认测试平台（Android，属于触屏），里面按 48 写的检查保持不变。
- 已经单独定过尺寸的不受影响：顶栏 56、会话条 60、app 行 68，写作面板一行 48、＋和发送 40。

### 2. 开关 `RappSwitchRow`

- 一行就是一个开关：左边是文字（下面可以带一行淡色说明），开关在这一行的最右边。
- 整行都能点，点哪里都切换。按下有圆角 `r` 的水波。
- 开关外观就是侧栏现在那样：用 38×24 的 `SizedBox` 加 `FittedBox` 把 Material Switch 缩进去，所以占位和可点区域也是 38×24。
- 整行的 `InkWell` 负责切换。Switch 自己的 `onChanged` 也接同一个回调，所以现有测试直接点 Switch 仍然有效。
- 侧栏开关的摆放不变，它本来就是这个样子。
- 行高等于控件高度。
- 用到的地方：
  - 侧栏的开关
  - `update_section` 的自动升级
  - `local_section` 的自动锁定
  - `ios_local_section` 的保持亮屏
  - `app_profile_page` 的 4 个开关
  - `composer_plus` 里「发送后回车」那个自画的勾，它其实也是开关，改用这个组件
- 主题加 `switchTheme`：打开时用 `accent` 色，关着用 `line` 色，跟侧栏现在的取色一致。

### 3. 勾选 `RappCheckRow`

- 勾选框在左，文字在右，整行能点，行高等于控件高度。
- 不能点时文字变成 `muted`。
- 用到的地方：`unlock` 的两个勾选、`allow_dialog` 的一个勾选。
- 主题加 `checkboxTheme`：勾上时用 `accent` 底、`accent-ink` 勾；没勾时是 `line` 边框；圆角取 `r` 的一半（我的判断：完整的 `r` 放在 18 的小框上太圆）。

### 4. 单选 `RappChoice`

- 以 `devices_tab` 的 `_ModeChoice` 为准，把它搬到 `controls.dart`：
  - 18 的图标，选中时用 `accent`，没选中用 `muted`
  - 行高等于控件高度，水波有圆角 `r`
  - 无障碍上声明为互斥的一组
- 用到的地方：`devices_tab` 的模式选择、`app_profile_page` 的 `_radio`、`allow_dialog` 的 `_choice`。
- `history_list` 的范围切换（全部 / 本机……）属于标签，改用 `TabChip` 的选中样式，不再用主按钮的实心底。

### 5. 下拉 `RappDropdown`

- 一个线框盒子，按下后弹出菜单。
  - 平时是 `line` 边框。打开时，或者表示「当前选中」时，用 `raise` 底、`text` 边框、字重 600。
  - 右边是 `muted` 色、18 大的 `arrow_drop_down`。
  - 圆角 `r`，高度等于控件高度。
  - 可以带一个开头图标。
- 弹出用现有的 `showMenu` 写法。
- 分两种用法：
  - **选值**：传入当前值。弹出时当前项打勾，盒子可以用选中样式。
  - **动作菜单**：例如 `shares_section`。不传当前值，没有打勾，盒子也不用选中样式。
- 换掉的地方：
  - `window_menu`
  - `devices_tab`
  - `log_screen`
  - `project_menu`：现在没有边框，改成有边框
  - `side_panel` 和 `app_profile_page` 里的 `DropdownButton`
  - `shares_section` 的 `PopupMenuButton`
- 顶栏上的会话块和 `hint_history` 保持「平时无框、打开时选中样式」。顶栏的其他开关都是这样，属于顶栏自己的规矩，不改。
- 弹出的菜单统一：
  - 主题加 `popupMenuTheme`：`bg` 实底、`text` 边框、圆角 `r`、深色投影（规格 §8 浮层）。
  - 当前项一律在左边打勾（`window_menu` 现在的做法），不再用加粗表示当前项。

### 6. 按钮

- `RappButton` 增加 `quiet`：`muted` 字、没有边框、透明底，带 0.97 按下缩放。它就是 `ConfirmButton` 平时的样子。
- 按下面的对应关系换掉直接用 Material 按钮的地方：

  | 现在 | 换成 |
  |---|---|
  | `FilledButton` | `RappButton.primary` |
  | `FilledButton.tonal`（`cm_page`） | `RappButton.secondary` |
  | `OutlinedButton` | `RappButton.secondary` |
  | 对话框里的「取消」类 `TextButton` | `RappButton.quiet` |
  | 页面里像链接的 `TextButton`（忘记密码、显示密钥……） | `RappButton.quiet` |

- 对话框按钮：确认用 `primary`，取消用 `quiet`，确认在右边。
- `RappButton` 仍按内容定宽，最小宽度和高度都是控件高度。这次改的 `TextButton` 都是单独的一个按钮，没有夹在一段文字中间的，所以换掉不会把段落撑开。
- `IconButton` 统一为：方块大小等于控件高度，图标 20，颜色 `text`。
  - `local_section` 的 `_icon` 去掉 `VisualDensity.compact`。
  - `side_panel`、`devices_tab` 的 24 号图标改成 20。
- `stage` 的黄色提示条是特意做的警示配色，按钮的颜色保持不变，只把大小统一到控件高度（我的判断）。如果提示条因此变高一点，也接受，因为它只是临时出现的提示，不属于固定布局。

### 7. 输入框

- 主题加 `inputDecorationTheme`，全部输入框都用同一种：
  - 线框，平时是 `line` 色，聚焦时是 `text` 色，圆角 `r`
  - 紧凑，高度等于控件高度
  - 标签用 `labelText`，加 `floatingLabelBehavior: always`，始终贴在框的上沿（我的判断）。这样只靠主题就能做到，不另写包装组件。
  - 选线框的理由（我的判断）：它和下拉盒子、次级按钮的线框一致，跟按钮并排时等高
- 报错文字统一用主题的 `error` 色，也就是 `accent`。`Colors.red` 和单独写死的颜色都去掉。
- 各处输入框去掉自己的 `isDense`、`contentPadding`、`border` 设置，交给主题。
- 写作面板里的输入框是特意做成无框的，保持不变。
- 多行输入框不受「高度等于控件高度」限制，只统一边框和颜色。
- 搜索框（`log_screen`、`history_list`）、`data_section`、`secure_text_field`、`inline_edit` 都算在内。

### 8. 小目标和水波

- 下面这些只扩大可点区域，画出来的样子不变，可点区域不小于控件高度：
  - `window_menu` 每行的关闭 ×
  - `tab_chip` 的关闭 ×
  - `composer_float` 的 ×
  - `picture` 浮层的关闭
  - `local_section` 的「局域网」折叠
  - `composer_panel` 的输入法链接
  - `term_stage` 的 `_Pill`
- `log_screen` 的日志行在鼠标设备上保持紧凑，因为它们是阅读用的列表，不是按钮（我的判断）。在 iPad 上仍是 48。
- 所有没有圆角的 `InkWell` 水波都补上圆角 `r`。审查列出的有 `sessions_tab`、`stream_menu`、`inline_edit`、`projects_tab`、`devices_tab`、`composer_panel`、`local_section` 和两个自画单选。
- `picture` 的弹窗关闭按钮现在是一个带投影的 accent 圆，全应用只有这一处。改成跟其他关闭一样的 20 号 × 图标按钮。

### 9. 按键

- 三种按键统一用 `app_key_row` 的样子：`raise` 底、`line` 边框；按住或锁定时是 `accent` 边框。
- 大小各自保持，因为那是按布局算出来的。只有 `composer_plus` 的键从 44 改成控件高度。
- `composer_plus` 粘住的键不再用 `text` 实心底，改成 `accent` 边框。

### 10. 规格文档

`2026-11-12-rapp-design-language.md` 跟着改：

- §6 的「所有可点的控件高度不小于 48px」改成「可点控件的高度：触屏 48，鼠标 40」。
- §8 加上开关、勾选、单选、下拉、弱按钮、输入框各一行约定。

## 分步

每一步都单独可测、单独可看，按顺序做：

1. 高度、主题的各子主题、规格文档改动，以及按 macOS 平台量高度的测试辅助。
2. 开关、勾选、单选三个组件，换掉所有用到的地方。
3. 下拉组件、弹出菜单主题和当前项打勾，换掉所有用到的地方。
4. 按钮，包括 `quiet`、对应关系替换和 `IconButton` 统一。
5. 输入框。
6. 小目标、水波圆角和按键。

## 留给实现者

- 组件的具体参数怎么起名、怎么拆分，按 `controls.dart` 现有的风格来。
- 现有测试凡是按名字、按 key 找控件的都要继续能找到。必要时保留原来的 key。
- 换完以后，`gui/lib` 里除了 `controls.dart` 和主题，不应再直接出现以下控件：
  - `Switch(`
  - `CheckboxListTile(`
  - `DropdownButton(`
  - `PopupMenuButton(`
  - `FilledButton(`
  - `OutlinedButton(`
  - `TextButton(`

  用 grep 检查。实在要留的，在旁边写一行注释说明为什么。
