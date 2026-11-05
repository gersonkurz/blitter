import AppKit

/// The Date Modified column (#12): the settings' date pattern, in the fixed-width font (#62).
extension FileListViewController {
    /// A new date pattern from the settings: shown in every row, and the column grows if dates in
    /// it may no longer fit (it never shrinks: a width the user chose stays).
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
        let column = tableView.tableColumns[index]
        let widest = Formatting.wideSampleDates.map { date in
            (dateFormatter.string(from: date) as NSString).size(withAttributes: [.font: fonts.mono]).width
        }.max() ?? 0
        let needed = ceil(widest) + Self.cellPadding
        if column.width < needed {
            column.width = needed
        }
        if !entries.isEmpty {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< entries.count), columnIndexes: [index])
        }
    }

    /// The text's insets in a cell plus room for the column separator.
    private static let cellPadding: CGFloat = 10
}
