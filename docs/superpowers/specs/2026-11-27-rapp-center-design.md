# 中心服务 rapp-center：rapp 所有端的协调服务，一个端口多块能力（设计）

日期：2026-11-27。在 rapp-state（`2026-11-26-rapp-state-design.md`，P1–P3 已发）之上。

## 0. 用户的要求（2026-11-27，原话）

> 我现在想更进一步, 这个内置的全局的服务, 可以使用统一的端口,不同的 router 实现不同的能力. 请规划一下这个服务和 对应的 router 怎么做可以方便扩展. 目前已经有3个需求了: llmapi/state/常用喜好配置,将来可以有 网盘/笔记等入口 api 的扩展.

对话里定下的：

| 编号 | 问题 | 用户选的 |
|---|---|---|
| D1 | 以后加网盘、笔记时怎么扩展 | **两种都要**：常用的（状态、喜好配置）写进同一个 Rust 程序；llmapi、网盘这类已有的或别的语言写的，挂在同一个端口下转发过去。rapp-llm 不改写 |
| D2 | 「常用喜好配置」指什么 | **常用语和语音词表全网一份，界面偏好各存各的** |
| D3 | 语音词表放哪 | **留在 llm 里**：它已经在 rapp-llm 网关里全网一份，app 经统一端口的 `/llm/…` 读写 |
| D4 | 怎么搭 | **甲：改造 rapp-state**（同一程序、同一端口 8102），不另写入口程序 |
| D5 | 第一段设计（路由、内置、转发、app 一侧） | 可以 |
| D6 | 叫什么（用户：“我希望这个服务负责 rapp 所有端的协调服务”） | **`rapp-center`，界面叫「中心服务」** |

## 1. 一句话

网里有一台设备跑「中心服务」`rapp-center`，负责 rapp 所有端之间的协调：一个端口，按路径前缀分给不同的能力。内置的能力（状态、常用语）在这个程序里；转发的能力（llmapi，以后网盘、笔记）在别的程序里，这个程序替它们收请求、带上 key、原样转过去。app 找到这一个服务，就找到了全部能力。

## 2. 现状（代码）

- **rapp-state**：`services/state/`，Rust + hyper 1.x，只听 `127.0.0.1:8102`，不认证。路由是 `services/state/src/http.rs:321` 起的一个 `match`，路径都在 `/v1/` 下：`health`、`events`、`state`、`queue`、`watch`、`seen`、`desk/<fp>`。`GET /v1/watch` 是 SSE，推 `what` 为 `session`、`queue`、`need`、`seen`、`desk` 的变化。存盘在 `services/state/src/disk.rs`。
- **怎么被启动、被找到**：`rapp-service` 的随行程序表 `rust/service/src/companion.rs:45`（`name:"state"`，`program:"rapp-state"`，`port:8102`，`kind:"state"`），开关在 `local/services.json`。端口分享时带 `kind:"state"`，设备之间用 `StateSink` 互相转告（状态规格 §7.2）。本机 IPC 的 `state` 回复带 `url`（`companion.rs:570` `sink_url`：本机是 `http://127.0.0.1:8102`，别台是映射出来的 `http://localhost:<分享号>`）。app 的接入点 `local/state.json`（`auto`/`off`/`manual`，`gui/lib/state/state_config.dart`）。
- **认名字**：发件箱（`rust/service/src/outbox/send.rs:52`）和 app（`gui/lib/state/state_link.dart:56`）都要求 `GET /v1/health` 回 `"name":"rapp-state"`，发件箱还发 `Host: rapp-state`。
- **llmapi**：另一个仓库 rapp-llm（Node），跑在用户的一台机器上（那台的 `127.0.0.1:8101`），手工分享成 `localhost:28001`。要 `Authorization: Bearer <key>`（`GET /healthz` 除外）。app 的地址和 key 手填在 `local/llm.json`（`gui/lib/llm_api.dart`，0600）。语音词表在网关里：词表文件、学到的改正，接口 `/v1/hotwords`、`/v1/vocabulary/rules|learn|learned`；网关做语音整理时直接把它们读进提示词。没开 CORS。
- **常用语**：在每台的 `gui.json` 的 `phrases`（`gui/lib/ui/prefs.dart:91`），是常用语条的整份列表（命令和常用语都在里面，`StripItem`），另有 `phrase_cmds_seeded`。各存各的。
- **端口映射**：`rapp-service` 把别台的分享映射成本机 `localhost:28000+`（`rust/service/src/maps.rs`），iOS 的内嵌 hub 自己开这些端口。

## 3. 目标、不做、反目标

目标：

- G1 一个端口、一个被找到的办法，覆盖所有能力。app 不用为每块能力各填一次地址。
- G2 加一块**转发**能力不发版：改一张表就行。
- G3 加一块**内置**能力有固定的写法：一个模块，共用存盘、日志、变化推送、路由表的登记。
- G4 常用语全网一份：一台改了，别台马上看到；连不上服务时照样能用上次那份。
- G5 llmapi 经统一端口可用，app 不用再填 llm 的地址和 key。
- G6 旧 app、旧 `rapp-service`（0.15.55 及以前）照常工作。

不做：

- 不同步界面偏好（主题、排列等），各台照旧各存各的（D2）。
- 不搬语音词表（D3）。
- 不改写 rapp-llm，不把 rapp-llm 放进安装包。
- 第一版不做网盘、笔记，只把转发做到它们以后能直接挂上来。
- 不做按能力分的权限（谁能用 llm、谁不能）。能进网就能用（见 §11）。

反目标（做出来也算失败）：

- 旧 app 连上新服务后状态全没了。
- 转发让 llm 的流式回复变成一次性回来（语音整理的首字时间是硬指标，常见 1.2–1.8 s）。
- 一块转发能力挂了、慢了，拖住状态和常用语。
- llm 的 key 出现在日志、`/v1/routes` 回复或任何别的设备能读到的地方。

## 4. 考虑过的做法

扩展的方式（D1）：

| 做法 | 结论 |
|---|---|
| 全部写进一个 Rust 程序 | 不用。rapp-llm 要改写；网盘这类现成程序接不进来 |
| 全部是独立程序，服务只做入口 | 不用。状态也要拆出去，多一层转发、多管一个进程 |
| **内置 + 转发两种都有** | **采用（D1）** |

服务怎么搭（D4）：

| 做法 | 结论 |
|---|---|
| **甲、改造 rapp-state** | **采用**。启动、被找到、存盘、推送都现成；旧 app 不受影响 |
| 乙、另写入口程序，状态服务被转发 | 不用。内置只剩常用语，多一个进程，多绕一层 |
| 丙、路由放进 `rapp-service` | 不用。违反 `services/README.md` 的“本体不依赖它”，进阶用户也没法换成自己的实现 |

## 5. 结构

```
app / 发件箱 / 脚本
        │  http://<中心服务>/…
        ▼
rapp-center（中心服务，127.0.0.1:8102）
  ├─ /v1/health  /v1/routes  /v1/watch           入口自己的
  ├─ /v1/events /v1/state … （根下旧路径）        = /state 的别名，给旧 app
  ├─ /state/v1/…        内置：状态（今天的全部）
  ├─ /prefs/v1/…        内置：常用语
  └─ /llm/…  ──转发──►  routes.json 里的地址（如 localhost:28001，可在别台）
     /drive/… /notes/… 以后同样转发
```

- **改名（D6）**：程序 `rapp-state` → `rapp-center`，目录和 crate `services/state/` → `services/center/`（crate `rapp-center`，库 `rapp_center`），命令 `rapp state` → `rapp center`（`rapp state` 留作别名），界面「状态服务」→「中心服务」，随行程序表里 `program:"rapp-center"`。安装包里只带新名字的程序。
- **线上的名字不改**【我定的】，旧设备认的都是它们：
  - `GET /v1/health` 的 `name` 仍回 `"rapp-state"`（旧发件箱 `outbox/send.rs:52`、旧 app `state_link.dart:56` 只认它），另加 `"service":"rapp-center"`；新代码认 `service`，没有时认 `name`。
  - 分享的 `kind:"state"`、设备之间的 `StateSink`、`SetService` 和 IPC 里的 `name:"state"`、发件箱的 `Host: rapp-state` 都不变。
  - `services.json` 的键改成 `center`；读到旧的 `state` 键时当成 `center`，下次写时改成新键。
  - 数据目录 `local/state/` → `local/center/`：启动时 `local/center/` 不存在而 `local/state/` 存在，就整个改名过去（同一个文件系统，一步完成）；改名失败就继续用 `local/state/`，记一行日志。
- 状态这块能力的前缀仍叫 `state`（它管的就是状态），和服务的名字分开。
- 前缀就是能力的名字：小写字母、数字、`-`，不能是 `v1`（入口自己用）。

## 6. 入口自己的接口

| 接口 | 做什么 |
|---|---|
| `GET /v1/health` | `{"name":"rapp-state","service":"rapp-center","v":2,"routes":true}`。`v` 从 1 变 2；`routes:true` 表示有 `/v1/routes`。旧 app 只看 `name`，不受影响（§5） |
| `GET /v1/routes` | 有哪些能力：`{"routes":[{"name":"state","kind":"builtin","v":1},{"name":"prefs","kind":"builtin","v":1},{"name":"llm","kind":"forward","up":true}]}`。转发的那项带 `up`（最近一次探测的结果，§9.3），**不带地址和 key** |
| `GET /v1/watch` | 和今天同一条 SSE，所有内置能力的变化都从这里推，`what` 区分。今天的 `session`、`queue`、`need`、`seen`、`desk` 不变；新的带能力前缀，如 `prefs.phrases`。另加 `routes`：路由表或某项 `up` 变了时推一次全表（和 `GET /v1/routes` 同形） |

- 根下的旧路径（`/v1/events`、`/v1/state`、`/v1/queue`、`/v1/seen`、`/v1/desk/<fp>`）一直保留，和 `/state/v1/…` 走同一段代码【我定的】。新 app 用 `/state/v1/…`，发件箱照旧用根下的（它不用改）。
- `/state/v1/watch` 不另开：watch 只有入口那一条。

## 7. 内置能力怎么写

每块内置能力是 `services/center/src/` 下的一个模块，实现同一个 trait（名字和细节留给实现者，形状如下）：

```rust
trait Builtin: Send + Sync {
    /// 前缀，也是 `/v1/routes` 里的 name。
    fn name(&self) -> &'static str;
    /// 这块的接口版本，出现在 `/v1/routes`。
    fn version(&self) -> u32;
    /// 处理 `/<name>/<rest>`，rest 以 `v1/` 开头。
    async fn handle(&self, cx: &Ctx, method: &Method, rest: &str, req: Request<Incoming>) -> Response<Body>;
    /// 存盘：自己那一块的 JSON，和从盘里读回。
    fn save(&self) -> Value;
    fn load(&self, v: &Value);
}
```

- 共用的东西在 `Ctx` 里：日志（`Log`）、发变化（`publish`，进同一条 watch）、“该存盘了”（今天的 `Dirty`）。
- 存盘：今天状态的文件跟着目录搬到 `local/center/`，内容不动；每块新能力存成同目录下自己的一个文件（`prefs.json`），各自 0600、各自原子写。一块读坏了只丢那一块，记一行 `load_failed`，别的照常【我定的】。
- 今天的状态代码搬成第一块（`state`），行为不变；它特有的过期、`keep_days` 这些仍是它自己的。
- 加一块内置能力 = 新模块 + 在一张表里登记一行 + `api/` 里写它的接口和样例。要跟着发版。

## 8. 内置：`prefs`（常用语）

### 8.1 存什么

一份常用语条，和 `gui.json` 的 `phrases` 同形（`StripItem` 的 JSON 列表，命令和常用语都在里面，按条上的顺序），加一个版本号 `rev`（每次写入加 1）和 `at`（服务的时钟）。整份读写（用户说的“全网一份”；常用语改得少，不做逐条合并）【我定的】。

`phrase_cmds_seeded` 不进服务：它是“这台的旧列表前面补过内置命令没有”，补过以后上传的就是补好的列表。

### 8.2 接口

| 接口 | 做什么 |
|---|---|
| `GET /prefs/v1/phrases` | 200 `{"rev":n,"at":t,"items":[…]}`；从没写过时 `{"rev":0,"items":null}` |
| `PUT /prefs/v1/phrases` | body `{"items":[…],"base":n}`。`base` 是写的人上次读到的 `rev`。`base` 等于当前 `rev`：存下，`rev+1`，回 200 新的整份，watch 推 `prefs.phrases`（带整份）。不等：409 回当前整份，不存 |
| 上限 | 最多 200 条，body 最大 256 KiB（和今天一样），每条不验内容，只要是 JSON 对象（新版本加的字段原样留着） |

- 冲突的处理在 app 一侧（§10.3）。409 让“两台差不多同时改”不会悄悄吃掉一边：后到的那台看到新的整份，再决定。
- 首次上传：`rev:0` 时 `base:0` 的 `PUT` 成功，就是“服务里还没有，用本机这份”。两台同时首次上传，后一台得 409，改用服务里的。

## 9. 转发

### 9.1 路由表

服务的数据目录下 `local/center/routes.json`（0600）【我定的】：

```json
{ "llm": { "url": "http://localhost:28001", "key": "…", "health": "/healthz" } }
```

- `url`：转去哪。只能是 `http://`；通常是端口映射出来的 `localhost:<分享号>`，对方在哪台都一样。也可以是本机的真实端口。
- `key`：可省。有的话转发时加 `Authorization: Bearer <key>`，替换请求里原来的那个头（原来没有也加）。
- `health`：可省。探测用的路径（§9.3），省了就不探测，`up` 总是 `true`。
- 名字不能和内置能力重名；重名、地址不合法的那行跳过，日志记一行，别的照常。
- 文件改了，服务在下一次探测（或收到 `SIGHUP`）时重读，不用重启【我定的】。
- 怎么填：第一版手改文件，或者 `rapp center route llm http://localhost:28001 --key …`（经 IPC 让 `rapp-service` 写这个文件）。app 里的编辑界面放下一期（§13）。

### 9.2 转发怎么做

- `/<name>/<rest>?<query>` → `<url>/<rest>?<query>`，方法、body、头原样（去掉逐跳头和 `Host`，`Host` 改成目标的）。回复的状态码、头、body 原样回来。
- **流式**：请求和回复的 body 都边收边转，不攒（反目标第 2 条）。用 hyper 的客户端，body 直接对接。
- **超时**：只限连接（5 s，连不上回 502 `{"error":"upstream unreachable"}`）。连上以后不限总时长（llm 的 `polish` 可以 30 s，SSE 更长），对面的超时由对面自己管。客户端断开时上游的连接一起断（rapp-llm 靠这个取消上游）。
- **隔离**：转发不拿状态的锁，不占内置能力的任何东西，一块转发慢了不影响别的（反目标第 3 条）。同时转发的连接数上限 64，超了回 503【我定的】。
- 没有这个名字：404 `{"error":"no route"}`。
- 日志：每次转发一行：名字、方法、状态码、耗时。不记路径后半段、query、body、头（反目标第 4 条）。

### 9.3 探测

有 `health` 的路由每 30 s `GET` 一次（不带 key），200 记 `up:true`，别的或 3 s 没回记 `false`。变了就推 `routes`。只用于 app 显示“llm 连不上”，**不挡请求**：`up:false` 时请求照转。

## 10. app 一侧

### 10.1 找到服务

不变：`local/state.json` 的 `auto`/`manual`/`off`，IPC 给 `url`。连上后读 `GET /v1/health`：没有 `routes:true` 就是旧服务，只用状态（今天的样子），常用语和 llm 都照旧本机来。

### 10.2 llm

- 有中心服务、`/v1/routes` 里有 `llm`：llm 的地址自动是 `<服务 url>/llm`，**不带 key**（入口替它带）。
- `local/llm.json` 手填了地址就用手填的，优先【我定的】：方便直连调试、在没开中心服务的网里照用。
- 设置里的「LLM 接入点」那一行显示“经中心服务”或“手填”，`up:false` 时显示连不上。
- `llm_api.dart` 里所有请求（apps、hotwords、vocabulary 各接口、模型层）只是换了 base，路径不变，不用改。

### 10.3 常用语

- 连上服务、`/v1/routes` 里有 `prefs`：`GET /prefs/v1/phrases`。
  - `rev:0`：把本机 `gui.json` 里那份 `PUT` 上去（`base:0`），成功就以它为准。
  - 否则：用服务里的，覆盖本机的 `phrases`（本机这份当缓存）。
- 改了常用语（增删改、排序）：本机先改、先显示，再 `PUT`（`base` 是上次的 `rev`）。
  - 200：记下新 `rev`。
  - 409：用回来的那份覆盖本机，提示一行“常用语在别的设备上改过，已换成最新的”【我定的】。用户刚才的改动丢掉，要的话再做一次（常用语改得少，同时改的机会很小）。
  - 连不上：本机改了照样留着，记“有没传的改动”，下次连上先 `GET`，`rev` 没变就 `PUT`，变了按 409 处理。
- watch 收到 `prefs.phrases`：`rev` 比本机的大就覆盖本机、刷新常用语条。
- 连不上服务：常用语条照样用本机缓存，能改（见上）。
- 第一次升到这个版本的设备，如果服务里已经有别台传上去的，本机原来那份会被换掉。写进发版说明。

## 11. 安全和隐私

- 和今天一样：只听回环，经端口分享访问，路上加密，能进网（持 relay key）就能用全部能力（[`security-posture`]：relay 是唯一门禁）。
- llm 的 key 只在跑中心服务那台的 `routes.json` 里（0600），别的设备的 app 不再需要它。代价：网里任何设备都能经 `/llm/` 用 llm，不用 key。这和“有 key 即互信”一致。
- 常用语里可能有私人内容：存在中心服务那台的盘上，0600。日志不记内容。

## 12. 兼容

| 谁 | 新服务 | 旧服务（0.15.55 及以前） |
|---|---|---|
| 新 app | 用 `/state/v1/…`、`/prefs`、`/llm` | 看 `health` 没有 `routes`，只用状态，走根下路径 |
| 旧 app | 根下旧路径照旧，watch 里多出的 `what` 它忽略（要验证，§14） | 不变 |
| 发件箱（新旧） | 根下 `/v1/events`，`health` 的 `name` 不变 | 不变 |

## 13. 分期

| 期 | 内容 | 验收 |
|---|---|---|
| G1 | 改名（§5）；入口：`/v1/routes`、`health` v2、`/state/v1/…` 别名、`Builtin` trait、把状态搬成第一块 | 旧 app 和发件箱对新服务的现有测试全过；新路径和旧路径回一样的东西；旧 `services.json`、旧 `local/state/` 升级后照用 |
| G2 | 转发：`routes.json`、流式转发、带 key、探测、`rapp center route`；app 的 llm 自动接入 | 经 `/llm/v1/apps/dictation` 流式整理，首字时间和直连相比多不过 50 ms（同一台机器上量）；llm 挂了状态照常 |
| G3 | `prefs`：常用语的存、读、写、409、watch；app 的同步和缓存 | 两台改常用语互相看到；同时改有一台得到提示；断网能用、重连补传 |
| 以后 | app 里编辑路由表；网盘、笔记作为转发挂上来 | |

G2 和 G3 都只依赖 G1，互不依赖。

## 14. 测试要求

- `services/center/api/` 加 `routes.md`、`prefs.md` 和样例；两边（Rust 服务、Dart app）用同一批样例测，规则和今天一样。
- 旧路径：今天所有的 HTTP 测试不改就要过（G1 的验收）。
- 旧 app 的 watch 解析遇到不认识的 `what`：在 Dart 测试里用 0.15.55 那版的解析代码跑一遍新的 watch 样例，确认它忽略，不报错、不断开。不忽略的话，新 `what` 改成只推给声明要的人（`/v1/watch?all=1`）。
- 转发：本地起一个假上游，测流式（分块到达时间不被攒）、断开传递、连不上 502、key 替换、日志里没有 key 和 body。
- `prefs`：`base` 对、不对、首次上传竞争、上限、坏文件只丢这一块。

## 15. 我定的（不对请改）

1. 改名只改本机看得见的（程序、目录、crate、命令、界面、`services.json` 键、数据目录），线上的名字（`health` 的 `name`、`kind`、`StateSink`、`SetService` 的 `name`、`Host`）不改，否则旧的发件箱和 app 找不到它（§5）。
2. 根下旧路径永久保留（§6）。
3. 每块内置能力存自己的文件，坏了只丢这一块（§7）。
4. 常用语整份读写，用 `rev` 防覆盖，冲突时后到的那台换成最新的并提示，自己的改动丢掉（§8、§10.3）。
5. 路由表放服务数据目录的 `routes.json`，改了不用重启；第一版用命令行或手改（§9.1）。
6. 转发只限连接超时，不限总时长；并发上限 64（§9.2）。
7. 手填的 `local/llm.json` 优先于经中心服务（§10.2）。

## 16. 留给实现者

- `Builtin` trait 的确切签名（async 的写法、`Ctx` 拆成哪几样）。
- 转发用 hyper-util 的哪个客户端、连接复用。
- `rapp center route` 的 IPC 形状（照 `SetService` 的样子）。
- 界面上「中心服务」那一节里列出各能力及状态的样子。

## 17. 确认后要跟着改的文档

- 状态规格 §8.3、§12（`llm/` 预留位置的说法改成“经转发挂上”）。
- `services/README.md`、`services/center/README.md`、`services/center/api/http.md`（跟着目录改名）。
- 打包脚本 `scripts/package-macos.sh`、`scripts/package-linux.sh` 里的 `rapp-state`；`rust/Cargo.toml` 的 `members`。
- 《配置规范总览》：`routes.json`、`state.json` 的说明。
- `tasks/todo.md` 加这一项。
