@testable import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #61: the workspace keeps an undo journal of its file operations; Undo is an action like any
/// other, for menus, shortcuts and the automation socket alike.
@MainActor
@Suite(.serialized)
struct UndoJournalTests {
    @Test func undoTakesBackTheLastOperation() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt", "alpha")
        sides.file("left/b.txt", "beta")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.lastUndo == nil && !sides.workspace.canRun("undo", on: .left))
        #expect(!sides.workspace.actions(for: .left).contains { $0.id == "undo" }) // menus agree

        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.copyToOtherSide)
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["b.txt"]))
        sides.workspace.perform(.trashSelection(.left))
        try await sides.settle()
        #expect(sides.workspace.undoJournal.map(\.title) == ["Copy", "Move to Trash"])
        #expect(sides.workspace.canRun("undo", on: .left) && sides.workspace.canRun("undo", on: .right))
        #expect(sides.workspace.actions(for: .right).contains { $0.id == "undo" })

        sides.workspace.perform(.runAction("undo", .right)) // either side: it is the last change
        try await sides.settle()
        #expect(sides.onDisk("left") == ["a.txt", "b.txt"] && sides.names(.left) == ["a.txt", "b.txt"])
        #expect(sides.workspace.undoJournal.map(\.title) == ["Copy"]) // an undo is not recorded

        sides.workspace.perform(.runAction("undo", .left))
        try await sides.settle()
        #expect(sides.onDisk("right").isEmpty && sides.names(.right).isEmpty)
        #expect(sides.workspace.lastUndo == nil && !sides.workspace.canRun("undo", on: .left))
        #expect(sides.onDisk("trash") == ["a.txt"]) // the copy, in the Trash, not deleted
    }

    /// The entry undone is the one that was shown (or allowed): a stale id does nothing.
    @Test func onlyTheEntryShownIsUndone() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.newFolder(.left))
        try await sides.settle()
        let entry = try #require(sides.workspace.lastUndo)
        #expect(entry.title == "New Folder")
        sides.workspace.perform(.undo(entry: entry.id + 1))
        try await sides.settle()
        #expect(sides.onDisk("left") == ["New Folder", "a.txt"] && sides.workspace.lastUndo == entry)
        sides.workspace.perform(.undo(entry: entry.id))
        try await sides.settle()
        #expect(sides.onDisk("left") == ["a.txt"])
    }

    @Test func theJournalKeepsTheLastHundred() {
        let workspace = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] }, volumes: { [] },
                                  watcher: FakeWatcher.factory)
        for index in 0 ..< 105 {
            var job = Job(id: index, operation: .newFolder(parent: "/x", name: "f\(index)"))
            job.undo = [.trash("/x/f\(index)", ItemIdentity(device: 1, inode: UInt64(index)))]
            job.state = .finished
            workspace.recordUndo(of: job)
        }
        #expect(workspace.undoJournal.count == Workspace.undoLimit)
        #expect(workspace.undoJournal.first?.items == ["/x/f5"])
    }

    /// Over the automation socket Undo is a change like any other: its preview names what it
    /// undoes, and it runs only once the user allows it.
    @Test func automationPreviewsWhatUndoDoes() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.trashSelection(.left))
        try await sides.settle()
        let reply = try #require(await sides.workspace.handleAutomation(
            #"{"jsonrpc": "2.0", "id": 1, "method": "preview", "params": {"action": "undo", "side": "left"}}"#,
            client: "test"
        ))
        #expect(reply.contains(#""effect":"changes""#) && reply.contains(#""needsConfirmation":true"#))
        #expect(reply.contains("Undo Move to Trash"))
        #expect(reply.contains(sides.left + "/a.txt"))
    }

    /// Undos run one at a time (#61 review): a second ⌘Z while one runs is refused, so the
    /// earlier change is undone only after the later one is back.
    @Test func undosRunOneAtATime() async throws {
        // Created at 0: a semaphore freed below the count it was created with traps.
        let gate = DispatchSemaphore(value: 0)
        gate.signal() // the two moves run; the undos wait
        gate.signal()
        let sides = try SidesOnDisk(gate: gate)
        sides.file("left/a.txt", "alpha")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.moveToOtherSide) // left → right
        try await sides.settle()
        sides.workspace.perform(.activate(.right))
        sides.workspace.perform(.select(.right, ["a.txt"]))
        sides.workspace.perform(.moveToOtherSide) // right → left again
        try await sides.settle()
        #expect(sides.workspace.undoJournal.count == 2)

        sides.workspace.perform(.runAction("undo", .left)) // waits at the gate
        await sides.workspace.settle()
        #expect(!sides.workspace.canRun("undo", on: .left) && !sides.workspace.actions(for: .left)
            .contains { $0.id == "undo" })
        let waiting = try #require(sides.workspace.lastUndo)
        sides.workspace.perform(.undo(entry: waiting.id)) // the command refuses too
        #expect(sides.workspace.undoJournal.count == 1 && sides.workspace.jobs.count == 1)

        gate.signal()
        try await sides.settle()
        #expect(sides.onDisk("right") == ["a.txt"] && sides.workspace.canRun("undo", on: .left))
        sides.workspace.perform(.runAction("undo", .left))
        gate.signal()
        try await sides.settle()
        #expect(sides.onDisk("left") == ["a.txt"] && sides.onDisk("right").isEmpty)
        #expect(sides.workspace.undoJournal.isEmpty && sides.workspace.jobs.isEmpty)
    }

    /// A move to another volume makes a copy there, and Undo brings it back as a copy again:
    /// another item each time. Older entries follow it (#61 review): rename a → b, move b to
    /// another volume, undo both, and a is back.
    @Test func olderEntriesFollowAnItemAcrossVolumes() async throws {
        let sides = try SidesOnDisk(otherVolume: true)
        sides.file("left/a.txt", "alpha")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.rename(.left, path: sides.left + "/a.txt", newName: "b.txt"))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["b.txt"]))
        sides.workspace.perform(.moveToOtherSide)
        try await sides.settle()
        #expect(sides.onDisk("right") == ["b.txt"] && sides.onDisk("left").isEmpty)

        sides.workspace.perform(.runAction("undo", .left)) // the move: copied back
        try await sides.settle()
        #expect(sides.onDisk("left") == ["b.txt"] && sides.workspace.jobs.isEmpty)
        sides.workspace.perform(.runAction("undo", .left)) // the rename, of the item copied back
        try await sides.settle()
        #expect(sides.onDisk("left") == ["a.txt"] && sides.onDisk("right").isEmpty)
        #expect(sides.workspace.jobs.isEmpty && sides.workspace.undoJournal.isEmpty) // no problems

        // An item inside a folder moved to another volume and back follows it too.
        try FileManager.default.createDirectory(atPath: sides.left + "/folder", withIntermediateDirectories: false)
        sides.file("left/folder/c.txt", "gamma")
        sides.workspace.perform(.rename(.left, path: sides.left + "/folder/c.txt", newName: "d.txt"))
        try await sides.settle()
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["folder"]))
        sides.workspace.perform(.moveToOtherSide)
        try await sides.settle()
        sides.workspace.perform(.runAction("undo", .left))
        try await sides.settle()
        sides.workspace.perform(.runAction("undo", .left))
        try await sides.settle()
        #expect(sides.onDisk("left/folder") == ["c.txt"] && sides.workspace.jobs.isEmpty)
    }
}
