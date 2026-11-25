//! Platform terminal launchers. Linux windows run in their own transient user service,
//! so stopping rapp-service does not kill the terminal or its pty holder.

use anyhow::{bail, Context};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::{ErrorKind, Read};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const START_TIMEOUT: &str = "terminal launcher did not respond within 5 s";
pub const NO_DESKTOP: &str = "no graphical desktop session is available";
const LINUX_APPS: &[&str] = &["ghostty", "kitty", "alacritty", "foot", "wezterm", "gnome-terminal", "konsole", "xterm"];
const DESKTOP_ENV: &[&str] = &["DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_SESSION_ID", "XDG_SESSION_TYPE", "DBUS_SESSION_BUS_ADDRESS", "XAUTHORITY", "PATH"];

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
    executable_in(name, &std::env::var_os("PATH").unwrap_or_default())
}

fn executable_in(name: &str, path: &std::ffi::OsStr) -> Option<PathBuf> {
    std::env::split_paths(path)
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
/// Also used when the service opens its connection manager after a later login.
/// This can wait for the user manager; call it off the async I/O runtime.
pub fn desktop_env() -> BTreeMap<String, String> {
    let mut env: BTreeMap<_, _> = DESKTOP_ENV.iter()
        .filter_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()).map(|v| ((*k).to_string(), v)))
        .collect();
    let mut cmd = Command::new("systemctl");
    cmd.args(["--user", "show-environment", "--output=json"]);
    if let Some(out) = bounded_output(&mut cmd, Duration::from_secs(2)) {
        if let Ok(values) = serde_json::from_slice::<BTreeMap<String, String>>(&out) {
            for (k, v) in values {
                if DESKTOP_ENV.contains(&k.as_str()) && !v.is_empty() {
                    // Include newly installed desktop tools, retaining explicit
                    // service PATH overrides ahead of the manager's directories.
                    let v = if k == "PATH" {
                        env.get(&k).map_or(v.clone(), |old| format!("{old}:{v}"))
                    } else { v };
                    env.insert(k, v);
                }
            }
        }
    }
    env
}

/// An unavailable user bus must not hang terminal lists or watches. Read stdout
/// without blocking so descendants holding stdout open cannot outlive the deadline.
#[derive(Debug, PartialEq)]
enum CommandFailure { Failed, TimedOut }

fn bounded_output(cmd: &mut Command, limit: Duration) -> Option<Vec<u8>> {
    bounded_command(cmd, limit).ok()
}

fn bounded_command(cmd: &mut Command, limit: Duration) -> Result<Vec<u8>, CommandFailure> {
    let mut child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
        .map_err(|_| CommandFailure::Failed)?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let end = Instant::now() + limit;
    let result = (|| {
        // SAFETY: stdout owns this live pipe fd; no other code uses or changes it.
        let fd = stdout.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(CommandFailure::Failed);
        }
        let mut out = Vec::new();
        let mut eof = false;
        let mut buf = [0; 8192];
        loop {
            if Instant::now() >= end { return Err(CommandFailure::TimedOut); }
            match stdout.read(&mut buf) {
                Ok(0) => eof = true,
                Ok(n) => {
                    if out.len() + n > 1024 * 1024 { return Err(CommandFailure::Failed); }
                    out.extend_from_slice(&buf[..n]);
                    continue;
                }
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == ErrorKind::WouldBlock => {},
                Err(_) => return Err(CommandFailure::Failed),
            }
            if let Some(status) = child.try_wait().map_err(|_| CommandFailure::Failed)? {
                if !status.success() { return Err(CommandFailure::Failed); }
                if eof { return Ok(out); }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    })();
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
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
        let env = desktop_env();
        let path = std::ffi::OsStr::new(env.get("PATH").map(String::as_str).unwrap_or(""));
        if !has_desktop(&env) || executable("systemd-run").is_none() { return Vec::new(); }
        return LINUX_APPS.iter().filter(|a| executable_in(a, path).is_some()).map(|a| (*a).into()).collect();
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
    let path = std::ffi::OsStr::new(env.get("PATH").map(String::as_str).unwrap_or(""));
    let terminal = executable_in(app, path).context("the terminal app is no longer installed")?;
    let mut c = Command::new("systemd-run");
    c.args(["--user", "--quiet", "--collect", "--no-ask-password", "--service-type=exec", "--expand-environment=no"]);
    for (key, value) in env { c.arg(format!("--setenv={key}={value}")); }
    c.arg("--").arg(terminal).args(args);
    Ok(c)
}

/// Terminal's AppleScript has no new-tab command, and `open -a` always makes a new window. So: raise the frontmost
/// window that already holds a `marker` process (a terminal rapp opened), press ⌘T there, and run `file` in the tab
/// that appears. Terminal reports each native tab as a window of its own, so the new tab is the window whose id was
/// not there before ⌘T. Answers `tab` once `file` runs; anything else means it did not run.
const TERMINAL_TAB: &str = r#"on run argv
	set f to item 1 of argv
	set marker to item 2 of argv
	if not (application "Terminal" is running) then return "none"
	tell application "Terminal"
		set target to missing value
		repeat with w in windows
			repeat with t in tabs of w
				try
					if (processes of t) contains marker then
						set target to contents of w
						exit repeat
					end if
				end try
			end repeat
			if target is not missing value then exit repeat
		end repeat
		if target is missing value then return "none"
		set known to id of every window
		try
			set miniaturized of target to false
		end try
		set index of target to 1
		activate
	end tell
	set raised to false
	repeat 20 times
		delay 0.05
		tell application "System Events" to set raised to frontmost of process "Terminal"
		if raised then exit repeat
	end repeat
	if not raised then return "not-front"
	delay 0.1
	tell application "System Events" to keystroke "t" using command down
	repeat 30 times
		delay 0.1
		tell application "Terminal"
			repeat with w in windows
				if known does not contain (id of w) then
					do script (" exec /bin/sh " & quoted form of f) in selected tab of w
					return "tab"
				end if
			end repeat
		end tell
	end repeat
	return "no-tab"
end run
"#;

/// The process name a window rapp opened holds: `rapp-term run`.
const HOLDER: &str = "rapp-term";

#[derive(Debug, PartialEq)]
enum TabOutcome {
    /// `file` runs in a new tab.
    Opened,
    /// `file` did not run: open a window instead.
    NotOpened,
    /// The script was cut off and `file` may have run; a window now could start it twice.
    Unsure,
}

fn tab_outcome(r: Result<Vec<u8>, CommandFailure>) -> TabOutcome {
    match r {
        Ok(out) if String::from_utf8_lossy(&out).trim() == "tab" => TabOutcome::Opened,
        Ok(_) | Err(CommandFailure::Failed) => TabOutcome::NotOpened,
        Err(CommandFailure::TimedOut) => TabOutcome::Unsure,
    }
}

fn terminal_tab(file: &Path) -> TabOutcome {
    let mut c = Command::new("osascript");
    c.arg("-e").arg(TERMINAL_TAB).arg(file).arg(HOLDER);
    tab_outcome(bounded_command(&mut c, Duration::from_secs(10)))
}

/// Open `file`; a test launcher is synchronous and has no platform dependencies.
pub fn open(app: &str, file: &Path, launch_with: Option<&Path>) -> anyhow::Result<()> {
    // A new terminal goes in a tab beside the ones rapp already opened; the first one gets a window.
    // Unsure leaves the holder's own start-up wait to tell whether it started.
    if cfg!(target_os = "macos") && launch_with.is_none() && app == "Terminal"
        && terminal_tab(file) != TabOutcome::NotOpened
    {
        return Ok(());
    }
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
    if cfg!(target_os = "linux") && launch_with.is_none() {
        return match bounded_command(&mut c, Duration::from_secs(5)) {
            Ok(_) => Ok(()),
            Err(CommandFailure::TimedOut) => bail!(START_TIMEOUT),
            Err(CommandFailure::Failed) => bail!("the program that opens the window failed"),
        };
    }
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

    #[test]
    fn a_stuck_launcher_is_killed_and_failure_is_distinct_from_timeout() {
        let mut sleep = Command::new("sleep");
        sleep.arg("30");
        assert_eq!(bounded_command(&mut sleep, Duration::from_millis(20)), Err(CommandFailure::TimedOut));
        assert_eq!(bounded_command(&mut Command::new("false"), Duration::from_secs(2)), Err(CommandFailure::Failed));
    }

    #[test]
    fn a_descendant_holding_stdout_does_not_defeat_the_deadline() {
        let mut c = Command::new("sh");
        c.args(["-c", "sleep 1 & exit 0"]);
        let began = Instant::now();
        assert_eq!(bounded_command(&mut c, Duration::from_millis(30)), Err(CommandFailure::TimedOut));
        assert!(began.elapsed() < Duration::from_millis(500));
    }

    #[test]
    fn large_output_is_drained_and_excess_output_is_refused() {
        let mut c = Command::new("head");
        c.args(["-c", "131072", "/dev/zero"]);
        assert_eq!(bounded_command(&mut c, Duration::from_secs(2)).unwrap().len(), 131072);
        let mut c = Command::new("head");
        c.args(["-c", "2097152", "/dev/zero"]);
        assert_eq!(bounded_command(&mut c, Duration::from_secs(2)), Err(CommandFailure::Failed));
    }

    #[test]
    fn a_terminal_installed_in_the_desktop_path_can_be_launched() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let terminal = dir.path().join("foot");
        std::fs::write(&terminal, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&terminal, std::fs::Permissions::from_mode(0o700)).unwrap();
        let env = BTreeMap::from([
            ("WAYLAND_DISPLAY".into(), "wayland-test".into()),
            ("PATH".into(), dir.path().to_string_lossy().into_owned()),
        ]);
        let c = linux_command("foot", Path::new("/a b/session.command"), &env).unwrap();
        let args: Vec<_> = c.get_args().collect();
        assert!(args.contains(&terminal.canonicalize().unwrap().as_os_str()));
        assert_eq!(args.last().unwrap(), &std::ffi::OsStr::new("/a b/session.command"));
        std::fs::set_permissions(&terminal, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(linux_command("foot", Path::new("/a"), &env).is_err());
    }

    #[test]
    fn only_a_tab_that_ran_the_file_counts_and_a_cut_off_script_never_opens_a_second_window() {
        assert_eq!(tab_outcome(Ok(b"tab\n".to_vec())), TabOutcome::Opened);
        for out in ["none\n", "no-tab\n", "not-front\n", ""] {
            assert_eq!(tab_outcome(Ok(out.as_bytes().to_vec())), TabOutcome::NotOpened, "{out:?}");
        }
        assert_eq!(tab_outcome(Err(CommandFailure::Failed)), TabOutcome::NotOpened);
        assert_eq!(tab_outcome(Err(CommandFailure::TimedOut)), TabOutcome::Unsure);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_terminal_tab_script_compiles() {
        let out = std::env::temp_dir().join(format!("rapp-tab-{}.scpt", std::process::id()));
        let status = Command::new("osacompile").arg("-o").arg(&out).arg("-e").arg(TERMINAL_TAB)
            .stdout(Stdio::null()).stderr(Stdio::inherit()).status().unwrap();
        let _ = std::fs::remove_file(&out);
        assert!(status.success());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_always_has_terminal() { assert_eq!(launchers()[0], "Terminal"); }
}
