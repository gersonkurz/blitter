@testable import BlitterModel
import Foundation
import Testing

/// The action registry (#15): ids, scopes, and running an action through the one command.
@MainActor
@Suite(.serialized)
struct ActionsTests {
    @Test func everyBuiltInActionHasAUniqueIDAndATitle() {
        let ids = ActionRegistry.builtIn.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ActionRegistry.builtIn.all.contains { $0.title.isEmpty })
        #expect(ActionRegistry.builtIn.action("move-to-trash")?.title == "Move to Trash")
        #expect(ActionRegistry.builtIn.action("no-such-action") == nil)
        #expect(ActionRegistry.builtIn.action("copy")?.output == .clipboard)
    }

    @Test func menusOfferOnlyTheActionsWhoseScopeFits() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()

        // Nothing selected: only what works on the folder itself.
        #expect(ids(sides.workspace.actions(for: .left)) == ["new-folder"])

        sides.workspace.perform(.select(.left, ["a.txt"]))
        let single = ids(sides.workspace.actions(for: .left))
        #expect(single.contains("open") && single.contains("rename") && single.contains("move-to-trash"))
        #expect(single.contains("new-folder")) // the folder is still there to act on

        sides.workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        let several = ids(sides.workspace.actions(for: .left))
        #expect(!several.contains("open") && !several.contains("rename"))
        #expect(several.contains("copy-to-other-side") && several.contains("move-to-trash"))
        #expect(sides.workspace.canRun("move-to-trash", on: .left))
        #expect(!sides.workspace.canRun("rename", on: .left))
        #expect(!sides.workspace.canRun("no-such-action", on: .left))
    }

    @Test func aFolderThatCouldNotBeReadOffersNoFolderActions() async throws {
        let sides = try SidesOnDisk()
        sides.workspace.perform(.navigate(.left, path: sides.root + "/missing"))
        try await sides.settle()
        guard case .failed = sides.workspace.state(of: .left).status else {
            Issue.record("the missing folder was read")
            return
        }
        #expect(sides.workspace.actions(for: .left).isEmpty)
        var changes = 0
        sides.workspace.onChange = { changes += 1 }
        sides.workspace.perform(.runAction("new-folder", .left))
        try await sides.settle()
        #expect(changes == 0 && sides.workspace.jobs.isEmpty)
    }

    @Test func runningAnActionCarriesOutItsCommand() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt", "b.txt"]))

        sides.workspace.perform(.runAction("move-to-trash", .left))
        try await sides.settle()
        #expect(sides.onDisk("trash") == ["a.txt", "b.txt"])
        #expect(sides.names(.left).isEmpty)
    }

    /// Copy and move work from the side the action runs on, active or not.
    @Test func copyAndMoveGoFromTheSideTheActionRunsOn() async throws {
        let sides = try SidesOnDisk()
        sides.file("right/r.txt")
        sides.file("right/s.txt")
        sides.workspace.perform(.refresh(.right))
        try await sides.settle()
        #expect(sides.workspace.activeSide == .left)

        sides.workspace.perform(.select(.right, ["r.txt"]))
        sides.workspace.perform(.runAction("copy-to-other-side", .right))
        try await sides.settle()
        sides.workspace.perform(.select(.right, ["s.txt"]))
        sides.workspace.perform(.runAction("move-to-other-side", .right))
        try await sides.settle()
        #expect(sides.onDisk("left") == ["r.txt", "s.txt"])
        #expect(sides.onDisk("right") == ["r.txt"])
    }

    @Test func anActionWhoseScopeDoesNotFitDoesNothing() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        var changes = 0
        sides.workspace.onChange = { changes += 1 }

        sides.workspace.perform(.runAction("move-to-trash", .left)) // nothing selected
        sides.workspace.perform(.runAction("no-such-action", .left))
        #expect(changes == 0)
        sides.workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        changes = 0
        sides.workspace.perform(.runAction("rename", .left)) // needs exactly one
        sides.workspace.perform(.runAction("open", .left))
        try await sides.settle()
        #expect(changes == 0 && sides.workspace.jobs.isEmpty)
        #expect(sides.workspace.state(of: .left).renameRequest == nil)
        #expect(sides.onDisk("left") == ["a.txt", "b.txt"])
    }

    @Test func singleItemActionsHitTheSelectedItem() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/folder", withIntermediateDirectories: false)
        sides.file("left/a.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        var revealed: [[SelectedItem]] = []
        var copied: [[SelectedItem]] = []
        var previews: [Side] = []
        sides.workspace.system.reveal = { revealed.append($0) }
        sides.workspace.system.copyToPasteboard = { copied.append($0) }
        sides.workspace.system.togglePreview = { previews.append($0) }

        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.runAction("rename", .left))
        #expect(sides.workspace.state(of: .left).renameRequest?.name == "a.txt")
        sides.workspace.perform(.runAction("reveal-in-finder", .left))
        sides.workspace.perform(.runAction("copy", .left))
        sides.workspace.perform(.runAction("quick-look", .left))
        let item = [SelectedItem(path: sides.left + "/a.txt", isDirectory: false)]
        #expect(revealed == [item] && copied == [item] && previews == [.left])

        sides.workspace.perform(.select(.left, ["folder"]))
        sides.workspace.perform(.runAction("open", .left))
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).location == sides.left + "/folder")

        sides.workspace.perform(.runAction("new-folder", .left))
        try await sides.settle()
        #expect(sides.onDisk("left/folder") == ["New Folder"])
    }

    /// #16: paths or names as plain text, one per line, in list order; nothing selected, nothing copied.
    @Test func copyPathAndCopyNamePutTheSelectionAsText() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/folder", withIntermediateDirectories: false)
        sides.file("left/a b.txt")
        sides.file("left/c.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        var copied: [String] = []
        sides.workspace.system.copyText = { copied.append($0) }

        sides.workspace.perform(.copyPaths(.left))
        sides.workspace.perform(.runAction("copy-name", .left))
        #expect(copied.isEmpty)

        sides.workspace.perform(.select(.left, ["c.txt", "folder", "a b.txt"]))
        sides.workspace.perform(.runAction("copy-path", .left))
        sides.workspace.perform(.runAction("copy-name", .left))
        sides.workspace.perform(.select(.left, ["c.txt"]))
        sides.workspace.perform(.copyPaths(.left))
        sides.workspace.perform(.copyNames(.left))
        #expect(copied == [
            [sides.left + "/folder", sides.left + "/a b.txt", sides.left + "/c.txt"].joined(separator: "\n"),
            "folder\na b.txt\nc.txt",
            sides.left + "/c.txt",
            "c.txt",
        ])
        #expect(ActionRegistry.builtIn.action("copy-path")?.output == .clipboard)
        #expect(ActionRegistry.builtIn.action("copy-name")?.title == "Copy Name")
    }

    private func ids(_ actions: [Action]) -> [String] {
        actions.map(\.id)
    }
}
