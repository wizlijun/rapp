#![cfg(windows)]
#[test]
fn every_subcommand_says_not_supported() {
    for args in [&["version"][..], &["version", "--json"], &["run"], &["serve", "--token-env", "T", "--config", "c"], &[]] {
        let out = std::process::Command::new(env!("CARGO_BIN_EXE_rapp-term")).args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(1), "{args:?}");
        assert_eq!(String::from_utf8(out.stderr).unwrap().trim(), "rapp-term: Windows 上还不支持文本终端");
        assert!(out.stdout.is_empty());
    }
}
