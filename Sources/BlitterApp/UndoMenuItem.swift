import AppKit
import BlitterModel

/// Edit → Undo for the file operations (#61): named after what it undoes, enabled while there is
/// something to undo. The file list and the tree answer it; a text being edited answers first.
@MainActor
enum UndoMenuItem {
    static func validate(_ item: NSMenuItem, workspace: Workspace, side: Side) -> Bool {
        let entry = workspace.lastUndo
        item.title = entry.map { "Undo " + $0.title } ?? "Undo"
        return workspace.canRun("undo", on: side) // false while an undo runs, too
    }
}

extension FolderTreeViewController: NSMenuItemValidation {
    @objc func undo(_: Any?) {
        workspace.perform(.runAction("undo", side))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(undo(_:)) else {
            return true
        }
        return UndoMenuItem.validate(menuItem, workspace: workspace, side: side)
    }
}
