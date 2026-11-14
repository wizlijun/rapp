use anyhow::{bail, ensure, Context, Result};
use std::{collections::HashSet, io::Read};

pub const VERSION: u8 = 9;
pub const MAX_MESSAGE: usize = 64 * 1024 * 1024;
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}
#[derive(Clone, Debug)]
pub struct Window {
    pub id: u32,
    pub parent: u32,
    pub kind: u8,
    pub flags: u8,
    pub rect: Rect,
    pub title_bar: f32,
    pub title: String,
}
#[derive(Clone, Debug)]
pub struct Menu {
    pub title: String,
    pub flags: u8,
    pub key: String,
    pub modifiers: u8,
    pub children: Vec<Menu>,
}
#[derive(Debug)]
pub enum Incoming {
    Ready(String, u16, u16),
    Error(String),
    Frame {
        mode: u8,
        region: Rect,
        width: usize,
        height: usize,
        full: bool,
        data: Vec<u8>,
    },
    Windows(Vec<Window>),
    Menus(Vec<Menu>),
    Clipboard {
        id: u32,
        text: Option<String>,
        truncated: bool,
    },
    Pasted {
        seq: u32,
        error: String,
    },
    InputBlocked(String),
    /// v7, v8 hosts: saving on or off.
    Weak(bool),
    /// The answer to `ping` (v9).
    Pong(u32),
    /// A's traffic-saving level, 0 to 2 (v9).
    Saving(u8),
    /// A's selected input source (v8); `ascii`: a plain keyboard layout, not an input method.
    InputSource {
        id: String,
        name: String,
        ascii: bool,
    },
}
#[derive(Clone, Debug)]
pub struct Address {
    pub version: u8,
    pub host: String,
    pub port: u16,
    pub app: String,
    pub token: String,
    pub mode: u8,
    pub fps: u8,
}
impl Address {
    pub fn parse(s: &str, fallback: Option<String>) -> Result<Self> {
        let u = url::Url::parse(s).context("invalid rapp address")?;
        ensure!(u.scheme() == "rapp", "address must start with rapp://");
        let host = u
            .host_str()
            .context("address has no host")?
            .trim_matches(['[', ']'])
            .to_owned();
        let port = u.port().unwrap_or(47800);
        ensure!(port > 0, "port must be positive");
        let app = percent_encoding::percent_decode_str(u.path().trim_start_matches('/'))
            .decode_utf8()?
            .into_owned();
        ensure!(!app.contains('/'), "invalid app identifier");
        let mut token = fallback.unwrap_or_default();
        let mut mode = 0;
        let mut fps = 15;
        let mut version = VERSION;
        for (k, v) in u.query_pairs() {
            match k.as_ref() {
                "token" if !v.is_empty() => token = v.into_owned(),
                "mode" => mode = mode_number(&v).context("unknown color mode")?,
                "fps" => fps = v.parse().context("invalid fps")?,
                "protocol" => version = v.parse().context("invalid protocol")?,
                _ => (),
            }
        }
        ensure!(!token.is_empty(), "address has no token (use --token-env)");
        ensure!([1, 5, 15, 30].contains(&fps), "fps must be 1, 5, 15 or 30");
        ensure!(
            token.len() <= 65535 && app.len() <= 65535,
            "token or app identifier too long"
        );
        ensure!(
            (4..=9).contains(&version),
            "protocol must be 4 to 9"
        );
        Ok(Self {
            version,
            host,
            port,
            app,
            token,
            mode,
            fps,
        })
    }
    pub fn hello(&self, density: f32) -> Vec<u8> {
        let mut p = vec![self.version];
        string(&mut p, &self.token);
        string(&mut p, &self.app);
        p.extend([self.mode, self.fps]);
        p.extend(density.to_le_bytes());
        packet(1, p)
    }

    /// A reconnect address without credentials (the caller passes the token via env).
    pub fn connect_url(&self) -> String {
        let mut url = url::Url::parse("rapp://localhost").unwrap();
        let host = if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        url.set_host(Some(&host)).unwrap();
        url.set_port(Some(self.port)).unwrap();
        url.set_path(&self.app);
        url.query_pairs_mut()
            .append_pair("protocol", &self.version.to_string())
            .append_pair(
                "mode",
                ["gray4", "color8", "color16", "duogray", "duocolor"][self.mode as usize],
            )
            .append_pair("fps", &self.fps.to_string());
        url.to_string()
    }
}
pub fn mode_number(s: &str) -> Option<u8> {
    ["gray4", "color8", "color16", "duogray", "duocolor"]
        .iter()
        .position(|v| *v == s)
        .map(|i| i as u8)
}
pub fn packet(kind: u8, payload: Vec<u8>) -> Vec<u8> {
    let mut p = vec![kind];
    p.extend((payload.len() as u32).to_le_bytes());
    p.extend(payload);
    p
}
pub fn string(out: &mut Vec<u8>, s: &str) {
    out.extend((s.len() as u16).to_le_bytes());
    out.extend(s.as_bytes());
}
pub fn id_packet(kind: u8, id: u32) -> Vec<u8> {
    packet(kind, id.to_le_bytes().to_vec())
}
/// Select A's input source `id`; "" selects A's ASCII-capable layout (v8 hosts).
pub fn select_input(id: &str) -> Vec<u8> {
    let mut p = vec![];
    string(&mut p, id);
    packet(30, p)
}
pub fn key(code: u16, modifiers: u64, down: bool) -> Vec<u8> {
    let mut p = code.to_le_bytes().to_vec();
    p.extend(modifiers.to_le_bytes());
    p.push(down as u8);
    packet(6, p)
}
pub fn mouse(kind: u8, button: u8, id: u32, x: f32, y: f32, clicks: u8) -> Vec<u8> {
    let mut p = vec![kind, button];
    p.extend(id.to_le_bytes());
    p.extend(x.to_le_bytes());
    p.extend(y.to_le_bytes());
    p.push(clicks);
    packet(7, p)
}
pub fn scroll(id: u32, x: f32, y: f32, dx: f32, dy: f32) -> Vec<u8> {
    let mut p = id.to_le_bytes().to_vec();
    for f in [x, y, dx, dy] {
        p.extend(f.to_le_bytes());
    }
    packet(8, p)
}
/// Measures the whole path to A (v9): A answers `pong` with the same number.
pub fn ping(seq: u32) -> Vec<u8> {
    id_packet(31, seq)
}
pub fn frame_ack(processing_ms: u16) -> Vec<u8> {
    packet(27, processing_ms.to_le_bytes().to_vec())
}
pub fn stream(mode: u8, fps: u8, density: f32, pinned: Option<bool>) -> Vec<u8> {
    let mut p = vec![mode, fps];
    p.extend(density.to_le_bytes());
    if let Some(pinned) = pinned {
        p.push(pinned as u8);
    }
    packet(11, p)
}
pub fn menu_pick(path: &[u16]) -> Vec<u8> {
    let mut p = vec![path.len() as u8];
    for i in path {
        p.extend(i.to_le_bytes());
    }
    packet(18, p)
}

pub struct Reader<'a> {
    pub data: &'a [u8],
    pub pos: usize,
}
impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }
    pub fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        ensure!(n <= self.data.len() - self.pos, "truncated message");
        let out = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(out)
    }
    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    pub fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into()?))
    }
    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into()?))
    }
    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into()?))
    }
    pub fn f32(&mut self) -> Result<f32> {
        let v = f32::from_bits(self.u32()?);
        ensure!(v.is_finite(), "non-finite coordinate");
        Ok(v)
    }
    pub fn string(&mut self) -> Result<String> {
        let n = self.u16()? as usize;
        Ok(std::str::from_utf8(self.take(n)?)?.to_owned())
    }
    pub fn rect(&mut self) -> Result<Rect> {
        let r = Rect {
            x: self.f32()?,
            y: self.f32()?,
            w: self.f32()?,
            h: self.f32()?,
        };
        ensure!(
            r.w > 0. && r.h > 0. && (r.x + r.w).is_finite() && (r.y + r.h).is_finite(),
            "invalid rectangle"
        );
        Ok(r)
    }
    pub fn end(&self) -> Result<()> {
        ensure!(self.pos == self.data.len(), "unexpected trailing bytes");
        Ok(())
    }
    fn menus(&mut self, depth: usize, budget: &mut usize) -> Result<Vec<Menu>> {
        let n = self.u16()? as usize;
        ensure!(n == 0 || depth <= 6, "menu too deep");
        ensure!(n <= *budget, "too many menu items");
        *budget -= n;
        let mut items = Vec::with_capacity(n);
        for _ in 0..n {
            let title = self.string()?;
            let flags = self.u8()?;
            let key = self.string()?;
            let modifiers = self.u8()?;
            ensure!(
                flags & !7 == 0 && modifiers & !15 == 0,
                "invalid menu flags"
            );
            items.push(Menu {
                title,
                flags,
                key,
                modifiers,
                children: self.menus(depth + 1, budget)?,
            });
        }
        Ok(items)
    }
}
pub fn read_message(input: &mut impl Read) -> Result<(Incoming, usize)> {
    let mut h = [0; 5];
    input.read_exact(&mut h).context("host disconnected")?;
    ensure!(
        [2, 3, 4, 13, 17, 19, 21, 26, 28, 29, 32, 33].contains(&h[0]),
        "unexpected host message type {}",
        h[0]
    );
    let n = u32::from_le_bytes(h[1..].try_into()?) as usize;
    ensure!(n <= MAX_MESSAGE, "message too large");
    let mut p = vec![0; n];
    input.read_exact(&mut p).context("truncated host message")?;
    Ok((decode(h[0], &p)?, n + 5))
}
pub fn decode(kind: u8, p: &[u8]) -> Result<Incoming> {
    let mut r = Reader::new(p);
    let message = match kind {
        2 => {
            let name = r.string()?;
            let w = r.u16()?;
            let h = r.u16()?;
            ensure!(w > 0 && h > 0, "empty canvas");
            Incoming::Ready(name, w, h)
        }
        3 => Incoming::Error(r.string()?),
        4 => {
            let mode = r.u8()?;
            ensure!(mode <= 4, "unknown mode");
            let region = r.rect()?;
            let width = r.u16()? as usize;
            let height = r.u16()? as usize;
            let full = r.u8()?;
            ensure!(full <= 1, "invalid full-frame flag");
            let data = r.take(p.len() - r.pos)?.to_vec();
            Incoming::Frame {
                mode,
                region,
                width,
                height,
                full: full == 1,
                data,
            }
        }
        13 => {
            let n = r.u16()? as usize;
            ensure!(n <= 256, "too many windows");
            let mut items = Vec::with_capacity(n);
            let mut ids = HashSet::new();
            for _ in 0..n {
                let id = r.u32()?;
                let parent = r.u32()?;
                let kind = r.u8()?;
                let flags = r.u8()?;
                ensure!(id != 0 && ids.insert(id), "invalid or duplicate window id");
                ensure!(kind <= 6 && flags & !3 == 0, "invalid window kind/flags");
                let rect = r.rect()?;
                let title_bar = r.f32()?;
                let title = r.string()?;
                ensure!(
                    title_bar >= 0. && title_bar < rect.h && title.chars().count() <= 200,
                    "invalid window metadata"
                );
                items.push(Window {
                    id,
                    parent,
                    kind,
                    flags,
                    rect,
                    title_bar,
                    title,
                });
            }
            ensure!(
                items
                    .iter()
                    .all(|w| w.parent == 0 || (w.parent != w.id && ids.contains(&w.parent))),
                "invalid window parent"
            );
            Incoming::Windows(items)
        }
        17 => Incoming::Menus(r.menus(1, &mut 5000)?),
        19 => {
            let id = r.u32()?;
            let mut text = None;
            let mut truncated = false;
            match r.u8()? {
                0 => {
                    let flag = r.u8()?;
                    ensure!(flag <= 1, "invalid clip truncation flag");
                    truncated = flag == 1;
                    let n = r.u32()? as usize;
                    ensure!(n <= 1024 * 1024, "clipboard text too large");
                    text = Some(std::str::from_utf8(r.take(n)?)?.to_owned());
                }
                1 => {
                    r.u16()?;
                    r.u16()?;
                    r.u64()?;
                }
                2 => {
                    let n = r.u16()?;
                    ensure!(n <= 100, "too many clipboard files");
                    for _ in 0..n {
                        r.string()?;
                        r.u64()?;
                    }
                }
                3 => {
                    r.string()?;
                    r.u64()?;
                }
                4 => {
                    r.string()?;
                }
                _ => bail!("invalid clipboard kind"),
            }
            Incoming::Clipboard {
                id,
                text,
                truncated,
            }
        }
        21 => Incoming::Pasted {
            seq: r.u32()?,
            error: r.string()?,
        },
        26 => Incoming::InputBlocked(r.string()?),
        28 => {
            let v = r.u8()?;
            ensure!(v <= 1, "invalid weak flag");
            Incoming::Weak(v == 1)
        }
        29 => {
            let id = r.string()?;
            let name = r.string()?;
            let ascii = r.u8()?;
            ensure!(ascii <= 1, "invalid ascii flag");
            Incoming::InputSource {
                id,
                name,
                ascii: ascii == 1,
            }
        }
        32 => Incoming::Pong(r.u32()?),
        33 => {
            let v = r.u8()?;
            ensure!(v <= 2, "invalid saving level");
            Incoming::Saving(v)
        }
        _ => bail!("unknown host message type {kind}"),
    };
    r.end()?;
    Ok(message)
}

/// Human-facing multi-client notices, matching RappCore.WorkerCLI on macOS.
pub fn takeover_notice(reason: &str) -> Option<String> {
    let reason = reason.strip_prefix("host says: ").unwrap_or(reason);
    let by = if reason == "taken over" {
        ""
    } else {
        reason.strip_prefix("taken over by ")?
    };
    Some(if by.is_empty() {
        "这个窗口在另一台设备上打开了".into()
    } else {
        format!("这个窗口在 {by} 上打开了")
    })
}

pub fn input_blocked_notice(by: &str) -> String {
    if by.is_empty() {
        "远端正在被另一台设备操作".into()
    } else {
        format!("远端正在被 {by} 操作")
    }
}
