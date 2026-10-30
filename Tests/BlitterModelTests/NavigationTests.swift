import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// A fake file system: listings per folder path, ENOENT for any other path. `slow` paths take
/// `delay` seconds and ignore cancellation, like a listing stuck in a system call.
final class FakeFolders: Sendable {
    private let folders: [String: [DirectoryEntry]]
    private let symlinkTargetsThatAreFolders: Set<String>
    private let slow: Set<String>
    private let delay: Double
    private let requests = Mutex<[String]>([])

    init(_ folders: [String: [DirectoryEntry]], symlinksToFolders: Set<String> = [], slow: Set<String> = [],
         delay: Double = 0.3)
    {
        self.folders = folders
        symlinkTargetsThatAreFolders = symlinksToFolders
        self.slow = slow
        self.delay = delay
    }

    var listed: [String] {
        requests.withLock { $0 }
    }

    func list(_ path: String) async throws -> [DirectoryEntry] {
        requests.withLock { $0.append(path) }
        if slow.contains(path) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        }
        guard let entries = folders[path] else {
            throw POSIXError(.ENOENT)
        }
        return entries
    }

    func isDirectory(_ path: String) async -> Bool {
        if slow.contains(path) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        }
        return folders[path] != nil || symlinkTargetsThatAreFolders.contains(path)
    }
}

@MainActor
struct NavigationTests {
    private let tree: [String: [DirectoryEntry]] = [
        "/": [entry("Users", .directory), entry("tmp", .symlink)],
        "/Users": [entry("me", .directory)],
        "/Users/me": [entry("Documents", .directory), entry("Tool.app", .directory), entry("notes.txt"),
                      entry("docs", .symlink), entry("readme", .symlink)],
        "/Users/me/Documents": [entry("a.txt")],
        "/Users/me/docs": [entry("linked.txt")],
        "/tmp": [entry("scratch")],
    ]

    private func makeWorkspace(_ folders: FakeFolders, at location: String = "/Users/me") async -> Workspace {
        let workspace = Workspace(initialLocation: location, home: "/Users/me", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] },
                                  watcher: FakeWatcher.factory)
        await workspace.settle()
        return workspace
    }

    private func names(_ workspace: Workspace) -> [String] {
        workspace.state(of: .left).visibleEntries.map(\.entry.name)
    }

    @Test(arguments: [
        ("Documents", "/Users/me/Documents"),
        ("~", "/Users/me"),
        ("~/Documents/", "/Users/me/Documents"),
        ("/Users//me/./Documents/../", "/Users/me"),
        ("..", "/Users"),
        ("../../..", "/"),
        ("/", "/"),
        ("/Users/me\n", "/Users/me"),
        ("~other", "/Users/me/~other"),
    ])
    func resolvesTypedPaths(input: String, expected: String) {
        #expect(Paths.resolve(input, relativeTo: "/Users/me", home: "/Users/me") == expected)
    }

    @Test func emptyInputIsIgnored() {
        #expect(Paths.resolve("", relativeTo: "/Users", home: "/Users/me") == nil)
        #expect(Paths.resolve("\n", relativeTo: "/Users", home: "/Users/me") == nil)
    }

    @Test func parentOfRootIsNil() {
        #expect(Paths.parent(of: "/") == nil)
        #expect(Paths.parent(of: "/Users") == "/")
        #expect(Paths.appending("Users", to: "/") == "/Users")
    }

    @Test func navigateListsTheFolderAndRecordsHistory() async {
        let workspace = await makeWorkspace(FakeFolders(tree))
        var changes = 0
        workspace.onChange = { changes += 1 }

        workspace.perform(.navigate(.left, path: "~/Documents"))
        await workspace.settle()
        let state = workspace.state(of: .left)
        #expect(state.location == "/Users/me/Documents")
        #expect(state.entriesLocation == "/Users/me/Documents")
        #expect(names(workspace) == ["a.txt"])
        #expect(state.backStack == ["/Users/me"])
        #expect(state.canGoBack && !state.canGoForward)
        #expect(state.recentLocations == ["/Users/me/Documents", "/Users/me"])
        #expect(changes == 3) // the navigation, the listing, and the tree's subfolders of /Users/me
        // The other side did not move.
        #expect(workspace.state(of: .right).location == "/Users/me")
    }

    @Test func navigatingToTheCurrentFolderRereadsItWithoutHistory() async {
        let folders = FakeFolders(tree)
        let workspace = await makeWorkspace(folders)
        let before = folders.listed.count
        workspace.perform(.navigate(.left, path: "."))
        await workspace.settle()
        #expect(folders.listed.count == before + 1)
        #expect(workspace.state(of: .left).backStack.isEmpty)
    }

    @Test func backAndForwardWalkTheHistory() async {
        let workspace = await makeWorkspace(FakeFolders(tree))
        workspace.perform(.navigate(.left, path: "Documents"))
        workspace.perform(.navigate(.left, path: "/tmp"))
        await workspace.settle()

        workspace.perform(.goBack(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Users/me/Documents")
        workspace.perform(.goBack(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Users/me")
        #expect(!workspace.state(of: .left).canGoBack)
        // Going back past the start does nothing and does not notify.
        var changes = 0
        workspace.onChange = { changes += 1 }
        workspace.perform(.goBack(.left))
        #expect(changes == 0)

        workspace.perform(.goForward(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Users/me/Documents")
        #expect(workspace.state(of: .left).forwardStack == ["/tmp"])

        // A new navigation drops the forward history.
        workspace.perform(.navigate(.left, path: "/"))
        await workspace.settle()
        #expect(!workspace.state(of: .left).canGoForward)
        #expect(workspace.state(of: .left).backStack == ["/Users/me", "/Users/me/Documents"])
        #expect(workspace.state(of: .left).recentLocations == ["/", "/Users/me/Documents", "/Users/me", "/tmp"])
    }

    @Test func goToParentSelectsTheFolderWeCameFrom() async {
        let workspace = await makeWorkspace(FakeFolders(tree), at: "/Users/me/Documents")
        workspace.perform(.goToParent(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Users/me")
        #expect(workspace.state(of: .left).selection == ["Documents"])

        // Back into Documents and back out again also selects it.
        workspace.perform(.goBack(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).selection.isEmpty)
        workspace.perform(.goForward(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).selection == ["Documents"])
    }

    @Test func goToParentStopsAtTheRoot() async {
        let workspace = await makeWorkspace(FakeFolders(tree), at: "/")
        #expect(!workspace.state(of: .left).canGoToParent)
        var changes = 0
        workspace.onChange = { changes += 1 }
        workspace.perform(.goToParent(.left))
        #expect(changes == 0)
    }

    @Test func openEntersFoldersButNotFilesOrPackages() async {
        let workspace = await makeWorkspace(FakeFolders(tree))
        var changes = 0
        workspace.onChange = { changes += 1 }
        workspace.perform(.open(.left, name: "notes.txt"))
        workspace.perform(.open(.left, name: "Tool.app"))
        workspace.perform(.open(.left, name: "missing"))
        #expect(changes == 0)
        #expect(workspace.state(of: .left).location == "/Users/me")

        workspace.perform(.open(.left, name: "Documents"))
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Users/me/Documents")
        #expect(names(workspace) == ["a.txt"])
    }

    @Test func openFollowsSymlinksOnlyToFolders() async {
        let workspace = await makeWorkspace(FakeFolders(tree))
        workspace.perform(.open(.left, name: "readme")) // not a folder
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Users/me")

        workspace.perform(.open(.left, name: "docs"))
        await workspace.settle()
        #expect(workspace.state(of: .left).location == "/Users/me/docs")
        #expect(names(workspace) == ["linked.txt"])
    }

    @Test func aNavigationCancelsASlowSymlinkCheck() async throws {
        let folders = FakeFolders(tree, slow: ["/Users/me/docs"])
        let workspace = await makeWorkspace(folders)
        workspace.perform(.open(.left, name: "docs"))
        workspace.perform(.navigate(.left, path: "/tmp"))
        await workspace.settle()
        try await Task.sleep(for: .milliseconds(400)) // the check has returned by now
        #expect(workspace.state(of: .left).location == "/tmp")
        #expect(workspace.state(of: .left).backStack == ["/Users/me"])
    }

    @Test func rereadingTheCurrentFolderAlsoCancelsASlowSymlinkCheck() async throws {
        let folders = FakeFolders(tree, slow: ["/Users/me/docs"])
        let workspace = await makeWorkspace(folders)
        workspace.perform(.open(.left, name: "docs"))
        workspace.perform(.navigate(.left, path: "."))
        await workspace.settle()
        try await Task.sleep(for: .milliseconds(400)) // the check has returned by now
        #expect(workspace.state(of: .left).location == "/Users/me")
        #expect(workspace.state(of: .left).backStack.isEmpty)
    }

    /// While the next folder loads, the visible rows still belong to the previous one, and opening
    /// one of them must use that folder, even if the loading folder has an entry of the same name.
    @Test func openingAnOldRowWhileLoadingUsesTheFolderItBelongsTo() async {
        var folders = tree
        // The folder being loaded has an entry with the same name as the old row.
        folders["/Users/me/Documents"] = [entry("Documents", .directory)]
        folders["/Users/me/Documents/Documents"] = [entry("nested")]
        let workspace = await makeWorkspace(FakeFolders(folders, slow: ["/Users/me/Documents"]))

        workspace.perform(.navigate(.left, path: "Documents"))
        #expect(workspace.state(of: .left).entriesLocation == "/Users/me") // still the old rows
        workspace.perform(.open(.left, name: "Documents"))
        await workspace.settle()
        // /Users/me + Documents, which is where the side already goes: no deeper, no extra history.
        #expect(workspace.state(of: .left).location == "/Users/me/Documents")
        #expect(workspace.state(of: .left).backStack == ["/Users/me"])
        #expect(names(workspace) == ["Documents"])
    }

    @Test func theOldListingStaysUntilTheNewOneArrives() async {
        let folders = FakeFolders(tree, slow: ["/Users/me/Documents"])
        let workspace = await makeWorkspace(folders)
        workspace.perform(.navigate(.left, path: "Documents"))
        let loading = workspace.state(of: .left)
        #expect(loading.location == "/Users/me/Documents")
        #expect(loading.status == .loading)
        #expect(loading.entriesLocation == "/Users/me")
        #expect(loading.visibleEntries.count == 5)

        await workspace.settle()
        #expect(workspace.state(of: .left).entriesLocation == "/Users/me/Documents")
        #expect(names(workspace) == ["a.txt"])
    }

    @Test func aNewerNavigationWinsOverASlowerOlderOne() async throws {
        let folders = FakeFolders(tree, slow: ["/Users/me/Documents"])
        let workspace = await makeWorkspace(folders)
        workspace.perform(.navigate(.left, path: "Documents"))
        workspace.perform(.navigate(.left, path: "/tmp"))
        await workspace.settle()
        try await Task.sleep(for: .milliseconds(400))
        #expect(workspace.state(of: .left).entriesLocation == "/tmp")
        #expect(names(workspace) == ["scratch"])
    }

    @Test func aMissingFolderReportsTheErrorAndBackReturns() async {
        let workspace = await makeWorkspace(FakeFolders(tree))
        workspace.perform(.navigate(.left, path: "/nowhere"))
        await workspace.settle()
        #expect(workspace.state(of: .left).status == .failed("/nowhere: No such file or directory"))
        #expect(workspace.state(of: .left).visibleEntries.isEmpty)

        workspace.perform(.goBack(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).status == .loaded)
        #expect(workspace.state(of: .left).location == "/Users/me")
    }

    @Test func recentLocationsAreCapped() async {
        var folders = tree
        for index in 0 ..< 30 {
            folders["/f\(index)"] = []
        }
        let workspace = await makeWorkspace(FakeFolders(folders))
        for index in 0 ..< 30 {
            workspace.perform(.navigate(.left, path: "/f\(index)"))
        }
        await workspace.settle()
        let recent = workspace.state(of: .left).recentLocations
        #expect(recent.count == 20)
        #expect(recent.first == "/f29")
    }
}
