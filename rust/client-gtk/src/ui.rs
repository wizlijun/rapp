#[path = "controls.rs"]
mod controls;
use anyhow::{bail, Context, Result};
use glib::translate::IntoGlib;
use gtk::{cairo, gdk, gio, glib, prelude::*};
use rapp_client_core::{
    codec::Decoder,
    geometry,
    protocol::{self as p, Address, Incoming, Menu, Rect, Window},
    stream,
};
use serde_json::json;
use std::{
    cell::{Cell, RefCell},
    io::{BufRead, Write},
    net::{TcpStream, ToSocketAddrs},
    rc::Rc,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc::{self, SyncSender},
        Arc,
    },
    time::{Duration, Instant},
};

enum Event {
    Focus,
    PastePrepared(u32, Result<Vec<u8>>),
    Message(Incoming),
    Image(Vec<u8>, usize, usize, Rect),
    End(i32, String),
}
struct TextSend {
    seq: u32,
    text: String,
    window: Option<u32>,
    started: Instant,
}
type Shared = Rc<RefCell<State>>;
struct State {
    windows: Vec<Window>,
    region: Rect,
    surface: Option<cairo::ImageSurface>,
    tx: Option<SyncSender<Vec<u8>>>,
    pending_text: Option<TextSend>,
    next_seq: u32,
    ready: bool,
    takeover_pending: bool,
    address: Option<Address>,
    finished: bool,
    send_failed: Cell<bool>,
    pointer: (f64, f64),
    pressed: Option<(u32, u8, u8)>,
    zoom: f64,
    focused: Option<u32>,
    mode: u8,
    fps: u8,
    density_choice: u32,
    last_stream: Option<(u8, u8, f32)>,
    geometry_changed: Instant,
    last_size: (i32, i32, i32),
}
impl State {
    fn send(&self, bytes: Vec<u8>) {
        if let Some(tx) = &self.tx {
            // Bounded: an unresponsive peer cannot accumulate unlimited input or block GTK.
            if tx.try_send(bytes).is_err() {
                self.send_failed.set(true);
            }
        }
    }
    fn hit(&self, area: &gtk::DrawingArea, x: f64, y: f64, clamp: bool) -> Option<(u32, f32, f32)> {
        let (cx, cy) = geometry::zoom_point(
            self.region,
            area.width() as f64,
            area.height() as f64,
            self.zoom,
            x,
            y,
            clamp,
        )?;
        if let Some((id, _, _)) = self.pressed {
            let w = self.windows.iter().find(|w| w.id == id)?;
            return Some((
                id,
                (cx - w.rect.x).clamp(0., w.rect.w),
                (cy - w.rect.y).clamp(0., w.rect.h),
            ));
        }
        geometry::hit(&self.windows, cx, cy)
    }
}
fn emit(json_mode: bool, event: serde_json::Value) {
    if json_mode {
        println!("{event}");
        let _ = std::io::stdout().flush();
    }
}
fn connect(
    address: Address,
    events: SyncSender<Event>,
    bytes: Arc<AtomicU64>,
    initial_density: f32,
) -> SyncSender<Vec<u8>> {
    let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(128);
    let ack_tx = tx.clone();
    std::thread::spawn(move || {
        let result = (|| -> Result<()> {
            let addresses = (address.host.as_str(), address.port)
                .to_socket_addrs()
                .context("cannot resolve host")?;
            let deadline = Instant::now() + Duration::from_secs(8);
            let mut socket = None;
            for addr in addresses {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    break;
                }
                if let Ok(s) = TcpStream::connect_timeout(&addr, left) {
                    socket = Some(s);
                    break;
                }
            }
            let mut socket = socket.context("cannot connect to host within 8 seconds")?;
            socket.set_nodelay(true)?;
            socket.set_write_timeout(Some(Duration::from_secs(5)))?;
            socket.write_all(&address.hello(initial_density))?;
            let mut writer = socket.try_clone()?;
            let failure = events.clone();
            std::thread::spawn(move || {
                for packet in rx {
                    if let Err(e) = writer.write_all(&packet) {
                        let _ = failure.send(Event::End(1, format!("send failed: {e}")));
                        break;
                    }
                }
            });
            socket.set_read_timeout(Some(Duration::from_secs(15)))?;
            let mut ready = false;
            let mut decoder = Decoder::default();
            loop {
                let (message, size) = p::read_message(&mut socket)?;
                bytes.fetch_add(size as u64, Ordering::Relaxed);
                match message {
                    Incoming::Error(reason) => {
                        let code = if reason.starts_with("protocol version mismatch") {
                            5
                        } else {
                            1
                        };
                        let _ = events.send(Event::End(code, reason));
                        return Ok(());
                    }
                    Incoming::Ready(_, _, _) if ready => bail!("duplicate Ready"),
                    Incoming::Ready(_, _, _) => {
                        ready = true;
                        socket.set_read_timeout(None)?;
                        events.send(Event::Message(message))?;
                    }
                    Incoming::Frame {
                        mode,
                        region,
                        width,
                        height,
                        full,
                        data,
                    } => {
                        if !ready {
                            bail!("frame before Ready");
                        }
                        let received = Instant::now();
                        let pixels = decoder.decode(mode, width, height, full, &data)?;
                        events.send(Event::Image(pixels, width, height, region))?;
                        if address.version >= 7 {
                            let ms = u16::try_from(received.elapsed().as_millis()).unwrap_or(u16::MAX);
                            // Best effort: a full queue drops the ack, which only slows the host's pacing.
                            let _ = ack_tx.try_send(p::frame_ack(ms));
                        }
                    }
                    _ => {
                        if !ready {
                            bail!("metadata before Ready");
                        }
                        events.send(Event::Message(message))?;
                    }
                }
            }
        })();
        if let Err(e) = result {
            let _ = events.send(Event::End(1, format!("{e:#}")));
        }
    });
    tx
}

pub fn run() -> i32 {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let json_mode = args.iter().any(|a| a == "--json");
    if args.first().is_some_and(|a| a == "version") {
        if args.iter().skip(1).any(|a| a != "--json") {
            eprintln!("unexpected argument");
            return 2;
        }
        if json_mode {
            println!(
                "{}",
                json!({"version":env!("CARGO_PKG_VERSION"),"protocol":p::VERSION})
            );
        } else {
            println!(
                "rapp-client {} (Linux GTK, protocol {})",
                env!("CARGO_PKG_VERSION"),
                p::VERSION
            );
        }
        return 0;
    }
    let parsed = (|| -> Result<Option<Address>> {
        let mut url = None;
        let mut token = None;
        let mut it = args.iter();
        while let Some(a) = it.next() {
            match a.as_str() {
                "connect" if url.is_none() => (),
                "--json" => (),
                "--token-env" => {
                    let name = it.next().context("--token-env needs a variable name")?;
                    token =
                        Some(std::env::var(name).context("token environment variable not set")?);
                }
                _ if a.starts_with('-') => bail!("unknown option {a}"),
                _ => {
                    if url.replace(a).is_some() {
                        bail!("give exactly one rapp:// address");
                    }
                }
            }
        }
        if json_mode && url.is_none() {
            bail!("--json requires a rapp:// address");
        }
        url.map(|u| Address::parse(u, token)).transpose()
    })();
    let address = match parsed {
        Ok(a) => a,
        Err(e) => {
            eprintln!("rapp-client: {e}");
            emit(
                json_mode,
                json!({"event":"exit","code":2,"reason":e.to_string()}),
            );
            return 2;
        }
    };
    let app = gtk::Application::builder()
        .application_id("com.rapp.client")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    let status = Rc::new(Cell::new(0));
    let result = status.clone();
    app.connect_activate(move |app| build(app, address.clone(), json_mode, result.clone()));
    app.run_with_args::<&str>(&[]);
    status.get()
}

fn build(app: &gtk::Application, address: Option<Address>, json_mode: bool, status: Rc<Cell<i32>>) {
    let (events, rx) = mpsc::sync_channel(3);
    let bytes = Arc::new(AtomicU64::new(0));
    let state = Rc::new(RefCell::new(State {
        windows: vec![],
        region: Rect {
            x: 0.,
            y: 0.,
            w: 800.,
            h: 500.,
        },
        surface: None,
        tx: None,
        pending_text: None,
        next_seq: 1,
        ready: false,
        takeover_pending: false,
        address: address.clone(),
        finished: false,
        send_failed: Cell::new(false),
        pointer: (0., 0.),
        pressed: None,
        zoom: 1.,
        focused: None,
        mode: address.as_ref().map_or(2, |a| a.mode),
        fps: address.as_ref().map_or(15, |a| a.fps),
        density_choice: 1,
        last_stream: None,
        geometry_changed: Instant::now(),
        last_size: (0, 0, 0),
    }));
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("rapp-client · 远程窗口")
        .default_width(1000)
        .default_height(720)
        .build();
    let root = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let header = gtk::HeaderBar::new();
    let title = gtk::Label::new(Some("rapp-client"));
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    header.set_title_widget(Some(&title));
    let rate = gtk::MenuButton::builder()
        .label("0 KB/s")
        .has_frame(false)
        .tooltip_text("点击或右键调整画质、采集密度和帧率")
        .build();
    rate.set_visible(false);
    rate.add_css_class("caption");
    header.pack_end(&rate);
    window.set_titlebar(Some(&header));
    let menu_bar = gtk::PopoverMenuBar::from_model(None::<&gio::Menu>);
    root.append(&menu_bar);
    let connection = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let url = gtk::Entry::builder()
        .placeholder_text("rapp://主机地址/应用标识?mode=color16")
        .hexpand(true)
        .build();
    let token = gtk::PasswordEntry::builder()
        .placeholder_text("连接口令")
        .show_peek_icon(true)
        .build();
    let button = gtk::Button::with_label("连接");
    connection.append(&url);
    connection.append(&token);
    connection.append(&button);
    root.append(&connection);
    let info = gtk::Label::new(Some("输入主机地址与口令，或从 rapp 管理界面打开远程应用"));
    info.set_wrap(true);
    root.append(&info);
    let area = gtk::DrawingArea::builder()
        .hexpand(true)
        .vexpand(true)
        .build();
    let viewport = gtk::ScrolledWindow::builder()
        .hexpand(true)
        .vexpand(true)
        .child(&area)
        .build();
    root.append(&viewport);
    let controls = controls::Controls::new(&window, app, &state, &area, &viewport, json_mode);
    rate.set_menu_model(Some(&controls.stream_menu));
    let right = gtk::GestureClick::new();
    right.set_button(3);
    let rate_button = rate.clone();
    right.connect_pressed(move |gesture, _, _, _| {
        gesture.set_state(gtk::EventSequenceState::Claimed);
        if let Some(popover) = rate_button.popover() {
            popover.popup();
        }
    });
    rate.add_controller(right);
    let local_menu = gio::Menu::new();
    local_menu.append_submenu(Some("rapp-client"), &controls.app_menu);
    menu_bar.set_menu_model(Some(&local_menu));
    let entry = gtk::Entry::builder()
        .placeholder_text("在此输入或粘贴，回车发送")
        .build();
    let input = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    entry.set_hexpand(true);
    let copy = gtk::Button::with_label("复制");
    copy.set_tooltip_text(Some("复制远端选中的文字到本地剪贴板（v5）"));
    let send = gtk::Button::with_label("发送 ⏎");
    send.set_sensitive(false);
    input.append(&entry);
    input.append(&copy);
    input.append(&send);
    root.append(&input);
    let s = state.clone();
    copy.connect_clicked(move |_| {
        let s = s.borrow();
        if let Some(id) = s.focused {
            s.send(p::id_packet(14, id));
        }
        s.send(p::key(8, 1 << 20, true));
        s.send(p::key(8, 1 << 20, false));
    });
    let e = entry.clone();
    send.connect_clicked(move |_| {
        e.emit_activate();
        e.grab_focus();
    });
    let send_button = send.clone();
    entry.connect_changed(move |entry| send_button.set_sensitive(!entry.text().is_empty()));
    window.set_child(Some(&root));
    let s = state.clone();
    area.set_draw_func(move |_, cr, w, h| {
        cr.set_source_rgb(0.06, 0.06, 0.07);
        let _ = cr.paint();
        let s = s.borrow();
        if let Some(surface) = &s.surface {
            let (x, y, z) = geometry::zoom_placement(s.region, w as f64, h as f64, s.zoom);
            let _ = cr.save();
            cr.translate(x, y);
            cr.scale(
                z * s.region.w as f64 / surface.width() as f64,
                z * s.region.h as f64 / surface.height() as f64,
            );
            if cr.set_source_surface(surface, 0., 0.).is_ok() {
                let _ = cr.paint();
            }
            let _ = cr.restore();
        }
    });
    let a = app.clone();
    let s = state.clone();
    window.connect_close_request(move |_| {
        finish(&a, &s, json_mode, 0, "quit");
        glib::Propagation::Proceed
    });
    install_input(&area, &entry, app, &state, json_mode, events.clone());
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let a = app.clone();
    let s = state.clone();
    keys.connect_key_pressed(move |_, key, _, mods| {
        if mods.contains(gdk::ModifierType::CONTROL_MASK) && key.to_lower() == gdk::Key::q {
            finish(&a, &s, json_mode, 0, "quit");
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);
    let s = state.clone();
    let ev = events.clone();
    let meter = bytes.clone();
    let inf = info.clone();
    let panel = connection.clone();
    window.present();
    let connection_window = window.clone();
    let state_for_connect = state.clone();
    let menu_controls = controls.clone();
    button.connect_clicked(move |_| {
        match Address::parse(url.text().as_str(), Some(token.text().to_string())) {
            Ok(address) => {
                let mut s = s.borrow_mut();
                s.address = Some(address.clone());
                s.mode = address.mode;
                s.fps = address.fps;
                let backing = connection_window
                    .surface()
                    .map_or(connection_window.scale_factor() as f64, |surface| {
                        surface.scale()
                    });
                let density = stream::capture_density(s.zoom, backing, s.density_choice);
                s.last_stream = Some((address.mode, address.fps, density));
                s.tx = Some(connect(address, ev.clone(), meter.clone(), density));
                drop(s);
                menu_controls.sync(&state_for_connect);
                panel.set_visible(false);
                inf.set_text("正在连接…");
            }
            Err(e) => inf.set_text(&e.to_string()),
        }
    });
    if let Some(address) = address {
        connection.set_visible(false);
        info.set_text("正在连接…");
        let mut s = state.borrow_mut();
        let backing = window
            .surface()
            .map_or(window.scale_factor() as f64, |surface| surface.scale());
        let density = stream::capture_density(s.zoom, backing, s.density_choice);
        s.last_stream = Some((address.mode, address.fps, density));
        s.tx = Some(connect(address, events.clone(), bytes.clone(), density));
    }
    if json_mode {
        let ev = events.clone();
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                let Ok(line) = line else { break };
                let Ok(command) = serde_json::from_str::<serde_json::Value>(&line) else {
                    continue;
                };
                match command["cmd"].as_str() {
                    Some("quit") => {
                        let _ = ev.send(Event::End(0, "quit".into()));
                        return;
                    }
                    Some("focus") if ev.send(Event::Focus).is_err() => return,
                    _ => (),
                }
            }
            let _ = ev.send(Event::End(0, "stdin closed".into()));
        });
    }
    window.present();
    let app = app.clone();
    let mut last_rate = Instant::now();
    let mut notice_deadline = None;
    glib::timeout_add_local(Duration::from_millis(16), move || {
        if state.borrow().finished {
            return glib::ControlFlow::Break;
        }
        if state.borrow().send_failed.get() {
            status.set(1);
            finish(&app, &state, json_mode, 1, "connection input queue stalled");
            return glib::ControlFlow::Break;
        }
        for _ in 0..4 {
            let Ok(event) = rx.try_recv() else {
                break;
            };
            match event {
                Event::Focus => {
                    window.unminimize();
                    window.present();
                }
                Event::End(code, reason) => {
                    if state.borrow().takeover_pending {
                        continue;
                    }
                    if !json_mode {
                        if let Some(notice) = p::takeover_notice(&reason) {
                            offer_take_back(&window, &app, &state, &status, notice, reason);
                            continue;
                        }
                    }
                    status.set(code);
                    finish(&app, &state, json_mode, code, &reason);
                    return glib::ControlFlow::Break;
                }
                Event::Message(Incoming::Ready(name, w, h)) => {
                    window.set_title(Some(&format!("{name} · rapp-client")));
                    title.set_text(&name);
                    info.set_visible(false);
                    rate.set_visible(true);
                    state.borrow_mut().ready = true;
                    controls.sync(&state);
                    emit(
                        json_mode,
                        json!({"event":"ready","width":w,"height":h,"title":name}),
                    );
                    entry.grab_focus();
                }
                Event::Message(Incoming::Windows(table)) => {
                    emit(json_mode, json!({"event":"windows","count":table.len()}));
                    if table.is_empty() {
                        info.set_visible(true);
                        info.set_text("没有打开的远程窗口，可通过上方应用菜单新建");
                        state.borrow_mut().surface = None;
                        area.queue_draw();
                    } else {
                        if notice_deadline.is_none() {
                            info.set_visible(false);
                        }
                    }
                    {
                        let mut s = state.borrow_mut();
                        s.focused = table
                            .iter()
                            .find(|w| w.flags & 2 != 0 && w.kind <= 2)
                            .or_else(|| table.iter().find(|w| w.kind <= 2))
                            .map(|w| w.id);
                        s.windows = table;
                    }
                    controls.sync(&state);
                }
                Event::Message(Incoming::Menus(items)) => {
                    let (model, group) = menus(&items, &state);
                    window.insert_action_group("remote", Some(&group));
                    model.prepend_submenu(Some("rapp-client"), &controls.app_menu);
                    menu_bar.set_menu_model(Some(&model));
                }
                Event::Message(Incoming::Clipboard {
                    id,
                    text,
                    truncated,
                }) => {
                    controls.add_clip(id, text.clone(), truncated, &window);
                    info.set_visible(true);
                    notice_deadline = Some(Instant::now() + Duration::from_secs(3));
                    if let Some(text) = text {
                        if !truncated {
                            gtk::prelude::WidgetExt::display(&window)
                                .clipboard()
                                .set_text(&text);
                            info.set_text("远程文字已复制到本地剪贴板");
                        } else {
                            info.set_text("远程剪贴板文字过长，暂不支持完整下载");
                        }
                    } else {
                        info.set_text("已收到远程剪贴板信息；此版本暂不支持图片和文件下载");
                    }
                }
                Event::Message(Incoming::InputBlocked(by)) => {
                    info.set_text(&p::input_blocked_notice(&by));
                    info.set_visible(true);
                    notice_deadline = Some(Instant::now() + Duration::from_secs(1));
                    emit(json_mode, json!({"event":"input_blocked","by":by}));
                }
                Event::PastePrepared(seq, result) => {
                    let mut s = state.borrow_mut();
                    if let Some(pending) = &s.pending_text {
                        if pending.seq == seq {
                            match result {
                                Ok(packet) => {
                                    if let Some(id) = pending.window {
                                        s.send(p::id_packet(14, id));
                                    }
                                    s.send(packet);
                                }
                                Err(error) => {
                                    s.pending_text = None;
                                    info.set_text(&format!("发送没成功：{error}"));
                                    info.set_visible(true);
                                    notice_deadline = Some(Instant::now() + Duration::from_secs(5));
                                }
                            }
                        }
                    }
                }
                Event::Message(Incoming::Pasted { seq, error }) => {
                    let pending = {
                        let mut s = state.borrow_mut();
                        if s.pending_text.as_ref().is_some_and(|p| p.seq == seq) {
                            s.pending_text.take()
                        } else {
                            None
                        }
                    };
                    let Some(pending) = pending else { continue };
                    if error.is_empty() {
                        let current = entry.text();
                        if let Some(rest) = current.strip_prefix(&pending.text) {
                            entry.set_text(rest);
                        }
                    } else {
                        info.set_visible(true);
                        notice_deadline = Some(Instant::now() + Duration::from_secs(3));
                        info.set_text(&error);
                    }
                }
                Event::Image(pixels, w, h, region) => {
                    match cairo::ImageSurface::create_for_data(
                        pixels,
                        cairo::Format::Rgb24,
                        w as i32,
                        h as i32,
                        w as i32 * 4,
                    ) {
                        Ok(surface) => {
                            let mut s = state.borrow_mut();
                            s.surface = Some(surface);
                            if s.region != region {
                                s.geometry_changed = Instant::now();
                            }
                            s.region = region;
                            area.queue_draw();
                        }
                        Err(e) => {
                            status.set(1);
                            finish(&app, &state, json_mode, 1, &e.to_string());
                            return glib::ControlFlow::Break;
                        }
                    }
                }
                _ => (),
            }
        }
        if last_rate.elapsed() >= Duration::from_secs(1) {
            rate.set_label(&stream::rate(
                bytes.swap(0, Ordering::Relaxed),
                last_rate.elapsed().as_secs_f64(),
            ));
            last_rate = Instant::now();
        }
        if !state.borrow().takeover_pending
            && notice_deadline.is_some_and(|deadline| Instant::now() >= deadline)
        {
            notice_deadline = None;
            if !state.borrow().windows.is_empty() {
                info.set_visible(false);
            }
        }
        let mut s = state.borrow_mut();
        if s.pending_text
            .as_ref()
            .is_some_and(|p| p.started.elapsed() >= Duration::from_secs(30))
        {
            s.pending_text = None;
            info.set_text("未收到 A 的确认，请检查远端内容后再重试");
            info.set_visible(true);
            notice_deadline = Some(Instant::now() + Duration::from_secs(5));
        }
        copy.set_sensitive(s.ready);
        send.set_sensitive(s.ready && s.pending_text.is_none() && !entry.text().is_empty());
        let content_width = (s.region.w as f64 * s.zoom).ceil().clamp(1., 65535.) as i32;
        let content_height = (s.region.h as f64 * s.zoom).ceil().clamp(1., 65535.) as i32;
        if area.content_width() != content_width {
            area.set_content_width(content_width);
        }
        if area.content_height() != content_height {
            area.set_content_height(content_height);
        }
        let size = (area.width(), area.height(), area.scale_factor());
        if size != s.last_size {
            s.last_size = size;
            s.geometry_changed = Instant::now();
        }
        if s.ready && s.geometry_changed.elapsed() > Duration::from_millis(300) {
            let backing = area
                .native()
                .and_then(|n| n.surface())
                .map_or(size.2 as f64, |surface| surface.scale());
            let density = stream::capture_density(s.zoom, backing, s.density_choice);
            let next = (s.mode, s.fps, density);
            if stream::changed(s.last_stream, next) {
                s.send(p::stream(next.0, next.1, next.2, None));
                s.last_stream = Some(next);
            }
        }
        glib::ControlFlow::Continue
    });
}
// Standalone CLI clients offer an explicit take-back. Hub-managed clients keep
// their JSON exit contract: the manager owns reconnecting those sessions.
fn offer_take_back(
    window: &gtk::ApplicationWindow,
    app: &gtk::Application,
    state: &Shared,
    status: &Rc<Cell<i32>>,
    notice: String,
    reason: String,
) {
    {
        let mut s = state.borrow_mut();
        s.takeover_pending = true;
        s.ready = false;
        s.tx = None;
        s.pressed = None;
    }
    let dialog = gtk::AlertDialog::builder()
        .modal(true)
        .message(notice)
        .buttons(["关闭", "拿回来"])
        .cancel_button(0)
        .default_button(1)
        .build();
    let app = app.clone();
    let state = state.clone();
    let status = status.clone();
    dialog.choose(Some(window), None::<&gio::Cancellable>, move |response| {
        let result = if response == Ok(1) {
            (|| -> Result<()> {
                let s = state.borrow();
                let address = s.address.as_ref().context("missing reconnect address")?;
                std::process::Command::new(std::env::current_exe()?)
                    .arg(address.connect_url())
                    .args(["--token-env", "RAPP_RECONNECT_TOKEN"])
                    .env("RAPP_RECONNECT_TOKEN", &address.token)
                    .spawn()?;
                Ok(())
            })()
        } else {
            Err(anyhow::anyhow!(reason.clone()))
        };
        let (code, why) = match result {
            Ok(()) => (0, "reconnecting".into()),
            Err(e) => (1, e.to_string()),
        };
        status.set(code);
        finish(&app, &state, false, code, &why);
    });
}

fn finish(app: &gtk::Application, state: &Shared, json_mode: bool, code: i32, reason: &str) {
    let mut s = state.borrow_mut();
    if s.finished {
        return;
    }
    s.finished = true;
    s.tx = None;
    emit(
        json_mode,
        json!({"event":"exit","code":code,"reason":reason}),
    );
    if code != 0 {
        eprintln!("rapp-client: {reason}");
    }
    app.quit();
}
fn install_input(
    area: &gtk::DrawingArea,
    entry: &gtk::Entry,
    app: &gtk::Application,
    state: &Shared,
    json_mode: bool,
    events: SyncSender<Event>,
) {
    let click = gtk::GestureClick::new();
    click.set_button(0);
    let s = state.clone();
    let a = area.clone();
    let e = entry.clone();
    click.connect_pressed(move |g, n, x, y| {
        let button = match g.current_button() {
            1 => 0,
            3 => 1,
            _ => return,
        };
        let mut s = s.borrow_mut();
        if !s.ready {
            return;
        }
        if let Some((id, rx, ry)) = s.hit(&a, x, y, false) {
            s.focused = Some(id);
            s.send(p::id_packet(14, id));
            let n = n.clamp(1, 255) as u8;
            s.send(p::mouse(0, button, id, rx, ry, n));
            s.pressed = Some((id, button, n));
            s.pointer = (x, y);
            e.grab_focus();
            g.set_state(gtk::EventSequenceState::Claimed);
        }
    });
    let s = state.clone();
    let a = area.clone();
    click.connect_released(move |_, _, x, y| {
        let mut s = s.borrow_mut();
        if let Some((_, button, n)) = s.pressed {
            if let Some((id, rx, ry)) = s.hit(&a, x, y, true) {
                s.send(p::mouse(1, button, id, rx, ry, n));
            }
            s.pressed = None;
        }
    });
    let s = state.clone();
    let a = area.clone();
    click.connect_cancel(move |_, _| {
        let mut s = s.borrow_mut();
        if let Some((_, b, n)) = s.pressed {
            if let Some((id, x, y)) = s.hit(&a, s.pointer.0, s.pointer.1, true) {
                s.send(p::mouse(1, b, id, x, y, n));
            }
            s.pressed = None;
        }
    });
    area.add_controller(click);
    let motion = gtk::EventControllerMotion::new();
    let s = state.clone();
    let a = area.clone();
    motion.connect_motion(move |_, x, y| {
        let mut s = s.borrow_mut();
        s.pointer = (x, y);
        if let Some((id, rx, ry)) = s.hit(&a, x, y, s.pressed.is_some()) {
            if let Some((_, button, n)) = s.pressed {
                s.send(p::mouse(2, button, id, rx, ry, n));
            } else if s.windows.iter().any(|w| w.id == id && w.kind >= 3) {
                s.send(p::mouse(3, 0, id, rx, ry, 1));
            }
        }
    });
    area.add_controller(motion);
    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
    let s = state.clone();
    let a = area.clone();
    scroll.connect_scroll(move |controller, dx, dy| {
        let s = s.borrow();
        if let Some((id, x, y)) = s.hit(&a, s.pointer.0, s.pointer.1, false) {
            let unit = if controller.unit() == gdk::ScrollUnit::Wheel {
                10.
            } else {
                1.
            };
            s.send(p::scroll(
                id,
                x,
                y,
                (-dx * unit) as f32,
                (-dy * unit) as f32,
            ));
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    area.add_controller(scroll);
    let s = state.clone();
    entry.connect_activate(move |e| {
        let mut s = s.borrow_mut();
        if !s.ready || s.pending_text.is_some() {
            return;
        }
        let text = e.text().to_string();
        if text.is_empty() {
            s.send(p::key(36, 0, true));
            s.send(p::key(36, 0, false));
            return;
        }
        let Some(address) = s.address.clone() else {
            return;
        };
        if address.version == 4 {
            s.send(p::packet(5, text.as_bytes().to_vec()));
            e.set_text("");
            return;
        }
        let seq = s.next_seq;
        let Some(next) = seq.checked_add(1) else {
            return;
        };
        s.next_seq = next;
        s.pending_text = Some(TextSend {
            seq,
            text: text.clone(),
            window: s.focused,
            started: Instant::now(),
        });
        let events = events.clone();
        std::thread::spawn(move || {
            let result = rapp_client_core::text::prepare_paste(&address, seq, &text);
            let _ = events.send(Event::PastePrepared(seq, result));
        });
    });
    // Observe GtkText's own IM context; leave composing keystrokes to the input method.
    let preedit = Rc::new(Cell::new(false));
    if let Some(text) = entry.first_child() {
        let controllers = text.observe_controllers();
        for i in 0..controllers.n_items() {
            if let Some(key) = controllers
                .item(i)
                .and_then(|o| o.downcast::<gtk::EventControllerKey>().ok())
            {
                if let Some(im) = key.im_context() {
                    let active = preedit.clone();
                    im.connect_preedit_changed(move |im| {
                        active.set(!im.preedit_string().0.is_empty())
                    });
                }
            }
        }
    }
    let key = gtk::EventControllerKey::new();
    key.set_propagation_phase(gtk::PropagationPhase::Capture);
    let s = state.clone();
    let e = entry.clone();
    let app = app.clone();
    key.connect_key_pressed(move |_, key, _, mods| {
        if mods.intersects(gdk::ModifierType::SUPER_MASK | gdk::ModifierType::META_MASK) {
            return glib::Propagation::Proceed;
        }
        let ctrl = mods.contains(gdk::ModifierType::CONTROL_MASK);
        if ctrl && key.to_lower() == gdk::Key::q {
            finish(&app, &s, json_mode, 0, "quit");
            return glib::Propagation::Stop;
        }
        if ctrl
            && key.to_lower() == gdk::Key::v
            && !mods.intersects(gdk::ModifierType::SHIFT_MASK | gdk::ModifierType::ALT_MASK)
        {
            return glib::Propagation::Proceed;
        }
        if preedit.get() {
            return glib::Propagation::Proceed;
        }
        if !e.text().is_empty() {
            if key == gdk::Key::Escape {
                e.set_text("");
                return glib::Propagation::Stop;
            }
            return glib::Propagation::Proceed;
        }
        let raw = key.to_lower().into_glib();
        if ctrl || matches!(raw,0xff08|0xff09|0xfe20|0xff1b|0xff50..=0xff57|0xffff|0xffbe..=0xffc9)
        {
            if let Some(code) = geometry::keycode(raw) {
                let flags = (if ctrl { 1u64 << 20 } else { 0 })
                    | (if mods.contains(gdk::ModifierType::ALT_MASK) {
                        1 << 19
                    } else {
                        0
                    })
                    | (if mods.contains(gdk::ModifierType::SHIFT_MASK) {
                        1 << 17
                    } else {
                        0
                    });
                s.borrow().send(p::key(code, flags, true));
                s.borrow().send(p::key(code, flags, false));
                return glib::Propagation::Stop;
            }
        }
        glib::Propagation::Proceed
    });
    entry.add_controller(key);
}
fn menus(items: &[Menu], state: &Shared) -> (gio::Menu, gio::SimpleActionGroup) {
    fn fill(
        items: &[Menu],
        prefix: &[u16],
        group: &gio::SimpleActionGroup,
        state: &Shared,
    ) -> gio::Menu {
        let menu = gio::Menu::new();
        let mut section = gio::Menu::new();
        for (i, item) in items.iter().enumerate() {
            if item.flags & 4 != 0 {
                if section.n_items() > 0 {
                    menu.append_section(None, &section);
                }
                section = gio::Menu::new();
                continue;
            }
            let mut path = prefix.to_vec();
            path.push(i as u16);
            if !item.children.is_empty() {
                section.append_submenu(
                    Some(&item.title),
                    &fill(&item.children, &path, group, state),
                );
                continue;
            }
            let name = format!(
                "pick{}",
                path.iter()
                    .map(u16::to_string)
                    .collect::<Vec<_>>()
                    .join("_")
            );
            let action = if item.flags & 2 != 0 {
                gio::SimpleAction::new_stateful(&name, None, &true.to_variant())
            } else {
                gio::SimpleAction::new(&name, None)
            };
            action.set_enabled(item.flags & 1 != 0);
            let s = state.clone();
            action.connect_activate(move |_, _| s.borrow().send(p::menu_pick(&path)));
            group.add_action(&action);
            let label = if item.key.is_empty() {
                item.title.clone()
            } else {
                format!(
                    "{}    {}{}{}{}{}",
                    item.title,
                    if item.modifiers & 8 != 0 { "Ctrl+" } else { "" },
                    if item.modifiers & 4 != 0 { "Alt+" } else { "" },
                    if item.modifiers & 2 != 0 { "⌃" } else { "" },
                    if item.modifiers & 1 != 0 {
                        "Shift+"
                    } else {
                        ""
                    },
                    item.key
                )
            };
            section.append(Some(&label), Some(&format!("remote.{name}")));
        }
        if section.n_items() > 0 {
            menu.append_section(None, &section);
        }
        menu
    }
    let group = gio::SimpleActionGroup::new();
    let model = gio::Menu::new();
    for (i, item) in items.iter().enumerate() {
        model.append_submenu(
            Some(&item.title),
            &fill(&item.children, &[i as u16], &group, state),
        );
    }
    (model, group)
}
