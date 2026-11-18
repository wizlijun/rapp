#[cfg(target_os = "linux")]
mod capture;
#[cfg(target_os = "linux")]
pub mod desktop;
pub mod encode;
pub mod gate;
#[cfg(target_os = "linux")]
pub mod server;
pub mod wire;
