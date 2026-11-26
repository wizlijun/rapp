//! The pieces of `rapp-service`'s start that differ on Windows (spec §5.3): arguments,
//! "the supervisor went away" (`--supervised`), the single-instance name and the update cache.
//! No `cfg` here, so all of it is tested on every system.

use std::path::PathBuf;
use tokio::io::AsyncReadExt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Args {
    /// Started by `rapp-svc`: stdin is the supervisor's pipe, and its end means stop.
    pub supervised: bool,
}

const USAGE_UNIX: &str = "usage: rapp-service   (data root: $RAPP_HOME, data-root pointer or ~/rapp)";
const USAGE_WINDOWS: &str =
    r"usage: rapp-service [--supervised]   (data root: %RAPP_HOME%, data-root pointer or %USERPROFILE%\rapp)";

/// The arguments after the program name. `windows` is `cfg!(windows)` at the call site. Off
/// Windows any argument is a usage error, as before. `Err` is the usage line.
pub fn parse_args(args: &[String], windows: bool) -> Result<Args, String> {
    if !windows {
        return if args.is_empty() { Ok(Args { supervised: false }) } else { Err(USAGE_UNIX.into()) };
    }
    match args {
        [] => Ok(Args { supervised: false }),
        [a] if a == "--supervised" => Ok(Args { supervised: true }),
        _ => Err(USAGE_WINDOWS.into()),
    }
}

/// Resolves when `r` reaches end of input or fails. Bytes read are thrown away.
pub async fn closed<R: tokio::io::AsyncRead + Unpin>(mut r: R) {
    let mut buf = [0u8; 256];
    loop {
        match r.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
    }
}

/// The single-instance name. `prelogin` is always false in this phase (phase F passes true).
pub fn mutex_name(session: u32, prelogin: bool) -> String {
    let mut name = format!(r"Local\com.rapp.service.{session}");
    if prelogin {
        name.push_str(".prelogin");
    }
    name
}

/// Where downloaded updates wait. `system_mode`: installed with the system service
/// (`%ProgramData%\rapp\update`); otherwise `%LOCALAPPDATA%\rapp\update`, else
/// `%USERPROFILE%\AppData\Local\rapp\update`, else the temporary directory's `rapp\update`.
pub fn update_cache_dir_from(env: &dyn Fn(&str) -> Option<PathBuf>, system_mode: bool) -> PathBuf {
    let var = |k: &str| env(k).filter(|p| !p.as_os_str().is_empty());
    let base = if system_mode {
        var("ProgramData").unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"))
    } else {
        var("LOCALAPPDATA")
            .or_else(|| var("USERPROFILE").map(|u| u.join("AppData").join("Local")))
            .unwrap_or_else(std::env::temp_dir)
    };
    base.join("rapp").join("update")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use std::time::Duration;
    use tokio::io::AsyncWriteExt;

    #[test]
    fn arguments() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert!(!parse_args(&s(&[]), false).unwrap().supervised);
        assert!(parse_args(&s(&["--supervised"]), false).is_err()); // macOS, Linux: unchanged
        assert_eq!(
            parse_args(&s(&["x"]), false).unwrap_err(),
            "usage: rapp-service   (data root: $RAPP_HOME, data-root pointer or ~/rapp)"
        );
        assert!(!parse_args(&s(&[]), true).unwrap().supervised);
        assert!(parse_args(&s(&["--supervised"]), true).unwrap().supervised);
        assert!(parse_args(&s(&["--prelogin"]), true).is_err()); // phase F
        assert!(parse_args(&s(&["--supervised", "--supervised"]), true).is_err());
        assert_eq!(
            parse_args(&s(&["x"]), true).unwrap_err(),
            r"usage: rapp-service [--supervised]   (data root: %RAPP_HOME%, data-root pointer or %USERPROFILE%\rapp)"
        );
    }

    #[tokio::test]
    async fn closed_waits_for_end_of_input() {
        // Review Focus 5: input alone is not the end; only the pipe closing is.
        let (mut w, r) = tokio::io::duplex(64);
        let c = tokio::spawn(closed(r));
        w.write_all(b"junk\n").await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!c.is_finished());
        drop(w);
        tokio::time::timeout(Duration::from_secs(1), c).await.expect("closed finishes").unwrap();
    }

    #[test]
    fn names() {
        assert_eq!(mutex_name(3, false), r"Local\com.rapp.service.3");
        assert_eq!(mutex_name(0, true), r"Local\com.rapp.service.0.prelogin");
    }

    #[test]
    fn cache_dirs() {
        let (p, l, u) = (Path::new("P"), Path::new("L"), Path::new("U"));
        let env = |vars: Vec<(&'static str, PathBuf)>| move |k: &str| vars.iter().find(|(n, _)| *n == k).map(|(_, v)| v.clone());
        let all = || vec![("ProgramData", p.to_path_buf()), ("LOCALAPPDATA", l.to_path_buf()), ("USERPROFILE", u.to_path_buf())];
        let update = |b: &Path| b.join("rapp").join("update");

        assert_eq!(update_cache_dir_from(&env(all()), true), update(p));
        let no_program_data = vec![("LOCALAPPDATA", l.to_path_buf()), ("USERPROFILE", u.to_path_buf())];
        assert_eq!(update_cache_dir_from(&env(no_program_data), true), update(Path::new(r"C:\ProgramData")));

        assert_eq!(update_cache_dir_from(&env(all()), false), update(l));
        let no_local = vec![("ProgramData", p.to_path_buf()), ("USERPROFILE", u.to_path_buf())];
        assert_eq!(update_cache_dir_from(&env(no_local), false), update(&u.join("AppData").join("Local")));
    }
}
