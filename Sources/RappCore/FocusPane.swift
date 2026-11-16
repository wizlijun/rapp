import CoreGraphics

public enum PanelMiss: String, Error, Equatable { case small, large, blocked }

public struct PanelPick: Equatable {
    public let rect: CGRect
    public let depth: Int
    public let share: Double
    public init(rect: CGRect, depth: Int, share: Double) { self.rect = rect; self.depth = depth; self.share = share }
}

/// What the encoder sent in one frame, in pixels of the encoded region.
public struct EncodeReport: Equatable {
    public let region: CanvasRect
    public let width: Int
    public let height: Int
    /// Whole frame encoded, or the frame size changed.
    public let full: Bool
    /// Tile indexes ty*cols+tx sent this frame (any kind, copies too).
    public let changed: [Int]
    /// Pixels; bounding box of this frame's copy tiles.
    public let copyBounds: CGRect?
    public init(region: CanvasRect, width: Int, height: Int, full: Bool, changed: [Int], copyBounds: CGRect?) {
        self.region = region; self.width = width; self.height = height
        self.full = full; self.changed = changed; self.copyBounds = copyBounds
    }
}

public struct WindowTiles: Equatable {
    /// Window points; a tile belongs to the window when its centre is inside.
    public let changed: [CGRect]
    /// Tiles whose centre is inside the window.
    public let total: Int
    /// Window points, intersected with the window.
    public let copyBounds: CGRect?
    public let full: Bool
    public init(changed: [CGRect], total: Int, copyBounds: CGRect?, full: Bool) {
        self.changed = changed; self.total = total; self.copyBounds = copyBounds; self.full = full
    }
}

public enum FocusPane {
    public static let maxDepth = 40, minShare = 0.15, maxShare = 0.85
    public static let minWidth: CGFloat = 240, minHeight: CGFloat = 160

    /// Rule 2: pick the panel containing the focused control.
    /// `chain`: rects in window points, the start control first, then each parent (the window may be last).
    /// Only the first 40 layers are looked at. Each layer is intersected with (0,0,window) first.
    /// Among layers with share < 0.85 the largest wins (ties: the outer layer). No such layer -> `.large`.
    /// The pick is `.small` if share < 0.15, width < 240 or height < 160. An empty chain is `.small`.
    /// `depth` is the index of the picked layer in `chain`.
    public static func panel(chain: [CGRect], window: CGSize) -> Result<PanelPick, PanelMiss> {
        if chain.isEmpty { return .failure(.small) }
        let bounds = CGRect(origin: .zero, size: window)
        let area = Double(window.width * window.height)
        guard area > 0 else { return .failure(.small) }
        var best: PanelPick?
        for (i, raw) in chain.prefix(maxDepth).enumerated() {
            let r = raw.intersection(bounds)
            let share = r.isNull ? 0 : Double(r.width * r.height) / area
            if share >= maxShare { continue }
            if best == nil || share >= best!.share {
                best = PanelPick(rect: r.isNull ? .zero : r, depth: i, share: share)
            }
        }
        guard let p = best else { return .failure(.large) }
        if p.share < minShare || p.rect.width < minWidth || p.rect.height < minHeight { return .failure(.small) }
        return .success(p)
    }

    /// Global AX rect -> window points (title bar included, like `mouse`).
    public static func windowRect(global: CGRect, display: CGRect, window: CanvasRect) -> CGRect {
        CGRect(x: global.minX - display.minX - CGFloat(window.x),
               y: global.minY - display.minY - CGFloat(window.y),
               width: global.width, height: global.height)
    }

    public static func windowTiles(_ r: EncodeReport, window: CanvasRect) -> WindowTiles {
        let full = r.full
        guard r.width > 0, r.height > 0, r.region.w > 0, r.region.h > 0 else {
            return WindowTiles(changed: [], total: 0, copyBounds: nil, full: full)
        }
        let sx = CGFloat(r.width) / CGFloat(r.region.w), sy = CGFloat(r.height) / CGFloat(r.region.h)
        let ox = CGFloat(r.region.x) - CGFloat(window.x), oy = CGFloat(r.region.y) - CGFloat(window.y)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(window.w), height: CGFloat(window.h))
        let cols = (r.width + tileSize - 1) / tileSize, rows = (r.height + tileSize - 1) / tileSize
        func tileRect(_ tx: Int, _ ty: Int) -> CGRect {
            let x0 = tx * tileSize, y0 = ty * tileSize
            let tw = min(tileSize, r.width - x0), th = min(tileSize, r.height - y0)
            return CGRect(x: ox + CGFloat(x0) / sx, y: oy + CGFloat(y0) / sy,
                          width: CGFloat(tw) / sx, height: CGFloat(th) / sy)
        }
        func inside(_ t: CGRect) -> Bool { bounds.contains(CGPoint(x: t.midX, y: t.midY)) }
        var total = 0
        for ty in 0..<rows { for tx in 0..<cols where inside(tileRect(tx, ty)) { total += 1 } }
        var changed: [CGRect] = []
        for i in r.changed where i >= 0 && i < cols * rows {
            let t = tileRect(i % cols, i / cols)
            if inside(t) { changed.append(t) }
        }
        var cb: CGRect?
        if let c = r.copyBounds {
            let w = CGRect(x: ox + c.minX / sx, y: oy + c.minY / sy, width: c.width / sx, height: c.height / sy)
            let i = w.intersection(bounds)
            if !i.isNull && i.width > 0 && i.height > 0 { cb = i }
        }
        return WindowTiles(changed: changed, total: total, copyBounds: cb, full: full)
    }
}
