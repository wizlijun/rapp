# 总览本机列：终端卡片

- 日期：2026-11-27
- 相关：文本终端（`2026-11-16-rapp-text-terminal-design.md`）、多人同看一个终端（`2026-11-14-rapp-terminal-sessions-design.md` §15）、⌘T 多终端（`2026-11-26-rapp-term-multi-design.md`）、终端恢复（`2026-11-26-rapp-term-restore-design.md`）、本机列折叠（`2026-11-26-overview-fold-local-design.md`）、连上的服务（`2026-11-27-rapp-overview-local-services-design.md`）
- 原则：不接管不是 rapp 开的终端（2026-11-25 定）

## 1. 为什么

只有经 `rapp-term run` 开的文本终端，别的设备才能同时打开、一起看一起打字。可是在 PC 上，用户平时直接开「终端」app，开出来的终端别人接不进来。现在要在 PC 上开一个能共享的终端，只能从别的设备远程 ⌘T，或者自己在命令行敲命令。

所以要在 PC app 总览的本机一栏放一张「终端」卡片，让「用 rapp 开终端」成为最顺手的那条路：点「新建」开一个，点一行就切到那个终端的窗口。

## 2. 用户定的

1. **在「终端」app 里开**（第 1/2 件）。「新建」在「终端」app 里开一个新标签页，rApp 自己不开内嵌的文本视图，只是入口。卡片列出本机正在运行的 rapp 终端，点一行就把它的窗口切到前面。
2. **有 rapp 终端也算，本机列自己展开**（第 2/2 件）。有人接入，或者本机有 rapp 终端在运行，本机列就展开；两样都没有才折。手动开过或折过的，这次运行里照旧按用户的来。第一次「新建」要先点开竖条。
3. **走本机服务的控制通道**（做法 A，见 §6）。

```
本机
────────────────
终端                新建
 ● zsh · ~/git/rapp
 ● claude · rapp     2 个在看
────────────────
正在被接入 …
────────────────
连上的服务 …
```

## 3. 要做的

### 3.1 卡片放在哪、什么时候出现

- 只在 PC 上（macOS、Linux）本机列展开的时候出现，放在列的最上面，在「正在被接入」卡片和「连上的服务」之上。*（我的判断：这是用户主动要用的入口，放最上面；另外两组只是用来看的。）*
- 本机的终端服务不可用时整张卡片不出现。比如在 全局设置 里关了文本终端，或者服务太旧，不认识新命令。
- iOS / iPad / Duo 没有本机服务，不出现。Windows 等文本终端上了 Windows 再说，这次不出现。

### 3.2 列表

- 一行一个本机正在运行的 rapp 终端，也就是本机 `rapp-term serve` 列出的、`host` 为空的 `TermRow`。不管是本机「新建」开的，还是别的设备 ⌘T 开的，都列。
- 每行左边一个灯，然后是名字。名字和远程设备上看到的一样：`termDisplayName(row.shown, row.host)`。灯的颜色和含义沿用远程终端卡片的规则：程序状态（OSC 7501）、未读。
- 有别的设备正在看（`attached > 0`）时，行尾写「N 个在看」，muted 小字。*（我的判断：这正是这张卡片的意义，一眼看出它被共享了。）*
- 名字太长就折行，不裁掉，和「连上的服务」一致。
- 列表随 serve 的 watch 实时更新，不用手动刷新。
- 一个终端都没有时，卡片只剩标题行和「新建」，下面一行 muted 小字「用 rapp 开的终端，其他设备也能打开」。*（我的判断：顺便解释为什么要从这里开。）*

### 3.3 点一行：把这个终端的窗口切到前面

- 新加 serve 请求 `front {term}`：
  - 按 term id 找到 holder 的 `Status`，取它的 `tty`；
  - 在「终端」app 里找 `tty` 相同的标签页，取消最小化，选中这个标签页，把它的窗口放到最前，`activate`；
  - 回答 `{"ok":true}`，或者 `{"error":"not-found"}`（找不到这个标签页：holder 开在别的终端 app 里，或者「终端」app 没在运行）。
- AppleScript 和 `launch.rs` 里 `TERMINAL_TAB` 按 tty 找标签页的那段写法一致，跑的时候同样用 `bounded_command`，10 秒为限。
- Linux 上 `front` 回答 `{"error":"unsupported"}`。Linux 上的行只用来看，点了没有反应，也不显示可点的样子。
- 找不到时，GUI 给一条 hint：「没找到这个终端的窗口」。

### 3.4 新建

- 调 serve 的 `open`：`from: "last"`，从上次的目录开始，和现在远程「新建」的规则一样。`app` 取本机的终端 app 设置，和 `_launcherOf` 一样：`prefs.termAppFor(<本机 key>, launchers)`，launchers 来自本机 TermList 里 `host == null` 的 `HostRow`。
- 不打开 app 内的文本视图（这是和远程「新建」的唯一区别）。新终端出现在卡片里，是 watch 推过来的。
- 等待中显示全局等待卡片「正在新建终端…」（`Waits` / `WaitCard`，和 ⌘T 一样）。失败就用 hint 显示服务返回的错误。
- 第一次新建会遇到 macOS 的自动化授权弹框，沿用现有「新建终端先问授权」的处理。

### 3.5 本机列的折叠规则

- `localColumnOpen` 的输入从「有人接入」改成「有人接入 **或** 本机有 rapp 终端在运行」：
  `localColumnPick ?? (inbound || localTerms.isNotEmpty)`。
- 手动开、折的记忆不变（只在内存里，到 app 退出为止）。
- 终端服务不可用时，`localTerms` 当作空的，退回原来只看接入的规则。

### 3.6 本机服务控制通道上新加的命令

在 `rust/service/src/ipc.rs` 现有的 `term_saved` / `term_restore` / `term_forget` 旁边加三条，都要求本机控制令牌，和那几条一样：

| 命令 | 做什么 | 回答 |
|---|---|---|
| `term_watch` | 用 `crate::term::watch_local` 持续推本机终端列表，和 `watch_load` 一样占一条自己的连接 | 每行一个 `TermList`（`{"terms":[…],"hosts":[…]}`），出错时一行 `{"ok":false,"error":…}` 后关闭 |
| `term_open` | 转给 serve 的 `open`（带 `shell` / `from` / `app`） | serve 的回答，含新终端的 `id` |
| `term_front` | 转给 serve 的新请求 `front` | 见 §3.3 |

- 日志：`term_open` 记 `open_term` 的同类字段（不记 term id，不记名字）；`term_front` 只记 `{"op":"front_term"}`。和 `log_fields` 的规则一样。
- 旧服务回答 `unknown cmd` 时，GUI 当作没有终端卡片，到服务重启前不再问。和 `_watchLoad` 的处理一样。

### 3.7 GUI

- `ServiceMonitor` 像 `_watchLoad` 那样，再开一条连接跑 `term_watch`，把结果放在 `localTerms`（`TermList?`）上，变了就 `notifyListeners`。连接断开就清空，跟着 monitor 的重连一起重开。
- `ServiceMonitor` 加 `termOpen({String? shell, required String app, String? from})` 和 `termFront(String term)`，内部走 `_remoteRequest`。
- 卡片是新的组件 `LocalTerms`，`gui/lib/ui/local_terms.dart`：
  - 外框、标题行、行的样子都用现有的卡片部件（`SessionBlock` 那一族）拼出来，不另画一套（规则：一种卡片一份实现）；
  - 「新建」按钮的样子和远程设备列卡片上的「新建」一样。
- 状态和动作放在 `MainState`，比如 `newLocalTerm()`、`frontLocalTerm(term)`：等待卡片、hint、授权都在那里，和 `openText` 并列。

## 4. 不做

- 卡片里不放「恢复」。重启后恢复还是走原来的入口。
- 卡片里不做结束、改名。这些还在打开终端以后的菜单里。
- Linux 上不做切到前面。
- 不在本机 app 里开文本视图。
- 不列、不接管不是 rapp 开的终端。
- 竖条（折起状态）上不放终端数。
- iOS 不做。

## 5. 失败了也不能这样（反目标）

- 点一行打开的是别的终端，或者开了一个新窗口：找不到就报找不到，不要猜。
- 「新建」点一次开出好几个（0.15.37 修过同类问题）：等待中「新建」不可再点。
- 卡片让本机列在 iPad/Duo 上展开：那里没有本机服务，`localTerms` 永远为空。

## 6. 做法（考虑过的）

| 做法 | 怎么做 | 取舍 |
|---|---|---|
| **A 走本机服务的控制通道（选了）** | 在服务的本机 IPC 上加 `term_watch` / `term_open` / `term_front`，转给本机 `rapp-term serve` | `term_saved` 等现成命令和 `rapp term restore` 已经这么走；`watch_local` 现成（outbox 在用）；不经中继，不改设备之间的协议 |
| B 让 hub 把本机当远程设备 | 复用远程 `terms` / `open_term` 的代码 | hub 的设备表里没有自己，要改寻址；自己连自己还要绕回环或中继 |
| C app 直接跑 `rapp term …` | 每次起子进程 | 列表没法实时更新，还要再解析一遍输出 |

## 7. 留给实现的

- `front` 的 AppleScript 细节：Terminal 把每个原生标签页报成一个窗口，按 tty 找到以后，`set selected of t to true` 加 `set index of w to 1`。真机上验证。
- 卡片里灯的具体颜色，以及「N 个在看」用不用复数等措辞细节，沿用现有终端卡片。
- 测试：serve 的 `front`（找到、找不到、Linux），服务 IPC 三条命令（含旧服务、终端关闭），`ServiceMonitor.localTerms`，`LocalTerms` 组件，折叠规则的新输入。

## 8. 兼容

只涉及本机 app 和本机服务，不改设备之间的协议。服务太旧时，卡片不出现。
