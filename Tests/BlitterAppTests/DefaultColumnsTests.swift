import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// The default columns since #13: Name, Size, Date Modified; Kind is hidden.
@MainActor
struct DefaultColumnsTests {
    @Test func kindIsHiddenAndNamesTakeTheSpareWidth() {
        let workspace = Workspace(initialLocation: NSTemporaryDirectory(), volumes: { [] },
                                  watcher: FakeWatcher.factory)
        let list = FileListViewController(workspace: workspace, side: .left)
        _ = list.view
        let visible = list.tableView.tableColumns.filter { !$0.isHidden }.map(\.title)
        #expect(visible == ["Name", "Size", "Date Modified"])
        #expect(list.tableView.tableColumns.contains { $0.title == "Kind" && $0.isHidden })
        #expect(list.tableView.columnAutoresizingStyle == .firstColumnOnlyAutoresizingStyle)
    }

    @Test func theColumnLayoutIsSavedUnderANewNameSoV01LayoutsAreIgnored() {
        #expect(FileListViewController.columnsAutosaveName(.left) == "FileList-v2-left")
        #expect(FileListViewController.columnsAutosaveName(.right) == "FileList-v2-right")
    }
}
