//! The `rapp-term` command: version, list, watch, run.
//!
//! Exit codes: 0 ok, 1 a runtime error (tmux missing or failing, the session not there or not made), 2 an
//! argument error. Errors go to stderr as one line and never carry the command, the screen or the input.

use rapp_term::id::TermId;
use rapp_term::proto::PROTO;
use rapp_term::runner::Runner;
use rapp_term::session::{self, Opts};
use rapp_term::tmux::{cmd, parse, PaneInfo, Tmux};
use rapp_term::unread::Unread;
use serde::Serialize;
use std::collections::{BTreeMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const USAGE: &str = "\
usage: rapp-term version [--json]
       rapp-term list [--json] [--ssh <destination> --host <name>] [--tmux <path>]
       rapp-term watch <term id> [--ssh <destination>] [--tmux <path>] [--json]
       rapp-term run [--name <name>] [--size <cols>x<rows>] [--ssh <destination> --host <name>] [--tmux <path>] \
-- <command...>";

/// The only backend this command serves.
const BACKEND: &str = "tmux";
/// The size of a new session when `--size` is not given.
const DEFAULT_SIZE: (u16, u16) = (80, 24);

/// Why the command stopped.
enum Fail {
    /// Exit 2.
    Usage(String),
    /// Exit 1.
    Runtime(String),
}

fn usage(m: impl Into<String>) -> Fail {
    Fail::Usage(m.into())
}

fn runtime(m: impl Into<String>) -> Fail {
    Fail::Runtime(m.into())
}

type Res<T> = Result<T, Fail>;

/// The parsed options of one subcommand.
#[derive(Default)]
struct Args {
    json: bool,
    ssh: Option<String>,
    host: Option<String>,
    tmux: Option<String>,
    /// Hidden: a named tmux server (`tmux -L`), for tests.
    socket: Option<String>,
    name: Option<String>,
    size: Option<String>,
    /// Arguments that are not options.
    pos: Vec<String>,
    /// Everything after `--`.
    command: Option<Vec<String>>,
}

/// Parse `argv` taking only the options in `allowed` (names without the dashes; `"--"` allows a command after
/// `--`). Errors never repeat what was given: it may be the start of a command.
fn parse_args(allowed: &[&str], argv: &[String]) -> Res<Args> {
    let mut a = Args::default();
    let mut it = argv.iter();
    while let Some(arg) = it.next() {
        if arg == "--" {
            if !allowed.contains(&"--") {
                return Err(usage("unexpected --"));
            }
            a.command = Some(it.cloned().collect());
            break;
        }
        let Some(opt) = arg.strip_prefix("--") else {
            if arg.starts_with('-') && arg.len() > 1 {
                return Err(usage("unknown option"));
            }
            a.pos.push(arg.clone());
            continue;
        };
        if !allowed.contains(&opt) {
            return Err(usage("unknown option"));
        }
        if opt == "json" {
            a.json = true;
            continue;
        }
        let slot = match opt {
            "ssh" => &mut a.ssh,
            "host" => &mut a.host,
            "tmux" => &mut a.tmux,
            "socket" => &mut a.socket,
            "name" => &mut a.name,
            "size" => &mut a.size,
            _ => return Err(usage("unknown option")),
        };
        // The value is the next argument whatever it looks like; `Runner::ssh` rejects a destination like `-o…`.
        let Some(v) = it.next() else { return Err(usage(format!("--{opt} needs a value"))) };
        *slot = Some(v.clone());
    }
    Ok(a)
}

/// `<cols>x<rows>`, both above zero.
fn parse_size(s: &str) -> Option<(u16, u16)> {
    let (c, r) = s.split_once('x')?;
    let all_digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
    if !all_digits(c) || !all_digits(r) {
        return None;
    }
    let (c, r): (u16, u16) = (c.parse().ok()?, r.parse().ok()?);
    (c > 0 && r > 0).then_some((c, r))
}

/// A session name tmux keeps as given on every version: tmux before 3.5 turns `:` and `.` into `_`, so they are
/// turned here; empty names and control characters are refused.
fn session_name(s: &str) -> Option<String> {
    if s.is_empty() || s.chars().any(char::is_control) {
        return None;
    }
    Some(s.replace([':', '.'], "_"))
}

/// The default name of a new session: the last path part of the command's program.
fn default_name(program: &str) -> &str {
    program.rsplit('/').next().unwrap_or(program)
}

fn term_id(host: Option<&str>, name: &str) -> TermId {
    TermId { backend: BACKEND.into(), host: host.map(str::to_string), name: name.to_string() }
}

/// `--host` must be something a term id can carry.
fn check_host(a: &Args) -> Res<()> {
    let Some(h) = &a.host else { return Ok(()) };
    if a.ssh.is_none() {
        return Err(usage("--host goes with --ssh"));
    }
    // The id must read back with the same host: `a:b` parses, but as host `a` and a name starting `b:`.
    match TermId::parse(&term_id(Some(h), "-").to_string()) {
        Ok(t) if t.host.as_deref() == Some(h.as_str()) => Ok(()),
        _ => Err(usage("invalid --host name")),
    }
}

/// The ssh control-connection directory: `/tmp/rapp-term-<user>` on unix.
fn ctl_dir() -> PathBuf {
    let user = std::env::var("USER").or_else(|_| std::env::var("LOGNAME")).unwrap_or_default();
    ctl_dir_for(&user)
}

fn ctl_dir_for(user: &str) -> PathBuf {
    let user: String = user.chars().filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')).collect();
    let user = if user.is_empty() { "user".to_string() } else { user };
    // /tmp, not temp_dir(): macOS's TMPDIR (/var/folders/…/T/, ~49 bytes) plus `/%C` (40) and ssh's temporary
    // suffix overflow the 104-byte unix socket path, and ssh then silently drops multiplexing.
    #[cfg(unix)]
    let base = PathBuf::from("/tmp");
    #[cfg(not(unix))]
    let base = std::env::temp_dir();
    base.join(format!("rapp-term-{user}"))
}

/// Make `dir` (or keep it) readable by its owner only.
fn private_dir(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        match std::fs::DirBuilder::new().mode(0o700).create(dir) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            }
            Err(e) => Err(e),
        }
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(dir)
    }
}

/// The tmux the options point at. Argument errors come before anything is made on disk.
fn tmux_of(a: &Args) -> Res<Tmux> {
    let runner = match &a.ssh {
        None => Runner::Local,
        Some(dest) => {
            let dir = ctl_dir();
            let r = Runner::ssh(dest, &dir).map_err(|_| usage("invalid --ssh destination"))?;
            private_dir(&dir).map_err(|_| runtime("could not make the ssh control directory"))?;
            r
        }
    };
    Ok(Tmux { runner, bin: a.tmux.clone().unwrap_or_else(|| BACKEND.into()), socket: a.socket.clone() })
}

async fn check(tmux: &Tmux) -> Res<()> {
    tmux.check().await.map_err(|e| runtime(format!("tmux is not usable: {e}")))
}

async fn list_panes(tmux: &Tmux) -> Res<Vec<PaneInfo>> {
    tmux.list().await.map_err(|e| runtime(format!("could not list the tmux sessions: {e}")))
}

/// One session as `list` shows it.
#[derive(Serialize, Debug, PartialEq)]
struct SessionRow {
    id: String,
    name: String,
    command: String,
    panes: usize,
    attached: u32,
    activity: u64,
    dead: bool,
}

/// The sessions in `list`, oldest first: `command` is the first pane's of the session's current window (a window
/// in `current`; the first window when none is), `activity` the latest of its windows, `dead` when every pane
/// has exited.
fn sessions(list: &[PaneInfo], current: &HashSet<String>, host: Option<&str>) -> Vec<SessionRow> {
    let mut by: BTreeMap<(u64, &str), Vec<&PaneInfo>> = BTreeMap::new();
    for p in list {
        let n = p.session_id.trim_start_matches('$').parse().unwrap_or(u64::MAX);
        by.entry((n, p.session_id.as_str())).or_default().push(p);
    }
    by.into_values()
        .map(|ps| {
            let place = |p: &&&PaneInfo| (!current.contains(&p.window_id), p.window_index, p.pane_index);
            let first = ps.iter().min_by_key(place).expect("a session has a pane");
            SessionRow {
                id: term_id(host, &first.session).to_string(),
                name: first.session.clone(),
                command: first.command.clone(),
                panes: ps.len(),
                attached: first.attached,
                activity: ps.iter().map(|p| p.activity).max().unwrap_or(0),
                dead: ps.iter().all(|p| p.dead),
            }
        })
        .collect()
}

fn version(a: &Args) {
    #[derive(Serialize)]
    struct V {
        version: &'static str,
        proto: u32,
    }
    if a.json {
        let v = V { version: env!("CARGO_PKG_VERSION"), proto: PROTO };
        println!("{}", serde_json::to_string(&v).expect("always serializes"));
    } else {
        println!("rapp-term {} (protocol {PROTO})", env!("CARGO_PKG_VERSION"));
    }
}

async fn list(a: &Args) -> Res<()> {
    if !a.pos.is_empty() {
        return Err(usage("list takes no arguments"));
    }
    check_host(a)?;
    let tmux = tmux_of(a)?;
    let panes = list_panes(&tmux).await?;
    // A server that went away between the two calls leaves no current window: the first window stands in.
    let current = match panes.is_empty() {
        true => HashSet::new(),
        false => tmux.run(&cmd::window_flags()).await.map(|s| parse::current_windows(&s)).unwrap_or_default(),
    };
    let rows = sessions(&panes, &current, a.host.as_deref());
    if a.json {
        #[derive(Serialize)]
        struct L {
            sessions: Vec<SessionRow>,
        }
        println!("{}", serde_json::to_string(&L { sessions: rows }).expect("always serializes"));
    } else {
        for r in rows {
            println!("{}\t{}\t{}", r.id, r.command, r.panes);
        }
    }
    Ok(())
}

async fn watch(a: &Args) -> Res<()> {
    let [id] = a.pos.as_slice() else { return Err(usage("watch takes one term id")) };
    let id = TermId::parse(id).map_err(|_| usage("invalid term id"))?;
    if id.backend != BACKEND {
        return Err(usage("unsupported term backend"));
    }
    if id.host.is_some() && a.ssh.is_none() {
        return Err(usage("the term id names a host: give --ssh"));
    }
    let tmux = tmux_of(a)?;
    check(&tmux).await?;
    if !list_panes(&tmux).await?.iter().any(|p| p.session == id.name) {
        return Err(runtime("no such session"));
    }
    let unread = Arc::new(Mutex::new(Unread::default()));
    let input = tokio::io::BufReader::new(tokio::io::stdin());
    session::run(&tmux, &id.name, input, tokio::io::stdout(), unread, Opts::default())
        .await
        .map_err(|e| runtime(format!("watch stopped: {e}")))
}

async fn run(a: &Args) -> Res<()> {
    if !a.pos.is_empty() {
        return Err(usage("unexpected argument: the command goes after --"));
    }
    let command = match &a.command {
        Some(c) if !c.is_empty() => c,
        _ => return Err(usage("run needs a command after --")),
    };
    let (cols, rows) = match &a.size {
        None => DEFAULT_SIZE,
        Some(s) => parse_size(s).ok_or_else(|| usage("invalid --size: use <cols>x<rows>"))?,
    };
    let name = a.name.as_deref().unwrap_or_else(|| default_name(&command[0]));
    let name = session_name(name).ok_or_else(|| usage("invalid session name"))?;
    check_host(a)?;
    let tmux = tmux_of(a)?;
    check(&tmux).await?;
    if list_panes(&tmux).await?.iter().any(|p| p.session == name) {
        return Err(runtime("a session with that name already exists"));
    }
    // tmux's own words may quote the command, so they are not passed on.
    tmux.new_session(&name, command, cols, rows).await.map_err(|_| runtime("could not create the session"))?;
    let id = term_id(a.host.as_deref(), &name).to_string();
    if a.json {
        println!("{}", serde_json::json!({ "id": id }));
    } else {
        println!("{id}");
    }
    Ok(())
}

fn dispatch(argv: &[String]) -> Res<()> {
    let Some((sub, rest)) = argv.split_first() else { return Err(usage("missing subcommand")) };
    let allowed: &[&str] = match sub.as_str() {
        "version" => &["json", "socket"],
        "list" => &["json", "ssh", "host", "tmux", "socket"],
        "watch" => &["json", "ssh", "tmux", "socket"],
        "run" => &["json", "name", "size", "ssh", "host", "tmux", "socket", "--"],
        "help" | "--help" | "-h" => {
            println!("{USAGE}");
            return Ok(());
        }
        _ => return Err(usage("unknown subcommand")),
    };
    let a = parse_args(allowed, rest)?;
    if sub == "version" {
        if !a.pos.is_empty() {
            return Err(usage("version takes no arguments"));
        }
        version(&a);
        return Ok(());
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| runtime("could not start the async runtime"))?;
    let res = rt.block_on(async {
        match sub.as_str() {
            "list" => list(&a).await,
            "watch" => watch(&a).await,
            _ => run(&a).await,
        }
    });
    // Dropping the runtime would wait for tokio's blocking stdin read, which lasts as long as stdin stays open.
    rt.shutdown_background();
    res
}

fn main() {
    let argv: Option<Vec<String>> = std::env::args_os().skip(1).map(|s| s.into_string().ok()).collect();
    let res = match argv {
        Some(argv) => dispatch(&argv),
        None => Err(usage("arguments must be UTF-8")),
    };
    let code = match res {
        Ok(()) => 0,
        Err(Fail::Usage(m)) => {
            eprintln!("rapp-term: {} (see rapp-term help)", m.replace('\n', " "));
            2
        }
        Err(Fail::Runtime(m)) => {
            eprintln!("rapp-term: {}", m.replace('\n', " "));
            1
        }
    };
    let _ = std::io::stdout().flush();
    // Exit here rather than return: a pending stdin read on tokio's blocking pool would hold the process open.
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    fn pane(sid: &str, wid: &str, wi: u32, pi: u32, cmd: &str, activity: u64, dead: bool) -> PaneInfo {
        PaneInfo {
            session_id: sid.into(),
            session: format!("s{sid}"),
            window_id: wid.into(),
            window: "w".into(),
            pane: format!("%{wi}{pi}"),
            command: cmd.into(),
            title: "t".into(),
            window_index: wi,
            pane_index: pi,
            attached: 1,
            activity,
            cols: 80,
            rows: 24,
            dead,
        }
    }

    #[test]
    fn sessions_take_the_current_windows_first_pane_and_the_latest_activity() {
        let list = [
            pane("$10", "@9", 0, 0, "vim", 5, true),
            pane("$2", "@1", 0, 0, "zsh", 100, false),
            pane("$2", "@2", 1, 1, "htop", 300, false),
            pane("$2", "@2", 1, 0, "claude", 200, true),
        ];
        let current: HashSet<String> = ["@2".to_string()].into_iter().collect();
        let v = sessions(&list, &current, Some("gpu1"));
        assert_eq!(v.len(), 2);
        assert_eq!(
            v[0],
            SessionRow {
                id: "term:tmux@gpu1:s$2".into(),
                name: "s$2".into(),
                command: "claude".into(),
                panes: 3,
                attached: 1,
                activity: 300,
                dead: false,
            }
        );
        assert_eq!((v[1].name.as_str(), v[1].command.as_str(), v[1].dead), ("s$10", "vim", true));
        // No current window known: the first window's first pane.
        assert_eq!(sessions(&list, &HashSet::new(), None)[0].command, "zsh");
    }

    #[test]
    fn options_take_the_next_argument_as_their_value() {
        let a = parse_args(&["ssh", "json"], &s(&["--ssh", "-oProxyCommand=x", "--json"])).ok().unwrap();
        assert_eq!((a.ssh.as_deref(), a.json), (Some("-oProxyCommand=x"), true));
        assert!(parse_args(&["ssh"], &s(&["--ssh"])).is_err());
        assert!(parse_args(&["json"], &s(&["--name", "x"])).is_err());
        assert!(parse_args(&["json"], &s(&["--", "x"])).is_err());
        let a = parse_args(&["--", "name"], &s(&["--name", "n", "--", "sh", "--json"])).ok().unwrap();
        assert_eq!(a.command, Some(s(&["sh", "--json"])));
    }

    #[cfg(unix)]
    #[test]
    fn control_socket_paths_fit_a_unix_socket_address() {
        let dir = ctl_dir_for("firstname.lastname01");
        assert_eq!(dir, Path::new("/tmp/rapp-term-firstname.lastname01"));
        // `<dir>/%C` (40 hex characters), then ssh's temporary bind suffix (about 17), within sun_path's 104 bytes.
        let len = dir.as_os_str().len() + 1 + 40 + 17;
        assert!(len <= 104, "{len}");
    }

    #[test]
    fn hosts_must_read_back_the_same_from_an_id() {
        let host = |h: &str| Args { ssh: Some("d".into()), host: Some(h.into()), ..Args::default() };
        for good in ["gpu1", "gpu1.lab", "my_host-2"] {
            assert!(check_host(&host(good)).is_ok(), "{good}");
        }
        for bad in ["a:b", "", "a b", "a@b", "a/b"] {
            assert!(matches!(check_host(&host(bad)), Err(Fail::Usage(_))), "{bad}");
        }
        let no_ssh = Args { host: Some("gpu1".into()), ..Args::default() };
        assert!(matches!(check_host(&no_ssh), Err(Fail::Usage(_))));
    }

    #[test]
    fn sizes_and_names() {
        assert_eq!(parse_size("90x20"), Some((90, 20)));
        for bad in ["axb", "90", "x20", "90x", "0x20", "90x0", "+9x20", "99999x20", "90x20x1"] {
            assert_eq!(parse_size(bad), None, "{bad}");
        }
        assert_eq!(session_name("cli demo").as_deref(), Some("cli demo"));
        assert_eq!(session_name("py3.11:x").as_deref(), Some("py3_11_x"));
        assert_eq!(session_name(""), None);
        assert_eq!(session_name("a\nb"), None);
        assert_eq!((default_name("/usr/local/bin/claude"), default_name("cat")), ("claude", "cat"));
    }
}
