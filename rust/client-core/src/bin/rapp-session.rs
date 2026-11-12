//! Headless Linux session worker. stdin: JSON commands. stdout: length-prefixed
//! events (0 = JSON, 1 = BGRA frame with width/height and canvas rect). No GUI toolkit.
//! Pipe backpressure bounds decoded frames; EOF closes the remote socket.
use anyhow::{bail, ensure, Context, Result};
use rapp_client_core::{
    codec::Decoder,
    protocol::{self as p, Incoming, Menu},
};
use serde_json::{json, Value};
use std::{
    io::{BufRead, Read, Write},
    net::{Shutdown, TcpStream},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

type Output = Arc<Mutex<std::io::Stdout>>;
fn output(out: &Output, kind: u8, bytes: &[u8]) -> Result<()> {
    let mut w = out.lock().unwrap();
    w.write_all(&((bytes.len() + 1) as u32).to_le_bytes())?;
    w.write_all(&[kind])?;
    w.write_all(bytes)?;
    w.flush()?;
    Ok(())
}
fn event(out: &Output, value: Value) -> Result<()> {
    output(out, 0, &serde_json::to_vec(&value)?)
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
            p::stream(mode, fps as u8, float(v, "density")?.clamp(0.1, 8.))
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
    let mut writer = socket.try_clone()?;
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
                writer.write_all(&command(&serde_json::from_str(&line)?)?)?;
                Ok(())
            })();
            if result.is_err() {
                break;
            }
        }
        let _ = writer.shutdown(Shutdown::Both);
    });
    let bytes = Arc::new(AtomicU64::new(0));
    let rate = bytes.clone();
    let traffic = out.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(1));
        if event(
            &traffic,
            json!({"event":"traffic","bytes":rate.swap(0,Ordering::Relaxed)}),
        )
        .is_err()
        {
            break;
        }
    });
    let mut decoder = Decoder::default();
    let mut ready = false;
    socket.set_read_timeout(Some(Duration::from_secs(15)))?;
    loop {
        let (message, size) = p::read_message(&mut socket)?;
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
                full,
                data,
            } => {
                let pixels = decoder.decode(mode, width, height, full, &data)?;
                let mut frame = Vec::with_capacity(24 + pixels.len());
                frame.extend((width as u32).to_le_bytes());
                frame.extend((height as u32).to_le_bytes());
                for f in [region.x, region.y, region.w, region.h] {
                    frame.extend(f.to_le_bytes());
                }
                frame.extend(pixels);
                output(out, 1, &frame)?;
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
            Incoming::Pasted { error } => {
                event(out, json!({"event":"paste_result","error":error}))?
            }
        }
    }
}
fn main() {
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let reason = match run(&out) {
        Ok(()) => "closed".into(),
        Err(e) => format!("{e:#}"),
    };
    let _ = event(&out, json!({"event":"closed","reason":reason}));
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
    }
    #[test]
    fn malformed_commands_do_not_wrap_integer_fields() {
        for v in [
            json!({"cmd":"key","keyCode":65536,"modifiers":0}),
            json!({"cmd":"select_window","window":-1}),
            json!({"cmd":"menu_pick","path":[65536]}),
            json!({"cmd":"set_stream","mode":"color16","fps":256,"density":1.}),
            json!({"cmd":"mouse","kind":"invalid"}),
        ] {
            assert!(command(&v).is_err());
        }
    }
}
