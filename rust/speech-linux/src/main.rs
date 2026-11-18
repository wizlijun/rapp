//! Local speech worker. JSON lines on stdin/stdout; audio never leaves memory.
#[cfg(target_os = "linux")]
mod speech;

fn main() {
    #[cfg(target_os = "linux")]
    if let Err(error) = speech::run() {
        eprintln!("rapp-speech: {error:#}");
        speech::emit(serde_json::json!({"event":"error","code":"unavailable"}));
        std::process::exit(1);
    }
    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("rapp-speech requires Linux");
        std::process::exit(2);
    }
}
