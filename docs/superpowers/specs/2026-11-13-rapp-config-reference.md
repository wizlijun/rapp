# rapp：配置规范总览（给 agent 自动改配置用）

日期：2026-11-13。状态：**现行**（用户 2026-11-13：「系统中所有类似个性化配置的地方，都作成文档规格现行，为 agent 自动做而友好。」）

这份是 rapp 所有可配置处的**唯一清单**：文件、环境变量、命令行参数。每一处写明：在哪、谁读、字段和取值、谁来改、改完怎么生效、有没有机密。agent 要改 rapp 的任何配置，先查这里；查不到的就是不该改的。

- 每个字段的来历以代码为准，表里给了代码位置。代码改了字段，**同一个提交里**改这份文档（§9）。
- 某一类配置有自己的编写规范时，这里只给入口，细则看那份：app 配置 → 《app 配置编写规范》（`2026-11-13-rapp-app-profile-authoring.md`）。

## 0. agent 改配置的通用规则

1. **先分清能不能改。** 每个文件标了「谁来改」：
   - **GUI**：优先让用户在 GUI 里改；agent 要改，就用 GUI 背后的同一条路（IPC 或 hub 命令），不直接写文件。
   - **手改**：agent 可以直接改文件，按 §0.3 的步骤。
   - **程序自管**：程序自己写的状态，**不要改**，只能读来排查问题。
2. **机密字段不打印、不编、不外传。** 标了「机密」的字段（口令、密钥、token、哈希），agent 读文件时不把值写进输出、日志、提交、对话；要新值时让程序生成，或者让用户自己填。这类字段的取值规则照写在表里，值不写。
3. **手改文件的步骤：**
   1. 先停掉读写这个文件的程序（表里的「谁读」），否则它下次保存会盖掉你的改动；
   2. 先备份成 `<文件>.bak`；
   3. 只改要改的字段，其余原样保留（未知字段也保留）；
   4. 用 `python3 -m json.tool <文件> >/dev/null` 确认 JSON 能解析；
   5. 权限保持 `0600`（`chmod 600`）；
   6. 再启动那个程序，看日志里没有报错。
4. **数据根目录**（下称 `$ROOT`，规格《数据目录》）：所有 rapp 数据都在这一个目录下。找法按顺序：环境变量 `RAPP_HOME` → 指针文件 `<旧配置目录>/data-root`（一行绝对路径）→ `~/rapp`（Windows `%USERPROFILE%\rapp`）。代码：`rust/net/src/config.rs:23-38`、`gui/lib/paths.dart:50-56`、`Sources/RappCore/DataPaths.swift:3-9`。
   - **旧配置目录**：macOS `~/Library/Application Support/rapp`，Linux `$XDG_CONFIG_HOME/rapp`（默认 `~/.config/rapp`），Windows `%APPDATA%\rapp`（`rust/net/src/config.rs:50-63`）。现在只用来放 `data-root` 指针，和作搬家的来源（只复制，旧文件原样留着）。
   - **目录树**：

     ```
     $ROOT/
       README.md  .gitignore
       shared/            所有设备共用（进 git）：apps.json  workspace.json
       devices/<id>/      每台设备一份，只由这台设备写（进 git）：device.json  gui.json
       agent/             用户和 agent 的内容（进 git），rapp 不动
       clipboard/         钉住的文字条目，一条一个 .md（进 git）
       files/             二进制，不进 git：transfers/（收发的文件）  clipboard/（钉住的图片和文件）
       local/             本机私有，不进 git，0700：service.json  hosts.json  ipc.token  update.json  ……（§3）
     ```
   - **进 git 的**：`shared/`、`devices/`、`agent/`、`clipboard/`、`README.md`、`.gitignore`。**不进 git 的**：`files/`、`local/`（写在 `.gitignore` 里）。rapp-service 在改动后 60 秒内合成一次提交（`rust/service/src/data.rs:41`）。
   - **机密只在 `local/`**。`shared/`、`devices/`、`agent/`、`clipboard/` 里不写口令、key、secret、token；agent 往这些目录写东西时也一样。
   - 路径函数：Rust `local`/`shared`/`device`/`files`（`rust/net/src/config.rs:79-93`），Dart `DataDir`（`gui/lib/paths.dart:60-72`）。
   - 文件先写临时文件再改名；机密文件权限 `0600`。
5. **试验用临时目录。** 在自己机器上验证配置时，设 `RAPP_HOME=<临时目录>`（它优先于指针，所有数据都落在那里），不碰用户真实的 `~/rapp` 和旧配置目录。设了 `RAPP_HOME` 后日志在 `$RAPP_HOME/local/logs`，不用另设。

## 1. 一览

| 文件 / 设置 | 在哪一侧 | 谁来改 | 机密 | 细则 |
|---|---|---|---|---|
| `$ROOT/local/service.json` | A（B 上的 hub 也读其中 relay/key） | GUI + 手改（部分字段） | 有 | §2.1 |
| `$ROOT/local/hosts.json` | B | GUI（经 hub） | 有 | §2.2 |
| `$ROOT/shared/workspace.json` | B | GUI，可手改 | 无 | §2.3 |
| `$ROOT/devices/<id>/gui.json` | B | GUI，可手改 | 无 | §2.4 |
| `$ROOT/shared/apps.json` | B | GUI，可手改 | 无 | §2.5 |
| `$ROOT/devices/<id>/device.json` | A / B | 程序自管（rapp-service 写，没有机密） | 无 | §2.6 |
| `<旧配置目录>/data-root` | A / B | GUI「更改位置…」写，可手改 | 无 | §2.7 |
| `$ROOT/clipboard/`、`$ROOT/files/clipboard/` | B | GUI 写，可手删 | 无（用户钉住的内容可能含私事） | §2.8 |
| `$ROOT/agent/` | — | 用户和 agent，rapp 不动 | 不放机密 | §2.9 |
| 程序自管的状态（`$ROOT/local/` 等） | A / B | 程序自管 | 部分有 | §3 |
| macOS 开机自启 | A | 安装包 / GUI | 无 | §4 |
| 中继（VPS） | relay | 运维手改 | 有 | §5 |
| 环境变量 | 各侧 | 启动方 | 部分有 | §6 |
| 命令行参数 | 各程序 | 启动方 | 部分有 | §7 |
| 打包发布 | 构建机 | 发布脚本 | 有（签名身份） | §8 |

## 2. 用户可以改的配置

### 2.1 `$ROOT/local/service.json`（A 的主配置）

谁读：`rapp-service`，启动时读一次（`rust/service/src/config.rs:44`）；B 上的 `rapp-hub` 读其中的 `relay` 和 `key`（`rust/hub/src/lib.rs:72`）。第一次启动时自动补齐 `id`、`secret`、`password`、`name`。机密只在 `local/`，权限 `0600`，不进 git。旧版的 `service.json` 在旧配置目录里，第一次启动时复制过来（旧的留着）。

| 字段 | 类型 | 没写时 | 取值 | 谁改 | 机密 |
|---|---|---|---|---|---|
| `relay` | 字符串 | 不用中继 | 中继地址 `主机:端口`（端口一般 21116） | GUI（IPC `set_relay`） | |
| `key` | 字符串 | 无 | 和中继的 `--key` 一致 | GUI（IPC `set_relay`） | **机密** |
| `id` | 字符串 | 随机 9 位数字 | 9 位数字；改了就是另一台设备 | 不改 | |
| `secret` | 字符串 | 随机 32 位十六进制 | 设备在中继上的身份凭据 | 不改 | **机密** |
| `name` | 字符串 | 本机主机名 | 给人看的设备名 | 手改 | |
| `password` | 字符串 | 随机 | 连这台 A 用的口令（明文存放，GUI 要显示，规格 D8） | GUI（IPC `set_password`） | **机密** |
| `port` | 整数 | 21118（UDP） | 1–65535 | 手改 | |
| `ipc_port` | 整数 | 21119（TCP，只听 127.0.0.1） | 1–65535；改了 GUI 要能找到它 | 手改 | |
| `update_url` | 字符串 | 内置的 `latest.json` 地址 | 只收 `https://` | 手改 | |
| `auto_update` | 布尔 | `true` | 没人用时自己装新版 | GUI（IPC `set_update`） | |
| `check_updates` | 布尔 | `true` | 定时检查更新 | GUI（IPC `set_update`） | |

生效：手改后要重启 `rapp-service`。macOS：`launchctl kickstart -k gui/$(id -u)/com.rapp.service`（这会断开正在连着的会话，先问用户）。agent 改 `shared/` 和自己设备的 `devices/<id>/` 里的文件时，注意 rapp-service 一分钟内会把改动提交进 git。

### 2.2 `$ROOT/local/hosts.json`（B 存下的 A 列表）

谁读写：`rapp-hub`（`rust/hub/src/hosts.rs:24`），GUI 通过 hub 的 `add_host`、`remove_host` 改（`rust/hub/src/lib.rs:174-203`）。

格式：数组，每项 `{"id": 字符串, "name": 字符串, "password": 字符串, "lan": [字符串]}`。`lan` 是 A 的局域网地址 `ip:端口`，没有时是 `[]`。没有中继时，在 GUI 里用 `id@ip` 的形式添加 A，hub 会把地址记进 `lan`。

| 字段 | 机密 |
|---|---|
| `password` | **机密**（明文，规格 D8） |

agent 规则：**不直接改这个文件**。加、删设备走 GUI 的设备页或 hub 的 `add_host` / `remove_host`；口令由用户自己填。

### 2.3 `$ROOT/shared/workspace.json`（常用和项目）

谁读写：GUI，启动时读（`gui/lib/ui/workspace_store.dart:107`），每次改动都写（`:125`）。在 `shared/` 里，各设备共用，进 git。读不出来时改名为 `workspace.json.bad`，从空白开始，提示「项目和常用没有读到，已从空白开始」。

```json
{
  "version": 1,
  "favorites": [{"device": "123456789", "bundle": "com.apple.Terminal", "name": "终端"}],
  "projects": [{"id": "p1", "name": "rapp", "members": [
    {"device": "123456789", "bundle": "com.apple.Terminal", "name": "终端", "task": "跑测试"}]}]
}
```

| 字段 | 含义 |
|---|---|
| `device` | A 的设备 id（9 位数字，同 `service.json` 的 `id`） |
| `bundle` | app 标识（macOS bundle id / Windows exe / Omarchy class） |
| `name` | 存下时 app 的显示名 |
| `task` | 用户自己写的任务名，可以空 |

生效：先退出 GUI 再手改，改完重新打开。没有机密。旧位置是旧 GUI 配置目录，会被复制过来。

### 2.4 `$ROOT/devices/<id>/gui.json`（界面偏好）

谁读写：GUI（`gui/lib/ui/prefs.dart:14,33`）。每台设备一份，`<id>` 是这台的设备 id（`local/service.json` 的 `id`）；还不知道 id 时不保存改动（`gui/lib/ui/main_state.dart:1101`），启动时从 `local/gui.json` 读（有的话，`gui/lib/main.dart:64`）。

| 字段 | 取值 | 没写时 |
|---|---|---|
| `theme` | `matrix`、`ironMan`、`westworld`、`avatar` | `matrix` |
| `start_fullscreen` | 布尔：启动时全屏沉浸 | `true` |

生效：退出 GUI 再改，重新打开生效。没有机密。

### 2.5 `$ROOT/shared/apps.json`（我的 app 配置）

格式和取值见《app 配置设计》§2，怎么写见《app 配置编写规范》。内置的一份在 `gui/assets/app_profiles.json`（随 GUI 发布，只在仓库里改）。没有机密。

（状态：设计已确认，代码在 `feat/app-profiles` 上实施中；实施完成时把代码位置补进这一节。）

### 2.6 `$ROOT/devices/<id>/device.json`（这台设备是什么）

程序自管，**不要改**，只读。rapp-service 写（`rust/service/src/data.rs:372-382`），内容 `{"id","name","os","version"}`，给别的设备和 agent 看这台是什么。没有口令和地址，没有机密。内容没变就不重写。

### 2.7 `<旧配置目录>/data-root`（数据根目录指针）

一行绝对路径，指向 `$ROOT`。GUI 设置页「数据目录」的「更改位置…」写它（`gui/lib/data_relocate.dart:37-62`），「改回默认」删它；读它的代码见 §0.4。手改也行：只写一行绝对路径（不是绝对路径就当没有）。`RAPP_HOME` 设了就优先于它。改完要重启 `rapp-service`（先问用户）。它必须在 `$ROOT` 外面，所以放在旧配置目录里。没有机密。

### 2.8 `$ROOT/clipboard/` 和 `$ROOT/files/clipboard/`（钉住的剪贴板）

只有用户在 GUI 里「钉住」的条目才写盘，没钉住的只在内存里。文字：`clipboard/<时间>-<短标题>.md`，一条一个，进 git；图片和文件：`files/clipboard/`，不进 git。GUI 启动时读回来（`gui/lib/ui/pin_files.dart:37`），取消钉住就删这条的文件（`:77`）。agent 手删文件 = 取消钉住，下次 GUI 启动时生效；git 历史里还留着。不要往里写机密，不要把内容或标题抄进日志。

### 2.9 `$ROOT/agent/`（agent 的上下文）

用户和 agent 的目录，进 git，rapp 只建目录和 `agent/README.md`（指向这份文档），里面的内容不动。agent 可以在这里放自己的笔记和上下文，但不放机密。

## 3. 程序自管的状态（不要改）

| 文件 | 在哪 | 是什么 | 机密 |
|---|---|---|---|
| `$ROOT/local/ipc.token` | A、B | GUI 连本机 service 用的 token，每次启动重新生成（`rust/service/src/lib.rs:105`） | **机密** |
| `$ROOT/local/update.json` | A | 最近查到的版本、上次检查时间、用户按过「不装」的版本（`rust/service/src/update.rs:133`）。「不装」走 IPC `update_dismiss` | |
| `$ROOT/local/update-applied.json` | A | 上次升级的记录，用于回滚和授权提示（`rust/update/src/apply.rs:10`） | |
| `$ROOT/local/previous/` | A | 升级前的旧版，用于回滚（`rust/service/src/update.rs:136`） | |
| `$ROOT/local/last-dr` | A | 上次运行时的签名要求（一个字符串），升级时对照用（`rust/service/src/update.rs:242`） | |
| `$ROOT/local/sync.json` | A | rapp-service 写的 git 状态：`git`（`missing`、`local`、`synced`、`conflict`、`error`）、`last_commit`、`last_sync`、`error`（不含远端地址里的口令）；GUI 读（`rust/service/src/data.rs:49-55`） | |
| `$ROOT/local/migrated-from` | A、B | 搬家时写的旧目录路径，只是记录（`rust/net/src/datadir.rs:12`） | |
| `$ROOT/local/pin-hint-shown` | B | 「钉住会进 git 历史」的提示已经显示过的标记，没有内容（`gui/lib/ui/pin_files.dart:10`）。删掉它，下次钉住时会再提示 | |
| `~/Library/Caches/rapp/update` | A（macOS） | 升级包下载缓存 | |
| `$ROOT/local/permission-guide-shown` | A | 授权引导已经显示过的标记，没有内容（`gui/lib/pages/permissions_panel.dart:140`）。删掉它，下次启动会再引导一次 | |
| 日志 `service.log`、`hub.log`、`launchd.log` | A、B | 目录：`RAPP_LOG_DIR`，否则设了 `RAPP_HOME` 时 `$RAPP_HOME/local/logs`，否则 macOS `~/Library/Logs/rapp`、Linux `$XDG_STATE_HOME/rapp`（`rust/net/src/log.rs:236`）。日志不跟着指针搬，不进 git。内容规则见可观测性规格：不记口令、token、剪贴板和打字内容 | |

## 4. macOS 开机自启：`~/Library/LaunchAgents/com.rapp.service.plist`

两处会写：安装包（`scripts/pkg/postinstall`）和 GUI（`gui/lib/service_control.dart:76`，app 挪了位置时重写）。内容：Label `com.rapp.service`；运行 `rapp-service`；日志到 `launchd.log`；`RunAtLoad`、`KeepAlive` 都是 `true`。GUI 写的版本在设了 `RAPP_HOME` 时会把它带进去。

agent 规则：不手改；要换启动参数就改上面两处模板，**两处一起改**。

## 5. 中继（VPS）

| 东西 | 位置 | 内容 | 机密 |
|---|---|---|---|
| systemd 单元 | `/etc/systemd/system/rapp-relay.service`（模板 `scripts/rapp-relay.service`） | 从 `/etc/rapp-relay.env` 读 `RAPP_RELAY_KEY`；运行 `rapp-relay --key ${RAPP_RELAY_KEY} --listen 0.0.0.0:21116 --db /var/lib/rapp-relay/relay.json`；`DynamicUser`；总是重启 | |
| `/etc/rapp-relay.env` | VPS | 一行 `RAPP_RELAY_KEY=…`，和各设备 `service.json` 的 `key` 一致 | **机密** |
| `relay.json` | `/var/lib/rapp-relay/` | 中继自管：每个设备 id 的 `secret_hash`、`pw_salt`、`pw_hash`、`name`（`rust/relay/src/db.rs`）。不要改 | **机密**（哈希） |

中继是唯一的门禁（规格 D8），改它前先问用户；登录 VPS 也要用户同意。升级中继用 `scripts/upgrade-relay.sh`。改 key 后，所有设备的 `key` 都要跟着改，否则都连不上。

## 6. 环境变量

| 变量 | 哪一侧 | 含义 | 没设时 | 机密 |
|---|---|---|---|---|
| `RAPP_HOME` | A、B、GUI | 数据根目录 `$ROOT`，优先于指针文件（`rust/net/src/config.rs:30`） | 指针文件，再 `~/rapp`（§0.4） | |
| `RAPP_LOG_DIR` | A、B、GUI | 日志目录 | 见 §3 日志 | |
| `RAPP_BIN_DIR` | A、B、GUI | 辅助程序（rapp-host、rapp-client 等）所在目录 | 当前程序所在目录，再找 PATH | |
| `RAPP_GUI` | A | `--cm` 连接窗口用的 GUI 路径 | 无 | |
| `RAPP_FORCE_PATH` | B | 强制走 `relay`、`direct` 或 `lan` | 自动选 | |
| `RAPP_DOWNLOADS` | A、B（A：`rapp-host` 收上传；B：GUI 嵌入会话下载，`gui/macos/Runner/SessionPlugin.swift:47`） | 收发文件的目录（`Sources/RappCore/DataPaths.swift:18-21`） | `$ROOT/files/transfers`（旧版是 `~/Downloads/rapp`，那里的文件不会搬） | |
| `RAPP_TOKEN` | 内部 | service / hub 传给子进程的会话 token，不要自己设 | — | **机密** |
| `RAPP_RELAY_KEY` | VPS | 中继密钥，见 §5 | — | **机密** |

## 7. 命令行参数

| 程序 | 参数 | 谁来传 |
|---|---|---|
| `rapp-relay` | `--key`（必填，机密）、`--listen`（默认 `0.0.0.0:21116`）、`--db`（默认 `relay.json`）、`--debug`、`--version` | systemd 单元（§5） |
| `rapp-service`、`rapp-hub` | 不收参数（给了就以退出码 2 退出）；只看 §6 的环境变量 | launchd / GUI |
| `rapp-host` | `serve --app <标识> --token-env <变量> --port <端口>（默认 47800，0=随机）--bind <地址> --json`；`list-apps`；`check [--prompt]`；`version [--json]` | rapp-service（`Sources/RappCore/WorkerCLI.swift:97`） |
| `rapp-client`（Swift、GTK） | `[connect] rapp://… [--token-env <变量>] [--json]`；`version [--json]` | rapp-hub |
| `rapp-session` | 不收参数，从标准输入读 JSON 命令 | GUI |

agent 规则：`rapp-host`、`rapp-client`、`rapp-session` 是由上面的程序拉起的，一般不用手动跑；测试时只用自己起的实例，端口用临时端口，不用 47800、21116–21119。

## 8. 打包发布（构建机）

| 设置 | 含义 | 机密 |
|---|---|---|
| `RAPP_SIGN_APP` | 给 app 签名的身份名 | 身份名本身不是机密；签名用的私钥在钥匙串里，不导出 |
| `RAPP_SIGN_PKG` | 给 pkg 签名的身份名 | 同上 |
| `RAPP_NOTARY_PROFILE` | 公证用的钥匙串配置名，默认 `rapp-notary` | 同上 |
| `RAPP_ALLOW_ADHOC` | 允许不签名（ad-hoc）打包 | |
| `RAPP_RELEASE_BASE` | `latest.json` 里下载地址的前缀 | |
| `RAPP_RELEASE_NOTES` | 写进 `latest.json` 的更新说明 | |
| `RAPP_VERSION`（Linux `--dart-define`） | 版本标签，默认「开发版」 | |

`dist/latest.json`（升级清单，`scripts/package-macos.sh` 生成）：`version`（必填）、`published_at`、`notes`、`assets["macos-arm64"] = {url（只收 https）, sha256（64 位十六进制）, size（大于 0）}`。由脚本生成，不手写。

测试专用的变量（`RAPP_E2E_BUNDLE`、`RAPP_FIXTURE_TOKEN`、`RAPP_BENCH_*`）只在 `scripts/*.py` 里用，不算配置。

## 9. 维护这份文档

- 加、改、删任何配置文件的字段、环境变量、命令行参数时，在**同一个提交**里改这份文档对应的表；代码评审时没改文档算没做完。
- 新加一类用户会改的配置（像 app 配置这样），除了在这里登记一行，还要写一份它自己的编写规范：值不值得配、取值怎么选、格式、例子、自查表——照《app 配置编写规范》的写法。
- 表里的代码位置写到文件和行号；行号漂了就顺手更新。
