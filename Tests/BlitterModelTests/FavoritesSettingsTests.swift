import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #72: the Favorites in the settings file, written by changes from the tree (that line only),
/// read when the file changes; and Add to Favorites from the file list.
@MainActor
@Suite(.serialized)
struct FavoritesSettingsTests {
    private func makeWorkspace(settingsFile: String?, restoring saved: WorkspaceState? = nil) async -> Workspace {
        let folders = FakeFolders([
            "/Users/me": [entry("Projects", .directory), entry("notes.txt")],
            "/Users/me/Projects": [],
        ])
        let workspace = Workspace(initialLocation: "/Users/me", home: "/Users/me", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] },
                                  watcher: FakeWatcher.factory, restoring: saved, settingsFile: settingsFile)
        await workspace.settle()
        return workspace
    }

    private func titles(_ workspace: Workspace) -> [String] {
        workspace.treeRoots.filter { $0.section == .favorites }.map(\.title)
    }

    @Test func theSettingsFileWritesAndReadsThem() {
        var settings = Settings()
        #expect(Settings.parse(Settings.fileText(settings)).settings.favorites == nil) // a commented example
        settings.favorites = ["~", "~/Projects", "/Volumes/Data \"x\""]
        let read = Settings.parse(Settings.fileText(settings))
        #expect(read.problems.isEmpty && read.settings == settings)
        let wrong = Settings.parse("[favorites]\nfolders = [\"~\", 3]\nother = 1\n")
        #expect(wrong.settings.favorites == nil && wrong.problems.count == 2)
    }

    @Test func aChangeEditsOnlyTheFavoritesLine() throws {
        let text = "# mine\n[files]\nconfirm_delete = false  # keep\n"
        let edited = try #require(Settings.settingFavorites(["~", "~/Projects"], in: text))
        #expect(edited == text + "\n[favorites]\nfolders = [\"~\", \"~/Projects\"]\n")
        // The default file's commented example: the list goes below the header, comments stay.
        let fromDefault = try #require(Settings.settingFavorites(["~"], in: Settings.defaultFile))
        #expect(fromDefault.contains("[favorites]\nfolders = [\"~\"]\n# folders = ["))
        #expect(Settings.parse(fromDefault).settings.favorites == ["~"])
        // A list spread over lines is the text editor's to change: refused, never broken.
        #expect(Settings.settingFavorites(["~"], in: "[favorites]\nfolders = [\n  \"~/a\",\n]\n") == nil)
        // A [favorites] quoted in a multi-line string comes first: editing it would change the
        // string, not the list (which already is the new one): refused.
        let quoted = "note = \"\"\"\n[favorites]\nfolders = [\"old\"]\n\"\"\"\n\n[favorites]\nfolders = [\"~\"]\n"
        #expect(Settings.settingFavorites(["~"], in: quoted) == nil)
    }

    /// No list in the file: the ones from the window state stay; the first change writes them, as
    /// written ("~"), into the file, which keeps everything else.
    @Test func theFirstChangeMovesThemIntoTheFile() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        let text = "# mine\n[files]\nconfirm_delete = false\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let side = WorkspaceState.SideSettings(location: "/Users/me", sort: ListSort())
        let saved = WorkspaceState(left: side, right: side, showsHiddenFiles: false,
                                   favorites: ["/Users/me", "/Applications"])
        let workspace = await makeWorkspace(settingsFile: path, restoring: saved)
        #expect(titles(workspace) == ["Home", "Applications"])
        workspace.perform(.addFavorite("/Users/me/Projects"))
        #expect(titles(workspace) == ["Home", "Applications", "Projects"]) // at once
        await workspace.settle()
        #expect(try String(contentsOfFile: path, encoding: .utf8)
            == text + "\n[favorites]\nfolders = [\"~\", \"/Applications\", \"~/Projects\"]\n")
        #expect(workspace.notices.isEmpty && workspace.pendingFavorites == nil)
        #expect(workspace.favoritesAsWritten == ["~", "/Applications", "~/Projects"])
    }

    /// A change in the file reaches the tree; a favorite that goes takes its open nodes along.
    @Test func aChangeInTheFileReachesTheTree() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[favorites]\nfolders = [\"~\", \"~/Projects\"]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        #expect(titles(workspace) == ["Home", "Projects"])
        let node = TreeNodeID(root: "favorites:/Users/me/Projects", path: "/Users/me/Projects")
        workspace.perform(.expandTreeNode(.left, node))
        await workspace.settle()
        #expect(workspace.state(of: .left).tree.expanded.contains(node))
        try "[favorites]\nfolders = [\"/Applications\", \"~\"]\n".write(toFile: path, atomically: true, encoding: .utf8)
        workspace.loadSettings() // what the watcher does when the file changes
        await workspace.settle()
        #expect(titles(workspace) == ["Applications", "Home"])
        #expect(!workspace.state(of: .left).tree.expanded.contains(node))
    }

    /// Add to Favorites in the file list: the one selected folder, or the folder itself.
    @Test func addToFavoritesFromTheFileList() async {
        let workspace = await makeWorkspace(settingsFile: nil)
        let count = workspace.favorites.count
        workspace.perform(.select(.left, ["notes.txt"]))
        #expect(!workspace.canRun("add-to-favorites", on: .left)) // a file
        workspace.perform(.select(.left, ["Projects", "notes.txt"]))
        #expect(!workspace.canRun("add-to-favorites", on: .left)) // more than one
        workspace.perform(.select(.left, ["Projects"]))
        workspace.perform(.runAction("add-to-favorites", .left))
        #expect(workspace.favorites.last == "/Users/me/Projects")
        workspace.perform(.select(.left, []))
        workspace.perform(.runAction("add-to-favorites", .left)) // the folder: Home, already one
        #expect(workspace.favorites.count == count + 1)
        #expect(!workspace.treeContextMenu(for: "/Users/me").contains { // the tree has its own entries
            if case .action("add-to-favorites", _) = $0 {
                true
            } else {
                false
            }
        })
    }

    /// A Favorites change from the tree held just before it replaces the file, a newer list saved
    /// from the Settings window meanwhile: the newer one is what the file and the tree end with
    /// (#72 review). The window's save waits for the older write.
    @Test func aNewerSaveFromTheWindowWins() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[favorites]\nfolders = [\"~\"]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let gate = DispatchSemaphore(value: 0)
        let first = OnceFlag()
        workspace.settingsFileBeforeReplace = {
            if first.take() {
                gate.wait() // the older write, held
            }
        }
        let original = workspace.settings
        workspace.perform(.addFavorite("/Users/me/Projects")) // the older change
        try await Task.sleep(for: .milliseconds(100)) // it reaches the held point
        var edited = original
        edited.favorites = ["/Applications"]
        workspace.perform(.saveSettings(original: original, edited: edited)) // the newer one
        try await Task.sleep(for: .milliseconds(100))
        gate.signal()
        await workspace.settle()
        _ = await workspace.finishSavingSettings()
        await workspace.settle()
        #expect(try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings
            .favorites == ["/Applications"])
        #expect(workspace.favorites == ["/Applications"])
    }

    /// Held first write (list A), a window save (B) queued, then the tree changes away from A and
    /// back to A: the newest is A, and the file and the tree end with it (#72 review).
    @Test func theNewestChangeWinsEvenWhenItRepeatsAnOlderList() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[favorites]\nfolders = [\"~\"]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let gate = DispatchSemaphore(value: 0)
        let first = OnceFlag()
        workspace.settingsFileBeforeReplace = {
            if first.take() {
                gate.wait()
            }
        }
        let original = workspace.settings
        workspace.perform(.addFavorite("/Users/me/Projects")) // A, held
        try await Task.sleep(for: .milliseconds(100))
        var edited = original
        edited.favorites = ["/Applications"]
        workspace.perform(.saveSettings(original: original, edited: edited)) // B
        workspace.perform(.addFavorite("/Applications")) // away from A …
        workspace.perform(.removeFavorite("/Applications")) // … and back to A
        let newest = workspace.favorites
        #expect(newest == ["/Users/me", "/Users/me/Projects"])
        try await Task.sleep(for: .milliseconds(100))
        gate.signal()
        await workspace.settle()
        _ = await workspace.finishSavingSettings()
        await workspace.finishSavingFavorites()
        await workspace.settle()
        #expect(try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings.favorites == [
            "~",
            "~/Projects",
        ])
        #expect(workspace.favorites == newest)
    }

    /// Each folder once, whatever the file says ("~" and its full path are one) (#72 review).
    @Test func eachFavoriteIsOneRoot() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[favorites]\nfolders = [\"~\", \"/Users/me\", \"~/Projects\", \"~/Projects\"]\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        #expect(workspace.favorites == ["/Users/me", "/Users/me/Projects"])
        let ids = workspace.treeRoots.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    /// True the first time only.
    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}
