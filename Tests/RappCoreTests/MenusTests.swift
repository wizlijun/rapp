import RappCore
import XCTest

final class MenusTests: XCTestCase {
    // MARK: menuModifiers(fromAX:) (spec §2.3, §3.5)

    func testAXModifiersBecomeProtocolBits() {
        // AX: 0 = Command alone; bit0 shift, bit1 option, bit2 control, bit3 no Command.
        XCTAssertEqual(menuModifiers(fromAX: 0), 0b1000)               // ⌘
        XCTAssertEqual(menuModifiers(fromAX: 1), 0b1001)               // ⇧⌘
        XCTAssertEqual(menuModifiers(fromAX: 2), 0b1100)               // ⌥⌘
        XCTAssertEqual(menuModifiers(fromAX: 4), 0b1010)               // ⌃⌘
        XCTAssertEqual(menuModifiers(fromAX: 8), 0)                    // no Command
        XCTAssertEqual(menuModifiers(fromAX: 8 | 4 | 2 | 1), 0b0111)   // ⌃⌥⇧
        XCTAssertEqual(menuModifiers(fromAX: 0xF0), 0b1000)            // unknown bits ignored
    }

    // MARK: shortcutText(key:modifiers:) (spec §4.5)

    func testShortcutTextUsesMacOrder() {
        XCTAssertEqual(shortcutText(key: "N", modifiers: 0b1000), "⌘N")
        XCTAssertEqual(shortcutText(key: "s", modifiers: 0b1001), "⇧⌘S")
        XCTAssertEqual(shortcutText(key: "T", modifiers: 0b1110), "⌃⌥⌘T")
        XCTAssertEqual(shortcutText(key: "", modifiers: 0b1000), "")
    }

    // MARK: limitMenu (spec §2.3: at most 6 levels, 5000 items)

    func testLimitMenuDropsLevelsBelowTheMaximum() {
        let deep = MenuItem(title: "1", children: [MenuItem(title: "2", children: [MenuItem(title: "3")])])
        let limited = limitMenu([deep], maxDepth: 2, maxItems: 100)
        XCTAssertEqual(limited, [MenuItem(title: "1", children: [MenuItem(title: "2")])])
    }

    func testLimitMenuKeepsAPrefixSoPathsStayValid() {
        // The decoder charges a whole list before its children: the top
        // list (2) first, then File's children (3) — budget 4 keeps one of them.
        let tree = [
            MenuItem(title: "File", children: [MenuItem(title: "New"), MenuItem(title: "Open"), MenuItem(title: "Close")]),
            MenuItem(title: "Edit", children: [MenuItem(title: "Copy")]),
        ]
        let limited = limitMenu(tree, maxDepth: 6, maxItems: 4)
        XCTAssertEqual(limited, [
            MenuItem(title: "File", children: [MenuItem(title: "New"), MenuItem(title: "Open")]),
            MenuItem(title: "Edit"),
        ])
    }

    func testLimitedMenuAlwaysDecodes() throws {
        let wide = (0..<3000).map { MenuItem(title: "\($0)") }
        let tree = [MenuItem(title: "A", children: wide), MenuItem(title: "B", children: wide)]
        let limited = limitMenu(tree)
        let bytes = Message.menuBar(limited).encoded()
        var decoder = MessageParser()
        decoder.append(bytes)
        guard case let .menuBar(decoded)? = try decoder.next() else { return XCTFail("no menuBar") }
        XCTAssertEqual(decoded, limited)
        XCTAssertEqual(decoded[0].children.count, 3000)
        XCTAssertEqual(decoded[1].children.count, maxMenuItems - 2 - 3000)
    }
}
