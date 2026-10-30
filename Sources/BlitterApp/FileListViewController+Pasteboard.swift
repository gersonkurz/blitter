import AppKit
import BlitterModel

/// Copy and paste of files, the way Finder does it: Copy puts the selected items on the pasteboard
/// as file URLs; Paste copies file URLs from the pasteboard into this side's folder, and Move Item
/// Here (⌥⌘V) moves them. The Edit menu reaches these through the responder chain; while a text
/// field is edited, its editor gets them first.
extension FileListViewController: NSMenuItemValidation {
    @objc func copy(_: Any?) {
        // Whether each item is a folder comes from the listing: `URL(fileURLWithPath:)` without
        // that hint asks the disk, which can hang on a network volume.
        let state = workspace.state(of: side)
        let urls = state.visibleEntries.filter { state.selection.contains($0.entry.name) }.map { listed in
            URL(fileURLWithPath: (state.entriesLocation as NSString).appendingPathComponent(listed.entry.name),
                isDirectory: listed.entry.kind == .directory) as NSURL
        }
        guard !urls.isEmpty else {
            return
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    @objc func paste(_: Any?) {
        workspace.perform(.copyItems(pastedPaths(), into: side))
    }

    @objc func moveItemsHere(_: Any?) {
        workspace.perform(.moveItems(pastedPaths(), into: side))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            !workspace.state(of: side).selection.isEmpty
        case #selector(paste(_:)), #selector(moveItemsHere(_:)):
            pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLsOnly)
        default:
            true
        }
    }

    private func pastedPaths() -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLsOnly) as? [URL] ?? []
        return urls.map(\.path)
    }

    private static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
}
