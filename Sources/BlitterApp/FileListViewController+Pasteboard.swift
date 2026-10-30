import AppKit
import BlitterModel

/// Copy and paste of files, the way Finder does it: Copy puts the selected items on the pasteboard
/// as file URLs (through the Model's system services); Paste copies file URLs from the pasteboard
/// into this side's folder, and Move Item
/// Here (⌥⌘V) moves them. The Edit menu reaches these through the responder chain; while a text
/// field is edited, its editor gets them first.
extension FileListViewController: NSMenuItemValidation {
    @objc func copy(_: Any?) {
        workspace.perform(.copyToPasteboard(side))
    }

    @objc func paste(_: Any?) {
        workspace.perform(.copyItems(pastedPaths(), toFolder: workspace.state(of: side).location))
    }

    @objc func moveItemsHere(_: Any?) {
        workspace.perform(.moveItems(pastedPaths(), toFolder: workspace.state(of: side).location))
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

extension SelectedItem {
    /// The folder flag comes from the listing: `URL(fileURLWithPath:)` without it asks the disk,
    /// which can hang on a network volume.
    var url: NSURL {
        URL(fileURLWithPath: path, isDirectory: isDirectory) as NSURL
    }
}
