import AppKit
import BlitterModel

/// The list's fonts (#62): the settings' face and size, fixed-width where columns line up.
extension FileListViewController {
    /// New fonts from the settings: every row in the new fonts and height, and the date column
    /// grows if the dates no longer fit.
    func renderFonts() {
        let new = ListFonts.current(workspace.settings.font)
        guard new.settings != fonts.settings else {
            return
        }
        fonts = new
        tableView.rowHeight = new.rowHeight
        renderedDateFormat = "" // measured again in the new font
        tableView.reloadData()
    }

    /// Names in the folder or file style (#77), a packaged app being a file. A reused cell keeps
    /// its font until the fonts change: the fonts are shared objects, so the identity check is
    /// all a row costs.
    func applyFont(to cell: NSTableCellView, column: NSUserInterfaceItemIdentifier, entry listed: ListedEntry) {
        let font = switch column {
        case Self.nameColumn:
            fonts.name(listed.isFolder ? fonts.settings.folderStyle : fonts.settings.fileStyle,
                       emphasized: isHighlighted(listed.entry.name))
        case Self.sizeColumn: fonts.tabular
        case Self.modifiedColumn, Self.permissionsColumn: fonts.mono
        default: fonts.text
        }
        if cell.textField?.font !== font {
            cell.textField?.font = font
        }
    }
}
