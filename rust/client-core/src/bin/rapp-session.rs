//! Headless Linux session worker. stdin: JSON commands. stdout: length-prefixed
//! events (0 = JSON, 1 = BGRA frame with width/height and canvas rect). No GUI toolkit.
//! Latest-frame output bounds display latency; EOF closes the remote socket.
use rapp_client_core::session;

fn main() {
    // Before the first record: the trace file is opened once, on the first record.
    if let Some(dir) = std::env::var_os("RAPP_STREAM_TRACE_DIR") {
        session::trace_to(dir.into());
    }
    session::serve(std::io::BufReader::new(std::io::stdin()), std::io::stdout());
}
