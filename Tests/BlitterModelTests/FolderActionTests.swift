@testable import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// Folder actions from the tree's menu (#20): they run once the side shows the folder, and never
/// anywhere else.
@MainActor
@Suite(.serialized)
struct FolderActionTests {
    @Test func theTreeMenuHasTheFolderMenusFolderActions() async throws {
        let sides = try SidesOnDisk()
        try await sides.settle()
        #expect(ids(sides.workspace.treeContextMenu()) == ["new-folder", "-", "open-in-terminal", "open-in-code"])
        // A selection action in the folder menu does not fit a tree folder.
        sides.workspace.settings.contextMenus.folder = [.action("move-to-trash"), .action("open-in-code")]
        #expect(ids(sides.workspace.treeContextMenu()) == ["open-in-code"])
    }

    @Test func onTheShownFolderItRunsAtOnce() async throws {
        let sides = try SidesOnDisk()
        try await sides.settle()
        sides.workspace.perform(.runFolderAction("new-folder", .left, folder: sides.left))
        try await sides.settle()
        #expect(sides.onDisk("left") == ["New Folder"])
    }

    @Test func whileTheFolderIsReadItRunsWhenTheListingArrives() async throws {
        let gated = GatedLister(holding: "sub")
        let sides = try SidesOnDisk(lister: gated.list)
        try FileManager.default.createDirectory(atPath: sides.left + "/sub", withIntermediateDirectories: false)
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()

        sides.workspace.perform(.navigate(.left, path: sides.left + "/sub")) // held back
        sides.workspace.perform(.runFolderAction("new-folder", .left, folder: sides.left + "/sub"))
        #expect(sides.onDisk("left") == ["sub"] && sides.workspace.jobs.isEmpty) // not in the old folder
        gated.release()
        try await sides.settle()
        #expect(sides.onDisk("left/sub") == ["New Folder"])
        #expect(sides.onDisk("left") == ["sub"])
    }

    @Test func goingElsewhereFirstDropsIt() async throws {
        let gated = GatedLister(holding: "sub")
        let sides = try SidesOnDisk(lister: gated.list)
        try FileManager.default.createDirectory(atPath: sides.left + "/sub", withIntermediateDirectories: false)
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()

        sides.workspace.perform(.navigate(.left, path: sides.left + "/sub"))
        sides.workspace.perform(.runFolderAction("new-folder", .left, folder: sides.left + "/sub"))
        // Elsewhere and straight back, before anything was read: the choice was for the visit
        // that is gone, so it must not run on this one.
        sides.workspace.perform(.navigate(.left, path: sides.left))
        sides.workspace.perform(.navigate(.left, path: sides.left + "/sub"))
        gated.release()
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).entriesLocation == sides.left + "/sub")
        #expect(sides.onDisk("left") == ["sub"])
        #expect(sides.onDisk("left/sub").isEmpty)
        #expect(sides.workspace.jobs.isEmpty)
    }

    @Test func aFolderThatCouldNotBeReadTakesNoAction() async throws {
        let failing = FailingLister(failing: "sub")
        let sides = try SidesOnDisk(lister: failing.list)
        try FileManager.default.createDirectory(atPath: sides.left + "/sub", withIntermediateDirectories: false)
        sides.workspace.perform(.navigate(.left, path: sides.left + "/sub"))
        try await sides.settle()
        guard case .failed = sides.workspace.state(of: .left).status else {
            Issue.record("the listing should have failed")
            return
        }
        sides.workspace.perform(.runFolderAction("new-folder", .left, folder: sides.left + "/sub"))
        failing.heal()
        sides.workspace.perform(.refresh(.left)) // now it reads fine
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).status == .loaded)
        #expect(sides.onDisk("left/sub").isEmpty)
        #expect(sides.workspace.jobs.isEmpty)
    }

    @Test func otherFoldersAndOtherActionsDoNothing() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        var changes = 0
        sides.workspace.onChange = { changes += 1 }
        // A folder the side does not show, and an action that is not a folder action.
        sides.workspace.perform(.runFolderAction("new-folder", .left, folder: sides.right))
        sides.workspace.perform(.runFolderAction("move-to-trash", .left, folder: sides.left))
        try await sides.settle()
        #expect(changes == 0 && sides.workspace.jobs.isEmpty)
        #expect(sides.onDisk("left") == ["a.txt"] && sides.onDisk("right").isEmpty)
    }

    private func ids(_ entries: [ShownMenuEntry]) -> [String] {
        entries.map {
            if case let .action(id, _) = $0 {
                id
            } else {
                "-"
            }
        }
    }
}

/// Lists folders from disk, but holds back any folder named `held` until released.
private final class GatedLister: Sendable {
    private let held: String
    private let gate = DispatchSemaphore(value: 0)
    private let released = Atomic(false)

    init(holding name: String) {
        held = name
    }

    func release() {
        released.store(true, ordering: .relaxed)
        gate.signal()
    }

    var list: Workspace.Lister {
        { [self] path in
            if (path as NSString).lastPathComponent == held, !released.load(ordering: .relaxed) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        self.gate.wait()
                        self.gate.signal() // let later reads through too
                        continuation.resume()
                    }
                }
            }
            return try await listDirectory(path)
        }
    }
}

/// Lists folders from disk, but fails for a folder named `failing` until healed.
private final class FailingLister: Sendable {
    private let name: String
    private let healed = Atomic(false)

    init(failing name: String) {
        self.name = name
    }

    func heal() {
        healed.store(true, ordering: .relaxed)
    }

    var list: Workspace.Lister {
        { [self] path in
            if (path as NSString).lastPathComponent == name, !healed.load(ordering: .relaxed) {
                throw POSIXError(.EACCES)
            }
            return try await listDirectory(path)
        }
    }
}
