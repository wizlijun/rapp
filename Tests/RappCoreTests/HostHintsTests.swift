import CoreGraphics
import RappCore
import XCTest

final class HostHintsTests: XCTestCase {
    func testCoverNoticeOncePerOwnerPerFewSeconds() {
        var t = CoverNotices(every: 5)
        XCTAssertTrue(t.shouldSend(pid: 7, at: 100))
        XCTAssertFalse(t.shouldSend(pid: 7, at: 104.9))
        XCTAssertTrue(t.shouldSend(pid: 8, at: 104.9))
        XCTAssertTrue(t.shouldSend(pid: 7, at: 105))
        XCTAssertFalse(t.shouldSend(pid: 7, at: 106))
    }

    func testCoverNoticesRemembersWhatWasReported() {
        var t = CoverNotices(every: 5)
        _ = t.shouldSend(pid: 7, at: 100)
        t.reported(pid: 7, dismissable: true, at: CGPointZeroish.point)
        XCTAssertEqual(t.dismissPoint(pid: 7), CGPointZeroish.point)
        t.reported(pid: 8, dismissable: false, at: CGPointZeroish.point)
        XCTAssertNil(t.dismissPoint(pid: 8))
        XCTAssertNil(t.dismissPoint(pid: 9))
        t.forget(pid: 7)
        XCTAssertNil(t.dismissPoint(pid: 7))
    }

    func testSystemSecurityAndPasswordPromptsAreNeverDismissable() {
        for id in ["com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.coreservices.uiagent",
                   "com.apple.UserNotificationCenter", "com.apple.LocalAuthentication.UIAgent",
                   "com.apple.accessibility.universalAccessAuthWarn", "com.example.PasswordHelper"] {
            XCTAssertFalse(coverDismissable(bundleID: id, regular: true), id)
        }
        XCTAssertFalse(coverDismissable(bundleID: nil, regular: true))
        XCTAssertFalse(coverDismissable(bundleID: "", regular: true))
    }

    func testBannersAndOrdinaryAppWindowsAreDismissable() {
        XCTAssertTrue(coverDismissable(bundleID: "com.apple.notificationcenterui", regular: false))
        XCTAssertTrue(coverDismissable(bundleID: "com.apple.Notes", regular: true))
        XCTAssertFalse(coverDismissable(bundleID: "com.example.agent", regular: false))
    }

    private func opened(_ bundle: String? = "com.apple.Safari", pid: Int32 = 30, regular: Bool = true,
                        since: Double? = 0.5) -> Bool {
        appOpenedWorthTelling(bundleID: bundle, pid: pid, regular: regular, sessionPID: 10, ownPID: 20,
                              sinceInput: since)
    }

    func testAnotherAppRightAfterInputIsTold() {
        XCTAssertTrue(opened())
        XCTAssertTrue(opened(since: 2))
        XCTAssertTrue(opened("com.apple.Preview"))
        XCTAssertTrue(opened("com.apple.finder"))
    }

    func testLateOrInputlessActivationIsNotTold() {
        XCTAssertFalse(opened(since: 2.1))
        XCTAssertFalse(opened(since: nil))
        XCTAssertFalse(opened(since: -1))
    }

    func testSessionAppRappAndSystemAreNotTold() {
        XCTAssertFalse(opened(pid: 10))
        XCTAssertFalse(opened(pid: 20))
        XCTAssertFalse(opened(regular: false))
        XCTAssertFalse(opened(nil))
        XCTAssertFalse(opened(""))
        for id in ["com.rapp.rapp", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
                   "com.apple.SecurityAgent", "com.apple.notificationcenterui", "com.apple.controlcenter"] {
            XCTAssertFalse(opened(id), id)
        }
    }

    func testSecureFieldIsTheSecureSubrole() {
        XCTAssertTrue(isSecureField(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(isSecureField(role: nil, subrole: "AXSecureTextField"))
        XCTAssertFalse(isSecureField(role: "AXTextField", subrole: nil))
        XCTAssertFalse(isSecureField(role: "AXTextArea", subrole: "AXSearchField"))
    }
}

private enum CGPointZeroish { static let point = CGPoint(x: 12, y: 34) }
