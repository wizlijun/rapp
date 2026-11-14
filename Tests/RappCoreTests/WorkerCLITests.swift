import XCTest
@testable import RappCore

final class WorkerCLITests: XCTestCase {
    private let env = ["RAPP_TOKEN": "s3cret", "EMPTY": ""]

    private func host(_ args: String...) throws -> HostCommand {
        try parseHostArguments(args, environment: env)
    }

    private func client(_ args: String...) throws -> ClientCommand {
        try parseClientArguments(args, environment: env)
    }

    // MARK: rapp-host arguments

    func testTakeoverGateAllowsOnePromptAndStaysPending() {
        let gate = TakeoverGate()
        XCTAssertFalse(gate.pending)
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.pending)
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.pending)
    }

    func testHostLegacyForm() throws {
        XCTAssertEqual(try host("--token", "abc"),
                       .serve(HostServeOptions(app: nil, token: "abc", port: 47800, bind: nil, json: false)))
        XCTAssertEqual(try host("--port", "5000", "--token", "abc"),
                       .serve(HostServeOptions(app: nil, token: "abc", port: 5000, bind: nil, json: false)))
    }

    func testHostLegacyErrors() {
        for bad in [[], ["--token"], ["--token", ""], ["--token", "a", "--port", "0"], ["--token", "a", "--port", "70000"],
                    ["--token", "a", "--port"], ["--token", "a", "--json"], ["--token", "a", "extra"]] {
            XCTAssertThrowsError(try parseHostArguments(bad, environment: env), "\(bad)")
        }
    }

    func testHostServe() throws {
        XCTAssertEqual(try host("serve", "--app", "com.apple.Safari", "--bind", "127.0.0.1", "--port", "0",
                                "--token-env", "RAPP_TOKEN", "--json"),
                       .serve(HostServeOptions(app: "com.apple.Safari", token: "s3cret", port: 0, bind: "127.0.0.1", json: true)))
        XCTAssertEqual(try host("serve", "--token", "t", "--app", "a"),
                       .serve(HostServeOptions(app: "a", token: "t", port: 47800, bind: nil, json: false)))
    }

    func testHostServeErrors() {
        let bad: [[String]] = [
            ["serve", "--token", "t"],                                  // no app
            ["serve", "--app", "", "--token", "t"],                     // empty app
            ["serve", "--app", "a"],                                    // no token
            ["serve", "--app", "a", "--token-env", "MISSING"],          // unset variable
            ["serve", "--app", "a", "--token-env", "EMPTY"],            // empty variable
            ["serve", "--app", "a", "--token", "t", "--port", "65536"],
            ["serve", "--app", "a", "--token", "t", "--port", "x"],
            ["serve", "--app", "a", "--token", "t", "--bind"],
            ["serve", "--app", "a", "--token", "t", "--what"],
        ]
        for args in bad {
            XCTAssertThrowsError(try parseHostArguments(args, environment: env), "\(args)")
        }
    }

    func testHostSubcommands() throws {
        XCTAssertEqual(try host("version"), .version(json: false))
        XCTAssertEqual(try host("version", "--json"), .version(json: true))
        XCTAssertEqual(try host("check", "--json"), .check(json: true, prompt: false))
        XCTAssertEqual(try host("check", "--prompt", "--json"), .check(json: true, prompt: true))
        XCTAssertEqual(try host("check", "--prompt"), .check(json: false, prompt: true))
        XCTAssertThrowsError(try host("version", "--prompt"))
        XCTAssertEqual(try host("list-apps"), .listApps(json: false))
        XCTAssertThrowsError(try host("check", "--token", "x"))
        XCTAssertThrowsError(try host("list-apps", "extra"))
    }

    // MARK: rapp-client arguments

    func testClientLegacyForm() throws {
        let url = "rapp://mac-a.local/com.apple.TextEdit?token=abc"
        XCTAssertEqual(try client(url), .connect(try RemoteAddress(url: url), json: false))
        XCTAssertThrowsError(try parseClientArguments([], environment: env))
        XCTAssertThrowsError(try client(url, url))
        XCTAssertThrowsError(try client("rapp://h/app"))  // no token anywhere
    }

    func testClientConnectWithTokenFromEnvironment() throws {
        let expected = RemoteAddress(host: "127.0.0.1", port: 5000, bundleID: "", token: "s3cret", mode: .color16)
        XCTAssertEqual(try client("rapp://127.0.0.1:5000/?mode=color16", "--token-env", "RAPP_TOKEN", "--json"),
                       .connect(expected, json: true))
        XCTAssertEqual(try client("connect", "--json", "rapp://127.0.0.1:5000/?mode=color16", "--token-env", "RAPP_TOKEN"),
                       .connect(expected, json: true))
        // A token in the address wins over the environment.
        XCTAssertEqual(try client("rapp://h/app?token=inurl", "--token-env", "RAPP_TOKEN"),
                       .connect(RemoteAddress(host: "h", port: 47800, bundleID: "app", token: "inurl", mode: .gray4), json: false))
    }

    func testClientErrors() {
        for bad in [["rapp://h/?mode=color16", "--token-env", "MISSING"],
                    ["rapp://h/?mode=color16", "--token-env", "EMPTY"],
                    ["rapp://h/?token=t", "--token-env"],
                    ["rapp://h/?token=t", "--bogus"],
                    ["connect"],
                    ["version", "extra"]] {
            XCTAssertThrowsError(try parseClientArguments(bad, environment: env), "\(bad)")
        }
    }

    func testClientVersion() throws {
        XCTAssertEqual(try client("version"), .version(json: false))
        XCTAssertEqual(try client("version", "--json"), .version(json: true))
    }

    func testAddressWithoutAppHasEmptyAppID() throws {
        XCTAssertEqual(try RemoteAddress(url: "rapp://h/?token=t").bundleID, "")
        XCTAssertEqual(try RemoteAddress(url: "rapp://h?token=t").bundleID, "")
        XCTAssertThrowsError(try RemoteAddress(url: "rapp://h/a/b?token=t"))
    }

    func testClientExitCodeForHostError() {
        XCTAssertEqual(exitCode(forHostError: ProtocolVersionMismatch(client: 2).description), ExitCode.version)
        XCTAssertEqual(exitCode(forHostError: "bad token"), ExitCode.runtime)
        XCTAssertEqual(exitCode(forHostError: "busy"), ExitCode.runtime)
    }

    // MARK: Bound app

    func testHelloAppResolution() {
        XCTAssertEqual(resolveHelloApp(requested: "com.x", bound: nil), .success("com.x"))
        XCTAssertEqual(resolveHelloApp(requested: "", bound: "com.apple.Safari"), .success("com.apple.Safari"))
        XCTAssertEqual(resolveHelloApp(requested: "com.apple.Safari", bound: "com.apple.Safari"), .success("com.apple.Safari"))
        XCTAssertEqual(resolveHelloApp(requested: "com.x", bound: "com.apple.Safari"),
                       .failure(CodecError("this host shares com.apple.Safari")))
    }

    func testCheckHelloRejectsBadTokenAndWrongApp() {
        XCTAssertThrowsError(try checkHello(token: "x", bundleID: "", expected: "t", bound: "a").get()) { XCTAssertEqual("\($0)", "bad token") }
        XCTAssertEqual(try checkHello(token: "t", bundleID: "", expected: "t", bound: "a").get(), "a")
        XCTAssertThrowsError(try checkHello(token: "t", bundleID: "b", expected: "t", bound: "a").get()) { XCTAssertEqual("\($0)", "this host shares a") }
    }

    func testTakeoverWords() {
        XCTAssertEqual(takenOverError(by: "Mac mini"), "taken over by Mac mini")
        XCTAssertEqual(takenOverError(by: nil), "taken over")
        XCTAssertEqual(takenOverError(by: ""), "taken over")
        XCTAssertEqual(takeoverNotice("host says: taken over by Mac mini"), "这个窗口在 Mac mini 上打开了")
        XCTAssertEqual(takeoverNotice("taken over"), "这个窗口在另一台设备上打开了")
        XCTAssertNil(takeoverNotice("host says: Calculator quit"))
        XCTAssertEqual(inputBlockedNotice(by: "Mac mini"), "远端正在被 Mac mini 操作")
        XCTAssertEqual(inputBlockedNotice(by: ""), "远端正在被另一台设备操作")
    }

    func testInputEvents() {
        XCTAssertEqual(WorkerEvent.input.jsonLine, #"{"event":"input"}"#)
        XCTAssertEqual(WorkerEvent.inputBlocked(by: "M").jsonLine, #"{"by":"M","event":"input_blocked"}"#)
    }

    // MARK: JSON output

    func testEventLines() {
        XCTAssertEqual(WorkerEvent.listening(port: 51234).jsonLine, #"{"event":"listening","port":51234}"#)
        XCTAssertEqual(WorkerEvent.sessionStarted(client: "127.0.0.1:50000", mode: .color16, fps: 15).jsonLine,
                       #"{"client":"127.0.0.1:50000","event":"session","fps":15,"mode":"color16","state":"started"}"#)
        XCTAssertEqual(WorkerEvent.sessionEnded(reason: "client disconnected").jsonLine,
                       #"{"event":"session","reason":"client disconnected","state":"ended"}"#)
        XCTAssertEqual(WorkerEvent.rejected(reason: "busy").jsonLine, #"{"event":"rejected","reason":"busy"}"#)
        XCTAssertEqual(WorkerEvent.stats(kbps: 12.34, fps: 15, width: 800, height: 600,
                                         rttMs: nil, baseRttMs: nil, latencyMs: nil, weak: false).jsonLine,
                       #"{"event":"stats","fps":15,"fulls":0,"height":600,"kbps":12.3,"weak":false,"width":800}"#)
        XCTAssertEqual(WorkerEvent.ready(width: 800, height: 600, title: "Apple / “你好”").jsonLine,
                       #"{"event":"ready","height":600,"title":"Apple / “你好”","width":800}"#)
        XCTAssertEqual(WorkerEvent.windows(count: 3).jsonLine, #"{"count":3,"event":"windows"}"#)
        XCTAssertEqual(WorkerEvent.exit(code: 3, reason: "say \"hi\"\n").jsonLine,
                       #"{"code":3,"event":"exit","reason":"say \"hi\"\n"}"#)
    }

    func testTransferEventLine() {
        XCTAssertEqual(WorkerEvent.transfer(dir: .aToB, kind: .files, bytes: 5, name: "a.txt").jsonLine,
                       #"{"bytes":5,"dir":"a_to_b","event":"transfer","kind":"files","name":"a.txt"}"#)
        XCTAssertEqual(WorkerEvent.transfer(dir: .bToA, kind: .image, bytes: 1000, name: nil).jsonLine,
                       #"{"bytes":1000,"dir":"b_to_a","event":"transfer","kind":"image"}"#)
        XCTAssertEqual(WorkerEvent.transfer(dir: .bToA, kind: .data, bytes: 0, name: nil).jsonLine,
                       #"{"bytes":0,"dir":"b_to_a","event":"transfer","kind":"data"}"#)
        XCTAssertEqual(WorkerEvent.transfer(dir: .aToB, kind: .text, bytes: 7, name: nil).jsonLine,
                       #"{"bytes":7,"dir":"a_to_b","event":"transfer","kind":"text"}"#)
    }

    func testStatsKbpsIsRoundedToOneDecimal() {
        XCTAssertEqual(WorkerEvent.stats(kbps: 0, fps: 0, width: 0, height: 0,
                                         rttMs: nil, baseRttMs: nil, latencyMs: nil, weak: false).jsonLine,
                       #"{"event":"stats","fps":0,"fulls":0,"height":0,"kbps":0,"weak":false,"width":0}"#)
        XCTAssertEqual(WorkerEvent.stats(kbps: 1234.567, fps: 5, width: 1, height: 2,
                                         rttMs: nil, baseRttMs: nil, latencyMs: nil, weak: false).jsonLine,
                       #"{"event":"stats","fps":5,"fulls":0,"height":2,"kbps":1234.6,"weak":false,"width":1}"#)
    }

    func testStatsJsonCarriesPacingFields() {
        XCTAssertEqual(WorkerEvent.stats(kbps: 1, fps: 2, width: 3, height: 4,
                                         rttMs: 120, baseRttMs: 80, latencyMs: 300, weak: true).jsonLine,
                       #"{"baseRttMs":80,"event":"stats","fps":2,"fulls":0,"height":4,"kbps":1,"latencyMs":300,"rttMs":120,"weak":true,"width":3}"#)
        let partial = WorkerEvent.stats(kbps: 1, fps: 2, width: 3, height: 4,
                                        rttMs: nil, baseRttMs: 80, latencyMs: nil, weak: false).jsonLine
        XCTAssertFalse(partial.contains("rttMs"))
        XCTAssertFalse(partial.contains("latencyMs"))
        XCTAssertTrue(partial.contains(#""baseRttMs":80"#))
    }

    func testStatsJsonCarriesFullsAndEncodeTime() {
        XCTAssertEqual(WorkerEvent.stats(kbps: 1, fps: 2, width: 3, height: 4, rttMs: nil, baseRttMs: nil,
                                         latencyMs: nil, weak: false, fulls: 2, encMs: 9).jsonLine,
                       #"{"encMs":9,"event":"stats","fps":2,"fulls":2,"height":4,"kbps":1,"weak":false,"width":3}"#)
    }

    func testCommandOutputs() {
        XCTAssertEqual(versionJSON(), #"{"protocol":10,"version":"0.3.0"}"#)
        XCTAssertEqual(checkJSON(screenRecording: true, accessibility: false),
                       #"{"accessibility":false,"screen_recording":true}"#)
        XCTAssertEqual(appsJSON([SharedApp(app: "com.apple.Safari", name: "Safari")]),
                       #"{"apps":[{"app":"com.apple.Safari","name":"Safari"}]}"#)
        XCTAssertEqual(appsJSON([]), #"{"apps":[]}"#)
        XCTAssertEqual(appsJSON([], screenRecording: false, accessibility: true),
                       #"{"apps":[],"permissions":{"accessibility":true,"screen_recording":false}}"#)
    }

    func testStdinCommands() {
        XCTAssertEqual(parseWorkerCommand(#"{"cmd":"quit"}"#), .quit)
        XCTAssertEqual(parseWorkerCommand(#"  {"cmd":"kick","extra":1}  "#), .kick)
        XCTAssertEqual(parseWorkerCommand(#"{"cmd":"focus"}"#), .focus)
        XCTAssertEqual(parseWorkerCommand(#"{"cmd":"peer","port":50123,"name":"Mac mini"}"#), .peer(port: 50123, name: "Mac mini"))
        XCTAssertNil(parseWorkerCommand(#"{"cmd":"peer","port":70000,"name":"x"}"#))
        XCTAssertEqual(parseWorkerCommand(#"{"cmd":"yield","by":"Mac mini"}"#), .yield(by: "Mac mini"))
        XCTAssertNil(parseWorkerCommand(#"{"cmd":"yield"}"#))
        XCTAssertNil(parseWorkerCommand(#"{"cmd":"dance"}"#))
        XCTAssertNil(parseWorkerCommand(""))
        XCTAssertNil(parseWorkerCommand("quit"))
        XCTAssertNil(parseWorkerCommand(#"{"cmd":3}"#))
        XCTAssertNil(parseWorkerCommand(#"["quit"]"#))
    }

    // MARK: list-apps

    func testShareableApps() {
        let apps: [Int32: SharedApp] = [
            1: SharedApp(app: "com.apple.Safari", name: "Safari"),
            2: SharedApp(app: "com.apple.TextEdit", name: "TextEdit"),
            3: SharedApp(app: "com.apple.Calculator", name: "Calculator"),
            4: SharedApp(app: "com.tiny", name: "Tiny"),
        ]
        let windows = [
            ListedWindow(pid: 2, layer: 0, width: 600, height: 400),
            ListedWindow(pid: 1, layer: 0, width: 800, height: 600),
            ListedWindow(pid: 1, layer: 0, width: 300, height: 300),   // second Safari window: listed once
            ListedWindow(pid: 3, layer: 25, width: 300, height: 300),  // not a normal window
            ListedWindow(pid: 4, layer: 0, width: 49, height: 300),    // too small
            ListedWindow(pid: 4, layer: 0, width: 300, height: 49),
            ListedWindow(pid: 9, layer: 0, width: 300, height: 300),   // not a regular app
            ListedWindow(pid: 3, layer: 0, width: 50, height: 50),
        ]
        XCTAssertEqual(shareableApps(windows: windows, regularApps: apps).map(\.name), ["Calculator", "Safari", "TextEdit"])
        XCTAssertEqual(appsText(shareableApps(windows: windows, regularApps: apps)),
                       "com.apple.Calculator\tCalculator\ncom.apple.Safari\tSafari\ncom.apple.TextEdit\tTextEdit\n")
    }
}
