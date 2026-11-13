use std::process::Command;

#[test]
fn version_flag_prints_version() {
    let out = Command::new(env!("CARGO_BIN_EXE_rapp-relay")).arg("--version").output().unwrap();
    assert!(out.status.success());
    assert_eq!(String::from_utf8(out.stdout).unwrap(), format!("rapp-relay {}\n", env!("CARGO_PKG_VERSION")));
}
