import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// External tools (#18): defined in the settings file, run as actions, opened by the system.
struct ToolSettingsTests {
    @Test func theDefaultsOpenTheFolderInITermAndCodeAndFilesInTextEdit() {
        let tools = Settings().tools
        #expect(tools.map(\.id) == ["open-in-terminal", "open-in-code", "open-in-text-editor"])
        #expect(tools.map(\.app) == ["iTerm", "Visual Studio Code", "TextEdit"])
        #expect(tools.map(\.scope) == [.folder, .selectionOrFolder, .files])
        // The commented default file spells out exactly the defaults.
        #expect(Settings.parse(Settings.defaultFile) == (Settings(), []))
    }

    /// #45: a working copy opens with the terminal tool as the settings file defines it.
    @MainActor
    @Test func theTerminalToolOpensAFolder() {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in NoWatching() })
        guard case let .openWithApp(app, paths, _) = workspace.terminalCommand(for: "/repo") else {
            Issue.record("expected the app to open")
            return
        }
        #expect(app == "iTerm" && paths == ["/repo"])
        let (settings, problems) = Settings.parse("""
        [tools.open-in-terminal]
        command = ["open", "-a", "Terminal", "{folder}"]
        """)
        #expect(problems.isEmpty)
        workspace.settings = settings
        guard case let .runCommand(arguments, folder) = workspace.terminalCommand(for: "/repo") else {
            Issue.record("expected the command line to run")
            return
        }
        #expect(arguments == ["open", "-a", "Terminal", "/repo"] && folder == "/repo")
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

    @Test func aToolCanRunACommandLine() {
        let (settings, problems) = Settings.parse("""
        [tools.git-fetch]
        title = "Git Fetch"
        command = ["git", "-C", "{folder}", "fetch"]
        on = "folder"
        [tools.open-in-terminal]
        command = ["open", "-a", "Terminal", "{folder}"]
        """)
        #expect(problems.isEmpty)
        let fetch = settings.tools.first { $0.id == "git-fetch" }
        #expect(fetch?.command == ["git", "-C", "{folder}", "fetch"] && fetch?.app == "")
        let terminal = settings.tools.first { $0.id == "open-in-terminal" }
        #expect(terminal?.command.first == "open" && terminal?.app == "") // a command replaces the default app
        #expect(terminal?.title == "Open in Terminal")
    }

    @Test func aBadCommandIsReported() {
        let (settings, problems) = Settings.parse("""
        [tools.both]
        app = "TextEdit"
        command = ["vi"]
        [tools.glued]
        command = ["echo", "--files={paths}"]
        [tools.numbers]
        command = ["echo", 3]
        [tools.empty]
        command = []
        """)
        #expect(settings.tools == Settings().tools)
        #expect(problems.contains { $0.contains("tools.both") && $0.contains("not both") })
        #expect(problems.contains { $0.contains("tools.glued") && $0.contains("of its own") })
        #expect(problems.contains { $0.contains("tools.numbers") })
        #expect(problems.contains { $0.contains("tools.empty") })
    }

    @Test func placeholdersAreFilledInAsArguments() {
        let arguments = Tool.arguments(["sh", "-c", "x", "{folder}/log", "{paths}", "--in={folder}"],
                                       folder: "/a b", paths: ["/a b/1.txt", "/a b/2 x.txt"])
        #expect(arguments == ["sh", "-c", "x", "/a b/log", "/a b/1.txt", "/a b/2 x.txt", "--in=/a b"])
        #expect(Tool.arguments(["ls", "{paths}"], folder: "/f", paths: []) == ["ls"])
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

    /// A command tool runs as a job in the side's folder, and the folder is read again after.
    @Test func aCommandToolRunsAsAJobAndTheFolderIsReadAgain() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.settings.tools = [
            Tool(id: "mark", title: "Mark", app: "", scope: .folder, command: ["touch", "{folder}/marked"]),
            Tool(id: "copies", title: "Copies", app: "", scope: .files,
                 command: ["sh", "-c", "for f; do cp \"$f\" \"$f.copy\"; done", "sh", "{paths}"]),
        ]
        sides.workspace.perform(.runAction("mark", .left))
        try await sides.settle()
        #expect(sides.names(.left).contains("marked")) // read again after the job
        sides.workspace.perform(.select(.left, ["a b.txt"]))
        sides.workspace.perform(.runAction("copies", .left))
        try await sides.settle()
        #expect(sides.onDisk("left") == ["a b.txt", "a b.txt.copy", "marked"])
        #expect(sides.workspace.jobs.isEmpty) // they went fine
    }

    /// #37: Open in Code opens what is selected, or the folder when nothing is.
    @Test func openInCodeOpensTheSelectionOrTheFolder() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/sub", withIntermediateDirectories: false)
        sides.file("left/a.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        var opened: [[String]] = []
        sides.workspace.system.openWithApp = { _, paths, _ in opened.append(paths) }

        sides.workspace.perform(.runAction("open-in-code", .left))
        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.runAction("open-in-code", .left))
        sides.workspace.perform(.select(.left, ["a.txt", "sub"]))
        sides.workspace.perform(.runAction("open-in-code", .left))
        #expect(opened == [[sides.left], [sides.left + "/a.txt"], [sides.left + "/sub", sides.left + "/a.txt"]])
        #expect(Settings.parse("[tools.x]\napp = \"X\"\non = \"selection-or-folder\"\n").settings.tools.last?.scope
            == .selectionOrFolder)
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

private final class NoWatching: FolderWatching {
    func watch(_: Set<String>) {}
}
