# 安装包带上命令行和 ssh 设置；自动升级后提醒重装（短设计）

日期：2026-11-16。上游：在线升级 `2026-11-12-rapp-online-update-design.md` §4，端口分享 `2026-11-15-rapp-port-sharing-design.md` §9.4。

## 为什么

- 规格里处处写 `rapp share`、`rapp pipe`，但安装包从来没带 `rapp-cli`，装完敲不了。用户要的是装完就能用，不用自己编译、不用改 `~/.zshrc`。
- `ssh <设备>.rapp` 现在要用户自己往 `~/.ssh/config` 加两行。用户要 rapp 自己处理。
- 这两样都要管理员权限，只能由 pkg 的安装脚本做；zip 自动升级不跑安装脚本。用户定的：遇到这种变化，升级后提醒用户重新安装一次。

## 目标

- 装 pkg 后：`rapp hosts`、`rapp pipe …` 直接可用；`ssh <ID>.rapp` 直接可用（前提是对方分享了 22）。
- 凡是 pkg 新加了 zip 升级带不过去的东西，升级后的 rapp 自己发现"没装全"，在 GUI 里提醒重装，装好后提醒自己消失。
- 不改用户自己的文件（`~/.zshrc`、`~/.ssh/config`）。

## 不做

- 升级前的提醒（latest.json 里加字段）。自动升级挑的是没人在用的时候，事前提醒多半没人看见；装没装全只有装完才知道。（我定的）
- Linux 包。Linux 的 service 不报这一项。
- 卸载。

## 做法

考虑过的：

| 做法 | 结论 |
|---|---|
| **安装批次号**：pkg 写一个数字，service 里写死同一个数字，小了就提醒 | 采用。以后每多一样要 pkg 才能装的东西，两边一起加一，机制不用再改 |
| service 逐项检查 `/usr/local/bin/rapp`、`ssh_config.d/rapp.conf` 在不在 | 不用。每加一样都要改检查代码；用户自己删了某一项也会被一直提醒 |
| latest.json 带一个"这版要 pkg"的标记，升级前提醒 | 不用，见"不做" |

**安装脚本（`scripts/pkg/postinstall`）**，在"有没有人登录"的判断之前做，因为都是系统级的：

1. `/usr/local/bin/rapp` → `/Applications/rapp.app/Contents/MacOS/rapp-cli` 的符号链接。那里已经有一个不是符号链接的 `rapp` 时不覆盖。`/usr/local/bin` 在 macOS 默认的 PATH 里（`/etc/paths`）。zip 升级替换整个 app，链接仍然指向新的 `rapp-cli`。
2. `/etc/ssh/ssh_config.d/rapp.conf`：`Host *.rapp` + `ProxyCommand /usr/local/bin/rapp pipe %h %p`。macOS 的 `/etc/ssh/ssh_config` 开头就 `Include /etc/ssh/ssh_config.d/*`。用户自己的 `~/.ssh/config` 先读，里面写了的仍然优先。端口分享 §9.4 原来定"rapp 不替用户改 `~/.ssh/config`"，这里不碰那个文件。
3. 最后写 `/Library/Application Support/rapp/install-level`，内容是批次号，这次是 `1`。

**打包（`scripts/package-macos.sh`）**：编译 `rapp-cli`，拷进 `Contents/MacOS/`，签名标识 `com.rapp.cli`（加进 `EXPECTED_IDS`）。

**service**：
- `rapp_update::INSTALL_LEVEL = 1`，和安装脚本写的数字同步改。
- `UpdateOpts.install_level`：批次文件的路径；`None` 不检查。装好的 app（`UpdateOpts::system`）是上面那个路径；开发构建没有 `UpdateOpts`，不检查。
- `update_status`（也在 `status.update` 里）加两个字段：`needs_reinstall`（文件不在、读不出数字、或者数字比 `INSTALL_LEVEL` 小）；`reinstall_page`（发布页 `https://github.com/wizlijun/rapp/releases/latest`）。每次报告状态时读一次文件，pkg 装完后不用等重启也会变。

**GUI（本机 › 版本与升级）**：
- 正在检查、下载、安装时照旧显示进度；其余时候 `needs_reinstall` 优先，这一行写「这一版要重新运行一次安装包，才能用上命令行 rapp 和 ssh 的 .rapp 设置」，按钮「下载安装包」打开 `reinstall_page`。
- 侧栏「本机」上的小点在 `needs_reinstall` 时也亮。
- 旧 service 不发这个字段，当作 `false`。

## 怎么验

- 单元测试：批次号的判断（不在、空、乱写、`0`、`1`、`2`）；service 的 `update_status` 在文件不在 / 数字小 / 数字够 / 不检查四种情况下的 `needs_reinstall`；GUI 的那一行、按钮和小点；`test-package.sh` 的 `EXPECTED_IDS` 和安装脚本里的三步。
- 实机：在这台 Mac 上装新 pkg 前，GUI 显示重装提醒；装完提醒消失；`rapp hosts` 能用；`ssh <ID>.rapp` 能连上分享了 22 的设备。
