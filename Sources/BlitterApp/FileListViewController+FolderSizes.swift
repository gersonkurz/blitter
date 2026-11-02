import AppKit
import BlitterModel

extension FileListViewController {
    /// Folder sizes (#52): when they change, the Size column is drawn again (only its visible
    /// cells are made).
    func renderFolderSizes(_ sizes: [String: FolderSize]) {
        guard sizes != shownFolderSizes else {
            return
        }
        shownFolderSizes = sizes
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(SortColumn.size.rawValue))
        if column >= 0, !entries.isEmpty {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< entries.count), columnIndexes: [column])
        }
    }
}
