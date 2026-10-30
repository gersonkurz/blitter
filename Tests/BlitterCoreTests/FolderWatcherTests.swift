@testable import BlitterCore
import Foundation
import Synchronization
import Testing

/// Collects the batches a watcher reports.
private final class Batches: Sendable {
    private let batches = Mutex<[[FolderChange]]>([])

    func append(_ changes: [FolderChange]) {
        batches.withLock { $0.append(changes) }
    }

    var all: [[FolderChange]] {
        batches.withLock { $0 }
    }

    /// Drops what came in so far, e.g. events from setting up the test folder.
    func reset() {
        batches.withLock { $0.removeAll() }
    }

    /// Waits up to five seconds for a batch that satisfies `condition`.
    func wait(for condition: ([[FolderChange]]) -> Bool) async throws -> Bool {
        for _ in 0 ..< 500 {
            if condition(all) {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition(all)
    }
}

/// Real FSEvents on temporary folders. NSTemporaryDirectory() is under /var, a symbolic link to
/// /private/var, so these also cover mapping resolved paths back to the watched ones.
@Suite(.serialized)
struct FolderWatcherTests {
    @Test func reportsAChangeInAWatchedFolderUnderItsWatchedPath() async throws {
        let folder = try TemporaryFolder()
        #expect(folder.path.hasPrefix("/var/") || !folder.path.hasPrefix("/private/"))
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1) { batches.append($0) }
        watcher.watch([folder.path])
        try await Task.sleep(for: .milliseconds(300)) // the stream starts asynchronously

        folder.createFile("new.txt")
        #expect(try await batches.wait { $0.joined().contains { $0.path == folder.path } })
        withExtendedLifetime(watcher) {}
    }

    @Test func changesInUnwatchedSubfoldersAreIgnored() async throws {
        let folder = try TemporaryFolder()
        try FileManager.default.createDirectory(atPath: folder.path + "/sub", withIntermediateDirectories: false)
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1) { batches.append($0) }
        watcher.watch([folder.path])
        try await Task.sleep(for: .milliseconds(600))
        batches.reset() // creating "sub" itself changed the folder

        FileManager.default.createFile(atPath: folder.path + "/sub/deep.txt", contents: Data())
        try await Task.sleep(for: .milliseconds(600))
        #expect(!batches.all.joined().contains { $0.path == folder.path && !$0.includesSubfolders })
        withExtendedLifetime(watcher) {}
    }

    @Test func aBurstOfChangesArrivesAsOneReport() async throws {
        let folder = try TemporaryFolder()
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.3) { batches.append($0) }
        watcher.watch([folder.path])
        try await Task.sleep(for: .milliseconds(600))
        batches.reset() // creating the folder itself may still be reported

        for index in 0 ..< 200 {
            folder.createFile("file\(index)")
        }
        #expect(try await batches.wait { !$0.isEmpty })
        try await Task.sleep(for: .milliseconds(700))
        // FSEvents hands it out in several chunks; they are merged.
        #expect(batches.all.count == 1, "\(batches.all.count) batches")
        withExtendedLifetime(watcher) {}
    }

    @Test func deletingTheWatchedFolderItselfIsReported() async throws {
        let parent = try TemporaryFolder()
        let watchedPath = parent.path + "/watched"
        try FileManager.default.createDirectory(atPath: watchedPath, withIntermediateDirectories: false)
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1) { batches.append($0) }
        watcher.watch([watchedPath])
        try await Task.sleep(for: .milliseconds(300))

        try FileManager.default.removeItem(atPath: watchedPath)
        #expect(try await batches.wait { $0.joined().contains { $0.path == watchedPath } })
        withExtendedLifetime(watcher) {}
    }

    @Test func rewatchingSwitchesFolders() async throws {
        let first = try TemporaryFolder()
        let second = try TemporaryFolder()
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1) { batches.append($0) }
        watcher.watch([first.path])
        watcher.watch([second.path])
        try await Task.sleep(for: .milliseconds(300))

        first.createFile("ignored")
        second.createFile("seen")
        #expect(try await batches.wait { $0.joined().contains { $0.path == second.path } })
        #expect(!batches.all.joined().contains { $0.path == first.path })
        withExtendedLifetime(watcher) {}
    }

    // MARK: Nothing is lost

    /// The guarantee the workspace relies on: create the watcher, then read; a change in
    /// between is still reported once the folder is watched.
    @Test func aChangeBeforeTheFirstWatchIsReported() async throws {
        let folder = try TemporaryFolder()
        try await Task.sleep(for: .milliseconds(300)) // creating the folder is old news
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1) { batches.append($0) }
        folder.createFile("while-reading")
        // Long enough for FSEvents to have recorded the change before the stream exists.
        try await Task.sleep(for: .seconds(1))
        watcher.watch([folder.path])
        #expect(try await batches.wait { $0.joined().contains { $0.path == folder.path } })
        withExtendedLifetime(watcher) {}
    }

    @Test func aChangeWhileTheWatchedSetIsReplacedIsReported() async throws {
        let first = try TemporaryFolder()
        let second = try TemporaryFolder()
        let batches = Batches()
        // A long latency, so the first stream is certainly replaced before it delivers the change.
        let watcher = FolderWatcher(latency: 2) { batches.append($0) }
        watcher.watch([first.path])
        try await Task.sleep(for: .milliseconds(3000))
        batches.reset()

        first.createFile("during-restart")
        try await Task.sleep(for: .milliseconds(500)) // recorded by FSEvents, not yet delivered
        watcher.watch([first.path, second.path])
        #expect(try await batches.wait { $0.joined().contains { $0.path == first.path } })
        withExtendedLifetime(watcher) {}
    }

    /// Resolving a path on a stalled network volume holds up neither other folders nor later
    /// changes of the watched set.
    @Test func aStalledPathDoesNotStopOtherFolders() async throws {
        let local = try TemporaryFolder()
        let other = try TemporaryFolder()
        let gate = DispatchSemaphore(value: 0)
        let stalled = "/Volumes/Offline/share"
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1, resolve: { path in
            if path == stalled {
                gate.wait()
            }
            return FolderWatcher.realPath(path)
        }, onChange: { batches.append($0) })
        defer { gate.signal() }
        watcher.watch([local.path, stalled])
        try await Task.sleep(for: .milliseconds(300))

        local.createFile("still-seen")
        #expect(try await batches.wait { $0.joined().contains { $0.path == local.path } })
        watcher.watch([local.path, stalled, other.path])
        other.createFile("also-seen")
        #expect(try await batches.wait { $0.joined().contains { $0.path == other.path } })
        withExtendedLifetime(watcher) {}
    }

    /// While an alias (/var/...) is still being resolved, its changes arrive under the resolved
    /// path (/private/var/...) and match nothing. Once it is resolved it is reported as changed,
    /// so the missed change is caught without another one on disk.
    @Test func aChangeMissedWhileResolvingIsReportedOnceResolved() async throws {
        let folder = try TemporaryFolder()
        let alias = folder.path
        let canonical = FolderWatcher.realPath(alias)
        #expect(alias != canonical) // the temporary folder is under the /var symlink
        let gate = DispatchSemaphore(value: 0)
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1, resolve: { path in
            if path == alias {
                gate.wait()
            }
            return FolderWatcher.realPath(path)
        }, onChange: { batches.append($0) })
        watcher.watch([canonical, alias])
        try await Task.sleep(for: .milliseconds(600))
        batches.reset()

        folder.createFile("missed-by-the-alias")
        #expect(try await batches.wait { $0.joined().contains { $0.path == canonical } })
        #expect(!batches.all.joined().contains { $0.path == alias })
        gate.signal() // the alias resolves now; nothing changes on disk any more
        #expect(try await batches.wait { $0.joined().contains { $0.path == alias } })
        withExtendedLifetime(watcher) {}
    }

    // MARK: Lifetime

    @Test func releasingAWatcherWithQueuedWorkIsSafe() throws {
        let folder = try TemporaryFolder()
        for _ in 0 ..< 100 {
            let watcher = FolderWatcher(latency: 0.1) { _ in }
            watcher.watch([folder.path])
            watcher.watch([])
            watcher.watch([folder.path])
        } // each watcher goes away with its work still queued
    }

    /// The last reference can go away on the watcher's own queue, inside its callback.
    @Test func releasingAWatcherFromItsOwnCallbackIsSafe() async throws {
        let folder = try TemporaryFolder()
        let holder = WatcherHolder()
        let batches = Batches()
        holder.watcher = FolderWatcher(latency: 0.1) { changes in
            batches.append(changes)
            holder.watcher = nil // deinit runs right here, on the watcher's queue
        }
        holder.watcher?.watch([folder.path])
        try await Task.sleep(for: .milliseconds(300))
        folder.createFile("trigger")
        #expect(try await batches.wait { !$0.isEmpty })
        #expect(holder.watcher == nil)
    }
}

private final class WatcherHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: FolderWatcher?

    var watcher: FolderWatcher? {
        get { lock.withLock { current } }
        set {
            // Release outside the lock: deinit stops the stream.
            let old = lock.withLock { () -> FolderWatcher? in
                let old = current
                current = newValue
                return old
            }
            _ = old
        }
    }
}
