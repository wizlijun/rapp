import CoreGraphics

/// A strip of 18 cells drawn at the content origin of the test page, read back
/// from decoded pixels by the measurement scripts. Cell 0 is black and cell 1
/// white (sync); cells 2...17 are bits 15...0 of the frame number, black = 1.
public enum FrameMark {
    public static let cellCount = 18
    public static let cellPoints: CGFloat = 24
    public static let origin = CGPoint(x: 12, y: 12)

    /// true = black.
    public static func cells(_ n: UInt16) -> [Bool] {
        var c = [true, false]
        for bit in stride(from: 15, through: 0, by: -1) { c.append((n >> UInt16(bit)) & 1 == 1) }
        return c
    }

    /// `luma(i)` is the mean luma of the centre of cell i. Returns nil unless
    /// the sync cells read black, white. Below 128 counts as black.
    public static func read(luma: (Int) -> UInt8) -> UInt16? {
        guard luma(0) < 128, luma(1) >= 128 else { return nil }
        var n: UInt16 = 0
        for i in 2..<cellCount { n = (n << 1) | (luma(i) < 128 ? 1 : 0) }
        return n
    }
}
