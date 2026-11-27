# 总览本机列：连上的服务 + PC 默认折叠 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the 本机 column is open it lists 中心服务 and LLM 网关 with a lamp and a short status. On PC the column folds when nobody is connected in.

**Architecture:**
- A new `LocalServices` widget reads three things the app already has: `StateSync` for the center, the `stateHost()` of the service or hub for which device runs it, and `LlmEndpoint` plus `LlmApi.probe` for the gateway. The gateway probe runs on a periodic timer that lives only while the widget is mounted.
- `MainState`'s fold flag becomes a per-run user choice. On PC the column follows whether there are inbound sessions until the user makes a choice.

**Tech Stack:** Flutter/Dart (gui/), flutter_test widget tests.

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-overview-local-services-design.md`

## Global Constraints

- The copy is fixed:
  - group title `连上的服务`;
  - row names `中心服务` and `LLM 网关`;
  - center states `连接中…` / `没找到` / `已关` / `连不上`;
  - gateway not configured `没设置`;
  - the local device is named `本机`.
- Lamps:
  - green = `Lamp.active`;
  - gray = `Lamp.offline`, or `Lamp.connecting` while waiting;
  - red = `Lamp.disconnected`.
- The gateway is probed on show and then every 60 s. There is no probe while the widget is unmounted (folded, or away from 全景) or not configured.
- The rows are read-only: no tap handlers.
- The folded strip is unchanged: OS mark, lamp and name only.
- iPad/Duo folding is unchanged. Remote columns never fold.
- Don't touch version numbers, tags, push, `website/releases.json`, or the user's uncommitted docs in the main checkout. Run flutter as `~/development/flutter/bin/flutter` and revert `gui/pubspec.lock` after.

## Review Focus

1. A probe is still in flight when the column folds or the overview closes. Expected: no setState after dispose and no exception. (Task 1 test `a probe answering after unmount is dropped`.)
2. The LLM endpoint is edited while the row is visible. Expected: it re-probes the new endpoint, and an answer for the old one is dropped. (Task 1 test `a new endpoint re-probes and drops the old answer`.)
3. `stateHost()` throws or returns null. Expected: the center row falls back to the url's `host:port` instead of blank or crashing. (Task 1 test `host lookup failing falls back to the address`.)
4. On PC the user folds the column while someone is connected in, and then sessions come and go. Expected: it stays folded for the rest of the run. (Task 2 test `a manual fold sticks while sessions come and go`.)
5. A long device name or a long probe failure line in a 220-wide column. Expected: ellipsis, no overflow exception. (Task 1 test `long text ellipsizes`.)

---

### Task 1: `LocalServices` widget

**Files:**
- Create: `gui/lib/ui/local_services.dart`
- Test: `gui/test/ui/local_services_test.dart`

**Interfaces:**
- Consumes:
  - `StateSync` (`status`, `url`; it is a ChangeNotifier);
  - `ServiceSwitchApi.stateHost()`;
  - `LlmEndpoint` (`configured`, `base`, `url`);
  - `LlmApi.probe(LlmEndpoint) → Future<LlmProbe>` (`LlmProbeOk` / `LlmProbeFailed(line)`);
  - `StatusLamp(Lamp)`.
- Produces:
  ```dart
  class LocalServices extends StatefulWidget {
    const LocalServices({super.key, this.sync, required this.llm, required this.llmApi, this.hostApi,
        this.localId, required this.nameOf, this.every = const Duration(seconds: 60)});
    final StateSync? sync;          // null → no 中心服务 row
    final LlmEndpoint llm;
    final LlmApi llmApi;
    final ServiceSwitchApi? hostApi; // where the center runs; null → address only
    final String? localId;          // this device's id, written 本机
    final String Function(String id) nameOf;
    final Duration every;
  }
  ```
- Keys: `local-services` (the group), `local-service-center`, `local-service-llm` (rows). Each row has a `StatusLamp` and a single-line, ellipsized status text.

**Row rules:**

| Row | Condition | Lamp | Text |
|---|---|---|---|
| center | connected, host known | active | `本机 · :<port>` when host == localId, else `<nameOf(host)> · :<port>` |
| center | connected, host unknown or the lookup failed | active | `<url.host>:<url.port>` |
| center | connecting | connecting | `连接中…` |
| center | none | offline | `没找到` |
| center | off | offline | `已关` |
| center | unreachable | disconnected | `连不上` |
| llm | `!configured` | offline | `没设置` |
| llm | configured, no answer yet | connecting | authority of `base` (e.g. `localhost:28001`) |
| llm | last probe ok | active | authority of `base` |
| llm | last probe failed | disconnected | the probe's `line` |

`stateHost()` is asked each time the center reaches connected or its url changes. An answer that comes back after the url has changed again, or after unmount, is dropped.

- [ ] **Step 1: Write the failing tests** in `gui/test/ui/local_services_test.dart`.
  - Use `FakeStateSync(tmp.path)` from `test/fakes.dart`. Set `status` and `url`, then call `notifyListeners()`.
  - Add a `_FakeLlm extends LlmApi`, modelled on `side_panel_test.dart:957`. It counts calls and returns queued `Completer<LlmProbe>`s.
  - Add a `_FakeHost implements ServiceSwitchApi` whose `stateHost` returns or throws as configured.
  - Pump inside `SizedBox(width: 220)` with the app theme wrapper the overview tests use.
  - Tests and their assertions:
    - `center connected on this device reads 本机 · :28003`: sync connected with url `http://127.0.0.1:28003`, host = localId `111`. The row text is `本机 · :28003` and the lamp is `Lamp.active`.
    - `center on another device names it`: host `222` with `nameOf: (id) => 'Mac mini'`. Text `Mac mini · :28003`.
    - `host lookup failing falls back to the address`: stateHost throws. Text `127.0.0.1:28003`, no exception.
    - `center states map to their words`: connecting → `连接中…`/connecting; none → `没找到`/offline; off → `已关`/offline; unreachable → `连不上`/disconnected.
    - `no sync, no center row`: `find.byKey(Key('local-service-center'))` findsNothing; the llm row is still there.
    - `llm not configured: 没设置, never probed`: empty endpoint. Text `没设置`, `Lamp.offline`. After pumping 61 s the probe count is 0.
    - `llm probes on show and every 60 s`: configured endpoint `http://localhost:28001` with key `k`. Count is 1 after the first pump and the text is `localhost:28001` with `Lamp.connecting`. Complete with `LlmProbeOk([], Duration.zero)`: lamp is active. Pump 60 s: count is 2. Complete with `LlmProbeFailed('key 不对')`: text `key 不对`, `Lamp.disconnected`.
    - `a probe answering after unmount is dropped`: pump an empty `SizedBox`, then complete the pending probe. `tester.takeException()` is null. Pump 120 s: the count is unchanged.
    - `a new endpoint re-probes and drops the old answer`: rebuild with a different `llm` (port 28002). Count is 2. Complete the first completer with ok and the second with failed `连不上：x`. The text is `连不上：x`.
    - `long text ellipsizes`: `nameOf` returns 60 chars and the probe fails with a 120-char line. `tester.takeException()` is null.
    - `rows have no tap action`: neither row's subtree has an `InkWell` or `GestureDetector` (`find.descendant(..., matching: find.byType(InkWell))` findsNothing).
- [ ] **Step 2: Run to verify they fail.** Run `cd gui && ~/development/flutter/bin/flutter test test/ui/local_services_test.dart`. Expected: compile error, because `local_services.dart` doesn't exist.
- [ ] **Step 3: Implement `LocalServices`** in `gui/lib/ui/local_services.dart`.
  - Title `连上的服务` in the `常用` label style: `bodySmall`, `t.muted`, letterSpacing `t.labelSpacing * t.textSize`, top padding 14, bottom padding 6.
  - Each row: `StatusLamp`, 6 px, the name in fixed `t.text`, 8 px, then `Expanded` muted bodySmall text with maxLines 1 and ellipsis.
  - Listen to `sync` with `ListenableBuilder`.
  - Drop stale answers with a generation counter, as in `state_service_row.dart`'s `_loads`.
  - Start the timer with `Timer.periodic(every, …)` in `initState`. Restart it in `didUpdateWidget` when `llm != old.llm` or `llmApi` changes. Cancel it in `dispose`.
- [ ] **Step 4: Run to verify they pass.** Same command. Expected: all pass.
- [ ] **Step 5: Commit** both files with the message `feat(gui): LocalServices 列出中心服务和 LLM 网关的状态`.

### Task 2: Show it in the 本机 column; fold the PC column when nobody is connected in

**Files:**
- Modify: `gui/lib/ui/main_state.dart:1157-1165` (the fold flag).
- Modify: `gui/lib/ui/overview.dart`: the column loop at ~73-78, `_LocalFold` at 290-301, and `_Column` after the favourites and before the version (~455).
- Modify tests: `gui/test/ui/overview_test.dart` (group `local column fold`). Any test in `overview_inbound_test.dart`, `load_row_test.dart`, `session_labels_test.dart`, `overview_art_hit_test.dart` or `main_window_test.dart` that reads the local column's content with a monitor and no inbound sessions now opens the column first, by tapping `column-local-folded`.

**Interfaces:**
- Consumes: `LocalServices` (Task 1); `state.stateSync`, `state.llm`, `state.llmApi`, `state.deviceName`; `monitor?.status?.sessions`, `monitor?.status?.id`; `state.hub`.
- Produces, in MainState:
  ```dart
  /// The user's open/fold of 本机 this run; null until they touch it.
  bool? localColumnPick;
  /// Whether 本机 shows open: the pick, else open while someone is connected in (always false on iPad/Duo, no service).
  bool localColumnOpen({required bool inbound}) => localColumnPick ?? inbound;
  void openLocalColumn(bool open); // sets localColumnPick, notifies when it changes
  ```
  `localColumnOpen` changes from a field to this method. Update its callers.

- [ ] **Step 1: Write the failing tests** in `overview_test.dart` group `local column fold`.
  - Replace `a local service keeps the column open, with no fold button` with `PC with nobody connected in: 本机 starts folded`. With a monitor and no status: `column-local-folded` is found and the width is 56.
  - `PC opens 本机 while someone is connected in, folds when they leave`:
    - Use a monitor subclass like `overview_inbound_test.dart`'s, with `set(sessions)`. Set one `ServiceSession` and notify: width 220, and the `column-local-fold` button is found.
    - Set `[]`: `column-local-folded` is found.
  - `a manual fold sticks while sessions come and go`:
    - With a session in, tap `column-local-fold`. It is folded.
    - Set two sessions, then `[]`, then one: it is still folded.
    - Tap `column-local-folded`, then set `[]`: it is still open.
  - `the open 本机 column shows 连上的服务; the strip does not`:
    - iPad path, no monitor: folded → `find.byKey(Key('local-services'))` findsNothing.
    - Tap open → findsOneWidget, above `version-local` (dy less than its dy).
  - `remote columns have no 连上的服务`: with host `m1`, `find.descendant(of: column-m1, matching: local-services)` findsNothing.
- [ ] **Step 2: Run to verify they fail.** Run `cd gui && ~/development/flutter/bin/flutter test test/ui/overview_test.dart --name "local column fold|连上的服务|remote columns"`. Expected: the new tests fail. PC is open today, and `local-services` isn't found.
- [ ] **Step 3: Implement.**
  - In `overview.dart`, every `c.id == null` column goes through `_LocalFold`, which also takes `monitor`:
    - `inbound` = `monitor?.status?.sessions.isNotEmpty ?? false`.
    - Open → `_Column(…, monitor: monitor, onFold: () => state.openLocalColumn(false))`.
    - Folded → `_FoldedColumn(col, onOpen: () => state.openLocalColumn(true))`.
  - In `_Column`, when `id == null`, add `LocalServices` after the favourites block:
    - `sync: state.stateSync`, `llm: state.llm`, `llmApi: state.llmApi`;
    - `hostApi: monitor ?? state.hub`, `localId: monitor?.status?.id`, `nameOf: state.deviceName`.
  - Update the doc comments on `_LocalFold`, on the fold button ("this column only folds on iPad/Duo" → "only 本机 folds"), and on `localColumnPick`.
- [ ] **Step 4: Run the overview tests, then the whole UI suite.**
  - Run `cd gui && ~/development/flutter/bin/flutter test test/ui/ > $WS/ui.log 2>&1; tail -5 $WS/ui.log`. Expected: `All tests passed!`.
  - Fix any older test that read the local column with a monitor and no sessions: it opens the column first. Rewrite no assertions beyond that, and ledger each touched file.
- [ ] **Step 5: Commit** with the message `feat(gui): 总览本机列显示连上的服务；PC 上没人接入时折起`.

### Task 3: Gate and todo

**Files:**
- Modify: `tasks/todo.md`. Add a section `总览本机列：连上的服务（feat/overview-local-services）` with real-machine checks:
  1. On PC with nobody connected in, 本机 is a strip after launch.
  2. When another device connects in, it opens on its own; when they leave, it folds.
  3. After a manual fold or open it no longer changes on its own, until a restart.
  4. With 本机 open, 中心服务 shows green and `<device> · :port`; after `rapp center off` it changes to 没找到 or 已关.
  5. LLM 网关 is green with an address. With a wrong key it turns red `key 不对` within a minute.
  6. On Duo/iPad, open 本机 and both rows are visible.

- [ ] **Step 1: Run the full gate.** The change is Dart-only.
  - Run `cd gui && ~/development/flutter/bin/flutter analyze` → `No issues found!`.
  - Run `~/development/flutter/bin/flutter test > $WS/all.log 2>&1; tail -3 $WS/all.log` → `All tests passed!`. A fresh worktree needs `cd rust && cargo build --release -p rapp-client-core --bin rapp-session` first.
  - Then `git checkout gui/pubspec.lock`.
- [ ] **Step 2: Commit** the todo with the message `docs(todo): 总览本机列连上的服务的实机检查`.
