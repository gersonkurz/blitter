import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// The file list's context menu (#19), opened the way the user opens it: real right-click,
/// ctrl-click and keyboard events in a window. Each menu is closed again as soon as it is up.
@MainActor
@Suite(.serialized)
final class ContextMenuInteractionTests {
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        let entries = [file("a.txt"), file("b.txt"), folder("sub")]
        workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { _ in entries },
                              directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        controller = FileListViewController(workspace: workspace, side: .right)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 200 where workspace.state(of: .right).visibleEntries.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.render()
        controller.view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(controller.tableView)
    }

    isolated deinit {
        window.close()
    }

    @Test func aRightClickOnAnUnselectedRowIsForThatRow() throws {
        workspace.perform(.select(.right, ["b.txt"]))
        let shown = try open(mouse: .rightMouseDown, at: row("a.txt"))
        #expect(shown == [
            "Open", "Quick Look", "-", "Copy Path", "Copy Name", "-", "Rename", "Move to Trash",
            "Delete Immediately", "-", "Reveal in Finder", "Open in Terminal", "Open in Code", "Open in Text Editor",
        ])
        #expect(workspace.activeSide == .right)
        #expect(workspace.state(of: .right).selection == ["a.txt"])
        #expect(try deleteTargets() == ["/fake/a.txt"])
    }

    @Test func aCtrlClickInsideTheSelectionKeepsIt() throws {
        workspace.perform(.select(.right, ["a.txt", "b.txt"]))
        let shown = try open(mouse: .leftMouseDown, at: row("b.txt"), modifiers: .control)
        #expect(workspace.state(of: .right).selection == ["a.txt", "b.txt"])
        #expect(!shown.contains("Open") && !shown.contains("Rename") && shown.contains("Move to Trash"))
        #expect(try deleteTargets() == ["/fake/a.txt", "/fake/b.txt"])
    }

    @Test func aRightClickOnEmptySpaceIsForTheFolder() throws {
        workspace.perform(.select(.right, ["a.txt"]))
        let below = controller.tableView.rect(ofRow: 2).maxY + 40
        let shown = try open(mouse: .rightMouseDown, at: NSPoint(x: 50, y: below))
        #expect(workspace.state(of: .right).selection.isEmpty)
        #expect(shown == ["New Folder", "-", "Open in Terminal", "Open in Code"])
    }

    /// The keyboard menu (⌃↩) is for the selection as it is. AppKit fakes a click for it; with
    /// three rows the view's middle is empty space, so trusting that click would show the
    /// folder menu and drop the selection.
    @Test func theKeyboardMenuIsForTheSelection() throws {
        workspace.perform(.select(.right, ["b.txt"]))
        let shown = try openFromKeyboard()
        #expect(workspace.state(of: .right).selection == ["b.txt"])
        #expect(shown.first == "Open")
        #expect(try deleteTargets() == ["/fake/b.txt"])

        workspace.perform(.select(.right, []))
        #expect(try openFromKeyboard() == ["New Folder", "-", "Open in Terminal", "Open in Code"])
    }

    @Test func theKeyboardMenuAppearsAtTheSelectedRow() throws {
        workspace.perform(.select(.right, ["b.txt"]))
        let table = controller.tableView
        #expect(try table.selectionAnchorRect == table.rect(ofRow: index("b.txt")))
    }

    @Test func submenusAreBuiltFromTheSettings() throws {
        workspace.settings.contextMenus.items = [.submenu("Copy", [.action("copy-path"), .action("copy-name")])]
        var copied: [String] = []
        workspace.system.copyText = { copied.append($0) }
        _ = try open(mouse: .rightMouseDown, at: row("b.txt"))
        let menu = try #require(controller.tableView.menu)
        #expect(menu.items.first?.title == "Copy")
        let submenu = try #require(menu.items.first?.submenu)
        #expect(submenu.items.map(\.title) == ["Copy Path", "Copy Name"])
        try choose("Copy Name", in: submenu)
        #expect(copied == ["b.txt"])
    }

    // MARK: Helpers

    private func index(_ name: String) throws -> Int {
        try #require(controller.entries.firstIndex { $0.entry.name == name })
    }

    private func row(_ name: String) throws -> NSPoint {
        let rect = try controller.tableView.rect(ofRow: index(name))
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// Hands a mouse event at a point of the table to the table; AppKit opens the menu.
    private func open(mouse type: NSEvent.EventType, at point: NSPoint,
                      modifiers: NSEvent.ModifierFlags = []) throws -> [String]
    {
        let location = controller.tableView.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let table = controller.tableView
        if type == .rightMouseDown {
            return try whileOpen { table.rightMouseDown(with: event) }
        }
        // A ctrl-click: AppKit asks the view for its menu with the click (which sets clickedRow),
        // then pops it up. (Handing the event to mouseDown would start a drag-tracking loop.)
        let menu = try #require(table.menu(for: event), "a ctrl-click must give the context menu")
        return try whileOpen { NSMenu.popUpContextMenu(menu, with: event, for: table) }
    }

    private func openFromKeyboard() throws -> [String] {
        try whileOpen { controller.tableView.showContextMenuForSelection(nil) }
    }

    /// Runs `show`, which opens the table's menu and tracks it until it closes; a timer reads the
    /// menu once it is up and closes it. Fails if the menu never opened.
    private func whileOpen(_ show: () -> Void) throws -> [String] {
        let menu = try #require(controller.tableView.menu)
        let reader = MenuReader(menu)
        RunLoop.main.add(reader.timer, forMode: .common)
        show()
        reader.timer.invalidate()
        return try #require(reader.titles, "the menu did not open")
    }

    /// What the menu's Delete Immediately would delete: it asks first, and the answer is no.
    private func deleteTargets() throws -> [String] {
        let menu = try #require(controller.tableView.menu)
        try choose("Delete Immediately", in: menu)
        let request = try #require(workspace.deleteRequest)
        workspace.perform(.answerDelete(token: request.token, delete: false))
        return request.paths
    }

    private func choose(_ title: String, in menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title })
        _ = item.target?.perform(item.action, with: item)
    }
}
