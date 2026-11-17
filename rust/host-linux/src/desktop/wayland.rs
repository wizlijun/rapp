use super::{keys, Display, Image};
use anyhow::{ensure, Context, Result};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    os::fd::{AsFd, AsRawFd},
    time::{Duration, Instant},
};
use wayland_client::{
    delegate_noop,
    protocol::{
        wl_buffer, wl_callback, wl_output, wl_pointer, wl_registry, wl_seat, wl_shm, wl_shm_pool,
    },
    Connection, Dispatch, EventQueue, Proxy, QueueHandle, WEnum,
};
use wayland_protocols::xdg::xdg_output::zv1::client::{
    zxdg_output_manager_v1::ZxdgOutputManagerV1,
    zxdg_output_v1::{self, ZxdgOutputV1},
};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};
use wayland_protocols_wlr::{
    screencopy::v1::client::{
        zwlr_screencopy_frame_v1::{self, ZwlrScreencopyFrameV1},
        zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1,
    },
    virtual_pointer::v1::client::{
        zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
        zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1,
    },
};

struct Output {
    proxy: wl_output::WlOutput,
    display: Display,
    scale: i32,
    pixels: (i32, i32),
    transform: u32,
    logical: bool,
}
#[derive(Default)]
struct State {
    outputs: BTreeMap<u32, Output>,
    shm: Option<wl_shm::WlShm>,
    seat: Option<wl_seat::WlSeat>,
    capture: Option<ZwlrScreencopyManagerV1>,
    pointers: Option<ZwlrVirtualPointerManagerV1>,
    keyboards: Option<ZwpVirtualKeyboardManagerV1>,
    xdg: Option<ZxdgOutputManagerV1>,
    sync: bool,
    format: Option<(wl_shm::Format, u32, u32, u32)>,
    buffer_done: bool,
    ready: bool,
    failed: bool,
    inverted: bool,
}
pub struct Wayland {
    conn: Connection,
    queue: EventQueue<State>,
    state: State,
    selected: Option<Display>,
    pointer: Option<ZwlrVirtualPointerV1>,
    keyboard: Option<ZwpVirtualKeyboardV1>,
    held: BTreeSet<u32>,
    buttons: BTreeSet<u32>,
    began: Instant,
}
impl Wayland {
    pub fn connect() -> Result<Self> {
        let conn = Connection::connect_to_env().context("cannot connect to the Wayland desktop")?;
        let queue = conn.new_event_queue();
        conn.display().get_registry(&queue.handle(), ());
        let mut w = Self {
            conn,
            queue,
            state: State::default(),
            selected: None,
            pointer: None,
            keyboard: None,
            held: BTreeSet::new(),
            buttons: BTreeSet::new(),
            began: Instant::now(),
        };
        w.sync()?;
        w.sync()?;
        ensure!(w.state.capture.is_some() && w.state.shm.is_some(), "this Wayland compositor does not expose wlr-screencopy (supported: Omarchy/Hyprland and compatible wlroots desktops; GNOME/KDE Wayland need a portal backend)");
        ensure!(
            w.state.pointers.is_some() && w.state.keyboards.is_some() && w.state.seat.is_some(),
            "this Wayland compositor does not allow virtual keyboard/pointer input"
        );
        if let Some(xdg) = &w.state.xdg {
            for (id, output) in &w.state.outputs {
                xdg.get_xdg_output(&output.proxy, &w.queue.handle(), *id);
            }
            w.sync()?;
        }
        ensure!(!w.displays().is_empty(), "no active Wayland output");
        Ok(w)
    }
    fn sync(&mut self) -> Result<()> {
        self.state.sync = false;
        self.conn.display().sync(&self.queue.handle(), ());
        self.until(|s| s.sync).context("Wayland roundtrip")
    }
    fn until(&mut self, done: impl Fn(&State) -> bool) -> Result<()> {
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            self.queue.dispatch_pending(&mut self.state)?;
            if done(&self.state) {
                return Ok(());
            }
            self.conn.flush()?;
            ensure!(
                Instant::now() < end,
                "Wayland compositor did not respond within 2 s"
            );
            if let Some(read) = self.queue.prepare_read() {
                let mut fd = libc::pollfd {
                    fd: self.conn.as_fd().as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                let ms = end
                    .saturating_duration_since(Instant::now())
                    .as_millis()
                    .min(2000) as i32;
                // SAFETY: one initialized pollfd with a valid connection fd for this call.
                let n = unsafe { libc::poll(&mut fd, 1, ms) };
                if n < 0 {
                    let e = std::io::Error::last_os_error();
                    if e.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(e.into());
                }
                ensure!(n > 0, "Wayland compositor timed out");
                match read.read() {
                    Ok(_) => {}
                    Err(wayland_client::backend::WaylandError::Io(e))
                        if e.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(e) => return Err(e.into()),
                }
            }
        }
    }
    pub fn displays(&self) -> Vec<Display> {
        let mut out: Vec<_> = self
            .state
            .outputs
            .values()
            .filter_map(|o| {
                let mut d = o.display.clone();
                if !o.logical {
                    let (w, h) = if o.transform % 2 == 1 {
                        (o.pixels.1, o.pixels.0)
                    } else {
                        o.pixels
                    };
                    d.width = (w / o.scale.max(1)).clamp(0, 65535) as u16;
                    d.height = (h / o.scale.max(1)).clamp(0, 65535) as u16;
                }
                (d.width > 0 && d.height > 0).then_some(d)
            })
            .collect();
        let main = out.iter().position(|d| d.x == 0 && d.y == 0).unwrap_or(0);
        if let Some(d) = out.get_mut(main) {
            d.main = true;
        }
        out
    }
    pub fn select(&mut self, d: &Display) -> Result<()> {
        let qh = self.queue.handle();
        let output = &self
            .state
            .outputs
            .get(&d.id)
            .context("display disconnected")?
            .proxy;
        self.pointer = Some(
            self.state
                .pointers
                .as_ref()
                .unwrap()
                .create_virtual_pointer_with_output(
                    self.state.seat.as_ref(),
                    Some(output),
                    &qh,
                    (),
                ),
        );
        let keyboard = self
            .state
            .keyboards
            .as_ref()
            .unwrap()
            .create_virtual_keyboard(self.state.seat.as_ref().unwrap(), &qh, ());
        set_keymap(&keyboard, "xkb_keymap { xkb_keycodes { include \"evdev+aliases(qwerty)\" }; xkb_types { include \"complete\" }; xkb_compatibility { include \"complete\" }; xkb_symbols { include \"pc+us+inet(evdev)\" }; };\n")?;
        self.keyboard = Some(keyboard);
        self.selected = Some(d.clone());
        self.sync()
    }
    pub fn capture(&mut self) -> Result<Image> {
        let d = self
            .selected
            .as_ref()
            .context("no selected display")?
            .clone();
        self.sync()?;
        ensure!(
            self.displays().iter().any(|now| now.id == d.id
                && now.width == d.width
                && now.height == d.height
                && now.x == d.x
                && now.y == d.y),
            "display geometry changed; reconnect to refresh the desktop"
        );
        let output = self
            .state
            .outputs
            .get(&d.id)
            .context("display disconnected")?;
        let transform = output.transform;
        self.state.format = None;
        self.state.buffer_done = false;
        self.state.ready = false;
        self.state.failed = false;
        self.state.inverted = false;
        let frame = self.state.capture.as_ref().unwrap().capture_output(
            1,
            &output.proxy,
            &self.queue.handle(),
            (),
        );
        let result = self.read_frame(&frame, transform);
        frame.destroy();
        result
    }
    fn read_frame(&mut self, frame: &ZwlrScreencopyFrameV1, transform: u32) -> Result<Image> {
        self.until(|s| {
            s.failed
                || if frame.version() >= 3 {
                    s.buffer_done
                } else {
                    s.format.is_some()
                }
        })
        .context("waiting for capture buffer")?;
        ensure!(
            !self.state.failed,
            "desktop capture was denied or the display disappeared"
        );
        let (format, w, h, stride) = self
            .state
            .format
            .context("no shared-memory capture format")?;
        ensure!(
            w > 0
                && h > 0
                && w <= 8192
                && h <= 8192
                && stride >= w * 4
                && stride as u64 * h as u64 <= 512 * 1024 * 1024,
            "invalid Wayland capture buffer"
        );
        ensure!(
            matches!(
                format,
                wl_shm::Format::Argb8888
                    | wl_shm::Format::Xrgb8888
                    | wl_shm::Format::Abgr8888
                    | wl_shm::Format::Xbgr8888
                    | wl_shm::Format::Xrgb2101010
                    | wl_shm::Format::Xbgr2101010
                    | wl_shm::Format::Argb2101010
                    | wl_shm::Format::Abgr2101010
            ),
            "unsupported Wayland pixel format: {format:?}"
        );
        let mut file = tempfile::tempfile()?;
        file.set_len(stride as u64 * h as u64)?;
        let qh = self.queue.handle();
        let pool = self.state.shm.as_ref().unwrap().create_pool(
            file.as_fd(),
            (stride * h) as i32,
            &qh,
            (),
        );
        let buffer = pool.create_buffer(0, w as i32, h as i32, stride as i32, format, &qh, ());
        // Keep the pool alive through the copy and let the compositor import the
        // shared-memory buffer before requesting its first render.
        self.sync()?;
        frame.copy(&buffer);
        let result = self
            .until(|s| s.ready || s.failed)
            .context("waiting for captured pixels");
        buffer.destroy();
        pool.destroy();
        result?;
        ensure!(
            !self.state.failed,
            "desktop capture failed (screen may be locked)"
        );
        let mut raw = vec![0; stride as usize * h as usize];
        file.seek(SeekFrom::Start(0))?;
        file.read_exact(&mut raw)?;
        let (w, h, stride) = (w as usize, h as usize, stride as usize);
        let (ow, oh) = if transform % 2 == 1 { (h, w) } else { (w, h) };
        let mut pixels = vec![0; ow * oh * 4];
        let swap = matches!(
            format,
            wl_shm::Format::Abgr8888
                | wl_shm::Format::Xbgr8888
                | wl_shm::Format::Xbgr2101010
                | wl_shm::Format::Abgr2101010
        );
        let ten = matches!(
            format,
            wl_shm::Format::Xrgb2101010
                | wl_shm::Format::Xbgr2101010
                | wl_shm::Format::Argb2101010
                | wl_shm::Format::Abgr2101010
        );
        for y in 0..oh {
            for x in 0..ow {
                let fx = if transform >= 4 { ow - 1 - x } else { x };
                let (sx, sy) = match transform % 4 {
                    1 => (y, h - 1 - fx),
                    2 => (w - 1 - fx, h - 1 - y),
                    3 => (w - 1 - y, fx),
                    _ => (fx, y),
                };
                let sy = if self.state.inverted { h - 1 - sy } else { sy };
                let src = &raw[sy * stride + sx * 4..sy * stride + sx * 4 + 4];
                let mut p: [u8; 4] = if ten {
                    let v = u32::from_le_bytes(src.try_into().unwrap());
                    [(v >> 2) as u8, (v >> 12) as u8, (v >> 22) as u8, 255]
                } else {
                    [src[0], src[1], src[2], 255]
                };
                if swap {
                    p.swap(0, 2);
                }
                pixels[(y * ow + x) * 4..(y * ow + x + 1) * 4].copy_from_slice(&p);
            }
        }
        Ok(Image {
            width: ow,
            height: oh,
            pixels,
        })
    }
    fn time(&self) -> u32 {
        self.began.elapsed().as_millis() as u32
    }
    pub fn key(&mut self, code: u16, flags: u64, down: bool) -> Result<()> {
        let Some(key) = keys::evdev(code) else {
            return Ok(());
        };
        let keyboard = self.keyboard.as_ref().context("no virtual keyboard")?;
        keyboard.modifiers(keys::xkb_mods(flags), 0, 0, 0);
        keyboard.key(self.time(), key, down as u32);
        // v13 modifiers belong to this event; clients need not send a separate
        // Control/Shift release (macOS CGEvent flags work the same way).
        keyboard.modifiers(0, 0, 0, 0);
        if down {
            self.held.insert(key);
        } else {
            self.held.remove(&key);
        }
        self.conn.flush()?;
        Ok(())
    }
    pub fn mouse(&mut self, kind: u8, button: u8, x: f32, y: f32) -> Result<()> {
        let d = self.selected.as_ref().context("no display")?;
        let p = self.pointer.as_ref().context("no virtual pointer")?;
        p.motion_absolute(
            self.time(),
            x.clamp(0., d.width.saturating_sub(1) as f32) as u32,
            y.clamp(0., d.height.saturating_sub(1) as f32) as u32,
            d.width as u32,
            d.height as u32,
        );
        let button = 0x110 + button as u32;
        if kind <= 1 {
            p.button(
                self.time(),
                button,
                if kind == 0 {
                    wl_pointer::ButtonState::Pressed
                } else {
                    wl_pointer::ButtonState::Released
                },
            );
            if kind == 0 {
                self.buttons.insert(button);
            } else {
                self.buttons.remove(&button);
            }
        }
        p.frame();
        self.conn.flush()?;
        Ok(())
    }
    pub fn scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32) -> Result<()> {
        self.mouse(3, 0, x, y)?;
        let p = self.pointer.as_ref().unwrap();
        p.axis_source(wl_pointer::AxisSource::Continuous);
        // CG scroll deltas have the opposite sign to Wayland axis distances.
        if dx != 0. {
            p.axis(
                self.time(),
                wl_pointer::Axis::HorizontalScroll,
                -dx.clamp(-1000., 1000.) as f64,
            );
        }
        if dy != 0. {
            p.axis(
                self.time(),
                wl_pointer::Axis::VerticalScroll,
                -dy.clamp(-1000., 1000.) as f64,
            );
        }
        p.frame();
        self.conn.flush()?;
        Ok(())
    }
    pub fn text(&mut self, text: &str) -> Result<()> {
        self.release();
        // A separate keyboard carries Unicode symbols without replacing the physical-key map.
        let kb = self
            .state
            .keyboards
            .as_ref()
            .unwrap()
            .create_virtual_keyboard(self.state.seat.as_ref().unwrap(), &self.queue.handle(), ());
        let result = (|| {
            let chars: Vec<_> = text.chars().collect();
            for chunk in chars.chunks(200) {
                let mut codes = String::new();
                let mut symbols = String::new();
                for (i, c) in chunk.iter().enumerate() {
                    codes += &format!("<K{i:03}> = {};", i + 8);
                    let sym = match c {
                        '\n' | '\r' => "Return".into(),
                        '\t' => "Tab".into(),
                        c => format!("U{:04X}", *c as u32),
                    };
                    symbols += &format!("key <K{i:03}> {{ [ {sym} ] }};");
                }
                let map = format!("xkb_keymap {{ xkb_keycodes {{ minimum=8; maximum=255; {codes} }}; xkb_types {{ type \"ONE_LEVEL\" {{ modifiers=None; map[None]=Level1; }}; }}; xkb_compatibility {{ }}; xkb_symbols {{ {symbols} }}; }};");
                set_keymap(&kb, &map)?;
                kb.modifiers(0, 0, 0, 0);
                for i in 0..chunk.len() {
                    kb.key(self.time(), i as u32, 1);
                    kb.key(self.time(), i as u32, 0);
                }
                self.sync()?;
            }
            Ok(())
        })();
        kb.destroy();
        let _ = self.conn.flush();
        result
    }
    pub fn release(&mut self) {
        if let Some(kb) = &self.keyboard {
            for k in &self.held {
                kb.key(self.time(), *k, 0);
            }
            kb.modifiers(0, 0, 0, 0);
        }
        if let Some(p) = &self.pointer {
            for b in &self.buttons {
                p.button(self.time(), *b, wl_pointer::ButtonState::Released);
            }
            p.frame();
        }
        self.held.clear();
        self.buttons.clear();
        let _ = self.conn.flush();
    }
}
fn set_keymap(kb: &ZwpVirtualKeyboardV1, text: &str) -> Result<()> {
    let mut file: File = tempfile::tempfile()?;
    file.write_all(text.as_bytes())?;
    file.write_all(&[0])?;
    file.flush()?;
    kb.keymap(1, file.as_fd(), text.len() as u32 + 1);
    Ok(())
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        s: &mut Self,
        r: &wl_registry::WlRegistry,
        e: wl_registry::Event,
        _: &(),
        _: &Connection,
        q: &QueueHandle<Self>,
    ) {
        match e {
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } => match interface.as_str() {
                "wl_shm" => s.shm = Some(r.bind(name, 1, q, ())),
                "wl_seat" if s.seat.is_none() => s.seat = Some(r.bind(name, 1, q, ())),
                "wl_output" => {
                    s.outputs.insert(
                        name,
                        Output {
                            proxy: r.bind(name, version.min(4), q, name),
                            display: Display {
                                id: name,
                                name: format!("Display {name}"),
                                x: 0,
                                y: 0,
                                width: 0,
                                height: 0,
                                main: false,
                            },
                            scale: 1,
                            pixels: (0, 0),
                            transform: 0,
                            logical: false,
                        },
                    );
                }
                // v3 enumerates all buffer offers before copy; older servers offer shm directly.
                "zwlr_screencopy_manager_v1" => {
                    s.capture = Some(r.bind(name, version.min(3), q, ()))
                }
                "zwlr_virtual_pointer_manager_v1" if version >= 2 => {
                    s.pointers = Some(r.bind(name, 2, q, ()))
                }
                "zwp_virtual_keyboard_manager_v1" => s.keyboards = Some(r.bind(name, 1, q, ())),
                "zxdg_output_manager_v1" => s.xdg = Some(r.bind(name, version.min(3), q, ())),
                _ => {}
            },
            wl_registry::Event::GlobalRemove { name } => {
                s.outputs.remove(&name);
            }
            _ => {}
        }
    }
}
impl Dispatch<wl_callback::WlCallback, ()> for State {
    fn event(
        s: &mut Self,
        _: &wl_callback::WlCallback,
        _: wl_callback::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        s.sync = true;
    }
}
impl Dispatch<wl_output::WlOutput, u32> for State {
    fn event(
        s: &mut Self,
        _: &wl_output::WlOutput,
        e: wl_output::Event,
        id: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(o) = s.outputs.get_mut(id) else {
            return;
        };
        match e {
            wl_output::Event::Geometry {
                x, y, transform, ..
            } => {
                o.display.x = x;
                o.display.y = y;
                o.transform = match transform {
                    WEnum::Value(v) => v as u32,
                    WEnum::Unknown(v) => v,
                };
            }
            wl_output::Event::Mode {
                flags: WEnum::Value(flags),
                width,
                height,
                ..
            } if flags.contains(wl_output::Mode::Current) => o.pixels = (width, height),
            wl_output::Event::Scale { factor } => o.scale = factor,
            wl_output::Event::Name { name } => o.display.name = name,
            _ => {}
        }
    }
}
impl Dispatch<ZxdgOutputV1, u32> for State {
    fn event(
        s: &mut Self,
        _: &ZxdgOutputV1,
        e: zxdg_output_v1::Event,
        id: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(o) = s.outputs.get_mut(id) else {
            return;
        };
        match e {
            zxdg_output_v1::Event::LogicalPosition { x, y } => {
                o.display.x = x;
                o.display.y = y;
            }
            zxdg_output_v1::Event::LogicalSize { width, height } => {
                o.display.width = width.clamp(0, 65535) as u16;
                o.display.height = height.clamp(0, 65535) as u16;
                o.logical = true;
            }
            zxdg_output_v1::Event::Name { name } => o.display.name = name,
            _ => {}
        }
    }
}
impl Dispatch<ZwlrScreencopyFrameV1, ()> for State {
    fn event(
        s: &mut Self,
        _: &ZwlrScreencopyFrameV1,
        e: zwlr_screencopy_frame_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match e {
            zwlr_screencopy_frame_v1::Event::BufferDone => s.buffer_done = true,
            zwlr_screencopy_frame_v1::Event::Buffer {
                format: WEnum::Value(format),
                width,
                height,
                stride,
            } => s.format = Some((format, width, height, stride)),
            zwlr_screencopy_frame_v1::Event::Buffer { .. } => s.failed = true,
            zwlr_screencopy_frame_v1::Event::Flags {
                flags: WEnum::Value(flags),
            } => s.inverted = flags.contains(zwlr_screencopy_frame_v1::Flags::YInvert),
            zwlr_screencopy_frame_v1::Event::Ready { .. } => s.ready = true,
            zwlr_screencopy_frame_v1::Event::Failed => s.failed = true,
            _ => {}
        }
    }
}
delegate_noop!(State: ignore wl_shm::WlShm);
delegate_noop!(State: ignore wl_shm_pool::WlShmPool);
delegate_noop!(State: ignore wl_buffer::WlBuffer);
delegate_noop!(State: ignore wl_seat::WlSeat);
delegate_noop!(State: ignore ZwlrScreencopyManagerV1);
delegate_noop!(State: ignore ZwlrVirtualPointerManagerV1);
delegate_noop!(State: ignore ZwlrVirtualPointerV1);
delegate_noop!(State: ignore ZwpVirtualKeyboardManagerV1);
delegate_noop!(State: ignore ZwpVirtualKeyboardV1);
delegate_noop!(State: ignore ZxdgOutputManagerV1);
