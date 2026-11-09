import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Testing

/// The Git Clean window (#71): Delete for Good asks first (Cancel keeps everything), unless the
/// settings turn the question off, as for Delete Immediately.
@MainActor
@Suite(.serialized)
final class GitCleanWindowTests {
    private let folder = NSTemporaryDirectory() + "BlitterAppTests-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
    }

    isolated deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func window(_ workspace: Workspace) async throws -> GitCleanWindowController {
        FileManager.default.createFile(atPath: folder + "/x.txt", contents: Data("x".utf8))
        let folder = folder
        let access = GitCleanAccess(preview: { _, _, _, _ in
            FileManager.default
                .fileExists(atPath: folder + "/x.txt") ? GitCleanPreview(removed: ["x.txt"]) : GitCleanPreview()
        }, isFolder: { _ in true })
        let controller = GitCleanWindowController(workspace: workspace, path: folder, access: access)
        try await waitUntil { controller.clean.items != nil }
        return controller
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func deleteForGoodAsksFirst() async throws {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, volumes: { [] },
                                  watcher: FakeWatcher.factory)
        let controller = try await window(workspace)
        defer { controller.close() }
        #expect(controller.deleteButton.isEnabled && controller.statusLabel.stringValue == "1 item would go.")
        var asked: [Int] = []
        controller.confirmDelete = { count, answer in
            asked.append(count)
            answer(false) // Cancel
        }
        controller.deleteButton.performClick(nil)
        #expect(asked == [1] && workspace.jobs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder + "/x.txt"))

        controller.confirmDelete = { _, answer in answer(true) }
        controller.deleteButton.performClick(nil)
        try await waitUntil { controller.clean.items == [] }
        #expect(!FileManager.default.fileExists(atPath: folder + "/x.txt"))
    }

    @Test func withoutTheQuestionItDeletesAtOnce() async throws {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, volumes: { [] },
                                  watcher: FakeWatcher.factory)
        workspace.settings.confirmDelete = false
        let controller = try await window(workspace)
        defer { controller.close() }
        #expect(controller.deleteButton.title == "Delete for Good")
        controller.confirmDelete = { _, _ in Issue.record("it must not ask") }
        controller.deleteButton.performClick(nil)
        try await waitUntil { controller.clean.items == [] }
        #expect(!FileManager.default.fileExists(atPath: folder + "/x.txt"))
    }
}
