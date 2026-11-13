import AppKit
import RappCore

// Test windows for the measurement scripts: --clip [--marks PATH], --reading, --editor PATH.
// Every window is 1280x720 pt, titled, with a flipped content view; clip and reading draw the frame mark at its origin (editor has none).

let args = CommandLine.arguments
func argValue(of flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func drawMark(_ n: UInt16) {
    let cells = FrameMark.cells(n)
    let s = FrameMark.cellPoints
    NSColor.white.setFill()
    NSRect(x: FrameMark.origin.x - 4, y: FrameMark.origin.y - 4, width: s * CGFloat(cells.count) + 8, height: s + 8).fill()
    NSColor.black.setFill()
    for (i, black) in cells.enumerated() where black {
        NSRect(x: FrameMark.origin.x + s * CGFloat(i), y: FrameMark.origin.y, width: s, height: s).fill()
    }
}

/// Appends 10-byte records (u16 frame LE + u64 uptime ns LE). Each record goes straight to the
/// file with write(2), so nothing is lost when the app is killed.
final class MarksWriter {
    private let fd: Int32
    init?(path: String) {
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 { return nil }
    }
    func record(frame: UInt16, at ns: UInt64) {
        var rec = Data(capacity: 10)
        withUnsafeBytes(of: frame.littleEndian) { rec.append(contentsOf: $0) }
        withUnsafeBytes(of: ns.littleEndian) { rec.append(contentsOf: $0) }
        let n = rec.withUnsafeBytes { write(fd, $0.baseAddress, 10) }
        if n != 10 { FileHandle.standardError.write(Data("marks write failed (errno \(errno))\n".utf8)) }
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

final class ClipView: FlippedView {
    var frame16: UInt16 = 0
    var lineX: CGFloat = 0
    var step: CGFloat = 4
    var marks: MarksWriter?
    private var link: CADisplayLink?

    func start() {
        let l = displayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc func tick() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        drawMark(frame16)
        marks?.record(frame: frame16, at: uptimeNs())
        NSColor.black.setFill()
        NSRect(x: lineX, y: 60, width: 4, height: bounds.height - 60).fill()
        frame16 &+= 1
        lineX += step
        if lineX + 4 >= bounds.width { lineX = bounds.width - 4; step = -4 }
        else if lineX <= 0 { lineX = 0; step = 4 }
    }
}

final class ReadingView: FlippedView {
    var page = 0
    let lines = (1...400).map { "第 \($0) 行 这是用来测试翻页和文字清晰度的一段中文文字，包含标点、数字 0123456789。" }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 121 { page += 1; needsDisplay = true } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        drawMark(UInt16(truncatingIfNeeded: page))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
        let perPage = 30
        let start = (page * perPage) % lines.count
        for i in 0..<perPage {
            let line = lines[(start + i) % lines.count]
            (line as NSString).draw(at: NSPoint(x: 12, y: 60 + CGFloat(i) * 21), withAttributes: attrs)
        }
    }
}

final class EditorDelegate: NSObject, NSTextViewDelegate {
    let path: String
    init(path: String) { self.path = path }
    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        let tmp = path + ".tmp"
        do {
            try tv.string.write(toFile: tmp, atomically: false, encoding: .utf8)
            if rename(tmp, path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch { FileHandle.standardError.write(Data("write failed: \(error)\n".utf8)) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var keep: AnyObject?
    func applicationDidFinishLaunching(_ n: Notification) {
        let size = NSSize(width: 1280, height: 720)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if args.contains("--reading") {
            let v = ReadingView(frame: NSRect(origin: .zero, size: size))
            window.contentView = v; window.title = "RappTestPage reading"
            window.makeFirstResponder(v)
        } else if let path = argValue(of: "--editor") {
            let v = FlippedView(frame: NSRect(origin: .zero, size: size))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 60, width: size.width, height: size.height - 60))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let tv = NSTextView(frame: scroll.bounds)
            tv.autoresizingMask = [.width]
            tv.isRichText = false
            tv.font = NSFont.systemFont(ofSize: 14)
            tv.isVerticallyResizable = true
            let d = EditorDelegate(path: path); keep = d
            tv.delegate = d
            scroll.documentView = tv
            v.addSubview(scroll)
            window.contentView = v; window.title = "RappTestPage editor"
            window.makeFirstResponder(tv)
            // Test hook: --type TEXT inserts text as if typed, so the write path can be checked unattended.
            if let t = argValue(of: "--type") { tv.insertText(t, replacementRange: NSRange(location: 0, length: 0)) }
        } else {
            let v = ClipView(frame: NSRect(origin: .zero, size: size))
            if let p = argValue(of: "--marks") {
                guard let w = MarksWriter(path: p) else {
                    FileHandle.standardError.write(Data("cannot open marks file \(p)\n".utf8))
                    exit(1)
                }
                v.marks = w
            }
            window.contentView = v; window.title = "RappTestPage clip"
            v.start()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// The host pastes with a synthesized Cmd-V, which a text view only answers through a menu key equivalent.
let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
appItem.submenu = NSMenu(title: "RappTestPage")
let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
app.mainMenu = mainMenu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
