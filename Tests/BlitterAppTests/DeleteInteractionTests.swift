import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Testing

/// Delete Immediately (#17) in the app: the menu items, the words, and the sheet that asks.
@MainActor
@Suite(.serialized)
struct DeleteInteractionTests {
    @Test func theFileMenuHasDeleteImmediatelyAndItsNoQuestionAlternate() throws {
        let fileMenu = try #require(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "File" })
        let ask = try #require(fileMenu.items.first { $0.title == "Delete Immediately" })
        let now = try #require(fileMenu.items.first { $0.title == "Delete Immediately Without Asking" })
        #expect(ask.keyEquivalent == "\u{8}" && ask.keyEquivalentModifierMask == [.command, .option])
        #expect(now.keyEquivalent == "\u{8}" && now.keyEquivalentModifierMask == [.command, .option, .shift])
        #expect(!ask.isAlternate && now.isAlternate)
        #expect(ask.representedObject as? String == "delete-immediately")
        #expect(now.representedObject as? String == "delete-immediately-without-asking")
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(!delegate.validateMenuItem(ask) && !delegate.validateMenuItem(now)) // nothing selected
    }

    @Test func theQuestionNamesTheItemsAndSaysItCannotBeUndone() {
        let one = DeleteConfirmation.alert(for: DeleteRequest(paths: ["/a/report.txt"], token: 1))
        #expect(one.messageText == "Delete “report.txt” immediately?")
        #expect(one.informativeText.contains("cannot be undone") && one.informativeText
            .contains("not moved to the Trash"))
        let three = DeleteConfirmation.alert(for: DeleteRequest(paths: ["/a/x", "/a/y", "/a/z"], token: 2))
        #expect(three.messageText == "Delete 3 items immediately?")
        // Cancel comes first: it is the default button, so Return never deletes.
        #expect(three.buttons.map(\.title) == ["Cancel", "Delete"])
        #expect(three.buttons[1].hasDestructiveAction)
        #expect(JobText.title(.delete(["/a/x"])) == "Deleting “x”")
        #expect(JobText.title(.delete(["/a/x", "/a/y"])) == "Deleting 2 items")
    }

    @Test func theWindowAsksInASheetAndTheAnswerDecides() async throws {
        let folder = NSTemporaryDirectory() + "BlitterAppTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for name in ["keep.txt", "doomed.txt"] {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("x".utf8))
        }
        let workspace = Workspace(initialLocation: folder, home: folder, volumes: { [] }, watcher: FakeWatcher.factory,
                                  jobs: JobQueue(trash: { _ in
                                      Issue.record("nothing may go to the Trash")
                                      return nil
                                  }))
        let controller = MainWindowController(workspace: workspace)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        try await waitUntil { workspace.state(of: .left).visibleEntries.count == 2 }

        // Cancel: nothing happens.
        workspace.perform(.select(.left, ["doomed.txt"]))
        workspace.perform(.deleteSelection(.left))
        var sheet = try #require(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await waitUntil { workspace.deleteRequest == nil }
        #expect(FileManager.default.fileExists(atPath: folder + "/doomed.txt"))

        // Delete: exactly the confirmed item goes.
        workspace.perform(.deleteSelection(.left))
        sheet = try #require(window.attachedSheet)
        window.endSheet(sheet, returnCode: DeleteConfirmation.delete)
        try await waitUntil { !FileManager.default.fileExists(atPath: folder + "/doomed.txt") }
        #expect(FileManager.default.fileExists(atPath: folder + "/keep.txt"))
        #expect(window.attachedSheet == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
