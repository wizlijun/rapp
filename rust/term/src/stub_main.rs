//! `rapp-term` where text terminals are not supported yet (Windows before phase E): any arguments, one line on
//! stderr, exit 1, nothing on stdout.

pub fn main() {
    eprintln!("rapp-term: Windows 上还不支持文本终端");
    std::process::exit(1);
}
