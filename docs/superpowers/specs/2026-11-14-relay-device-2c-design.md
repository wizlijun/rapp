# 2c：换 key（relay 一换，所有设备断开，客户端提示重新输入 key）

日期：2026-11-14。上级规格：`docs/superpowers/specs/2026-11-13-rapp-relay-design.md`（下称"relay 规格"）。本文**取代**本文件上一版（`f03af66`，吊销名单、key 自动传递、"接受新设备"开关、访问记录、redirect）。

## 1. 用户怎么定的

用户 2026-11-14 的原话：

> 一旦key要修改，一定是出了重大的安全隐患。频率肯定不会高。用户可以手动去服务器修改key。relay是docker运行的。在外面只能修改配置文件。因此告诉用户或他的agent如何修改配置文件即可。不用开发程序。
>
> 另外终端链接relay一定会失效。这时，client应该准确的提示用户安全变更了，需要重新输入key。请做好对应的交互。
> 其他繁琐的环节，不要再做了。

之后两个问题的回答：

- 服务器上换 key：用现成的 `docker exec rapp-relay rapp-relay rotate-key`，只写操作文档，不改换 key 的方式。
- 吊销名单、"接受新设备"开关、访问记录的新事件、跟着 redirect 走：**都不做**。

## 2. 和 relay 规格不同的地方

relay 规格 §7.4 第 3 步（"这台设备把新 key 发给它认识的其他设备……"）**作废**：key 不在设备之间传，每台设备由用户自己输入新 key。

relay 规格 §7.4 说"换 key 不影响已经认识的设备之间的连接"：这一条**照旧**。设备之间直连靠的是 `paired.json` 里的指纹，和 key 无关。变的只是**到 relay 的连接**。

## 3. 现在的问题

`rotate-key` 现在只换了入网口令的哈希。relay 靠指纹认已入网的设备，所以换 key 以后所有设备照样连着、照样能重连，用户不会察觉，被怀疑泄露的旧 key 也没有作废的感觉。用户要求的是"一定会失效"。

## 4. 做法

### 4.1 relay：换 key 让所有设备失效

- 设备记录多一个 `stale`（"要重新输入 key"）。`rotate-key` 把所有没吊销的设备标成 `stale`，然后立刻用新的关闭码 **4**（原因 `key changed`）断开所有已入网的连接。审计 `rotate_key` 多记被标的台数。
- `stale` 的设备连上来时当作没入网：只能 `enroll`。
  - 带对的（新）口令：去掉 `stale`，**保留它原来的 ID**。和第一次入网一样回复。
  - 带错的口令：回 `key changed`（不是 `bad key`），并且**不计入**按来源的试错锁定（这台设备的证书证明它是原来入过网的那台，不是在猜口令；不然换 key 后同一个局域网里几台旧设备一重试就会把整个出口 IP 锁住）。照旧按 `enroll_per_ip_per_min` 限速。
- `stale` 的设备照旧占着它的 ID，别人 `connect` 它得到 `offline`。
- `rapp-relay devices` 的最后一栏，`stale` 的设备显示 `stale`（和 `revoked` 同一栏）。
- 第一次 `key`（`rotate: false`）不标任何设备。

### 4.2 被控的一侧（rapp-service）

- relay 连接以关闭码 4 结束，或请求得到 `key changed`：状态 `relay: "error"`，`relay_error: "key changed"`，**停止重试**，直到用户改了设置（和现在的"已吊销"一样）。日志 `relay_key_changed`（不含 key）。
- 用户输入了新 key 之后仍然得到 `key changed`：说明新 key 也不对。这时 `relay_error` 报 `bad key`。判断办法：service 在内存里记下"第一次得到 `key changed` 时用的是哪把 key"（只存哈希，不存文本）；之后用另一把 key 又得到 `key changed`，就报 `bad key`。重启后忘掉也没关系，最多再提示一次"中继换了 key"。

### 4.3 操作的一侧（rapp-hub）

hub 自己也连 relay。它连 relay 时得到关闭码 4 或 `key changed`，就把这台主机的错误报成 `key changed`。也就是说，经中继打开窗口、在线探测失败时，错误都是 `key changed`。hub 的 key 读的是 `service.json`，用户在本机一节输入一次新 key，两边都换上。

### 4.4 GUI 的交互

本机一节（设置里），状态 `relay_error == "key changed"` 时：

```
中继   120.48.136.92:22026                     [✎]
状态   ⚠ 安全变更：中继换了 key                      ← 警示色
       这台设备已经和中继断开。请向管理中继的人要新 key，再输入。
       [ 输入新 key ]                                ← FilledButton
key    ••••••••                         [显示]
```

- 点"输入新 key"：打开一个只有一个 key 输入框的对话框，标题"输入新 key"。输入框获得焦点、遮住内容。接入点保持不变。保存调用现有的 `set_relay`（地址不变，key 换新）。
- 保存后状态先显示"连接中"。如果成功，就是"已连接"；如果新 key 也不对，就显示"出错：新 key 不对"，按钮仍在。
- 这台设备在别处报出 `key changed` 时，比如打开窗口失败、主机列表里的离线原因，文字统一是 **"中继换了 key，请到 本机 → 输入新 key"**。

`disconnectWord`：`key changed` → `中继换了 key，请到 本机 → 输入新 key`。状态一行的专门文字见上图。

### 4.5 老版本

- 0.6.0 的设备连到新 relay：收到关闭码 4 当普通断开，重连后入网得到 `key changed`，当普通错误显示原文并按退避重试（不会被锁定）。升级后就正常提示了。
- 新设备连 0.6.0 的 relay：不会遇到 `stale`，行为和现在一样。VPS 要升级到含本改动的 relay 镜像，"一定会失效"才成立。

## 5. 操作文档

写在 `docker/relay/README.md` 新的一节"Changing the key / 换 key"，中英都写，写给人，也写给替人操作的 agent（命令照抄即可执行，每步写清楚预期看到什么）：

1. 什么时候换：怀疑 key 泄露、丢了设备。
2. 丢了设备的话，先 `docker exec rapp-relay rapp-relay revoke <ID>`。
3. `docker exec rapp-relay rapp-relay rotate-key`：新 key 只显示这一次，立刻保存好。所有设备马上断开。
4. 在每台设备上：本机 → 状态那一行"安全变更：中继换了 key" → "输入新 key"。
5. `docker exec rapp-relay rapp-relay devices`：还显示 `stale` 的就是还没输入新 key 的设备。
6. 不要直接改 `/data` 下的文件：key 只以哈希的形式存在那里，改了也得不到能用的 key。

## 6. 不做

- 设备之间传 key、`key_gen`、`adopt_key`。
- 设备端的吊销名单。已知缺口：在 relay 上被吊销的设备连不上中继，但在同一个局域网里，认识它的设备仍然会认它。留到以后。
- "接受新设备"开关、访问记录的新事件、redirect、设备端口的单向流上限、"信任被拒"的日志限速。
- 打洞（用户定：安全性不确定，放到以后）。以后要回答的问题是：会不会被拿去当跳板打别人（反射、放大）；设备端口在公网可达以后，门禁还够不够；要在 VPS 和两个不同网络下实测。
- 不发版，不改版本号。

## 7. 我替你定的

1. 换 key 后设备的 ID 保留，重新输入 key 就回到原来的 ID。
2. 旧设备用旧 key 重试回 `key changed`，不计入试错锁定。
3. 关闭码用 4（2 是吊销，3 是超限）。
4. "新 key 也不对"由 service 记一把 key 的哈希来区分，只放内存。
