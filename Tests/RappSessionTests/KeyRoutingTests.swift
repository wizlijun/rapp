import AppKit
import XCTest
@testable import RappSession

final class KeyRoutingTests: XCTestCase {
    func testRouteKey() {
        XCTAssertEqual(routeKey(keyCode: 3, flags: [.control, .command], pictureFocused: true), .local)   // ⌃⌘F
        XCTAssertEqual(routeKey(keyCode: 2, flags: [.control, .command], pictureFocused: true), .local)   // ⌃⌘D
        XCTAssertEqual(routeKey(keyCode: 33, flags: [.control, .command], pictureFocused: true), .local)  // ⌃⌘[
        XCTAssertEqual(routeKey(keyCode: 12, flags: [.command], pictureFocused: true), .local)            // ⌘Q
        XCTAssertEqual(routeKey(keyCode: 53, flags: [], pictureFocused: true), .remote)                   // Esc
        XCTAssertEqual(routeKey(keyCode: 13, flags: [.command], pictureFocused: true), .remote)           // ⌘W
        XCTAssertEqual(routeKey(keyCode: 33, flags: [.command], pictureFocused: true), .remote)           // ⌘[
        XCTAssertEqual(routeKey(keyCode: 12, flags: [.command, .shift], pictureFocused: true), .remote)   // ⇧⌘Q
        XCTAssertEqual(routeKey(keyCode: 53, flags: [], pictureFocused: false), .local)
    }

    func testRouteKeyIgnoresNonModifierBits() {
        // Caps lock and the numeric-pad bit do not stop ⌘Q being rapp's.
        XCTAssertEqual(routeKey(keyCode: 12, flags: [.command, .capsLock, .numericPad], pictureFocused: true), .local)
        XCTAssertEqual(routeKey(keyCode: 3, flags: [.control, .command, .shift], pictureFocused: true), .local)
    }

    func testKeyTrackerReleasesHeldKeys() {
        var k = KeyTracker(); k.down(0); k.down(56); k.down(0); k.up(0); k.down(11)
        XCTAssertEqual(k.releaseAll(), [11, 56]); XCTAssertEqual(k.releaseAll(), [])
    }

    func testKeyTrackerKnowsWhatIsHeld() {
        var k = KeyTracker()
        k.down(4)
        XCTAssertTrue(k.isDown(4))
        XCTAssertFalse(k.isDown(5))
        k.up(4)
        XCTAssertFalse(k.isDown(4))
    }

    func testModifierKeyDirectionFromFlags() {
        XCTAssertEqual(modifierKeyIsDown(keyCode: 56, flags: [.shift]), true)        // left shift down
        XCTAssertEqual(modifierKeyIsDown(keyCode: 60, flags: []), false)             // right shift up
        XCTAssertEqual(modifierKeyIsDown(keyCode: 55, flags: [.command]), true)      // left command
        XCTAssertEqual(modifierKeyIsDown(keyCode: 54, flags: [.shift]), false)       // right command up
        XCTAssertEqual(modifierKeyIsDown(keyCode: 58, flags: [.option]), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 61, flags: []), false)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 59, flags: [.control]), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 62, flags: [.control]), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 57, flags: [.capsLock]), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 63, flags: [.function]), true)
        XCTAssertNil(modifierKeyIsDown(keyCode: 0, flags: [.shift]))                 // not a modifier key
        XCTAssertNil(modifierKeyIsDown(keyCode: 64, flags: []))
    }
}

final class KeyTrackerRouteTests: XCTestCase {
    private func flags(_ f: NSEvent.ModifierFlags, device: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: f.rawValue | device)
    }

    func testPressesWhileFocusedGoToAAndTheirReleasesFollow() {
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 0, down: true, flags: [], pictureFocused: true), KeyDecision(.remote))
        XCTAssertEqual(k.route(keyCode: 0, down: false, flags: [], pictureFocused: true), KeyDecision(.remote))
        XCTAssertEqual(k.releaseAll(), [])
    }

    func testAReleaseAHasNoPressForStaysLocal() {
        // Pressed before the picture had focus: Flutter saw the press, so it gets the release.
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 55, down: false, flags: [], pictureFocused: true), KeyDecision(.local))
    }

    func testCommandQReleasesTheCommandAHolds() {
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 55, down: true, flags: [.command], pictureFocused: true), KeyDecision(.remote))
        XCTAssertEqual(k.route(keyCode: 12, down: true, flags: [.command], pictureFocused: true),
                       KeyDecision(.local, release: [55]))
        XCTAssertEqual(k.route(keyCode: 12, down: true, flags: [.command], pictureFocused: true), KeyDecision(.local))
        XCTAssertFalse(k.isDown(55))
    }

    func testAReservedChordReleasesWhatAHoldsThenStaysLocal() {
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 59, down: true, flags: [.control], pictureFocused: true), KeyDecision(.remote))   // ⌃ to A
        XCTAssertEqual(k.route(keyCode: 55, down: true, flags: [.control, .command], pictureFocused: true),
                       KeyDecision(.local, release: [59]))
        XCTAssertEqual(k.route(keyCode: 3, down: true, flags: [.control, .command], pictureFocused: true), KeyDecision(.local))
        XCTAssertEqual(k.route(keyCode: 3, down: false, flags: [.control, .command], pictureFocused: true), KeyDecision(.local))
        XCTAssertEqual(k.route(keyCode: 55, down: false, flags: [.control], pictureFocused: true), KeyDecision(.local))
        // A already had its release; this one is Flutter's.
        XCTAssertEqual(k.route(keyCode: 59, down: false, flags: [], pictureFocused: true), KeyDecision(.local))
        XCTAssertEqual(k.releaseAll(), [])
    }

    func testUnfocusedPressesStayLocal() {
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 0, down: true, flags: [], pictureFocused: false), KeyDecision(.local))
        XCTAssertEqual(k.releaseAll(), [])
    }

    func testLeftAndRightModifiersAreToldApart() {
        var k = KeyTracker()
        let both = flags(.shift, device: 0x2 | 0x4)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 56, flags: flags(.shift, device: 0x2)), true)
        XCTAssertEqual(k.route(keyCode: 56, down: modifierKeyIsDown(keyCode: 56, flags: flags(.shift, device: 0x2))!,
                               flags: flags(.shift, device: 0x2), pictureFocused: true), KeyDecision(.remote))
        XCTAssertEqual(modifierKeyIsDown(keyCode: 60, flags: both), true)
        XCTAssertEqual(k.route(keyCode: 60, down: true, flags: both, pictureFocused: true), KeyDecision(.remote))
        // Right shift up: the shift bit stays (left still held), the right device bit goes.
        let leftOnly = flags(.shift, device: 0x2)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 60, flags: leftOnly), false)
        XCTAssertEqual(k.route(keyCode: 60, down: false, flags: leftOnly, pictureFocused: true), KeyDecision(.remote))
        XCTAssertTrue(k.isDown(56))
        XCTAssertFalse(k.isDown(60))
    }

    func testDeviceBitsForEveryPair() {
        XCTAssertEqual(modifierKeyIsDown(keyCode: 59, flags: flags(.control, device: 0x2000)), false)  // only right ctrl
        XCTAssertEqual(modifierKeyIsDown(keyCode: 62, flags: flags(.control, device: 0x2000)), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 59, flags: flags(.control, device: 0x1)), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 55, flags: flags(.command, device: 0x10)), false)    // only right cmd
        XCTAssertEqual(modifierKeyIsDown(keyCode: 54, flags: flags(.command, device: 0x10)), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 55, flags: flags(.command, device: 0x8)), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 58, flags: flags(.option, device: 0x40)), false)     // only right option
        XCTAssertEqual(modifierKeyIsDown(keyCode: 61, flags: flags(.option, device: 0x40)), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 58, flags: flags(.option, device: 0x20)), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 60, flags: flags(.shift, device: 0x4)), true)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 56, flags: flags(.shift, device: 0x4)), false)
        XCTAssertEqual(modifierKeyIsDown(keyCode: 63, flags: [.function]), true)                       // fn: no device bit
        XCTAssertEqual(modifierKeyIsDown(keyCode: 63, flags: []), false)
    }

    func testCapsLockIsNeverHeld() {
        var k = KeyTracker()
        k.down(57)
        XCTAssertFalse(k.isDown(57))
        XCTAssertEqual(k.route(keyCode: 57, down: true, flags: [.capsLock], pictureFocused: true), KeyDecision(.remote))
        XCTAssertEqual(k.releaseAll(), [])
        // Its toggle-off still goes to A while focused, and stays local without focus.
        XCTAssertEqual(k.route(keyCode: 57, down: false, flags: [], pictureFocused: true), KeyDecision(.remote))
        XCTAssertEqual(k.route(keyCode: 57, down: true, flags: [.capsLock], pictureFocused: false), KeyDecision(.local))
        XCTAssertEqual(k.releaseAll(), [])
    }
}
