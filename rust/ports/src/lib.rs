//! Local ports for other devices' shares, in one place for every device that has them: the
//! service on a PC, and the hub embedded in an app that has no service (iOS, later Android).
//! The table and its placement rules (`maps`), carrying a connection to the device (`carry`).

mod ask;
mod carry;
mod maps;

pub use ask::{known_hosts, known_ids, open, reply_err, request, shares_of, KnownHost, PipeErr, Way};
pub use carry::{ensure_all, number, numbers, serve, wants, Carrier, OnDead, RELISTEN_AFTER};
pub use maps::{free, listen, Map, Maps, Serve, COUNT, FIRST};
