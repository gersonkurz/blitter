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

    /// After a new listing or new git states: each shown item's state, looked up once here so
    /// a cell only reads a dictionary. Rows are redrawn only if a state changed.
    func renderGit() {
        let state = workspace.state(of: side)
        guard renderedGit != (workspace.gitVersion, state.entriesVersion) else {
            return
        }
        renderedGit = (workspace.gitVersion, state.entriesVersion)
        var states: [String: GitItemStatus] = [:]
        for listed in entries {
            let path = (location as NSString).appendingPathComponent(listed.entry.name)
            states[listed.entry.name] = workspace.gitStatus(of: path, isFolder: listed.entry.kind == .directory)
        }
        guard states != gitStates else {
            return
        }
        gitStates = states
        if !entries.isEmpty {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< entries.count),
                                 columnIndexes: IndexSet(integersIn: 0 ..< tableView.numberOfColumns))
        }
    }

    func textColor(for listed: ListedEntry) -> NSColor {
        // A git state is information: it shows with and without a theme; a problem still wins.
        if listed.entry.error == 0, let git = gitStates[listed.entry.name]?.state {
            return palette?.color(git.role) ?? .labelColor
        }
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
