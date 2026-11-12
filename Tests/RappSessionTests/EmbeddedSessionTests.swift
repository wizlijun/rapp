import CoreGraphics
import XCTest
import RappCore
@testable import RappSession

final class EmbeddedSessionTests: XCTestCase {
    private var boards = [NSPasteboard]()
    /// The link only holds its session weakly.
    private var sessions = [EmbeddedSession]()

    override func tearDown() {
        boards.forEach { $0.releaseGlobally() }
        boards = []
        sessions = []
        super.tearDown()
    }

    private let region = CanvasRect(x: 0, y: 0, w: 64, h: 32)
    private let w = WindowInfo(id: 7, parent: 0, kind: .normal, resizable: true, focused: true,
                               rect: CanvasRect(x: 0, y: 0, w: 64, h: 32), titleBar: 0, title: "Calc")

    private func goodFrame() throws -> FramePayload {
        let enc = FrameEncoder(mode: .color16)
        return try XCTUnwrap(enc.encode(samples: [UInt8](repeating: 0x55, count: 64 * 32 * 2), width: 64, height: 32))
    }

    private func make(_ link: FakeLink, events: @escaping (SessionEvent) -> Void) -> (EmbeddedSession, DispatchQueue) {
        let board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        boards.append(board)
        let q = DispatchQueue(label: "test.session")
        let s = EmbeddedSession(address: RemoteAddress(host: "127.0.0.1", port: 1, bundleID: "x", token: "t", mode: .color16),
                                choice: .adaptive, backingScale: 2, link: link, pasteboard: LocalPasteboard(board: board), queue: q)
        s.onEvent = events
        sessions.append(s)
        s.start()
        q.sync {}
        return (s, q)
    }

    func testReadyWindowsAndFrameProduceEvents() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        let frame = try goodFrame()
        q.sync {
            link.feed(.ready(appName: "Calc", width: 64, height: 32))
            link.feed(.windows([w]))
            link.feed(.frame(region: region, frame))
        }
        XCTAssertEqual(events, [.ready(appName: "Calc"),
                                .windows([SessionWindow(info: w, visible: CGRect(x: 0, y: 0, width: 1, height: 1))]),
                                .surfaces([7])])
        XCTAssertNotNil(s.surfaces.latest(7))
        XCTAssertTrue(link.started)
    }

    func testBadFrameEndsOnlyThatSession() throws {
        let link1 = FakeLink(), link2 = FakeLink()
        var events1 = [SessionEvent](), events2 = [SessionEvent]()
        let (_, q1) = make(link1) { events1.append($0) }
        let (s2, q2) = make(link2) { events2.append($0) }
        let good = try goodFrame()
        var bad = good
        bad.data = Array(good.data.prefix(good.data.count / 2))
        q1.sync { link1.feed(.windows([w])); link1.feed(.frame(region: region, bad)) }
        q2.sync { link2.feed(.windows([w])); link2.feed(.frame(region: region, good)) }
        guard case let .closed(reason)? = events1.last else { return XCTFail("expected closed, got \(events1)") }
        XCTAssertTrue(reason.hasPrefix("cannot decode frame: "))
        XCTAssertTrue(link1.cancelled)
        XCTAssertEqual(events2.last, .surfaces([7]))
        XCTAssertNotNil(s2.surfaces.latest(7))
        XCTAssertFalse(link2.cancelled)
    }

    func testFrameLargerThanDecoderThrowsNotCrash() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (_, q) = make(link) { events.append($0) }
        let big = WindowInfo(id: 9, parent: 0, kind: .normal, resizable: true, focused: true,
                             rect: CanvasRect(x: 0, y: 0, w: 640, h: 320), titleBar: 0, title: "big")
        let frame = try goodFrame()
        // A window far outside the frame's region draws nothing, and does not crash.
        q.sync {
            link.feed(.windows([big]))
            link.feed(.frame(region: CanvasRect(x: 5000, y: 5000, w: 64, h: 32), frame))
        }
        XCTAssertFalse(link.cancelled)
        // A later frame whose size disagrees with the canvas it continues ends the session.
        var odd = frame
        odd.isFull = false
        odd.width = 128; odd.height = 64
        q.sync { link.feed(.frame(region: region, odd)) }
        guard case .closed? = events.last else { return XCTFail("expected closed, got \(events)") }
        XCTAssertTrue(link.cancelled)
    }

    func testCloseUnregistersSurfacesOnceAndReportsOnce() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        let frame = try goodFrame()
        q.sync { link.feed(.windows([w])); link.feed(.frame(region: region, frame)) }
        XCTAssertNotNil(s.surfaces.latest(7))
        s.close(); s.close()
        q.sync { link.drop("x") }
        XCTAssertEqual(events.filter { if case .closed = $0 { return true } else { return false } }, [.closed(reason: "quit")])
        XCTAssertNil(s.surfaces.latest(7))
    }

    func testHostErrorClosesWithReason() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (_, q) = make(link) { events.append($0) }
        q.sync { link.feed(.error("Calculator quit")) }
        XCTAssertEqual(events.last, .closed(reason: "host says: Calculator quit"))
    }

    func testSetStreamDedupes() {
        let link = FakeLink()
        let (s, q) = make(link) { _ in }
        func streams() -> [Message] { link.sent.filter { if case .setStream = $0 { return true } else { return false } } }
        s.setStream(mode: .color16, fps: 15, choice: .adaptive)
        s.setStream(mode: .color16, fps: 15, choice: .adaptive)
        q.sync {}
        XCTAssertEqual(streams().count, 1)
        s.setStream(mode: .color16, fps: 1, choice: .adaptive)
        q.sync {}
        XCTAssertEqual(streams().count, 2)
        guard case let .setStream(_, fps, _)? = streams().last else { return XCTFail() }
        XCTAssertEqual(fps, 1)
    }

    func testTrafficTicksAndResets() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        q.sync { link.onBytes?(1500); link.onBytes?(500) }
        s.tickTraffic(); s.tickTraffic()
        q.sync {}
        XCTAssertEqual(events, [.traffic(bytesPerSecond: 2000), .traffic(bytesPerSecond: 0)])
    }

    func testClipsAndMenuEvents() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (_, q) = make(link) { events.append($0) }
        q.sync {
            link.feed(.clip(id: 1, .text("hello", truncated: false)))
            link.feed(.clip(id: 2, .unsupported("odd")))
            link.feed(.menuBar([MenuItem(title: "File")]))
        }
        XCTAssertEqual(events.last, .menu([MenuItem(title: "File")]))
        XCTAssertEqual(events[1], .clips([ClipRow(id: 2, title: "odd", pickable: false),
                                          ClipRow(id: 1, title: "文字 · hello", pickable: true)]))
    }
}
