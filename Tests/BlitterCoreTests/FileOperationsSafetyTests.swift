@testable import BlitterCore
import Foundation
import Synchronization
import Testing

/// A small case-sensitive APFS volume, mounted for one test and detached afterwards: a real second
/// volume, and a volume where "a.txt" and "A.txt" are different files.
final class DiskImage {
    let mountPoint: String
    private let folder: TemporaryFolder

    init() throws {
        folder = try TemporaryFolder()
        mountPoint = folder.path + "/mount"
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: false)
        let image = folder.path + "/volume"
        try Self.hdiutil(["create", "-quiet", "-size", "64m", "-fs", "Case-sensitive APFS", "-volname",
                          "BlitterTest", "-type", "SPARSE", image])
        try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint,
                          image + ".sparseimage"])
    }

    deinit {
        try? Self.hdiutil(["detach", "-quiet", "-force", mountPoint])
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
    }
}

@MainActor
@Suite(.serialized)
struct FileOperationsSafetyTests {
    // MARK: Real second volume

    @Test func copiesAndMovesAcrossRealVolumes() async throws {
        let volume = try DiskImage()
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "alpha")
        fixture.file("source/folder/inner/b.txt", "beta")
        let folder = fixture.root.path + "/source/folder"
        #expect(FileOperations.identity(volume.mountPoint)?.device != FileOperations.identity(file)?.device)

        var job = try await fixture.run(.copy([file, folder], into: volume.mountPoint))
        #expect(job.errors.isEmpty)
        #expect(try String(contentsOfFile: volume.mountPoint + "/folder/inner/b.txt", encoding: .utf8) == "beta")
        #expect(job.progress.doneBytes == 9)

        let target = volume.mountPoint + "/moved"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        job = try await fixture.run(.move([file, folder], into: target))
        #expect(job.errors.isEmpty)
        #expect(try String(contentsOfFile: target + "/a.txt", encoding: .utf8) == "alpha")
        #expect(try String(contentsOfFile: target + "/folder/inner/b.txt", encoding: .utf8) == "beta")
        #expect(fixture.names("source").isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: target)
        #expect(!names.contains { $0.hasPrefix(".blitter-partial") })
    }

    /// The copy arrived; the original could not be removed: both stay, and the job says so.
    @Test func aMoveWhoseOriginalCannotBeRemovedKeepsBoth() async throws {
        let volume = try DiskImage()
        let fixture = try OperationFixture()
        let file = fixture.file("source/locked/a.txt", "alpha")
        let locked = fixture.root.path + "/source/locked"
        chmod(locked, 0o555) // nothing can be removed from it
        defer { chmod(locked, 0o755) }

        let job = try await fixture.run(.move([file], into: volume.mountPoint))
        #expect(job.errors.count == 1)
        #expect(job.errors.first?.message.hasPrefix("Copied, but the original could not be removed") == true)
        #expect(try String(contentsOfFile: volume.mountPoint + "/a.txt", encoding: .utf8) == "alpha")
        #expect(fixture.contents("source/locked/a.txt") == "alpha")
    }

    @Test func aCaseOnlyRenameNeverOverwritesAnotherFile() async throws {
        let volume = try DiskImage()
        let fixture = try OperationFixture()
        let lower = volume.mountPoint + "/a.txt"
        FileManager.default.createFile(atPath: lower, contents: Data("lower".utf8))
        FileManager.default.createFile(atPath: volume.mountPoint + "/A.txt", contents: Data("upper".utf8))

        let job = try await fixture.run(.rename(lower, newName: "A.txt"))
        #expect(job.errors.count == 1)
        #expect(try String(contentsOfFile: volume.mountPoint + "/A.txt", encoding: .utf8) == "upper")
        #expect(try String(contentsOfFile: lower, encoding: .utf8) == "lower")
    }

    // MARK: Identity, not paths

    @Test func copyingIntoAnAliasOfTheSourceFolderDuplicates() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "a")
        let alias = fixture.root.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.source)
        let job = try await fixture.run(.copy([file], into: alias), answers: [ConflictAnswer(.replace)])
        #expect(job.errors.isEmpty)
        #expect(fixture.askedConflicts.isEmpty) // recognised as the same folder: no replace offered
        #expect(fixture.names("source") == ["a 2.txt", "a.txt"])
        #expect(fixture.names("trash").isEmpty)
    }

    @Test func movingIntoAnAliasOfTheSourceFolderDoesNothing() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt", "a")
        let alias = fixture.root.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.source)
        let job = try await fixture.run(.move([file], into: alias), answers: [ConflictAnswer(.replace)])
        #expect(job.errors.isEmpty)
        #expect(fixture.contents("source/a.txt") == "a")
        #expect(fixture.names("trash").isEmpty)
    }

    /// Copying /root/foo/foo into /root: "replacing" /root/foo would throw away the source.
    @Test func replaceNeverTrashesAFolderThatContainsTheSource() async throws {
        let fixture = try OperationFixture()
        let source = fixture.file("foo/foo", "inner")
        let job = try await fixture.run(.copy([source], into: fixture.root.path), answers: [ConflictAnswer(.replace)])
        #expect(job.errors.count == 1)
        #expect(fixture.contents("foo/foo") == "inner")
        #expect(fixture.names("trash").isEmpty)
    }

    /// The destination is an alias of a folder inside the source. The containment check must
    /// refuse before anything is copied: no bytes, no clone, nothing to clean up.
    @Test(arguments: [false, true])
    func aFolderCannotBeCopiedIntoAnAliasOfItsOwnSubfolder(otherVolume: Bool) async throws {
        let removals = Counter()
        let fixture = try OperationFixture(otherVolume: otherVolume, remove: { path in
            removals.increment()
            return FileOperations.removeForGood(path)
        })
        fixture.file("source/folder/sub/x.txt")
        let alias = fixture.root.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.source + "/folder/sub")
        for operation in [FileOperation.copy([fixture.source + "/folder"], into: alias),
                          .move([fixture.source + "/folder"], into: alias)]
        {
            let job = try await fixture.run(operation)
            #expect(job.errors.map(\.message) == ["A folder cannot be copied or moved into itself."])
            #expect(job.progress.doneBytes == 0)
            #expect(fixture.names("source/folder/sub") == ["x.txt"])
            #expect(fixture.names("source") == ["folder"])
        }
        #expect(removals.value == 0)
    }

    // MARK: Cancellation reaches every path

    @Test func aJobCancelledBeforeItStartsChangesNothing() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let file = fixture.file("source/a.txt")
        fixture.file("source/tree/deep/b.txt")
        let operations: [FileOperation] = [
            .rename(file, newName: "renamed.txt"),
            .newFolder(parent: fixture.source, name: "New Folder"),
            .copy([fixture.source + "/tree"], into: fixture.destination),
            .move([file], into: fixture.destination),
            .trash([file]),
            .delete([file, fixture.source + "/tree"]),
            .command(["touch", "made-by-a-cancelled-job"], folder: fixture.source),
        ]
        var ids: [Int] = []
        for operation in operations {
            let id = fixture.queue.start(operation)
            fixture.queue.cancel(id)
            ids.append(id)
            gate.signal() // the job starts only now, already cancelled
        }
        for id in ids {
            try await waitUntilDone(fixture.queue, id)
            #expect(fixture.queue.jobs.first { $0.id == id }?.state == .cancelled)
        }
        #expect(fixture.names("source") == ["a.txt", "tree"])
        #expect(fixture.names("destination").isEmpty)
        #expect(fixture.names("trash").isEmpty)
    }

    @Test func sizingStopsOnceCancelled() throws {
        let folder = try TemporaryFolder()
        for index in 0 ..< 50 {
            try FileManager.default.createDirectory(
                atPath: folder.path + "/d\(index)/e",
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: folder.path + "/d\(index)/e/f", contents: Data(count: 10))
        }
        #expect(FileOperations.size(of: folder.path, cancelled: CancellationFlag()) == 500)
        let cancelled = CancellationFlag()
        cancelled.set()
        #expect(FileOperations.size(of: folder.path, cancelled: cancelled) == 0)
    }

    /// A cancel arriving while a job measures its sources: the scan stops at once, nothing is copied.
    @Test func cancellingDuringTheInitialSizeScanStopsIt() async throws {
        let visits = Counter()
        let fixture = try OperationFixture(sizingProbe: { flag in
            visits.increment()
            flag.set() // the cancel arrives as the first folder is about to be read
        })
        let tree = try makeTree(in: fixture, folders: 20)
        let job = try await fixture.run(.copy([tree], into: fixture.destination))
        #expect(job.state == .cancelled)
        #expect(visits.value == 1)
        #expect(fixture.names("destination").isEmpty)
    }

    /// After a clone the job measures the clone to report its bytes; a cancel then must stop that
    /// scan too, instead of walking the whole tree a second time.
    @Test func cancellingDuringTheSizeScanAfterACloneStopsIt() async throws {
        let foldersPerScan = 21 // the tree's top folder and its 20 subfolders
        let visits = Counter()
        let fixture = try OperationFixture(sizingProbe: { flag in
            if visits.increment() == foldersPerScan + 1 {
                flag.set() // the first folder of the scan after the clone
            }
        })
        let tree = try makeTree(in: fixture, folders: 20)
        let job = try await fixture.run(.copy([tree], into: fixture.destination))
        #expect(job.state == .cancelled)
        #expect(visits.value == foldersPerScan + 1)
        #expect(fixture.names("destination") == ["tree"]) // the clone itself was complete
    }

    private func makeTree(in fixture: OperationFixture, folders: Int) throws -> String {
        for index in 0 ..< folders {
            fixture.file("source/tree/d\(index)/f", "12345")
        }
        return fixture.source + "/tree"
    }

    // MARK: Partial copies that cannot be removed

    @Test func aPartialCopyThatCannotBeRemovedIsReportedEvenWhenCancelled() async throws {
        let fixture = try OperationFixture(otherVolume: true, remove: { path in
            path.contains(".blitter-partial") ? EPERM : FileOperations.removeForGood(path)
        })
        // Sparse: no disk space to create, but the copy writes every byte, so it takes a while. In
        // a folder, because copyfile removes an incomplete single file itself.
        let big = fixture.file("source/folder/big.bin")
        #expect(truncate(big, 2 << 30) == 0)

        let id = fixture.queue.start(.copy([fixture.source + "/folder"], into: fixture.destination))
        for _ in 0 ..< 2000 where (fixture.queue.jobs.first?.progress.doneBytes ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        fixture.queue.cancel(id)
        try await waitUntilDone(fixture.queue, id)
        let job = try #require(fixture.queue.jobs.first)
        #expect(job.state == .cancelled)
        let partial = try #require(fixture.names("destination").first)
        #expect(partial.hasPrefix(".blitter-partial"))
        #expect(job.errors.map(\.path) == [fixture.destination + "/" + partial])
        #expect(job.errors.first?.message.hasPrefix("An incomplete copy could not be removed") == true)
    }

    @Test func aPartialCopyThatCannotBeRemovedAfterAnErrorIsReported() async throws {
        let fixture = try OperationFixture(otherVolume: true, remove: { path in
            path.contains(".blitter-partial") ? EPERM : FileOperations.removeForGood(path)
        })
        fixture.file("source/folder/ok.txt")
        let secret = fixture.file("source/folder/secret.txt")
        chmod(secret, 0)
        defer { chmod(secret, 0o644) }
        let job = try await fixture.run(.copy([fixture.source + "/folder"], into: fixture.destination))
        let partial = try #require(fixture.names("destination").first)
        #expect(partial.hasPrefix(".blitter-partial"))
        #expect(job.errors.count == 2) // the unreadable file, and the copy that stayed behind
        #expect(job.errors.last?.path == fixture.destination + "/" + partial)
    }

    private func waitUntilDone(_ queue: JobQueue, _ id: Int) async throws {
        for _ in 0 ..< 2000 where queue.jobs.first(where: { $0.id == id })?.isDone != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(queue.jobs.first { $0.id == id }?.isDone == true)
    }
}

/// A thread-safe counter for probes that run on job threads.
final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    @discardableResult
    func increment() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }
}
