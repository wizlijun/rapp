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
    // argc (i32), the exec path, NUL padding, then argv[0].
    let rest = buf.get(4..)?;
    let after_path = rest.iter().position(|&b| b == 0)?;
    let rest = &rest[after_path..];
    let start = rest.iter().position(|&b| b != 0)?;
    let rest = &rest[start..];
    let end = rest.iter().position(|&b| b == 0).unwrap_or(rest.len());
    String::from_utf8(rest[..end].to_vec()).ok()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prog_name_strips_dash_and_path() {
        assert_eq!(prog_name("-zsh"), "zsh");
        assert_eq!(prog_name("/usr/local/bin/claude"), "claude");
    }

    #[test]
    fn probe_self_reads_cwd() {
        let got = probe(std::process::id() as i32).1.unwrap();
        let want = std::env::current_dir().unwrap();
        assert_eq!(got.canonicalize().unwrap(), want.canonicalize().unwrap());
    }

    #[test]
    fn probe_self_reads_prog() {
        assert!(probe(std::process::id() as i32).0.is_some_and(|n| !n.is_empty()));
    }

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

    #[test]
    fn status_roundtrips_without_new_fields() {
        let old = r#"{"v":1,"name":"a","command":"sh","cols":80,"rows":24,"activity":1,"viewers":0,"pid":2}"#;
        let st: crate::pty::local::Status = serde_json::from_str(old).unwrap();
        assert_eq!((st.fg, st.cwd, st.shell, st.tty), (None, None, None, None));
    }
}
