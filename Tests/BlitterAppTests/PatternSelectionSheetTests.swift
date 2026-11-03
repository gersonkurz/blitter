import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// The Select by Pattern… sheet, presented on a real window.
@MainActor
@Suite(.serialized)
final class PatternSelectionSheetTests {
    private let workspace: Workspace
    private let window: NSWindow
    private let content = NSViewController()

    init() async throws {
        let listings = ["/fake": [folder("docs"), file("notes.txt"), file("readme.md"), file("todo.txt")]]
        workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { listings[$0] ?? [] },
                              directoryCheck: { listings[$0] != nil }, volumes: { [] }, watcher: FakeWatcher.factory)
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.workspace.state(of: .left).visibleEntries.count == 4 }
    }

    isolated deinit {
        window.close()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func selectAndDeselectApplyThePatternAndCloseTheSheet() async throws {
        PatternSelectionSheet.lastPattern = ""
        PatternSelectionSheet.lastIncludesFolders = false
        let sheet = PatternSelectionSheet(workspace: workspace, side: .left)
        content.presentAsSheet(sheet)
        #expect(content.presentedViewControllers?.count == 1)
        sheet.field.stringValue = "*.txt"
        sheet.select(nil)
        try await waitUntil { self.workspace.state(of: .left).selection == ["notes.txt", "todo.txt"] }
        try await waitUntil { self.content.presentedViewControllers?.isEmpty != false }

        // The pattern is offered again; Deselect takes the matches out.
        let again = PatternSelectionSheet(workspace: workspace, side: .left)
        content.presentAsSheet(again)
        #expect(again.field.stringValue == "*.txt")
        again.field.stringValue = "todo*"
        again.deselect(nil)
        try await waitUntil { self.workspace.state(of: .left).selection == ["notes.txt"] }

        // Cancel changes nothing.
        let cancelled = PatternSelectionSheet(workspace: workspace, side: .left)
        content.presentAsSheet(cancelled)
        cancelled.field.stringValue = "*"
        cancelled.cancel(nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspace.state(of: .left).selection == ["notes.txt"])
        #expect(PatternSelectionSheet.lastPattern == "todo*")

        // "Include folders" (#56): off, "*" selects the files only; on, the folder too, and it is
        // offered on again next time.
        let files = PatternSelectionSheet(workspace: workspace, side: .left)
        content.presentAsSheet(files)
        #expect(files.includesFolders.state == .off)
        files.field.stringValue = "*"
        files.select(nil)
        try await waitUntil { self.workspace.state(of: .left).selection == ["notes.txt", "readme.md", "todo.txt"] }
        let all = PatternSelectionSheet(workspace: workspace, side: .left)
        content.presentAsSheet(all)
        all.includesFolders.state = .on
        all.select(nil)
        try await waitUntil { self.workspace.state(of: .left).selection.contains("docs") }
        let remembered = PatternSelectionSheet(workspace: workspace, side: .left)
        content.presentAsSheet(remembered)
        #expect(remembered.includesFolders.state == .on)
        remembered.cancel(nil)
    }
}
