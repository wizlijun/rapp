import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import RappCore

let usage = "usage: rapp-host --token <secret> [--port \(defaultPort)]"

func exitWithMessage(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var token = ""
var port = defaultPort
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--token":
        guard !arguments.isEmpty else { exitWithMessage(usage) }
        token = arguments.removeFirst()
    case "--port":
        guard !arguments.isEmpty, let value = UInt16(arguments.removeFirst()), value != 0 else { exitWithMessage(usage) }
        port = value
    default:
        exitWithMessage("unknown argument \(argument)\n\(usage)")
    }
}
guard !token.isEmpty else { exitWithMessage(usage) }

setlinebuf(stdout)

// Both permissions belong to the app this command runs in (the terminal).
var missing = [String]()
if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    missing.append("Screen Recording")
}
if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
    missing.append("Accessibility")
}
if !missing.isEmpty {
    exitWithMessage("""
        missing permission: \(missing.joined(separator: ", "))
        Allow your terminal app under System Settings > Privacy & Security, restart the terminal, then run this again.
        """)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let server = Server(port: port, token: token)
do {
    try server.start()
} catch {
    exitWithMessage("cannot start: \(error.localizedDescription)")
}
application.run()
