import XCTest
@testable import RappCore

final class DataPathsTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/u")

    func testDownloadsEnvWins() {
        XCTAssertEqual(DataPaths.transfers(env: ["RAPP_DOWNLOADS": "/d", "RAPP_HOME": "/h"], home: home, read: { _ in nil }).path, "/d")
    }
    func testRappHomeThenPointerThenHomeRapp() {
        let ptr: (URL) -> String? = { $0.path == "/Users/u/Library/Application Support/rapp/data-root" ? "/Volumes/D/rapp\n" : nil }
        XCTAssertEqual(DataPaths.transfers(env: ["RAPP_HOME": "/h"], home: home, read: ptr).path, "/h/files/transfers")
        XCTAssertEqual(DataPaths.transfers(env: [:], home: home, read: ptr).path, "/Volumes/D/rapp/files/transfers")
        XCTAssertEqual(DataPaths.transfers(env: [:], home: home, read: { _ in nil }).path, "/Users/u/rapp/files/transfers")
    }
    func testEmptyValuesAndRelativePointerAreIgnored() {
        XCTAssertEqual(DataPaths.transfers(env: ["RAPP_DOWNLOADS": "", "RAPP_HOME": ""], home: home, read: { _ in "rapp" }).path,
                       "/Users/u/rapp/files/transfers")
    }
    func testABlankFirstLineIsNotSkipped() { // same as Rust `lines().next()`
        XCTAssertEqual(DataPaths.root(env: [:], home: home, read: { _ in "\n/x/y\n" }).path, "/Users/u/rapp")
    }
    func testPointerFirstLineTrimmed() {
        XCTAssertEqual(DataPaths.root(env: [:], home: home, read: { _ in "  /x/y  \nignored\n" }).path, "/x/y")
    }
}
