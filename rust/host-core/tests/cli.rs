//! The worker command line against the Swift reference (fixtures from
//! `Tests/RappCoreTests/HostCoreFixtures/CLIFixtures.swift`), plus the Windows-only shapes of
//! spec §6.1 pinned with literal JSON. Event lines are compared as parsed JSON values, so key
//! order and escaping do not matter but integer-ness does (`1` is not `1.0`).

mod common;
mod rules_common;

use std::collections::HashMap;

use common::raw_cases;
use rapp_host_core::cli::{
    apps_json, apps_text, check_hello, check_json, exit_code, exit_code_for_host_error, input_blocked_notice, lock_json,
    parse_host_arguments, parse_worker_command, resolve_hello_app, shareable_apps, taken_over_error, takeover_notice,
    version_json, HostCommand, HostServeOptions, ListedWindow, SharedApp, TransferDirection, WorkerCommand, WorkerEvent,
};
use rapp_host_core::desktop::DesktopDisplay;
use rapp_host_core::lock::LockOutcome;
use rapp_host_core::platform::{OpenError, Permissions};
use rapp_host_core::protocol::PROTOCOL_VERSION;
use rapp_host_core::{ClipKind, CodecError, Mode, Rect};
use rules_common::*;
use serde::Deserialize;
use serde_json::{json, Value};

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| s.to_string()).collect()
}

fn parsed(line: &str) -> Value {
    serde_json::from_str(line).unwrap_or_else(|e| panic!("not one JSON line: {line:?}: {e}"))
}

fn windows_permissions() -> Permissions {
    Permissions {
        screen_recording: true,
        accessibility: true,
        platform: "windows".into(),
        applications: true,
        error: None,
    }
}

// MARK: cli-args.json

/// A command as `CLIFixtures.command` writes it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
enum JCommand {
    Serve { app: Option<String>, token: String, port: u16, bind: Option<String>, json: bool },
    ListApps { json: bool },
    /// Swift's `prompt` is read and not compared: Windows drops it (spec §6.1).
    Check { json: bool, #[allow(dead_code)] prompt: bool },
    Version { json: bool },
    Lock { json: bool },
    StayAwake { json: bool },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum JArgsOut {
    Ok(JCommand),
    Error(String),
}

fn same_command(got: &HostCommand, want: &JCommand) -> bool {
    match (got, want) {
        (HostCommand::Serve(o), JCommand::Serve { app, token, port, bind, json }) => {
            o == &HostServeOptions { app: app.clone(), token: token.clone(), port: *port, bind: bind.clone(), json: *json }
        }
        (HostCommand::ListApps { json: a }, JCommand::ListApps { json: b })
        | (HostCommand::Check { json: a }, JCommand::Check { json: b, .. })
        | (HostCommand::Version { json: a }, JCommand::Version { json: b })
        | (HostCommand::Lock { json: a }, JCommand::Lock { json: b })
        | (HostCommand::StayAwake { json: a }, JCommand::StayAwake { json: b }) => a == b,
        _ => false,
    }
}

#[test]
fn host_arguments_match_swift() {
    let cases = raw_cases("cli-args.json");
    assert!(!cases.is_empty());
    for c in cases {
        assert_eq!(func(&c.input), "host", "{}", c.name);
        let args: Vec<String> = arg(&c.input["args"]);
        let env: HashMap<String, String> = arg(&c.input["env"]);
        let lookup = |name: &str| env.get(name).cloned();
        let got = parse_host_arguments(&args, &lookup);
        match (got, arg::<JArgsOut>(&c.out)) {
            (Ok(cmd), JArgsOut::Ok(want)) => assert!(same_command(&cmd, &want), "{}: {cmd:?} vs {want:?}", c.name),
            (Err(e), JArgsOut::Error(want)) => assert_eq!(e.0, want, "{}", c.name),
            (got, want) => panic!("{}: got {got:?}, Swift {want:?}", c.name),
        }
    }
}

// MARK: cli-events.json

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum JEvent {
    Listening { port: u16 },
    SessionStarted { client: String, mode: String, fps: i64 },
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
        fulls: i64,
        enc_ms: Option<i64>,
    },
    Ready { width: i64, height: i64, title: String },
    Windows { count: i64 },
    Transfer { dir: String, kind: String, bytes: u64, name: Option<String> },
    Input,
    InputBlocked { by: String },
    Unlock,
    Exit { code: i32, reason: String },
}

fn clip_kind(name: &str) -> ClipKind {
    match name {
        "text" => ClipKind::Text,
        "image" => ClipKind::Image,
        "files" => ClipKind::Files,
        "data" => ClipKind::Data,
        "unsupported" => ClipKind::Unsupported,
        _ => panic!("clip kind {name}"),
    }
}

impl JEvent {
    fn event(&self) -> WorkerEvent {
        match self.clone() {
            JEvent::Listening { port } => WorkerEvent::Listening { port },
            JEvent::SessionStarted { client, mode, fps } => {
                WorkerEvent::SessionStarted { client, mode: Mode::from_name(&mode).expect("mode"), fps }
            }
            JEvent::SessionEnded { reason } => WorkerEvent::SessionEnded { reason },
            JEvent::Rejected { reason } => WorkerEvent::Rejected { reason },
            JEvent::Stats { kbps, fps, width, height, rtt_ms, base_rtt_ms, latency_ms, weak, fulls, enc_ms } => {
                WorkerEvent::Stats { kbps, fps, width, height, rtt_ms, base_rtt_ms, latency_ms, weak, fulls, enc_ms }
            }
            JEvent::Ready { width, height, title } => WorkerEvent::Ready { width, height, title },
            JEvent::Windows { count } => WorkerEvent::Windows { count },
            JEvent::Transfer { dir, kind, bytes, name } => WorkerEvent::Transfer {
                dir: match dir.as_str() {
                    "a_to_b" => TransferDirection::AToB,
                    "b_to_a" => TransferDirection::BToA,
                    _ => panic!("dir {dir}"),
                },
                kind: clip_kind(&kind),
                bytes,
                name,
            },
            JEvent::Input => WorkerEvent::Input,
            JEvent::InputBlocked { by } => WorkerEvent::InputBlocked { by },
            JEvent::Unlock => WorkerEvent::Unlock,
            JEvent::Exit { code, reason } => WorkerEvent::Exit { code, reason },
        }
    }
}

#[derive(Debug, Deserialize)]
struct JApp {
    app: String,
    name: String,
}

#[derive(Debug, Deserialize)]
struct JFrame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, Deserialize)]
struct JDisplay {
    id: u32,
    name: String,
    main: bool,
    frame: JFrame,
}

#[derive(Debug, Deserialize)]
struct JListed {
    pid: i32,
    layer: i64,
    width: f64,
    height: f64,
}

#[derive(Debug, Deserialize)]
struct JRegular {
    pid: i32,
    app: String,
    name: String,
}

fn shared(apps: &[JApp]) -> Vec<SharedApp> {
    apps.iter().map(|a| SharedApp { app: a.app.clone(), name: a.name.clone() }).collect()
}

#[test]
fn events_and_app_lists_match_swift() {
    let cases = raw_cases("cli-events.json");
    assert!(!cases.is_empty());
    for c in cases {
        match func(&c.input) {
            "event" => {
                let event = arg::<JEvent>(&c.input["event"]).event();
                let line = event.json_line();
                assert!(!line.contains('\n'), "{}: {line:?}", c.name);
                let want: String = arg(&c.out);
                assert_eq!(parsed(&line), parsed(&want), "{}: {event:?}", c.name);
            }
            "apps" => {
                let apps: Vec<JApp> = arg(&c.input["apps"]);
                let screen: Option<bool> = arg(&c.input["screen_recording"]);
                let access: Option<bool> = arg(&c.input["accessibility"]);
                let displays: Vec<JDisplay> = arg(&c.input["displays"]);
                let displays: Vec<DesktopDisplay> = displays
                    .into_iter()
                    .map(|d| DesktopDisplay {
                        id: d.id,
                        name: d.name,
                        main: d.main,
                        frame: Rect::new(d.frame.x, d.frame.y, d.frame.width, d.frame.height),
                    })
                    .collect();
                let mut permissions = windows_permissions();
                permissions.screen_recording = screen.unwrap_or(true);
                permissions.accessibility = access.unwrap_or(true);
                let got = parsed(&apps_json(&displays, &shared(&apps), &permissions));
                let want = parsed(&arg::<String>(&c.out));
                // The list is Swift's; Windows always adds the permissions with its own fields.
                assert_eq!(got["apps"], want["apps"], "{}", c.name);
                let p = &got["permissions"];
                assert_eq!(p["platform"], json!("windows"), "{}", c.name);
                assert_eq!(p["applications"], json!(true), "{}", c.name);
                if let Some(wp) = want.get("permissions") {
                    assert_eq!(p["screen_recording"], wp["screen_recording"], "{}", c.name);
                    assert_eq!(p["accessibility"], wp["accessibility"], "{}", c.name);
                }
            }
            "shareable" => {
                let windows: Vec<JListed> = arg(&c.input["windows"]);
                let windows: Vec<ListedWindow> = windows
                    .iter()
                    .map(|w| ListedWindow { pid: w.pid, layer: w.layer, width: w.width, height: w.height })
                    .collect();
                let regular: Vec<JRegular> = arg(&c.input["regular"]);
                let regular: HashMap<i32, SharedApp> = regular
                    .into_iter()
                    .map(|r| (r.pid, SharedApp { app: r.app, name: r.name }))
                    .collect();
                let got = shareable_apps(&windows, &regular);
                let want_apps: Vec<JApp> = arg(&c.out["apps"]);
                assert_eq!(got, shared(&want_apps), "{}", c.name);
                assert_eq!(apps_text(&got), arg::<String>(&c.out["text"]), "{}", c.name);
            }
            other => panic!("{}: fn {other}", c.name),
        }
    }
}

// MARK: cli-commands.json

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
enum JWorkerCommand {
    Kick,
    Quit,
    Focus,
    Peer { port: u16, name: String },
    Yield { by: String },
}

fn jworker(c: &WorkerCommand) -> JWorkerCommand {
    match c {
        WorkerCommand::Kick => JWorkerCommand::Kick,
        WorkerCommand::Quit => JWorkerCommand::Quit,
        WorkerCommand::Focus => JWorkerCommand::Focus,
        WorkerCommand::Peer { port, name } => JWorkerCommand::Peer { port: *port, name: name.clone() },
        WorkerCommand::Yield { by } => JWorkerCommand::Yield { by: by.clone() },
    }
}

#[test]
fn worker_commands_match_swift() {
    let cases = raw_cases("cli-commands.json");
    assert!(!cases.is_empty());
    for c in cases {
        assert_eq!(func(&c.input), "command", "{}", c.name);
        let line: String = arg(&c.input["line"]);
        let got = parse_worker_command(&line).as_ref().map(jworker);
        assert_eq!(got, arg::<Option<JWorkerCommand>>(&c.out), "{}: {line:?}", c.name);
    }
}

// MARK: cli-hello.json

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum JResult {
    Ok(String),
    Error(String),
}

fn jresult(r: Result<String, CodecError>) -> JResult {
    match r {
        Ok(s) => JResult::Ok(s),
        Err(e) => JResult::Error(e.0),
    }
}

#[test]
fn hello_and_notices_match_swift() {
    let cases = raw_cases("cli-hello.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        match func(i) {
            "resolve" => {
                let requested: String = arg(&i["requested"]);
                let bound: Option<String> = arg(&i["bound"]);
                let got = jresult(resolve_hello_app(&requested, bound.as_deref()));
                assert_eq!(got, arg::<JResult>(&c.out), "{}", c.name);
            }
            "check" => {
                let token: String = arg(&i["token"]);
                let bundle_id: String = arg(&i["bundle_id"]);
                let expected: String = arg(&i["expected"]);
                let bound: Option<String> = arg(&i["bound"]);
                let got = jresult(check_hello(&token, &bundle_id, &expected, bound.as_deref()));
                assert_eq!(got, arg::<JResult>(&c.out), "{}", c.name);
            }
            "exit_code" => {
                let reason: String = arg(&i["reason"]);
                assert_eq!(exit_code_for_host_error(&reason), arg::<i32>(&c.out), "{}", c.name);
            }
            "taken_over" => {
                let by: Option<String> = arg(&i["by"]);
                assert_eq!(taken_over_error(by.as_deref()), arg::<String>(&c.out), "{}", c.name);
            }
            "takeover_notice" => {
                let reason: String = arg(&i["reason"]);
                assert_eq!(takeover_notice(&reason), arg::<Option<String>>(&c.out), "{}: {reason:?}", c.name);
            }
            "input_blocked_notice" => {
                let by: String = arg(&i["by"]);
                assert_eq!(input_blocked_notice(&by), arg::<String>(&c.out), "{}", c.name);
            }
            other => panic!("{}: fn {other}", c.name),
        }
    }
}

// MARK: Windows-only shapes (spec §6.1), literal

fn no_env(_: &str) -> Option<String> {
    None
}

#[test]
fn secure_helper_takes_a_pipe() {
    let got = parse_host_arguments(&strings(&["secure-helper", "--pipe", r"\\.\pipe\rapp-secure-1"]), &no_env);
    assert_eq!(got, Ok(HostCommand::SecureHelper { pipe: r"\\.\pipe\rapp-secure-1".into() }));
}

#[test]
fn secure_helper_errors() {
    let cases: [(&[&str], &str); 7] = [
        (&["secure-helper"], "--pipe is required"),
        (&["secure-helper", "--pipe", ""], "--pipe is required"),
        (&["secure-helper", "--pipe"], "--pipe needs a value"),
        (&["secure-helper", "--json", "--pipe", "p"], "unknown argument --json"),
        (&["secure-helper", "--pipe", "p", "--json"], "unknown argument --json"),
        (&["secure-helper", "--pipe", "p", "extra"], "unexpected argument extra"),
        (&["secure-helper", "--token", "t"], "unknown argument --token"),
    ];
    for (args, want) in cases {
        assert_eq!(parse_host_arguments(&strings(args), &no_env), Err(CodecError::new(want)), "{args:?}");
    }
}

#[test]
fn check_prompt_is_accepted_and_ignored() {
    assert_eq!(parse_host_arguments(&strings(&["check", "--prompt"]), &no_env), Ok(HostCommand::Check { json: false }));
    assert_eq!(
        parse_host_arguments(&strings(&["check", "--prompt", "--json"]), &no_env),
        Ok(HostCommand::Check { json: true })
    );
}

#[test]
fn version_reports_crate_version_and_platform() {
    let want = format!(
        r#"{{"platform":"windows","protocol":{},"version":"{}"}}"#,
        PROTOCOL_VERSION,
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(version_json("windows"), want);
}

#[test]
fn check_json_carries_platform_fields() {
    assert_eq!(
        check_json(&windows_permissions()),
        r#"{"accessibility":true,"applications":true,"platform":"windows","screen_recording":true}"#
    );
    let blocked = Permissions {
        screen_recording: false,
        accessibility: true,
        platform: "windows".into(),
        applications: false,
        error: Some(OpenError::SessionDisconnected),
    };
    assert_eq!(
        check_json(&blocked),
        r#"{"accessibility":true,"applications":false,"error":"session disconnected","platform":"windows","screen_recording":false}"#
    );
}

#[test]
fn open_error_reasons_are_fixed() {
    assert_eq!(OpenError::NoDisplay.reason(), "no display");
    assert_eq!(OpenError::SessionDisconnected.reason(), "session disconnected");
    assert_eq!(OpenError::NotInteractive.reason(), "not interactive");
    assert_eq!(OpenError::OtherUser.reason(), "other user");
    assert_eq!(OpenError::NotFound("notepad.exe".into()).reason(), "notepad.exe not found");
    assert_eq!(OpenError::Other("拒绝访问".into()).reason(), "拒绝访问");
    assert_eq!(OpenError::OtherUser.to_string(), "other user");
}

#[test]
fn apps_json_without_displays_has_no_desktop_entry() {
    let apps = [SharedApp { app: "notepad.exe".into(), name: "记事本".into() }];
    assert_eq!(
        apps_json(&[], &apps, &windows_permissions()),
        r#"{"apps":[{"app":"notepad.exe","name":"记事本"}],"permissions":{"accessibility":true,"applications":true,"platform":"windows","screen_recording":true}}"#
    );
}

#[test]
fn apps_json_starts_with_the_desktop_main_display_first() {
    let displays = [
        DesktopDisplay { id: 7, name: "DELL".into(), main: false, frame: Rect::new(1512.0, 0.0, 2560.0, 1440.0) },
        DesktopDisplay { id: 1, name: "内建显示器".into(), main: true, frame: Rect::new(0.0, 0.0, 1512.0, 982.0) },
    ];
    let mut permissions = windows_permissions();
    permissions.applications = false;
    permissions.error = Some(OpenError::NotInteractive);
    permissions.screen_recording = false;
    assert_eq!(
        apps_json(&displays, &[], &permissions),
        concat!(
            r#"{"apps":[{"app":"desktop:","displays":["#,
            r#"{"height":982,"id":"1","main":true,"name":"内建显示器","width":1512},"#,
            r#"{"height":1440,"id":"7","main":false,"name":"DELL","width":2560}],"name":"桌面"}],"#,
            r#""permissions":{"accessibility":true,"applications":false,"error":"not interactive","platform":"windows","screen_recording":false}}"#
        )
    );
}

#[test]
fn lock_json_lines() {
    assert_eq!(lock_json(&LockOutcome::Locked), r#"{"ok":true}"#);
    assert_eq!(lock_json(&LockOutcome::Already), r#"{"already":true,"ok":true}"#);
    assert_eq!(
        lock_json(&LockOutcome::Failed("调用后 2 秒内没有锁上".into())),
        r#"{"error":"调用后 2 秒内没有锁上","ok":false}"#
    );
}

#[test]
fn exit_codes_are_swifts() {
    assert_eq!(
        [exit_code::OK, exit_code::RUNTIME, exit_code::USAGE, exit_code::PERMISSION, exit_code::VERSION],
        [0, 1, 2, 3, 5]
    );
}

#[test]
fn event_lines_escape_and_stay_on_one_line() {
    let line = WorkerEvent::SessionStarted { client: "a\"b\\c\nd/客户端".into(), mode: Mode::Color16, fps: 15 }.json_line();
    assert!(!line.contains('\n'));
    assert_eq!(
        parsed(&line),
        json!({"event":"session","state":"started","client":"a\"b\\c\nd/客户端","mode":"color16","fps":15})
    );
    // Slashes are not escaped (Swift's .withoutEscapingSlashes).
    assert!(line.contains("d/客户端"));
}
