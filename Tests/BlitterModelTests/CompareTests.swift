import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// Compare Files and Compare Folders (#40): what is compared, with which tool, and failures.
@MainActor
@Suite(.serialized)
struct CompareTests {
    private final class Launches: Sendable {
        let calls = Mutex<[[String]]>([])
        let environments = Mutex<[[String: String]]>([])
    }

    private func sides(tool: DiffTool? = DiffTool(["found", "{left}", "{right}"]),
                       failing: Bool = false) async throws -> (SidesOnDisk, Launches)
    {
        let sides = try SidesOnDisk()
        for name in ["left/a.txt", "left/b.txt", "right/c.txt"] {
            sides.file(name)
        }
        try FileManager.default.createDirectory(atPath: sides.left + "/sub", withIntermediateDirectories: false)
        let launches = Launches()
        sides.workspace.findDiffTool = { tool }
        sides.workspace.launchTool = { arguments, environment in
            if failing {
                throw Launcher.Failure.notFound(arguments[0])
            }
            launches.calls.withLock { $0.append(arguments) }
            launches.environments.withLock { $0.append(environment) }
        }
        sides.workspace.perform(.refresh(.left))
        sides.workspace.perform(.refresh(.right))
        try await sides.settle()
        return (sides, launches)
    }

    private func settle(_ workspace: Workspace) async {
        for _ in 0 ..< 100 where workspace.compareWork != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func compareFilesTakesTwoHereOrOneOnEachSideTheLeftOneFirst() async throws {
        let (sides, launches) = try await sides()
        let workspace = sides.workspace
        #expect(!workspace.canRun("compare-files", on: .left)) // nothing selected

        workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        #expect(workspace.canRun("compare-files", on: .left))
        workspace.perform(.runAction("compare-files", .left))
        await settle(workspace)

        workspace.perform(.select(.left, ["a.txt", "sub"])) // a folder among them: no
        #expect(!workspace.canRun("compare-files", on: .left))
        workspace.perform(.select(.left, ["a.txt", "b.txt", "sub"]))
        #expect(!workspace.canRun("compare-files", on: .left))

        workspace.perform(.select(.left, ["b.txt"]))
        #expect(!workspace.canRun("compare-files", on: .left)) // one, and nothing on the other side
        workspace.perform(.select(.right, ["c.txt"]))
        #expect(workspace.canRun("compare-files", on: .left) && workspace.canRun("compare-files", on: .right))
        workspace.perform(.runAction("compare-files", .right)) // from the right: the left one still first
        await settle(workspace)

        #expect(launches.calls.withLock { $0 } == [
            ["found", sides.left + "/a.txt", sides.left + "/b.txt"],
            ["found", sides.left + "/b.txt", sides.right + "/c.txt"],
        ])
        #expect(workspace.notices.isEmpty)
    }

    @Test func compareFoldersTakesTheLeftAndRightFolders() async throws {
        let (sides, launches) = try await sides(tool: DiffTool(["opendiff", "{left}", "{right}"],
                                                               environment: [
                                                                   "DEVELOPER_DIR": "/X.app/Contents/Developer",
                                                               ]))
        #expect(sides.workspace.canRun("compare-folders", on: .right))
        sides.workspace.perform(.runAction("compare-folders", .right))
        await settle(sides.workspace)
        #expect(launches.calls.withLock { $0 } == [["opendiff", sides.left, sides.right]])
        #expect(launches.environments.withLock { $0 } == [["DEVELOPER_DIR": "/X.app/Contents/Developer"]])
    }

    /// #40 review: while the other side is still reading the folder it went to, it still lists
    /// the one it left: Compare Folders waits instead of comparing with that one.
    @Test func compareFoldersNeverTakesAFolderTheOtherSideIsLeaving() async throws {
        let sides = try SidesOnDisk(lister: { path in
            if path.hasSuffix("/slow") {
                try await Task.sleep(for: .milliseconds(300))
            }
            return try await listDirectory(path)
        })
        try FileManager.default.createDirectory(atPath: sides.right + "/slow", withIntermediateDirectories: false)
        let launches = Launches()
        sides.workspace.findDiffTool = { DiffTool(["found", "{left}", "{right}"]) }
        sides.workspace.launchTool = { arguments, _ in launches.calls.withLock { $0.append(arguments) } }
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.canRun("compare-folders", on: .left))

        sides.workspace.perform(.navigate(.right, path: sides.right + "/slow"))
        #expect(sides.workspace.state(of: .right).entriesLocation == sides.right) // still the old rows
        #expect(!sides.workspace.canRun("compare-folders", on: .left))
        sides.workspace.perform(.runAction("compare-folders", .left))
        await settle(sides.workspace)
        #expect(launches.calls.withLock { $0 }.isEmpty)

        try await sides.settle()
        sides.workspace.perform(.runAction("compare-folders", .left))
        await settle(sides.workspace)
        #expect(launches.calls.withLock { $0 } == [["found", sides.left, sides.right + "/slow"]])
    }

    @Test func theSettingsToolWinsAndProblemsBecomeNotices() async throws {
        let (sides, launches) = try await sides(tool: nil)
        let workspace = sides.workspace
        workspace.perform(.runAction("compare-folders", .left)) // none installed, none configured
        await settle(workspace)
        #expect(launches.calls.withLock { $0 }.isEmpty)
        #expect(workspace.notices.first?.text.hasPrefix("Compare: no diff tool was found.") == true)

        workspace.settings.diffTool = ["ksdiff", "--partial-changeset", "{left}", "{right}"]
        workspace.perform(.runAction("compare-folders", .left))
        await settle(workspace)
        #expect(launches.calls.withLock { $0 } == [["ksdiff", "--partial-changeset", sides.left, sides.right]])

        let (failing, _) = try await self.sides(failing: true)
        failing.workspace.perform(.runAction("compare-folders", .left))
        await settle(failing.workspace)
        #expect(failing.workspace.notices.map(\.text)
            == ["Compare: the diff tool could not be started: “found” was not found."])
    }

    @Test func theToolIsASetting() {
        let (bcomp, problems) = Settings.parse("[diff]\ntool = [\"bcomp\", \"{left}\", \"{right}\"]\n")
        #expect(problems.isEmpty && bcomp.diffTool == ["bcomp", "{left}", "{right}"])
        #expect(Settings.parse("[diff]\ntool = \"auto\"\n").settings.diffTool == nil)
        for bad in [
            "\"bcomp\"",
            "[\"bcomp\", \"{left}\"]",
            "[\"\", \"{left}\", \"{right}\"]",
            "[\"x\", 1, \"{left}\"]",
        ] {
            let (settings, problems) = Settings.parse("[diff]\ntool = \(bad)\n")
            #expect(settings.diffTool == nil && problems.count == 1, "\(bad)")
        }
        #expect(Settings.parse(Settings.defaultFile) == (Settings(), []))
    }
}
