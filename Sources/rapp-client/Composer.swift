import AppKit
import RappCore
import RappSession

/// The inseparable attachment behind one block; it only carries the chip id and draws as a label.
private final class ChipAttachment: NSTextAttachment {
    let chip: Int

    init(chip: Int, label: String, font: NSFont) {
        self.chip = chip
        super.init(data: nil, ofType: nil)
        attachmentCell = ChipCell(label: label, font: font)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// Draws a block as a small rounded label.
private final class ChipCell: NSTextAttachmentCell {
    private let text: NSAttributedString
    private let size: NSSize

    init(label: String, font: NSFont) {
        let small = NSFont.systemFont(ofSize: font.pointSize - 2)
        text = NSAttributedString(string: label, attributes: [.font: small, .foregroundColor: NSColor.labelColor])
        let measured = text.size()
        size = NSSize(width: ceil(measured.width) + 10, height: ceil(measured.height) + 2)
        super.init(textCell: label)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func cellSize() -> NSSize { size }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -3) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let box = cellFrame.insetBy(dx: 1, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        path.fill()
        let origin = NSPoint(x: box.minX + 4, y: box.minY + (box.height - text.size().height) / 2)
        text.draw(at: origin)
    }
}

/// The multi-line editor under the picture (spec §4.1). Text is composed here
/// with the local input method; pasted or attached things become blocks. While
/// it is empty, navigation keys go straight to the remote app instead.
final class Composer: NSTextView {
    /// Called with a `.key` message for the keys that pass through an empty editor.
    var onSend: ((Message) -> Void)?
    /// Return, with something typed and no input-method composition in progress.
    var onSubmit: (() -> Void)?
    /// A line for the transfer bar (a refused paste, an unreadable file).
    var onStatus: ((String?) -> Void)?
    /// The content changed; the bar re-measures its height.
    var onChange: (() -> Void)?

    static let maxBytes: UInt64 = 256 << 20
    static let placeholder = "Type here, press Return to send  ·  在此输入，回车发送"
    static let maxLines = 8

    private let pasteboard = LocalPasteboard()
    private let blocks = ComposerBlocks()
    private let baseFont = NSFont.systemFont(ofSize: 14)

    /// macOS virtual key codes for the keys that pass through an empty editor.
    private let passThrough: [Selector: UInt16] = [
        #selector(NSResponder.insertNewline(_:)): 36,
        #selector(NSResponder.deleteBackward(_:)): 51,
        #selector(NSResponder.insertTab(_:)): 48,
        #selector(NSResponder.cancelOperation(_:)): 53,
        #selector(NSResponder.moveUp(_:)): 126,
        #selector(NSResponder.moveDown(_:)): 125,
        #selector(NSResponder.moveLeft(_:)): 123,
        #selector(NSResponder.moveRight(_:)): 124,
    ]

    init() {
        // An explicit TextKit 1 stack: block attachments draw through their cells.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        font = baseFont
        typingAttributes = plainAttributes
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 4, height: 4)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        drawsBackground = true
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private var plainAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    // MARK: Content

    /// True when nothing is typed, there is no block and no input-method composition is in progress.
    var isEmpty: Bool { string.isEmpty && !hasMarkedText() }

    /// The content in order; a block is its chip id.
    func pieces() -> [ComposerPiece] {
        guard let storage = textStorage else { return [] }
        var result: [ComposerPiece] = []
        let text = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let chip = value as? ChipAttachment {
                result.append(.chunk(chip.chip))
            } else {
                result.append(.text(text.substring(with: range)))
            }
        }
        return result
    }

    func payload(_ chip: Int) -> ChipPayload? { blocks.payload(chip) }

    func uploadedItem(_ chip: Int) -> UInt32? { blocks.uploadedItem(chip) }

    func setUploadedItem(_ chip: Int, _ item: UInt32) { blocks.setUploadedItem(item, for: chip) }

    /// Deletes [0, end) of the content.
    func removeUpTo(_ end: Int) {
        guard let storage = textStorage else { return }
        replace(NSRange(location: 0, length: min(max(end, 0), storage.length)), with: "")
        pruneChips()
        undoManager?.removeAllActions()
    }

    private func clear() {
        replace(NSRange(location: 0, length: textStorage?.length ?? 0), with: "")
        pruneChips()
        undoManager?.removeAllActions()
    }

    private func replace(_ range: NSRange, with string: String) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
    }

    /// Forgets the payloads of blocks no longer in the editor.
    private func pruneChips() {
        var present = Set<Int>()
        for case .chunk(let chip) in pieces() { present.insert(chip) }
        blocks.keep(only: present)
    }

    // MARK: Inserting

    private func insertChip(_ payload: ChipPayload) {
        let id = blocks.add(payload)
        let attachment = ChipAttachment(chip: id, label: blocks.label(id) ?? "", font: baseFont)
        let block = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        block.addAttributes(plainAttributes, range: NSRange(location: 0, length: block.length))
        insertText(block, replacementRange: selectedRange())
        typingAttributes = plainAttributes
    }

    private func insertTextChunk(_ text: String) {
        insertChip(.text(text))
    }

    private func insertImage(png: [UInt8], width: Int, height: Int) {
        insertChip(.image(png: png, width: width, height: height))
    }

    private func insertData(uti: String, _ bytes: [UInt8]) {
        guard UInt64(bytes.count) <= Self.maxBytes else {
            onStatus?("太大了，A 最多收 256 MB")
            return
        }
        insertChip(.data(uti: uti, bytes))
    }

    /// One block per file; folders are skipped.
    func insertFiles(_ urls: [URL]) {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                onStatus?("不支持文件夹：\(url.lastPathComponent)")
                continue
            }
            let bytes = UInt64(values?.fileSize ?? 0)
            insertChip(.file(url, bytes: bytes))
        }
    }

    /// Option-click on a history entry: text by the paste rule, the rest as blocks.
    func insert(_ payload: InsertPayload, info: ClipInfo) {
        switch (payload, info) {
        case let (.text(text), _):
            insertPlainOrChunk(text)
        case let (.bytes(data), .image(width, height, _)):
            insertImage(png: data, width: Int(width), height: Int(height))
        case let (.bytes(data), .data(uti, _)):
            insertData(uti: uti, data)
        case let (.files(urls), _):
            insertFiles(urls)
        default:
            break
        }
    }

    private func insertPlainOrChunk(_ text: String) {
        switch pasteDecision(types: [typeUTF8Text], text: text.replacingOccurrences(of: "\u{FFFC}", with: "")) {
        case let .inlineText(text): insertText(text, replacementRange: selectedRange())
        case let .textChunk(text): insertTextChunk(text)
        default: break
        }
    }

    // MARK: Paste and drop

    override func paste(_ sender: Any?) {
        // A copied block is a bare object-replacement character in text; never insert one.
        let text = pasteboard.string?.replacingOccurrences(of: "\u{FFFC}", with: "")
        switch pasteDecision(types: pasteboard.types, text: text) {
        case .files:
            insertFiles(pasteboard.fileURLs())
        case .image:
            if let image = pasteboard.imagePNG() { insertImage(png: image.png, width: image.width, height: image.height) }
        case let .inlineText(text):
            insertText(text, replacementRange: selectedRange())
        case let .textChunk(text):
            insertTextChunk(text)
        case let .data(uti):
            if let bytes = pasteboard.data(uti: uti) { insertData(uti: uti, bytes) }
        case .nothing:
            break
        }
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        // Dragging a selection around inside the editor could leave a bare block character.
        guard !urls.isEmpty else { return (sender.draggingSource as? Composer) === self ? false : super.performDragOperation(sender) }
        insertFiles(urls)
        return true
    }

    // MARK: Keys

    /// Sends one key press and release to the remote app.
    func sendKey(_ keyCode: UInt16, modifiers: UInt64 = 0) {
        onSend?(.key(keyCode: keyCode, modifiers: modifiers, down: true))
        onSend?(.key(keyCode: keyCode, modifiers: modifiers, down: false))
    }

    override func doCommand(by selector: Selector) {
        // Leave everything to the input method while it is composing.
        if hasMarkedText() { return super.doCommand(by: selector) }
        if string.isEmpty {
            if let keyCode = passThrough[selector] { sendKey(keyCode) }
            // Nothing is typed, so there is nothing for any other command to edit.
            return
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape discards what was typed, and keeps the keyboard focus here.
            clear()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // Tab would move the focus out of the editor.
            break
        default:
            super.doCommand(by: selector)
        }
    }

    // MARK: Size and look

    var lineHeight: CGFloat { layoutManager?.defaultLineHeight(for: baseFont) ?? 17 }

    /// Height of one line, with the insets.
    var minHeight: CGFloat { ceil(lineHeight) + 2 * textContainerInset.height }

    /// Height of up to `maxLines` lines, with the insets.
    var maxHeight: CGFloat { ceil(lineHeight) * CGFloat(Self.maxLines) + 2 * textContainerInset.height }

    /// Height of the content at the current width, with the insets.
    func contentHeight() -> CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return minHeight }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height) + 2 * textContainerInset.height
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onChange?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        NSAttributedString(string: Self.placeholder, attributes: [.font: baseFont, .foregroundColor: NSColor.placeholderTextColor])
            .draw(at: origin)
    }
}
