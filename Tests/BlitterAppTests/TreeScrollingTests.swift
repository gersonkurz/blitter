import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// The tree keeps where the user scrolled it: expanding a folder far below the selected one
/// rebuilds the tree, and the selection is selected again, but the view does not jump back to
/// it. A new selection is still scrolled to.
@MainActor
@Suite(.serialized)
final class TreeScrollingTests {
    private nonisolated static let names = (0 ..< 80).map { String(format: "f%02d", $0) }
    private nonisolated static let folders: [String: [DirectoryEntry]] = {
        var folders = ["/home": names.map(folder)]
        for name in names {
            folders["/home/" + name] = [folder("inner")]
        }
        folders["/home/f79/inner"] = []
        return folders
    }()

    private let workspace: Workspace
    private let tree: FolderTreeViewController
    private let window: NSWindow

    init() async throws {
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { path in
            guard let entries = Self.folders[path] else {
                throw POSIXError(.ENOENT)
            }
            return entries
        }, directoryCheck: { Self.folders[$0] != nil }, volumes: { [] }, watcher: FakeWatcher.factory)
        tree = FolderTreeViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = tree
        workspace.onChange = { [tree] in tree.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.workspace.state(of: .left).status == .loaded && !self.workspace.treeRoots.isEmpty }
        tree.render()
        tree.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    @Test func expandingAFolderFarBelowTheSelectionKeepsTheScrollPosition() async throws {
        let outline = tree.outlineView
        try expand("Home")
        try await waitUntil { self.row("f79") != nil }
        #expect((outline.item(atRow: outline.selectedRow) as? TreeItem)?.title == "Home") // at the top
        let last = try #require(row("f79"))
        outline.scrollRowToVisible(last) // the user scrolls down
        let scrolled = clipView.bounds.origin.y
        #expect(scrolled > 0)

        try expand("f79") // by the user, far below the selection
        try await waitUntil { self.row("inner") != nil }
        #expect(clipView.bounds.origin.y == scrolled)
        #expect((outline.item(atRow: outline.selectedRow) as? TreeItem)?.title == "Home") // still selected

        // A new selection is shown: going to a folder scrolls the tree to it.
        workspace.perform(.navigate(.left, path: "/home/f00"))
        try await waitUntil { (outline.item(atRow: outline.selectedRow) as? TreeItem)?.title == "f00" }
        #expect(clipView.bounds.origin.y < scrolled)
    }

    private var clipView: NSClipView {
        (tree.view as? NSScrollView)?.contentView ?? NSClipView()
    }

    private func row(_ title: String) -> Int? {
        (0 ..< tree.outlineView.numberOfRows).first {
            (tree.outlineView.item(atRow: $0) as? TreeItem)?.title == title
        }
    }

    private func expand(_ title: String) throws {
        let row = try #require(row(title))
        tree.outlineView.expandItem(tree.outlineView.item(atRow: row))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
