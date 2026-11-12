import CoreGraphics
import CoreVideo
import Foundation
import RappCore

/// The latest decoded picture of every A window, each in an IOSurface-backed
/// pixel buffer drawn from a pool sized to the window's crop. Frames are
/// expanded straight into the buffers: no intermediate image.
public final class WindowSurfaces {
    private struct Slot {
        var pool: CVPixelBufferPool
        var width: Int
        var height: Int
        var latest: CVPixelBuffer?
        var visible: CGRect?
    }

    private let lock = NSLock()
    private var slots = [UInt32: Slot]()

    /// How many pools were ever created (for tests).
    public private(set) var poolsCreated = 0

    public init() {}

    /// Expands each table window's part of `decoder`'s canvas (a frame covering `region`) into a
    /// buffer of its own and makes it the window's latest. Returns the ids updated. Windows with
    /// nothing in the region keep what they had.
    public func draw(table: [WindowInfo], decoder: FrameDecoder, region: CanvasRect) throws -> [UInt32] {
        var updated = [UInt32]()
        for info in table {
            guard let crop = cropRect(window: info, region: region, pixelWidth: decoder.width, pixelHeight: decoder.height),
                  let visible = visiblePart(window: info, region: region) else { continue }
            let w = Int(crop.width), h = Int(crop.height)
            let pool = try poolFor(info.id, width: w, height: h)
            var made: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
                throw SurfaceError.noBuffer
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            do {
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SurfaceError.noBuffer }
                try Quantizer.expand(samples: decoder.samples, width: decoder.width, height: decoder.height, mode: decoder.mode,
                                     rect: (x: Int(crop.minX), y: Int(crop.minY), w: w, h: h),
                                     into: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
            } catch {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw error
            }
            // Unlocked before it is published: readers never see a CPU-locked buffer.
            CVPixelBufferUnlockBaseAddress(buffer, [])
            lock.lock()
            slots[info.id]?.latest = buffer
            slots[info.id]?.visible = visible
            lock.unlock()
            updated.append(info.id)
        }
        return updated
    }

    public func latest(_ id: UInt32) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return slots[id]?.latest
    }

    /// The part of the window's content the latest buffer shows, 0...1 from the top-left.
    public func visible(_ id: UInt32) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return slots[id]?.visible
    }

    /// Drops every window not in `ids`; returns the ids dropped.
    public func keep(only ids: Set<UInt32>) -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        let gone = slots.keys.filter { !ids.contains($0) }.sorted()
        for id in gone { slots[id] = nil }
        return gone
    }

    private func poolFor(_ id: UInt32, width: Int, height: Int) throws -> CVPixelBufferPool {
        lock.lock()
        if let slot = slots[id], slot.width == width, slot.height == height {
            lock.unlock()
            return slot.pool
        }
        lock.unlock()
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolOptions: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
        var made: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolOptions as CFDictionary, attributes as CFDictionary, &made) == kCVReturnSuccess,
              let pool = made else { throw SurfaceError.noPool }
        lock.lock(); defer { lock.unlock() }
        poolsCreated += 1
        var slot = slots[id].map { old in
            Slot(pool: pool, width: width, height: height, latest: old.latest, visible: old.visible)
        } ?? Slot(pool: pool, width: width, height: height, latest: nil, visible: nil)
        slot.pool = pool
        slots[id] = slot
        return pool
    }
}

public enum SurfaceError: Error, Equatable {
    case noPool
    case noBuffer
}
