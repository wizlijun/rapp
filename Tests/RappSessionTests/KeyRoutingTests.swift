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
    func testPressesWhileFocusedGoToAAndTheirReleasesFollow() {
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 0, down: true, flags: [], pictureFocused: true), .remote)
        XCTAssertEqual(k.route(keyCode: 0, down: false, flags: [], pictureFocused: true), .remote)
        XCTAssertEqual(k.releaseAll(), [])
    }

    func testAReleaseAHasNoPressForStaysLocal() {
        // Pressed before the picture had focus: Flutter saw the press, so it gets the release.
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 55, down: false, flags: [], pictureFocused: true), .local)
    }

    func testAReleaseGoesToAEvenOnceTheChordIsRapps() {
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 59, down: true, flags: [.control], pictureFocused: true), .remote)   // ⌃ to A
        XCTAssertEqual(k.route(keyCode: 55, down: true, flags: [.control, .command], pictureFocused: true), .local)
        XCTAssertEqual(k.route(keyCode: 3, down: true, flags: [.control, .command], pictureFocused: true), .local)
        XCTAssertEqual(k.route(keyCode: 3, down: false, flags: [.control, .command], pictureFocused: true), .local)
        XCTAssertEqual(k.route(keyCode: 55, down: false, flags: [.control], pictureFocused: true), .local)
        XCTAssertEqual(k.route(keyCode: 59, down: false, flags: [], pictureFocused: true), .remote)
        XCTAssertEqual(k.releaseAll(), [])
    }

    func testUnfocusedPressesStayLocal() {
        var k = KeyTracker()
        XCTAssertEqual(k.route(keyCode: 0, down: true, flags: [], pictureFocused: false), .local)
        XCTAssertEqual(k.releaseAll(), [])
    }
}
