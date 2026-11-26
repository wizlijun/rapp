#![cfg(not(windows))]

#[test]
fn says_windows_only_elsewhere() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_rapp-svc")).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(String::from_utf8_lossy(&out.stderr).trim(), "rapp-svc: 只支持 Windows");
    assert!(out.stdout.is_empty());
}
