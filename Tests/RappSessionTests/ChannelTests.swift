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
        XCTAssertEqual(try channelCommand("cancel_transfer", ["sid": 4]), .cancelTransfer(sid: 4, id: nil))
        XCTAssertEqual(try channelCommand("cancel_transfer", ["sid": 1, "id": 3]), .cancelTransfer(sid: 1, id: 3))
        XCTAssertEqual(try channelCommand("fetch_clip", ["sid": 1, "clip": 2]), .fetchClip(sid: 1, clip: 2))
        XCTAssertEqual(try channelCommand("copy_local", ["copy": 4]), .copyLocal(copy: 4))
        XCTAssertEqual(try channelCommand("drop_copy", ["copy": 4]), .dropCopy(copy: 4))
        XCTAssertEqual(try channelCommand("reveal", ["path": "/tmp/x"]), .reveal(path: "/tmp/x"))
        XCTAssertThrowsError(try channelCommand("fetch_clip", ["sid": 1])) { XCTAssertEqual($0 as? ChannelError, .bad("fetch_clip")) }
        XCTAssertThrowsError(try channelCommand("copy_local", ["copy": "x"]))
        XCTAssertThrowsError(try channelCommand("reveal", [:]))
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

    func testComposerCommandsParse() throws {
        XCTAssertEqual(try channelCommand("composer_paste", ["sid": 1]), .composerPaste(sid: 1))
        XCTAssertEqual(try channelCommand("composer_attach", ["sid": 1]), .composerAttach(sid: 1))
        XCTAssertEqual(try channelCommand("composer_send", ["sid": 1, "pieces": [["block": 3], ["text": "x"]]]),
                       .composerSend(sid: 1, pieces: [.chunk(3), .text("x")]))
        XCTAssertEqual(try channelCommand("composer_send", ["sid": 1, "pieces": []]), .composerSend(sid: 1, pieces: []))
        XCTAssertEqual(try channelCommand("composer_drop_block", ["sid": 1, "block": 2]), .composerDropBlock(sid: 1, block: 2))
        XCTAssertThrowsError(try channelCommand("composer_send", ["sid": 1]))
        XCTAssertThrowsError(try channelCommand("composer_send", ["sid": 1, "pieces": [["block": -1]]]))
        XCTAssertThrowsError(try channelCommand("composer_send", ["sid": 1, "pieces": [["text": 3]]]))
        XCTAssertThrowsError(try channelCommand("composer_send", ["sid": 1, "pieces": [["block": 1, "text": "x"]]]))
        XCTAssertThrowsError(try channelCommand("composer_send", ["sid": 1, "pieces": ["x"]]))
        XCTAssertThrowsError(try channelCommand("composer_drop_block", ["sid": 1, "block": 1.5]))
        XCTAssertThrowsError(try channelCommand("composer_drop_block", ["sid": 1]))
    }

    func testComposerPayloads() throws {
        XCTAssertEqual(pasteResultPayload(.text("hi")) as? [String: String], ["text": "hi"])
        XCTAssertEqual(pasteResultPayload(.status("no")) as? [String: String], ["status": "no"])
        XCTAssertTrue(pasteResultPayload(.nothing).isEmpty)
        let blocks = try XCTUnwrap(pasteResultPayload(.blocks([BlockChip(n: 2, label: "[图片 #1 10×20]")]))["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["n"] as? Int, 2)
        XCTAssertEqual(blocks.first?["label"] as? String, "[图片 #1 10×20]")

        let blocked = eventPayload(.inputBlocked(by: "Mac mini"), sid: 3, textures: [:])
        XCTAssertEqual(blocked?.method, "input_blocked")
        XCTAssertEqual(blocked?.args["by"] as? String, "Mac mini")
        XCTAssertEqual(blocked?.args["sid"] as? Int64, 3)
        let done = try XCTUnwrap(eventPayload(.composer(.done(sent: 2, failure: nil)), sid: 3, textures: [:]))
        XCTAssertEqual(done.method, "composer")
        let d = try XCTUnwrap(done.args["done"] as? [String: Any])
        XCTAssertEqual(d["sent"] as? Int, 2); XCTAssertTrue(d["failure"] is NSNull)
        let failed = try XCTUnwrap(eventPayload(.composer(.done(sent: 0, failure: "x")), sid: 3, textures: [:]))
        XCTAssertEqual((failed.args["done"] as? [String: Any])?["failure"] as? String, "x")
        let insert = try XCTUnwrap(eventPayload(.composer(.insert(.text("hi"))), sid: 3, textures: [:]))
        XCTAssertEqual(insert.method, "composer_insert")
        XCTAssertEqual(insert.args["text"] as? String, "hi"); XCTAssertEqual(insert.args["sid"] as? Int64, 3)
        XCTAssertNil(eventPayload(.composer(.insert(.nothing)), sid: 3, textures: [:]))
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

    func testTrafficPayloadCarriesFrames() throws {
        let t2 = try XCTUnwrap(eventPayload(.traffic(bytesPerSecond: 10, frames: 2), sid: 2, textures: [:]))
        XCTAssertEqual(t2.method, "traffic"); XCTAssertEqual(t2.args["bytes"] as? Int, 10); XCTAssertEqual(t2.args["frames"] as? Int, 2)
    }

    func testDisconnectedPayload() throws {
        let dis = try XCTUnwrap(eventPayload(.disconnected(reason: "x"), sid: 3, textures: [:]))
        XCTAssertEqual(dis.method, "disconnected"); XCTAssertEqual(dis.args["reason"] as? String, "x")
    }

    func testOtherPayloads() throws {
        XCTAssertNil(eventPayload(.surfaces([1, 2]), sid: 1, textures: [:]))
        let ready = try XCTUnwrap(eventPayload(.ready(appName: "Calc"), sid: 2, textures: [:]))
        XCTAssertEqual(ready.method, "ready"); XCTAssertEqual(ready.args["appName"] as? String, "Calc")
        XCTAssertEqual(ready.args["sid"] as? Int64, 2)
        let traffic = try XCTUnwrap(eventPayload(.traffic(bytesPerSecond: 2048, frames: 0), sid: 2, textures: [:]))
        XCTAssertEqual(traffic.method, "traffic"); XCTAssertEqual(traffic.args["bytes"] as? Int, 2048)
        let clips = try XCTUnwrap(eventPayload(.clips([ClipRow(id: 5, title: "hi", pickable: false, kind: "files")]), sid: 2, textures: [:]))
        XCTAssertEqual(clips.method, "clipboard")
        let row = try XCTUnwrap((clips.args["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["id"] as? Int, 5); XCTAssertEqual(row["title"] as? String, "hi"); XCTAssertEqual(row["pickable"] as? Bool, false); XCTAssertEqual(row["kind"] as? String, "files")
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
        let transfer = try XCTUnwrap(eventPayload(.transferStatus("1/2"), sid: 2, textures: [:]))
        XCTAssertEqual(transfer.method, "transfer_status"); XCTAssertEqual(transfer.args["status"] as? String, "1/2")
        let idle = try XCTUnwrap(eventPayload(.transferStatus(nil), sid: 2, textures: [:]))
        XCTAssertTrue(idle.args["status"] is NSNull)
        let composer = try XCTUnwrap(eventPayload(.composer(.sending(true)), sid: 2, textures: [:]))
        XCTAssertEqual(composer.method, "composer"); XCTAssertEqual(composer.args["sending"] as? Bool, true)
        let closed = try XCTUnwrap(eventPayload(.closed(reason: "quit"), sid: 2, textures: [:]))
        XCTAssertEqual(closed.method, "closed"); XCTAssertEqual(closed.args["reason"] as? String, "quit")
    }

    func testTransferProgressPayloadAndCopyReply() throws {
        let p = TransferProgress(id: 3, dir: .down, name: "a.bin", kind: nil, done: 5, total: 10, state: .done,
                                 path: "/tmp/a.bin", error: nil)
        let e = try XCTUnwrap(eventPayload(.transferProgress(p), sid: 2, textures: [:]))
        XCTAssertEqual(e.method, "transfer")
        XCTAssertEqual(e.args["id"] as? Int, 3); XCTAssertEqual(e.args["dir"] as? String, "down")
        XCTAssertEqual(e.args["name"] as? String, "a.bin"); XCTAssertEqual(e.args["done"] as? Int, 5)
        XCTAssertEqual(e.args["total"] as? Int, 10); XCTAssertEqual(e.args["state"] as? String, "done")
        XCTAssertEqual(e.args["path"] as? String, "/tmp/a.bin"); XCTAssertNil(e.args["error"])
        let f = TransferProgress(id: 4, dir: .up, name: "b.txt", kind: .files, done: 0, total: 1, state: .failed, path: nil,
                                 error: "x")
        let g = try XCTUnwrap(eventPayload(.transferProgress(f), sid: 2, textures: [:]))
        XCTAssertNil(g.args["path"]); XCTAssertEqual(g.args["error"] as? String, "x")
        XCTAssertNil(e.args["kind"]); XCTAssertEqual(g.args["kind"] as? String, "files")
        XCTAssertEqual(clipCopyReply(.success(3)) as NSDictionary, ["copy": 3] as NSDictionary)
        XCTAssertEqual(clipCopyReply(.failure(TransferFailure(reason: "r"))) as NSDictionary, ["error": "r"] as NSDictionary)
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
