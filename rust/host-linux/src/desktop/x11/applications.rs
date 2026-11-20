use super::super::application::{Application, NativeWindow};
use super::*;
use rapp_client_core::protocol::{Rect, Window};
use x11rb::protocol::composite::{ConnectionExt as _, Redirect};

impl X11 {
    fn atom(&self, name: &str) -> Result<u32> {
        Ok(self.conn.intern_atom(false, name.as_bytes())?.reply()?.atom)
    }
    fn words(&self, window: u32, name: &str) -> Result<Vec<u32>> {
        let value = self
            .conn
            .get_property(
                false,
                window,
                self.atom(name)?,
                xproto::AtomEnum::ANY,
                0,
                4096,
            )?
            .reply()?;
        Ok(value.value32().map(|v| v.collect()).unwrap_or_default())
    }
    fn title(&self, window: u32, name: &str) -> Result<String> {
        let value = self
            .conn
            .get_property(
                false,
                window,
                self.atom(name)?,
                xproto::AtomEnum::ANY,
                0,
                4096,
            )?
            .reply()?;
        Ok(String::from_utf8_lossy(&value.value)
            .trim_end_matches('\0')
            .chars()
            .take(200)
            .collect())
    }
    pub fn application_capture_supported(&self) -> bool {
        self.conn
            .composite_query_version(0, 4)
            .ok()
            .and_then(|c| c.reply().ok())
            .is_some_and(|r| r.major_version > 0 || r.minor_version >= 2)
    }
    pub fn native_windows(&self) -> Result<Vec<NativeWindow>> {
        let ids = self.words(self.root, "_NET_CLIENT_LIST_STACKING")?;
        let ids = if ids.is_empty() {
            self.conn.query_tree(self.root)?.reply()?.children
        } else {
            let mut ids = ids;
            for id in self.conn.query_tree(self.root)?.reply()?.children {
                if !ids.contains(&id)
                    && self
                        .conn
                        .get_window_attributes(id)?
                        .reply()
                        .is_ok_and(|a| a.override_redirect)
                {
                    ids.push(id);
                }
            }
            ids
        };
        let focus = self
            .words(self.root, "_NET_ACTIVE_WINDOW")?
            .first()
            .copied()
            .unwrap_or_else(|| {
                self.conn
                    .get_input_focus()
                    .ok()
                    .and_then(|c| c.reply().ok())
                    .map(|r| r.focus)
                    .unwrap_or(0)
            });
        let mut windows = vec![];
        for id in ids.into_iter().take(1024) {
            let entry = (|| -> Result<NativeWindow> {
                let attrs = self.conn.get_window_attributes(id)?.reply()?;
                ensure!(
                    attrs.map_state == xproto::MapState::VIEWABLE
                        && attrs.class == xproto::WindowClass::INPUT_OUTPUT,
                    "not visible"
                );
                let geometry = self.conn.get_geometry(id)?.reply()?;
                let origin = self
                    .conn
                    .translate_coordinates(id, self.root, 0, 0)?
                    .reply()?;
                let pid = self.words(id, "_NET_WM_PID")?.first().copied().unwrap_or(0);
                let parent = self
                    .words(id, "WM_TRANSIENT_FOR")?
                    .first()
                    .copied()
                    .unwrap_or(0);
                let mut title = self.title(id, "_NET_WM_NAME")?;
                if title.is_empty() {
                    title = self.title(id, "WM_NAME")?;
                }
                let class = self.title(id, "WM_CLASS")?;
                let name = class
                    .split('\0')
                    .next_back()
                    .filter(|s| !s.is_empty())
                    .unwrap_or(&title)
                    .to_owned();
                Ok(NativeWindow {
                    pid,
                    name,
                    native_id: id as u64,
                    window: Window {
                        id,
                        parent,
                        kind: if parent == 0 { 0 } else { 1 },
                        flags: 1 | if focus == id { 2 } else { 0 },
                        rect: Rect {
                            x: origin.dst_x as f32,
                            y: origin.dst_y as f32,
                            w: geometry.width as f32,
                            h: geometry.height as f32,
                        },
                        title_bar: 0.,
                        title,
                    },
                })
            })();
            if let Ok(entry) = entry {
                windows.push(entry);
            }
        }
        // Override-redirect/transient popups may inherit their process from a parent.
        for _ in 0..2 {
            let pids: std::collections::HashMap<_, _> =
                windows.iter().map(|w| (w.window.id, w.pid)).collect();
            for w in &mut windows {
                if w.pid == 0 {
                    w.pid = pids.get(&w.window.parent).copied().unwrap_or(0);
                }
            }
        }
        Ok(windows)
    }
    pub fn application_windows(&self) -> Result<Vec<Window>> {
        let app = self.app.as_ref().context("no application selected")?;
        app.check()?;
        let d = self.selected.as_ref().context("no selected display")?;
        let mut windows: Vec<_> = self
            .native_windows()?
            .into_iter()
            .filter(|w| w.pid == app.pid)
            .map(|w| w.window)
            .collect();
        let ids: BTreeSet<_> = windows.iter().map(|w| w.id).collect();
        for w in &mut windows {
            w.rect.x -= d.x as f32;
            w.rect.y -= d.y as f32;
            if !ids.contains(&w.parent) {
                w.parent = 0;
            }
        }
        Ok(windows)
    }
    pub fn select_application(&mut self, app: Application) -> Result<Display> {
        ensure!(
            self.application_capture_supported(),
            "X11 compositor does not support isolated window capture"
        );
        let windows = self.native_windows()?;
        ensure!(
            windows.iter().any(|w| w.pid == app.pid),
            "application has no visible windows"
        );
        let d = super::super::application_display(&self.displays)?;
        self.app = Some(app);
        self.selected = Some(d.clone());
        Ok(d)
    }
    fn application_window(&self, id: u32) -> Result<Window> {
        self.application_windows()?
            .into_iter()
            .find(|w| w.id == id)
            .context("window does not belong to this application")
    }
    pub fn focus_window(&self, id: u32) -> Result<()> {
        self.application_window(id)?;
        self.send_wm(id, "_NET_ACTIVE_WINDOW", [2, 0, 0, 0, 0])?;
        // Xvfb and minimal X11 desktops may not run an EWMH window manager.
        if self
            .words(self.root, "_NET_SUPPORTING_WM_CHECK")?
            .is_empty()
        {
            self.conn
                .configure_window(
                    id,
                    &xproto::ConfigureWindowAux::new().stack_mode(xproto::StackMode::ABOVE),
                )?
                .check()?;
            self.conn
                .set_input_focus(xproto::InputFocus::PARENT, id, 0u32)?
                .check()?;
        }
        self.conn.flush()?;
        Ok(())
    }
    fn send_wm(&self, id: u32, name: &str, data: [u32; 5]) -> Result<()> {
        let event = xproto::ClientMessageEvent::new(32, id, self.atom(name)?, data);
        self.conn
            .send_event(
                false,
                self.root,
                xproto::EventMask::SUBSTRUCTURE_REDIRECT | xproto::EventMask::SUBSTRUCTURE_NOTIFY,
                event,
            )?
            .check()?;
        self.conn.flush()?;
        Ok(())
    }
    pub fn resize_window(&self, id: u32, width: u16, height: u16) -> Result<()> {
        self.application_window(id)?;
        ensure!(width > 0 && height > 0, "invalid window size");
        if self
            .words(self.root, "_NET_SUPPORTING_WM_CHECK")?
            .is_empty()
        {
            self.conn
                .configure_window(
                    id,
                    &xproto::ConfigureWindowAux::new()
                        .width(width as u32)
                        .height(height as u32),
                )?
                .check()?;
        } else {
            self.send_wm(
                id,
                "_NET_MOVERESIZE_WINDOW",
                [
                    10 | (1 << 10) | (1 << 11) | (2 << 12),
                    0,
                    0,
                    width as u32,
                    height as u32,
                ],
            )?;
        }
        self.conn.flush()?;
        Ok(())
    }
    pub fn move_window(&self, id: u32, x: f32, y: f32) -> Result<()> {
        self.application_window(id)?;
        let d = self.selected.as_ref().unwrap();
        let (x, y) = (
            (x + d.x as f32).round() as i32,
            (y + d.y as f32).round() as i32,
        );
        if self
            .words(self.root, "_NET_SUPPORTING_WM_CHECK")?
            .is_empty()
        {
            self.conn
                .configure_window(id, &xproto::ConfigureWindowAux::new().x(x).y(y))?
                .check()?;
        } else {
            self.send_wm(
                id,
                "_NET_MOVERESIZE_WINDOW",
                [
                    10 | (1 << 8) | (1 << 9) | (2 << 12),
                    x as u32,
                    y as u32,
                    0,
                    0,
                ],
            )?;
        }
        self.conn.flush()?;
        Ok(())
    }
    pub fn close_window(&self, id: u32) -> Result<()> {
        self.application_window(id)?;
        self.close_protocol(id)
    }
    pub fn close_cover(&self, id: u32, pid: u32) -> Result<()> {
        ensure!(
            self.native_windows()?
                .iter()
                .any(|w| w.window.id == id && w.pid == pid),
            "cover changed"
        );
        self.close_protocol(id)
    }
    fn close_protocol(&self, id: u32) -> Result<()> {
        let delete = self.atom("WM_DELETE_WINDOW")?;
        ensure!(
            self.words(id, "WM_PROTOCOLS")?.contains(&delete),
            "application does not support closing windows"
        );
        let event = xproto::ClientMessageEvent::new(
            32,
            id,
            self.atom("WM_PROTOCOLS")?,
            [delete, 0, 0, 0, 0],
        );
        self.conn
            .send_event(false, id, xproto::EventMask::NO_EVENT, event)?
            .check()?;
        self.conn.flush()?;
        Ok(())
    }
    pub fn capture_application(&mut self) -> Result<Image> {
        let windows = self.application_windows()?;
        let d = self.selected.as_ref().unwrap().clone();
        ensure!(
            d.width <= 8192 && d.height <= 8192,
            "application canvas exceeds capture limit"
        );
        let mut canvas = Image {
            width: d.width as usize,
            height: d.height as usize,
            pixels: vec![0; d.width as usize * d.height as usize * 4],
        };
        for pixel in canvas.pixels.as_chunks_mut::<4>().0 {
            pixel[3] = 255;
        }
        for window in windows {
            if self.redirected.insert(window.id) {
                if let Err(e) = self
                    .conn
                    .composite_redirect_window(window.id, Redirect::AUTOMATIC)?
                    .check()
                {
                    self.redirected.remove(&window.id);
                    return Err(e.into());
                }
            }
            let pixmap = self.conn.generate_id()?;
            self.conn
                .composite_name_window_pixmap(window.id, pixmap)?
                .check()?;
            let result = (|| -> Result<Image> {
                let g = self.conn.get_geometry(pixmap)?.reply()?;
                ensure!(
                    g.width <= 8192 && g.height <= 8192,
                    "application window exceeds capture limit"
                );
                let image = self
                    .conn
                    .get_image(
                        xproto::ImageFormat::Z_PIXMAP,
                        pixmap,
                        0,
                        0,
                        g.width,
                        g.height,
                        u32::MAX,
                    )?
                    .reply()?;
                let format = self
                    .conn
                    .setup()
                    .pixmap_formats
                    .iter()
                    .find(|f| f.depth == image.depth)
                    .context("unknown pixel format")?;
                ensure!(
                    format.bits_per_pixel == 32
                        && self.conn.setup().image_byte_order == xproto::ImageOrder::LSB_FIRST,
                    "unsupported application pixel format"
                );
                ensure!(
                    image.data.len() == g.width as usize * g.height as usize * 4,
                    "invalid application image"
                );
                let mut pixels = image.data;
                for p in pixels.as_chunks_mut::<4>().0 {
                    p[3] = 255;
                }
                Ok(Image {
                    width: g.width as usize,
                    height: g.height as usize,
                    pixels,
                })
            })();
            self.conn.free_pixmap(pixmap)?.check()?;
            let image = result?;
            canvas.place(&image, window.rect);
        }
        Ok(canvas)
    }
}
