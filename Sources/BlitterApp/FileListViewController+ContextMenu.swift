import AppKit
import BlitterModel

/// The context menu (#19): right-click or ctrl-click on a row shows the menu for the items, on
/// empty space the menu for the side's folder. Which actions it lists comes from the settings.
extension FileListViewController: NSMenuDelegate {
    func configureContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false // the model lists only actions that can run
        tableView.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tableView.headerView?.menu {
            fillColumnsMenu(menu) // #25
            return
        }
        guard menu === tableView.menu else {
            return
        }
        // From the keyboard the menu is for the selection as it is; the "clicked" row is made up.
        let row = tableView.isShowingContextMenuFromKeyboard ? nil : tableView.clickedRow
        prepareContextMenu(menu, clickedRow: row)
    }

    /// Like Finder: a click on an unselected row selects just that row, a click on empty space
    /// clears the selection; then the menu shows what fits. `nil` (the keyboard) keeps the
    /// selection: its menu, or the folder's if nothing is selected.
    func prepareContextMenu(_ menu: NSMenu, clickedRow: Int?) {
        workspace.perform(.activate(side))
        let selection = workspace.state(of: side).selection
        guard let row = clickedRow else {
            menu.fill(with: workspace.contextMenu(for: side, folder: selection.isEmpty), target: self,
                      action: #selector(runContextAction(_:)))
            return
        }
        let onFolder = row < 0 || row >= entries.count
        if onFolder, !selection.isEmpty {
            workspace.perform(.select(side, []))
        } else if !onFolder, !selection.contains(entries[row].entry.name) {
            workspace.perform(.select(side, [entries[row].entry.name]))
        }
        menu.fill(with: workspace.contextMenu(for: side, folder: onFolder), target: self,
                  action: #selector(runContextAction(_:)))
    }

    @objc private func runContextAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        workspace.perform(.runAction(id, side))
    }
}

extension NSMenu {
    /// Replaces the items with the entries; each action item runs `action` on `target` with the
    /// action id as its `representedObject`.
    func fill(with entries: [ShownMenuEntry], target: AnyObject, action: Selector) {
        removeAllItems()
        for entry in entries {
            switch entry {
            case let .action(id, title):
                let item = addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = target
                item.representedObject = id
            case .separator:
                addItem(.separator())
            case let .submenu(title, inner):
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                submenu.fill(with: inner, target: target, action: action)
                addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
            }
        }
    }
}
