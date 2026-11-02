import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// Folder sizes (#52) in a real window: the Size column and the status line show them.
@MainActor
@Suite(.serialized)
final class FolderSizesInteractionTests {
    private let root = NSTemporaryDirectory() + "BlitterFolderSizesUI-" + UUID().uuidString
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        try FileManager.default.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/docs/a.bin", contents: Data(count: 5000))
        FileManager.default.createFile(atPath: root + "/note.txt", contents: Data(count: 10))
        workspace = Workspace(initialLocation: root, home: root, directoryCheck: { _ in true }, volumes: { [] },
                              watcher: FakeWatcher.factory)
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.controller.entries.count == 2 }
    }

    isolated deinit {
        window.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func sizeText(row: Int) throws -> String {
        let column = controller.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        let cell = controller.tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return try #require(cell?.textField?.stringValue)
    }

    @Test func theSizeColumnAndTheStatusLineShowTheMeasuredSize() async throws {
        let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        #expect(try sizeText(row: 0) == "--") // "docs", not measured
        #expect(controller.statusBar.summaryLabel.stringValue == "1 folder, 1 file, \(size(10))")

        workspace.perform(.measureFolderSizes(.left))
        #expect(try sizeText(row: 0) == "…")
        try await waitUntil { (try? self.sizeText(row: 0)) == size(5000) }
        #expect(controller.statusBar.summaryLabel.stringValue == "1 folder, 1 file, \(size(5010))")
        controller.tableView.selectRowIndexes([0], byExtendingSelection: false)
        #expect(controller.statusBar.summaryLabel.stringValue == "1 of 2 selected: 1 folder, \(size(5000))")
    }
}
