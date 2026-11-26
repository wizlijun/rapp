//! `rapp-host-core`'s session over a real TCP connection, on the fake platform (plan B,
//! Tasks 13-17). The host clock runs at `SPEED` (20x), so "5 s of host time" is a quarter of a
//! second here; every wait has a real-time limit that fails the test with what did arrive.

use std::time::{Duration, Instant};

use rapp_client_core::protocol::{self as client, Incoming};
use rapp_host_core::platform::OpenError;
use rapp_host_core::protocol::Mode;
use rapp_host_core::quantize;
use rapp_testkit::fake_platform::{FakePlatform, FAKE_APP, FAKE_APP_NAME};
use rapp_testkit::host_harness::{Controller, Host, SPEED};
use serde_json::{json, Value};

const TOKEN: &str = "fixture-secret";

/// Real time for `host_seconds` of host time.
fn host_time(host_seconds: f64) -> Duration {
    Duration::from_secs_f64(host_seconds / SPEED)
}

fn serve() -> (FakePlatform, Host) {
    let platform = FakePlatform::new();
    let host = Host::start(platform.clone(), FAKE_APP, TOKEN);
    (platform, host)
}

/// A controller whose hello was answered with `ready`.
fn ready(host: &Host, mode: u8) -> Controller {
    let mut c = Controller::connect(host.port());
    c.hello(TOKEN, FAKE_APP, "B", mode, 15);
    c.wait_for(|m| matches!(m, Incoming::Ready(..)));
    c
}

fn is_error(m: &Incoming, text: &str) -> bool {
    matches!(m, Incoming::Error(e) if e == text)
}

/// The full frame's picture as the host quantised it.
fn expected_canvas(width: usize, height: usize, scroll: i64, mode: Mode) -> Vec<u8> {
    let bgra = FakePlatform::pattern(width, height, scroll);
    quantize(&bgra, width, height, width * 4, mode)
}

/// Takes messages until the decoded canvas equals `want` (10 s real time at most).
fn wait_canvas(c: &mut Controller, want: &[u8]) -> bool {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if c.canvas().2 == want {
            return true;
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() || c.is_closed() {
            return false;
        }
        let _ = c.next_within(left.min(Duration::from_millis(100)));
    }
}

#[test]
fn listening_then_ready() {
    let (_platform, host) = serve();
    let listening = host.wait_event("listening");
    assert!(listening["port"].as_u64().is_some_and(|p| p > 0), "{listening}");
    let mut c = Controller::connect(host.port());
    c.hello(TOKEN, FAKE_APP, "B", 0, 15);
    match c.wait_for(|m| matches!(m, Incoming::Ready(..))) {
        // The canvas is the display the window is on, in points; the title is the app's name.
        Incoming::Ready(title, w, h) => assert_eq!((title.as_str(), w, h), (FAKE_APP_NAME, 1280, 800)),
        _ => unreachable!(),
    }
    match c.wait_for(|m| matches!(m, Incoming::Windows(_))) {
        Incoming::Windows(list) => {
            assert_eq!(list.len(), 1);
            assert_eq!((list[0].rect.x, list[0].rect.y, list[0].rect.w, list[0].rect.h), (240.0, 100.0, 800.0, 600.0));
        }
        _ => unreachable!(),
    }
    // Density 1: one pixel per point, so the frame is the region's size.
    let (width, height) = match c.wait_for(|m| matches!(m, Incoming::Frame { .. })) {
        Incoming::Frame { width, height, mode, .. } => {
            assert_eq!(mode, 0);
            (width, height)
        }
        _ => unreachable!(),
    };
    // The first frame can come in slices (each acknowledged): wait for the whole picture.
    assert!(wait_canvas(&mut c, &expected_canvas(width, height, 0, Mode::Gray4)), "decoded canvas differs from the pattern");
    assert_eq!((c.canvas().0, c.canvas().1), (width, height));
    let started = host.wait_event("session");
    assert_eq!(started["state"], "started");
    assert_eq!(started["mode"], "gray4");
    assert_eq!(started["fps"], 15);
}

/// A refused hello: the client is told why, the worker reports it and goes on serving.
fn refused(hello: impl FnOnce(&mut Controller), text: &str) {
    let (_platform, host) = serve();
    let mut c = Controller::connect(host.port());
    hello(&mut c);
    c.wait_for(|m| matches!(m, Incoming::Error(_)));
    assert!(c.seen.iter().any(|s| s.contains(text)), "{:?}", c.seen);
    let event = host.wait_event("rejected");
    assert!(event["reason"].as_str().is_some_and(|r| r.starts_with(text)), "{event}");
    assert!(c.closes_within(Duration::from_secs(5)));
    // Still serving.
    let _next = ready(&host, 0);
}

#[test]
fn wrong_token_is_rejected() {
    refused(|c| c.hello("not-the-secret", FAKE_APP, "B", 0, 15), "bad token");
}

#[test]
fn wrong_app_is_rejected() {
    refused(|c| c.hello(TOKEN, "other.app", "B", 0, 15), &format!("this host shares {FAKE_APP}"));
}

#[test]
fn version_mismatch_is_rejected() {
    refused(
        |c| {
            let mut p = vec![15u8];
            client::string(&mut p, TOKEN);
            client::string(&mut p, FAKE_APP);
            p.extend([0u8, 15]);
            p.extend(1.0f32.to_le_bytes());
            c.send(&client::packet(1, p));
        },
        "protocol version mismatch: host 16, client 15 (update both sides)",
    );
}

#[test]
fn silent_client_is_dropped_after_5s() {
    let (_platform, host) = serve();
    let mut c = Controller::connect(host.port());
    let start = Instant::now();
    assert!(c.closes_within(Duration::from_secs(5)), "the silent connection stayed open");
    let waited = start.elapsed();
    assert!(waited >= host_time(4.5), "closed after {waited:?}, before 5 s of host time");
    assert!(c.seen.iter().any(|s| s.contains("no hello received")), "{:?}", c.seen);
    let event = host.wait_event("rejected");
    assert_eq!(event["reason"], "no hello received");
}

#[test]
fn second_hello_takes_over() {
    let (_platform, host) = serve();
    let mut first = ready(&host, 0);
    let mut second = Controller::connect(host.port());
    host.command(&second.peer_line("iPad"));
    // The command is read on the worker's stdin thread; give it time to land before the hello.
    std::thread::sleep(Duration::from_millis(100));
    second.hello(TOKEN, FAKE_APP, "iPad", 0, 15);
    first.wait_for(|m| is_error(m, "taken over by iPad"));
    let ended = host.wait_event_where(|e| e["event"] == "session" && e["state"] == "ended");
    assert_eq!(ended["reason"], "taken over by iPad");
    second.wait_for(|m| matches!(m, Incoming::Ready(..)));
    assert!(first.closes_within(Duration::from_secs(5)));
}

#[test]
fn kick_ends_the_session() {
    let (_platform, host) = serve();
    let mut c = ready(&host, 0);
    host.command(r#"{"cmd":"kick"}"#);
    c.wait_for(|m| is_error(m, "kicked by the host"));
    let ended = host.wait_event_where(|e| e["event"] == "session" && e["state"] == "ended");
    assert_eq!(ended["reason"], "kicked by the host");
    // The host keeps listening.
    let _next = ready(&host, 0);
}

#[test]
fn quit_exits_0() {
    let (platform, host) = serve();
    let mut c = ready(&host, 0);
    host.command(r#"{"cmd":"quit"}"#);
    assert!(c.closes_within(Duration::from_secs(5)));
    let exit = host.wait_event("exit");
    assert_eq!(exit["code"], 0);
    assert_eq!(exit["reason"], "quit");
    // The session ended before the worker finished.
    assert!(host.saw(|e| e["event"] == "session" && e["state"] == "ended" && e["reason"] == "host stopped"));
    assert_eq!(host.wait_exit(), 0);
    assert!(!platform.awake(), "stay_awake was not released");
}

#[test]
fn stdin_eof_exits_0() {
    let (_platform, host) = serve();
    let mut c = ready(&host, 0);
    host.close_stdin();
    assert!(c.closes_within(Duration::from_secs(5)));
    let exit = host.wait_event("exit");
    assert_eq!(exit["code"], 0);
    assert_eq!(exit["reason"], "stdin closed");
    assert_eq!(host.wait_exit(), 0);
}

#[test]
fn yield_blocks_input_for_1s() {
    let (_platform, host) = serve();
    let mut c = ready(&host, 0);
    host.command(r#"{"cmd":"yield","by":"Mac"}"#);
    std::thread::sleep(Duration::from_millis(50));
    c.send(&client::key(36, 0, true));
    match c.wait_for(|m| matches!(m, Incoming::InputBlocked(_))) {
        Incoming::InputBlocked(by) => assert_eq!(by, "Mac"),
        _ => unreachable!(),
    }
    let blocked = host.wait_event("input_blocked");
    assert_eq!(blocked["by"], "Mac");
    // After 1 s of host time the same input goes through and is reported.
    std::thread::sleep(host_time(1.5));
    c.send(&client::key(36, 0, false));
    host.wait_event("input");
}

/// Garbage after a valid hello ends that session with Swift's text; the worker serves on.
#[test]
fn garbage_ends_the_session_not_the_worker() {
    let mut truncated_key = vec![6u8];
    truncated_key.extend(3u32.to_le_bytes());
    truncated_key.extend([36, 0, 0]);
    let mut huge = vec![6u8];
    huge.extend(u32::MAX.to_le_bytes());
    let second_hello_address = client::Address {
        host: "127.0.0.1".into(),
        port: 0,
        app: FAKE_APP.into(),
        token: TOKEN.into(),
        mode: 0,
        fps: 15,
    };
    let mut unknown = vec![99u8];
    unknown.extend(0u32.to_le_bytes());
    let cases: Vec<(&str, Vec<u8>, String)> = vec![
        ("unknown type", unknown, "bad data from client: unknown message type 99".into()),
        ("4 GiB length", huge, format!("bad data from client: message too large ({} bytes)", u32::MAX)),
        ("truncated key", truncated_key, "bad data from client: message is truncated".into()),
        ("host-to-client type", client::packet(2, ready_payload()), "unexpected message from client".into()),
        ("second hello", second_hello_address.hello(1.0), "unexpected hello".into()),
    ];
    let (_platform, host) = serve();
    for (name, bytes, text) in cases {
        let mut c = ready(&host, 0);
        c.send(&bytes);
        let wanted = text.clone();
        c.wait_for(move |m| is_error(m, &wanted));
        let ended = host.wait_event_where(|e| e["event"] == "session" && e["state"] == "ended");
        assert_eq!(ended["reason"], text.as_str(), "case {name}");
        assert!(c.closes_within(Duration::from_secs(5)), "case {name}: still open");
    }
    let _still = ready(&host, 0);
}

/// A well-formed `ready` body: a title and the canvas size.
fn ready_payload() -> Vec<u8> {
    let mut p = Vec::new();
    client::string(&mut p, "x");
    p.extend(10u16.to_le_bytes());
    p.extend(10u16.to_le_bytes());
    p
}

#[test]
fn menu_pick_is_ignored() {
    let (_platform, host) = serve();
    let mut c = ready(&host, 0);
    c.send(&client::menu_pick(&[0, 1]));
    c.send(&client::ping(7));
    c.wait_for(|m| matches!(m, Incoming::Pong(7)));
    assert!(!c.seen.iter().any(|s| s.starts_with("Error")), "{:?}", c.seen);
    assert!(!host.saw(|e| e["event"] == "session" && e["state"] == "ended"));
}

#[test]
fn cannot_open_reports_the_reason() {
    for error in [OpenError::NoDisplay, OpenError::SessionDisconnected, OpenError::NotInteractive, OpenError::OtherUser] {
        let reason = error.reason();
        let platform = FakePlatform::new();
        platform.set_open_error(Some(error));
        let (code, stdout, _) = Host::run_once(platform.clone(), &["list-apps", "--json"]);
        assert_eq!(code, 0, "{reason}");
        let listed: Value = serde_json::from_str(stdout.lines().next().unwrap_or("")).expect("list-apps JSON");
        assert_eq!(listed["permissions"]["error"], reason.as_str());
        assert_eq!(listed["permissions"]["screen_recording"], false);

        let host = Host::start(platform, FAKE_APP, TOKEN);
        let exit = host.wait_event("exit");
        assert_eq!(exit["code"], 1, "{reason}");
        assert_eq!(exit["reason"], reason.as_str());
        assert!(host.stderr_text().contains(&reason));
        assert_eq!(host.wait_exit(), 1);
    }
}

/// The literal JSON of spec §6.1 for the fake platform.
#[test]
fn list_apps_check_version_lock_json() {
    let one_line = |args: &[&str], platform: FakePlatform| -> (i32, Value) {
        let (code, stdout, stderr) = Host::run_once(platform, args);
        let line = stdout.lines().find(|l| !l.contains("\"event\"")).unwrap_or_else(|| panic!("{args:?}: {stdout}{stderr}"));
        (code, serde_json::from_str(line).expect("JSON"))
    };
    let permissions = json!({
        "screen_recording": true,
        "accessibility": true,
        "platform": "fake",
        "applications": true,
    });
    let (code, apps) = one_line(&["list-apps", "--json"], FakePlatform::new());
    assert_eq!(code, 0);
    assert_eq!(
        apps,
        json!({
            "apps": [
                {
                    "app": "desktop:",
                    "name": "桌面",
                    "displays": [{ "id": "1", "name": "Fake Display", "main": true, "width": 1280, "height": 800 }],
                },
                { "app": "fake.app", "name": "Fake" },
            ],
            "permissions": permissions,
        })
    );
    let (code, check) = one_line(&["check", "--json"], FakePlatform::new());
    assert_eq!(code, 0);
    assert_eq!(check, permissions);
    let (code, version) = one_line(&["version", "--json"], FakePlatform::new());
    assert_eq!(code, 0);
    assert_eq!(version, json!({ "version": env!("CARGO_PKG_VERSION"), "protocol": 16, "platform": "fake" }));
    let platform = FakePlatform::new();
    let (code, lock) = one_line(&["lock", "--json"], platform.clone());
    assert_eq!(code, 0);
    assert_eq!(lock, json!({ "ok": true }));
    let (code, again) = one_line(&["lock", "--json"], platform);
    assert_eq!(code, 0);
    assert_eq!(again, json!({ "ok": true, "already": true }));
}

// MARK: - Task 14: the picture loop

const MODES: [Mode; 5] = [Mode::Gray4, Mode::Color8, Mode::Color16, Mode::Duogray, Mode::Duocolor];

fn is_frame(m: &Incoming) -> bool {
    matches!(m, Incoming::Frame { .. })
}

fn frame_flags(m: &Incoming) -> u8 {
    match m {
        Incoming::Frame { flags, .. } => *flags,
        _ => 0,
    }
}

fn frame_region(m: &Incoming) -> client::Rect {
    match m {
        Incoming::Frame { region, .. } => *region,
        other => panic!("not a frame: {}", rapp_testkit::host_harness::describe(other)),
    }
}

/// A ready controller whose canvas shows the whole first picture; returns its pixel size.
fn showing(host: &Host, mode: u8) -> (Controller, usize, usize) {
    let mut c = ready(host, mode);
    c.wait_for(is_frame);
    let (w, h, _) = c.canvas();
    assert!(wait_canvas(&mut c, &expected_canvas(w, h, 0, MODES[mode as usize])), "{:?}", c.seen);
    (c, w, h)
}

/// Takes everything that arrives within `wait`.
fn drain(c: &mut Controller, wait: Duration) -> Vec<Incoming> {
    let deadline = Instant::now() + wait;
    let mut got = Vec::new();
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return got;
        }
        if let Some(m) = c.next_within(left) {
            got.push(m);
        } else if c.is_closed() {
            return got;
        }
    }
}

fn ended_event(host: &Host) -> Value {
    host.wait_event_where(|e| e["event"] == "session" && e["state"] == "ended")
}

#[test]
fn scroll_arrives_as_copy_tiles() {
    let (platform, host) = serve();
    let (mut c, w, h) = showing(&host, 0);
    platform.scroll_by(16);
    let m = c.wait_for(|m| is_frame(m) && frame_flags(m) & rapp_client_core::codec::COPIES != 0);
    assert!(frame_flags(&m) & rapp_client_core::codec::COPIES != 0);
    assert!(wait_canvas(&mut c, &expected_canvas(w, h, 16, Mode::Gray4)), "{:?}", c.seen);
}

#[test]
fn window_added_and_removed() {
    let (platform, host) = serve();
    let (mut c, _, _) = showing(&host, 0);
    let one = platform.windows();
    let mut two = one.clone();
    two.push(FakePlatform::window(2, rapp_host_core::Rect::new(100.0, 500.0, 400.0, 200.0)));
    platform.set_windows(two);
    c.wait_for(|m| matches!(m, Incoming::Windows(l) if l.len() == 2));
    // The union of both, rounded out to 8 points: x 96..1040.
    let f = c.wait_for(|m| is_frame(m) && frame_region(m).x <= 100.0 && frame_region(m).x + frame_region(m).w >= 1040.0);
    let r = frame_region(&f);
    assert!(r.y + r.h >= 700.0, "{r:?}");
    platform.set_windows(one);
    c.wait_for(|m| matches!(m, Incoming::Windows(l) if l.len() == 1));
    // Nothing changed for 1 s: no table goes out again.
    let quiet = c.quiet_for(host_time(1.0), |m| !matches!(m, Incoming::Windows(_)));
    assert!(quiet.is_ok(), "{quiet:?}");
}

/// Pauses, scrolls for 2 s of host time, renames the window, and returns what arrived.
fn paused_while_scrolling(platform: &FakePlatform, c: &mut Controller, mode: u8) -> Vec<Incoming> {
    c.send(&client::stream(mode, 0, 1.0, false, false));
    // Slices already on the way still arrive.
    let _ = drain(c, host_time(0.3));
    let frames = c.frames;
    let mut renamed = platform.windows();
    renamed[0].title = "Renamed".into();
    platform.set_windows(renamed);
    let start = Instant::now();
    let mut got = Vec::new();
    while start.elapsed() < host_time(2.0) {
        platform.scroll_by(16);
        got.extend(drain(c, host_time(0.1)));
    }
    got.extend(drain(c, host_time(0.3)));
    assert_eq!(c.frames, frames, "frames while paused: {:?}", c.seen);
    got
}

#[test]
fn pause_and_resume() {
    let (platform, host) = serve();
    let (mut c, w, h) = showing(&host, 0);
    let got = paused_while_scrolling(&platform, &mut c, 0);
    let changed = got.iter().filter(|m| matches!(m, Incoming::Changed)).count();
    // About once a second (the capture runs at 1 fps while paused).
    assert!((1..=4).contains(&changed), "{changed} changed messages: {:?}", c.seen);
    assert!(
        got.iter().any(|m| matches!(m, Incoming::Windows(l) if l.first().is_some_and(|w| w.title.contains("Renamed")))),
        "windows not delivered while paused: {:?}",
        c.seen
    );
    c.send(&client::stream(0, 15, 1.0, false, false));
    let first = c.wait_for(is_frame);
    // A diff against the last frame sent before the pause (Server.swift:1203), not a full frame.
    assert_eq!(frame_flags(&first) & rapp_client_core::codec::FULL, 0, "{:?}", c.seen);
    assert!(wait_canvas(&mut c, &expected_canvas(w, h, platform.scroll(), Mode::Gray4)), "{:?}", c.seen);
}

#[test]
fn pause_mode_change_resumes_full() {
    let (platform, host) = serve();
    let (mut c, w, h) = showing(&host, 0);
    let _ = paused_while_scrolling(&platform, &mut c, 0);
    // A mode switch while paused: still nothing sent.
    c.send(&client::stream(1, 0, 1.0, false, false));
    let _ = drain(&mut c, host_time(0.5));
    c.send(&client::stream(1, 15, 1.0, false, false));
    let first = c.wait_for(is_frame);
    assert_ne!(frame_flags(&first) & rapp_client_core::codec::FULL, 0, "{:?}", c.seen);
    assert!(matches!(first, Incoming::Frame { mode: 1, .. }));
    assert!(wait_canvas(&mut c, &expected_canvas(w, h, platform.scroll(), Mode::Color8)), "{:?}", c.seen);
}

#[test]
fn unacknowledged_controller_gets_bounded_frames() {
    let (platform, host) = serve();
    let mut c = Controller::connect(host.port());
    c.auto_ack = false;
    c.hello(TOKEN, FAKE_APP, "B", 0, 15);
    c.wait_for(|m| matches!(m, Incoming::Ready(..)));
    let start = Instant::now();
    while start.elapsed() < host_time(5.0) {
        platform.scroll_by(8);
        let _ = drain(&mut c, host_time(0.05));
    }
    // Without a single ack there is no RTT, so the cap is 1 frame in flight (SendPacer.cap).
    assert_eq!(c.frames, 1, "{:?}", c.seen);
    // The worker keeps reporting at most that one frame per second.
    let stats: Vec<Value> = host.events().into_iter().filter(|e| e["event"] == "stats").collect();
    assert!(stats.len() >= 3, "{stats:?}");
    assert!(stats.iter().all(|s| s["fps"].as_i64().is_some_and(|f| f <= 1)), "{stats:?}");
    // The paced sender holds one offer at most: acking now lets the newest picture through.
    c.auto_ack = true;
    c.send(&client::frame_ack(0));
    let (w, h, _) = c.canvas();
    assert!(wait_canvas(&mut c, &expected_canvas(w, h, platform.scroll(), Mode::Gray4)), "{:?}", c.seen);
}

#[test]
fn set_view_narrows_the_picture() {
    let (_platform, host) = serve();
    let mut c = ready(&host, 0);
    let id = match c.wait_for(|m| matches!(m, Incoming::Windows(l) if !l.is_empty())) {
        Incoming::Windows(l) => l[0].id,
        _ => unreachable!(),
    };
    c.wait_for(is_frame);
    c.send(&client::set_view(id, client::Rect { x: 0.0, y: 0.0, w: 400.0, h: 300.0 }));
    let f = c.wait_for(|m| is_frame(m) && frame_region(m).w <= 408.0);
    let r = frame_region(&f);
    // Window content coordinates: below the title row, inside the window, rounded out to 8 points.
    assert!(r.x >= 232.0 && r.w <= 408.0 && r.h <= 312.0, "{r:?}");
    // Window 0 clears the view: the whole window again.
    c.send(&client::set_view(0, client::Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 }));
    c.wait_for(|m| is_frame(m) && frame_region(m).w >= 800.0);
}

#[test]
fn set_stream_changes_mode() {
    let (platform, host) = serve();
    let (mut c, w, h) = showing(&host, 0);
    for (i, mode) in MODES.iter().enumerate().skip(1).chain(MODES.iter().enumerate().take(1)) {
        c.send(&client::stream(i as u8, 15, 1.0, false, false));
        let first = c.wait_for(|m| matches!(m, Incoming::Frame { mode: got, .. } if *got as usize == i));
        assert_ne!(frame_flags(&first) & rapp_client_core::codec::FULL, 0, "mode {i}: {:?}", c.seen);
        // Two-tone modes settle to the exact picture 300 ms after the last change.
        assert!(wait_canvas(&mut c, &expected_canvas(w, h, platform.scroll(), *mode)), "mode {i}: {:?}", c.seen);
    }
}

#[test]
fn density_is_capped_by_the_display_scale() {
    // The fake display has 2 pixels per point; B asks for 3.
    let (_platform, host) = serve();
    let mut c = Controller::connect(host.port());
    c.hello_at(TOKEN, FAKE_APP, 0, 15, 3.0);
    c.wait_for(|m| matches!(m, Incoming::Ready(..)));
    let f = c.wait_for(is_frame);
    let r = frame_region(&f);
    assert_eq!((c.canvas().0, c.canvas().1), ((r.w * 2.0) as usize, (r.h * 2.0) as usize), "{:?}", c.seen);
    // On a 1x display the same request captures one pixel per point.
    let platform = FakePlatform::new();
    platform.set_scale(1.0);
    let host = Host::start(platform, FAKE_APP, TOKEN);
    let mut c = Controller::connect(host.port());
    c.hello_at(TOKEN, FAKE_APP, 0, 15, 3.0);
    let f = c.wait_for(is_frame);
    let r = frame_region(&f);
    assert_eq!((c.canvas().0, c.canvas().1), (r.w as usize, r.h as usize), "{:?}", c.seen);
}

#[test]
fn stats_event_every_second() {
    let (_platform, host) = serve();
    let (_c, _, _) = showing(&host, 0);
    let _first = host.wait_event("stats");
    let start = Instant::now();
    // The event cursor is past the first one: this is the next.
    let _second = host.wait_event("stats");
    assert!(start.elapsed() < host_time(3.0) + Duration::from_secs(1));
    // Swift's `stats` line: these keys and no others (absent optionals left out).
    let allowed = ["event", "kbps", "fps", "width", "height", "weak", "fulls", "rttMs", "baseRttMs", "latencyMs", "encMs"];
    for e in host.events().iter().filter(|e| e["event"] == "stats") {
        let o = e.as_object().expect("object");
        for k in o.keys() {
            assert!(allowed.contains(&k.as_str()), "unexpected key {k}: {e}");
        }
        for k in ["kbps", "fps", "width", "height", "weak", "fulls"] {
            assert!(o.contains_key(k), "missing {k}: {e}");
        }
    }
}

#[test]
fn capture_error_ends_the_session() {
    let (platform, host) = serve();
    let (mut c, _, _) = showing(&host, 0);
    platform.fail_capture(Some("device lost"));
    c.wait_for(|m| is_error(m, "capture stopped: device lost"));
    assert!(c.closes_within(Duration::from_secs(5)));
    assert_eq!(ended_event(&host)["reason"], "capture stopped: device lost");
    platform.fail_capture(None);
    let _next = showing(&host, 0);
}

#[test]
fn capture_silence_does_not_spin() {
    let (platform, host) = serve();
    let (_c, _, _) = showing(&host, 0);
    let before = platform.frame_calls();
    std::thread::sleep(host_time(2.0));
    let calls = platform.frame_calls() - before;
    // 15 fps for 2 s, with room for timing: never a busy loop.
    assert!(calls <= 2 * 15 * 2, "{calls} frame calls in 2 s");
    assert!(calls >= 2, "the capture stopped polling: {calls}");
}

#[test]
fn target_exit_ends_the_session() {
    let (platform, host) = serve();
    let (mut c, _, _) = showing(&host, 0);
    let start = Instant::now();
    platform.kill_target();
    c.wait_for(|m| is_error(m, &format!("{FAKE_APP_NAME} quit")));
    // The 1 s tick notices; generous real-time slack for a loaded machine.
    assert!(start.elapsed() < host_time(1.5) + Duration::from_millis(500), "{:?}", start.elapsed());
    assert!(c.closes_within(Duration::from_secs(5)));
}

#[test]
fn all_windows_closed_keeps_the_session() {
    let (platform, host) = serve();
    let (mut c, _, _) = showing(&host, 0);
    let one = platform.windows();
    let before = frame_region(&{
        platform.touch();
        c.wait_for(is_frame)
    });
    platform.set_windows(vec![]);
    c.wait_for(|m| matches!(m, Incoming::Windows(l) if l.is_empty()));
    // An empty table keeps the region (Server.swift:939-963).
    platform.touch();
    let after = frame_region(&c.wait_for(is_frame));
    assert_eq!((before.x, before.y, before.w, before.h), (after.x, after.y, after.w, after.h));
    platform.set_windows(one);
    c.wait_for(|m| matches!(m, Incoming::Windows(l) if l.len() == 1));
    assert!(!c.is_closed());
}

#[test]
fn empty_region_sends_no_frame() {
    let (platform, host) = serve();
    let (mut c, _, _) = showing(&host, 0);
    platform.set_frame_size(Some((0, 0)));
    let quiet = c.quiet_for(host_time(1.5), |m| !is_frame(m));
    assert!(quiet.is_ok(), "{quiet:?}");
    assert!(!c.is_closed());
    platform.set_frame_size(None);
    c.wait_for(is_frame);
}

#[test]
fn disconnect_mid_frame_cleans_up() {
    let (platform, host) = serve();
    let mut c = ready(&host, 3);
    // The first frame of a two-tone picture is several slices; close during them.
    c.wait_for(is_frame);
    c.close();
    let ended = ended_event(&host);
    assert!(ended["reason"].is_string(), "{ended}");
    assert!(!platform.awake(), "stay_awake still on");
    // The capture thread stops polling (at most one call was in flight).
    std::thread::sleep(host_time(0.5));
    let calls = platform.frame_calls();
    std::thread::sleep(host_time(1.0));
    assert!(platform.frame_calls() <= calls + 1, "the capture thread is still polling");
    let _next = ready(&host, 0);
}

// MARK: - Task 15: input, covers, focus pane, state rules

use rapp_host_core::platform::OpenedApp;
use rapp_testkit::fake_platform::{COVER_APP, COVER_PID};

const DOWN: u8 = 0;
const UP: u8 = 1;
const LEFT: u8 = 0;

/// A ready controller and the id of the first window in its table.
fn with_window(host: &Host) -> (Controller, u32) {
    let mut c = ready(host, 0);
    let id = match c.wait_for(|m| matches!(m, Incoming::Windows(l) if !l.is_empty())) {
        Incoming::Windows(l) => l[0].id,
        _ => unreachable!(),
    };
    (c, id)
}

/// Waits (5 s real time at most) until the fake's log satisfies `pred`; returns the log.
fn wait_log(platform: &FakePlatform, pred: impl Fn(&[String]) -> bool) -> Vec<String> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let log = platform.log();
        if pred(&log) {
            return log;
        }
        assert!(Instant::now() < deadline, "fake log never matched: {log:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn click(c: &mut Controller, window: u32, x: f32, y: f32) {
    c.send(&client::mouse(DOWN, LEFT, window, x, y, 1));
    c.send(&client::mouse(UP, LEFT, window, x, y, 1));
}

fn presses(log: &[String]) -> usize {
    log.iter().filter(|l| l.starts_with("mouse down")).count()
}

#[test]
fn typed_text_arrives_in_20_unit_chunks() {
    let (platform, host) = serve();
    let (mut c, _) = with_window(&host);
    platform.clear_log();
    let start = Instant::now();
    c.send(&client::packet(5, "a".repeat(45).into_bytes()));
    let log = wait_log(&platform, |l| l.iter().filter(|x| x.starts_with("text ")).count() >= 3);
    let chunks: Vec<&String> = log.iter().filter(|x| x.starts_with("text ")).collect();
    assert_eq!(chunks, ["text 20", "text 20", "text 5"], "{log:?}");
    // 5 ms of host time after each chunk: at least two gaps before the last one went out.
    assert!(start.elapsed() >= host_time(0.010), "{:?}", start.elapsed());
    host.wait_event("input");
}

#[test]
fn keys_and_buttons_released_at_session_end() {
    let (platform, host) = serve();
    let (mut c, id) = with_window(&host);
    c.send(&client::key(36, 0, true));
    c.send(&client::mouse(DOWN, LEFT, id, 100.0, 100.0, 1));
    wait_log(&platform, |l| l.iter().any(|x| x == "key 36 down") && presses(l) == 1);
    c.close();
    ended_event(&host);
    let log = wait_log(&platform, |l| l.iter().any(|x| x.starts_with("release ")));
    assert!(log.iter().any(|x| x == "release keys=[36] buttons=[left]"), "{log:?}");
}

#[test]
fn click_count_reaches_the_platform() {
    let (platform, host) = serve();
    let (mut c, id) = with_window(&host);
    c.send(&client::mouse(DOWN, LEFT, id, 100.0, 100.0, 2));
    let log = wait_log(&platform, |l| presses(l) == 1);
    let press = log.iter().find(|l| l.starts_with("mouse down")).unwrap();
    // Window point (100, 100) on a window at (240, 100) of a display at the origin.
    assert_eq!(press, "mouse down left 340,200 2", "{log:?}");
}

#[test]
fn yield_blocks_then_releases() {
    let (platform, host) = serve();
    let (mut c, id) = with_window(&host);
    platform.clear_log();
    host.command(r#"{"cmd":"yield","by":"Mac"}"#);
    std::thread::sleep(Duration::from_millis(50));
    click(&mut c, id, 100.0, 100.0);
    c.wait_for(|m| matches!(m, Incoming::InputBlocked(by) if by == "Mac"));
    assert_eq!(host.wait_event("input_blocked")["by"], "Mac");
    assert_eq!(presses(&platform.log()), 0, "{:?}", platform.log());
    std::thread::sleep(host_time(1.5));
    click(&mut c, id, 100.0, 100.0);
    wait_log(&platform, |l| presses(l) == 1);
}

#[test]
fn elevated_window_reports_input_blocked() {
    let (platform, host) = serve();
    let (mut c, id) = with_window(&host);
    platform.clear_log();
    platform.set_elevated(Some(rapp_host_core::Rect::new(240.0, 100.0, 800.0, 600.0)));
    click(&mut c, id, 100.0, 100.0);
    c.wait_for(|m| matches!(m, Incoming::InputBlocked(by) if by == "elevated"));
    assert_eq!(host.wait_event("input_blocked")["by"], "elevated");
    // 0.2 s later: still inside the 0.5 s notice gap.
    std::thread::sleep(host_time(0.2));
    click(&mut c, id, 100.0, 100.0);
    let quiet = c.quiet_for(host_time(0.15), |m| !matches!(m, Incoming::InputBlocked(_)));
    assert!(quiet.is_ok(), "{quiet:?}");
    // 0.6 s after the first: a new notice.
    std::thread::sleep(host_time(0.3));
    click(&mut c, id, 100.0, 100.0);
    c.wait_for(|m| matches!(m, Incoming::InputBlocked(by) if by == "elevated"));
    assert!(!platform.log().iter().any(|l| l.starts_with("mouse ")), "{:?}", platform.log());
}

#[test]
fn cover_is_announced_every_5s_and_dismissed() {
    let (platform, host) = serve();
    let (mut c, id) = with_window(&host);
    let cover = rapp_host_core::Rect::new(300.0, 150.0, 200.0, 200.0);
    // Not a regular app: may not be closed from B.
    platform.set_cover(Some((cover, false)));
    click(&mut c, id, 100.0, 100.0);
    match c.wait_for(|m| matches!(m, Incoming::Covered { .. })) {
        Incoming::Covered { id: pid, name, bundle, dismissable } => {
            assert_eq!((pid, name.as_str(), bundle.as_str(), dismissable), (COVER_PID as u32, "Cover", COVER_APP, false));
        }
        _ => unreachable!(),
    }
    // The press never reached the app under the cover.
    assert_eq!(presses(&platform.log()), 0, "{:?}", platform.log());
    // Once per cover every 5 s.
    click(&mut c, id, 100.0, 100.0);
    let quiet = c.quiet_for(host_time(1.0), |m| !matches!(m, Incoming::Covered { .. }));
    assert!(quiet.is_ok(), "{quiet:?}");
    c.send(&client::dismiss_cover(COVER_PID as u32));
    std::thread::sleep(host_time(0.5));
    assert!(!platform.log().iter().any(|l| l.starts_with("close_cover")), "{:?}", platform.log());
    // A regular app's cover, after the 5 s: announced as dismissable and closed on request.
    platform.set_cover(Some((cover, true)));
    std::thread::sleep(host_time(5.0));
    click(&mut c, id, 100.0, 100.0);
    c.wait_for(|m| matches!(m, Incoming::Covered { dismissable: true, .. }));
    c.send(&client::dismiss_cover(COVER_PID as u32));
    wait_log(&platform, |l| l.iter().any(|x| x == &format!("close_cover {COVER_PID}")));
}

#[test]
fn app_opened_after_input_only() {
    let (platform, host) = serve();
    let (mut c, id) = with_window(&host);
    let other = || OpenedApp { id: "com.other.app".into(), name: "Other".into(), pid: 5000, regular: true };
    // Without input from B: not news.
    platform.open_other_app(other());
    let quiet = c.quiet_for(host_time(1.0), |m| !matches!(m, Incoming::AppOpened { .. }));
    assert!(quiet.is_ok(), "{quiet:?}");
    click(&mut c, id, 100.0, 100.0);
    wait_log(&platform, |l| presses(l) == 1);
    platform.open_other_app(other());
    match c.wait_for(|m| matches!(m, Incoming::AppOpened { .. })) {
        Incoming::AppOpened { bundle, name } => assert_eq!((bundle.as_str(), name.as_str()), ("com.other.app", "Other")),
        _ => unreachable!(),
    }
    // More than 2 s after the input: not news again.
    std::thread::sleep(host_time(2.5));
    platform.open_other_app(other());
    let quiet = c.quiet_for(host_time(1.0), |m| !matches!(m, Incoming::AppOpened { .. }));
    assert!(quiet.is_ok(), "{quiet:?}");
}

#[test]
fn secure_focus_follows_the_platform() {
    let (platform, host) = serve();
    let (mut c, _) = with_window(&host);
    platform.set_secure(true);
    c.wait_for(|m| matches!(m, Incoming::SecureFocus(true)));
    // Unchanged: nothing more.
    let quiet = c.quiet_for(host_time(0.5), |m| !matches!(m, Incoming::SecureFocus(_)));
    assert!(quiet.is_ok(), "{quiet:?}");
    platform.set_secure(false);
    c.wait_for(|m| matches!(m, Incoming::SecureFocus(false)));
}

/// The left half of the fake window below its title row, in global points, and the same
/// panel in window points.
fn left_panel() -> (rapp_host_core::Rect, rapp_host_core::Rect) {
    let global = rapp_host_core::Rect::new(240.0, 128.0, 400.0, 572.0);
    let window = rapp_host_core::Rect::new(0.0, 28.0, 400.0, 572.0);
    (global, window)
}

fn focus_rects(m: &Incoming) -> Option<(u32, Vec<client::Rect>)> {
    match m {
        Incoming::FocusRegion { window, rects } => Some((*window, rects.clone())),
        _ => None,
    }
}

/// `rects` is the one panel, rounded out by at most 8 points on each edge.
fn is_panel(rects: &[client::Rect], want: rapp_host_core::Rect) -> bool {
    let [r] = rects else { return false };
    let near = |a: f64, b: f64| (a - b).abs() <= 8.0;
    near(f64::from(r.x), want.min_x())
        && near(f64::from(r.y), want.min_y())
        && near(f64::from(r.x + r.w), want.max_x())
        && near(f64::from(r.y + r.h), want.max_y())
}

#[test]
fn focus_region_after_click() {
    let (platform, host) = serve();
    let (mut c, id) = with_window(&host);
    let (global, window) = left_panel();
    // What the session computes from the chain: the panel pick of the window-point chain.
    let pick = rapp_host_core::focus::panel(&[window], rapp_host_core::Size::new(800.0, 600.0)).expect("a panel");
    assert_eq!(pick.rect, window);
    platform.set_focus_chain(Some(vec![global]));
    c.send(&client::stream(0, 15, 1.0, false, true));
    std::thread::sleep(host_time(1.5));
    click(&mut c, id, 100.0, 200.0);
    let m = c.wait_for(|m| focus_rects(m).is_some_and(|(w, r)| w == id && !r.is_empty()));
    let (_, rects) = focus_rects(&m).unwrap();
    assert!(is_panel(&rects, pick.rect), "{rects:?}");
}

#[test]
fn slow_focus_query_is_abandoned() {
    let (platform, host) = serve();
    let (mut c, id) = with_window(&host);
    let (global, window) = left_panel();
    platform.set_focus_chain(Some(vec![global]));
    // 0.2 s per query against a 0.05 s budget: every answer comes too late.
    platform.set_focus_delay(Some(0.2));
    c.send(&client::stream(0, 15, 1.0, false, true));
    std::thread::sleep(host_time(1.5));
    click(&mut c, id, 100.0, 200.0);
    let quiet = c.quiet_for(host_time(1.0), |m| !focus_rects(m).is_some_and(|(_, r)| !r.is_empty()));
    assert!(quiet.is_ok(), "{quiet:?}");
    assert!(!c.is_closed());
    c.send(&client::ping(9));
    c.wait_for(|m| matches!(m, Incoming::Pong(9)));
    // A fast platform again: the next query is answered.
    platform.set_focus_delay(None);
    click(&mut c, id, 120.0, 220.0);
    let m = c.wait_for(|m| focus_rects(m).is_some_and(|(w, r)| w == id && !r.is_empty()));
    assert!(is_panel(&focus_rects(&m).unwrap().1, window), "{:?}", c.seen);
}

/// `genericChatJSON` (`Tests/RappCoreTests/RuleFixtures.swift:3-25`), verbatim.
const GENERIC_CHAT: &str = r#"{
  "format": "1.0", "id": "generic-chat", "name": "聊天类通用", "rev": 1, "updated": "2026-11-25",
  "ids": [],
  "regions": {
    "sidebar": {"edge": {"from": "left", "min": 160, "max": 420}},
    "main":    {"box": {"rightOf": "sidebar", "top": 0, "right": 0, "bottom": 0}},
    "bottom":  {"box": {"in": "main", "bottom": 0, "height": 160}},
    "button":  {"blob": {"in": "bottom", "round": true, "size": [24, 48], "pick": "rightmost"}},
    "markers": {"blob": {"in": {"strip": {"of": "sidebar", "side": "right", "width": 40}}, "size": [6, 20], "pick": "all"}},
    "tail":    {"box": {"in": "main", "above": "bottom", "height": 240}}
  },
  "signals": {
    "stop":    {"in": "button",  "detect": {"shape": "square"}, "status": "untested"},
    "rowBusy": {"in": "markers", "detect": {"motion": {"window": 0.4}}, "count": true, "status": "untested"}
  },
  "states": [
    {"state": "working", "when": {"any": ["stop", "rowBusy"]}, "hold": 0.6, "release": 2.0},
    {"state": "idle"}
  ],
  "require": ["bottom"]
}"#;

#[test]
fn state_rules_report() {
    let (_platform, host) = serve();
    let (mut c, _) = with_window(&host);
    c.send(&client::state_rules(GENERIC_CHAT));
    let m = c.wait_for(|m| matches!(m, Incoming::AppState(s) if s.contains("generic-chat")));
    let Incoming::AppState(text) = m else { unreachable!() };
    let report: Value = serde_json::from_str(&text).expect("appState JSON");
    assert_eq!(report["pack"], "generic-chat", "{report}");
    assert_eq!(report["rev"], 1, "{report}");
    assert_eq!(report["inferred"], true, "{report}");
    assert_ne!(report["health"], "invalid", "{report}");
    assert!(text.len() <= rapp_host_core::protocol::APP_STATE_LIMIT, "{} bytes", text.len());
    // Rules that cannot be read: one invalid report with the engine's text.
    c.send(&client::state_rules("{not json"));
    let m = c.wait_for(|m| matches!(m, Incoming::AppState(s) if s.contains("invalid")));
    let Incoming::AppState(text) = m else { unreachable!() };
    let report: Value = serde_json::from_str(&text).expect("appState JSON");
    assert_eq!(report["error"], "bad json", "{report}");
}

#[test]
fn oversized_rules_are_rejected_with_swift_text() {
    let (_platform, host) = serve();
    let (mut c, _) = with_window(&host);
    // One byte over `stateRulesLimit` (Protocol.swift:474): the decoder refuses it.
    let big = vec![b' '; rapp_host_core::protocol::STATE_RULES_LIMIT + 1];
    c.send(&client::packet(43, big));
    c.wait_for(|m| is_error(m, "bad data from client: rules too large"));
    assert_eq!(ended_event(&host)["reason"], "bad data from client: rules too large");
    assert!(c.closes_within(Duration::from_secs(5)));
}

// MARK: Clipboard, paste and file transfer (Task 16)

use std::io::{ErrorKind, Read as _, Write as _};
use std::net::{Shutdown, TcpStream};

use rapp_host_core::clipboard::{safe_file_name, ClipSource, CHUNK_SIZE, MAX_SIDE_CONNECTIONS};
use rapp_host_core::filename::portable_file_name;
use rapp_host_core::platform::ClipRead;
use rapp_host_core::protocol::{ClipKind, Message, MessageParser, PasteSource};
use rapp_host_core::transfers::{FileRef, ReceivedItem, PART_SUFFIX};

fn clip_read(source: ClipSource) -> ClipRead {
    ClipRead { source, text: None, image_png: None, files: Vec::new(), data: None, concealed: false }
}

fn text_clip(s: &str) -> ClipRead {
    ClipRead { text: Some(s.to_string()), ..clip_read(ClipSource::Text) }
}

/// The start of a PNG: signature and IHDR, which is all the host reads.
fn tiny_png(width: u32, height: u32) -> Vec<u8> {
    let mut p = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13];
    p.extend(b"IHDR");
    p.extend(width.to_be_bytes());
    p.extend(height.to_be_bytes());
    p.extend([8, 6, 0, 0, 0, 0, 0, 0, 0]);
    p
}

/// Deterministic bytes (a linear congruential generator).
fn seeded(n: usize, seed: u32) -> Vec<u8> {
    let mut x = seed;
    (0..n)
        .map(|_| {
            x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (x >> 24) as u8
        })
        .collect()
}

fn is_clip(m: &Incoming) -> bool {
    matches!(m, Incoming::Clipboard { .. })
}

/// A session whose clipboard has started: `screenLocked` goes out right after it.
fn clip_ready(host: &Host) -> Controller {
    let mut c = ready(host, 0);
    c.wait_for(|m| matches!(m, Incoming::ScreenLocked(false)));
    c
}

fn next_clip(c: &mut Controller) -> (u32, Option<String>, Value) {
    match c.wait_for(is_clip) {
        Incoming::Clipboard { id, text, info, .. } => (id, text, info),
        _ => unreachable!(),
    }
}

fn send_paste(c: &mut Controller, seq: u32, source: PasteSource) {
    c.send(&Message::Paste { seq, source }.encoded());
}

fn pasted(c: &mut Controller, want: u32) -> String {
    match c.wait_for(|m| matches!(m, Incoming::Pasted { seq, .. } if *seq == want)) {
        Incoming::Pasted { error, .. } => error,
        _ => unreachable!(),
    }
}

fn current_text(platform: &FakePlatform) -> Option<String> {
    platform.current_clipboard().and_then(|c| c.text)
}

/// A side connection, spoken in the host's own codec (the controller's reader refuses 24/25).
struct Side {
    stream: TcpStream,
    parser: MessageParser,
}

impl Side {
    fn open(host: &Host, first: Message) -> Side {
        let mut stream = TcpStream::connect(("127.0.0.1", host.port())).expect("connect a side connection");
        let _ = stream.set_nodelay(true);
        stream.write_all(&first.encoded()).expect("send the first message");
        Side { stream, parser: MessageParser::new() }
    }

    fn send(&mut self, m: &Message) -> bool {
        self.stream.write_all(&m.encoded()).is_ok()
    }

    /// The next message within 10 s real time; `None` once the host closed.
    fn next(&mut self) -> Option<Message> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            match self.parser.next() {
                Ok(Some(m)) => return Some(m),
                Ok(None) => {}
                Err(e) => panic!("bad data from the host: {e:?}"),
            }
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "nothing from the side connection within 10 s");
            let _ = self.stream.set_read_timeout(Some(left.min(Duration::from_millis(100))));
            match self.stream.read(&mut buf) {
                Ok(0) => return None,
                Ok(n) => self.parser.append(&buf[..n]),
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted) => {}
                Err(_) => return None,
            }
        }
    }

    fn start(&mut self) -> u64 {
        match self.next() {
            Some(Message::TransferStart(n)) => n,
            other => panic!("expected transferStart, got {other:?}"),
        }
    }

    fn close(self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

fn put_message(token: &str, item: u32, name: &str, total: u64) -> Message {
    Message::Put { token: token.to_string(), item, kind: ClipKind::Files, uti: String::new(), name: name.to_string(), total }
}

/// Uploads `bytes` as file item `item` on one side connection, from the offset the host
/// reports; returns that offset.
fn put_file(host: &Host, item: u32, name: &str, bytes: &[u8]) -> u64 {
    let mut side = Side::open(host, put_message(TOKEN, item, name, bytes.len() as u64));
    let have = side.start();
    for chunk in bytes[have as usize..].chunks(CHUNK_SIZE) {
        assert!(side.send(&Message::Chunk(chunk.to_vec())), "host closed during the upload");
    }
    match side.next() {
        Some(Message::Chunk(c)) if c.is_empty() => {}
        other => panic!("expected the closing empty chunk, got {other:?}"),
    }
    side.close();
    have
}

/// Waits (5 s real time at most) until `path` has `len` bytes.
fn wait_size(path: &std::path::Path, len: u64) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let size = std::fs::metadata(path).map(|m| m.len()).ok();
        if size == Some(len) {
            return;
        }
        assert!(Instant::now() < deadline, "{} has {size:?} bytes, not {len}", path.display());
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn file_names(dir: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|r| r.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    names.sort();
    names
}

fn is_transfer(e: &Value, dir: &str, kind: &str) -> bool {
    e["event"] == "transfer" && e["dir"] == dir && e["kind"] == kind
}

#[test]
fn host_copy_is_announced() {
    let (platform, host) = serve();
    let mut c = clip_ready(&host);

    platform.set_clipboard(text_clip("hello from A"));
    let (_, text, info) = next_clip(&mut c);
    assert_eq!((text.as_deref(), info["kind"].as_str()), (Some("hello from A"), Some("text")));
    // Inline text is reported when it is announced.
    let e = host.wait_event_where(|e| is_transfer(e, "a_to_b", "text"));
    assert_eq!(e["bytes"], "hello from A".len());

    let png = tiny_png(4, 3);
    platform.set_clipboard(ClipRead { image_png: Some(png.clone()), ..clip_read(ClipSource::Image) });
    let (_, _, info) = next_clip(&mut c);
    assert_eq!(info, json!({"kind": "image", "width": 4, "height": 3, "bytes": png.len()}));

    let dir = platform.data_root().join("copied");
    std::fs::create_dir_all(&dir).unwrap();
    let files: Vec<FileRef> = [("a.txt", 5usize), ("b.bin", 300)]
        .iter()
        .map(|(name, n)| {
            let path = dir.join(name);
            std::fs::write(&path, seeded(*n, 7)).unwrap();
            FileRef { path, size: *n as u64, modified: std::time::UNIX_EPOCH }
        })
        .collect();
    platform.set_clipboard(ClipRead { files, ..clip_read(ClipSource::Files) });
    let (_, _, info) = next_clip(&mut c);
    assert_eq!(
        info,
        json!({"kind": "files", "files": [{"name": "a.txt", "bytes": 5}, {"name": "b.bin", "bytes": 300}]})
    );

    // Copied while another app was in front: not this session's.
    platform.set_frontmost(false);
    platform.set_clipboard(text_clip("copied elsewhere"));
    assert_eq!(c.quiet_for(host_time(2.0), |m| !is_clip(m)), Ok(()));
    platform.set_frontmost(true);
    assert_eq!(c.quiet_for(host_time(1.0), |m| !is_clip(m)), Ok(()));

    // A password manager's item.
    platform.set_clipboard(ClipRead { concealed: true, ..text_clip("concealed item") });
    assert_eq!(c.quiet_for(host_time(2.0), |m| !is_clip(m)), Ok(()));

    // The host's own paste write, and its restore, are not copies.
    send_paste(&mut c, 1, PasteSource::Text("typed on B".to_string()));
    assert_eq!(pasted(&mut c, 1), "");
    wait_log(&platform, |l| l.iter().any(|x| x == "clipboard restore"));
    assert_eq!(c.quiet_for(host_time(1.0), |m| !is_clip(m)), Ok(()));
}

#[test]
fn paste_text_inline() {
    let (platform, host) = serve();
    let mut c = clip_ready(&host);
    platform.set_clipboard(text_clip("old clipboard"));
    next_clip(&mut c);
    platform.clear_log();

    let sent = Instant::now();
    send_paste(&mut c, 7, PasteSource::Text("from B".to_string()));
    assert_eq!(pasted(&mut c, 7), "");
    let answered = Instant::now();
    // The answer waits 0.15 s after the paste key.
    assert!(answered - sent >= host_time(0.15), "answered after {:?}", answered - sent);
    let log = wait_log(&platform, |l| l.iter().any(|x| x == "paste_key"));
    let order: Vec<&str> = log
        .iter()
        .map(String::as_str)
        .filter(|l| matches!(*l, "clipboard snapshot" | "activate" | "paste_key") || l.starts_with("clipboard write"))
        .collect();
    assert_eq!(order, ["clipboard snapshot", "clipboard write text 6", "activate", "paste_key"]);
    assert_eq!(platform.pastes().last(), Some(&Some(ReceivedItem::Text("from B".to_string()))));
    let e = host.wait_event_where(|e| is_transfer(e, "b_to_a", "text"));
    assert_eq!(e["bytes"], 6);

    // About 2 s later the old clipboard is back.
    wait_log(&platform, |l| l.iter().any(|x| x == "clipboard restore"));
    assert!(answered.elapsed() >= host_time(2.0), "restored after {:?}", answered.elapsed());
    assert_eq!(current_text(&platform).as_deref(), Some("old clipboard"));
}

#[test]
fn paste_does_not_restore_over_a_newer_copy() {
    let (platform, host) = serve();
    let mut c = clip_ready(&host);
    platform.set_clipboard(text_clip("old clipboard"));
    next_clip(&mut c);

    send_paste(&mut c, 1, PasteSource::Text("from B".to_string()));
    assert_eq!(pasted(&mut c, 1), "");
    // The user copies something new on A before the restore is due.
    platform.set_clipboard(text_clip("newer copy"));
    let (_, text, _) = next_clip(&mut c);
    assert_eq!(text.as_deref(), Some("newer copy"));
    std::thread::sleep(host_time(3.0));
    assert!(!platform.log().iter().any(|l| l == "clipboard restore"), "{:?}", platform.log());
    assert_eq!(current_text(&platform).as_deref(), Some("newer copy"));
}

#[test]
fn paste_when_locked_fails_with_the_fixed_text() {
    // Locked during the session: the target never comes to the front.
    let (platform, host) = serve();
    let mut c = clip_ready(&host);
    platform.set_frontmost(false);
    platform.set_locked(true);
    send_paste(&mut c, 3, PasteSource::Text("from B".to_string()));
    assert_eq!(pasted(&mut c, 3), "screen locked");
    assert!(!platform.log().iter().any(|l| l == "paste_key"), "{:?}", platform.log());

    // Locked at session start: the app is not attached yet, and B still gets an answer.
    let (platform, host) = serve();
    platform.set_locked(true);
    let mut c = ready(&host, 0);
    c.wait_for(|m| matches!(m, Incoming::ScreenLocked(true)));
    send_paste(&mut c, 4, PasteSource::Text("from B".to_string()));
    assert_eq!(pasted(&mut c, 4), "远程电脑已锁屏，解锁后再发送");
    assert!(!platform.log().iter().any(|l| l.starts_with("clipboard")), "{:?}", platform.log());
}

#[test]
fn paste_item_not_uploaded() {
    let (platform, host) = serve();
    let mut c = clip_ready(&host);
    send_paste(&mut c, 9, PasteSource::Item(77));
    assert_eq!(pasted(&mut c, 9), "not uploaded");
    assert!(!platform.log().iter().any(|l| l.starts_with("clipboard write")), "{:?}", platform.log());
    // The queue goes on after it.
    send_paste(&mut c, 10, PasteSource::Text("next".to_string()));
    assert_eq!(pasted(&mut c, 10), "");
}

#[test]
fn put_then_paste_a_file() {
    let (platform, host) = serve();
    let mut c = clip_ready(&host);
    let bytes = seeded(700 * 1024, 42);
    assert_eq!(put_file(&host, 5, "report.bin", &bytes), 0);
    let e = host.wait_event_where(|e| is_transfer(e, "b_to_a", "files"));
    assert_eq!((e["bytes"].as_u64(), e["name"].as_str()), (Some(bytes.len() as u64), Some("report.bin")));
    let path = host.downloads().join("report.bin");
    assert!(std::fs::read(&path).unwrap() == bytes, "uploaded bytes differ");
    assert_eq!(file_names(host.downloads()), ["report.bin"]);

    send_paste(&mut c, 2, PasteSource::Item(5));
    assert_eq!(pasted(&mut c, 2), "");
    assert_eq!(platform.pastes().last(), Some(&Some(ReceivedItem::File(path))));
}

#[test]
fn fetch_a_host_file() {
    let (platform, host) = serve();
    let mut c = clip_ready(&host);
    let dir = platform.data_root().join("copied");
    std::fs::create_dir_all(&dir).unwrap();
    let first = seeded(1000, 1);
    let second = seeded(600 * 1024, 2);
    let files: Vec<FileRef> = [("one.bin", &first), ("two.bin", &second)]
        .iter()
        .map(|(name, b)| {
            let path = dir.join(name);
            std::fs::write(&path, b).unwrap();
            FileRef { path, size: b.len() as u64, modified: std::time::UNIX_EPOCH }
        })
        .collect();
    platform.set_clipboard(ClipRead { files, ..clip_read(ClipSource::Files) });
    let (id, _, _) = next_clip(&mut c);

    let mut side = Side::open(&host, Message::Fetch { token: TOKEN.to_string(), clip: id, file: 1, offset: 0 });
    let total = side.start();
    assert_eq!(total, second.len() as u64);
    let mut got = Vec::new();
    while let Some(m) = side.next() {
        match m {
            Message::Chunk(c) => {
                assert!(c.len() <= CHUNK_SIZE);
                got.extend(c);
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(got == second, "fetched bytes differ ({} of {})", got.len(), second.len());
    let e = host.wait_event_where(|e| is_transfer(e, "a_to_b", "files"));
    assert_eq!(e["bytes"].as_u64(), Some(second.len() as u64));

    // From an offset: only the rest.
    let offset = 300_000u64;
    let mut side = Side::open(&host, Message::Fetch { token: TOKEN.to_string(), clip: id, file: 1, offset });
    side.start();
    let mut rest = Vec::new();
    while let Some(Message::Chunk(c)) = side.next() {
        rest.extend(c);
    }
    assert!(rest == second[offset as usize..], "fetched rest differs");
}

#[test]
fn put_resumes_after_disconnect() {
    let (_platform, host) = serve();
    let _c = clip_ready(&host);
    let bytes = seeded(700 * 1024, 9);
    let total = bytes.len() as u64;

    let mut side = Side::open(&host, put_message(TOKEN, 3, "big.bin", total));
    assert_eq!(side.start(), 0);
    // One whole chunk, then part of the next message, then the connection drops at 300 KiB.
    assert!(side.send(&Message::Chunk(bytes[..CHUNK_SIZE].to_vec())));
    let next = Message::Chunk(bytes[CHUNK_SIZE..2 * CHUNK_SIZE].to_vec()).encoded();
    let cut = next.len() - (2 * CHUNK_SIZE - 300 * 1024);
    let _ = side.stream.write_all(&next[..cut]);
    side.close();

    let part = host.downloads().join(format!("big.bin{PART_SUFFIX}"));
    wait_size(&part, CHUNK_SIZE as u64);

    let have = put_file(&host, 3, "big.bin", &bytes);
    assert!(have == CHUNK_SIZE as u64 || have == 2 * CHUNK_SIZE as u64, "resumed from {have}");
    assert!(std::fs::read(host.downloads().join("big.bin")).unwrap() == bytes, "uploaded bytes differ");
    assert_eq!(file_names(host.downloads()), ["big.bin"]);
}

#[test]
fn fifth_side_connection_is_refused() {
    let (_platform, host) = serve();
    let _c = clip_ready(&host);
    let mut open: Vec<Side> = (0..MAX_SIDE_CONNECTIONS as u32)
        .map(|i| {
            let mut s = Side::open(&host, put_message(TOKEN, 100 + i, &format!("slot{i}.bin"), 1 << 20));
            assert_eq!(s.start(), 0);
            s
        })
        .collect();
    let mut fifth = Side::open(&host, put_message(TOKEN, 200, "fifth.bin", 1 << 20));
    assert_eq!(fifth.next(), Some(Message::Error("busy".to_string())));
    assert_eq!(fifth.next(), None);
    assert!(host.stdout_text().contains("side connection: busy") || host.stderr_text().contains("side connection: busy"));

    // A slot comes back once one of them closes.
    open.pop().unwrap().close();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let mut again = Side::open(&host, put_message(TOKEN, 201, "again.bin", 1 << 20));
        match again.next() {
            Some(Message::TransferStart(0)) => break,
            Some(Message::Error(e)) if e == "busy" => {}
            other => panic!("unexpected {other:?}"),
        }
        assert!(Instant::now() < deadline, "the slot never came back");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn side_connection_with_wrong_token_is_refused() {
    let (_platform, host) = serve();
    let _c = clip_ready(&host);
    let mut fetch = Side::open(&host, Message::Fetch { token: "not-the-secret".to_string(), clip: 1, file: 0, offset: 0 });
    assert_eq!(fetch.next(), Some(Message::Error("bad token".to_string())));
    assert_eq!(fetch.next(), None);
    let mut put = Side::open(&host, put_message("not-the-secret", 1, "x.bin", 10));
    assert_eq!(put.next(), Some(Message::Error("bad token".to_string())));
    assert_eq!(put.next(), None);
    assert!(file_names(host.downloads()).is_empty(), "{:?}", file_names(host.downloads()));
}

#[test]
fn hostile_names_stay_inside() {
    let (platform, host) = serve();
    let _c = clip_ready(&host);
    let raws = ["..\\x", "a/b", "CON", "nul.txt", "a<b>.txt", "C:\\Users\\x\\报告.pdf", "../../escape.txt", "/etc/passwd2"];
    let mut want: Vec<String> = raws.iter().map(|r| portable_file_name(&safe_file_name(r))).collect();
    let distinct: std::collections::HashSet<&String> = want.iter().collect();
    assert_eq!(distinct.len(), want.len(), "the table must map to distinct names: {want:?}");
    for (i, raw) in raws.iter().enumerate() {
        put_file(&host, 300 + i as u32, raw, &seeded(10 + i, i as u32));
    }
    want.sort();
    assert_eq!(file_names(host.downloads()), want);
    // Nothing landed beside the downloads folder or above it.
    for leaf in ["x", "b", "escape.txt", "passwd2"] {
        assert!(!platform.data_root().join(leaf).exists(), "{leaf} escaped");
    }
    for entry in std::fs::read_dir(host.downloads()).unwrap() {
        assert!(entry.unwrap().file_type().unwrap().is_file());
    }
}
