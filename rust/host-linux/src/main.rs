#[cfg(target_os = "linux")]
fn run() -> anyhow::Result<()> {
    use anyhow::{bail, Context};
    use rapp_host_linux::{
        desktop::Desktop,
        server::{self, emit, Options},
    };
    use serde_json::json;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let value = |flag: &str| {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    match args.first().map(String::as_str) {
        Some("version") => emit(json!({"version":env!("CARGO_PKG_VERSION"), "protocol":rapp_client_core::protocol::VERSION, "platform":"linux"})),
        Some(cmd @ ("check" | "list-apps")) => {
            let (apps, permissions) = match Desktop::connect() {
                Ok(desktop) => {
                    let mut apps = vec![json!({"app":"desktop:", "name":"桌面", "displays":desktop.displays().iter().map(|d| d.json()).collect::<Vec<_>>()})];
                    apps.extend(desktop.applications().unwrap_or_default());
                    (json!(apps), json!({"screen_recording":true, "accessibility":true, "platform":"linux", "applications":desktop.application_capture_supported()}))
                },
                Err(e) => (json!([]), json!({"screen_recording":false, "accessibility":false, "platform":"linux", "error":e.to_string()})),
            };
            if cmd == "check" { emit(permissions); } else { emit(json!({"apps":apps,"permissions":permissions})); }
        }
        Some("lock") => match server::lock() { Ok(already) => emit(json!({"ok":true, "already":!already})), Err(e) => { emit(json!({"ok":false,"error":e.to_string()})); return Err(e); } },
        Some("serve") => {
            let token = if let Some(var) = value("--token-env") { std::env::var(var).context("missing token environment variable")? } else { value("--token").context("--token-env is required")? };
            server::serve(Options { app: value("--app").context("--app desktop: is required")?, token, bind: value("--bind").unwrap_or_else(|| "127.0.0.1".into()), port: value("--port").unwrap_or_else(|| "47800".into()).parse()? })?;
        }
        _ => bail!("usage: rapp-host check|list-apps|lock|version [--json], or serve --app desktop: --token-env VAR [--bind 127.0.0.1] [--port 47800] --json"),
    }
    Ok(())
}
#[cfg(target_os = "linux")]
fn main() {
    if std::env::args().nth(1).as_deref() == Some("--internal-accessibility") {
        std::process::exit(if rapp_host_linux::accessibility::run_child().is_ok() {
            0
        } else {
            1
        });
    }
    if std::env::args().nth(1).as_deref() == Some("--internal-clipboard") {
        std::process::exit(match rapp_host_linux::clipboard::run_child() {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("clipboard: {e}");
                1
            }
        });
    }
    match run() {
        Ok(()) => rapp_host_linux::server::emit(
            serde_json::json!({"event":"exit","code":0,"reason":"done"}),
        ),
        Err(e) => {
            rapp_host_linux::server::emit(
                serde_json::json!({"event":"exit","code":1,"reason":e.to_string()}),
            );
            std::process::exit(1);
        }
    }
}
#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("Use the platform's native rapp-host; this worker is for Linux.");
    std::process::exit(1);
}
