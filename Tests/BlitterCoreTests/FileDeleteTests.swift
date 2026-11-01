@testable import BlitterCore
import Foundation
import Testing

/// Deleting for good (#17): the one operation that bypasses the Trash. Everything happens in a
/// temporary folder.
@MainActor
@Suite(.serialized)
struct FileDeleteTests {
    @Test func filesAndFoldersAreDeletedForGoodNotTrashed() async throws {
        let fixture = try OperationFixture()
        let file = fixture.file("source/a.txt")
        fixture.file("source/folder/sub/deep.txt")
        fixture.file("source/keep.txt")
        let job = try await fixture.run(.delete([file, fixture.source + "/folder"]))
        #expect(job.errors.isEmpty && job.state == .finished)
        #expect(fixture.names("source") == ["keep.txt"])
        #expect(fixture.names("trash").isEmpty)
        #expect(job.progress.doneItems == 2 && job.progress.totalItems == 2)
    }

    /// A link to a folder goes; the folder it points to, and what is in it, stay.
    @Test func aSymbolicLinkIsRemovedNotFollowed() async throws {
        let fixture = try OperationFixture()
        fixture.file("destination/target/precious.txt")
        let link = fixture.source + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fixture.destination + "/target")
        let job = try await fixture.run(.delete([link]))
        #expect(job.errors.isEmpty)
        #expect(fixture.names("source").isEmpty)
        #expect(fixture.contents("destination/target/precious.txt") == "x")
    }

    @Test func stoppingPartwayLeavesTheRestOfTheFolder() throws {
        let folder = try TemporaryFolder()
        let tree = folder.path + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: false)
        for index in 0 ..< 20 {
            FileManager.default.createFile(atPath: tree + "/f\(index)", contents: Data("x".utf8))
        }
        var asked = 0
        let code = FileOperations.deleteForGood(tree) {
            asked += 1
            return asked > 5
        }
        #expect(code == ECANCELED)
        let left = try FileManager.default.contentsOfDirectory(atPath: tree)
        #expect(left.count >= 15) // at most the five confirmed items are gone
        #expect(asked == 6)

        #expect(FileOperations.deleteForGood(tree) { false } == 0)
        #expect(!FileManager.default.fileExists(atPath: tree))
    }

    /// Cancelled while a folder is half deleted: the job says so for that folder and stops.
    @Test func cancellingInsideAFolderIsReportedNotTakenForSuccess() throws {
        let folder = try TemporaryFolder()
        let tree = folder.path + "/tree"
        let next = folder.path + "/next.txt"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: false)
        for index in 0 ..< 20 {
            FileManager.default.createFile(atPath: tree + "/f\(index)", contents: Data("x".utf8))
        }
        FileManager.default.createFile(atPath: next, contents: Data("x".utf8))
        let context = CancelOnItem("tree")
        var operations = FileOperations(context: context)
        let errors = operations.run(.delete([tree, next]))
        #expect(errors.map(\.path) == [tree])
        #expect(errors.first?.message.contains("cancelled") == true)
        #expect(FileManager.default.fileExists(atPath: tree))
        #expect(FileManager.default.fileExists(atPath: next)) // the job stopped
    }

    @Test func anItemThatCannotBeDeletedIsReportedAndTheOthersStillGo() async throws {
        let fixture = try OperationFixture()
        fixture.file("source/locked/inside.txt")
        let other = fixture.file("source/other.txt")
        let locked = fixture.source + "/locked"
        chmod(locked, 0o555) // its contents cannot be removed
        defer { chmod(locked, 0o755) }
        let job = try await fixture.run(.delete([locked, other]))
        #expect(job.errors.map(\.path) == [locked])
        #expect(fixture.names("source") == ["locked"])
        #expect(fixture.names("source/locked") == ["inside.txt"])
    }

    @Test func aMissingItemIsReported() async throws {
        let fixture = try OperationFixture()
        let job = try await fixture.run(.delete([fixture.source + "/gone.txt"]))
        #expect(job.errors.count == 1)
        #expect(job.errors.first?.message.isEmpty == false)
    }
}

/// Cancels the job as soon as it starts on the named item.
private final class CancelOnItem: OperationContext, @unchecked Sendable {
    let cancellation = CancellationFlag()
    private let name: String
    private var progress = JobProgress()

    init(_ name: String) {
        self.name = name
    }

    func update(_ change: (inout JobProgress) -> Void) {
        change(&progress)
        if progress.currentItem == name {
            cancellation.set()
        }
    }

    func ask(_: Conflict) -> ConflictAnswer? {
        nil
    }
}
