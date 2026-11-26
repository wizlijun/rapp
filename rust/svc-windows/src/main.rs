//! `rapp-svc`, the Windows supervisor (spec §5.3). A shell until phase C.

#[cfg(windows)]
fn main() {
    eprintln!("rapp-svc: 这一版还没有监督程序");
    std::process::exit(1);
}

#[cfg(not(windows))]
fn main() {
    eprintln!("rapp-svc: 只支持 Windows");
    std::process::exit(2);
}
