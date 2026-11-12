import Foundation

// The worker command line (platform spec §5): argument parsing, JSON lines on
// stdout, and the commands read from stdin. Shared by rapp-host and rapp-client.

public let rappVersion = "0.3.0"

/// Exit codes of both workers.
public enum ExitCode {
    public static let ok: Int32 = 0
    public static let runtime: Int32 = 1
    public static let usage: Int32 = 2
    public static let permission: Int32 = 3
    public static let version: Int32 = 5
}

public struct HostServeOptions: Equatable {
    /// The app this host shares; nil for the legacy form, which takes the app from each Hello.
    public var app: String?
    public var token: String
    public var port: UInt16
    /// The address to listen on; nil listens on every interface.
    public var bind: String?
    public var json: Bool

    public init(app: String?, token: String, port: UInt16, bind: String?, json: Bool) {
        self.app = app
        self.token = token
        self.port = port
        self.bind = bind
        self.json = json
    }
}

public enum HostCommand: Equatable {
    case serve(HostServeOptions)
    case listApps(json: Bool)
    /// `prompt`: ask macOS for what is missing, so the system lists this app.
    case check(json: Bool, prompt: Bool)
    case version(json: Bool)
}

public enum ClientCommand: Equatable {
    case connect(RemoteAddress, json: Bool)
    case version(json: Bool)
}

/// Splits flags (`--name value`, or bare `--json`) from positional arguments.
private struct Arguments {
    var values = [String: String]()
    var json = false
    var flags = Set<String>()
    var positional = [String]()

    init(_ args: [String], valued: Set<String>, bare: Set<String> = []) throws {
        var rest = args[...]
        while let arg = rest.popFirst() {
            if arg == "--json" {
                json = true
            } else if bare.contains(arg) {
                flags.insert(arg)
            } else if valued.contains(arg) {
                guard let value = rest.popFirst() else { throw CodecError("\(arg) needs a value") }
                values[arg] = value
            } else if arg.hasPrefix("--") {
                throw CodecError("unknown argument \(arg)")
            } else {
                positional.append(arg)
            }
        }
    }

    func noPositional() throws {
        if let extra = positional.first { throw CodecError("unexpected argument \(extra)") }
    }

    /// `--token`, else the variable named by `--token-env`; must not be empty.
    func token(_ environment: [String: String]) throws -> String {
        if let token = values["--token"] {
            guard !token.isEmpty else { throw CodecError("the token is empty") }
            return token
        }
        guard let name = values["--token-env"] else { throw CodecError("--token or --token-env is required") }
        guard let token = environment[name], !token.isEmpty else {
            throw CodecError("environment variable \(name) is empty or not set")
        }
        return token
    }
}

private func parsePort(_ text: String?, allowZero: Bool) throws -> UInt16 {
    guard let text else { return defaultPort }
    guard let port = UInt16(text), allowZero || port != 0 else { throw CodecError("bad port \(text)") }
    return port
}

public func parseHostArguments(_ args: [String], environment: [String: String]) throws -> HostCommand {
    let subcommand = args.first ?? ""
    switch subcommand {
    case "list-apps", "check", "version":
        let parsed = try Arguments(Array(args.dropFirst()), valued: [],
                                   bare: subcommand == "check" ? ["--prompt"] : [])
        try parsed.noPositional()
        switch subcommand {
        case "list-apps": return .listApps(json: parsed.json)
        case "check": return .check(json: parsed.json, prompt: parsed.flags.contains("--prompt"))
        default: return .version(json: parsed.json)
        }
    case "serve":
        let parsed = try Arguments(Array(args.dropFirst()),
                                   valued: ["--app", "--token", "--token-env", "--port", "--bind"])
        try parsed.noPositional()
        guard let app = parsed.values["--app"], !app.isEmpty else { throw CodecError("--app is required") }
        return .serve(HostServeOptions(app: app, token: try parsed.token(environment),
                                       port: try parsePort(parsed.values["--port"], allowZero: true),
                                       bind: parsed.values["--bind"], json: parsed.json))
    default:
        // Legacy: rapp-host --token X [--port N]
        let parsed = try Arguments(args, valued: ["--token", "--port"])
        try parsed.noPositional()
        guard !parsed.json else { throw CodecError("unknown argument --json") }
        guard parsed.values["--token"] != nil else { throw CodecError("--token is required") }
        return .serve(HostServeOptions(app: nil, token: try parsed.token(environment),
                                       port: try parsePort(parsed.values["--port"], allowZero: false),
                                       bind: nil, json: false))
    }
}

public func parseClientArguments(_ args: [String], environment: [String: String]) throws -> ClientCommand {
    if args.first == "version" {
        let parsed = try Arguments(Array(args.dropFirst()), valued: [])
        try parsed.noPositional()
        return .version(json: parsed.json)
    }
    let parsed = try Arguments(args.first == "connect" ? Array(args.dropFirst()) : args, valued: ["--token-env"])
    guard parsed.positional.count == 1 else { throw CodecError("give exactly one address") }
    let fallback = parsed.values["--token-env"].flatMap { environment[$0] }
    return .connect(try RemoteAddress(url: parsed.positional[0], fallbackToken: fallback), json: parsed.json)
}

/// The client's exit code after the host sent `Error(reason)`.
public func exitCode(forHostError reason: String) -> Int32 {
    reason.hasPrefix("protocol version mismatch") ? ExitCode.version : ExitCode.runtime
}

/// The app a Hello asks for, given the app this host was started for (if any).
public func resolveHelloApp(requested: String, bound: String?) -> Result<String, CodecError> {
    guard let bound else { return .success(requested) }
    return requested.isEmpty || requested == bound ? .success(bound) : .failure(CodecError("this host shares \(bound)"))
}

/// Checks a Hello's token (constant time), then resolves the app it asks for.
public func checkHello(token: String, bundleID: String, expected: String, bound: String?) -> Result<String, CodecError> {
    guard constantTimeEquals(token, expected) else { return .failure(CodecError("bad token")) }
    return resolveHelloApp(requested: bundleID, bound: bound)
}

/// The `Error` reason sent to a client whose session another client took over.
public func takenOverError(by name: String?) -> String {
    guard let name, !name.isEmpty else { return "taken over" }
    return "taken over by \(name)"
}

/// The notice shown to the user for a takeover reason (with or without the `host says: ` prefix); nil for other reasons.
public func takeoverNotice(_ reason: String) -> String? {
    let prefix = "host says: "
    let text = reason.hasPrefix(prefix) ? String(reason.dropFirst(prefix.count)) : reason
    if text == "taken over" { return "这个窗口在另一台设备上打开了" }
    let by = "taken over by "
    if text.hasPrefix(by) {
        let name = text.dropFirst(by.count)
        return name.isEmpty ? "这个窗口在另一台设备上打开了" : "这个窗口在 \(name) 上打开了"
    }
    return nil
}

/// The notice shown to a client whose input is blocked because another client is operating A.
public func inputBlockedNotice(by: String) -> String {
    by.isEmpty ? "A 正在被另一台设备操作" : "A 正在被 \(by) 操作"
}

// MARK: JSON lines

/// One JSON object on one line, keys sorted.
public func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

/// Which way a clipboard item or file went.
public enum TransferDirection: String, Sendable { case aToB = "a_to_b", bToA = "b_to_a" }

public enum WorkerEvent: Equatable {
    case listening(port: UInt16)
    case sessionStarted(client: String, mode: Mode, fps: Int)
    case sessionEnded(reason: String)
    case rejected(reason: String)
    case stats(kbps: Double, fps: Int, width: Int, height: Int)
    case ready(width: Int, height: Int, title: String)
    /// The client's window table changed; `count` windows in it (multi-window spec §4.6).
    case windows(count: Int)
    /// One clipboard item or file finished crossing (observability spec §4.3). `name` only for files.
    case transfer(dir: TransferDirection, kind: ClipKind, bytes: UInt64, name: String?)
    /// This client's own input reached the host.
    case input
    /// This client's input was blocked because `by` is operating A.
    case inputBlocked(by: String)
    case exit(code: Int32, reason: String)

    public var jsonLine: String {
        switch self {
        case let .listening(port):
            return RappCore.jsonLine(["event": "listening", "port": Int(port)])
        case let .sessionStarted(client, mode, fps):
            return RappCore.jsonLine(["event": "session", "state": "started", "client": client, "mode": mode.name, "fps": fps])
        case let .sessionEnded(reason):
            return RappCore.jsonLine(["event": "session", "state": "ended", "reason": reason])
        case let .rejected(reason):
            return RappCore.jsonLine(["event": "rejected", "reason": reason])
        case let .stats(kbps, fps, width, height):
            // A decimal, so it prints as 12.3 rather than 12.300000000000001.
            let rounded = NSDecimalNumber(string: String(format: "%.1f", kbps))
            return RappCore.jsonLine(["event": "stats", "kbps": rounded, "fps": fps, "width": width, "height": height])
        case let .ready(width, height, title):
            return RappCore.jsonLine(["event": "ready", "width": width, "height": height, "title": title])
        case let .windows(count):
            return RappCore.jsonLine(["event": "windows", "count": count])
        case let .transfer(dir, kind, bytes, name):
            var object: [String: Any] = ["event": "transfer", "dir": dir.rawValue, "kind": "\(kind)", "bytes": bytes]
            if let name { object["name"] = name }
            return RappCore.jsonLine(object)
        case .input:
            return RappCore.jsonLine(["event": "input"])
        case let .inputBlocked(by):
            return RappCore.jsonLine(["event": "input_blocked", "by": by])
        case let .exit(code, reason):
            return RappCore.jsonLine(["event": "exit", "code": Int(code), "reason": reason])
        }
    }
}

public func versionJSON() -> String {
    jsonLine(["version": rappVersion, "protocol": Int(protocolVersion)])
}

public func checkJSON(screenRecording: Bool, accessibility: Bool) -> String {
    jsonLine(["screen_recording": screenRecording, "accessibility": accessibility])
}

/// A command read from a worker's stdin.
public enum WorkerCommand: Equatable {
    case kick, quit, focus
    case peer(port: UInt16, name: String)
    case yield(by: String)
}

/// The command on one stdin line; nil if the line is not a JSON object with a known `cmd` and its fields.
public func parseWorkerCommand(_ line: String) -> WorkerCommand? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let cmd = object["cmd"] as? String else { return nil }
    switch cmd {
    case "kick": return .kick
    case "quit": return .quit
    case "focus": return .focus
    case "peer":
        guard let port = object["port"] as? Int, let port = UInt16(exactly: port),
              let name = object["name"] as? String else { return nil }
        return .peer(port: port, name: name)
    case "yield":
        guard let by = object["by"] as? String else { return nil }
        return .yield(by: by)
    default: return nil
    }
}

// MARK: list-apps

public struct SharedApp: Equatable {
    public var app: String
    public var name: String
    public init(app: String, name: String) {
        self.app = app
        self.name = name
    }
}

public struct ListedWindow {
    public var pid: Int32
    public var layer: Int
    public var width: Double
    public var height: Double
    public init(pid: Int32, layer: Int, width: Double, height: Double) {
        self.pid = pid
        self.layer = layer
        self.width = width
        self.height = height
    }
}

/// Regular apps owning at least one on-screen window of layer 0 and at least
/// 50×50 points, each once, sorted by name.
public func shareableApps(windows: [ListedWindow], regularApps: [Int32: SharedApp]) -> [SharedApp] {
    var byID = [String: SharedApp]()
    for w in windows where w.layer == 0 && w.width >= 50 && w.height >= 50 {
        if let app = regularApps[w.pid] { byID[app.app] = app }
    }
    return byID.values.sorted {
        let order = $0.name.localizedStandardCompare($1.name)
        return order == .orderedSame ? $0.app < $1.app : order == .orderedAscending
    }
}

/// With the permissions when given, so B sees what A is missing before opening an app.
public func appsJSON(_ apps: [SharedApp], screenRecording: Bool? = nil, accessibility: Bool? = nil) -> String {
    var object: [String: Any] = ["apps": apps.map { ["app": $0.app, "name": $0.name] }]
    if let screenRecording, let accessibility {
        object["permissions"] = ["screen_recording": screenRecording, "accessibility": accessibility]
    }
    return jsonLine(object)
}

/// `bundleID<TAB>name`, one app per line.
public func appsText(_ apps: [SharedApp]) -> String {
    apps.map { "\($0.app)\t\($0.name)\n" }.joined()
}

// MARK: Output

/// Where a worker writes. With `json`, stdout carries only JSON event lines and
/// human logs go to stderr; without it logs go to stdout as before.
public final class WorkerOutput {
    public let json: Bool
    private let lock = NSLock()

    public init(json: Bool) { self.json = json }

    public func log(_ text: String) {
        write(text, to: json ? .standardError : .standardOutput)
    }

    public func error(_ text: String) {
        write(text, to: .standardError)
    }

    /// Writes the event line; does nothing without `json`.
    public func emit(_ event: WorkerEvent) {
        if json { write(event.jsonLine, to: .standardOutput) }
    }

    /// Writes a result line (version, check, list-apps) to stdout.
    public func result(_ line: String) {
        write(line, to: .standardOutput)
    }

    /// Ends the process. A failure reason also goes to stderr; with `json` the
    /// last stdout line is the exit event. Later callers block until the exit.
    public func finish(_ code: Int32, _ reason: String) -> Never {
        lock.lock()  // never released: nothing may be written after the exit event
        if code != ExitCode.ok { FileHandle.standardError.write(Data((reason + "\n").utf8)) }
        if json { FileHandle.standardOutput.write(Data((WorkerEvent.exit(code: code, reason: reason).jsonLine + "\n").utf8)) }
        exit(code)
    }

    private func write(_ text: String, to handle: FileHandle) {
        lock.withLock { handle.write(Data((text + "\n").utf8)) }
    }

    /// Reads JSON-line commands from stdin on a background thread, calling
    /// `onCommand` with each command (unknown or malformed lines are logged and skipped)
    /// and `onEOF` once stdin closes.
    public func readCommands(onCommand: @escaping (WorkerCommand) -> Void, onEOF: @escaping () -> Void) {
        let thread = Thread { [self] in
            while let line = readLine() {
                if let command = parseWorkerCommand(line) {
                    onCommand(command)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    error("ignored stdin line: \(line)")
                }
            }
            onEOF()
        }
        thread.start()
    }
}

/// Whether a takeover prompt is up. While it is, the closing socket and later host messages must not end the
/// client (the user is still choosing), and a second takeover must not stack another prompt.
public final class TakeoverGate {
    public private(set) var pending = false
    public init() {}
    /// True the first time only: the caller shows the prompt then.
    public func begin() -> Bool {
        if pending { return false }
        pending = true
        return true
    }
}
