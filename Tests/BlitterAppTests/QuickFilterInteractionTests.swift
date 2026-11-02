import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// The fast filter in the list (#39), driven by key presses on the table.
@MainActor
@Suite(.serialized)
final class QuickFilterInteractionTests {
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        let listings = ["/fake": [folder("docs"), file("notes.txt"), file("readme.md"), file("todo.txt")]]
        workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { listings[$0] ?? [] },
                              directoryCheck: { listings[$0] != nil }, volumes: { [] }, watcher: FakeWatcher.factory)
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.controller.entries.count == 4 }
        window.makeFirstResponder(controller.tableView)
    }

    isolated deinit {
        window.close()
    }

    private func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: keyCode
        ))
        controller.tableView.keyDown(with: event)
    }

    private func isBold(_ name: String) throws -> Bool {
        let row = try #require(controller.entries.firstIndex { $0.entry.name == name })
        let cell = controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        let font = try #require(cell?.textField?.font)
        return font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    @Test func typingHighlightsAndArrowsStepThroughTheMatches() async throws {
        try press("t")
        try press("x")
        try await waitUntil { self.workspace.state(of: .left).highlighted.count == 2 }
        #expect(workspace.state(of: .left).quickFilter == QuickFilter("tx", mode: .highlight))
        #expect(workspace.state(of: .left).selection == ["notes.txt"])
        #expect(!controller.quickFilterBar.isHidden)
        #expect(controller.quickFilterBar.label.stringValue.hasPrefix("Find “tx”: 2 matches"))
        #expect(try isBold("notes.txt") && isBold("todo.txt") && !isBold("readme.md"))

        try press("\u{F701}", keyCode: 125) // ↓
        #expect(workspace.state(of: .left).selection == ["todo.txt"])
        try press("\u{7F}", keyCode: 51) // Backspace
        #expect(workspace.state(of: .left).quickFilter?.text == "t")
        try await waitUntil { self.workspace.state(of: .left).highlighted.count == 2 }
        try press("\u{1B}", keyCode: 53) // Escape
        #expect(workspace.state(of: .left).quickFilter == nil)
        #expect(controller.quickFilterBar.isHidden)
        #expect(try !isBold("notes.txt"))
    }

    @Test func aStarFiltersTheList() async throws {
        try press("*")
        #expect(controller.quickFilterBar.label.stringValue.hasPrefix("Filter type to filter"))
        try press("m")
        try press("d")
        try await waitUntil { self.controller.entries.count == 1 }
        #expect(controller.entries.map(\.entry.name) == ["readme.md"])
        #expect(controller.quickFilterBar.label.stringValue.hasPrefix("Filter “md”: 1 item"))
        try press("\u{7F}", keyCode: 51)
        try press("\u{7F}", keyCode: 51)
        try press("\u{7F}", keyCode: 51) // nothing left: the filter ends
        try await waitUntil { self.controller.entries.count == 4 }
        #expect(workspace.state(of: .left).quickFilter == nil)
    }

    @Test func keysTheFilterDoesNotTakeKeepTheirMeaning() throws {
        var previews = 0
        controller.tableView.onSpace = { previews += 1 }
        try press(" ", keyCode: 49) // Space without a filter: Quick Look
        #expect(previews == 1 && workspace.state(of: .left).quickFilter == nil)
        try press("c", keyCode: 8, modifiers: .command) // a shortcut, not typing
        #expect(workspace.state(of: .left).quickFilter == nil)
        try press("n")
        try press(" ", keyCode: 49) // with a filter, Space is typed
        #expect(workspace.state(of: .left).quickFilter?.text == "n " && previews == 1)
    }

    /// #39 review: a match outside the visible rows is scrolled into view, by typing and by
    /// stepping (wrapping around to the end).
    @Test func aSelectedMatchIsScrolledIntoView() async throws {
        let many = (0 ..< 300).map { file(String(format: "file%03d.txt", $0)) } + [file("zebra.txt")]
        let workspace = Workspace(initialLocation: "/many", home: "/home", lister: { _ in many },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        let list = FileListViewController(workspace: workspace, side: .left)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        window.setContentSize(NSSize(width: 600, height: 300)) // the controller sized it to fit
        workspace.onChange = { list.render() }
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await waitUntil { list.entries.count == 301 }
        list.view.layoutSubtreeIfNeeded()
        #expect(list.tableView.rows(in: list.tableView.visibleRect).length > 5) // a real viewport
        func isVisible(_ name: String) throws -> Bool {
            let row = try #require(list.entries.firstIndex { $0.entry.name == name })
            list.view.layoutSubtreeIfNeeded()
            return list.tableView.rows(in: list.tableView.visibleRect).contains(row)
        }
        #expect(try !isVisible("zebra.txt"))
        for key in "zeb" {
            workspace.perform(.setQuickFilter(.left, QuickFilter(
                (workspace.state(of: .left).quickFilter?.text ?? "") + String(key), mode: .highlight
            )))
        }
        try await waitUntil { workspace.state(of: .left).selection == ["zebra.txt"] }
        #expect(try isVisible("zebra.txt"))

        workspace.perform(.setQuickFilter(.left, QuickFilter("file0", mode: .highlight)))
        try await waitUntil { workspace.state(of: .left).selection == ["file000.txt"] }
        #expect(try isVisible("file000.txt"))
        workspace.perform(.selectQuickFilterMatch(.left, forward: false)) // wraps to the last match
        #expect(workspace.state(of: .left).selection == ["file099.txt"])
        #expect(try isVisible("file099.txt"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
