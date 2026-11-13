# rapp 在线升级与权限保持 — 设计稿 v1

> 日期：2026-11-12。来源：用户要求（高优先级）：「参考 codex 官方代码的升级包机制，生成一个轻量级的在线升级模块……服务端升级后要重启，还需要优化权限部分。目前需要删掉之前的安全设置再重新设置很麻烦。」
> 状态：已确认（用户 2026-11-12：「请全部按推荐」）。§2 三条均按推荐：2.1 公开仓库 `wizlijun/rapp-releases`；2.2 Apple Development: bruce lee (M753G3H4R8)；2.3 自动下载、没人在用时自动安装。
>
> 修订（2026-11-13，用户：「请不要额外开仓库，把版本更新的信息放在 rapp 的仓库中。使用对应分发中的下载连接。」）：不建 `rapp-releases`。`latest.json`、升级 zip 和 pkg 都传到 `wizlijun/rapp`（已公开）对应版本的 Release；检查地址是 `https://github.com/wizlijun/rapp/releases/latest/download/latest.json`，zip 用同一个 Release 的下载链接。下文的 `rapp-releases` 都按此读。注意：GitHub 的「latest」是最新的正式 Release，所以每个正式 Release 都要带 `latest.json`，否则 Mac 上会看到「最新的 Release 里没有 latest.json（404）」。

## 0 现状（实测）

- **安装**：rapp-0.4.x.pkg 把 rapp.app 装到 `/Applications`，归属 `root:wheel`。postinstall 给登录用户写 LaunchAgent `com.rapp.service`（`KeepAlive=true`、`RunAtLoad=true`）并启动。升级只能手动下载 pkg、双击安装。
- **签名**：`scripts/package-macos.sh` 找不到 Developer ID 证书时用 ad-hoc（`codesign -s -`）。已装的 0.4.1 实测：
  - `codesign -d -r- /Applications/rapp.app` → `designated => cdhash H"dee3c9…"`
  - `Signature=adhoc`，`TeamIdentifier=not set`
- **权限为什么每次都要删了重加**：macOS 的隐私授权（屏幕录制、辅助功能）记的是 app 的「指定要求」（designated requirement）。ad-hoc 签名的指定要求就是 cdhash，每次构建都不一样。所以装了新版以后，系统设置里的「rapp」开关看着还开着，其实对新版不生效，只能先点「−」删掉、再重新加。**这和升级方式无关，换任何升级方式都会这样，要从签名上改。**
- **Codex 的做法**（openai/codex `codex-rs/tui/src/updates.rs`、`update_action.rs`）：
  - 启动时读缓存 `version.json`：`latest_version`、`last_checked_at`、`dismissed_version`。缓存超过 20 小时就在后台刷新一次，不挡启动；这次运行先用旧缓存，新结果下次才显示。
  - 版本来源：GitHub `releases/latest` 的 `tag_name`，或 brew/npm 的源。`is_newer` 解析失败当作「不是更新」；源码构建和 debug 构建不检查。
  - 只屏蔽用户点过「忽略」的那一个版本，更新的版本出来照样提示。
  - 配置 `check_for_update_on_startup=false` 可以关掉。
  - 真正的升级由 `UpdateAction` 按安装方式选命令（npm/brew/独立安装脚本），在 TUI 退出后执行。
- **rapp 照搬的部分**：缓存三字段、20 小时、后台检查、只忽略单个版本、可关闭、开发构建不检查。**rapp 的不同**：没有包管理器，rapp-service 常驻，所以下载、安装、重启都由 service 自己做，不另起安装器。

## 1 目标与不做

**目标**
1. 装好一次以后，升级不用再碰 pkg：有新版时自动下载；A 没人在用时自动装好并重启服务；有人在用时，只在 GUI 里安静地显示「有新版本」和「立即升级」。
2. 升级以后屏幕录制、辅助功能**保持有效**，不用再删了重加。
3. 万一授权记录坏了，GUI 里一个按钮就能把 rapp 自己的授权记录清掉重来，不用进系统设置找「−」。
4. 升级以后服务一定重启，跑的是新版本。

**不做（v1）**
- Windows、Omarchy 主机自动升级（manifest 里给它们留了位置）。
- 从 B 远程让 A 升级（v2：A 在 `list_apps` 里报版本，B 上显示「A 有新版本」）。
- 增量包、多渠道（beta）、自动回滚。
- 在 sha256 和签名比对之外再加一层签名体系（D8：门禁只在 relay；见 §9 的说明）。
- rapp-relay 自升级。v1 只给一个手动执行的升级脚本（§6）。

## 2 三个决定（已按推荐确认）

### 2.1 新版本放在哪 —— 推荐：单独一个公开的 `wizlijun/rapp-releases` 仓库，只放发布文件

- `wizlijun/rapp` 是私有仓库，别的电脑没有登录 GitHub 就读不到它的 release。把 token 写进 app 不行，谁拿到 app 谁就能读私有仓库。
- 推荐：新建一个公开仓库，只放 release，代码仍在私有仓库。用 GitHub 的下载地址，不用自己搭服务器，`gh release create` 照旧。代价是安装包公开可下。
- 备选：
  - B. 放在你的 VPS 上，用 caddy/nginx 做静态文件（`https://<vps>/rapp/latest.json`）。安装包不公开，但要多维护一个 HTTPS 站点。
  - C. 把 `wizlijun/rapp` 改成公开。
- 不管选哪种，地址都写在 service 配置 `update_url` 里，以后能改。

### 2.2 用哪个证书签名 —— 推荐：先用钥匙串里已有的「Apple Development: bruce lee (M753G3H4R8)」

- 只要每一版都用同一个证书签，指定要求就不变，授权一直有效。这是解决「删了重加」的关键。
- Apple Development 证书的指定要求按证书名和 Apple 的中间证书来定，证书每年续期、名字不变，所以续期不影响授权。
- 代价：跟 ad-hoc 一样，没有公证。别的 Mac 第一次装 pkg 还是要右键打开；之后的自动升级不经过浏览器下载，不会被 Gatekeeper 拦。第一次签名时钥匙串会问是否允许 codesign 使用这个证书，点「始终允许」。
- 备选：
  - B. 在 Wuhan Fulin（T5G56DH47L）账号里申请 Developer ID Application 证书。可以公证，首次安装也不用右键。打包脚本已经支持，只要证书进钥匙串。
  - C. 自建一个自签名代码签名证书，换电脑打包时要带上它的私钥。
- 以后要是从 A 换成 B，指定要求会变一次，要重新授权一次，用 §3.2 的「重置授权记录」按钮就行。

### 2.3 自动安装的时机 —— 推荐：自动下载；没人在用时自动安装

- 「没人在用」= 这台电脑上没有进行中的会话（A 侧），并且 rapp.app 里除了 rapp-service 以外没有别的进程在跑（GUI、hub、client、host）。
- 不满足时只在 GUI 里提示，等你点「立即升级」。
- 设置里有「自动升级」开关，默认开；关掉以后就和 Codex 一样，只提示不安装。
- 备选：只提示，永远手动点。

## 3 权限：升级后保持有效

### 3.1 稳定签名（`scripts/package-macos.sh`）

- 签名身份的查找顺序：
  1. `RAPP_SIGN_APP`
  2. Developer ID Application
  3. Apple Development（§2.2 推荐）
  4. ad-hoc
- 都按 SHA-1 选，沿用现有 `identity()`。
- 每个可执行文件都给固定标识：`-i com.rapp.service`、`com.rapp.hub`、`com.rapp.host`、`com.rapp.client`；app 本身仍是 `com.rapp.rapp`。
- 只有 Developer ID 才加 `--options runtime` 和 `--timestamp`。Apple Development 不加，免得把 Flutter 引擎和库校验搞复杂。
- 发布检查：脚本最后打印 `codesign -d -r-` 的结果。发布构建如果还是 cdhash 形式的指定要求，就直接失败，除非设了 `RAPP_ALLOW_ADHOC=1`（本地调试用）。
- pkg 的 postinstall 加一步 `chown -R <登录用户>:staff /Applications/rapp.app`，之后的自动升级不用管理员密码就能替换它。拖进「应用程序」的 app 本来就归用户所有，这里只是对齐。

### 3.2 一键重置 rapp 的授权记录（GUI · 本机 › 权限）

- 新增 IPC `{"cmd":"permissions_reset"}`，rapp-service 执行：
  - `tccutil reset ScreenCapture com.rapp.rapp`
  - `tccutil reset Accessibility com.rapp.rapp`
  - 然后照现有流程跑 `rapp-host check --prompt --json`，让系统重新弹出授权请求，并把 rapp 重新登记进系统设置。
- **只动 rapp 自己的 bundle id**，不碰别的 app 的授权。
- `PermissionsPanel` 每个 ✗ 行下面加一行小字按钮：「设置里已经打开了还是 ✗？重置授权记录」。它是 `ConfirmButton`，点两下生效，因为重置后两项权限都要重新打开。
- 重置以后流程和第一次授权一样：「打开系统设置」→ 打开开关 → 3 秒轮询自动变成 ✓（现有逻辑）。

### 3.3 迁移（只发生一次）

- 第一个用稳定证书签名的版本，签名会从 cdhash 变成证书形式，旧授权记录这一次一定失效。
- service 在升级后第一次启动时，如果发现「升级前两项 ✓，升级后变 ✗」，就在 `status` 里置 `permissions_lost_after_update=true`。GUI 看到后再弹一次首次引导，不管 `permission-guide-shown` 标记。引导里直接给「重置授权记录」和「打开系统设置」。
- 之后的升级签名不变，不会再出现这种情况。§4.3 的签名比对保证了这一点。

## 4 升级模块

### 4.1 放在哪

- 新 Rust crate `rust/update`（包名 `rapp-update`），只放能单测的纯逻辑：
  - manifest 解析、版本比较、缓存读写、「该不该检查」；
  - 下载（调 `/usr/bin/curl`）、校验（sha256、`codesign`）、解包（`/usr/bin/ditto`）、替换 bundle。
  - 所有外部命令都通过一个可注入的 `Runner` 调用，测试时用假的。
- `rust/service/src/update.rs`：在 service 里挂定时器、实现 IPC 命令、判断「没人在用」、写访问日志、触发重启。
- 不引入 HTTP 库。macOS 自带 curl，支持 HTTPS 和断点续传（`-C -`），二进制不会变大。Codex 的独立安装方式同样用 curl。
- GUI：`gui/lib/update.dart` 放状态模型和文案纯函数；界面放在 本机 › 版本与升级。

### 4.2 manifest（`latest.json`，和安装包放在同一个地方）

```json
{
  "version": "0.5.0",
  "published_at": "2026-11-20T08:00:00Z",
  "notes": "一句话说明，GUI 原样显示",
  "assets": {
    "macos-arm64": {
      "url": "https://github.com/wizlijun/rapp-releases/releases/download/v0.5.0/rapp-0.5.0-macos-arm64.zip",
      "sha256": "…64 位十六进制…",
      "size": 31457280
    }
  }
}
```

- 不认识的字段忽略，没有本平台的 key 就当没有更新。
- 用 manifest，不直接读 GitHub API：2.1 的三种放法都适用，也不受 GitHub API 匿名限流（每小时 60 次）影响。

### 4.3 流程

**① 检查**（照搬 Codex）
- 什么时候检查：
  - service 启动 30 秒后检查一次；
  - 之后每小时看一次缓存，`last_checked_at` 超过 20 小时才真去拉 manifest；
  - GUI 的「检查更新」按钮立即检查。
- 缓存：`<configDir>/update.json` = `{latest_version, last_checked_at, dismissed_version}`。拉取失败就不写缓存，只记日志。
- 版本比较：只比 `x.y.z`，解析失败当作「不是更新」。当前版本取自 bundle 的 `CFBundleShortVersionString`；不在 `.app` 里运行（开发构建）时整个模块不工作。
- 配置 `auto_update`（默认 true）和 `check_updates`（默认 true，等同 Codex 的 `check_for_update_on_startup`）。

**② 下载**
- 有新版且可用空间够（size × 3）时，下载到 `~/Library/Caches/rapp/update/rapp-<v>.zip.part`：
  - `curl -fL --retry 3 -C - -o …`，断了下次接着下；
  - 完成后核对 size 和 sha256，对上了才改名为 `.zip`。

**③ 校验**
- 用 `ditto -x -k` 解到 `~/Library/Caches/rapp/update/<v>/rapp.app`。
- `codesign --verify --deep --strict` 必须通过。
- 新 app 的指定要求（`codesign -d -r-`）必须和当前运行的 app **完全一样**。不一样就不自动装。GUI 显示：「这一版换了签名，装上以后要重新授权屏幕录制和辅助功能」，再加一个「仍然安装」按钮，走手动确认。授权会不会失效就是在这里把关的。
- 新 app 的 `CFBundleShortVersionString` 必须等于 manifest 的 version。

**④ 安装**（自动：满足 2.3 的「没人在用」；手动：GUI 点「立即升级」）
1. 手动时，GUI 先发 `update_apply`，然后自己退出。service 等这个 GUI 的 IPC 连接断开（最多 10 秒），再检查一次「没人在用」。
2. 把新 app 移到 `/Applications/.rapp-new.app`，和目标在同一目录、同一个卷，改名是原子的。
3. `rename(/Applications/rapp.app → ~/Library/Application Support/rapp/previous/rapp.app)`，跨目录改名失败时退回 `ditto` 复制再删除。然后 `rename(/Applications/.rapp-new.app → /Applications/rapp.app)`。第二步失败就把第一步移回去，并记 `update_failed`。
4. `/Applications/rapp.app` 不可写（还是 root 所有、或者当前用户不是管理员）时，不自动替换，GUI 提示「这次需要管理员密码」，并给「打开安装包」按钮：下载的不是 pkg，所以这一步改为打开 release 页面，让用户手动装 pkg。之后 §3.1 的 chown 会让下次不再需要。
5. 写 `<configDir>/update-applied.json` = `{from, to, at, gui_was_open}`。

**⑤ 重启（必须）**
- service 正常退出（退出码 0），launchd 的 `KeepAlive` 会从同一路径拉起，也就是新的 rapp-service。退出前先停掉自己起的空闲 rapp-host worker。
- 新 service 启动时读到 `update-applied.json`：
  - 记 `update_applied` 事件；
  - `gui_was_open` 为真时执行 `open /Applications/rapp.app` 重新打开 GUI；
  - 30 秒后如果还在正常运行，就删掉标记和缓存里的 zip。`previous/` 只保留上一版。
- 不是 launchd 拉起的 service（命令行直接运行）不自动安装，只提示。

**⑥ 回到上一版（v1 手动）**
- GUI 本机 › 版本与升级 有「回到上一版」（`ConfirmButton`），用 `previous/rapp.app` 走 ④⑤。
- 新版连 service 都起不来时，到 release 页面下载上一版 pkg 手动装。

### 4.4 IPC（新增，旧 GUI 不认识就忽略）

- `update_status` 返回 `{current, latest, state, progress?, error?, notes?, auto_update, needs_confirm?}`，其中 `state ∈ idle|checking|downloading|ready|installing|failed|up_to_date`。状态变了，订阅者会收到 `changed`（复用现有 `notify()`）。
- `update_check`、`update_apply {confirm_signature_change?: bool}`、`update_dismiss {version}`、`update_rollback`、`set_update {auto_update?, check_updates?}`。

## 5 GUI

- 本机 › 版本与升级 一行：
  - 平时：「当前 0.4.1 · 已是最新」，右边「检查更新」；
  - 下载中：「正在下载 0.5.0（45%）」；
  - 准备好：「0.5.0 已下载，没人在用时会自动装好」+「立即升级」+「这一版先不装」（= `dismiss`）。
  - 下面是「自动升级」开关和「回到上一版」。
- 外壳只在侧栏「本机」入口上放一个不闪的小点，不弹窗、不抢焦点。按设计语言 §0：升级不是「等你」级别的信息，只能待在边缘；装完小点自己消失。
- `permissions_lost_after_update` 和 §3.2 的重置按钮见 §3。

## 6 发布端

- `scripts/package-macos.sh` 额外输出：
  - `dist/rapp-<v>-macos-arm64.zip`（`ditto -c -k --keepParent rapp.app`）；
  - `dist/latest.json`：version、size、sha256 自动填，url 按 `RAPP_RELEASE_BASE` 拼，`notes` 取 `RAPP_RELEASE_NOTES`。
- 发布：
  - `gh release create v<v> --repo <2.1 定的位置> rapp-<v>.pkg rapp-<v>-macos-arm64.zip latest.json`。
  - manifest 地址固定为 `…/releases/latest/download/latest.json`。GitHub 会把它跳转到最新 release 的 `latest.json`，所以不用改客户端。
- `scripts/upgrade-relay.sh`（在 VPS 上手动跑）：
  1. 下载新的 `rapp-relay-x86_64-linux` 到临时文件并 `chmod +x`；
  2. 用 `--version` 自检；
  3. `mv` 替换；
  4. `systemctl restart rapp-relay`，再看 `systemctl is-active`。
  - 这只是给 relay 的一条命令，不算自升级。

## 7 可观测性（写进 A 的 service.log，沿用 observability 规格的格式）

- `update_check {result: up_to_date|available|failed, latest?, reason?}`：每次真正拉 manifest 记一条（每天最多约 1 条）。
- `update_download {version, result, bytes}`、`update_applied {from, to, mode: auto|manual|rollback}`、`update_failed {stage: download|verify|install|restart, reason}`。
- `permissions_reset {}`。
- 不记 URL 里的查询参数，不记任何密码或令牌（这个通道本来也没有）。

## 8 测试

- `rapp-update`（Rust 单测，全用临时目录和假 `Runner`）：
  - `is_newer`：大小、相等、坏格式、带后缀的版本；
  - 20 小时规则，以及缓存文件缺失或损坏；
  - `dismissed_version` 只屏蔽同一个版本；
  - manifest 缺平台或缺字段；
  - sha256 不对和 size 不对都拒绝，`.part` 能续下；
  - 指定要求不一样时进入 `needs_confirm`，不安装；
  - 第二次 rename 失败时还原；
  - 不在 `.app` 里运行时整个模块不工作。
- service（集成测试，假 manifest 用本地临时 HTTP 服务、临时端口）：
  - 有会话时不安装；没会话时安装，写标记，退出码 0；
  - 带标记启动时记 `update_applied`；
  - `permissions_reset` 调用的假 `tccutil` 参数正确，只针对 `com.rapp.rapp`。
- 打包脚本：签完名后检查四个子程序的标识，以及「发布构建不能是 cdhash 形式」的那条检查。
- GUI：状态到文案的纯函数、本机页各个状态的组件测试、重置按钮要点两次。
- 实机验收（要你同意再做，会替换 `/Applications/rapp.app` 并重启你正在用的 rapp-service）：
  - 用稳定证书装两个连续版本，确认第二次升级后屏幕录制、辅助功能仍是 ✓；
  - 有会话时不装、断开后自动装好；
  - 「重置授权记录」以后能重新授权。

## 9 说明（不是新增门禁，只是告知）

- 升级通道是一条**不经过 relay** 的路：谁能往 §2.1 选定的位置放文件，谁就能让所有 rapp 装上它。v1 里能挡住这件事的，是「指定要求必须和当前一样」这条比对。它本来是为了保证授权不失效，顺带让只有持有签名证书的人发的版本才会被自动装上。sha256 只防下坏了。按 D8 不另加签名体系。

## 10 未验证的假设（计划阶段先验证）

1. 没有 root 时，`tccutil reset Accessibility com.rapp.rapp` 能否生效（屏幕录制在用户的授权库里，辅助功能可能在系统的授权库里）。不能的话，按钮改成说明加深链。
2. 用 Apple Development 证书、不开 hardened runtime 签名时，跨两次构建授权是否一直有效。需要实机装两次才能确认。
3. `/Applications/…` 改名到 `~/Library/…` 是否在同一个卷上（APFS firmlink），不行就走 `ditto` 退路。
4. service 带着一个已经被替换的 bundle 退出、再由 launchd 拉起新路径，中间是否会触发 launchd 的 10 秒节流；会的话只是晚 10 秒，不影响结果。
5. 新 rapp-host 是否沿用 rapp.app 的授权。现有规格说系统设置里登记的是 rapp，升级不改变这层关系。
