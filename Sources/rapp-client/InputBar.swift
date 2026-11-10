import AppKit
import RappCore

/// The one-line text field under the picture. Text is composed here with the
/// local input method and sent as a whole when Return is pressed. While the
/// field is empty, navigation keys go straight to the remote app instead.
final class InputBar: NSTextField, NSTextFieldDelegate {
    /// Called with a `.text` or `.key` message.
    var onSend: ((Message) -> Void)?

    /// macOS virtual key codes for the keys that pass through an empty field.
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        placeholderString = "Type here, press Return to send  ·  在此输入，回车发送"
        font = NSFont.systemFont(ofSize: 14)
        isBordered = false
        isBezeled = false
        drawsBackground = true
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingHead
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// True when nothing is typed and no input-method composition is in progress.
    var isEmpty: Bool {
        if let editor = currentEditor() as? NSTextView {
            return editor.string.isEmpty && !editor.hasMarkedText()
        }
        return stringValue.isEmpty
    }

    /// Sends one key press and release to the remote app.
    func sendKey(_ keyCode: UInt16, modifiers: UInt64 = 0) {
        onSend?(.key(keyCode: keyCode, modifiers: modifiers, down: true))
        onSend?(.key(keyCode: keyCode, modifiers: modifiers, down: false))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Leave everything to the input method while it is composing.
        if textView.hasMarkedText() { return false }
        if textView.string.isEmpty {
            if let keyCode = passThrough[commandSelector] { sendKey(keyCode) }
            // Nothing is typed, so there is nothing for any other command to edit.
            return true
        }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSend?(.text(textView.string))
            textView.string = ""
            stringValue = ""
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape discards what was typed, and keeps the keyboard focus here.
            textView.string = ""
            stringValue = ""
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // Tab would move the focus out of the bar.
            return true
        default:
            return false
        }
    }
}
