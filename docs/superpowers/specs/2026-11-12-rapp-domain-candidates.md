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

## 补充 14：按定位和用户心智重新想名字和域名（2026-11-14 11:00 JST 前后查询）

用户的话（反馈文档 U101）："根据你对rapp这个项目的定位、用户心智的认识。你再给他取名取域名，应该怎么取"。

依据是 2026-11-14 上午定的心智（U90）：**我的工具都在这里，谁需要我，灯会亮。** 前半句是一个地方，后半句是一盏灯。

### 取名的三条原则（我的分析）

1. 名字要落在"地方"或"灯"上，至少一个。
2. 不带这三类词：remote（会被拿去和远程桌面比）、AI 或 agent（会被拿去和聊天式的多 Agent 工具比）、suite 或 OS（会被当成什么都有的套件）。
3. 有实物感、念得出来：桌、台、板、灯这类东西，而不是抽象的词。

### 做法：名字不换，让域名里的第二个词说出"地方"

`rapp` 原来是 remote app 的缩写，正是第 2 条要避开的那个框。但它短，已经在代码、仓库、文档里到处都是。所以不换名字，只是不再把它展开成 remote app；意思由后面跟的那个词来带。`rapp` 本身也能读出别的意思：英语 rapport 是默契，法语 rappel 是提醒、叫回来。

| 候选 | 意思 | 查询结果 |
|---|---|---|
| **rappdesk** | 桌：工具都摆在上面，位置固定 | rappdesk.com、.dev、.app、.net 注册局都没有记录，没有 NS，应该可注册 |
| **rappdeck** | 操控台、甲板：硬件感更强 | rappdeck.com、.dev、.app、.net 同上，应该可注册 |
| rappconsole、rappboard、rappstation、rapphelm、rapphq | 控制台、板、站、舵、总部 | 这几个的 .com 都应该可注册 |
| rapp.center、rapp.place | 中心、地方 | 应该可注册。rapp.one、rapp.house 已被注册 |
| rapplamp、rapplight、rappbeacon、rappsignal、rapptally、rappandon、rappglow | 落在"灯"上 | 这几个的 .com 都应该可注册；rapplamp.dev 也是 |
| rappel | 法语的提醒、叫回来 | rappel.dev、rappel.app 已被注册；rappel.run 应该可注册 |

和之前的首选 rappad 比：pad 说的是那块设备，desk 说的是那个地方。按现在的心智，地方比设备更准。rappad.com 在域名贩子手里，rappdesk.com 是空的。

### 如果愿意换名字（用户没有这么要求，列出来备查）

| 候选 | 意思 | 查询结果 | 问题 |
|---|---|---|---|
| Desklamp | 台灯。桌和灯两半都在里面 | desklamp.dev 应该可注册；desklamp.com、.net 在域名贩子手里；desklamp.app 已被注册 | 普通词，搜不出来 |
| Tomoru | 日语"灯る"，灯亮起来。和 Sumi 是同一路取法 | tomoru.dev 应该可注册；tomoru.com、.net、.app 已被注册 | 也是日语里的人名 |
| Andon | 安灯：丰田生产线上，哪个工位需要人，那里的灯就亮。和后半句是同一个概念 | andon.dev、andon.app 已被注册；andondesk.com 应该可注册 | 据我所知已有一家做 AI 的公司叫 Andon Labs，在同一个圈子里会撞名。适合当文档里的说法，不适合当名字 |
| 其他 | lampdesk、pilotlamp（指示灯）、calmdesk | lampdesk.dev、pilotlamp.dev、calmdesk.dev 应该可注册；对应的 .com 都已被注册 | |

### 重名（各搜了一次，没搜到不等于没有）

rappdesk、rappdeck 都没有搜到同名的产品。搜出来的是名字相近的别的东西（RepairDesk、RapidDesk 等）。

### 建议（我的分析，待用户定）

- 名字仍然叫 rapp。
- ~~域名取 rappdesk.com，同时把 rappdesk.dev 也拿下。~~ 已改，见补充 16：desk 在这个领域里读作"远程桌面"，改为 rappdeck。
- "灯"这一半不放进域名，放进一句话和标志里：一句话是"你的工具都在这里。谁需要你，灯会亮。"；标志用设计语言里"等你"的那个菱形。

查询方法和之前一样：注册局的 RDAP 记录加 NS 记录。"应该可注册"的意思是查询时两样都没有，不保证注册时还在；实际注册和付款要用户自己做。

## 补充 15：rapdesk（少一个 p）（2026-11-14 11:00 JST 前后查询）

用户的话（反馈文档 U102）："rapdesk 没能不能注册"（按"能不能注册"理解）。

| 域名 | 查询结果 | 结论 |
|---|---|---|
| rapdesk.com | 已被注册：2026-11-07 在 GoDaddy 注册，到期 2027-11-07，NS 在 Cloudflare。网站在用，标题是"RapDesk: marketing software that runs on your own computer"，介绍是八个桌面营销工具（WhatsApp、短信、邮件、找客户、社交推广），支持 Windows 和 macOS | 不能注册，而且有同名的在用产品 |
| rapdesk.net、.dev、.app、.org、.ai | 注册局没有记录，没有 NS | 应该可注册 |
| rapdesk.io、rapdesk.co | 没有 NS；这两个后缀的查询结果不可靠 | 不确定，多半可注册 |

判断（我的分析，待用户定）：不建议用 rapdesk。.com 一周前刚被别人注册，并且已经是一个叫 RapDesk 的桌面软件产品，同样是"装在自己电脑上的桌面工具"。用别的后缀会直接和它撞名，用户搜 rapdesk 先看到的是它。两个 p 的 rappdesk 没有这个问题：rappdesk.com 是空的，也没搜到同名产品。

## 补充 16：desk 这个词的联想（2026-11-14）

用户的话（反馈文档 U103）："叫desk会不会让人联想起rushdesk这类产品做类比？"（"rushdesk"按 RustDesk 理解）。

会，而且这推翻了补充 14 里我的建议。

- 在远程这个领域，名字以 Desk 结尾的几乎都是远程桌面：RustDesk、AnyDesk、ToDesk。在这些名字里 desk 读作 desktop（桌面），不读作"桌子"。
- 所以 rappdesk 会被直接读成"又一个远程桌面"，正是补充 14 第 2 条原则要避开的那个框。我在补充 14 里只想到了"桌子"这一层意思，没有想到这个后缀在这个领域里已经有了固定的读法。
- 另一类以 desk 结尾的是客服工单软件（Zendesk、Freshdesk），也不是 rapp 要的联想。
- 补充 15 的 rapdesk 同样有这个问题，再加上已有同名产品。

**改后的建议（我的分析，待用户定）：rappdeck。**

| | rappdesk | rappdeck |
|---|---|---|
| 这个领域里的联想 | 远程桌面（RustDesk、AnyDesk、ToDesk） | 操控台：驾驶舱（flight deck）、Stream Deck、Steam Deck，都是摆在手边、带按键和灯的实物 |
| 对"地方" | 有，但被"桌面"的读法盖住了 | 有：一块台面 |
| 对"灯" | 没有 | 有一点：操控台上的按键本来就会亮 |
| 域名 | .com、.dev、.app、.net 应该可注册 | .com、.dev、.app、.net 应该可注册 |

其余不带 desk 的候选（rappanel、rappboard、rappconsole、rapphelm、rapp.center）仍然在补充 14 和更早的几节里。其中 console 现在不合适：rapp 已经在设计终端会话的管理，console 会被读成"终端"。

## 补充 17：换成常用的词（2026-11-14 11:10 JST 前后查询）

用户的话（反馈文档 U104）："deck 不常用。请在想象"（按"请再想想"理解）。

条件多了一条：第二个词要是谁都认识的常用词。同时仍然不能读成远程桌面（desk、view）、终端（console）、任务看板或套件。

| 候选 | 词的意思和联想 | .com | 其他 | 问题 |
|---|---|---|---|---|
| **rappcenter** | 中心。系统里人人见过的"控制中心""通知中心"：东西集中在这里管，通知也在这里，两半都沾 | 应该可注册 | rappcenter.dev、rapp.center 应该可注册 | 英式拼写是 centre |
| **rapphub** | 中枢。所有东西都连到它上面。代码里操作端的引擎本来就叫 hub | 应该可注册 | rapphub.dev 应该可注册 | 也可能被读成"一个放 rapp 的市场"（像 Docker Hub） |
| rappboard | 板。用户最早说的就是 dashboard | 应该可注册 | rappboard.dev 应该可注册 | 会让人想到任务看板 |
| rappdock | 坞。Mac 上放 app 的地方就叫 Dock | 应该可注册 | rappdock.dev 应该可注册 | 和 Docker 读音近 |
| rapphome | 家 | 已被注册 | rapphome.dev 应该可注册 | 像智能家居 |
| rapproom、rappspace、rappbase、rappbox、rappone、rapphere、rappwall、rapptable、rappbench、rappcontrol、rappspot、rappbay、rappmain | 房间、空间、基地、盒子、一、这里、墙、桌面、工作台、控制、点、湾、主 | 都应该可注册 | | space 和 base 分别会被读成各家工具里的 workspace 和后端数据库；其余的意思不够准 |
| rappstage、rapplab、rappstudio | 舞台、实验室、工作室 | 已被注册 | | |

单独的后缀：rapp.works、rapp.tools、rapp.plus、rapp.site、rapp.center、rapp.place 应该可注册；rapp.space、rapp.studio、rapp.page、rapp.live、rapp.world 已被注册。

重名（各搜了一次，没搜到不等于没有）：rappcenter、rapphub 都没有搜到同名的产品。

### 建议（我的分析，待用户定）

1. **rappcenter.com**，同时拿下短的 **rapp.center**。center 是最常用的词之一；"控制中心""通知中心"是每个人在手机和电脑上都见过的东西，意思正好是"都在这里管，有事在这里叫你"；它不会被读成远程桌面。
2. 备选 **rapphub.com**。更短，和代码里的名字一致；弱点是可能被读成市场。
3. 再备选 rappboard.com。

## 补充 18：raphub（少一个 p）（2026-11-14 11:55 JST 前后查询）

用户的话（反馈文档 U105）："raphub 呢"。

| 域名 | 查询结果 | 结论 |
|---|---|---|
| raphub.com | 已被注册：2011-04-12 在 GoDaddy 注册，到期 2027-04-12。网站打得开，页面上只有"Raphub"一个词 | 不能注册 |
| raphub.org | 已被注册：2020-09-01 注册，到期 2027-09-01 | 不能注册 |
| raphub.net、.dev、.app、.ai | 注册局没有记录，没有 NS | 应该可注册 |
| raphub.io、raphub.co | 没有 NS；这两个后缀的查询结果不可靠 | 不确定，多半可注册 |

联想：少了一个 p，raphub 会被读成 rap hub，也就是"说唱的聚集地"。搜这个词，出来的全是说唱音乐的 app 和网站。产品名 rapp 也不在里面了。

判断（我的分析，待用户定）：不建议。.com 拿不到；读出来是说唱；而且和产品名对不上。两个 p 的 rapphub.com 是空的，没有这三个问题。

## 补充 19：再看 rappc（2026-11-14 12:00 JST 前后查询）

用户的话（反馈文档 U106）："rappc"。这个名字在补充 12 里查过一次，这次按新的心智和原则重看。

域名的状态和补充 12 一样：

| 域名 | 查询结果 |
|---|---|
| rappc.com | 2012-06-02 注册，到期 2027-06-02，NS 在 namebright，也就是在转售商手里，要溢价 |
| rappc.app | 已被注册：2026-10-20 注册，到期 2027-10-20 |
| rappc.net、rappc.dev、rappc.org、rappc.ai | 注册局没有记录，没有 NS，应该可注册 |

按补充 14 的三条原则看：

- **落在"地方"或"灯"上吗**：只有知道 c 代表什么的人才看得出来。c 可以是 center、console、control、PC、client，名字本身不说是哪一个。
- **避开了那几个框吗**：没有完全避开。读成 rap-PC 时是"远处的那台 PC"，又回到远程桌面的框里；在开发者眼里，结尾带 c 的短名字像命令行工具或编译器（rustc、gcc）。
- **有实物感、念得出来吗**：念法不确定（rapp-C 还是 rap-PC）。

判断（我的分析，待用户定）：和补充 12 的结论一样，不建议当主域名。如果 c 想表达的是 center，rapp.center 把这个词写全了，一看就懂，而且是空的。rappc 适合的用处是当命令行里的短名字，不是给人记的名字。

## 补充 20：故事要大的十个候选（2026-11-14 12:20 JST 前后查询）

用户的话（反馈文档 U107）："你是个营销大师，请再帮我想象域名，列出10个我选择。注意深入理解我们产品希望占据的心智。故事要大，将来我可以做 pc 大屏 分布式个人数据方案 来商业化"。

### 要占的位置（我的分析）

小的说法是"我的工具都在这里，谁需要我，灯会亮"。放大以后是一个品类：**个人总部**。每个人都会有一小群自己的机器，和一群替自己干活的 AI。它们需要一个属于这个人的总部：不在别人的云上，在自己手里。今天它是一个 app；以后可以是一台摆在家里的主机、一面大屏、一套存在自己机器上的数据。

名字要同时能叫今天的 app、以后的硬件、以后的数据方案。

### 一个之前没说透的问题：rapp 读出来像 rap

英语里 rapp 和 rap（说唱）同音。后面跟的词如果常和音乐搭配，整个名字就会被读成说唱的东西。这次查到的实例：

- raphub：搜出来全是说唱网站（补充 18）。
- rappstation：差一个字母就是 RAPSTATION，一个已有的说唱电台网络。
- rappcrew（rap crew，说唱团体）、rappcore（rapcore 是一种音乐风格）同理。

所以第二个词还要过一道筛：不能是常和音乐搭配的词。station、hub、crew、core、land、world 因此被降级或去掉。

### 十个候选

.com 全部是查询时注册局没有记录、没有 NS，应该可注册。

| # | 域名 | 故事 | 延伸到硬件和数据 | 弱点 |
|---|---|---|---|---|
| 1 | **rapphq.com** | 个人总部。你的机器、app、AI 都向这里汇报；需要你时，总部的灯亮。和文档里一直用的"员工"是一套话 | 主机叫 HQ，大屏是总部的作战墙，数据是总部的档案 | hq 是缩写，要一个字母一个字母念 |
| 2 | **rappbridge.com** | 舰桥。你是舰长，设备是舰队，app 是船员；舰桥是唯一能看到整条船的地方 | 大屏就是舰桥的主屏幕，最有画面 | bridge 也有"转接器"的意思，会把故事读小 |
| 3 | **rappone.com** | 一。一块屏，一个 key，一个地方 | 硬件最顺口：Rapp One | 意思靠解释；念出来像 rap-pone |
| 4 | rappcenter.com（加 rapp.center） | 指挥中心。人人见过控制中心、通知中心 | 中等：更像软件的名字 | 平，不出挑 |
| 5 | rappbase.com | 大本营。一切回到这里，数据也落在这里 | 数据方案最顺：base 本来就有"数据放在这里"的意思 | 会被读成后端数据库服务 |
| 6 | rappkeep.com | 城堡的主楼，也是"保管"。属于你的东西守在这里 | 数据方案很顺：keep your data | keep 当"主楼"讲不常用；会想到 Google Keep |
| 7 | rappgrid.com | 个人电网。你的几台机器连成一张网，算力和数据像电一样流动 | 分布式的故事最直接 | 说的是网，不是地方；偏基础设施 |
| 8 | rappharbor.com | 港。船（设备）停在这里，港口有灯塔；数据上还有"安全港"的意思 | 数据方案顺 | 长；英式拼写是 harbour |
| 9 | rappcommand.com | 指挥。你在指挥，它们在执行 | 中等 | 长；command 也是"命令行"的命令 |
| 10 | rappdom.com | 领地。像 kingdom、freedom 的那个 dom：这是你的地盘 | 数据主权的故事顺 | 是造的词；也可能被读成 rap 的粉丝圈 |

没进前十但查过的：rappstation、rapphub（有上面说的说唱读法）、rappfleet、rappcrew、rappland、rappnest、rappcastle、rappmind、rappcore 的 .com 都应该可注册；rappcloud、rappos、rapphive、rappsphere、rappworld 的 .com 已被注册。

重名（各搜了一次，没搜到不等于没有）：rapphq、rappbridge 没有搜到同名产品；rappstation 搜到的是 RAPSTATION。

### 建议（我的分析，待用户定）

1. **rapphq.com。** 词最小，故事最大。"总部"能同时装下 app、主机、大屏、数据四样东西；它和"员工"是同一套比喻，不用另讲一个故事。六个字母。
2. rappbridge.com。画面感最强，最适合大屏。
3. rappone.com。如果最看重将来硬件的名字。

## 补充 21：主驾驶，pilot（2026-11-14 13:05 JST 前后查询）

用户的话（反馈文档 U108）："主驾驶员那个单词呢"。按 pilot 理解。这个名字在补充 6 里出现过（Rappilot），这次按"故事要大"重看。

| 域名 | 查询结果 |
|---|---|
| rappilot.com、.dev、.net、.ai | 注册局没有记录，没有 NS，应该可注册 |
| rappilot.app | 已被注册 |
| rappilot.io | 没有 NS；这个后缀的查询结果不可靠，多半可注册 |
| rapppilot.com、.dev（三个 p） | 应该可注册 |
| rappcaptain.com、.dev（机长） | 应该可注册 |

重名（搜了一次，没搜到不等于没有）：没有搜到叫 rappilot 的产品。

### 故事（我的分析）

**现在人人都在卖副驾驶（Copilot）。主驾驶是你。** rapp 给的是主驾驶的那个位子。

它和已有的东西对得上：

| 飞行里的东西 | rapp 里的东西 |
|---|---|
| 主驾驶 | 用户：看管，而不是每一步都自己动手 |
| 副驾驶 | 各个 app 里的 AI，也就是"员工" |
| 驾驶舱：所有仪表都在面前 | "我的工具都在这里" |
| 指示灯。英语里指示灯就叫 pilot lamp | "谁需要我，灯会亮" |
| 塔台 | 用户的另一个项目 Tower.md |
| 飞行记录仪 | 带时间线的记录和审计 |

驾驶舱的设计里有一条做法，据我所知叫"暗舱"：一切正常时灯都不亮，亮了就是要人处理。这和设计语言的"颜色只表示要你处理"是同一条。这一条我没有核对出处，写进正式文档前要查。

按筛子看：是常用词；不会读成远程桌面；和 rap 搭在一起没有音乐上的意思。

### 弱点

- 它是拿 Copilot 当对照来立的，所以会被放进 AI 工具那一堆里看。带 pilot 的 AI 产品名已经很多。
- pilot 还有"试点、试用"的意思。
- 拼写：rappilot 里 rapp 和 pilot 共用一个 p。有人会打成三个 p 或一个 p。建议把 rapppilot.com 一起注册，指到同一个地方。
- 它说的是人的角色，不是一样东西。叫 app 很顺；叫将来的主机和数据方案，不如 hq、base 这类词顺。

### 和 rapphq 比（我的分析，待用户定）

| | rappilot | rapphq |
|---|---|---|
| 一句话讲清楚 | 更强：副驾驶到处都是，主驾驶是你 | 要多解释一句什么是个人总部 |
| 情绪 | 有：我在掌控 | 平 |
| 装得下硬件和数据 | 一般 | 更好 |
| 和已有的东西 | 对上 Tower.md、指示灯、记录 | 对上"员工" |

建议：**首选改为 rappilot.com**，同时注册 rapppilot.com。故事的力度比产品线的整齐更要紧；硬件和数据到时候可以用"驾驶舱""记录仪"这些同一套里的词来叫。rapphq.com 作为第二选择。

## 补充 22：remote.app（2026-11-14 13:15 JST 前后查询）

用户的话（反馈文档 U109）："remote.app 这个域名呢"。

| 域名 | 查询结果 |
|---|---|
| remote.app | 已被注册：2022-10-30 注册，到期 2027-10-30，注册商 Dynadot，NS 在 Afternic（域名交易平台）。Afternic 的页面写着在售，一口价 17,273 美元，也可以出价 |
| remoteapp.com、remoteapp.dev、remoteapp.app、remote-app.com | 都已被注册，NS 多是停放页 |
| rapp.app | 已被注册 |

判断（我的分析，待用户定）：能买到，但不建议当主域名。

- **好处**：一眼就懂，正是用户最早要的那种"一眼就能看明白"的域名；remote app 也是 rapp 这个名字的原意。
- **它把产品放回了要避开的那个框**。remote 会让人拿它和远程桌面比（补充 14 的第 2 条原则）。它讲的是一个工具能做什么，不是"个人总部""主驾驶是你"这种大的故事。
- **它不是一个能占住的名字**。remote 是个普通词；已经有一家很大的公司就叫 Remote（remote.com，做跨国雇佣和薪酬的），remote.app 容易被当成它家的 app。remote 还会被读成"遥控器"。
- **贵**：一万七千多美元，而别的候选都是普通注册价。

如果将来想要一个"一眼就懂"的入口，可以在预算宽裕时买来跳转到主域名；现在不值得。

## 补充 23：给 rapp 的 r 新的解释（2026-11-14）

用户的话（反馈文档 U110）："那我们能给rapp的r一些新的解释吗？"

可以。名字不动，只换 r 代表的词，就能离开 remote 那个框。标准和补充 14 一样：这个词要指向"都在这里"、"灯会亮"或者"我在掌控"三者之一，并且是常用词。以下都是我的提议。

| r 代表 | rapp 读作 | 指向哪一半 | 评价 |
|---|---|---|---|
| **Ready** | ready apps：随时待命的 app | 都在这里；也沾灯（设备上"就绪"的那盏灯） | 最稳。词最常用，一句话就能说清：你的 app 都在，随时待命，需要你时才叫你。和"员工待命"是一套话 |
| **Radar** | radar：雷达 | 两半都有：什么都看得见，有情况才亮一个点 | 画面感最强，也是驾驶舱里的东西 |
| **Roger** | Roger：飞行员在无线电里说的"收到" | 我在掌控 | 和 pilot 的故事是一套。据我所知 Roger 原本就是字母 R 的旧读法，意思是"收到"（没有核对出处）。适合当口吻，不适合当正式解释 |
| Resume | resume：回来接着干 | 回来（工作域研究里最要紧的时刻） | 准，但 resume 还有"简历"的意思 |
| Real | real apps：真的 app | 定位上的区别：用的是官方 app 和自己的订阅，不是套壳的聊天窗口 | 是卖点，不是心智 |
| Reach | reach：够得着 | 都在这里 | 是 remote 的温和说法，框没有变 |
| Rally | rally：集结 | 都在这里 | 动词，有劲，但不常用 |
| Roam | roam：跟着人走 | 换设备接着用 | 只说了一个功能 |
| Rapport | rapport：默契（rapp 是它的前四个字母） | 人和工具的关系 | 好听，但要解释 |

建议（待用户定）：

- 对外的解释用 **Ready**：rapp，ready apps。
- **Roger** 留作口吻里的一个词：用户处理完一件"需要你"的事，界面可以回一句 Roger。它把 r、pilot、"需要你"三样串在了一起。
- 不再在任何地方写 remote app。

这一条和域名是两件事：r 的解释是"名字是什么意思"，域名里的第二个词（pilot、hq）是"它是什么东西"。两者可以同时用，比如 rappilot.com 加上"ready apps"。

## 补充 24：rogerapp（2026-11-14 13:20 JST 前后查询）

用户的话（反馈文档 U111）："rogerapp"。

| 域名 | 查询结果 |
|---|---|
| rogerapp.com | 已被注册（2020-03-22 起，到期 2027-03-22），打开后跳到 HugeDomains 的出售页：在转售商手里，要溢价 |
| rogerapp.net | 已被注册（2026-05-28 注册） |
| rogerapp.ai | 已被注册（2023-08-02 起，到期 2029-08-02） |
| roger.app、rogerapps.com | 已被注册 |
| rogerapp.dev、rogerapp.app | 注册局没有记录，没有 NS，应该可注册 |
| rogerapp.io | 没有 NS；这个后缀的查询结果不可靠，多半可注册 |

重名（搜了一次）：叫 Roger 的 app 已经很多。搜到的有家庭健康助手、对讲机式的语音消息、设备管理、门禁钥匙、企业软件里的助手，还有加拿大电信公司 Rogers 的 app。

判断（我的分析，待用户定）：不建议当名字或主域名。

- Roger 首先是一个人名。rogerapp 会被读成"罗杰的 app"，"收到"那层意思要解释才有。
- 这个名字太挤：.com、.net、.ai 分别在三家手里，同名的 app 一大把，搜不出来，也占不住。
- 把 r 展开写进域名以后，产品名 rapp 反而不在里面了。

Roger 的用处还是补充 23 说的那个：当口吻里的一个词，不当名字。想把"主驾驶"这一套放进域名，用 rappilot.com。

## 补充 25：更短的名字（2026-11-14 14:40 JST 前后查询）

用户的话（反馈文档 U112）："我希望更短一些，rappilot 有点长"。rappilot 是 8 个字母。这一轮只看 7 个字母以内的。

| 域名 | 字母数 | 意思 | .com | 评价 |
|---|---|---|---|---|
| **rapphq.com** | 6 | 个人总部 | 应该可注册（rapphq.net、.app 也是） | 短，意思清楚，故事大。和"员工"是一套话 |
| **rappx.com** | 5 | X：地图上标 X 的那个点，"就在这里"；也是跨设备的"跨" | 应该可注册（rappx.dev、.app 也是） | 最短。X 本身没有固定的意思，要靠一句话来带；带 X 的名字很多，容易显得泛 |
| rappbox.com | 7 | 盒子：摆在家里的一台主机，数据也装在里面 | 应该可注册 | 硬件和数据的故事顺；对今天的 app 来说偏小 |
| rappone.com | 7 | 一 | 应该可注册 | 硬件名字顺；意思靠解释 |
| rapptop.com | 7 | 像 desktop、laptop 那样的"某某 top" | 应该可注册 | 有巧思，像一个新的设备品类；要解释 |
| rappnav.com | 7 | 领航 | 应该可注册 | 留在飞行这一套里，但 nav 更像"导航栏" |
| rappcab.com | 7 | 驾驶室 | 应该可注册 | cab 更常被读成出租车 |
| rappsky.com、rappjet.com、rappfly.com | 7 | 天空、喷气机、飞 | 应该可注册 | 留在飞行这一套里，但说的不是"地方"也不是"灯"；fly 在说唱里是常用词，会被读成音乐 |
| rappops.com | 7 | 作战室、运维 | 应该可注册 | 会被读成运维工具 |

查了但拿不到的：rappod.com（pod，座舱；已被注册）、rappace.com（王牌飞行员；已被注册）、rappcap.com（机长；在交易平台上出售）、rappon.com、rappup.com、rappgo.com、myrapp.com、rappair.com、rappdot.com、rapilot.com 都已被注册。rappad.com 仍在转售商手里。

重名（各搜了一次，没搜到不等于没有）：rapphq、rappx 都没有搜到同名的产品。

### 建议（我的分析，待用户定）

- **rapphq.com**。六个字母，是这一轮里唯一又短、意思又不用解释的。
- "主驾驶是你"不必放在域名里。它可以是那句话，Roger 是口吻，ready apps 是 r 的解释；域名只管短和好记。
- 只求最短的话是 rappx.com，但它要多花力气讲清楚 X 是什么。

## 补充 26：rapps.com（2026-11-14 15:10 JST 前后查询）

用户的话（反馈文档 U113）："rapps.com"。

| 域名 | 查询结果 |
|---|---|
| rapps.com | 已被注册：1996-07-01 注册，到期 2027-06-30。网站打不开，但邮件记录指向 Google 的企业邮箱，也就是有人在拿它收发邮件。没有看到出售的页面 |
| rapps.org | 已被注册（1998 年起） |
| rapps.net | 已被注册（2023 年起）。网站是一家叫 Rapps 的建筑工程公司 |
| rapps.app | 已被注册（2026-03-07 注册） |
| rapps.ai | 已被注册（2026-03-12 注册，到期 2031 年） |
| rapps.co | 有 NS，已被注册 |
| rapps.dev、rapps.run | 注册局没有记录，没有 NS，应该可注册 |
| rapps.io、rapps.sh | 没有记录也没有 NS；这两个后缀的查询结果不可靠，多半可注册 |

判断（我的分析，待用户定）：

- **rapps.com 拿不到。** 持有了三十年，还在用来收发邮件，也没有挂出来卖。要买只能自己去联系持有人，成不成、多少钱都不知道。
- **名字本身有好的一面**：只有五个字母；加了 s 以后正好读成复数，和补充 23 的"ready apps"对得上，说的是"你的那一群 app"。
- **问题**：产品名要从 rapp 改成 rapps；Rapps 是一个姓；几个常用后缀分别在不相干的人手里（一家建筑公司，还有今年三月刚被注册走的 .app 和 .ai），占不住；念出来和 raps 一样。
- 喜欢这个名字的话，能拿到的是 rapps.dev。但 .com 在别人手里的名字，用户记成 .com 时会走到别人那里去。

和 rapphq.com 比：rapps 短一个字母，但 .com 拿不到，名字也要改。仍然建议 rapphq.com。

## 补充 27：rap、rapping 这个词能带出的比喻（2026-11-14 15:20 JST 前后）

用户的话（反馈文档 U114）："rapping 相关隐喻"。

之前我把"rapp 读起来像 rap"当成一个要躲开的问题（补充 20）。换个方向：rap 这个词本身就有几层意思，其中一层正好是 rapp 要占的心智。以下都是我的整理和提议。

### rap 的几层意思

| 意思 | 例子 | 对 rapp |
|---|---|---|
| **敲，尤其是敲门** | a rap on the door，门上敲了一下 | 最贴。"谁需要我，灯会亮"换成声音就是"有事敲门"。敲门是有礼貌的打扰：先敲，不闯进来 |
| 聊，说话 | rap session，坐下来聊 | 和员工说话；rapport（默契）也是这个词根的近亲 |
| 说唱 | | 见下面一节 |
| 名声、记录 | rap sheet，记录在案的单子 | 带时间线的记录、审计 |
| 同音的 wrap：包起来；收工 | that's a wrap，收工了 | "把你的 app 都包在一起"；"开工、收工"的快捷动作 |
| 近音的 rapt：全神贯注 | rapt attention | 专注 |

另外，据我所知瑞典语里 rapp 是"快、利落"的意思（没有核对）。

### 最值得用的：敲门

**rapp = rap + app：会敲门的 app。**

- 这样 r 不需要另找一个词来解释，名字自己就有出处。
- 它说的是后半句心智，而且比"灯"多一层意思：敲门是对方主动、但把决定权留给你。平时安静，有事敲一下，你来开门。这和"尽量减少提醒"（U69）、"只有等你会闪"是一个意思。
- 它也能落到产品上：等你处理的那一声提示音，就做成两下敲门声；用户处理完，回一句 Roger。
- 平板上用手指点屏幕，英语里也可以叫 rap。你敲它，它敲你。

一句话可以是：**你的 app 都在这里。有事，它们会敲门。**

### 说唱那一套：可以当口吻，不当定位

说唱的行话里有不少词碰巧对得上：

| 行话 | 原意 | 对上的东西 |
|---|---|---|
| MC | 主持人 | 主控的人，也就是用户 |
| crew | 一伙人 | 员工 |
| flow | 说唱的节奏 | 心流，专注 |
| freestyle | 即兴 | 不要求用户先有结构（U94） |
| cypher | 围成一圈轮流说唱；和 cipher（加密）同音 | 只有持 key 的设备才在圈里 |
| bars | 小节 | 流量标签上的那几格 |
| beat | 节拍 | 设备的心跳 |
| drop the mic | 说完扔下话筒 | 收工 |

好处是好玩、好记，把同音这件事从弱点变成特点。风险是定位会跑偏：别人会以为这是个和音乐有关的东西，搜索结果也会和说唱混在一起。所以我的建议是只拿来当文案和彩蛋里的口吻，不写进"它是什么"。

### 相关的域名（顺手查的）

| 域名 | 查询结果 |
|---|---|
| rapping.com、rappin.com | 已被注册，NS 是停放或交易平台 |
| rapping.app | 已被注册 |
| rapping.dev、rappin.dev | 应该可注册 |
| rapptap.com、rappknock.com | 应该可注册 |
| raptap.com | 在交易平台上出售 |

### 建议（待用户定）

- 名字的出处改讲"敲门"：rapp 是 rap 加 app。这比补充 23 里给 r 找一个词（Ready）更自然；Ready 可以留作副的解释。
- 口吻里可以用 Roger 和少量说唱的词。
- 域名不受影响：仍然是 rapphq.com。"敲门"是名字的故事，"总部"是它是什么。

