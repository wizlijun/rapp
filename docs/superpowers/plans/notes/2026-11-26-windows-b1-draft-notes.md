# Windows plan B, Tasks 2–6: draft notes

Branch `feat/windows-host-core`. Plan: `docs/superpowers/plans/2026-11-26-rapp-windows-b-host-core.md`
(on `docs/windows-design`). **Nothing here has been compiled or run**: no `cargo`, `swift` or
fixture generation took place. Every commit title ends with `(草稿，未编译未验证)`. No fixture files
are committed. The Swift generators under `Tests/RappCoreTests/HostCoreFixtures/` write them, and
the Rust tests under `rust/host-core/tests/` read them.

## 1. What is written

| Task | Commit | Rust | Swift source ported | Generator / test |
|---|---|---|---|---|
| 2 Protocol codec, not-handled table | 670f7904 | `src/protocol.rs` | `Sources/RappCore/Protocol.swift`, `Clipboard.swift`, client-core decoders | `ProtocolFixtures.swift` → `protocol-messages.bin`, `protocol-types.json`, `protocol-rejects.json`; `tests/protocol.rs` |
| 3 Deflate | f28363bb | `src/deflate.rs` (`DeflateStream`, `InflateStream`, libz-sys, the only `unsafe`) | `Sources/RappCore/Deflate.swift` | `DeflateFixtures.swift` → `deflate.bin`; `tests/deflate.rs` |
| 4 Quantise | a73a38e6 | `src/quantize.rs` | `Sources/RappCore/Quantize.swift` | `QuantizeFixtures.swift`; `tests/quantize.rs` |
| 5 Tile codec, scroll detection | aeefee1a | `src/tile.rs`, `src/scroll.rs` | `TileCodec.swift`, `ScrollDetect.swift`, `FocusPane.swift:13` (`EncodeReport`) | `TileFixtures.swift` → `tile-frames.bin`, `tile-<mode>.bin`, `tile-settle.bin`; `tests/tile.rs` (incl. `decoder_agrees` through `rapp_client_core::codec::Decoder`) |
| 6 Pacing, ladder, pause outbox | 74443b0b | `src/pacing.rs` (`SendPacer`, `WeakTier`, `StreamSpec`, `save_ladder_*`, `Stats`, `SenderOutput`, `PacedSender`), `src/pause.rs` (`PauseOutbox`) | `SendPacer.swift`, `WeakTier.swift`, `SaveLadder.swift`, `PacedSender.swift`, `PauseOutbox.swift` | `PacingFixtures.swift` → `send-pacer.json`, `weak-tier.json`, `save-ladder.json`, `pause-outbox.json`, `paced-sender.json`; `tests/pacing.rs` (one test per fixture + `unacknowledged_stream_keeps_one_frame`) |

Task 6 traces:
- every scenario of `SendPacerTests`, `WeakTierTests`, `PauseOutboxTests` and `PacedSenderTests`, rebuilt as traces (the reference/real pair and the settle on/off pair each become two traces);
- every plan trace (plan line 324);
- seeded random traces (`HostRNG`) for the pacer, the tier and the outbox;
- `save-ladder.json`, a grid of 5 modes × 8 fps × 8 densities.

`PacedSender` pictures are generator specs (`random` = `randomSamples`, `scene` = `PacedSenderTests.scene` + typed/touch/corner edits). Rust rebuilds them and first checks Swift's `samples_fnv` / `raw_fnv`, so a generator mismatch is reported apart from a sender mismatch.

`lib.rs` is unchanged from Task 1 (cead3c91).

## 2. What is not written, and why

- Tasks 7–19 are not written: out of scope. `lib.rs` already declares their modules (`geometry`, `focus`, …), so **the crate does not compile until those files exist**. `tile.rs` uses `crate::geometry::Rect` (Task 7) for `EncodeReport.copy_bounds`.
- `PORTING.md` is not written. The plan sends "not byte-exact" findings there (plan lines 82, 214, 284), but it is Task 18. Those findings are in §4 and §5 here instead.
- No fixture files: the generators must be run on macOS (`RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`).
- Task 3's `cargo tree -p rapp-client-core -e features` output is not in the commit message (plan line 212), because running cargo was forbidden. `libz-sys` was already in `Cargo.toml`, and `Cargo.lock` was off limits.
- `PacedSender` encode timing: Swift measures each encode with `now()`. Rust measures it only when `set_timer(Arc<dyn Clock>)` is given. The fixtures use a clock that moves only between calls, so `encode_ms_max` is 0 on both sides; the measured path is not fixture-tested.

## 3. Departures from the plan

### Public names and signatures that differ from plan B

Task 2–5:
- `DeflateStream::compress_if_at_most` returns `(bool, Vec<u8>)` (Swift returns whether it fit plus the bytes).
- `InflateStream` added (the test mirror; plan line 282 assumes one exists).
- `Password` is a newtype with `Deref`, `into_inner`, `From<Zeroizing<String>>`.
- `PROTOCOL_VERSION` is an alias of `rapp_client_core::protocol::VERSION`.
- `FrameEncoder::encode` returns `Option<FramePayload>` and takes `region: Option<CanvasRect>`. Swift `encode` returns `encodeSlices(...).first` and the region defaults (TileCodec.swift:190).
- `encode_slices` takes `region: Option<CanvasRect>` and `first_limit: Option<usize>` (TileCodec.swift:317).
- Added accessors: `last_tile_count`, `needs_settle`, `last_encode_diverged`, `last_encode_added_approximation`, `mode`, `model`, `last_report`.
- `force_full` and `copies_enabled` are pub fields (Swift vars).
- `last_tile_stream()` returns the last slice's stream; `last_tile_streams()` added (a frame has several slices).
- `moved_canvas` is pub; `scroll::{Cover, ScrollDetector}` are pub.
- `EncodeReport.copy_bounds: Option<geometry::Rect>` (Swift `CGRect?`; `Rect` belongs to Task 7).

Task 6 (plan lines 301–319):
- `PacedSender::offer(samples, raw, width, height, region, captured: f64, now: f64)`: extra `captured`. Swift `offer(...captured:)` separates capture time (used for latency) from call time.
- `SenderOutput::Frame { region: CanvasRect, payload: FramePayload }` instead of `Frame(FramePayload)`. Swift calls `transmit(region, payload)`, and the region is part of the `frame` message.
- `set_paused(&mut self, on: bool, now: f64) -> Vec<SenderOutput>`: a resume pumps (sends).
- `set_pinned(&mut self, pinned: bool) -> Vec<SenderOutput>`: it can report `onLevelChange`.
- `set_steps(&mut self, steps: Vec<i64>) -> Vec<SenderOutput>`: same reason.
- `take_stats(&mut self, now: f64) -> Stats`: Swift reads `now()`.
- `WeakTier.pinned` is private, with `set_pinned(bool)` and `pinned()`. Swift's `didSet` drops the level to 0 (WeakTier.swift:12–14), which a pub field cannot do.
- Added: `PacedSender::set_timer`, `weak()`, `level()`, `#[doc(hidden)] pending_bytes()` (plan line 325); `SendPacer::last_rtt()`; `PauseOutbox::paused()`, `PauseOutbox::new()`.
- `PauseOutbox::set_paused(on, now) -> Vec<Message>` returns the held messages (windows, menu bar, focus region).
- `pass(m, now) -> Option<Message>`, `due(now)`, `changed(now) -> Option<Message>`, as in Swift.
- `Stats` field names are exactly the plan's. `StreamSpec`, `save_ladder_stream` and `save_ladder_steps` are exactly the plan's.

### Other departures

- **Value comparison in `tests/pacing.rs`** (plan line 80 says typed comparison, never `serde_json::Value`). The trace results are heterogeneous, so the test builds a `Value` from Rust results and compares it with `same()`:
  - numbers are compared as f64 with `==` (no tolerance), because `JSONSerialization` writes `1.0` as `1`;
  - strings and bools are compared exactly; key sets must match.

  The strictness is the same, but the form departs from the rule. `tests/protocol.rs` also reads `protocol-types.json` input as `Value`.
- Fixture formats:
  - `protocol-rejects.json` cases are `{error, again}`;
  - `deflate.bin` tag 4 always carries data;
  - `protocol-types.json` is a single case;
  - the tile fixtures carry input records and FNV hashes, so Rust can replay them;
  - Task 6 calls are `{"op": …}` with `"pic"` (plan line 324 shows `{"call": …, "scene": …}`);
  - frames over 512 bytes are recorded as length + FNV-1a only (`hex: null`), to keep `paced-sender.json` small.
- Task 6 plan trace "a full frame after" resume: the Swift behaviour is tested instead. Resume sends a diff (see §4).

## 4. Plan errors and contradictions

1. Task 3 "Modify `rust/host-core/Cargo.toml`, `rust/Cargo.lock`" (plan line 207). `libz-sys` is already in `rust/host-core/Cargo.toml` (Task 1), and `Cargo.lock` belongs to the release session (CLAUDE.md).
2. The C1 probe results do not exist. The plan names `docs/superpowers/specs/2026-11-26-rapp-windows-probe-results.md` (plan lines 11, 15), but `specs/` has no such file. Task 3's precondition is unmet; the draft assumes stock zlib (`libz-sys`).
3. libz-sys `static` bundles zlib 1.3.x, while Swift uses Apple's system zlib. Byte identity of deflate output is assumed, not proven. If it fails, plan line 214's fallback applies, and Task 5's slice boundaries move with it.
4. `lib.rs` (Task 1) declares the modules of Tasks 7–19, so Tasks 2–6 cannot be compiled or tested on their own (plan's Step "Run … --test X" per task is impossible until those files exist).
5. Task 3 says "Output buffer grows in a loop until `avail_out` is non-zero" (plan line 232). Swift drains a fixed 64 KiB buffer repeatedly (Deflate.swift:10, 60–70). The port follows Swift; the output bytes are the same either way.
6. Task 2 rejects list says "NaN-free out-of-range values" (plan line 189), but the rejects fixture also contains NaN densities, which Swift rejects. Plan line 80 says fixtures never contain NaN. The NaN cases are bytes in hex, not JSON numbers, so no JSON NaN appears.
7. Task 5 signatures (plan lines 273–274) contradict Swift. `encode` returns `encodeSlices(...).first` (optional) with a default region (TileCodec.swift:190). `encodeSlices` has optional `region` and `firstLimit` (TileCodec.swift:317).
8. `last_tile_stream(&self) -> &[u8]` is singular (plan line 284), but one `encode_slices` call produces several slices, each with its own stream. `last_tile_streams()` was added.
9. Task 5's record layout (plan line 282) has no input records, so Rust could not replay the encoder calls. Input records were added.
10. "a region size change (forces full)" (plan line 282) is wrong. Only a density change over 1% forces full (TileCodec.swift:329). A size change makes `resized`, which sets `full` in the report but does not force a full frame.
11. `PORTING.md` is cited by Tasks 3 and 5 (plan lines 82, 214, 284), but it is created only in Task 18.
12. Task 6 `offer` has no `captured` (plan line 311), but Swift's `offer(..., captured:)` (PacedSender.swift:83) needs it for latency.
13. Task 6 `SenderOutput::Frame(FramePayload)` (plan line 307) drops the region that Swift's `transmit(region, payload)` passes (PacedSender.swift:46).
14. Task 6 missing parameters and returns (plan lines 316–317):
    - `set_paused` needs `now` and returns outputs (resume pumps, PacedSender.swift:135–139);
    - `set_pinned` and `set_steps` report level changes (PacedSender.swift:142–151);
    - `take_stats` reads `now()` (PacedSender.swift:163).
15. Task 6 expects a full frame after `setPaused(false)` (plan line 324). Swift sends a diff: PacedSenderTests.swift:601 has `XCTAssertFalse(sent[1].payload.isFull, "a diff against what B has")`. Only a mode change while paused resumes with a full frame (PacedSenderTests.swift:655–668). The traces record Swift's behaviour.
16. Task 6 gives `WeakTier` a `pub pinned: bool` field (plan line 302), but Swift's `pinned` has a `didSet` that sets `level = 0` (WeakTier.swift:12–14).

## 5. Compile and behaviour risks

1. **Whole-crate compile.** Nothing was compiled, and the crate cannot build until Tasks 7–19 add their modules (`geometry::Rect` with fields `x, y, width, height: f64` is assumed by `tile.rs` and `tests/pacing.rs`).
2. **zlib byte identity**: libz-sys's bundled zlib against Apple's zlib. Also the `zalloc`/`zfree` fn-pointer types in `deflate.rs`, the `z_stream` in a `Box`, and `deflateCopy` lifetime handling.
3. **Swift type-checking of the generators.**
   - Heterogeneous dictionary literals were annotated `as [String: Any]`, but some long tuple-array literals (`WeakTier` traces) may hit "expression too complex".
   - The `[unowned self]` closures in `SenderTrace.init` rely on `s` being an IUO var initialised to nil.
4. **JSON number round-trip.** `JSONSerialization` must print every `Double` (call times like `0.1 * k`, RTTs) so it parses back to the same f64, and the Rust comparison is exact.
5. **Fixture size and run time.**
   - `paced-sender.json` includes several 1920×1080 and 1280×800 traces, and the 75 s 10 Hz delay traces. Big frames are only hashed.
   - `protocol-rejects.json` is several MB (64 KiB payloads in hex).
   - Rust rebuilds all pictures, including quantizing 1024×768 scenes per offer.
6. Other risks:
   - **Integer casts.** `as usize` / `as i64` saturate where Swift traps (quantizer uses i64 arithmetic), and isize/usize casts appear in `tile.rs`/`scroll.rs`.
   - The fingerprint code assumes little-endian loads.
   - BOM and grapheme handling: title limits use `unicode-segmentation` against Swift `Character`.
   - The type-35 (unlock) buffer is zeroized even on decode error.
   - `SendPacer::cap`: `ceil(fps*base - 1e-9)` can be `-0.0` and casts to 0, as in Swift.
   - `encode_ms_max` is 0 in every fixture, so the real timing path is untested.

## 6. What the verifier should do first, in order

1. Get the crate compiling.
   - Either add stub-free Task 7 `geometry.rs` (at least `Rect { x, y, width, height: f64 }`) from the rules branch, or temporarily comment the Task 7–19 `pub mod` lines in a scratch copy (do not commit that).
   - Then run `cargo check -p rapp-host-core --tests` and `cargo clippy -p rapp-host-core --tests -D warnings`.
2. Run `tests/boundary.rs`.
3. Compile and run the Swift generators: `RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`.
   - Fix type-check errors in `ProtocolFixtures`, `DeflateFixtures`, `QuantizeFixtures`, `TileFixtures` and `PacingFixtures`.
   - Confirm the XCTAsserts inside the generators pass; they re-assert the original Swift test expectations.
4. `cargo test -p rapp-host-core --test protocol --test deflate` first. Deflate byte identity decides plan line 214's fallback; record C1 if it fails.
5. `--test quantize`, then `--test tile` (`decoder_agrees` before the byte comparisons), then `--test pacing`. For pacing, the picture FNV asserts come first and separate generator bugs from sender bugs.
6. Review the §3 public-name differences with the `feat/windows-host-core-rules` agent, especially `EncodeReport.copy_bounds: Option<geometry::Rect>`. Then decide whether the plan or the code changes for each §4 item.
