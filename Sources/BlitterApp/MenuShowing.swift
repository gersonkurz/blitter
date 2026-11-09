import AppKit
import BlitterModel

/// The automation's `showMenu` (#69): a menu opened for a few seconds, then closed, so a script
/// can take its picture (`just menu-screenshots`). Opened after the answer went out: an open menu
/// holds the main thread until it closes.
extension MainWindowController {
    func showMenu(_ shown: ShownMenu, side: Side, for seconds: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.popUp(shown, side: side, closingAfter: seconds)
        }
    }

    private func popUp(_ shown: ShownMenu, side: Side, closingAfter seconds: Double) {
        guard let window, let list = fileList(of: side) else {
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Over the side's list, wholly on screen: nothing but the list shows at its edges.
        var place = list.contextMenuToShow()
        if shown != .context {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == shown.rawValue })?.submenu else {
                return
            }
            place = MenuPlace(menu: menu, view: list.tableView,
                              point: NSPoint(x: 200, y: list.tableView.visibleRect.minY + 30))
        }
        // In the common modes, so it runs while the menu tracks.
        place.menu.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: seconds, inModes: [.common])
        place.menu.popUp(positioning: nil, at: place.point, in: place.view)
    }
}

extension FileListViewController {
    /// The context menu as the keyboard opens it (for the selection, or the folder), and where:
    /// at the first selected row, or at the top of the list.
    func contextMenuToShow() -> MenuPlace {
        let menu = NSMenu()
        menu.autoenablesItems = false
        prepareContextMenu(menu, clickedRow: nil)
        // Below the selected row, or a little into the list: within the window, never above it.
        let below = tableView.selectedRowIndexes.first.map { tableView.rect(ofRow: $0).maxY }
        return MenuPlace(
            menu: menu,
            view: tableView,
            point: NSPoint(x: 200, y: below ?? tableView.visibleRect.minY + 30)
        )
    }
}

/// A menu and where it opens: at `point` in `view`.
struct MenuPlace {
    var menu: NSMenu
    var view: NSView
    var point: NSPoint
}
