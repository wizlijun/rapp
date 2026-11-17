//! Desktop backends run only after an authenticated service has started this worker.
pub mod keys;
mod wayland;
mod x11;

use anyhow::{bail, ensure, Result};
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub struct Display {
    pub id: u32,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: u16,
    pub height: u16,
    pub main: bool,
}
impl Display {
    pub fn json(&self) -> Value {
        json!({"id": self.id.to_string(), "name": self.name, "main": self.main, "width": self.width, "height": self.height})
    }
}
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}
impl Image {
    pub fn scaled(self, display: &Display, density: f32) -> Self {
        // Bound both memory and a worst-case uncompressible v13 message (<64 MiB).
        let factor = (display.width as f32 * density / self.width as f32)
            .min(display.height as f32 * density / self.height as f32)
            .min(4096. / self.width.max(self.height) as f32)
            .min(1.);
        let (w, h) = (
            ((self.width as f32 * factor).round() as usize).max(1),
            ((self.height as f32 * factor).round() as usize).max(1),
        );
        if (w, h) == (self.width, self.height) {
            return self;
        }
        let mut pixels = vec![0; w * h * 4];
        for y in 0..h {
            for x in 0..w {
                let src = ((y * self.height / h) * self.width + x * self.width / w) * 4;
                pixels[(y * w + x) * 4..(y * w + x + 1) * 4]
                    .copy_from_slice(&self.pixels[src..src + 4]);
            }
        }
        Self {
            width: w,
            height: h,
            pixels,
        }
    }
}
pub enum Desktop {
    Wayland(Box<wayland::Wayland>),
    X11(Box<x11::X11>),
}
impl Desktop {
    pub fn connect() -> Result<Self> {
        // Never fall back to XWayland: its root window is not the Wayland desktop.
        if std::env::var_os("WAYLAND_DISPLAY").is_some_and(|s| !s.is_empty()) {
            Ok(Self::Wayland(Box::new(wayland::Wayland::connect()?)))
        } else if std::env::var_os("DISPLAY").is_some_and(|s| !s.is_empty()) {
            Ok(Self::X11(Box::new(x11::X11::connect()?)))
        } else {
            bail!("no graphical desktop session is available");
        }
    }
    pub fn displays(&self) -> Vec<Display> {
        match self {
            Self::Wayland(d) => d.displays(),
            Self::X11(d) => d.displays.clone(),
        }
    }
    pub fn select(&mut self, app: &str) -> Result<Display> {
        let id = app
            .strip_prefix("desktop:")
            .ok_or_else(|| anyhow::anyhow!("Linux host supports desktop sessions only"))?;
        let displays = self.displays();
        let d = if id.is_empty() {
            displays.iter().find(|d| d.main)
        } else {
            let id: u32 = id.parse()?;
            displays.iter().find(|d| d.id == id)
        }
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("display is no longer available"))?;
        ensure!(d.width > 0 && d.height > 0, "invalid display dimensions");
        match self {
            Self::Wayland(b) => b.select(&d)?,
            Self::X11(b) => b.selected = Some(d.clone()),
        }
        Ok(d)
    }
    pub fn capture(&mut self) -> Result<Image> {
        match self {
            Self::Wayland(d) => d.capture(),
            Self::X11(d) => d.capture(),
        }
    }
    pub fn key(&mut self, code: u16, flags: u64, down: bool) -> Result<()> {
        match self {
            Self::Wayland(d) => d.key(code, flags, down),
            Self::X11(d) => d.key(code, flags, down),
        }
    }
    pub fn mouse(&mut self, kind: u8, button: u8, x: f32, y: f32) -> Result<()> {
        match self {
            Self::Wayland(d) => d.mouse(kind, button, x, y),
            Self::X11(d) => d.mouse(kind, button, x, y),
        }
    }
    pub fn scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32) -> Result<()> {
        match self {
            Self::Wayland(d) => d.scroll(x, y, dx, dy),
            Self::X11(d) => d.scroll(x, y, dx, dy),
        }
    }
    pub fn text(&mut self, text: &str) -> Result<()> {
        match self {
            Self::Wayland(d) => d.text(text),
            Self::X11(d) => d.text(text),
        }
    }
    pub fn release(&mut self) {
        match self {
            Self::Wayland(d) => d.release(),
            Self::X11(d) => d.release(),
        }
    }
}
