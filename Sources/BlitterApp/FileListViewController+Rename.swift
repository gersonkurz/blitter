import AppKit
import BlitterModel

/// Renaming in place: a rename request from the model starts editing the name cell, and the edit
/// ends in a rename command (or a cancel).
extension FileListViewController {
    /// Starts editing a requested name once its row is there (a new folder appears a moment
    /// after it was asked for).
    func startRequestedRename(_ request: RenameRequest?) {
        // Only in the folder the request was made for.
        guard let request, request.token != handledRenameToken, !inlineRename.isEditing, request.folder == location,
              let row = entries.firstIndex(where: { $0.entry.name == request.name })
        else {
            return
        }
        handledRenameToken = request.token
        inlineRename.begin(row: row, column: tableView.column(withIdentifier: Self.nameColumn), name: request.name,
                           path: request.path)
    }

    func makeInlineRename() -> InlineRename {
        let rename = InlineRename(tableView: tableView)
        rename.onCommit = { [weak self] path, newName in
            guard let self else {
                return
            }
            workspace.perform(.rename(side, path: path, newName: newName))
        }
        rename.onCancel = { [weak self] in
            guard let self else {
                return
            }
            workspace.perform(.cancelRename(side))
        }
        return rename
    }

    /// Whatever changed the selection (a click, navigation, a finished job), an open preview
    /// follows it.
    func followSelectionInPreview() {
        let previewPaths = workspace.selectedItems(on: side).map(\.path)
        guard previewPaths != renderedPreviewPaths else {
            return
        }
        renderedPreviewPaths = previewPaths
        previewItemsChanged()
    }
}
