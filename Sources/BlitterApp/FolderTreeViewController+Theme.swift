import AppKit
import BlitterModel

/// Colors (#21): the tree follows the settings' theme and the window's light or dark mode.
extension FolderTreeViewController {
    /// Returns true if the colors changed, so the tree is rebuilt in the new ones.
    func renderPalette() -> Bool {
        guard let new = Palette.changed(from: palette, workspace.settings.theme, for: view) else {
            return false
        }
        palette = new
        view.appearance = new.appearance
        outlineView.backgroundColor = new.color(.background)
        (view as? NSScrollView)?.backgroundColor = new.color(.background)
        outlineView.usesAlternatingRowBackgroundColors = !new.isThemed
        return true
    }

    /// Whether the git states changed since the cells were drawn (#22).
    func gitColorsChanged() -> Bool {
        defer { renderedGitVersion = workspace.gitVersion }
        return workspace.gitVersion != renderedGitVersion
    }

    /// New colors for the cells; the rows, and what is expanded, stay.
    func reloadCells() {
        if outlineView.numberOfRows > 0 {
            outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< outlineView.numberOfRows),
                                   columnIndexes: [0])
        }
    }

    func textColor(isSection: Bool, isHidden: Bool, folder: String?) -> NSColor {
        // A git state is information: it shows with and without a theme (#22).
        if let folder, let git = workspace.gitState(ofFolder: folder) {
            return palette?.color(git.role) ?? .labelColor
        }
        guard let palette, palette.isThemed else {
            return isSection || isHidden ? .secondaryLabelColor : .labelColor // the system look
        }
        return palette.color(isSection ? .dimText : isHidden ? .hidden : .folder)
    }

    /// Section rows keep their group semantics but not the grey group-row band of the plain
    /// style; a theme draws every row itself.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let palette, palette.isThemed {
            return ThemedRowView.make(in: outlineView, palette: palette)
        }
        return (item as? TreeItem)?.section != nil ? SectionRowView() : nil
    }
}
