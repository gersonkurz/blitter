import AppKit

/// The Date Modified column (#12): the settings' date pattern, in the fixed-width font (#62).
extension FileListViewController {
    /// A new date pattern from the settings: shown in every row, and the columns laid out again
    /// for the dates' new width (#123).
    func renderDateFormat(_ pattern: String) {
        guard pattern != renderedDateFormat else {
            return
        }
        renderedDateFormat = pattern
        dateFormatter = Formatting.dateFormatter(pattern)
        let index = tableView.column(withIdentifier: Self.modifiedColumn)
        guard index >= 0 else {
            return
        }
        layoutColumns() // the dates' fitted width changed (#123)
        if !entries.isEmpty {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< entries.count), columnIndexes: [index])
        }
    }
}
