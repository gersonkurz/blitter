import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// #88: the main window's toolbar, built from the settings, following the active side.
@MainActor
@Suite(.serialized)
final class WindowToolbarTests {
    private let workspace: Workspace
    private let window: NSWindow
    private let toolbar: WindowToolbar

    init() async throws {
        let folders: [String: [DirectoryEntry]] = [
            "/home": [DirectoryEntry(name: "a.txt", kind: .file, size: 1, modificationDate: .distantPast,
                                     isHidden: false, isDataless: false, error: 0)],
        ]
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { path in
            guard let entries = folders[path] else {
                throw POSIXError(.ENOENT)
            }
            return entries
        }, directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        toolbar = WindowToolbar(workspace: workspace, window: window)
        try await waitUntil { self.workspace.state(of: .left).status == .loaded }
        toolbar.render()
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

    private func button(_ id: String) throws -> NSButton {
        try #require(toolbar.buttons.values.first { $0.id == id }?.button)
    }

    /// A misspelt symbol would show the question mark: every action's own must be one macOS has.
    @Test func everyActionsSymbolIsAnSFSymbol() {
        let actions = ActionRegistry.builtIn.all + Tool.defaults.map(\.action)
            + [Tool(id: "x", title: "X", app: "X", scope: .files), Tool(id: "y", title: "Y", app: "", scope: .folder,
                                                                        command: ["true"])].map(\.action)
        for action in actions {
            #expect(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil, "\(action.id)")
        }
        #expect(NSImage(systemSymbolName: WindowToolbar.unknownSymbol, accessibilityDescription: nil) != nil)
    }

    @Test func theDefaultToolbarHasAButtonPerActionAndGaps() throws {
        let items = try #require(window.toolbar).items
        #expect(items.count == Settings().toolbar.count)
        #expect(items.filter { $0.itemIdentifier == .space }.count == 2)
        #expect(toolbar.buttons.count == 12)
        #expect(try button("refresh").toolTip == "Refresh")
        #expect(try button("refresh").image != nil)
    }

    @Test func buttonsFollowTheActiveSideAndTheToggleShowsItsState() throws {
        #expect(try button("refresh").isEnabled)
        #expect(try !button("move-to-trash").isEnabled)
        workspace.perform(.select(.left, ["a.txt"]))
        toolbar.render()
        #expect(try button("move-to-trash").isEnabled)

        let hidden = try button("toggle-hidden-files")
        #expect(hidden.state == .off)
        hidden.performClick(nil)
        #expect(workspace.showsHiddenFiles)
        #expect(hidden.state == .on)
        workspace.perform(.toggleHiddenFiles) // from the View menu: the button follows
        toolbar.render()
        #expect(hidden.state == .off)
    }

    /// A button the window has no room for is in the overflow menu: its menu item runs the same
    /// action, and is enabled and checked as the button is (#88 review). AppKit sends the item
    /// itself to its target, as `sendAction` does here.
    @Test func overflowMenuItemsRunTheirActionsAndShowTheirState() throws {
        let items = try #require(window.toolbar).items.filter { $0.itemIdentifier != .space }
        #expect(items.count == toolbar.buttons.count)
        func menuItem(_ id: String) throws -> NSMenuItem {
            let item = try #require(items.first { toolbar.buttons[$0.itemIdentifier]?.id == id })
            return try #require(item.menuFormRepresentation)
        }
        let trash = try menuItem("move-to-trash")
        #expect(trash.title == "Move to Trash" && trash.image != nil)
        #expect(!toolbar.validateMenuItem(trash))
        workspace.perform(.select(.left, ["a.txt"]))
        #expect(toolbar.validateMenuItem(trash))

        let hidden = try menuItem("toggle-hidden-files")
        #expect(toolbar.validateMenuItem(hidden) && hidden.state == .off)
        #expect(try NSApp.sendAction(#require(hidden.action), to: hidden.target, from: hidden))
        #expect(workspace.showsHiddenFiles)
        #expect(toolbar.validateMenuItem(hidden) && hidden.state == .on)
        #expect(try button("toggle-hidden-files").state == .on) // the button follows too
    }

    @Test func aChangedToolbarIsBuiltAnewAndAnEmptyOneIsNone() throws {
        workspace.settings.toolbar = [.action("refresh", icon: "no.such.symbol"), .gap,
                                      .action("toggle-hidden-files", icon: "star")]
        toolbar.render()
        #expect(try #require(window.toolbar).items.count == 3)
        #expect(toolbar.buttons.count == 2)
        let unknown = NSImage(systemSymbolName: WindowToolbar.unknownSymbol, accessibilityDescription: "Refresh")
        #expect(try button("refresh").image?.tiffRepresentation == unknown?.tiffRepresentation)
        workspace.settings.toolbar = []
        toolbar.render()
        #expect(window.toolbar == nil)
        #expect(toolbar.buttons.isEmpty)
    }
}
