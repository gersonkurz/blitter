import AppKit
import BlitterModel
import Quartz

/// Space shows the selection in Quick Look, as in Finder. The panel asks the responder chain who
/// controls it; the file list that has focus does, and the panel follows its selection.
/// Quick Look calls these on the main thread; its protocols and the panel-control methods predate
/// Swift concurrency (#81).
extension FileListViewController: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else {
            return
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Called when the selection changes, so an open panel shows the new selection.
    func quickLookSelectionChanged() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self
        else {
            return
        }
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_: QLPreviewPanel?) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel?) {
        MainActor.assumeIsolated {
            panel?.dataSource = self
            panel?.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel?) {
        MainActor.assumeIsolated {
            panel?.dataSource = nil
            panel?.delegate = nil
        }
    }

    func numberOfPreviewItems(in _: QLPreviewPanel?) -> Int {
        workspace.selectedItems(on: side).count
    }

    func previewPanel(_: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        let items = workspace.selectedItems(on: side)
        return index < items.count ? items[index].url : nil
    }
}
