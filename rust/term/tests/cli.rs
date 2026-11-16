use std::process::{Command, Stdio};

const BIN: &str = env!("CARGO_BIN_EXE_rapp-term");

/// What one finished run of the binary left behind.
struct O {
    code: i32,
    stderr: String,
}

fn run(args: &[&str]) -> O {
    let out = Command::new(BIN).args(args).stdin(Stdio::null()).output().unwrap();
    O {
        code: out.status.code().expect("rapp-term was killed by a signal"),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

#[test]
fn version_json() {
    let o = Command::new(BIN).args(["version", "--json"]).output().unwrap();
    assert_eq!(o.status.code(), Some(0));
    let v: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(v["proto"], 2);
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
}

#[test]
fn bad_arguments_exit_2() {
    for a in [
        &[][..],
        &["nope"],
        // The subcommands and options of the removed backend are unknown now.
        &["list"],
        &["watch", "term:pty:x"],
        &["new", "--", "sh"],
        &["version", "--socket", "x"],
        &["serve", "--ssh", "x"],
        &["run", "--tmux", "x"],
    ] {
        assert_eq!(run(a).code, 2, "{a:?}");
    }
}

#[test]
fn run_refuses_a_cwd_that_is_not_a_directory_without_echoing_it() {
    let d = tempfile::Builder::new().prefix("rt").tempdir_in("/tmp").unwrap();
    let file = d.path().join("SECRET-FILE");
    std::fs::write(&file, b"").unwrap();
    let missing = d.path().join("SECRET-MISSING");
    let dir = d.path().to_str().unwrap();
    for cwd in [&file, &missing] {
        let o = run(&["run", "--dir", dir, "--cwd", cwd.to_str().unwrap(), "--", "/bin/cat"]);
        assert_eq!(o.code, 2, "{cwd:?}");
        assert!(o.stderr.contains("--cwd is not a directory"), "{}", o.stderr);
        assert!(!o.stderr.contains("SECRET"), "{}", o.stderr);
    }
}
