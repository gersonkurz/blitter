@testable import BlitterCore
import Foundation
import Testing

/// #112: heavy jobs one after the other, quick ones at once, and no job before an earlier one
/// that uses its paths. The gate holds every started job before it touches the disk, so what has
/// started (running) and what waits (queued) can be looked at.
@MainActor
@Suite(.serialized)
struct JobQueueTurnTests {
    @Test func heavyJobsRunOneAfterTheOther() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let first = fixture.file("source/a.txt", "a")
        let second = fixture.file("source/b.txt", "b")
        let one = fixture.queue.start(.copy([first], into: fixture.destination))
        let two = fixture.queue.start(.copy([second], into: fixture.destination))
        try await waitUntil { state(fixture, one) == .running }
        try await settle()
        #expect(state(fixture, two) == .queued)
        gate.signal()
        try await waitUntil { state(fixture, two) == .running }
        #expect(fixture.names("destination") == ["a.txt"])
        gate.signal()
        try await waitUntil { fixture.queue.jobs.isEmpty || fixture.queue.jobs.allSatisfy(\.isDone) }
        #expect(fixture.names("destination") == ["a.txt", "b.txt"])
    }

    /// A rename elsewhere, a new folder inside the copy's destination, the Trash of another item,
    /// a move on the same volume and a command line run beside a running copy.
    @Test func quickJobsThatUseOtherPathsRunAtOnce() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let copied = fixture.file("source/copied.txt")
        let other = fixture.file("source/other.txt")
        let trashed = fixture.file("source/trashed.txt")
        let moved = fixture.file("source/moved.txt")
        let copy = fixture.queue.start(.copy([copied], into: fixture.destination))
        let quick = [
            fixture.queue.start(.rename(other, newName: "renamed.txt")),
            fixture.queue.start(.newFolder(parent: fixture.destination, name: "new")),
            fixture.queue.start(.trash([trashed])),
            fixture.queue.start(.move([moved], into: fixture.destination)),
            fixture.queue.start(.command(["/usr/bin/true"], folder: fixture.root.path)),
        ]
        try await waitUntil {
            quick.allSatisfy { state(fixture, $0) == .running }
        } // the move: once its volume is known
        #expect(state(fixture, copy) == .running)
        for _ in 0 ... quick.count {
            gate.signal()
        }
        try await waitUntil { fixture.queue.jobs.allSatisfy(\.isDone) }
    }

    /// Renaming what a waiting or running copy will read, or its destination, waits for the copy:
    /// the copy finds what it was given, then the rename happens.
    @Test func aJobThatUsesAnEarlierJobsPathsWaitsForIt() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let file = fixture.file("source/a.txt", "a")
        let copy = fixture.queue.start(.copy([file], into: fixture.destination))
        let renameSource = fixture.queue.start(.rename(file, newName: "b.txt"))
        let renameDestination = fixture.queue.start(.rename(fixture.destination, newName: "elsewhere"))
        let trashFolder = fixture.queue.start(.trash([fixture.source])) // holds the copied item
        try await waitUntil { state(fixture, copy) == .running }
        try await settle()
        #expect([renameSource, renameDestination, trashFolder].allSatisfy { state(fixture, $0) == .queued })
        gate.signal()
        try await waitUntil { state(fixture, renameSource) == .running } // the copy is done
        #expect(fixture.names("destination") == ["a.txt"])
        // The rename of the source and of the destination do not touch each other's paths, but the
        // Trash of the source folder waits for the rename inside it.
        #expect(state(fixture, renameDestination) == .running && state(fixture, trashFolder) == .queued)
        gate.signal()
        gate.signal()
        try await waitUntil { state(fixture, trashFolder) == .running }
        gate.signal()
        try await waitUntil { fixture.queue.jobs.allSatisfy(\.isDone) }
        #expect(fixture.names("elsewhere") == ["a.txt"])
        #expect(!fixture.exists("source"))
    }

    /// Cancelling a waiting job ends it at once, having done nothing; the next one gets its turn.
    @Test func aWaitingJobIsCancelledWithoutRunning() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let first = fixture.file("source/a.txt")
        let second = fixture.file("source/b.txt")
        let third = fixture.file("source/c.txt")
        let one = fixture.queue.start(.copy([first], into: fixture.destination))
        let two = fixture.queue.start(.copy([second], into: fixture.destination))
        let three = fixture.queue.start(.copy([third], into: fixture.destination))
        try await waitUntil { state(fixture, one) == .running }
        var finished: [Int] = []
        fixture.queue.onFinish = { finished.append($0.id) }
        fixture.queue.cancel(two)
        #expect(state(fixture, two) == .cancelled && finished == [two])
        #expect(state(fixture, three) == .queued) // still behind the first
        gate.signal()
        gate.signal()
        try await waitUntil { fixture.queue.jobs.allSatisfy(\.isDone) }
        #expect(fixture.names("destination") == ["a.txt", "c.txt"])
    }

    /// Delete for good, undo and Git Clean are heavy; the Trash is quick.
    @Test func deletingForGoodIsHeavy() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let copied = fixture.file("source/a.txt")
        let deleted = fixture.file("source/b.txt")
        let copy = fixture.queue.start(.copy([copied], into: fixture.destination))
        let delete = fixture.queue.start(.delete([deleted]))
        let undo = fixture.queue.start(.undo([]))
        try await waitUntil { state(fixture, copy) == .running }
        try await settle()
        #expect(state(fixture, delete) == .queued && state(fixture, undo) == .queued)
        for _ in 0 ..< 3 {
            gate.signal()
        }
        try await waitUntil { fixture.queue.jobs.allSatisfy(\.isDone) }
        #expect(!fixture.exists("source/b.txt"))
    }

    @Test func aMoveIsQuickOnlyOnOneVolume() throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt")
        #expect(FileOperations.isOnVolume(of: fixture.destination, [file]))
        #expect(!FileOperations.isOnVolume(of: "/dev", [file])) // another file system
        #expect(!FileOperations.isOnVolume(of: fixture.destination, [fixture.root.path + "/missing"]))
    }

    func state(_ fixture: OperationFixture, _ id: Int) -> Job.State? {
        fixture.queue.jobs.first { $0.id == id }?.state
    }

    /// Long enough for every job's paths to be resolved and its turn decided.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
