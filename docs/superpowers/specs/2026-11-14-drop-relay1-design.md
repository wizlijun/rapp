# 删掉旧 relay（relay1），新 relay 改名为 relay

日期：2026-11-14。用户已确认（"ok"）。

## 意图

用户在 VPS 上只跑新 relay（`rapp-relay/2`）。app 里的中继设置还在说旧协议 `rapp-relay/1`，所以连不上（TLS alert 120）。用户的决定是：旧 relay 的代码、协议、脚本和 app 里的功能全部删掉，仓库里只留新 relay，名字就叫 relay。

## 目标

- 删除 `rust/relay`（旧 relay crate），以及别处所有只为旧 relay 服务的代码：
  - `rapp-net`：`ALPN_RELAY`；`Op::Register` / `Connect` / `Relay` / `Incoming` / `Relayed`；`Auth.token`。
  - service：`relay_link.rs`、`RelayCmd`、中继状态、令牌表、IPC `set_relay`、`status` 里的 `relay` / `relay_error`；`service.json` 不再读取 `relay` / `key`。
  - hub：经中继连 A 的路径（`relay_connect`、`relay_conn`、"unknown id" 那套）、`RAPP_FORCE_PATH=relay`。
  - GUI：本机卡片的「中继」行和修改对话框、`setRelay`、`relay` 路径标签，以及依赖中继状态的 ID 显示规则（ID 一律按 `ID@IP` 显示）。
  - 脚本：`package-macos.sh` / `build-linux.sh` 不再编译、打包旧 relay（`rapp-relay-x86_64-linux`、`rapp-relay.service`）；删 `upgrade-relay.sh`、`scripts/rapp-relay.service` 和它们在 `test-package.sh` 里的测试。
- 新 relay 改名：目录 `rust/relay2` → `rust/relay`，crate `rapp-relay2` → `rapp-relay`，二进制 `rapp-relay2` → `rapp-relay`。Dockerfile、`build-relay-image.sh`、smoke 测试跟着改。
- 测试：`testkit` 里经过旧 relay 的用例改成走局域网 / `ID@IP` 直连，或者删掉只测中继的用例。

## 不做

- 不做新旧并存的迁移（原设计 §13.2 作废）。
- 不写设备接新 relay 的连接层（那是第 2 步）。
- 局域网 / `ID@IP` 直连（`rapp/1`、密码认证）原样保留：设备 ID 和密码留着，直到第 2 步用新连接层替换。
- 这一步不发版：装好的 app 会自动更新，会平白少掉中继功能。等第 2 步完成一起发 0.6。

## 后果（用户已知）

第 2 步完成之前，app 没有中继通路：只能局域网，或手填 `ID@IP`（公网要端口映射）。只填 ID 的主机显示离线。

## 做法

一次性删干净。另一种做法（旧 relay 换端口继续跑、等第 2 步再删）用户没选。

## 留给实现的

- 顺序：先删旧 relay 的使用方（service、hub、GUI、脚本、测试），再删 crate，最后改名，每步都能编译、测试通过。
- 只填 ID、没有 IP 的主机怎么报错：沿用现有的"离线 / 无路可达"提示，措辞去掉"relay"。
