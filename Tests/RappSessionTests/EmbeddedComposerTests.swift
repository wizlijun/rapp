import AppKit
import XCTest
import RappCore
@testable import RappSession

final class EmbeddedComposerTests: XCTestCase {
    private var board: NSPasteboard!
    private var pasteboard: LocalPasteboard!
    private var sent = [Message]()
    private var events = [ComposerEvent]()
    private var composer: EmbeddedComposer!
    private var temp: URL!

    override func setUp() {
        super.setUp()
        board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        pasteboard = LocalPasteboard(board: board)
        sent = []
        events = []
        let address = RemoteAddress(host: "127.0.0.1", port: 1, bundleID: "x", token: "t", mode: .color16)
        composer = EmbeddedComposer(pasteboard: pasteboard, transfers: TransferQueue(address: address),
                                    counters: SendCounters(),
                                    send: { [unowned self] in self.sent.append($0) },
                                    emit: { [unowned self] in self.events.append($0) })
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("rapp-composer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: temp)
        composer = nil
        super.tearDown()
    }

    private func png(width: Int, height: Int) throws -> [UInt8] {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return [UInt8](try XCTUnwrap(rep.representation(using: .png, properties: [:])))
    }

    func testPasteShortTextIsInline() {
        pasteboard.write(text: "hi")
        XCTAssertEqual(composer.paste(), .text("hi"))
    }

    func testPasteLongTextBecomesABlock() {
        pasteboard.write(text: String(repeating: "a", count: 900))
        XCTAssertEqual(composer.paste(), .blocks([BlockChip(n: 1, label: "[贴入文字 #1 +1 行]")]))
    }

    func testPastePNGBecomesImageBlock() throws {
        pasteboard.write(png: try png(width: 10, height: 20))
        XCTAssertEqual(composer.paste(), .blocks([BlockChip(n: 1, label: "[图片 #1 10×20]")]))
    }

    func testPasteOfAnEmptyBoardIsNothing() {
        board.clearContents()
        XCTAssertEqual(composer.paste(), .nothing)
    }

    func testAttachFolderIsRefused() {
        let folder = temp.appendingPathComponent("stuff")
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true))
        XCTAssertEqual(composer.attach([folder]), .status("不支持文件夹：stuff"))
    }

    func testAttachTooBigIsRefused() throws {
        let big = temp.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        // Sparse: costs no disk.
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: maxComposerBytes + 1)
        try handle.close()
        XCTAssertEqual(composer.attach([big]), .status("太大了，远端最多收 256 MB"))
    }

    func testAttachFilesBecomeBlocksAndAFolderAmongThemIsReported() throws {
        let file = temp.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: file)
        let folder = temp.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(composer.attach([file, folder]), .blocks([BlockChip(n: 1, label: "[文件 a.txt 3 B]")]))
        XCTAssertEqual(events, [.insert(.status("不支持文件夹：dir"))])
    }

    func testSendOrderAndDone() {
        let long = String(repeating: "a", count: 900)
        pasteboard.write(text: long)
        XCTAssertEqual(composer.paste(), .blocks([BlockChip(n: 1, label: "[贴入文字 #1 +1 行]")]))
        composer.send([.chunk(1), .text("x")])
        XCTAssertEqual(sent, [.paste(seq: 1, .text(long))])
        XCTAssertTrue(composer.pasted(seq: 1, error: ""))
        XCTAssertEqual(sent, [.paste(seq: 1, .text(long)), .paste(seq: 2, .text("x"))])
        XCTAssertTrue(composer.pasted(seq: 2, error: ""))
        XCTAssertEqual(events, [.sending(true), .sending(false), .done(sent: 2, failure: nil)])
    }

    func testAFailedPasteReportsWhatWent() {
        composer.send([.text("a")])
        XCTAssertTrue(composer.pasted(seq: 1, error: "target not frontmost"))
        XCTAssertEqual(events.last, .done(sent: 0, failure: "远端的目标窗口不在最前"))
    }

    func testDroppedBlockIsForgotten() {
        pasteboard.write(text: String(repeating: "a", count: 900))
        _ = composer.paste()
        composer.drop(1)
        composer.send([.chunk(1)])
        XCTAssertEqual(events.last, .done(sent: 0, failure: "找不到这一块的内容"))
    }

    func testInsertFromAsClipboardEmitsInsert() throws {
        composer.insert(.text("hi", truncated: false), .text("hi"))
        composer.insert(.image(width: 10, height: 20, bytes: 1), .bytes(try png(width: 10, height: 20)))
        XCTAssertEqual(events, [.insert(.text("hi")), .insert(.blocks([BlockChip(n: 1, label: "[图片 #1 10×20]")]))])
    }
}
