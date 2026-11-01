import AppKit
import BlitterModel

/// What the user does in the tree — expand, collapse, select — becomes workspace commands (#32).
extension FolderTreeViewController {
    // AppKit sends these while it is still expanding, collapsing or selecting (for each child
    // of a collapsed node, too). Performing the command right there renders, and rebuilding the
    // outline view under AppKit's feet crashed it (crash report 2026-11-01). So the command runs
    // once AppKit is done; whether the change is the user's is decided now.

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRendering, let node = (notification.userInfo?["NSObject"] as? TreeItem)?.node else {
            return
        }
        performLater(.expandTreeNode(side, node))
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRendering, let node = (notification.userInfo?["NSObject"] as? TreeItem)?.node else {
            return
        }
        performLater(.collapseTreeNode(side, node))
    }

    func outlineViewSelectionDidChange(_: Notification) {
        guard !isRendering, let node = (outlineView.item(atRow: outlineView.selectedRow) as? TreeItem)?.node else {
            return
        }
        performLater(.selectTreeNode(side, node))
    }

    private func performLater(_ command: Command) {
        DispatchQueue.main.async { [weak self] in
            self?.workspace.perform(command)
        }
    }
}
