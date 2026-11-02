import AppKit
@testable import Blitter
@testable import BlitterModel
import SwiftUI
import Testing

/// Batch Rename in the main window: the action shows the sheet, the preview follows the rule,
/// Rename renames and closes it.
@MainActor
@Suite(.serialized)
final class BatchRenameDialogTests {
    private let folder: String

    init() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            + "/BlitterBatchRename-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for file in ["one.txt", "two.txt", "Note 1.txt"] {
            FileManager.default.createFile(atPath: folder + "/" + file, contents: Data(file.utf8))
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func theSheetPreviewsAndRenames() async throws {
        BatchRenameModel.lastRule = BatchRename()
        let workspace = Workspace(initialLocation: folder, home: folder, volumes: { [] }, watcher: FakeWatcher.factory)
        let controller = MainWindowController(workspace: workspace)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        try await waitUntil { workspace.state(of: .left).visibleEntries.count == 3 }
        workspace.perform(.select(.left, ["one.txt", "two.txt"]))
        workspace.perform(.runAction("batch-rename", .left))

        let content = try #require(window.contentViewController)
        let sheet = try #require(content.presentedViewControllers?.first as? NSHostingController<BatchRenameView>)
        let model = sheet.rootView.model
        #expect(model.status == "0 of 2 names change")
        model.rule.template = "Note {n}"
        // "Note 1.txt" is there already and keeps its name.
        #expect(model.status == "An item with this name is already there." && !model.preview.canRename)
        model.rule.counterStart = 2
        #expect(model.preview.rows.map(\.newName) == ["Note 2.txt", "Note 3.txt"] && model.preview.canRename)
        #expect(model.status == "2 of 2 names change")

        model.rename()
        try await waitUntil { content.presentedViewControllers?.isEmpty != false }
        try await waitUntil { workspace.state(of: .left).selection == ["Note 2.txt", "Note 3.txt"] }
        #expect(FileManager.default.contents(atPath: folder + "/Note 3.txt") == Data("two.txt".utf8))
        #expect(BatchRenameModel.lastRule.template == "Note {n}") // offered next time
    }

    @Test func thePreviewFollowsTheFolderWhileTheSheetIsOpen() async throws {
        BatchRenameModel.lastRule = BatchRename()
        let workspace = Workspace(initialLocation: folder, home: folder, volumes: { [] }, watcher: FakeWatcher.factory)
        let controller = MainWindowController(workspace: workspace)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        try await waitUntil { workspace.state(of: .left).visibleEntries.count == 3 }
        workspace.perform(.select(.left, ["one.txt", "two.txt"]))
        workspace.perform(.runAction("batch-rename", .left))
        let content = try #require(window.contentViewController)
        let sheet = try #require(content.presentedViewControllers?.first as? NSHostingController<BatchRenameView>)
        let model = sheet.rootView.model
        model.rule.template = "{n}"
        #expect(model.preview.rows.map(\.newName) == ["1.txt", "2.txt"])

        // Another app deletes "one.txt": the sheet shows what Rename would now do.
        try FileManager.default.removeItem(atPath: folder + "/one.txt")
        workspace.reload(showing: [folder])
        try await waitUntil { model.preview.rows.count == 1 }
        #expect(model.preview.rows.map(\.newName) == ["1.txt"])
        model.rename()
        try await waitUntil { FileManager.default.fileExists(atPath: self.folder + "/1.txt") }
        #expect(FileManager.default.contents(atPath: folder + "/1.txt") == Data("two.txt".utf8))
    }
}
