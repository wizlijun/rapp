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

/// Captures the pixels of one window with ScreenCaptureKit.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let window: SCWindow

    private let onFrame: (CVPixelBuffer) -> Void
    private let onStopped: (String) -> Void
    private let filter: SCContentFilter
    private let sampleQueue = DispatchQueue(label: "rapp.capture")
    private let lock = NSLock()
    private var stream: SCStream?
    private let pid: pid_t
    private var configuredSize = CGSize.zero
    private var configuredTitleRow: CGFloat = 0
    /// Frames per second (15 or 5) and capture pixels per point, as the client asked.
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
    static func find(bundleID: String) async throws -> (window: SCWindow, app: NSRunningApplication) {
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
            if let best = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return (best, app)
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

    init(window: SCWindow, fps: Int, density: Double,
         onFrame: @escaping (CVPixelBuffer) -> Void, onStopped: @escaping (String) -> Void) {
        self.window = window
        self.configuredFps = fps
        self.configuredDensity = density
        self.pid = window.owningApplication?.processID ?? 0
        self.onFrame = onFrame
        self.onStopped = onStopped
        self.filter = SCContentFilter(desktopIndependentWindow: window)
        super.init()
        // Measured now so the content area is known before capture starts.
        if let frame = currentFrame {
            configuredSize = frame.size
            configuredTitleRow = measureTitleRow(frame)
        }
    }

    /// The window's current frame in global screen coordinates (origin at the
    /// top-left of the main display), or nil once the window is gone.
    var currentFrame: CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], window.windowID) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return rect
    }

    /// Height of the title row being cut off, in points.
    var titleRow: CGFloat { lock.withLock { configuredTitleRow } }

    /// The captured part of the window (below the title row), global coordinates.
    var contentFrame: CGRect? {
        guard let frame = currentFrame else { return nil }
        return contentRect(windowFrame: frame, titleRow: titleRow)
    }

    private func measureTitleRow(_ frame: CGRect) -> CGFloat {
        pid == 0 ? 0 : WindowResizer.titleRowHeight(pid: pid, currentFrame: frame)
    }

    private func makeConfiguration(windowSize size: CGSize, titleRow: CGFloat, fps: Int, density: Double) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let content = CGSize(width: size.width, height: max(1, size.height - titleRow))
        config.sourceRect = CGRect(x: 0, y: titleRow, width: size.width, height: content.height)
        // Never ask for more pixels than the window really has.
        let factor = min(CGFloat(density), CGFloat(filter.pointPixelScale))
        config.width = max(1, Int((content.width * factor).rounded()))
        config.height = max(1, Int((content.height * factor).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        return config
    }

    func start() async throws {
        guard currentFrame != nil else { throw HostError("the window was closed") }
        // Uses the size and title row measured in init, which Ready announced;
        // any change since is picked up by the next refreshIfNeeded().
        let (size, row, fps, density) = lock.withLock { (configuredSize, configuredTitleRow, configuredFps, configuredDensity) }
        let stream = SCStream(filter: filter,
                              configuration: makeConfiguration(windowSize: size, titleRow: row, fps: fps, density: density),
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

    /// Re-targets the stream when the window's size or title row has changed.
    /// Returns true if it did.
    func refreshIfNeeded() async -> Bool {
        guard let frame = currentFrame else { return false }
        let row = measureTitleRow(frame)
        let changed: Bool = lock.withLock {
            guard stream != nil,
                  abs(frame.width - configuredSize.width) >= 0.5 || abs(frame.height - configuredSize.height) >= 0.5
                    || row != configuredTitleRow
            else { return false }
            configuredSize = frame.size
            configuredTitleRow = row
            return true
        }
        guard changed else { return false }
        await updates.request()
        return true
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
        let current: (SCStream, CGSize, CGFloat, Int, Double)? = lock.withLock {
            stream.map { ($0, configuredSize, configuredTitleRow, configuredFps, configuredDensity) }
        }
        guard let (active, size, row, fps, density) = current else { return }
        try? await active.updateConfiguration(makeConfiguration(windowSize: size, titleRow: row, fps: fps, density: density))
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame(pixelBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let expected = lock.withLock { stoppedByUs }
        if !expected { onStopped(error.localizedDescription) }
    }
}
