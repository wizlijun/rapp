//! Which shells this machine has, found from plain inputs so every platform's rules can be tested anywhere.

use serde::Serialize;

/// One shell a window can run: the button's `name`, where it is, and whether it is the user's own.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Shell {
    pub name: String,
    pub path: String,
    pub default: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Os {
    Mac,
    Linux,
    Windows,
}

/// What `find` looks at. Paths are text so Windows rules run on any OS.
pub struct Env<'a> {
    /// The content of `/etc/shells`.
    pub etc_shells: &'a str,
    pub path: &'a str,
    /// The user's login shell.
    pub login: Option<&'a str>,
    pub system_root: Option<&'a str>,
    pub program_files: Option<&'a str>,
    /// Whether the path is an executable file.
    pub is_exec: &'a dyn Fn(&str) -> bool,
    /// The full paths of the directories in a directory.
    pub subdirs: &'a dyn Fn(&str) -> Vec<String>,
}

/// Directories searched after `/etc/shells` and `PATH`: `serve` runs under launchd, whose PATH is short.
const UNIX_EXTRA: [&str; 4] = ["/opt/homebrew/bin", "/usr/local/bin", "/bin", "/usr/bin"];

/// The installed shells: the default one first, then the others in candidate order.
pub fn find(os: Os, env: &Env) -> Vec<Shell> {
    match os {
        Os::Windows => find_windows(env),
        _ => find_unix(os, env),
    }
}

fn find_unix(os: Os, env: &Env) -> Vec<Shell> {
    let names: [&str; 5] = match os {
        Os::Mac => ["zsh", "bash", "sh", "fish", "tcsh"],
        _ => ["bash", "sh", "zsh", "fish", "dash"],
    };
    let listed: Vec<&str> = env
        .etc_shells
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect();
    let mut shells: Vec<Shell> = Vec::new();
    for name in names {
        let from_list = listed.iter().map(|p| p.to_string()).filter(|p| p.rsplit('/').next() == Some(name));
        let from_dirs = env
            .path
            .split(':')
            .filter(|d| !d.is_empty())
            .chain(UNIX_EXTRA)
            .map(|d| format!("{}/{name}", d.trim_end_matches('/')));
        if let Some(path) = from_list.chain(from_dirs).find(|p| (env.is_exec)(p)) {
            shells.push(Shell { name: name.into(), path, default: false });
        }
    }
    if !shells.iter().any(|s| s.name == "sh") {
        shells.push(Shell { name: "sh".into(), path: "/bin/sh".into(), default: false });
    }
    let login = env.login.filter(|p| (env.is_exec)(p));
    let default = match login {
        Some(p) => {
            let name = p.rsplit('/').next().unwrap_or(p);
            match shells.iter().position(|s| s.name == name) {
                Some(i) => i,
                None => {
                    shells.push(Shell { name: name.into(), path: p.into(), default: false });
                    shells.len() - 1
                }
            }
        }
        None => shells.iter().position(|s| s.name == "sh").unwrap_or(0),
    };
    first(shells, default)
}

fn find_windows(env: &Env) -> Vec<Shell> {
    let path_dirs: Vec<&str> = env.path.split(';').map(|d| d.trim_end_matches('\\')).filter(|d| !d.is_empty()).collect();
    let join = |dir: &str, rest: &str| format!("{}\\{rest}", dir.trim_end_matches('\\'));
    let sys32 = env.system_root.map(|r| join(r, "System32"));
    let pf = env.program_files;
    let exec = |p: &String| (env.is_exec)(p);
    let git_dirs = || path_dirs.iter().filter(|d| format!("{}\\", d.to_lowercase()).contains("\\git\\"));

    let cmd = sys32.iter().map(|d| join(d, "cmd.exe")).find(exec);
    let powershell = sys32.iter().map(|d| join(d, "WindowsPowerShell\\v1.0\\powershell.exe")).find(exec);
    let pwsh = pf
        .iter()
        .flat_map(|p| (env.subdirs)(&join(p, "PowerShell")))
        .map(|d| join(&d, "pwsh.exe"))
        .chain(path_dirs.iter().map(|d| join(d, "pwsh.exe")))
        .find(exec);
    let git = |exe: &str| {
        pf.iter().map(|p| join(p, &format!("Git\\bin\\{exe}"))).chain(git_dirs().map(|d| join(d, exe))).find(exec)
    };
    let mut shells: Vec<Shell> = Vec::new();
    for (name, path) in [
        ("cmd", cmd),
        ("PowerShell", powershell),
        ("pwsh", pwsh),
        ("Git Bash", git("bash.exe")),
        ("Git sh", git("sh.exe")),
    ] {
        if let Some(path) = path {
            shells.push(Shell { name: name.into(), path, default: false });
        }
    }
    if !shells.iter().any(|s| s.name == "cmd") {
        let path = sys32.map(|d| join(&d, "cmd.exe")).unwrap_or_else(|| "cmd.exe".into());
        shells.insert(0, Shell { name: "cmd".into(), path, default: false });
    }
    let default = shells.iter().position(|s| s.name == "cmd").unwrap_or(0);
    first(shells, default)
}

/// `shells` with the one at `default` marked and moved to the front.
fn first(mut shells: Vec<Shell>, default: usize) -> Vec<Shell> {
    let mut d = shells.remove(default);
    d.default = true;
    shells.insert(0, d);
    shells
}

/// The shells on this machine now.
#[cfg(unix)]
pub fn here() -> Vec<Shell> {
    use std::os::unix::fs::PermissionsExt;
    let etc = std::fs::read_to_string("/etc/shells").unwrap_or_default();
    let path = std::env::var("PATH").unwrap_or_default();
    let login = login_shell();
    let is_exec = |p: &str| std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0);
    let os = if cfg!(target_os = "macos") { Os::Mac } else { Os::Linux };
    find(
        os,
        &Env {
            etc_shells: &etc,
            path: &path,
            login: login.as_deref(),
            system_root: None,
            program_files: None,
            is_exec: &is_exec,
            subdirs: &|_| Vec::new(),
        },
    )
}

/// `pw_shell` of the user this process runs as; `$SHELL` is often missing under launchd.
#[cfg(unix)]
fn login_shell() -> Option<String> {
    use std::ffi::CStr;
    // SAFETY: getpwuid returns null or a record that stays valid until the next passwd call; it is copied at once.
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() || (*pw).pw_shell.is_null() {
            return None;
        }
        CStr::from_ptr((*pw).pw_shell).to_str().ok().filter(|s| !s.is_empty()).map(String::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn run(os: Os, etc: &str, path: &str, login: Option<&str>, exec: &[&str]) -> Vec<Shell> {
        let set: HashSet<String> = exec.iter().map(|s| s.to_string()).collect();
        let is_exec = |p: &str| set.contains(p);
        let subdirs = |d: &str| {
            let prefix = format!("{d}\\");
            let mut v: Vec<String> = set
                .iter()
                .filter_map(|p| p.strip_prefix(&prefix).and_then(|r| r.split('\\').next().filter(|_| r.contains('\\'))))
                .map(|n| format!("{prefix}{n}"))
                .collect();
            v.sort();
            v.dedup();
            v
        };
        find(
            os,
            &Env {
                etc_shells: etc,
                path,
                login,
                system_root: Some("C:\\Windows"),
                program_files: Some("C:\\Program Files"),
                is_exec: &is_exec,
                subdirs: &subdirs,
            },
        )
    }

    fn names(v: &[Shell]) -> Vec<&str> {
        v.iter().map(|s| s.name.as_str()).collect()
    }

    fn sh(name: &str, path: &str, default: bool) -> Shell {
        Shell { name: name.into(), path: path.into(), default }
    }

    #[test]
    fn mac_lists_only_what_exists() {
        let v = run(Os::Mac, "", "/usr/bin:/bin", Some("/bin/zsh"), &["/bin/zsh", "/bin/bash", "/bin/sh"]);
        assert_eq!(names(&v), ["zsh", "bash", "sh"]);
        assert_eq!(v.iter().filter(|s| s.default).count(), 1);
        assert!(v[0].default);
    }

    #[test]
    fn homebrew_fish_is_found_without_path() {
        let v = run(Os::Mac, "", "/usr/bin:/bin", Some("/bin/zsh"), &["/bin/zsh", "/bin/sh", "/opt/homebrew/bin/fish"]);
        assert_eq!(v.iter().find(|s| s.name == "fish"), Some(&sh("fish", "/opt/homebrew/bin/fish", false)));
    }

    #[test]
    fn etc_shells_wins_over_path() {
        let v = run(
            Os::Mac,
            "# shells\n/bin/sh\n/usr/local/bin/bash\n",
            "/bin",
            Some("/bin/sh"),
            &["/usr/local/bin/bash", "/bin/bash", "/bin/sh"],
        );
        assert_eq!(v.iter().find(|s| s.name == "bash").unwrap().path, "/usr/local/bin/bash");
    }

    #[test]
    fn a_login_shell_outside_the_candidates_comes_first() {
        let v = run(Os::Mac, "", "/bin", Some("/usr/local/bin/nu"), &["/usr/local/bin/nu", "/bin/zsh", "/bin/sh"]);
        assert_eq!(v[0], sh("nu", "/usr/local/bin/nu", true));
        assert_eq!(names(&v), ["nu", "zsh", "sh"]);
    }

    #[test]
    fn a_missing_login_shell_falls_back_to_bin_sh() {
        let v = run(Os::Mac, "", "/bin", Some("/bin/nope"), &["/bin/zsh", "/bin/sh"]);
        assert_eq!(v[0], sh("sh", "/bin/sh", true));
        assert_eq!(v.iter().filter(|s| s.default).count(), 1);
    }

    #[test]
    fn nothing_found_lists_only_the_fallback() {
        assert_eq!(run(Os::Mac, "", "/bin", Some("/bin/zsh"), &[]), [sh("sh", "/bin/sh", true)]);
        assert_eq!(run(Os::Linux, "", "", None, &[]), [sh("sh", "/bin/sh", true)]);
    }

    #[test]
    fn linux_order() {
        let all = ["/bin/bash", "/bin/sh", "/bin/zsh", "/usr/bin/fish", "/bin/dash"];
        let v = run(Os::Linux, "", "/bin:/usr/bin", Some("/bin/bash"), &all);
        assert_eq!(names(&v), ["bash", "sh", "zsh", "fish", "dash"]);
        let v = run(Os::Linux, "", "/bin:/usr/bin", Some("/bin/zsh"), &all);
        assert_eq!(names(&v), ["zsh", "bash", "sh", "fish", "dash"]);
    }

    #[test]
    fn windows_rules() {
        let v = run(
            Os::Windows,
            "",
            "C:\\Windows\\System32",
            None,
            &[
                "C:\\Windows\\System32\\cmd.exe",
                "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                "C:\\Windows\\System32\\bash.exe",
                "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
                "C:\\Program Files\\Git\\bin\\bash.exe",
                "C:\\Program Files\\Git\\bin\\sh.exe",
            ],
        );
        assert_eq!(names(&v), ["cmd", "PowerShell", "pwsh", "Git Bash", "Git sh"]);
        assert!(v[0].default);
        assert_eq!(v[3].path, "C:\\Program Files\\Git\\bin\\bash.exe");
        assert_eq!(v[2].path, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
    }

    #[test]
    fn wsl_bash_is_not_git_bash() {
        let v = run(
            Os::Windows,
            "",
            "C:\\Windows\\System32",
            None,
            &["C:\\Windows\\System32\\cmd.exe", "C:\\Windows\\System32\\bash.exe"],
        );
        assert_eq!(names(&v), ["cmd"]);
    }

    #[test]
    fn windows_git_on_path() {
        let v = run(
            Os::Windows,
            "",
            "D:\\tools\\Git\\bin;D:\\other",
            None,
            &["C:\\Windows\\System32\\cmd.exe", "D:\\tools\\Git\\bin\\bash.exe", "D:\\other\\sh.exe"],
        );
        assert_eq!(names(&v), ["cmd", "Git Bash"]);
        assert_eq!(v[1].path, "D:\\tools\\Git\\bin\\bash.exe");
    }

    #[cfg(unix)]
    #[test]
    fn this_machine_has_one_default_and_the_fallback() {
        let v = here();
        assert_eq!(v.iter().filter(|s| s.default).count(), 1);
        assert!(v.iter().any(|s| s.name == "sh"));
    }
}
