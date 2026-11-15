import XCTest
@testable import RappCore

final class UnlockSequenceTests: XCTestCase {
    func testUnlockedScreenReceivesNoInput() {
        var events = [String]()
        typeUnlockPassword("secret", isLocked: { false }, wake: { events.append("wake") },
                           wait: { _ in events.append("wait") }, typeChunk: { _ in events.append("text") },
                           pressReturn: { events.append("return") })
        XCTAssertTrue(events.isEmpty)
    }

    func testUnlockWhileWakingStopsBeforePassword() {
        var locked = true
        var events = [String]()
        typeUnlockPassword("secret", isLocked: { locked }, wake: { events.append("wake") },
                           wait: { _ in locked = false }, typeChunk: { _ in events.append("text") },
                           pressReturn: { events.append("return") })
        XCTAssertEqual(events, ["wake"])
    }

    func testUnlockDuringTypingStopsRemainingChunksAndReturn() {
        var locked = true
        var text = [String]()
        typeUnlockPassword(String(repeating: "x", count: 50), isLocked: { locked }, wake: {}, wait: { _ in },
                           typeChunk: { chunk in text.append(String(decoding: chunk, as: UTF16.self)); locked = false },
                           pressReturn: { XCTFail("already unlocked") })
        XCTAssertEqual(text, [String(repeating: "x", count: 20)])
    }

    func testLockedScreenReceivesUnicodeThenReturnAfterDelays() {
        let password = "pässword🔑" + String(repeating: "密", count: 30)
        var text = [UInt16]()
        var events = [String]()
        var waits = [UInt32]()
        typeUnlockPassword(password, isLocked: { true }, wake: { events.append("wake") },
                           wait: { waits.append($0) }, typeChunk: { text += $0; events.append("text") },
                           pressReturn: { events.append("return") })
        XCTAssertEqual(String(decoding: text, as: UTF16.self), password)
        XCTAssertEqual(events.first, "wake")
        XCTAssertEqual(events.last, "return")
        XCTAssertEqual(waits.first, 1_000_000)
        XCTAssertEqual(waits.last, 50_000)
    }
}
