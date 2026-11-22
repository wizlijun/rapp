# 看不见的会话停发画面 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sessions nobody can see stop streaming pictures (`set_stream` fps 0) and only send a few-byte `changed` (type 42, ≤ 1/s), so their traffic is near zero while the activity lamp still works.

**Architecture:** Protocol v15 on all five ends. Each host keeps its encoder reference untouched while paused, watches for change at about 1 fps, throttles the window table to one per 5 s and holds the menu bar and focus region until resume. The GUI decides "shown" per session: on stage + main window visible, or its detached window visible; it never pauses a session that has not shown a frame yet.

**Tech Stack:** Swift (RappCore, RappSession, rapp-host), Rust (client-core, host-linux), Dart/Flutter GUI, macOS and GTK runners.

**Spec:** `docs/superpowers/specs/2026-11-22-rapp-offstage-pause-design.md`

## Global Constraints

- Protocol version 15 everywhere (Swift `protocolVersion`, Rust `VERSION`, Dart `sessionProtocolVersion`); strict match, no v14 fallback.
- `set_stream` fps ∈ {0, 1, 5, 15, 30}; `hello` (and the `rapp://` address) fps ∈ {1, 5, 15, 30}. The UI pickers never offer 0.
- `changed`: type 42, empty payload, host→client, only while paused, at most one per second.
- While paused: window table (13) at most once per 5 s (the newest); menu bar (17) and focus region (36) held, flushed on resume in the order windows, menu bar, focus region, then the picture; everything else unchanged.
- Pause never changes the saving level, never counts as in-flight, never trips the 15 s "client stopped acknowledging frames" check; resume keeps the saving level from before.
- On resume the first picture is a tile diff against the last frame actually sent (the encoder reference is never advanced by the pause watch).
- `changed` counts as one frame in the client's `traffic` event `frames`; no `frame_ack` for it.
- macOS B: visible = `NSWindow.occlusionState.contains(.visible)`; Linux B: visible = not iconified; iPad: always visible while in front.
- Run Rust tests as `cargo test --workspace --no-fail-fast`; Flutter at `~/development/flutter/bin/flutter`, revert `gui/pubspec.lock` after; `grep` is ugrep, use `/usr/bin/grep`.

## Review Focus

1. A frame already encoded when the pause arrives (Linux job in flight, macOS slices queued) must still be sent, otherwise B and the encoder reference diverge → Task 2 / Task 4 tests "in-flight frame still sent".
2. Pause and a mode/density change in the same `set_stream` (the user changes the profile while the session is off stage): the host must still apply the new mode and resume with a correct (full) frame → Task 2 `pausedModeChangeResumesWithFullFrame`, Task 4 server reasoning (epoch reset).
3. A session that reconnects while off stage: hello fps > 0, no frame yet → the GUI must not pause until its first frame → Task 5 `does not pause before the first frame`.
4. Resume while a held window table is newer than the one B has: B must get the newest table before the picture → Task 1 / Task 4 outbox flush tests.
5. A static but different picture during the whole pause (changed once, then still): exactly one `changed`, not one per second forever → Task 4 `Probe` test, Task 2 (SCK only delivers on change).

---

### Task 1: Swift protocol v15 + pause outbox + session counting

**Files:**
- Modify: `Sources/RappCore/Protocol.swift` (version 15 + doc line, `case changed` type 42, `knownTypes`, fps rules)
- Create: `Sources/RappCore/PauseOutbox.swift`
- Modify: `Sources/RappSession/Channel.swift:325` (`fps()` accepts 0 for `set_stream`)
- Modify: `Sources/RappSession/EmbeddedSession.swift` (`.changed` → `frames += 1`)
- Test: `Tests/RappCoreTests/` (protocol + outbox), `Tests/RappSessionTests/` (changed counts)

**Interfaces:**
- Produces: `Message.changed` (type 42, empty); `public let allowedFps` unchanged for hello; `public let allowedStreamFps: Set<UInt8> = [30, 15, 5, 1, 0]`.
- Produces: `public struct PauseOutbox` with `init()`, `var paused: Bool { get }`, `mutating func pass(_ m: Message, now: TimeInterval) -> Message?`, `mutating func due(now: TimeInterval) -> Message?`, `mutating func changed(now: TimeInterval) -> Message?`, `mutating func setPaused(_ on: Bool, now: TimeInterval) -> [Message]`. Constants `windowsEvery = 5`, `changedEvery = 1`.

- [ ] Tests: `changed` round-trips; `setStream` fps 0 decodes; `hello` fps 0 throws; type 42 with a payload throws; outbox: not paused passes everything; paused holds `.menuBar`/`.focusRegion` (keeps newest), passes `.clip`/`.pong`; paused `.windows` passes the first then holds until 5 s after the last one sent, `due` returns the held one when due; `changed` returns `.changed` at most once per second and nil when not paused; `setPaused(false)` returns `[windows, menuBar, focusRegion]` (only those held) in that order and clears them; `setPaused(true)` returns `[]`.
- [ ] Implement, run `swift test --filter "Protocol|PauseOutbox|Embedded"`, commit.

### Task 2: macOS host pause

**Files:**
- Modify: `Sources/RappCore/PacedSender.swift` (`setPaused(_:)`)
- Modify: `Sources/rapp-host/Server.swift` (setStream fps 0, `send` through the outbox, `changed` from `frameArrived`, `tick` → `outbox.due`)
- Modify: `Sources/rapp-host/WindowCapture.swift` (capture fps 1 while paused — via `setStream(fps: 1, …)`)
- Test: `Tests/RappCoreTests/PacedSenderTests.swift`

**Interfaces:**
- Consumes: `PauseOutbox` (Task 1).
- Produces: `PacedSender.setPaused(_ on: Bool)`: while paused, `offer` keeps only the newest frame without encoding it, already queued slices still drain, `settleIfIdle` does nothing, `tick` does not count the pause as stalled; `setPaused(false)` encodes the newest offered frame against the last produced one.

- [ ] Tests (PacedSender): paused → offers produce no transmit; slices queued before the pause still transmit; resume transmits one diff whose decode on top of B's last picture equals the newest offered frame; saving level unchanged across a pause; mode change while paused then resume yields a full frame.
- [ ] Server: on `setStream` with fps 0 keep `requestedFps` (not 0 into `SaveLadder`), apply mode/density/pinned/focus as usual, call `paced?.setPaused(true)`, `outbox.setPaused(true, …)`, capture fps 1. On fps > 0: send `outbox.setPaused(false, …)` messages, then `paced?.setPaused(false)`. `frameArrived` while paused → `outbox.changed(now:)` → send. All non-frame sends go through `outbox.pass`.
- [ ] `swift build` + `swift test`, commit.

### Task 3: Rust client-core v15

**Files:**
- Modify: `rust/client-core/src/protocol.rs` (`VERSION = 15`, `Incoming::Changed`, allow-list adds 42, decode 42 empty)
- Modify: `rust/client-core/src/bin/rapp-session.rs` (`set_stream` fps allows 0; `Incoming::Changed` → `frames += 1`, no ack, no event)
- Test: same files' test modules

- [ ] Tests: `read_message` of `[42,0,0,0,0]` → `Incoming::Changed`; 42 with one payload byte errors; address `fps=0` rejected; `set_stream` json fps 0 accepted, 2 rejected.
- [ ] Implement, `cargo test --workspace --no-fail-fast` (protocol fields hit testkit), commit.

### Task 4: Linux host pause

**Files:**
- Modify: `rust/host-linux/src/wire.rs` (`settings(r, stream: bool)`: fps 0 only for `set_stream`)
- Create: `rust/host-linux/src/pause.rs` (non-gated, `Outbox` over raw packets)
- Modify: `rust/host-linux/src/encode.rs` (`Probe`)
- Modify: `rust/host-linux/src/capture.rs` (`Job.probe`, `Completed.probe`)
- Modify: `rust/host-linux/src/server.rs` (paused flag, outbox, probe jobs, resume)
- Modify: `rust/host-linux/src/lib.rs` (`mod pause`)

**Interfaces:**
- Produces: `pause::Outbox::new(windows: Vec<u8>)`, `paused(&self) -> bool`, `windows(&mut self, packet: Vec<u8>, now: f64) -> Option<Vec<u8>>` (dedupes against the last sent; throttled 5 s while paused), `menus(&mut self, packet) -> Option<Vec<u8>>`, `focus(&mut self, packet) -> Option<Vec<u8>>` (dedupe; held while paused), `changed(&mut self, now: f64) -> Option<Vec<u8>>` (`packet(42, vec![])`, ≤1/s, only paused), `set_paused(&mut self, on: bool, now: f64) -> Vec<Vec<u8>>` (resume flush in order windows, menus, focus; only those differing from what was sent).
- Produces: `encode::Probe::default()`, `reset(&mut self)`, `changed(&mut self, encoder: &Encoder, bgra: &[u8], w, h, region: Rect, mode: u8) -> bool` — compares with the last probe, or with the encoder reference on the first probe; never touches the encoder.

- [ ] Tests (mac-runnable): wire `set_stream` fps 0 ok, `hello` fps 0 rejected; Outbox cases mirroring Task 1; Probe: first probe after encoding identical pixels → false, changed pixels → true, same changed pixels again → false, encoder still produces the right diff afterwards (decode equals current pixels).
- [ ] Server: `Live.paused`; fps 0 keeps the previous `settings.fps` (pacing never sees 0); paused → submit `Job{probe: true}` every 1 s, skip `pacing.ready`; probe result → send `changed`; non-probe completed frames are always sent (in-flight); resume → flush outbox, `next_frame = now`, `next_windows = now`.
- [ ] `cargo test --workspace --no-fail-fast`; try a Linux container (`colima start` + `cargo check -p rapp-host-linux` in rust:latest); commit.

### Task 5: Dart GUI

**Files:**
- Modify: `gui/lib/embed/session_protocol.dart` (15)
- Modify: `gui/lib/embed/stream_choice.dart` (`effectiveFps(c, {required bool shown}) => shown ? c.fps : 0`)
- Modify: `gui/lib/ui/main_state.dart` (`mainVisible`, `_windowVisible`, `_applyFps` rules, first-frame re-apply)
- Modify: `gui/lib/embed/session_port.dart` (`window_visible` → `WindowVisibleEvent(sid, visible)`)
- Modify: `gui/lib/main.dart` (listen on `rapp/system` `visible`)
- Test: `gui/test/` stream choice + main state tests

- [ ] Tests: `effectiveFps` shown/not; `_applyFps`: off-stage session gets 0; on-stage gets its fps; main window hidden → on-stage 0, detached stays; detached window hidden → 0; overview → all 0; no first frame → not paused, first `TrafficEvent(frames>0)` then pauses.
- [ ] `flutter analyze` + `flutter test`, revert `pubspec.lock`, commit.

### Task 6: runners

**Files:**
- Modify: `gui/macos/Runner/MainFlutterWindow.swift` (occlusion observer → `rapp/system` `visible`)
- Modify: `gui/macos/Runner/DetachedWindow.swift` + `SessionPlugin.swift` (`windowDidChangeOcclusionState` → `window_visible` event, any of the session's windows visible)
- Modify: `gui/linux/runner/my_application.cc` (`window-state-event` iconified → `rapp/system` `visible`)

- [ ] Build the macOS app (`flutter build macos --debug`), compile-check iOS only if `gui/ios` changed, commit.

### Task 7: wrap-up

- [ ] Full suites, whole-branch review, fix findings, update `tasks/todo.md` with the real-machine checks (spec §5 1–9), memory, hand the branch to rapp-49.
