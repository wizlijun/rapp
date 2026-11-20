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

#[test]
#[ignore = "requires RAPP_TEST_ISOLATED_DESKTOP=1 and a private display"]
fn isolated_clipboard_observation_typed_paste_restoration_and_concealed_data() {
    use gdk::{glib, prelude::*};
    use rapp_client_core::transfer::Copy;
    use rapp_host_linux::clipboard::Clipboard;
    assert_eq!(
        std::env::var("RAPP_TEST_ISOLATED_DESKTOP").as_deref(),
        Ok("1")
    );
    assert_ne!(unsafe { gtk4_sys::gtk_init_check() }, 0);
    let context = glib::MainContext::default();
    let display = gdk::Display::default().unwrap();
    let clipboard = display.clipboard();
    // On Wayland, a regular clipboard owner needs keyboard focus. The test
    // surface belongs only to the nested compositor, never the user's desktop.
    let window = unsafe { gtk4_sys::gtk_window_new() };
    unsafe {
        gtk4_sys::gtk_window_set_default_size(window.cast(), 320, 200);
        gtk4_sys::gtk_window_present(window.cast());
    }
    let pump = |duration: Duration| {
        let end = std::time::Instant::now() + duration;
        while std::time::Instant::now() < end {
            while context.pending() {
                context.iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    };
    pump(Duration::from_millis(250));
    let worker =
        Clipboard::start_with_executable(std::path::Path::new(env!("CARGO_BIN_EXE_rapp-host")))
            .unwrap();
    pump(Duration::from_millis(250));
    let _input = if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        let mut input = rapp_host_linux::desktop::Desktop::connect().unwrap();
        let screen = input.select("desktop:").unwrap();
        pump(Duration::from_millis(100));
        input
            .mouse(0, 0, screen.width as f32 / 2., screen.height as f32 / 2.)
            .unwrap();
        input
            .mouse(1, 0, screen.width as f32 / 2., screen.height as f32 / 2.)
            .unwrap();
        input.key(56, 1 << 17, true).unwrap();
        input.key(56, 0, false).unwrap();
        input.release();
        pump(Duration::from_millis(100));
        Some(input)
    } else {
        None
    };
    clipboard.set_text("synthetic clipboard 中文");
    let end = std::time::Instant::now() + Duration::from_secs(4);
    let observed = loop {
        pump(Duration::from_millis(10));
        if let Some(copy) = worker.next() {
            break copy;
        }
        assert!(std::time::Instant::now() < end, "clipboard event missing");
    };
    assert!(matches!(observed, Copy::Text(t) if t == "synthetic clipboard 中文"));
    // Keep servicing the source clipboard while the helper snapshots it.
    let (send, done) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let result = worker.set(&Copy::Data(
            "application/x-rapp-test".into(),
            b"typed attachment".to_vec(),
        ));
        send.send((worker, result)).unwrap();
    });
    let end = std::time::Instant::now() + Duration::from_secs(5);
    let worker = loop {
        pump(Duration::from_millis(10));
        if let Ok((worker, result)) = done.try_recv() {
            result.unwrap();
            break worker;
        }
        assert!(std::time::Instant::now() < end);
    };
    thread.join().unwrap();
    let (stream, _) = context
        .block_on(glib::future_with_timeout(
            Duration::from_secs(2),
            clipboard.read_future(&["application/x-rapp-test"], glib::Priority::DEFAULT),
        ))
        .unwrap()
        .unwrap();
    let bytes = context
        .block_on(stream.read_bytes_future(100, glib::Priority::DEFAULT))
        .unwrap();
    assert_eq!(&*bytes, b"typed attachment");
    pump(Duration::from_millis(2200));
    let restored = context
        .block_on(glib::future_with_timeout(
            Duration::from_secs(2),
            clipboard.read_text_future(),
        ))
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(restored.as_str(), "synthetic clipboard 中文");
    let providers = [
        gdk::ContentProvider::for_bytes(
            "text/plain;charset=utf-8",
            &glib::Bytes::from_static(b"secret fixture"),
        ),
        gdk::ContentProvider::for_bytes(
            "x-kde-passwordManagerHint",
            &glib::Bytes::from_static(b"secret"),
        ),
    ];
    clipboard
        .set_content(Some(&gdk::ContentProvider::new_union(&providers)))
        .unwrap();
    pump(Duration::from_millis(400));
    let unexpected = worker.next();
    assert!(
        unexpected.is_none(),
        "concealed or own clipboard write was announced: {unexpected:?}"
    );
    drop(worker);
    clipboard.set_text("synthetic clipboard before upload");
    pump(Duration::from_millis(80));
    // Exercise the listener's authenticated side connection through to native
    // clipboard ownership, not just the transfer store and clipboard in isolation.
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (finish_tx, finish_rx) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let directory = tempfile::tempdir().unwrap();
        let mut host = Worker(
            Command::new(env!("CARGO_BIN_EXE_rapp-host"))
                .args([
                    "serve",
                    "--app",
                    "desktop:",
                    "--port",
                    "0",
                    "--token-env",
                    "RAPP_HOST_TEST_TOKEN",
                ])
                .env("RAPP_HOST_TEST_TOKEN", "native-test-token")
                .env("RAPP_DOWNLOADS", directory.path())
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap(),
        );
        let mut output = BufReader::new(host.0.stdout.take().unwrap());
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        let event: serde_json::Value = serde_json::from_str(&line).unwrap();
        let port = event["port"].as_u64().unwrap() as u16;
        let mut socket = connect(port, "native-test-token");
        until(&mut socket, |m| matches!(m, Incoming::Ready(..)));
        let address = Address {
            host: "127.0.0.1".into(),
            port,
            token: "native-test-token".into(),
            app: String::new(),
            mode: 2,
            fps: 5,
        };
        let text = "synthetic uploaded 中文 ".repeat(4096);
        rapp_client_core::transfer::upload(
            &address,
            91,
            &Copy::Text(text),
            &Default::default(),
            |_, _| {},
        )
        .unwrap();
        socket
            .write_all(&rapp_client_core::transfer::paste_item(92, 91))
            .unwrap();
        let pasted = until(&mut socket, |m| {
            matches!(m, Incoming::Pasted { seq: 92, .. })
        });
        let Incoming::Pasted { error, .. } = pasted else {
            unreachable!()
        };
        assert!(error.is_empty(), "native paste failed: {error}");
        ready_tx.send(()).unwrap();
        finish_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    });
    let end = std::time::Instant::now() + Duration::from_secs(7);
    loop {
        pump(Duration::from_millis(5));
        if ready_rx.try_recv().is_ok() {
            break;
        }
        assert!(
            std::time::Instant::now() < end,
            "uploaded native paste did not complete"
        );
    }
    let pasted = context
        .block_on(glib::future_with_timeout(
            Duration::from_secs(2),
            clipboard.read_text_future(),
        ))
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(pasted.as_str(), "synthetic uploaded 中文 ".repeat(4096));
    finish_tx.send(()).unwrap();
    thread.join().unwrap();
    unsafe {
        gtk4_sys::gtk_window_destroy(window.cast());
    }
}

#[test]
#[ignore = "requires RAPP_TEST_ISOLATED_DESKTOP=1 and a private X11 display"]
fn isolated_application_capture_excludes_other_apps_and_tracks_geometry() {
    use rapp_host_linux::{desktop::Desktop, wire};
    use x11rb::{
        connection::Connection,
        protocol::{
            xproto::{self, ConnectionExt as _},
            Event,
        },
        wrapper::ConnectionExt as _,
    };
    assert_eq!(
        std::env::var("RAPP_TEST_ISOLATED_DESKTOP").as_deref(),
        Ok("1")
    );
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        // labwc does not implement Hyprland's surface export/mapping protocols.
        // It must continue offering desktop sessions without claiming app capture.
        if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_none() {
            assert!(!Desktop::connect().unwrap().application_capture_supported());
        }
        return;
    }
    let (conn, screen) = x11rb::connect(None).unwrap();
    let root = conn.setup().roots[screen].root;
    let atom = |name: &[u8]| conn.intern_atom(false, name).unwrap().reply().unwrap().atom;
    let pid = atom(b"_NET_WM_PID");
    let protocols = atom(b"WM_PROTOCOLS");
    let delete = atom(b"WM_DELETE_WINDOW");
    let target = conn.generate_id().unwrap();
    let cover = conn.generate_id().unwrap();
    for (window, color, process) in [(target, 0xcc4422, std::process::id()), (cover, 0x1133ee, 1)] {
        conn.create_window(
            x11rb::COPY_DEPTH_FROM_PARENT,
            window,
            root,
            50,
            60,
            200,
            100,
            0,
            xproto::WindowClass::INPUT_OUTPUT,
            0,
            &xproto::CreateWindowAux::new()
                .background_pixel(color)
                .event_mask(xproto::EventMask::STRUCTURE_NOTIFY),
        )
        .unwrap()
        .check()
        .unwrap();
        conn.change_property32(
            xproto::PropMode::REPLACE,
            window,
            pid,
            xproto::AtomEnum::CARDINAL,
            &[process],
        )
        .unwrap()
        .check()
        .unwrap();
        conn.change_property8(
            xproto::PropMode::REPLACE,
            window,
            xproto::AtomEnum::WM_CLASS,
            xproto::AtomEnum::STRING,
            b"fixture\0Fixture\0",
        )
        .unwrap()
        .check()
        .unwrap();
        conn.change_property32(
            xproto::PropMode::REPLACE,
            window,
            protocols,
            xproto::AtomEnum::ATOM,
            &[delete],
        )
        .unwrap()
        .check()
        .unwrap();
    }
    conn.map_window(target).unwrap().check().unwrap();
    conn.flush().unwrap();
    let mut desktop = Desktop::connect().unwrap();
    let app = desktop
        .applications()
        .unwrap()
        .into_iter()
        .find(|a| a["pid"] == std::process::id())
        .unwrap()["app"]
        .as_str()
        .unwrap()
        .to_owned();
    desktop.select(&app).unwrap();
    desktop.capture().unwrap();
    conn.clear_area(false, target, 0, 0, 0, 0)
        .unwrap()
        .check()
        .unwrap();
    conn.map_window(cover).unwrap().check().unwrap();
    conn.flush().unwrap();
    let image = desktop.capture().unwrap();
    let pixel = |x: usize, y: usize| {
        &image.pixels[(y * image.width + x) * 4..(y * image.width + x + 1) * 4]
    };
    assert_eq!(
        pixel(100, 100),
        &[0x22, 0x44, 0xcc, 255],
        "another application's covering pixels leaked into capture"
    );
    assert_eq!(pixel(0, 0), &[0, 0, 0, 255]);
    assert!(desktop.pointer_cover(100., 100.).unwrap().is_some());
    desktop.focus_window(target).unwrap();
    assert!(desktop.target_active());
    assert!(desktop.pointer_cover(100., 100.).unwrap().is_none());
    desktop.move_window(target, 90., 110.).unwrap();
    desktop.resize_window(target, 180, 140).unwrap();
    let windows = desktop.windows().unwrap();
    assert_eq!(windows.len(), 1);
    assert_eq!(
        windows[0].rect,
        protocol::Rect {
            x: 90.,
            y: 110.,
            w: 180.,
            h: 140.
        }
    );
    assert_eq!(
        desktop.canvas_point(target, 12., 13.).unwrap(),
        (102., 123.)
    );
    let message = wire::window_table(&windows);
    assert!(
        matches!(protocol::read_message(&mut &message[..]).unwrap().0, Incoming::Windows(w) if w[0].id == target)
    );
    assert!(
        desktop.close_window(cover).is_err(),
        "an app session must not close arbitrary windows"
    );
    desktop.close_window(target).unwrap();
    let end = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(Event::ClientMessage(e)) = conn.poll_for_event().unwrap() {
            if e.window == target {
                assert_eq!(e.data.as_data32()[0], delete);
                break;
            }
        }
        assert!(std::time::Instant::now() < end);
        std::thread::sleep(Duration::from_millis(5));
    }
    conn.destroy_window(cover).unwrap().check().unwrap();
    conn.destroy_window(target).unwrap().check().unwrap();
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
    let mut view = 1u32.to_le_bytes().to_vec();
    for f in [10f32, 20., 100., 80.] {
        view.extend(f.to_le_bytes());
    }
    a.write_all(&protocol::packet(41, view)).unwrap();
    let cropped = until(
        &mut a,
        |m| matches!(m, Incoming::Frame { region, .. } if region.x == 10. && region.y == 20.),
    );
    assert!(
        matches!(cropped, Incoming::Frame { region, flags, .. } if region.w == 100. && region.h == 80. && flags & 1 != 0)
    );
    a.write_all(&protocol::frame_ack(0)).unwrap();
    a.write_all(&protocol::packet(41, vec![0; 20])).unwrap();
    let full = until(
        &mut a,
        |m| matches!(m, Incoming::Frame { region, .. } if region.x == 0. && region.y == 0.),
    );
    assert!(
        matches!(full, Incoming::Frame { region, flags, .. } if region.w > 100. && region.h > 80. && flags & 1 != 0)
    );
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
    // A capture already in flight for A must not become B's decoder reference.
    let first = until(&mut b, |m| matches!(m, Incoming::Frame { .. }));
    assert!(matches!(first, Incoming::Frame { flags, .. } if flags & 1 != 0));
    b.write_all(&protocol::frame_ack(0)).unwrap();
    b.write_all(&protocol::stream(0, 5, 0.5, true, false))
        .unwrap();
    let changed = until(&mut b, |m| matches!(m, Incoming::Frame { mode: 0, .. }));
    assert!(matches!(changed, Incoming::Frame { flags, .. } if flags & 1 != 0));
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
    let display = desktop
        .displays()
        .into_iter()
        .find(|d| {
            pos.dst_x as i32 >= d.x
                && pos.dst_y as i32 >= d.y
                && (pos.dst_x as i32) < d.x + d.width as i32
                && (pos.dst_y as i32) < d.y + d.height as i32
        })
        .unwrap();
    let display = desktop.select(&format!("desktop:{}", display.id)).unwrap();
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

#[test]
#[ignore = "requires an isolated nested Hyprland compositor"]
fn isolated_hyprland_surface_capture_and_window_control() {
    use rapp_host_linux::desktop::Desktop;
    if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_none() {
        return;
    }
    assert_eq!(
        std::env::var("RAPP_TEST_ISOLATED_DESKTOP").as_deref(),
        Ok("1")
    );
    let fixture = |color: &str| {
        Worker(
            Command::new("python3")
                .args([
                    "-c",
                    r#"
import sys,gi
gi.require_version('Gtk','3.0')
from gi.repository import Gtk
w=Gtk.Window(title='Synthetic '+sys.argv[1]); w.set_default_size(240,160)
a=Gtk.DrawingArea(); w.add(a)
def draw(widget,ctx):
    ctx.set_source_rgb(*( (0.8,0.2,0.1) if sys.argv[1]=='red' else (0.1,0.2,0.9)))
    ctx.paint()
a.connect('draw',draw);w.connect('destroy',Gtk.main_quit);w.show_all();Gtk.main()
"#,
                    color,
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .spawn()
                .unwrap(),
        )
    };
    let mut red = fixture("red");
    let mut desktop = Desktop::connect().unwrap();
    assert!(desktop.application_capture_supported());
    let find_app = |desktop: &Desktop, pid: u32| {
        let until = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(app) = desktop
                .applications()
                .unwrap()
                .iter()
                .find(|a| a["pid"] == pid)
            {
                break app["app"].as_str().unwrap().to_owned();
            }
            assert!(std::time::Instant::now() < until, "fixture not enumerated");
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    let red_app = find_app(&desktop, red.0.id());
    let canvas = desktop.select(&red_app).unwrap();
    assert_eq!(desktop.lock_state().unwrap(), Some(false));
    let red_id = desktop.windows().unwrap()[0].id;
    desktop.move_window(red_id, 100., 100.).unwrap();
    desktop.resize_window(red_id, 240, 160).unwrap();
    std::thread::sleep(Duration::from_millis(150));
    let blue = fixture("blue");
    let blue_app = find_app(&desktop, blue.0.id());
    let mut cover = Desktop::connect().unwrap();
    cover.select(&blue_app).unwrap();
    let blue_id = cover.windows().unwrap()[0].id;
    cover.move_window(blue_id, 100., 100.).unwrap();
    cover.resize_window(blue_id, 240, 160).unwrap();
    cover.focus_window(blue_id).unwrap();
    std::thread::sleep(Duration::from_millis(200));
    let image = desktop.capture().unwrap();
    let red_pixels = image
        .pixels
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|p| p[2] > 150 && p[0] < 80)
        .count();
    let blue_pixels = image
        .pixels
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|p| p[0] > 150 && p[2] < 80)
        .count();
    assert!(
        red_pixels > 20000,
        "target surface pixels missing: {red_pixels}"
    );
    assert_eq!(
        blue_pixels, 0,
        "another application's pixels leaked into capture"
    );
    let window = desktop
        .windows()
        .unwrap()
        .into_iter()
        .find(|w| w.id == red_id)
        .unwrap();
    assert_eq!(
        (window.rect.x, window.rect.y, window.rect.w, window.rect.h),
        (100., 100., 240., 160.)
    );
    assert!(desktop.pointer_cover(150., 150.).unwrap().is_some());
    desktop.focus_window(red_id).unwrap();
    std::thread::sleep(Duration::from_millis(80));
    assert!(desktop.target_active());
    // The application canvas spans outputs; capture and absolute input must
    // still address the target after moving it to a second monitor.
    if desktop.displays().len() > 1 {
        desktop.move_window(red_id, 900., 100.).unwrap();
        std::thread::sleep(Duration::from_millis(100));
        let image = desktop.capture().unwrap();
        assert!(
            image
                .pixels
                .as_chunks::<4>()
                .0
                .iter()
                .filter(|p| p[2] > 150 && p[0] < 80)
                .count()
                > 20000
        );
        desktop.mouse(3, 0, 950., 150.).unwrap();
        std::thread::sleep(Duration::from_millis(50));
        let cursor = Command::new("hyprctl")
            .args(["-j", "cursorpos"])
            .output()
            .unwrap();
        let cursor: serde_json::Value = serde_json::from_slice(&cursor.stdout).unwrap();
        assert_eq!(
            (cursor["x"].as_i64(), cursor["y"].as_i64()),
            (Some(canvas.x as i64 + 950), Some(canvas.y as i64 + 150))
        );
    }
    desktop.close_window(red_id).unwrap();
    let until = std::time::Instant::now() + Duration::from_secs(3);
    while red.0.try_wait().unwrap().is_none() {
        assert!(
            std::time::Instant::now() < until,
            "close request not delivered"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        !cover.windows().unwrap().is_empty(),
        "closing target closed another app"
    );
}

#[test]
#[ignore = "requires an isolated X11 server"]
fn isolated_input_sources_follow_and_switch_xkb_groups() {
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        return;
    }
    assert_eq!(
        std::env::var("RAPP_TEST_ISOLATED_DESKTOP").as_deref(),
        Ok("1")
    );
    assert!(Command::new("setxkbmap")
        .args(["-layout", "us,ru"])
        .status()
        .unwrap()
        .success());
    let sources = rapp_host_linux::input_source::InputSources::start();
    let next = || {
        let end = std::time::Instant::now() + Duration::from_secs(4);
        loop {
            if let Some(source) = sources.next() {
                break source;
            }
            assert!(
                std::time::Instant::now() < end,
                "input source event missing"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    let source = next().unwrap();
    assert_eq!(source.id, "xkb:0");
    assert!(source.ascii);
    sources.select("xkb:1".into()).unwrap();
    let source = next().unwrap();
    assert_eq!(source.id, "xkb:1");
    assert!(!source.ascii);
    sources.select(String::new()).unwrap();
    let source = next().unwrap();
    assert_eq!(source.id, "xkb:0");
    assert!(source.ascii);
    sources.select("xkb:99".into()).unwrap();
    assert!(next().is_err());
    assert!(Command::new("setxkbmap")
        .args(["-layout", "us"])
        .status()
        .unwrap()
        .success());
}
