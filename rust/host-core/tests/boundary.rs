//! host-core stays OS-independent: no OS-specific code or dependency, and all
//! time goes through `clock::Clock`. The platform crates hold everything else.

use std::path::{Path, PathBuf};

fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir).expect("read src").map(|e| e.expect("entry").path()).collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

fn sources() -> Vec<(PathBuf, String)> {
    let mut files = Vec::new();
    rust_files(&crate_dir().join("src"), &mut files);
    assert!(!files.is_empty(), "no sources found");
    files
        .into_iter()
        .map(|p| {
            let text = std::fs::read_to_string(&p).expect("read source");
            (p, text)
        })
        .collect()
}

fn offenders(files: &[(PathBuf, String)], needles: &[&str]) -> Vec<String> {
    let mut out = Vec::new();
    for (path, text) in files {
        for (n, line) in text.lines().enumerate() {
            for needle in needles {
                if line.contains(needle) {
                    out.push(format!("{}:{}: `{}`", path.display(), n + 1, needle));
                }
            }
        }
    }
    out
}

#[test]
fn no_os_specific_code() {
    let needles = [
        "cfg(windows",
        "cfg(unix",
        "target_os",
        "target_family",
        "libc::",
        "tokio",
        "windows_sys",
        "windows::",
        "std::os::",
    ];
    let found = offenders(&sources(), &needles);
    assert!(found.is_empty(), "OS-specific code in host-core:\n{}", found.join("\n"));
}

#[test]
fn time_goes_through_clock() {
    let files: Vec<_> = sources().into_iter().filter(|(p, _)| !p.ends_with("src/clock.rs")).collect();
    let found = offenders(&files, &["Instant::now", "SystemTime::now", "thread::sleep"]);
    assert!(found.is_empty(), "time read or waited outside clock.rs:\n{}", found.join("\n"));
}

#[test]
fn cargo_has_no_os_dependency() {
    let text = std::fs::read_to_string(crate_dir().join("Cargo.toml")).expect("read Cargo.toml");
    let mut found = Vec::new();
    for (n, line) in text.lines().enumerate() {
        for needle in ["libc", "windows", "tokio", "flate2", "[target."] {
            if line.contains(needle) {
                found.push(format!("Cargo.toml:{}: `{}`", n + 1, needle));
            }
        }
    }
    assert!(found.is_empty(), "OS dependency in host-core's Cargo.toml:\n{}", found.join("\n"));
}
