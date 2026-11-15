# 文本终端 P0 探查（本机部分）

日期：2026-11-16。状态：本机先验已完成；四项真机验证待用户（见末尾）。

## 探查程序

独立 cargo 小程序（不进仓库），portable-pty 0.9.0 + alacritty_terminal 0.25.1。`pty-probe -- <命令>`：开 pty 跑命令，输出原样写回标准输出并喂给 alacritty_terminal；标准输入 raw；收到 SIGUSR1 把网格转成行写 `/tmp/pty-probe.txt`（SGR 颜色/粗体/反显，宽字符只写一次，行尾默认空白裁掉，末行附光标位置与尺寸）；原始输出字节追加到 `/tmp/pty-probe.bin`。

二进制：`/private/tmp/claude-501/-Users-bruce-git-rapp/ef39f28a-f016-46c7-b62c-73c1b1693898/scratchpad/pty-probe/target/release/pty-probe`

## 本机检查

**程序自测。** 在 `script` 提供的 pty 里跑 `printf '红色 hello / 日本語 ok'`，SIGUSR1 后得到的行：红色带 `ESC[31m`，中日文各写一次（无占位空格），光标 row=2 col=0，尺寸 80x24。原始字节文件里能看到 pty 回显的杂项（`^D\b\b`），属 `script` 造成，与程序无关。

**① 窗口脱离 rapp-service。** `open -a Terminal x.command`（内容 `exec sleep 600`）。观察到的进程链：

```
sleep 600   pid 5209  ppid 5191  pgid 5209  tty ttys006
-zsh        pid 5191  ppid 5189
login -pf   pid 5189  ppid 20788
Terminal    pid 20788 ppid 1
rapp-service pid 25844 ppid 1 pgid 25844 （/Applications/rapp.app/Contents/MacOS/rapp-service）
```

链是 Terminal → login → zsh → sleep；sleep 自成进程组，有自己的控制终端，与 rapp-service 的进程组不同，也不是它的后代。（`ps` 的 sess 列在 macOS 上恒为 0，不能用来比较会话，以 ppid 链为准。）这只证明“父子关系上无关联”；“停掉 rapp 服务后窗口是否还在”未在本机做（不想中断用户正在用的服务），留给真机验证 ①。收尾：`pkill -f 'sleep 600'` 已清理，无残留。

**② iTerm。** 本机未安装（`open -Ra iTerm` 报找不到），无法验；留给真机验证 ②。

**终端 app 的 bundle id**（本机只装了 Terminal）：

| app | bundle id |
|---|---|
| Terminal | com.apple.Terminal |
| iTerm / Ghostty / WezTerm / kitty / Alacritty / Warp | 本机未安装，未核对 |

## 许可证（cargo metadata）

| crate | 版本 | 许可证 |
|---|---|---|
| portable-pty | 0.9.0 | MIT |
| alacritty_terminal | 0.25.1 | Apache-2.0 |
| vte | 0.15.0 | Apache-2.0 OR MIT |

三者都是宽松许可证，可直接依赖；发行时需保留 Apache-2.0 / MIT 的版权与许可声明（alacritty_terminal 的 NOTICE/许可文本要随附）。

## 对计划的影响

- ①：进程链支持“Terminal 窗口里的进程独立于 rapp-service”，任务 7、9 可以按此写，但需真机 ① 最终确认。
- ②：未验，任务 9 的 iTerm 部分先按 `open -a iTerm x.command` 写，真机 ② 不成立再换 `osascript`（需“自动化”权限，届时问用户）。
- ③ 的转换规则（宽字符一次、行尾裁空白、SGR）在 alacritty_terminal 的网格上直接可行；`WIDE_CHAR_SPACER` / `LEADING_WIDE_CHAR_SPACER` 两个标志要跳过。
- ③ 的真实样本 `claude-screen.bin` 要等用户的运行结果，到时单独提交。

## 待用户真机验证

先让 pty-probe 可用：`P=/private/tmp/claude-501/-Users-bruce-git-rapp/ef39f28a-f016-46c7-b62c-73c1b1693898/scratchpad/pty-probe/target/release/pty-probe`。

1. **① 服务重启后窗口还在吗（待验证）**
   ```
   printf '#!/bin/sh\nexec /private/tmp/claude-501/-Users-bruce-git-rapp/ef39f28a-f016-46c7-b62c-73c1b1693898/scratchpad/pty-probe/target/release/pty-probe -- sleep 600\n' > ~/pp.command && chmod 700 ~/pp.command && open -a Terminal ~/pp.command
   ```
   窗口打开后，在「本机」里停掉 rapp 服务（或 `launchctl kickstart -k gui/$UID/<服务 label>`），看窗口和 `sleep 600` 还在不在：`pgrep -fl 'sleep 600'`。
2. **② iTerm 能不能这样开 .command（待验证）**（装了 iTerm 才需要）
   ```
   open -a iTerm ~/pp.command
   ```
   看是不是新窗口、命令有没有跑起来。
3. **③ 真实屏幕转换是否一致（待验证）**
   ```
   rm -f /tmp/pty-probe.bin /tmp/pty-probe.txt; /private/tmp/claude-501/-Users-bruce-git-rapp/ef39f28a-f016-46c7-b62c-73c1b1693898/scratchpad/pty-probe/target/release/pty-probe -- claude
   ```
   正常用一会儿 Claude Code（打几句中文，让它出彩色输出），另开一个窗口 `kill -USR1 $(pgrep -n pty-probe)`，把 `/tmp/pty-probe.txt` 和窗口截图对一下：中日文、颜色、光标位置是否一致；然后把 `/tmp/pty-probe.bin` 和 `.txt` 交给我。
4. **④ 升级 rapp 后窗口还在吗（待验证）**
   按 ① 开着 `pp.command` 的窗口，用新安装包升级 rapp（替换 .app），然后 `pgrep -fl 'sleep 600'` 看它还在不在、窗口有没有被关。
