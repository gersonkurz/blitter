import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

@MainActor
struct PersistenceTests {
    private let tree: [String: [DirectoryEntry]] = [
        "/Users/me": [
            entry("Documents", .directory),
            entry(".hidden"),
            entry("b.txt", size: 1),
            entry("a.txt", size: 9),
        ],
        "/Users/me/Documents": [entry("x.txt")],
        "/Volumes/Backup": [entry("2026", .directory)],
    ]

    private func makeWorkspace(_ folders: FakeFolders, restoring saved: WorkspaceState? = nil) async -> Workspace {
        let workspace = Workspace(initialLocation: "/Users/me", home: "/Users/me", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] },
                                  watcher: FakeWatcher.factory, restoring: saved)
        await workspace.settle()
        return workspace
    }

    private func saved(left: String, right: String, sort: ListSort = ListSort(),
                       hidden: Bool = false) -> WorkspaceState
    {
        WorkspaceState(left: .init(location: left, sort: sort), right: .init(location: right, sort: ListSort()),
                       showsHiddenFiles: hidden)
    }

    private func names(_ workspace: Workspace, _ side: Side = .left) -> [String] {
        workspace.state(of: side).visibleEntries.map(\.entry.name)
    }

    @Test func theSavedStateHasEachSidesFolderAndSortAndTheHiddenSetting() async {
        let workspace = await makeWorkspace(FakeFolders(tree))
        workspace.perform(.navigate(.right, path: "/Users/me/Documents"))
        workspace.perform(.sort(.left, ListSort(column: .size, ascending: false)))
        workspace.perform(.toggleHiddenFiles)
        await workspace.settle()
        var state = workspace.savedState
        #expect(state.right.recentFolders?.visits.keys.sorted() == ["/Users/me", "/Users/me/Documents"])
        state.right.recentFolders = nil // the strip's own test: RecentFoldersTests (#74)
        #expect(state == saved(left: "/Users/me", right: "/Users/me/Documents",
                               sort: ListSort(column: .size, ascending: false), hidden: true))
    }

    @Test func aRestoredWorkspaceStartsWhereTheLastOneEnded() async {
        let state = saved(left: "/Volumes/Backup", right: "/Users/me/Documents",
                          sort: ListSort(column: .size, ascending: false), hidden: true)
        let workspace = await makeWorkspace(FakeFolders(tree), restoring: state)
        #expect(workspace.state(of: .left).location == "/Volumes/Backup")
        #expect(workspace.state(of: .right).location == "/Users/me/Documents")
        #expect(workspace.state(of: .left).sort == ListSort(column: .size, ascending: false))
        #expect(workspace.showsHiddenFiles)
        #expect(workspace.savedState == state)

        workspace.perform(.navigate(.left, path: "/Users/me"))
        await workspace.settle()
        #expect(names(workspace) == ["Documents", "a.txt", "b.txt", ".hidden"]) // size order, hidden shown
    }

    @Test func aRestoredFolderThatIsGoneFallsBackToHome() async {
        let workspace = await makeWorkspace(FakeFolders(tree), restoring: saved(left: "/Volumes/Gone",
                                                                                right: "/Users/me/Documents"))
        let left = workspace.state(of: .left)
        #expect(left.location == "/Users/me")
        #expect(left.status == .loaded) // no error for the folder that is gone
        #expect(left.backStack.isEmpty) // and no way "back" to it
        #expect(names(workspace) == ["Documents", "a.txt", "b.txt"])
        #expect(workspace.state(of: .right).location == "/Users/me/Documents")
    }

    @Test func onlyTheFirstListingFallsBack() async {
        let folders = ChangingFolders(tree)
        let workspace = Workspace(initialLocation: "/Users/me", home: "/Users/me", lister: folders.list,
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                                  restoring: saved(left: "/Volumes/Backup", right: "/Users/me"))
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Volumes/Backup")

        folders["/Volumes/Backup"] = nil // unmounted later: that is an error now, not a fallback
        workspace.perform(.refresh(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Volumes/Backup")
        #expect(workspace.state(of: .left).status == .failed("/Volumes/Backup: No such file or directory"))
    }

    @Test func navigatingAwayBeforeTheFirstListingEndsTheFallback() async {
        let workspace = Workspace(initialLocation: "/Users/me", home: "/Users/me", lister: FakeFolders(tree).list,
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                                  restoring: saved(left: "/Volumes/Gone", right: "/Users/me"))
        workspace.perform(.navigate(.left, path: "/nowhere")) // before the restored listing arrived
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/nowhere")
        #expect(workspace.state(of: .left).status == .failed("/nowhere: No such file or directory"))
    }

    /// The Kind column is gone (#13): a sort by Kind saved by v0.1 comes back as the default sort.
    @Test func aSavedSortByKindBecomesTheDefault() async {
        let workspace = await makeWorkspace(FakeFolders(tree), restoring: saved(
            left: "/Users/me", right: "/Users/me", sort: ListSort(column: .kind, ascending: false)
        ))
        #expect(workspace.state(of: .left).sort == ListSort())
    }

    @Test func theStateSurvivesJSON() throws {
        let state = saved(left: "/a", right: "/b", sort: ListSort(column: .kind, ascending: false), hidden: true)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }
}
