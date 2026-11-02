import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// The status line below a file list (#51), in a real window.
@MainActor
@Suite(.serialized)
final class StatusBarTests {
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        let listings = ["/fake": [folder("docs"), folder("src"), file("notes.txt"), file("readme.md"),
                                  file("todo.txt")], "/empty": []]
        workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { listings[$0] ?? [] },
                              directoryCheck: { listings[$0] != nil }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.readFreeSpace = { folder in
            guard folder == "/fake" else {
                try? await Task.sleep(for: .seconds(2)) // a slow volume: still reading when the test looks
                return 1
            }
            return 5_000_000_000
        }
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { !self.controller.statusBar.freeSpaceLabel.stringValue.isEmpty }
    }

    isolated deinit {
        window.close()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @Test func theLineShowsTheListingTheSelectionAndTheFreeSpace() async throws {
        let bar = controller.statusBar
        #expect(bar.summaryLabel.stringValue == "2 folders, 3 files, \(size(3))")
        #expect(bar.freeSpaceLabel.stringValue == "\(size(5_000_000_000)) free")
        #expect(bar.frame.height == 20 && bar.frame.minY == 0)

        // Selecting in the table updates the line.
        controller.tableView.selectRowIndexes([0, 2], byExtendingSelection: false)
        #expect(bar.summaryLabel.stringValue == "2 of 5 selected: 1 folder, 1 file, \(size(1))")
        controller.tableView.selectRowIndexes([0], byExtendingSelection: false)
        #expect(bar.summaryLabel.stringValue == "1 of 5 selected: 1 folder")

        // An empty folder whose free space is still being read: the old folder's is not shown.
        workspace.perform(.navigate(.left, path: "/empty"))
        try await waitUntil { self.controller.location == "/empty" }
        #expect(workspace.state(of: .left).freeSpace?.folder == "/fake")
        #expect(bar.summaryLabel.stringValue == "No items")
        #expect(bar.freeSpaceLabel.stringValue.isEmpty)
    }
}
