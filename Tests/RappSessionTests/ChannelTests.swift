import CoreGraphics
import XCTest
import RappCore
@testable import RappSession

final class ChannelTests: XCTestCase {
    func testStartParses() throws {
        let c = try channelCommand("start", ["sid": 3, "port": 5000, "token": "t", "mode": "color16", "fps": 15, "density": "adaptive"])
        XCTAssertEqual(c, .start(sid: 3, port: 5000, token: "t", mode: .color16, fps: 15, density: .adaptive))
    }

    func testMouseBecomesAMessage() throws {
        let c = try channelCommand("mouse", ["sid": 1, "window": 7, "kind": "down", "button": "right", "x": 10.5, "y": 20, "clicks": 2])
        XCTAssertEqual(c, .mouse(sid: 1, .mouse(kind: .down, button: .right, window: 7, x: 10.5, y: 20, clickCount: 2)))
    }

    func testOtherInputParses() throws {
        XCTAssertEqual(try channelCommand("scroll", ["sid": 1, "window": 7, "x": 1, "y": 2, "dx": -0.5, "dy": 3]),
                       .scroll(sid: 1, .scroll(window: 7, x: 1, y: 2, dx: -0.5, dy: 3)))
        XCTAssertEqual(try channelCommand("key", ["sid": 1, "keyCode": 123, "modifiers": 1_048_576]),
                       .key(sid: 1, keyCode: 123, modifiers: 1_048_576))
        // Sizes clamp to what the protocol carries.
        XCTAssertEqual(try channelCommand("resize", ["sid": 1, "window": 7, "w": 800.4, "h": 70_000]),
                       .resize(sid: 1, .resize(window: 7, width: 800, height: 65535)))
        XCTAssertEqual(try channelCommand("select_window", ["sid": 1, "window": 2]), .selectWindow(sid: 1, window: 2))
        XCTAssertEqual(try channelCommand("set_stream", ["sid": 1, "mode": "duogray", "fps": 1, "density": "saver1x"]),
                       .setStream(sid: 1, mode: .duogray, fps: 1, density: .saver1x))
        XCTAssertEqual(try channelCommand("close", ["sid": 4]), .close(sid: 4))
        XCTAssertEqual(try channelCommand("cancel_transfer", ["sid": 4]), .cancelTransfer(sid: 4))
        XCTAssertEqual(try channelCommand("init", nil), .initialize)
    }

    func testBadArgsThrow() {
        XCTAssertThrowsError(try channelCommand("start", ["sid": 3, "port": 5000, "mode": "color16", "fps": 15, "density": "adaptive"]))
        XCTAssertThrowsError(try channelCommand("mouse", ["sid": 1, "window": 7, "kind": "hop", "button": "left", "x": 1, "y": 1, "clicks": 1]))
        XCTAssertThrowsError(try channelCommand("start", ["sid": 3, "port": 70000, "token": "t", "mode": "color16", "fps": 15, "density": "adaptive"]))
        XCTAssertThrowsError(try channelCommand("start", ["sid": 3, "port": 5000, "token": "t", "mode": "color16", "fps": 15, "density": "huge"]))
        XCTAssertThrowsError(try channelCommand("set_stream", ["sid": 1, "mode": "color16", "fps": 7, "density": "adaptive"]))
        XCTAssertThrowsError(try channelCommand("close", ["sid": "1"]))
        XCTAssertThrowsError(try channelCommand("close", ["sid": true]))
        XCTAssertThrowsError(try channelCommand("close", "x"))
        XCTAssertThrowsError(try channelCommand("scroll", ["sid": 1, "window": 7, "x": Double.nan, "y": 2, "dx": 0, "dy": 0]))
        XCTAssertThrowsError(try channelCommand("mouse", ["sid": 1, "window": -1, "kind": "down", "button": "left", "x": 1, "y": 1, "clicks": 1]))
        XCTAssertThrowsError(try channelCommand("start", [3, 5000]))
    }

    func testClipPickParses() throws {
        XCTAssertEqual(try channelCommand("clip_pick", ["sid": 1, "clip": 5, "insert": true]),
                       .clipPick(sid: 1, clip: 5, insert: true))
        XCTAssertEqual(try channelCommand("clip_pick", ["sid": 1, "clip": 5, "insert": false]),
                       .clipPick(sid: 1, clip: 5, insert: false))
        XCTAssertThrowsError(try channelCommand("clip_pick", ["sid": 1, "clip": 5]))
        XCTAssertThrowsError(try channelCommand("clip_pick", ["sid": 1, "clip": -1, "insert": true]))
        XCTAssertThrowsError(try channelCommand("clip_pick", ["sid": 1, "clip": 5, "insert": 1]))
    }

    func testMenuPickAndMoveTopLeftParse() throws {
        XCTAssertEqual(try channelCommand("menu_pick", ["sid": 1, "path": [0, 2]]), .menuPick(sid: 1, path: [0, 2]))
        XCTAssertThrowsError(try channelCommand("menu_pick", ["sid": 1, "path": []]))
        XCTAssertThrowsError(try channelCommand("menu_pick", ["sid": 1, "path": [0, -1]]))
        XCTAssertThrowsError(try channelCommand("menu_pick", ["sid": 1, "path": "0"]))
        XCTAssertThrowsError(try channelCommand("menu_pick", ["sid": 1, "path": Array(repeating: 0, count: 9)]))
        XCTAssertNoThrow(try channelCommand("menu_pick", ["sid": 1, "path": Array(repeating: 0, count: maxMenuDepth)]))
        XCTAssertEqual(try channelCommand("move_top_left", ["sid": 1, "window": 7]), .moveTopLeft(sid: 1, window: 7))
    }

    func testPictureFocusTakesASidOrNull() throws {
        XCTAssertEqual(try channelCommand("picture_focus", ["sid": 3]), .pictureFocus(sid: 3))
        XCTAssertEqual(try channelCommand("picture_focus", ["sid": NSNull()]), .pictureFocus(sid: nil))
        XCTAssertThrowsError(try channelCommand("picture_focus", [:]))
        XCTAssertThrowsError(try channelCommand("picture_focus", ["sid": "3"]))
    }

    func testUnknownMethodIsNotImplemented() {
        XCTAssertThrowsError(try channelCommand("detach_everything", ["sid": 1])) { error in
            XCTAssertEqual(error as? ChannelError, .unknown("detach_everything"))
        }
        XCTAssertThrowsError(try channelCommand("start", [:])) { error in
            XCTAssertEqual(error as? ChannelError, .bad("start"))
        }
    }

    func testWindowsPayloadCarriesTextureAndVisible() throws {
        let info = WindowInfo(id: 7, parent: 3, kind: .menu, resizable: false, focused: true,
                              rect: CanvasRect(x: 10, y: 20, w: 300, h: 200), titleBar: 28, title: "Edit")
        let p = try XCTUnwrap(eventPayload(.windows([SessionWindow(info: info, visible: CGRect(x: 0, y: 0, width: 1, height: 0.5))]),
                                           sid: 1, textures: [7: 42]))
        XCTAssertEqual(p.method, "windows")
        XCTAssertEqual(p.args["sid"] as? Int64, 1)
        let windows = try XCTUnwrap(p.args["windows"] as? [[String: Any]])
        XCTAssertEqual(windows[0]["texture"] as? Int64, 42)
        XCTAssertEqual(windows[0]["visible"] as? [Double], [0, 0, 1, 0.5])
        XCTAssertEqual(windows[0]["kind"] as? String, "menu")
        XCTAssertEqual(windows[0]["id"] as? Int, 7)
        XCTAssertEqual(windows[0]["parent"] as? Int, 3)
        XCTAssertEqual(windows[0]["title"] as? String, "Edit")
        XCTAssertEqual(windows[0]["x"] as? Double, 10)
        XCTAssertEqual(windows[0]["h"] as? Double, 200)
        XCTAssertEqual(windows[0]["titleBar"] as? Double, 28)
        XCTAssertEqual(windows[0]["resizable"] as? Bool, false)
        XCTAssertEqual(windows[0]["focused"] as? Bool, true)
    }

    func testWindowWithoutTextureSendsNull() throws {
        let info = WindowInfo(id: 9, parent: 0, kind: .normal, resizable: true, focused: false,
                              rect: CanvasRect(x: 0, y: 0, w: 1, h: 1), titleBar: 0, title: "")
        let p = try XCTUnwrap(eventPayload(.windows([SessionWindow(info: info, visible: .zero)]), sid: 1, textures: [:]))
        let windows = try XCTUnwrap(p.args["windows"] as? [[String: Any]])
        XCTAssertTrue(windows[0]["texture"] is NSNull)
    }

    func testOtherPayloads() throws {
        XCTAssertNil(eventPayload(.surfaces([1, 2]), sid: 1, textures: [:]))
        let ready = try XCTUnwrap(eventPayload(.ready(appName: "Calc"), sid: 2, textures: [:]))
        XCTAssertEqual(ready.method, "ready"); XCTAssertEqual(ready.args["appName"] as? String, "Calc")
        XCTAssertEqual(ready.args["sid"] as? Int64, 2)
        let traffic = try XCTUnwrap(eventPayload(.traffic(bytesPerSecond: 2048), sid: 2, textures: [:]))
        XCTAssertEqual(traffic.method, "traffic"); XCTAssertEqual(traffic.args["bytes"] as? Int, 2048)
        let clips = try XCTUnwrap(eventPayload(.clips([ClipRow(id: 5, title: "hi", pickable: false)]), sid: 2, textures: [:]))
        XCTAssertEqual(clips.method, "clipboard")
        let row = try XCTUnwrap((clips.args["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["id"] as? Int, 5); XCTAssertEqual(row["title"] as? String, "hi"); XCTAssertEqual(row["pickable"] as? Bool, false)
        let menu = try XCTUnwrap(eventPayload(.menu([MenuItem(title: "File", children: [
            MenuItem(title: "New", key: "n", modifiers: MenuModifier.command), MenuItem(title: "", separator: true),
        ])]), sid: 2, textures: [:]))
        XCTAssertEqual(menu.method, "menu")
        let top = try XCTUnwrap((menu.args["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(top["title"] as? String, "File"); XCTAssertEqual(top["shortcut"] as? String, "")
        let kids = try XCTUnwrap(top["children"] as? [[String: Any]])
        XCTAssertEqual(kids[0]["shortcut"] as? String, shortcutText(key: "n", modifiers: MenuModifier.command))
        XCTAssertEqual(kids[0]["enabled"] as? Bool, true); XCTAssertEqual(kids[0]["checked"] as? Bool, false)
        XCTAssertEqual(kids[1]["separator"] as? Bool, true)
        let transfer = try XCTUnwrap(eventPayload(.transfer("1/2"), sid: 2, textures: [:]))
        XCTAssertEqual(transfer.method, "transfer"); XCTAssertEqual(transfer.args["status"] as? String, "1/2")
        let idle = try XCTUnwrap(eventPayload(.transfer(nil), sid: 2, textures: [:]))
        XCTAssertTrue(idle.args["status"] is NSNull)
        let composer = try XCTUnwrap(eventPayload(.composer(.sending(true)), sid: 2, textures: [:]))
        XCTAssertEqual(composer.method, "composer"); XCTAssertEqual(composer.args["sending"] as? Bool, true)
        let closed = try XCTUnwrap(eventPayload(.closed(reason: "quit"), sid: 2, textures: [:]))
        XCTAssertEqual(closed.method, "closed"); XCTAssertEqual(closed.args["reason"] as? String, "quit")
    }

    func testTextureChangesDiffByWindowId() {
        func window(_ id: UInt32) -> SessionWindow {
            SessionWindow(info: WindowInfo(id: id, parent: 0, kind: .normal, resizable: true, focused: false,
                                           rect: CanvasRect(x: 0, y: 0, w: 1, h: 1), titleBar: 0, title: ""),
                          visible: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let first = textureChanges(have: [], windows: [window(1), window(2)])
        XCTAssertEqual(first.register, [1, 2]); XCTAssertEqual(first.unregister, [])
        // The same ids again (the captured part changed): nothing to do.
        let repeated = textureChanges(have: [1, 2], windows: [window(2), window(1)])
        XCTAssertEqual(repeated.register, []); XCTAssertEqual(repeated.unregister, [])
        let next = textureChanges(have: [1, 2], windows: [window(2), window(3), window(3)])
        XCTAssertEqual(next.register, [3]); XCTAssertEqual(next.unregister, [1])
    }
}
