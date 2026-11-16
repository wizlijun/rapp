//! Full v12 host framing and a real rapp-session subprocess regression. A decode-only
//! focusRegion test missed the production header allowlist rejecting type 36.
use flate2::{Compress, Compression, FlushCompress};
use rapp_client_core::protocol::{read_message, Incoming};
use serde_json::{json, Value};
use std::{
    io::{BufReader, Cursor, Read, Write},
    net::{TcpListener, TcpStream},
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver},
    time::{Duration, Instant},
};

fn wire(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut bytes = vec![kind];
    bytes.extend((body.len() as u32).to_le_bytes());
    bytes.extend(body);
    bytes
}

fn text(value: &str) -> Vec<u8> {
    let mut bytes = (value.len() as u16).to_le_bytes().to_vec();
    bytes.extend(value.as_bytes());
    bytes
}

fn focus(count: u8) -> Vec<u8> {
    let mut body = 7u32.to_le_bytes().to_vec();
    body.push(count);
    for i in 0..count {
        for v in [f32::from(i), 0., 1., 1.] {
            body.extend(v.to_le_bytes());
        }
    }
    body
}

fn frame(z: &mut Compress, full: bool, color: u16) -> Vec<u8> {
    let mut body = vec![2]; // color16, 4 x 4 points and pixels
    for v in [0f32, 0., 4., 4.] {
        body.extend(v.to_le_bytes());
    }
    body.extend([4, 0, 4, 0, if full { 7 } else { 6 }]);
    if !full {
        body.extend([0; 8]);
    }
    let mut tile = vec![1, 0, 0, 0, 0]; // one solid tile, index 0
    tile.extend(color.to_le_bytes());
    let mut compressed = [0; 128];
    let start = z.total_out();
    z.compress(&tile, &mut compressed, FlushCompress::Sync)
        .unwrap();
    body.extend(&compressed[..(z.total_out() - start) as usize]);
    body
}

// Audited against Sources/RappCore/Protocol.swift: every main-connection host
// type, including v6 inputBlocked, v7 weak, v8 inputSource, v9 pong/saving,
// v11 screenLocked and v12 focusRegion. 24/25 belong to side connections.
fn host_messages() -> Vec<(u8, Vec<u8>)> {
    let ready = [text("Fixture"), vec![4, 0, 4, 0]].concat();
    let clip = [7u32.to_le_bytes().to_vec(), vec![4], text("unsupported")].concat();
    let pasted = [42u32.to_le_bytes().to_vec(), text("")].concat();
    let input = [text("com.apple.keylayout.ABC"), text("ABC"), vec![1]].concat();
    // v13: a cover over the press point, another app coming to the front, a password field.
    let covered = [9u32.to_le_bytes().to_vec(), text("提示"), text("com.apple.Notes"), vec![1]].concat();
    let opened = [text("com.apple.Safari"), text("Safari")].concat();
    vec![
        (2, ready),
        (3, text("host error")),
        (13, vec![0, 0]),
        (17, vec![0, 0]),
        (19, clip),
        (21, pasted),
        (26, text("Mac")),
        (28, vec![1]),
        (29, input),
        (32, 7u32.to_le_bytes().to_vec()),
        (33, vec![2]),
        (34, vec![1]),
        (36, focus(3)),
        (37, covered),
        (39, opened),
        (40, vec![1]),
        (
            4,
            frame(
                &mut Compress::new(Compression::default(), true),
                true,
                0xf800,
            ),
        ),
        (36, focus(0)),
    ]
}

fn kind(message: &Incoming) -> u8 {
    match message {
        Incoming::Ready(..) => 2,
        Incoming::Error(_) => 3,
        Incoming::Frame { .. } => 4,
        Incoming::Windows(_) => 13,
        Incoming::Menus(_) => 17,
        Incoming::Clipboard { .. } => 19,
        Incoming::Pasted { .. } => 21,
        Incoming::InputBlocked(_) => 26,
        Incoming::Weak(_) => 28,
        Incoming::InputSource { .. } => 29,
        Incoming::Pong(_) => 32,
        Incoming::Saving(_) => 33,
        Incoming::ScreenLocked(_) => 34,
        Incoming::FocusRegion { .. } => 36,
        Incoming::Covered { .. } => 37,
        Incoming::AppOpened { .. } => 39,
        Incoming::SecureFocus(_) => 40,
    }
}

#[test]
fn every_swift_host_type_survives_fragmented_and_buffered_framing() {
    struct OneByte(Cursor<Vec<u8>>);
    impl Read for OneByte {
        fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
            let n = out.len().min(1);
            self.0.read(&mut out[..n])
        }
    }
    let messages = host_messages();
    let bytes: Vec<_> = messages
        .iter()
        .flat_map(|(kind, body)| wire(*kind, body))
        .collect();
    let fragmented = OneByte(Cursor::new(bytes.clone()));
    // In particular focusRegion -> frame -> clear share one buffered stream.
    for mut reader in [
        Box::new(fragmented) as Box<dyn Read>,
        Box::new(BufReader::new(Cursor::new(bytes))),
    ] {
        for (expected, body) in &messages {
            let (message, consumed) = read_message(&mut reader).unwrap();
            assert_eq!(kind(&message), *expected);
            assert_eq!(consumed, body.len() + 5);
            if let Incoming::FocusRegion { window, rects } = message {
                assert_eq!(window, 7);
                assert_eq!(rects.len(), body[4] as usize);
            }
        }
        let mut tail = [0];
        assert_eq!(reader.read(&mut tail).unwrap(), 0);
    }
}

#[test]
fn framed_focus_validation_and_wrong_direction_rejection_remain_strict() {
    let mut truncated = wire(36, &focus(1));
    truncated.pop();
    assert!(read_message(&mut &truncated[..])
        .unwrap_err()
        .to_string()
        .contains("truncated host"));
    let mut extra = focus(0);
    extra.push(0);
    let mut nonfinite = focus(1);
    nonfinite[5..9].copy_from_slice(&f32::NAN.to_le_bytes());
    for invalid in [focus(4), focus(1)[..5].to_vec(), extra, nonfinite] {
        assert!(read_message(&mut &wire(36, &invalid)[..]).is_err());
    }
    // This includes client commands (e.g. ping 31 and unlock 35), transfer 24/25
    // and unknown future types. None may be silently skipped on the main stream.
    let allowed: Vec<_> = host_messages().into_iter().map(|(kind, _)| kind).collect();
    for rejected in (0..=255).filter(|kind| !allowed.contains(kind)) {
        let bytes = wire(rejected, &[]);
        let error = read_message(&mut &bytes[..]).unwrap_err().to_string();
        assert!(
            error.contains(&format!("unexpected host message type {rejected}")),
            "{error}"
        );
    }
}

struct Worker(Child);
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn next_output(output: &Receiver<Vec<u8>>, deadline: Instant) -> Vec<u8> {
    output
        .recv_timeout(deadline.saturating_duration_since(Instant::now()))
        .expect("worker output stalled or exited")
}

fn read_client(socket: &mut TcpStream, expected: u8) -> Vec<u8> {
    loop {
        let mut header = [0; 5];
        socket.read_exact(&mut header).unwrap();
        let length = u32::from_le_bytes(header[1..].try_into().unwrap()) as usize;
        assert!(length < 4096);
        let mut body = vec![0; length];
        socket.read_exact(&mut body).unwrap();
        if header[0] == expected {
            return body;
        }
        assert_eq!(header[0], 31, "unexpected client message");
        socket.write_all(&wire(32, &body)).unwrap();
    }
}

#[test]
fn real_worker_smart_stream_keeps_focus_events_frames_and_clear_then_rejects_unknown() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    listener.set_nonblocking(true).unwrap();
    // Reuse the same regression against the assembled/installed release worker.
    let executable = std::env::var_os("RAPP_TEST_SESSION_BIN")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_rapp-session").into());
    let mut worker = Worker(
        Command::new(executable)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
    );
    writeln!(
        worker.0.stdin.as_mut().unwrap(),
        "{}",
        json!({
            "port":listener.local_addr().unwrap().port(), "token":"fixture-only",
            "mode":"color16", "fps":15, "density":1,
        })
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut socket = loop {
        match listener.accept() {
            Ok((socket, _)) => break socket,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(e) => panic!("worker failed to connect: {e}"),
        }
    };
    // The listener polls, and on macOS (unlike Linux) an accepted socket inherits O_NONBLOCK, which
    // makes read_exact fail with WouldBlock at once instead of waiting for the read timeout below.
    socket.set_nonblocking(false).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    socket
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    assert_eq!(read_client(&mut socket, 1)[0], rapp_client_core::protocol::VERSION);
    let mut stdout = worker.0.stdout.take().unwrap();
    let (tx, output) = mpsc::channel();
    std::thread::spawn(move || {
        let mut header = [0; 4];
        while stdout.read_exact(&mut header).is_ok() {
            let length = u32::from_le_bytes(header) as usize;
            assert!((1..=1024 * 1024).contains(&length));
            let mut body = vec![0; length];
            if stdout.read_exact(&mut body).is_err() || tx.send(body).is_err() {
                break;
            }
        }
    });
    // Mirror selecting the UI's smart preset before A starts sending focus masks.
    writeln!(
        worker.0.stdin.as_mut().unwrap(),
        "{}",
        json!({
            "cmd":"set_stream", "mode":"color16", "fps":15, "density":1,
            "pinned":false, "focus":true,
        })
    )
    .unwrap();
    assert_eq!(read_client(&mut socket, 11).last(), Some(&2));
    let mut z = Compress::new(Compression::default(), true);
    let mut batch: Vec<_> = host_messages()
        .into_iter()
        .filter(|(kind, _)| ![3, 4, 36].contains(kind))
        .flat_map(|(kind, body)| wire(kind, &body))
        .collect();
    batch.extend(wire(36, &focus(3)));
    batch.extend(wire(4, &frame(&mut z, true, 0xf800)));
    socket.write_all(&batch).unwrap();
    let mut seen = Vec::new();
    for (rect_count, pixel) in [(3, [0, 0, 255, 255]), (0, [0, 255, 0, 255])] {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut saw_focus = false;
        loop {
            let packet = next_output(&output, deadline);
            if packet[0] == 1 {
                assert!(saw_focus, "frame overtook its focus event");
                assert_eq!(&packet[1..9], &[4, 0, 0, 0, 4, 0, 0, 0]);
                assert_eq!(&packet[25..], pixel.repeat(16));
                break;
            }
            assert_eq!(packet[0], 0);
            let event: Value = serde_json::from_slice(&packet[1..]).unwrap();
            assert_ne!(event["event"], "disconnected", "{event}");
            seen.push(event["event"].as_str().unwrap().to_owned());
            if event["event"] == "focus" {
                assert_eq!(event["window"], 7);
                assert_eq!(event["rects"].as_array().unwrap().len(), rect_count);
                saw_focus = true;
            }
        }
        assert_eq!(read_client(&mut socket, 27).len(), 2);
        if rect_count == 3 {
            // One write: clearing focus cannot swallow/misalign the following delta.
            socket
                .write_all(&[wire(36, &focus(0)), wire(4, &frame(&mut z, false, 0x07e0))].concat())
                .unwrap();
        }
    }
    for event in [
        "ready",
        "windows",
        "menu",
        "clip",
        "paste_result",
        "input_blocked",
        "weak",
        "input_source",
        "screen_locked",
    ] {
        assert!(
            seen.iter().any(|name| name == event),
            "missing {event}: {seen:?}"
        );
    }
    assert!(worker.0.try_wait().unwrap().is_none());
    // A type outside read_message's allow-list must take the connection down. 37 used to stand in for
    // "unknown future type" here; it is v13's covered now, so this picks a number far from the protocol.
    socket.write_all(&wire(200, &[])).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let packet = next_output(&output, deadline);
        let event: Value = serde_json::from_slice(&packet[1..]).unwrap();
        if event["event"] == "disconnected" {
            assert!(event["reason"]
                .as_str()
                .unwrap()
                .contains("unexpected host message type 200"));
            break;
        }
    }
}
