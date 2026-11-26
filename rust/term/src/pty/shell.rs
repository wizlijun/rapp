//! OSC 7502 shell reports: what the hook scripts say about the shell (directory, virtual environments, the command
//! being run), and the state the holder keeps from them; and the hook files themselves, and how a shell is started
//! through them.

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;
#[cfg(unix)]
use std::path::PathBuf;

/// The version of the hook files; bump it whenever one of them changes, so installed copies are written again.
pub const HOOK_V: u32 = 3;
// Windows: no hook files before phase E.
#[cfg(unix)]
const ZSHENV: &str = include_str!("hook/zshenv");
#[cfg(unix)]
const RAPP_ZSH: &str = include_str!("hook/rapp.zsh");
#[cfg(unix)]
const RAPP_BASH: &str = include_str!("hook/rapp.bash");
#[cfg(unix)]
const RAPP_FISH: &str = include_str!("hook/rapp.fish");
/// Each hook file and where it goes under `shell/`.
#[cfg(unix)]
const FILES: [(&str, &str); 4] =
    [("zsh/.zshenv", ZSHENV), ("rapp.zsh", RAPP_ZSH), ("rapp.bash", RAPP_BASH), ("rapp.fish", RAPP_FISH)];

/// Writes the hook files under `<term_dir>/shell/` (0700) unless that version is there already; the `shell/` dir.
/// Each file is written to a temporary name and renamed, so a shell starting meanwhile reads a whole file.
#[cfg(unix)]
pub fn install(term_dir: &Path) -> std::io::Result<PathBuf> {
    let dir = term_dir.join("shell");
    for d in [dir.clone(), dir.join("zsh")] {
        std::fs::create_dir_all(&d)?;
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700))?;
    }
    let current = std::fs::read_to_string(dir.join(".v")).is_ok_and(|v| v.trim() == HOOK_V.to_string());
    if current && FILES.iter().all(|(p, _)| dir.join(p).is_file()) {
        return Ok(dir);
    }
    let v = HOOK_V.to_string();
    // `.v` last: it is there only once every file is.
    for (rel, body) in FILES.iter().copied().chain([(".v", v.as_str())]) {
        let path = dir.join(rel);
        let tmp = dir.join(format!("{rel}.{}.tmp", std::process::id()));
        std::fs::write(&tmp, body)?;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        if let Err(e) = std::fs::rename(&tmp, &path) {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
    }
    Ok(dir)
}

/// What a restored terminal activates once its shell is up (from the snapshot).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Restore {
    /// A venv's directory (`$VIRTUAL_ENV`).
    pub venv: Option<String>,
    /// A conda environment's prefix (`$CONDA_PREFIX`).
    pub conda: Option<String>,
}

/// How to start a shell through the hook: its arguments (replacing the command's own), and the environment to set
/// and to take away.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Launch {
    pub args: Vec<String>,
    pub set: Vec<(String, String)>,
    pub unset: Vec<String>,
}

/// The variables the hook files act on; whichever is not set here is taken away, so a stray one from outside is
/// never taken for ours.
const HOOK_VARS: [&str; 4] = ["RAPP_ZDOTDIR", "RAPP_BASH_LOGIN", "RAPP_RESTORE_VENV", "RAPP_RESTORE_CONDA"];

/// How to start `command` (`[shell, "-l"]` or `[shell]`) with the hook in `hook_dir`; none for any other shell or
/// arguments. `env_zdotdir` is the `ZDOTDIR` the shell would have had.
pub fn launch(command: &[String], hook_dir: &Path, env_zdotdir: Option<&str>, restore: Option<&Restore>) -> Option<Launch> {
    let (program, rest) = command.split_first()?;
    let login = match rest {
        [] => false,
        [l] if l == "-l" => true,
        _ => return None,
    };
    let at = |f: &str| hook_dir.join(f).to_string_lossy().into_owned();
    let mut set: Vec<(String, String)> = Vec::new();
    let args: Vec<String> = match Path::new(program).file_name()?.to_str()? {
        "zsh" => {
            set.push(("ZDOTDIR".into(), at("zsh")));
            if let Some(z) = env_zdotdir {
                set.push(("RAPP_ZDOTDIR".into(), z.into()));
            }
            rest.to_vec()
        }
        // bash refuses --init-file for a login shell: the hook reads the login files itself.
        "bash" => {
            if login {
                set.push(("RAPP_BASH_LOGIN".into(), "1".into()));
            }
            vec!["--init-file".into(), at("rapp.bash"), "-i".into()]
        }
        // -C runs after the user's config. In fish's single quotes only a backslash and a quote need escaping.
        "fish" => {
            let quoted = at("rapp.fish").replace('\\', "\\\\").replace('\'', "\\'");
            let mut a = if login { vec!["-l".to_string()] } else { vec![] };
            a.extend(["-C".to_string(), format!("source '{quoted}'")]);
            a
        }
        _ => return None,
    };
    if let Some(r) = restore {
        if let Some(v) = &r.venv {
            set.push(("RAPP_RESTORE_VENV".into(), v.clone()));
        }
        if let Some(c) = &r.conda {
            set.push(("RAPP_RESTORE_CONDA".into(), c.clone()));
        }
    }
    let unset = HOOK_VARS.iter().filter(|k| set.iter().all(|(s, _)| s != *k)).map(|k| k.to_string()).collect();
    Some(Launch { args, set, unset })
}

/// One decoded OSC 7502 report.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Report {
    /// `norun`: the hook reports no runs (bash stepped back for a DEBUG trap already set).
    State { cwd: Option<String>, venv: Option<String>, conda: Option<String>, conda_name: Option<String>, norun: bool },
    Run(String),
}

fn b64(s: &[u8]) -> Option<String> {
    String::from_utf8(STANDARD.decode(s).ok()?).ok()
}

/// Parses what follows `7502;` up to the terminator: `state;cwd=<b64>;venv=<b64>;...` or `run;<b64>`.
pub fn parse_report(body: &[u8]) -> Option<Report> {
    let (kind, rest) = match body.iter().position(|&c| c == b';') {
        Some(i) => (&body[..i], &body[i + 1..]),
        None => (body, &body[body.len()..]),
    };
    match kind {
        b"run" => b64(rest).map(Report::Run),
        b"state" => {
            let (mut cwd, mut venv, mut conda, mut conda_name, mut norun) = (None, None, None, None, false);
            for field in rest.split(|&c| c == b';').filter(|f| !f.is_empty()) {
                let i = field.iter().position(|&c| c == b'=')?;
                let (k, v) = (&field[..i], &field[i + 1..]);
                let value = if v.is_empty() { None } else { Some(b64(v)?) };
                match k {
                    b"cwd" => cwd = value,
                    b"venv" => venv = value,
                    b"conda" => conda = value,
                    b"conda_name" => conda_name = value,
                    b"norun" => norun = value.as_deref() == Some("1"),
                    _ => {}
                }
            }
            Some(Report::State { cwd, venv, conda, conda_name, norun })
        }
        _ => None,
    }
}

/// What the holder knows about the shell it runs.
#[derive(Default, Clone, PartialEq, Debug)]
pub struct ShellState {
    /// True after the first 7502 report: the hook is in place.
    pub hooked: bool,
    pub cwd: Option<String>,
    pub venv: Option<String>,
    pub conda: Option<String>,
    pub conda_name: Option<String>,
    /// The raw command line between `run` and the next prompt.
    pub running: Option<String>,
    /// The restored command still waiting for the user.
    pub pending: Option<String>,
    /// The hook said it reports no runs; once said, it holds for the shell.
    pub norun: bool,
}

impl ShellState {
    pub fn apply(&mut self, r: Report) {
        self.hooked = true;
        match r {
            Report::Run(c) => {
                self.running = Some(c);
                self.pending = None;
            }
            Report::State { cwd, venv, conda, conda_name, norun } => {
                self.norun |= norun;
                self.cwd = cwd;
                self.venv = venv;
                self.conda = conda;
                self.conda_name = conda_name;
            }
        }
    }

    /// A prompt was drawn: whatever ran is done. Only meaningful once the hook reports.
    pub fn prompt(&mut self) {
        if self.hooked {
            self.running = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn state_report_parses_fields() {
        assert_eq!(
            parse_report(b"state;cwd=L1VzZXJzL2I=;venv="),
            Some(Report::State { cwd: Some("/Users/b".into()), venv: None, conda: None, conda_name: None, norun: false })
        );
    }

    #[test]
    fn state_report_says_when_runs_are_not_reported() {
        // "1" in base64; a key this side does not know is passed over.
        let r = parse_report(b"state;cwd=L1VzZXJzL2I=;norun=MQ==;later=eA==").unwrap();
        assert_eq!(r, Report::State { cwd: Some("/Users/b".into()), venv: None, conda: None, conda_name: None, norun: true });
        let mut s = ShellState::default();
        s.apply(r);
        assert!(s.hooked && s.norun);
        // It stays said: a later report without it does not take it back.
        s.apply(parse_report(b"state;cwd=L3Q=").unwrap());
        assert!(s.norun);
        let mut s = ShellState::default();
        s.apply(parse_report(b"state;cwd=L3Q=;norun=").unwrap());
        assert!(s.hooked && !s.norun);
    }

    #[test]
    fn run_report_parses() {
        assert_eq!(parse_report(b"run;Y2xhdWRlIC1j"), Some(Report::Run("claude -c".into())));
    }

    #[test]
    fn bad_base64_and_unknown_kind_are_none() {
        assert_eq!(parse_report(b"run;!!!"), None);
        assert_eq!(parse_report(b"weird;x"), None);
        assert_eq!(parse_report(b"state;cwd=/plain"), None);
    }

    #[test]
    fn prompt_clears_running_only_when_hooked() {
        let mut s = ShellState { running: Some("x".into()), ..Default::default() };
        s.prompt();
        assert_eq!(s.running.as_deref(), Some("x"));
        s.apply(Report::State { cwd: None, venv: None, conda: None, conda_name: None, norun: false });
        assert!(s.hooked);
        s.prompt();
        assert_eq!(s.running, None);
    }

    fn v(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|x| x.to_string()).collect()
    }

    fn pair(k: &str, val: &str) -> (String, String) {
        (k.to_string(), val.to_string())
    }

    #[test]
    fn zsh_launch_sets_zdotdir_and_keeps_old() {
        let l = launch(&v(&["/bin/zsh", "-l"]), Path::new("/h"), Some("/u/z"), None).unwrap();
        assert_eq!(l.args, v(&["-l"]));
        assert!(l.set.contains(&pair("ZDOTDIR", "/h/zsh")), "{l:?}");
        assert!(l.set.contains(&pair("RAPP_ZDOTDIR", "/u/z")), "{l:?}");
        assert!(!l.unset.contains(&"RAPP_ZDOTDIR".to_string()), "{l:?}");
        // An empty value is a value, kept as it was.
        let l = launch(&v(&["zsh"]), Path::new("/h"), Some(""), None).unwrap();
        assert_eq!(l.args, Vec::<String>::new());
        assert!(l.set.contains(&pair("RAPP_ZDOTDIR", "")), "{l:?}");
    }

    #[test]
    fn zsh_launch_without_old_zdotdir_sets_no_rapp_zdotdir() {
        let l = launch(&v(&["/bin/zsh", "-l"]), Path::new("/h"), None, None).unwrap();
        assert!(l.set.contains(&pair("ZDOTDIR", "/h/zsh")), "{l:?}");
        assert!(l.set.iter().all(|(k, _)| k != "RAPP_ZDOTDIR"), "{l:?}");
        // A stray one from outside would be taken as the user's: it goes.
        assert!(l.unset.contains(&"RAPP_ZDOTDIR".to_string()), "{l:?}");
    }

    #[test]
    fn bash_launch_drops_login_flag() {
        let l = launch(&v(&["/bin/bash", "-l"]), Path::new("/h"), Some("/u/z"), None).unwrap();
        assert_eq!(l.args, v(&["--init-file", "/h/rapp.bash", "-i"]));
        assert!(l.set.contains(&pair("RAPP_BASH_LOGIN", "1")), "{l:?}");
        // No login flag: no login files, and no stray RAPP_BASH_LOGIN from outside either.
        let l = launch(&v(&["bash"]), Path::new("/h"), None, None).unwrap();
        assert_eq!(l.args, v(&["--init-file", "/h/rapp.bash", "-i"]));
        assert!(l.set.iter().all(|(k, _)| k != "RAPP_BASH_LOGIN"), "{l:?}");
        assert!(l.unset.contains(&"RAPP_BASH_LOGIN".to_string()), "{l:?}");
    }

    #[test]
    fn fish_launch_quotes_path() {
        let l = launch(&v(&["/opt/my shells/fish", "-l"]), Path::new(r"/h/it's\x"), None, None).unwrap();
        assert_eq!(l.args, v(&["-l", "-C", r"source '/h/it\'s\\x/rapp.fish'"]));
        let l = launch(&v(&["fish"]), Path::new("/h"), None, None).unwrap();
        assert_eq!(l.args, v(&["-C", "source '/h/rapp.fish'"]));
    }

    #[test]
    fn other_shells_and_commands_get_no_hook() {
        for c in [&["sh", "-l"][..], &["nu"], &["zsh", "-c", "x"], &["claude"], &["/bin/bash", "-l", "-x"], &[]] {
            assert_eq!(launch(&v(c), Path::new("/h"), None, None), None, "{c:?}");
        }
    }

    #[test]
    fn restore_goes_into_the_environment_and_stray_ones_go() {
        let r = Restore { venv: Some("/p/v".into()), conda: Some("/c/e".into()) };
        let l = launch(&v(&["zsh", "-l"]), Path::new("/h"), None, Some(&r)).unwrap();
        assert!(l.set.contains(&pair("RAPP_RESTORE_VENV", "/p/v")) && l.set.contains(&pair("RAPP_RESTORE_CONDA", "/c/e")), "{l:?}");
        let r = Restore { venv: Some("/p/v".into()), conda: None };
        for l in [
            launch(&v(&["bash", "-l"]), Path::new("/h"), None, Some(&r)).unwrap(),
            launch(&v(&["fish", "-l"]), Path::new("/h"), None, None).unwrap(),
        ] {
            assert!(l.set.iter().all(|(k, _)| k != "RAPP_RESTORE_CONDA"), "{l:?}");
            assert!(l.unset.contains(&"RAPP_RESTORE_CONDA".to_string()), "{l:?}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn install_rewrites_on_version_change() {
        let d = tempfile::tempdir().unwrap();
        let dir = install(d.path()).unwrap();
        assert_eq!(dir, d.path().join("shell"));
        let read = |p: &str| std::fs::read_to_string(dir.join(p)).unwrap();
        assert_eq!(read("zsh/.zshenv"), ZSHENV);
        assert_eq!(read("rapp.zsh"), RAPP_ZSH);
        assert_eq!(read("rapp.bash"), RAPP_BASH);
        assert_eq!(read("rapp.fish"), RAPP_FISH);
        assert_eq!(read(".v"), HOOK_V.to_string());
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!((mode(&dir), mode(&dir.join("zsh"))), (0o700, 0o700));
        // The same version: what is there stays.
        std::fs::write(dir.join("rapp.zsh"), "old").unwrap();
        install(d.path()).unwrap();
        assert_eq!(read("rapp.zsh"), "old");
        // Another version: all of it is written again.
        std::fs::write(dir.join(".v"), "0").unwrap();
        install(d.path()).unwrap();
        assert_eq!((read("rapp.zsh"), read(".v")), (RAPP_ZSH.to_string(), HOOK_V.to_string()));
        // A file gone is written again too.
        std::fs::remove_file(dir.join("rapp.bash")).unwrap();
        install(d.path()).unwrap();
        assert_eq!(read("rapp.bash"), RAPP_BASH);
        // No temporary files left behind.
        let names: Vec<_> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names.len(), 5, "{names:?}");
    }

    #[test]
    fn run_clears_pending() {
        let mut s = ShellState { pending: Some("claude -c".into()), ..Default::default() };
        s.apply(Report::Run("ls".into()));
        assert_eq!((s.pending, s.running.as_deref()), (None, Some("ls")));
    }
}
