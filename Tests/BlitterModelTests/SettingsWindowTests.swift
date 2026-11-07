import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// #64: the settings file written from settings gives exactly those settings back.
struct SettingsFileTextTests {
    /// Every section away from its default, with text that needs escaping.
    static var unusual: Settings {
        var settings = Settings()
        settings.dateFormat = "yyyy-MM-dd 'um' HH:mm \"\\\" \t"
        settings.columns = [.name, .permissions, .git]
        settings.confirmDelete = false
        settings.gitColors = false
        settings.font = FontSettings(face: "Helvetica", mono: "Menlo", size: 13.5)
        settings.tools[0].app = "Terminal"
        settings.tools.append(Tool(id: "git fetch", title: "Git \"Fetch\"", app: "", scope: .folder,
                                   command: ["git", "-C", "{folder}", "fetch"]))
        settings.tools.append(Tool(id: "hex", title: "Hex", app: "Hex Fiend", scope: .files,
                                   extensions: ["bin", "tar.gz"]))
        settings.contextMenus.items = [
            .action("open"), .separator, .submenu("More", [.action("hex"), .separator, .action("copy-path")]),
            .action("git fetch"),
        ]
        settings.contextMenus.folder = []
        settings.menuBar.file = [
            .action("rename", shortcut: Shortcut(.function(2)), alternate: false), .separator,
            .action("hex", shortcut: Shortcut(.character("+"), [.control, .command]), alternate: false),
            .action("copy-path", shortcut: nil, alternate: false),
            .action("copy-name", shortcut: Shortcut(.forwardDelete, [.shift, .option]), alternate: true),
        ]
        settings.menuBar.edit = []
        settings.diffTool = ["bcomp", "-title={left}", "{right}"]
        settings.theme.light = "solarized-light"
        settings.theme.dark = "mine"
        settings.theme.slots[.folder] = 0x17
        let colors = (0 ..< 16).map { String(format: "#%02x%02x%02x", $0 * 16, 255 - $0, $0) }
        settings.theme.schemes["mine"] = Base24Scheme(colors)
        return settings
    }

    @Test func theDefaultFileIsTheDefaults() {
        let (settings, problems) = Settings.parse(Settings.defaultFile)
        #expect(settings == Settings() && problems.isEmpty)
        #expect(Settings.defaultFile
            .contains(
                "# Its app also opens this file (Open Settings File, in Settings…).\n[tools.open-in-text-editor]"
            ))
    }

    @Test func everyEntryComesBack() {
        let settings = Self.unusual
        let (read, problems) = Settings.parse(Settings.fileText(settings))
        #expect(problems.isEmpty)
        #expect(read == settings)
        #expect(Settings.fileText(read) == Settings.fileText(settings)) // and it stays the same text
    }

    @Test func shortcutsAreWrittenAsTheyAreRead() {
        for text in ["shift+cmd+n", "f2", "opt+cmd+backspace", "ctrl+plus", "ctrl+shift+opt+cmd+pagedown", ","] {
            let shortcut = Shortcut(text)
            #expect(shortcut?.text == text, "\(text)")
        }
    }

    /// The window's draft is checked by writing it: what the file cannot hold is a problem.
    @Test func whatTheFileCannotHoldIsAProblem() {
        var settings = Settings()
        #expect(settings.problems.isEmpty)
        settings.dateFormat = ""
        settings.diffTool = ["bcomp", "{left}"]
        settings.theme.dark = "no such scheme, not a path"
        #expect(settings.problems.count == 3)
    }

    /// Only what the window changed is taken; what changed in the file meanwhile stays.
    @Test func changesAreAppliedEntryByEntry() {
        let original = Settings()
        var edited = original
        edited.font.face = "Helvetica"
        edited.confirmDelete = false
        var current = Settings()
        current.font.size = 15 // zoomed meanwhile
        current.dateFormat = "HH:mm" // an editor meanwhile
        let merged = current.applying(changesFrom: original, to: edited)
        #expect(merged.font == FontSettings(face: "Helvetica", size: 15))
        #expect(merged.dateFormat == "HH:mm" && !merged.confirmDelete)
    }

    /// Each role, each scheme and each column is a setting of its own: one changed in the window
    /// does not undo another changed in the file meanwhile.
    @Test func rolesSchemesAndColumnsMergeOneByOne() {
        let original = Settings()
        var edited = original
        edited.theme.slots[.folder] = 0x9
        edited.columns.insert(.kind)
        var current = Settings()
        current.theme.slots[.background] = 0x1
        current.columns.insert(.permissions)
        current.columns.remove(.size)
        let merged = current.applying(changesFrom: original, to: edited)
        #expect(merged.theme.slots[.folder] == 0x9 && merged.theme.slots[.background] == 0x1)
        #expect(merged.columns == [.name, .modified, .kind, .permissions])
    }
}

/// #64: saving from the Settings window into the file.
@MainActor
@Suite(.serialized)
struct SettingsWindowSaveTests {
    private func makeWorkspace(settingsFile: String) async -> Workspace {
        let workspace = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                                  settingsFile: settingsFile)
        workspace.fontSizeSaveDelay = .seconds(60)
        await workspace.settle()
        return workspace
    }

    @Test func aSaveWritesTheWholeFileAndTheSettingsApplyAtOnce() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "# mine\n[files]\ndate_format = \"HH:mm\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let document = await workspace.readSettingsDocument()
        #expect(document.canBeSaved && document.problems.isEmpty && document.settings.dateFormat == "HH:mm")
        var edited = document.settings
        edited.gitColors = false
        workspace.perform(.saveSettings(original: document.settings, edited: edited))
        await workspace.settle()
        var expected = Settings()
        expected.dateFormat = "HH:mm"
        expected.gitColors = false
        #expect(try String(contentsOfFile: path, encoding: .utf8) == Settings.fileText(expected))
        #expect(workspace.settings.gitColors == false)
        #expect(workspace.notices.isEmpty)
    }

    /// A zoom waiting to be saved, and an editor's change made while the window was open: both stay.
    @Test func changesMadeElsewhereMeanwhileStay() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[files]\ndate_format = \"HH:mm\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let document = await workspace.readSettingsDocument()
        try "[files]\ndate_format = \"d.M.\"\n".write(toFile: path, atomically: true, encoding: .utf8) // an editor
        workspace.perform(.zoomFont(.larger)) // its save waits 60 s
        var edited = document.settings
        edited.font.face = "Helvetica"
        workspace.perform(.saveSettings(original: document.settings, edited: edited))
        await workspace.settle()
        let saved = try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings
        #expect(saved.dateFormat == "d.M." && saved.font == FontSettings(face: "Helvetica", size: 12))
        #expect(workspace.notices.isEmpty)
    }

    @Test func noFileYetIsCreated() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/blitter/settings.toml"
        let workspace = await makeWorkspace(settingsFile: path)
        let document = await workspace.readSettingsDocument()
        #expect(document.canBeSaved && document.settings == Settings())
        var edited = document.settings
        edited.confirmDelete = false
        workspace.perform(.saveSettings(original: document.settings, edited: edited))
        await workspace.settle()
        #expect(try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings == edited)
        #expect((workspace.watcher as? FakeWatcher)?.watched.contains(folder.path + "/blitter") == true)
    }

    /// A file that does not parse as a whole is never rewritten: everything in it would be lost.
    @Test func aFileThatDoesNotParseIsNotWritten() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        let broken = "[files]\ndate_format = \"HH:mm\n[font]\nsize = 14\n"
        try broken.write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let document = await workspace.readSettingsDocument()
        #expect(!document.canBeSaved && !document.problems.isEmpty)
        var edited = document.settings
        edited.confirmDelete = false
        workspace.perform(.saveSettings(original: document.settings, edited: edited))
        await workspace.settle()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == broken)
        #expect(workspace.notices.contains { $0.text.hasPrefix("The settings could not be saved") })
    }

    /// An entry with a problem keeps its default in the window; saving writes the default.
    @Test func entriesWithProblemsAreListed() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[files]\nconfirm_delete = \"no\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let document = await workspace.readSettingsDocument()
        #expect(document.canBeSaved && document.problems.count == 1)
        #expect(document.settings.confirmDelete)
    }

    /// A role changed in the window and another in an editor meanwhile: both are in the file.
    @Test func aRoleChangedHereAndAnotherInAnEditorBothStay() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        let workspace = await makeWorkspace(settingsFile: path)
        let document = await workspace.readSettingsDocument()
        try "[theme.roles]\nbackground = \"base01\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        var edited = document.settings
        edited.theme.slots[.folder] = 0x9
        workspace.perform(.saveSettings(original: document.settings, edited: edited))
        await workspace.settle()
        let saved = try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings
        #expect(saved.theme.slots[.background] == 0x1 && saved.theme.slots[.folder] == 0x9)
    }

    /// Three saves, the third made after the first has finished: they run in order, the last
    /// one's value wins, and none overlaps another.
    @Test func savesRunOneAfterTheOtherInOrder() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[files]\ndate_format = \"0\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let running = Mutex((now: 0, most: 0))
        workspace.settingsFileBeforeReplace = {
            running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            Thread.sleep(forTimeInterval: 0.15)
            running.withLock { $0.now -= 1 }
        }
        func save(_ before: String, _ after: String) {
            var original = Settings()
            original.dateFormat = before
            var edited = original
            edited.dateFormat = after
            workspace.perform(.saveSettings(original: original, edited: edited))
        }
        save("0", "A")
        save("A", "B") // queued behind A
        for _ in 0 ..< 300 where (try? String(contentsOfFile: path, encoding: .utf8))?.contains("\"A\"") != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        save("B", "C") // A is done, B is still running or waiting
        let problem = await workspace.finishSavingSettings()
        await workspace.settle()
        #expect(problem == nil)
        #expect(try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings.dateFormat == "C")
        #expect(running.withLock { $0.most } == 1)
        #expect(workspace.notices.isEmpty)
    }

    @Test func nothingChangedWritesNothing() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "# mine\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let document = await workspace.readSettingsDocument()
        workspace.perform(.saveSettings(original: document.settings, edited: document.settings))
        await workspace.settle()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# mine\n")
    }
}
