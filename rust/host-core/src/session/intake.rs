//! A new connection's first message (`Server.swift:162-232`, `Intake`): a connection that
//! says nothing for 5 s of host time is dropped. Reads block with a read timeout taken from
//! the clock, so a scaled test clock shortens the wait too.

use std::io::{ErrorKind, Read};
use std::net::TcpStream;
use std::time::Duration;

use crate::clock::Clock;
use crate::protocol::{CodecError, Message, MessageParser};

/// How long a connection may stay silent before its first message (`Server.swift:192`).
pub const HELLO_WAIT: f64 = 5.0;
/// Read slice: the timeout of one blocking read, in host seconds.
pub const READ_SLICE: f64 = 0.25;

pub enum Outcome {
    First(Message, MessageParser),
    Rejected { reason: String, notify: bool },
}

/// Swift tells a version mismatch apart by its error type; here by its fixed text.
pub fn is_version_mismatch(e: &CodecError) -> bool {
    e.0.starts_with("protocol version mismatch")
}

/// The text a parse error ends a connection or session with.
pub fn bad_data_reason(e: &CodecError) -> String {
    if is_version_mismatch(e) {
        e.0.clone()
    } else {
        format!("bad data from client: {e}")
    }
}

pub fn read_timeout(clock: &dyn Clock, seconds: f64) -> Duration {
    clock.real(seconds).max(Duration::from_millis(1))
}

/// Reads until the first whole message, a parse error, EOF, or the 5 s limit.
pub fn first_message(stream: &mut TcpStream, clock: &dyn Clock) -> Outcome {
    let start = clock.now();
    let mut parser = MessageParser::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        match parser.next() {
            Ok(Some(m)) => return Outcome::First(m, parser),
            Ok(None) => {}
            Err(e) => return Outcome::Rejected { reason: bad_data_reason(&e), notify: true },
        }
        let left = HELLO_WAIT - (clock.now() - start);
        if left <= 0.0 {
            return Outcome::Rejected { reason: "no hello received".into(), notify: true };
        }
        if stream.set_read_timeout(Some(read_timeout(clock, left.min(READ_SLICE)))).is_err() {
            return Outcome::Rejected { reason: "connection error: cannot set a read timeout".into(), notify: false };
        }
        match stream.read(&mut buf) {
            Ok(0) => return Outcome::Rejected { reason: "client disconnected".into(), notify: false },
            Ok(n) => parser.append(&buf[..n]),
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted) => {}
            Err(e) => return Outcome::Rejected { reason: format!("connection error: {e}"), notify: false },
        }
    }
}
