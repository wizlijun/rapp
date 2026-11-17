use super::{keys, Display, Image};
use anyhow::{ensure, Context, Result};
use std::collections::BTreeSet;
use x11rb::{
    connection::Connection,
    protocol::{
        randr::ConnectionExt as _,
        xfixes::ConnectionExt as _,
        xproto::{self, ConnectionExt as _},
        xtest::ConnectionExt as _,
    },
    rust_connection::RustConnection,
};

pub struct X11 {
    conn: RustConnection,
    root: u32,
    masks: [u32; 3],
    cursor: bool,
    pub displays: Vec<Display>,
    pub selected: Option<Display>,
    held: BTreeSet<u8>,
    buttons: BTreeSet<u8>,
    scroll: (f32, f32),
}
impl X11 {
    pub fn connect() -> Result<Self> {
        let (conn, screen) = x11rb::connect(None).context("cannot connect to the X11 desktop")?;
        conn.xtest_get_version(2, 2)?
            .reply()
            .context("X11 server does not provide XTEST input")?;
        let s = &conn.setup().roots[screen];
        let root = s.root;
        let visual = s
            .allowed_depths
            .iter()
            .flat_map(|d| &d.visuals)
            .find(|v| v.visual_id == s.root_visual)
            .context("unknown X11 root visual")?;
        ensure!(
            visual.class == xproto::VisualClass::TRUE_COLOR,
            "X11 desktop must use TrueColor"
        );
        let masks = [visual.blue_mask, visual.green_mask, visual.red_mask];
        let mut displays = vec![];
        if let Ok(cookie) = conn.randr_get_monitors(root, true) {
            if let Ok(monitors) = cookie.reply() {
                for m in monitors.monitors {
                    if m.width == 0 || m.height == 0 {
                        continue;
                    }
                    let name = String::from_utf8_lossy(&conn.get_atom_name(m.name)?.reply()?.name)
                        .into_owned();
                    displays.push(Display {
                        id: m.name,
                        name,
                        x: m.x as i32,
                        y: m.y as i32,
                        width: m.width,
                        height: m.height,
                        main: m.primary,
                    });
                }
            }
        }
        if displays.is_empty() {
            displays.push(Display {
                id: root,
                name: "X11 desktop".into(),
                x: 0,
                y: 0,
                width: s.width_in_pixels,
                height: s.height_in_pixels,
                main: true,
            });
        }
        if !displays.iter().any(|d| d.main) {
            displays[0].main = true;
        }
        let cursor = conn
            .xfixes_query_version(4, 0)
            .ok()
            .is_some_and(|r| r.reply().is_ok());
        Ok(Self {
            conn,
            root,
            masks,
            cursor,
            displays,
            selected: None,
            held: BTreeSet::new(),
            buttons: BTreeSet::new(),
            scroll: (0., 0.),
        })
    }
    pub fn capture(&mut self) -> Result<Image> {
        let d = self.selected.as_ref().context("no selected display")?;
        if d.id != self.root {
            let monitors = self.conn.randr_get_monitors(self.root, true)?.reply()?;
            ensure!(
                monitors.monitors.iter().any(|m| m.name == d.id
                    && m.width == d.width
                    && m.height == d.height
                    && m.x as i32 == d.x
                    && m.y as i32 == d.y),
                "display geometry changed; reconnect to refresh the desktop"
            );
        }
        let (w, h) = (d.width as usize, d.height as usize);
        ensure!(w <= 8192 && h <= 8192, "X11 output exceeds capture limit");
        let image = self
            .conn
            .get_image(
                xproto::ImageFormat::Z_PIXMAP,
                self.root,
                d.x as i16,
                d.y as i16,
                d.width,
                d.height,
                u32::MAX,
            )?
            .reply()
            .context("X11 capture failed (display may have disconnected)")?;
        let fmt = self
            .conn
            .setup()
            .pixmap_formats
            .iter()
            .find(|f| f.depth == image.depth)
            .context("unknown X11 pixel format")?;
        let bpp = fmt.bits_per_pixel as usize;
        ensure!([16, 24, 32].contains(&bpp), "unsupported X11 pixel depth");
        let pad = fmt.scanline_pad as usize;
        let stride = (w * bpp).div_ceil(pad) * pad / 8;
        ensure!(image.data.len() >= stride * h, "truncated X11 image");
        let little = self.conn.setup().image_byte_order == xproto::ImageOrder::LSB_FIRST;
        let mut pixels = vec![255; w * h * 4];
        for y in 0..h {
            for x in 0..w {
                let bytes = &image.data[y * stride + x * bpp / 8..y * stride + (x + 1) * bpp / 8];
                let mut v = 0u32;
                if little {
                    for (i, b) in bytes.iter().enumerate() {
                        v |= (*b as u32) << (8 * i);
                    }
                } else {
                    for b in bytes {
                        v = (v << 8) | *b as u32;
                    }
                }
                for (i, mask) in self.masks.iter().enumerate() {
                    ensure!(*mask != 0, "invalid X11 color mask");
                    let shift = mask.trailing_zeros();
                    pixels[(y * w + x) * 4 + i] =
                        (((v & mask) >> shift) as u64 * 255 / (mask >> shift) as u64) as u8;
                }
            }
        }
        if let Some(cursor) = self
            .cursor
            .then(|| {
                self.conn
                    .xfixes_get_cursor_image()
                    .ok()
                    .and_then(|c| c.reply().ok())
            })
            .flatten()
        {
            let left = cursor.x as i32 - cursor.xhot as i32 - d.x;
            let top = cursor.y as i32 - cursor.yhot as i32 - d.y;
            for cy in 0..cursor.height as usize {
                for cx in 0..cursor.width as usize {
                    let (x, y) = (left + cx as i32, top + cy as i32);
                    if x < 0 || y < 0 || x >= w as i32 || y >= h as i32 {
                        continue;
                    }
                    let c = cursor.cursor_image[cy * cursor.width as usize + cx];
                    let alpha = c >> 24;
                    let dest = &mut pixels[(y as usize * w + x as usize) * 4..][..4];
                    for (i, channel) in dest[..3].iter_mut().enumerate() {
                        *channel = (((c >> (8 * i)) & 255) + *channel as u32 * (255 - alpha) / 255)
                            .min(255) as u8;
                    }
                }
            }
        }
        Ok(Image {
            width: w,
            height: h,
            pixels,
        })
    }
    fn key_event(&mut self, key: u8, down: bool) -> Result<()> {
        self.conn
            .xtest_fake_input(
                if down {
                    xproto::KEY_PRESS_EVENT
                } else {
                    xproto::KEY_RELEASE_EVENT
                },
                key,
                0,
                self.root,
                0,
                0,
                0,
            )?
            .check()?;
        if down {
            self.held.insert(key);
        } else {
            self.held.remove(&key);
        }
        Ok(())
    }
    pub fn key(&mut self, code: u16, flags: u64, down: bool) -> Result<()> {
        let Some(k) = keys::evdev(code) else {
            return Ok(());
        };
        for (flag, evdev) in keys::MODIFIERS {
            let key = (evdev + 8) as u8;
            let want = flags & flag != 0;
            if self.held.contains(&key) != want {
                self.key_event(key, want)?;
            }
        }
        self.key_event((k + 8) as u8, down)?;
        // The wire carries event flags, not physical modifier lifetimes.
        for (_, evdev) in keys::MODIFIERS {
            let key = (evdev + 8) as u8;
            if self.held.contains(&key) {
                self.key_event(key, false)?;
            }
        }
        self.conn.flush()?;
        Ok(())
    }
    pub fn mouse(&mut self, kind: u8, button: u8, x: f32, y: f32) -> Result<()> {
        let d = self.selected.as_ref().context("no display")?;
        let (x, y) = (
            d.x + x.clamp(0., d.width.saturating_sub(1) as f32) as i32,
            d.y + y.clamp(0., d.height.saturating_sub(1) as f32) as i32,
        );
        self.conn
            .xtest_fake_input(
                xproto::MOTION_NOTIFY_EVENT,
                0,
                0,
                self.root,
                x as i16,
                y as i16,
                0,
            )?
            .check()?;
        if kind <= 1 {
            let b = if button == 0 { 1 } else { 3 };
            self.conn
                .xtest_fake_input(
                    if kind == 0 {
                        xproto::BUTTON_PRESS_EVENT
                    } else {
                        xproto::BUTTON_RELEASE_EVENT
                    },
                    b,
                    0,
                    self.root,
                    0,
                    0,
                    0,
                )?
                .check()?;
            if kind == 0 {
                self.buttons.insert(b);
            } else {
                self.buttons.remove(&b);
            }
        }
        self.conn.flush()?;
        Ok(())
    }
    pub fn scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32) -> Result<()> {
        self.mouse(3, 0, x, y)?;
        self.scroll.0 += dx.clamp(-1000., 1000.);
        self.scroll.1 += dy.clamp(-1000., 1000.);
        for (delta, positive, negative) in [(&mut self.scroll.0, 6, 7), (&mut self.scroll.1, 4, 5)]
        {
            let steps = (*delta / 15.).trunc() as i32;
            *delta -= steps as f32 * 15.;
            for _ in 0..steps.unsigned_abs() {
                for kind in [xproto::BUTTON_PRESS_EVENT, xproto::BUTTON_RELEASE_EVENT] {
                    self.conn
                        .xtest_fake_input(
                            kind,
                            if steps > 0 { positive } else { negative },
                            0,
                            self.root,
                            0,
                            0,
                            0,
                        )?
                        .check()?;
                }
            }
        }
        self.conn.flush()?;
        Ok(())
    }
    pub fn text(&mut self, text: &str) -> Result<()> {
        self.release();
        crate::server::command(
            "xdotool",
            &["type", "--clearmodifiers", "--delay", "0", "--file", "-"],
            Some(text.as_bytes()),
        )
        .context("X11 text input requires xdotool")?;
        Ok(())
    }
    pub fn release(&mut self) {
        for key in std::mem::take(&mut self.held) {
            let _ =
                self.conn
                    .xtest_fake_input(xproto::KEY_RELEASE_EVENT, key, 0, self.root, 0, 0, 0);
        }
        for b in std::mem::take(&mut self.buttons) {
            let _ =
                self.conn
                    .xtest_fake_input(xproto::BUTTON_RELEASE_EVENT, b, 0, self.root, 0, 0, 0);
        }
        self.scroll = (0., 0.);
        let _ = self.conn.flush();
    }
}
