# 经验教训

- zsh 不会把没加引号的变量按空格拆开。要把多个文件名交给命令，用 `xargs`，不要用 `$files`。
- macOS 的 BSD grep 用 `--null` 输出 NUL 分隔，`-Z` 在这里不是这个意思。
- 发合成点击之前，先确认那个位置最上层的窗口确实是目标窗口（`topat`）。以前有一次点到了用户的 Claude 窗口上。
- 不要去改用户文档里的文字（比如 TextEdit）。自动模式会把这种操作当作不可逆的破坏而拒绝。
- 用户先说了"性能优先于安全，relay 是唯一门禁"，就不要再提议额外的加密层或审批步骤。
- 省流（双色）档的目标是"看清文字"，不是"字节最少"。按亮度均值二分会把抗锯齿边缘一刀切掉，低密度下文字断笔、字周围出灰块；基色要取两端最暗、最亮的像素，边缘保留过渡级。改动画质的算法时，要把新旧输出渲染成图片亲眼对比，不能只看码率。
- 抓屏报 "application connection being interrupted"（replayd 的 XPC 4097），先查有没有一直开着的旧 rapp-host。这次是一个连续跑了约 18 分钟、30 fps 的旧进程，replayd 把新进程的抓屏请求记到它头上，新进程一开流就被断开；停掉旧进程就好了。两个新进程同时抓不同窗口、甚至同一个窗口都正常，所以不是“同一身份只能一个进程”的限制。
- 用 System Events / AX 操作窗口时，只按 PID 定位自己启动的进程（`first process whose unix id is …`），不按进程名。用户自己可能正开着同名的 rapp-client：有一次按名字找，挪了用户正在用的 "Grok Bot" 窗口。
- 用窗口列表（CGWindowList）判断"这个点最上层是谁"不可靠：macOS 27 的 Dock 一直挂着一个铺满屏幕、layer 20、alpha 1 的透明窗口，结果 B 上的每次点击都报 "covered by Dock" 被丢掉。碰到 Dock 的窗口要再用 AX 命中测试（AXUIElementCopyElementAtPosition）确认那个点是不是真的 Dock 栏。系统升级后先看一眼 host 日志里有没有成片的 "click dropped"。
- 在本机回环（host 和 client 在同一台 Mac）做实测时，用户若同时在用电脑，焦点和窗口遮挡都会变。开始前先请用户别动键盘鼠标，每次合成点击前都查最上层窗口。
- rust/ 下没有 rustfmt.toml，现有代码也不是 rustfmt 的产物（宽度约 120，任何配置下 `--check` 都不干净）。不要跑 `cargo fmt --all`：一跑就把整个 workspace 改了 1000+ 行。只格式化新文件：`rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <新文件>`。
- 用户可能同时在仓库里改文件（这次是设计语言、README、新规格）。提交只按文件名 `git add <路径>`，不要 `git add -u/-A/.`；也不要 `git stash`、`checkout`、`restore`、`reset` 去拿基线——会把用户没提交的改动卷走或暂时弄没。要基线就用 `git worktree add` 到临时目录。
- `topat` 按窗口所属 app 的名字判断"是不是 rapp"不够：用户机上常同时开着自己的 rapp GUI、rapp-client 和连接管理窗口，都叫 rapp。合成点击前要按 PID 判断（`s2live/topatp`）。
- 实机检查要用户把电脑让出来一段时间。用户在用的时候测试 GUI 会被抢焦点、甚至被用户 ⌘Q 关掉；这时停下、记"待实机"，不要反复把自己的窗口提到前面。
- Flutter 里祖先已经 `Focus(autofocus: true)` 时，子控件的 `autofocus` 不起作用；要在下一帧 `requestFocus()`。
