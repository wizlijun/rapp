//! Opt-in native smoke test. Captures pixels, but never sends keyboard/mouse input,
//! changes the clipboard, locks the screen, or contacts a saved device/relay.
#![cfg(target_os = "linux")]
use rapp_client_core::{
    codec::Decoder,
    protocol::{self, Address, Incoming},
};
use std::{
    io::{BufRead, BufReader, Write},
    net::TcpStream,
    process::{Child, Command, Stdio},
    time::Duration,
};

struct Worker(Child);
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn connect(port: u16, token: &str) -> TcpStream {
    connect_app(port, token, "")
}
fn connect_app(port: u16, token: &str, app: &str) -> TcpStream {
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(8))).unwrap();
    let o = Address {
        host: "127.0.0.1".into(),
        port,
        token: token.into(),
        app: app.into(),
        mode: 2,
        fps: 5,
    };
    // Deliberate fragmentation of the authenticated hello.
    let bytes = o.hello(1.);
    for chunk in bytes.chunks(3) {
        s.write_all(chunk).unwrap();
    }
    s
}
fn until(s: &mut TcpStream, accept: impl Fn(&Incoming) -> bool) -> Incoming {
    for _ in 0..30 {
        let (message, _) = protocol::read_message(s).unwrap();
        if accept(&message) {
            return message;
        }
        if matches!(message, Incoming::Frame { .. }) {
            s.write_all(&protocol::frame_ack(0)).unwrap();
        }
        if let Incoming::Error(e) = message {
            panic!("host error: {e}");
        }
    }
    panic!("expected host message");
}

#[test]
#[ignore = "requires a graphical session; read-only native capture"]
fn native_desktop_stream_auth_takeover_ping_kick_and_eof() {
    let bin = env!("CARGO_BIN_EXE_rapp-host");
    let list = Command::new(bin)
        .args(["list-apps", "--json"])
        .output()
        .unwrap();
    let first = String::from_utf8(list.stdout).unwrap();
    let list: serde_json::Value = serde_json::from_str(first.lines().next().unwrap()).unwrap();
    assert_eq!(list["permissions"]["screen_recording"], true, "{list}");
    assert_eq!(list["apps"][0]["app"], "desktop:");
    let mut child = Worker(
        Command::new(bin)
            .args([
                "serve",
                "--app",
                "desktop:",
                "--bind",
                "127.0.0.1",
                "--port",
                "0",
                "--token-env",
                "RAPP_HOST_TEST_TOKEN",
                "--json",
            ])
            .env("RAPP_HOST_TEST_TOKEN", "native-test-token")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
    );
    let mut output = BufReader::new(child.0.stdout.take().unwrap());
    let mut line = String::new();
    output.read_line(&mut line).unwrap();
    let event: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(event["event"], "listening", "{line}");
    let port = event["port"].as_u64().unwrap() as u16;
    let mut a = connect(port, "native-test-token");
    assert!(
        matches!(until(&mut a, |m| matches!(m, Incoming::Ready(..))), Incoming::Ready(_, w, h) if w > 0 && h > 0)
    );
    assert!(
        matches!(until(&mut a, |m| matches!(m, Incoming::Windows(_))), Incoming::Windows(w) if w.len() == 1 && w[0].id == 1)
    );
    let frame = until(&mut a, |m| matches!(m, Incoming::Frame { .. }));
    if let Incoming::Frame {
        mode,
        width,
        height,
        flags,
        dx,
        dy,
        data,
        ..
    } = frame
    {
        let decoded = Decoder::default()
            .decode(mode, width, height, flags, dx, dy, &data)
            .unwrap()
            .unwrap();
        assert_eq!(decoded.len(), width * height * 4);
        assert!(decoded.as_chunks::<4>().0.iter().all(|p| p[3] == 255));
    }
    a.write_all(&protocol::frame_ack(0)).unwrap();
    let mut bad = connect(port, "incorrect-token!!");
    assert!(
        matches!(until(&mut bad, |m| matches!(m, Incoming::Error(_))), Incoming::Error(e) if e.contains("token"))
    );
    a.write_all(&protocol::ping(1234)).unwrap();
    assert!(matches!(
        until(&mut a, |m| matches!(m, Incoming::Pong(_))),
        Incoming::Pong(1234)
    ));
    let mut b = connect_app(port, "native-test-token", "desktop:");
    assert!(matches!(
        until(&mut b, |m| matches!(m, Incoming::Ready(..))),
        Incoming::Ready(..)
    ));
    assert!(
        matches!(until(&mut a, |m| matches!(m, Incoming::Error(_))), Incoming::Error(e) if e.contains("taken over"))
    );
    child
        .0
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"{\"cmd\":\"kick\"}\n")
        .unwrap();
    let kicked = until(&mut b, |m| matches!(m, Incoming::Error(_)));
    assert!(
        matches!(&kicked, Incoming::Error(e) if e.contains("kicked")),
        "{kicked:?}"
    );
    drop(child.0.stdin.take());
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while child.0.try_wait().unwrap().is_none() {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
#[ignore = "requires RAPP_TEST_ISOLATED_DESKTOP=1 and a private Xvfb or nested Wayland/Xwayland desktop"]
fn isolated_input_coordinates_shortcuts_unicode_and_release() {
    use rapp_host_linux::desktop::Desktop;
    use x11rb::{
        connection::Connection,
        protocol::{
            xproto::{self, ConnectionExt as _},
            Event,
        },
    };
    assert_eq!(
        std::env::var("RAPP_TEST_ISOLATED_DESKTOP").as_deref(),
        Ok("1")
    );
    let (conn, screen) = x11rb::connect(None).unwrap();
    let root = conn.setup().roots[screen].root;
    let window = conn.generate_id().unwrap();
    conn.create_window(
        x11rb::COPY_DEPTH_FROM_PARENT,
        window,
        root,
        0,
        0,
        400,
        300,
        0,
        xproto::WindowClass::INPUT_OUTPUT,
        0,
        &xproto::CreateWindowAux::new()
            .background_pixel(0x224466)
            .event_mask(
                xproto::EventMask::KEY_PRESS
                    | xproto::EventMask::KEY_RELEASE
                    | xproto::EventMask::BUTTON_PRESS
                    | xproto::EventMask::BUTTON_RELEASE
                    | xproto::EventMask::POINTER_MOTION,
            ),
    )
    .unwrap()
    .check()
    .unwrap();
    conn.map_window(window).unwrap().check().unwrap();
    conn.flush().unwrap();
    std::thread::sleep(Duration::from_millis(300));
    conn.set_input_focus(xproto::InputFocus::PARENT, window, x11rb::CURRENT_TIME)
        .unwrap()
        .check()
        .unwrap();
    let pos = conn
        .translate_coordinates(window, root, 0, 0)
        .unwrap()
        .reply()
        .unwrap();
    let mut desktop = Desktop::connect().unwrap();
    let display = desktop.select("desktop:").unwrap();
    std::thread::sleep(Duration::from_millis(150));
    let (x, y) = (
        (pos.dst_x as i32 - display.x + 50) as f32,
        (pos.dst_y as i32 - display.y + 60) as f32,
    );
    desktop.mouse(3, 0, x, y).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    desktop.mouse(0, 0, x, y).unwrap();
    desktop.mouse(1, 0, x, y).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    desktop.key(8, 1 << 20, true).unwrap(); // Cmd-C becomes Control-C
    desktop.key(8, 1 << 20, false).unwrap();
    let mut pressed = false;
    let mut released = false;
    let mut shortcut = false;
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while std::time::Instant::now() < deadline && !(pressed && released && shortcut) {
        if let Some(event) = conn.poll_for_event().unwrap() {
            match event {
                Event::ButtonPress(e) => {
                    assert_eq!((e.detail, e.event_x, e.event_y), (1, 50, 60));
                    pressed = true;
                }
                Event::ButtonRelease(_) => released = true,
                Event::KeyPress(e) if e.detail == 54 => {
                    assert!(e.state.contains(xproto::KeyButMask::CONTROL), "{e:?}");
                    shortcut = true;
                }
                _ => {}
            }
        } else {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    assert!(
        pressed && released && shortcut,
        "press={pressed}, release={released}, shortcut={shortcut}, pointer={:?}, focus={:?}",
        conn.query_pointer(root).unwrap().reply().unwrap(),
        conn.get_input_focus().unwrap().reply().unwrap(),
    );
    assert!(
        !conn
            .query_pointer(root)
            .unwrap()
            .reply()
            .unwrap()
            .mask
            .contains(xproto::KeyButMask::CONTROL),
        "event modifier stuck after Cmd-C"
    );
    // A held modifier and pointer button must be released when the session ends.
    desktop.key(0, 1 << 17, true).unwrap();
    desktop.mouse(0, 1, x, y).unwrap();
    desktop.release();
    std::thread::sleep(Duration::from_millis(100));
    let pointer = conn.query_pointer(root).unwrap().reply().unwrap();
    assert!(
        !pointer.mask.intersects(
            xproto::KeyButMask::SHIFT
                | xproto::KeyButMask::CONTROL
                | xproto::KeyButMask::BUTTON1
                | xproto::KeyButMask::BUTTON3
        ),
        "{:?}",
        pointer.mask
    );
    // Unicode uses a separate virtual keymap on Wayland; the normal map must survive.
    while conn.poll_for_event().unwrap().is_some() {}
    desktop.text("A中\n").unwrap();
    std::thread::sleep(Duration::from_millis(100));
    let mut unicode_presses = 0;
    while let Some(event) = conn.poll_for_event().unwrap() {
        if matches!(event, Event::KeyPress(_)) {
            unicode_presses += 1;
        }
    }
    assert!(
        unicode_presses >= 3,
        "only {unicode_presses} text key events"
    );
    desktop.key(0, 0, true).unwrap();
    desktop.key(0, 0, false).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    let mut normal_map = false;
    while let Some(event) = conn.poll_for_event().unwrap() {
        if let Event::KeyPress(e) = event {
            if e.detail == 38 {
                normal_map = true;
            }
        }
    }
    assert!(
        normal_map,
        "physical key map was not restored after Unicode input"
    );
    conn.destroy_window(window).unwrap().check().unwrap();
}
