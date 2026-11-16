import CoreGraphics
import Foundation

/// What the host remembers of the `covered` notices it sent (protocol v13): one per covering owner per
/// few seconds, so a burst of dropped presses tells B once, and where each dismissable one was, so a
/// `dismissCover` acts only on a window this session reported.
public struct CoverNotices {
    public let every: TimeInterval
    private var sentAt: [Int32: TimeInterval] = [:]
    private var points: [Int32: CGPoint] = [:]

    public init(every: TimeInterval = 5) { self.every = every }

    /// Whether a notice for `pid` goes now; true records it as sent.
    public mutating func shouldSend(pid: Int32, at now: TimeInterval) -> Bool {
        if let last = sentAt[pid], now - last < every { return false }
        sentAt[pid] = now
        return true
    }

    /// The notice for `pid` went, about a press at `point`; only a dismissable one can be dismissed.
    public mutating func reported(pid: Int32, dismissable: Bool, at point: CGPoint) {
        points[pid] = dismissable ? point : nil
    }

    /// Where the dismissable cover of `pid` was pressed; nil when none was reported (or not dismissable).
    public func dismissPoint(pid: Int32) -> CGPoint? { points[pid] }

    public mutating func forget(pid: Int32) { points[pid] = nil }
}

/// System prompts the host never closes for B: security, login, permission and password dialogs.
/// Those are for a person at A (or in a desktop session) to answer.
private let protectedCovers: Set<String> = [
    "com.apple.securityagent", "com.apple.loginwindow", "com.apple.coreservices.uiagent",
    "com.apple.usernotificationcenter", "com.apple.localauthentication.uiagent",
    "com.apple.accessibility.universalaccessauthwarn", "com.apple.coreauthui", "com.apple.screensaver.engine",
]

/// Words in a bundle id that mark it as a prompt the host must not close, whoever made it.
private let protectedWords = ["security", "auth", "password", "keychain", "login", "permission", "privacy"]

/// Whether the host may close a covering window of this owner on B's request (protocol v13): a
/// notification banner, or an ordinary window of a regular app. Never a system security, login,
/// permission or password prompt, and never an owner without a bundle id.
public func coverDismissable(bundleID: String?, regular: Bool) -> Bool {
    guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
    if protectedCovers.contains(id) || protectedWords.contains(where: id.contains) { return false }
    if id == "com.apple.notificationcenterui" { return true }
    return regular
}

/// How soon after this session's input another app's activation is taken for one the input opened.
public let appOpenedWindow: TimeInterval = 2

/// Processes that come to the front without being "an app the click opened".
private let notOpenedApps: Set<String> = [
    "com.rapp.rapp", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
    "com.apple.securityagent", "com.apple.notificationcenterui", "com.apple.controlcenter",
    "com.apple.spotlight", "com.apple.coreservices.uiagent", "com.apple.windowmanager",
]

/// Whether an activation is worth an `appOpened` (protocol v13): another regular app (not the session's,
/// not rapp's own process, not a system agent) came to the front within `appOpenedWindow` of this
/// session's last input (`sinceInput`, nil when there was none).
public func appOpenedWorthTelling(bundleID: String?, pid: Int32, regular: Bool, sessionPID: Int32, ownPID: Int32,
                                  sinceInput: TimeInterval?) -> Bool {
    guard regular, pid != sessionPID, pid != ownPID, let id = bundleID, !id.isEmpty,
          !notOpenedApps.contains(id.lowercased()) else { return false }
    guard let since = sinceInput, since >= 0, since <= appOpenedWindow else { return false }
    return true
}

/// Whether a focused element is a password field. Only its role and subrole are looked at, never its
/// contents (see FocusReader's privacy rule).
public func isSecureField(role: String?, subrole: String?) -> Bool {
    subrole == "AXSecureTextField"
}

extension Message {
    /// Input that may open another app on A (a click on a link, a typed shortcut, Return): the clock for
    /// `appOpened` starts from it. Hovering, dragging and scrolling never do.
    public var opensThings: Bool {
        switch self {
        case .text: return true
        case let .key(_, _, down): return down
        case let .mouse(kind, _, _, _, _, _): return kind == .down || kind == .up
        default: return false
        }
    }
}
