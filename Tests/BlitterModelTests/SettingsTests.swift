import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

struct SettingsParsingTests {
    @Test func theDefaultFileGivesTheDefaultsWithoutProblems() {
        let (settings, problems) = Settings.parse(Settings.defaultFile)
        #expect(settings == Settings())
        #expect(problems.isEmpty)
    }

    @Test func anEmptyFileMeansAllDefaults() {
        #expect(Settings.parse("") == (Settings(), []))
    }

    @Test func knownEntriesAreApplied() {
        let (settings, problems) = Settings.parse("[files]\ndate_format = \"yyyy-MM-dd\"\n")
        #expect(settings.dateFormat == "yyyy-MM-dd")
        #expect(problems.isEmpty)
    }

    @Test func deleteConfirmationCanBeTurnedOff() {
        #expect(Settings().confirmDelete)
        let (off, problems) = Settings.parse("[files]\nconfirm_delete = false\n")
        #expect(!off.confirmDelete && problems.isEmpty)
        // Anything but a boolean keeps the safe default.
        for value in ["\"no\"", "0", "1"] {
            let (settings, problems) = Settings.parse("[files]\nconfirm_delete = \(value)\n")
            #expect(settings.confirmDelete, "\(value)")
            #expect(problems.count == 1 && problems[0].contains("files.confirm_delete"), "\(value)")
        }
    }

    @Test func unknownEntriesAndWrongTypesAreReportedAndTheRestApplies() {
        let text = """
        [files]
        date_format = 42
        colour = "red"
        [nonsense]
        x = 1
        """
        let (settings, problems) = Settings.parse(text)
        #expect(settings.dateFormat == Settings().dateFormat)
        #expect(problems.count == 3)
        #expect(problems.contains { $0.contains("files.date_format") })
        #expect(problems.contains { $0.contains("files.colour") })
        #expect(problems.contains { $0.contains("nonsense") })
    }

    /// TOMLKit's own iterator crashes on keys with an escaped NUL; the parser must not.
    @Test func keysWithANulAreReportedNotFatal() {
        let entry = Settings.parse("[files]\n\"bad\\u0000key\" = 1\ndate_format = \"HH:mm\"\n")
        #expect(entry.settings.dateFormat == "HH:mm") // the rest still applies
        #expect(entry.problems.count == 1 && entry.problems[0].contains("“files.bad”"))

        let section = Settings.parse("[\"bad\\u0000section\"]\nx = 1\n")
        #expect(section.settings == Settings())
        #expect(section.problems.count == 1 && section.problems[0].contains("“bad”"))

        // Cut short, the key would read as a known one; it must not be applied as that.
        let lookalike = Settings.parse("[files]\n\"date_format\\u0000x\" = \"HH:mm\"\n")
        #expect(lookalike.settings == Settings())
        #expect(lookalike.problems.count == 1)

        // Cut short, it collides with a real key: the real one applies, the bad one is reported.
        let collision = Settings.parse("[files]\ndate_format = \"HH:mm\"\n\"date_format\\u0000x\" = \"yyyy\"\n")
        #expect(collision.settings.dateFormat == "HH:mm")
        #expect(collision.problems.count == 1 && collision.problems[0].contains("“files.date_format”"))

        // The same at section level: a real [files] and a "files\u0000x" section.
        let sections = Settings.parse("[files]\ndate_format = \"HH:mm\"\n[\"files\\u0000x\"]\ndate_format = \"yyyy\"\n")
        #expect(sections.settings.dateFormat == "HH:mm")
        #expect(sections.problems.count == 1 && sections.problems[0].contains("“files”"))
    }

    /// Types are TOML's, not a conversion's: a date is no date pattern.
    @Test func aTOMLDateIsNotAString() {
        let (settings, problems) = Settings.parse("[files]\ndate_format = 2026-11-01\n")
        #expect(settings == Settings())
        #expect(problems.count == 1 && problems[0].contains("files.date_format"))
    }

    /// A value JSON can't hold (infinity) is just another unknown entry; the rest applies.
    @Test func nonFiniteNumbersDontSinkTheFile() {
        let (settings, problems) = Settings.parse("[files]\ndate_format = \"HH:mm\"\nunknown = inf\nother = nan\n")
        #expect(settings.dateFormat == "HH:mm")
        #expect(problems.count == 2)
    }

    @Test func aSyntaxErrorNamesTheLineAndKeepsTheDefaults() {
        let (settings, problems) = Settings.parse("[files]\ndate_format = \"unterminated\n")
        #expect(settings == Settings())
        #expect(problems.count == 1 && problems[0].hasPrefix("Line 2"))
    }
}

/// The settings file as the workspace uses it: read at launch, re-read on changes, problems as
/// a notice, created on demand.
@MainActor
@Suite(.serialized)
struct SettingsFileTests {
    private func makeWorkspace(settingsFile: String) async -> Workspace {
        let workspace = Workspace(
            initialLocation: "/",
            home: "/home",
            lister: { _ in [] },
            directoryCheck: { _ in false },
            volumes: { [] },
            watcher: FakeWatcher.factory,
            settingsFile: settingsFile
        )
        await workspace.settle()
        return workspace
    }

    @Test func theFileIsReadAtLaunchAndItsFolderWatched() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[files]\ndate_format = \"HH:mm\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        #expect(workspace.settings.dateFormat == "HH:mm")
        #expect(workspace.notices.isEmpty)
        #expect((workspace.watcher as? FakeWatcher)?.watched.contains(folder.path) == true)
    }

    @Test func noFileMeansDefaultsAndNoNotice() async throws {
        let folder = try TemporaryFolder()
        let workspace = await makeWorkspace(settingsFile: folder.path + "/settings.toml")
        #expect(workspace.settings == Settings())
        #expect(workspace.notices.isEmpty)
    }

    @Test func aChangeIsPickedUpAndProblemsComeAndGoAsOneNotice() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        let workspace = await makeWorkspace(settingsFile: path)
        let changed = [FolderChange(path: folder.path, includesSubfolders: false)]

        try "[files]\ndate_format = 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        workspace.foldersChanged(changed)
        await workspace.settle()
        #expect(workspace.notices.count == 1)
        #expect(workspace.notices[0].text.contains("files.date_format"))

        try "[files]\ndate_format = 2\nx = 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        workspace.foldersChanged(changed)
        await workspace.settle()
        #expect(workspace.notices.count == 1) // replaced, not added

        try "[files]\ndate_format = \"d.M.yy\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        workspace.foldersChanged(changed)
        await workspace.settle()
        #expect(workspace.notices.isEmpty)
        #expect(workspace.settings.dateFormat == "d.M.yy")
    }

    /// Bytes that are not UTF-8 are a problem to report, not an empty file.
    @Test func aFileThatIsNotUTF8GivesTheDefaultsAndANotice() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[files]\ndate_format = \"HH:mm\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        #expect(workspace.settings.dateFormat == "HH:mm")

        try Data([0x5B, 0x66, 0xFF, 0xFE, 0x5D]).write(to: URL(fileURLWithPath: path)) // "[f", invalid, "]"
        workspace.foldersChanged([FolderChange(path: folder.path, includesSubfolders: false)])
        await workspace.settle()
        #expect(workspace.settings == Settings())
        #expect(workspace.notices.count == 1)
        #expect(workspace.notices.first?.text.contains("could not be read") == true)
    }

    @Test func aNoticeCanBeDismissed() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "nonsense = 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let notice = try #require(workspace.notices.first)
        workspace.perform(.dismissNotice(notice.id))
        #expect(workspace.notices.isEmpty)
    }

    @Test func openingTheSettingsFileCreatesItWithTheDefaultsOnce() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/config/blitter/settings.toml"
        let workspace = await makeWorkspace(settingsFile: path)
        var edited: [String] = []
        workspace.system.openWithApp = { app, paths, _ in
            #expect(app == "TextEdit") // the text editor tool's app (#36)
            edited += paths
        }
        workspace.system.editText = { _ in Issue.record("the default app is only the fallback") }

        workspace.perform(.openSettingsFile)
        for _ in 0 ..< 200 where edited.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(edited == [path])
        #expect(try String(contentsOfFile: path, encoding: .utf8) == Settings.defaultFile)
        // The folder exists only now: the watcher is handed the same set again, to try it (#29).
        let watcher = try #require(workspace.watcher as? FakeWatcher)
        #expect(watcher.watched.contains(folder.path + "/config/blitter"))
        let callsBefore = watcher.watchCalls

        try "[files]\ndate_format = \"mine\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        workspace.perform(.openSettingsFile)
        for _ in 0 ..< 200 where edited.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        await workspace.settle()
        #expect(watcher.watchCalls > callsBefore)
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("mine")) // not overwritten
        #expect(workspace.settings.dateFormat == "mine")
    }

    /// #36: if the text editor tool's app cannot be found, the file still opens (default app),
    /// and a notice says why.
    @Test func theSettingsFileOpensEvenIfTheEditorAppIsMissing() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[tools.open-in-text-editor]\napp = \"NoSuchEditor\"\n".write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
        let workspace = await makeWorkspace(settingsFile: path)
        var tried: [String] = []
        var edited: [String] = []
        workspace.system.openWithApp = { app, _, failed in
            tried.append(app)
            failed("the app “\(app)” was not found.")
        }
        workspace.system.editText = { edited.append($0) }
        workspace.perform(.openSettingsFile)
        for _ in 0 ..< 200 where edited.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(tried == ["NoSuchEditor"])
        #expect(edited == [path])
        #expect(workspace.notices.map(\.text)
            == ["Settings…: the app “NoSuchEditor” was not found. It opens with the default app instead."])
    }

    /// #36: a text editor tool that runs a command has no app to open the file with.
    @Test func aCommandTextEditorLeavesTheSettingsFileToItsDefaultApp() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[tools.open-in-text-editor]\ncommand = [\"vim\", \"{paths}\"]\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        var edited: [String] = []
        workspace.system.openWithApp = { _, _, _ in Issue.record("a command tool has no app") }
        workspace.system.editText = { edited.append($0) }
        workspace.perform(.openSettingsFile)
        for _ in 0 ..< 200 where edited.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(edited == [path])
        #expect(workspace.notices.isEmpty)
    }
}
