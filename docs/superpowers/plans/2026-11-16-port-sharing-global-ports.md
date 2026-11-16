# 端口分享：统一分享号 + 协议（第一步）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every share gets one share number from 28000–28999, chosen by the sharer. The sharer and every visitor serve the share on `localhost:<number>`. The address carries its protocol (http/https/tcp/ssh), which is detected when the port is shared, and the user can change it.

**Architecture:**
- **Sharer:** the sharer writes the number into `shares.json` (`local`, plus `proto`/`proto_auto`) and advertises it in `list_shares`, `shares` and `share` replies. A new `own.rs` listens on the sharer's own numbers and connects straight to the shared port.
- **Visitor:** `maps.rs` takes the advertised number when it is free. Otherwise it yields to another port and remembers the wanted number, so it can move back later.
- **Shared helpers:** a new `numbers.rs` holds number picking, the "seen numbers" set, and the clash rule. A new `probe.rs` detects the protocol.

**Tech Stack:** Rust (tokio, serde, rustls 0.23), Flutter (gui/), testkit integration tests.

**Spec:** `docs/superpowers/specs/2026-11-16-rapp-port-sharing-global-ports-design.md` (step 1 only: everything except §4 UDP). It amends `docs/superpowers/specs/2026-11-16-rapp-port-sharing-local-ports-design.md`.

## Global Constraints

- **Range:** 28000–28999 (`maps::FIRST`, `maps::COUNT`; tests pass their own range through `Opts.map_ports`). The same range is used for share numbers and for visitors' maps.
- **Protocols:** `http` | `https` | `tcp` | `ssh`, spelled exactly like that on the wire, in files and on the command line. There is no `udp` in this plan.
- **Addresses** (copied verbatim): `http://localhost:N`, `https://localhost:N`, `tcp://localhost:N`, `ssh -p N localhost`. 打开 is offered only for http/https. `(22,22) => "ssh localhost"` is gone.
- **Exact user-facing copy** (GUI and CLI use the same strings):
  - Visitor yielded: `这台上是 {local}（{wanted} 被占）`
  - Number taken on the sharer: `本机上 {local} 被别的程序占着，本机请用 localhost:{port}`
  - Renumbered: `{from} 和 {with} 撞了，换成 {local}`
  - Own share with no number: `没有空的号`
  - After `rapp share`: `在别的设备上也用这个地址`
- **Protocol default** when nothing is stored: port 22 → `ssh`, any other → `http`, with `proto_auto` true.
- **Wire changes are additive only:** no protocol version bump, and an old peer ignores the new fields.
- **Repo rules:**
  - `cargo` needs `PATH=$HOME/.cargo/bin:$PATH`. Run from `rust/`.
  - Flutter: `~/development/flutter/bin/flutter`, run from `gui/`. Revert `gui/pubspec.lock` after every flutter run.
  - Never read `docs/archives/`.
  - Never use bare `git stash`.
  - Do not push.
  - Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Comments** follow the codebase style: a doc comment on every item, and they say *why*.

## Review Focus

1. **Upgrade from 0.12.2.** A `shares.json` without `local`/`proto` and a `maps.json` without `wanted` must load, and every old share must end up numbered. → Task 1 `an_old_file_loads_and_writes_back_unchanged`, Task 2 `an_old_table_is_numbered_at_start`.
2. **Sharer's range is full.** Sharing still succeeds, with no number and an empty address. → Task 1 `a_full_range_shares_without_a_number`, Task 2 `a_share_with_no_number_left_has_no_address`.
3. **A visitor follows a renumbered share.** The visitor's old port must close, not keep carrying. → Task 4 `the_visitor_follows_a_renumbered_share`.
4. **The probe hits a service that accepts and closes at once, or never answers.** It must come back as `tcp` within about 1 s and never hang. → Task 5 `a_service_that_closes_at_once_is_tcp`, `a_silent_service_is_tcp`.
5. **An echo-like service.** It answers a probe with the probe's own bytes and must not be taken for https or http. → Task 5 `an_echo_service_is_tcp`.

---

### Task 1: Share number and protocol in the share table

**Files:**
- Modify: `rust/service/src/shares.rs`, `rust/service/src/maps.rs` (add `free`, `range`), `rust/service/src/share_cmds.rs` (`addr`), `rust/service/src/sharing.rs` (pass a picker), `rust/service/src/state.rs` (add `numbers`), `rust/service/src/lib.rs` (build it; `mod numbers`)
- Create: `rust/service/src/numbers.rs`
- Modify: `rust/testkit/tests/common/mod.rs`. `start_service` passes map range `(0, 0)`, so tests that do not ask for numbers get none and existing tests keep their meaning.

**Interfaces:**
- Produces (in `shares.rs`):
  ```rust
  #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
  #[serde(rename_all = "lowercase")]
  pub enum Proto { Http, Https, Tcp, Ssh }
  impl Proto {
      pub fn guess(port: u16) -> Proto;          // 22 → Ssh, else Http
      pub fn parse(s: &str) -> Option<Proto>;    // "http"|"https"|"tcp"|"ssh"
      pub fn as_str(self) -> &'static str;
      pub fn web(self) -> bool;                  // Http | Https
  }
  pub struct Share {                             // existing fields stay
      #[serde(default, skip_serializing_if = "Option::is_none")] pub local: Option<u16>,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub proto: Option<Proto>,
      #[serde(default = "yes", skip_serializing_if = "is_true")] pub proto_auto: bool,
      ..
  }
  impl Share { pub fn new(port: u16) -> Share; pub fn protocol(&self) -> Proto /* proto or guess */; }
  pub struct Patch { pub note, pub allow, pub raw, pub proto: Option<Proto> }  // proto Some → proto_auto = false
  /// Gives a share number: the lowest one free, given the numbers the share table already uses.
  pub type Pick<'a> = &'a dyn Fn(&[u16]) -> Option<u16>;
  impl Shares {
      pub fn share_all(&self, ports: &[u16], patch: &Patch, pick: Pick) -> Result<Vec<Shared>>;
      pub fn number_all(&self, pick: Pick) -> Result<Vec<Share>>;            // fills every share without `local`; returns those numbered; no write when none
      pub fn renumber(&self, port: u16, pick: Pick) -> Result<Option<(u16, u16)>>; // (old, new); its current number counts as used
      pub fn set_proto(&self, port: u16, proto: Proto, auto: bool) -> Result<bool>; // whether it changed
  }
  ```
  `share_all` gives a number to a port that is new, or shared but without one. It calls `pick(used)`, where `used` is the numbers of the rest of the table plus those given earlier in the same call. A port that already has a number keeps it, whatever else the patch changes.
- Produces (in `numbers.rs`):
  ```rust
  pub struct Numbers { /* seen: Mutex<HashMap<String, Vec<u16>>>; Task 4 adds renumbered */ }
  impl Numbers {
      pub fn new() -> Numbers;
      pub fn set_seen(&self, id: &str, numbers: Vec<u16>);   // replaces that device's list
      pub fn seen(&self) -> Vec<u16>;                         // every device's, deduplicated
  }
  /// The lowest number of `state.maps.range()` that is not in `used`, not a local of `maps.json`,
  /// not seen, and `maps::free`.
  pub fn pick(state: &State, used: &[u16]) -> Option<u16>;
  /// Of two sharers holding the same number, whether `me` gives it up: the larger ID, compared as numbers (as strings when either is not a number).
  pub fn yields(me: &str, other: &str) -> bool;
  ```
- Produces (in `maps.rs`): `pub fn free(local: u16) -> bool` (no program answers on either loopback address; the connect check `listen` already makes) and `pub fn range(&self) -> (u16, u16)`.
- Produces (in `share_cmds.rs`): `pub fn addr(proto: Proto, local: u16) -> String` (the Global Constraints table).

- [ ] **Step 1: Write failing unit tests in `shares.rs`**
  - `an_old_file_loads_and_writes_back_unchanged`: load `[{"port":8000,"note":"x"},{"port":22}]`, then `share_all(&[8000], &Patch::default(), &|_| None)`. The file still parses, and `get(22).unwrap().protocol() == Proto::Ssh`. The file has no `proto`/`proto_auto` keys, and 8000 has no `local`.
  - `a_new_share_gets_a_number_and_keeps_it`: `pick = |used| (29000..).find(|n| !used.contains(n))`. Share 8000, then 8001: locals 29000 and 29001. Share 8000 again with a new note: local stays 29000.
  - `a_full_range_shares_without_a_number`: with `&|_| None`, the share succeeds with `local == None`.
  - `proto_from_a_patch_is_not_auto`: `Patch { proto: Some(Proto::Tcp), .. }` gives `proto == Some(Tcp)` and `proto_auto == false`. A later share without `proto` keeps both.
  - `number_all_fills_only_the_missing`: two shares, one with `local: 29005`. `number_all` with the pick above gives the other 29000, and returns exactly that one.
  - `renumber_gives_another_number`: a share on 29000; `renumber(port, pick)` returns `Some((29000, 29001))`.
  - `set_proto_says_whether_it_changed`.
- [ ] **Step 2: Unit tests in `numbers.rs` and `share_cmds.rs`**
  - `yields("343758121","297283213") == true` and the reverse is false.
  - Seen lists are replaced per device and deduplicated across devices.
  - `addr` gives the four exact strings for 28000. For ssh: `addr(Proto::Ssh, 28001) == "ssh -p 28001 localhost"`.
- [ ] **Step 3: Run, expect failures**
  Run: `cd rust && PATH=$HOME/.cargo/bin:$PATH cargo test -p rapp-service shares:: numbers:: share_cmds::`
  Expected: compile errors / FAIL.
- [ ] **Step 4: Implement.**
  - `sharing::share` passes `&|used| numbers::pick(state, used)` and takes `proto` from `req["proto"]` (a bad one → `Err("bad proto")`). This applies to both `By::Local` and `By::Remote`.
  - Replace every `Share { .. }` literal with `Share::new`.
  - Existing callers of `addr(port, local)` use `addr(s.protocol(), local)`. The own rows in `share_cmds::shares` stay as they are until Task 2.
  - Testkit `start_service` uses `(0, 0)`.
- [ ] **Step 5: Run everything**
  Run: `cd rust && PATH=$HOME/.cargo/bin:$PATH cargo test --workspace`
  Expected: all pass. Where an existing test pinned `ssh localhost` for (22,22) or a file shape, update it to the new rule and say so in the report.
- [ ] **Step 6: Commit** `feat(share): share number and protocol in the share table`

---

### Task 2: The sharer serves its numbers and advertises them

**Files:**
- Create: `rust/service/src/own.rs`
- Modify:
  - `rust/service/src/{lib.rs,state.rs,sharing.rs,share_cmds.rs,forward.rs,numbers.rs}`
  - `rust/net/src/msg.rs`: `Op::Share` gains `#[serde(default, skip_serializing_if = "Option::is_none")] proto: Option<String>`
  - `rapp_service::Opts`: gains `pub own_ports: bool`
- Test: `rust/testkit/tests/share_numbers.rs` (new), plus small fixture additions in `rust/testkit/tests/common/{mod.rs,sharing.rs}`

**Interfaces:**
- Consumes: Task 1 `Share.local`, `Share::protocol`, `numbers::pick`, `Shares::number_all`, `addr`.
- Produces:
  ```rust
  // own.rs: this device's own shares on their numbers, connected straight to the shared port.
  pub struct Own { .. }
  impl Own {
      pub fn new(on: bool) -> Own;                      // on = Opts.own_ports; off: sync does nothing, taken() is always false
      pub fn sync(&self, shares: &[Share]) -> Vec<Share>;   // listen for each numbered share, stop the rest; returns the shares whose number another program has
      pub fn taken(&self, port: u16) -> bool;
      pub fn stop(&self);
  }
  // sharing.rs
  pub fn sync_own(state: &State);   // own.sync(shares.list()); logs share_number_taken {port, local} once per share and number, not on every call
  // numbers.rs
  pub async fn on_start(state: Arc<State>);  // see Step 4
  ```
  - **`Opts.own_ports`:** true in the real service. In testkit, `start_service_*` keeps it true unless a test turns it off: devices in one test share one machine, so a visitor can only take a number when the sharer is not listening on it.
  - **Accept loop:** each accepted connection is joined to `forward::connect_local(&local_addrs(port), LOCAL_CONNECT_WAIT)` with `tokio::io::copy_bidirectional`, with `set_nodelay` on both ends. When nothing answers, the connection is closed.
  - **Listening:** reuse `maps::listen`, made `pub(crate)`.
  - **Replies gain fields:**
    - `forward::listed` (`list_shares`): `local` (when set) and `proto`.
    - `Op::Shares` items: `local`, `proto`, `proto_auto`.
    - `Op::Share` reply items: `local`, `proto`, `proto_auto`.
    - Local IPC `share` reply items: `local`, `proto`, `proto_auto`, `addr` (`""` without a number).
    - Local IPC `shares` own rows: `local` = the number, `addr` = `addr(protocol, number)` or `""`, `proto`, `proto_auto`, `web` = `protocol.web()`, and `taken: true` when `own.taken(port)`.
  - `share_cmds::share` with `to` passes `proto` into `Op::Share`.
  - After every local or remote `share`/`unshare`, `sync_own` runs. `sharing::table` also calls `sync_own` first, which retries a taken number.

- [ ] **Step 1: Write the failing testkit tests** in `share_numbers.rs`. Each test uses its own range from 29500 upward, 10 apart. Sharers start with that range and `own_ports` on.
  - `a_share_gets_a_number_and_the_sharer_listens_on_it`: shares.json `[{"port": <echo>}]`, range 29500. After start, the `shares` own row has `local == 29500` and `addr == "http://localhost:29500"`, and `through(29500, b"hi") == b"hi"`. shares.json has `"local": 29500`.
  - `a_new_share_gets_the_next_number`: IPC `share` of a second echo port: `shared[0]` has `local == 29511` (range 29510; the first share holds 29510), `proto == "http"`, `proto_auto == true`, `addr == "http://localhost:29511"`.
  - `list_shares_and_shares_carry_the_number_and_protocol`: through the `Visitor` fixture, `list_shares` gives `shares[0].local == 29520` and `proto == "http"`. `shares` gives the same, plus `proto_auto`.
  - `a_proto_given_is_kept`: IPC `share` with `"proto":"tcp"` gives `addr == "tcp://localhost:N"` and `proto_auto == false`. A second `share` of the same port with only a note keeps tcp. `"proto":"ftp"` gives the error `bad proto`.
  - `a_share_number_another_program_has_on_the_sharer_stays`:
    - Hold `127.0.0.1:29540` before start; shares.json `[{"port": <echo>, "local": 29540}]`.
    - The row has `taken == true` and `local == 29540`.
    - Drop the holder and read `shares` again: `taken` is absent and `through(29540, ..)` echoes.
  - `unshare_closes_the_number`.
  - `a_share_with_no_number_left_has_no_address`: range `(29550, 1)` with 29550 held by the test. The share succeeds, and the reply and the row have `addr == ""` and no `local`.
  - `an_old_table_is_numbered_at_start`: shares.json without `local`, no hosts.json. Within 6 s, the `shares` row has `local == 29560`.
  - `an_old_table_avoids_the_numbers_of_devices_online_at_start`:
    - Device B (range 29570, own_ports off, sharing an echo) is numbered 29570.
    - Device A (same range and key, hosts.json knowing B, an old shares.json) starts.
    - A's share ends up on 29571.
- [ ] **Step 2: Run, expect FAIL**
  Run: `cd rust && PATH=$HOME/.cargo/bin:$PATH cargo test -p rapp-testkit --test share_numbers`
- [ ] **Step 3: Implement** `own.rs`, the reply fields, `Opts.own_ports` (production `main`/builders set true), and `Op::Share.proto`. Add a `msg.rs` wire test: `Op::Share` with `proto: None` serializes exactly as before.
- [ ] **Step 4: `numbers::on_start`**, spawned from `Service::start` after `maps.start`.
  - When no share lacks a number, it only runs `sync_own`.
  - Otherwise it asks every `known_hosts` device at once with `pipe::shares_of`, with 5 s for all of them together. Each reply's `local`s go into `set_seen(id, ..)`.
  - Then it runs `shares.number_all(pick)`, logs `share_numbered {port, local}` for each share numbered, and runs `sync_own`.
  - `Service::start` still calls `sync_own` once before spawning `on_start`, so numbered shares listen at once.
- [ ] **Step 5: Run the test file and the workspace**
  Run: `cd rust && PATH=$HOME/.cargo/bin:$PATH cargo test --workspace`
  Expected: all pass. Fix existing tests that pinned own rows as `http://localhost:<port>`: with the default `(0,0)` range they now have `addr == ""`. Update the assertion, or give the test a range when it is about addresses.
- [ ] **Step 6: Commit** `feat(share): the sharer serves its share numbers and advertises them`

---

### Task 3: Visitors take the share number, or yield and say so

**Files:**
- Modify: `rust/service/src/maps.rs`, `rust/service/src/share_cmds.rs`, `rust/service/src/ipc.rs` (`reached`), `rust/service/src/numbers.rs`, `rust/service/src/lib.rs` (the `start` call)
- Test: `maps.rs` unit tests (existing ones adapted); `rust/testkit/tests/maps.rs`; `rust/testkit/tests/share_numbers.rs`

**Interfaces:**
- Consumes: Task 2 reply fields `local`/`proto`; `Numbers::seen/set_seen`; `own_ports` off for multi-device tests.
- Produces:
  ```rust
  pub struct Map { pub id: String, pub port: u16, pub local: u16,
                   #[serde(default, skip_serializing_if = "Option::is_none")] pub wanted: Option<u16> }
  /// What to do with a listener on `local`: spawn its accept loop. Each connection asks
  /// `Maps::target(local)` where it goes, so a map can change ports without a rebind.
  pub type Serve<'a> = &'a dyn Fn(TcpListener, u16) -> JoinHandle<()>;
  impl Maps {
      pub fn ensure(&self, id: &str, port: u16, wanted: Option<u16>, avoid: &[u16], serve: Serve) -> Option<u16>;
      pub fn target(&self, local: u16) -> Option<Map>;
  }
  // numbers.rs
  /// Another device's table was read: remember its numbers (Task 4 adds the clash check here).
  pub fn saw(state: &Arc<State>, id: &str, name: &str, numbers: &[u16]);
  ```
  - `ensure` with `wanted = Some(w)`, in this order:
    1. If the map already has `w` and listens on it, use it.
    2. Otherwise, if no other entry has `w` and `listen(w)` succeeds, the map moves to `w`. Its old port's tasks are aborted.
    3. Otherwise, if another entry has `w` but that entry's `wanted != Some(w)`, it is moved out of the way first. It gets the lowest free port by the yield rule (below). The map then takes over that entry's listeners on `w`, so no rebind is needed.
    4. Otherwise (another program has `w`, or another entry sits on it as its own number), the map yields. It keeps its current port if it has one and it still listens. If not, it takes the lowest port of the range that no entry uses, that is not in `avoid`, that is not `w`, and that `listen` accepts.
  - In every case `wanted` is stored, and the file is saved when anything changed.
  - With `wanted = None` (an old sharer), `ensure` is today's behaviour, plus `avoid`.
  - Callers pass `avoid = numbers.seen()` plus this device's own share numbers.
  - `share_cmds::shares` (with `to`) and `ipc::reached`:
    - Call `numbers::saw` with the reply's `local`s.
    - Pass each item's `local` as `wanted`.
    - Build `addr` from the item's `proto` (absent → `Proto::guess(port)`).
    - Add to the row: `proto`, `proto_auto` (absent → true), `web`, and `wanted` (only when the row's `local != wanted`).
  - The table reply gets `"old": true` when any item lacks `proto` (an empty list → false).
  - `carry` logs `map_refused` with `reason: "gone"` when `target(local)` is None.

- [ ] **Step 1: Write the failing `maps.rs` unit tests** (ranges from 29400 upward)
  - `a_wanted_number_is_used_when_free`: `ensure("111111111", 8000, Some(29400), &[], ..) == Some(29400)`, and the saved map has `wanted: Some(29400)`.
  - `a_wanted_number_another_program_has_yields_past_avoided`: hold 29410. `ensure(.., Some(29410), &[29411], ..) == Some(29412)`.
  - `a_yielded_map_moves_back_when_its_number_is_free`: continue the above. Drop the holder, then `ensure` again `== Some(29410)`, and 29412 stops answering.
  - `a_map_on_its_own_number_is_not_moved`: A gets `Some(29420)`. C asks for 29420 too and gets 29421. A is still 29420.
  - `two_maps_on_each_others_numbers_both_end_on_their_own`:
    - File `[map(A,8000,29430) no wanted, map(C,5353,29431) no wanted]`; `start` them.
    - `ensure(A, 8000, Some(29431)) == Some(29431)`.
    - `ensure(C, 5353, Some(29430)) == Some(29430)`.
    - `target(29431)` is A and `target(29430)` is C.
  - Adapt the existing tests to the new `ensure`/`Serve` signatures, with `None, &[]`.
- [ ] **Step 2: Write the failing testkit tests** (`share_numbers.rs`; sharer `own_ports` off; all devices in one range)
  - `a_visitor_uses_the_share_number_and_a_second_one_yields`:
    - A shares an echo on number 29600.
    - B: `shares --to A` row has `local == 29600`, `addr == "http://localhost:29600"`, no `wanted`; `through(29600)` echoes.
    - C (also knowing A): row has `local == 29601` and `wanted == 29600`.
  - `the_yielded_visitor_moves_back`: continue. Stop B, and C reads again: `local == 29600`, no `wanted`.
  - `hosts_carries_the_number_and_the_yield`: the same through `hosts`.
  - `an_old_sharer_still_works`:
    - A shares through a hand-written shares.json, in the `(0,0)` range, so it has no number and its reply items have no `local`.
    - B gets the lowest free port of its own range, with no `wanted`.
    - Because A's items still carry `proto` (Task 2), "old" here only means "no number". Also add a share_cmds unit test where items lack `proto`: `old == true`.
  - `long_lived_streams_are_not_held_back` (§3.6):
    - A test server writes `data: n\n\n` every 100 ms.
    - Read through B's map and through the sharer's own number (a second sharer with `own_ports` on, in its own range).
    - Over 3 s, no gap between events is more than 200 ms.
    - Rule: the spec's 5 minutes is covered on the real machine; CI holds 3 s.
- [ ] **Step 3: Run, expect FAIL**
  Run: `cd rust && PATH=$HOME/.cargo/bin:$PATH cargo test -p rapp-service maps:: && cargo test -p rapp-testkit --test share_numbers --test maps`
- [ ] **Step 4: Implement**
- [ ] **Step 5: Run the workspace; expect all pass**
- [ ] **Step 6: Commit** `feat(share): visitors take the share number, or yield and say so`

---

### Task 4: Two sharers on one number — the larger ID moves

**Files:**
- Modify: `rust/service/src/numbers.rs`, `rust/service/src/sharing.rs`, `rust/service/src/share_cmds.rs` (own rows)
- Test: `rust/testkit/tests/share_numbers.rs`

**Interfaces:**
- Consumes: `numbers::saw`, `numbers::yields`, `Shares::renumber`, `sync_own`.
- Produces:
  - `Numbers` gains `renumbered: Mutex<HashMap<u16 /*port*/, Renumbered>>`, with `pub struct Renumbered { pub from: u16, pub with: String }`.
  - `saw` checks, after recording the numbers: for each of this device's shares whose `local` is in `numbers` and where `yields(my_id, id)`, run `renumber(port, pick)`. It then:
    - logs `share_renumbered {port, from, to, with: id}`;
    - stores `Renumbered { from, with: name }`;
    - runs `sync_own`.
  - Own rows of `shares` carry `"renumbered": {"from": N, "with": "name"}` while it is stored.
  - Any `share` request (local or remote) that names the port clears it. The GUI's 知道了 button sends a bare `share` of the port.
  - A device with no ID never renumbers.

- [ ] **Step 1: Write the failing testkit tests** (own_ports off on both sharers, so both pick 29700)
  - `two_sharers_on_one_number_the_larger_id_moves`:
    - A and B each share an echo before they know each other; both are on 29700.
    - Write hosts.json so each knows the other. A runs `shares --to B` and B runs `shares --to A`.
    - The larger-ID device's share is now 29701, and its own row has `renumbered == {"from":29700,"with":<the name its hosts.json gives the other>}`.
    - The smaller keeps 29700 and has no `renumbered`.
  - `a_bare_share_clears_the_notice`.
  - `the_visitor_follows_a_renumbered_share`:
    - Visitor C (range 29700) knows only the larger-ID device L and reads L's table before the clash is found: C's row has `local == 29700` (L's number then; nothing on this machine holds it, since sharers run with `own_ports` off).
    - Then L and the smaller device read each other's tables, and L renumbers to 29701.
    - C reads L's table again: its row has `local == 29701` and no `wanted`, and C's old port 29700 stops answering.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run the workspace; expect all pass**
- [ ] **Step 5: Commit** `feat(share): a share number two sharers hold is given up by the larger ID`

---

### Task 5: Detect the protocol when a port is shared

**Files:**
- Create: `rust/service/src/probe.rs`
- Modify:
  - `rust/net/src/quic.rs`: add `pub fn probe_tls_config() -> Arc<rustls::ClientConfig>`, reusing `AcceptAny`, with no ALPN.
  - `rust/service/Cargo.toml`: `rustls.workspace = true`.
  - `rust/service/src/sharing.rs`, `share_cmds.rs`, `state.rs`.
- Test: unit tests in `probe.rs`; one testkit test in `share_numbers.rs`

**Interfaces:**
- Produces:
  ```rust
  /// Each step is a new connection to `127.0.0.1:<port>`, then `[::1]:<port>` (`forward::connect_local`),
  /// with STEP_WAIT = 300 ms for its reply. None: nothing accepts on the port.
  pub async fn detect(port: u16) -> Option<Proto>;
  pub struct Probed { .. }  // Mutex<HashSet<u16>>: ports detected in this run of the service
  // sharing.rs
  pub async fn settle(state: &State, ports: &[u16]);  // for each proto_auto share not yet Probed: detect; Some(p) → set_proto(port, p, true), mark Probed, log share_proto {port, proto}; None → leave unprobed
  ```
  - **Steps, in order:**
    1. Connect and send nothing. The first bytes read start with `SSH-` → Ssh.
    2. Write the first flight of a `rustls::ClientConnection` (server name `localhost`) and read up to 6 bytes. `[0] == 0x16 && [1] == 0x03 && [5] == 0x02` (a ServerHello, not an echoed ClientHello) → Https.
    3. Write `HEAD / HTTP/1.0\r\nHost: localhost\r\n\r\n`. The reply starts with `HTTP/` → Http.
    4. Otherwise → Tcp.
  - A connect that fails at step 1 gives None. A later step's connect failure counts as "not this protocol".
  - **Callers:**
    - `settle` runs after `sharing::share` for the shared ports, in both `share_cmds::share` and the remote `answer`. It runs before replying, so the reply carries the detected protocol.
    - `table()` runs `settle` for its listening shares.
    - A proto given by the user (`proto_auto` false) is never probed.

- [ ] **Step 1: Write the failing unit tests**. Fake servers on `127.0.0.1:0`:
  - `an_ssh_banner_is_ssh`: the server writes `SSH-2.0-test\r\n` on accept.
  - `a_server_hello_is_https`: the server reads, then writes `[0x16,0x03,0x03,0x00,0x04,0x02,0,0,0]`.
  - `an_http_reply_is_http`: the server reads, then writes `HTTP/1.1 400 Bad Request\r\n\r\n` and closes. It does so for every request, including the TLS one.
  - `an_echo_service_is_tcp`.
  - `a_silent_service_is_tcp`: accepts and never writes. The whole `detect` takes under 1.5 s.
  - `a_service_that_closes_at_once_is_tcp`.
  - `nothing_listening_is_none`.
- [ ] **Step 2: Run, expect FAIL**
  Run: `cd rust && PATH=$HOME/.cargo/bin:$PATH cargo test -p rapp-service probe::`
- [ ] **Step 3: Implement** `detect`, `Probed`, `settle`, and the calls.
- [ ] **Step 4: Testkit `a_share_of_an_echo_is_detected_as_tcp`**
  - IPC `share` of an echo port, with a range so it has a number: the reply has `proto == "tcp"`, `proto_auto == true`, and `addr == "tcp://localhost:N"`.
  - Sharing a port with nothing listening gives `"http"` and stays unprobed.
  - Start an HTTP fake on it and read `shares`: the row says `"http"`. Use any listener that replies `HTTP/1.0 200 OK`.
- [ ] **Step 5: Run the workspace; expect all pass.** Existing testkit tests that share an echo and pinned `http://` change to `tcp://`; update them.
- [ ] **Step 6: Commit** `feat(share): detect the protocol of a shared port`

---

### Task 6: Command line, user doc, real-machine checklist

**Files:**
- Modify: `rust/cli/src/args.rs`, `rust/cli/src/say.rs`, `rust/cli/src/main.rs`
- Create: `docs/port-sharing.md` (user doc, Chinese)
- Modify: `tasks/todo.md` (new last section)

**Interfaces:**
- Consumes: IPC `share` reply items `{port, local?, proto, proto_auto, addr, allow?, warn?}`; `shares` own rows; `hosts` rows `{port, local?, addr, wanted?, proto}`.
- Produces: `Cmd::Share { ports, allow, raw, note, proto: Option<String> }` and a `--proto <http|https|tcp|ssh>` option. Any other value is the error `--proto 只能是 http、https、tcp、ssh`. `--proto` without a port is an error, like the other options. The IPC `share` request carries `proto` only when given.

- [ ] **Step 1: Write the failing `say.rs`/`args.rs` tests**
  - `shared`:
    - `{"port":8007,"local":28000,"proto":"http","proto_auto":true,"addr":"http://localhost:28000"}` prints `已分享：8007 → http://localhost:28000（探测到 http）\n` and, once at the end, `在别的设备上也用这个地址\n`.
    - With `proto_auto:false` and tcp, the line is `已分享：8007 → tcp://localhost:28000`.
    - With no `addr`: `已分享：8007（没有空的号）`.
    - The `只给` and warn lines stay.
    - The old `ELSEWHERE` constant is removed.
  - `table`: the header is `这台设备：297283213   中继：…`, with no `.rapp`. The columns are `端口  地址  状态  只给`. The 地址 cell is the row's `addr`, or `没有空的号`. A taken row adds `本机上 28000 被别的程序占着，本机请用 localhost:8007` as a following line. A renumbered row adds `28000 和 Mini 撞了，换成 28003`.
  - `hosts`: there is no `.rapp` in the ID column. A row with `wanted` gets a last cell `这台上是 28002（28001 被占）`.
  - `args`: `share 8007 --proto tcp` parses; `share 8007 --proto ftp` and `share --proto tcp` fail with the messages above.
- [ ] **Step 2: Run, expect FAIL**
  Run: `cd rust && PATH=$HOME/.cargo/bin:$PATH cargo test -p rapp-cli`
- [ ] **Step 3: Implement.** Update the `rapp share` usage text in `args.rs` line 4 to show `[--proto http|https|tcp|ssh]`.
- [ ] **Step 4: Write `docs/port-sharing.md`**, about one page, from the spec:
  - one number everywhere;
  - protocols and copy;
  - the yield, taken and renumber notices;
  - long connections (SSE / Streamable HTTP / WebSocket) work, but drop when the link between devices drops, and clients reconnect;
  - after upgrading to this version a visitor's address changes once, so bookmarks and MCP configs need one edit.
  Add the real-machine section to `tasks/todo.md` with spec §7 items 1–4 as checkboxes, plus "an MCP connection kept 5 minutes".
- [ ] **Step 5: Run `cargo test --workspace`; expect all pass**
- [ ] **Step 6: Commit** `feat(cli): addresses with protocol, --proto, no .rapp; docs`

---

### Task 7: Panel — protocol picker, copy with protocol, notices

**Files:**
- Modify: `gui/lib/shares.dart`, `gui/lib/service_client.dart` (`share`), `gui/lib/ui/shares_section.dart`
- Test: `gui/test/ui/shares_section_test.dart` (and its fake `SharesApi`), plus any `shares.dart` parsing test

**Interfaces:**
- Consumes: `shares` rows `{port, note, allow, addr, web, listening, mine, local?, proto, proto_auto, wanted?, taken?, renumbered?: {from, with}}` and table-level `old`. Also the `share` request's `proto`.
- Produces:
  - `ShareRow` gains:
    - `final String proto;` (default `'http'`)
    - `final bool protoAuto;`
    - `final int? local, wanted;`
    - `final bool taken;`
    - `final ({int from, String with_})? renumbered;` or a small class; implementer's choice.
  - `ShareTable` gains `final bool old;`.
  - `SharesApi.share` gains `String? proto`.

- [ ] **Step 1: Write the failing widget tests**
  - Each row shows a protocol control `Key('share-proto-<port>')` with the current proto. When `protoAuto` is set, the text `自动` sits beside it.
  - Choosing `tcp` calls `api.share(to:, ports:[port], proto:'tcp')`.
  - When `table.old`, there is no `share-proto-*`.
  - `复制` copies `addr` exactly; check `tcp://localhost:28000` and `ssh -p 28001 localhost`.
  - `打开` (`share-open-*`) appears only when `web`.
  - A row with `wanted: 28000, local: 28005` shows `这台上是 28005（28000 被占）`.
  - A row with `taken` and port 8007, local 28000, shows `本机上 28000 被别的程序占着，本机请用 localhost:8007`.
  - A row with `renumbered {from:28000, with:'Mini'}`, local 28003, shows `28000 和 Mini 撞了，换成 28003` and a `知道了` button (`Key('share-renumbered-ok-<port>')`) that calls `api.share(to:, ports:[port])`.
  - An own row (`mine`, no address) shows `没有空的号` when the table is this device's (`to == null`). A remote row that is `mine` with no address keeps `没有本机端口可用`.
- [ ] **Step 2: Run, expect FAIL**
  Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/shares_section_test.dart; git checkout pubspec.lock`
- [ ] **Step 3: Implement.** Use the panel's existing button/menu widgets (look in `gui/lib/ui/` for the menu that other rows use). The protocol choices are `http`, `https`, `tcp`, `ssh`.
- [ ] **Step 4: Run the full GUI suite**
  Run: `cd gui && ~/development/flutter/bin/flutter test; git checkout pubspec.lock`
  Expected: all pass, and `flutter analyze` is clean.
- [ ] **Step 5: Commit** `feat(gui): share protocol picker, protocol addresses, number notices`
