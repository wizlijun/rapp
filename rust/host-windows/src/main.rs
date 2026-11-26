//! `rapp-host` on Windows (spec §5.3). A shell until phase D.

#[cfg(windows)]
fn main() {
    eprintln!("rapp-host: 这一版还不能当被控端");
    std::process::exit(1);
}

#[cfg(not(windows))]
fn main() {
    eprintln!("rapp-host: 只支持 Windows");
    std::process::exit(2);
}
