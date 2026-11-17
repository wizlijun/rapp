use crate::{
    desktop::Desktop,
    encode::Encoder,
    wire::{self, Input, Settings},
};
use anyhow::{bail, ensure, Context, Result};
use rapp_client_core::protocol::{id_packet, packet};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    io::{BufRead, Read, Seek, SeekFrom, Write},
    net::{Shutdown, TcpListener, TcpStream},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc, Arc,
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
    encoder: Encoder,
    pending: Vec<u8>,
    next_frame: Instant,
    awaiting: Option<Instant>,
    gate: crate::gate::Gate,
    locked: Option<bool>,
    next_lock_check: Instant,
    _inhibit: Option<std::process::Child>,
}
impl Drop for Live {
    fn drop(&mut self) {
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
            messages.push(wire::input(
                self.pending[offset],
                &self.pending[offset + 5..offset + 5 + n],
            )?);
            offset += 5 + n;
        }
        self.pending.drain(..offset);
        Ok(messages)
    }
}
fn handshake(mut s: TcpStream, opts: &Options) -> Result<Authenticated> {
    s.set_read_timeout(Some(Duration::from_secs(5)))?;
    s.set_write_timeout(Some(Duration::from_secs(3)))?;
    s.set_nodelay(true)?;
    let mut header = [0; 5];
    s.read_exact(&mut header)?;
    let n = u32::from_le_bytes(header[1..].try_into().unwrap()) as usize;
    if header[0] != 1 || n > 131100 {
        let message = "first message must be a desktop hello; Linux clipboard file transfers are not supported";
        let _ = s.write_all(&wire::text_packet(3, message));
        bail!(message);
    }
    let mut data = vec![0; n];
    s.read_exact(&mut data)?;
    match wire::hello(&data, &opts.token, &opts.app) {
        Ok(settings) => Ok(Authenticated {
            socket: s,
            settings,
        }),
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
    let title = format!("桌面 · {}", display.name);
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
    let opts = Arc::new(opts);
    std::thread::spawn(move || {
        let pending = Arc::new(AtomicUsize::new(0));
        for socket in listener.incoming().flatten() {
            if pending.load(Ordering::Relaxed) >= 8 {
                continue;
            }
            pending.fetch_add(1, Ordering::Relaxed);
            let (opts, tx, pending) = (opts.clone(), tx.clone(), pending.clone());
            std::thread::spawn(move || {
                if let Ok(accepted) = handshake(socket, &opts) {
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
                    let mut l = Live {
                        socket: a.socket,
                        settings: a.settings,
                        encoder: Encoder::default(),
                        pending: vec![],
                        next_frame: now,
                        awaiting: None,
                        gate: Default::default(),
                        locked: None,
                        next_lock_check: now,
                        _inhibit: inhibit,
                    };
                    let start = (|| {
                        l.send(&wire::ready(&title, display.width, display.height))?;
                        l.send(&wire::windows(&title, display.width, display.height))?;
                        l.send(&packet(33, vec![0]))
                    })();
                    if start.is_ok() {
                        emit(json!({"event":"session", "state":"started"}));
                        live = Some(l);
                    }
                }
            }
        }
        if let Some(l) = &mut live {
            let result = (|| -> Result<()> {
                for input in l.read()? {
                    handle(l, &mut desktop, input)?;
                }
                let now = Instant::now();
                if l.gate.tick(now) {
                    emit(json!({"event":"input"}));
                }
                if now >= l.next_lock_check {
                    let current = locked();
                    if current != l.locked {
                        l.locked = current;
                        if let Some(value) = current {
                            l.send(&packet(34, vec![value as u8]))?;
                        }
                    }
                    l.next_lock_check = Instant::now() + Duration::from_secs(2);
                }
                if let Some(since) = l.awaiting {
                    ensure!(
                        since.elapsed() < Duration::from_secs(15),
                        "client stopped acknowledging frames"
                    );
                }
                if now >= l.next_frame && l.awaiting.is_none() {
                    let image = desktop.capture()?.scaled(&display, l.settings.density);
                    if let Some(frame) = l.encoder.frame(
                        &image.pixels,
                        image.width,
                        image.height,
                        (display.width, display.height),
                        l.settings.mode,
                    )? {
                        l.send(&frame)?;
                        l.awaiting = Some(Instant::now());
                    }
                    l.next_frame = now + Duration::from_secs_f32(1. / l.settings.fps as f32);
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
fn handle(l: &mut Live, desktop: &mut Desktop, input: Input) -> Result<()> {
    match input {
        Input::Ping(seq) => return l.send(&id_packet(32, seq)),
        Input::Ack => {
            l.awaiting = None;
            return Ok(());
        }
        Input::Stream(s) => {
            if l.settings.mode != s.mode || l.settings.density != s.density {
                l.encoder.reset();
            }
            l.settings = s;
            return Ok(());
        }
        Input::Ignore => return Ok(()),
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
    match input {
        Input::Key(k, m, d) => desktop.key(k, m, d)?,
        Input::Mouse(k, b, x, y) => desktop.mouse(k, b, x, y)?,
        Input::Scroll(x, y, dx, dy) => desktop.scroll(x, y, dx, dy)?,
        Input::Text(text) => { ensure!(l.locked != Some(true), "desktop is locked; unlock locally before sending text"); desktop.text(&text)?; }
        Input::Paste(seq, text) => {
            let result = if l.locked == Some(true) { Err(anyhow::anyhow!("desktop is locked; unlock locally before sending text")) }
                else if let Some(text) = text { desktop.text(&text) }
                else { Err(anyhow::anyhow!("Linux host currently supports text insertion only; file and image uploads are unavailable")) };
            l.send(&wire::pasted(seq, &result.err().map(|e| e.to_string()).unwrap_or_default()))?;
        }
        // Do not type a password based on logind's hint: it does not prove focus is a lock field.
        Input::Unlock => bail!("automatic password entry is not supported by the Linux host; unlock the desktop locally"),
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn helper_timeout_and_argument_boundaries() {
        let text = b"quotes ' and $HOME; $(touch nope)\n\xe4\xb8\xad\xe6\x96\x87";
        assert_eq!(command("cat", &[], Some(text)).unwrap(), text);
        assert!(command("false", &[], None).is_err());
    }
}
