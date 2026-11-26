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
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod pause;
#[cfg(target_os = "linux")]
pub mod input_source;
// Shared so its tests run everywhere; only the Linux server uses it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod pacing;
#[cfg(target_os = "linux")]
pub mod server;
#[cfg(target_os = "linux")]
pub mod transfers;
// Shared so its tests run everywhere; only the Linux input source uses it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod select_wait;
pub mod wire;
