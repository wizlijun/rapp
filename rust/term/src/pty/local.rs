//! The local protocol between `rapp-term run`, which holds a pty in a terminal window, and `rapp-term serve`, which
//! reaches it over a unix socket `pty/<pid>.sock`. A client writes a request line `{"op":…,"v":2}` (`rename` adds
//! `"name"`) and then a line holding the token. A run of version 1 answers `status` and `view` whatever version the
//! request names, and `rename` as an unsupported op. The token only keeps other local users out (the directory is 0700, the token 0600).

use crate::wire::{Got, Lines, MAX_IN_LINE};
use anyhow::{anyhow, bail, Context};
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

/// The version of this protocol.
pub const LOCAL_V: u32 = 2;
/// How long a client has to send its request line and token.
const HEAD_WAIT: Duration = Duration::from_secs(5);
/// How long `status` waits for a reply before calling the socket busy.
const STATUS_WAIT: Duration = Duration::from_millis(500);
/// macOS limits a unix socket path to 104 bytes, the terminating NUL included.
const SOCKET_PATH_MAX: usize = 104;

/// `$ROOT/local/term`.
pub fn default_dir() -> PathBuf {
    rapp_net::config::local(&rapp_net::config::home()).join("term")
}

/// Creates `term/`, `pty/` and `launch/`, all 0700 (also when they exist already).
pub fn ensure_dirs(term_dir: &Path) -> anyhow::Result<()> {
    for d in [term_dir.to_path_buf(), term_dir.join("pty"), term_dir.join("launch"), term_dir.join("ended")] {
        std::fs::create_dir_all(&d).with_context(|| format!("cannot create {}", d.display()))?;
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("cannot protect {}", d.display()))?;
    }
    Ok(())
}

/// The length of a token: 16 random bytes in hex.
const TOKEN_LEN: usize = 32;
/// An empty or short token file this old was left by a crash between its creation and its write.
const TOKEN_BROKEN_AFTER: Duration = Duration::from_secs(1);

/// The token in `pty.token`; made (32 hex characters, 0600) when there is none yet, or when the file is broken.
pub fn token(term_dir: &Path) -> anyhow::Result<String> {
    let path = term_dir.join("pty.token");
    for _ in 0..20 {
        match std::fs::read_to_string(&path) {
            Ok(s) if s.trim().len() >= TOKEN_LEN => return Ok(s.trim().to_string()),
            // Empty or short: someone is writing it right now, or it is broken and made again. Nothing: make it.
            Ok(_) if broken_token(&path) => match std::fs::remove_file(&path) {
                Ok(()) => continue,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e).with_context(|| format!("cannot remove {}", path.display())),
            },
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let mut raw = [0u8; 16];
                std::fs::File::open("/dev/urandom")?.read_exact(&mut raw)?;
                let hex: String = raw.iter().map(|b| format!("{b:02x}")).collect();
                match std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path) {
                    Ok(mut f) => {
                        std::io::Write::write_all(&mut f, hex.as_bytes())?;
                        return Ok(hex);
                    }
                    // Someone else got there first: read theirs.
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(e) => return Err(e).with_context(|| format!("cannot write {}", path.display())),
                }
            }
            Err(e) => return Err(e).with_context(|| format!("cannot read {}", path.display())),
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    bail!("the token file stays empty: {}", path.display())
}

/// The token file was last written long enough ago that nobody is writing it now.
fn broken_token(path: &Path) -> bool {
    let Ok(at) = std::fs::metadata(path).and_then(|m| m.modified()) else { return false };
    std::time::SystemTime::now().duration_since(at).is_ok_and(|age| age > TOKEN_BROKEN_AFTER)
}

/// `pty/<pid>.sock`, which must fit a unix socket address.
pub fn socket_path(term_dir: &Path, pid: u32) -> anyhow::Result<PathBuf> {
    let p = term_dir.join("pty").join(format!("{pid}.sock"));
    if p.as_os_str().len() >= SOCKET_PATH_MAX {
        return Err(anyhow!("the socket path is too long: {}", p.display()));
    }
    Ok(p)
}

/// What a `status` request answers.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Status {
    pub v: u32,
    pub name: String,
    pub command: String,
    pub cols: u16,
    pub rows: u16,
    /// The Unix second of the last output.
    pub activity: u64,
    pub viewers: u32,
    pub pid: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ticket: Option<String>,
    /// The session's stable key: 16 lowercase hex characters made at start. A run of version 1 sends none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// What the program says about itself; none when it says nothing.
    #[serde(default, deserialize_with = "super::ps::lenient", skip_serializing_if = "Option::is_none")]
    pub ps: Option<super::ps::Ps>,
    /// The title the program set for itself; none when it set none or the session was named by hand.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// The foreground program's name (argv[0]'s file name).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fg: Option<String>,
    /// The foreground program's current directory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Whether the program the holder started is the foreground one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shell: Option<bool>,
    /// The holder's window tty, like `/dev/ttys012`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tty: Option<String>,
}

/// Why a socket gave no status.
#[derive(Debug, PartialEq)]
pub enum Probe {
    /// Nobody listens: a leftover socket file.
    Gone,
    /// Connected but no reply in time.
    Busy,
    /// An error reply, or one that is no status.
    Refused(String),
}

/// Connects to `path` and writes the request head for `op`.
pub async fn connect(path: &Path, op: &str, token: &str) -> std::io::Result<UnixStream> {
    let mut s = UnixStream::connect(path).await?;
    send_head(&mut s, op, token).await?;
    Ok(s)
}

async fn send_head(s: &mut UnixStream, op: &str, token: &str) -> std::io::Result<()> {
    send_head_with(s, serde_json::json!({ "op": op, "v": LOCAL_V }), token).await
}

async fn send_head_with(s: &mut UnixStream, req: serde_json::Value, token: &str) -> std::io::Result<()> {
    s.write_all(format!("{req}\n{token}\n").as_bytes()).await
}

/// 16 lowercase hex characters nobody could have guessed: a random hash seed mixed with the clock.
pub fn new_key() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos()));
    format!("{:016x}", h.finish())
}

/// Whether a failed connect means nobody listens. Any other error (too many files, a full backlog, no access)
/// says nothing about the process behind the socket, so its file must stay.
pub fn gone(e: &std::io::Error) -> bool {
    matches!(e.kind(), std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound)
}

/// Asks the socket at `path` for its status.
pub async fn status(path: &Path, token: &str) -> Result<Status, Probe> {
    let ask = async {
        let mut s = UnixStream::connect(path).await.map_err(|e| if gone(&e) { Probe::Gone } else { Probe::Busy })?;
        send_head(&mut s, "status", token).await.map_err(|_| Probe::Busy)?;
        let got = Lines::new(BufReader::new(s), MAX_IN_LINE).next().await;
        let Ok(Got::Line(line)) = got else {
            return Err(Probe::Refused("bad status".into()));
        };
        let v: serde_json::Value = serde_json::from_slice(&line).map_err(|_| Probe::Refused("bad status".into()))?;
        if let Some(e) = v.get("error") {
            return Err(Probe::Refused(e.as_str().unwrap_or("error").to_string()));
        }
        serde_json::from_value(v).map_err(|_| Probe::Refused("bad status".into()))
    };
    tokio::time::timeout(STATUS_WAIT, ask).await.unwrap_or(Err(Probe::Busy))
}

/// Asks the run at `path` to be called `name`. A run of version 1 refuses with `unsupported`.
pub async fn rename(path: &Path, token: &str, name: &str) -> Result<(), Probe> {
    let ask = async {
        let mut s = UnixStream::connect(path).await.map_err(|e| if gone(&e) { Probe::Gone } else { Probe::Busy })?;
        let req = serde_json::json!({ "op": "rename", "v": LOCAL_V, "name": name });
        send_head_with(&mut s, req, token).await.map_err(|_| Probe::Busy)?;
        let got = Lines::new(BufReader::new(s), MAX_IN_LINE).next().await;
        let Ok(Got::Line(line)) = got else {
            return Err(Probe::Refused("bad reply".into()));
        };
        let v: serde_json::Value = serde_json::from_slice(&line).map_err(|_| Probe::Refused("bad reply".into()))?;
        match (v.get("ok"), v.get("error")) {
            (Some(serde_json::Value::Bool(true)), _) => Ok(()),
            (_, Some(e)) => Err(Probe::Refused(e.as_str().unwrap_or("error").to_string())),
            _ => Err(Probe::Refused("bad reply".into())),
        }
    };
    tokio::time::timeout(STATUS_WAIT, ask).await.unwrap_or(Err(Probe::Busy))
}

/// Asks the run at `path` to end: it answers first, then ends as if its window were closed. An old run refuses with `unsupported`.
pub async fn end(path: &Path, token: &str) -> Result<(), Probe> {
    let ask = async {
        let mut s = UnixStream::connect(path).await.map_err(|e| if gone(&e) { Probe::Gone } else { Probe::Busy })?;
        let req = serde_json::json!({ "op": "end", "v": LOCAL_V });
        send_head_with(&mut s, req, token).await.map_err(|_| Probe::Busy)?;
        let got = Lines::new(BufReader::new(s), MAX_IN_LINE).next().await;
        let Ok(Got::Line(line)) = got else {
            return Err(Probe::Refused("bad reply".into()));
        };
        let v: serde_json::Value = serde_json::from_slice(&line).map_err(|_| Probe::Refused("bad reply".into()))?;
        match (v.get("ok"), v.get("error")) {
            (Some(serde_json::Value::Bool(true)), _) => Ok(()),
            (_, Some(e)) => Err(Probe::Refused(e.as_str().unwrap_or("error").to_string())),
            _ => Err(Probe::Refused("bad reply".into())),
        }
    };
    tokio::time::timeout(STATUS_WAIT, ask).await.unwrap_or(Err(Probe::Busy))
}

/// The statuses of the live sockets in `pty/`, by name. A leftover socket file is removed; a busy or refusing
/// socket is skipped.
pub async fn scan(term_dir: &Path, token: &str) -> Vec<Status> {
    scan_all(term_dir, token).await.0
}

/// [`scan`], and whether some socket was there but gave no status in time (busy, or not reachable just now): a
/// session missing from the statuses may be that one.
pub async fn scan_all(term_dir: &Path, token: &str) -> (Vec<Status>, bool) {
    let Ok(dir) = std::fs::read_dir(term_dir.join("pty")) else {
        return (Vec::new(), false);
    };
    let mut probes = tokio::task::JoinSet::new();
    for path in dir.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "sock")) {
        let token = token.to_string();
        probes.spawn(async move { (status(&path, &token).await, path) });
    }
    let mut out = Vec::new();
    let mut busy = false;
    while let Some(Ok((probe, path))) = probes.join_next().await {
        match probe {
            Ok(s) => out.push(s),
            Err(Probe::Gone) => {
                let _ = std::fs::remove_file(&path);
            }
            Err(Probe::Busy) => busy = true,
            Err(Probe::Refused(_)) => {}
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.key.cmp(&b.key)).then(a.pid.cmp(&b.pid)));
    (out, busy)
}

/// A request head.
#[derive(Debug, PartialEq)]
pub struct Head {
    pub op: String,
    pub v: u32,
    /// The new name of a `rename`.
    pub name: Option<String>,
}

#[derive(Deserialize)]
struct Request {
    op: String,
    v: u32,
    name: Option<String>,
}

/// Reads the request line and the token line, both within `HEAD_WAIT`. The error is what to tell the client.
pub async fn read_head<R: AsyncBufRead + Unpin>(r: &mut R, token: &str) -> Result<Head, &'static str> {
    let both = async {
        let mut lines = Lines::new(&mut *r, 4096);
        let req = next_line(&mut lines).await?;
        let sent = next_line(&mut lines).await?;
        let req: Request = serde_json::from_slice(&req).map_err(|_| "bad request")?;
        if sent.strip_suffix(b"\r").unwrap_or(&sent) != token.as_bytes() {
            return Err("bad token");
        }
        Ok(Head { op: req.op, v: req.v, name: req.name })
    };
    tokio::time::timeout(HEAD_WAIT, both).await.unwrap_or(Err("timeout"))
}

async fn next_line<R: AsyncBufRead + Unpin>(lines: &mut Lines<R>) -> Result<Vec<u8>, &'static str> {
    match lines.next().await {
        Ok(Got::Line(l)) => Ok(l),
        Ok(Got::TooLong) => Err("bad request"),
        Ok(Got::Eof) | Err(_) => Err("closed"),
    }
}

/// `base`, else `base-2`, `base-3`…: the first not in `taken`.
pub fn pick_name(base: &str, taken: &[String]) -> String {
    std::iter::once(base.to_string())
        .chain((2..).map(|n| format!("{base}-{n}")))
        .find(|c| !taken.contains(c))
        .expect("the counter never runs out")
}

/// Opens `pty/.lock` and locks it; dropping the file releases the lock. Held while a name is picked and bound.
pub fn name_lock(term_dir: &Path) -> anyhow::Result<std::fs::File> {
    let path = term_dir.join("pty/.lock");
    let f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&path)
        .with_context(|| format!("cannot open {}", path.display()))?;
    f.lock().with_context(|| format!("cannot lock {}", path.display()))?;
    Ok(f)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tokio::io::{AsyncWriteExt, BufReader};
    use tokio::net::UnixListener;

    #[test]
    fn a_ps_this_build_cannot_read_is_no_ps_not_no_status() {
        let base = |ps: &str| format!(r#"{{"v":2,"name":"a","command":"sh","cols":80,"rows":24,"activity":1,"viewers":0,"pid":7,"ps":{ps}}}"#);
        for bad in [r#"{"state":"working","progress":999}"#, r#""x""#, r#"{"seq":1}"#, "null"] {
            let s = serde_json::from_str::<Status>(&base(bad)).unwrap();
            assert_eq!((s.ps, s.name.as_str(), s.pid), (None, "a", 7), "{bad}");
        }
        let s = serde_json::from_str::<Status>(&base(r#"{"state":"working"}"#)).unwrap();
        assert_eq!(s.ps.unwrap().state, "working");
    }

    #[test]
    fn status_without_ps_reads_and_unknown_fields_are_ignored() {
        let old = r#"{"v":2,"name":"a","command":"sh","cols":80,"rows":24,"activity":1,"viewers":0,"pid":7}"#;
        assert_eq!(serde_json::from_str::<Status>(old).unwrap().ps, None);
        let newer = r#"{"v":2,"name":"a","command":"sh","cols":80,"rows":24,"activity":1,"viewers":0,"pid":7,"ps":{"state":"done","since":1,"stopped":1,"seq":1},"later":true}"#;
        assert_eq!(serde_json::from_str::<Status>(newer).unwrap().ps.unwrap().state, "done");
    }

    #[test]
    fn a_status_title_is_optional() {
        let base = r#"{"v":2,"name":"a","command":"sh","cols":80,"rows":24,"activity":1,"viewers":0,"pid":7"#;
        let none: Status = serde_json::from_str(&format!("{base}}}")).unwrap();
        assert_eq!(none.title, None);
        assert!(!serde_json::to_string(&none).unwrap().contains("title"));
        let some: Status = serde_json::from_str(&format!(r#"{base},"title":"x"}}"#)).unwrap();
        assert_eq!(some.title.as_deref(), Some("x"));
    }

    fn mode(p: &Path) -> u32 {
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn names_count_up_from_two() {
        assert_eq!(pick_name("claude", &[]), "claude");
        assert_eq!(pick_name("claude", &["claude".into(), "claude-2".into()]), "claude-3");
    }

    #[test]
    fn the_token_is_made_once_and_kept() {
        let d = tempfile::tempdir().unwrap();
        ensure_dirs(d.path()).unwrap();
        let a = token(d.path()).unwrap();
        assert_eq!((a.len(), token(d.path()).unwrap()), (32, a.clone()));
        assert_eq!(mode(&d.path().join("pty.token")), 0o600);
        assert_eq!(mode(&d.path().join("pty")), 0o700);
        assert_eq!(mode(&d.path().join("launch")), 0o700);
    }

    #[test]
    fn an_old_empty_token_file_is_made_again_at_once() {
        let d = tempfile::tempdir().unwrap();
        ensure_dirs(d.path()).unwrap();
        let path = d.path().join("pty.token");
        let f = std::fs::File::create(&path).unwrap();
        f.set_modified(std::time::SystemTime::now() - Duration::from_secs(5)).unwrap();
        drop(f);
        let started = std::time::Instant::now();
        let t = token(d.path()).unwrap();
        assert!(started.elapsed() < Duration::from_millis(200), "{:?}", started.elapsed());
        assert!(t.len() == 32 && t.bytes().all(|b| b.is_ascii_hexdigit()), "{t}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), t);
        assert_eq!(mode(&path), 0o600);
    }

    #[test]
    fn a_long_socket_path_is_an_error() {
        let long = Path::new("/tmp").join("x".repeat(100));
        assert!(socket_path(&long, 1).unwrap_err().to_string().contains("too long"));
        assert!(socket_path(Path::new("/tmp/t"), 7).unwrap().ends_with("pty/7.sock"));
    }

    #[test]
    fn the_name_lock_excludes_a_second_holder() {
        let d = tempfile::tempdir().unwrap();
        ensure_dirs(d.path()).unwrap();
        let a = name_lock(d.path()).unwrap();
        let b = std::fs::File::options().write(true).open(d.path().join("pty/.lock")).unwrap();
        assert!(b.try_lock().is_err());
        drop(a);
        assert!(b.try_lock().is_ok());
    }

    #[tokio::test]
    async fn a_dead_socket_is_removed_and_skipped() {
        let d = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
        let dir = d.path();
        ensure_dirs(dir).unwrap();
        let tok = token(dir).unwrap();
        // 1: bound then dropped, so it refuses.
        drop(std::os::unix::net::UnixListener::bind(dir.join("pty/1.sock")).unwrap());
        // 2: a live fake answering a status for "b".
        let live = UnixListener::bind(dir.join("pty/2.sock")).unwrap();
        let t = tok.clone();
        tokio::spawn(async move {
            loop {
                let (mut s, _) = live.accept().await.unwrap();
                let (r, mut w) = s.split();
                let mut r = BufReader::new(r);
                let head = read_head(&mut r, &t).await.unwrap();
                assert_eq!(head.op, "status");
                let st = Status {
                    v: 1,
                    name: "b".into(),
                    command: "sh".into(),
                    cols: 80,
                    rows: 24,
                    activity: 5,
                    viewers: 0,
                    pid: 2,
                    ticket: None,
                    key: None,
                    ps: None,
                    title: None,
                    fg: None,
                    cwd: None,
                    shell: None,
                    tty: None,
                };
                w.write_all(format!("{}\n", serde_json::to_string(&st).unwrap()).as_bytes()).await.unwrap();
            }
        });
        // 3: accepts and never answers.
        let busy = UnixListener::bind(dir.join("pty/3.sock")).unwrap();
        tokio::spawn(async move {
            let mut held = Vec::new();
            loop {
                held.push(busy.accept().await.unwrap());
            }
        });
        let got = scan(dir, &tok).await;
        assert_eq!(got.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["b"]);
        assert!(!dir.join("pty/1.sock").exists() && dir.join("pty/3.sock").exists());
        assert_eq!(status(&dir.join("pty/3.sock"), &tok).await.unwrap_err(), Probe::Busy);
        assert_eq!(status(&dir.join("pty/1.sock"), &tok).await.unwrap_err(), Probe::Gone);
    }

    #[test]
    fn only_a_refused_or_missing_socket_is_gone() {
        use std::io::{Error, ErrorKind};
        assert!(gone(&Error::from(ErrorKind::ConnectionRefused)));
        assert!(gone(&Error::from(ErrorKind::NotFound)));
        for k in [ErrorKind::PermissionDenied, ErrorKind::WouldBlock, ErrorKind::Other] {
            assert!(!gone(&Error::from(k)));
        }
        assert!(!gone(&Error::from_raw_os_error(libc::EMFILE)));
        assert!(!gone(&Error::from_raw_os_error(libc::EACCES)));
    }

    #[tokio::test]
    async fn an_unreadable_socket_is_not_removed() {
        let d = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
        ensure_dirs(d.path()).unwrap();
        let tok = token(d.path()).unwrap();
        let p = d.path().join("pty/4.sock");
        drop(std::os::unix::net::UnixListener::bind(&p).unwrap());
        // No access to the socket: EACCES, not a refusal.
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o000)).unwrap();
        let r = status(&p, &tok).await;
        let uid_is_root = unsafe { libc::geteuid() } == 0;
        if !uid_is_root {
            assert_eq!(r.unwrap_err(), Probe::Busy);
            assert!(scan(d.path(), &tok).await.is_empty());
            assert!(p.exists());
        }
    }

    #[tokio::test]
    async fn a_wrong_token_gets_the_error_reply() {
        let d = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
        let p = d.path().join("s.sock");
        let l = UnixListener::bind(&p).unwrap();
        tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            let (r, mut w) = s.split();
            let e = read_head(&mut BufReader::new(r), "good").await.unwrap_err();
            w.write_all(format!("{{\"error\":\"{e}\"}}\n").as_bytes()).await.unwrap();
        });
        assert_eq!(status(&p, "nope").await.unwrap_err(), Probe::Refused("bad token".into()));
    }

    #[tokio::test]
    async fn a_bad_token_is_refused() {
        let mut r = BufReader::new(&b"{\"op\":\"status\",\"v\":1}\nnope\n"[..]);
        assert_eq!(read_head(&mut r, "good").await.unwrap_err(), "bad token");
    }

    #[tokio::test]
    async fn a_good_head_is_read_and_junk_is_not() {
        let mut r = BufReader::new(&b"{\"op\":\"view\",\"v\":1,\"x\":2}\ngood\r\nrest"[..]);
        let h = read_head(&mut r, "good").await.unwrap();
        assert_eq!((h.op.as_str(), h.v), ("view", 1));
        let mut r = BufReader::new(&b"nonsense\ngood\n"[..]);
        assert_eq!(read_head(&mut r, "good").await.unwrap_err(), "bad request");
        let mut r = BufReader::new(&b"{\"op\":\"view\",\"v\":1}\n"[..]);
        assert_eq!(read_head(&mut r, "good").await.unwrap_err(), "closed");
        let long = vec![b'a'; 100_000];
        let mut r = BufReader::new(&long[..]);
        assert_eq!(read_head(&mut r, "good").await.unwrap_err(), "bad request");
    }

    #[test]
    fn unknown_status_fields_are_ignored() {
        let s: Status = serde_json::from_str(
            r#"{"v":1,"name":"a","command":"","cols":1,"rows":1,"activity":0,"viewers":0,"pid":9,"new":1}"#,
        )
        .unwrap();
        assert_eq!(s.name, "a");
        assert!(!serde_json::to_string(&s).unwrap().contains("ticket"));
        // A run of version 1 sends no key, and none is sent back.
        assert_eq!(s.key, None);
        assert!(!serde_json::to_string(&s).unwrap().contains("key"));
    }

    #[test]
    fn keys_are_16_lowercase_hex_and_differ() {
        let (a, b) = (new_key(), new_key());
        assert!(a.len() == 16 && a.bytes().all(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f')), "{a}");
        assert_ne!(a, b);
    }

    #[tokio::test]
    async fn a_rename_head_carries_the_name() {
        let mut r = BufReader::new(&b"{\"op\":\"rename\",\"v\":2,\"name\":\"\xe5\x90\x8e\xe7\xab\xaf\"}\ngood\n"[..]);
        let h = read_head(&mut r, "good").await.unwrap();
        assert_eq!((h.op.as_str(), h.v, h.name.as_deref()), ("rename", 2, Some("后端")));
    }
}
