@testable import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// #112: Undo of a job that has not started yet takes it out of the queue — when it is the newest
/// thing done. A job held here: its paths are never resolved (under "held/"), so it waits.
@MainActor
@Suite(.serialized)
final class UndoWaitingJobTests {
    private let root = NSTemporaryDirectory() + "BlitterUndoWaiting-" + UUID().uuidString
    private let release = DispatchSemaphore(value: 0)
    /// While set, every job's paths are held, not only those under held/.
    private let holdAll = Hold()
    private let workspace: Workspace

    final class Hold: Sendable {
        private let flag = Mutex(false)

        var isOn: Bool {
            get { flag.withLock { $0 } }
            set { flag.withLock { $0 = newValue } }
        }
    }

    init() throws {
        for folder in ["held", "other", "right"] {
            try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        let release = release
        let holdAll = holdAll
        workspace = Workspace(initialLocation: root, home: root, directoryCheck: { _ in false }, volumes: { [] },
                              watcher: FakeWatcher.factory,
                              jobs: JobQueue(trash: { _ in nil }, resolve: { use in
                                  if holdAll.isOn || use.items.contains(where: { $0.contains("/held/") }) {
                                      release.wait()
                                  }
                                  return use.resolved()
                              }, stallDelay: 0.1))
    }

    isolated deinit {
        for _ in 0 ..< 4 {
            release.signal()
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    private func file(_ path: String) -> String {
        let full = root + "/" + path
        FileManager.default.createFile(atPath: full, contents: Data("x".utf8))
        return full
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    @Test func undoTakesOutTheNewestWaitingJob() async throws {
        let waiting = workspace.startJob(.copy([file("held/a.txt")], into: root + "/right"))
        #expect(workspace.waitingUndo?.job == waiting)
        #expect(workspace.undoTitle == "Undo Copy (Not Started)" && workspace.canRun("undo", on: .left))
        workspace.perform(.runAction("undo", .left))
        try await waitUntil { self.workspace.jobs.isEmpty } // cancelled, and gone
        #expect(workspace.undoTitle == "Undo" && !workspace.canRun("undo", on: .left))
        #expect(!FileManager.default.fileExists(atPath: root + "/right/a.txt"))
    }

    /// A job finished after the waiting one was started is the newest: Undo undoes it first; then
    /// the waiting one is the newest again. (The undo itself is a heavy job: it runs once the
    /// copy before it has.)
    @Test func aJobDoneLaterIsUndoneFirst() async throws {
        let waiting = workspace.startJob(.copy([file("held/a.txt")], into: root + "/right"))
        let renamed = file("other/b.txt")
        workspace.startJob(.rename(renamed, newName: "c.txt"))
        try await waitUntil { self.workspace.lastUndo != nil }
        #expect(workspace.undoTitle == "Undo Rename" && workspace.waitingUndo == nil)
        workspace.perform(.runAction("undo", .left))
        #expect(workspace.undoTitle == "Undo Copy (Not Started)" && workspace.waitingUndo?.job == waiting)
        release.signal() // the copy goes on, then the undo
        try await waitUntil { FileManager.default.fileExists(atPath: renamed) } // renamed back
        try await waitUntil { FileManager.default.fileExists(atPath: self.root + "/right/a.txt") }
    }

    /// #112 review: while an undo runs, the journal is not undone again — even though Undo can
    /// still take a waiting job out of the queue.
    @Test func anUndoRunningKeepsTheJournalWaitingButAWaitingJobCanBeTakenOut() async throws {
        workspace.startJob(.rename(file("other/a.txt"), newName: "b.txt"))
        workspace.startJob(.rename(file("other/c.txt"), newName: "d.txt"))
        try await waitUntil { self.workspace.undoJournal.count == 2 }
        holdAll.isOn = true // from now on every job waits
        workspace.perform(.runAction("undo", .left)) // the last rename: an undo, held
        let entry = try #require(workspace.lastUndo)
        #expect(workspace.undoJournal.count == 1 && workspace.jobs.count == 1)
        let waiting = workspace.startJob(.copy([file("other/e.txt")], into: root + "/right"))
        #expect(workspace.waitingUndo?.job == waiting && workspace.canRun("undo", on: .left))

        workspace.perform(.undo(entry: entry.id)) // the journal: refused while the undo runs
        #expect(workspace.undoJournal.count == 1 && workspace.jobs.count == 2)

        workspace.perform(.runAction("undo", .left)) // the waiting copy: taken out
        try await waitUntil { !self.workspace.jobs.contains { $0.id == waiting } }
        #expect(workspace.undoJournal.count == 1)
        holdAll.isOn = false
        release.signal() // the undo's resolver and the cancelled copy's both wait: one each
        release.signal()
        try await waitUntil { FileManager.default.fileExists(atPath: self.root + "/other/c.txt") } // undone
    }

    /// Deleting for good cannot be undone, waiting or not: Undo leaves it alone.
    @Test func aWaitingDeleteIsNotTakenOut() {
        let delete = workspace.startJob(.delete([file("held/a.txt")]))
        #expect(workspace.waitingUndo == nil && workspace.undoTitle == "Undo")
        #expect(workspace.jobs.first { $0.id == delete }?.state == .queued)
    }

    /// The automation socket's preview says what Undo does with a waiting job.
    @Test func automationIsToldItIsCancelled() throws {
        workspace.startJob(.copy([file("held/a.txt")], into: root + "/right"))
        let action = try #require(workspace.actionRegistry.action("undo"))
        #expect(workspace.plan(for: action, on: .left).detail == "Undo Copy (Not Started): it is cancelled")
    }
}
