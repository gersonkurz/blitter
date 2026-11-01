import AppKit
import BlitterModel

/// Colors (#21): the list follows the settings' theme and the window's light or dark mode.
extension FileListViewController {
    /// A new theme, or the appearance changed: redraw everything in the new colors.
    func renderPalette() {
        guard let new = Palette.changed(from: palette, workspace.settings.theme, for: view) else {
            return
        }
        palette = new
        // Controls are drawn for the scheme's brightness, so the path row behind them takes the
        // scheme's background too (otherwise light buttons would sit on the light window).
        view.appearance = new.appearance
        view.wantsLayer = true
        view.layer?.backgroundColor = new.isThemed ? new.color(.background).cgColor : nil
        tableView.backgroundColor = new.color(.background)
        // The theme's rows draw their own stripes; the system's are AppKit's.
        tableView.usesAlternatingRowBackgroundColors = !new.isThemed
        tableView.reloadData()
    }

    func textColor(for listed: ListedEntry) -> NSColor {
        guard let palette, palette.isThemed else {
            return listed.entry.isHidden ? .secondaryLabelColor : .labelColor // the system look
        }
        return palette.color(listed.themeRole)
    }

    /// The message over the list: nothing while reading, "Empty folder", or why the folder
    /// could not be read, in the error color when themed.
    func renderStatus(_ status: LoadStatus) {
        switch status {
        case .loading:
            statusLabel.stringValue = ""
        case .loaded:
            statusLabel.stringValue = entries.isEmpty ? "Empty folder" : ""
            statusLabel.textColor = statusColor(isFailure: false)
        case let .failed(message):
            statusLabel.stringValue = message
            statusLabel.textColor = statusColor(isFailure: true)
        }
    }

    /// "Empty folder" is dim; a folder that could not be read is an error.
    private func statusColor(isFailure: Bool) -> NSColor {
        guard let palette, palette.isThemed else {
            return .secondaryLabelColor // the system look
        }
        return palette.color(isFailure ? .error : .dimText)
    }

    func pathFieldColor(isActive: Bool) -> NSColor {
        guard let palette, palette.isThemed else {
            return isActive ? .controlAccentColor : .secondaryLabelColor
        }
        return palette.color(isActive ? .folder : .dimText)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        guard let palette, palette.isThemed else {
            return nil // AppKit's own row
        }
        return ThemedRowView.make(in: tableView, palette: palette)
    }
}
