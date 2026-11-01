@testable import BlitterCore
import Foundation
import Synchronization
import Testing

/// #29: a folder that hangs when it is opened (a privacy prompt, a stalled network volume) holds
/// up only itself, and nothing it missed is lost. Real FSEvents on temporary folders; the hang
/// is simulated in the resolver, which runs right before that folder's stream is made.
@Suite(.serialized)
struct FolderWatcherStallTests {
    /// #29: a folder whose open hangs (a privacy prompt, a stalled volume) stays out of the
    /// stream, so the others are watched meanwhile; once it opens, a change made while it hung is
    /// replayed and reported.
    @Test func aFolderThatHangsOnOpenJoinsLaterWithoutLosingChanges() async throws {
        let slow = try TemporaryFolder()
        let other = try TemporaryFolder()
        let gate = DispatchSemaphore(value: 0)
        let batches = Batches()
        let slowPath = slow.path
        let watcher = FolderWatcher(latency: 0.1, resolve: { path in
            if path == slowPath {
                gate.wait()
            }
            return FolderWatcher.watchablePath(path)
        }, onChange: { batches.append($0) })
        watcher.watch([slow.path, other.path])
        try await Task.sleep(for: .milliseconds(300))
        batches.reset()

        slow.createFile("while-it-hangs")
        // Strictly later, so the stream has seen a newer event than the one to be replayed.
        try await Task.sleep(for: .milliseconds(500))
        other.createFile("seen-meanwhile")
        #expect(try await batches.wait { $0.joined().contains { $0.path == other.path } })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!batches.all.joined().contains { $0.path == slow.path }) // not watched yet
        gate.signal() // it opens now; nothing changes on disk any more
        #expect(try await batches.wait { $0.joined().contains { $0.path == slow.path } })
        withExtendedLifetime(watcher) {}
    }

    /// #29 review: a folder that opened fine before can stall on a later visit (a network share
    /// gone quiet). Making its stream again waits; folders already watched, and new ones, go on.
    @Test func aFolderThatStallsOnALaterVisitHoldsUpOnlyItself() async throws {
        let flaky = try TemporaryFolder()
        let steady = try TemporaryFolder()
        let added = try TemporaryFolder()
        let stalled = Atomic(false)
        let gate = DispatchSemaphore(value: 0)
        let flakyPath = flaky.path
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1, resolve: { path in
            if path == flakyPath, stalled.load(ordering: .relaxed) {
                gate.wait()
            }
            return FolderWatcher.watchablePath(path)
        }, onChange: { batches.append($0) })
        defer { gate.signal() }
        watcher.watch([flaky.path, steady.path])
        try await Task.sleep(for: .milliseconds(300))
        flaky.createFile("seen-first")
        #expect(try await batches.wait { $0.joined().contains { $0.path == flaky.path } })

        stalled.store(true, ordering: .relaxed) // from now on, opening it hangs
        watcher.watch([steady.path]) // away from it…
        watcher.watch([flaky.path, steady.path, added.path]) // …and back, with another folder
        try await Task.sleep(for: .milliseconds(300))
        batches.reset()
        steady.createFile("still-seen")
        added.createFile("seen-too")
        #expect(try await batches.wait { changes in
            let paths = Set(changes.joined().map(\.path))
            return paths.contains(steady.path) && paths.contains(added.path)
        })
        withExtendedLifetime(watcher) {}
    }

    /// #29 review: the watched set changing again just after a waiting folder joined must not
    /// drop the replay of that folder's changes.
    @Test func anotherChangeOfTheSetKeepsAWaitingFoldersReplay() async throws {
        let slow = try TemporaryFolder()
        let first = try TemporaryFolder()
        let second = try TemporaryFolder()
        let gate = DispatchSemaphore(value: 0)
        let slowPath = slow.path
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1, resolve: { path in
            if path == slowPath {
                gate.wait()
            }
            return FolderWatcher.watchablePath(path)
        }, onChange: { batches.append($0) })
        watcher.watch([slow.path, first.path])
        try await Task.sleep(for: .milliseconds(300))
        slow.createFile("while-it-waits")
        try await Task.sleep(for: .milliseconds(500))
        first.createFile("newer")
        #expect(try await batches.wait { $0.joined().contains { $0.path == first.path } })
        batches.reset()

        gate.signal() // slow opens now; nothing changes on disk any more…
        try await Task.sleep(for: .milliseconds(30))
        // …and right after it joined, while its replay is still on the way, the set changes again.
        watcher.watch([slow.path, first.path, second.path])
        #expect(try await batches.wait { $0.joined().contains { $0.path == slow.path } })
        withExtendedLifetime(watcher) {}
    }

    /// A new stream that replays history ends with a marker carrying one of its paths; that is
    /// not a change, so adding a folder reloads nothing.
    @Test func addingAFolderReportsNothingThatDidNotChange() async throws {
        let first = try TemporaryFolder()
        let second = try TemporaryFolder()
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1) { batches.append($0) }
        watcher.watch([first.path])
        try await Task.sleep(for: .milliseconds(500))
        batches.reset()
        watcher.watch([first.path, second.path])
        try await Task.sleep(for: .milliseconds(800))
        #expect(batches.all.isEmpty)
        withExtendedLifetime(watcher) {}
    }

    @Test func aFolderThatDoesNotExistYetIsWatchedOnceItDoes() async throws {
        let parent = try TemporaryFolder()
        let later = parent.path + "/later"
        #expect(FolderWatcher.watchablePath(later) == nil)
        #expect(FolderWatcher.watchablePath(parent.path) == FolderWatcher.realPath(parent.path))
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1) { batches.append($0) }
        watcher.watch([later])
        try await Task.sleep(for: .milliseconds(300))

        try FileManager.default.createDirectory(atPath: later, withIntermediateDirectories: false)
        watcher.watch([later]) // the same set: tries the folder again
        try await Task.sleep(for: .milliseconds(300))
        batches.reset()
        FileManager.default.createFile(atPath: later + "/inside", contents: Data())
        #expect(try await batches.wait { $0.joined().contains { $0.path == later } })
        withExtendedLifetime(watcher) {}
    }

    /// #29 review: a thread that hangs while making a folder's stream does not keep the watcher
    /// alive; it lets go of its stream once it finds the watcher gone.
    @Test func aHangingFolderDoesNotKeepTheWatcherAlive() async throws {
        let folder = try TemporaryFolder()
        let gate = DispatchSemaphore(value: 0)
        let entered = Atomic(false)
        weak var released: FolderWatcher?
        do {
            let watcher = FolderWatcher(latency: 0.1, resolve: { path in
                entered.store(true, ordering: .relaxed)
                gate.wait()
                return FolderWatcher.watchablePath(path)
            }, onChange: { _ in })
            released = watcher
            watcher.watch([folder.path])
            for _ in 0 ..< 200 where !entered.load(ordering: .relaxed) {
                try await Task.sleep(for: .milliseconds(5))
            }
            let didEnter = entered.load(ordering: .relaxed)
            #expect(didEnter)
        }
        #expect(released == nil) // gone while its thread still hangs
        gate.signal()
        try await Task.sleep(for: .milliseconds(200)) // the thread finishes and cleans up
    }

    /// #29 review: going away from a hanging folder and back again does not start another thread
    /// each time; the one that hangs is waited for, and other folders still start.
    @Test func revisitingAHangingFolderStartsNoMoreThreads() async throws {
        let stuck = try TemporaryFolder()
        let other = try TemporaryFolder()
        let fresh = try TemporaryFolder()
        let gate = DispatchSemaphore(value: 0)
        let tries = Atomic(0)
        let stuckPath = stuck.path
        let batches = Batches()
        let watcher = FolderWatcher(latency: 0.1, resolve: { path in
            if path == stuckPath {
                tries.add(1, ordering: .relaxed)
                gate.wait()
            }
            return FolderWatcher.watchablePath(path)
        }, onChange: { batches.append($0) })
        defer { gate.signal() }
        for _ in 0 ..< 20 {
            watcher.watch([stuck.path, other.path])
            watcher.watch([other.path])
        }
        watcher.watch([stuck.path, other.path, fresh.path])
        try await Task.sleep(for: .milliseconds(300))
        let triesSoFar = tries.load(ordering: .relaxed)
        #expect(triesSoFar == 1)
        batches.reset()
        fresh.createFile("seen")
        other.createFile("seen-too")
        #expect(try await batches.wait { changes in
            let paths = Set(changes.joined().map(\.path))
            return paths.contains(fresh.path) && paths.contains(other.path)
        })

        gate.signal() // the hanging folder opens; it was asked for again, so it is watched now
        try await Task.sleep(for: .milliseconds(300))
        batches.reset()
        stuck.createFile("finally")
        #expect(try await batches.wait { $0.joined().contains { $0.path == stuck.path } })
        withExtendedLifetime(watcher) {}
    }
}
