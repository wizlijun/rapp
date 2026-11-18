use anyhow::{bail, ensure, Result};
use rapp_client_core::protocol::{packet, string, Reader, VERSION};

pub const MAX_INPUT: usize = 1024 * 1024;
#[derive(Debug, Clone, Copy)]
pub struct Settings {
    pub mode: u8,
    pub fps: u8,
    pub density: f32,
}
fn settings(r: &mut Reader<'_>) -> Result<Settings> {
    let s = Settings {
        mode: r.u8()?,
        fps: r.u8()?,
        density: r.f32()?,
    };
    ensure!(
        s.mode <= 4 && [1, 5, 15, 30].contains(&s.fps) && s.density > 0. && s.density <= 8.,
        "invalid stream settings"
    );
    Ok(s)
}
pub fn hello(p: &[u8], token: &str, app: &str) -> Result<Settings> {
    let mut r = Reader::new(p);
    ensure!(
        r.u8()? == VERSION,
        "protocol version mismatch (update both sides)"
    );
    let supplied = r.string()?;
    ensure!(
        supplied.len() == token.len()
            && supplied
                .bytes()
                .zip(token.bytes())
                .fold(0u8, |a, (b, c)| a | (b ^ c))
                == 0,
        "invalid token"
    );
    // Embedded clients leave this empty: the authenticated service tunnel
    // already selects the worker's desktop. Match the macOS host contract.
    let requested = r.string()?;
    ensure!(requested.is_empty() || requested == app, "wrong desktop");
    let s = settings(&mut r)?;
    r.end()?;
    Ok(s)
}
#[derive(Debug)]
pub enum Input {
    Key(u16, u64, bool),
    Mouse(u8, u8, f32, f32),
    Scroll(f32, f32, f32, f32),
    Text(String),
    Paste(u32, Option<String>),
    Stream(Settings),
    Ack,
    Ping(u32),
    Unlock,
    Ignore,
}
pub fn input(kind: u8, p: &[u8]) -> Result<Input> {
    let mut r = Reader::new(p);
    let value = match kind {
        5 => {
            ensure!(p.len() <= 65535, "text too large");
            return Ok(Input::Text(std::str::from_utf8(p)?.into()));
        }
        6 => {
            let (k, m, d) = (r.u16()?, r.u64()?, r.u8()?);
            ensure!(d <= 1, "invalid key state");
            Input::Key(k, m, d == 1)
        }
        7 => {
            let (k, b, id, x, y, _) = (r.u8()?, r.u8()?, r.u32()?, r.f32()?, r.f32()?, r.u8()?);
            ensure!(k <= 3 && b <= 1 && id == 1, "invalid mouse event");
            Input::Mouse(k, b, x, y)
        }
        8 => {
            ensure!(r.u32()? == 1, "invalid window");
            Input::Scroll(r.f32()?, r.f32()?, r.f32()?, r.f32()?)
        }
        11 => {
            let s = settings(&mut r)?;
            ensure!(r.u8()? & !3 == 0, "invalid stream flags");
            Input::Stream(s)
        }
        20 => {
            let seq = r.u32()?;
            let text = match r.u8()? {
                0 => Some(r.string()?),
                1 => {
                    r.u32()?;
                    None
                }
                _ => bail!("invalid paste source"),
            };
            Input::Paste(seq, text)
        }
        27 => {
            r.u16()?;
            Input::Ack
        }
        31 => Input::Ping(r.u32()?),
        35 => {
            ensure!(r.string()?.len() <= 1024, "password too long");
            Input::Unlock
        }
        // Desktop geometry is owned by the compositor. Never act on app-only operations.
        9 => {
            r.u32()?;
            r.u16()?;
            r.u16()?;
            Input::Ignore
        }
        14 | 15 | 38 => {
            r.u32()?;
            Input::Ignore
        }
        16 => {
            r.u32()?;
            r.f32()?;
            r.f32()?;
            Input::Ignore
        }
        18 => {
            let n = r.u8()?;
            ensure!(n <= 8, "invalid menu path");
            for _ in 0..n {
                r.u16()?;
            }
            Input::Ignore
        }
        30 => {
            r.string()?;
            Input::Ignore
        }
        _ => bail!("unexpected client message type {kind}"),
    };
    r.end()?;
    Ok(value)
}
pub fn text_packet(kind: u8, s: &str) -> Vec<u8> {
    let mut p = vec![];
    string(&mut p, s);
    packet(kind, p)
}
pub fn pasted(seq: u32, error: &str) -> Vec<u8> {
    let mut p = seq.to_le_bytes().to_vec();
    string(&mut p, error);
    packet(21, p)
}
pub fn ready(name: &str, w: u16, h: u16) -> Vec<u8> {
    let mut p = vec![];
    string(&mut p, name);
    p.extend(w.to_le_bytes());
    p.extend(h.to_le_bytes());
    packet(2, p)
}
pub fn windows(name: &str, w: u16, h: u16) -> Vec<u8> {
    let mut p = 1u16.to_le_bytes().to_vec();
    p.extend(1u32.to_le_bytes());
    p.extend(0u32.to_le_bytes());
    p.extend([0, 2]);
    for f in [0., 0., w as f32, h as f32, 0.] {
        p.extend(f.to_le_bytes());
    }
    string(&mut p, name);
    packet(13, p)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_untrusted_input_before_backend_calls() {
        assert!(input(7, &[0; 15]).is_err()); // nonexistent window
        let mut p = vec![2, 30];
        p.extend(f32::NAN.to_le_bytes());
        p.push(0);
        assert!(input(11, &p).is_err());
        assert!(input(6, &[0; 10]).is_err());
        assert!(input(27, &[0, 0, 1]).is_err());
        assert!(input(22, &[]).is_err());
    }
    #[test]
    fn authentication_binds_version_token_and_desktop() {
        let mut p = vec![VERSION];
        string(&mut p, "secret");
        string(&mut p, "desktop:");
        p.extend([2, 15]);
        p.extend(1f32.to_le_bytes());
        assert!(hello(&p, "secret", "desktop:").is_ok());
        assert!(hello(&p, "wrong!", "desktop:").is_err());
        assert!(hello(&p, "secret", "desktop:2").is_err());
        p[0] -= 1;
        assert!(hello(&p, "secret", "desktop:").is_err());
    }

    #[test]
    fn embedded_hello_uses_the_bound_desktop_without_an_app_id() {
        // Both the Swift SessionPlugin and Rust rapp-session connect through a
        // service-bound tunnel and leave the hello's app field empty.
        let address = rapp_client_core::protocol::Address::parse(
            "rapp://127.0.0.1:47800/?mode=color16&fps=15",
            Some("secret".into()),
        )
        .unwrap();
        let packet = address.hello(1.);
        let payload = &packet[5..];
        for bound in ["desktop:", "desktop:2"] {
            assert!(hello(payload, "secret", bound).is_ok());
            assert!(hello(payload, "wrong!", bound).is_err());
        }
        let mut old = payload.to_vec();
        old[0] -= 1;
        assert!(hello(&old, "secret", "desktop:").is_err());
        let mut trailing = payload.to_vec();
        trailing.push(0);
        assert!(hello(&trailing, "secret", "desktop:").is_err());
    }
}
