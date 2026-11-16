//! Platform terminal launchers. Linux windows run in their own transient user service,
//! so stopping rapp-service does not kill the terminal or its pty holder.

use anyhow::{bail, Context};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const NO_DESKTOP: &str = "no graphical desktop session is available";
const LINUX_APPS: &[&str] = &["ghostty", "kitty", "alacritty", "foot", "wezterm", "gnome-terminal", "konsole", "xterm"];
const DESKTOP_ENV: &[&str] = &["DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "XAUTHORITY"];

/// `s` in single quotes for `sh`.
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// The content of a `.command` file that runs `bin run` in `dir` for `ticket`, with `shell` as a login shell.
pub fn command_file(bin: &Path, dir: &Path, ticket: &str, shell: &str) -> String {
    format!(
        "#!/bin/sh\nexec {} run --dir {} --ticket {} -- {} -l\n",
        quote(&bin.to_string_lossy()), quote(&dir.to_string_lossy()), quote(ticket), quote(shell)
    )
}

fn executable(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|p| p.join(name))
        .find(|p| {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                p.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            }
            #[cfg(not(unix))]
            { p.is_file() }
        })
        .and_then(|p| p.canonicalize().ok())
}

/// A long-running service may have started before the desktop. Prefer the user
/// manager's current session environment, without importing arbitrary variables.
fn desktop_env() -> BTreeMap<String, String> {
    let mut env: BTreeMap<_, _> = DESKTOP_ENV.iter()
        .filter_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()).map(|v| ((*k).to_string(), v)))
        .collect();
    let mut cmd = Command::new("systemctl");
    cmd.args(["--user", "show-environment", "--output=json"]);
    if let Some(out) = bounded_output(&mut cmd, Duration::from_secs(2)) {
        if let Ok(values) = serde_json::from_slice::<BTreeMap<String, String>>(&out) {
            for (k, v) in values {
                if DESKTOP_ENV.contains(&k.as_str()) && !v.is_empty() { env.insert(k, v); }
            }
        }
    }
    env
}

/// An unavailable user bus must not hang terminal lists or watches. Read stdout
/// concurrently so an unusually large manager environment cannot fill the pipe.
fn bounded_output(cmd: &mut Command, limit: Duration) -> Option<Vec<u8>> {
    let mut child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        stdout.take(1024 * 1024).read_to_end(&mut out).map(|_| out)
    });
    let end = Instant::now() + limit;
    let success = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Ok(None) if Instant::now() < end => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let out = reader.join().ok()?.ok()?;
    success.then_some(out)
}

fn has_desktop(env: &BTreeMap<String, String>) -> bool {
    ["DISPLAY", "WAYLAND_DISPLAY"].iter().any(|k| env.get(*k).is_some_and(|v| !v.is_empty()))
}

/// Known IDs are a platform allowlist, never an executable supplied by a peer.
pub fn known(app: &str) -> bool {
    if cfg!(target_os = "linux") { LINUX_APPS.contains(&app) } else { ["Terminal", "iTerm"].contains(&app) }
}

/// The terminal programs this machine can open a window with right now.
pub fn launchers() -> Vec<String> {
    if cfg!(target_os = "linux") {
        if !has_desktop(&desktop_env()) || executable("systemd-run").is_none() { return Vec::new(); }
        return LINUX_APPS.iter().filter(|a| executable(a).is_some()).map(|a| (*a).into()).collect();
    }
    if !cfg!(target_os = "macos") { return Vec::new(); }
    let mut v = vec!["Terminal".to_string()];
    let iterm = Command::new("open").args(["-Ra", "iTerm"])
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
    if iterm.is_ok_and(|s| s.success()) { v.push("iTerm".into()); }
    v
}

/// Keep every path as a separate argument. The launcher never runs a peer's shell expression.
fn terminal_args(app: &str, file: &Path) -> anyhow::Result<Vec<OsString>> {
    let prefix: &[&str] = match app {
        "ghostty" | "alacritty" | "xterm" => &["-e"],
        "kitty" | "foot" => &["--"],
        "wezterm" => &["start", "--always-new-process", "--"],
        "gnome-terminal" => &["--wait", "--"],
        "konsole" => &["--separate", "-e"],
        _ => bail!("unknown terminal app"),
    };
    let mut args: Vec<_> = prefix.iter().map(OsString::from).collect();
    // The private launch file need not be executable; /bin/sh reads it as data.
    args.extend([OsString::from("/bin/sh"), file.as_os_str().to_owned()]);
    Ok(args)
}

fn linux_command(app: &str, file: &Path, env: &BTreeMap<String, String>) -> anyhow::Result<Command> {
    if !has_desktop(env) { bail!(NO_DESKTOP); }
    let args = terminal_args(app, file)?;
    let terminal = executable(app).context("the terminal app is no longer installed")?;
    let mut c = Command::new("systemd-run");
    c.args(["--user", "--quiet", "--collect", "--no-ask-password", "--service-type=exec", "--expand-environment=no"]);
    for (key, value) in env { c.arg(format!("--setenv={key}={value}")); }
    c.arg("--").arg(terminal).args(args);
    Ok(c)
}

/// Open `file`; a test launcher is synchronous and has no platform dependencies.
pub fn open(app: &str, file: &Path, launch_with: Option<&Path>) -> anyhow::Result<()> {
    let mut c = match launch_with {
        Some(p) => {
            let mut c = Command::new(p);
            c.arg(app).arg(file);
            c
        }
        None if cfg!(target_os = "linux") => linux_command(app, file, &desktop_env())?,
        None => {
            let mut c = Command::new("open");
            c.arg("-a").arg(app).arg(file);
            c
        }
    };
    let status = c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
        .status().context("cannot start the program that opens the window")?;
    if !status.success() { bail!("the program that opens the window failed"); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_command_file_runs_the_shell_as_a_login_shell() {
        let f = command_file(Path::new("/A pp/rapp-term"), Path::new("/r/local/term"), "t1", "/opt/my shells/fish");
        assert_eq!(f, "#!/bin/sh\nexec '/A pp/rapp-term' run --dir '/r/local/term' --ticket 't1' -- '/opt/my shells/fish' -l\n");
    }

    #[test]
    fn terminal_arguments_preserve_spaces_quotes_and_shell_metacharacters() {
        let file = Path::new("/a b/'quote'$HOME;$(touch nope).command");
        for app in LINUX_APPS {
            let args = terminal_args(app, file).unwrap();
            assert_eq!(args[args.len() - 2], "/bin/sh");
            assert_eq!(args.last().unwrap(), file.as_os_str());
        }
        assert!(terminal_args("sh -c touch /tmp/no", file).is_err());
    }

    #[test]
    fn a_headless_machine_never_starts_a_terminal() {
        assert_eq!(linux_command("foot", Path::new("/a"), &BTreeMap::new()).unwrap_err().to_string(), NO_DESKTOP);
    }

    #[test]
    fn launch_script_quotes_every_argument() {
        let f = command_file(Path::new("/x'y"), Path::new("/a b"), "t;$USER", "/shell's/bash");
        assert_eq!(f, "#!/bin/sh\nexec '/x'\\''y' run --dir '/a b' --ticket 't;$USER' -- '/shell'\\''s/bash' -l\n");
    }

    #[test]
    fn a_stuck_manager_query_is_bounded() {
        let mut c = Command::new("sleep");
        c.arg("30");
        let began = Instant::now();
        assert!(bounded_output(&mut c, Duration::from_millis(20)).is_none());
        assert!(began.elapsed() < Duration::from_secs(2));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_always_has_terminal() { assert_eq!(launchers()[0], "Terminal"); }
}
