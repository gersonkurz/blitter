import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// Folders whose contents a test can change between reads.
final class ChangingFolders: Sendable {
    private let folders: Mutex<[String: [DirectoryEntry]]>
    private let requests = Mutex<[String]>([])

    init(_ folders: [String: [DirectoryEntry]]) {
        self.folders = Mutex(folders)
    }

    subscript(path: String) -> [DirectoryEntry]? {
        get { folders.withLock { $0[path] } }
        set { folders.withLock { $0[path] = newValue } }
    }

    var listed: [String] {
        requests.withLock { $0 }
    }

    func list(_ path: String) async throws -> [DirectoryEntry] {
        requests.withLock { $0.append(path) }
        guard let entries = self[path] else {
            throw POSIXError(.ENOENT)
        }
        return entries
    }
}

@MainActor
struct LiveUpdatesTests {
    private let folders = ChangingFolders([
        "/home": [entry("Documents", .directory), entry("a.txt"), entry("b.txt")],
        "/home/Documents": [entry("Old", .directory)],
        "/home/Documents/Old": [],
        "/elsewhere": [entry("x")],
    ])

    private func makeWorkspace() async -> Workspace {
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: folders.list,
                                  directoryCheck: { _ in false }, volumes: { [] },
                                  watcher: FakeWatcher.factory)
        await workspace.settle()
        return workspace
    }

    private func watched(_ workspace: Workspace) -> Set<String> {
        (workspace.watcher as? FakeWatcher)?.watched ?? []
    }

    private func names(_ workspace: Workspace, _ side: Side = .left) -> [String] {
        workspace.state(of: side).visibleEntries.map(\.entry.name)
    }

    @Test func theShownFoldersAndExpandedTreeFoldersAreWatched() async {
        let workspace = await makeWorkspace()
        #expect(watched(workspace) == ["/home"])

        workspace.perform(.navigate(.right, path: "/elsewhere"))
        await workspace.settle()
        #expect(watched(workspace) == ["/home", "/elsewhere"])

        // An expanded tree folder is watched once its subfolders are shown.
        let documents = TreeNodeID(root: "favorites:/home", path: "/home/Documents")
        workspace.perform(.expandTreeNode(.left, documents))
        await workspace.settle()
        #expect(watched(workspace) == ["/home", "/elsewhere", "/home/Documents"])
        workspace.perform(.collapseTreeNode(.left, documents))
        #expect(watched(workspace) == ["/home", "/elsewhere"])
    }

    @Test func aChangeReadsTheFolderAgainAndKeepsTheSelection() async {
        let workspace = await makeWorkspace()
        workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        let before = workspace.state(of: .left)

        folders["/home"] = [entry("Documents", .directory), entry("a.txt", size: 99), entry("c.txt")]
        workspace.foldersChanged([FolderChange(path: "/home", includesSubfolders: false)])
        // Until the new listing arrives, the old one stays.
        #expect(names(workspace) == ["Documents", "a.txt", "b.txt"])
        await workspace.settle()

        let after = workspace.state(of: .left)
        #expect(names(workspace) == ["Documents", "a.txt", "c.txt"])
        #expect(after.visibleEntries[1].entry.size == 99)
        #expect(after.selection == ["a.txt"]) // b.txt is gone
        #expect(after.entriesVersion > before.entriesVersion)
        #expect(after.location == "/home" && after.backStack.isEmpty)
        // Both sides show /home, so both were read again.
        #expect(names(workspace, .right) == ["Documents", "a.txt", "c.txt"])
    }

    @Test func changesElsewhereReadNothing() async {
        let workspace = await makeWorkspace()
        let reads = folders.listed.count
        workspace.foldersChanged([FolderChange(path: "/home/Documents/Old", includesSubfolders: false),
                                  FolderChange(path: "/unrelated", includesSubfolders: true)])
        await workspace.settle()
        #expect(folders.listed.count == reads)
    }

    @Test func aRescanOfAnAncestorReadsTheFolderAgain() async {
        let workspace = await makeWorkspace()
        let reads = folders.listed.count
        workspace.foldersChanged([FolderChange(path: "/", includesSubfolders: true)])
        await workspace.settle()
        #expect(folders.listed.count == reads + 2) // /home for each side
    }

    @Test func aBatchOfChangesReadsEachFolderOnce() async {
        let workspace = await makeWorkspace()
        let reads = folders.listed.count
        workspace.foldersChanged([FolderChange(path: "/home", includesSubfolders: false),
                                  FolderChange(path: "/", includesSubfolders: true)])
        await workspace.settle()
        #expect(folders.listed.count == reads + 2)
    }

    @Test func expandedTreeFoldersFollowChangesWithoutFlickering() async {
        let workspace = await makeWorkspace()
        let documents = TreeNodeID(root: "favorites:/home", path: "/home/Documents")
        workspace.perform(.expandTreeNode(.left, documents))
        await workspace.settle()
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == .loaded([
            TreeFolder(name: "Old", isHidden: false),
        ]))

        folders["/home/Documents"] = [entry("New", .directory), entry("Old", .directory)]
        workspace.foldersChanged([FolderChange(path: "/home/Documents", includesSubfolders: false)])
        // The old subfolders stay visible while they are read again; no "loading" in between.
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == .loaded([
            TreeFolder(name: "Old", isHidden: false),
        ]))
        await workspace.settle()
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == .loaded([
            TreeFolder(name: "New", isHidden: false), TreeFolder(name: "Old", isHidden: false),
        ]))
    }

    @Test func aTreeReadThatFindsNothingNewDoesNotNotify() async {
        let workspace = await makeWorkspace()
        workspace.perform(.expandTreeNode(.left, TreeNodeID(root: "favorites:/home", path: "/home/Documents")))
        await workspace.settle()
        let version = workspace.state(of: .left).tree.version
        var changes = 0
        workspace.onChange = { changes += 1 }
        // A file was added: the folder changed, its subfolders did not.
        folders["/home/Documents"] = [entry("Old", .directory), entry("new.txt")]
        workspace.foldersChanged([FolderChange(path: "/home/Documents", includesSubfolders: false)])
        await workspace.settle()
        #expect(workspace.state(of: .left).tree.version == version)
        #expect(changes == 0)
    }

    @Test func aDeletedFolderShowsTheError() async {
        let workspace = await makeWorkspace()
        workspace.perform(.navigate(.left, path: "/elsewhere"))
        await workspace.settle()
        folders["/elsewhere"] = nil
        workspace.foldersChanged([FolderChange(path: "/elsewhere", includesSubfolders: true)])
        await workspace.settle()
        #expect(workspace.state(of: .left).status == .failed("/elsewhere: No such file or directory"))
    }

    // MARK: Freshness

    @Test func anExpandedFolderIsWatchedBeforeItIsRead() async {
        let slow = SlowFirstRead(folders, slowPath: "/home/Documents")
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: slow.list,
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        workspace.perform(.expandTreeNode(.left, TreeNodeID(root: "favorites:/home", path: "/home/Documents")))
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == .loading)
        #expect(watched(workspace).contains("/home/Documents"))
        slow.release()
        await workspace.settle()
    }

    /// Two reads of the same tree folder that finish in reverse order: the newer one wins.
    @Test func anOlderTreeReadNeverOverwritesANewerOne() async throws {
        let slow = SlowFirstRead(folders, slowPath: "/home/Documents")
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: slow.list,
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        // First read: it takes its snapshot (the old contents), then is held back.
        workspace.perform(.expandTreeNode(.left, TreeNodeID(root: "favorites:/home", path: "/home/Documents")))
        for _ in 0 ..< 400 where !slow.firstReadHasSnapshot {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(slow.firstReadHasSnapshot)
        // The folder changes; the second read starts and finishes first with the new contents.
        folders["/home/Documents"] = [entry("New", .directory)]
        workspace.foldersChanged([FolderChange(path: "/home/Documents", includesSubfolders: false)])
        for _ in 0 ..< 200 where workspace.treeChildren(of: "/home/Documents", on: .left) == .loading {
            try await Task.sleep(for: .milliseconds(5))
        }
        let newer = TreeChildren.loaded([TreeFolder(name: "New", isHidden: false)])
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == newer)

        slow.release() // the old read returns its old snapshot now
        for _ in 0 ..< 400 where !slow.firstReadHasReturned {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(slow.firstReadHasReturned)
        await workspace.settle()
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == newer)
        #expect(workspace.treeWork[.left]?["/home/Documents"] == nil)
    }

    /// Being watched again (by the other side) does not make subfolders read during an earlier
    /// watched interval current: what changed while nobody watched must still be read.
    @Test func aChangeWhileUnwatchedShowsEvenIfTheOtherSideWatchesAgain() async {
        let workspace = await makeWorkspace()
        let documents = TreeNodeID(root: "favorites:/home", path: "/home/Documents")
        workspace.perform(.expandTreeNode(.left, documents))
        await workspace.settle()
        workspace.perform(.collapseTreeNode(.left, documents))
        #expect(!watched(workspace).contains("/home/Documents"))

        folders["/home/Documents"] = [entry("Added", .directory), entry("Old", .directory)]
        workspace.perform(.navigate(.right, path: "/home/Documents")) // watched again, by the right side
        await workspace.settle()
        #expect(watched(workspace).contains("/home/Documents"))

        workspace.perform(.expandTreeNode(.left, documents))
        await workspace.settle()
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == .loaded([
            TreeFolder(name: "Added", isHidden: false), TreeFolder(name: "Old", isHidden: false),
        ]))
    }

    /// The same through revealing: navigating into a folder expands its stale parent again.
    @Test func revealingReadsAStaleParentAgain() async {
        let workspace = await makeWorkspace()
        let documents = TreeNodeID(root: "favorites:/home", path: "/home/Documents")
        workspace.perform(.expandTreeNode(.left, documents))
        await workspace.settle()
        workspace.perform(.collapseTreeNode(.left, documents))

        folders["/home/Documents"] = [entry("Added", .directory), entry("Old", .directory)]
        workspace.perform(.navigate(.right, path: "/home/Documents"))
        workspace.perform(.navigate(.left, path: "/home/Documents/Old")) // reveals Documents expanded
        await workspace.settle()
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == .loaded([
            TreeFolder(name: "Added", isHidden: false), TreeFolder(name: "Old", isHidden: false),
        ]))
    }

    /// The case that made collapsed folders stale: collapse, change while unwatched, expand.
    @Test func aChangeWhileCollapsedShowsAfterExpandingAgain() async {
        let workspace = await makeWorkspace()
        let documents = TreeNodeID(root: "favorites:/home", path: "/home/Documents")
        workspace.perform(.expandTreeNode(.left, documents))
        await workspace.settle()
        workspace.perform(.collapseTreeNode(.left, documents))
        #expect(!watched(workspace).contains("/home/Documents"))

        folders["/home/Documents"] = [entry("Added", .directory), entry("Old", .directory)]
        workspace.perform(.expandTreeNode(.left, documents))
        await workspace.settle()
        #expect(workspace.treeChildren(of: "/home/Documents", on: .left) == .loaded([
            TreeFolder(name: "Added", isHidden: false), TreeFolder(name: "Old", isHidden: false),
        ]))
    }
}

/// Holds back the first read of one folder, returning what it contained when the read started.
final class SlowFirstRead: Sendable {
    private let folders: ChangingFolders
    private let slowPath: String
    private let gate = DispatchSemaphore(value: 0)
    private let calls = Mutex(0)
    private let progress = Mutex((snapshot: false, returned: false))

    init(_ folders: ChangingFolders, slowPath: String) {
        self.folders = folders
        self.slowPath = slowPath
    }

    var firstReadHasSnapshot: Bool {
        progress.withLock { $0.snapshot }
    }

    var firstReadHasReturned: Bool {
        progress.withLock { $0.returned }
    }

    func release() {
        gate.signal()
    }

    func list(_ path: String) async throws -> [DirectoryEntry] {
        let entries = try await folders.list(path)
        guard path == slowPath, calls.withLock({ count in
            count += 1
            return count == 1
        }) else {
            return entries
        }
        progress.withLock { $0.snapshot = true }
        let gate = gate
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                gate.wait()
                continuation.resume()
            }
        }
        progress.withLock { $0.returned = true }
        return entries
    }
}
