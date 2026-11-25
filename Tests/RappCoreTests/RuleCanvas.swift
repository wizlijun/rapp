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
    /// at its right, and three dots on the sidebar's right side. All numbers follow the brief, except the
    /// sidebar colours: (240) and (32) sit within 16 of the main column and would never pass `regionContrast`.
    static func chatWindow(width: Int = 800, height: Int = 600, sidebar: Bool = true, dark: Bool = false) -> RuleImage {
        let side: RGB = dark ? (36, 36, 36) : (232, 232, 232)
        let main: RGB = dark ? (18, 18, 18) : (255, 255, 255)
        let box: RGB = dark ? (26, 26, 26) : (244, 244, 244)
        let ink: RGB = dark ? (240, 240, 240) : (0, 0, 0)
        let paper: RGB = dark ? (18, 18, 18) : (255, 255, 255)
        var img = solid(width: width, height: height, main)
        let left = sidebar ? 240 : 0
        if sidebar {
            fill(&img, RuleRect(x: 0, y: 0, w: 240, h: height), side)
            for y in [100, 140, 180] { disc(&img, x: 210, y: y, size: 12, ink) }
        }
        fill(&img, RuleRect(x: left + 20, y: 500, w: width - left - 40, h: 80), box)
        disc(&img, x: width - 60, y: 520, size: 32, ink)
        fill(&img, RuleRect(x: width - 50, y: 530, w: 12, h: 12), paper)
        return img
    }
}
