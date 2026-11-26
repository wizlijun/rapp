//! The `rapp-term` command. Unix: `unix_main`. Windows: not yet (phase E), every call says so.

#[cfg(unix)]
mod unix_main;
#[cfg(not(unix))]
mod stub_main;

fn main() {
    #[cfg(unix)]
    unix_main::main();
    #[cfg(not(unix))]
    stub_main::main();
}
