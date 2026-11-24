import XCTest
@testable import RappSession

final class PressRoutingTests: XCTestCase {
    private let command = 0x100000  // UIKeyModifierFlags.command
    private let control = 0x40000   // UIKeyModifierFlags.control

    private func focused(_ sid: Int64 = 7) -> PressRouter {
        var r = PressRouter()
        r.focusedSid = sid
        return r
    }

    func testUnfocusedIsLocal() {
        var r = PressRouter()
        XCTAssertEqual(r.press(hidUsage: 0x04, uiModifiers: 0, down: true, characters: "a", composeOn: true,
                               remoteSecure: false), .local)
        XCTAssertEqual(r.press(hidUsage: 0x2B, uiModifiers: 0, down: true, characters: "\t", composeOn: false,
                               remoteSecure: false), .local)
        XCTAssertEqual(r.blur(), [])
    }

    func testUnmappedKeyIsLocal() {
        var r = focused()
        XCTAssertEqual(r.press(hidUsage: 0xFFFF, uiModifiers: 0, down: true, characters: nil, composeOn: false,
                               remoteSecure: false), .local)
    }

    func testLetterOpensCompose() {
        var r = focused()
        XCTAssertEqual(r.press(hidUsage: 0x04, uiModifiers: 0, down: true, characters: "a", composeOn: true,
                               remoteSecure: false), .compose(sid: 7))
        // The letter never reached A: nothing to release.
        XCTAssertEqual(r.blur(), [])
    }

    func testCmdCGoesRemote() {
        var r = focused()
        XCTAssertEqual(r.press(hidUsage: 0x06, uiModifiers: command, down: true, characters: "c", composeOn: true,
                               remoteSecure: false), .send([KeyOut(8, 0x100000, true)], latchUsed: false))
        XCTAssertEqual(r.press(hidUsage: 0x06, uiModifiers: command, down: false, characters: "c", composeOn: true,
                               remoteSecure: false), .send([KeyOut(8, 0x100000, false)], latchUsed: false))
    }

    func testLatchAppliesOnceToNextKey() {
        var r = focused()
        r.latched = 0x100000
        XCTAssertEqual(r.press(hidUsage: 0x2B, uiModifiers: 0, down: true, characters: "\t", composeOn: false,
                               remoteSecure: false), .send([KeyOut(48, 0x100000, true)], latchUsed: true))
        XCTAssertEqual(r.latched, 0)
        _ = r.press(hidUsage: 0x2B, uiModifiers: 0, down: false, characters: "\t", composeOn: false, remoteSecure: false)
        XCTAssertEqual(r.press(hidUsage: 0x2B, uiModifiers: 0, down: true, characters: "\t", composeOn: false,
                               remoteSecure: false), .send([KeyOut(48, 0, true)], latchUsed: false))
    }

    func testLatchWaitsPastModifierKeys() {
        var r = focused()
        r.latched = 0x100000
        // ⇧ down: carries the latch but does not use it up.
        XCTAssertEqual(r.press(hidUsage: 0xE1, uiModifiers: 0x20000, down: true, characters: nil, composeOn: false,
                               remoteSecure: false), .send([KeyOut(56, 0x120000, true)], latchUsed: false))
        XCTAssertEqual(r.latched, 0x100000)
    }

    func testLatchedCommandStopsCompose() {
        var r = focused()
        r.latched = 0x100000
        XCTAssertEqual(r.press(hidUsage: 0x04, uiModifiers: 0, down: true, characters: "a", composeOn: true,
                               remoteSecure: false), .send([KeyOut(0, 0x100000, true)], latchUsed: true))
    }

    func testBlurReleasesHeld() {
        var r = focused()
        _ = r.press(hidUsage: 0xE1, uiModifiers: 0x20000, down: true, characters: nil, composeOn: false, remoteSecure: false)
        _ = r.press(hidUsage: 0x04, uiModifiers: 0x20000, down: true, characters: "A", composeOn: false, remoteSecure: false)
        XCTAssertEqual(r.blur(), [KeyOut(0, 0, false), KeyOut(56, 0, false)])
        XCTAssertEqual(r.blur(), [])
        // A release after the blur has nothing left on A: it stays local.
        XCTAssertEqual(r.press(hidUsage: 0x04, uiModifiers: 0, down: false, characters: "a", composeOn: false,
                               remoteSecure: false), .local)
    }

    func testReservedChordReleasesWhatAHolds() {
        var r = focused()
        XCTAssertEqual(r.press(hidUsage: 0xE0, uiModifiers: control, down: true, characters: nil, composeOn: false,
                               remoteSecure: false), .send([KeyOut(59, 0x40000, true)], latchUsed: false))
        // ⌃⌘… is rApp's: as ⌘ joins, A first lets go of the ⌃ it holds, and ⌘ stays local.
        XCTAssertEqual(r.press(hidUsage: 0xE3, uiModifiers: control | command, down: true, characters: nil,
                               composeOn: false, remoteSecure: false), .localAfterRelease([KeyOut(59, 0, false)]))
        XCTAssertEqual(r.press(hidUsage: 0x09, uiModifiers: control | command, down: true, characters: "f",
                               composeOn: false, remoteSecure: false), .local)
        XCTAssertEqual(r.blur(), [])
    }

    func testSecureFieldNeverComposes() {
        var r = focused()
        XCTAssertEqual(r.press(hidUsage: 0x04, uiModifiers: 0, down: true, characters: "a", composeOn: true,
                               remoteSecure: true), .send([KeyOut(0, 0, true)], latchUsed: false))
    }
}
