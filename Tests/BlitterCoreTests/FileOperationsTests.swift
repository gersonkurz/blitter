@testable import BlitterCore
import Foundation
import Testing

/// A source and a destination folder in a temporary folder, and a Trash of its own, so tests
/// never touch the user's Trash.
@MainActor
final class OperationFixture {
    let root: TemporaryFolder
    let source: String
    let destination: String
    let trash: String
    let queue: JobQueue

    init(otherVolume: Bool = false, remove: @escaping FileOperations.Remover = FileOperations.removeForGood,
         gate: DispatchSemaphore? = nil, sizingProbe: (@Sendable (CancellationFlag) -> Void)? = nil) throws
    {
        root = try TemporaryFolder()
        source = root.path + "/source"
        destination = root.path + "/destination"
        trash = root.path + "/trash"
        for folder in [source, destination, trash] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        }
        let trash = trash
        queue = JobQueue(trash: { path in
            let target = trash + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
            try FileManager.default.moveItem(atPath: path, toPath: target)
        }, remove: remove, simulateOtherVolume: otherVolume, gate: gate, sizingProbe: sizingProbe)
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "x") -> String {
        let full = root.path + "/" + path
        try? FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: full, contents: Data(contents.utf8))
        return full
    }

    func contents(_ path: String) -> String? {
        FileManager.default.contents(atPath: root.path + "/" + path).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.path + "/" + path)
    }

    func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path + "/" + folder)) ?? []).sorted()
    }

    /// Runs the operation to the end, answering conflicts with `answers` in order.
    func run(_ operation: FileOperation, answers: [ConflictAnswer] = []) async throws -> Job {
        var answers = answers
        var asked: [Conflict] = []
        let id = queue.start(operation)
        for _ in 0 ..< 1000 {
            let job = try #require(queue.jobs.first { $0.id == id })
            if job.isDone {
                askedConflicts = asked
                return job
            }
            if case let .waiting(conflict) = job.state, asked.last != conflict {
                asked.append(conflict)
                queue.answer(id, answers.isEmpty ? ConflictAnswer(.skip) : answers.removeFirst())
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("job \(id) did not finish")
        return try #require(queue.jobs.first { $0.id == id })
    }

    private(set) var askedConflicts: [Conflict] = []
}

@MainActor
@Suite(.serialized)
struct FileOperationsTests {
    // MARK: Copy

    @Test(arguments: [false, true])
    func copiesFilesAndFoldersWithTheirContents(otherVolume: Bool) async throws {
        let fixture = try OperationFixture(otherVolume: otherVolume)
        let file = fixture.file("source/a.txt", "alpha")
        fixture.file("source/folder/inner/b.txt", "beta")
        let folder = fixture.root.path + "/source/folder"

        let job = try await fixture.run(.copy([file, folder], into: fixture.destination))
        #expect(job.state == .finished && job.errors.isEmpty)
        #expect(fixture.contents("destination/a.txt") == "alpha")
        #expect(fixture.contents("destination/folder/inner/b.txt") == "beta")
        #expect(fixture.contents("source/a.txt") == "alpha") // the originals stay
        #expect(job.progress.doneItems == 2 && job.progress.totalItems == 2)
        #expect(job.progress.totalBytes == 9 && job.progress.doneBytes == 9)
        #expect(!fixture.names("destination").contains { $0.hasPrefix(".blitter-partial") })
    }

    @Test func copyingIntoTheSameFolderMakesADuplicate() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/report.txt", "r")
        fixture.file("source/report 2.txt", "taken")
        let job = try await fixture.run(.copy([file], into: fixture.source))
        #expect(job.errors.isEmpty)
        #expect(fixture.contents("source/report 3.txt") == "r")
        #expect(fixture.askedConflicts.isEmpty)
    }

    @Test func aFolderCannotBeCopiedIntoItself() async throws {
        let fixture = try OperationFixture()
        fixture.file("source/folder/sub/x.txt")
        let folder = fixture.root.path + "/source/folder"
        let job = try await fixture.run(.copy([folder], into: folder + "/sub"))
        #expect(job.errors.count == 1)
        #expect(fixture.names("source/folder/sub") == ["x.txt"])
    }

    @Test(arguments: [false, true])
    func anUnreadableFileFailsTheCopyAndLeavesNothingBehind(otherVolume: Bool) async throws {
        let fixture = try OperationFixture(otherVolume: otherVolume)
        fixture.file("source/folder/ok.txt")
        let secret = fixture.file("source/folder/secret.txt")
        chmod(secret, 0)
        defer { chmod(secret, 0o644) }
        let job = try await fixture.run(.copy([fixture.root.path + "/source/folder"], into: fixture.destination))
        // Neither a clone nor a copy can read it: the copy fails as a whole.
        #expect(job.errors.count == 1)
        #expect(fixture.names("destination").isEmpty)
    }

    // MARK: Conflicts

    @Test func conflictsCanBeSkippedKeptOrReplaced() async throws {
        let fixture = try OperationFixture()
        let one = fixture.file("source/one.txt", "new one")
        let two = fixture.file("source/two.txt", "new two")
        let three = fixture.file("source/three.txt", "new three")
        for name in ["one.txt", "two.txt", "three.txt"] {
            fixture.file("destination/" + name, "old")
        }
        let job = try await fixture.run(.copy([one, two, three], into: fixture.destination),
                                        answers: [ConflictAnswer(.skip), ConflictAnswer(.keepBoth),
                                                  ConflictAnswer(.replace)])
        #expect(job.errors.isEmpty)
        #expect(fixture.askedConflicts.map { ($0.existing as NSString).lastPathComponent }
            == ["one.txt", "two.txt", "three.txt"])
        #expect(fixture.contents("destination/one.txt") == "old")
        #expect(fixture.contents("destination/two.txt") == "old")
        #expect(fixture.contents("destination/two 2.txt") == "new two")
        #expect(fixture.contents("destination/three.txt") == "new three")
        // The replaced item went to the Trash, it was not deleted.
        #expect(fixture.names("trash").count == 1 && fixture.names("trash")[0].hasSuffix("three.txt"))
    }

    @Test func aFolderIsReplacedNotMergedInto() async throws {
        let fixture = try OperationFixture()
        fixture.file("source/folder/new.txt")
        fixture.file("destination/folder/old.txt")
        let job = try await fixture.run(.copy([fixture.root.path + "/source/folder"], into: fixture.destination),
                                        answers: [ConflictAnswer(.replace)])
        #expect(job.errors.isEmpty)
        #expect(fixture.names("destination/folder") == ["new.txt"])
    }

    @Test func applyToAllAnswersTheRestWithoutAsking() async throws {
        let fixture = try OperationFixture()
        var sources: [String] = []
        for index in 0 ..< 4 {
            sources.append(fixture.file("source/f\(index)", "new"))
            fixture.file("destination/f\(index)", "old")
        }
        let job = try await fixture.run(.copy(sources, into: fixture.destination),
                                        answers: [ConflictAnswer(.keepBoth, applyToAll: true)])
        #expect(job.errors.isEmpty)
        #expect(fixture.askedConflicts.count == 1)
        #expect(fixture.names("destination").count == 8)
    }

    @Test func anAnswerNobodyAskedForIsIgnored() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "new")
        fixture.file("destination/a.txt", "old")
        let id = fixture.queue.start(.copy([file], into: fixture.destination))
        fixture.queue.answer(id, ConflictAnswer(.replace)) // before the job asks
        for _ in 0 ..< 400 {
            if case .waiting? = fixture.queue.jobs.first?.state {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.queue.jobs.first?.state == .waiting(Conflict(source: file,
                                                                     existing: fixture.destination + "/a.txt")))
        fixture.queue.cancel(id)
        try await waitUntilDone(fixture.queue, id)
        #expect(fixture.contents("destination/a.txt") == "old")
    }

    @Test func cancellingWhileAskingChangesNothing() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "new")
        fixture.file("destination/a.txt", "old")
        let id = fixture.queue.start(.copy([file], into: fixture.destination))
        for _ in 0 ..< 400 {
            if case .waiting? = fixture.queue.jobs.first?.state {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        fixture.queue.cancel(id)
        try await waitUntilDone(fixture.queue, id)
        #expect(fixture.queue.jobs.first?.state == .cancelled)
        #expect(fixture.contents("destination/a.txt") == "old")
        #expect(fixture.names("trash").isEmpty)
    }

    // MARK: Cancelling a copy

    @Test func cancellingInTheMiddleOfACopyRemovesThePartialCopy() async throws {
        let fixture = try OperationFixture(otherVolume: true)
        // Sparse: no disk space to create, but the copy writes every byte, so it takes a while.
        let big = fixture.file("source/big.bin")
        #expect(truncate(big, 2 << 30) == 0)

        let id = fixture.queue.start(.copy([big], into: fixture.destination))
        for _ in 0 ..< 2000 where (fixture.queue.jobs.first?.progress.doneBytes ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let copied = try #require(fixture.queue.jobs.first?.progress.doneBytes)
        #expect(copied > 0 && copied < 2 << 30)
        fixture.queue.cancel(id)
        try await waitUntilDone(fixture.queue, id)
        #expect(fixture.queue.jobs.first?.state == .cancelled)
        #expect(fixture.names("destination").isEmpty) // neither the file nor a partial copy
        #expect(fixture.exists("source/big.bin"))
    }

    // MARK: Move

    @Test(arguments: [false, true])
    func movesFilesAndFolders(otherVolume: Bool) async throws {
        let fixture = try OperationFixture(otherVolume: otherVolume)
        let file = fixture.file("source/a.txt", "alpha")
        fixture.file("source/folder/b.txt", "beta")
        let job = try await fixture.run(.move([file, fixture.root.path + "/source/folder"], into: fixture.destination))
        #expect(job.errors.isEmpty)
        #expect(fixture.contents("destination/a.txt") == "alpha")
        #expect(fixture.contents("destination/folder/b.txt") == "beta")
        #expect(fixture.names("source").isEmpty)
    }

    @Test func aFailedMoveBetweenVolumesKeepsTheOriginal() async throws {
        let fixture = try OperationFixture(otherVolume: true)
        let secret = fixture.file("source/folder/secret.txt", "s")
        chmod(secret, 0)
        defer { chmod(secret, 0o644) }
        let job = try await fixture.run(.move([fixture.root.path + "/source/folder"], into: fixture.destination))
        #expect(job.errors.count == 1)
        #expect(fixture.exists("source/folder/secret.txt"))
        #expect(fixture.names("destination").isEmpty)
    }

    @Test func movingToWhereItAlreadyIsDoesNothing() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt")
        let job = try await fixture.run(.move([file], into: fixture.source))
        #expect(job.errors.isEmpty)
        #expect(fixture.names("source") == ["a.txt"])
    }

    // MARK: Trash, rename, new folder

    @Test func trashMovesItemsToTheTrash() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt")
        fixture.file("source/folder/b.txt")
        let job = try await fixture.run(.trash([file, fixture.root.path + "/source/folder"]))
        #expect(job.errors.isEmpty)
        #expect(fixture.names("source").isEmpty)
        #expect(fixture.names("trash").count == 2)
    }

    /// The one test that uses the real Trash; it takes its file back out afterwards.
    @Test func theRealTrashWorks() throws {
        let folder = try TemporaryFolder()
        let file = folder.createFile("blitter-trash-test.txt")
        var trashed: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: file), resultingItemURL: &trashed)
        let inTrash = try #require(trashed as URL?)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: inTrash.path))
        try FileManager.default.removeItem(at: inTrash)
    }

    @Test func renameRefusesToOverwriteButAllowsACaseChange() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "a")
        fixture.file("source/b.txt", "b")
        var job = try await fixture.run(.rename(file, newName: "b.txt"))
        #expect(job.errors.count == 1)
        #expect(fixture.contents("source/b.txt") == "b")

        job = try await fixture.run(.rename(file, newName: "A.txt"))
        #expect(job.errors.isEmpty)
        #expect(fixture.names("source") == ["A.txt", "b.txt"])

        job = try await fixture.run(.rename(fixture.root.path + "/source/A.txt", newName: "c.txt"))
        #expect(job.errors.isEmpty && fixture.contents("source/c.txt") == "a")

        for invalid in ["", "x/y", "..", "."] {
            job = try await fixture.run(.rename(fixture.root.path + "/source/c.txt", newName: invalid))
            #expect(job.errors.count == 1)
        }
    }

    @Test func newFolderRefusesAnExistingName() async throws {
        let fixture = try OperationFixture()
        var job = try await fixture.run(.newFolder(parent: fixture.source, name: "New Folder"))
        #expect(job.errors.isEmpty && fixture.names("source") == ["New Folder"])
        job = try await fixture.run(.newFolder(parent: fixture.source, name: "New Folder"))
        #expect(job.errors.count == 1)
    }

    // MARK: Queue

    @Test func finishedJobsReportOnceAndCanBeDismissed() async throws {
        let fixture = try OperationFixture()
        var finished: [Int] = []
        fixture.queue.onFinish = { finished.append($0.id) }
        let job = try await fixture.run(.newFolder(parent: fixture.source, name: "x"))
        try await Task.sleep(for: .milliseconds(200)) // late progress updates must not report again
        #expect(finished == [job.id])
        fixture.queue.dismiss(job.id)
        #expect(fixture.queue.jobs.isEmpty)
    }

    private func waitUntilDone(_ queue: JobQueue, _ id: Int) async throws {
        for _ in 0 ..< 2000 where queue.jobs.first(where: { $0.id == id })?.isDone != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(queue.jobs.first { $0.id == id }?.isDone == true)
    }
}

/// #48 review: an item together with a folder it is in goes along with the folder; one behind a
/// symbolic link does not (copying the link does not copy it).
@MainActor
struct NestedItemsTests {
    @Test func onlyTheOutermostItemsAreOperatedOn() {
        let paths = ["/r/a/b/two.txt", "/r/a", "/r/top.txt", "/r/a/one.txt", "/r/top.txt", "/r/ab"]
        let real: (String) -> Bool = { _ in true }
        #expect(FileOperation.outermost(paths, isRealFolder: real) == ["/r/a", "/r/top.txt", "/r/ab"])
        let behindLink = FileOperation.outermost(["/r/link/file.txt", "/r/link"]) { $0 != "/r/link" }
        #expect(behindLink == ["/r/link/file.txt", "/r/link"])
        #expect(FileOperation.rename("/r/a", newName: "b").withoutNestedItems(isRealFolder: real)
            == .rename("/r/a", newName: "b"))
    }

    /// On disk: a link and a file reached through it, both copied, both arrive.
    @Test func aFileBehindALinkIsCopiedToo() async throws {
        let folder = try TemporaryFolder()
        let external = folder.path + "/external"
        let source = folder.path + "/source"
        let target = folder.path + "/target"
        for path in [external, source, target] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        }
        FileManager.default.createFile(atPath: external + "/file.txt", contents: Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: source + "/link", withDestinationPath: external)
        #expect(FileOperation.copy([source + "/link/file.txt", source + "/link"], into: target)
            .withoutNestedItems() == .copy([source + "/link/file.txt", source + "/link"], into: target))
        let queue = JobQueue()
        let done = AsyncStream<Job> { continuation in
            queue.onFinish = { continuation.yield($0) }
        }
        queue.start(.copy([source + "/link/file.txt", source + "/link"], into: target))
        var finished: Job?
        for await job in done {
            finished = job
            break
        }
        #expect(finished?.errors.isEmpty == true)
        let copied = try FileManager.default.contentsOfDirectory(atPath: target).sorted()
        #expect(copied == ["file.txt", "link"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target + "/link") == external)
    }
}
