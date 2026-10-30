import AppKit

/// A table view that reports when it gains keyboard focus, which makes its side the active side,
/// and when Return is pressed, which opens the selected entry.
final class ActivatingTableView: NSTableView {
    var onBecomeFirstResponder: (() -> Void)?
    var onReturn: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let returnKeys: Set<UInt16> = [36, 76] // Return, keypad Enter
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if returnKeys.contains(event.keyCode), modifiers.isEmpty {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A combo box that reports when it gains keyboard focus, which makes its side the active side.
final class ActivatingComboBox: NSComboBox {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }
}
