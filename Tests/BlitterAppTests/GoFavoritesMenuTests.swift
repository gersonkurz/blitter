import AppKit
@testable import Blitter
@testable import BlitterModel
import Testing

/// #72: Go → Favorites lists the tree's Favorites, the first nine with ⌃1 … ⌃9, follows changes,
/// and takes the active side there.
@MainActor
@Suite(.serialized)
struct GoFavoritesMenuTests {
    @Test func theFavoritesAreInTheGoMenu() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let workspace = delegate.workspace
        let goMenu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "Go" }?.submenu)
        let menu = try #require(goMenu.items.first { $0.title == "Favorites" }?.submenu)
        delegate.updateMenuBar()
        let roots = workspace.treeRoots.filter { $0.section == .favorites }
        #expect(menu.items.map(\.title) == roots.map(\.title))
        #expect(menu.items.first?.keyEquivalent == "1" && menu.items.first?.keyEquivalentModifierMask == .control)

        let folder = NSTemporaryDirectory() + "BlitterGoFavorites-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer {
            workspace.perform(.removeFavorite(folder))
            try? FileManager.default.removeItem(atPath: folder)
        }
        workspace.perform(.addFavorite(folder))
        delegate.updateMenuBar()
        let added = try #require(menu.items.last)
        #expect(added.toolTip == folder)
        menu.performActionForItem(at: menu.items.count - 1)
        #expect(workspace.state(of: workspace.activeSide).location == folder)
    }
}

/// Add Folder… in the Settings window skips what is already listed (#72 review).
@MainActor
struct FavoritesEditorTests {
    @Test func aFolderAlreadyListedIsNotAddedAgain() {
        #expect(FavoritesSettings.adding(["~", "~/New", "~/New"], to: ["~", "/Applications"]) == ["~/New"])
    }
}
