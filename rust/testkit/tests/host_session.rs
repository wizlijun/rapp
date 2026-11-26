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
    let (cw, ch, samples) = c.canvas();
    assert_eq!((cw, ch), (width, height));
    assert!(samples == expected_canvas(width, height, 0, Mode::Gray4).as_slice(), "decoded canvas differs from the pattern");
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
