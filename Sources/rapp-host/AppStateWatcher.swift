import AppKit
import CoreVideo
import Foundation
import RappCore

/// The app's version from `Contents/Info.plist`, read fresh each call (`Bundle` would cache it).
func appVersion(bundleURL: URL?) -> String? {
    guard let url = bundleURL,
          let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
    for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
        if let v = info[key] as? String, !v.isEmpty { return v }
    }
    return nil
}

/// Runs the state rules (spec §5, §7) on the app's main window and sends the inferred state.
/// `offer` is called on the capture queue and stays cheap; the engine lives on `queue`.
final class AppStateWatcher {
    private let app: NSRunningApplication
    private let text: TextReader?
    private let send: (Message) -> Void
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "rapp.state", qos: .utility)

    /// Guards `active`, `window`, `pending` and `lastSample`, which the capture queue touches.
    private let lock = NSLock()
    private var active = false
    private var window: CanvasRect?
    private var pending: RuleImage?
    private var lastSample: TimeInterval = 0

    /// Queue only.
    private var engine: StateEngine?
    private var timer: DispatchSourceTimer?
    private var stopped = false

    private static let interval: TimeInterval = 0.5

    init(app: NSRunningApplication, text: TextReader?, send: @escaping (Message) -> Void, log: @escaping (String) -> Void) {
        self.app = app
        self.text = text
        self.send = send
        self.log = log
    }

    /// "" stops; rules that cannot be read send one invalid report.
    func setRules(_ json: String) {
        queue.async { [self] in
            guard !stopped else { return }
            engine = nil
            timer?.cancel()
            timer = nil
            lock.withLock { active = false; pending = nil }
            guard !json.isEmpty else { return }

            let bundleURL = app.bundleURL
            let version = appVersion(bundleURL: bundleURL)
            var caps: Set<String> = ["pixels"]
            if text != nil { caps.insert("text") }
            let env = RuleEnv(appVersion: version, os: "macos", locale: Locale.preferredLanguages.first ?? "en",
                              caps: caps, rereadVersion: { appVersion(bundleURL: bundleURL) })
            do {
                let engine = try StateEngine(rules: Data(json.utf8), env: env, text: text)
                self.engine = engine
                log("state rules: \(engine.report.pack ?? "-") rev \(engine.report.rev.map(String.init) ?? "-"), app \(version ?? "-")")
            } catch {
                let err = (error as? RuleError) ?? .badJSON
                log("state rules: invalid (\(err))")
                send(.appState(AppStateReport.invalid(err, caps: caps.sorted(), appVersion: version).json()))
                return
            }
            lock.withLock { active = true }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    /// The app's main window in canvas points; nil when there is none.
    func setWindow(_ rect: CanvasRect?) {
        lock.withLock {
            window = rect
            if rect == nil { pending = nil }
        }
    }

    /// Capture queue. Returns at once when no rules are set or the last sample is under 0.5 s old.
    func offer(_ buffer: CVPixelBuffer, region: CanvasRect) {
        let now = uptimeSeconds()
        let win: CanvasRect? = lock.withLock {
            guard active, let window, now - lastSample >= Self.interval else { return nil }
            return window
        }
        guard let win, region.w > 0, region.h > 0 else { return }

        let x0 = max(win.x, region.x), y0 = max(win.y, region.y)
        let x1 = min(win.x + win.w, region.x + region.w), y1 = min(win.y + win.h, region.y + region.h)
        guard x1 > x0, y1 > y0 else { return }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let scale = Double(width) / Double(region.w)
        guard scale.isFinite, scale > 0 else { return }
        let px0 = max(0, Int((Double(x0 - region.x) * scale).rounded(.down)))
        let py0 = max(0, Int((Double(y0 - region.y) * scale).rounded(.down)))
        let px1 = min(width, Int((Double(x1 - region.x) * scale).rounded(.up)))
        let py1 = min(height, Int((Double(y1 - region.y) * scale).rounded(.up)))
        guard px1 > px0, py1 > py0 else { return }
        let crop = RuleRect(x: px0, y: py0, w: px1 - px0, h: py1 - py0)
        let bytes = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        guard let image = RuleImage.sample(bgra: bytes, width: width, height: height, bytesPerRow: bytesPerRow,
                                           crop: crop, scale: scale) else { return }
        lock.withLock {
            guard active, window != nil else { return }
            lastSample = now
            pending = image
        }
    }

    func stop() {
        lock.withLock { active = false; pending = nil; window = nil }
        queue.async { [self] in
            stopped = true
            timer?.cancel()
            timer = nil
            engine = nil
        }
    }

    /// Queue only.
    private func tick() {
        guard let engine, !stopped else { return }
        let (image, visible): (RuleImage?, Bool) = lock.withLock {
            let p = pending
            pending = nil
            return (window == nil ? nil : p, window != nil)
        }
        if let report = engine.tick(image: image, visible: visible, now: uptimeSeconds()) {
            send(.appState(report.json()))
        }
    }
}
