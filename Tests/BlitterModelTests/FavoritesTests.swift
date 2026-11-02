import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// The tree's Favorites: added, removed, moved, and kept for the next launch.
@MainActor
struct FavoritesTests {
    private func makeWorkspace(restoring saved: WorkspaceState? = nil) async -> Workspace {
        let folders = FakeFolders([
            "/Users/me": [entry("Projects", .directory)],
            "/Users/me/Projects": [entry("sub", .directory)],
            "/Users/me/Projects/sub": [],
        ])
        let workspace = Workspace(initialLocation: "/Users/me", home: "/Users/me", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory,
                                  restoring: saved)
        await workspace.settle()
        return workspace
    }

    private func titles(_ workspace: Workspace) -> [String] {
        workspace.treeRoots.filter { $0.section == .favorites }.map(\.title)
    }

    private func menu(_ workspace: Workspace, _ folder: String) -> [String] {
        workspace.favoriteMenu(for: folder).map(\.title)
    }

    @Test func theDefaultsCanBeAddedToMovedAndRemoved() async {
        let workspace = await makeWorkspace()
        #expect(titles(workspace) == ["Home", "Desktop", "Documents", "Downloads", "Applications"])
        #expect(menu(workspace, "/Users/me/Projects") == ["Add to Favorites"])

        workspace.perform(.addFavorite("/Users/me/Projects"))
        workspace.perform(.addFavorite("/Users/me/Projects")) // once is enough
        #expect(titles(workspace) == ["Home", "Desktop", "Documents", "Downloads", "Applications", "Projects"])
        #expect(workspace.treeRoots.first { $0.path == "/Users/me/Projects" }?.kind == .folder)
        #expect(menu(workspace, "/Users/me/Projects") == ["Move Up in Favorites", "Remove from Favorites"])
        #expect(menu(workspace, "/Users/me") == ["Move Down in Favorites", "Remove from Favorites"])
        #expect(menu(workspace, "/Users/me/Desktop") == [
            "Move Up in Favorites", "Move Down in Favorites", "Remove from Favorites",
        ])

        // The menu's commands are what they say.
        for item in workspace.favoriteMenu(for: "/Users/me/Projects") where item.title.hasPrefix("Move Up") {
            workspace.perform(item.command)
        }
        #expect(titles(workspace) == ["Home", "Desktop", "Documents", "Downloads", "Projects", "Applications"])
        workspace.perform(.moveFavorite("/Users/me", offset: -1)) // already first
        workspace.perform(.moveFavorite("/Applications", offset: 1)) // already last
        workspace.perform(.moveFavorite("/Users/me/Projects", offset: -4))
        #expect(titles(workspace) == ["Projects", "Home", "Desktop", "Documents", "Downloads", "Applications"])
        workspace.perform(.moveFavorite("/Users/me", offset: 3))
        #expect(titles(workspace) == ["Projects", "Desktop", "Documents", "Downloads", "Home", "Applications"])
        workspace.perform(.moveFavorite("/Users/me", offset: 2)) // past the end: stays
        for offset in [Int.max, Int.min, -6] { // far past either end, overflowing too: nothing happens
            workspace.perform(.moveFavorite("/Applications", offset: offset))
            workspace.perform(.moveFavorite("/Users/me/Projects", offset: offset))
        }
        #expect(workspace.treeRoots.first { $0.path == "/Users/me" }?.title == "Home") // wherever it is

        #expect(titles(workspace) == ["Projects", "Desktop", "Documents", "Downloads", "Home", "Applications"])
        workspace.perform(.removeFavorite("/Users/me/Desktop"))
        workspace.perform(.removeFavorite("/nowhere"))
        #expect(titles(workspace) == ["Projects", "Documents", "Downloads", "Home", "Applications"])
    }

    @Test func theyAreKeptForTheNextLaunch() async throws {
        let workspace = await makeWorkspace()
        workspace.perform(.addFavorite("/Users/me/Projects"))
        workspace.perform(.removeFavorite("/Applications"))
        let saved = workspace.savedState
        #expect(saved.favorites == [
            "/Users/me", "/Users/me/Desktop", "/Users/me/Documents", "/Users/me/Downloads", "/Users/me/Projects",
        ])
        let data = try JSONEncoder().encode(saved)
        let restored = try await makeWorkspace(restoring: JSONDecoder().decode(WorkspaceState.self, from: data))
        #expect(titles(restored) == ["Home", "Desktop", "Documents", "Downloads", "Projects"])
        // Back to the defaults: none are saved, so later defaults apply.
        restored.perform(.removeFavorite("/Users/me/Projects"))
        restored.perform(.addFavorite("/Applications"))
        #expect(restored.savedState.favorites == nil)

        // A state saved before favorites could change has none: the defaults.
        let side = #"{"location":"/Users/me","sort":{"column":"name","ascending":true}}"#
        let old = Data(#"{"left":\#(side),"right":\#(side),"showsHiddenFiles":false}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: old)
        #expect(decoded.favorites == nil)
        #expect(await titles(makeWorkspace(restoring: decoded)).count == 5)
    }

    @Test func aSideInAFavoriteThatGoesIsShownUnderAnotherRoot() async {
        let workspace = await makeWorkspace()
        workspace.perform(.addFavorite("/Users/me/Projects"))
        workspace.perform(.navigate(.left, path: "/Users/me/Projects"))
        await workspace.settle()
        workspace.perform(.selectTreeNode(.left, TreeNodeID(root: "favorites:/Users/me/Projects",
                                                            path: "/Users/me/Projects")))
        await workspace.settle()
        workspace.perform(.removeFavorite("/Users/me/Projects"))
        await workspace.settle()
        let selection = workspace.state(of: .left).tree.selection
        #expect(selection?.path == "/Users/me/Projects" && selection?.root != "favorites:/Users/me/Projects")
    }

    @Test func aRemovedFavoriteIsNoLongerWatched() async throws {
        let workspace = await makeWorkspace()
        workspace.perform(.addFavorite("/Users/me/Projects"))
        let root = "favorites:/Users/me/Projects"
        for path in ["/Users/me/Projects", "/Users/me/Projects/sub"] {
            workspace.perform(.expandTreeNode(.left, TreeNodeID(root: root, path: path)))
        }
        // The same folder expanded under Home on the other side: that stays.
        workspace.perform(.expandTreeNode(.right, TreeNodeID(root: "favorites:/Users/me", path: "/Users/me")))
        workspace.perform(.expandTreeNode(.right, TreeNodeID(root: "favorites:/Users/me", path: "/Users/me/Projects")))
        await workspace.settle()
        let watcher = try #require(workspace.watcher as? FakeWatcher)
        #expect(watcher.watched.isSuperset(of: ["/Users/me/Projects", "/Users/me/Projects/sub"]))

        workspace.perform(.removeFavorite("/Users/me/Projects"))
        await workspace.settle()
        #expect(!workspace.state(of: .left).tree.expanded.contains { $0.root == root })
        #expect(!watcher.watched.contains("/Users/me/Projects/sub"))
        #expect(watcher.watched.contains("/Users/me/Projects")) // still expanded under Home, on the right
    }
}
