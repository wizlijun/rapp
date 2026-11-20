//! Clipboard observation starts with an authenticated session, never at worker startup.
mod wayland;
mod x11;
use anyhow::{ensure, Context, Result};
use gdk::{gio, prelude::*};
use rapp_client_core::transfer::Copy;
use std::{
    io::{Read, Write},
    process::{Child, ChildStdin, Command as Process, Stdio},
    sync::{mpsc, Arc, Mutex},
    time::{Duration, Instant},
};

const LIMIT: usize = 64 * 1024 * 1024;
type Data = Vec<(String, Vec<u8>)>;
enum Command {
    Set(Data, mpsc::SyncSender<Result<()>>),
}
pub struct Clipboard {
    child: Child,
    input: Mutex<Option<ChildStdin>>,
    events: mpsc::Receiver<Copy>,
    replies: mpsc::Receiver<Result<()>>,
}
impl Clipboard {
    pub fn start() -> Result<Self> {
        Self::start_with_executable(&std::env::current_exe()?)
    }
    pub fn start_for_application(app: Option<&str>) -> Result<Self> {
        Self::spawn(&std::env::current_exe()?, app)
    }
    /// The bundled worker is passed explicitly by isolated native tests.
    pub fn start_with_executable(executable: &std::path::Path) -> Result<Self> {
        Self::spawn(executable, None)
    }
    fn spawn(executable: &std::path::Path, app: Option<&str>) -> Result<Self> {
        let mut command = Process::new(executable);
        command.arg("--internal-clipboard");
        if let Some(app) = app {
            command.arg(app);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(
                if std::env::var_os("RAPP_TEST_ISOLATED_DESKTOP").is_some() {
                    Stdio::inherit()
                } else {
                    Stdio::null()
                },
            )
            .spawn()?;
        let input = child.stdin.take().unwrap();
        use std::os::fd::AsRawFd;
        let flags = unsafe { libc::fcntl(input.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(input.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::last_os_error().into());
        }
        let input = Mutex::new(Some(input));
        let mut output = child.stdout.take().unwrap();
        let (tx, events) = mpsc::sync_channel(16);
        let (reply, replies) = mpsc::sync_channel(1);
        let (ready, initialized) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            while let Ok((kind, bytes)) = read_ipc(&mut output) {
                match kind {
                    0 => {
                        let _ = ready.try_send(());
                    }
                    1 => {
                        if let Ok(data) = unpack(&bytes) {
                            let types: Vec<_> = data.iter().map(|(k, _)| k.clone()).collect();
                            if let Some(kind) = preferred(&types) {
                                if let Some((_, bytes)) = data.iter().find(|(k, _)| k == kind) {
                                    if let Ok(copy) = decode(kind, bytes.clone()) {
                                        let _ = tx.try_send(copy);
                                    }
                                }
                            }
                        }
                    }
                    2 => {
                        let _ = reply.try_send(if bytes.is_empty() {
                            Ok(())
                        } else {
                            Err(anyhow::anyhow!(String::from_utf8_lossy(&bytes).into_owned()))
                        });
                    }
                    _ => break,
                }
            }
        });
        if initialized.recv_timeout(Duration::from_secs(4)).is_err() {
            let _ = child.kill();
            let _ = child.wait();
            anyhow::bail!("clipboard backend did not initialize");
        }
        Ok(Self {
            child,
            input,
            events,
            replies,
        })
    }
    pub fn next(&self) -> Option<Copy> {
        self.events.try_recv().ok()
    }
    pub fn set(&self, copy: &Copy) -> Result<()> {
        let data = encode(copy)?;
        let bytes = pack(&data)?;
        drop(data);
        let mut input = self.input.lock().unwrap();
        let result = (|| -> Result<()> {
            let input = input.as_mut().context("clipboard unavailable")?;
            let end = Instant::now() + Duration::from_secs(4);
            let mut header = vec![1];
            header.extend((bytes.len() as u32).to_le_bytes());
            write_until(input, &header, end)?;
            write_until(input, &bytes, end)?;
            self.replies
                .recv_timeout(Duration::from_secs(4))
                .context("clipboard did not respond")?
        })();
        if result.is_err() {
            input.take();
        }
        result
    }
}
fn write_until(input: &mut ChildStdin, mut bytes: &[u8], end: Instant) -> Result<()> {
    use std::os::fd::AsRawFd;
    while !bytes.is_empty() {
        ensure!(Instant::now() < end, "clipboard write timed out");
        match input.write(bytes) {
            Ok(0) => anyhow::bail!("clipboard helper closed"),
            Ok(n) => bytes = &bytes[n..],
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                let mut fd = libc::pollfd {
                    fd: input.as_raw_fd(),
                    events: libc::POLLOUT,
                    revents: 0,
                };
                if unsafe { libc::poll(&mut fd, 1, 50) } < 0 {
                    let error = std::io::Error::last_os_error();
                    if error.kind() != std::io::ErrorKind::Interrupted {
                        return Err(error.into());
                    }
                }
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}
fn ready() -> Result<()> {
    let mut output = std::io::stdout();
    output.write_all(&rapp_client_core::protocol::packet(0, vec![]))?;
    output.flush()?;
    Ok(())
}
fn send(output: &Mutex<std::io::Stdout>, kind: u8, bytes: Vec<u8>) -> std::io::Result<()> {
    let mut output = output.lock().unwrap();
    output.write_all(&rapp_client_core::protocol::packet(kind, bytes))?;
    output.flush()
}
impl Drop for Clipboard {
    fn drop(&mut self) {
        self.input.get_mut().unwrap().take();
        let end = Instant::now() + Duration::from_millis(500);
        while Instant::now() < end {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
pub fn run_child() -> Result<()> {
    let scope = Scope::new(std::env::args().nth(2).as_deref())?;
    let (commands, rx) = mpsc::sync_channel(4);
    let (tx, events) = mpsc::sync_channel(16);
    let output = Arc::new(Mutex::new(std::io::stdout()));
    let replies = output.clone();
    std::thread::spawn(move || {
        let mut input = std::io::stdin();
        while let Ok((1, bytes)) = read_ipc(&mut input) {
            let Ok(data) = unpack(&bytes) else {
                break;
            };
            let (reply, response) = mpsc::sync_channel(1);
            if commands.send(Command::Set(data, reply)).is_err() {
                break;
            }
            let result = response
                .recv()
                .unwrap_or_else(|_| Err(anyhow::anyhow!("clipboard unavailable")));
            let bytes = result
                .err()
                .map(|e| e.to_string().into_bytes())
                .unwrap_or_default();
            if send(&replies, 2, bytes).is_err() {
                break;
            }
        }
    });
    std::thread::spawn(move || {
        for copy in events {
            if let Ok(bytes) = encode(&copy).and_then(|data| pack(&data)) {
                if send(&output, 1, bytes).is_err() {
                    break;
                }
            }
        }
    });
    if std::env::var_os("WAYLAND_DISPLAY").is_some_and(|s| !s.is_empty()) {
        wayland::run(rx, tx, scope)
    } else {
        // GTK/GDK initialization and its event loop stay on this helper's main thread.
        ensure!(
            unsafe { gtk4_sys::gtk_init_check() } != 0,
            "cannot initialize X11 clipboard"
        );
        x11::run(rx, tx, scope)
    }
}
struct Scope {
    desktop: Option<crate::desktop::Desktop>,
    was_active: bool,
    next: Instant,
}
impl Scope {
    fn new(app: Option<&str>) -> Result<Self> {
        let desktop = if let Some(app) = app {
            let mut d = crate::desktop::Desktop::connect()?;
            d.select_capture(app)?;
            Some(d)
        } else {
            None
        };
        let was_active = desktop.as_ref().is_none_or(|d| d.target_active());
        Ok(Self {
            desktop,
            was_active,
            next: Instant::now(),
        })
    }
    fn active(&self) -> bool {
        self.desktop.as_ref().is_none_or(|d| d.target_active())
    }
    fn allow_copy(&mut self) -> bool {
        let active = self.active();
        let allowed = active && self.was_active;
        self.was_active = active;
        allowed
    }
    fn poll(&mut self) {
        if Instant::now() >= self.next {
            self.was_active = self.active();
            self.next = Instant::now() + Duration::from_millis(100);
        }
    }
}
fn pack(data: &Data) -> Result<Vec<u8>> {
    ensure!(data.len() <= 128, "too many clipboard formats");
    let mut bytes = (data.len() as u16).to_le_bytes().to_vec();
    for (kind, value) in data {
        ensure!(
            kind.len() <= 65535 && value.len() <= 256 * 1024 * 1024,
            "clipboard too large"
        );
        rapp_client_core::protocol::string(&mut bytes, kind);
        bytes.extend((value.len() as u32).to_le_bytes());
        bytes.extend(value);
    }
    ensure!(bytes.len() <= 256 * 1024 * 1024, "clipboard too large");
    Ok(bytes)
}
fn unpack(bytes: &[u8]) -> Result<Data> {
    let mut r = rapp_client_core::protocol::Reader::new(bytes);
    let n = r.u16()?;
    ensure!(n <= 128, "too many clipboard formats");
    let mut data = vec![];
    for _ in 0..n {
        let kind = r.string()?;
        let n = r.u32()? as usize;
        data.push((kind, r.take(n)?.to_vec()));
    }
    r.end()?;
    Ok(data)
}
fn read_ipc(input: &mut impl Read) -> Result<(u8, Vec<u8>)> {
    let mut h = [0; 5];
    input.read_exact(&mut h)?;
    let n = u32::from_le_bytes(h[1..].try_into()?) as usize;
    ensure!(n <= 256 * 1024 * 1024, "clipboard too large");
    let mut b = vec![0; n];
    input.read_exact(&mut b)?;
    Ok((h[0], b))
}
fn mime(uti: &str) -> &str {
    match uti {
        "public.png" => "image/png",
        "public.tiff" => "image/tiff",
        "com.adobe.pdf" => "application/pdf",
        "public.html" => "text/html",
        "public.rtf" => "text/rtf",
        "public.utf8-plain-text" => "text/plain;charset=utf-8",
        v => v,
    }
}
fn uti(mime: &str) -> &str {
    match mime {
        "image/png" => "public.png",
        "image/tiff" => "public.tiff",
        "application/pdf" => "com.adobe.pdf",
        "text/html" => "public.html",
        "text/rtf" => "public.rtf",
        v => v,
    }
}
fn concealed(types: &[String]) -> bool {
    types.iter().any(|t| {
        matches!(
            t.as_str(),
            "x-kde-passwordManagerHint"
                | "application/x-keepassxc"
                | "org.nspasteboard.ConcealedType"
        )
    })
}
fn preferred(types: &[String]) -> Option<&str> {
    if concealed(types) {
        return None;
    }
    for preferred in [
        "text/uri-list",
        "image/png",
        "text/plain;charset=utf-8",
        "UTF8_STRING",
        "text/plain",
    ] {
        if let Some(t) = types.iter().find(|s| s.as_str() == preferred) {
            return Some(t);
        }
    }
    types
        .iter()
        .find(|s| s.contains('/') && !s.starts_with("application/x-rapp-"))
        .map(String::as_str)
}
fn decode(kind: &str, bytes: Vec<u8>) -> Result<Copy> {
    ensure!(bytes.len() <= LIMIT, "clipboard exceeds 64 MB");
    Ok(match kind {
        "text/uri-list" => {
            let text = std::str::from_utf8(&bytes)?;
            let paths = text
                .lines()
                .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
                .map(|url| {
                    gio::File::for_uri(url.trim())
                        .path()
                        .context("clipboard contains a nonlocal file")
                })
                .collect::<Result<Vec<_>>>()?;
            ensure!(
                paths.len() <= 100 && paths.iter().all(|p| p.is_file()),
                "clipboard files unavailable"
            );
            Copy::Files(paths)
        }
        "image/png" => Copy::Image(bytes),
        "text/plain;charset=utf-8" | "UTF8_STRING" | "text/plain" => {
            Copy::Text(String::from_utf8(bytes)?)
        }
        kind => Copy::Data(uti(kind).into(), bytes),
    })
}
fn encode(copy: &Copy) -> Result<Data> {
    let size = match copy {
        Copy::Text(t) => t.len(),
        Copy::Image(b) | Copy::Data(_, b) => b.len(),
        Copy::Files(_) => 0,
    };
    ensure!(
        size <= LIMIT,
        "clipboard paste exceeds 64 MB; transfer it as a file instead"
    );
    Ok(match copy {
        Copy::Text(t) => vec![
            ("text/plain;charset=utf-8".into(), t.as_bytes().to_vec()),
            ("text/plain".into(), t.as_bytes().to_vec()),
            ("UTF8_STRING".into(), t.as_bytes().to_vec()),
        ],
        Copy::Image(bytes) => {
            ensure!(bytes.starts_with(b"\x89PNG\r\n\x1a\n"), "invalid PNG");
            vec![("image/png".into(), bytes.clone())]
        }
        Copy::Data(u, bytes) => {
            ensure!(!u.is_empty() && !u.contains('\0'), "invalid clipboard type");
            vec![(mime(u).into(), bytes.clone())]
        }
        Copy::Files(paths) => {
            ensure!(
                !paths.is_empty() && paths.len() <= 100 && paths.iter().all(|p| p.is_file()),
                "files unavailable"
            );
            let uris = paths
                .iter()
                .map(|p| gio::File::for_path(p).uri().to_string())
                .collect::<Vec<_>>()
                .join("\r\n")
                + "\r\n";
            vec![("text/uri-list".into(), uris.into_bytes())]
        }
    })
}
