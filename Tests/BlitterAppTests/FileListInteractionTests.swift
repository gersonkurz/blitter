import AppKit
@testable import Blitter
import BlitterCore
import BlitterModel
import Foundation
import Testing

private let fakeFolders: [String: [DirectoryEntry]] = [
    "/home": [folder("Desktop"), folder("Documents"),
              folder("Downloads"), file("notes.txt")],
    "/home/Documents": [file("a.txt")],
    "/home/Downloads": [file("b.zip")],
    "/pasted": [file("c.txt")],
]

/// Drives one side's file list in a real window with real key events, the way AppKit delivers
/// them, without System Events or accessibility permissions. The main menu is the app's own.
@MainActor
@Suite(.serialized)
final class FileListInteractionTests {
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { path in
            guard let entries = fakeFolders[path] else {
                throw POSIXError(.ENOENT)
            }
            return entries
        }, directoryCheck: { fakeFolders[$0] != nil }, volumes: { [] },
        watcher: FakeWatcher.factory)
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 700, height: 500)) // the controller shrank it to its fitting size
        workspace.onChange = { [controller] in controller.render() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.workspace.state(of: .left).status == .loaded }
        controller.render()
    }

    /// Swift Testing may release the suite on any thread; an isolated deinit hops to the main actor.
    isolated deinit {
        window.close()
    }

    // MARK: Tests

    /// Never touches the user's clipboard: the text comes from a private pasteboard, through the
    /// same `readSelection(from:)` that `paste:` uses on the general one.
    @Test func pastingAPathAndPressingReturnNavigates() async throws {
        let general = NSPasteboard.general
        let generalChanges = general.changeCount
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Blitter.tests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("/pasted", forType: .string)

        controller.focusPathField()
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        // The app's own ⌘V item has no target, so AppKit sends it to the first responder: the
        // path field's editor, which must handle it.
        let paste = try #require(menuItem(in: "Edit", titled: "Paste"))
        #expect(paste.keyEquivalent == "v" && paste.keyEquivalentModifierMask == .command && paste.target == nil)
        let action = try #require(paste.action)
        #expect(editor.responds(to: action))
        #expect(editor.readSelection(from: pasteboard))
        #expect(editor.string == "/pasted")

        editor.keyDown(with: key("\r", code: 36))
        try await waitUntil { self.workspace.state(of: .left).entriesLocation == "/pasted" }
        #expect(workspace.state(of: .left).location == "/pasted")
        #expect(window.firstResponder === tableView) // focus went back to the list
        #expect(general.changeCount == generalChanges) // the user's clipboard was not touched
    }

    @Test func escapeInThePathFieldDropsTheEdit() throws {
        controller.focusPathField()
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("/somewhere/else", replacementRange: editor.selectedRange())

        editor.keyDown(with: key("\u{1b}", code: 53))
        #expect(pathField.stringValue == "/home")
        #expect(window.firstResponder === tableView)
        #expect(workspace.state(of: .left).location == "/home")
    }

    @Test func returnOpensTheSelectedFolder() async throws {
        workspace.perform(.select(.left, ["Documents"]))
        window.makeFirstResponder(tableView)
        tableView.keyDown(with: key("\r", code: 36))
        try await waitUntil { self.workspace.state(of: .left).entriesLocation == "/home/Documents" }
        #expect(names() == ["a.txt"])
    }

    @Test func returnOnAFileDoesNothing() {
        workspace.perform(.select(.left, ["notes.txt"]))
        window.makeFirstResponder(tableView)
        tableView.keyDown(with: key("\r", code: 36))
        #expect(workspace.state(of: .left).location == "/home")
    }

    /// Synthetic mouse tracking does not run in a background test host, so this checks the wiring;
    /// the click itself is checked by hand.
    @Test func doubleClickIsWiredToOpen() {
        #expect(tableView.target === controller)
        #expect(tableView.doubleAction == NSSelectorFromString("openClickedRow:"))
        #expect(controller.responds(to: tableView.doubleAction))
    }

    @Test func typingSelectsByNamePrefix() async throws {
        window.makeFirstResponder(tableView)
        tableView.keyDown(with: key("d", code: 2))
        tableView.keyDown(with: key("o", code: 31))
        tableView.keyDown(with: key("w", code: 13))
        try await waitUntil { self.workspace.state(of: .left).selection == ["Downloads"] }
    }

    /// macOS adapts ⌘[ and ⌘] to the keyboard layout (⌘ö and ⌘ä on German), so only the layout
    /// independent parts are compared exactly.
    @Test func goMenuHasTheNavigationShortcuts() throws {
        let back = try #require(menuItem(in: "Go", titled: "Back"))
        let forward = try #require(menuItem(in: "Go", titled: "Forward"))
        let parent = try #require(menuItem(in: "Go", titled: "Enclosing Folder"))
        let goTo = try #require(menuItem(in: "Go", titled: "Go to Folder…"))
        for item in [back, forward, parent] {
            #expect(item.keyEquivalentModifierMask == .command)
        }
        #expect(!back.keyEquivalent.isEmpty && !forward.keyEquivalent.isEmpty)
        let upArrow = try #require(UnicodeScalar(NSUpArrowFunctionKey))
        #expect(parent.keyEquivalent == String(Character(upArrow)))
        #expect(goTo.keyEquivalent == "g" && goTo.keyEquivalentModifierMask == [.command, .shift])
    }

    // MARK: Helpers

    private var tableView: NSTableView {
        // swiftlint:disable:next force_cast
        (controller.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as! NSTableView)
    }

    private var pathField: NSComboBox {
        // swiftlint:disable:next force_cast
        controller.view.subviews.first { $0 is NSComboBox } as! NSComboBox
    }

    private func menuItem(in menu: String, titled title: String) -> NSMenuItem? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == menu }?.submenu?.items.first { $0.title == title }
    }

    private func names() -> [String] {
        workspace.state(of: .left).visibleEntries.map(\.entry.name)
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        // swiftlint:disable:next force_unwrapping
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
