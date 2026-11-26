//! Desktop backends run only after an authenticated service has started this worker.
mod application;
pub(crate) mod hyprland;
mod hyprland_protocol;
pub mod keys;
mod omarchy_lock;
mod unlock;
mod wayland;
mod x11;

use anyhow::{bail, ensure, Result};
use rapp_client_core::protocol::{Rect, Window};
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
fn application_display(displays: &[Display]) -> Result<Display> {
    let mut canvas = displays
        .first()
        .ok_or_else(|| anyhow::anyhow!("no display"))?
        .clone();
    let x = displays.iter().map(|d| d.x).min().unwrap();
    let y = displays.iter().map(|d| d.y).min().unwrap();
    let right = displays
        .iter()
        .map(|d| d.x as i64 + d.width as i64)
        .max()
        .unwrap();
    let bottom = displays
        .iter()
        .map(|d| d.y as i64 + d.height as i64)
        .max()
        .unwrap();
    ensure!(
        right - x as i64 <= 65535 && bottom - y as i64 <= 65535,
        "desktop canvas exceeds protocol limits"
    );
    canvas.x = x;
    canvas.y = y;
    canvas.width = (right - x as i64) as u16;
    canvas.height = (bottom - y as i64) as u16;
    Ok(canvas)
}
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}
impl Image {
    /// Composite a surface onto the canvas without ever sampling other applications.
    pub fn place(&mut self, image: &Image, rect: Rect) {
        if rect.w <= 0. || rect.h <= 0. {
            return;
        }
        let x0 = rect.x.floor().max(0.) as usize;
        let y0 = rect.y.floor().max(0.) as usize;
        let x1 = (rect.x + rect.w).ceil().clamp(0., self.width as f32) as usize;
        let y1 = (rect.y + rect.h).ceil().clamp(0., self.height as f32) as usize;
        for y in y0..y1 {
            for x in x0..x1 {
                let sx = (((x as f32 - rect.x) / rect.w * image.width as f32) as usize)
                    .min(image.width - 1);
                let sy = (((y as f32 - rect.y) / rect.h * image.height as f32) as usize)
                    .min(image.height - 1);
                self.pixels[(y * self.width + x) * 4..(y * self.width + x + 1) * 4]
                    .copy_from_slice(
                        &image.pixels[(sy * image.width + sx) * 4..(sy * image.width + sx + 1) * 4],
                    );
            }
        }
    }
    /// Crop before downsampling, so a small remote view retains native detail.
    /// Round out to physical pixels and describe exactly those pixels on the canvas.
    pub fn cropped(self, display: &Display, view: Rect) -> (Self, Rect) {
        let sx = self.width as f32 / display.width as f32;
        let sy = self.height as f32 / display.height as f32;
        let x0 = (view.x * sx).floor().clamp(0., self.width as f32) as usize;
        let y0 = (view.y * sy).floor().clamp(0., self.height as f32) as usize;
        let x1 = ((view.x + view.w) * sx).ceil().clamp(0., self.width as f32) as usize;
        let y1 = ((view.y + view.h) * sy)
            .ceil()
            .clamp(0., self.height as f32) as usize;
        // Match macOS: a view outside the canvas falls back to the full region.
        if x1 <= x0 || y1 <= y0 {
            return (
                self,
                Rect {
                    x: 0.,
                    y: 0.,
                    w: display.width as f32,
                    h: display.height as f32,
                },
            );
        }
        let (width, height) = (x1 - x0, y1 - y0);
        let mut pixels = Vec::with_capacity(width * height * 4);
        for y in y0..y1 {
            pixels.extend_from_slice(
                &self.pixels[(y * self.width + x0) * 4..(y * self.width + x1) * 4],
            );
        }
        (
            Self {
                width,
                height,
                pixels,
            },
            Rect {
                x: x0 as f32 / sx,
                y: y0 as f32 / sy,
                w: width as f32 / sx,
                h: height as f32 / sy,
            },
        )
    }

    pub fn scaled_region(self, region: Rect, density: f32) -> Self {
        let (w, h) = dimensions(self.width, self.height, region.w, region.h, density);
        self.resized(w, h)
    }

    pub fn scaled(self, display: &Display, density: f32) -> Self {
        let (w, h) = scaled_dimensions(self.width, self.height, display, density);
        self.resized(w, h)
    }

    fn resized(self, w: usize, h: usize) -> Self {
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
// Bound both memory and the largest uncompressed v13 frame.
pub fn scaled_dimensions(w: usize, h: usize, display: &Display, density: f32) -> (usize, usize) {
    dimensions(w, h, display.width as f32, display.height as f32, density)
}
fn dimensions(w: usize, h: usize, logical_w: f32, logical_h: f32, density: f32) -> (usize, usize) {
    let factor = (logical_w * density / w as f32)
        .min(logical_h * density / h as f32)
        .min(4096. / w.max(h) as f32)
        .min(1.);
    (
        ((w as f32 * factor).round() as usize).max(1),
        ((h as f32 * factor).round() as usize).max(1),
    )
}
pub enum Desktop {
    Wayland(Box<wayland::Wayland>),
    X11(Box<x11::X11>),
}
pub struct Cover {
    pub id: u32,
    pub name: String,
    app: Option<application::Application>,
}
impl Cover {
    pub fn dismissable(&self) -> bool {
        self.app.is_some()
    }
    pub fn app_id(&self) -> String {
        self.app.as_ref().map(|a| a.id()).unwrap_or_default()
    }
}
impl Desktop {
    pub fn lock_state(&mut self) -> Result<Option<bool>> {
        match self {
            Self::Wayland(d) => d.lock_state(),
            Self::X11(_) => Ok(None),
        }
    }
    pub fn unlock(&mut self, password: &str) -> Result<()> {
        unlock::type_password(self, password)
    }
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
    pub fn application_capture_supported(&self) -> bool {
        match self {
            Self::Wayland(d) => d.application_capture_supported(),
            Self::X11(d) => d.application_capture_supported(),
        }
    }
    pub fn applications(&self) -> Result<Vec<Value>> {
        if !self.application_capture_supported() {
            return Ok(vec![]);
        }
        let windows = match self {
            Self::Wayland(d) => d.native_windows()?,
            Self::X11(d) => d.native_windows()?,
        };
        Ok(application::applications(&windows))
    }
    pub fn is_application(&self) -> bool {
        match self {
            Self::Wayland(d) => d.app.is_some(),
            Self::X11(d) => d.app.is_some(),
        }
    }
    pub fn windows(&self) -> Result<Vec<Window>> {
        if self.is_application() {
            let mut windows = match self {
                Self::Wayland(d) => d.application_windows()?,
                Self::X11(d) => d.application_windows()?,
            };
            // Retain the topmost windows when reaching the shared protocol limit.
            if windows.len() > 256 {
                windows.drain(..windows.len() - 256);
            }
            let ids: std::collections::HashSet<_> = windows.iter().map(|w| w.id).collect();
            for w in &mut windows {
                if !ids.contains(&w.parent) {
                    w.parent = 0;
                }
            }
            return Ok(windows);
        }
        let d = match self {
            Self::Wayland(d) => d.selected.as_ref(),
            Self::X11(d) => d.selected.as_ref(),
        }
        .ok_or_else(|| anyhow::anyhow!("no selected display"))?;
        Ok(vec![Window {
            id: 1,
            parent: 0,
            kind: 0,
            flags: 2,
            rect: Rect {
                x: 0.,
                y: 0.,
                w: d.width as f32,
                h: d.height as f32,
            },
            title_bar: 0.,
            title: format!("桌面 · {}", d.name),
        }])
    }
    pub fn focus_window(&mut self, id: u32) -> Result<()> {
        if !self.is_application() {
            return Ok(());
        }
        match self {
            Self::Wayland(d) => d.focus_window(id),
            Self::X11(d) => d.focus_window(id),
        }
    }
    pub fn close_window(&mut self, id: u32) -> Result<()> {
        if !self.is_application() {
            return Ok(());
        }
        match self {
            Self::Wayland(d) => d.close_window(id),
            Self::X11(d) => d.close_window(id),
        }
    }
    pub fn move_window(&mut self, id: u32, x: f32, y: f32) -> Result<()> {
        if !self.is_application() {
            return Ok(());
        }
        match self {
            Self::Wayland(d) => d.move_window(id, x, y),
            Self::X11(d) => d.move_window(id, x, y),
        }
    }
    pub fn resize_window(&mut self, id: u32, w: u16, h: u16) -> Result<()> {
        if !self.is_application() {
            return Ok(());
        }
        match self {
            Self::Wayland(d) => d.resize_window(id, w, h),
            Self::X11(d) => d.resize_window(id, w, h),
        }
    }
    pub fn target_active(&self) -> bool {
        !self.is_application()
            || self
                .windows()
                .is_ok_and(|windows| windows.iter().any(|w| w.flags & 2 != 0))
    }
    pub fn activate(&mut self) -> Result<()> {
        if self.target_active() {
            return Ok(());
        }
        let windows = self.windows()?;
        let id = windows
            .last()
            .ok_or_else(|| anyhow::anyhow!("application has no visible windows"))?
            .id;
        self.focus_window(id)?;
        for _ in 0..10 {
            if self.target_active() {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        bail!("target not frontmost")
    }
    pub fn canvas_point(&self, id: u32, x: f32, y: f32) -> Result<(f32, f32)> {
        let w = self
            .windows()?
            .into_iter()
            .find(|w| w.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown window"))?;
        Ok((
            w.rect.x + x.clamp(0., w.rect.w.max(1.) - 1.),
            w.rect.y + w.title_bar + y.clamp(0., (w.rect.h - w.title_bar).max(1.) - 1.),
        ))
    }
    pub fn view_region(&self, view: Option<(u32, Rect)>) -> Result<Option<Rect>> {
        let Some((id, mut rect)) = view else {
            return Ok(None);
        };
        let windows = self.windows()?;
        let Some(window) = windows.iter().find(|w| w.id == id) else {
            return Ok(None);
        };
        rect.x += window.rect.x;
        rect.y += window.rect.y + window.title_bar;
        for child in windows.iter().filter(|w| w.parent == id) {
            let right = (rect.x + rect.w).max(child.rect.x + child.rect.w);
            let bottom = (rect.y + rect.h).max(child.rect.y + child.rect.h);
            rect.x = rect.x.min(child.rect.x);
            rect.y = rect.y.min(child.rect.y);
            rect.w = right - rect.x;
            rect.h = bottom - rect.y;
        }
        Ok(Some(rect))
    }
    pub fn pointer_cover(&self, x: f32, y: f32) -> Result<Option<Cover>> {
        if !self.is_application() {
            return Ok(None);
        }
        let (windows, display, pid) = match self {
            Self::X11(d) => (
                d.native_windows()?,
                d.selected.as_ref().unwrap(),
                d.app.as_ref().unwrap().pid,
            ),
            Self::Wayland(d) => {
                let display = d.selected.as_ref().unwrap();
                return hyprland::pointer_cover(
                    x + display.x as f32,
                    y + display.y as f32,
                    d.app.as_ref().unwrap().pid,
                );
            }
        };
        let (x, y) = (x + display.x as f32, y + display.y as f32);
        let covering = windows.into_iter().rev().find(|w| {
            x >= w.window.rect.x
                && y >= w.window.rect.y
                && x < w.window.rect.x + w.window.rect.w
                && y < w.window.rect.y + w.window.rect.h
        });
        Ok(covering.filter(|w| w.pid != pid).map(|w| Cover {
            id: w.window.id,
            name: w.name,
            app: application::Application::current(w.pid)
                .ok()
                .filter(|app| app.dismissable()),
        }))
    }
    pub fn dismiss_cover(&self, cover: &Cover) -> Result<()> {
        let app = cover
            .app
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("this cover cannot be dismissed"))?;
        app.check()?;
        match self {
            Self::Wayland(_) => hyprland::dispatch(app, cover.id, "closewindow", None),
            Self::X11(d) => d.close_cover(cover.id, app.pid),
        }
    }
    pub fn opened_application(&self) -> Option<(String, String)> {
        let (windows, selected) = match self {
            Self::X11(d) => (d.native_windows().ok()?, d.app.as_ref()?),
            Self::Wayland(d) => (d.native_windows().ok()?, d.app.as_ref()?),
        };
        let window = windows.iter().find(|w| w.window.flags & 2 != 0)?;
        if window.pid == selected.pid || window.pid == std::process::id() {
            return None;
        }
        let app = application::Application::current(window.pid).ok()?;
        if !app.dismissable() {
            return None;
        }
        Some((app.id(), window.name.clone()))
    }
    pub fn focus_target(&self) -> Value {
        let Ok(windows) = (match self {
            Self::X11(d) => d.native_windows(),
            Self::Wayland(d) => d.native_windows(),
        }) else {
            return Value::Null;
        };
        let Some(window) = windows.iter().find(|w| w.window.flags & 2 != 0) else {
            return Value::Null;
        };
        let (app, display) = match self {
            Self::X11(d) => (d.app.as_ref(), d.selected.as_ref()),
            Self::Wayland(d) => (d.app.as_ref(), d.selected.as_ref()),
        };
        let Some(display) = display else {
            return Value::Null;
        };
        if app.is_some_and(|a| a.pid != window.pid) {
            return Value::Null;
        }
        let (id, x, y) = if app.is_some() {
            (window.window.id, 0., 0.)
        } else {
            (
                1,
                window.window.rect.x - display.x as f32,
                window.window.rect.y - display.y as f32,
            )
        };
        json!({"pid":window.pid,"window":id,"x":x,"y":y})
    }
    pub fn select(&mut self, app: &str) -> Result<Display> {
        self.select_for(app, true)
    }
    pub fn select_capture(&mut self, app: &str) -> Result<Display> {
        self.select_for(app, false)
    }
    fn select_for(&mut self, app: &str, input: bool) -> Result<Display> {
        if !app.starts_with("desktop:") {
            let app = application::Application::parse(app)?;
            return match self {
                Self::X11(b) => b.select_application(app),
                Self::Wayland(b) => b.select_application(app, input),
            };
        }
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
            Self::Wayland(b) if input => b.select(&d)?,
            Self::Wayland(b) => b.select_capture(&d),
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
    pub fn capture_scaled(&mut self, display: &Display, density: f32) -> Result<Image> {
        match self {
            Self::Wayland(d) => d.capture_scaled(density),
            Self::X11(d) => Ok(d.capture()?.scaled(display, density)),
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
    pub fn paste_modifiers(&self) -> u64 {
        let terminal = match self {
            Self::Wayland(_) => hyprland::active_window_is_terminal(),
            Self::X11(d) => d
                .native_windows()
                .ok()
                .and_then(|windows| windows.into_iter().find(|w| w.window.flags & 2 != 0))
                .is_some_and(|w| is_terminal_class(&w.name)),
        };
        if terminal {
            (1 << 20) | (1 << 17)
        } else {
            1 << 20
        }
    }
    pub fn release(&mut self) {
        match self {
            Self::Wayland(d) => d.release(),
            Self::X11(d) => d.release(),
        }
    }
}

pub(crate) fn is_terminal_class(class: &str) -> bool {
    let lower = class.trim().to_ascii_lowercase();
    if lower.is_empty() {
        return false;
    }
    matches!(
        lower.as_str(),
        "foot"
            | "footclient"
            | "org.codeberg.dnkl.foot"
            | "alacritty"
            | "kitty"
            | "ghostty"
            | "com.mitchellh.ghostty"
            | "wezterm"
            | "org.wezfurlong.wezterm"
            | "gnome-terminal"
            | "gnome-terminal-server"
            | "org.gnome.console"
            | "kgx"
            | "konsole"
            | "org.kde.konsole"
            | "xfce4-terminal"
            | "tilix"
            | "terminator"
            | "urxvt"
            | "rxvt"
            | "rxvt-unicode"
            | "xterm"
            | "uxterm"
            | "st"
            | "st-256color"
            | "rio"
            | "contour"
            | "blackbox"
            | "ptyxis"
            | "org.gnome.ptyxis"
            | "sakura"
            | "lxterminal"
            | "mate-terminal"
            | "qterminal"
            | "deepin-terminal"
            | "warp"
            | "dev.warp.warp"
            | "tabby"
            | "hyper"
    ) || lower.starts_with("org.omarchy.")
        || lower.starts_with("tui.")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn view_crops_native_pixels_before_density_scaling_and_clips_edges() {
        let display = Display {
            id: 1,
            name: "test".into(),
            x: 100,
            y: -100,
            width: 4,
            height: 3,
            main: true,
        };
        let image = || Image {
            width: 8,
            height: 6,
            pixels: (0..48).flat_map(|i| [i, i, i, 255]).collect(),
        };
        let (crop, region) = image().cropped(
            &display,
            Rect {
                x: 1.,
                y: 1.,
                w: 2.,
                h: 1.,
            },
        );
        assert_eq!(
            region,
            Rect {
                x: 1.,
                y: 1.,
                w: 2.,
                h: 1.
            }
        );
        assert_eq!((crop.width, crop.height), (4, 2));
        assert_eq!(crop.pixels[0], 18);
        let scaled = crop.scaled_region(region, 1.);
        assert_eq!((scaled.width, scaled.height), (2, 1));
        assert_eq!(scaled.pixels, [18, 18, 18, 255, 20, 20, 20, 255]);
        let (crop, region) = image().cropped(
            &display,
            Rect {
                x: -0.25,
                y: 2.25,
                w: 2.,
                h: 2.,
            },
        );
        assert_eq!(
            region,
            Rect {
                x: 0.,
                y: 2.,
                w: 2.,
                h: 1.
            }
        );
        assert_eq!((crop.width, crop.height), (4, 2));
        let (full, region) = image().cropped(
            &display,
            Rect {
                x: 20.,
                y: 20.,
                w: 1.,
                h: 1.,
            },
        );
        assert_eq!((full.width, full.height), (8, 6));
        assert_eq!(
            region,
            Rect {
                x: 0.,
                y: 0.,
                w: 4.,
                h: 3.
            }
        );
    }
}
