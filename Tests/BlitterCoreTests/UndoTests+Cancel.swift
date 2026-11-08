@testable import BlitterCore
import Foundation
import Testing

/// #61: moves between volumes, cancelled at each point; the identities Undo goes by.
extension UndoTests {
    /// Cancelled between a move's copy to another volume and removing the original: both stay,
    /// and the copy is what Undo takes back.
    @Test func aMoveCancelledAfterItsCopyIsUndoneByTrashingTheCopy() async throws {
        let box = CancelBox()
        let fixture = try OperationFixture(otherVolume: true, rename: { path, target in
            let code = FileOperations.renameExclusive(path, target)
            if path.contains(".blitter-partial-") { // the copy is complete and published: cancel now
                DispatchQueue.main.sync { MainActor.assumeIsolated { box.queue?.cancel(box.id) } }
            }
            return code
        })
        box.queue = fixture.queue
        box.id = 1 // the fixture's first job
        let file = fixture.file("source/a.txt", "alpha")
        let job = try await fixture.run(.move([file], into: fixture.destination))
        #expect(job.state == .cancelled)
        #expect(fixture.contents("source/a.txt") == "alpha" && fixture.contents("destination/a.txt") == "alpha")
        #expect(job.undo.flatMap(\.paths) == [fixture.destination + "/a.txt"])
        guard case .trash = job.undo.first else {
            Issue.record("expected the copy to go to the Trash: \(job.undo)")
            return
        }
        _ = try await undo(job, in: fixture)
        #expect(fixture.names("destination").isEmpty && fixture.contents("source/a.txt") == "alpha")
    }

    /// Cancelled right after the original was removed (the move went through): the copy's
    /// identities are known all the same, so an older step still finds the item after the move
    /// and its undo (#61 review).
    @Test func aMoveCancelledAfterRemovingTheOriginalStillMapsTheItem() async throws {
        let box = CancelBox()
        let fixture = try OperationFixture(otherVolume: true, remove: { path in
            let code = FileOperations.removeForGood(path)
            DispatchQueue.main.sync { MainActor.assumeIsolated { box.queue?.cancel(box.id) } }
            return code
        })
        box.queue = fixture.queue
        let file = fixture.file("source/a.txt", "alpha")
        let rename = try await fixture.run(.rename(file, newName: "b.txt"))
        box.id = rename.id + 1 // the move
        let move = try await fixture.run(.move([fixture.source + "/b.txt"], into: fixture.destination))
        #expect(move.state == .cancelled && !fixture.exists("source/b.txt") && fixture.exists("destination/b.txt"))
        #expect(move.identityChanges.count == 1)

        let back = try await fixture.run(.undo(move.undo)) // copied back: another item again
        #expect(back.errors.isEmpty && fixture.contents("source/b.txt") == "alpha")
        let steps = rename.undo.map { $0.replacing(move.identityChanges).replacing(back.identityChanges) }
        let renamed = try await fixture.run(.undo(steps))
        #expect(renamed.errors.isEmpty && fixture.names("source") == ["a.txt"])
    }

    /// A symbolic link to a folder counts as itself: what it leads to is not walked, and a
    /// relative link that leads elsewhere after the move maps nothing but itself (#61 review).
    @Test func aMovedFolderLinkMapsOnlyItself() async throws {
        let fixture = try OperationFixture(otherVolume: true)
        fixture.file("source/real/x.txt", "here")
        fixture.file("destination/real/x.txt", "there") // what the link leads to after the move
        try FileManager.default.createSymbolicLink(atPath: fixture.source + "/link", withDestinationPath: "real")
        let move = try await fixture.run(.move([fixture.source + "/link"], into: fixture.destination))
        #expect(move.errors.isEmpty)
        let moved = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination + "/link")
        #expect(moved == "real")
        #expect(move.identityChanges.count == 1)
    }

    /// Cancel while a move between volumes reads what the original is (#61 review): the scan
    /// stops at once, nothing is copied, nothing changed.
    @Test func cancelWhileReadingTheOriginalStopsBeforeCopying() async throws {
        let box = CancelBox()
        let folders = RunCounter()
        let fixture = try OperationFixture(otherVolume: true, sizingProbe: { _ in
            folders.add()
            DispatchQueue.main.sync { MainActor.assumeIsolated { box.queue?.cancel(box.id) } }
        })
        box.queue = fixture.queue
        box.id = 1
        for path in ["tree/one/a.txt", "tree/two/b.txt", "tree/three/c.txt"] {
            fixture.file("source/" + path)
        }
        let job = try await fixture.run(.move([fixture.source + "/tree"], into: fixture.destination))
        #expect(job.state == .cancelled && job.undo.isEmpty && job.identityChanges.isEmpty)
        #expect(folders.value == 1) // stopped after the first folder
        #expect(fixture.names("destination").isEmpty && fixture.names("source/tree") == ["one", "three", "two"])
    }

    /// Cancel while it reads what the copy is: the scan stops, the original stays, and the
    /// complete copy is what Undo takes back.
    @Test func cancelWhileReadingTheCopyKeepsTheOriginal() async throws {
        let box = CancelBox()
        let copyFolders = RunCounter()
        let fixture = try OperationFixture(otherVolume: true, sizingProbe: { _ in
            guard FileManager.default.fileExists(atPath: box.copy) else {
                return // the original's scan, or the size scan
            }
            copyFolders.add()
            DispatchQueue.main.sync { MainActor.assumeIsolated { box.queue?.cancel(box.id) } }
        })
        box.queue = fixture.queue
        box.id = 1
        box.copy = fixture.destination + "/tree"
        for path in ["tree/one/a.txt", "tree/two/b.txt", "tree/three/c.txt"] {
            fixture.file("source/" + path)
        }
        let job = try await fixture.run(.move([fixture.source + "/tree"], into: fixture.destination))
        #expect(job.state == .cancelled && job.identityChanges.isEmpty)
        #expect(copyFolders.value == 1) // stopped after the first folder
        #expect(fixture.names("source/tree") == ["one", "three", "two"] && fixture.exists("destination/tree/two/b.txt"))
        #expect(job.undo.flatMap(\.paths) == [fixture.destination + "/tree"])
        _ = try await undo(job, in: fixture)
        #expect(fixture.names("destination").isEmpty && fixture.names("source/tree").count == 3)
    }
}
