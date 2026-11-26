#[cfg(target_os = "linux")]
pub mod accessibility;
#[cfg(target_os = "linux")]
mod capture;
#[cfg(target_os = "linux")]
pub mod clipboard;
#[cfg(target_os = "linux")]
pub mod desktop;
pub mod encode;
pub mod gate;
// Shared so its tests run everywhere; only the Linux server uses it.
#[cfg(target_os = "linux")]
pub mod input_source;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod pause;
// Shared so its tests run everywhere; only the Linux server uses it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod pacing;
// Shared so its tests run everywhere; only the Linux input source uses it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod select_wait;
#[cfg(target_os = "linux")]
pub mod server;
#[cfg(target_os = "linux")]
pub mod transfers;
pub mod wire;
