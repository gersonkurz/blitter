import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// Free-space reads that wait until the test lets them return, and count how many run at once.
private final class FreeSpaceGate: Sendable {
    private let state = Mutex((open: false, running: 0, mostAtOnce: 0, folders: [String]()))

    var folders: [String] {
        state.withLock { $0.folders }
    }

    var mostAtOnce: Int {
        state.withLock { $0.mostAtOnce }
    }

    func open() {
        state.withLock { $0.open = true }
    }

    func read(_ folder: String) async -> Int64? {
        state.withLock {
            $0.folders.append(folder)
            $0.running += 1
            $0.mostAtOnce = max($0.mostAtOnce, $0.running)
        }
        while !state.withLock(\.open) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        state.withLock { $0.running -= 1 }
        return folder == "/home" ? 1000 : 2000
    }
}

/// The status line below each file list (#51): totals, what is selected, free space.
@MainActor
struct StatusLineTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    @Test func theListingIsCountedFoldersAndFilesApart() async {
        let files = (1 ... 20).map { entry("file\($0).txt", size: 10) }
        let lister = FakeLister([
            .success([entry("Archive", .directory), entry(".hidden", size: 1000)] + files),
            .success([entry("Archive", .directory), entry(".hidden", size: 1000)] + files),
            .failure(POSIXError(.EACCES)),
        ])
        let workspace = Workspace(initialLocation: "/folder", home: "/home", lister: lister.list,
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.readFreeSpace = { _ in nil }
        await workspace.settle()
        var totals = workspace.state(of: .left).totals
        #expect((totals.folders, totals.files) == (1, 20) && totals.bytes == 200) // hidden items are not shown

        workspace.perform(.toggleHiddenFiles)
        await workspace.settle()
        totals = workspace.state(of: .left).totals
        #expect((totals.folders, totals.files) == (1, 21) && totals.bytes == 1200 && totals.count == 22)

        // Few selected (looked up) and many (one pass) count the same way.
        workspace.perform(.select(.left, ["Archive", "file3.txt"]))
        var selected = workspace.state(of: .left).selectedTotals
        #expect((selected.folders, selected.files) == (1, 1) && selected.bytes == 10)
        workspace.perform(.select(.left, Set(files.map(\.name)).union(["gone"])))
        #expect(!workspace.state(of: .left).selectionIsSparse)
        selected = workspace.state(of: .left).selectedTotals
        #expect((selected.folders, selected.files) == (0, 20) && selected.bytes == 200)

        workspace.reload(showing: ["/folder"]) // the left side's third listing fails
        await workspace.settle()
        let left = workspace.state(of: .left)
        #expect(left.status != .loaded && left.totals == EntryTotals())
    }

    @Test func searchResultsAreCounted() async throws {
        let temporary = try TemporaryFolder()
        try FileManager.default.createDirectory(
            atPath: temporary.path + "/sub/match",
            withIntermediateDirectories: true
        )
        try Data(count: 5).write(to: URL(fileURLWithPath: temporary.path + "/match.txt"))
        try Data(count: 7).write(to: URL(fileURLWithPath: temporary.path + "/sub/match.md"))
        let workspace = Workspace(initialLocation: temporary.path, home: temporary.path,
                                  directoryCheck: { _ in true }, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        workspace.perform(.find(.left, pattern: "match*"))
        await workspace.settle()
        let totals = workspace.state(of: .left).totals
        #expect((totals.folders, totals.files) == (1, 2) && totals.bytes == 12)
        // The real free space of the volume, read in the background.
        let space = try #require(workspace.state(of: .left).freeSpace)
        #expect(space.folder == temporary.path && space.bytes > 0)
    }

    @Test func freeSpaceIsReadOnePerSideAndForTheFolderShown() async throws {
        let folders = FakeFolders(["/home": [entry("Archive", .directory)], "/home/Archive": []])
        let gate = FreeSpaceGate()
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.readFreeSpace = gate.read
        try await waitUntil { gate.folders.count == 2 } // a read per side, both still waiting

        // New listings while those wait: no second read per side, one later instead.
        workspace.reload(showing: ["/home"])
        workspace.perform(.navigate(.left, path: "/home/Archive"))
        try await waitUntil { workspace.state(of: .left).entriesLocation == "/home/Archive" }
        try await Task.sleep(for: .milliseconds(50))
        #expect(gate.folders.count == 2 && gate.mostAtOnce == 2)
        #expect(workspace.state(of: .left).freeSpace == nil)

        gate.open()
        await workspace.settle()
        #expect(gate.folders.sorted() == ["/home", "/home", "/home", "/home/Archive"])
        // The left side's first read, for the folder it left, was replaced by one for its folder.
        #expect(workspace.state(of: .left).freeSpace == FreeSpace(folder: "/home/Archive", bytes: 2000))
        #expect(workspace.state(of: .right).freeSpace == FreeSpace(folder: "/home", bytes: 1000))
    }
}
