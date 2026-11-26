//! The worker command line (platform spec §5, Windows spec §6.1): argument parsing, JSON lines
//! on stdout and the commands read from stdin (`Sources/RappCore/WorkerCLI.swift:9-345`, host
//! half only: no `parseClientArguments`, `ClientCommand`, `WorkerOutput` or `TakeoverGate`).
//!
//! Differences from Swift, all from spec §6.1: `secure-helper --pipe <name>` is parsed;
//! `check --prompt` is accepted and ignored; `version` reports this crate's version and the
//! caller's platform; `list-apps` and `check` carry `platform`, `applications` and an optional `error`.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use serde_json::{json, Map, Number, Value};
use unicode_segmentation::GraphemeCursor;

use crate::desktop::{desktop_entry, parse_swift_u32, DesktopDisplay};
use crate::lock::LockOutcome;
use crate::platform::Permissions;
use crate::protocol::{constant_time_equals, ClipKind, CodecError, Mode, DEFAULT_PORT, PROTOCOL_VERSION};

/// Exit codes of the worker. Windows never returns `PERMISSION` (spec §6.1).
pub mod exit_code {
    pub const OK: i32 = 0;
    pub const RUNTIME: i32 = 1;
    pub const USAGE: i32 = 2;
    pub const PERMISSION: i32 = 3;
    pub const VERSION: i32 = 5;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostServeOptions {
    /// The app this host shares; `None` for the legacy form, which takes the app from each Hello.
    pub app: Option<String>,
    pub token: String,
    pub port: u16,
    /// The address to listen on; `None` listens on every interface.
    pub bind: Option<String>,
    pub json: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostCommand {
    Serve(HostServeOptions),
    ListApps { json: bool },
    /// Swift's `prompt` flag is parsed and dropped: Windows has nothing to ask for.
    Check { json: bool },
    Lock { json: bool },
    Version { json: bool },
    /// Windows only: the secure-desktop helper `rapp-svc` starts as SYSTEM (spec §7.4).
    SecureHelper { pipe: String },
}

fn fail<T>(text: impl Into<String>) -> Result<T, CodecError> {
    Err(CodecError::new(text))
}

/// Splits flags (`--name value`, or bare `--json`) from positional arguments.
struct Arguments {
    values: HashMap<String, String>,
    json: bool,
    flags: HashSet<String>,
    positional: Vec<String>,
}

impl Arguments {
    fn new(args: &[String], valued: &[&str], bare: &[&str]) -> Result<Arguments, CodecError> {
        let mut parsed =
            Arguments { values: HashMap::new(), json: false, flags: HashSet::new(), positional: Vec::new() };
        let mut rest = args.iter();
        while let Some(arg) = rest.next() {
            if arg == "--json" {
                parsed.json = true;
            } else if bare.contains(&arg.as_str()) {
                parsed.flags.insert(arg.clone());
            } else if valued.contains(&arg.as_str()) {
                let Some(value) = rest.next() else { return fail(format!("{arg} needs a value")) };
                parsed.values.insert(arg.clone(), value.clone());
            } else if arg.starts_with("--") {
                return fail(format!("unknown argument {arg}"));
            } else {
                parsed.positional.push(arg.clone());
            }
        }
        Ok(parsed)
    }

    fn no_positional(&self) -> Result<(), CodecError> {
        if let Some(extra) = self.positional.first() {
            return fail(format!("unexpected argument {extra}"));
        }
        Ok(())
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    /// `--token`, else the variable named by `--token-env`; must not be empty.
    fn token(&self, env: &dyn Fn(&str) -> Option<String>) -> Result<String, CodecError> {
        if let Some(token) = self.value("--token") {
            if token.is_empty() {
                return fail("the token is empty");
            }
            return Ok(token.to_string());
        }
        let Some(name) = self.value("--token-env") else { return fail("--token or --token-env is required") };
        match env(name) {
            Some(token) if !token.is_empty() => Ok(token),
            _ => fail(format!("environment variable {name} is empty or not set")),
        }
    }
}

/// Swift's `UInt16(text)`, `allowZero || port != 0`; no text is the default port.
fn parse_port(text: Option<&str>, allow_zero: bool) -> Result<u16, CodecError> {
    let Some(text) = text else { return Ok(DEFAULT_PORT) };
    match parse_swift_u32(text).and_then(|v| u16::try_from(v).ok()) {
        Some(port) if allow_zero || port != 0 => Ok(port),
        _ => fail(format!("bad port {text}")),
    }
}

pub fn parse_host_arguments(
    args: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<HostCommand, CodecError> {
    let subcommand = args.first().map(String::as_str).unwrap_or("");
    let tail = if args.is_empty() { &args[..] } else { &args[1..] };
    match subcommand {
        "list-apps" | "check" | "version" | "lock" => {
            let bare: &[&str] = if subcommand == "check" { &["--prompt"] } else { &[] };
            let parsed = Arguments::new(tail, &[], bare)?;
            parsed.no_positional()?;
            Ok(match subcommand {
                "list-apps" => HostCommand::ListApps { json: parsed.json },
                "check" => HostCommand::Check { json: parsed.json },
                "lock" => HostCommand::Lock { json: parsed.json },
                _ => HostCommand::Version { json: parsed.json },
            })
        }
        "serve" => {
            let parsed = Arguments::new(tail, &["--app", "--token", "--token-env", "--port", "--bind"], &[])?;
            parsed.no_positional()?;
            let app = match parsed.value("--app") {
                Some(app) if !app.is_empty() => app.to_string(),
                _ => return fail("--app is required"),
            };
            let token = parsed.token(env)?;
            let port = parse_port(parsed.value("--port"), true)?;
            Ok(HostCommand::Serve(HostServeOptions {
                app: Some(app),
                token,
                port,
                bind: parsed.value("--bind").map(str::to_string),
                json: parsed.json,
            }))
        }
        "secure-helper" => {
            // Windows only (spec §6.1); no Swift counterpart. Same checks as the legacy form's `--json`.
            let parsed = Arguments::new(tail, &["--pipe"], &[])?;
            parsed.no_positional()?;
            if parsed.json {
                return fail("unknown argument --json");
            }
            match parsed.value("--pipe") {
                Some(pipe) if !pipe.is_empty() => Ok(HostCommand::SecureHelper { pipe: pipe.to_string() }),
                _ => fail("--pipe is required"),
            }
        }
        _ => {
            // Legacy: rapp-host --token X [--port N]
            let parsed = Arguments::new(args, &["--token", "--port"], &[])?;
            parsed.no_positional()?;
            if parsed.json {
                return fail("unknown argument --json");
            }
            if parsed.value("--token").is_none() {
                return fail("--token is required");
            }
            let token = parsed.token(env)?;
            let port = parse_port(parsed.value("--port"), false)?;
            Ok(HostCommand::Serve(HostServeOptions { app: None, token, port, bind: None, json: false }))
        }
    }
}

/// The client's exit code after the host sent `Error(reason)`.
pub fn exit_code_for_host_error(reason: &str) -> i32 {
    if swift_has_prefix(reason, "protocol version mismatch") {
        exit_code::VERSION
    } else {
        exit_code::RUNTIME
    }
}

/// The app a Hello asks for, given the app this host was started for (if any).
pub fn resolve_hello_app(requested: &str, bound: Option<&str>) -> Result<String, CodecError> {
    let Some(bound) = bound else { return Ok(requested.to_string()) };
    if requested.is_empty() || requested == bound {
        Ok(bound.to_string())
    } else {
        fail(format!("this host shares {bound}"))
    }
}

/// Checks a Hello's token (constant time), then resolves the app it asks for.
pub fn check_hello(token: &str, bundle_id: &str, expected: &str, bound: Option<&str>) -> Result<String, CodecError> {
    if !constant_time_equals(token, expected) {
        return fail("bad token");
    }
    resolve_hello_app(bundle_id, bound)
}

/// The `Error` reason sent to a client whose session another client took over.
pub fn taken_over_error(by: Option<&str>) -> String {
    match by {
        Some(name) if !name.is_empty() => format!("taken over by {name}"),
        _ => "taken over".to_string(),
    }
}

/// The notice shown to the user for a takeover reason (with or without the `host says: `
/// prefix); `None` for other reasons.
pub fn takeover_notice(reason: &str) -> Option<String> {
    let prefix = "host says: ";
    let text = if swift_has_prefix(reason, prefix) { &reason[prefix.len()..] } else { reason };
    if text == "taken over" {
        return Some("这个窗口在另一台设备上打开了".to_string());
    }
    let by = "taken over by ";
    if swift_has_prefix(text, by) {
        let name = &text[by.len()..];
        return Some(if name.is_empty() {
            "这个窗口在另一台设备上打开了".to_string()
        } else {
            format!("这个窗口在 {name} 上打开了")
        });
    }
    None
}

/// The notice shown to a client whose input is blocked because another client is operating A.
pub fn input_blocked_notice(by: &str) -> String {
    if by.is_empty() {
        "远端正在被另一台设备操作".to_string()
    } else {
        format!("远端正在被 {by} 操作")
    }
}

/// Swift's `String.hasPrefix` for an ASCII prefix: the bytes match and the prefix ends on a
/// character boundary (a combining mark right after it makes a different last character).
fn swift_has_prefix(s: &str, prefix: &str) -> bool {
    if !s.starts_with(prefix) {
        return false;
    }
    if s.len() == prefix.len() || prefix.is_empty() {
        return true;
    }
    let mut cursor = GraphemeCursor::new(prefix.len(), s.len(), true);
    cursor.is_boundary(s, 0).unwrap_or(true)
}

// MARK: JSON lines

/// One JSON object on one line, keys sorted (serde_json's map is ordered by key bytes, which is
/// Swift's `.sortedKeys` order for the ASCII keys used here). `/` is never escaped, as Swift's
/// `.withoutEscapingSlashes`.
pub fn json_line(object: Map<String, Value>) -> String {
    serde_json::to_string(&Value::Object(object)).unwrap_or_default()
}

fn object(pairs: Vec<(&str, Value)>) -> Map<String, Value> {
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

/// Which way a clipboard item or file went.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransferDirection {
    AToB,
    BToA,
}

impl TransferDirection {
    pub fn name(self) -> &'static str {
        match self {
            TransferDirection::AToB => "a_to_b",
            TransferDirection::BToA => "b_to_a",
        }
    }
}

/// Swift's `"\(kind)"` for a `ClipKind`: the case name.
pub fn clip_kind_name(kind: ClipKind) -> &'static str {
    match kind {
        ClipKind::Text => "text",
        ClipKind::Image => "image",
        ClipKind::Files => "files",
        ClipKind::Data => "data",
        ClipKind::Unsupported => "unsupported",
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkerEvent {
    Listening { port: u16 },
    SessionStarted { client: String, mode: Mode, fps: i64 },
    SessionEnded { reason: String },
    Rejected { reason: String },
    Stats {
        kbps: f64,
        fps: i64,
        width: i64,
        height: i64,
        rtt_ms: Option<i64>,
        base_rtt_ms: Option<i64>,
        latency_ms: Option<i64>,
        weak: bool,
        /// Swift's default is 0.
        fulls: i64,
        enc_ms: Option<i64>,
    },
    Ready { width: i64, height: i64, title: String },
    /// The client's window table changed; `count` windows in it (multi-window spec §4.6).
    Windows { count: i64 },
    /// One clipboard item or file finished crossing (observability spec §4.3). `name` only for files.
    Transfer { dir: TransferDirection, kind: ClipKind, bytes: u64, name: Option<String> },
    /// This client's own input reached the host.
    Input,
    /// This client's input was blocked because `by` is operating A.
    InputBlocked { by: String },
    /// B had A's system password typed at the lock screen (never the password itself).
    Unlock,
    Exit { code: i32, reason: String },
}

/// Swift's `NSDecimalNumber(string: String(format: "%.1f", kbps))`: one decimal, and a whole
/// number prints without a fraction (`12.3`, `0`, `1234.6`).
fn kbps_value(kbps: f64) -> Value {
    let text = format!("{kbps:.1}");
    if let Some(whole) = text.strip_suffix(".0") {
        if let Ok(n) = whole.parse::<i64>() {
            return Value::Number(Number::from(n));
        }
    }
    match text.parse::<f64>().ok().and_then(Number::from_f64) {
        Some(n) => Value::Number(n),
        // NaN or infinity: Swift traps in JSONSerialization; there is nothing to match.
        None => Value::Number(Number::from(0)),
    }
}

impl WorkerEvent {
    pub fn json_line(&self) -> String {
        let o = match self {
            WorkerEvent::Listening { port } => object(vec![("event", json!("listening")), ("port", json!(*port))]),
            WorkerEvent::SessionStarted { client, mode, fps } => object(vec![
                ("event", json!("session")),
                ("state", json!("started")),
                ("client", json!(client)),
                ("mode", json!(mode.name())),
                ("fps", json!(*fps)),
            ]),
            WorkerEvent::SessionEnded { reason } => {
                object(vec![("event", json!("session")), ("state", json!("ended")), ("reason", json!(reason))])
            }
            WorkerEvent::Rejected { reason } => object(vec![("event", json!("rejected")), ("reason", json!(reason))]),
            WorkerEvent::Stats { kbps, fps, width, height, rtt_ms, base_rtt_ms, latency_ms, weak, fulls, enc_ms } => {
                let mut o = object(vec![
                    ("event", json!("stats")),
                    ("kbps", kbps_value(*kbps)),
                    ("fps", json!(*fps)),
                    ("width", json!(*width)),
                    ("height", json!(*height)),
                    ("weak", json!(*weak)),
                    ("fulls", json!(*fulls)),
                ]);
                if let Some(v) = rtt_ms {
                    o.insert("rttMs".into(), json!(*v));
                }
                if let Some(v) = base_rtt_ms {
                    o.insert("baseRttMs".into(), json!(*v));
                }
                if let Some(v) = latency_ms {
                    o.insert("latencyMs".into(), json!(*v));
                }
                if let Some(v) = enc_ms {
                    o.insert("encMs".into(), json!(*v));
                }
                o
            }
            WorkerEvent::Ready { width, height, title } => object(vec![
                ("event", json!("ready")),
                ("width", json!(*width)),
                ("height", json!(*height)),
                ("title", json!(title)),
            ]),
            WorkerEvent::Windows { count } => object(vec![("event", json!("windows")), ("count", json!(*count))]),
            WorkerEvent::Transfer { dir, kind, bytes, name } => {
                let mut o = object(vec![
                    ("event", json!("transfer")),
                    ("dir", json!(dir.name())),
                    ("kind", json!(clip_kind_name(*kind))),
                    ("bytes", json!(*bytes)),
                ]);
                if let Some(name) = name {
                    o.insert("name".into(), json!(name));
                }
                o
            }
            WorkerEvent::Input => object(vec![("event", json!("input"))]),
            WorkerEvent::InputBlocked { by } => object(vec![("event", json!("input_blocked")), ("by", json!(by))]),
            WorkerEvent::Unlock => object(vec![("event", json!("unlock"))]),
            WorkerEvent::Exit { code, reason } => {
                object(vec![("event", json!("exit")), ("code", json!(*code)), ("reason", json!(reason))])
            }
        };
        json_line(o)
    }
}

/// `{"platform", "protocol", "version"}`: this crate's version (the workspace's), not Swift's fixed `0.3.0`.
pub fn version_json(platform: &str) -> String {
    json_line(object(vec![
        ("version", json!(env!("CARGO_PKG_VERSION"))),
        ("protocol", json!(PROTOCOL_VERSION)),
        ("platform", json!(platform)),
    ]))
}

/// The permissions object of `check` and `list-apps` (spec §6.1).
fn permissions_object(p: &Permissions) -> Map<String, Value> {
    let mut o = object(vec![
        ("screen_recording", json!(p.screen_recording)),
        ("accessibility", json!(p.accessibility)),
        ("platform", json!(p.platform)),
        ("applications", json!(p.applications)),
    ]);
    if let Some(e) = &p.error {
        o.insert("error".into(), json!(e.reason()));
    }
    o
}

pub fn check_json(permissions: &Permissions) -> String {
    json_line(permissions_object(permissions))
}

/// `{"ok":true}` / `{"ok":true,"already":true}` / `{"ok":false,"error":…}` (Sources/rapp-host/main.swift:85-97).
pub fn lock_json(outcome: &LockOutcome) -> String {
    json_line(match outcome {
        LockOutcome::Locked => object(vec![("ok", json!(true))]),
        LockOutcome::Already => object(vec![("ok", json!(true)), ("already", json!(true))]),
        LockOutcome::Failed(reason) => object(vec![("ok", json!(false)), ("error", json!(reason))]),
    })
}

/// A command read from a worker's stdin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkerCommand {
    Kick,
    Quit,
    /// A rapp-client command; the host takes it and does nothing.
    Focus,
    Peer { port: u16, name: String },
    Yield { by: String },
}

/// Swift's `object["port"] as? Int` on a JSONSerialization value: any JSON number that is a
/// whole number in range (NSNumber bridging), and a JSON bool as 0 or 1 (NSNumber again).
fn swift_as_int(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                return Some(i);
            }
            if n.as_u64().is_some() {
                return None;
            }
            let f = n.as_f64()?;
            if f.fract() == 0.0 && f >= i64::MIN as f64 && f < i64::MAX as f64 {
                Some(f as i64)
            } else {
                None
            }
        }
        Value::Bool(b) => Some(i64::from(*b)),
        _ => None,
    }
}

/// The command on one stdin line; `None` if the line is not a JSON object with a known `cmd` and its fields.
pub fn parse_worker_command(line: &str) -> Option<WorkerCommand> {
    let value: Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    let cmd = object.get("cmd")?.as_str()?;
    match cmd {
        "kick" => Some(WorkerCommand::Kick),
        "quit" => Some(WorkerCommand::Quit),
        "focus" => Some(WorkerCommand::Focus),
        "peer" => {
            let port = swift_as_int(object.get("port")?)?;
            let port = u16::try_from(port).ok()?;
            let name = object.get("name")?.as_str()?;
            Some(WorkerCommand::Peer { port, name: name.to_string() })
        }
        "yield" => {
            let by = object.get("by")?.as_str()?;
            Some(WorkerCommand::Yield { by: by.to_string() })
        }
        _ => None,
    }
}

// MARK: list-apps

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedApp {
    pub app: String,
    pub name: String,
}

/// One on-screen window as the platform lists it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ListedWindow {
    pub pid: i32,
    pub layer: i64,
    pub width: f64,
    pub height: f64,
}

/// An approximation of Foundation's `localizedStandardCompare` (Finder order): runs of ASCII
/// digits compare as numbers, everything else case-insensitively by lower-cased characters.
fn standard_compare(a: &str, b: &str) -> Ordering {
    fn runs(s: &str) -> Vec<(bool, String)> {
        let mut out: Vec<(bool, String)> = Vec::new();
        for c in s.chars() {
            let digit = c.is_ascii_digit();
            match out.last_mut() {
                Some((d, run)) if *d == digit => run.push(c),
                _ => out.push((digit, c.to_string())),
            }
        }
        out
    }
    let (ra, rb) = (runs(a), runs(b));
    for (x, y) in ra.iter().zip(rb.iter()) {
        let order = match (x.0, y.0) {
            (true, true) => {
                let xs = x.1.trim_start_matches('0');
                let ys = y.1.trim_start_matches('0');
                xs.len().cmp(&ys.len()).then_with(|| xs.cmp(ys))
            }
            _ => x.1.to_lowercase().cmp(&y.1.to_lowercase()),
        };
        if order != Ordering::Equal {
            return order;
        }
    }
    ra.len().cmp(&rb.len())
}

/// Regular apps owning at least one on-screen window of layer 0 and at least 50×50 points, each
/// once, sorted by name (ties by app id).
pub fn shareable_apps(windows: &[ListedWindow], regular_apps: &HashMap<i32, SharedApp>) -> Vec<SharedApp> {
    let mut by_id: HashMap<String, SharedApp> = HashMap::new();
    for w in windows.iter().filter(|w| w.layer == 0 && w.width >= 50.0 && w.height >= 50.0) {
        if let Some(app) = regular_apps.get(&w.pid) {
            by_id.insert(app.app.clone(), app.clone());
        }
    }
    let mut apps: Vec<SharedApp> = by_id.into_values().collect();
    apps.sort_by(|x, y| match standard_compare(&x.name, &y.name) {
        Ordering::Equal => x.app.cmp(&y.app),
        other => other,
    });
    apps
}

/// The list starts with the desktop entry when there is a display (desktop sessions spec §4.1),
/// and always carries the permissions on Windows (spec §6.1).
pub fn apps_json(desktop: &[DesktopDisplay], apps: &[SharedApp], permissions: &Permissions) -> String {
    let mut listed: Vec<Value> = desktop_entry(desktop).into_iter().collect();
    listed.extend(apps.iter().map(|a| json!({ "app": a.app, "name": a.name })));
    json_line(object(vec![
        ("apps", Value::Array(listed)),
        ("permissions", Value::Object(permissions_object(permissions))),
    ]))
}

/// `id<TAB>name`, one app per line.
pub fn apps_text(apps: &[SharedApp]) -> String {
    apps.iter().map(|a| format!("{}\t{}\n", a.app, a.name)).collect()
}
