import AppKit
import BlitterModel

/// A table view that reports when it gains keyboard focus, which makes its side the active side,
/// and when Return is pressed, which opens the selected entry.
final class ActivatingTableView: NSTableView, @preconcurrency NSViewContentSelectionInfo {
    var onBecomeFirstResponder: (() -> Void)?
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    /// Sees every key first (the fast filter, #39); returns whether it used it.
    var onKey: ((NSEvent) -> Bool)?
    var onZoom: ((FontZoom) -> Void)?
    /// Set while the context menu is opened from the keyboard (⌃↩ by default). AppKit then fakes a
    /// right-click at `selectionAnchorRect`, so `clickedRow` must not be taken as the user's choice.
    private(set) var isShowingContextMenuFromKeyboard = false

    override func showContextMenuForSelection(_ sender: Any?) {
        isShowingContextMenuFromKeyboard = true
        defer { isShowingContextMenuFromKeyboard = false }
        super.showContextMenuForSelection(sender)
    }

    /// Where a keyboard-opened context menu appears: at the first selected row, or at the top of
    /// what is visible when nothing is selected.
    var selectionAnchorRect: NSRect {
        if let row = selectedRowIndexes.first {
            return rect(ofRow: row)
        }
        return NSRect(x: visibleRect.minX, y: visibleRect.minY, width: visibleRect.width, height: 1)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }

    override func scrollWheel(with event: NSEvent) {
        if !ZoomWheel.handle(event, onZoom) {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true {
            return
        }
        let returnKeys: Set<UInt16> = [36, 76] // Return, keypad Enter
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if returnKeys.contains(event.keyCode), modifiers.isEmpty {
            onReturn?()
        } else if event.keyCode == 49, modifiers.isEmpty { // Space: Quick Look, as in Finder
            onSpace?()
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

/// Ctrl+mouse wheel zooms the lists' font (#63), as in browsers and editors: up is larger. A
/// mouse wheel's notch is one step; a trackpad's smooth scrolling adds up to steps.
@MainActor
enum ZoomWheel {
    private static var accumulated: CGFloat = 0
    /// Smooth scrolling (points) per step.
    private static let step: CGFloat = 20

    /// Returns whether the event zoomed (Ctrl held, nothing else).
    static func handle(_ event: NSEvent, _ zoom: ((FontZoom) -> Void)?) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .control, let zoom else {
            return false
        }
        // The physical direction: natural scrolling turns the deltas around.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            if delta != 0 {
                zoom(delta > 0 ? .larger : .smaller)
            }
            return true
        }
        if event.phase == .began {
            accumulated = 0
        }
        accumulated += delta
        while abs(accumulated) >= step {
            zoom(accumulated > 0 ? .larger : .smaller)
            accumulated -= accumulated > 0 ? step : -step
        }
        return true
    }
}

/// The folder tree's outline view: reports when it gains keyboard focus, and opens its context
/// menu from the keyboard (#20) at the selected node, like ActivatingTableView.
final class ActivatingOutlineView: NSOutlineView, @preconcurrency NSViewContentSelectionInfo {
    var onBecomeFirstResponder: (() -> Void)?
    var onZoom: ((FontZoom) -> Void)?
    private(set) var isShowingContextMenuFromKeyboard = false

    override func scrollWheel(with event: NSEvent) {
        if !ZoomWheel.handle(event, onZoom) {
            super.scrollWheel(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }

    override func showContextMenuForSelection(_ sender: Any?) {
        isShowingContextMenuFromKeyboard = true
        defer { isShowingContextMenuFromKeyboard = false }
        super.showContextMenuForSelection(sender)
    }

    var selectionAnchorRect: NSRect {
        selectedRow >= 0 ? rect(ofRow: selectedRow) : .null
    }
}
