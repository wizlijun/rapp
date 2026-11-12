import AppKit
import RappCore
import RappSession

/// The bar under the picture (spec §4.1): the transfer strip (only while there
/// is something to say), the scrolling editor and the button row. Its height
/// follows the editor's, one to eight lines.
final class ComposerBar: NSView, ComposerSink {
    let composer = Composer()
    /// The bar wants this height now; the window makes room for it.
    var onHeightChange: ((CGFloat) -> Void)?
    var onAttach, onCopy, onSendButton, onCancel: (() -> Void)?

    private static let buttonRow: CGFloat = 26
    private static let statusRow: CGFloat = 24
    private static let gap: CGFloat = 4
    private static let localStatusFor: TimeInterval = 5
    private static let copyTitle = "复制"

    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let attachButton = NSButton(title: "📎 附件", target: nil, action: nil)
    private let copyButton = NSButton(title: ComposerBar.copyTitle, target: nil, action: nil)
    private let sendButton = NSButton(title: "发送 ⏎", target: nil, action: nil)
    private var statusShown = false
    private var statusGeneration = 0
    private var lastWidth: CGFloat = 0
    /// The height the bar wants: the editor's, plus the rows around it.
    private(set) var barHeight: CGFloat = 0

    private var chrome: CGFloat { Self.buttonRow + 3 * Self.gap }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.documentView = composer
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.isHidden = true
        cancelButton.isHidden = true
        addSubview(statusLabel)
        addSubview(cancelButton)

        let actions: [(NSButton, Selector)] = [
            (cancelButton, #selector(cancelClicked)), (attachButton, #selector(attachClicked)),
            (copyButton, #selector(copyClicked)), (sendButton, #selector(sendClicked)),
        ]
        for (button, action) in actions {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 12)
            addSubview(button)
        }
        composer.onStatus = { [weak self] in self?.showLocalStatus($0) }
        composer.onChange = { [weak self] in self?.updateHeight() }
        barHeight = chrome + composer.minHeight
        frame.size.height = barHeight
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Actions

    @objc private func cancelClicked() { onCancel?() }
    @objc private func attachClicked() { onAttach?() }
    @objc private func copyClicked() { onCopy?() }
    @objc private func sendClicked() { onSendButton?() }

    // MARK: State

    /// The transfer strip's text; nil hides it.
    func setStatus(_ text: String?) {
        statusGeneration += 1
        statusShown = text != nil
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
        cancelButton.isHidden = text == nil
        needsLayout = true
        updateHeight()
    }

    /// The strip's text now; nil when hidden.
    var statusText: String? { statusShown ? statusLabel.stringValue : nil }

    /// A message of the composer's own, shown for a few seconds.
    func showLocalStatus(_ text: String?) {
        setStatus(text)
        guard text != nil else { return }
        let generation = statusGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.localStatusFor) { [weak self] in
            if let self, self.statusGeneration == generation { self.setStatus(nil) }
        }
    }

    func setUploadedItem(_ item: UInt32, for chunk: Int) { composer.setUploadedItem(chunk, item) }

    func payload(_ chunk: Int) -> ChipPayload? { composer.payload(chunk) }

    func uploadedItem(_ chunk: Int) -> UInt32? { composer.uploadedItem(chunk) }

    /// A send round ended: what was pasted is removed from the editor, unless the user has changed that part meanwhile.
    func finished(pieces: [ComposerPiece], sent: Int, failure: String?) {
        let length = pieces.prefix(sent).reduce(0) { $0 + Self.pieceLength($1) }
        var note: String?
        if length > 0 {
            if composerPrefixMatches(pieces, composer.pieces(), length: length) {
                composer.removeUpTo(length)
            } else {
                note = "（发送中改过内容，未清除）"
            }
        }
        // Self-clearing, unlike the queue's strip, which 取消 would not end.
        let shown = failure.flatMap { $0.isEmpty ? statusText : $0 }
        let text = [shown, note].compactMap { $0 }
        if !text.isEmpty && (failure != "" || note != nil) { showLocalStatus(text.joined(separator: " ")) }
    }

    private static func pieceLength(_ piece: ComposerPiece) -> Int {
        switch piece {
        case let .text(text): return text.utf16.count
        case .chunk: return 1
        }
    }

    /// Dims the send button while a send is under way.
    func setSending(_ busy: Bool) {
        sendButton.isEnabled = !busy
    }

    /// The copy button's text for a moment ("已复制", "A 上没有复制到东西"); nil restores it.
    func showCopyFeedback(_ text: String?) {
        copyButton.title = text ?? Self.copyTitle
    }

    // MARK: Layout

    private func updateHeight() {
        let width = scroll.contentSize.width
        let text = width > 20 ? min(max(composer.contentHeight(), composer.minHeight), composer.maxHeight)
                              : composer.minHeight
        let height = chrome + text + (statusShown ? Self.statusRow : 0)
        guard height != barHeight else { return }
        barHeight = height
        onHeightChange?(height)
    }

    override func layout() {
        super.layout()
        let gap = Self.gap, width = bounds.width
        var y = gap
        var x = width - gap
        for button in [sendButton, copyButton, attachButton] {
            button.sizeToFit()
            let w = max(button.frame.width, 56)
            x -= w
            button.frame = NSRect(x: x, y: y, width: w, height: Self.buttonRow)
            x -= gap
        }
        y += Self.buttonRow + gap
        let status = statusShown ? Self.statusRow : 0
        scroll.frame = NSRect(x: 0, y: y, width: width, height: max(0, bounds.height - y - status - gap))
        composer.frame.size.width = scroll.contentSize.width
        composer.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        if statusShown {
            cancelButton.sizeToFit()
            let w = max(cancelButton.frame.width, 48)
            let top = bounds.height - Self.statusRow
            cancelButton.frame = NSRect(x: width - gap - w, y: top, width: w, height: Self.statusRow - gap)
            statusLabel.frame = NSRect(x: 2 * gap, y: top, width: max(0, cancelButton.frame.minX - 3 * gap), height: Self.statusRow - gap)
        }
        if width != lastWidth {
            lastWidth = width
            // Wrapping changes with the width; measure after this layout pass.
            DispatchQueue.main.async { [weak self] in self?.updateHeight() }
        }
    }
}
