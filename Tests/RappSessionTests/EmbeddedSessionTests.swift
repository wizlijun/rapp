import AppKit
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
        hosts.forEach { $0.stop() }
        hosts = []
        if let d = downloadsDir { try? FileManager.default.removeItem(at: d) }
        super.tearDown()
    }

    private let region = CanvasRect(x: 0, y: 0, w: 64, h: 32)
    private let w = WindowInfo(id: 7, parent: 0, kind: .normal, resizable: true, focused: true,
                               rect: CanvasRect(x: 0, y: 0, w: 64, h: 32), titleBar: 0, title: "Calc")

    private func goodFrame() throws -> FramePayload {
        let enc = FrameEncoder(mode: .color16)
        return try XCTUnwrap(enc.encode(samples: [UInt8](repeating: 0x55, count: 64 * 32 * 2), width: 64, height: 32))
    }

    private var downloadsDir: URL?
    private var hosts = [FakeSideHost]()

    private func make(_ link: FakeLink, address: RemoteAddress? = nil, downloads: URL? = nil,
                      events: @escaping (SessionEvent) -> Void) -> (EmbeddedSession, DispatchQueue) {
        let board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        boards.append(board)
        let q = DispatchQueue(label: "test.session")
        let s = EmbeddedSession(address: address ?? RemoteAddress(host: "127.0.0.1", port: 1, bundleID: "x", token: "t", mode: .color16),
                                choice: .adaptive, backingScale: 2, link: link, pasteboard: LocalPasteboard(board: board), queue: q,
                                downloads: downloads)
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
        guard case let .disconnected(reason)? = events1.last else { return XCTFail("expected disconnected, got \(events1)") }
        XCTAssertTrue(reason.hasPrefix("cannot decode frame: "))
        XCTAssertFalse(events1.contains { if case .closed = $0 { return true } else { return false } })
        XCTAssertTrue(link1.cancelled)
        XCTAssertEqual(events2.last, .surfaces([7]))
        XCTAssertNotNil(s2.surfaces.latest(7))
        XCTAssertFalse(link2.cancelled)
    }

    func testInconsistentFrameClosesNotCrashes() throws {
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
        guard case let .disconnected(reason)? = events.last else { return XCTFail("expected disconnected, got \(events)") }
        XCTAssertTrue(reason.hasPrefix("cannot decode frame: "))
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

    func testHostErrorClosesWithReason() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        let frame = try goodFrame()
        q.sync { link.feed(.windows([w])); link.feed(.frame(region: region, frame)); link.feed(.error("Calculator quit")) }
        XCTAssertEqual(events.last, .disconnected(reason: "host says: Calculator quit"))
        XCTAssertNotNil(s.surfaces.latest(7))
    }

    func testInputBlockedBecomesAnEventAndKeepsTheLink() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (_, q) = make(link) { events.append($0) }
        q.sync { link.feed(.windows([w])); link.feed(.inputBlocked(by: "Mac mini")) }
        XCTAssertEqual(events.last, .inputBlocked(by: "Mac mini"))
        XCTAssertFalse(events.contains { if case .disconnected = $0 { return true }; return false })
    }

    func testTakenOverDisconnectsWithTheHostText() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (_, q) = make(link) { events.append($0) }
        q.sync { link.feed(.windows([w])); link.feed(.error("taken over by Mac mini")) }
        XCTAssertEqual(events.last, .disconnected(reason: "host says: taken over by Mac mini"))
    }

    func testMenuPickAndMoveToTopLeftSendMessages() {
        let link = FakeLink()
        let (s, q) = make(link) { _ in }
        q.sync { link.feed(.windows([w])) }
        s.menuPick([0, 2])
        s.moveToTopLeft(window: 7)
        q.sync {}
        XCTAssertTrue(link.sent.contains(.menuPick([0, 2])))
        XCTAssertEqual(Array(link.sent.suffix(2)), moveToTopLeftMessages(window: 7, table: [w]))
        // A window that is not in the table is left alone.
        let before = link.sent.count
        s.moveToTopLeft(window: 99)
        q.sync {}
        XCTAssertEqual(link.sent.count, before)
    }

    func testPickClipTextGoesToBsClipboardOrComposer() {
        let link = FakeLink()
        var statuses = [String]()
        let (s, q) = make(link) { if case let .transferStatus(t?) = $0 { statuses.append(t) } }
        var inserted = [String]()
        s.onInsert = { _, payload in if case let .text(t) = payload { inserted.append(t) } }
        q.sync { link.feed(.clip(id: 5, .text("hello", truncated: false))); link.feed(.clip(id: 6, .text("later", truncated: false))) }
        s.pickClip(5, insert: true)
        q.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))  // the hand-over hops to main
        XCTAssertEqual(inserted, ["hello"])
        s.pickClip(99, insert: false)  // unknown id: nothing is taken, the status says so
        q.sync {}
        XCTAssertEqual(inserted, ["hello"])
        XCTAssertTrue(statuses.contains("取用没成功：太旧了，A 已不保留"))
    }

    func testPickClipWithCapturedInfoSurvivesRollover() {
        let board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        boards.append(board)
        let pb = LocalPasteboard(board: board)
        let history = ClipHistory(pasteboard: pb, limit: 20, log: { _ in })
        let info = ClipInfo.text("old", truncated: false)
        history.add(id: 1, info)
        for i in 2...(UInt32(history.limit) + 5) { history.add(id: i, .text("n\(i)", truncated: false)) }
        XCTAssertNil(history.info(1))
        var inserted = [String]()
        history.pick(1, info: info, insert: true, transfers: TransferQueue(address: RemoteAddress(host: "127.0.0.1", port: 1, bundleID: "x", token: "t", mode: .color16)),
                     pasteboard: pb) { _, p in if case let .text(t) = p { inserted.append(t) } }
        XCTAssertEqual(inserted, ["old"])
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
        XCTAssertEqual(events, [.traffic(bytesPerSecond: 2000, frames: 0), .traffic(bytesPerSecond: 0, frames: 0)])
    }

    private func closedCount(_ events: [SessionEvent]) -> Int {
        events.filter { if case .closed = $0 { return true } else { return false } }.count
    }

    func testLinkDropDisconnectsAndKeepsLastFrame() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        let frame = try goodFrame()
        q.sync { link.feed(.windows([w])); link.feed(.frame(region: region, frame)) }
        q.sync { link.drop("the host closed the connection") }
        XCTAssertEqual(events.filter { if case .disconnected = $0 { return true } else { return false } },
                       [.disconnected(reason: "the host closed the connection")])
        XCTAssertEqual(events.last, .disconnected(reason: "the host closed the connection"))
        XCTAssertEqual(closedCount(events), 0)
        XCTAssertNotNil(s.surfaces.latest(7))
        s.close()
        q.sync {}
        XCTAssertEqual(events.last, .closed(reason: "quit"))
        XCTAssertEqual(closedCount(events), 1)
        XCTAssertNil(s.surfaces.latest(7))
        let n = events.count
        s.close()
        q.sync {}
        XCTAssertEqual(events.count, n)
    }

    func testTrafficCountsFrames() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        let frame = try goodFrame()
        q.sync {
            link.feed(.windows([w]))
            for _ in 0..<3 { link.feed(.frame(region: region, frame)) }
            link.onBytes?(100)
        }
        s.tickTraffic(); s.tickTraffic()
        q.sync {}
        XCTAssertEqual(events.suffix(2), [.traffic(bytesPerSecond: 100, frames: 3), .traffic(bytesPerSecond: 0, frames: 0)])
    }

    func testNoTrafficAfterDisconnect() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        q.sync { link.drop("gone") }
        s.tickTraffic()
        q.sync {}
        XCTAssertEqual(events, [.disconnected(reason: "gone")])
    }

    func testSideBytesCountAsTraffic() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        s.transfers.onBytes?(4096)  // main thread, as the transfer queue calls it
        q.sync {}
        s.tickTraffic()
        q.sync {}
        XCTAssertEqual(events, [.traffic(bytesPerSecond: 4096, frames: 0)])
    }

    private func hostAddress(serving: [UInt8], failWith: String? = nil) throws -> RemoteAddress {
        let host = try FakeSideHost(serving: serving, failWith: failWith)
        hosts.append(host)
        downloadsDir = FileManager.default.temporaryDirectory.appendingPathComponent("rapp-test-\(UUID().uuidString)")
        return RemoteAddress(host: "127.0.0.1", port: host.port, bundleID: "x", token: "t", mode: .color16)
    }

    private func fetch(_ s: EmbeddedSession, _ id: UInt32) -> Result<ClipCopy, TransferFailure>? {
        var result: Result<ClipCopy, TransferFailure>?
        s.fetchCopy(id) { result = $0 }
        let deadline = Date().addingTimeInterval(10)
        while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }

    func testClipRowsCarryKind() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (_, q) = make(link) { events.append($0) }
        q.sync {
            link.feed(.clip(id: 1, .text("a", truncated: false)))
            link.feed(.clip(id: 2, .image(width: 2, height: 2, bytes: 10)))
            link.feed(.clip(id: 3, .files([ClipFile(name: "f", bytes: 1)])))
            link.feed(.clip(id: 4, .unsupported("odd")))
            link.feed(.clip(id: 5, .data(uti: "public.rtf", bytes: 3)))
        }
        guard case let .clips(rows)? = events.last else { return XCTFail("no clips") }
        XCTAssertEqual(rows.map(\.kind), ["data", "unsupported", "files", "image", "text"])
    }

    func testFetchCopyOfTextIsImmediate() throws {
        let address = try hostAddress(serving: [1])
        let link = FakeLink()
        let (s, q) = make(link, address: address, downloads: downloadsDir) { _ in }
        q.sync { link.feed(.clip(id: 1, .text("hello", truncated: false))) }
        guard case .success(.text("hello"))? = fetch(s, 1) else { return XCTFail("expected text copy") }
        XCTAssertTrue(hosts[0].fetches.isEmpty)
    }

    func testFetchCopyOfImageDownloadsToMemory() throws {
        let bytes = (0..<1000).map { UInt8($0 % 251) }
        let address = try hostAddress(serving: bytes)
        let link = FakeLink()
        let (s, q) = make(link, address: address, downloads: downloadsDir) { _ in }
        q.sync { link.feed(.clip(id: 1, .image(width: 10, height: 10, bytes: 1000))) }
        guard case let .success(.image(got))? = fetch(s, 1) else { return XCTFail("expected image copy") }
        XCTAssertTrue(got == bytes)
    }

    func testFetchCopyOfUnknownOrDownLink() throws {
        let link = FakeLink()
        let (s, q) = make(link) { _ in }
        guard case let .failure(f)? = fetch(s, 9) else { return XCTFail("expected failure") }
        XCTAssertEqual(f.reason, "unknown clip")
        q.sync { link.feed(.clip(id: 1, .text("x", truncated: false))); link.drop("x") }
        q.sync {}
        guard case let .failure(g)? = fetch(s, 1) else { return XCTFail("expected failure") }
        XCTAssertEqual(g.reason, "A 已断开")
    }

    func testTransferProgressAndStatusAreBothForwarded() throws {
        let address = try hostAddress(serving: [UInt8](repeating: 7, count: 1000))
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link, address: address, downloads: downloadsDir) { events.append($0) }
        q.sync { link.feed(.clip(id: 1, .image(width: 10, height: 10, bytes: 1000))) }
        s.pickClip(1, insert: false)
        func progress() -> [TransferProgress] { events.compactMap { if case let .transferProgress(p) = $0 { return p } else { return nil } } }
        settle(q) { progress().last?.state == .done }
        q.sync {
            XCTAssertEqual(progress().last?.state, .done)
            XCTAssertTrue(events.contains { if case .transferStatus = $0 { return true } else { return false } })
        }
    }

    func testCopiesOutliveTheSession() throws {
        let bytes = [UInt8](repeating: 9, count: 1000)
        let address = try hostAddress(serving: bytes)
        let link = FakeLink()
        let (s, q) = make(link, address: address, downloads: downloadsDir) { _ in }
        q.sync { link.feed(.clip(id: 1, .image(width: 10, height: 10, bytes: 1000))) }
        guard case let .success(copy)? = fetch(s, 1) else { return XCTFail("expected copy") }
        let copies = ClipCopies()
        let n = copies.add(copy)
        s.close()
        q.sync {}
        let board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        boards.append(board)
        XCTAssertTrue(copies.write(n, to: LocalPasteboard(board: board)))
        XCTAssertNotNil(board.data(forType: NSPasteboard.PasteboardType(typePNG)))
    }

    func testFetchAndCopyNeverLogContent() throws {
        let host = try FakeSideHost(serving: [], failWith: "unknown clip")
        defer { host.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rapp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let address = RemoteAddress(host: "127.0.0.1", port: host.port, bundleID: "x", token: "t", mode: .color16)
        var lines = [String]()
        let board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        boards.append(board)
        let pb = LocalPasteboard(board: board)
        let history = ClipHistory(pasteboard: pb, limit: 20, log: { lines.append($0) })
        let transfers = TransferQueue(address: address, downloads: dir)
        transfers.log = { lines.append($0) }
        history.add(id: 1, .text("hello", truncated: false))
        history.add(id: 2, .image(width: 1, height: 1, bytes: 10))
        var fetched = 0
        history.fetch(1, info: .text("hello", truncated: false), transfers: transfers) { _ in fetched += 1 }
        history.pick(1, insert: false, transfers: transfers, pasteboard: pb) { _, _ in }
        history.fetch(2, info: .image(width: 1, height: 1, bytes: 10), transfers: transfers) { _ in fetched += 1 }
        let deadline = Date().addingTimeInterval(10)
        while fetched < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(fetched, 2)
        XCTAssertFalse(lines.contains { $0.contains("hello") }, "a log line carried clipboard content")
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
        XCTAssertEqual(events[1], .clips([ClipRow(id: 2, title: "odd", pickable: false, kind: "unsupported"),
                                          ClipRow(id: 1, title: "文字 · hello", pickable: true, kind: "text")]))
    }

    func testWindowsReemittedWhenVisibleChanges() throws {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (_, q) = make(link) { events.append($0) }
        // The frame covers only the left half of the 64-wide window.
        let half = CanvasRect(x: 0, y: 0, w: 32, h: 32)
        let enc = FrameEncoder(mode: .color16)
        let frame = try XCTUnwrap(enc.encode(samples: [UInt8](repeating: 0x55, count: 32 * 32 * 2), width: 32, height: 32))
        q.sync {
            link.feed(.windows([w]))
            link.feed(.frame(region: half, frame))
        }
        let visible = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        XCTAssertEqual(events.suffix(2), [.surfaces([7]), .windows([SessionWindow(info: w, visible: visible)])])
        let count = events.count
        q.sync { link.feed(.frame(region: half, frame)) }
        XCTAssertEqual(Array(events.dropFirst(count)), [.surfaces([7])])
    }

    /// Spins the main queue (the composer's home) until `done` holds on the session queue.
    private func settle(_ q: DispatchQueue, until done: () -> Bool) {
        for _ in 0..<100 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if q.sync(execute: done) { return }
        }
    }

    private func composerEvents(_ events: [SessionEvent]) -> [ComposerEvent] {
        events.compactMap { if case let .composer(e) = $0 { return e } else { return nil } }
    }

    func testComposerSendGoesOutOnTheQueueAndPastedHopsToMain() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        s.composer.send([.text("hi")])  // main, as the runner calls it
        q.sync {}
        XCTAssertEqual(link.sent.last, .paste(seq: 1, .text("hi")))
        q.sync { link.feed(.pasted(seq: 1, error: "")) }
        settle(q) { composerEvents(events).count == 3 }
        q.sync {
            XCTAssertEqual(composerEvents(events), [.sending(true), .sending(false), .done(sent: 1, failure: nil)])
        }
    }

    func testClipInsertGoesToTheComposer() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        q.sync { link.feed(.clip(id: 5, .text("hello", truncated: false))) }
        s.pickClip(5, insert: true)
        settle(q) { !composerEvents(events).isEmpty }
        q.sync { XCTAssertEqual(composerEvents(events), [.insert(.text("hello"))]) }
    }

    func testUploadStatusIsForwardedAndCancelEndsTheRound() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        // Too long to go inline: uploaded first (to a port nothing listens on).
        s.composer.send([.text(String(repeating: "a", count: inlinePasteLimit))])
        settle(q) { events.contains(.transferStatus("上传 1/1 0%")) }
        s.cancelTransfers()
        settle(q) { events.contains(.transferStatus(nil)) && composerEvents(events).count == 3 }
        q.sync {
            // The round starts (sending) before the upload reports.
            XCTAssertEqual(events.first, .composer(.sending(true)))
            XCTAssertTrue(events.contains(.transferStatus("上传 1/1 0%")))
            XCTAssertTrue(events.contains(.transferStatus(nil)))
            XCTAssertEqual(composerEvents(events), [.sending(true), .sending(false), .done(sent: 0, failure: "")])
            XCTAssertFalse(link.sent.contains { if case .paste = $0 { return true } else { return false } })
        }
    }

    func testNoComposerEventsAfterClose() {
        let link = FakeLink()
        var events = [SessionEvent]()
        let (s, q) = make(link) { events.append($0) }
        s.close()
        s.composer.send([.text("hi")])
        settle(q) { false }
        q.sync {
            XCTAssertEqual(events, [.closed(reason: "quit")])
            XCTAssertFalse(link.sent.contains(.paste(seq: 1, .text("hi"))))
        }
    }
}
