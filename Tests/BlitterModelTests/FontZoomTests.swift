import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// #63: changing `[font] size` in the settings file's text, and only that.
struct FontSizeEditTests {
    @Test func theSizeLineChangesAndItsCommentStays() throws {
        let text = "# mine\n[font]\nface = \"system\"\nsize   =  11   # my size\n\n[files]\nconfirm_delete = false\n"
        let edited = try #require(Settings.settingFontSize(14, in: text))
        #expect(edited == text.replacingOccurrences(of: "=  11   #", with: "=  14   #"))
    }

    @Test func theDefaultFileChangesInOneLine() throws {
        let edited = try #require(Settings.settingFontSize(13.5, in: Settings.defaultFile))
        let before = Settings.defaultFile.components(separatedBy: "\n")
        let after = edited.components(separatedBy: "\n")
        #expect(before.count == after.count)
        #expect(zip(before, after).filter { $0 != $1 }.map(\.1) == ["size = 13.5"])
        #expect(Settings.parse(edited).settings.font.size == 13.5)
    }

    @Test func aMissingSizeGoesBelowTheHeaderAndAMissingTableAtTheEnd() {
        #expect(Settings.settingFontSize(12, in: "[font]\nface = \"system\"\n[files]\n")
            == "[font]\nsize = 12\nface = \"system\"\n[files]\n")
        #expect(Settings.settingFontSize(12, in: "[files]\nconfirm_delete = false")
            == "[files]\nconfirm_delete = false\n\n[font]\nsize = 12\n")
        #expect(Settings.settingFontSize(12, in: "") == "[font]\nsize = 12\n")
    }

    /// Only `[font]`'s own size: not one in another table, not past the next table's header.
    @Test func otherTablesAreLeftAlone() {
        let text = "[theme.schemes.mine]\nsize = 3\n[font]\nmono = \"system\"\n[[x]]\nsize = 1\n"
        // [[x]] is not valid in a Blitter file, but it must still end [font].
        #expect(Settings.setting("size", to: "12", inSection: "font", of: text)
            == "[theme.schemes.mine]\nsize = 3\n[font]\nsize = 12\nmono = \"system\"\n[[x]]\nsize = 1\n")
    }

    /// A size set some other way, or a file that does not parse: no edit at all.
    @Test func whatALineEditCannotChangeIsRefused() {
        #expect(Settings.settingFontSize(12, in: "font = { size = 11 }\n") == nil)
        #expect(Settings.settingFontSize(12, in: "font.size = 11\n") == nil)
        #expect(Settings.settingFontSize(12, in: "[font]\nsize = 11\n[files\n") == nil)
    }

    /// The edit replaces an invalid size; other problems in the file stay what they were.
    @Test func anInvalidSizeIsReplacedAndOtherProblemsStay() throws {
        let text = "[font]\nsize = 99\n[files]\nunknown = 1\n"
        let edited = try #require(Settings.settingFontSize(12, in: text))
        #expect(edited == "[font]\nsize = 12\n[files]\nunknown = 1\n")
    }
}

/// #63: zooming the font through the workspace, and saving the size into the file.
@MainActor
@Suite(.serialized)
struct FontZoomTests {
    private func makeWorkspace(settingsFile: String? = nil) async -> Workspace {
        let workspace = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                                  settingsFile: settingsFile)
        workspace.fontSizeSaveDelay = .zero
        await workspace.settle()
        return workspace
    }

    @Test func stepsArePointsWithinTheLimitsAndActualSizeIsTheDefault() async {
        let workspace = await makeWorkspace()
        workspace.perform(.zoomFont(.larger))
        #expect(workspace.settings.font.size == 12)
        workspace.settings.font.size = 13.5
        workspace.perform(.zoomFont(.smaller))
        #expect(workspace.settings.font.size == 13) // to whole points
        workspace.perform(.zoomFont(.actualSize))
        #expect(workspace.settings.font.size == FontSettings().size)
        for _ in 0 ..< 40 {
            workspace.perform(.zoomFont(.smaller))
        }
        #expect(workspace.settings.font.size == FontSettings.sizes.lowerBound)
        var changes = 0
        workspace.onChange = { changes += 1 }
        workspace.perform(.zoomFont(.smaller))
        #expect(changes == 0) // at the limit: nothing changes, nobody is told
    }

    @Test func theSizeIsSavedInTheFileAndNothingElseChanges() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        let text = "# my comment\n[files]\nconfirm_delete = false   # keep\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        workspace.fontSizeSaveDelay = .milliseconds(50)
        for _ in 0 ..< 3 {
            workspace.perform(.zoomFont(.larger))
        }
        #expect(workspace.settings.font.size == 14)
        await workspace.settle()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text + "\n[font]\nsize = 14\n")
        #expect(workspace.pendingFontSize == nil)
        #expect(workspace.notices.isEmpty)
    }

    /// No file yet: it is created with the commented defaults, and the size set in it.
    @Test func withoutAFileTheDefaultFileIsCreated() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        let workspace = await makeWorkspace(settingsFile: path)
        workspace.perform(.zoomFont(.smaller))
        await workspace.settle()
        let saved = try String(contentsOfFile: path, encoding: .utf8)
        #expect(saved == Settings.defaultFile.replacingOccurrences(of: "size = 11\n", with: "size = 10\n"))
    }

    /// The file read again before the save (another edit): the zoomed size stays.
    @Test func aReloadBeforeTheSaveKeepsTheZoomedSize() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        workspace.fontSizeSaveDelay = .seconds(60)
        workspace.perform(.zoomFont(.larger))
        workspace.loadSettings()
        await workspace.settingsWork?.value
        #expect(workspace.settings.font.size == 12)
        workspace.fontSizeSave?.cancel() // ends the long wait; the save then runs
        await workspace.settle()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "[font]\nsize = 12\n")
    }

    @Test func aSizeSetSomeOtherWayIsLeftAloneWithANotice() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        let text = "font = { size = 11 }\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        workspace.perform(.zoomFont(.larger))
        await workspace.settle()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
        #expect(workspace.notices.count == 1)
        #expect(workspace.notices.first?.text.contains("font size could not be saved") == true)
    }
}

/// #63 review: the edit must provably touch `font.size` alone; saves survive editors and quitting.
@MainActor
@Suite(.serialized)
struct FontSizeSaveSafetyTests {
    private func makeWorkspace(settingsFile: String) async -> Workspace {
        let workspace = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                                  settingsFile: settingsFile)
        workspace.fontSizeSaveDelay = .zero
        await workspace.settle()
        return workspace
    }

    /// A `[font]` line inside a multi-line string is text, not a table: both parse to the same
    /// settings, so only the documents' values tell them apart.
    @Test func linesInsideAMultiLineStringAreNeverEdited() {
        for quote in ["'''", "\"\"\""] {
            let text = "notes = \(quote)\n[font]\nsize = 99\n\(quote)\n"
            #expect(Settings.settingFontSize(11, in: text) == nil, "\(quote)")
            #expect(Settings.settingFontSize(12, in: text) == nil, "\(quote)")
        }
    }

    /// A file that does not parse is never edited, even to the default size its parse gives.
    @Test func aFileThatDoesNotParseIsNeverEdited() {
        #expect(Settings.settingFontSize(11, in: "[font]\nsize = 11\n[files\n") == nil)
        #expect(Settings.settingFontSize(11, in: "[font]\nsize = = 3\n") == nil)
    }

    /// An editor saves between Blitter's read and its write: the editor's text stays, and the
    /// size is set in it.
    @Test func anEditorsSaveInBetweenIsKept() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let editorSaves = Mutex(1)
        workspace.fontSizeBeforeReplace = {
            editorSaves.withLock { remaining in
                if remaining > 0 {
                    remaining -= 1
                    try? "# the editor's\n[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        workspace.perform(.zoomFont(.larger))
        await workspace.settle()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# the editor's\n[font]\nsize = 12\n")
        #expect(workspace.notices.isEmpty)
        // Its kept copy is gone once its text, with the size, was confirmed in the file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["settings.toml"])
    }

    /// An editor that saves before every one of Blitter's writes: after three tries the size
    /// is in the file, and every version the editor saved is kept beside it, never lost.
    @Test func aFileThatKeepsChangingKeepsEveryOtherVersion() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let saves = Mutex(0)
        workspace.fontSizeBeforeReplace = {
            let count = saves.withLock { $0 += 1; return $0 }
            try? "# save \(count)\n[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        workspace.perform(.zoomFont(.larger))
        await workspace.settle()
        #expect(saves.withLock { $0 } == 3)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# save 2\n[font]\nsize = 12\n")
        for number in 1 ... 3 {
            #expect(try String(contentsOfFile: path + ".conflict-\(number)", encoding: .utf8)
                == "# save \(number)\n[font]\nsize = 11\n")
        }
        #expect(workspace.notices.count == 1)
        #expect(workspace.notices.first?.text.contains(path + ".conflict-3") == true)
    }

    /// The editor's save is not text Blitter can read: it stays byte for byte beside the file,
    /// and the notice says where.
    @Test func anEditorsSaveThatIsNotTextIsKeptAsItIs() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let notText = Data([0x23, 0xFF, 0xFE, 0x0A])
        let once = Mutex(true)
        workspace.fontSizeBeforeReplace = {
            if once.withLock({ let first = $0; $0 = false; return first }) {
                try? notText.write(to: URL(fileURLWithPath: path))
            }
        }
        workspace.perform(.zoomFont(.larger))
        await workspace.settle()
        #expect(FileManager.default.contents(atPath: path + ".conflict-1") == notText)
        #expect(workspace.notices.first?.text.contains(path + ".conflict-1") == true)
    }

    /// A version kept by an earlier save is never overwritten by a later one.
    @Test func anEarlierKeptVersionSurvivesALaterConflict() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        try "kept before".write(toFile: path + ".conflict-1", atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        let once = Mutex(true)
        workspace.fontSizeBeforeReplace = {
            if once.withLock({ let first = $0; $0 = false; return first }) {
                try? "# editor\n[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        workspace.perform(.zoomFont(.larger))
        await workspace.settle()
        #expect(try String(contentsOfFile: path + ".conflict-1", encoding: .utf8) == "kept before")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# editor\n[font]\nsize = 12\n")
        #expect(workspace.notices.isEmpty) // the editor's text is in the file: its copy is gone
        #expect(!FileManager.default.fileExists(atPath: path + ".conflict-2"))
    }

    /// Zoom, then quit at once: the size is saved without waiting out the pause.
    @Test func finishingSavesAtOnce() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        workspace.fontSizeSaveDelay = .seconds(60)
        workspace.perform(.zoomFont(.larger))
        workspace.perform(.zoomFont(.larger))
        let start = ContinuousClock.now
        await workspace.finishSavingFontSize()
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "[font]\nsize = 13\n")
        #expect(workspace.pendingFontSize == nil)
        await workspace.settle()
    }

    /// The first save creates the settings folder: the watcher is asked again, so later edits in
    /// it are seen.
    @Test func creatingTheFolderWatchesItAgain() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/blitter/settings.toml"
        let workspace = await makeWorkspace(settingsFile: path)
        let watcher = try #require(workspace.watcher as? FakeWatcher)
        let calls = watcher.watchCalls
        workspace.perform(.zoomFont(.larger))
        await workspace.settle()
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(watcher.watchCalls > calls)
        #expect(watcher.watched.contains(folder.path + "/blitter"))
    }
}
