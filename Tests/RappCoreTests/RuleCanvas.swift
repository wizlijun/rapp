import Foundation
@testable import RappCore

/// Synthetic frames for the rule tests. Tasks 5 and 7 add more scenes here.
enum Canvas {
    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    static func solid(width: Int, height: Int, _ c: RGB = (255, 255, 255)) -> RuleImage {
        var img = RuleImage(width: width, height: height, pixels: [UInt8](repeating: 255, count: width * height * 4))
        fill(&img, RuleRect(x: 0, y: 0, w: width, h: height), c)
        return img
    }

    static func fill(_ img: inout RuleImage, _ r: RuleRect, _ c: RGB) {
        for y in max(0, r.y)..<min(img.height, r.maxY) {
            for x in max(0, r.x)..<min(img.width, r.maxX) {
                let i = (y * img.width + x) * 4
                img.pixels[i] = c.b; img.pixels[i + 1] = c.g; img.pixels[i + 2] = c.r; img.pixels[i + 3] = 255
            }
        }
    }

    /// A disc that exactly fills the `size` x `size` square at (x, y).
    static func disc(_ img: inout RuleImage, x: Int, y: Int, size: Int, _ c: RGB) {
        let r = Double(size) / 2
        for py in 0..<size {
            for px in 0..<size {
                let dx = Double(px) + 0.5 - r, dy = Double(py) + 0.5 - r
                guard dx * dx + dy * dy < r * r, x + px >= 0, y + py >= 0, x + px < img.width, y + py < img.height else { continue }
                fill(&img, RuleRect(x: x + px, y: y + py, w: 1, h: 1), c)
            }
        }
    }

    /// A ring: the disc minus a smaller disc.
    static func ring(_ img: inout RuleImage, x: Int, y: Int, size: Int, thickness: Int, _ c: RGB, hole: RGB) {
        disc(&img, x: x, y: y, size: size, c)
        disc(&img, x: x + thickness, y: y + thickness, size: size - 2 * thickness, hole)
    }

    /// Sidebar 240 wide (when present), main column, an input box at the bottom, a stop-style button
    /// at its right, and three dots on the sidebar's right side. All numbers follow the brief.
    enum Icon { case square, arrow, none }
    enum Dot { case green, gray }
    static let buttonRect = RuleRect(x: 16, y: 16, w: 32, h: 32)
    static let dotRect = RuleRect(x: 26, y: 26, w: 12, h: 12)
    static let black: RGB = (0, 0, 0), white: RGB = (255, 255, 255)

    /// 64x64 white page, a black 32 disc at `buttonRect` with a white icon in it.
    static func button(icon: Icon) -> RuleImage {
        var img = solid(width: 64, height: 64)
        disc(&img, x: 16, y: 16, size: 32, black)
        switch icon {
        case .square: fill(&img, RuleRect(x: 26, y: 26, w: 12, h: 12), white)
        case .arrow:   // 14x14 up arrow: stem 4 wide, head 14 wide over the top 7 rows
            fill(&img, RuleRect(x: 30, y: 25, w: 4, h: 14), white)
            for row in 0..<7 { fill(&img, RuleRect(x: 32 - (row + 1), y: 25 + row, w: 2 * (row + 1), h: 1), white) }
        case .none: break
        }
        return img
    }
    static func bareSquare() -> RuleImage {
        var img = solid(width: 64, height: 64); fill(&img, buttonRect, black); return img
    }
    static func ring() -> RuleImage {
        var img = solid(width: 64, height: 64); ring(&img, x: 16, y: 16, size: 32, thickness: 6, black, hole: white); return img
    }
    static func dot(color: RGB, on bg: RGB) -> RuleImage {
        var img = solid(width: 64, height: 64, bg); disc(&img, x: 26, y: 26, size: 12, color); return img
    }

    /// `dots == nil`: three black dots (older tests). `spinnerPhase` 1 brightens the dots (they "move");
    /// `tailText` draws a text-like bar in the tail region.
    static func chatWindow(width: Int = 800, height: Int = 600, sidebar: Bool = true, dark: Bool = false,
                           dots: [Dot]? = nil, spinnerPhase: Int = 0, tailText: Bool = false,
                           button: Icon = .square) -> RuleImage {
        let side: RGB = dark ? (32, 32, 32) : (240, 240, 240)
        let main: RGB = dark ? (18, 18, 18) : (255, 255, 255)
        let box: RGB = dark ? (26, 26, 26) : (244, 244, 244)
        let ink: RGB = dark ? (240, 240, 240) : (0, 0, 0)
        let paper: RGB = dark ? (18, 18, 18) : (255, 255, 255)
        var img = solid(width: width, height: height, main)
        let left = sidebar ? 240 : 0
        if sidebar {
            fill(&img, RuleRect(x: 0, y: 0, w: 240, h: height), side)
            let shown: [RGB] = dots.map { $0.map { $0 == .green ? (52, 199, 89) : (150, 150, 150) } } ?? [ink, ink, ink]
            for (i, c) in shown.prefix(3).enumerated() {
                let lift = spinnerPhase == 0 ? 0 : 30
                let c2: RGB = (UInt8(min(255, Int(c.r) + lift)), UInt8(min(255, Int(c.g) + lift)), UInt8(min(255, Int(c.b) + lift)))
                disc(&img, x: 210, y: 100 + 40 * i, size: 12, c2)
            }
        }
        if tailText { fill(&img, RuleRect(x: left + 40, y: 300, w: 200, h: 14), (60, 60, 60)) }
        fill(&img, RuleRect(x: left + 20, y: 500, w: width - left - 40, h: 80), box)
        disc(&img, x: width - 60, y: 520, size: 32, ink)
        let bx = width - 60, by = 520
        switch button {
        case .square: fill(&img, RuleRect(x: width - 50, y: 530, w: 12, h: 12), paper)
        case .arrow:
            fill(&img, RuleRect(x: bx + 14, y: by + 9, w: 4, h: 14), paper)
            for row in 0..<7 { fill(&img, RuleRect(x: bx + 16 - (row + 1), y: by + 9 + row, w: 2 * (row + 1), h: 1), paper) }
        case .none: break
        }
        return img
    }
}
