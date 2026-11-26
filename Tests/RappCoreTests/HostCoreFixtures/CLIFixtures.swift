import CoreGraphics
import Foundation
import XCTest
@testable import RappCore

/// The worker command line for `rust/host-core/tests/cli.rs` (host half of WorkerCLITests).
///
/// - `cli-args.json`: `in` = `{"fn":"host","args","env"}`, `out` = `{"ok": command}` or
///   `{"error": text}`. A command is `{"cmd": "serve"|"list_apps"|"check"|"version"|"lock", …}`.
/// - `cli-events.json`: `fn == "event"`: `in.event` describes one `WorkerEvent` (`type` plus its
///   fields, absent optionals as null), `out` is Swift's `jsonLine`. `fn == "apps"`: `appsJSON`
///   inputs and its line. `fn == "shareable"`: `shareableApps` + `appsText`.
/// - `cli-commands.json`: `in.line` is one stdin line, `out` the parsed command or null.
/// - `cli-hello.json`: `resolve` / `check` (out `{"ok"}` or `{"error"}`), `exit_code`,
///   `taken_over`, `takeover_notice`, `input_blocked_notice`.
///
/// Swift-only shapes (versionJSON's fixed "0.3.0", checkJSON without platform fields) are not
/// written: the Windows host prints its own (spec §6.1), pinned in `tests/cli.rs` by literal JSON.
final class CLIFixtures: XCTestCase {
    private typealias F = HostFixture

    private static func c(_ name: String, _ input: [String: Any], _ out: Any) -> [String: Any] {
        ["name": name, "in": input, "out": out]
    }

    // MARK: - cli-args.json

    private static func command(_ cmd: HostCommand) -> [String: Any] {
        switch cmd {
        case let .serve(o):
            return ["cmd": "serve", "app": F.opt(o.app), "token": o.token, "port": Int(o.port),
                    "bind": F.opt(o.bind), "json": o.json]
        case let .listApps(json): return ["cmd": "list_apps", "json": json]
        case let .check(json, prompt): return ["cmd": "check", "json": json, "prompt": prompt]
        case let .version(json): return ["cmd": "version", "json": json]
        case let .lock(json): return ["cmd": "lock", "json": json]
        }
    }

    func testArguments() {
        let env = ["RAPP_TOKEN": "s3cret", "EMPTY": ""]
        let lists: [[String]] = [
            // testHostLegacyForm
            ["--token", "abc"],
            ["--port", "5000", "--token", "abc"],
            // testHostLegacyErrors
            [], ["--token"], ["--token", ""], ["--token", "a", "--port", "0"], ["--token", "a", "--port", "70000"],
            ["--token", "a", "--port"], ["--token", "a", "--json"], ["--token", "a", "extra"],
            // testHostServe
            ["serve", "--app", "com.apple.Safari", "--bind", "127.0.0.1", "--port", "0", "--token-env", "RAPP_TOKEN", "--json"],
            ["serve", "--token", "t", "--app", "a"],
            ["serve", "--token", "t", "--app", "desktop:"],
            // testHostServeErrors
            ["serve", "--token", "t"],
            ["serve", "--app", "", "--token", "t"],
            ["serve", "--app", "a"],
            ["serve", "--app", "a", "--token-env", "MISSING"],
            ["serve", "--app", "a", "--token-env", "EMPTY"],
            ["serve", "--app", "a", "--token", "t", "--port", "65536"],
            ["serve", "--app", "a", "--token", "t", "--port", "x"],
            ["serve", "--app", "a", "--token", "t", "--bind"],
            ["serve", "--app", "a", "--token", "t", "--what"],
            // testHostSubcommands
            ["version"], ["version", "--json"], ["check", "--json"], ["check", "--prompt", "--json"], ["check", "--prompt"],
            ["version", "--prompt"], ["list-apps"], ["check", "--token", "x"], ["list-apps", "extra"],
            ["lock", "--json"], ["lock"], ["lock", "extra"],
            // Extras: both token forms, empty --token beside a set variable, the port edges.
            ["serve", "--app", "a", "--token", "t", "--token-env", "RAPP_TOKEN"],
            ["serve", "--app", "a", "--token-env", "RAPP_TOKEN", "--token", ""],
            ["serve", "--app", "a", "--token", "t", "--port", "65535"],
            ["serve", "--app", "a", "--token", "t", "--port", "+80"],
            ["serve", "--app", "a", "--token", "t", "--port", "-0"],
            ["serve", "--app", "a", "--token", "t", "--port", "-1"],
            ["serve", "--app", "a", "--token", "t", "--port", "007"],
            ["serve", "--app", "a", "--token", "t", "--port", ""],
            ["serve", "--app", "a", "--token", "t", "--port", " 80"],
            ["serve", "--app", "a", "--token", "t", "--app", "b"],
            ["serve", "--json", "--json", "--app", "a", "--token", "t"],
            ["serve", "--app", "--token", "t"],
            ["serve", "--what", "--app"],
            ["serve", "--app", "desktop:2", "--token", "t", "--bind", "::1"],
            ["serve", "--app", "中文应用", "--token", "\"q\\\n"],
            ["serve", "--app", "a", "--token", "t", "-x"],
            ["dance"], ["-"], ["--token", "a", "--port", "1"], ["--token", "a", "--token-env", "RAPP_TOKEN"],
            ["--token-env", "RAPP_TOKEN"], ["check", "--prompt", "--prompt"], ["version", "--json", "extra"],
            ["list-apps", "--json"], ["lock", "--prompt"], ["Serve", "--app", "a", "--token", "t"],
        ]
        var cases: [[String: Any]] = []
        for (i, args) in lists.enumerated() {
            let out: [String: Any]
            do {
                out = ["ok": Self.command(try parseHostArguments(args, environment: env))]
            } catch {
                out = ["error": "\(error)"]
            }
            cases.append(Self.c("args \(i): \(args)", ["fn": "host", "args": args, "env": env], out))
        }
        F.check("cli-args.json", F.cases(cases))
    }

    // MARK: - cli-events.json

    private static func clipName(_ k: ClipKind) -> String { "\(k)" }

    private static func event(_ e: WorkerEvent) -> [String: Any] {
        switch e {
        case let .listening(port): return ["type": "listening", "port": Int(port)]
        case let .sessionStarted(client, mode, fps):
            return ["type": "session_started", "client": client, "mode": mode.name, "fps": fps]
        case let .sessionEnded(reason): return ["type": "session_ended", "reason": reason]
        case let .rejected(reason): return ["type": "rejected", "reason": reason]
        case let .stats(kbps, fps, width, height, rttMs, baseRttMs, latencyMs, weak, fulls, encMs):
            return ["type": "stats", "kbps": kbps, "fps": fps, "width": width, "height": height,
                    "rtt_ms": F.opt(rttMs), "base_rtt_ms": F.opt(baseRttMs), "latency_ms": F.opt(latencyMs),
                    "weak": weak, "fulls": fulls, "enc_ms": F.opt(encMs)]
        case let .ready(width, height, title): return ["type": "ready", "width": width, "height": height, "title": title]
        case let .windows(count): return ["type": "windows", "count": count]
        case let .transfer(dir, kind, bytes, name):
            return ["type": "transfer", "dir": dir.rawValue, "kind": clipName(kind), "bytes": bytes, "name": F.opt(name)]
        case .input: return ["type": "input"]
        case let .inputBlocked(by): return ["type": "input_blocked", "by": by]
        case .unlock: return ["type": "unlock"]
        case let .exit(code, reason): return ["type": "exit", "code": Int(code), "reason": reason]
        }
    }

    private static func stats(_ kbps: Double, rtt: Int? = nil, base: Int? = nil, latency: Int? = nil, weak: Bool = false,
                              fulls: Int = 0, enc: Int? = nil) -> WorkerEvent {
        .stats(kbps: kbps, fps: 15, width: 800, height: 600, rttMs: rtt, baseRttMs: base, latencyMs: latency, weak: weak,
               fulls: fulls, encMs: enc)
    }

    func testEvents() {
        let awkward = "say \"hi\" \\ back\nslash / 客户端 “你好”\t\u{1}"
        var events: [WorkerEvent] = [
            .listening(port: 51234), .listening(port: 0), .listening(port: 65535),
            .sessionStarted(client: "127.0.0.1:50000", mode: .color16, fps: 15),
            .sessionStarted(client: awkward, mode: .gray4, fps: 0),
            .sessionStarted(client: "", mode: .duocolor, fps: 30),
            .sessionEnded(reason: "client disconnected"), .sessionEnded(reason: awkward),
            .rejected(reason: "busy"),
            .stats(kbps: 12.34, fps: 15, width: 800, height: 600, rttMs: nil, baseRttMs: nil, latencyMs: nil, weak: false),
            .stats(kbps: 0, fps: 0, width: 0, height: 0, rttMs: nil, baseRttMs: nil, latencyMs: nil, weak: false),
            .stats(kbps: 1234.567, fps: 5, width: 1, height: 2, rttMs: nil, baseRttMs: nil, latencyMs: nil, weak: false),
            .stats(kbps: 1, fps: 2, width: 3, height: 4, rttMs: 120, baseRttMs: 80, latencyMs: 300, weak: true),
            .stats(kbps: 1, fps: 2, width: 3, height: 4, rttMs: nil, baseRttMs: 80, latencyMs: nil, weak: false),
            .stats(kbps: 1, fps: 2, width: 3, height: 4, rttMs: nil, baseRttMs: nil, latencyMs: nil, weak: false,
                   fulls: 2, encMs: 9),
            .ready(width: 800, height: 600, title: "Apple / “你好”"), .ready(width: 0, height: 0, title: awkward),
            .windows(count: 3), .windows(count: 0),
            .transfer(dir: .aToB, kind: .files, bytes: 5, name: "a.txt"),
            .transfer(dir: .bToA, kind: .image, bytes: 1000, name: nil),
            .transfer(dir: .bToA, kind: .data, bytes: 0, name: nil),
            .transfer(dir: .aToB, kind: .text, bytes: 7, name: nil),
            .transfer(dir: .bToA, kind: .files, bytes: UInt64.max, name: awkward),
            .input, .inputBlocked(by: "M"), .inputBlocked(by: ""), .unlock,
            .exit(code: 3, reason: "say \"hi\"\n"), .exit(code: 0, reason: "done"), .exit(code: -1, reason: awkward),
        ]
        // kbps rounding: ties, a tenth either side, large and tiny values.
        for kbps in [0.05, 0.15, 0.25, 0.35, 0.04, 0.06, 99.95, 99.94, 1e6, 123456789.98, 0.0001, 2.5, 7.25] {
            events.append(Self.stats(kbps))
        }
        events.append(Self.stats(3.3, rtt: 0, base: 0, latency: 0, weak: true, fulls: 1, enc: 0))
        var cases: [[String: Any]] = []
        for (i, e) in events.enumerated() {
            cases.append(Self.c("event \(i)", ["fn": "event", "event": Self.event(e)], e.jsonLine))
        }

        // appsJSON: the list part and the permissions Swift reports; Rust adds the Windows fields.
        func display(_ d: DesktopDisplay) -> [String: Any] {
            ["id": Int(d.id), "name": d.name, "main": d.main,
             "frame": F.rect(x: Double(d.frame.origin.x), y: Double(d.frame.origin.y),
                             width: Double(d.frame.size.width), height: Double(d.frame.size.height))]
        }
        let displays = [
            DesktopDisplay(id: 7, name: "DELL", main: false, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440)),
            DesktopDisplay(id: 1, name: "内建显示器", main: true, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ]
        let safari = [SharedApp(app: "com.apple.Safari", name: "Safari")]
        let appSets: [([SharedApp], Bool?, Bool?, [DesktopDisplay])] = [
            (safari, nil, nil, []), ([], nil, nil, []), (safari, nil, nil, displays), ([], false, true, []),
            (safari, true, true, displays),
            ([SharedApp(app: "notepad.exe", name: "记事本 \"x\""), SharedApp(app: "a/b", name: "")], false, false, []),
        ]
        for (i, (apps, screen, access, ds)) in appSets.enumerated() {
            let input: [String: Any] = [
                "fn": "apps", "apps": apps.map { ["app": $0.app, "name": $0.name] },
                "screen_recording": F.opt(screen), "accessibility": F.opt(access), "displays": ds.map(display),
            ]
            cases.append(Self.c("apps \(i)", input,
                                appsJSON(apps, screenRecording: screen, accessibility: access, displays: ds)))
        }

        // shareableApps + appsText.
        let regular: [Int32: SharedApp] = [
            1: SharedApp(app: "com.apple.Safari", name: "Safari"),
            2: SharedApp(app: "com.apple.TextEdit", name: "TextEdit"),
            3: SharedApp(app: "com.apple.Calculator", name: "Calculator"),
            4: SharedApp(app: "com.tiny", name: "Tiny"),
            5: SharedApp(app: "app10", name: "App 10"),
            6: SharedApp(app: "app9", name: "App 9"),
            7: SharedApp(app: "z.lower", name: "safari"),
            8: SharedApp(app: "b.alpha", name: "alpha"),
            9: SharedApp(app: "a.alpha", name: "Alpha"),
        ]
        func w(_ pid: Int32, _ layer: Int, _ width: Double, _ height: Double) -> ListedWindow {
            ListedWindow(pid: pid, layer: layer, width: width, height: height)
        }
        let windowSets: [[ListedWindow]] = [
            [w(2, 0, 600, 400), w(1, 0, 800, 600), w(1, 0, 300, 300), w(3, 25, 300, 300), w(4, 0, 49, 300),
             w(4, 0, 300, 49), w(9, 0, 300, 300), w(3, 0, 50, 50)].filter { $0.pid != 9 } + [w(99, 0, 300, 300)],
            [w(5, 0, 100, 100), w(6, 0, 100, 100), w(7, 0, 100, 100), w(1, 0, 100, 100), w(8, 0, 100, 100),
             w(9, 0, 100, 100)],
            [w(1, -1, 500, 500), w(2, 0, 49.9, 500), w(3, 0, 50, 49.99)],
            [],
        ]
        func listed(_ ws: [ListedWindow]) -> [[String: Any]] {
            ws.map { ["pid": Int($0.pid), "layer": $0.layer, "width": $0.width, "height": $0.height] }
        }
        let regularList: [[String: Any]] = regular.keys.sorted().map {
            ["pid": Int($0), "app": regular[$0]!.app, "name": regular[$0]!.name]
        }
        for (i, ws) in windowSets.enumerated() {
            let apps = shareableApps(windows: ws, regularApps: regular)
            cases.append(Self.c("shareable \(i)", ["fn": "shareable", "windows": listed(ws), "regular": regularList],
                                ["apps": apps.map { ["app": $0.app, "name": $0.name] }, "text": appsText(apps)]))
        }
        F.check("cli-events.json", F.cases(cases))
    }

    // MARK: - cli-commands.json

    private static func workerCommand(_ c: WorkerCommand?) -> Any {
        guard let c else { return NSNull() }
        switch c {
        case .kick: return ["cmd": "kick"]
        case .quit: return ["cmd": "quit"]
        case .focus: return ["cmd": "focus"]
        case let .peer(port, name): return ["cmd": "peer", "port": Int(port), "name": name]
        case let .yield(by): return ["cmd": "yield", "by": by]
        }
    }

    func testCommands() {
        let lines = [
            // testStdinCommands
            #"{"cmd":"quit"}"#, #"  {"cmd":"kick","extra":1}  "#, #"{"cmd":"focus"}"#,
            #"{"cmd":"peer","port":50123,"name":"Mac mini"}"#, #"{"cmd":"peer","port":70000,"name":"x"}"#,
            #"{"cmd":"yield","by":"Mac mini"}"#, #"{"cmd":"yield"}"#, #"{"cmd":"dance"}"#, "", "quit",
            #"{"cmd":3}"#, #"["quit"]"#,
            // Extras: peer without a port or a name, odd port numbers, broken JSON, blank lines.
            #"{"cmd":"peer","name":"x"}"#, #"{"cmd":"peer","port":1}"#, #"{"cmd":"peer","port":-1,"name":"x"}"#,
            #"{"cmd":"peer","port":0,"name":""}"#, #"{"cmd":"peer","port":65535,"name":"客厅的 \"Mac\""}"#,
            #"{"cmd":"peer","port":50123.0,"name":"x"}"#, #"{"cmd":"peer","port":50123.5,"name":"x"}"#,
            #"{"cmd":"peer","port":1e3,"name":"x"}"#, #"{"cmd":"peer","port":"50123","name":"x"}"#,
            #"{"cmd":"peer","port":true,"name":"x"}"#, #"{"cmd":"peer","port":null,"name":"x"}"#,
            #"{"cmd":"peer","port":65535,"name":3}"#, #"{"cmd":"yield","by":""}"#, #"{"cmd":"yield","by":null}"#,
            #"{"cmd":"quit""#, "   ", "\t", "{}", #"{"CMD":"quit"}"#, #"{"cmd":"Quit"}"#, #"{"cmd":"quit"} x"#,
            "null", "3", #""quit""#, #"{"cmd":"kick"}"# + "\n", #"{"cmd":"yield","by":"aé\n"}"#,
        ]
        var cases: [[String: Any]] = []
        for (i, line) in lines.enumerated() {
            cases.append(Self.c("command \(i)", ["fn": "command", "line": line], Self.workerCommand(parseWorkerCommand(line))))
        }
        F.check("cli-commands.json", F.cases(cases))
    }

    // MARK: - cli-hello.json

    private static func result(_ r: Result<String, CodecError>) -> [String: Any] {
        switch r {
        case let .success(s): return ["ok": s]
        case let .failure(e): return ["error": e.description]
        }
    }

    func testHello() {
        var cases: [[String: Any]] = []
        let resolves: [(String, String?)] = [
            ("com.x", nil), ("", "com.apple.Safari"), ("com.apple.Safari", "com.apple.Safari"), ("com.x", "com.apple.Safari"),
            ("", nil), ("desktop:", "desktop:"), ("desktop:1", "desktop:"), ("COM.X", "com.x"), ("", ""), ("a", ""),
        ]
        for (i, (requested, bound)) in resolves.enumerated() {
            cases.append(Self.c("resolve \(i)", ["fn": "resolve", "requested": requested, "bound": F.opt(bound)],
                                Self.result(resolveHelloApp(requested: requested, bound: bound))))
        }
        let checks: [(String, String, String, String?)] = [
            ("x", "", "t", "a"), ("t", "", "t", "a"), ("t", "b", "t", "a"),
            // Wrong token of the same length, of a different length, a prefix, empty on both sides.
            ("u", "", "t", "a"), ("tt", "", "t", "a"), ("t", "", "tt", "a"), ("", "", "", "a"), ("", "", "t", nil),
            ("s3cret", "com.x", "s3cret", nil), ("s3creT", "com.x", "s3cret", nil), ("密钥", "", "密钥", "a"),
            ("x", "b", "t", "a"),
        ]
        for (i, (token, bundleID, expected, bound)) in checks.enumerated() {
            cases.append(Self.c("check \(i)",
                                ["fn": "check", "token": token, "bundle_id": bundleID, "expected": expected, "bound": F.opt(bound)],
                                Self.result(checkHello(token: token, bundleID: bundleID, expected: expected, bound: bound))))
        }
        for (i, reason) in [ProtocolVersionMismatch(client: 2).description, "bad token", "busy",
                            "Protocol version mismatch", "", "host says: protocol version mismatch"].enumerated() {
            cases.append(Self.c("exit code \(i)", ["fn": "exit_code", "reason": reason], Int(exitCode(forHostError: reason))))
        }
        for (i, by) in (["Mac mini", nil, "", "客厅 \"Mac\""] as [String?]).enumerated() {
            cases.append(Self.c("taken over \(i)", ["fn": "taken_over", "by": F.opt(by)], takenOverError(by: by)))
        }
        let notices = [
            "host says: taken over by Mac mini", "taken over", "host says: Calculator quit", "host says: taken over",
            "taken over by ", "host says: taken over by ", "taken over by 客厅", "host says: host says: taken over",
            "Taken over", "taken over ", "taken over by \u{301}x", "host says: \u{301}taken over", "", "host says: ",
        ]
        for (i, reason) in notices.enumerated() {
            cases.append(Self.c("takeover notice \(i)", ["fn": "takeover_notice", "reason": reason],
                                F.opt(takeoverNotice(reason))))
        }
        for (i, by) in ["Mac mini", "", "客厅"].enumerated() {
            cases.append(Self.c("input blocked notice \(i)", ["fn": "input_blocked_notice", "by": by],
                                inputBlockedNotice(by: by)))
        }
        F.check("cli-hello.json", F.cases(cases))
    }
}
