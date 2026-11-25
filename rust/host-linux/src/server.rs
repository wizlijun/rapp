use crate::{
    capture::{self, CaptureWorker, Job},
    clipboard::Clipboard,
    desktop::Desktop,
    transfers::Transfers,
    wire::{self, Input, Settings},
};
use anyhow::{bail, ensure, Context, Result};
use rapp_client_core::protocol::{id_packet, packet};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    io::{BufRead, Read, Seek, SeekFrom, Write},
    net::{Shutdown, TcpListener, TcpStream},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        mpsc, Arc, Mutex, Weak,
    },
    time::{Duration, Instant},
};

pub fn emit(value: Value) {
    println!("{value}");
}

/// Bounded subprocesses; input is a private file, never shell syntax or argv text.
pub fn command(bin: &str, args: &[&str], input: Option<&[u8]>) -> Result<Vec<u8>> {
    let mut stdin = tempfile::tempfile()?;
    if let Some(bytes) = input {
        stdin.write_all(bytes)?;
        stdin.rewind()?;
    }
    let mut stdout = tempfile::tempfile()?;
    let mut child = Command::new(bin)
        .args(args)
        .stdin(stdin)
        .stdout(stdout.try_clone()?)
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("cannot start {bin}"))?;
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = child.try_wait()? {
            ensure!(status.success(), "{bin} failed");
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("{bin} timed out");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    ensure!(
        stdout.metadata()?.len() <= 1024 * 1024,
        "{bin} output too large"
    );
    stdout.seek(SeekFrom::Start(0))?;
    let mut out = vec![];
    stdout.read_to_end(&mut out)?;
    Ok(out)
}
fn session_id() -> String {
    std::env::var("XDG_SESSION_ID").unwrap_or_else(|_| "auto".into())
}
pub fn locked() -> Option<bool> {
    let out = command(
        "loginctl",
        &[
            "show-session",
            &session_id(),
            "--property=LockedHint",
            "--value",
        ],
        None,
    )
    .ok()?;
    match std::str::from_utf8(&out).ok()?.trim() {
        "yes" => Some(true),
        "no" => Some(false),
        _ => None,
    }
}
pub fn lock() -> Result<bool> {
    if locked() == Some(true) {
        return Ok(false);
    }
    command("loginctl", &["lock-session", &session_id()], None)?;
    // logind's method is a request; only claim success when the session confirms it.
    for _ in 0..10 {
        if locked() == Some(true) {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    bail!("desktop did not confirm locking; configure a session locker that handles logind lock requests")
}

pub struct Options {
    pub app: String,
    pub token: String,
    pub bind: String,
    pub port: u16,
}
struct Authenticated {
    socket: TcpStream,
    settings: Settings,
}
enum Event {
    Accepted(Authenticated),
    Control(Value),
    Eof,
}
struct Live {
    socket: TcpStream,
    settings: Settings,
    view: Option<(u32, rapp_client_core::protocol::Rect)>,
    transfers: Arc<Transfers>,
    clipboard: Option<Clipboard>,
    accessibility: crate::accessibility::Accessibility,
    input_sources: crate::input_source::InputSources,
    target: Value,
    secure: bool,
    /// Window table, menu bar and focus region, and the pause (v15) that throttles or holds them.
    outbox: crate::pause::Outbox,
    epoch: u64,
    unchanged: u32,
    pending: Vec<u8>,
    next_frame: Instant,
    active_after: Instant,
    clock: Instant,
    pacing: crate::pacing::Pacing,
    saving: u8,
    gate: crate::gate::Gate,
    locked: Option<bool>,
    next_lock_check: Instant,
    next_windows: Instant,
    cover: Option<crate::desktop::Cover>,
    last_opening_input: Option<Instant>,
    covered_buttons: HashSet<u8>,
    _inhibit: Option<std::process::Child>,
}
fn next_epoch() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}
impl Drop for Live {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.pending.zeroize();
        self.transfers.cancel();
        let _ = self.socket.shutdown(Shutdown::Both);
        if let Some(child) = &mut self._inhibit {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
impl Live {
    fn send(&mut self, bytes: &[u8]) -> Result<()> {
        self.socket.write_all(bytes)?;
        Ok(())
    }
    fn read(&mut self) -> Result<Vec<Input>> {
        // Poll before reading so fragmented packets never lose their prefix on timeout.
        let mut buf = [0; 65536];
        use std::os::fd::AsRawFd;
        let mut fd = libc::pollfd {
            fd: self.socket.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: the socket owns this fd throughout the call.
        if unsafe { libc::poll(&mut fd, 1, 0) } > 0 {
            let n = self.socket.read(&mut buf)?;
            ensure!(n != 0, "client disconnected");
            self.pending.extend_from_slice(&buf[..n]);
            buf[..n].fill(0);
        }
        ensure!(
            self.pending.len() <= wire::MAX_INPUT + 5,
            "client input buffer too large"
        );
        let mut offset = 0;
        let mut messages = vec![];
        while self.pending.len() - offset >= 5 {
            let n = u32::from_le_bytes(self.pending[offset + 1..offset + 5].try_into().unwrap())
                as usize;
            ensure!(n <= wire::MAX_INPUT, "client message too large");
            if self.pending.len() - offset < 5 + n {
                break;
            }
            let parsed = wire::input(
                self.pending[offset],
                &self.pending[offset + 5..offset + 5 + n],
            );
            if self.pending[offset] == 35 {
                self.pending[offset + 5..offset + 5 + n].fill(0);
            }
            messages.push(parsed?);
            offset += 5 + n;
        }
        self.pending.drain(..offset);
        Ok(messages)
    }
}
fn handshake(
    mut s: TcpStream,
    opts: &Options,
    transfers: &Mutex<Option<Weak<Transfers>>>,
) -> Result<Option<Authenticated>> {
    s.set_read_timeout(Some(Duration::from_secs(5)))?;
    s.set_write_timeout(Some(Duration::from_secs(3)))?;
    s.set_nodelay(true)?;
    let mut header = [0; 5];
    s.read_exact(&mut header)?;
    let n = u32::from_le_bytes(header[1..].try_into().unwrap()) as usize;
    if ![1, 22, 23].contains(&header[0]) || n > 131100 {
        let message = "first message must be hello, fetch or put";
        let _ = s.write_all(&wire::text_packet(3, message));
        bail!(message);
    }
    let mut data = vec![0; n];
    s.read_exact(&mut data)?;
    if header[0] != 1 {
        let session = transfers.lock().unwrap().as_ref().and_then(Weak::upgrade);
        let result = session
            .context("no session")
            .and_then(|session| session.side(&mut s, header[0], &data, &opts.token));
        if let Err(e) = result {
            let _ = s.write_all(&wire::text_packet(3, &e.to_string()));
        }
        return Ok(None);
    }
    match wire::hello(&data, &opts.token, &opts.app) {
        Ok(settings) => Ok(Some(Authenticated {
            socket: s,
            settings,
        })),
        Err(e) => {
            let _ = s.write_all(&wire::text_packet(3, &e.to_string()));
            Err(e)
        }
    }
}
fn end(live: &mut Option<Live>, desktop: &mut Desktop, reason: &str) {
    if let Some(mut old) = live.take() {
        let _ = old.send(&wire::text_packet(3, reason));
        desktop.release();
        emit(json!({"event":"session", "state":"ended", "reason": reason}));
    }
}
pub fn serve(opts: Options) -> Result<()> {
    ensure!(!opts.token.is_empty(), "a token is required");
    let mut desktop = Desktop::connect()?;
    let display = desktop.select(&opts.app)?;
    let mut capture = CaptureWorker::start(opts.app.clone(), display.clone());
    let title = if desktop.is_application() {
        desktop
            .windows()?
            .first()
            .map(|w| w.title.clone())
            .unwrap_or_else(|| "应用".into())
    } else {
        format!("桌面 · {}", display.name)
    };
    let listener = TcpListener::bind((opts.bind.as_str(), opts.port))?;
    let port = listener.local_addr()?.port();
    let (tx, rx) = mpsc::sync_channel(64);
    let controls = tx.clone();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else {
                break;
            };
            if let Ok(v) = serde_json::from_str(&line) {
                if controls.send(Event::Control(v)).is_err() {
                    return;
                }
            }
        }
        let _ = controls.send(Event::Eof);
    });
    let clipboard_app = (!opts.app.starts_with("desktop:")).then(|| opts.app.clone());
    let opts = Arc::new(opts);
    let transfers = Arc::new(Mutex::new(None::<Weak<Transfers>>));
    let side_transfers = transfers.clone();
    std::thread::spawn(move || {
        let pending = Arc::new(AtomicUsize::new(0));
        for socket in listener.incoming().flatten() {
            if pending.load(Ordering::Relaxed) >= 8 {
                continue;
            }
            pending.fetch_add(1, Ordering::Relaxed);
            let (opts, tx, pending, transfers) = (
                opts.clone(),
                tx.clone(),
                pending.clone(),
                side_transfers.clone(),
            );
            std::thread::spawn(move || {
                if let Ok(Some(accepted)) = handshake(socket, &opts, &transfers) {
                    let _ = tx.send(Event::Accepted(accepted));
                }
                pending.fetch_sub(1, Ordering::Relaxed);
            });
        }
    });
    emit(json!({"event":"listening", "port":port}));
    let mut live: Option<Live> = None;
    let mut names = HashMap::<u16, String>::new();
    loop {
        while let Ok(event) = rx.try_recv() {
            match event {
                Event::Eof => {
                    end(&mut live, &mut desktop, "stdin closed");
                    return Ok(());
                }
                Event::Control(v) => match v["cmd"].as_str() {
                    Some("quit") => {
                        end(&mut live, &mut desktop, "quit");
                        return Ok(());
                    }
                    Some("kick") => end(&mut live, &mut desktop, "kicked"),
                    Some("peer") => {
                        if let (Some(port), Some(name)) = (
                            v["port"].as_u64().filter(|p| *p <= 65535),
                            v["name"].as_str(),
                        ) {
                            if names.len() >= 256 {
                                names.clear();
                            }
                            names.insert(
                                port as u16,
                                name.chars().filter(|c| !c.is_control()).take(100).collect(),
                            );
                        }
                    }
                    Some("yield") => {
                        if let Some(l) = &mut live {
                            l.gate.yielded(
                                v["by"].as_str().unwrap_or("").chars().take(100).collect(),
                                Instant::now(),
                            );
                        }
                    }
                    _ => {}
                },
                Event::Accepted(a) => {
                    let name = names.remove(&a.socket.peer_addr()?.port());
                    let reason =
                        name.map_or_else(|| "taken over".into(), |n| format!("taken over by {n}"));
                    end(&mut live, &mut desktop, &reason);
                    let now = Instant::now();
                    let inhibit = Command::new("systemd-inhibit")
                        .args([
                            "--what=idle:sleep",
                            "--mode=block",
                            "--who=rapp",
                            "--why=Remote desktop session",
                            "cat",
                        ])
                        .stdin(Stdio::piped())
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .spawn()
                        .ok();
                    let directory = std::env::var_os("RAPP_DOWNLOADS")
                        .filter(|p| !p.is_empty())
                        .map(std::path::PathBuf::from)
                        .unwrap_or_else(|| rapp_net::config::home().join("files/transfers"));
                    let session_transfers = Arc::new(Transfers::new(directory));
                    *transfers.lock().unwrap() = Some(Arc::downgrade(&session_transfers));
                    let windows = wire::window_table(&desktop.windows()?);
                    let mut l = Live {
                        socket: a.socket,
                        settings: a.settings,
                        view: None,
                        transfers: session_transfers,
                        clipboard: Clipboard::start_for_application(clipboard_app.as_deref()).ok(),
                        accessibility: crate::accessibility::Accessibility::start()?,
                        input_sources: crate::input_source::InputSources::start(),
                        target: Value::Null,
                        secure: false,
                        outbox: crate::pause::Outbox::new(windows.clone()),
                        epoch: next_epoch(),
                        unchanged: 0,
                        pending: vec![],
                        next_frame: now,
                        active_after: now,
                        clock: now,
                        pacing: Default::default(),
                        saving: 0,
                        gate: Default::default(),
                        locked: None,
                        next_lock_check: now,
                        next_windows: now,
                        cover: None,
                        last_opening_input: None,
                        covered_buttons: HashSet::new(),
                        _inhibit: inhibit,
                    };
                    let start = (|| {
                        l.send(&wire::ready(&title, display.width, display.height))?;
                        l.send(&windows)?;
                        l.send(&packet(33, vec![0]))
                    })();
                    if start.is_ok() {
                        emit(json!({"event":"session", "state":"started"}));
                        live = Some(l);
                    }
                }
            }
        }
        let completed = capture.completed();
        if let Some(l) = &mut live {
            let result = (|| -> Result<()> {
                if Instant::now() >= l.next_lock_check {
                    refresh_lock(l, &mut desktop)?;
                }
                if let Some(done) = completed.filter(|done| done.epoch == l.epoch) {
                    if done.frame.is_err() {
                        refresh_lock(l, &mut desktop)?;
                    }
                    let frame = if l.locked == Some(true) {
                        None
                    } else {
                        done.frame?
                    };
                    if done.probe {
                        // Paused: watch about once a second; resumed meanwhile: capture now.
                        if done.changed && l.locked != Some(true) {
                            if let Some(p) = l.outbox.changed(l.clock.elapsed().as_secs_f64()) {
                                l.send(&p)?;
                            }
                        }
                        l.next_frame = Instant::now()
                            + if l.outbox.paused() {
                                Duration::from_secs(1)
                            } else {
                                Duration::ZERO
                            };
                    } else {
                        if let Some(frame) = frame {
                            // Also while paused: it was encoded, so the client must get it.
                            l.send(&frame)?;
                            l.pacing.sent(l.clock.elapsed().as_secs_f64());
                            l.unchanged = 0;
                        } else {
                            l.unchanged = l.unchanged.saturating_add(1);
                        }
                        l.active_after = Instant::now()
                            + capture::rest(l.pacing.effective(l.settings).fps, done.elapsed, 0);
                        l.next_frame = Instant::now()
                            + capture::rest(
                                l.pacing.effective(l.settings).fps,
                                done.elapsed,
                                l.unchanged,
                            );
                    }
                }
                for input in l.read()? {
                    handle(l, &mut desktop, input)?;
                }
                while let Some(copy) = l.clipboard.as_ref().and_then(Clipboard::next) {
                    if l.locked != Some(true) && desktop.target_active() {
                        if let Ok(packet) = l.transfers.remember(copy) {
                            l.send(&packet)?;
                        }
                    }
                }
                let now = Instant::now();
                if now >= l.next_windows {
                    let windows = wire::window_table(&desktop.windows()?);
                    if let Some(p) = l.outbox.windows(windows, l.clock.elapsed().as_secs_f64()) {
                        l.send(&p)?;
                    }
                    let target = if l.locked == Some(true) {
                        Value::Null
                    } else {
                        desktop.focus_target()
                    };
                    if target != l.target {
                        let sent = l
                            .accessibility
                            .send(&json!({"cmd":"target","target":target}));
                        l.target = target;
                        // Optional accessibility must not interrupt picture/input if
                        // an application's accessibility bus has stopped responding.
                        if sent.is_err() {
                            metadata(l, &json!({"target":l.target}))?;
                        }
                    }
                    if l.last_opening_input
                        .is_some_and(|at| now.duration_since(at) <= Duration::from_secs(2))
                    {
                        if let Some((id, name)) = desktop.opened_application() {
                            let mut p = vec![];
                            rapp_client_core::protocol::string(&mut p, &id);
                            rapp_client_core::protocol::string(&mut p, &name);
                            l.send(&packet(39, p))?;
                            l.last_opening_input = None;
                        }
                    }
                    l.next_windows = now + Duration::from_millis(100);
                }
                while let Some(value) = l.accessibility.next() {
                    if value["target"] == l.target {
                        metadata(l, &value)?;
                    }
                }
                while let Some(source) = l.input_sources.next() {
                    match source {
                        Ok(source) => {
                            if let (Desktop::Wayland(backend), Some(rules)) =
                                (&mut desktop, &source.keyboard)
                            {
                                backend.update_keyboard(rules)?;
                            }
                            let mut p = vec![];
                            rapp_client_core::protocol::string(&mut p, &source.id);
                            rapp_client_core::protocol::string(&mut p, &source.name);
                            p.push(source.ascii as u8);
                            l.send(&packet(29, p))?;
                        }
                        Err(error) => {
                            l.send(&wire::text_packet(26, &error.to_string()))?;
                        }
                    }
                }
                if l.gate.tick(now) {
                    emit(json!({"event":"input"}));
                }
                let elapsed = l.clock.elapsed().as_secs_f64();
                // Paused: an idle link with a stale slow RTT is not a slow network.
                if !l.outbox.paused() {
                    l.pacing.observe(elapsed, false, l.settings);
                }
                update_saving(l)?;
                ensure!(
                    l.pacing.oldest_age(elapsed) < 15.,
                    "client stopped acknowledging frames"
                );
                let settings = l.pacing.effective(l.settings);
                let paused = l.outbox.paused();
                if l.locked != Some(true)
                    && now >= l.next_frame
                    && (paused || l.pacing.ready(elapsed, settings.fps))
                {
                    capture.submit(Job {
                        epoch: l.epoch,
                        settings,
                        view: l.view,
                        probe: paused,
                    })?;
                }
                Ok(())
            })();
            if let Err(error) = result {
                end(&mut live, &mut desktop, &format!("{error:#}"));
            }
        }
        std::thread::sleep(Duration::from_millis(4));
    }
}
fn update_saving(l: &mut Live) -> Result<()> {
    if l.saving != l.pacing.level {
        l.saving = l.pacing.level;
        l.epoch = next_epoch();
        l.next_frame = Instant::now();
        l.send(&packet(33, vec![l.saving]))?;
    }
    Ok(())
}
fn refresh_lock(l: &mut Live, desktop: &mut Desktop) -> Result<()> {
    let verified = desktop.lock_state()?;
    let current = verified.or_else(locked);
    if current != l.locked {
        l.locked = current;
        l.epoch = next_epoch();
        l.next_frame = Instant::now();
        if let Some(value) = current {
            desktop.release();
            l.send(&packet(34, vec![value as u8]))?;
        }
    }
    l.next_lock_check = Instant::now()
        + if verified.is_some() {
            Duration::from_millis(250)
        } else {
            Duration::from_secs(2)
        };
    Ok(())
}
fn handle(l: &mut Live, desktop: &mut Desktop, input: Input) -> Result<()> {
    match input {
        Input::Ping(seq) => return l.send(&id_packet(32, seq)),
        Input::Ack(ms) => {
            l.pacing
                .ack(l.clock.elapsed().as_secs_f64(), ms, l.settings);
            return update_saving(l);
        }
        Input::Stream(mut s) => {
            // fps 0 pauses (v15) and keeps the rate it had: pacing and saving never see 0.
            let pause = s.fps == 0;
            if pause {
                s.fps = l.settings.fps;
            }
            if l.settings.mode != s.mode || l.settings.density != s.density {
                l.epoch = next_epoch();
            }
            l.settings = s;
            l.pacing.set_paused(pause, l.clock.elapsed().as_secs_f64());
            l.pacing.configure(s);
            update_saving(l)?;
            let _ = l
                .accessibility
                .send(&json!({"cmd":"target","target":l.target}));
            // Resume: what was held goes before the picture, which is captured at once.
            for p in l.outbox.set_paused(pause, l.clock.elapsed().as_secs_f64()) {
                l.send(&p)?;
            }
            if !pause {
                l.next_windows = Instant::now();
            }
            l.unchanged = 0;
            l.next_frame = Instant::now();
            return Ok(());
        }
        Input::View(view) => {
            if l.view != view {
                l.view = view;
                l.epoch = next_epoch();
                l.unchanged = 0;
                l.next_frame = Instant::now();
            }
            return Ok(());
        }
        _ => {}
    }
    let decision = l.gate.admit(&input, Instant::now());
    if let Some(by) = decision.notice {
        l.send(&wire::text_packet(26, &by))?;
        emit(json!({"event":"input_blocked", "by":by}));
    }
    if !decision.pass {
        if let Input::Paste(seq, _) = input {
            l.send(&wire::pasted(
                seq,
                "another device is controlling the desktop",
            ))?;
        }
        return Ok(());
    }
    if decision.report {
        emit(json!({"event":"input"}));
    }
    l.unchanged = 0;
    l.next_frame = l.next_frame.min(Instant::now().max(l.active_after));
    match input {
        Input::Key(k, m, d) => {
            desktop.activate()?;
            desktop.key(k, m, d)?;
            if d {
                l.last_opening_input = Some(Instant::now());
            }
        }
        Input::Mouse(k, b, id, x, y) => {
            if k == 1 && l.covered_buttons.remove(&b) || k == 2 && l.covered_buttons.contains(&b) {
                return Ok(());
            }
            if let Ok((x, y)) = desktop.canvas_point(id, x, y) {
                if k == 0 {
                    desktop.focus_window(id)?;
                    desktop.activate()?;
                    if covered(l, desktop, x, y)? {
                        l.covered_buttons.insert(b);
                        return Ok(());
                    }
                    l.covered_buttons.remove(&b);
                }
                desktop.mouse(k, b, x, y)?;
                if k <= 1 {
                    l.last_opening_input = Some(Instant::now());
                }
            }
        }
        Input::Scroll(id, x, y, dx, dy) => {
            if let Ok((x, y)) = desktop.canvas_point(id, x, y) {
                desktop.focus_window(id)?;
                desktop.activate()?;
                if covered(l, desktop, x, y)? {
                    return Ok(());
                }
                desktop.scroll(x, y, dx, dy)?;
            }
        }
        Input::Resize(id, w, h) => desktop.resize_window(id, w, h)?,
        Input::Move(id, x, y) => desktop.move_window(id, x, y)?,
        Input::Focus(id) => desktop.focus_window(id)?,
        Input::Close(id) => desktop.close_window(id)?,
        Input::Dismiss(id) => {
            if let Some(cover) = l.cover.as_ref().filter(|c| c.id == id) {
                desktop.dismiss_cover(cover)?;
                l.cover = None;
            }
        }
        Input::Menu(path) => {
            desktop.activate()?;
            l.accessibility
                .send(&json!({"cmd":"menu","target":l.target,"path":path}))?;
        }
        Input::SelectInput(id) => l.input_sources.select(id)?,
        Input::Text(text) => {
            ensure!(
                desktop.lock_state()?.or_else(locked) != Some(true),
                "screen locked"
            );
            desktop.activate()?;
            desktop.text(&text)?;
            l.last_opening_input = Some(Instant::now());
        }
        Input::Paste(seq, source) => {
            let result = (|| -> Result<()> {
                ensure!(
                    desktop.lock_state()?.or_else(locked) != Some(true),
                    "screen locked"
                );
                desktop.activate()?;
                let copy = match source {
                    wire::Paste::Text(text) => rapp_client_core::transfer::Copy::Text(text),
                    wire::Paste::Item(id) => l.transfers.received(id)?,
                };
                l.clipboard
                    .as_ref()
                    .context("clipboard is unavailable on this desktop")?
                    .set(&copy)?;
                desktop.release();
                desktop.key(9, 1 << 20, true)?;
                desktop.key(9, 1 << 20, false)?;
                desktop.release();
                Ok(())
            })();
            l.send(&wire::pasted(
                seq,
                &result.err().map(|e| e.to_string()).unwrap_or_default(),
            ))?;
        }
        // Do not type a password based on logind's hint: it does not prove focus is a lock field.
        Input::Unlock(password) => {
            let result = (|| -> Result<()> {
                if desktop.lock_state()? == Some(true) {
                    desktop.unlock(password.as_str())?;
                } else {
                    ensure!(
                        l.locked != Some(true),
                        "this desktop does not expose verified remote password entry"
                    );
                }
                Ok(())
            })();
            l.next_lock_check = Instant::now();
            if let Some(message) = unlock_failure(result) {
                // v15 text feedback: older clients can still consume this packet.
                // A refused unlock is recoverable and must not close the session.
                l.send(&wire::text_packet(26, &message))?;
            }
        }
        Input::StateRules => {
            static LOGGED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
            if !LOGGED.swap(true, std::sync::atomic::Ordering::Relaxed) {
                eprintln!("state rules: not supported on this host");
            }
        }
        _ => {}
    }
    Ok(())
}
fn unlock_failure(result: Result<()>) -> Option<String> {
    result.err().map(|error| {
        let reason = error.to_string();
        emit(json!({"event":"unlock", "reason":reason}));
        format!("unlock-failed: {reason}")
    })
}

fn metadata(l: &mut Live, value: &Value) -> Result<()> {
    let secure = value["secure"] == true;
    if l.secure != secure {
        l.send(&packet(40, vec![secure as u8]))?;
        l.secure = secure;
    }
    fn menus(items: &Value, output: &mut Vec<u8>) {
        let items = items.as_array().map(Vec::as_slice).unwrap_or_default();
        output.extend((items.len() as u16).to_le_bytes());
        for item in items {
            rapp_client_core::protocol::string(output, item["title"].as_str().unwrap_or(""));
            output.push(item["flags"].as_u64().unwrap_or(0) as u8);
            rapp_client_core::protocol::string(output, item["key"].as_str().unwrap_or(""));
            output.push(item["modifiers"].as_u64().unwrap_or(0) as u8);
            menus(&item["children"], output);
        }
    }
    let mut menu = vec![];
    menus(&value["menus"], &mut menu);
    if let Some(p) = l.outbox.menus(packet(17, menu)) {
        l.send(&p)?;
    }
    let window = value["target"]["window"].as_u64().unwrap_or(0) as u32;
    let rects = value["rects"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default();
    let rects = if l.settings.focus && !secure {
        rects
    } else {
        &[]
    };
    let mut focus = window.to_le_bytes().to_vec();
    focus.push(rects.len().min(3) as u8);
    for rect in rects.iter().take(3) {
        let x = rect["x"].as_f64().unwrap_or(0.) + l.target["x"].as_f64().unwrap_or(0.);
        let y = rect["y"].as_f64().unwrap_or(0.) + l.target["y"].as_f64().unwrap_or(0.);
        for f in [
            x,
            y,
            rect["w"].as_f64().unwrap_or(1.),
            rect["h"].as_f64().unwrap_or(1.),
        ] {
            focus.extend((f as f32).to_le_bytes());
        }
    }
    if let Some(p) = l.outbox.focus(packet(36, focus)) {
        l.send(&p)?;
    }
    Ok(())
}
fn covered(l: &mut Live, desktop: &Desktop, x: f32, y: f32) -> Result<bool> {
    if let Some(cover) = desktop.pointer_cover(x, y)? {
        let mut bytes = cover.id.to_le_bytes().to_vec();
        rapp_client_core::protocol::string(&mut bytes, &cover.name);
        rapp_client_core::protocol::string(&mut bytes, &cover.app_id());
        bytes.push(cover.dismissable() as u8);
        l.send(&packet(37, bytes))?;
        l.cover = Some(cover);
        return Ok(true);
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unlock_refusal_is_recoverable_v15_feedback() {
        assert!(unlock_failure(Ok(())).is_none());
        let message = unlock_failure(Err(anyhow::anyhow!("no verified lock screen"))).unwrap();
        let packet = wire::text_packet(26, &message);
        assert_eq!(packet[0], 26);
        assert_eq!(message, "unlock-failed: no verified lock screen");
    }
    #[test]
    fn helper_timeout_and_argument_boundaries() {
        let text = b"quotes ' and $HOME; $(touch nope)\n\xe4\xb8\xad\xe6\x96\x87";
        assert_eq!(command("cat", &[], Some(text)).unwrap(), text);
        assert!(command("false", &[], None).is_err());
    }
}
