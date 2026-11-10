import Foundation

public let protocolVersion: UInt8 = 3

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
public let allowedFps: Set<UInt8> = [15, 5]

/// A capture density (pixels per A point) is finite and in (0, 8].
public func isValidDensity(_ d: Float) -> Bool { d.isFinite && d > 0 && d <= 8 }

public enum MouseKind: UInt8 { case down = 0, up = 1, drag = 2 }
public enum MouseButton: UInt8 { case left = 0, right = 1 }

/// Everything that travels over the connection. On the wire each message is
/// a 1-byte type, a 4-byte little-endian payload length, then the payload.
/// Strings are a u16 length followed by UTF-8, except `text`, whose payload
/// is the UTF-8 text itself. Mouse and scroll positions are 0...1 inside the
/// remote window.
public enum Message: Equatable {
    case hello(token: String, bundleID: String, mode: Mode, fps: UInt8, density: Float)      // 1, client -> host
    case ready(title: String, width: UInt16, height: UInt16)                                 // 2, host -> client (points)
    case error(String)                                                                       // 3, host -> client
    case frame(FramePayload)                                                                 // 4, host -> client
    case text(String)                                                                        // 5, client -> host
    case key(keyCode: UInt16, modifiers: UInt64, down: Bool)                                 // 6, macOS virtual key code + CGEventFlags
    case mouse(kind: MouseKind, button: MouseButton, x: Float, y: Float, clickCount: UInt8)  // 7
    case scroll(x: Float, y: Float, dx: Float, dy: Float)                                    // 8
    case resize(width: UInt16, height: UInt16)                                               // 9, client -> host (points)
    case title(String)                                                                       // 10, host -> client
    case setStream(mode: Mode, fps: UInt8, density: Float)                                   // 11, client -> host
    case size(width: UInt16, height: UInt16)                                                 // 12, host -> client (points)

    public func encoded() -> [UInt8] {
        var w = Writer()
        let type: UInt8
        switch self {
        case let .hello(token, bundleID, mode, fps, density):
            type = 1
            w.u8(protocolVersion); w.string(token); w.string(bundleID); w.u8(mode.rawValue); w.u8(fps); w.f32(density)
        case let .ready(title, width, height):
            type = 2
            w.string(title); w.u16(width); w.u16(height)
        case let .error(text):
            type = 3
            w.string(text)
        case let .frame(f):
            type = 4
            w.u8(f.mode.rawValue); w.u16(f.width); w.u16(f.height); w.u8(f.isFull ? 1 : 0); w.bytes.append(contentsOf: f.data)
        case let .text(text):
            type = 5
            w.bytes.append(contentsOf: Array(text.utf8))
        case let .key(keyCode, modifiers, down):
            type = 6
            w.u16(keyCode); w.u64(modifiers); w.u8(down ? 1 : 0)
        case let .mouse(kind, button, x, y, clickCount):
            type = 7
            w.u8(kind.rawValue); w.u8(button.rawValue); w.f32(x); w.f32(y); w.u8(clickCount)
        case let .scroll(x, y, dx, dy):
            type = 8
            w.f32(x); w.f32(y); w.f32(dx); w.f32(dy)
        case let .resize(width, height):
            type = 9
            w.u16(width); w.u16(height)
        case let .title(text):
            type = 10
            w.string(text)
        case let .setStream(mode, fps, density):
            type = 11
            w.u8(mode.rawValue); w.u8(fps); w.f32(density)
        case let .size(width, height):
            type = 12
            w.u16(width); w.u16(height)
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
            message = .hello(token: token, bundleID: bundleID, mode: mode, fps: fps, density: density)
        case 2:
            message = .ready(title: try r.string(), width: try r.u16(), height: try r.u16())
        case 3:
            message = .error(try r.string())
        case 4:
            guard let mode = Mode(rawValue: try r.u8()) else { throw CodecError("unknown mode") }
            let width = try r.u16(), height = try r.u16(), full = try r.u8()
            guard full <= 1 else { throw CodecError("bad frame flag") }
            message = .frame(FramePayload(mode: mode, width: width, height: height, isFull: full == 1, data: r.rest()))
        case 5:
            message = .text(try r.utf8(r.rest()))
        case 6:
            let keyCode = try r.u16(), modifiers = try r.u64(), down = try r.u8()
            guard down <= 1 else { throw CodecError("bad key state") }
            message = .key(keyCode: keyCode, modifiers: modifiers, down: down == 1)
        case 7:
            guard let kind = MouseKind(rawValue: try r.u8()) else { throw CodecError("unknown mouse event") }
            guard let button = MouseButton(rawValue: try r.u8()) else { throw CodecError("unknown mouse button") }
            message = .mouse(kind: kind, button: button, x: try r.f32(), y: try r.f32(), clickCount: try r.u8())
        case 8:
            message = .scroll(x: try r.f32(), y: try r.f32(), dx: try r.f32(), dy: try r.f32())
        case 9:
            message = .resize(width: try r.u16(), height: try r.u16())
        case 10:
            message = .title(try r.string())
        case 11:
            guard let mode = Mode(rawValue: try r.u8()) else { throw CodecError("unknown mode") }
            let (fps, density) = try r.stream()
            message = .setStream(mode: mode, fps: fps, density: density)
        case 12:
            message = .size(width: try r.u16(), height: try r.u16())
        default:
            throw CodecError("unknown message type \(type)")
        }
        guard r.isAtEnd else { throw CodecError("unexpected bytes after message \(type)") }
        return message
    }
}

private let knownTypes: ClosedRange<UInt8> = 1...12

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
    mutating func u16() throws -> UInt16 { UInt16(try uint(2)) }
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
        guard allowedFps.contains(fps) else { throw CodecError("fps must be 15 or 5") }
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

/// A parsed `rapp://host[:port]/bundle-id?token=...&mode=...&fps=...` address.
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

    public init(url: String) throws {
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
        guard !bundleID.isEmpty, !bundleID.contains("/") else { throw CodecError("address has no bundle id") }

        var query = [String: String]()
        for item in c.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard let token = query["token"], !token.isEmpty else { throw CodecError("address has no token") }
        var mode = Mode.gray4
        if let name = query["mode"] {
            guard let m = Mode(name: name) else {
                throw CodecError("mode must be gray4, color8, color16, duogray or duocolor")
            }
            mode = m
        }
        var fps: UInt8 = 15
        if let f = query["fps"] {
            guard let v = UInt8(f), allowedFps.contains(v) else { throw CodecError("fps must be 15 or 5") }
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
