@testable import BlitterCore
import Foundation
import Testing

/// #112 review: which paths a job uses — through links, in any case, what it makes — and a job
/// whose paths cannot be resolved.
extension JobQueueTurnTests {
    /// #112 review: a rename through a linked folder, or in another case, of what a running copy
    /// reads waits for it; so does a rename or Trash of what the copy will make, or of the name
    /// Keep Both would give it. Other items in the destination do not wait.
    @Test func linksCaseAndWhatAJobMakesCountToo() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let file = fixture.file("source/a.txt", "a")
        fixture.file("destination/b.txt", "taken") // what the copy will make, there already
        fixture.file("destination/b 2.txt")
        fixture.file("destination/other.txt")
        let alias = fixture.root.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.source)
        let copy = fixture.queue.start(.copy([file], into: fixture.destination))
        try await waitUntil { state(fixture, copy) == .running }
        let waiting = [
            fixture.queue.start(.rename(alias + "/a.txt", newName: "x.txt")), // through the link
            fixture.queue.start(.rename(fixture.root.path + "/SOURCE/A.TXT", newName: "y.txt")), // in another case
        ]
        let copyB = fixture.queue.start(.copy([fixture.file("source/b.txt", "b")], into: fixture.destination))
        let atOnce = [fixture.queue.start(.trash([fixture.destination + "/other.txt"]))]
        try await waitUntil { atOnce.allSatisfy { state(fixture, $0) == .running } }
        try await settle()
        #expect(waiting.allSatisfy { state(fixture, $0) == .queued })
        // The second copy (heavy, queued) makes b.txt: its target and Keep Both name wait behind it.
        let behindB = [
            fixture.queue.start(.rename(fixture.destination + "/b.txt", newName: "c.txt")),
            fixture.queue.start(.trash([fixture.destination + "/b 2.txt"])),
        ]
        try await settle()
        #expect(behindB.allSatisfy { state(fixture, $0) == .queued } && state(fixture, copyB) == .queued)
        for _ in 0 ..< 10 {
            gate.signal()
        }
        fixture.queue.cancel(copyB) // conflicts with b.txt: not answered here
        try await waitUntil { fixture.queue.jobs.allSatisfy(\.isDone) }
        #expect(fixture.names("destination").contains("a.txt")) // copied before the renames
    }

    /// #112 review: a job whose paths cannot be resolved (here: a resolver that hangs, as on a
    /// stalled network volume) holds up every later job that uses paths only for a while (the
    /// stall delay; the owner's choice); then only those that share its paths as given. A command
    /// line, which uses no paths, never waits.
    @Test func aJobThatCannotBeResolvedHoldsUpOtherJobsOnlyForAWhile() async throws {
        let stalled = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(resolve: { use in
            if use.items.contains(where: { $0.contains("/stalled/") }) {
                stalled.wait()
            }
            return use.resolved()
        }, stallDelay: 0.5)
        let stuck = fixture.file("source/stalled/x.txt")
        let other = fixture.file("source/other.txt")
        let copied = fixture.file("source/copied.txt")
        let hanging = fixture.queue.start(.rename(stuck, newName: "y.txt"))
        let sharing = fixture.queue.start(.trash([fixture.source + "/stalled"])) // holds the stuck item
        let command = fixture.queue.start(.command(["/usr/bin/true"], folder: fixture.root.path))
        let unrelated = [
            fixture.queue.start(.rename(other, newName: "renamed.txt")),
            fixture.queue.start(.copy([copied], into: fixture.destination)),
        ]
        func isDone(_ id: Int) -> Bool {
            fixture.queue.jobs.first { $0.id == id }?.isDone == true
        }
        try await waitUntil { isDone(command) }
        try await Task.sleep(for: .milliseconds(200)) // well within the stall delay
        #expect(unrelated.allSatisfy { state(fixture, $0) == .queued })
        try await waitUntil { unrelated.allSatisfy(isDone) } // once the stuck job counts as stalled
        #expect(state(fixture, hanging) == .queued && state(fixture, sharing) == .queued)
        #expect(fixture.names("destination") == ["copied.txt"])
        stalled.signal()
        stalled.signal()
        try await waitUntil { fixture.queue.jobs.allSatisfy(\.isDone) }
        #expect(fixture.names("source").contains("renamed.txt"))
    }

    /// #112 review: while an earlier copy through a link is still being resolved, a later rename
    /// of the item by its real path waits — it cannot be told yet that both name the same item —
    /// and the copy, once resolved, finds what it was given.
    @Test func aRenameByTheRealPathWaitsForACopyThroughALinkBeingResolved() async throws {
        let held = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(resolve: { use in
            if use.items.contains(where: { $0.contains("/alias/") }) {
                held.wait()
            }
            return use.resolved()
        }, stallDelay: 5)
        let real = fixture.file("source/a.txt", "the original")
        let alias = fixture.root.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.source)
        let copy = fixture.queue.start(.copy([alias + "/a.txt"], into: fixture.destination))
        let rename = fixture.queue.start(.rename(real, newName: "b.txt"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(state(fixture, copy) == .queued && state(fixture, rename) == .queued)
        held.signal()
        try await waitUntil { fixture.queue.jobs.allSatisfy(\.isDone) }
        #expect(fixture.queue.jobs.allSatisfy { $0.errors.isEmpty })
        #expect(fixture.contents("destination/a.txt") == "the original")
        #expect(fixture.names("source") == ["b.txt"])
    }

    /// #112 review: a later job making the same item as an earlier one — or the name Keep Both
    /// would give it — waits; one making another name in the same folder does not.
    @Test func twoJobsMakingTheSameItemTakeTurns() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        fixture.file("destination/x.txt", "taken") // the copy will make "x 2.txt" (Keep Both)
        let copied = fixture.file("source/x.txt", "copied")
        let sameName = fixture.file("other/x.txt", "moved")
        let keepBothName = fixture.file("other2/x 2.txt", "moved too")
        let otherName = fixture.file("other3/y.txt")
        let copy = fixture.queue.start(.copy([copied], into: fixture.destination))
        try await waitUntil { state(fixture, copy) == .running }
        let waiting = [
            fixture.queue.start(.move([sameName], into: fixture.destination)), // same volume: quick
            fixture.queue.start(.move([keepBothName], into: fixture.destination)),
        ]
        let atOnce = fixture.queue.start(.move([otherName], into: fixture.destination))
        try await waitUntil { state(fixture, atOnce) == .running }
        try await settle()
        #expect(waiting.allSatisfy { state(fixture, $0) == .queued })
        for _ in 0 ..< 4 {
            gate.signal()
        }
        try await waitUntil {
            if case .waiting = state(fixture, copy) {
                true
            } else {
                false
            }
        }
        fixture.queue.answer(copy, ConflictAnswer(.keepBoth)) // x.txt is taken: the copy is "x 2.txt"
        // The moves come after the copy: each meets a name that is taken, and is skipped.
        for _ in 0 ..< 500 where !fixture.queue.jobs.allSatisfy(\.isDone) {
            for job in fixture.queue.jobs {
                if case .waiting = job.state {
                    fixture.queue.answer(job.id, ConflictAnswer(.skip))
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.queue.jobs.allSatisfy { $0.isDone })
        #expect(fixture.contents("destination/x 2.txt") == "copied") // the copy's, not the move's
        #expect(fixture.contents("destination/x.txt") == "taken")
        #expect(fixture.exists("destination/y.txt"))
    }

    /// #112 review: renaming a link a waiting copy goes through waits for the copy, which then
    /// finds its item where it was given.
    @Test func renamingALinkAWaitingCopyGoesThroughWaits() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let first = fixture.file("source/first.txt")
        fixture.file("source/a.txt", "through the link")
        let alias = fixture.root.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.source)
        let running = fixture.queue.start(.copy([first], into: fixture.destination))
        let waitingCopy = fixture.queue.start(.copy([alias + "/a.txt"], into: fixture.destination))
        let renameLink = fixture.queue.start(.rename(alias, newName: "renamed-link"))
        try await waitUntil { state(fixture, running) == .running }
        try await settle()
        #expect(state(fixture, waitingCopy) == .queued && state(fixture, renameLink) == .queued)
        for _ in 0 ..< 3 {
            gate.signal()
        }
        try await waitUntil { fixture.queue.jobs.allSatisfy(\.isDone) }
        #expect(fixture.queue.jobs.allSatisfy { $0.errors.isEmpty })
        #expect(fixture.contents("destination/a.txt") == "through the link")
        #expect(fixture.exists("renamed-link"))
    }

    @Test func pathUsesOverlapWhereOneJobGetsInTheOthersWay() {
        let copy = PathUse(.copy(["/a/x"], into: "/b"))
        func overlaps(_ operation: FileOperation) -> Bool {
            PathUse(operation).overlaps(copy) && copy.overlaps(PathUse(operation))
        }
        #expect(overlaps(.rename("/a/x", newName: "y"))) // the item itself
        #expect(overlaps(.rename("/a/x/inner", newName: "y"))) // inside it
        #expect(overlaps(.trash(["/a"]))) // holding it
        #expect(overlaps(.rename("/b", newName: "c"))) // the destination
        #expect(overlaps(.trash(["/"]))) // above the destination
        #expect(!overlaps(.newFolder(parent: "/b", name: "n"))) // inside the destination
        #expect(!overlaps(.trash(["/b/old"])))
        #expect(!overlaps(.rename("/a/xy", newName: "z"))) // a name that only starts the same
        #expect(!overlaps(.copy(["/c"], into: "/b"))) // the same destination
        #expect(!overlaps(.command(["rm", "-rf", "/"], folder: "/")))
        #expect(overlaps(.rename("/a/y", newName: "x"))) // the new name is the item
        #expect(overlaps(.rename("/b/x", newName: "y"))) // what the copy makes
        #expect(overlaps(.trash(["/b/x 2"]))) // the name Keep Both gives it
        #expect(overlaps(.rename("/b/x/inner", newName: "y"))) // inside what it makes
        #expect(!overlaps(.trash(["/b/x 2b"])))
        #expect(!overlaps(.trash(["/b/xy"])))

        let report = PathUse(.copy(["/a/report.txt"], into: "/b"))
        #expect(report.overlaps(PathUse(.trash(["/b/report 12.txt"]))))
        #expect(!report.overlaps(PathUse(.trash(["/b/report 2.md"]))))
        #expect(!report.overlaps(PathUse(.trash(["/b/report.txt 2"]))))

        // Undo: where an item is now, and where it goes back to.
        let undo = PathUse(.undo([.rename([Rename(path: "/a/new", newName: "old")], [])]))
        #expect(undo.overlaps(PathUse(.rename("/a/old", newName: "z"))))
        #expect(undo.overlaps(PathUse(.trash(["/a/new"]))))

        // Two jobs making the same item, a Keep Both name of it, or one making the other's
        // destination; another name in the same folder is no overlap.
        #expect(copy.overlaps(PathUse(.move(["/c/x"], into: "/b"))))
        #expect(copy.overlaps(PathUse(.move(["/c/x 2"], into: "/b"))))
        #expect(copy.overlaps(PathUse(.copy(["/c/z"], into: "/b/x"))))
        #expect(!copy.overlaps(PathUse(.move(["/c/y"], into: "/b"))))
    }

    /// The folders on the way are resolved (a link, the case on disk), the item itself is kept as
    /// given (a link being copied is the link), and everything compares in one case.
    @Test func pathsAreComparedAsTheFileSystemNamesThem() throws {
        let fixture = try OperationFixture()
        fixture.file("source/a.txt")
        let alias = fixture.root.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.source)
        let real = PathUse(items: [fixture.source + "/a.txt"]).resolved()
        #expect(PathUse(items: [alias + "/a.txt"]).resolved() == real)
        #expect(PathUse(items: [fixture.root.path + "/Source/A.txt"]).resolved() == real)
        #expect(PathUse(items: [alias]).resolved() != PathUse(items: [fixture.source]).resolved()) // the link itself
        #expect(PathUse(into: [alias]).resolved() == PathUse(into: [fixture.source]).resolved()) // a destination
        #expect(PathUse(items: ["/"]).resolved().items == ["/"])
    }
}
