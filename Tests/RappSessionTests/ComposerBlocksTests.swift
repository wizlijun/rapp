import XCTest
@testable import RappSession

final class ComposerBlocksTests: XCTestCase {
    func testComposerBlocksNumbersAndLabels() {
        let blocks = ComposerBlocks()
        let sixty = (1...60).map(String.init).joined(separator: "\n")
        XCTAssertEqual(blocks.add(.text(sixty)), 1)
        XCTAssertEqual(blocks.label(1), "[贴入文字 #1 +60 行]")
        XCTAssertEqual(blocks.add(.image(png: [1], width: 10, height: 20)), 2)
        XCTAssertEqual(blocks.label(2), "[图片 #1 10×20]")
        blocks.remove(1)
        XCTAssertNil(blocks.payload(1))
        XCTAssertNil(blocks.label(1))
        XCTAssertNotNil(blocks.payload(2))
        XCTAssertEqual(blocks.add(.text("b")), 3)
        XCTAssertEqual(blocks.label(3), "[贴入文字 #2 +1 行]")
    }

    func testUploadedItemFollowsTheBlock() {
        let blocks = ComposerBlocks()
        let n = blocks.add(.text("a"))
        XCTAssertNil(blocks.uploadedItem(n))
        blocks.setUploadedItem(9, for: n)
        XCTAssertEqual(blocks.uploadedItem(n), 9)
        blocks.keep(only: [])
        XCTAssertNil(blocks.uploadedItem(n))
        XCTAssertNil(blocks.payload(n))
    }
}
