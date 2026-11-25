# 总览「打开应用」菜单 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 每台远程设备列底部（版本号右侧）加「打开应用 ▾」，点开是一个可筛选的下拉菜单，一步打开/切到该设备上的应用。

**Architecture:** 纯函数 `deviceAppGroups` 把 `AppList` + `TermList` 排成分组（与设备页同序）；`showOpenAppsMenu` 用 `showGeneralDialog`（透明遮罩、点外面关）把菜单贴在链接下方/上方，菜单内 `ListenableBuilder(state)` 实时刷新探测结果和星标。

**Tech Stack:** Flutter（gui/），flutter_test widget 测试。执行方式：Native（用户要求全部做完、中途不问）。

**Spec:** `docs/superpowers/specs/2026-11-25-rapp-overview-open-apps-design.md`

## Global Constraints

- 只列正在运行的应用；不改协议、不改主机端。
- 只放远程设备列；本机列不放。
- 文案：链接「打开应用」、分组「屏幕」「终端」「应用（N）」、「正在读取…」、「没有匹配的应用」、「设备详情 ›」、「已打开」「打开」、包名框沿用设备页文案「其他 app 的包名（例：com.apple.TextEdit）」。
- 菜单宽 290；行高 32；链接点击区高 ≥ 48（沿用「blocks and buttons are at least 48 tall」）。
- 不在 main 上提交；分支 feat/overview-open-apps。

## Review Focus

- 设备离线/hub 不可用：链接灰、点不开；菜单开着时设备掉线 → 行点击不崩，仍可关。
- 探测结果还没回来（apps == null）：显示「正在读取…」，回来后菜单原地刷新。
- 文本终端设备（graphical == false）：没有屏幕/应用组，只有终端组 + 提示；无包名行。
- 筛选后为空时回车：什么都不做，不崩。
- 菜单贴近窗口底部：往上翻，不溢出。

---

### Task 1: 分组函数 `deviceAppGroups`

**Files:**
- Create: `gui/lib/ui/device_apps.dart`
- Test: `gui/test/ui/device_apps_test.dart`

**Interfaces:**
- Produces:
  - `class DeviceAppGroup { final String title; final List<HubApp> apps; }`
  - `List<DeviceAppGroup> deviceAppGroups(AppList? apps, TermList? terms)` — 屏幕（`desktop:`，有才有）→ 终端（`showsTermsEntry(terms)` 时一行 `HubApp(termsEntry, termsEntryName)`，applications 为真时再跟上 `terminalAppsOf`——否则 Terminal.app 等在菜单里打不开）→ `应用（N）`（`orderApps(..., entry: showsTermsEntry(terms))` 去掉 desktop；graphical == false 时没有屏幕/应用组）。空组不出现。
  - `List<DeviceAppGroup> filterAppGroups(List<DeviceAppGroup> groups, String query)` — 名字包含（不分大小写，trim），空组去掉；空 query 原样返回。

- [ ] **Step 1: 写失败测试**：`desktop + terminal app + Safari + terms 可用` → 标题 `['屏幕','终端','应用（1）']`，终端组唯一一项 app == `termsEntry`，应用组不含终端类 app；terms 不可用时终端类 app 留在应用组；`capabilities: {'graphical': false}` → 只有终端组；apps == null → 只有终端组（若可用）；filter `'saf'` → 只剩 `应用（1）` 里的 Safari，组标题数字按筛选前不变。
- [ ] **Step 2:** `cd gui && ~/development/flutter/bin/flutter test test/ui/device_apps_test.dart` → FAIL（文件不存在）。
- [ ] **Step 3:** 实现上面两个函数。
- [ ] **Step 4:** 同命令 → PASS。
- [ ] **Step 5:** commit `feat(gui): group a device's apps for the overview menu`。

### Task 2: 菜单 + 总览链接

**Files:**
- Create: `gui/lib/ui/open_apps_menu.dart`
- Modify: `gui/lib/ui/overview.dart`（`_Column` 底部行；去掉 `open-app-$id`）
- Test: `gui/test/ui/overview_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `deviceAppGroups` / `filterAppGroups`。
- Produces: `Future<void> showOpenAppsMenu(BuildContext anchor, MainState state, String id)`；Keys：链接 `open-apps-$id`，菜单 `open-apps-menu`，筛选框 `open-apps-filter`，行 `open-apps-row-$app`，星 `open-apps-star-$app`，包名框 `open-apps-bundle`，包名打开 `open-apps-bundle-open`，详情 `open-apps-details`。

- [ ] **Step 1: 写失败测试**（overview_test，fake 的 `apps` 回复按 `appsOf[id]` 给列表）：
  - `open-apps-m1` 存在、`open-apps-local` 不存在、版本号与链接同一行（dy 中心差 < 4）、链接右边缘 == 列右边缘（±1）、高度 ≥ 48；`open-app-m1` 不再存在。
  - 设备离线 → 点链接不出 `open-apps-menu`。
  - 点开：出现「屏幕」「应用（2）」；点 `open-apps-row-com.x.Notes` → `s.entries` 含该 app 且菜单消失。
  - 点 `open-apps-star-com.x.Notes` → `s.isFavorite('m1','com.x.Notes')` 为真，菜单还在。
  - 在筛选框输入 `note` → 只剩 Notes 行；按回车 → 打开 Notes；输入 `zzz` → 「没有匹配的应用」，回车无事。
  - ↓ 一次再回车 → 打开第二项。Esc → 菜单关闭。
  - `open-apps-details` → `s.panel == PanelTab.devices && s.deviceTab == 'm1'`，菜单关闭。
  - 包名框输入 `com.y.Pages` 回车 → `s.entries` 含 `com.y.Pages`。
  - 删掉旧测试 `an empty host column offers 打开 app`；`blocks and buttons are at least 48 tall` 里的 `open-app-m2` 换成 `open-apps-m2`。
- [ ] **Step 2:** `flutter test test/ui/overview_test.dart` → 新测试 FAIL。
- [ ] **Step 3:** 实现：
  - 链接：`_Column` 底部一行 `ConstrainedBox(minHeight: 48)` 的 Row：版本号（可空）+ Spacer + 链接（InkWell，「打开应用」+ `Icons.arrow_drop_down`，颜色 `t.on`，禁用时 `t.muted` 半透明）。启用条件 `state.hubUsable && !col.offline`。Semantics label「打开应用，<设备名>」。
  - 菜单：`showGeneralDialog(barrierDismissible: true, barrierColor: transparent, barrierLabel: '关闭')`；用链接 RenderBox 算位置，`CustomSingleChildLayout` 右对齐链接，下方放不下就放上方，最大高度 = 可用空间 − 12，最小不小于 200。打开时 `state.probe(id)`（刷新正在运行列表）。
  - 菜单体：`ListenableBuilder(listenable: state)`；顶部筛选框（非 iOS 自动聚焦）；中间可滚动列表：组标题 + 行（灯：`state.entries` 里 key `'$id/$app'` 的 lamp，否则 `Lamp.notOpened`；名字；「已打开」/高亮时「打开」；星：桌面没有）；高亮行用 `t.raiseBox()` 底色；apps == null 且无组 → 「正在读取…」；筛选为空 → 「没有匹配的应用」；探测出错且无 apps → `disconnectWord(error)`。底部：applications 为真时包名行；然后「设备详情 ›」。
  - 键盘：筛选框外包 `CallbackShortcuts`：↑/↓ 改高亮（夹在 0..n−1），回车打开高亮项，Esc 关闭。
- [ ] **Step 4:** `flutter test test/ui/overview_test.dart test/ui/device_apps_test.dart` → PASS；`flutter analyze` 无问题。
- [ ] **Step 5:** commit `feat(gui): 总览设备列底部「打开应用」下拉菜单`。

### Task 3: 收尾

- [ ] 全量 `flutter test`（在 gui/），`flutter analyze`；`git checkout gui/pubspec.lock`。
- [ ] `tasks/todo.md` 加实机检查项（macOS 点开/筛选/上翻、iPad 触摸、Linux）。
- [ ] 整分支评审（fresh reviewer），修完再交给 rapp-49。
