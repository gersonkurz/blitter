import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// Git Log (#42) as an action: offered inside a working copy only, for the selected item or the
/// side's folder; it asks the app to present the log.
@MainActor
@Suite(.serialized)
struct GitLogActionTests {
    @Test func offeredInsideAWorkingCopyForTheSelectionOrTheFolder() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        var presented: [DialogRequest] = []
        sides.workspace.system.present = { presented.append($0) }
        #expect(!sides.workspace.canRun("git-log", on: .left)) // not a working copy (yet)

        sides.workspace.gitRepositories[sides.left] = KnownRepository(GitRepoStatus(), checked: Date())
        #expect(sides.workspace.workingCopyRoot(containing: sides.left + "/a.txt") == sides.left)
        #expect(sides.workspace.canRun("git-log", on: .left))
        #expect(!sides.workspace.canRun("git-log", on: .right)) // the other side is in none
        sides.workspace.perform(.runAction("git-log", .left))

        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.runAction("git-log", .left))

        sides.workspace.perform(.select(.left, ["a.txt", "b.txt"])) // two: whose history?
        #expect(!sides.workspace.canRun("git-log", on: .left))

        #expect(presented == [DialogRequest(kind: DialogRequest.gitLog, path: sides.left),
                              DialogRequest(kind: DialogRequest.gitLog, path: sides.left + "/a.txt")])
        sides.workspace.perform(.select(.left, [])) // the folder's menu: a click on empty space
        #expect(sides.workspace.contextMenu(for: .left, folder: true).contains(.action(
            id: "git-log",
            title: "Git Log…"
        )))
    }

    /// #42 review: a working copy selected in the folder that holds it is offered too.
    @Test func aWorkingCopySelectedInItsParentFolder() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/repo", withIntermediateDirectories: false)
        sides.file("left/plain.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.gitRepositories[sides.left + "/repo"] = KnownRepository(GitRepoStatus(), checked: Date())
        var presented: [DialogRequest] = []
        sides.workspace.system.present = { presented.append($0) }
        #expect(!sides.workspace.canRun("git-log", on: .left)) // the folder is in none
        sides.workspace.perform(.select(.left, ["plain.txt"]))
        #expect(!sides.workspace.canRun("git-log", on: .left)) // neither is this file
        sides.workspace.perform(.select(.left, ["repo"]))
        #expect(sides.workspace.canRun("git-log", on: .left))
        #expect(sides.workspace.actions(for: .left).contains { $0.id == "git-log" })
        sides.workspace.perform(.runAction("git-log", .left))
        #expect(presented == [DialogRequest(kind: DialogRequest.gitLog, path: sides.left + "/repo")])
    }

    @Test func theTreeOffersItOnlyOnFoldersInAKnownWorkingCopy() async throws {
        let sides = try SidesOnDisk()
        try await sides.settle()
        let ids = { (folder: String) in
            sides.workspace.treeContextMenu(for: folder).compactMap { entry -> String? in
                if case let .action(id, _) = entry {
                    id
                } else {
                    nil
                }
            }
        }
        #expect(!ids(sides.left + "/deep/folder").contains("git-log"))
        sides.workspace.gitRepositories[sides.left] = KnownRepository(GitRepoStatus(), checked: Date())
        #expect(ids(sides.left + "/deep/folder").contains("git-log"))
        #expect(!ids(sides.right).contains("git-log"))
    }
}
