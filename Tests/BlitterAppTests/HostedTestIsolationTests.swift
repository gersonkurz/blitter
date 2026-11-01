import AppKit
@testable import Blitter
import BlitterModel
import Testing

/// The app hosts these tests and shares the real app's defaults: it must leave them alone.
@MainActor
struct HostedTestIsolationTests {
    @Test func theHostOpensNoWindowAndSavesNothing() {
        #expect(AppEnvironment.isHostedTest)
        #expect(NSApp.mainMenu != nil) // the menu is still there for the tests
        #expect(!NSApp.windows.contains { $0.windowController is MainWindowController })
    }

    @Test func viewsDoNotAutosaveTheirLayoutUnderTest() {
        #expect(AppEnvironment.autosaveName("MainWindow") == nil)
        let workspace = Workspace(initialLocation: NSTemporaryDirectory(), volumes: { [] },
                                  watcher: FakeWatcher.factory)
        let side = SideViewController(workspace: workspace, side: .left)
        _ = side.view
        #expect(side.splitView.autosaveName == nil)
        let list = FileListViewController(workspace: workspace, side: .left)
        _ = list.view
        #expect(list.tableView.autosaveName == nil && !list.tableView.autosaveTableColumns)
    }
}
