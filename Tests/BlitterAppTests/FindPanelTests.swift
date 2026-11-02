import AppKit
@testable import Blitter
@testable import BlitterModel
import Testing

/// The Find panel (#48) in the main window: ⌘F shows it, Return searches the active side, it
/// tells how the search goes, and Escape hides it while the results stay.
@MainActor
@Suite(.serialized)
final class FindPanelTests {
    private let folder: String

    init() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            + "/BlitterFindPanel-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder + "/sub", withIntermediateDirectories: true)
        for file in ["one.txt", "sub/two.txt", "sub/other.md"] {
            FileManager.default.createFile(atPath: folder + "/" + file, contents: Data("x".utf8))
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func findSearchesTheActiveSideAndEscapeHidesThePanel() async throws {
        let workspace = Workspace(initialLocation: folder, home: folder, volumes: { [] }, watcher: FakeWatcher.factory)
        let controller = MainWindowController(workspace: workspace)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        let panel = controller.findController
        #expect(panel.view.isHidden) // until asked for

        let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }
        let item = edit?.items.first { $0.title == "Find…" }
        #expect(item?.keyEquivalent == "f" && item?.action == #selector(MainWindowController.showFind(_:)))
        controller.showFind(nil)
        #expect(!panel.view.isHidden)
        #expect((window.firstResponder as? NSText)?.delegate === panel.field) // typing goes there
        #expect(panel.scopeLabel.stringValue == "in " + folder)

        panel.field.stringValue = "*.txt"
        _ = panel.field.sendAction(panel.field.action, to: panel.field.target)
        try await waitUntil { workspace.state(of: .left).find?.isRunning == false }
        try await waitUntil { workspace.state(of: .left).visibleEntries.count == 2 }
        #expect(workspace.state(of: .left).visibleEntries.map(\.entry.name).sorted() == ["one.txt", "sub/two.txt"])
        #expect(panel.statusLabel.stringValue == "2 found in 2 folders")
        #expect(!panel.stopButton.isEnabled)
        #expect(FileListViewController.shownLocation(workspace.state(of: .left))
            == "search://" + folder + "?name=*.txt")

        _ = panel.control(panel.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(panel.view.isHidden)
        #expect(workspace.state(of: .left).find != nil) // the results stay
        #expect(window.firstResponder is NSTableView) // the keys go back to the list
    }

    /// #48 review: Return in the path field while it shows the search leaves the search alone.
    @Test func returnOnTheShownSearchKeepsIt() async throws {
        let workspace = Workspace(initialLocation: folder, home: folder, volumes: { [] }, watcher: FakeWatcher.factory)
        let list = FileListViewController(workspace: workspace, side: .left)
        let window = NSWindow(contentViewController: list)
        defer { window.close() }
        workspace.onChange = { list.render() }
        workspace.perform(.find(.left, pattern: "*.txt"))
        try await waitUntil { workspace.state(of: .left).find?.isRunning == false }
        list.render()
        let shown = "search://" + folder + "?name=*.txt"
        #expect(list.pathField.stringValue == shown)
        _ = list.pathField.sendAction(list.pathField.action, to: list.pathField.target) // Return, unchanged
        #expect(workspace.state(of: .left).find?.pattern == "*.txt" && workspace.state(of: .left).location == folder)
        #expect(list.pathField.stringValue == shown)
    }

    @Test func theStatusSaysHowItGoes() {
        var find = FindState(root: "/r", pattern: "x")
        find.foldersSearched = 1
        #expect(FindPanelController.status(find, found: 0) == "Searching… 0 found in 1 folder")
        find.isRunning = false
        find.foldersSearched = 1200
        find.unreadableFolders = 3
        #expect(FindPanelController.status(find, found: 5)
            == "5 found in \(1200.formatted()) folders (3 could not be read)") // in the Mac's own number format
    }
}
