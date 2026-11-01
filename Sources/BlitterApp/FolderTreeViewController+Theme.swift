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

    func textColor(isSection: Bool, isHidden: Bool) -> NSColor {
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
