/// Protocol modifier bits (spec §2.3): bit0 shift, bit1 control, bit2 option, bit3 command.
public enum MenuModifier {
    public static let shift: UInt8 = 1, control: UInt8 = 2, option: UInt8 = 4, command: UInt8 = 8
}

/// Converts `AXMenuItemCmdModifiers` (0 = Command alone; bit0 shift, bit1
/// option, bit2 control, bit3 no Command) to protocol bits.
public func menuModifiers(fromAX ax: Int) -> UInt8 {
    var bits: UInt8 = 0
    if ax & 1 != 0 { bits |= MenuModifier.shift }
    if ax & 2 != 0 { bits |= MenuModifier.option }
    if ax & 4 != 0 { bits |= MenuModifier.control }
    if ax & 8 == 0 { bits |= MenuModifier.command }
    return bits
}

/// How a Mac menu shows a shortcut, e.g. "⇧⌘S"; empty when there is no key.
public func shortcutText(key: String, modifiers: UInt8) -> String {
    guard !key.isEmpty else { return "" }
    var text = ""
    if modifiers & MenuModifier.control != 0 { text += "⌃" }
    if modifiers & MenuModifier.option != 0 { text += "⌥" }
    if modifiers & MenuModifier.shift != 0 { text += "⇧" }
    if modifiers & MenuModifier.command != 0 { text += "⌘" }
    return text + key.uppercased()
}

/// Cuts a menu tree to what the decoder accepts (spec §2.3): no lists below
/// `maxDepth` levels and at most `maxItems` items, counted the way the decoder
/// counts them (a whole list before its children). Only a tail is ever cut,
/// so every path into the result means the same item as in `items`.
public func limitMenu(_ items: [MenuItem], maxDepth: Int = maxMenuDepth, maxItems: Int = maxMenuItems) -> [MenuItem] {
    var budget = maxItems
    func limit(_ list: [MenuItem], depth: Int) -> [MenuItem] {
        guard depth <= maxDepth, budget > 0 else { return [] }
        let kept = Array(list.prefix(budget))
        budget -= kept.count
        return kept.map { item in
            var item = item
            item.children = limit(item.children, depth: depth + 1)
            return item
        }
    }
    return limit(items, depth: 1)
}
