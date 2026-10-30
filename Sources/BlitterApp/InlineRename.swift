import AppKit

/// Edits a name in place in the file list. Return, Tab or clicking elsewhere commits, Escape
/// cancels. The cell always goes back to showing the model's name: a successful rename arrives
/// with the next listing, a failed one never shows a name that isn't on disk.
@MainActor
final class InlineRename: NSObject, NSTextFieldDelegate {
    private weak var tableView: NSTableView?
    private var field: NSTextField?
    private var original = ""
    /// The item being renamed, fixed when editing starts: whatever the list shows when editing
    /// ends, the commit renames this item.
    private var path = ""
    private var cancelled = false
    var onCommit: ((_ path: String, _ newName: String) -> Void)?
    var onCancel: (() -> Void)?

    init(tableView: NSTableView) {
        self.tableView = tableView
    }

    var isEditing: Bool {
        field != nil
    }

    /// Starts editing the name in `row`. Returns false if that row has no editable cell.
    @discardableResult
    func begin(row: Int, column: Int, name: String, path: String) -> Bool {
        guard let tableView, !isEditing, row >= 0, row < tableView.numberOfRows, column >= 0 else {
            return false
        }
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField
        else {
            return false
        }
        self.field = field
        original = name
        self.path = path
        cancelled = false
        field.isEditable = true
        field.delegate = self
        tableView.window?.makeFirstResponder(field)
        // Like Finder, select the name without its extension.
        let base = (name as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        return true
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        cancelled = true
        field?.abortEditing()
        finish()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field, notification.object as? NSTextField === field else {
            return
        }
        let newName = field.stringValue
        let path = path
        finish()
        // Editing can also end while the table reloads; report it after that, not inside it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onCommit?(path, newName) }
        }
    }

    private func finish() {
        guard let field else {
            return
        }
        self.field = nil
        field.isEditable = false
        field.delegate = nil
        field.stringValue = original
        tableView?.window?.makeFirstResponder(tableView)
        if cancelled {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onCancel?() }
            }
        }
    }
}
