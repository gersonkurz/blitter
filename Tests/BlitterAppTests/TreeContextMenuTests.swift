import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

private let folders: [String: [DirectoryEntry]] = [
    "/home": [folder("Documents"), folder("Music")],
    "/home/Documents": [],
    "/home/Music": [],
]

/// The tree's context menu (#20), opened by real right-click and keyboard events in a window.
@MainActor
@Suite(.serialized)
final class TreeContextMenuTests {
    private let workspace: Workspace
    private let tree: FolderTreeViewController
    private let window: NSWindow
    private var opened: [(String, [String])] = []

    init() async throws {
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { path in
            guard let entries = folders[path] else {
                throw POSIXError(.ENOENT)
            }
            return entries
        }, directoryCheck: { folders[$0] != nil }, volumes: { [] }, watcher: FakeWatcher.factory)
        tree = FolderTreeViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = tree
        workspace.onChange = { [tree] in tree.render() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 200 where workspace.state(of: .left).status != .loaded || workspace.treeRoots.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        tree.render()
        tree.view.layoutSubtreeIfNeeded()
        workspace.system.openWithApp = { [weak self] app, paths, _ in self?.opened.append((app, paths)) }
    }

    isolated deinit {
        window.close()
    }

    @Test func aRightClickOnAFolderGoesThereAndOffersItsFolderActions() async throws {
        let shown = try open(rightClickOn: "Documents")
        #expect(shown == [
            "New Folder", "Calculate Folder Sizes", "-", "Copy Path", "Compare Folders", "Git Clone…", "-",
            "Open in Terminal",
            "Open in Code", "-", "Move Up in Favorites", "Move Down in Favorites", "Remove from Favorites",
        ]) // Documents is one of the default favorites
        #expect(workspace.state(of: .left).location == "/home/Documents")
        try choose("Open in Terminal")
        try await waitUntil { !self.opened.isEmpty }
        #expect(opened.map(\.0) == ["iTerm"] && opened.map(\.1) == [["/home/Documents"]])
    }

    /// #33: Copy Path from the tree's menu copies that folder's path.
    @Test func copyPathInTheTreeCopiesTheFoldersPath() async throws {
        var copied: [String] = []
        workspace.system.copyText = { copied.append($0) }
        _ = try open(rightClickOn: "Documents")
        try choose("Copy Path")
        try await waitUntil { !copied.isEmpty }
        #expect(copied == ["/home/Documents"])
    }

    @Test func theKeyboardMenuIsForTheSelectedFolder() throws {
        let shown = try whileOpen { tree.outlineView.showContextMenuForSelection(nil) }
        #expect(shown.first == "New Folder")
        #expect(workspace.state(of: .left).location == "/home") // the selected node: Home
        #expect(tree.menuFolder == "/home")
        #expect(tree.outlineView.selectionAnchorRect == tree.outlineView.rect(ofRow: tree.outlineView.selectedRow))
    }

    @Test func sectionHeadersAndEmptySpaceHaveNoMenu() throws {
        let menu = NSMenu()
        let section = try #require(row("Favorites"))
        tree.prepareContextMenu(menu, clickedRow: section)
        #expect(menu.items.isEmpty && tree.menuFolder == nil)
        tree.prepareContextMenu(menu, clickedRow: -1)
        #expect(menu.items.isEmpty)
    }

    // MARK: Helpers

    @Test func favoritesAreAddedAndRemovedFromTheMenu() async throws {
        workspace.perform(.expandTreeNode(.left, TreeNodeID(root: "favorites:/home", path: "/home")))
        try await waitUntil { self.row("Music") != nil }
        var shown = try open(rightClickOn: "Music") // under Home: not a favorite
        #expect(shown.suffix(2) == ["-", "Add to Favorites"])
        try choose("Add to Favorites")
        #expect(workspace.favorites.last == "/home/Music")
        tree.render()
        let musicRows = (0 ..< tree.outlineView.numberOfRows).filter {
            (tree.outlineView.item(atRow: $0) as? TreeItem)?.title == "Music"
        }
        #expect(musicRows.count == 2) // a favorite now, and still under Home

        shown = try open(rightClickOn: "Music") // the first row: the favorite
        #expect(shown.suffix(3) == ["-", "Move Up in Favorites", "Remove from Favorites"])
        try choose("Remove from Favorites")
        #expect(!workspace.favorites.contains("/home/Music"))
    }

    private func row(_ title: String) -> Int? {
        (0 ..< tree.outlineView.numberOfRows).first { (tree.outlineView.item(atRow: $0) as? TreeItem)?.title == title }
    }

    private func open(rightClickOn title: String) throws -> [String] {
        let outline = tree.outlineView
        let rect = try outline.rect(ofRow: #require(row(title)))
        let location = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        return try whileOpen { outline.rightMouseDown(with: event) }
    }

    /// Runs `show`, which opens the outline view's menu; a timer reads it and closes it.
    private func whileOpen(_ show: () -> Void) throws -> [String] {
        let reader = try MenuReader(#require(tree.outlineView.menu))
        reader.menu.removeAllItems() // so items left from an earlier opening never count
        RunLoop.main.add(reader.timer, forMode: .common)
        show()
        reader.timer.invalidate()
        // A test host that is not the active app sometimes gets no menu tracking at all: the
        // pop-up returns at once. The menu was still prepared for this click (menuNeedsUpdate),
        // and its items are what is checked.
        let titles = reader.titles ?? reader.menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        try #require(!titles.isEmpty, "the menu was not prepared")
        return titles
    }

    private func choose(_ title: String) throws {
        let menu = try #require(tree.outlineView.menu)
        let item = try #require(menu.items.first { $0.title == title })
        _ = item.target?.perform(item.action, with: item)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
