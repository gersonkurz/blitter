import AppKit
import BlitterModel

/// The tree's context menu (#20): right-click, ctrl-click or ⌃↩ on a folder shows the folder
/// menu's folder actions for that folder. Like a click, it selects the node, so the side goes
/// there; an action chosen before the folder is read runs once it is.
extension FolderTreeViewController: NSMenuDelegate {
    func configureContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        outlineView.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === outlineView.menu else {
            return
        }
        // From the keyboard the menu is for the selected node; the "clicked" row is made up.
        prepareContextMenu(
            menu,
            clickedRow: outlineView.isShowingContextMenuFromKeyboard ? nil : outlineView.clickedRow
        )
    }

    /// `nil` (the keyboard) means the selected node. Section headers and empty space get no menu.
    func prepareContextMenu(_ menu: NSMenu, clickedRow: Int?) {
        let row = clickedRow ?? outlineView.selectedRow
        guard let node = (outlineView.item(atRow: row) as? TreeItem)?.node else {
            menuFolder = nil
            menu.removeAllItems()
            return
        }
        workspace.perform(.activate(side))
        workspace.perform(.selectTreeNode(side, node))
        menuFolder = node.path
        menu.fill(with: workspace.treeContextMenu(), target: self, action: #selector(runTreeAction(_:)))
    }

    @objc private func runTreeAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let folder = menuFolder else {
            return
        }
        workspace.perform(.runFolderAction(id, side, folder: folder))
    }
}
