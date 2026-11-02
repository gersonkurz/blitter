import BlitterCore

/// The window is asked to show Batch Rename for a side's selection.
public struct BatchRenameRequest: Equatable, Sendable {
    public let side: Side
    /// Changes with every request, so the window shows each one once.
    public let token: Int
}

// MARK: Batch rename

/// Batch Rename: new names for the selected items of a folder, made by a `BatchRename` rule,
/// shown before anything happens (`batchRenamePreview`) and given as one job, all or none.
extension Workspace {
    func requestBatchRename(_ side: Side) -> Bool {
        guard let state = sides[side], state.find == nil, state.status == .loaded, !state.selection.isEmpty else {
            return false
        }
        nextBatchRenameToken += 1
        batchRenameRequest = BatchRenameRequest(side: side, token: nextBatchRenameToken)
        return true
    }

    func cancelBatchRename() -> Bool {
        guard batchRenameRequest != nil else {
            return false
        }
        batchRenameRequest = nil
        return true
    }

    /// What the rule would do with the side's selected items, in list order.
    public func batchRenamePreview(_ side: Side, _ rule: BatchRename) -> BatchRenamePreview {
        let state = state(of: side)
        let items = state.selectedEntries.map {
            BatchRename.Item(name: $0.entry.name, isFolder: $0.entry.kind == .directory)
        }
        return BatchRenamePreview(rule, items: items, taken: state.allEntries.map(\.name),
                                  folder: state.entriesLocation)
    }

    /// Carries out exactly the renames `preview` shows, if the side still shows its folder and,
    /// checked against the folder as it is now, every one is still possible; then selects the
    /// items under their new names.
    func batchRename(_ side: Side, _ shown: BatchRenamePreview) -> Bool {
        if batchRenameRequest?.side == side {
            batchRenameRequest = nil
        }
        guard let state = sides[side], state.find == nil, state.status == .loaded,
              state.entriesLocation == shown.folder
        else {
            return true
        }
        let preview = shown.rechecked(taken: state.allEntries.map(\.name))
        guard preview.canRename else {
            return true
        }
        let folder = shown.folder
        let renames = preview.rows.filter(\.changes).map {
            Rename(path: Paths.appending($0.oldName, to: folder), newName: $0.newName)
        }
        let names = Set(preview.rows.map(\.newName))
        startJob(.renameAll(renames)) { workspace in
            workspace.select(names, in: folder, on: side)
        }
        return true
    }
}
