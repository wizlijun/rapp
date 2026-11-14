import Foundation

/// Protocol v9. The host and client must both speak exactly this version; frame messages carry
/// per-tile flags (see TileCodec for the frame format).
public let protocolVersion: UInt8 = 9

/// A client's `Hello` carried a different protocol version than this build speaks.
public struct ProtocolVersionMismatch: Error, CustomStringConvertible {
    public let client: UInt8
    public init(client: UInt8) { self.client = client }
    public var description: String {
        "protocol version mismatch: host \(protocolVersion), client \(client) (update both sides)"
    }
}
public let defaultPort: UInt16 = 47800
/// Upper bound for one message's payload; anything larger is treated as garbage.
public let maxMessageLength = 64 * 1024 * 1024

/// Frame rates a client may ask for.
public let allowedFps: Set<UInt8> = [30, 15, 5, 1]

/// A capture density (pixels per A point) is finite and in (0, 8].
public func isValidDensity(_ d: Float) -> Bool { d.isFinite && d > 0 && d <= 8 }

public enum MouseKind: UInt8 { case down = 0, up = 1, drag = 2, move = 3 }
public enum MouseButton: UInt8 { case left = 0, right = 1 }

/// A rectangle on the canvas: points, origin at the top-left of A's display, y down.
public struct CanvasRect: Equatable {
    public var x, y, w, h: Float
    public init(x: Float, y: Float, w: Float, h: Float) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public enum WindowKind: UInt8 {
    case normal = 0, dialog, floating, sheet, popover, menu, tooltip
    /// Normal, dialog and floating windows get a B window with a title bar;
    /// the rest are borderless popups attached to a parent.
    public var isDecorated: Bool { self == .normal || self == .dialog || self == .floating }
}

/// One item of the window table (spec §2.2).
public struct WindowInfo: Equatable {
    public var id: UInt32
    public var parent: UInt32
    public var kind: WindowKind
    public var resizable: Bool
    public var focused: Bool
    public var rect: CanvasRect
    public var titleBar: Float
    public var title: String
    public init(id: UInt32, parent: UInt32, kind: WindowKind, resizable: Bool, focused: Bool,
                rect: CanvasRect, titleBar: Float, title: String) {
        self.id = id; self.parent = parent; self.kind = kind; self.resizable = resizable; self.focused = focused
        self.rect = rect; self.titleBar = titleBar; self.title = title
    }
}

/// One item of the mirrored menu bar (spec §2.3). `modifiers`: bit0 shift,
/// bit1 control, bit2 option, bit3 command.
public struct MenuItem: Equatable {
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    public var separator: Bool
    public var key: String
    public var modifiers: UInt8
    public var children: [MenuItem]
    public init(title: String, enabled: Bool = true, checked: Bool = false, separator: Bool = false,
                key: String = "", modifiers: UInt8 = 0, children: [MenuItem] = []) {
        self.title = title; self.enabled = enabled; self.checked = checked; self.separator = separator
        self.key = key; self.modifiers = modifiers; self.children = children
    }
}

public let maxWindows = 256
public let maxMenuDepth = 6
public let maxMenuItems = 5000
public let maxMenuPickDepth = 8
public let maxTitleCharacters = 200

/// Everything that travels over the connection. On the wire each message is
/// a 1-byte type, a 4-byte little-endian payload length, then the payload.
/// Strings are a u16 length followed by UTF-8, except `text`, whose payload
/// is the UTF-8 text itself. Coordinates are points: mouse and scroll are
/// relative to the top-left of the given A window, everything else is on the
/// canvas (A's display). Types 10 and 12 (v3 title and size) are gone.
public enum Message: Equatable {
    case hello(token: String, bundleID: String, mode: Mode, fps: UInt8, density: Float, version: UInt8 = protocolVersion)  // 1, client -> host
    case ready(appName: String, width: UInt16, height: UInt16)                               // 2, host -> client (canvas points)
    case error(String)                                                                       // 3, host -> client
    case frame(region: CanvasRect, FramePayload)                                             // 4, host -> client
    case text(String)                                                                        // 5, client -> host
    case key(keyCode: UInt16, modifiers: UInt64, down: Bool)                                 // 6, macOS virtual key code + CGEventFlags
    case mouse(kind: MouseKind, button: MouseButton, window: UInt32, x: Float, y: Float, clickCount: UInt8)  // 7
    case scroll(window: UInt32, x: Float, y: Float, dx: Float, dy: Float)                    // 8
    case resize(window: UInt32, width: UInt16, height: UInt16)                               // 9, client -> host (content points)
    case setStream(mode: Mode, fps: UInt8, density: Float, pinned: Bool)                     // 11, client -> host; ends with the pinned byte (0 or 1)
    case windows([WindowInfo])                                                               // 13, host -> client, front to back
    case focus(UInt32)                                                                       // 14, client -> host
    case close(UInt32)                                                                       // 15, client -> host
    case move(window: UInt32, x: Float, y: Float)                                            // 16, client -> host (canvas)
    case menuBar([MenuItem])                                                                 // 17, host -> client
    case menuPick([UInt16])                                                                  // 18, client -> host
    case clip(id: UInt32, ClipInfo)                                                          // 19, host -> client
    case paste(seq: UInt32, PasteSource)                                                     // 20, client -> host
    case pasted(seq: UInt32, error: String)                                                  // 21, host -> client
    case fetch(token: String, clip: UInt32, file: UInt16, offset: UInt64)                    // 22, side connection, carries the version
    case put(token: String, item: UInt32, kind: ClipKind, uti: String, name: String, total: UInt64)  // 23, side connection, carries the version
    case transferStart(UInt64)                                                               // 24, side connection
    case chunk([UInt8])                                                                      // 25, side connection, payload is the data
    case inputBlocked(by: String)                                                            // 26, host -> client
    case frameAck(processingMs: UInt16)                                                      // 27, client -> host (v7)
    case weak(Bool)                                                                          // 28, host -> client (v7)
    /// A's selected keyboard input source. `ascii`: it is a plain keyboard layout, not an input method.
    case inputSource(id: String, name: String, ascii: Bool)                                  // 29, host -> client (v8)
    /// Select an enabled input source on A; "" selects the current ASCII-capable layout.
    case selectInput(id: String)                                                             // 30, client -> host (v8)

    public func encoded() -> [UInt8] {
        var w = Writer()
        let type: UInt8
        switch self {
        case let .hello(token, bundleID, mode, fps, density, version):
            type = 1
            w.u8(version); w.string(token); w.string(bundleID); w.u8(mode.rawValue); w.u8(fps); w.f32(density)
        case let .ready(appName, width, height):
            type = 2
            w.string(appName); w.u16(width); w.u16(height)
        case let .error(text):
            type = 3
            w.string(text)
        case let .frame(region, f):
            type = 4
            w.u8(f.mode.rawValue); w.rect(region); w.u16(f.width); w.u16(f.height); w.u8(f.flags.rawValue)
            if f.flags.contains(.start) && !f.flags.contains(.full) { w.u32(UInt32(bitPattern: f.dx)); w.u32(UInt32(bitPattern: f.dy)) }
            w.bytes.append(contentsOf: f.data)
        case let .text(text):
            type = 5
            w.bytes.append(contentsOf: Array(text.utf8))
        case let .key(keyCode, modifiers, down):
            type = 6
            w.u16(keyCode); w.u64(modifiers); w.u8(down ? 1 : 0)
        case let .mouse(kind, button, window, x, y, clickCount):
            type = 7
            w.u8(kind.rawValue); w.u8(button.rawValue); w.u32(window); w.f32(x); w.f32(y); w.u8(clickCount)
        case let .scroll(window, x, y, dx, dy):
            type = 8
            w.u32(window); w.f32(x); w.f32(y); w.f32(dx); w.f32(dy)
        case let .resize(window, width, height):
            type = 9
            w.u32(window); w.u16(width); w.u16(height)
        case let .setStream(mode, fps, density, pinned):
            type = 11
            w.u8(mode.rawValue); w.u8(fps); w.f32(density); w.u8(pinned ? 1 : 0)
        case let .windows(items):
            type = 13
            w.u16(UInt16(clamping: items.count))
            for i in items {
                w.u32(i.id); w.u32(i.parent); w.u8(i.kind.rawValue)
                w.u8((i.resizable ? 1 : 0) | (i.focused ? 2 : 0))
                w.rect(i.rect); w.f32(i.titleBar); w.string(i.title)
            }
        case let .focus(id):
            type = 14
            w.u32(id)
        case let .close(id):
            type = 15
            w.u32(id)
        case let .move(window, x, y):
            type = 16
            w.u32(window); w.f32(x); w.f32(y)
        case let .menuBar(items):
            type = 17
            w.menuItems(items)
        case let .menuPick(path):
            type = 18
            w.u8(UInt8(clamping: path.count))
            for i in path { w.u16(i) }
        case let .clip(id, info):
            type = 19
            w.u32(id); w.clipInfo(info)
        case let .paste(seq, source):
            type = 20
            w.u32(seq)
            switch source {
            case let .text(t):
                precondition(t.utf8.count < inlinePasteLimit, "paste text too long")
                w.u8(0); w.string(t)
            case let .item(n):
                w.u8(1); w.u32(n)
            }
        case let .pasted(seq, error):
            type = 21
            w.u32(seq); w.string(error)
        case let .fetch(token, clip, file, offset):
            type = 22
            w.u8(protocolVersion); w.string(token); w.u32(clip); w.u16(file); w.u64(offset)
        case let .put(token, item, kind, uti, name, total):
            type = 23
            precondition(kind != .unsupported, "put cannot carry an unsupported clip")
            w.u8(protocolVersion); w.string(token); w.u32(item); w.u8(kind.rawValue); w.string(uti); w.string(name); w.u64(total)
        case let .transferStart(n):
            type = 24
            w.u64(n)
        case let .chunk(data):
            type = 25
            precondition(data.count <= chunkSize, "chunk too large")
            w.bytes.append(contentsOf: data)
        case let .inputBlocked(by):
            type = 26
            w.string(by)
        case let .frameAck(processingMs):
            type = 27
            w.u16(processingMs)
        case let .weak(on):
            type = 28
            w.u8(on ? 1 : 0)
        case let .inputSource(id, name, ascii):
            type = 29
            w.string(id); w.string(name); w.u8(ascii ? 1 : 0)
        case let .selectInput(id):
            type = 30
            w.string(id)
        }
        precondition(w.bytes.count <= maxMessageLength, "message too large")
        var out: [UInt8] = [type]
        let n = UInt32(w.bytes.count)
        out.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)])
        out.append(contentsOf: w.bytes)
        return out
    }

    fileprivate static func decode(type: UInt8, payload: ArraySlice<UInt8>) throws -> Message {
        var r = Reader(payload)
        let message: Message
        switch type {
        case 1:
            let version = try r.u8()
            guard version == protocolVersion else { throw ProtocolVersionMismatch(client: version) }
            let token = try r.string(), bundleID = try r.string()
            guard let mode = Mode(rawValue: try r.u8()) else { throw CodecError("unknown mode") }
            let (fps, density) = try r.stream()
            message = .hello(token: token, bundleID: bundleID, mode: mode, fps: fps, density: density, version: version)
        case 2:
            message = .ready(appName: try r.string(), width: try r.u16(), height: try r.u16())
        case 3:
            message = .error(try r.string())
        case 4:
            guard let mode = Mode(rawValue: try r.u8()) else { throw CodecError("unknown mode") }
            let region = try r.rect()
            let width = try r.u16(), height = try r.u16()
            let flags = FrameFlags(rawValue: try r.u8())
            var dx: Int32 = 0, dy: Int32 = 0
            if flags.contains(.start) && !flags.contains(.full) {
                dx = Int32(bitPattern: try r.u32()); dy = Int32(bitPattern: try r.u32())
            }
            message = .frame(region: region, FramePayload(mode: mode, width: width, height: height, flags: flags, dx: dx, dy: dy, data: r.rest()))
        case 5:
            message = .text(try r.utf8(r.rest()))
        case 6:
            let keyCode = try r.u16(), modifiers = try r.u64(), down = try r.u8()
            guard down <= 1 else { throw CodecError("bad key state") }
            message = .key(keyCode: keyCode, modifiers: modifiers, down: down == 1)
        case 7:
            guard let kind = MouseKind(rawValue: try r.u8()) else { throw CodecError("unknown mouse event") }
            guard let button = MouseButton(rawValue: try r.u8()) else { throw CodecError("unknown mouse button") }
            message = .mouse(kind: kind, button: button, window: try r.u32(), x: try r.f32(), y: try r.f32(), clickCount: try r.u8())
        case 8:
            message = .scroll(window: try r.u32(), x: try r.f32(), y: try r.f32(), dx: try r.f32(), dy: try r.f32())
        case 9:
            message = .resize(window: try r.u32(), width: try r.u16(), height: try r.u16())
        case 11:
            guard let mode = Mode(rawValue: try r.u8()) else { throw CodecError("unknown mode") }
            let (fps, density) = try r.stream()
            let flag = try r.u8()
            guard flag <= 1 else { throw CodecError("bad pinned flag") }
            message = .setStream(mode: mode, fps: fps, density: density, pinned: flag == 1)
        case 13:
            message = .windows(try r.windows())
        case 14:
            message = .focus(try r.u32())
        case 15:
            message = .close(try r.u32())
        case 16:
            message = .move(window: try r.u32(), x: try r.f32(), y: try r.f32())
        case 17:
            var budget = maxMenuItems
            message = .menuBar(try r.menuItems(depth: 1, budget: &budget))
        case 18:
            let n = Int(try r.u8())
            guard (1...maxMenuPickDepth).contains(n) else { throw CodecError("menu path must have 1 to 8 levels") }
            message = .menuPick(try (0..<n).map { _ in try r.u16() })
        case 19:
            message = .clip(id: try r.u32(), try r.clipInfo())
        case 20:
            let seq = try r.u32()
            switch try r.u8() {
            case 0:
                let t = try r.string()
                guard t.utf8.count < inlinePasteLimit else { throw CodecError("paste text must be under \(inlinePasteLimit) bytes") }
                message = .paste(seq: seq, .text(t))
            case 1:
                message = .paste(seq: seq, .item(try r.u32()))
            default:
                throw CodecError("unknown paste source")
            }
        case 21:
            message = .pasted(seq: try r.u32(), error: try r.string())
        case 22:
            try r.version()
            message = .fetch(token: try r.string(), clip: try r.u32(), file: try r.u16(), offset: try r.u64())
        case 23:
            try r.version()
            let token = try r.string(), item = try r.u32()
            guard let kind = ClipKind(rawValue: try r.u8()), kind != .unsupported else { throw CodecError("unknown put kind") }
            message = .put(token: token, item: item, kind: kind, uti: try r.string(), name: try r.string(), total: try r.u64())
        case 24:
            message = .transferStart(try r.u64())
        case 25:
            let data = r.rest()
            guard data.count <= chunkSize else { throw CodecError("chunk larger than \(chunkSize) bytes") }
            message = .chunk(data)
        case 26:
            message = .inputBlocked(by: try r.string())
        case 27:
            message = .frameAck(processingMs: try r.u16())
        case 28:
            let flag = try r.u8()
            guard flag <= 1 else { throw CodecError("bad weak flag") }
            message = .weak(flag == 1)
        case 29:
            let id = try r.string(), name = try r.string(), ascii = try r.u8()
            guard ascii <= 1 else { throw CodecError("bad ascii flag") }
            message = .inputSource(id: id, name: name, ascii: ascii == 1)
        case 30:
            message = .selectInput(id: try r.string())
        default:
            throw CodecError("unknown message type \(type)")
        }
        guard r.isAtEnd else { throw CodecError("unexpected bytes after message \(type)") }
        return message
    }
}

private let knownTypes: Set<UInt8> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30]

/// Turns a byte stream into messages. Feed it whatever the socket delivers
/// with `append`, then call `next()` until it returns nil.
public struct MessageParser {
    private var buffer = [UInt8]()

    public init() {}

    public mutating func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete message, or nil when more bytes are needed.
    /// Throws on anything malformed; the connection should then be dropped.
    public mutating func next() throws -> Message? {
        guard buffer.count >= 5 else { return nil }
        let type = buffer[0]
        guard knownTypes.contains(type) else { throw CodecError("unknown message type \(type)") }
        let length = Int(buffer[1]) | Int(buffer[2]) << 8 | Int(buffer[3]) << 16 | Int(buffer[4]) << 24
        guard length <= maxMessageLength else { throw CodecError("message too large (\(length) bytes)") }
        guard buffer.count >= 5 + length else { return nil }
        let message = try Message.decode(type: type, payload: buffer[5..<(5 + length)])
        buffer.removeFirst(5 + length)
        return message
    }
}

private struct Writer {
    var bytes = [UInt8]()
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(v >> (8 * UInt32(i)) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(v >> (8 * UInt64(i)) & 0xFF)) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func rect(_ r: CanvasRect) { f32(r.x); f32(r.y); f32(r.w); f32(r.h) }
    mutating func menuItems(_ items: [MenuItem]) {
        u16(UInt16(clamping: items.count))
        for i in items {
            string(i.title)
            u8((i.enabled ? 1 : 0) | (i.checked ? 2 : 0) | (i.separator ? 4 : 0))
            string(i.key); u8(i.modifiers)
            menuItems(i.children)
        }
    }
    mutating func clipInfo(_ info: ClipInfo) {
        switch info {
        case let .text(t, truncated):
            let utf8 = Array(t.utf8)
            precondition(utf8.count <= maxClipText, "clip text too long")
            u8(ClipKind.text.rawValue); u8(truncated ? 1 : 0); u32(UInt32(utf8.count)); bytes.append(contentsOf: utf8)
        case let .image(width, height, n):
            u8(ClipKind.image.rawValue); u16(width); u16(height); u64(n)
        case let .files(files):
            precondition(files.count <= maxClipFiles, "too many clip files")
            u8(ClipKind.files.rawValue); u16(UInt16(files.count))
            for f in files { string(f.name); u64(f.bytes) }
        case let .data(uti, n):
            u8(ClipKind.data.rawValue); string(uti); u64(n)
        case let .unsupported(why):
            u8(ClipKind.unsupported.rawValue); string(why)
        }
    }
    mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        precondition(utf8.count <= 0xFFFF, "string too long")
        u16(UInt16(utf8.count))
        bytes.append(contentsOf: utf8)
    }
}

private struct Reader {
    private let data: ArraySlice<UInt8>
    private var pos: Int

    init(_ data: ArraySlice<UInt8>) {
        self.data = data
        self.pos = data.startIndex
    }

    var isAtEnd: Bool { pos == data.endIndex }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard data.endIndex - pos >= n else { throw CodecError("message is truncated") }
        defer { pos += n }
        return data[pos..<(pos + n)]
    }

    mutating func rest() -> [UInt8] {
        defer { pos = data.endIndex }
        return Array(data[pos...])
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    /// The version byte that opens `fetch` and `put`.
    mutating func version() throws {
        let v = try u8()
        guard v == protocolVersion else { throw ProtocolVersionMismatch(client: v) }
    }

    mutating func clipInfo() throws -> ClipInfo {
        guard let kind = ClipKind(rawValue: try u8()) else { throw CodecError("unknown clip kind") }
        switch kind {
        case .text:
            let flag = try u8()
            guard flag <= 1 else { throw CodecError("bad truncated flag") }
            let n = Int(try u32())
            guard n <= maxClipText else { throw CodecError("clip text larger than \(maxClipText) bytes") }
            return .text(try utf8(Array(try take(n))), truncated: flag == 1)
        case .image:
            return .image(width: try u16(), height: try u16(), bytes: try u64())
        case .files:
            let n = Int(try u16())
            guard n <= maxClipFiles else { throw CodecError("more than \(maxClipFiles) clip files") }
            return .files(try (0..<n).map { _ in ClipFile(name: try string(), bytes: try u64()) })
        case .data:
            return .data(uti: try string(), bytes: try u64())
        case .unsupported:
            return .unsupported(try string())
        }
    }
    mutating func u16() throws -> UInt16 { UInt16(try uint(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }
    mutating func rect() throws -> CanvasRect { CanvasRect(x: try f32(), y: try f32(), w: try f32(), h: try f32()) }

    mutating func windows() throws -> [WindowInfo] {
        let n = Int(try u16())
        guard n <= maxWindows else { throw CodecError("more than \(maxWindows) windows") }
        var items = [WindowInfo]()
        for _ in 0..<n {
            let id = try u32(), parent = try u32()
            guard id != 0 else { throw CodecError("window id 0") }
            guard let kind = WindowKind(rawValue: try u8()) else { throw CodecError("unknown window kind") }
            let flags = try u8()
            guard flags & ~3 == 0 else { throw CodecError("unknown window flags") }
            let rect = try rect(), titleBar = try f32(), title = try string()
            guard rect.w > 0, rect.h > 0 else { throw CodecError("window size must be positive") }
            guard titleBar >= 0, titleBar < rect.h else { throw CodecError("title bar must be in [0, height)") }
            guard title.count <= maxTitleCharacters else { throw CodecError("window title too long") }
            items.append(WindowInfo(id: id, parent: parent, kind: kind, resizable: flags & 1 != 0, focused: flags & 2 != 0,
                                    rect: rect, titleBar: titleBar, title: title))
        }
        let ids = Set(items.map(\.id))
        guard ids.count == items.count else { throw CodecError("duplicate window id") }
        guard items.allSatisfy({ $0.parent == 0 || ($0.parent != $0.id && ids.contains($0.parent)) }) else {
            throw CodecError("window parent not in table")
        }
        return items
    }

    mutating func menuItems(depth: Int, budget: inout Int) throws -> [MenuItem] {
        let n = Int(try u16())
        guard n == 0 || depth <= maxMenuDepth else { throw CodecError("menu deeper than \(maxMenuDepth) levels") }
        budget -= n
        guard budget >= 0 else { throw CodecError("more than \(maxMenuItems) menu items") }
        var items = [MenuItem]()
        for _ in 0..<n {
            let title = try string(), flags = try u8()
            guard flags & ~7 == 0 else { throw CodecError("unknown menu flags") }
            let key = try string(), modifiers = try u8()
            guard modifiers & ~15 == 0 else { throw CodecError("unknown menu modifiers") }
            let children = try menuItems(depth: depth + 1, budget: &budget)
            items.append(MenuItem(title: title, enabled: flags & 1 != 0, checked: flags & 2 != 0, separator: flags & 4 != 0,
                                  key: key, modifiers: modifiers, children: children))
        }
        return items
    }
    mutating func u64() throws -> UInt64 { try uint(8) }
    mutating func f32() throws -> Float {
        let v = Float(bitPattern: UInt32(try uint(4)))
        guard v.isFinite else { throw CodecError("coordinate is not a finite number") }
        return v
    }

    private mutating func uint(_ n: Int) throws -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in try take(n).enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }

    func utf8(_ bytes: [UInt8]) throws -> String {
        guard let s = String(bytes: bytes, encoding: .utf8) else { throw CodecError("text is not valid UTF-8") }
        return s
    }

    /// The fps byte and density f32 shared by `hello` and `setStream`.
    mutating func stream() throws -> (UInt8, Float) {
        let fps = try u8()
        guard allowedFps.contains(fps) else { throw CodecError("fps must be 30, 15, 5 or 1") }
        let density = Float(bitPattern: UInt32(try uint(4)))
        guard isValidDensity(density) else { throw CodecError("density must be in (0, 8]") }
        return (fps, density)
    }

    mutating func string() throws -> String {
        let n = Int(try u16())
        return try utf8(Array(try take(n)))
    }
}

/// Compares two secrets without stopping at the first difference.
public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff: UInt8 = x.count == y.count ? 0 : 1
    for i in 0..<max(x.count, y.count) {
        diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
    }
    return diff == 0
}

/// A parsed `rapp://host[:port]/[bundle-id]?token=...&mode=...&fps=...` address.
/// Without a bundle id the Hello's appID is empty: the host's bound app.
/// A `scale` parameter from revision 1 is ignored.
public struct RemoteAddress: Equatable {
    public var host: String
    public var port: UInt16
    public var bundleID: String
    public var token: String
    public var mode: Mode
    public var fps: UInt8

    public init(host: String, port: UInt16, bundleID: String, token: String, mode: Mode, fps: UInt8 = 15) {
        self.host = host
        self.port = port
        self.bundleID = bundleID
        self.token = token
        self.mode = mode
        self.fps = fps
    }

    /// `fallbackToken` is used when the address carries no token.
    public init(url: String, fallbackToken: String? = nil) throws {
        guard let c = URLComponents(string: url), c.scheme == "rapp" else {
            throw CodecError("address must start with rapp://")
        }
        guard let host = c.host, !host.isEmpty else { throw CodecError("address has no host") }
        var port = defaultPort
        if let p = c.port {
            guard let valid = UInt16(exactly: p), valid != 0 else { throw CodecError("bad port \(p)") }
            port = valid
        }
        let bundleID = String(c.path.drop(while: { $0 == "/" }))
        guard !bundleID.contains("/") else { throw CodecError("bad bundle id \(bundleID)") }

        var query = [String: String]()
        for item in c.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard let token = [query["token"], fallbackToken].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw CodecError("address has no token")
        }
        var mode = Mode.gray4
        if let name = query["mode"] {
            guard let m = Mode(name: name) else {
                throw CodecError("mode must be gray4, color8, color16, duogray or duocolor")
            }
            mode = m
        }
        var fps: UInt8 = 15
        if let f = query["fps"] {
            guard let v = UInt8(f), allowedFps.contains(v) else { throw CodecError("fps must be 30, 15, 5 or 1") }
            fps = v
        }
        self.init(host: host, port: port, bundleID: bundleID, token: token, mode: mode, fps: fps)
    }
}

/// The title shown on the client: the window's title, or the app's name when
/// the window has none, at most 200 characters.
public func windowTitle(_ raw: String?, appName: String?) -> String {
    let title = (raw?.isEmpty == false ? raw : nil) ?? appName ?? "rapp"
    return String(title.prefix(200))
}

/// One second's received bytes as a rate: KB/s below 1000 KB, MB/s from there
/// (1 KB = 1024 bytes), one decimal, and "0 KB/s" when nothing arrived.
public func formatRate(bytes: Int) -> String {
    if bytes == 0 { return "0 KB/s" }
    let kb = Double(bytes) / 1024
    return kb < 1000 ? String(format: "%.1f KB/s", kb) : String(format: "%.1f MB/s", kb / 1024)
}
