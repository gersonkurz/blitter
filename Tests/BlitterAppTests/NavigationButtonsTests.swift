import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// Back, Up and Forward next to the path field.
@MainActor
@Suite(.serialized)
final class NavigationButtonsTests {
    private let workspace: Workspace
    private let list: FileListViewController
    private let window: NSWindow

    init() async throws {
        let folders: [String: [DirectoryEntry]] = ["/home": [folder("Documents")], "/home/Documents": [], "/": []]
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { path in
            guard let entries = folders[path] else {
                throw POSIXError(.ENOENT)
            }
            return entries
        }, directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.perform(.activate(.right))
        list = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        workspace.onChange = { [list] in list.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.workspace.state(of: .left).status == .loaded }
        list.render()
        list.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    @Test func theButtonsSitLeftOfThePathFieldWithTheirSymbols() throws {
        let buttons = list.navigationButtons
        for button in [buttons.back, buttons.upward, buttons.forward] {
            #expect(button.image != nil)
        }
        let path = try #require(list.view.subviews.first { $0 is NSComboBox })
        #expect(buttons.frame.maxX <= path.frame.minX)
        #expect(abs(buttons.frame.midY - path.frame.midY) < 2)
    }

    @Test func theyNavigateActivateTheirSideAndFollowTheHistory() async throws {
        let buttons = list.navigationButtons
        #expect(!buttons.back.isEnabled && !buttons.forward.isEnabled && buttons.upward.isEnabled)
        #expect(workspace.activeSide == .right)

        buttons.upward.performClick(nil)
        #expect(workspace.activeSide == .left) // clicking a button activates its side
        try await waitUntil { self.workspace.state(of: .left).location == "/" }
        #expect(buttons.back.isEnabled && !buttons.upward.isEnabled && !buttons.forward.isEnabled)

        buttons.back.performClick(nil)
        try await waitUntil { self.workspace.state(of: .left).location == "/home" }
        #expect(buttons.forward.isEnabled)

        buttons.forward.performClick(nil)
        try await waitUntil { self.workspace.state(of: .left).location == "/" }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
