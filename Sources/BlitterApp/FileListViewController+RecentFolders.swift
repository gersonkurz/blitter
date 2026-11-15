import AppKit
import BlitterModel

/// The side's recent folders (#74, #90), in a menu that the ⌄ button at the path field's right
/// opens (also ↓ in the field, and Go → Recent Folders): the pinned folders first (with a pin),
/// then the others by frecency. With ⌥ held, each one offers Unpin or Remove from Recent Folders
/// instead; at the bottom, the side's own folder is pinned or unpinned.
extension FileListViewController {
    func configureRecentFoldersButton() {
        let button = recentFoldersButton
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Recent Folders")
        button.toolTip = "Recent Folders"
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.controlSize = .small
        button.target = self
        button.action = #selector(recentFoldersClicked(_:))
    }

    @objc private func recentFoldersClicked(_: Any?) {
        showRecentFolders()
    }

    /// Opens the menu below the path field; it closes when a folder is picked or the menu is left.
    func showRecentFolders() {
        workspace.perform(.activate(side)) // as a click anywhere else in the side does
        let menu = makeRecentFoldersMenu()
        menu.minimumWidth = recentFoldersButton.frame.maxX - pathField.frame.minX
        let below = pathField.isFlipped ? pathField.bounds.maxY + 2 : pathField.bounds.minY - 2
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: pathField)
    }

    /// The menu as the side's recent folders are now (tests read it).
    func makeRecentFoldersMenu() -> NSMenu {
        let state = workspace.state(of: side)
        let pinned = Set(state.recentFolders.pinned)
        let folders = workspace.recentFolders(of: side)
        let menu = NSMenu(title: "Recent Folders")
        menu.autoenablesItems = false
        if folders.isEmpty {
            menu.addItem(withTitle: "No Recent Folders", action: nil, keyEquivalent: "").isEnabled = false
        }
        for folder in folders {
            let isPinned = pinned.contains(folder)
            let item = menu.addItem(withTitle: folder, action: #selector(recentFolderChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            if isPinned {
                item.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            }
            let change: RecentFolderChange = isPinned ? .unpin : .remove
            let alternate = addRecentFolderChange(
                isPinned ? "Unpin “\(folder)”" : "Remove “\(folder)” from Recent Folders", change, folder, to: menu
            )
            alternate.isAlternate = true
            alternate.keyEquivalentModifierMask = .option
        }
        menu.addItem(.separator())
        let isPinned = pinned.contains(state.location)
        addRecentFolderChange(isPinned ? "Unpin This Folder" : "Pin This Folder", isPinned ? .unpin : .pin,
                              state.location, to: menu)
        return menu
    }

    @discardableResult
    private func addRecentFolderChange(_ title: String, _ change: RecentFolderChange, _ folder: String,
                                       to menu: NSMenu) -> NSMenuItem
    {
        let item = menu.addItem(withTitle: title, action: #selector(recentFolderChanged(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = RecentFolderMenuChange(folder: folder, change: change)
        return item
    }

    @objc private func recentFolderChosen(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? String {
            view.window?.makeFirstResponder(tableView) // as after a path typed in the field
            workspace.perform(.navigate(side, path: folder))
        }
    }

    @objc private func recentFolderChanged(_ sender: NSMenuItem) {
        if let change = sender.representedObject as? RecentFolderMenuChange {
            workspace.perform(.recentFolder(side, change.folder, change.change))
        }
    }
}

/// What a recent folder's menu item changes, carried by the item.
private final class RecentFolderMenuChange {
    let folder: String
    let change: RecentFolderChange

    init(folder: String, change: RecentFolderChange) {
        self.folder = folder
        self.change = change
    }
}
