import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// #64: the Settings window shows the settings file, saves what changed, and follows the file.
@MainActor
@Suite(.serialized)
final class SettingsWindowTests {
    private let folder: String
    private let path: String
    private let workspace: Workspace

    init() throws {
        folder = NSTemporaryDirectory() + "BlitterAppTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        path = folder + "/settings.toml"
        try "[files]\ndate_format = \"HH:mm\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        workspace = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                              directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                              settingsFile: path)
    }

    isolated deinit {
        SettingsWindowController.current?.close()
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func openWindow() async throws -> SettingsWindowModel {
        SettingsWindowController.show(workspace)
        let controller = try #require(SettingsWindowController.current)
        #expect(controller.window?.isVisible == true && controller.window?.title == "Settings")
        try await waitUntil { controller.model.document != nil }
        return controller.model
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func itShowsTheFileAndSavesWhatChanged() async throws {
        let model = try await openWindow()
        #expect(model.draft.dateFormat == "HH:mm" && !model.isDirty && !model.canSave)
        model.draft.font.face = "Helvetica"
        model.draft.gitColors = false
        #expect(model.isDirty && model.canSave)
        model.save()
        try await waitUntil { !model.isSaving } // clean once it is in the file
        #expect(!model.isDirty && model.saveProblem == nil)
        try await waitUntil { self.workspace.settings.font.face == "Helvetica" }
        let saved = try Settings.parse(String(contentsOfFile: path, encoding: .utf8))
        #expect(saved.problems.isEmpty)
        #expect(saved.settings.dateFormat == "HH:mm" && !saved.settings.gitColors && saved.settings.font
            .face == "Helvetica")
        SettingsWindowController.show(workspace) // ⌘, again: the same window
        #expect(SettingsWindowController.current?.model === model)
    }

    @Test func whatTheFileCannotHoldCannotBeSaved() async throws {
        let model = try await openWindow()
        model.draft.dateFormat = ""
        #expect(model.isDirty && !model.canSave && model.draftProblems.count == 1)
        model.revert()
        #expect(!model.isDirty && model.draftProblems.isEmpty)
    }

    @Test func itFollowsTheFileUnlessSomethingIsEdited() async throws {
        let model = try await openWindow()
        try "[files]\ndate_format = \"d.M.\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        workspace.loadSettings()
        try await waitUntil { self.workspace.settingsReads > 0 }
        model.workspaceChanged()
        try await waitUntil { model.draft.dateFormat == "d.M." }

        model.draft.confirmDelete = false // now something is edited
        try "[files]\ndate_format = \"yy\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        let reads = workspace.settingsReads
        workspace.loadSettings()
        try await waitUntil { self.workspace.settingsReads > reads }
        model.workspaceChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.draft.dateFormat == "d.M." && !model.draft.confirmDelete)
    }

    /// A save that fails keeps the draft's changes, and saving again works once the file is fixed.
    @Test func aFailedSaveKeepsTheChangesToSaveAgain() async throws {
        let model = try await openWindow()
        model.draft.gitColors = false
        try "[files\n".write(toFile: path, atomically: true, encoding: .utf8) // broken meanwhile
        model.save()
        #expect(model.isSaving && !model.canSave)
        try await waitUntil { !model.isSaving }
        #expect(model.saveProblem?.contains("could not be saved") == true)
        #expect(model.isDirty && !model.draft.gitColors && model.canSave)
        model.workspaceChanged() // a reload must not drop the changes either
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.draft.gitColors)

        try "[files]\ndate_format = \"HH:mm\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        model.save()
        try await waitUntil { !model.isSaving }
        #expect(model.saveProblem == nil && !model.isDirty)
        #expect(try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings.gitColors == false)
    }

    /// The file is read slowly; the user edits meanwhile: the edit stays when the read arrives.
    @Test func anEditWhileTheFileIsReadStays() async throws {
        let release = AsyncStream<Void>.makeStream()
        let workspace = workspace
        let model = SettingsWindowModel(workspace: workspace) {
            for await _ in release.stream {
                break
            }
            return await workspace.readSettingsDocument()
        }
        model.draft.confirmDelete = false
        release.continuation.yield()
        try await waitUntil { model.document != nil }
        // The file's settings are the baseline now, the edit on top of them, and it can be saved.
        #expect(model.original.dateFormat == "HH:mm" && model.draft.dateFormat == "HH:mm")
        #expect(!model.draft.confirmDelete && model.isDirty && model.canSave)
        model.save()
        try await waitUntil { !model.isSaving }
        #expect(model.saveProblem == nil && !model.isDirty)
        let saved = try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings
        #expect(!saved.confirmDelete && saved.dateFormat == "HH:mm") // the edit, and what it did not touch
    }

    /// Save, then quit at once: the app's wait for pending saves covers the window's save.
    @Test func quittingWaitsForTheSave() async throws {
        let model = try await openWindow()
        workspace.settingsFileBeforeReplace = { Thread.sleep(forTimeInterval: 0.3) }
        model.draft.gitColors = false
        model.save()
        #expect(workspace.isSavingSettings)
        var replied = false
        AppDelegate.finishSaving(workspace) { replied = true }
        try await waitUntil { replied }
        #expect(try Settings.parse(String(contentsOfFile: path, encoding: .utf8)).settings.gitColors == false)
    }

    /// Showing the Compare tab never changes a command, even one the editor can't show line by line.
    @Test func showingTheCompareTabChangesNothing() async throws {
        for command in [#"["bcomp", "", "{left}", "{right}"]"#, #"["bcomp", "{left}", "{right}"]"#] {
            try "[diff]\ntool = \(command)\n".write(toFile: path, atomically: true, encoding: .utf8)
            SettingsWindowController.current?.close()
            let model = try await openWindow()
            let tool = model.draft.diffTool
            model.tab = .compare
            // Drawn for real, so the tab's views appear (onAppear) as they do on screen.
            for _ in 0 ..< 3 {
                try await Task.sleep(for: .milliseconds(100))
                let view = try #require(SettingsWindowController.current?.window?.contentView)
                view.layoutSubtreeIfNeeded()
                view.display()
            }
            #expect(try #require(SettingsWindowController.current?.window?.contentView)
                .hasTextView == (command.contains("\"\"") == false))
            #expect(model.draft.diffTool == tool && !model.isDirty, "\(command)")
        }
    }

    @Test func aFileThatDoesNotParseIsShownButCannotBeSaved() async throws {
        try "[files\n".write(toFile: path, atomically: true, encoding: .utf8)
        let model = try await openWindow()
        #expect(model.document?.canBeSaved == false)
        model.draft.gitColors = false
        #expect(!model.canSave)
    }
}

extension NSView {
    /// Whether a text view (the Compare tab's command editor) is among the subviews.
    var hasTextView: Bool {
        self is NSTextView || subviews.contains { $0.hasTextView }
    }
}
