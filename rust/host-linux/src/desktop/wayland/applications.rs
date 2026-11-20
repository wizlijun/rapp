use super::super::{
    application::{Application, NativeWindow},
    hyprland,
};
use super::*;
use rapp_client_core::protocol::Window;

pub(super) enum Frame {
    Output(ZwlrScreencopyFrameV1),
    Toplevel(HyprlandToplevelExportFrameV1),
}
impl Frame {
    pub fn waits_buffer_done(&self) -> bool {
        match self {
            Self::Output(f) => f.version() >= 3,
            Self::Toplevel(_) => true,
        }
    }
    pub fn copy(&self, buffer: &wl_buffer::WlBuffer) {
        match self {
            Self::Output(f) => f.copy(buffer),
            Self::Toplevel(f) => f.copy(buffer, 1),
        }
    }
    pub fn destroy(&self) {
        match self {
            Self::Output(f) => f.destroy(),
            Self::Toplevel(f) => f.destroy(),
        }
    }
}
impl Wayland {
    pub fn application_capture_supported(&self) -> bool {
        self.state.export.is_some()
            && self.state.mapping.is_some()
            && self.state.toplevel_manager.is_some()
            && std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some()
    }
    pub fn native_windows(&self) -> Result<Vec<NativeWindow>> {
        ensure!(
            self.application_capture_supported(),
            "compositor does not expose isolated application capture and window mapping"
        );
        hyprland::windows()
    }
    pub fn application_windows(&self) -> Result<Vec<Window>> {
        let app = self.app.as_ref().context("no application selected")?;
        app.check()?;
        let d = self.selected.as_ref().context("no selected display")?;
        Ok(self
            .native_windows()?
            .into_iter()
            .filter(|w| w.pid == app.pid)
            .map(|w| {
                let mut w = w.window;
                w.rect.x -= d.x as f32;
                w.rect.y -= d.y as f32;
                w
            })
            .collect())
    }
    pub fn select_application(&mut self, app: Application, input: bool) -> Result<Display> {
        let windows = self.native_windows()?;
        ensure!(
            windows.iter().any(|w| w.pid == app.pid),
            "application has no visible windows"
        );
        let d = super::super::application_display(&self.displays())?;
        if input {
            self.select_input(&d, false)?;
        } else {
            self.select_capture(&d);
        }
        self.app = Some(app);
        Ok(d)
    }
    pub fn focus_window(&self, id: u32) -> Result<()> {
        hyprland::dispatch(
            self.app.as_ref().context("no application")?,
            id,
            "focuswindow",
            None,
        )
    }
    pub fn close_window(&self, id: u32) -> Result<()> {
        hyprland::dispatch(
            self.app.as_ref().context("no application")?,
            id,
            "closewindow",
            None,
        )
    }
    pub fn move_window(&self, id: u32, x: f32, y: f32) -> Result<()> {
        let d = self.selected.as_ref().context("no display")?;
        hyprland::dispatch(
            self.app.as_ref().context("no application")?,
            id,
            "movewindowpixel",
            Some((
                (x + d.x as f32).round() as i32,
                (y + d.y as f32).round() as i32,
            )),
        )
    }
    pub fn resize_window(&self, id: u32, w: u16, h: u16) -> Result<()> {
        ensure!(w > 0 && h > 0, "invalid window size");
        hyprland::dispatch(
            self.app.as_ref().context("no application")?,
            id,
            "resizewindowpixel",
            Some((w as i32, h as i32)),
        )
    }
    pub fn capture_application(&mut self) -> Result<Image> {
        self.sync()?;
        let app = self.app.as_ref().context("no application")?;
        app.check()?;
        let windows: Vec<_> = self
            .native_windows()?
            .into_iter()
            .filter(|w| w.pid == app.pid)
            .collect();
        let d = self.selected.as_ref().unwrap().clone();
        let density = self
            .displays()
            .iter()
            .filter_map(|d| {
                let output = self.state.outputs.get(&d.id)?;
                let width = if output.transform % 2 == 1 {
                    output.pixels.1
                } else {
                    output.pixels.0
                };
                Some(width as f32 / d.width as f32)
            })
            .fold(1.0f32, f32::max);
        let scale = density.min(8192. / d.width.max(d.height) as f32);
        let (w, h) = (
            (d.width as f32 * scale).round() as usize,
            (d.height as f32 * scale).round() as usize,
        );
        let mut canvas = Image {
            width: w,
            height: h,
            pixels: vec![0; w * h * 4],
        };
        for p in canvas.pixels.as_chunks_mut::<4>().0 {
            p[3] = 255;
        }
        let sx = w as f32 / d.width as f32;
        let sy = h as f32 / d.height as f32;
        for window in windows {
            let handle = self
                .state
                .toplevels
                .get(&window.native_id)
                .context("application window has no verified capture handle")?;
            self.state.format = None;
            self.state.buffer_done = false;
            self.state.ready = false;
            self.state.failed = false;
            self.state.inverted = false;
            let frame = Frame::Toplevel(
                self.state
                    .export
                    .as_ref()
                    .unwrap()
                    .capture_toplevel_with_wlr_toplevel_handle(1, handle, &self.queue.handle(), ()),
            );
            let result = self.read_frame(&frame, 0, None);
            frame.destroy();
            if result.is_err() {
                self.buffer = None;
                self.state.buffer_in_use = None;
            }
            let image = result?;
            let mut rect = window.window.rect;
            rect.x = (rect.x - d.x as f32) * sx;
            rect.y = (rect.y - d.y as f32) * sy;
            rect.w *= sx;
            rect.h *= sy;
            canvas.place(&image, rect);
        }
        self.conn.flush()?;
        Ok(canvas)
    }
}
impl Dispatch<ZwlrForeignToplevelManagerV1, ()> for State {
    fn event(
        s: &mut Self,
        _: &ZwlrForeignToplevelManagerV1,
        e: zwlr_foreign_toplevel_manager_v1::Event,
        _: &(),
        _: &Connection,
        q: &QueueHandle<Self>,
    ) {
        if let zwlr_foreign_toplevel_manager_v1::Event::Toplevel { toplevel } = e {
            if let Some(mapping) = &s.mapping {
                mapping.get_window_for_toplevel_wlr(&toplevel, q, toplevel.clone());
            }
        }
    }
    wayland_client::event_created_child!(State, ZwlrForeignToplevelManagerV1, [0 => (ZwlrForeignToplevelHandleV1, ())]);
}
impl Dispatch<ZwlrForeignToplevelHandleV1, ()> for State {
    fn event(
        s: &mut Self,
        handle: &ZwlrForeignToplevelHandleV1,
        e: zwlr_foreign_toplevel_handle_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if matches!(e, zwlr_foreign_toplevel_handle_v1::Event::Closed) {
            s.toplevels.retain(|_, h| h != handle);
            handle.destroy();
        }
    }
}
impl Dispatch<HyprlandToplevelWindowMappingHandleV1, ZwlrForeignToplevelHandleV1> for State {
    fn event(
        s: &mut Self,
        mapping: &HyprlandToplevelWindowMappingHandleV1,
        e: hyprland_toplevel_window_mapping_handle_v1::Event,
        handle: &ZwlrForeignToplevelHandleV1,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match e {
            hyprland_toplevel_window_mapping_handle_v1::Event::WindowAddress {
                address_hi,
                address,
            } => {
                s.toplevels
                    .insert((address_hi as u64) << 32 | address as u64, handle.clone());
                mapping.destroy();
            }
            hyprland_toplevel_window_mapping_handle_v1::Event::Failed => mapping.destroy(),
        }
    }
}
impl Dispatch<HyprlandToplevelExportFrameV1, ()> for State {
    fn event(
        s: &mut Self,
        _: &HyprlandToplevelExportFrameV1,
        e: hyprland_toplevel_export_frame_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match e {
            hyprland_toplevel_export_frame_v1::Event::BufferDone => s.buffer_done = true,
            hyprland_toplevel_export_frame_v1::Event::Buffer {
                format: WEnum::Value(format),
                width,
                height,
                stride,
            } => s.format = Some((format, width, height, stride)),
            hyprland_toplevel_export_frame_v1::Event::Buffer { .. } => s.failed = true,
            hyprland_toplevel_export_frame_v1::Event::Flags {
                flags: WEnum::Value(flags),
            } => s.inverted = flags.contains(hyprland_toplevel_export_frame_v1::Flags::YInvert),
            hyprland_toplevel_export_frame_v1::Event::Ready { .. } => s.ready = true,
            hyprland_toplevel_export_frame_v1::Event::Failed => s.failed = true,
            _ => {}
        }
    }
}
delegate_noop!(State: ignore HyprlandToplevelExportManagerV1);
delegate_noop!(State: ignore HyprlandToplevelMappingManagerV1);
