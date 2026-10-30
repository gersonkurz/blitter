import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

@MainActor
struct FolderTreeTests {
    private let tree: [String: [DirectoryEntry]] = [
        "/": [entry("Users", .directory), entry("Applications", .directory), entry(".vol", .directory)],
        "/Users": [entry("me", .directory)],
        "/Users/me": [entry("Documents", .directory), entry("Desktop", .directory), entry("Downloads", .directory),
                      entry(".config", .directory), entry("Tool.app", .directory), entry("notes.txt"),
                      entry("link", .symlink), entry("Library", .directory)],
        "/Users/me/Documents": [entry("Projects", .directory), entry("b", .directory), entry("a10", .directory),
                                entry("a9", .directory)],
        "/Users/me/Documents/Projects": [entry("blitter", .directory)],
        "/Users/me/Documents/Projects/blitter": [],
        "/Users/me/Library": [entry("CloudStorage", .directory)],
        "/Users/me/Library/CloudStorage": [entry("GoogleDrive-me@example.com", .directory),
                                           entry("OneDrive-Personal", .directory), entry(".hidden", .directory),
                                           entry("stray.txt")],
        "/Users/me/Library/CloudStorage/OneDrive-Personal": [entry("Shared", .directory)],
        "/Volumes/Backup": [entry("2026", .directory)],
        "/Volumes/Backup/2026": [],
    ]

    private let volumes = [
        MountedVolume(name: "Macintosh HD", path: "/", isLocal: true, isRoot: true),
        MountedVolume(name: "Backup", path: "/Volumes/Backup", isLocal: true, isRoot: false),
    ]

    private func makeWorkspace(_ folders: FakeFolders, at location: String = "/Users/me") async -> Workspace {
        let volumes = volumes
        let workspace = Workspace(initialLocation: location, home: "/Users/me", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { volumes },
                                  watcher: FakeWatcher.factory)
        await workspace.settle()
        return workspace
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    private func node(_ root: String, _ path: String) -> TreeNodeID {
        TreeNodeID(root: root, path: path)
    }

    private func names(_ children: TreeChildren?) -> [String]? {
        guard case let .loaded(folders) = children else {
            return nil
        }
        return folders.map(\.name)
    }

    // MARK: Roots

    @Test func rootsAreFavoritesVolumesAndCloudDrives() async {
        let workspace = await makeWorkspace(FakeFolders(tree, symlinksToFolders: [
            "/Users/me/Library/Mobile Documents/com~apple~CloudDocs",
        ]))
        let roots = workspace.treeRoots.map { "\($0.section.rawValue): \($0.title) \($0.path)" }
        #expect(roots == [
            "favorites: Home /Users/me",
            "favorites: Desktop /Users/me/Desktop",
            "favorites: Documents /Users/me/Documents",
            "favorites: Downloads /Users/me/Downloads",
            "favorites: Applications /Applications",
            "volumes: Macintosh HD /",
            "volumes: Backup /Volumes/Backup",
            "cloud: iCloud Drive /Users/me/Library/Mobile Documents/com~apple~CloudDocs",
            "cloud: GoogleDrive (me@example.com) /Users/me/Library/CloudStorage/GoogleDrive-me@example.com",
            "cloud: OneDrive (Personal) /Users/me/Library/CloudStorage/OneDrive-Personal",
        ])
    }

    @Test func refreshingTheRootsPicksUpANewVolume() async {
        let mounted = MountedVolumesBox(volumes)
        let workspace = Workspace(initialLocation: "/Users/me", home: "/Users/me", lister: FakeFolders(tree).list,
                                  directoryCheck: { _ in false }, volumes: { mounted.value },
                                  watcher: FakeWatcher.factory)
        await workspace.settle()
        #expect(!workspace.treeRoots.contains { $0.title == "Stick" })

        mounted.value.append(MountedVolume(name: "Stick", path: "/Volumes/Stick", isLocal: true, isRoot: false))
        var changes = 0
        workspace.onChange = { changes += 1 }
        workspace.perform(.refreshTreeRoots)
        #expect(changes == 0) // nothing changes until the volumes have been read
        await workspace.settle()
        #expect(workspace.treeRoots.contains { $0.title == "Stick" && $0.section == .volumes })
        #expect(changes == 1)
    }

    /// Volumes are published as soon as they are read, even while the cloud drives hang.
    @Test func aStalledCloudDriveDoesNotHoldBackTheVolumes() async throws {
        let iCloud = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
        let folders = FakeFolders(tree, symlinksToFolders: [iCloud],
                                  slow: ["/Users/me/Library/CloudStorage", iCloud], delay: 1.0)
        let mounted = MountedVolumesBox(volumes)
        let workspace = Workspace(initialLocation: "/Users/me", home: "/Users/me", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { mounted.value },
                                  watcher: FakeWatcher.factory)
        let start = ContinuousClock.now
        try await waitUntil { workspace.treeRoots.contains { $0.title == "Backup" } }
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(!workspace.treeRoots.contains { $0.section == .cloud })
        // Both sides' trees can reveal folders on the volume right away.
        workspace.perform(.navigate(.right, path: "/Volumes/Backup/2026"))
        #expect(workspace.state(of: .right).tree.selection == node("volumes:/Volumes/Backup", "/Volumes/Backup/2026"))

        // A refresh while the cloud drives still hang publishes a new volume just as fast.
        mounted.value.append(MountedVolume(name: "Stick", path: "/Volumes/Stick", isLocal: true, isRoot: false))
        workspace.perform(.refreshTreeRoots)
        try await waitUntil { workspace.treeRoots.contains { $0.title == "Stick" } }
        #expect(ContinuousClock.now - start < .milliseconds(800))

        // The cloud drives arrive once their reads return.
        await workspace.settle()
        #expect(workspace.treeRoots.filter { $0.section == .cloud }.map(\.title)
            == ["iCloud Drive", "GoogleDrive (me@example.com)", "OneDrive (Personal)"])
    }

    // MARK: Expanding

    @Test func expandingReadsPlainFoldersSortedByName() async {
        let workspace = await makeWorkspace(FakeFolders(tree), at: "/Volumes/Backup")
        let documents = node("favorites:/Users/me/Documents", "/Users/me/Documents")
        workspace.perform(.expandTreeNode(.left, documents))
        #expect(workspace.treeChildren(of: "/Users/me/Documents", on: .left) == .loading)
        await workspace.settle()
        #expect(names(workspace.treeChildren(of: "/Users/me/Documents", on: .left)) == ["a9", "a10", "b", "Projects"])
        // Only that side's tree read it.
        #expect(workspace.treeChildren(of: "/Users/me/Documents", on: .right) == nil)

        // Files, packages and symbolic links are not tree nodes; hidden folders only when shown.
        workspace.perform(.expandTreeNode(.left, node("favorites:/Users/me", "/Users/me")))
        await workspace.settle()
        #expect(names(workspace.treeChildren(of: "/Users/me", on: .left))
            == ["Desktop", "Documents", "Downloads", "Library"])
        workspace.perform(.toggleHiddenFiles)
        #expect(names(workspace.treeChildren(of: "/Users/me", on: .left))
            == [".config", "Desktop", "Documents", "Downloads", "Library"])
    }

    /// A collapsed folder is not watched, so expanding it again reads it again; until the new
    /// subfolders arrive, the ones read before stay visible.
    @Test func expandingTwiceDoesNothingAndReexpandingReadsAgain() async {
        let folders = FakeFolders(tree)
        let workspace = await makeWorkspace(folders, at: "/Volumes/Backup")
        let documents = node("favorites:/Users/me/Documents", "/Users/me/Documents")
        workspace.perform(.expandTreeNode(.left, documents))
        await workspace.settle()
        var changes = 0
        workspace.onChange = { changes += 1 }
        workspace.perform(.expandTreeNode(.left, documents))
        #expect(changes == 0)

        workspace.perform(.collapseTreeNode(.left, documents))
        #expect(!workspace.state(of: .left).tree.expanded.contains(documents))
        let reads = folders.listed.count
        workspace.perform(.expandTreeNode(.left, documents))
        #expect(names(workspace.treeChildren(of: "/Users/me/Documents", on: .left)) == ["a9", "a10", "b", "Projects"])
        await workspace.settle()
        #expect(folders.listed.count == reads + 1)
    }

    @Test func collapsingStopsAReadNobodyWaitsFor() async throws {
        let folders = FakeFolders(tree, slow: ["/Users/me/Documents"])
        let workspace = await makeWorkspace(folders, at: "/Volumes/Backup")
        let documents = node("favorites:/Users/me/Documents", "/Users/me/Documents")
        workspace.perform(.expandTreeNode(.left, documents))
        workspace.perform(.collapseTreeNode(.left, documents))
        #expect(workspace.treeChildren(of: "/Users/me/Documents", on: .left) == nil)
        try await Task.sleep(for: .milliseconds(400)) // the slow read has returned by now
        #expect(workspace.treeChildren(of: "/Users/me/Documents", on: .left) == nil)
    }

    @Test func aFailedReadIsTriedAgainOnTheNextExpand() async {
        let workspace = await makeWorkspace(FakeFolders(tree), at: "/Volumes/Backup")
        let missing = node("favorites:/Users/me/Desktop", "/Users/me/Desktop")
        workspace.perform(.expandTreeNode(.left, missing))
        await workspace.settle()
        #expect(workspace.treeChildren(of: "/Users/me/Desktop", on: .left) == .failed)
        workspace.perform(.collapseTreeNode(.left, missing))
        workspace.perform(.expandTreeNode(.left, missing))
        #expect(workspace.treeChildren(of: "/Users/me/Desktop", on: .left) == .loading)
    }

    // MARK: Tree and list in sync

    @Test func theSidesFolderIsRevealedUnderTheMostSpecificRoot() async {
        let workspace = await makeWorkspace(FakeFolders(tree), at: "/Users/me/Documents/Projects/blitter")
        let state = workspace.state(of: .left).tree
        let root = "favorites:/Users/me/Documents"
        #expect(state.selection == node(root, "/Users/me/Documents/Projects/blitter"))
        #expect(state.expanded == [node(root, "/Users/me/Documents"), node(root, "/Users/me/Documents/Projects")])
        #expect(names(workspace.treeChildren(of: "/Users/me/Documents/Projects", on: .left)) == ["blitter"])
    }

    @Test func listNavigationStaysUnderTheCurrentRoot() async {
        let workspace = await makeWorkspace(FakeFolders(tree), at: "/Users/me")
        #expect(workspace.state(of: .left).tree.selection == node("favorites:/Users/me", "/Users/me"))
        // Documents has its own favorite, but the user is browsing under Home.
        workspace.perform(.open(.left, name: "Documents"))
        await workspace.settle()
        #expect(workspace.state(of: .left).tree.selection == node("favorites:/Users/me", "/Users/me/Documents"))

        // Leaving Home falls back to the most specific root that contains the folder.
        workspace.perform(.navigate(.left, path: "/Volumes/Backup/2026"))
        await workspace.settle()
        #expect(workspace.state(of: .left).tree.selection == node("volumes:/Volumes/Backup", "/Volumes/Backup/2026"))
    }

    @Test func selectingANodeNavigatesAndKeepsItsRoot() async {
        let workspace = await makeWorkspace(FakeFolders(tree), at: "/Volumes/Backup")
        // /Users/me through the startup volume, although Home is the more specific root.
        let viaVolume = node("volumes:/", "/Users/me")
        workspace.perform(.selectTreeNode(.left, viaVolume))
        await workspace.settle()
        let state = workspace.state(of: .left)
        #expect(state.location == "/Users/me")
        #expect(state.tree.selection == viaVolume)
        #expect(state.tree.expanded.contains(node("volumes:/", "/Users")))
        #expect(state.backStack == ["/Volumes/Backup"])
        #expect(state.visibleEntries.map(\.entry.name).contains("notes.txt"))

        // The same folder through Home: only the selection moves, nothing is read or recorded.
        var changes = 0
        workspace.onChange = { changes += 1 }
        workspace.perform(.selectTreeNode(.left, node("favorites:/Users/me", "/Users/me")))
        #expect(workspace.state(of: .left).tree.selection == node("favorites:/Users/me", "/Users/me"))
        #expect(workspace.state(of: .left).backStack == ["/Volumes/Backup"])
        #expect(changes == 1)
    }

    @Test func aFolderOutsideEveryRootHasNoSelection() async {
        // No volumes: nothing contains /elsewhere.
        let workspace = Workspace(initialLocation: "/Users/me", home: "/Users/me", lister: FakeFolders(tree).list,
                                  directoryCheck: { _ in false }, volumes: { [] },
                                  watcher: FakeWatcher.factory)
        await workspace.settle()
        workspace.perform(.navigate(.left, path: "/elsewhere"))
        #expect(workspace.state(of: .left).tree.selection == nil)
    }

    /// A tree node on a stalled volume holds up neither the other side nor other nodes.
    @Test func aStalledFolderBlocksNothingElse() async throws {
        let folders = FakeFolders(tree, slow: ["/Volumes/Backup"], delay: 1.0)
        let workspace = await makeWorkspace(folders, at: "/Users/me")
        workspace.perform(.expandTreeNode(.left, node("volumes:/Volumes/Backup", "/Volumes/Backup")))
        workspace.perform(.expandTreeNode(.left, node("favorites:/Users/me/Documents", "/Users/me/Documents")))
        workspace.perform(.navigate(.right, path: "/Users/me/Documents/Projects"))

        let start = ContinuousClock.now
        while workspace.state(of: .right).status != .loaded
            || workspace.treeChildren(of: "/Users/me/Documents", on: .left) == .loading
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(workspace.treeChildren(of: "/Volumes/Backup", on: .left) == .loading)
        #expect(workspace.state(of: .right).visibleEntries.map(\.entry.name) == ["blitter"])
    }
}

/// Mounted volumes that a test can change between reads.
final class MountedVolumesBox: Sendable {
    private let volumes: Mutex<[MountedVolume]>

    init(_ volumes: [MountedVolume]) {
        self.volumes = Mutex(volumes)
    }

    var value: [MountedVolume] {
        get { volumes.withLock { $0 } }
        set { volumes.withLock { $0 = newValue } }
    }
}
