import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import RappCore
import ScreenCaptureKit

let windowLookupTimeoutText =
    "timed out asking macOS for windows (check the Screen Recording permission, and look for a permission prompt on A)"

struct HostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// What `WindowCapture.find` located: the app, its largest window, and the
/// display (canvas) that holds the window's center.
struct FoundApp {
    let app: NSRunningApplication
    let scApp: SCRunningApplication
    let window: SCWindow
    let display: SCDisplay
}

/// Captures every window of one app on one display with ScreenCaptureKit
/// (multi-window spec §3.1). Only the capture region of the display is
/// streamed; each frame says which region it shows.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// The canvas display in global points (top-left origin).
    let displayFrame: CGRect

    private let onFrame: (CVPixelBuffer, CanvasRect) -> Void
    private let onStopped: (String) -> Void
    private let filter: SCContentFilter
    private let sampleQueue = DispatchQueue(label: "rapp.capture")
    private let lock = NSLock()
    private var stream: SCStream?
    private var configuredRegion: CanvasRect
    /// Frames per second (30, 15, 5 or 1) and capture pixels per point, as the client asked.
    private var configuredFps: Int
    private var configuredDensity: Double
    private var stoppedByUs = false
    /// Serializes every updateConfiguration call; each one applies the
    /// configuration wanted at that moment.
    private let updates = UpdateGate()

    /// Finds the app's largest normal on-screen window. Launches the app if it
    /// is not running; if it runs but shows no window (closed windows are often
    /// only hidden), asks it once to reopen. Gives up after 10 seconds in all,
    /// including any ScreenCaptureKit call that never returns.
    static func find(bundleID: String) async throws -> FoundApp {
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if running == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw HostError("no app with bundle id \(bundleID) is installed")
            }
            running = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        guard let app = running else { throw HostError("could not start \(bundleID)") }
        app.activate()

        let deadline = Date().addingTimeInterval(10)
        var askedToReopen = false
        repeat {
            let content: SCShareableContent
            do {
                content = try await withTimeout(seconds: max(0.1, deadline.timeIntervalSinceNow)) {
                    try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                }
            } catch is TimeoutError {
                throw HostError(windowLookupTimeoutText)
            }
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == app.processIdentifier
                    && $0.windowLayer == 0 && $0.frame.width >= 50 && $0.frame.height >= 50
            }
            if let best = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
               let scApp = best.owningApplication {
                let center = CGPoint(x: best.frame.midX, y: best.frame.midY)
                guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first
                else { throw HostError("macOS reports no display") }
                return FoundApp(app: app, scApp: scApp, window: best, display: display)
            }
            if !askedToReopen, let url = app.bundleURL {
                askedToReopen = true
                // Same as `open -b <bundle-id>`: a running app gets a reopen event.
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
        throw HostError("\(bundleID) has no window on screen (open one, and make sure it is not minimized)")
    }

    init(found: FoundApp, region: CanvasRect, fps: Int, density: Double,
         onFrame: @escaping (CVPixelBuffer, CanvasRect) -> Void, onStopped: @escaping (String) -> Void) {
        self.displayFrame = found.display.frame
        self.configuredRegion = region
        self.configuredFps = fps
        self.configuredDensity = density
        self.onFrame = onFrame
        self.onStopped = onStopped
        self.filter = SCContentFilter(display: found.display, including: [found.scApp], exceptingWindows: [])
        super.init()
    }

    private func makeConfiguration(region: CanvasRect, fps: Int, density: Double) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: CGFloat(region.x), y: CGFloat(region.y),
                                   width: CGFloat(region.w), height: CGFloat(region.h))
        // Never ask for more pixels than the display really has.
        let factor = min(CGFloat(density), CGFloat(filter.pointPixelScale))
        config.width = max(1, Int((CGFloat(region.w) * factor).rounded()))
        config.height = max(1, Int((CGFloat(region.h) * factor).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        return config
    }

    func start() async throws {
        let (region, fps, density) = lock.withLock { (configuredRegion, configuredFps, configuredDensity) }
        let stream = SCStream(filter: filter, configuration: makeConfiguration(region: region, fps: fps, density: density),
                              delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
        // Changes asked for while starting are applied now. If stop() ran
        // meanwhile it could not reach this stream, so stop it here.
        guard await updates.open({ [weak self] in await self?.applyConfiguration() }) else {
            lock.withLock { self.stream = nil }
            try? await stream.stopCapture()
            throw HostError("capture was stopped while starting")
        }
    }

    func stop() {
        updates.close()
        let active: SCStream? = lock.withLock {
            defer { stream = nil }
            stoppedByUs = true
            return stream
        }
        active?.stopCapture { _ in }
    }

    /// Captures `region` (canvas points) from now on. Safe to call before `start()`.
    func setRegion(_ region: CanvasRect) async {
        let changed: Bool = lock.withLock {
            guard region != configuredRegion else { return false }
            configuredRegion = region
            return true
        }
        if changed { await updates.request() }
    }

    /// Switches the frame rate and the capture pixels per point (never more
    /// than the display has). Safe to call before `start()`: it is applied then.
    func setStream(fps: Int, density: Double) async {
        let changed: Bool = lock.withLock {
            guard fps != configuredFps || density != configuredDensity else { return false }
            configuredFps = fps
            configuredDensity = density
            return true
        }
        if changed { await updates.request() }
    }

    /// Run only through `updates`, so never twice at once.
    private func applyConfiguration() async {
        let current: (SCStream, CanvasRect, Int, Double)? = lock.withLock {
            stream.map { ($0, configuredRegion, configuredFps, configuredDensity) }
        }
        guard let (active, region, fps, density) = current else { return }
        try? await active.updateConfiguration(makeConfiguration(region: region, fps: fps, density: density))
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        // The region this frame shows, in global points (Task 1 probe); a
        // frame without it cannot be placed, so it is dropped (spec §3.2).
        guard let raw = info[.screenRect], CFGetTypeID(raw as CFTypeRef) == CFDictionaryGetTypeID(),
              let screen = CGRect(dictionaryRepresentation: raw as! CFDictionary),
              screen.width > 0, screen.height > 0 else { return }
        let region = CanvasRect(x: Float(screen.minX - displayFrame.minX), y: Float(screen.minY - displayFrame.minY),
                                w: Float(screen.width), h: Float(screen.height))
        onFrame(pixelBuffer, region)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let expected = lock.withLock { stoppedByUs }
        if !expected { onStopped(error.localizedDescription) }
    }
}
