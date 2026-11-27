//! Opt-in timing only: no pixels, text, clipboard, credentials or window titles.
use std::{
    fmt,
    fs::{File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

static DIR: OnceLock<PathBuf> = OnceLock::new();

/// Sets the trace dir; the first call wins and its dir is returned. Call it before the
/// first `record`: the file is opened once, on the first `record`, and stays as it is.
pub fn trace_to(dir: PathBuf) -> &'static Path {
    DIR.get_or_init(|| dir)
}

pub(super) fn record(stage: &str, detail: fmt::Arguments<'_>) {
    static FILE: OnceLock<Option<Mutex<File>>> = OnceLock::new();
    let file = FILE.get_or_init(|| {
        let path = DIR.get()?.join(format!("worker-{}.log", std::process::id()));
        let mut options = OpenOptions::new();
        options.create(true).append(true);
        #[cfg(unix)]
        options.mode(0o600);
        options.open(path).ok().map(Mutex::new)
    });
    let Some(file) = file else { return };
    let Ok(mut file) = file.lock() else { return };
    let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH) else { return };
    let _ = writeln!(file, "{} {stage} {detail}", now.as_micros());
}
