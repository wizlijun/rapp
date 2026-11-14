//! Headless Linux session worker. stdin: JSON commands. stdout: length-prefixed
//! events (0 = JSON, 1 = BGRA frame with width/height and canvas rect). No GUI toolkit.
//! Latest-frame output bounds display latency; EOF closes the remote socket.
mod session_output;
use anyhow::{bail, ensure, Context, Result};
use rapp_client_core::{
    codec::Decoder,
    protocol::{self as p, Incoming, Menu},
};
use serde_json::{json, Value};
use session_output::Output;
use std::{
    io::{BufRead, Read, Write},
    net::{Shutdown, TcpStream},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

fn event(out: &Output, value: Value) -> Result<()> {
    out.event(serde_json::to_vec(&value)?)
}
fn menus(items: &[Menu]) -> Vec<Value> {
    items
        .iter()
        .map(|m| {
            json!({"title":m.title,"enabled":m.flags&1!=0,"checked":m.flags&2!=0,
        "separator":m.flags&4!=0,"shortcut":m.key,"children":menus(&m.children)})
        })
        .collect()
}
fn number(v: &Value, key: &str) -> Result<u32> {
    v[key]
        .as_u64()
        .and_then(|n| u32::try_from(n).ok())
        .with_context(|| format!("invalid {key}"))
}
fn float(v: &Value, key: &str) -> Result<f32> {
    let f = v[key].as_f64().context("missing coordinate")? as f32;
    ensure!(f.is_finite(), "invalid coordinate");
    Ok(f)
}
fn command(v: &Value) -> Result<Vec<u8>> {
    let id = || number(v, "window");
    Ok(match v["cmd"].as_str().context("missing command")? {
        "key" => {
            let code = u16::try_from(number(v, "keyCode")?)?;
            let mods = v["modifiers"].as_u64().context("invalid modifiers")?;
            if let Some(down) = v["down"].as_bool() {
                p::key(code, mods, down)
            } else {
                [p::key(code, mods, true), p::key(code, mods, false)].concat()
            }
        }
        "mouse" => {
            let kind = match v["kind"].as_str() {
                Some("down") => 0,
                Some("up") => 1,
                Some("drag") => 2,
                Some("move") => 3,
                _ => bail!("invalid mouse kind"),
            };
            p::mouse(
                kind,
                u8::from(v["button"] == "right"),
                id()?,
                float(v, "x")?,
                float(v, "y")?,
                number(v, "clicks")?.clamp(1, 3) as u8,
            )
        }
        "scroll" => p::scroll(
            id()?,
            float(v, "x")?,
            float(v, "y")?,
            float(v, "dx")?,
            float(v, "dy")?,
        ),
        "select_window" => p::id_packet(14, id()?),
        "close_window" => p::id_packet(15, id()?),
        "select_input" => {
            let id = v["id"].as_str().context("missing id")?;
            ensure!(id.len() <= 1024, "input source id too long");
            p::select_input(id)
        }
        "resize" => {
            let mut b = id()?.to_le_bytes().to_vec();
            b.extend((number(v, "w")?.clamp(1, 65535) as u16).to_le_bytes());
            b.extend((number(v, "h")?.clamp(1, 65535) as u16).to_le_bytes());
            p::packet(9, b)
        }
        "move" => {
            let mut b = id()?.to_le_bytes().to_vec();
            b.extend(float(v, "x")?.to_le_bytes());
            b.extend(float(v, "y")?.to_le_bytes());
            p::packet(16, b)
        }
        "set_stream" => {
            let mode = p::mode_number(v["mode"].as_str().context("missing mode")?)
                .context("invalid mode")?;
            let fps = number(v, "fps")?;
            ensure!([1, 5, 15, 30].contains(&fps), "invalid fps");
            let pinned = v["pinned"].as_bool().unwrap_or(false);
            p::stream(mode, fps as u8, float(v, "density")?.clamp(0.1, 8.), Some(pinned))
        }
        "menu_pick" => {
            let path: Vec<u16> = v["path"]
                .as_array()
                .context("invalid menu path")?
                .iter()
                .map(|n| {
                    n.as_u64()
                        .and_then(|n| u16::try_from(n).ok())
                        .context("invalid menu index")
                })
                .collect::<Result<_>>()?;
            ensure!(path.len() <= 6, "menu path too deep");
            p::menu_pick(&path)
        }
        "text" => {
            let text = v["text"].as_str().context("missing text")?;
            ensure!(text.len() <= 1024 * 1024, "text too long");
            p::packet(5, text.as_bytes().to_vec())
        }
        "paste" => {
            let mut b = number(v, "seq")?.to_le_bytes().to_vec();
            if let Some(text) = v["text"].as_str() {
                ensure!(text.len() < 60_000, "paste text must be under 60000 bytes");
                b.push(0);
                p::string(&mut b, text);
            } else {
                b.push(1);
                b.extend(number(v, "item")?.to_le_bytes());
            }
            p::packet(20, b)
        }
        _ => bail!("unknown command"),
    })
}
fn run(out: &Output) -> Result<()> {
    let stdin = std::io::stdin();
    let mut input = stdin.lock();
    let mut line = String::new();
    input.by_ref().take(1024 * 1024).read_line(&mut line)?;
    let start: Value = serde_json::from_str(&line)?;
    let port = u16::try_from(number(&start, "port")?)?;
    let address = p::Address::parse(
        &format!(
            "rapp://127.0.0.1:{port}/?mode={}&fps={}",
            start["mode"].as_str().unwrap_or("color16"),
            number(&start, "fps")?
        ),
        Some(start["token"].as_str().context("missing token")?.into()),
    )?;
    let mut socket =
        TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_secs(8))?;
    socket.set_nodelay(true)?;
    socket.set_write_timeout(Some(Duration::from_secs(5)))?;
    socket.write_all(&address.hello(float(&start, "density")?.clamp(0.1, 8.)))?;
    let writer = Arc::new(Mutex::new(socket.try_clone()?));
    let stdin_writer = writer.clone();
    drop(input);
    std::thread::spawn(move || {
        let mut input = std::io::stdin().lock();
        loop {
            let mut line = String::new();
            match input.by_ref().take(2 * 1024 * 1024).read_line(&mut line) {
                Ok(n) if n > 0 && n < 2 * 1024 * 1024 => (),
                _ => break,
            }
            let result = (|| -> Result<()> {
                let packet = command(&serde_json::from_str(&line)?)?;
                // One whole packet per lock: acks from the read loop never interleave with it.
                stdin_writer.lock().unwrap().write_all(&packet)?;
                Ok(())
            })();
            if result.is_err() {
                break;
            }
        }
        let _ = stdin_writer.lock().unwrap().shutdown(Shutdown::Both);
    });
    let bytes = Arc::new(AtomicU64::new(0));
    let rate = bytes.clone();
    let frames = Arc::new(AtomicU64::new(0));
    let frame_rate = frames.clone();
    let traffic = out.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(1));
        if event(
            &traffic,
            json!({"event":"traffic","bytes":rate.swap(0,Ordering::Relaxed),"frames":frame_rate.swap(0,Ordering::Relaxed)}),
        )
        .is_err()
        {
            break;
        }
    });
    socket.set_read_timeout(Some(Duration::from_secs(15)))?;
    read_loop(&mut socket, &writer, out, &bytes, &frames)
}
fn read_loop(
    socket: &mut TcpStream,
    writer: &Mutex<TcpStream>,
    out: &Output,
    bytes: &AtomicU64,
    frames: &AtomicU64,
) -> Result<()> {
    let mut decoder = Decoder::default();
    let mut pixels = Vec::new();
    let mut ready = false;
    loop {
        let (message, size) = p::read_message(socket)?;
        let received = Instant::now();
        bytes.fetch_add(size as u64, Ordering::Relaxed);
        match message {
            Incoming::Error(reason) => bail!("{reason}"),
            Incoming::Ready(name, _, _) => {
                ensure!(!ready, "duplicate Ready");
                ready = true;
                socket.set_read_timeout(None)?;
                event(out, json!({"event":"ready","appName":name}))?;
            }
            _ if !ready => bail!("message before Ready"),
            Incoming::Frame {
                mode,
                region,
                width,
                height,
                flags,
                dx,
                dy,
                data,
            } => {
                let show = decoder.decode_into(mode, width, height, flags, dx, dy, &data, &mut pixels)?;
                let mut frame = Vec::with_capacity(24);
                frame.extend((width as u32).to_le_bytes());
                frame.extend((height as u32).to_le_bytes());
                for f in [region.x, region.y, region.w, region.h] {
                    frame.extend(f.to_le_bytes());
                }
                // Decoding continues while stdout is slow. Only expanded, complete
                // canvases may be replaced; compressed deltas must all be applied.
                if show {
                    out.frame(frame.try_into().unwrap(), &mut pixels)?;
                    frames.fetch_add(1, Ordering::Relaxed);
                }
                let ms = u16::try_from(received.elapsed().as_millis()).unwrap_or(u16::MAX);
                writer.lock().unwrap().write_all(&p::frame_ack(ms))?;
            }
            Incoming::Windows(windows) => {
                let kinds = [
                    "normal", "dialog", "floating", "sheet", "popover", "menu", "tooltip",
                ];
                event(
                    out,
                    json!({"event":"windows","windows":windows.iter().map(|w|json!({"id":w.id,"parent":w.parent,"kind":kinds[w.kind as usize],"title":w.title,"x":w.rect.x,"y":w.rect.y,"w":w.rect.w,"h":w.rect.h,"titleBar":w.title_bar,"resizable":w.flags&1!=0,"focused":w.flags&2!=0,"texture":null,"visible":[0,0,1,1]})).collect::<Vec<_>>()}),
                )?;
            }
            Incoming::Menus(items) => event(out, json!({"event":"menu","items":menus(&items)}))?,
            Incoming::Clipboard {
                id,
                text,
                truncated,
            } => event(
                out,
                json!({"event":"clip","id":id,"text":text,"truncated":truncated}),
            )?,
            Incoming::Pasted { seq, error } => {
                event(out, json!({"event":"paste_result","seq":seq,"error":error}))?
            }
            Incoming::InputBlocked(by) => event(out, json!({"event":"input_blocked","by":by}))?,
            Incoming::Weak(on) => event(out, json!({"event":"weak","on":on}))?,
            Incoming::InputSource { id, name, ascii } => event(
                out,
                json!({"event":"input_source","id":id,"name":name,"ascii":ascii}),
            )?,
        }
    }
}
fn main() {
    let (out, writer) = Output::spawn(std::io::stdout());
    let reason = match run(&out) {
        Ok(()) => "closed".into(),
        Err(e) => format!("{e:#}"),
    };
    let _ = event(&out, json!({"event":"disconnected","reason":reason}));
    out.finish();
    let _ = writer.join();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn input_packets_match_host_protocol() {
        assert_eq!(
            command(&json!({"cmd":"resize","window":7,"w":640,"h":480})).unwrap(),
            p::packet(
                9,
                [
                    7u32.to_le_bytes().to_vec(),
                    640u16.to_le_bytes().to_vec(),
                    480u16.to_le_bytes().to_vec()
                ]
                .concat()
            )
        );
        assert_eq!(
            command(&json!({"cmd":"key","keyCode":0,"modifiers":1048576,"down":false})).unwrap(),
            p::key(0, 1 << 20, false)
        );
        assert_eq!(
            command(&json!({"cmd":"text","text":"你好"})).unwrap(),
            p::packet(5, "你好".as_bytes().to_vec())
        );
        assert_eq!(command(&json!({"cmd":"mouse","window":2,"kind":"drag","button":"left","x":1.5,"y":3.,"clicks":1})).unwrap(),p::mouse(2,0,2,1.5,3.,1));
        assert_eq!(
            command(&json!({"cmd":"paste","seq":7,"text":"你好"})).unwrap(),
            p::packet(
                20,
                [
                    7u32.to_le_bytes().to_vec(),
                    vec![0, 6, 0],
                    "你好".as_bytes().to_vec()
                ]
                .concat()
            )
        );
        assert_eq!(
            command(&json!({"cmd":"close_window","window":7})).unwrap(),
            p::packet(15, 7u32.to_le_bytes().to_vec())
        );
        assert_eq!(
            command(&json!({"cmd":"select_input","id":""})).unwrap(),
            vec![30, 2, 0, 0, 0, 0, 0]
        );
        assert_eq!(
            command(&json!({"cmd":"select_input","id":"com.apple.keylayout.ABC"})).unwrap(),
            [
                vec![30, 25, 0, 0, 0, 23, 0],
                b"com.apple.keylayout.ABC".to_vec()
            ]
            .concat()
        );
        assert_eq!(
            command(&json!({"cmd":"paste","seq":8,"item":9})).unwrap(),
            p::packet(
                20,
                [
                    8u32.to_le_bytes().to_vec(),
                    vec![1],
                    9u32.to_le_bytes().to_vec()
                ]
                .concat()
            )
        );
    }
    #[test]
    fn malformed_commands_do_not_wrap_integer_fields() {
        for v in [
            json!({"cmd":"key","keyCode":65536,"modifiers":0}),
            json!({"cmd":"select_window","window":-1}),
            json!({"cmd":"menu_pick","path":[65536]}),
            json!({"cmd":"set_stream","mode":"color16","fps":256,"density":1.}),
            json!({"cmd":"mouse","kind":"invalid"}),
            json!({"cmd":"paste","seq":4294967296u64,"text":"x"}),
            json!({"cmd":"paste","seq":1,"text":"x".repeat(60000)}),
            json!({"cmd":"close_window","window":4294967296u64}),
            json!({"cmd":"close_window"}),
            json!({"cmd":"select_input"}),
            json!({"cmd":"select_input","id":3}),
            json!({"cmd":"select_input","id":"x".repeat(1025)}),
        ] {
            assert!(command(&v).is_err());
        }
    }
    #[test]
    fn set_stream_pinned() {
        let v = json!({"cmd":"set_stream","mode":"duogray","fps":1,"density":1.,"pinned":true});
        assert_eq!(command(&v).unwrap(), p::stream(3, 1, 1., Some(true)));
        let v = json!({"cmd":"set_stream","mode":"duogray","fps":1,"density":1.});
        assert_eq!(command(&v).unwrap(), p::stream(3, 1, 1., Some(false)));
    }
    #[derive(Clone, Default)]
    struct Sink(Arc<std::sync::Mutex<Vec<u8>>>);
    impl Write for Sink {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    fn tiny_frame(z: &mut flate2::Compress, full: bool, value: u8) -> Vec<u8> {
        // One 8x8 gray4 tile: count=1, index=0, kind 0 (solid), one sample byte.
        let body = [1, 0, 0, 0, 0, value];
        let mut data = Vec::with_capacity(64);
        z.compress_vec(&body, &mut data, flate2::FlushCompress::Sync).unwrap();
        let mut b = vec![0];
        for f in [0f32, 0., 8., 8.] {
            b.extend(f.to_le_bytes());
        }
        b.extend(8u16.to_le_bytes());
        b.extend(8u16.to_le_bytes());
        if full {
            b.push(0x07);
        } else {
            b.push(0x06);
            b.extend([0u8; 8]);
        }
        b.extend(data);
        p::packet(4, b)
    }
    fn session_with_host() -> (Sink, std::net::TcpStream, std::thread::JoinHandle<Result<()>>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (host, _) = listener.accept().unwrap();
        let writer = Arc::new(Mutex::new(socket.try_clone().unwrap()));
        let sink = Sink::default();
        let (out, _writer_thread) = Output::spawn(sink.clone());
        let thread = std::thread::spawn(move || {
            let (bytes, frames) = (AtomicU64::new(0), AtomicU64::new(0));
            socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            read_loop(&mut socket, &writer, &out, &bytes, &frames)
        });
        (sink, host, thread)
    }
    fn ready() -> Vec<u8> {
        let mut b = Vec::new();
        p::string(&mut b, "app");
        b.extend(8u16.to_le_bytes());
        b.extend(8u16.to_le_bytes());
        p::packet(2, b)
    }
    #[test]
    fn acks_each_frame_over_loopback() {
        let (sink, mut host, thread) = session_with_host();
        let mut z = flate2::Compress::new(flate2::Compression::fast(), true);
        host.write_all(&ready()).unwrap();
        host.write_all(&tiny_frame(&mut z, true, 1)).unwrap();
        host.write_all(&tiny_frame(&mut z, false, 2)).unwrap();
        host.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        for _ in 0..2 {
            let mut ack = [0; 7];
            host.read_exact(&mut ack).unwrap();
            assert_eq!(ack[..5], [27, 2, 0, 0, 0]);
        }
        host.write_all(&p::packet(28, vec![1])).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let needle = br#""event":"weak","on":true"#;
        while !sink.0.lock().unwrap().windows(needle.len()).any(|w| w == needle) {
            assert!(std::time::Instant::now() < deadline, "no weak event");
            std::thread::sleep(Duration::from_millis(10));
        }
        drop(host);
        assert!(thread.join().unwrap().is_err());
    }
}
