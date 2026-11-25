use anyhow::{bail, ensure, Result};
use rapp_client_core::protocol::{packet, string, Reader, Rect, Window, VERSION};

pub const MAX_INPUT: usize = 1024 * 1024;
pub fn token_matches(supplied: &str, token: &str) -> bool {
    supplied.len() == token.len()
        && supplied
            .bytes()
            .zip(token.bytes())
            .fold(0u8, |a, (b, c)| a | (b ^ c))
            == 0
}
#[derive(Debug, Clone, Copy)]
pub struct Settings {
    pub mode: u8,
    pub fps: u8,
    pub density: f32,
    pub focus: bool,
    pub pinned: bool,
}
/// `stream`: a `set_stream`, where fps 0 pauses the pictures (v15); a hello always starts them.
fn settings(r: &mut Reader<'_>, stream: bool) -> Result<Settings> {
    let s = Settings {
        mode: r.u8()?,
        fps: r.u8()?,
        density: r.f32()?,
        focus: false,
        pinned: false,
    };
    ensure!(
        s.mode <= 4
            && ([1, 5, 15, 30].contains(&s.fps) || stream && s.fps == 0)
            && s.density > 0.
            && s.density <= 8.,
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
    ensure!(token_matches(&supplied, token), "invalid token");
    // Embedded clients leave this empty: the authenticated service tunnel
    // already selects the worker's desktop. Match the macOS host contract.
    let requested = r.string()?;
    ensure!(requested.is_empty() || requested == app, "wrong desktop");
    let s = settings(&mut r, false)?;
    r.end()?;
    Ok(s)
}
#[derive(Debug)]
pub enum Paste {
    Text(String),
    Item(u32),
}
pub struct Password(zeroize::Zeroizing<String>);
impl Password {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl std::fmt::Debug for Password {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Password([redacted])")
    }
}
#[derive(Debug)]
pub enum Input {
    Key(u16, u64, bool),
    Mouse(u8, u8, u32, f32, f32),
    Scroll(u32, f32, f32, f32, f32),
    Text(String),
    Paste(u32, Paste),
    Stream(Settings),
    View(Option<(u32, Rect)>),
    Resize(u32, u16, u16),
    Close(u32),
    Focus(u32),
    Move(u32, f32, f32),
    Dismiss(u32),
    Menu(Vec<u16>),
    SelectInput(String),
    Ack(u16),
    Ping(u32),
    Unlock(Password),
    /// v16: a rules pack; this host does not evaluate rules, so the content is dropped.
    StateRules,
}
pub fn input(kind: u8, p: &[u8]) -> Result<Input> {
    let mut r = Reader::new(p);
    let value = match kind {
        5 => {
            ensure!(p.len() <= 65535, "text too large");
            return Ok(Input::Text(std::str::from_utf8(p)?.into()));
        }
        43 => {
            ensure!(p.len() <= 65536, "state rules too large");
            std::str::from_utf8(p)?;
            return Ok(Input::StateRules);
        }
        6 => {
            let (k, m, d) = (r.u16()?, r.u64()?, r.u8()?);
            ensure!(d <= 1, "invalid key state");
            Input::Key(k, m, d == 1)
        }
        7 => {
            let (k, b, id, x, y, _) = (r.u8()?, r.u8()?, r.u32()?, r.f32()?, r.f32()?, r.u8()?);
            ensure!(k <= 3 && b <= 1 && id != 0, "invalid mouse event");
            Input::Mouse(k, b, id, x, y)
        }
        8 => {
            let id = r.u32()?;
            ensure!(id != 0, "invalid window");
            Input::Scroll(id, r.f32()?, r.f32()?, r.f32()?, r.f32()?)
        }
        11 => {
            let mut s = settings(&mut r, true)?;
            let flags = r.u8()?;
            ensure!(flags & !3 == 0, "invalid stream flags");
            s.pinned = flags & 1 != 0;
            s.focus = flags & 2 != 0;
            Input::Stream(s)
        }
        20 => {
            let seq = r.u32()?;
            let text = match r.u8()? {
                0 => Paste::Text(r.string()?),
                1 => Paste::Item(r.u32()?),
                _ => bail!("invalid paste source"),
            };
            Input::Paste(seq, text)
        }
        27 => Input::Ack(r.u16()?),
        31 => Input::Ping(r.u32()?),
        35 => {
            let password = zeroize::Zeroizing::new(r.string()?);
            ensure!(
                password.len() <= 1024 && !password.chars().any(char::is_control),
                "invalid password input"
            );
            Input::Unlock(Password(password))
        }
        9 => Input::Resize(r.u32()?, r.u16()?, r.u16()?),
        14 => Input::Focus(r.u32()?),
        15 => Input::Close(r.u32()?),
        38 => Input::Dismiss(r.u32()?),
        16 => Input::Move(r.u32()?, r.f32()?, r.f32()?),
        18 => {
            let n = r.u8()?;
            ensure!(n <= 8, "invalid menu path");
            let mut path = vec![];
            for _ in 0..n {
                path.push(r.u16()?);
            }
            Input::Menu(path)
        }
        30 => {
            let id = r.string()?;
            ensure!(id.len() <= 1024, "input source id too long");
            Input::SelectInput(id)
        }
        41 => {
            let window = r.u32()?;
            let rect = Rect {
                x: r.f32()?,
                y: r.f32()?,
                w: r.f32()?,
                h: r.f32()?,
            };
            ensure!(
                window == 0 || (rect.w > 0. && rect.h > 0.),
                "invalid view dimensions"
            );
            Input::View((window != 0).then_some((window, rect)))
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
pub fn window_table(windows: &[Window]) -> Vec<u8> {
    let mut p = (windows.len() as u16).to_le_bytes().to_vec();
    for w in windows {
        p.extend(w.id.to_le_bytes());
        p.extend(w.parent.to_le_bytes());
        p.extend([w.kind, w.flags]);
        for f in [w.rect.x, w.rect.y, w.rect.w, w.rect.h, w.title_bar] {
            p.extend(f.to_le_bytes());
        }
        string(&mut p, &w.title);
    }
    packet(13, p)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn state_rules_are_accepted_and_checked() {
        assert!(matches!(input(43, b"{}"), Ok(Input::StateRules)));
        assert!(matches!(input(43, b""), Ok(Input::StateRules)));
        assert!(input(43, &[0xFF]).is_err());
        assert!(matches!(input(43, &vec![b' '; 65536]), Ok(Input::StateRules)));
        assert!(input(43, &vec![b' '; 65537]).is_err());
    }
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
    fn window_commands_keep_the_shared_protocol_meaning() {
        let p = 42u32.to_le_bytes();
        assert!(matches!(input(14, &p), Ok(Input::Focus(42))));
        assert!(matches!(input(15, &p), Ok(Input::Close(42))));
        assert!(matches!(input(38, &p), Ok(Input::Dismiss(42))));
    }
    #[test]
    fn unlock_password_is_redacted_and_cannot_inject_control_keys() {
        let mut bytes = vec![];
        string(&mut bytes, "synthetic-secret");
        let message = input(35, &bytes).unwrap();
        assert!(!format!("{message:?}").contains("synthetic-secret"));
        let mut bytes = vec![];
        string(&mut bytes, "password\ncommand");
        assert!(input(35, &bytes).is_err());
    }
    fn payload(window: u32, floats: &[f32]) -> Vec<u8> {
        let mut p = window.to_le_bytes().to_vec();
        for f in floats {
            p.extend(f.to_le_bytes());
        }
        p
    }
    #[test]
    fn set_view_preserves_region_and_can_be_cleared() {
        // v14 setView: window u32 + rect (x, y, w, h) f32; window 0 clears the view.
        let zoomed = payload(1, &[10., 20., 300., 200.]);
        assert!(matches!(
            input(41, &zoomed),
            Ok(Input::View(Some((
                1,
                Rect {
                    x: 10.,
                    y: 20.,
                    w: 300.,
                    h: 200.
                }
            ))))
        ));
        assert!(matches!(
            input(41, &payload(0, &[0.; 4])),
            Ok(Input::View(None))
        ));
        assert!(input(41, &zoomed[..19]).is_err());
        assert!(input(41, &payload(1, &[0., 0., 0., 1.])).is_err());
        assert!(input(41, &payload(1, &[f32::NAN, 0., 1., 1.])).is_err());
        assert!(matches!(
            input(41, &payload(2, &[0., 0., 1., 1.])),
            Ok(Input::View(Some((2, _))))
        ));
    }
    #[test]
    fn menus_and_input_sources_are_forwarded() {
        let mut menu = vec![2];
        menu.extend([0u8; 4]);
        let mut select = vec![];
        string(&mut select, "");
        assert!(matches!(input(30, &select), Ok(Input::SelectInput(id)) if id.is_empty()));
        assert!(matches!(input(18, &menu), Ok(Input::Menu(path)) if path == [0, 0]));
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
        // v15: a hello never starts paused.
        p[0] += 1;
        let fps = p.len() - 5;
        p[fps] = 0;
        assert!(hello(&p, "secret", "desktop:").is_err());
    }
    #[test]
    fn set_stream_fps_zero_pauses_and_other_rates_stay_strict() {
        let stream = |fps: u8| {
            let mut p = vec![2, fps];
            p.extend(1f32.to_le_bytes());
            p.push(0);
            input(11, &p)
        };
        assert!(matches!(stream(0), Ok(Input::Stream(s)) if s.fps == 0));
        assert!(matches!(stream(15), Ok(Input::Stream(s)) if s.fps == 15));
        assert!(stream(2).is_err());
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
