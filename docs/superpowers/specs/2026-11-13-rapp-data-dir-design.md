# rapp：数据目录（所有数据放一处，文字用 git 管）

日期：2026-11-13。状态：**已确认**（用户 2026-11-13：「可以，用户可以修改这个目录的根目录」，加了 D12）（用户 2026-11-13：「请规范配置的位置。可以放在一个专门的目录下 可以放各个设备的配置、agent 上下文、共享的粘贴板、传输的文件等所有数据，纯文本的部分用 git 管理，二进制放在一个目录下，设置 git ignore,用其他方式保持同步。」）

改动的是《配置规范总览》§0.4、§1–§3、§6 写的位置；这份落地后回去改那份。

## 0. 决定

| # | 决定 | 为什么 | 代价 |
|---|---|---|---|
| D1 | 根目录 `~/rapp`（Windows `%USERPROFILE%\rapp`）。环境变量 `RAPP_HOME` 仍可改（意思从「配置目录」变成「数据根目录」） | 用户要「专门的目录」：放在家目录下看得见、好找，不藏在 Library 里 | 家目录多一个文件夹 |
| D2 | 根目录是一个 git 仓库。进 git 的只有文字：`shared/`、`devices/`、`clipboard/`、`agent/`、`README.md`、`.gitignore` | 用户：纯文本用 git 管 | 无 |
| D3 | 不进 git（写在 `.gitignore` 里）：`files/`（二进制）、`local/`（本机私有） | 用户：二进制放一个目录，设 git ignore | 无 |
| D4 | **机密不进 git**：`service.json`（设备口令、relay key、secret）和 `hosts.json`（各 A 的口令）放 `local/`，权限 0700/0600 | git 仓库会被推到别处、历史删不掉；口令进了历史就收不回。这不是新加的安全层，只是不把门禁的钥匙放进会到处同步的地方 | 换一台设备要重新填口令（和现在一样） |
| D5 | 剪贴板只存**钉住的**条目：文字一条一个 `.md` 进 `clipboard/`，图片和文件进 `files/clipboard/`。没钉的照旧只在内存里 | 剪贴板里常有私事（复制的密码、聊天）；进了 git 历史就永远在。钉住 = 用户自己说要留 | 取消钉住只删文件，git 历史里还有（GUI 在「钉住」旁提示一次） |
| D6 | git 由每台设备上的 rapp-service 来提交：改动后 60 秒内合成一次 `git add -A` + `git commit`，作者 `rapp <设备名>`。机器上没有 `git` 就不做，GUI 设置页显示「没装 git，文字没有版本记录」 | service 每台都在跑；只有一个写 git 的，不会互相抢锁 | 提交粒度粗（一分钟一次） |
| D7 | 同步文字：用户自己给这个仓库加了 remote（`git remote add …`）才同步：每次提交后 `git pull --rebase` + `git push`，另外每 5 分钟拉一次。没有 remote 就只在本机记版本。冲突 → 放弃这次 rebase、停同步，GUI 显示「同步有冲突，需要手工处理」 | 推到哪里是用户的事，rapp 不替用户选远端 | 冲突要手工解；每台设备只写自己的 `devices/<id>/`，冲突只会出在 `shared/` |
| D8 | 同步二进制（`files/`）：第一版 rapp 不做，`README.md` 写明可以用文件夹同步工具（Syncthing、iCloud 云盘、坚果云等）指向 `~/rapp/files`。第二版再考虑用 rapp 自己的传输通道 | 用户：二进制用其他方式同步。先不重复造一个同步工具 | 第一版要用户自己配同步工具 |
| D9 | 收发的文件从 `~/Downloads/rapp` 改到 `~/rapp/files/transfers/`（A 收到的上传、B 下载的都在这）。`RAPP_DOWNLOADS` 仍可改 | 用户：传输的文件也放这里 | A 前的人要换个地方找上传的文件 |
| D10 | 日志不动：仍在 `~/Library/Logs/rapp`（Linux `$XDG_STATE_HOME/rapp`）；设了 `RAPP_HOME` 时在 `$RAPP_HOME/local/logs` | 日志是本机的、量大、给系统工具看；不该进 git，也不必同步 | 不在同一个目录（README 里写了在哪） |
| D12 | **根目录用户可以改**（用户 2026-11-13：「用户可以修改这个目录的根目录」）。找根目录的顺序：环境变量 `RAPP_HOME` → 指针文件 `<旧配置目录>/data-root`（一行，绝对路径）→ `~/rapp`。GUI 设置页「数据目录」一节有「更改位置…」：选一个文件夹 → 新位置是空的或不存在，就把当前根目录的内容复制过去（旧的原样留着）；新位置里已经有 rapp 的 `README.md`（比如别的设备同步过来的），就直接用它、不复制 → 写指针文件 → 重启 rapp-service（GUI 提示「数据目录已改到 〈路径〉，服务已重启」）。改回默认 = 删掉指针文件，走同样的流程 | 指针文件必须在根目录外面，放在旧配置目录里，固定、每台都有 | 改位置时会重启服务，正在连着的会话会断一次 |
| D11 | 搬家只复制不删：新版本第一次启动，`local/service.json` 不在而旧配置目录里有，就把旧文件按 §2 复制过来，写 `local/migrated-from`（内容是旧目录路径）。旧目录原样留着；`~/Downloads/rapp` 里已有的文件不搬 | 不能弄丢用户的配置；复制是可逆的 | 旧目录多占一点空间，用户确认没问题后可自己删 |

## 1. 目录

```
~/rapp/
  README.md            rapp 写：这个目录里各是什么、哪些进 git、二进制怎么同步（给人和 agent 看）
  .gitignore           rapp 写：files/  local/
  shared/              所有设备共用（进 git）
    apps.json            我的 app 配置（原 <GUI 配置目录>/apps.json）
    workspace.json       项目和常用（原 workspace.json）
  devices/<设备id>/    每台设备一份，只由这台设备写（进 git）
    device.json          {"id","name","os","version"}：给别的设备和 agent 看这台是什么。没有口令和地址
    gui.json             这台的界面偏好（原 gui.json）
  agent/               agent 上下文（进 git）。rapp 只建目录和 agent/README.md（指向配置规范），里面的内容归用户和 agent
  clipboard/           钉住的文字条目，一条一个 <时间>-<短标题>.md（进 git）
  files/               二进制，不进 git
    transfers/           收发的文件（D9）
    clipboard/           钉住的图片和文件
  local/               本机私有，不进 git，0700
    service.json  hosts.json  update.json  update-applied.json  sync.json  permission-guide-shown
```

- `sync.json`（程序自管）：上次提交、上次同步的时间，最近一次同步出错的原因（不含远端地址里的口令）。
- 短标题：条目的前 20 个字，去掉换行和路径符号；空的写「文字」。
- `agent/` 以外的内容由 rapp 写；用户和 agent 也可以手改 `shared/` 和自己设备的 `devices/<id>/`（格式见配置规范）。

## 2. 旧位置 → 新位置（D11 的复制表）

| 旧 | 新 |
|---|---|
| `<旧配置目录>/service.json`、`hosts.json`、`update.json`、`update-applied.json` | `local/` 同名 |
| `<旧 GUI 配置目录>/workspace.json`、`apps.json` | `shared/` 同名 |
| `<旧 GUI 配置目录>/gui.json` | `devices/<id>/gui.json` |
| `<旧 GUI 配置目录>/permission-guide-shown` | `local/permission-guide-shown` |

旧配置目录：macOS `~/Library/Application Support/rapp`，Linux `$XDG_CONFIG_HOME/rapp`（默认 `~/.config/rapp`），Windows `%APPDATA%\rapp`。`~/Library/Caches/rapp/update`（升级缓存）不动。

## 3. 谁做什么

- **路径**：Rust `rapp_net::config` 和 Dart `paths.dart` 各有一份同样的规则（根、`local()`、`shared()`、`device(id)`、`files()`），Swift 的上传目录跟 `RAPP_DOWNLOADS` → `RAPP_HOME/files/transfers` → `~/rapp/files/transfers`。
- **建目录和搬家**：谁先启动谁做（service、hub、GUI 都调同一段逻辑，幂等）；`README.md`、`.gitignore`、`agent/README.md` 不存在才写。
- **git**：只有 rapp-service 做（D6、D7）；GUI 设置页「数据目录」一节显示路径、「打开数据目录」按钮、git 状态（没装 git / 只在本机 / 已同步 HH:MM / 同步有冲突）。
- **剪贴板钉住**：GUI 的「资源」里钉住时写 `clipboard/` 或 `files/clipboard/`；取消钉住删文件。启动时把 `clipboard/` 里的读回来当钉住的条目。

## 4. 不做

- 不替用户建远端仓库、不选远端、不存远端口令（git 自己的凭据管理负责）。
- 不同步 `files/`（D8，第一版）。
- 不把没钉住的剪贴板写盘；日志里不记条目内容和标题（可观测性规格不变）。

## 5. 测试

全部在临时 `RAPP_HOME` 下：路径规则（三个系统）、搬家只复制且幂等、`.gitignore` 生效（`local/`、`files/` 下的文件不出现在 `git status`）、60 秒合并提交、没有 git 时不报错、有 remote 时 pull/push 走一遍（用临时目录里的裸仓库当 remote）、冲突时停同步并留状态、钉住/取消钉住写删文件。
