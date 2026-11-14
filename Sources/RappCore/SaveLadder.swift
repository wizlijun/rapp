import Foundation

/// What A streams: mode, frame rate and capture density.
public struct StreamSpec: Equatable {
    public var mode: Mode
    public var fps: Int
    public var density: Float
    public init(mode: Mode, fps: Int, density: Float) {
        self.mode = mode; self.fps = fps; self.density = density
    }
}

/// The automatic traffic-saving ladder (spec 2026-11-14-rapp-network-status §6.2). B's choice is
/// the ceiling (level 0); level 1 caps the frame rate at 5 fps; level 2 is the weak floor (duogray,
/// density at most 1.0) and also caps the frame rate.
public enum SaveLadder {
    static let savingFps = 5
    static let floorMode = Mode.duogray
    static let floorDensity: Float = 1

    public static func stream(level: Int, ceiling: StreamSpec) -> StreamSpec {
        switch level {
        case ..<1:
            return ceiling
        case 1:
            return StreamSpec(mode: ceiling.mode, fps: min(ceiling.fps, savingFps), density: ceiling.density)
        default:
            return StreamSpec(mode: floorMode, fps: min(ceiling.fps, savingFps), density: min(ceiling.density, floorDensity))
        }
    }

    /// The levels below the ceiling that save something over the one above them.
    public static func steps(ceiling: StreamSpec) -> [Int] {
        var out = [Int]()
        var above = ceiling
        for level in 1...2 {
            let s = stream(level: level, ceiling: ceiling)
            if s != above { out.append(level) }
            above = s
        }
        return out
    }
}

extension Message {
    /// The user operating A: B probes the path faster for a while after it (`PathProbe.input`).
    public var isUserInput: Bool {
        switch self {
        case .text, .key, .mouse, .scroll, .paste, .menuPick: return true
        default: return false
        }
    }
}
