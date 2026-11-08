@testable import BlitterCore
import Foundation
import Testing

/// #61: every file operation records how to undo it, and undoing puts things back as they were,
/// never overwriting anything that took their place since.
@MainActor
@Suite(.serialized)
struct UndoTests {
    /// Runs a job, then its undo steps as a job of their own.
    func undo(_ job: Job, in fixture: OperationFixture) async throws -> Job {
        #expect(!job.undo.isEmpty)
        return try await fixture.run(.undo(job.undo))
    }

    @Test(arguments: [false, true])
    func undoingACopyPutsTheCopiesInTheTrash(otherVolume: Bool) async throws {
        let fixture = try OperationFixture(otherVolume: otherVolume)
        let file = fixture.file("source/a.txt", "alpha")
        fixture.file("source/folder/b.txt", "beta")
        let job = try await fixture.run(.copy([file, fixture.source + "/folder"], into: fixture.destination))
        #expect(job.undo.flatMap(\.paths) == [fixture.destination + "/folder", fixture.destination + "/a.txt"])
        let undone = try await undo(job, in: fixture)
        #expect(undone.errors.isEmpty)
        #expect(fixture.names("destination").isEmpty)
        #expect(fixture.contents("source/a.txt") == "alpha") // the originals stay
        #expect(fixture.names("trash").count == 2) // never deleted for good
    }

    /// Keep Both made "a 2.txt": that is the copy Undo takes back, not the one that was there.
    @Test func undoingAKeepBothCopyTakesBackTheNewName() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "new")
        fixture.file("destination/a.txt", "old")
        let job = try await fixture.run(.copy([file], into: fixture.destination), answers: [.init(.keepBoth)])
        #expect(fixture.names("destination") == ["a 2.txt", "a.txt"])
        _ = try await undo(job, in: fixture)
        #expect(fixture.names("destination") == ["a.txt"])
        #expect(fixture.contents("destination/a.txt") == "old")
    }

    /// Replace sent the old item to the Trash: Undo removes the new one and brings the old back.
    @Test func undoingAReplaceBringsTheReplacedItemBack() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "new")
        fixture.file("destination/a.txt", "old")
        let job = try await fixture.run(.move([file], into: fixture.destination), answers: [.init(.replace)])
        #expect(fixture.contents("destination/a.txt") == "new")
        let undone = try await undo(job, in: fixture)
        #expect(undone.errors.isEmpty)
        #expect(fixture.contents("destination/a.txt") == "old")
        #expect(fixture.contents("source/a.txt") == "new")
    }

    @Test(arguments: [false, true])
    func undoingAMoveMovesTheItemsBack(otherVolume: Bool) async throws {
        let fixture = try OperationFixture(otherVolume: otherVolume)
        let file = fixture.file("source/a.txt", "alpha")
        fixture.file("source/folder/b.txt", "beta")
        let job = try await fixture.run(.move([file, fixture.source + "/folder"], into: fixture.destination))
        #expect(fixture.names("source").isEmpty)
        let undone = try await undo(job, in: fixture)
        #expect(undone.errors.isEmpty)
        #expect(fixture.contents("source/a.txt") == "alpha" && fixture.contents("source/folder/b.txt") == "beta")
        #expect(fixture.names("destination").isEmpty)
    }

    @Test func undoingTheTrashPutsItemsBack() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "alpha")
        let job = try await fixture.run(.trash([file]))
        #expect(!fixture.exists("source/a.txt"))
        _ = try await undo(job, in: fixture)
        #expect(fixture.contents("source/a.txt") == "alpha")
        #expect(fixture.names("trash").isEmpty)
    }

    @Test func undoingRenamesGivesTheOldNamesBack() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "alpha")
        let rename = try await fixture.run(.rename(file, newName: "b.txt"))
        _ = try await undo(rename, in: fixture)
        #expect(fixture.names("source") == ["a.txt"])

        // A batch that swaps two names: undone as a batch, so the swap goes back too.
        fixture.file("source/c.txt", "gamma")
        let batch = try await fixture.run(.renameAll([
            Rename(path: fixture.source + "/a.txt", newName: "c.txt"),
            Rename(path: fixture.source + "/c.txt", newName: "a.txt"),
        ]))
        #expect(fixture.contents("source/a.txt") == "gamma")
        let undone = try await undo(batch, in: fixture)
        #expect(undone.errors.isEmpty)
        #expect(fixture.contents("source/a.txt") == "alpha" && fixture.contents("source/c.txt") == "gamma")
    }

    @Test func undoingANewFolderPutsItInTheTrash() async throws {
        let fixture = try OperationFixture()
        let job = try await fixture.run(.newFolder(parent: fixture.source, name: "New Folder"))
        #expect(job.undo.flatMap(\.paths) == [fixture.source + "/New Folder"])
        _ = try await undo(job, in: fixture)
        #expect(fixture.names("source").isEmpty && fixture.names("trash").count == 1)
    }

    /// What took an item's old place since is never overwritten: that step is reported, the
    /// others still run.
    @Test func undoNeverOverwritesWhatIsThereNow() async throws {
        let fixture = try OperationFixture()
        let first = fixture.file("source/a.txt", "alpha")
        let second = fixture.file("source/b.txt", "beta")
        let job = try await fixture.run(.move([first, second], into: fixture.destination))
        fixture.file("source/a.txt", "someone else's")
        let undone = try await undo(job, in: fixture)
        #expect(undone.errors.count == 1 && undone.errors.first?.path == fixture.source + "/a.txt")
        #expect(fixture.contents("source/a.txt") == "someone else's")
        #expect(fixture.contents("destination/a.txt") == "alpha")
        #expect(fixture.contents("source/b.txt") == "beta")

        // An item that is gone is reported too.
        try FileManager.default.removeItem(atPath: fixture.destination + "/a.txt")
        let gone = ItemIdentity(device: 0, inode: 0)
        let again = try await fixture.run(.undo([.move(fixture.destination + "/a.txt",
                                                       toPath: fixture.source + "/x.txt", gone)]))
        #expect(again.errors.count == 1 && !fixture.exists("source/x.txt"))
    }

    /// Nothing that cannot be undone is recorded: a delete for good, a command line.
    @Test func deletesAndCommandsRecordNothing() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt")
        #expect(try await fixture.run(.delete([file])).undo.isEmpty)
        #expect(try await fixture.run(.command(["/usr/bin/true"], folder: fixture.source)).undo.isEmpty)
    }

    /// Undo acts only on the very item the job made or moved: another one at that path now (the
    /// item was deleted and something else put there) is left alone and reported.
    @Test func anotherItemAtThePathIsLeftAlone() async throws {
        let fixture = try OperationFixture()
        let first = fixture.file("source/a.txt", "alpha")
        let copy = try await fixture.run(.copy([first], into: fixture.destination))
        try FileManager.default.removeItem(atPath: fixture.destination + "/a.txt")
        fixture.file("destination/a.txt", "someone else's")
        let undone = try await undo(copy, in: fixture)
        #expect(undone.errors.count == 1 && undone.errors.first?.message.contains("Another item") == true)
        #expect(fixture.contents("destination/a.txt") == "someone else's" && fixture.names("trash").isEmpty)

        let second = fixture.file("source/b.txt", "beta")
        let move = try await fixture.run(.move([second], into: fixture.destination))
        try FileManager.default.removeItem(atPath: fixture.destination + "/b.txt")
        fixture.file("destination/b.txt", "a third one")
        let back = try await undo(move, in: fixture)
        #expect(back.errors.count == 1)
        #expect(fixture.contents("destination/b.txt") == "a third one" && !fixture.exists("source/b.txt"))
    }

    /// The real Trash (#61 review): where macOS puts an item is what Undo puts back from, also
    /// when the Trash already holds an item of that name. Disposable files; nothing is left in
    /// the Trash.
    @Test func theRealTrashIsUndone() async throws {
        let folder = try TemporaryFolder()
        let queue = JobQueue()
        let name = "blitter-undo-test-" + UUID().uuidString + ".txt"
        let path = folder.path + "/" + name
        var trashed: [Job] = []
        for contents in ["one", "two"] { // the second goes to the Trash under another name
            FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
            let job = try await Self.run(.trash([path]), on: queue)
            #expect(job.errors.isEmpty && !FileManager.default.fileExists(atPath: path))
            trashed.append(job)
        }
        let locations = trashed.flatMap(\.undo).flatMap(\.paths)
        #expect(Set(locations).count == 2 && locations.allSatisfy { $0.contains("/.Trash") })
        #expect(locations.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        for (job, contents) in zip(trashed.reversed(), ["two", "one"]) {
            let undone = try await Self.run(.undo(job.undo), on: queue)
            #expect(undone.errors.isEmpty)
            #expect(FileManager.default.contents(atPath: path)
                .flatMap { String(bytes: $0, encoding: .utf8) } == contents)
            try FileManager.default.removeItem(atPath: path)
        }
        #expect(!locations.contains { FileManager.default.fileExists(atPath: $0) }) // the Trash is as it was
    }

    static func run(_ operation: FileOperation, on queue: JobQueue) async throws -> Job {
        let id = queue.start(operation)
        for _ in 0 ..< 1000 {
            if let job = queue.jobs.first(where: { $0.id == id }), job.isDone {
                return job
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("job \(id) did not finish")
        return try #require(queue.jobs.first { $0.id == id })
    }
}

final class CancelBox: @unchecked Sendable {
    var id = 0
    var copy = ""
    weak var queue: JobQueue?
}
