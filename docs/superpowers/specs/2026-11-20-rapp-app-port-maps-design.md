# 没有后台服务的 app 里的端口映射（设计）

2026-11-20。依据：用户原话（§1），用户的两次决定（§4），现有的端口共享代码：`rust/service/src/maps.rs`（本机端口表）、`pipe.rs`（向共享方要端口）、`rust/conn/src/dial.rs`（`Outbound`）、`rust/hub-ffi`（iOS 内嵌的 hub）。

## 1. 为什么做

在 iOS app 里把 LLM 接入点设成 `localhost:28001`，连接被拒绝。Mac 上能用，是因为 Mac 有 rapp 后台服务：它在本机 `localhost:28000–28999` 开端口，再把连接经虚拟网转到共享这个端口的设备上（`maps.rs`）。iOS app 里只有 hub（连远程窗口的那一半，`rapp-hub-ffi`），没有后台服务，所以手机上这个端口什么都没有监听。Android app 以后也会是这种情况。

用户原话：

- 「这种 ios adroid 的 app，都没有后台服务，请给他们规划一个统一的位置处理这些端口映射的问题，确保 url 一致」
- 「只需要 app 内能有效访问到即可。」

## 2. 目标、不做的、不能出现的

**目标**

- G1 在没有后台服务的 app 里（现在是 iOS，以后是 Android），app 自己访问 `localhost:<共享号>`，就能连到别的设备共享的那个端口。地址和 Mac、Linux 上的一样：共享方定的共享号是 28001，手机上也是 `localhost:28001`。
- G2 只有一个地方处理映射：本机端口表和放置规则从后台服务挪到一个共用的 Rust 模块里。后台服务用它，内嵌的 hub 也用它，所以「哪个共享放在哪个号」的规则只有一份。
- G3 每台设备上只有一处开这些端口：有后台服务的设备由后台服务开（Mac 上的 hub 不开）；没有后台服务的 app 由内嵌的 hub 开。
- G4 app 一启动就能用：上次的映射存在 app 自己的 `maps.json` 里，启动时先按它开好端口，再去问各设备现在共享了什么。

**不做的**

- 不让手机上别的 app 访问（用户：只需要 app 内）。端口只开在本机回环地址，app 退到后台、被挂起时不保证能用。
- 不做系统级 VPN、DNS 或 `.rapp` 名字。
- 手机不当共享方：手机不共享自己的端口。
- 这一步不在 iOS 上做「设备 / 共享」面板，映射只写进 hub 日志（日志页能看到）。面板以后再说。
- 不合并 hub 现有的中继连接和 `Outbound` 的中继连接，先各用各的（多一条到中继的连接）。

**不能出现的**

- 同一个共享在手机上和在 Mac 上号不一样。只有手机本机已经有程序占着这个号时才让开，而 app 内一般不会有。
- Mac 上 hub 和后台服务都去开 28000 段，抢端口。
- 共享方没允许这台手机，却连得上。放行规则不变，仍由共享方判断（`forward.rs` 的 `authorize`）。

## 3. 做法对比

- **A. 共用模块，内嵌 hub 也开本机端口（选这个）**：把端口表、放置规则、转发挪到一个共用的 crate，后台服务和内嵌 hub 都调它。地址规则天然一致，app 里任何代码（Dart 的 HTTP、以后的 WebView）用 `localhost:<号>` 都能连。代价是 hub 要多维护一份端口表，要处理 iOS 挂起后恢复。
- B. Dart 层拦截：Dart 发 HTTP 前看到 `localhost:28xxx`，就改走 hub 的一条流。只管得到 Dart 自己发的请求，WebView 和别的库管不到；放置规则要在 Dart 里再写一份，违反 G2。
- C. 让 Mac 把 28001 开到局域网，手机连 Mac 的 IP：要求 Mac 开着、在同一局域网，地址也和别处不一样，违反 G1。

## 4. 用户的决定

- D1（2026-11-20）：iOS app 自己开端口（选了 A 的方向），而不是只给语音整理开一条专用路，也不是在 iOS 上关掉整理。
- D2（2026-11-20）：只需要 app 内能访问到即可。

## 5. 设计

### 5.1 共用模块 `rapp-ports`

新建 `rust/ports`（crate 名 `rapp-ports`），从 `rust/service/src/maps.rs` 原样挪进去：

- `Map`、`Maps` 端口表（`load` / `start` / `ensure` / `target` / `keep` / `keep_devices` / `closed` / `stop`）和它的单元测试；
- `listen` / `free`（两个回环地址都要空着）；
- `ensure_all` 的放置规则：想要共享方给的号；别处在用的号避开；本机自己共享占着的号让开。

不依赖后台服务的 `State`。它需要的外部能力抽成一个参数：

```rust
/// 怎么把一个连接带到设备 `id` 的 `port`：后台服务和内嵌 hub 各给一个。
pub trait Carrier: Send + Sync + 'static {
    async fn open(&self, id: &str, port: u16) -> Result<Pipe, String>;
}
```

两边各自实现：后台服务里是现在的 `pipe::open`；hub 里是同样的 `Outbound::request(Op::Forward)`，用 hub 自己的 identity、`service.json` 里的中继和 key，以及 `hosts.json` 里的地址和指纹。「问设备共享了什么」（`Op::ListShares`）两边也用同一个函数，放在 `rapp-ports` 里，传入 `Outbound` 和中继、key。

后台服务改成调用 `rapp-ports`，行为不变，现有的 testkit `maps.rs`、`share_numbers.rs` 测试照样通过。

### 5.2 谁开端口

`hub::Opts` 新加 `own_ports: bool`。只有 `rapp-hub-ffi` 设为 true（它本来就是 `owns_access: true`，意思是「这台设备上没有后台服务」）；桌面上的 hub 进程是 false。这样每台设备上只有一处开端口（G3）。

### 5.3 内嵌 hub 什么时候问、什么时候开

- 启动：读 app 主目录的 `maps.json`，先把上次的映射全部开好（`Maps::start`），然后马上按 `hosts.json` 问一遍各设备。
- 每 60 秒问一遍；主机列表变化、网络恢复（netmon）时也马上问一遍。每次的结果和后台服务的 `hosts` 命令一样处理：记下别处在用的号（`saw`），按共享号 `ensure`，对方不再共享的就收回（`keep`）。
- app 回到前台：Dart 在 `AppLifecycleState.resumed` 时发一条 hub 命令 `ports_relisten`。hub 把所有监听关掉再重开，然后马上问一遍。iOS 挂起时可能收回监听用的 socket，这样一回来就恢复。监听循环在 `accept` 出错时也要关掉重开，不能一直空转。
- 每次映射有变化，hub 发一个事件 `{"event":"ports","maps":[{"id","port","local"}]}`，同时写进 hub 日志。现在 Dart 只记日志，不显示。

### 5.4 放行

不改。手机用自己的设备身份（`device` key）去连共享方，共享方照旧检查 key、远程策略和允许列表。允许列表为空就是所有用这把 key 的设备都能连；如果列了设备，要在共享方的「设备」面板里把这台手机加进去。

### 5.5 失败时

- 映射还没建好时（第一次装、还没问到），或者对方不在线、不允许：连接被关掉，hub 日志写明原因（`map_refused`，和后台服务一样）。
- LLM 这边不用改：连不上就算整理失败，保留原话（rapp-llm 网关的规则）。

## 6. 留给实现的

- `Carrier` 用 trait 还是函数闭包，`rapp-ports` 具体怎么分文件。
- hub 的 60 秒定时放在 `presence` 里还是另起一个任务。
- 测试：testkit 里起一个共享方后台服务，加一个 `own_ports` 的 hub，hub 那边连 `localhost:<号>` 能回显；Mac 上的 hub（`own_ports` 为 false）不开端口；`ports_relisten` 之后还能连。
- iOS 上要实机看：设好 `localhost:28001` 后点「测试」能通；长语音能整理；app 切到后台再回来还能用。
