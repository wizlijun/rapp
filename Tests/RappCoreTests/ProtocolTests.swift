import XCTest
@testable import RappCore

final class ProtocolTests: XCTestCase {
    private let all: [Message] = [
        .hello(token: "口令abc", bundleID: "com.apple.TextEdit", mode: .color8, fps: 15, density: 2),
        .hello(token: "t", bundleID: "b", mode: .duogray, fps: 5, density: 0.375),
        .ready(title: "未命名 — 你好😀", width: 800, height: 600),
        .error("bad token"),
        .frame(FramePayload(width: 130, height: 70, isFull: true, data: [1, 2, 3, 250])),
        .frame(FramePayload(width: 1, height: 1, isFull: false, data: [])),
        .text("你好😀"),
        .key(keyCode: 36, modifiers: 0x100108, down: true),
        .mouse(kind: .drag, button: .right, x: 0.25, y: 0.75, clickCount: 2),
        .scroll(x: 0.5, y: 0.5, dx: -3.5, dy: 12),
        .resize(width: 1024, height: 768),
        .title("文档 2 — 已编辑"),
        .setStream(mode: .color16, fps: 15, density: 1),
        .setStream(mode: .duocolor, fps: 5, density: 1.25),
        .setStream(mode: .duogray, fps: 1, density: 2),
        .setStream(mode: .color16, fps: 30, density: 2),
        .hello(token: "t", bundleID: "b", mode: .duogray, fps: 1, density: 1),
        .size(width: 1200, height: 750),
        .frame(FramePayload(mode: .color16, width: 130, height: 70, isFull: true, data: [1, 2, 3, 250])),
    ]

    func testOldClientGetsVersionError() {
        // A protocol-2 hello: version 2, token "a", bundle "b", gray4, scale 2 (strings are u16 LE length + UTF-8).
        var p = MessageParser()
        let payload: [UInt8] = [2, 1, 0, 0x61, 1, 0, 0x62, 0, 2]
        p.append([1, UInt8(payload.count), 0, 0, 0] + payload)
        XCTAssertThrowsError(try p.next()) { error in
            XCTAssertEqual((error as? ProtocolVersionMismatch)?.client, 2)
            XCTAssertEqual("\(error)", "protocol version mismatch: host 3, client 2 (update both sides)")
        }
    }

    /// A SetStream payload: mode, fps, density (f32 LE).
    private func setStream(mode: UInt8 = 0, fps: UInt8 = 15, density: Float) -> [UInt8] {
        let d = density.bitPattern
        return [11, 6, 0, 0, 0, mode, fps, UInt8(d & 0xFF), UInt8(d >> 8 & 0xFF), UInt8(d >> 16 & 0xFF), UInt8(d >> 24)]
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
        XCTAssertEqual(try p.next(), .setStream(mode: .gray4, fps: 5, density: 8))
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

    func testSizeLayout() {
        XCTAssertEqual(Message.size(width: 0x0102, height: 0x0304).encoded(), [12, 4, 0, 0, 0, 0x02, 0x01, 0x04, 0x03])
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
        let bytes = Message.resize(width: 0x0102, height: 0x0304).encoded()
        XCTAssertEqual(bytes, [9, 4, 0, 0, 0, 0x02, 0x01, 0x04, 0x03])
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
        assertRejects(frame(9, [1, 0, 2, 0, 3]), "trailing bytes")
        assertRejects(frame(7, [9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]), "unknown mouse kind")
        assertRejects(frame(8, [0, 0, 0xC0, 0x7F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), "NaN coordinate")
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
