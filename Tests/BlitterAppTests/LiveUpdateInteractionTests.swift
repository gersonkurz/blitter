import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Synchronization
import Testing

private func listed(_ entries: [DirectoryEntry]) -> [ListedEntry] {
    entries.map { ListedEntry(entry: $0, contentType: .data, kindDescription: "") }
}

struct RowChangesTests {
    @Test func addedRemovedAndUpdatedRows() throws {
        let old = listed([file("a"), file("b"), file("c"), file("d")])
        var bigger = file("c")
        bigger.size = 500
        let new = listed([file("a"), file("a2"), bigger, file("d"), file("e")])
        let changes = try #require(RowChanges.between(old, new))
        #expect(changes.removed == [1]) // b
        #expect(changes.inserted == [1, 4]) // a2, e
        #expect(changes.updated == [2]) // c got bigger
    }

    @Test func nothingChanged() {
        let rows = listed([file("a"), file("b")])
        #expect(RowChanges.between(rows, rows) == RowChanges())
    }

    @Test func reorderedRowsNeedAReload() {
        #expect(RowChanges.between(listed([file("a"), file("b")]), listed([file("b"), file("a")])) == nil)
    }

    @Test func tooManyChangesNeedAReload() {
        let old = listed((0 ..< 10).map { file("old\($0)") })
        let new = listed((0 ..< 10).map { file("new\($0)") })
        #expect(RowChanges.between(old, new, limit: 19) == nil)
        #expect(RowChanges.between(old, new, limit: 20) != nil)
    }
}

/// The files of the test folder; the lister reads them on a background thread.
private final class Contents: Sendable {
    let files = Mutex<[DirectoryEntry]>((0 ..< 300).map { file(String(format: "file%03d", $0)) })
}

/// A folder of many files that a test changes, then reads again, like a change on disk would.
@MainActor
@Suite(.serialized)
final class LiveUpdateInteractionTests {
    private let contents = Contents()
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        let contents = contents
        workspace = Workspace(initialLocation: "/big", home: "/home", lister: { path in
            guard path == "/big" else {
                throw POSIXError(.ENOENT)
            }
            return contents.files.withLock { $0 }
        }, directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 700, height: 500))
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.workspace.state(of: .left).visibleEntries.count == 300 }
        controller.render()
        controller.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    @Test func aChangeOnDiskKeepsScrollSelectionAndCells() async throws {
        tableView.scrollRowToVisible(150)
        tableView.layoutSubtreeIfNeeded()
        let scrolledTo = scrollView.contentView.bounds.origin
        workspace.perform(.select(.left, ["file150"]))
        let visible = tableView.rows(in: tableView.visibleRect)
        let unchangedRow = visible.location + 1
        let cellBefore = try #require(tableView.view(atColumn: 0, row: unchangedRow, makeIfNecessary: false))

        // A file appears after everything visible, another one disappears far below.
        contents.files.withLock { files in
            files.append(file("file999"))
            files.removeAll { $0.name == "file299" }
        }
        workspace.foldersChanged([FolderChange(path: "/big", includesSubfolders: false)])
        try await waitUntil { self.tableView.numberOfRows == 300 && self.names().last == "file999" }

        #expect(scrollView.contentView.bounds.origin == scrolledTo)
        #expect(tableView.selectedRowIndexes == [150])
        #expect(workspace.state(of: .left).selection == ["file150"])
        // The table was updated row by row, not reloaded: the cell is the very same view.
        #expect(tableView.view(atColumn: 0, row: unchangedRow, makeIfNecessary: false) === cellBefore)
    }

    @Test func aChangedSizeUpdatesThatRow() async throws {
        let sizeColumn = try #require(tableView.tableColumns.firstIndex { $0.identifier.rawValue == "size" })
        contents.files.withLock { files in
            files[0].size = 5_000_000
        }
        workspace.foldersChanged([FolderChange(path: "/big", includesSubfolders: false)])
        try await waitUntil { self.workspace.state(of: .left).visibleEntries.first?.entry.size == 5_000_000 }
        let cell = try #require(tableView.view(
            atColumn: sizeColumn,
            row: 0,
            makeIfNecessary: false
        ) as? NSTableCellView)
        #expect(cell.textField?.stringValue == Formatting.size(of: workspace.state(of: .left).visibleEntries[0].entry))
    }

    // MARK: Helpers

    private var scrollView: NSScrollView {
        // swiftlint:disable:next force_cast
        controller.view.subviews.first { $0 is NSScrollView } as! NSScrollView
    }

    private var tableView: NSTableView {
        // swiftlint:disable:next force_cast
        scrollView.documentView as! NSTableView
    }

    private func names() -> [String] {
        workspace.state(of: .left).visibleEntries.map(\.entry.name)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
