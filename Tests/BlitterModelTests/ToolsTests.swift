@testable import BlitterModel
import Foundation
import Testing

/// External tools (#18): defined in the settings file, run as actions, opened by the system.
struct ToolSettingsTests {
    @Test func theDefaultsOpenTheFolderInITermAndCodeAndFilesInTextEdit() {
        let tools = Settings().tools
        #expect(tools.map(\.id) == ["open-in-terminal", "open-in-code", "open-in-text-editor"])
        #expect(tools.map(\.app) == ["iTerm", "Visual Studio Code", "TextEdit"])
        #expect(tools.map(\.scope) == [.folder, .folder, .files])
        // The commented default file spells out exactly the defaults.
        #expect(Settings.parse(Settings.defaultFile) == (Settings(), []))
    }

    @Test func aDefaultChangesOnlyWhatIsGivenAndANewToolIsAdded() {
        let (settings, problems) = Settings.parse("""
        [tools.open-in-terminal]
        app = "Terminal"
        [tools.preview]
        title = "Open in Preview"
        app = "com.apple.Preview"
        on = "files"
        """)
        #expect(problems.isEmpty)
        #expect(settings.tools.map(\.id) == ["open-in-terminal", "open-in-code", "open-in-text-editor", "preview"])
        #expect(settings.tools[0] == Tool(id: "open-in-terminal", title: "Open in Terminal", app: "Terminal",
                                          scope: .folder))
        #expect(settings.tools[3] == Tool(id: "preview", title: "Open in Preview", app: "com.apple.Preview",
                                          scope: .files))
    }

    @Test func aToolWithAProblemIsReportedAndKeepsItsPreviousDefinition() {
        let (settings, problems) = Settings.parse("""
        [tools.open-in-code]
        app = "Cursor"
        on = "everywhere"
        [tools.no-app]
        title = "Nothing to open with"
        [tools.copy]
        app = "TextEdit"
        [tools.extra]
        app = "TextEdit"
        colour = "red"
        """)
        #expect(settings.tools == Settings().tools) // none of them applied
        #expect(problems.count == 4)
        #expect(problems.contains { $0.contains("tools.open-in-code.on") })
        #expect(problems.contains { $0.contains("tools.no-app") && $0.contains("needs an app") })
        #expect(problems.contains { $0.contains("tools.copy") && $0.contains("built-in") })
        #expect(problems.contains { $0.contains("tools.extra.colour") })
    }

    @Test func toolsMustBeSections() {
        let (settings, problems) = Settings.parse("tools = 3\n[tools2]\n")
        #expect(settings.tools == Settings().tools)
        #expect(problems.count == 2)
        let (inner, innerProblems) = Settings.parse("[tools]\nterminal = \"iTerm\"\n")
        #expect(inner.tools == Settings().tools)
        #expect(innerProblems.count == 1 && innerProblems[0].contains("tools.terminal"))
    }
}

@MainActor
@Suite(.serialized)
struct ToolActionsTests {
    @Test func toolsAreOfferedByScopeAndOpenTheFolderOrTheFiles() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/folder", withIntermediateDirectories: false)
        sides.file("left/a.txt")
        sides.file("left/b.md")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        var opened: [(String, [String])] = []
        sides.workspace.system.openWithApp = { app, paths, _ in opened.append((app, paths)) }

        let offered = sides.workspace.actions(for: .left).map(\.id)
        #expect(offered.contains("open-in-terminal") && offered.contains("open-in-code"))
        #expect(!offered.contains("open-in-text-editor")) // no files selected

        sides.workspace.perform(.select(.left, ["a.txt", "folder"]))
        #expect(!sides.workspace.canRun("open-in-text-editor", on: .left)) // a folder is selected
        sides.workspace.perform(.select(.left, ["b.md", "a.txt"]))
        #expect(sides.workspace.canRun("open-in-text-editor", on: .left))

        sides.workspace.perform(.runAction("open-in-text-editor", .left))
        sides.workspace.perform(.runAction("open-in-terminal", .left))
        #expect(opened.map(\.0) == ["TextEdit", "iTerm"])
        #expect(opened.map(\.1) == [[sides.left + "/a.txt", sides.left + "/b.md"], [sides.left]])
    }

    @Test func aFailureBecomesANoticeNamingTheTool() async throws {
        let sides = try SidesOnDisk()
        try await sides.settle()
        sides.workspace.system.openWithApp = { _, _, failed in failed("the app “iTerm” was not found.") }
        var changes = 0
        sides.workspace.onChange = { changes += 1 }
        sides.workspace.perform(.runAction("open-in-terminal", .left))
        #expect(sides.workspace.notices.map(\.text) == ["Open in Terminal: the app “iTerm” was not found."])
        #expect(changes == 1)
    }

    @Test func changedToolsReplaceTheActions() async throws {
        let sides = try SidesOnDisk()
        try await sides.settle()
        sides.workspace.settings.tools = [Tool(id: "fork", title: "Open in Fork", app: "Fork", scope: .folder)]
        #expect(sides.workspace.actionRegistry.action("fork")?.title == "Open in Fork")
        #expect(sides.workspace.actionRegistry.action("open-in-terminal") == nil)
        #expect(sides.workspace.actionRegistry.action("move-to-trash") != nil) // built-ins stay
        var opened: [String] = []
        sides.workspace.system.openWithApp = { app, _, _ in opened.append(app) }
        sides.workspace.perform(.runAction("fork", .left))
        #expect(opened == ["Fork"])
    }
}
