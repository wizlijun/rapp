import RappCore
import XCTest
@testable import RappSession

private final class FakeSink: ComposerSink {
    var payloads: [Int: ChipPayload] = [:]
    var uploaded: [Int: UInt32] = [:]
    var sending: [Bool] = []
    var finishedCalls: [(pieces: [ComposerPiece], sent: Int, failure: String?)] = []

    func payload(_ chunk: Int) -> ChipPayload? { payloads[chunk] }
    func uploadedItem(_ chunk: Int) -> UInt32? { uploaded[chunk] }
    func setUploadedItem(_ item: UInt32, for chunk: Int) { uploaded[chunk] = item }
    func setSending(_ on: Bool) { sending.append(on) }
    func finished(pieces: [ComposerPiece], sent: Int, failure: String?) {
        finishedCalls.append((pieces, sent, failure))
    }
}

final class SenderTests: XCTestCase {
    private var sink: FakeSink!
    private var sent: [Message] = []
    private var sender: Sender!

    override func setUp() {
        sink = FakeSink()
        sent = []
        let address = RemoteAddress(host: "127.0.0.1", port: 1, bundleID: "x", token: "t", mode: .color16)
        sender = Sender(sink: sink, transfers: TransferQueue(address: address), counters: SendCounters()) { [unowned self] in
            sent.append($0)
        }
    }

    func testSenderPastesTextThenReportsAllSent() {
        sender.start(pieces: [.text("hi")])
        XCTAssertEqual(sent, [.paste(seq: 1, .text("hi"))])
        XCTAssertEqual(sink.sending, [true])
        XCTAssertTrue(sender.pasted(seq: 1, error: ""))
        XCTAssertEqual(sink.finishedCalls.count, 1)
        XCTAssertEqual(sink.finishedCalls[0].sent, 1)
        XCTAssertNil(sink.finishedCalls[0].failure)
        XCTAssertEqual(sink.sending, [true, false])
    }

    func testSenderReportsPasteError() {
        sender.start(pieces: [.text("hi")])
        XCTAssertTrue(sender.pasted(seq: 1, error: "x"))
        XCTAssertEqual(sink.finishedCalls[0].sent, 0)
        XCTAssertEqual(sink.finishedCalls[0].failure, pasteErrorMessage("x"))
    }

    func testSenderFailsAMissingChunk() {
        sender.start(pieces: [.chunk(7)])
        XCTAssertEqual(sink.finishedCalls.count, 1)
        XCTAssertEqual(sink.finishedCalls[0].sent, 0)
        XCTAssertEqual(sink.finishedCalls[0].failure, "找不到这一块的内容")
    }

    func testPastedOfAnotherSeqIsNotAnswered() {
        sender.start(pieces: [.text("hi")])
        XCTAssertFalse(sender.pasted(seq: 99, error: ""))
        XCTAssertTrue(sink.finishedCalls.isEmpty)
    }
}
