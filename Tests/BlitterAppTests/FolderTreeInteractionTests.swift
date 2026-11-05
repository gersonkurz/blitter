import AppKit
@testable import Blitter
import BlitterCore
import BlitterModel
import Testing

private let treeFolders: [String: [DirectoryEntry]] = [
    "/home": [folder("Documents"), folder("Music"), file("notes.txt")],
    "/home/Documents": [folder("Projects"), file("a.txt")],
    "/home/Documents/Projects": [],
    "/home/Music": [],
    "/Volumes/Disk": [folder("Archive")],
    "/Volumes/Disk/Archive": [],
]

/// Drives one whole side (tree and file list) in a real window: the tree follows the list, and
/// clicking, expanding and arrowing through the tree drive the side.
@MainActor
@Suite(.serialized)
final class FolderTreeInteractionTests {
    private let workspace: Workspace
    private let controller: SideViewController
    private let window: NSWindow

    init() async throws {
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { path in
            guard let entries = treeFolders[path] else {
                throw POSIXError(.ENOENT)
            }
            return entries
        }, directoryCheck: { treeFolders[$0] != nil }, volumes: {
            [MountedVolume(name: "Disk", path: "/Volumes/Disk", isLocal: true, isRoot: false)]
        }, watcher: { _ in FakeWatcher() })
        controller = SideViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil {
            self.workspace.state(of: .left).status == .loaded && self.workspace.treeRoots.count == 6
        }
        controller.render()
    }

    isolated deinit {
        window.close()
    }

    @Test func theTreeShowsSectionsAndSelectsTheSidesFolder() {
        #expect(rowTitles().prefix(3) == ["Favorites", "Home", "Desktop"])
        #expect(rowTitles().contains("Volumes") && rowTitles().contains("Disk"))
        #expect(selectedTitle() == "Home")
    }

    @Test func navigatingTheListRevealsTheFolderInTheTree() async throws {
        workspace.perform(.open(.left, name: "Documents"))
        try await waitUntil { self.selectedTitle() == "Documents" && self.selectedRoot() == "favorites:/home" }
        // Revealed under Home, which is now expanded and shows its subfolders.
        let titles = rowTitles()
        let home = try #require(titles.firstIndex(of: "Home"))
        #expect(Array(titles[home + 1 ... home + 2]) == ["Documents", "Music"])
    }

    @Test func clickingANodeNavigatesTheSide() async throws {
        let disk = try #require(row(titled: "Disk"))
        outlineView.selectRowIndexes([disk], byExtendingSelection: false)
        try await waitUntil { self.workspace.state(of: .left).entriesLocation == "/Volumes/Disk" }
        #expect(workspace.state(of: .left).visibleEntries.map(\.entry.name) == ["Archive"])
        #expect(selectedTitle() == "Disk")
    }

    @Test func expandingANodeShowsItsSubfolders() async throws {
        let diskRow = try #require(row(titled: "Disk"))
        let item = try #require(outlineView.item(atRow: diskRow))
        outlineView.expandItem(item)
        try await waitUntil { self.rowTitles().contains("Archive") }
        #expect(workspace.state(of: .left).tree.expanded.contains(TreeNodeID(root: "volumes:/Volumes/Disk",
                                                                             path: "/Volumes/Disk")))
        try outlineView.collapseItem(outlineView.item(atRow: #require(row(titled: "Disk"))))
        #expect(!rowTitles().contains("Archive"))
        // The model hears of it once AppKit is done collapsing (crash report 2026-11-01).
        try await waitUntil { self.workspace.state(of: .left).tree.expanded.isEmpty }
    }

    /// Crash report 2026-11-01: collapsing a node whose children are expanded. AppKit tells us
    /// about each item it collapses while it is still at work; re-rendering the tree right there
    /// pulled the rows from under it (EXC_BAD_ACCESS in _recursiveCollapseItemEntry).
    @Test func collapsingANodeWithExpandedChildrenIsSafe() async throws {
        for collapseChildren in [false, true] {
            try expand("Home")
            try await waitUntil { self.rowTitles().contains("Documents") && self.rowTitles().contains("Music") }
            try expand("Documents")
            try await waitUntil { self.rowTitles().contains("Projects") }
            let homeRow = try #require(row(titled: "Home"))
            let home = try #require(outlineView.item(atRow: homeRow))
            outlineView.collapseItem(home, collapseChildren: collapseChildren)
            try await Task.sleep(for: .milliseconds(100))
            #expect(!rowTitles().contains("Projects"), "\(collapseChildren)")
            #expect(!workspace.state(of: .left).tree.expanded.contains { $0.path == "/home" })
        }
    }

    private func expand(_ title: String) throws {
        let index = try #require(row(titled: title))
        let item = try #require(outlineView.item(atRow: index))
        outlineView.expandItem(item)
    }

    @Test func arrowKeysInTheTreeNavigate() async throws {
        window.makeFirstResponder(outlineView)
        #expect(workspace.activeSide == .left)
        let downArrow = try String(Character(#require(UnicodeScalar(NSDownArrowFunctionKey))))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: downArrow, charactersIgnoringModifiers: downArrow,
                                     isARepeat: false, keyCode: 125)
        let down = try #require(event)
        outlineView.keyDown(with: down) // Home → Desktop
        try await waitUntil { self.workspace.state(of: .left).location == "/home/Desktop" }
        #expect(selectedTitle() == "Desktop")
    }

    /// #14: the tree looks like the file list, and section headers have no grey group band.
    @Test func theTreeHasTheFileListsLook() throws {
        #expect(outlineView.style == .fullWidth)
        #expect(outlineView.backgroundColor == .controlBackgroundColor)
        #expect(outlineView.usesAlternatingRowBackgroundColors)
        #expect(outlineView.rowHeight == ListFonts.current(FontSettings()).rowHeight)
        let favorites = try #require(row(titled: "Favorites"))
        let rowView = try #require(outlineView.rowView(atRow: favorites, makeIfNecessary: true))
        #expect(rowView is SectionRowView && !rowView.isGroupRowStyle)
    }

    /// Sections are the fixed root: they can't be collapsed (a collapse would also come undone at
    /// the next rebuild of the tree).
    @Test func sectionsStayOpen() throws {
        let favoritesRow = try #require(row(titled: "Favorites"))
        let favorites = try #require(outlineView.item(atRow: favoritesRow))
        outlineView.collapseItem(favorites)
        #expect(outlineView.isItemExpanded(favorites))
        #expect(rowTitles().contains("Home"))
    }

    // MARK: Helpers

    private var outlineView: NSOutlineView {
        let tree = controller.splitViewItems[0].viewController
        // swiftlint:disable:next force_cast
        return (tree.view as! NSScrollView).documentView as! NSOutlineView
    }

    private func rowTitles() -> [String] {
        (0 ..< outlineView.numberOfRows).compactMap { (outlineView.item(atRow: $0) as? TreeItem)?.title }
    }

    private func row(titled title: String) -> Int? {
        rowTitles().firstIndex(of: title)
    }

    private func selectedTitle() -> String? {
        (outlineView.item(atRow: outlineView.selectedRow) as? TreeItem)?.title
    }

    private func selectedRoot() -> String? {
        (outlineView.item(atRow: outlineView.selectedRow) as? TreeItem)?.node?.root
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
