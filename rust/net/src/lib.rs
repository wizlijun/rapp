//! Shared pieces of rapp-service and rapp-hub (spec §1).

pub mod addr;
pub mod bins;
pub mod config;
pub mod crypto;
pub mod datadir;
pub mod line;
pub mod log;
pub mod logq;
pub mod msg;
pub mod private;
pub mod proc;
pub mod quic;
pub mod udp;
#[cfg(windows)]
pub mod win;
