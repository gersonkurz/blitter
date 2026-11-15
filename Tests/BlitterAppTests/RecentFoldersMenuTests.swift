import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// #90: the side's recent folders in the path field's menu: pinned first (with a pin), ⌥ offers
/// Unpin or Remove, the side's own folder is pinned at the bottom; picking one goes there.
@MainActor
@Suite(.serialized)
final class RecentFoldersMenuTests {
    private let workspace: Workspace
    private let list: FileListViewController
    private let window: NSWindow

    init() async throws {
        let folders: [String: [DirectoryEntry]] = ["/home": [folder("Documents")], "/home/Documents": [], "/": []]
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { path in
            guard let entries = folders[path] else {
                throw POSIXError(.ENOENT)
            }
            return entries
        }, directoryCheck: { folders[$0] != nil }, volumes: { [] }, watcher: FakeWatcher.factory)
        list = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        workspace.onChange = { [list] in list.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.workspace.state(of: .left).status == .loaded }
        list.render()
        list.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    @Test func theButtonSitsRightOfThePathFieldAndOpensTheMenu() {
        let button = list.recentFoldersButton
        #expect(button.image != nil && button.toolTip == "Recent Folders")
        #expect(list.pathField.frame.maxX <= button.frame.minX)
        #expect(abs(button.frame.midY - list.pathField.frame.midY) < 2)
        #expect(button.target === list && button.action == NSSelectorFromString("recentFoldersClicked:"))
    }

    @Test func aNewSideHasNoRecentFoldersButCanPinItsOwn() {
        let menu = list.makeRecentFoldersMenu()
        #expect(menu.items.map(\.title) == ["No Recent Folders", "", "Pin This Folder"])
        #expect(!menu.items[0].isEnabled)
        menu.performActionForItem(at: 2)
        #expect(workspace.state(of: .left).recentFolders.pinned == ["/home"])
        #expect(list.makeRecentFoldersMenu().items.last?.title == "Unpin This Folder")
    }

    @Test func pinnedFirstThenTheOthersAndOptionChangesThem() async throws {
        workspace.perform(.navigate(.left, path: "/home/Documents"))
        workspace.perform(.navigate(.left, path: "/"))
        try await waitUntil { self.workspace.state(of: .left).status == .loaded }
        workspace.perform(.recentFolder(.left, "/home", .pin))

        let menu = list.makeRecentFoldersMenu()
        #expect(menu.items.map(\.title) == [
            "/home", "Unpin “/home”",
            "/home/Documents", "Remove “/home/Documents” from Recent Folders",
            "", "Pin This Folder",
        ])
        #expect(menu.items.map(\.isAlternate) == [false, true, false, true, false, false])
        #expect(menu.items[1].keyEquivalentModifierMask == .option)
        #expect(menu.items[0].image != nil && menu.items[2].image == nil) // pinned: marked

        menu.performActionForItem(at: 3) // ⌥: forget Documents
        #expect(workspace.recentFolders(of: .left) == ["/home"])
        list.makeRecentFoldersMenu().performActionForItem(at: 1) // ⌥: unpin /home
        #expect(workspace.state(of: .left).recentFolders.pinned.isEmpty)

        list.makeRecentFoldersMenu().performActionForItem(at: 0) // go to /home
        try await waitUntil { self.workspace.state(of: .left).entriesLocation == "/home" }
        #expect(window.firstResponder === list.tableView)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
