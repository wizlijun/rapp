//! What the pty's foreground process group is running, and where.

use std::path::PathBuf;

/// The foreground program of a holder. A failed read keeps the last value.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Fg {
    /// argv[0]'s file name (no leading `-`), else the process name.
    pub prog: Option<String>,
    /// The program's current directory.
    pub cwd: Option<PathBuf>,
    /// True when the foreground group is the process the holder started.
    pub shell: bool,
    /// True once a probe ran (so `shell` means something).
    pub probed: bool,
    /// The foreground process group (its leader's pid), as last probed.
    pub pgrp: Option<i32>,
}

/// The file name of `argv0`, without a leading `-` (login shells are `-zsh`).
pub fn prog_name(argv0: &str) -> String {
    let base = argv0.rsplit('/').next().unwrap_or(argv0);
    base.trim_start_matches('-').to_string()
}

impl Fg {
    /// Reads the foreground group again; true when anything changed.
    pub fn update(&mut self, pgrp: Option<i32>, child_pid: u32) -> bool {
        let before = self.clone();
        if let Some(g) = pgrp {
            let (prog, cwd) = probe(g);
            if prog.is_some() {
                self.prog = prog;
            }
            if cwd.is_some() {
                self.cwd = cwd;
            }
            self.shell = g as u32 == child_pid;
            self.probed = true;
            self.pgrp = Some(g);
        }
        *self != before
    }
}

/// The program name and current directory of process `pid`; none for what cannot be read.
pub fn probe(pid: i32) -> (Option<String>, Option<PathBuf>) {
    if pid <= 0 {
        return (None, None);
    }
    let prog = argv0(pid).map(|a| prog_name(&a)).filter(|n| !n.is_empty()).or_else(|| proc_name(pid));
    (prog, cwd(pid))
}

#[cfg(target_os = "macos")]
fn argv0(pid: i32) -> Option<String> {
    let buf = procargs2(pid)?;
    let (argv, _) = parse_procargs2(&buf, false)?;
    argv.into_iter().next()
}

/// The kernel's `KERN_PROCARGS2` record of process `pid`.
#[cfg(target_os = "macos")]
fn procargs2(pid: i32) -> Option<Vec<u8>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size = 0usize;
    let null = std::ptr::null_mut();
    if unsafe { libc::sysctl(mib.as_mut_ptr(), 3, null, &mut size, null, 0) } != 0 || size < 5 {
        return None;
    }
    let mut buf = vec![0u8; size];
    if unsafe { libc::sysctl(mib.as_mut_ptr(), 3, buf.as_mut_ptr().cast(), &mut size, null, 0) } != 0 {
        return None;
    }
    buf.truncate(size);
    Some(buf)
}

/// A `KERN_PROCARGS2` record: argc (i32), the exec path, NUL padding, argc argv strings, then the environment up to
/// an empty string. The argv, and (with `env`) the `ENV_KEPT` entries of the environment.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn parse_procargs2(buf: &[u8], env: bool) -> Option<LaunchInfo> {
    let argc = i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?);
    let rest = buf.get(4..)?;
    let after_path = rest.iter().position(|&b| b == 0)?;
    let rest = &rest[after_path..];
    let start = rest.iter().position(|&b| b != 0)?;
    let mut strings = rest[start..].split(|&b| b == 0);
    let mut argv = Vec::new();
    for _ in 0..argc.max(0) {
        argv.push(String::from_utf8_lossy(strings.next()?).into_owned());
    }
    let kept = if env { kept_env(strings.take_while(|s| !s.is_empty())) } else { Vec::new() };
    Some((argv, kept))
}

/// Of `KEY=value` entries, only the `ENV_KEPT` ones.
fn kept_env<'a>(entries: impl Iterator<Item = &'a [u8]>) -> Vec<(String, String)> {
    entries
        .filter_map(|e| {
            let eq = e.iter().position(|&b| b == b'=')?;
            let key = std::str::from_utf8(&e[..eq]).ok()?;
            ENV_KEPT.contains(&key).then(|| (key.to_string(), String::from_utf8_lossy(&e[eq + 1..]).into_owned()))
        })
        .collect()
}

#[cfg(target_os = "linux")]
fn argv0(pid: i32) -> Option<String> {
    let raw = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let first = raw.split(|&b| b == 0).next()?;
    String::from_utf8(first.to_vec()).ok().filter(|s| !s.is_empty())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn argv0(_pid: i32) -> Option<String> {
    None
}

#[cfg(target_os = "macos")]
fn proc_name(pid: i32) -> Option<String> {
    let mut buf = [0u8; 256];
    let n = unsafe { libc::proc_name(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    (n > 0).then(|| String::from_utf8_lossy(&buf[..n as usize]).into_owned())
}

#[cfg(target_os = "linux")]
fn proc_name(pid: i32) -> Option<String> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    Some(s.trim_end().to_string()).filter(|s| !s.is_empty())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn proc_name(_pid: i32) -> Option<String> {
    None
}

#[cfg(target_os = "macos")]
fn cwd(pid: i32) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as i32;
    let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, (&mut info as *mut libc::proc_vnodepathinfo).cast(), size) };
    if n < size {
        return None;
    }
    let path = &info.pvi_cdir.vip_path;
    let bytes: Vec<u8> = path.iter().flat_map(|row| row.iter()).map(|&c| c as u8).take_while(|&b| b != 0).collect();
    (!bytes.is_empty()).then(|| PathBuf::from(std::ffi::OsStr::from_bytes(&bytes)))
}

#[cfg(target_os = "linux")]
fn cwd(pid: i32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn cwd(_pid: i32) -> Option<PathBuf> {
    None
}

/// A process's argv, and the `ENV_KEPT` entries of its starting environment.
pub type LaunchInfo = (Vec<String>, Vec<(String, String)>);

/// The environment variables a snapshot keeps of a foreground program; no other is ever read out.
pub const ENV_KEPT: [&str; 3] = ["VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV"];

/// The argv of process `pid` and, of its starting environment, only the `ENV_KEPT` entries; none when unreadable.
#[cfg(target_os = "macos")]
pub fn launch_info(pid: i32) -> Option<LaunchInfo> {
    if pid <= 0 {
        return None;
    }
    parse_procargs2(&procargs2(pid)?, true).filter(|(argv, _)| !argv.is_empty())
}

/// The argv of process `pid` and, of its starting environment, only the `ENV_KEPT` entries; none when unreadable.
#[cfg(target_os = "linux")]
pub fn launch_info(pid: i32) -> Option<LaunchInfo> {
    if pid <= 0 {
        return None;
    }
    let raw = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let argv: Vec<String> = raw.split(|&b| b == 0).filter(|a| !a.is_empty()).map(|a| String::from_utf8_lossy(a).into_owned()).collect();
    if argv.is_empty() {
        return None;
    }
    let env = std::fs::read(format!("/proc/{pid}/environ")).unwrap_or_default();
    Some((argv, kept_env(env.split(|&b| b == 0))))
}

/// The argv of process `pid` and, of its starting environment, only the `ENV_KEPT` entries; none when unreadable.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn launch_info(_pid: i32) -> Option<LaunchInfo> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn procargs2_record_parses() {
        let mut rec = 2i32.to_ne_bytes().to_vec();
        rec.extend_from_slice(b"/bin/x\0\0\0x\0a b\0HOME=/h\0VIRTUAL_ENV=/v\0TOKEN=s\0\0junk=1\0CONDA_PREFIX=/no\0");
        let (argv, env) = parse_procargs2(&rec, true).unwrap();
        assert_eq!((argv, env), (vec!["x".to_string(), "a b".into()], vec![("VIRTUAL_ENV".to_string(), "/v".to_string())]));
        assert_eq!(parse_procargs2(&rec, false).unwrap().1, vec![]);
        assert_eq!(parse_procargs2(&rec[..3], true), None);
        // Fewer strings than argc says: unreadable.
        let mut short = 3i32.to_ne_bytes().to_vec();
        short.extend_from_slice(b"/bin/x\0x");
        assert_eq!(parse_procargs2(&short, true), None);
    }

    /// Run by `launch_info_reads_argv_and_only_the_kept_env` in a process of its own: a program to read.
    #[test]
    #[ignore]
    fn sleeper() {
        if std::env::var_os("RAPP_FG_SLEEPER").is_some() {
            std::thread::sleep(std::time::Duration::from_secs(5));
        }
    }

    // Windows: no reader of another process yet (the fallbacks above answer None).
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn launch_info_reads_argv_and_only_the_kept_env() {
        // This test binary, not /bin/sleep: macOS keeps the environment of its own (platform) programs unreadable.
        let exe = std::env::current_exe().unwrap();
        let args = ["--exact", "pty::fg::tests::sleeper", "--ignored", "--nocapture"];
        let mut child = std::process::Command::new(&exe)
            .args(args)
            .env_remove("CONDA_PREFIX")
            .env("RAPP_FG_SLEEPER", "1")
            .env("VIRTUAL_ENV", "/x/venv")
            .env("CONDA_DEFAULT_ENV", "ml")
            .env("RAPP_SECRET_TEST", "hunter2")
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        #[cfg(target_os = "linux")]
        let got = {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
            loop {
                let g = launch_info(child.id() as i32);
                if g.as_ref().is_some_and(|(argv, _)| argv.len() > 1) || std::time::Instant::now() >= deadline {
                    break g;
                }
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        };
        #[cfg(not(target_os = "linux"))]
        let got = launch_info(child.id() as i32);
        let _ = child.kill();
        let _ = child.wait();
        let (argv, mut env) = got.expect("readable");
        env.sort();
        assert_eq!(argv[1..], args);
        assert_eq!(env, [("CONDA_DEFAULT_ENV".to_string(), "ml".to_string()), ("VIRTUAL_ENV".into(), "/x/venv".into())]);
        assert_eq!(launch_info(0), None);
    }

    #[test]
    fn prog_name_strips_dash_and_path() {
        assert_eq!(prog_name("-zsh"), "zsh");
        assert_eq!(prog_name("/usr/local/bin/claude"), "claude");
    }

    // Windows: no reader of another process yet (the fallbacks above answer None).
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn probe_self_reads_cwd() {
        let got = probe(std::process::id() as i32).1.unwrap();
        let want = std::env::current_dir().unwrap();
        assert_eq!(got.canonicalize().unwrap(), want.canonicalize().unwrap());
    }

    // Windows: no reader of another process yet (the fallbacks above answer None).
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn probe_self_reads_prog() {
        assert!(probe(std::process::id() as i32).0.is_some_and(|n| !n.is_empty()));
    }

    // Windows: no reader of another process yet (the fallbacks above answer None).
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn update_keeps_last_on_failure() {
        let mut fg = Fg::default();
        let me = std::process::id();
        assert!(fg.update(Some(me as i32), me));
        assert!(fg.shell);
        let good = fg.clone();
        assert!(!fg.update(Some(i32::MAX), 1) || fg.shell != good.shell);
        assert_eq!((fg.prog.clone(), fg.cwd.clone()), (good.prog, good.cwd));
        assert!(!fg.shell);
    }

    #[cfg(unix)]
    #[test]
    fn status_roundtrips_without_new_fields() {
        let old = r#"{"v":1,"name":"a","command":"sh","cols":80,"rows":24,"activity":1,"viewers":0,"pid":2}"#;
        let st: crate::pty::local::Status = serde_json::from_str(old).unwrap();
        assert_eq!((st.fg, st.cwd, st.shell, st.tty), (None, None, None, None));
    }
}
