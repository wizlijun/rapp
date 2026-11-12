import CoreGraphics
import Foundation
import RappCore

/// The `rapp/session` method channel between the GUI's Dart side and its macOS runner, as pure
/// functions: method calls become `ChannelCommand`s, `SessionEvent`s become method calls back.
/// Arguments are maps; `sid` is the hub's session id.

public enum ChannelError: Error, Equatable {
    /// A method this build does not handle (the runner answers "not implemented").
    case unknown(String)
    /// A field is missing, has the wrong type or is out of range.
    case bad(String)
}

public enum ChannelCommand: Equatable {
    case initialize
    case start(sid: Int64, port: UInt16, token: String, mode: Mode, fps: UInt8, density: DensityChoice)
    case close(sid: Int64)
    case mouse(sid: Int64, Message)
    case scroll(sid: Int64, Message)
    /// A press and a release, for the composer's key row.
    case key(sid: Int64, keyCode: UInt16, modifiers: UInt64)
    case resize(sid: Int64, Message)
    case selectWindow(sid: Int64, window: UInt32)
    case setStream(sid: Int64, mode: Mode, fps: UInt8, density: DensityChoice)
    case cancelTransfer(sid: Int64)
    /// The session whose picture has keyboard focus; nil for none.
    case pictureFocus(sid: Int64?)
    /// Take A's clipboard entry `clip` onto B's clipboard, or (insert) into the composer.
    case clipPick(sid: Int64, clip: UInt32, insert: Bool)
    /// Press the A menu item at `path` (indices into the last menu, separators counted).
    case menuPick(sid: Int64, path: [UInt16])
    /// Move A's window to the top-left stack slot and raise it.
    case moveTopLeft(sid: Int64, window: UInt32)
    /// ⌘V in the composer: read B's clipboard; answered with a `pasteResultPayload`.
    case composerPaste(sid: Int64)
    /// 「附件」: pick files; answered with a `pasteResultPayload`.
    case composerAttach(sid: Int64)
    /// Send the editor's pieces (`{"text": s}` or `{"block": n}`, in order).
    case composerSend(sid: Int64, pieces: [ComposerPiece])
    /// A chip was removed from the editor.
    case composerDropBlock(sid: Int64, block: Int)
}

/// Parses one Dart call. Missing fields, wrong types and out-of-range values throw
/// `ChannelError.bad(method)`; sizes and click counts clamp to what the protocol carries.
public func channelCommand(_ method: String, _ args: Any?) throws -> ChannelCommand {
    if method == "init" { return .initialize }
    let known: Set<String> = ["start", "close", "mouse", "scroll", "key", "resize", "select_window", "set_stream",
                              "cancel_transfer", "picture_focus", "clip_pick", "menu_pick", "move_top_left",
                              "composer_paste", "composer_attach", "composer_send", "composer_drop_block"]
    guard known.contains(method) else { throw ChannelError.unknown(method) }
    guard let map = args as? [String: Any] else { throw ChannelError.bad(method) }
    let a = Args(method: method, map: map)
    if method == "picture_focus" {
        // `sid` is required but may be null (Dart's null arrives as NSNull).
        guard let raw = map["sid"] else { throw ChannelError.bad(method) }
        return .pictureFocus(sid: raw is NSNull ? nil : try a.int("sid"))
    }
    let sid = try a.int("sid")
    switch method {
    case "start":
        guard let port = UInt16(exactly: try a.int("port")), port != 0 else { throw ChannelError.bad(method) }
        return .start(sid: sid, port: port, token: try a.string("token"), mode: try a.mode(), fps: try a.fps(),
                      density: try a.density())
    case "close":
        return .close(sid: sid)
    case "mouse":
        let kinds: [String: MouseKind] = ["down": .down, "up": .up, "drag": .drag, "move": .move]
        let buttons: [String: MouseButton] = ["left": .left, "right": .right]
        guard let kind = kinds[try a.string("kind")], let button = buttons[try a.string("button")] else {
            throw ChannelError.bad(method)
        }
        return .mouse(sid: sid, .mouse(kind: kind, button: button, window: try a.window(), x: try a.float("x"),
                                       y: try a.float("y"), clickCount: UInt8(clamping: try a.int("clicks"))))
    case "scroll":
        return .scroll(sid: sid, .scroll(window: try a.window(), x: try a.float("x"), y: try a.float("y"),
                                         dx: try a.float("dx"), dy: try a.float("dy")))
    case "key":
        guard let code = UInt16(exactly: try a.int("keyCode")), let modifiers = UInt64(exactly: try a.int("modifiers")) else {
            throw ChannelError.bad(method)
        }
        return .key(sid: sid, keyCode: code, modifiers: modifiers)
    case "resize":
        return .resize(sid: sid, .resize(window: try a.window(), width: try a.size("w"), height: try a.size("h")))
    case "select_window":
        return .selectWindow(sid: sid, window: try a.window())
    case "set_stream":
        return .setStream(sid: sid, mode: try a.mode(), fps: try a.fps(), density: try a.density())
    case "clip_pick":
        guard let clip = UInt32(exactly: try a.int("clip")) else { throw ChannelError.bad(method) }
        return .clipPick(sid: sid, clip: clip, insert: try a.bool("insert"))
    case "menu_pick":
        return .menuPick(sid: sid, path: try a.path())
    case "move_top_left":
        return .moveTopLeft(sid: sid, window: try a.window())
    case "composer_paste":
        return .composerPaste(sid: sid)
    case "composer_attach":
        return .composerAttach(sid: sid)
    case "composer_send":
        return .composerSend(sid: sid, pieces: try a.pieces())
    case "composer_drop_block":
        return .composerDropBlock(sid: sid, block: try a.block("block"))
    default:
        return .cancelTransfer(sid: sid)
    }
}

/// Reads typed fields out of one call's argument map.
private struct Args {
    let method: String
    let map: [String: Any]

    private var bad: ChannelError { .bad(method) }

    /// A number that is not a boolean (booleans bridge to NSNumber too).
    private func number(_ key: String) throws -> NSNumber {
        guard let n = map[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw bad }
        return n
    }

    func int(_ key: String) throws -> Int64 {
        let n = try number(key)
        guard CFNumberIsFloatType(n) else { return n.int64Value }
        let d = n.doubleValue
        guard d.isFinite, d.rounded() == d, let i = Int64(exactly: d) else { throw bad }
        return i
    }

    func float(_ key: String) throws -> Float {
        let f = Float(try number(key).doubleValue)
        guard f.isFinite else { throw bad }
        return f
    }

    func string(_ key: String) throws -> String {
        guard let s = map[key] as? String else { throw bad }
        return s
    }

    func bool(_ key: String) throws -> Bool {
        guard let n = map[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw bad }
        return n.boolValue
    }

    /// A non-empty list of u16 menu indices.
    func path() throws -> [UInt16] {
        guard let raw = map["path"] as? [Any], (1...maxMenuDepth).contains(raw.count) else { throw bad }
        return try raw.map { item in
            guard let n = item as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n),
                  let i = UInt16(exactly: n.int64Value) else { throw bad }
            return i
        }
    }

    /// A block number: a positive integer.
    func block(_ key: String) throws -> Int {
        guard let n = Int(exactly: try int(key)), n > 0 else { throw bad }
        return n
    }

    /// The composer's pieces: each a map with exactly one of `text` (a string) or `block` (a block number).
    func pieces() throws -> [ComposerPiece] {
        guard let raw = map["pieces"] as? [Any] else { throw bad }
        return try raw.map { item in
            guard let m = item as? [String: Any], m.count == 1 else { throw bad }
            if let text = m["text"] {
                guard let text = text as? String else { throw bad }
                return .text(text)
            }
            return .chunk(try Args(method: method, map: m).block("block"))
        }
    }

    func window() throws -> UInt32 {
        guard let id = UInt32(exactly: try int("window")) else { throw bad }
        return id
    }

    /// A content size in points, rounded and clamped to the protocol's u16.
    func size(_ key: String) throws -> UInt16 {
        let r = try float(key).rounded()
        return r <= 0 ? 0 : r >= Float(UInt16.max) ? .max : UInt16(r)
    }

    func mode() throws -> Mode {
        guard let m = Mode(name: try string("mode")) else { throw bad }
        return m
    }

    func fps() throws -> UInt8 {
        guard let f = UInt8(exactly: try int("fps")), allowedFps.contains(f) else { throw bad }
        return f
    }

    func density() throws -> DensityChoice {
        switch try string("density") {
        case "saver1x": return .saver1x
        case "adaptive": return .adaptive
        case "original": return .original
        default: throw bad
        }
    }
}

/// The channel's name for each window kind (same names as Dart's `WindowKind`).
public func channelName(_ kind: WindowKind) -> String {
    switch kind {
    case .normal: return "normal"
    case .dialog: return "dialog"
    case .floating: return "floating"
    case .sheet: return "sheet"
    case .popover: return "popover"
    case .menu: return "menu"
    case .tooltip: return "tooltip"
    }
}

/// The Dart call for `e`, or nil for events with none (`.surfaces` only wakes textures).
/// `textures` maps window ids to their Flutter texture ids; a window without one sends null.
public func eventPayload(_ e: SessionEvent, sid: Int64, textures: [UInt32: Int64]) -> (method: String, args: [String: Any])? {
    func payload(_ method: String, _ fields: [String: Any]) -> (method: String, args: [String: Any]) {
        (method, fields.merging(["sid": sid]) { $1 })
    }
    switch e {
    case let .ready(appName):
        return payload("ready", ["appName": appName])
    case let .windows(windows):
        return payload("windows", ["windows": windows.map { w -> [String: Any] in
            let i = w.info
            return [
                "id": Int(i.id), "parent": Int(i.parent), "kind": channelName(i.kind), "title": i.title,
                "x": Double(i.rect.x), "y": Double(i.rect.y), "w": Double(i.rect.w), "h": Double(i.rect.h),
                "titleBar": Double(i.titleBar), "resizable": i.resizable, "focused": i.focused,
                "texture": textures[i.id].map { $0 as Any } ?? NSNull(),
                "visible": [w.visible.minX, w.visible.minY, w.visible.width, w.visible.height].map { Double($0) },
            ]
        }])
    case .surfaces:
        return nil
    case let .traffic(bytes):
        return payload("traffic", ["bytes": bytes])
    case let .clips(rows):
        return payload("clipboard", ["clips": rows.map { ["id": Int($0.id), "title": $0.title, "pickable": $0.pickable] }])
    case let .menu(items):
        func encode(_ items: [MenuItem]) -> [[String: Any]] {
            items.map {
                ["title": $0.title, "enabled": $0.enabled, "checked": $0.checked, "separator": $0.separator,
                 "shortcut": shortcutText(key: $0.key, modifiers: $0.modifiers), "children": encode($0.children)]
            }
        }
        return payload("menu", ["items": encode(items)])
    case let .transfer(status):
        return payload("transfer", ["status": status.map { $0 as Any } ?? NSNull()])
    case let .composer(.sending(sending)):
        return payload("composer", ["sending": sending])
    case let .composer(.done(sent, failure)):
        return payload("composer", ["done": ["sent": sent, "failure": failure.map { $0 as Any } ?? NSNull()]])
    case .composer(.insert(.nothing)):
        return nil
    case let .composer(.insert(result)):
        return payload("composer_insert", pasteResultPayload(result))
    case let .closed(reason):
        return payload("closed", ["reason": reason])
    }
}

/// A paste, attach or insert result as Dart's `PasteResult` reads it: `text`, `blocks` (`[{n, label}]`)
/// or `status`; empty for nothing.
public func pasteResultPayload(_ r: PasteResult) -> [String: Any] {
    switch r {
    case let .text(text): return ["text": text]
    case let .blocks(chips): return ["blocks": chips.map { ["n": $0.n, "label": $0.label] as [String: Any] }]
    case let .status(status): return ["status": status]
    case .nothing: return [:]
    }
}

/// Which window textures to register and unregister when a window table arrives: by id only, so
/// a table re-sent with the same ids (the captured part changed) changes nothing.
public func textureChanges(have: Set<UInt32>, windows: [SessionWindow]) -> (register: [UInt32], unregister: [UInt32]) {
    var seen = Set<UInt32>()
    var register = [UInt32]()
    for w in windows where seen.insert(w.info.id).inserted && !have.contains(w.info.id) {
        register.append(w.info.id)
    }
    return (register, have.subtracting(seen).sorted())
}
