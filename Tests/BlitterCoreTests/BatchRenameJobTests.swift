@testable import BlitterCore
import Foundation
import Testing

/// The batch rename job: all or none, names swapped and passed along.
@MainActor
struct BatchRenameJobTests {
    private func renames(_ fixture: OperationFixture, _ pairs: [(String, String)]) -> FileOperation {
        .renameAll(pairs.map { Rename(path: fixture.source + "/" + $0.0, newName: $0.1) })
    }

    @Test func namesCanBeSwappedPassedAlongAndChangeCase() async throws {
        let fixture = try OperationFixture()
        for name in ["a", "b", "c", "d.txt"] {
            fixture.file("source/" + name, name)
        }
        let job = try await fixture.run(renames(fixture, [("a", "b"), ("b", "a"), ("c", "e"), ("d.txt", "D.TXT")]))
        #expect(job.errors.isEmpty)
        #expect(fixture.names("source") == ["D.TXT", "a", "b", "e"]) // no temporary name left behind
        #expect(fixture.contents("source/b") == "a" && fixture.contents("source/a") == "b")
        #expect(fixture.contents("source/e") == "c" && fixture.contents("source/D.TXT") == "d.txt")

        // Passed along: "a" takes "b"'s name while "b" takes "c"'s.
        let chain = try await fixture.run(renames(fixture, [("a", "b"), ("b", "c")]))
        #expect(chain.errors.isEmpty && fixture.contents("source/b") == "b" && fixture.contents("source/c") == "a")
    }

    @Test func anyUnusableNameRenamesNothing() async throws {
        let fixture = try OperationFixture()
        for name in ["a", "b", "kept"] {
            fixture.file("source/" + name, name)
        }
        // A name an item outside the batch has, ignoring case.
        var job = try await fixture.run(renames(fixture, [("a", "x"), ("b", "KEPT")]))
        #expect(job.errors.map(\.path) == [fixture.source + "/b"])
        #expect(fixture.names("source") == ["a", "b", "kept"])
        // Two items with one name.
        job = try await fixture.run(renames(fixture, [("a", "same"), ("b", "Same")]))
        #expect(job.errors.count == 1 && fixture.names("source") == ["a", "b", "kept"])
        // A name that is not one.
        job = try await fixture.run(renames(fixture, [("a", "x"), ("b", "y/z")]))
        #expect(job.errors.count == 1 && fixture.names("source") == ["a", "b", "kept"])
    }

    /// A folder that may be written to but not listed: what is in it is not known, so nothing
    /// is renamed (#54 review).
    @Test func aFolderThatCannotBeListedRenamesNothing() async throws {
        let fixture = try OperationFixture()
        for name in ["a", "b"] {
            fixture.file("source/" + name, name)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o333], ofItemAtPath: fixture.source)
        let job = try await fixture.run(renames(fixture, [("a", "x"), ("b", "y")]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.source)
        #expect(job.errors.count == 2 && job.errors.allSatisfy { $0.message.contains("could not be read") })
        #expect(fixture.names("source") == ["a", "b"] && fixture.contents("source/a") == "a")
        #expect(fixture.contents("source/b") == "b")
    }

    /// A renamer that fails where `failing` says, and otherwise renames.
    private static func renamer(failing: @escaping @Sendable (String, String) -> Bool) -> FileOperations.Renamer {
        { path, target in failing(path, target) ? EIO : FileOperations.renameExclusive(path, target) }
    }

    private func setUp(_ rename: @escaping FileOperations.Renamer) throws -> OperationFixture {
        let fixture = try OperationFixture(rename: rename)
        for name in ["a", "b"] {
            fixture.file("source/" + name, name)
        }
        return fixture
    }

    @Test func aFailureWhileStagingPutsEverythingBack() async throws {
        let fixture = try setUp(Self.renamer { path, _ in path.hasSuffix("/b") })
        let job = try await fixture.run(renames(fixture, [("a", "x"), ("b", "y")]))
        #expect(job.errors.map(\.path) == [fixture.source + "/b"])
        #expect(fixture.names("source") == ["a", "b"] && fixture.contents("source/a") == "a")
    }

    @Test func aFailureAtTheNewNamesPutsEverythingBack() async throws {
        // "a" already has its new name when "b" fails; a swap shows the order of the undo.
        let fixture = try setUp(Self.renamer { _, target in target.hasSuffix("/c") })
        fixture.file("source/z", "z")
        let job = try await fixture.run(renames(fixture, [("a", "b"), ("b", "a"), ("z", "c")]))
        #expect(job.errors.count == 1)
        #expect(fixture.names("source") == ["a", "b", "z"])
        #expect(fixture.contents("source/a") == "a" && fixture.contents("source/b") == "b")
    }

    @Test func anItemThatCannotGetItsNameBackIsTold() async throws {
        let fixture = try setUp(Self.renamer { path, target in
            target.hasSuffix("/y") || (path.contains(".blitter-rename-") && target.hasSuffix("/a"))
        })
        let job = try await fixture.run(renames(fixture, [("a", "x"), ("b", "y")]))
        let names = fixture.names("source")
        #expect(names.count == 2 && names.contains("b") && names.contains { $0.hasPrefix(".blitter-rename-") })
        #expect(job.errors.count == 2 && job.errors.contains { $0.message.contains("now named “.blitter-rename-") })

        // What the rollback left is recorded for Undo (#61), and Undo puts it right.
        #expect(job.undo.flatMap(\.paths).count == 1)
        let undone = try await UndoTests.run(.undo(job.undo), on: JobQueue(trash: { _ in nil }))
        #expect(undone.errors.isEmpty && fixture.names("source") == ["a", "b"])
    }

    @Test func cancelBeforeTheStartRenamesNothingAfterItTheBatchFinishes() async throws {
        let gate = DispatchSemaphore(value: 0)
        let early = try OperationFixture(gate: gate)
        early.file("source/a", "a")
        let id = early.queue.start(renames(early, [("a", "x")]))
        early.queue.cancel(id)
        gate.signal()
        for _ in 0 ..< 400 where early.queue.jobs.first?.isDone != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(early.queue.jobs.first?.state == .cancelled && early.names("source") == ["a"])

        // Cancelled while it renames: it goes on, and counts as finished.
        let box = JobBox()
        let late = try setUp { path, target in
            if !box.cancelled {
                box.cancelled = true
                DispatchQueue.main.sync { MainActor.assumeIsolated { box.queue?.cancel(box.id) } }
            }
            return FileOperations.renameExclusive(path, target)
        }
        box.queue = late.queue
        box.id = 1
        let job = try await late.run(renames(late, [("a", "b"), ("b", "a")]))
        #expect(job.state == .finished && job.errors.isEmpty)
        #expect(late.contents("source/a") == "b" && box.cancelled)
    }
}

/// What the renamer needs to cancel its own job from the job's thread.
private final class JobBox: @unchecked Sendable {
    var cancelled = false
    var id = 0
    weak var queue: JobQueue?
}
