import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import RappCore

let usage = """
    usage: rapp-host --token <secret> [--port \(defaultPort)]
           rapp-host serve --app <bundle-id> (--token <secret> | --token-env <VAR>) [--port \(defaultPort)] [--bind <address>] [--json]
           rapp-host list-apps [--json]
           rapp-host check [--prompt] [--json]
           rapp-host version [--json]
    """

let arguments = Array(CommandLine.arguments.dropFirst())
let command: HostCommand
do {
    command = try parseHostArguments(arguments, environment: ProcessInfo.processInfo.environment)
} catch {
    let output = WorkerOutput(json: arguments.contains("--json"))
    output.error(usage)
    output.finish(ExitCode.usage, "\(error)")
}

/// Both permissions belong to the app this command runs in (the terminal, or the service).
func permissions(prompt: Bool) -> (screenRecording: Bool, accessibility: Bool) {
    let screen = CGPreflightScreenCaptureAccess()
    // The grant only takes effect after a restart, so it still counts as missing.
    if !screen && prompt { _ = CGRequestScreenCaptureAccess() }
    let accessibility = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    return (screen, accessibility)
}

func missingPermissions(_ p: (screenRecording: Bool, accessibility: Bool)) -> [String] {
    (p.screenRecording ? [] : ["Screen Recording"]) + (p.accessibility ? [] : ["Accessibility"])
}

/// Regular apps with a normal on-screen window. Window bounds, layer and
/// owner need no permission, so this never prompts.
func listApps() -> [SharedApp] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let windows = list.compactMap { info -> ListedWindow? in
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let layer = info[kCGWindowLayer as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return ListedWindow(pid: pid, layer: layer, width: rect.width, height: rect.height)
    }
    var apps = [Int32: SharedApp]()
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let id = app.bundleIdentifier else { continue }
        apps[app.processIdentifier] = SharedApp(app: id, name: app.localizedName ?? id)
    }
    return shareableApps(windows: windows, regularApps: apps)
}

switch command {
case let .version(json):
    let output = WorkerOutput(json: json)
    output.result(json ? versionJSON() : "rapp-host \(rappVersion) (protocol \(protocolVersion))")
    output.finish(ExitCode.ok, "done")

case let .listApps(json):
    let output = WorkerOutput(json: json)
    let apps = listApps()
    if json {
        let granted = permissions(prompt: false)
        output.result(appsJSON(apps, screenRecording: granted.screenRecording, accessibility: granted.accessibility))
    } else if !apps.isEmpty {
        FileHandle.standardOutput.write(Data(appsText(apps).utf8))
    }
    output.finish(ExitCode.ok, "done")

case let .check(json, prompt):
    let output = WorkerOutput(json: json)
    let granted = permissions(prompt: prompt)
    output.result(checkJSON(screenRecording: granted.screenRecording, accessibility: granted.accessibility))
    let missing = missingPermissions(granted)
    if missing.isEmpty { output.finish(ExitCode.ok, "done") }
    output.finish(ExitCode.permission, "missing permission: \(missing.joined(separator: ", "))")

case let .serve(options):
    let output = WorkerOutput(json: options.json)
    // The legacy form asks for the permissions as before; `serve` never prompts.
    let legacy = options.app == nil
    let missing = missingPermissions(permissions(prompt: legacy))
    if !missing.isEmpty {
        output.finish(legacy ? ExitCode.usage : ExitCode.permission, """
            missing permission: \(missing.joined(separator: ", "))
            Allow rapp (or the terminal running rapp-host) under System Settings > Privacy & Security, then connect again.
            """)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    // Every AX call in this process gives up after 1 s instead of the
    // default 6: an app whose main thread is busy (TextEdit tearing down its
    // Save panel) must not stall the 10-times-a-second window poll.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)

    let server = Server(options: options, output: output)
    do {
        try server.start()
    } catch {
        output.finish(ExitCode.runtime, "cannot start: \(error.localizedDescription)")
    }
    if options.json {
        output.readCommands(onCommand: { command in
            switch command {
            case .kick: server.kick()
            case .quit: server.stop("quit")
            case .peer, .yield, .focus: break  // Task 3 wires peer and yield
            }
        }, onEOF: { server.stop("stdin closed") })
    }
    application.run()
}
