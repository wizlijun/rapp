# rapp 域名候选

日期：2026-11-12。状态：**记录，还没有注册任何域名**。注册要用用户自己的注册商账号和付款，由用户来做。

## 用户的要求

> 能否根据现在的主张，申请一个域名。raap.dev 类似这样一眼就能看明白的域名。

"现在的主张"按 `2026-11-12-rapp-requirements-feedback.md` §3 理解：一套最常用的键盘和显示屏当主控制台，别的电脑上跑着的 app 在这里看一眼、写一段回复。

## 怎么查的

2026-11-12 19:30（JST）前后，对每个候选做了两项查询：

- RDAP 注册数据查询（经 rdap.org 转到各后缀的注册局）：返回 200 表示已注册，404 表示注册局没有这条记录。
- DNS 的 NS 记录：有 NS 说明有人在用。

两项都没有记录的记为"应该可注册"。这不是最终结论：注册局保留词、溢价域名查不出来，以注册商下单页面为准。

## 结果

| 域名 | RDAP | NS | 判断 |
|---|---|---|---|
| rapp.dev | 200 | 有 | 已被注册 |
| rapp.app | 200 | 有 | 已被注册 |
| rapp.ai | 200 | 有 | 已被注册 |
| rapp.cc | 200 | 有 | 已被注册 |
| rapp.sh | 404 | 有 | 有人在用，按已注册算 |
| rapp.computer、rapp.systems、rapp.page、rapp.studio | 200 | 有 | 已被注册 |
| remoteapp.dev、remoteapp.app | 200 | 有 | 已被注册 |
| agentconsole.dev、appconsole.dev | 200 | 有 | 已被注册 |
| getrapp.com | 查询超时 | 有 | 有人在用，按已注册算 |
| **rapp.run** | 404 | 无 | 应该可注册 |
| **remoteapp.run** | 404 | 无 | 应该可注册 |
| **getrapp.dev** | 404 | 无 | 应该可注册 |
| raap.dev | 404 | 无 | 应该可注册 |
| raap.app、raap.sh | 404 | 无 | 应该可注册 |
| rapp.tools、rapp.works | 404 | 无 | 应该可注册 |
| getrapp.app、tryrapp.dev、rapphq.com | 404 | 无 | 应该可注册 |
| remoteapps.dev、remote-app.dev | 404 | 无 | 应该可注册 |
| rappdesk.dev、rappdeck.dev | 404 | 无 | 应该可注册 |
| mainconsole.dev、oneconsole.dev、calmconsole.dev、onekeyboard.dev | 404 | 无 | 应该可注册 |
| rapp.so | 404 | 无 | 不确定：.so 后缀可能不支持这种查询 |
| raap.run | 302 | 无 | 不确定：查询被重定向，没拿到结果 |

## 建议（我的分析，待用户定）

1. **rapp.run** 做主域名。和产品名一致，短，读出来就是"rapp，运行"。
2. **remoteapp.run** 一起注册，跳转到主域名。它不用解释就知道是"远程运行 app"，最符合"一眼看明白"。
3. 想要 .dev 后缀的话用 **getrapp.dev**。

不建议 raap.dev：它和产品名 rapp 只差一个字母的位置，别人会当成拼错，口头说也说不清；除非产品要改名叫 raap。

mainconsole.dev、oneconsole.dev 这一类说的是"主控台"这个主张，但里面没有产品名，适合当口号页，不适合当主域名。

## 要知道的两点

- rapp 这个名字在 .dev、.app、.ai、.cc 等后缀上都已经被别人注册，rapp.com 据我所知属于一家同名的营销公司（没有核对）。以后搜"rapp"不容易搜到这个项目。要不要因此换名字，由用户定。
- 商标没有查过。我不是律师。

## 补充：和 rapp.dev 相关的名字（2026-11-12 21:05 JST 前后查询）

用户追问"rapp.dev 相关的"。查了 rapp.dev 本身，和一批带 rapp 的 .dev 域名，方法同上。

### rapp.dev 本身

- 2019-02-28 注册（.dev 开放注册的头几天），到期日 2027-02-28，最近一次变更 2026-10-06。
- 域名服务器是一家德国注册商的；`https://rapp.dev` 连不上，没有网站，也没看到出售页面。
- 判断：有人长期持有，不像会放出来。想要只能找持有人谈，我没有联系方式，也没有试过。

### 带 rapp 的 .dev

| 域名 | 判断 |
|---|---|
| rappy.dev | 已被注册 |
| getrapp.dev、tryrapp.dev、runrapp.dev、gorapp.dev、openrapp.dev、myrapp.dev、heyrapp.dev、hellorapp.dev、joinrapp.dev、withrapp.dev、onrapp.dev | 应该可注册 |
| rappd.dev、rapps.dev、rappx.dev、rappapp.dev、rapp-app.dev、rapphq.dev、rappkit.dev、rapplabs.dev、rappcli.dev、rappctl.dev、rapphub.dev、rappio.dev、rappos.dev、rappone.dev、rappgo.dev、rapprun.dev、rappnow.dev、rappbox.dev、rappdock.dev、rapplink.dev、rappview.dev | 应该可注册 |
| rappremote.dev、rappconsole.dev、rappstation.dev | 应该可注册 |
| userapp.dev、therapp.dev、rappdev.dev、rapp-dev.dev、rapp-run.dev | 应该可注册，但不建议：前两个会被读成 user app、therapy，后三个啰嗦 |

### 建议（我的分析，待用户定）

1. **getrapp.dev**：离 rapp.dev 最近的常规写法，"get + 产品名"是软件官网的惯例，别人一看就知道是 rapp 的官网。
2. **rappconsole.dev**：把"主控台"这个主张直接写进域名。
3. **rappremote.dev**：不知道 rapp 的人也能看出是远程相关的东西。

三个里只选一个的话选 getrapp.dev；想让域名自己说明用途，选 rappconsole.dev。

## 补充 2：换后缀、换说法再找一轮（2026-11-12 22:35 JST 前后查询）

用户问"还有没有更好的域名"。这一轮查了两类：rapp 接其他后缀，以及不带 rapp、直接描述用途的 .dev。方法同上。
查询中有几次 DNS 超时，表里标了"不确定"。国家后缀（.is、.gg、.to、.so 等）不一定支持 RDAP 查询，404 不能当作可注册，也标"不确定"。

### rapp 接其他后缀

| 判断 | 域名 |
|---|---|
| 已被注册或有人在用 | rapp.io、rapp.co、rapp.one、rapp.cloud、rapp.build、rapp.link、rapp.live、rapp.net、rapp.org、rapp.xyz、rapp.space、rapp.pro、rapp.win、rapp.im、rapp.at、rapp.me、rapp.ws |
| 应该可注册 | rapp.run、rapp.host、rapp.tech、rapp.codes、rapp.software、rapp.zone、rapp.land、rapp.center、rapp.network、rapp.direct、rapp.express、rapp.fyi、rapp.tools、rapp.works |
| 不确定 | rapp.is、rapp.gg、rapp.cx、rapp.fm、rapp.to、rapp.vc |

### 不带 rapp、直接描述用途

| 判断 | 域名 |
|---|---|
| 已被注册或有人在用 | appbridge.dev、maindeck.dev、onedesk.dev、appcast.dev、remotely.run、remoteapp.one、remoteapp.io、remoteapp.cloud、remoteapp.xyz、remoteapp.net、remoteapp.org、remoteapp.co |
| 应该可注册 | appremote.dev、maindesk.dev、appbeam.dev、beamapp.dev、apptunnel.dev、appwindow.dev、farapp.dev、windowcast.dev、rmtapp.dev、r-app.dev、re-app.dev、remoteapp.run、remoteapp.tools、remoteapp.host |
| 不确定 | calmdesk.dev、remoteapp.sh、remoteapp.so、remoteapp.to、remoteapp.is |

### 这一轮的判断（我的分析，待用户定）

- 没有找到比 rapp.run 明显更好的。最好的几个（rapp.dev、rapp.app、rapp.io、rapp.co）都被占了。
- 新出现的值得考虑的有三个：
  - **rapp.host**：字面就是"rapp 主机"，和项目里的 `rapp-host` 同名，也能读成"app 托管在别的机器上"。缺点是 .host 这个后缀名声一般。
  - **appremote.dev**：不认识 rapp 的人也能看懂（app 的遥控）。是 .dev 后缀里最直白的一个，但里面没有产品名。
  - **maindesk.dev**：对应"主控台"的主张，同样没有产品名。
- 如果这些都不满意，根子在"rapp"这四个字母太抢手。换一个更独特的产品名，才拿得到又短又是 .dev 的域名。

## 补充 3：让目标用户一眼知道是为自己做的（2026-11-12 22:55 JST 前后查询）

用户把"更好"说清楚了：

> 要让目标用户一眼就能知道为自己所做

目标用户按 `2026-11-12-rapp-requirements-feedback.md` §0.8：Omarchy 用户，和用机械键盘做生产力工作的人（不是游戏用户）；他们手上有多台机器、多个 Agent。
所以这一轮不从产品名出发，而是从这群人怎么称呼自己、在意什么出发，分四个角度找。

| 角度 | 应该可注册 | 已被注册或有人在用 |
|---|---|---|
| 键盘 | onekeyboard.dev、onekeyboard.run、keyboardfirst.dev、keysfirst.dev、keyconsole.dev、keyboardconsole.dev、agentkeyboard.dev、mykeyboard.dev | — |
| 键盘圈的行话 keeb | onekeeb.dev、keebconsole.dev、keebdesk.dev、keebremote.dev、keebfirst.dev、mykeeb.dev、keebhub.dev | keeb.run |
| 多台机器（KVM 切换器） | agentkvm.dev、appkvm.dev、appkvm.com、softkvm.dev、aikvm.dev、kvmapp.dev | kvm.run、agentkvm.com |
| 指挥多个 Agent | manyagents.dev、agentseat.dev、fleetdesk.dev、basestation.dev、deskforagents.dev、agentconsole.run、mainconsole.run、oneconsole.run、consolepad.dev、padconsole.dev | agentdesk.dev、agentdeck.dev、agentcockpit.dev、agentbridge.dev、agentfleet.dev、agenthelm.dev、commanddeck.dev、mothership.dev、homebase.dev、oneseat.dev、agentdesk.run |
| 在这里写、在那边跑 | typehere.run、writehere.dev、thinapp.dev | typehere.dev |
| 借 Omarchy / Hyprland 的命名 | omaremote.dev、hyprremote.dev | — |

thinclient.dev 查询时 DNS 超时，不确定。

### 判断（我的分析，待用户定）

1. **onekeyboard.dev** 最符合这次的要求。
   - 这群人最在意、也最引以为傲的东西就是那把键盘。域名直接说出承诺：一把键盘，管所有机器和 Agent。
   - 两类目标用户都对得上：Omarchy 本来就是以键盘为中心的系统。
   - 是普通英文，不用行话，不借别人的牌子。
   - 和 U3"一套最常用的键盘和显示屏当主控制台"是同一句话。
2. **agentkvm.dev**：有多台机器的人都知道 KVM 切换器，"给 Agent 用的 KVM"一听就懂。
   风险：在 Linux 用户那里 KVM 也指内核虚拟机，Omarchy 用户可能先想到虚拟化。
3. **keebconsole.dev / onekeeb.dev**：keeb 是机械键盘爱好者的行话，圈内人一眼认出是自己人。
   风险：圈外人看不懂；这个词偏向玩键盘的爱好者，其中不少是游戏用户，而目标是做生产力工作的人。

不建议当主域名的：

- "Agent 指挥台"这一类。同类名字大多已被占（agentdesk、agentdeck、agentcockpit、agentbridge、agentfleet 的 .dev 都有人了），说明这个说法很拥挤，用了也分不出谁是谁。
- omaremote.dev、hyprremote.dev。Omarchy 和 Hyprland 的用户确实一眼就懂，但这是借别人的命名，容易被当成官方出品；而且 rapp 还要出 macOS、Windows 版，名字里带 Linux 桌面的牌子不合适。

### 域名和产品名的关系

选 onekeyboard.dev 不等于改产品名。可以产品仍叫 rapp，onekeyboard.dev 做对外的官网，rapp.run 或 getrapp.dev 注册下来跳转过去。
要不要干脆把产品也改叫 One Keyboard，由用户定。

## 补充 4：必须带 rapp，要有趣、有 Agent 时代的味道（2026-11-12 23:40 JST 前后查询）

用户的新要求：

> 必须是带产品名 rapp 的域名。请根据我们产品定位，给出更有趣的，agent 时代的域名

所以补充 3 里不带 rapp 的那些（onekeyboard.dev 等）都不再考虑。这一轮用两种办法找：rapp 接一个有含义的后缀；rapp 和别的词拼成双关（rapp 读音同 rap、wrap）。

### rapp 接有含义的后缀

| 判断 | 域名 |
|---|---|
| 应该可注册 | rapp.boss、rapp.team、rapp.army、rapp.rsvp、rapp.bot、rapp.chat、rapp.watch、rapp.center、rapp.farm、rapp.camp、rapp.band、rapp.quest、rapp.ninja、rapp.fun、rapp.cool、rapp.day、rapp.meme、rapp.channel、rapp.monster、rapp.management、rapp.vision、rapp.plus、rapp.lol、rapp.wtf |
| 已被注册 | rapp.ing、rapp.foo、rapp.zip、rapp.rocks、rapp.work、rapp.agency |

### rapp 拼成双关的 .dev

| 判断 | 域名 |
|---|---|
| 应该可注册 | rappcrew.dev、rappsquad.dev、rappteam.dev、rapparmy.dev、rappfleet.dev、rappboss.dev、rappsession.dev、rappsheet.dev、rappstar.dev、rappgod.dev、rappbattle.dev、rappsody.dev、rappture.dev、rappunzel.dev、rapptile.dev、thatsarapp.dev、itsarapp.dev、rappbot.dev、rappagent.dev、rappagents.dev、agentrapp.dev、rappcenter.dev |
| 已被注册 | rapport.dev、rapport.run、rappel.dev、rappid.dev、rapptor.dev、wrapp.dev |

rapport（默契、融洽）里正好含 rapp，意思也最贴"和 Agent 员工打交道"，可惜 .dev 和 .run 都被占了。

### 判断（我的分析，待用户定）

按"对得上产品定位"排：

| 域名 | 对应定位里的哪一句 | 顾虑 |
|---|---|---|
| **rapp.boss** | 把每个设备、app 当成干活的"员工"，你是老板 | .boss 后缀少见 |
| **rapp.team** | 同上：你的 Agent 团队。第三次查询才拿到结果（前两次超时） | 最不出格，也最不有趣；.team 上同名的团队协作产品很多 |
| **rapp.army** | 用户原话"掌控千军万马" | 带军事色彩，有人会不喜欢 |
| **rapp.rsvp** | 设计语言里"只有'等你'会闪"：Agent 在等你回复 | RSVP 常用于活动邀请，不是人人都会联想到"请回复" |
| **rappcrew.dev** | 一队 Agent；谐音 rap crew | 比上面三个长 |
| **rappsession.dev** | rap session 是"随便聊聊"，session 又是远程会话，一语双关 | 更长 |
| **rapp.chat**、**rapp.watch** | 和员工对话；平时只用余光看一眼 | 直白，不够有趣 |

首选 rapp.boss：短，带产品名，目标用户一看就知道自己是"老板"，和"员工"这个设想是一套说法。
想保留 .dev 的话选 rappcrew.dev。

## 补充 5：从主题的隐喻出发——电影里的高科技平板（2026-11-12 23:45 JST 前后查询）

用户的话：

> 你看我们的隐喻，那几个电影里的高科技平板。应该教师们？

"教师们"按"叫什么"理解（像是输入法的同音错字），即：按这个隐喻，域名应该叫什么。这是我的理解，没有向用户确认。

四套主题对应的电影里，那块屏幕各自扮演的角色（凭印象，没有核对）：

| 主题 | 电影里是什么 | 可以借的通用词 |
|---|---|---|
| MATRIX | 坐在控制台前盯着字符、给里面的人指路的人叫 Operator；里面的程序叫 Agent | operator、console |
| WESTWORLD | 工作人员拿着平板查看、调整机器人；机器人叫 host | host、tablet |
| AVATAR | 人躺进连接舱，远程驱动另一个身体，这个动作叫 link；实验室里是透明的玻璃平板 | link、glass、slate |
| IRON MAN | 头盔里的抬头显示叫 HUD；工作室里是全息台 | hud、holo |

四部电影都没有给"那块平板"起一个共同的名字。科幻里对这种"拿在手里、接入别的系统的控制台"的通称是 deck（赛博朋克小说里的 cyberdeck）。

### 查询结果

下面这些全部"应该可注册"：

rappdeck.dev、rappdeck.com、rappdeck.run、rapp.host、rapphost.dev、rappoperator.dev、rappop.dev、rappops.dev、rappconsole.dev、rapplink.dev、rapphud.dev、rappholo.dev、rappslate.dev、rappglass.dev、rapppad.dev、rapptab.dev、rapptablet.dev、rappcontrol.dev、rappboard.dev、rappbridge.dev、rappcockpit.dev、rappjack.dev、rappterminal.dev、rappmesa.dev、rappdatapad.dev、rappcyberdeck.dev

### 判断（我的分析，待用户定）

| 域名 | 隐喻 | 顾虑 |
|---|---|---|
| **rappdeck.dev**（.com 也空着） | deck 就是科幻里那块控制台的通称。目标用户正好是玩 cyberdeck、机械键盘的那群人，一看就懂；Stream Deck、Steam Deck 也让这个词家喻户晓 | 不是四部电影里的原词 |
| **rapp.host** | WESTWORLD 里被平板管着的机器人叫 host，而 rapp 的被控端本来就叫 `rapp-host` | .host 后缀名声一般；说的是被控的一方，不是你手里那块板 |
| **rappoperator.dev** | MATRIX 里你是 Operator，对面是 Agent。放在 Agent 时代正好 | 长 |
| **rapplink.dev** | AVATAR 里的 link：人在这头，身体在那头 | link 太常见，别人不一定想到电影 |
| **rapphud.dev** | IRON MAN 的 HUD：信息浮在视野边缘，和"信息待在边缘注意力"是一回事 | HUD 只管看，不含操作 |

首选 rappdeck.dev，并把 rappdeck.com 一起注册。

域名里不要直接用片名或角色名（matrix、westworld、jarvis 等），那是别人的商标。上面用的都是通用词。

## 补充 6：给"那种很酷的高科技操控平板"起个好听、好记的名字（2026-11-12 23:55 JST 前后查询）

用户的话：

> 那种很酷的高科技的操控平板，有什么好听的名字，让人能记住

仍然按"必须带 rapp"来找。这一轮多了一种拼法：让 rapp 结尾的 p 和下一个词开头的 p 叠在一起，拼成一个词。这样拼写里 rapp 四个字母完整保留，读起来又是一个名字。

### 叠字拼成一个词

| 名字 | 怎么拼的 | 意思 | 域名 |
|---|---|---|---|
| **Rappilot** | rapp + pilot | 你是驾驶员，驾驶远处的 app 和 Agent；pilot、copilot 正是 Agent 时代的词 | rappilot.dev、rappilot.com 都应该可注册；rappilot.app 已被注册 |
| **Rappanel** | rapp + panel | 控制面板，就是那块操控平板本身 | rappanel.dev、rappanel.com 都应该可注册 |
| **Rappad** | rapp + pad | 手里的那块板；只有 6 个字母，最短 | rappad.dev、rappad.app 应该可注册；rappad.com 在域名贩子手里 |
| **Rapportal** | rapp + portal | 通往别的机器的传送门；里面还藏着 rapport（默契） | rapportal.dev 应该可注册；rapportal.com 已被注册 |
| Rappixel | rapp + pixel | rapp 传的就是像素 | rappixel.dev 应该可注册 |
| Rappatrol | rapp + patrol | 巡视：偶尔去看一眼 | rappatrol.dev 应该可注册 |
| Rapprism | rapp + prism | 棱镜 | rapprism.dev 应该可注册 |
| Rappanorama | rapp + panorama | 全景模式 | rappanorama.dev 应该可注册，但太长 |

### rapp 加一个科幻里的器物名

以下 .dev 都应该可注册：

| 名字 | 器物 |
|---|---|
| Rappdeck | deck，科幻里手持控制台的通称（见补充 5）。rappdeck.com、rappdeck.app 也空着 |
| Rappslate | slate，一整块玻璃板。rappslate.com 也空着 |
| Rappconn | conn，《星际迷航》里"你来指挥"说的是"You have the conn"；也是 connection 的缩写（凭印象，没有核对） |
| Rappvisor | visor，护目镜式的显示 |
| Rapphalo | halo，光环 |
| Rappglyph | glyph，字符；对应 MATRIX 主题满屏的字符 |
| Rappuplink | uplink，上行链路 |
| Rappmonolith | monolith，黑色石板；太长 |
| Rapplasso | lasso，套索：把远处的东西套过来；带西部味，对应 WESTWORLD |
| Rappbaton | baton，指挥棒 |
| Rapphelm、Rappnexus、Rappwrangler、Rappulse | 舵、枢纽、牧马人、脉冲 |

rappmaestro.dev 查询时 DNS 超时，不确定。

### 判断（我的分析，待用户定）

1. **Rappilot**：最好听也最好记。两个音节的 rap 加 pilot，念出来顺；意思一听就懂；.dev 和 .com 都空着。
2. **Rappdeck**：最贴"高科技操控平板"这个隐喻，目标用户里懂的人最多。
3. **Rappad**：最短。
4. **Rappanel**：最直白，但不如前三个有趣。

叠字拼法的一个小毛病：别人听到以后可能拼成 rapilot 或 rapppilot。定下来以后，可以把少一个 p 的写法也注册下来做跳转。

## 补充 7：用户优先考虑 rappad.com、rappad.net（2026-11-13 00:40 JST 前后查询）

用户的话：

> 优先 rappad.com rappad.net

| 域名 | 查到的 | 判断 |
|---|---|---|
| rappad.net | 注册局没有记录，没有 NS | 应该可注册，按普通价格 |
| rappad.com | 2013-05-07 注册，到期日 2027-05-07；域名服务器是 HugeDomains 的出售专用服务器，注册商是 NameBright | 在域名转售商手里，挂牌出售。能买，但是溢价 |
| rappad.dev、rappad.app、rappad.org、rappad.run、rappad.ai | 注册局没有记录，没有 NS | 应该可注册 |
| rappad.io | 没有 NS；.io 的查询结果不可靠 | 不确定，多半可注册 |

rappad.com 的标价没有查到：转售商的页面从这边打不开。据我所知这类转售商的标价常在一千到几千美元，但这个域名的具体价格要用户自己打开 hugedomains.com 搜 rappad.com 才知道。

### 重名（实测）

`https://www.rappad.co` 是一个正在运营的网站，网页标题是"Write and Share Rap Songs Online - RapPad"，一个写说唱歌词的社区。

这意味着：

- 搜"rappad"会先搜到它。
- 名字读音、拼写都一样，只是它把 P 大写成 RapPad。
- 它有没有注册商标没有查过。我不是律师。两边的行业差得远（写歌词和远程控制软件），但要不要因此避开，由用户定。

### 建议（我的分析，待用户定）

1. 先把 rappad.net 注册下来，同时注册 rappad.dev 防止被别人拿走。两个都是普通价格。
2. rappad.com 等看过标价再决定。
3. 下决心之前先想清楚和 RapPad 重名这件事能不能接受。

## 补充 8：rapad.com（少一个 p）（2026-11-13 00:47 JST 前后查询）

用户问"rapad.com 呢"。

| 域名 | 查到的 | 判断 |
|---|---|---|
| rapad.com | 2006-08-05 注册，到期日 2027-08-05，注册商 GoDaddy；打开后跳到 GoDaddy 的出售页（NameFind 渠道） | 挂牌出售，溢价。标价没查到：出售页从这边打不开（403） |
| rapad.net | 已注册，有 NS | 已被注册，在用 |
| rapad.org | 已注册，NS 是 Afternic 的 | 挂牌出售 |
| rapad.dev、rapad.app | 注册局没有记录，没有 NS | 应该可注册 |
| rapad.io | 没有 NS；.io 的查询结果不可靠 | 不确定 |

要注意：rapad 只有一个 p，里面没有 rapp 四个字母，和"必须带产品名 rapp"这条不符。它只能当 rappad 的防错拼跳转，不适合当主域名。

## 补充 9：容易叫的名字，兼顾将来的 Agent 助理（2026-11-13 01:30 JST 前后查询）

用户的话：

> 再提案一些容易叫的名字。这个产品解决了基本的远程使用 app 的问题。后续可能会加 agent 助理，来管理这些远程反馈和交互。

这一轮的标准：两三个音节、念出来顺；名字既能当产品名，将来也能当那个助理的名字，用语音喊得出口。仍然保留 rapp 四个字母。

### 查询结果

| 名字 | 拼法和意思 | .com | .net | .dev |
|---|---|---|---|---|
| **Rappmate** | rapp + mate，伙伴、搭档 | 应该可注册 | 应该可注册 | 应该可注册 |
| **Rapprove** | rapp + approve，批准、放行 | 应该可注册 | 应该可注册 | 不确定（查询被重定向） |
| Rappbuddy | rapp + buddy，伙伴 | 应该可注册 | 应该可注册 | 应该可注册 |
| **Rapply** | rapp + reply，回复 | 已被注册 | 应该可注册 | 应该可注册 |
| Rappal | rapp + pal，朋友 | 挂牌出售 | 应该可注册 | 应该可注册 |
| Rappu | 日语ラップ的读音 | 挂牌出售 | 应该可注册 | 应该可注册 |
| Rapplet | rapp + applet，小程序 | 已被注册 | 应该可注册 | 应该可注册 |
| **Rappa** | 两个音节；日语ラッパ是军号 | 已被注册 | 已被注册 | 应该可注册 |
| Rapple | 两个音节，读音近 apple、ripple | 已被注册 | 已被注册 | 应该可注册 |
| Rappie | 昵称式 | 已被注册 | 已被注册 | 应该可注册 |
| Rappage | rapp + page，呼叫 | 已被注册 | 已被注册 | 应该可注册 |
| Rappster | rapp + ster | 挂牌出售 | 已被注册 | 应该可注册 |
| Rappo | 两个音节 | 已被注册 | 已被注册 | 已被注册 |
| Rappit | 读音近 rabbit | 已被注册 | 已被注册 | 已被注册 |

两个音节的短名字（Rappo、Rappa、Rappit、Rapple、Rappie）的 .com 全都没有了。

### 重名（各搜了一次，没搜到不等于没有）

- Rappit：已经有一个同名的软件产品（一个做 app 的平台，SourceForge 上有条目）。加上三个后缀都被占，排除。
- Rappmate、Rapply：各搜了一次，没有搜到同名的产品，搜出来的都是名字相近的别的东西。
- Rappi：是拉美一家很大的外卖公司，没有列进候选。

### 判断（我的分析，待用户定）

1. **Rappmate**：最适合"现在是产品、将来是助理"。mate 就是搭档，喊它、写它都自然；.com、.net、.dev 三个都空着。
2. **Rapply**：念起来像 reply，正好是助理要管的事（回复和反馈）。缺点是口头上容易被听成 reply 或 apply，而且 .com 没有了。
3. **Rapprove**：对应"放行"。意思准，但是个动词，不像一个可以喊的名字。
4. **Rappa**：最好喊，只有两个音节；日语里ラッパ是军号，吹号集合正好对应"千军万马"。缺点是只剩 .dev，而且英语里 rappa 是 rapper 的俗写。

和前几轮比：Rappilot 和 Rappdeck 的 .com、.dev 也都空着；Rappilot 三个音节，Rappmate 两个音节，更好叫。

## 补充 10：Rapple 和 Rappo（2026-11-13 01:55 JST 前后查询）

用户问"Rapple 和 Rappo 呢"。

### Rapple

| 域名 | 查到的 | 判断 |
|---|---|---|
| rapple.com | 2004-07-26 注册，到期日 2027-07-26；网站打不开 | 已被注册，长期持有 |
| rapple.net | 有网站，标题是 Private Site，要登录 | 已被注册，在用 |
| rapple.app、rapple.ai | 已注册，有 NS | 已被注册 |
| rapple.org、rapple.co | NS 是停放、出售用的服务器 | 挂牌或停放 |
| rapple.dev、rapple.run、rapple.tech | 注册局没有记录，没有 NS | 应该可注册 |
| rapple.io、rapple.sh | 没有 NS；这两个后缀的查询结果不可靠 | 不确定 |

### Rappo

| 域名 | 查到的 | 判断 |
|---|---|---|
| rappo.com | 1997-07-15 注册，到期日 2027-07-14；有一个几乎空白的页面 | 已被注册，长期持有 |
| rappo.net | 打开后跳到一个域名出售平台 | 挂牌出售 |
| rappo.dev | 2023-01-31 注册，到期日 2028-01-31；有网站，标题是 RAPPO.DEV | 已被注册，在用 |
| rappo.app、rappo.org、rappo.io、rappo.co | 已注册或有 NS | 已被注册 |
| rappo.tech | NS 是停放用的服务器 | 停放 |
| rappo.ai、rappo.run | 注册局没有记录，没有 NS | 应该可注册 |
| rappo.sh | 没有 NS；.sh 的查询结果不可靠 | 不确定 |

### 重名（各搜了一次，没搜到不等于没有）

- Rapple、Rappo 都没有搜到同名的软件产品，搜出来的都是名字相近的别的东西（Ripple、Rappit、Rappi 等）。
- rappo.dev 上已经有人在用 RAPPO.DEV 这个名字，是谁、做什么没有细看。

### 判断（我的分析，待用户定）

| | Rapple | Rappo |
|---|---|---|
| 好叫 | 两个音节，像 apple | 两个音节，中文、日文、英文念法都一样 |
| 能拿到的最好的域名 | rapple.dev | rappo.ai（.ai 的年费比 .dev 贵不少） |
| 顾虑 | 读音和拼写都贴着 Apple 和 Ripple；据我所知苹果公司对名字里带 apple 的商标比较敏感，我不是律师 | .com、.net、.dev 全没有；rappo.dev 已有人用同一个名字 |
| 当助理的名字 | 像个水果，不像个人 | 像个名字，喊得出口 |

两个里选 Rappo：更像一个可以喊的助理，rappo.ai 也对得上"Agent 助理"。
但它拿不到 .com 和 .dev；如果这两个后缀要紧，Rappmate 仍然是三个后缀都空着的那个。

## 补充 11：rapppad（三个 p）（2026-11-13 02:15 JST 前后查询）

用户问"rapppad 呢"。即 rapp + pad 不叠字，三个 p 都保留。

### 查询结果

下面这些注册局都没有记录，也都没有 NS，应该可注册：

rapppad.com、rapppad.net、rapppad.dev、rapppad.app、rapppad.org、rapppad.run、rapppad.ai、rapppad.tech、rapppad.xyz，以及带连字符的 rapp-pad.com、rapp-pad.dev。

rapppad.io、rapppad.co 也没有记录和 NS，但这两个后缀的查询结果不可靠，记为"多半可注册"。

这是到目前为止唯一一个 .com、.net、.dev、.app、.ai 全都空着的名字。

### 重名（搜了一次）

没有搜到叫 rapppad 的产品。但搜索引擎会把 rapppad 自动当成 rappad，搜出来的是那个写说唱歌词的 RapPad（网站和一个浏览器扩展）。

### 判断（我的分析，待用户定）

好处：

- 产品名 rapp 完整保留，后面接 pad，意思清楚；写成 RappPad 一眼能看出是两个词。
- 念法和 Rappad 完全一样，好叫。
- 所有主流后缀都能按普通价格注册，不用去买转售商手里的 rappad.com。

毛病：

- 三个 p 连在一起，小写时难认，口头说不清（得补一句"三个 p"）。
- 别人很容易少打一个 p，打成 rappad。rappad.com 在转售商手里，rappad.co 是 RapPad 那个歌词网站，打错的人会走到别人那里去。
- 搜索上会和 RapPad 混在一起。

如果用它：对外一律写成 RappPad；把 rapppad.com、rapppad.net、rapppad.dev 一起注册；rappad.net、rappad.dev 现在也空着，顺手注册下来接住打错的人。

## 补充 12：rappc（2026-11-13 02:18 JST 前后查询）

用户问"rappc 呢"。

| 域名 | 查到的 | 判断 |
|---|---|---|
| rappc.com | 2012-06-02 注册，到期日 2027-06-02；打开后跳到 HugeDomains 的出售页 | 在转售商手里，挂牌出售，溢价。标价没查到 |
| rappc.app | 已注册 | 已被注册 |
| rappc.net、rappc.dev、rappc.org、rappc.run、rappc.ai、rappc.tech | 注册局没有记录，没有 NS | 应该可注册 |
| rappc.io、rappc.co、rappc.sh | 没有 NS；这几个后缀的查询结果不可靠 | 不确定，多半可注册 |
| rapppc.com、rapppc.dev（三个 p） | 注册局没有记录，没有 NS | 应该可注册 |

重名：搜了一次，没有搜到叫 rappc 的产品，出来的都是不相干的缩写。

### 判断（我的分析，待用户定）

- 读法不确定。可以读成 rapp-C，也可以读成 rap-PC。别人第一次看到不知道怎么念，这和"容易叫"相反。
- 读成 rap-PC 时意思是好的：rapp 加 PC，远处那台干活的 PC，和"主要靠远端 PC 的能力"对得上。但要写成 RapPC 才看得出来，而这样写又把 rapp 拆开了。
- 在开发者眼里，结尾带 c 的短名字像命令行工具或编译器（gcc、rustc、protoc 这一类），容易被当成 rapp 的某个命令，而不是产品名。
- .com 在转售商手里，要溢价。

结论：比 Rappmate、RappPad、Rappilot 都弱，不建议当主域名。

## 补充 13：rappd（2026-11-13 14:40 JST 前后查询）

用户问"rappd 呢"。

| 域名 | 查到的 | 判断 |
|---|---|---|
| rappd.com | 2012-05-18 注册，到期日 2031-05-18；有网站，但挡在验证页后面，看不到内容 | 已被注册，有人在用，续费到了 2031 年，不像会放出来 |
| rappd.io、rappd.co | 有 NS | 已被注册 |
| rappd.net、rappd.dev、rappd.app、rappd.run、rappd.ai、rappd.tech | 注册局没有记录，没有 NS | 应该可注册 |
| rappd.sh | 没有 NS；.sh 的查询结果不可靠 | 不确定，多半可注册 |
| rappd.org | 查询被重定向，没拿到结果 | 不确定 |

重名：搜了一次，没有搜到叫 rappd 的产品。有名字相近的开源项目 rapd、rapd2（少一个 p），是别的东西。

### 判断（我的分析，待用户定）

- **Linux 用户会把它读成"rapp 的守护进程"。** 结尾带 d 是 Unix 上后台服务的惯例写法（sshd、systemd、dockerd）。Omarchy 这群人一眼就认得，这是它的好处。
- **但它指的是后台那一头，不是你手里的主控台。** rapp 里真有后台服务（`rapp-service`、`rapp-host`）。产品叫 rappd，别人会以为说的是那个服务，而不是整个产品。
- 圈外人看不懂这个 d，会读成 rapped 或者不知道怎么念。macOS、Windows 用户里这样的人不少。
- 念成 rap-D 只有两个音节，好叫。
- .com 拿不到。

结论：适合当后台服务的程序名或内部昵称，不适合当产品名和主域名。真想留着，注册 rappd.dev 就够了。
