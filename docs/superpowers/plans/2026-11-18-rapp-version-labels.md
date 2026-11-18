# Version Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each device's rapp version, in muted small text, at the bottom of its column in the overview (全景). The 本机 column shows this client's own version.

**Architecture:**
- A device's `list_apps` reply gains a `version` field. The hub's `apps` event copies it through, and its `hosts` event carries the hub's own version.
- In the GUI, `AppList.version` and `HubClient.version` feed a new `DeviceColumn.version`, and the overview prints it under each column.

**Tech Stack:** Rust (service, hub), Flutter/Dart (gui).

**Spec:** `docs/superpowers/specs/2026-11-18-rapp-version-labels-design.md`

## Global Constraints

- The field is named `version` everywhere. Its value comes from `env!("CARGO_PKG_VERSION")`.
- The change is additive: no protocol version bump, and old peers keep working.
- In Dart, version is a `String?`. Treat an empty string as none.
- When the version is unknown, render no label at all, not "未知".
- The label goes after the column's content, with a 14 top margin, in `bodySmall` with the `muted` color.
- Never commit `rust/Cargo.lock`, and revert `gui/pubspec.lock` after running tests.

## Review Focus

- **An old peer that sends no `version`:** its column shows no label and nothing crashes. Covered by the Task 2 model test.
- **A device that only sessions know about (no host entry):** its version is null. Covered by the Task 2 model test.
- **An empty-string version:** treat it as none. Covered by the Task 2 HubClient/AppList parse test.

---

### Task 1: version in `list_apps` reply and hub events (Rust)

**Files:**
- Modify: `rust/service/src/peer.rs:188-195`
- Modify: `rust/hub/src/lib.rs:238-240` (hosts event) and `:309-320` (apps event)

**Interfaces:**
- Produces:
  - In `rust/service/src/peer.rs`: `fn list_apps_reply(apps: Value, perms: Option<Value>, caps: Value) -> Value`. It returns `ok({...})` with `apps`, `permissions` (only when `perms` is `Some`), `capabilities` and `"version": CARGO_PKG_VERSION`.
  - In `rust/hub/src/lib.rs`: `fn apps_event(id: &str, path: &str, r: &Value) -> Value`. It copies `permissions` and `capabilities` (when they are objects) and `version` (when it is a non-empty string).
  - The `hosts` event gains `"version": CARGO_PKG_VERSION`.

- [ ] **Step 1: Write the failing tests**
  - In peer.rs: test `list_apps_reply_carries_version`. Assert that `r["version"] == env!("CARGO_PKG_VERSION")`, and that `permissions` is absent when `perms` is `None`.
  - In hub lib.rs: test `apps_event_copies_version`. When `r` has `version:"0.14.8"`, the event has `version == "0.14.8"`. When `r` has no version, the event has no `version` key.
- [ ] **Step 2:** Run `cargo test -p rapp-service list_apps_reply` and `cargo test -p rapp-hub apps_event`. Expected: FAIL (the functions are not defined yet).
- [ ] **Step 3:** Implement both helpers and use them at the two call sites. Add `version` to `hosts_event`.
- [ ] **Step 4:** Run the same tests. Expected: PASS. Then run `cargo clippy -p rapp-service -p rapp-hub -- -D warnings`. Expected: exit 0.
- [ ] **Step 5:** Commit with the message `feat(service,hub): report the rapp version in list_apps and hub events`.

### Task 2: version labels in the overview (Dart)

**Files:**
- Modify: `gui/lib/hub_client.dart`: `AppList` (around line 106), `apps()` (around line 333) and the `hosts` event (around line 456).
- Modify: `gui/lib/ui/overview_model.dart`: `DeviceColumn` and `deviceColumns`.
- Modify: `gui/lib/ui/overview.dart`: `_Overview.build`, which passes the local version, and `_Column`, which draws the label.
- Test: `gui/test/hub_client_test.dart`, `gui/test/ui/overview_model_test.dart`, `gui/test/ui/overview_test.dart`.

**Interfaces:**
- Consumes: Task 1's `version` fields.
- Produces:
  - `AppList.version` (`String?`).
  - `HubClient.version` (`String?`). It is set from every `hosts` event, and `''` becomes null.
  - `DeviceColumn.version` (`String?`).
  - `deviceColumns(..., String? localVersion)`. This named parameter is optional and defaults to null.

- [ ] **Step 1: Write the failing tests**
  - In hub_client_test, add two tests:
    - A `hosts` event with `version:'0.14.8'` sets `hub.version == '0.14.8'`, and `version:''` sets it to null.
    - An `apps` reply with `version` fills `AppList.version`, and a reply without one leaves it null.
  - In overview_model_test: the local column's version equals `localVersion`. A host whose probe `apps` carries `version:'0.14.8'` gets `'0.14.8'`. A host with no probe, or with `apps` that has no version, gets null. A sessions-only device gets null.
  - In overview_test: add the test `each column shows its version at the bottom in muted text`. Find `Text('0.14.8')` inside `column-m1` and check its color is `t.muted`. The local column shows the hub version. A column without a version has no label: in a column for a host with no probe, no text matches `RegExp(r'^\d+\.\d+')`.
- [ ] **Step 2:** Run `flutter test test/hub_client_test.dart test/ui/overview_model_test.dart test/ui/overview_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement the fields, the parsing and the label (with key `version-<id|local>`).
- [ ] **Step 4:** Run the same tests, then `flutter analyze`. Expected: PASS, with no issues reported.
- [ ] **Step 5:** Commit with the message `feat(gui): version label at the bottom of each overview column`.
