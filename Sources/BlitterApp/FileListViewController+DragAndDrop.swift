import AppKit
import BlitterModel

/// Drag and drop of files, between the two sides and with Finder and other apps. Rows are dragged
/// as file URLs. A drop moves, or copies with ⌥ held (the user's choice: the Windows habit, with
/// the Mac's copy key); on a folder row it goes into that folder, anywhere else into the side's
/// folder. Dropping items on the folder they are already in does nothing.
extension FileListViewController {
    func configureDragAndDrop() {
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        // Elsewhere (Finder) the destination applies its own rules.
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
    }

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < entries.count else {
            return nil
        }
        let entry = entries[row].entry
        return SelectedItem(path: (location as NSString).appendingPathComponent(entry.name),
                            isDirectory: entry.kind == .directory).url
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation
    {
        let folder = dropFolder(row: row, dropOperation: dropOperation)
        if folder == location {
            tableView.setDropRow(-1, dropOperation: .on) // the whole list: the side's folder
        }
        return DropRules.operation(for: info.draggingSourceOperationMask, sources: draggedPaths(info),
                                   into: folder)
    }

    func tableView(_: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool
    {
        let folder = dropFolder(row: row, dropOperation: dropOperation)
        let sources = draggedPaths(info)
        switch DropRules.operation(for: info.draggingSourceOperationMask, sources: sources, into: folder) {
        case .move:
            workspace.perform(.moveItems(sources, toFolder: folder))
        case .copy:
            workspace.perform(.copyItems(sources, toFolder: folder))
        default:
            return false
        }
        return true
    }

    /// A plain folder under the pointer takes the drop; anything else means the side's folder.
    private func dropFolder(row: Int, dropOperation: NSTableView.DropOperation) -> String {
        guard dropOperation == .on, row >= 0, row < entries.count,
              entries[row].entry.kind == .directory, !entries[row].contentType.conforms(to: .package)
        else {
            return location
        }
        return (location as NSString).appendingPathComponent(entries[row].entry.name)
    }

    private func draggedPaths(_ info: any NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }
}

/// What a drop does, from the drag's allowed operations (which the modifier keys narrow down) and
/// where the items come from.
enum DropRules {
    static func operation(for allowed: NSDragOperation, sources: [String], into folder: String) -> NSDragOperation {
        guard !sources.isEmpty else {
            return []
        }
        for source in sources {
            let parent = (source as NSString).deletingLastPathComponent
            // Onto its own folder (nothing to do), onto itself, or into itself.
            if parent == folder || source == folder || folder.hasPrefix(source + "/") {
                return []
            }
        }
        // ⌥ held: AppKit narrows the operations to copy.
        if allowed == .copy {
            return .copy
        }
        // A plain drag, or ⌘ held (move, or "generic" on older systems): move.
        if allowed.contains(.move) || allowed.contains(.generic) {
            return .move
        }
        // A source that only lets its items be copied.
        return allowed.contains(.copy) ? .copy : []
    }
}
