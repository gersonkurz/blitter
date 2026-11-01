import AppKit

/// The Date Modified column (#12): the settings' date pattern, and digits of equal width.
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
            (dateFormatter.string(from: date) as NSString).size(withAttributes: [.font: Self.tabularFont]).width
        }.max() ?? 0
        let needed = ceil(widest) + Self.cellPadding
        if column.width < needed {
            column.width = needed
        }
        if !entries.isEmpty {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< entries.count), columnIndexes: [index])
        }
    }

    /// What the dates are measured with: the small rows' system font, as TabularTextField shows it.
    private static let tabularFont = Formatting.tabularFont(like: .systemFont(ofSize: NSFont.smallSystemFontSize))
    /// The text's insets in a cell plus room for the column separator.
    private static let cellPadding: CGFloat = 10
}

/// Text whose digits all have the same width, so sizes and dates line up from row to row. The
/// table sets the font for its row size; whatever font it sets, the digits stay tabular.
final class TabularTextField: NSTextField {
    override var font: NSFont? {
        get { super.font }
        set { super.font = Formatting.tabularFont(like: newValue) }
    }
}
