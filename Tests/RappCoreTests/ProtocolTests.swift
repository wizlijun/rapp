import XCTest
@testable import RappCore

final class ProtocolTests: XCTestCase {
    private let all: [Message] = [
        .hello(token: "口令abc", bundleID: "com.apple.TextEdit", mode: .color8, fps: 15, density: 2),
        .hello(token: "t", bundleID: "b", mode: .duogray, fps: 5, density: 0.375),
        .ready(appName: "文本编辑 😀", width: 1920, height: 1080),
        .error("bad token"),
        .frame(region: CanvasRect(x: 208, y: 72, w: 616, h: 512), FramePayload(width: 130, height: 70, isFull: true, data: [1, 2, 3, 250])),
        .frame(region: CanvasRect(x: 0, y: 0, w: 1, h: 1), FramePayload(width: 1, height: 1, isFull: false, data: [])),
        .text("你好😀"),
        .key(keyCode: 36, modifiers: 0x100108, down: true),
        .mouse(kind: .drag, button: .right, window: 3931, x: 25.5, y: -3, clickCount: 2),
        .mouse(kind: .move, button: .left, window: 1, x: 0, y: 0, clickCount: 0),
        .scroll(window: 0xFFFF_FFFF, x: 10, y: 20.5, dx: -3.5, dy: 12),
        .resize(window: 3931, width: 1024, height: 768),
        .windows([]),
        .windows([
            WindowInfo(id: 3931, parent: 0, kind: .normal, resizable: true, focused: true,
                       rect: CanvasRect(x: 213, y: 77, w: 603, h: 505), titleBar: 32, title: "未命名 — 已编辑"),
            WindowInfo(id: 3935, parent: 3931, kind: .menu, resizable: false, focused: false,
                       rect: CanvasRect(x: 219, y: 171, w: 220, h: 342), titleBar: 0, title: ""),
        ]),
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
                MenuItem(title: "字体", children: [MenuItem(title: "粗体", checked: true, key: "B", modifiers: 8)]),
            ]),
        ]),
        .menuPick([0]),
        .menuPick([1, 0, 0, 2, 3, 4, 5, 65535]),
        .setStream(mode: .color16, fps: 15, density: 1, pinned: false),
        .setStream(mode: .duocolor, fps: 5, density: 1.25, pinned: false),
        .setStream(mode: .duogray, fps: 1, density: 2, pinned: false),
        .setStream(mode: .color16, fps: 30, density: 2, pinned: false),
        .hello(token: "t", bundleID: "b", mode: .duogray, fps: 1, density: 1),
        .frame(region: CanvasRect(x: 0.5, y: 8, w: 64, h: 64), FramePayload(mode: .color16, width: 130, height: 70, isFull: true, data: [1, 2, 3, 250])),
        .clip(id: 1, .text("你好😀", truncated: false)),
        .clip(id: 0xFFFF_FFFF, .text("", truncated: true)),
        .clip(id: 2, .image(width: 1280, height: 720, bytes: 348_160)),
        .clip(id: 3, .files([ClipFile(name: "app.log", bytes: 2_411_724), ClipFile(name: "空 文件", bytes: 0)])),
        .clip(id: 4, .data(uti: "com.adobe.pdf", bytes: 81_920)),
        .clip(id: 5, .unsupported("文件夹（不支持）")),
        .paste(seq: 1, .text("贴😀")),
        .paste(seq: 2, .item(7)),
        .pasted(seq: 2, error: ""),
        .pasted(seq: 3, error: "target not frontmost"),
        .fetch(token: "t", clip: 9, file: 99, offset: 1 << 40),
        .put(token: "t", item: 3, kind: .files, uti: "public.data", name: "app.log", total: 5),
        .transferStart(0),
        .chunk([]),
        .inputBlocked(by: "Mac mini"),
        .frameAck(processingMs: 0),
        .frameAck(processingMs: 65535),
        .weak(true),
        .weak(false),
        .setStream(mode: .duogray, fps: 1, density: 2, pinned: true),
        .inputSource(id: "com.apple.inputmethod.SCIM.ITABC", name: "简体拼音", ascii: false),
        .inputSource(id: "com.apple.keylayout.ABC", name: "ABC", ascii: true),
        .selectInput(id: ""),
        .selectInput(id: "com.apple.keylayout.US"),
        .hello(token: "t", bundleID: "b", mode: .gray4, fps: 15, density: 1, version: 9),
        .chunk([UInt8](repeating: 7, count: chunkSize)),
    ]

    private func decodeOne(_ bytes: [UInt8]) throws -> Message? {
        var p = MessageParser()
        p.append(bytes)
        return try p.next()
    }

    func testInputBlockedRoundTrips() throws {
        let m = Message.inputBlocked(by: "Mac mini")
        XCTAssertEqual(try decodeOne(m.encoded()), m)
    }

    func testInputSourceWireFormat() throws {
        XCTAssertEqual(Message.inputSource(id: "a", name: "B", ascii: true).encoded(), [29, 7, 0, 0, 0, 1, 0, 0x61, 1, 0, 0x42, 1])
        XCTAssertEqual(Message.selectInput(id: "").encoded(), [30, 2, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try decodeOne([29, 7, 0, 0, 0, 1, 0, 0x61, 1, 0, 0x42, 2])) {
            XCTAssertEqual("\($0)", "bad ascii flag")
        }
        XCTAssertThrowsError(try decodeOne([30, 3, 0, 0, 0, 0, 0, 9]))
    }

    func testOldClientGetsVersionError() {
        // A protocol-2 hello: version 2, token "a", bundle "b", gray4, scale 2 (strings are u16 LE length + UTF-8).
        var p = MessageParser()
        let payload: [UInt8] = [2, 1, 0, 0x61, 1, 0, 0x62, 0, 2]
        p.append([1, UInt8(payload.count), 0, 0, 0] + payload)
        XCTAssertThrowsError(try p.next()) { error in
            XCTAssertEqual((error as? ProtocolVersionMismatch)?.client, 2)
            XCTAssertEqual("\(error)", "protocol version mismatch: host 9, client 2 (update both sides)")
        }
    }

    func testHelloAcceptsOnlyVersion9() throws {
        let m = Message.hello(token: "t", bundleID: "b", mode: .gray4, fps: 15, density: 1, version: 9)
        XCTAssertEqual(try decodeOne(m.encoded()), m)
        for v: UInt8 in [8, 10] {
            var bytes = m.encoded()
            bytes[5] = v
            XCTAssertThrowsError(try decodeOne(bytes)) { XCTAssertEqual(($0 as? ProtocolVersionMismatch)?.client, v) }
        }
        var old = m.encoded()
        old[5] = 4
        XCTAssertThrowsError(try decodeOne(old)) {
            XCTAssertEqual("\($0)", "protocol version mismatch: host 9, client 4 (update both sides)")
        }
    }

    func testFetchAndPutAcceptOnlyVersion9() throws {
        let f = Message.fetch(token: "t", clip: 1, file: 2, offset: 3).encoded()
        let q = Message.put(token: "t", item: 1, kind: .files, uti: "u", name: "n", total: 5).encoded()
        XCTAssertEqual(f[5], 9)
        XCTAssertEqual(q[5], 9)
        XCTAssertEqual(try decodeOne(f), .fetch(token: "t", clip: 1, file: 2, offset: 3))
        XCTAssertEqual(try decodeOne(q), .put(token: "t", item: 1, kind: .files, uti: "u", name: "n", total: 5))
        for v: UInt8 in [8, 10] {
            for var bytes in [f, q] {
                bytes[5] = v
                XCTAssertThrowsError(try decodeOne(bytes)) { XCTAssertEqual(($0 as? ProtocolVersionMismatch)?.client, v) }
            }
        }
    }

    func testV3HelloIsVersionMismatch() {
        var bytes = Message.hello(token: "a", bundleID: "b", mode: .gray4, fps: 15, density: 1).encoded()
        bytes[5] = 3
        var p = MessageParser()
        p.append(bytes)
        XCTAssertThrowsError(try p.next()) { error in
            XCTAssertEqual((error as? ProtocolVersionMismatch)?.client, 3)
        }
    }

    func testTypes10And12AreUnknown() {
        assertRejects(frame(10, [1, 0, 0x61]), "v3 title")
        assertRejects(frame(12, [1, 0, 2, 0]), "v3 size")
    }

    /// A SetStream payload: mode, fps, density (f32 LE).
    private func setStream(mode: UInt8 = 0, fps: UInt8 = 15, density: Float) -> [UInt8] {
        let d = density.bitPattern
        return [11, 6, 0, 0, 0, mode, fps, UInt8(d & 0xFF), UInt8(d >> 8 & 0xFF), UInt8(d >> 16 & 0xFF), UInt8(d >> 24)]
    }

    func testV6SetStreamWithoutPinnedDecodesUnpinned() throws {
        var bytes = setStream(mode: 3, fps: 5, density: 1.25)
        let withPinned = bytes + [1]
        XCTAssertEqual(try decodeOne(bytes), .setStream(mode: .duogray, fps: 5, density: 1.25, pinned: false))
        bytes = withPinned
        bytes[1] = 7
        XCTAssertEqual(try decodeOne(bytes), .setStream(mode: .duogray, fps: 5, density: 1.25, pinned: true))
    }

    func testSetStreamWithTwoTrailingBytesIsRejected() {
        var bytes = setStream(density: 1) + [0, 0]
        bytes[1] = 8
        assertRejects(bytes, "two trailing bytes")
        var bad = setStream(density: 1) + [2]
        bad[1] = 7
        assertRejects(bad, "pinned flag above 1")
    }

    func testFrameAckAndWeakWireFormat() throws {
        XCTAssertEqual(Message.frameAck(processingMs: 0x0102).encoded(), [27, 2, 0, 0, 0, 0x02, 0x01])
        XCTAssertEqual(Message.weak(true).encoded(), [28, 1, 0, 0, 0, 1])
        assertRejects(frame(27, [1]), "short ack")
        assertRejects(frame(27, [1, 0, 0]), "long ack")
        assertRejects(frame(28, [2]), "weak flag above 1")
        assertRejects(frame(28, []), "empty weak")
    }

    func testSetStreamRejectsBadFpsAndDensity() {
        for bytes in [setStream(fps: 3, density: 1), setStream(fps: 0, density: 1), setStream(density: 0),
                      setStream(density: -1), setStream(density: 9), setStream(density: .nan),
                      setStream(density: .infinity), setStream(mode: 5, density: 1)] {
            var p = MessageParser()
            p.append(bytes)
            XCTAssertThrowsError(try p.next(), "\(bytes)")
        }
        var p = MessageParser()
        p.append(setStream(fps: 5, density: 8))
        XCTAssertEqual(try p.next(), .setStream(mode: .gray4, fps: 5, density: 8, pinned: false))
    }

    func testHelloRejectsBadFpsAndDensity() {
        for (fps, density) in [(UInt8(7), Float(1)), (15, 0), (15, 8.5), (15, .nan)] {
            var bytes = Message.hello(token: "a", bundleID: "b", mode: .gray4, fps: 15, density: 1).encoded()
            let d = density.bitPattern
            bytes[bytes.count - 5] = fps
            for i in 0..<4 { bytes[bytes.count - 4 + i] = UInt8(d >> (8 * UInt32(i)) & 0xFF) }
            var p = MessageParser()
            p.append(bytes)
            XCTAssertThrowsError(try p.next(), "fps \(fps), density \(density)")
        }
    }

    func testFrameLayout() {
        let f = Message.frame(region: CanvasRect(x: 1, y: 2, w: 3, h: 4), FramePayload(width: 0x0102, height: 0x0304, isFull: true, data: [9]))
        let one: [UInt8] = [0, 0, 0x80, 0x3F], two: [UInt8] = [0, 0, 0, 0x40], three: [UInt8] = [0, 0, 0x40, 0x40], four: [UInt8] = [0, 0, 0x80, 0x40]
        XCTAssertEqual(f.encoded(), [4, 23, 0, 0, 0, 0] + one + two + three + four + [0x02, 0x01, 0x04, 0x03, 1, 9])
    }

    func testMouseLayout() {
        let m = Message.mouse(kind: .move, button: .left, window: 0x0A0B0C0D, x: 1, y: 2, clickCount: 0)
        XCTAssertEqual(m.encoded(), [7, 15, 0, 0, 0, 3, 0, 0x0D, 0x0C, 0x0B, 0x0A, 0, 0, 0x80, 0x3F, 0, 0, 0, 0x40, 0])
    }

    // MARK: windows

    private func window(_ id: UInt32, parent: UInt32 = 0, kind: WindowKind = .normal, w: Float = 100, h: Float = 80,
                        titleBar: Float = 0, title: String = "") -> WindowInfo {
        WindowInfo(id: id, parent: parent, kind: kind, resizable: false, focused: false,
                   rect: CanvasRect(x: 0, y: 0, w: w, h: h), titleBar: titleBar, title: title)
    }

    /// Encodes with the real encoder, then lets `patch` corrupt the payload.
    private func windowsBytes(_ items: [WindowInfo], patch: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        var bytes = Message.windows(items).encoded()
        var payload = Array(bytes[5...])
        patch(&payload)
        bytes = frame(13, payload)
        return bytes
    }

    func testWindowsRejectsDuplicateIDs() {
        assertRejects(windowsBytes([window(1), window(1)]), "duplicate id")
    }

    func testWindowsRejectsUnknownParent() {
        assertRejects(windowsBytes([window(1), window(2, parent: 9, kind: .menu)]), "parent not in table")
        assertRejects(windowsBytes([window(0)]), "id 0")
    }

    func testWindowsRejectsMoreThan256() {
        let many = (1...257).map { window(UInt32($0)) }
        assertRejects(windowsBytes(many), "257 windows")
        var p = MessageParser()
        p.append(Message.windows(Array(many.prefix(256))).encoded())
        XCTAssertNotNil(try p.next())
    }

    func testWindowsRejectsExtraFlagBits() {
        // count u16, id u32, parent u32, kind u8, flags u8 -> flags at offset 11.
        assertRejects(windowsBytes([window(1)]) { $0[11] = 4 }, "flag bit 2")
    }

    func testWindowsRejectsUnknownKind() {
        assertRejects(windowsBytes([window(1)]) { $0[10] = 7 }, "kind 7")
    }

    func testWindowsRejectsNonPositiveSize() {
        assertRejects(windowsBytes([window(1, w: 0)]), "zero width")
        assertRejects(windowsBytes([window(1, h: -5)]), "negative height")
    }

    func testWindowsRejectsTitleBarNotBelowHeight() {
        assertRejects(windowsBytes([window(1, h: 30, titleBar: 30)]), "titleBar == h")
        assertRejects(windowsBytes([window(1, titleBar: -1)]), "negative titleBar")
        var p = MessageParser()
        p.append(Message.windows([window(1, h: 30, titleBar: 29.5)]).encoded())
        XCTAssertNotNil(try p.next())
    }

    func testWindowsRejectsLongTitle() {
        assertRejects(windowsBytes([window(1, title: String(repeating: "字", count: 201))]), "201 characters")
        var p = MessageParser()
        p.append(Message.windows([window(1, title: String(repeating: "字", count: 200))]).encoded())
        XCTAssertNotNil(try p.next())
    }

    // MARK: menu bar

    private func nested(_ depth: Int) -> MenuItem {
        depth == 1 ? MenuItem(title: "leaf") : MenuItem(title: "\(depth)", children: [nested(depth - 1)])
    }

    func testMenuBarRejectsDepth7() {
        assertRejects(Message.menuBar([nested(7)]).encoded(), "7 levels")
        var p = MessageParser()
        p.append(Message.menuBar([nested(6)]).encoded())
        XCTAssertEqual(try p.next(), .menuBar([nested(6)]))
    }

    func testMenuBarRejectsMoreThan5000Items() {
        let big = MenuItem(title: "m", children: Array(repeating: MenuItem(title: "x"), count: 4999))
        var p = MessageParser()
        p.append(Message.menuBar([big]).encoded())
        XCTAssertNotNil(try p.next(), "5000 items")
        assertRejects(Message.menuBar([big, MenuItem(title: "y")]).encoded(), "5001 items")
    }

    func testMenuBarRejectsExtraFlagBits() {
        // count u16, title (u16 len + 1 byte), flags u8 at offset 5; key (u16 0), modifiers at offset 8.
        let one = Array(Message.menuBar([MenuItem(title: "a")]).encoded()[5...])
        var badFlags = one; badFlags[5] = 8
        assertRejects(frame(17, badFlags), "flag bit 3")
        var badMods = one; badMods[8] = 16
        assertRejects(frame(17, badMods), "modifier bit 4")
    }

    func testMenuPickRejectsEmptyAndNineLevels() {
        assertRejects(frame(18, [0]), "empty path")
        assertRejects(frame(18, [9] + Array(repeating: 0, count: 18)), "9 levels")
        assertRejects(frame(18, [2, 0, 0]), "truncated path")
    }

    func testEveryMessageRoundTrips() throws {
        for m in all {
            var parser = MessageParser()
            parser.append(m.encoded())
            XCTAssertEqual(try parser.next(), m)
            XCTAssertNil(try parser.next())
        }
    }

    func testHeaderLayout() {
        let bytes = Message.resize(window: 0x01020304, width: 0x0102, height: 0x0304).encoded()
        XCTAssertEqual(bytes, [9, 8, 0, 0, 0, 0x04, 0x03, 0x02, 0x01, 0x02, 0x01, 0x04, 0x03])
    }

    func testParserHandlesSplitAndCoalescedInput() throws {
        let bytes = all[0].encoded() + all[5].encoded()
        for cut in 0...bytes.count {
            var parser = MessageParser()
            parser.append(Array(bytes[0..<cut]))
            var got = [Message]()
            while let m = try parser.next() { got.append(m) }
            parser.append(Array(bytes[cut...]))
            while let m = try parser.next() { got.append(m) }
            XCTAssertEqual(got, [all[0], all[5]], "cut at \(cut)")
            XCTAssertNil(try parser.next())
        }
    }

    private func assertRejects(_ bytes: [UInt8], _ what: String, line: UInt = #line) {
        var parser = MessageParser()
        parser.append(bytes)
        XCTAssertThrowsError(try parser.next(), what, line: line)
    }

    private func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = UInt32(payload.count)
        return [type, UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)] + payload
    }

    func testParserRejectsBadInput() {
        assertRejects(frame(99, []), "unknown type")
        let tooLong = UInt32(maxMessageLength + 1)
        assertRejects([5, UInt8(tooLong & 0xFF), UInt8(tooLong >> 8 & 0xFF), UInt8(tooLong >> 16 & 0xFF), UInt8(tooLong >> 24)],
                      "oversized length")
        assertRejects(frame(1, [2, 200, 0, 0x61]), "string longer than payload")
        assertRejects(frame(1, [3, 1, 0, 0x61, 1, 0, 0x62, 0, 2]), "wrong protocol version")
        assertRejects(frame(1, [2, 1, 0, 0x61, 1, 0, 0x62, 7, 2]), "unknown mode")
        assertRejects(frame(4, [0, 1, 0, 1]), "frame payload too short")
        assertRejects(frame(4, [9, 1, 0, 1, 0, 0]), "unknown frame mode")
        assertRejects(frame(5, [0xFF, 0xFE]), "text is not UTF-8")
        assertRejects(frame(9, [1, 0, 0, 0, 1, 0, 2, 0, 3]), "trailing bytes")
        assertRejects(frame(7, [9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]), "unknown mouse kind")
        assertRejects(frame(8, [1, 0, 0, 0, 0, 0, 0xC0, 0x7F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), "NaN coordinate")
        assertRejects(frame(16, [1, 0, 0, 0, 0, 0, 0x80, 0x7F, 0, 0, 0, 0]), "infinite move")
    }

    func testHelloOfVersion4IsAMismatch() {
        // version 4, token "a", bundle "b", gray4, fps 15, density 1.0
        let payload: [UInt8] = [4, 1, 0, 0x61, 1, 0, 0x62, 0, 15, 0, 0, 0x80, 0x3F]
        var p = MessageParser()
        p.append(frame(1, payload))
        XCTAssertThrowsError(try p.next()) { error in
            XCTAssertEqual((error as? ProtocolVersionMismatch)?.client, 4)
        }
    }

    func testBadV5PayloadsAreRejected() {
        func u32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        let zero8 = [UInt8](repeating: 0, count: 8)
        let id = u32(1)
        assertRejects(frame(19, id + [5, 0, 0]), "clip kind 5")
        assertRejects(frame(19, id + [0, 0] + u32(maxClipText + 1) + [UInt8](repeating: 0x61, count: maxClipText + 1)), "clip text too long")
        assertRejects(frame(19, id + [0, 0] + u32(10) + [0x61]), "clip text shorter than its length")
        assertRejects(frame(19, id + [2] + u16(maxClipFiles + 1) + (0...maxClipFiles).flatMap { _ in u16(0) + zero8 }), "101 files")
        assertRejects(frame(19, id + [0, 2] + u32(0)), "truncated flag 2")
        assertRejects(frame(23, [5] + u16(1) + [0x74] + u32(1) + [4] + u16(0) + u16(0) + zero8), "put kind unsupported")
        assertRejects(frame(20, id + [2] + u16(0)), "paste source 2")
        assertRejects(frame(20, id + [0] + u16(inlinePasteLimit) + [UInt8](repeating: 0x61, count: inlinePasteLimit)), "paste text 60000 bytes")
        assertRejects(frame(25, [UInt8](repeating: 0, count: chunkSize + 1)), "chunk too large")
        assertRejects(frame(21, id + u16(0) + [0]), "pasted trailing byte")
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(constantTimeEquals("abc", "abc"))
        XCTAssertFalse(constantTimeEquals("abc", "abd"))
        XCTAssertFalse(constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(constantTimeEquals("", "a"))
        XCTAssertTrue(constantTimeEquals("口令", "口令"))
    }

    func testCodecErrorPrintsItsMessage() {
        XCTAssertEqual("\(CodecError("bad token"))", "bad token")
    }

    func testAddressDefaults() throws {
        let a = try RemoteAddress(url: "rapp://mac-a.local/com.apple.TextEdit?token=abc")
        XCTAssertEqual(a, RemoteAddress(host: "mac-a.local", port: 47800, bundleID: "com.apple.TextEdit",
                                        token: "abc", mode: .gray4, fps: 15))
    }

    func testAddressFull() throws {
        let a = try RemoteAddress(url: "rapp://10.0.0.5:5000/com.x.Y?token=t&mode=color16&fps=5")
        XCTAssertEqual(a, RemoteAddress(host: "10.0.0.5", port: 5000, bundleID: "com.x.Y",
                                        token: "t", mode: .color16, fps: 5))
    }

    func testAddressAcceptsOneAndThirtyFps() throws {
        XCTAssertEqual(try RemoteAddress(url: "rapp://h/b?token=t&fps=1").fps, 1)
        XCTAssertEqual(try RemoteAddress(url: "rapp://h/b?token=t&fps=30").fps, 30)
    }

    func testAddressTwoToneModesAndIgnoredScale() throws {
        XCTAssertEqual(try RemoteAddress(url: "rapp://h/b?token=t&mode=duogray").mode, .duogray)
        XCTAssertEqual(try RemoteAddress(url: "rapp://h/b?token=t&mode=duocolor").mode, .duocolor)
        // Revision 1 addresses with scale still work; the parameter is ignored.
        let old = try RemoteAddress(url: "rapp://h/b?token=t&mode=color16&scale=2")
        XCTAssertEqual(old, RemoteAddress(host: "h", port: 47800, bundleID: "b", token: "t", mode: .color16, fps: 15))
        XCTAssertNoThrow(try RemoteAddress(url: "rapp://h/b?token=t&scale=3"))
    }

    func testAddressErrors() {
        for bad in ["http://mac-a.local/com.apple.TextEdit?token=abc",
                    "rapp://mac-a.local/com.apple.TextEdit",
                    "rapp://mac-a.local/com.apple.TextEdit?token=",
                    "rapp://mac-a.local/a/b?token=abc",
                    "rapp:///com.apple.TextEdit?token=abc",
                    "rapp://mac-a.local/com.apple.TextEdit?token=abc&fps=7",
                    "rapp://mac-a.local/com.apple.TextEdit?token=abc&fps=",
                    "rapp://mac-a.local/com.apple.TextEdit?token=abc&mode=foo",
                    "rapp://mac-a.local:99999/com.apple.TextEdit?token=abc",
                    "not a url"] {
            XCTAssertThrowsError(try RemoteAddress(url: bad), bad)
        }
    }

    func testWindowTitleRule() {
        XCTAssertEqual(windowTitle("", appName: "Calculator"), "Calculator")
        XCTAssertEqual(windowTitle(nil, appName: nil), "rapp")
        XCTAssertEqual(windowTitle("Untitled 2", appName: "TextEdit"), "Untitled 2")
        XCTAssertEqual(windowTitle(String(repeating: "字", count: 300), appName: "x").count, 200)
    }

    func testFormatRateUsesKilobytesAndMegabytes() {
        XCTAssertEqual(formatRate(bytes: 0), "0 KB/s")
        XCTAssertEqual(formatRate(bytes: 512), "0.5 KB/s")
        XCTAssertEqual(formatRate(bytes: 6538), "6.4 KB/s")
        XCTAssertEqual(formatRate(bytes: 999 * 1024), "999.0 KB/s")
        XCTAssertEqual(formatRate(bytes: 1000 * 1024), "1.0 MB/s")
        XCTAssertEqual(formatRate(bytes: 1024 * 1024), "1.0 MB/s")
        XCTAssertEqual(formatRate(bytes: 2_400_000), "2.3 MB/s")
    }
}
