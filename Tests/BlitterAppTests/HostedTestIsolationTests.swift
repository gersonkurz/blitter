import AppKit
@testable import Blitter
import BlitterModel
import Testing

/// The app hosts these tests and shares the real app's defaults: it must leave them alone.
@MainActor
struct HostedTestIsolationTests {
    @Test func theHostOpensNoWindowAndSavesNothing() throws {
        #expect(AppEnvironment.isHostedTest)
        #expect(NSApp.mainMenu != nil) // the menu is still there for the tests
        // The host's own window: never made. (Not "no main window anywhere": suites run
        // interleaved, and another test may have one of its own open right now.)
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(delegate.windowController == nil)
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
