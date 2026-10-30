@testable import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// Two real folders, one per side, and a Trash of their own.
@MainActor
final class SidesOnDisk {
    let root: String
    let left: String
    let right: String
    let trash: String
    let workspace: Workspace

    init(lister: @escaping Workspace.Lister = listDirectory, gate: DispatchSemaphore? = nil) throws {
        root = NSTemporaryDirectory() + "BlitterModelTests-" + UUID().uuidString
        left = root + "/left"
        right = root + "/right"
        trash = root + "/trash"
        for folder in [left, right, trash] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let trash = trash
        let jobs = JobQueue(trash: { path in
            try FileManager.default.moveItem(atPath: path, toPath: trash + "/" + (path as NSString).lastPathComponent)
        }, gate: gate)
        workspace = Workspace(
            initialLocation: left,
            home: root + "/home",
            lister: lister,
            directoryCheck: { _ in false },
            volumes: { [] },
            watcher: FakeWatcher.factory,
            jobs: jobs
        )
        workspace.perform(.navigate(.right, path: right))
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "x") -> String {
        let full = root + "/" + path
        FileManager.default.createFile(atPath: full, contents: Data(contents.utf8))
        return full
    }

    func names(_ side: Side) -> [String] {
        workspace.state(of: side).visibleEntries.map(\.entry.name)
    }

    func onDisk(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + folder)) ?? []).sorted()
    }

    /// Waits until no job is running and every read has finished.
    func settle() async throws {
        for _ in 0 ..< 400 {
            await workspace.settle()
            if !workspace.jobs.contains(where: { !$0.isDone }) {
                await workspace.settle()
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("jobs did not finish")
    }
}

@MainActor
@Suite(.serialized)
struct FileCommandsTests {
    @Test func copyToOtherSideCopiesTheSelectionAndShowsIt() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt"]))

        sides.workspace.perform(.copyToOtherSide)
        try await sides.settle()
        #expect(sides.onDisk("right") == ["a.txt"])
        #expect(sides.names(.right) == ["a.txt"]) // read again right away, no FSEvents here
        #expect(sides.names(.left) == ["a.txt", "b.txt"])
        #expect(sides.workspace.jobs.isEmpty) // a job that went fine leaves the list
    }

    @Test func moveToOtherSideGoesFromTheActiveSide() async throws {
        let sides = try SidesOnDisk()
        sides.file("right/r.txt")
        sides.workspace.perform(.refresh(.right))
        try await sides.settle()
        sides.workspace.perform(.activate(.right))
        sides.workspace.perform(.select(.right, ["r.txt"]))

        sides.workspace.perform(.moveToOtherSide)
        try await sides.settle()
        #expect(sides.names(.left) == ["r.txt"])
        #expect(sides.names(.right).isEmpty)
    }

    @Test func nothingSelectedStartsNoJob() async throws {
        let sides = try SidesOnDisk()
        try await sides.settle()
        var changes = 0
        sides.workspace.onChange = { changes += 1 }
        sides.workspace.perform(.copyToOtherSide)
        sides.workspace.perform(.trashSelection(.left))
        #expect(changes == 0 && sides.workspace.jobs.isEmpty)
    }

    @Test func trashSelectionMovesItemsToTheTrash() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        sides.workspace.perform(.trashSelection(.left))
        try await sides.settle()
        #expect(sides.names(.left).isEmpty)
        #expect(sides.onDisk("trash") == ["a.txt", "b.txt"])
        #expect(sides.workspace.state(of: .left).selection.isEmpty)
    }

    @Test func renameSelectsTheRenamedItem() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/old.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["old.txt"]))
        sides.workspace.perform(.requestRename(.left))
        #expect(sides.workspace.state(of: .left).renameRequest?.name == "old.txt")

        sides.workspace.perform(.rename(.left, path: sides.left + "/old.txt", newName: "new.txt"))
        #expect(sides.workspace.state(of: .left).renameRequest == nil)
        try await sides.settle()
        #expect(sides.names(.left) == ["new.txt"])
        #expect(sides.workspace.state(of: .left).selection == ["new.txt"])
    }

    @Test func renameToAnExistingNameReportsTheProblem() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt", "a")
        sides.file("left/b.txt", "b")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.rename(.left, path: sides.left + "/a.txt", newName: "b.txt"))
        try await sides.settle()
        let job = try #require(sides.workspace.jobs.first)
        #expect(job.errors.count == 1)
        #expect(sides.names(.left) == ["a.txt", "b.txt"])
        sides.workspace.perform(.dismissJob(job.id))
        #expect(sides.workspace.jobs.isEmpty)
    }

    @Test func requestRenameNeedsExactlyOneSelectedItem() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        sides.workspace.perform(.requestRename(.left))
        #expect(sides.workspace.state(of: .left).renameRequest == nil)

        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.requestRename(.left))
        let first = try #require(sides.workspace.state(of: .left).renameRequest)
        sides.workspace.perform(.cancelRename(.left))
        sides.workspace.perform(.requestRename(.left))
        #expect(sides.workspace.state(of: .left).renameRequest?.token != first.token)
    }

    @Test func newFolderPicksAFreeNameSelectsItAndEditsItsName() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/New Folder", withIntermediateDirectories: false)
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()

        sides.workspace.perform(.newFolder(.left))
        try await sides.settle()
        #expect(sides.onDisk("left") == ["New Folder", "New Folder 2"])
        #expect(sides.workspace.state(of: .left).selection == ["New Folder 2"])
        #expect(sides.workspace.state(of: .left).renameRequest?.name == "New Folder 2")
    }

    @Test func aConflictIsAnsweredThroughACommand() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt", "new")
        sides.file("right/a.txt", "old")
        sides.workspace.perform(.refresh(.left))
        sides.workspace.perform(.refresh(.right))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.copyToOtherSide)

        var waiting: Job?
        for _ in 0 ..< 400 {
            waiting = sides.workspace.jobs.first {
                if case .waiting = $0.state {
                    true
                } else {
                    false
                }
            }
            if waiting != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let job = try #require(waiting)
        sides.workspace.perform(.answerConflict(job: job.id, ConflictAnswer(.keepBoth)))
        try await sides.settle()
        #expect(sides.names(.right) == ["a 2.txt", "a.txt"])
    }

    @Test func aJobCanBeCancelledThroughACommand() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt", "new")
        sides.file("right/a.txt", "old")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.copyToOtherSide)
        let id = try #require(sides.workspace.jobs.first?.id)
        sides.workspace.perform(.cancelJob(id))
        try await sides.settle()
        #expect(sides.workspace.jobs.first?.state == .cancelled)
        #expect(try String(contentsOfFile: sides.right + "/a.txt", encoding: .utf8) == "old")
    }

    // MARK: Items from elsewhere (pasted)

    @Test func itemsFromElsewhereAreCopiedOrMovedIntoTheSide() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.root + "/outside", withIntermediateDirectories: false)
        let copied = sides.file("outside/copied.txt")
        let moved = sides.file("outside/moved.txt")
        try await sides.settle()

        sides.workspace.perform(.copyItems([copied], into: .right))
        sides.workspace.perform(.moveItems([moved], into: .right))
        try await sides.settle()
        #expect(sides.names(.right) == ["copied.txt", "moved.txt"])
        #expect(sides.onDisk("outside") == ["copied.txt"])

        var changes = 0
        sides.workspace.onChange = { changes += 1 }
        sides.workspace.perform(.copyItems([], into: .right))
        #expect(changes == 0 && sides.workspace.jobs.isEmpty)
    }

    // MARK: Names belong to their folder

    /// Going up selects the folder we came from only once the parent's listing is there; before
    /// that nothing is selected, so a command cannot hit "/left/child/child".
    @Test func goingUpNeverAppliesTheSelectionToTheOldListing() async throws {
        let gate = HeldListing()
        let sides = try SidesOnDisk(lister: gate.list)
        try FileManager.default.createDirectory(atPath: sides.left + "/child/child", withIntermediateDirectories: true)
        sides.workspace.perform(.navigate(.left, path: sides.left + "/child"))
        try await sides.settle()

        gate.hold(sides.left)
        sides.workspace.perform(.goToParent(.left))
        #expect(sides.workspace.state(of: .left).entriesLocation == sides.left + "/child") // old rows
        #expect(sides.workspace.state(of: .left).selection.isEmpty)
        sides.workspace.perform(.trashSelection(.left))
        #expect(sides.workspace.jobs.isEmpty)

        gate.release()
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).selection == ["child"])
        sides.workspace.perform(.trashSelection(.left))
        try await sides.settle()
        #expect(sides.onDisk("trash") == ["child"]) // /left/child, with its own child inside
        #expect(sides.onDisk("left").isEmpty)
    }

    @Test func aListingOfAnotherFolderStartsWithoutSelection() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/same.txt")
        sides.file("right/same.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["same.txt"]))
        sides.workspace.perform(.navigate(.left, path: sides.right))
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).selection.isEmpty) // not the other folder's same.txt
    }

    /// A new folder finishes after the side went to another folder that has a "New Folder" too:
    /// nothing there gets selected or renamed.
    @Test func aJobFinishingAfterNavigationLeavesTheOtherFolderAlone() async throws {
        let gate = DispatchSemaphore(value: 0)
        let sides = try SidesOnDisk(gate: gate)
        try FileManager.default.createDirectory(atPath: sides.right + "/New Folder", withIntermediateDirectories: false)
        sides.file("right/renamed.txt")
        sides.file("left/original.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()

        sides.workspace.perform(.newFolder(.left))
        sides.workspace.perform(.rename(.left, path: sides.left + "/original.txt", newName: "renamed.txt"))
        sides.workspace.perform(.navigate(.left, path: sides.right))
        await sides.workspace.settle()
        gate.signal()
        gate.signal()
        try await sides.settle()

        #expect(sides.onDisk("left") == ["New Folder", "renamed.txt"]) // both jobs did their work
        let state = sides.workspace.state(of: .left)
        #expect(state.location == sides.right)
        #expect(state.renameRequest == nil)
        #expect(state.selection.isEmpty)
        // And going back does not pick up the stale follow-ups either.
        sides.workspace.perform(.goBack(.left))
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).renameRequest == nil)
        #expect(sides.workspace.state(of: .left).selection.isEmpty)
    }
}

/// The real lister, except that listing one chosen folder waits until released.
final class HeldListing: Sendable {
    private let held = Mutex<String?>(nil)
    private let gate = DispatchSemaphore(value: 0)

    func hold(_ path: String) {
        held.withLock { $0 = path }
    }

    func release() {
        held.withLock { $0 = nil }
        gate.signal()
    }

    func list(_ path: String) async throws -> [DirectoryEntry] {
        if held.withLock({ $0 == path }) {
            let gate = gate
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    gate.wait()
                    continuation.resume()
                }
            }
        }
        return try await listDirectory(path)
    }
}
