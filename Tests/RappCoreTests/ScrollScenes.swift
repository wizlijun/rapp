import RappCore

/// One captured frame of a scene: tightly packed BGRA pixels (one pixel per
/// point) and the captured region in screen points.
struct SceneFrame {
    var bgra: [UInt8]
    var width: Int
    var height: Int
    var region: CanvasRect
}

/// What changes from one scene frame to the next.
enum SceneKind {
    enum Edge: CaseIterable { case left, right, top, bottom }
    /// The document moves up one 16 px text line; a new line appears at the bottom.
    case terminalScroll
    /// The document moves up 37 px under a fixed top bar and side bar (in px).
    case webScroll(topBar: Int, sideBar: Int)
    /// One edge of the captured region moves out or in by 1...40 px.
    case resize(edge: Edge)
    /// The captured region moves by up to ±50 px each way; its size stays.
    case regionMove
    /// A few text cells of the document change in place.
    case localChange
}

/// Deterministic scenes for codec tests: a "browser window" fixed on the
/// screen (top bar, side bar, a scrolling text document) on a blocky desktop.
/// Content is anchored to the screen, so moving or resizing the captured
/// region moves the picture by exactly the region offset. Uses its own 64-bit
/// LCG, never the system random generator.
enum ScrollScenes {
    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
    }

    /// A stateless 64-bit mix, used to derive the content from positions.
    private static func hash(_ a: Int, _ b: Int, _ c: UInt64 = 0) -> UInt64 {
        var z = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
        z ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
        z ^= c &* 0x1656_67B1_9E37_79F9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private struct World {
        var winX: Int, winY: Int          // top left of the browser window on the screen
        var topBar = 0, sideBar = 0
        var scroll = 0                     // document y shown at the top of the window
        var edits = [Int: UInt64]()        // (line << 16 | cell) -> salt, from local changes

        /// BGRA of screen point (sx, sy).
        func pixel(_ sx: Int, _ sy: Int) -> (UInt8, UInt8, UInt8) {
            let wx = sx - winX, wy = sy - winY
            if wx < 0 || wy < 0 {
                // Desktop: 32 px blocks of muted colours.
                let h = hash(sx >> 5, sy >> 5, 1)
                return (UInt8(80 + h & 63), UInt8(90 + (h >> 8) & 63), UInt8(100 + (h >> 16) & 63))
            }
            if wy < topBar {
                // Light grey bar with darker "buttons" every 40 px.
                let button = wx % 40 >= 8 && wx % 40 < 32 && wy >= 8 && wy < topBar - 8
                return button ? (150, 150, 150) : (230, 230, 230)
            }
            if wx < sideBar {
                // Dark side bar with its own fixed text.
                return text(wx, wy, salt: 2, bg: (60, 50, 40), fg: (220, 220, 220))
            }
            return text(wx - sideBar, wy + scroll, salt: 3, bg: (255, 255, 255), fg: nil)
        }

        /// A text page: 16 px lines of 8 px cells, some lines blank, glyph
        /// rows 3...12 with an anti-aliased (blended) right edge.
        func text(_ x: Int, _ y: Int, salt: UInt64, bg: (UInt8, UInt8, UInt8),
                  fg: (UInt8, UInt8, UInt8)?) -> (UInt8, UInt8, UInt8) {
            let line = y >> 4, row = y & 15, cell = x >> 3, col = x & 7
            let lh = hash(line, -1, salt)
            if lh % 5 == 0 || row < 3 || row > 12 { return bg }
            let edit = edits[line << 16 | (cell & 0xFFFF)] ?? 0
            let g = hash(line, cell, salt &+ edit &* 7)
            if g % 7 == 0 { return bg }                    // a space
            let bits = UInt8(truncatingIfNeeded: g >> UInt64((row - 3) * 6))
            let color = fg ?? (UInt8(lh >> 8 & 0x7F), UInt8(lh >> 16 & 0x7F), UInt8(lh >> 24 & 0x7F))
            if col < 6 && bits & (1 << UInt8(col)) != 0 { return color }
            if col == 6 && bits & 0x20 != 0 {
                return (UInt8((Int(color.0) + Int(bg.0)) / 2), UInt8((Int(color.1) + Int(bg.1)) / 2),
                        UInt8((Int(color.2) + Int(bg.2)) / 2))
            }
            return bg
        }
    }

    /// `count` frames; the first is the starting picture and every later one
    /// applies one kind picked from `kinds` (by the generator, so a single kind
    /// repeats). The same seed and kinds give the same frames.
    static func frames(seed: UInt64, count: Int, kinds: [SceneKind]) -> [SceneFrame] {
        precondition(!kinds.isEmpty, "no scene kinds")
        var rng = LCG(seed: seed)
        var x = rng.int(0...200), y = rng.int(0...200)
        var w = rng.int(100...220), h = rng.int(70...160)
        var world = World(winX: x + rng.int(0...20), winY: y + rng.int(0...20))
        for case let .webScroll(top, side) in kinds {
            world.topBar = top
            world.sideBar = side
            break
        }
        var out = [SceneFrame]()
        out.reserveCapacity(count)
        for i in 0..<count {
            if i > 0 {
                switch kinds[Int(rng.next() % UInt64(kinds.count))] {
                case .terminalScroll:
                    world.scroll += 16
                case .webScroll:
                    world.scroll += 37
                case .resize(let edge):
                    let grow = rng.next() & 1 == 0
                    let n = rng.int(1...40) * (grow ? 1 : -1)
                    switch edge {
                    case .left: let v = min(max(w + n, 64), 320); x -= v - w; w = v
                    case .right: w = min(max(w + n, 64), 320)
                    case .top: let v = min(max(h + n, 64), 240); y -= v - h; h = v
                    case .bottom: h = min(max(h + n, 64), 240)
                    }
                case .regionMove:
                    x += rng.int(-50...50)
                    y += rng.int(-50...50)
                case .localChange:
                    for _ in 0..<rng.int(1...5) {
                        let line = (world.scroll + y - world.winY + rng.int(0...max(0, h - 1))) >> 4
                        let cell = (x - world.winX - world.sideBar + rng.int(0...max(0, w - 1))) >> 3
                        world.edits[line << 16 | (cell & 0xFFFF), default: 0] &+= rng.next() | 1
                    }
                }
            }
            var bgra = [UInt8](repeating: 255, count: w * h * 4)
            for py in 0..<h {
                for px in 0..<w {
                    let (b, g, r) = world.pixel(x + px, y + py)
                    let o = (py * w + px) * 4
                    bgra[o] = b
                    bgra[o + 1] = g
                    bgra[o + 2] = r
                }
            }
            out.append(SceneFrame(bgra: bgra, width: w, height: h,
                                  region: CanvasRect(x: Float(x), y: Float(y), w: Float(w), h: Float(h))))
        }
        return out
    }

    /// The frame's samples for `mode`, as the host quantizes a capture.
    static func samples(_ frame: SceneFrame, mode: Mode) -> [UInt8] {
        frame.bgra.withUnsafeBytes {
            Quantizer.quantize(bgra: $0, width: frame.width, height: frame.height,
                               bytesPerRow: frame.width * 4, mode: mode)
        }
    }
}
