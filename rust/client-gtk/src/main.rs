#[cfg(target_os = "linux")]
mod ui;

fn main() {
    #[cfg(target_os = "linux")]
    std::process::exit(ui::run());
    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("rapp-client-gtk requires Linux");
        std::process::exit(2);
    }
}
