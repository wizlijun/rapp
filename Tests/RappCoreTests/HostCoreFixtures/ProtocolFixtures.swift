import XCTest
@testable import RappCore

/// The picture protocol as the Swift host speaks it (read by `rust/host-core/tests/protocol.rs`).
///
/// - `protocol-messages.bin`: one record per sample, tag = the message type byte,
///   payload = `message.encoded()` (the whole message: type, u32 LE length, body).
/// - `protocol-types.json`: one case `{"name": "types", "in": null, "out": [{"type", "case"}…]}`,
///   sorted by type: every type the parser knows, with its Swift case name.
/// - `protocol-rejects.json`: cases whose `in` is the hex of bytes fed to one `MessageParser`
///   and whose `out` is `{"error": text or null, "again": hex or null}`: the error text of the
///   first `next()` that throws, or, when every message parses, the hex of all of them
///   re-encoded (which catches a decoder that silently changes what it accepts).
final class ProtocolFixtures: XCTestCase {
    // MARK: - Samples

    /// 66 é (e + combining acute), 67 flags and 67 ZWJ families: 200 grapheme clusters.
    static let title200: String = String(repeating: "e\u{301}", count: 66)
        + String(repeating: "🇨🇳", count: 67) + String(repeating: "👨‍👩‍👧", count: 67)

    static let windows256: [WindowInfo] = (1...256).map { i in
        WindowInfo(id: UInt32(i), parent: i == 1 ? 0 : 1, kind: WindowKind(rawValue: UInt8(i % 7))!,
                   resizable: i % 2 == 0, focused: i == 1,
                   rect: CanvasRect(x: Float(i), y: -Float(i) / 4, w: 100 + Float(i), h: 50.5),
                   titleBar: i % 3 == 0 ? 0 : 28, title: "窗口 \(i)")
    }

    static let samples: [Message] = {
        var rng = HostRNG(seed: 2)
        var out: [Message] = [
            .hello(token: "口令abc", bundleID: "com.apple.TextEdit", mode: .color8, fps: 15, density: 2),
            .hello(token: "", bundleID: "", mode: .gray4, fps: 30, density: 8),
            .hello(token: "t", bundleID: "b", mode: .duogray, fps: 1, density: 0.375),
            .ready(appName: "文本编辑 😀", width: 1920, height: 1080),
            .ready(appName: "", width: 0, height: 65535),
            .error("bad token"),
            .error(""),
            .frame(region: CanvasRect(x: 208, y: 72, w: 616, h: 512),
                   FramePayload(width: 130, height: 70, flags: [.full, .start, .end], data: [1, 2, 3, 250])),
            .frame(region: CanvasRect(x: 0, y: 0, w: 1, h: 1),
                   FramePayload(width: 1, height: 1, flags: [.start, .end], data: [])),
            .frame(region: CanvasRect(x: -10.25, y: 3, w: 160, h: 120),
                   FramePayload(mode: .duocolor, width: 160, height: 120, flags: [.start, .copies],
                                dx: -3, dy: -64, data: rng.bytes(65536))),
            .frame(region: CanvasRect(x: 0.5, y: 8, w: 64, h: 64),
                   FramePayload(mode: .color16, width: 64, height: 64, flags: [.end], data: [9])),
            .text("你好😀"),
            .text(""),
            .text("e\u{301}🇨🇳👨‍👩‍👧"),
            .key(keyCode: 36, modifiers: 0x100108, down: true),
            .key(keyCode: 65535, modifiers: UInt64.max, down: false),
            .mouse(kind: .drag, button: .right, window: 3931, x: 25.5, y: -3, clickCount: 2),
            .mouse(kind: .move, button: .left, window: 1, x: 0, y: 0, clickCount: 0),
            .mouse(kind: .down, button: .left, window: 0, x: -0.0, y: 16_777_216, clickCount: 255),
            .mouse(kind: .up, button: .right, window: 7, x: 1e-7, y: 3.4e38, clickCount: 1),
            .scroll(window: 0xFFFF_FFFF, x: 10, y: 20.5, dx: -3.5, dy: 12),
            .scroll(window: 0, x: 0, y: 0, dx: 0, dy: -0.125),
            .resize(window: 3931, width: 1024, height: 768),
            .setStream(mode: .color16, fps: 15, density: 1, pinned: false),
            .setStream(mode: .duocolor, fps: 0, density: 1.25, pinned: true, focus: true),
            .setStream(mode: .gray4, fps: 30, density: 8, pinned: false, focus: true),
            .windows([]),
            .windows([
                WindowInfo(id: 3931, parent: 0, kind: .normal, resizable: true, focused: true,
                           rect: CanvasRect(x: 213, y: 77, w: 603, h: 505), titleBar: 32, title: "未命名 — 已编辑"),
                WindowInfo(id: 3935, parent: 3931, kind: .menu, resizable: false, focused: false,
                           rect: CanvasRect(x: 219, y: 171, w: 220, h: 342), titleBar: 0, title: ""),
                WindowInfo(id: 3936, parent: 0, kind: .dialog, resizable: false, focused: false,
                           rect: CanvasRect(x: 1, y: 2, w: 3, h: 4), titleBar: 3.5, title: title200),
            ]),
            .windows(windows256),
            .focus(3931),
            .close(7),
            .move(window: 3931, x: -40.5, y: 1000),
            .menuBar([]),
            .menuBar([
                MenuItem(title: "TextEdit", children: [
                    MenuItem(title: "About TextEdit"),
                    MenuItem(title: "", enabled: false, separator: true),
                    MenuItem(title: "Quit TextEdit", key: "Q", modifiers: 8),
                ]),
                MenuItem(title: "格式", children: [
                    MenuItem(title: "字体", children: [MenuItem(title: "粗体", checked: true, key: "B", modifiers: 15)]),
                ]),
            ]),
            .menuPick([0]),
            .menuPick([1, 0, 0, 2, 3, 4, 5, 65535]),
            .clip(id: 1, .text("你好😀", truncated: false)),
            .clip(id: 0xFFFF_FFFF, .text("", truncated: true)),
            .clip(id: 2, .image(width: 1280, height: 720, bytes: 348_160)),
            .clip(id: 3, .files([ClipFile(name: "app.log", bytes: 2_411_724), ClipFile(name: "空 文件", bytes: 0)])),
            .clip(id: 6, .files([])),
            .clip(id: 4, .data(uti: "com.adobe.pdf", bytes: UInt64.max)),
            .clip(id: 5, .unsupported("文件夹（不支持）")),
            .paste(seq: 1, .text("贴😀")),
            .paste(seq: 0, .text("")),
            .paste(seq: 2, .item(7)),
            .pasted(seq: 2, error: ""),
            .pasted(seq: 3, error: "target not frontmost"),
            .fetch(token: "t", clip: 9, file: 99, offset: 1 << 40),
            .put(token: "t", item: 3, kind: .files, uti: "public.data", name: "app.log", total: 5),
            .put(token: "", item: 0, kind: .text, uti: "", name: "", total: 0),
            .put(token: "k", item: 1, kind: .image, uti: "public.png", name: "a.png", total: 1),
            .put(token: "k", item: 2, kind: .data, uti: "com.adobe.pdf", name: "x", total: UInt64.max),
            .transferStart(0),
            .transferStart(UInt64.max),
            .chunk([]),
            .chunk(rng.bytes(chunkSize)),
            .inputBlocked(by: "rapp-49"),
            .frameAck(processingMs: 0),
            .frameAck(processingMs: 65535),
            .weak(true),
            .weak(false),
            .inputSource(id: "com.apple.keylayout.ABC", name: "ABC", ascii: true),
            .inputSource(id: "im.rime.inputmethod.Squirrel.Hans", name: "鼠须管", ascii: false),
            .selectInput(id: ""),
            .selectInput(id: "com.apple.keylayout.US"),
            .ping(0),
            .ping(0xFFFF_FFFF),
            .pong(42),
            .saving(0),
            .saving(2),
            .screenLocked(true),
            .screenLocked(false),
            .unlock(password: ""),
            .unlock(password: "密码 pass"),
            .unlock(password: String(repeating: "A", count: unlockPasswordLimit)),
            .focusRegion(window: 3, rects: []),
            .focusRegion(window: 0, rects: [
                CanvasRect(x: 1, y: 2, w: 3, h: 4),
                CanvasRect(x: -5, y: 0.5, w: 100, h: 0),
                CanvasRect(x: 0, y: 0, w: 1920, h: 1080),
            ]),
            .covered(id: 412, name: "1Password", bundleID: "com.1password.1password", dismissable: false),
            .covered(id: 0, name: "", bundleID: "", dismissable: true),
            .setView(window: 0, rect: CanvasRect(x: 0, y: 0, w: 0, h: 0)),
            .setView(window: 3931, rect: CanvasRect(x: 10, y: -20, w: 300.5, h: 200)),
            .dismissCover(412),
            .appOpened(bundleID: "com.apple.Safari", name: "Safari"),
            .appOpened(bundleID: "", name: ""),
            .secureFocus(true),
            .secureFocus(false),
            .changed,
            .stateRules(""),
            .stateRules("{\"name\":\"状态\",\"rules\":[]}"),
            .stateRules(String(repeating: "r", count: stateRulesLimit)),
            .appState(""),
            .appState("{\"a\":1}"),
            .appState(String(repeating: "s", count: appStateLimit)),
        ]
        for mode in Mode.allCases {
            out.append(.setStream(mode: mode, fps: 5, density: 2, pinned: false))
            out.append(.frame(region: CanvasRect(x: 1, y: 1, w: 2, h: 2),
                              FramePayload(mode: mode, width: 2, height: 2, flags: [.start, .end], dx: 1, dy: -1, data: [0])))
        }
        return out
    }()

    /// Exhaustive on purpose, with no `default`: a new Swift case stops this file compiling
    /// until it has a name here and a sample above.
    private static func caseName(_ m: Message) -> String {
        switch m {
        case .hello: return "hello"
        case .ready: return "ready"
        case .error: return "error"
        case .frame: return "frame"
        case .text: return "text"
        case .key: return "key"
        case .mouse: return "mouse"
        case .scroll: return "scroll"
        case .resize: return "resize"
        case .setStream: return "setStream"
        case .windows: return "windows"
        case .focus: return "focus"
        case .close: return "close"
        case .move: return "move"
        case .menuBar: return "menuBar"
        case .menuPick: return "menuPick"
        case .clip: return "clip"
        case .paste: return "paste"
        case .pasted: return "pasted"
        case .fetch: return "fetch"
        case .put: return "put"
        case .transferStart: return "transferStart"
        case .chunk: return "chunk"
        case .inputBlocked: return "inputBlocked"
        case .frameAck: return "frameAck"
        case .weak: return "weak"
        case .inputSource: return "inputSource"
        case .selectInput: return "selectInput"
        case .ping: return "ping"
        case .pong: return "pong"
        case .saving: return "saving"
        case .screenLocked: return "screenLocked"
        case .unlock: return "unlock"
        case .focusRegion: return "focusRegion"
        case .covered: return "covered"
        case .setView: return "setView"
        case .dismissCover: return "dismissCover"
        case .appOpened: return "appOpened"
        case .secureFocus: return "secureFocus"
        case .changed: return "changed"
        case .stateRules: return "stateRules"
        case .appState: return "appState"
        }
    }

    /// Every case name `caseName` can return, so a case without a sample is caught.
    private static let allCaseNames: [String] = [
        "hello", "ready", "error", "frame", "text", "key", "mouse", "scroll", "resize", "setStream",
        "windows", "focus", "close", "move", "menuBar", "menuPick", "clip", "paste", "pasted", "fetch",
        "put", "transferStart", "chunk", "inputBlocked", "frameAck", "weak", "inputSource", "selectInput",
        "ping", "pong", "saving", "screenLocked", "unlock", "focusRegion", "covered", "setView",
        "dismissCover", "appOpened", "secureFocus", "changed", "stateRules", "appState",
    ]

    private static func errorText(_ error: Error) -> String {
        if let e = error as? CodecError { return e.message }
        if let e = error as? ProtocolVersionMismatch { return e.description }
        return "\(error)"
    }

    /// Feeds `bytes` to one parser: the first error text, or every message re-encoded.
    private static func outcome(_ bytes: [UInt8]) -> [String: Any] {
        var p = MessageParser()
        p.append(bytes)
        var again: [UInt8] = []
        do {
            while let m = try p.next() { again += m.encoded() }
        } catch {
            return ["error": errorText(error), "again": NSNull()]
        }
        return ["error": NSNull(), "again": HostFixture.hex(again)]
    }

    /// `type`, u32 LE length, body.
    private static func message(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type] + HostFixture.u32(UInt32(body.count)) + body
    }

    private static func string(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        return HostFixture.u16(UInt16(u.count)) + u
    }

    /// One window entry of a `windows` body.
    private static func windowEntry(id: UInt32, parent: UInt32 = 0, kind: UInt8 = 0, flags: UInt8 = 0,
                                    rect: (Float, Float, Float, Float) = (0, 0, 100, 50),
                                    titleBar: Float = 0, title: String = "") -> [UInt8] {
        HostFixture.u32(id) + HostFixture.u32(parent) + [kind, flags]
            + HostFixture.f32(rect.0) + HostFixture.f32(rect.1) + HostFixture.f32(rect.2) + HostFixture.f32(rect.3)
            + HostFixture.f32(titleBar) + string(title)
    }

    // MARK: - Tests

    func testEveryCaseHasASample() {
        let names = Set(Self.samples.map(Self.caseName))
        for name in Self.allCaseNames {
            XCTAssertTrue(names.contains(name), "no sample for \(name)")
        }
        XCTAssertEqual(names.count, Self.allCaseNames.count)
    }

    func testMessages() {
        var items: [(tag: UInt8, payload: [UInt8])] = []
        for m in Self.samples {
            let bytes = m.encoded()
            // Every sample round-trips through Swift's own parser first.
            var p = MessageParser()
            p.append(bytes)
            XCTAssertEqual(try p.next(), m, "\(Self.caseName(m)) does not round-trip")
            items.append((tag: bytes[0], payload: bytes))
        }
        HostFixture.check("protocol-messages.bin", HostFixture.records(items))
    }

    func testTypes() {
        var byType: [UInt8: String] = [:]
        for m in Self.samples { byType[m.encoded()[0]] = Self.caseName(m) }
        // The parser's own set: a type it does not know is rejected at the header.
        var known: Set<UInt8> = []
        for t in 0...255 {
            var p = MessageParser()
            p.append([UInt8(t), 0, 0, 0, 0])
            do {
                _ = try p.next()
                known.insert(UInt8(t))
            } catch {
                if Self.errorText(error) != "unknown message type \(t)" { known.insert(UInt8(t)) }
            }
        }
        XCTAssertEqual(known, Set(byType.keys), "the samples do not cover exactly the parser's types")
        let out: [[String: Any]] = byType.keys.sorted().map { ["type": Int($0), "case": byType[$0]!] }
        HostFixture.check("protocol-types.json", HostFixture.cases([["name": "types", "in": NSNull(), "out": out]]))
    }

    func testRejects() {
        var cases: [[String: Any]] = []
        func add(_ name: String, _ bytes: [UInt8]) {
            cases.append(["name": name, "in": HostFixture.hex(bytes), "out": Self.outcome(bytes)])
        }
        let v = protocolVersion
        add("unknown type 0", [0, 0, 0, 0, 0])
        add("unknown type 10", [10, 1, 0, 0, 0, 7])
        add("unknown type 12", [12, 0, 0, 0, 0])
        add("unknown type 45", [45, 0, 0, 0, 0])
        add("unknown type 255", [255, 0xFF, 0xFF, 0xFF, 0xFF])
        add("length maxMessageLength + 1", [4] + HostFixture.u32(UInt32(maxMessageLength + 1)))
        add("length 4 GiB - 1", [25, 0xFF, 0xFF, 0xFF, 0xFF])
        add("length maxMessageLength, body missing", [25] + HostFixture.u32(UInt32(maxMessageLength)))

        // Every client-to-host sample with its body cut by one byte (or, when empty, one byte added).
        let fromClient: Set<UInt8> = [1, 5, 6, 7, 8, 9, 11, 14, 15, 16, 20, 27, 30, 31, 35, 38, 41, 43]
        for (i, m) in Self.samples.enumerated() {
            let bytes = m.encoded()
            guard fromClient.contains(bytes[0]) else { continue }
            let body = Array(bytes[5...])
            if body.isEmpty {
                add("\(Self.caseName(m)) #\(i) plus one byte", Self.message(bytes[0], [0x7F]))
            } else {
                add("\(Self.caseName(m)) #\(i) cut by one byte", Self.message(bytes[0], Array(body.dropLast())))
            }
        }
        // A short body for the host-to-client and side types too: a session must not crash on them.
        for (i, m) in Self.samples.enumerated() {
            let bytes = m.encoded()
            guard !fromClient.contains(bytes[0]), bytes.count > 5 else { continue }
            add("\(Self.caseName(m)) #\(i) cut by one byte", Self.message(bytes[0], Array(bytes[5..<(bytes.count - 1)])))
        }
        // Extra bytes after a fixed-size message.
        add("ping plus one byte", Self.message(31, HostFixture.u32(1) + [0]))
        add("changed plus one byte", Self.message(42, [0]))

        // hello
        let helloTail = Self.string("t") + Self.string("b")
        add("hello version 15", Self.message(1, [15] + helloTail + [0, 30] + HostFixture.f32(1)))
        add("hello version 255", Self.message(1, [255] + helloTail + [0, 30] + HostFixture.f32(1)))
        add("hello unknown mode", Self.message(1, [v] + helloTail + [5, 30] + HostFixture.f32(1)))
        for fps: UInt8 in [0, 2, 10, 29, 31, 60, 255] {
            add("hello fps \(fps)", Self.message(1, [v] + helloTail + [0, fps] + HostFixture.f32(1)))
        }
        for (label, d) in [("0", Float(0)), ("-0", -Float(0)), ("8.5", Float(8.5)), ("-1", Float(-1)),
                           ("8.000001", Float(8).nextUp), ("1e30", Float(1e30))] {
            add("hello density \(label)", Self.message(1, [v] + helloTail + [0, 30] + HostFixture.f32(d)))
        }
        add("hello density NaN bits", Self.message(1, [v] + helloTail + [0, 30] + HostFixture.u32(0x7FC0_0000)))
        add("hello density inf bits", Self.message(1, [v] + helloTail + [0, 30] + HostFixture.u32(0x7F80_0000)))
        add("hello token not UTF-8", Self.message(1, [v, 1, 0, 0xFF] + Self.string("b") + [0, 30] + HostFixture.f32(1)))

        // setStream
        for fps: UInt8 in [2, 60, 255] {
            add("setStream fps \(fps)", Self.message(11, [0, fps] + HostFixture.f32(1) + [0]))
        }
        add("setStream density 0", Self.message(11, [0, 0] + HostFixture.f32(0) + [0]))
        add("setStream density 8.5", Self.message(11, [0, 5] + HostFixture.f32(8.5) + [0]))
        add("setStream flags 4", Self.message(11, [0, 5] + HostFixture.f32(1) + [4]))
        add("setStream unknown mode", Self.message(11, [9, 5] + HostFixture.f32(1) + [0]))

        // key, mouse, scroll
        add("key state 2", Self.message(6, HostFixture.u16(1) + HostFixture.u64(0) + [2]))
        add("mouse kind 4", Self.message(7, [4, 0] + HostFixture.u32(1) + HostFixture.f32(0) + HostFixture.f32(0) + [1]))
        add("mouse button 2", Self.message(7, [0, 2] + HostFixture.u32(1) + HostFixture.f32(0) + HostFixture.f32(0) + [1]))
        add("mouse x NaN", Self.message(7, [0, 0] + HostFixture.u32(1) + HostFixture.u32(0x7FC0_0000) + HostFixture.f32(0) + [1]))
        add("scroll dy -inf", Self.message(8, HostFixture.u32(1) + HostFixture.f32(0) + HostFixture.f32(0)
            + HostFixture.f32(0) + HostFixture.u32(0xFF80_0000)))
        add("setView w inf", Self.message(41, HostFixture.u32(1) + HostFixture.f32(0) + HostFixture.f32(0)
            + HostFixture.u32(0x7F80_0000) + HostFixture.f32(1)))

        // text, rules
        add("text not UTF-8", Self.message(5, [0x61, 0xC3]))
        add("text with a BOM", Self.message(5, [0xEF, 0xBB, 0xBF, 0x61]))
        add("text only a BOM", Self.message(5, [0xEF, 0xBB, 0xBF]))
        add("text with NUL", Self.message(5, [0x61, 0x00, 0x62]))
        add("text surrogate bytes", Self.message(5, [0xED, 0xA0, 0x80]))
        add("text overlong", Self.message(5, [0xC0, 0xAF]))
        add("rules stateRulesLimit + 1", Self.message(43, [UInt8](repeating: 0x72, count: stateRulesLimit + 1)))
        add("rules not UTF-8", Self.message(43, [0x7B, 0xFF]))
        add("rules with a BOM", Self.message(43, [0xEF, 0xBB, 0xBF, 0x7B, 0x7D]))
        add("state appStateLimit + 1", Self.message(44, [UInt8](repeating: 0x73, count: appStateLimit + 1)))
        add("state not UTF-8", Self.message(44, [0xFE]))

        // unlock
        add("password of 1025 bytes", Self.message(35, Self.string(String(repeating: "A", count: unlockPasswordLimit + 1))))
        add("password of 1024 bytes in 2-byte characters plus one", Self.message(35, Self.string(String(repeating: "é", count: 512) + "A")))
        add("password string longer than body", Self.message(35, HostFixture.u16(10) + [0x41]))

        // windows
        let t200 = Self.title200
        add("title of 200 graphemes", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, title: t200)))
        add("title of 201 graphemes", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, title: t200 + "a")))
        add("title of 201 combining marks on one base",
            Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, title: "a" + String(repeating: "\u{301}", count: 300))))
        add("257 windows", Self.message(13, HostFixture.u16(257)))
        add("window id 0", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 0)))
        add("window kind 7", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, kind: 7)))
        add("window flags 4", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, flags: 4)))
        add("window width 0", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, rect: (0, 0, 0, 10))))
        add("window height -1", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, rect: (0, 0, 10, -1))))
        add("title bar = height", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, rect: (0, 0, 10, 20), titleBar: 20)))
        add("title bar -0.5", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, titleBar: -0.5)))
        add("duplicate window id", Self.message(13, HostFixture.u16(2) + Self.windowEntry(id: 1) + Self.windowEntry(id: 1)))
        add("parent not in table", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, parent: 9)))
        add("parent is itself", Self.message(13, HostFixture.u16(1) + Self.windowEntry(id: 1, parent: 1)))
        add("parent after child", Self.message(13, HostFixture.u16(2) + Self.windowEntry(id: 2, parent: 1) + Self.windowEntry(id: 1)))

        // menus
        func item(_ children: [UInt8] = HostFixture.u16(0), flags: UInt8 = 1, modifiers: UInt8 = 0) -> [UInt8] {
            Self.string("m") + [flags] + Self.string("") + [modifiers] + children
        }
        var deep = HostFixture.u16(0)
        for _ in 0..<6 { deep = HostFixture.u16(1) + item(deep) }
        add("menu 6 levels", Self.message(17, deep))
        add("menu 7 levels", Self.message(17, HostFixture.u16(1) + item(deep)))
        add("menu flags 8", Self.message(17, HostFixture.u16(1) + item(flags: 8)))
        add("menu modifiers 16", Self.message(17, HostFixture.u16(1) + item(modifiers: 16)))
        add("menu 5001 items", Self.message(17, HostFixture.u16(5001)))
        add("menuPick empty", Self.message(18, [0]))
        add("menuPick 9 levels", Self.message(18, [9] + [UInt8](repeating: 0, count: 18)))

        // clip, paste, side
        add("clip kind 5", Self.message(19, HostFixture.u32(1) + [5]))
        add("clip text flag 2", Self.message(19, HostFixture.u32(1) + [0, 2] + HostFixture.u32(0)))
        add("clip text too long", Self.message(19, HostFixture.u32(1) + [0, 0] + HostFixture.u32(UInt32(maxClipText + 1))))
        add("clip 101 files", Self.message(19, HostFixture.u32(1) + [2] + HostFixture.u16(101)))
        add("paste source 2", Self.message(20, HostFixture.u32(1) + [2]))
        add("paste text of inlinePasteLimit bytes",
            Self.message(20, HostFixture.u32(1) + [0] + Self.string(String(repeating: "p", count: inlinePasteLimit))))
        add("fetch version 15", Self.message(22, [15] + Self.string("t") + HostFixture.u32(0) + HostFixture.u16(0) + HostFixture.u64(0)))
        add("put kind unsupported", Self.message(23, [v] + Self.string("t") + HostFixture.u32(0) + [4]))
        add("put kind 9", Self.message(23, [v] + Self.string("t") + HostFixture.u32(0) + [9]))
        add("chunk too large", Self.message(25, [UInt8](repeating: 0, count: chunkSize + 1)))

        // flags of host-to-client messages
        add("weak 2", Self.message(28, [2]))
        add("screenLocked 2", Self.message(34, [2]))
        add("secureFocus 2", Self.message(40, [2]))
        add("inputSource ascii 2", Self.message(29, Self.string("") + Self.string("") + [2]))
        add("saving 3", Self.message(33, [3]))
        add("covered dismissable 2", Self.message(37, HostFixture.u32(1) + Self.string("") + Self.string("") + [2]))
        add("focusRegion 4 rects", Self.message(36, HostFixture.u32(1) + [4] + [UInt8](repeating: 0, count: 64)))
        add("frame unknown mode", Self.message(4, [5] + [UInt8](repeating: 0, count: 21)))

        // A good message, then a bad one: the first is returned before the error.
        add("ping then unknown", Message.ping(3).encoded() + [0, 0, 0, 0, 0])
        add("two good messages", Message.ping(3).encoded() + Message.changed.encoded())

        HostFixture.check("protocol-rejects.json", HostFixture.cases(cases))
    }
}
